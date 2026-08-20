#!/bin/bash
# Spray queued FLEX_START GCE VMs across all valid (zone, SKU) combos for
# our GPU backend. First to fire wins; watcher kills the losers.
#
# Used when:
#   - GKE Autopilot's cluster-autoscaler is stuck in FailedScaleUp loops
#     (saw 43h of "GCE out of resources" in us-east5-a on 2026-05-15)
#   - The current GPU VM is about to hit its 7-day FLEX_START max-run-duration
#     and we need a fresh slot
#
# Behavior:
#   - Submits 1 queued FLEX_START VM per (zone, SKU) combo. Each holds a 2h
#     queue slot (max --request-valid-for-duration). Each grants 7d runtime.
#   - Costs $0 until DWS allocates. Once any one fires the watcher deletes
#     the rest before they can fire (so we never pay for parallel grants).
#   - Per docs, this is the recommended pattern: "if your request fails
#     because resources are unavailable, try creating the Flex-start VM in
#     a different zone" — we just do it in parallel.
#
# Standalone. This does not touch the Slurm cluster: it creates ordinary GCE
# VMs, not reservations or nodesets. scripts/flex-poll.sh is the cluster-facing
# equivalent, which creates FLEX_START reservations for nodesets to bind to.
#
# Usage:  PROJECT_ID=my-proj bash scripts/flex-spray.sh
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
LOG="${LOG:-/tmp/flex-spray.log}"
> "${LOG}"

# (zone, machine-type) tuples — every reachable combo where the project has
# subnet + SKU configured. Derived from `gcloud compute accelerator-types list`
# filtered against `gcloud compute networks subnets list`.
COMBOS=$(cat <<'EOF'
us-central1-a a3-megagpu-8g
us-central1-b a3-megagpu-8g
us-central1-c a3-megagpu-8g
us-east4-a a3-megagpu-8g
us-east4-b a3-megagpu-8g
us-east4-c a3-megagpu-8g
us-east5-a a3-megagpu-8g
us-west1-a a3-megagpu-8g
us-west1-b a3-megagpu-8g
us-west4-a a3-megagpu-8g
europe-west4-b a3-megagpu-8g
us-central1-a a3-highgpu-8g
us-central1-b a3-highgpu-8g
us-central1-c a3-highgpu-8g
us-east4-a a3-highgpu-8g
us-east4-b a3-highgpu-8g
us-east5-a a3-highgpu-8g
us-west1-a a3-highgpu-8g
us-west1-b a3-highgpu-8g
us-west4-a a3-highgpu-8g
us-central1-b a3-ultragpu-8g
us-east4-b a3-ultragpu-8g
us-east5-a a3-ultragpu-8g
us-south1-b a3-ultragpu-8g
us-west1-c a3-ultragpu-8g
europe-west4-a a3-ultragpu-8g
us-central1-b a4-highgpu-8g
us-east1-b a4-highgpu-8g
us-east4-b a4-highgpu-8g
us-south1-b a4-highgpu-8g
us-west2-c a4-highgpu-8g
us-west3-b a4-highgpu-8g
EOF
)

echo ">>> Submitting 32 queued FLEX_START VMs (2h queue, 7d runtime)..."
echo "$COMBOS" | grep -v '^$' | xargs -P 16 -L 1 bash -c '
  zone=$1 sku=$2
  region=$(echo $zone | sed "s/-[a-z]$//")
  short_sku=$(echo $sku | sed "s/gpu-8g//;s/-//g")
  short_zone=$(echo $zone | sed "s/-//g")
  name="qflex-${short_sku}-${short_zone}"
  out=$(gcloud compute instances create "$name" \
    --project='"${PROJECT_ID}"' --zone=$zone --machine-type=$sku \
    --provisioning-model=FLEX_START \
    --request-valid-for-duration=7200s \
    --max-run-duration=604800s --instance-termination-action=DELETE \
    --image-family=common-cu129-ubuntu-2204-nvidia-580 --image-project=deeplearning-platform-release \
    --boot-disk-size=200GB --boot-disk-type=hyperdisk-balanced \
    --subnet=projects/'"${PROJECT_ID}"'/regions/$region/subnetworks/default \
    --no-address --no-restart-on-failure --maintenance-policy=TERMINATE \
    --labels=purpose=demo-qflex --async 2>&1)
  rc=$?
  if [[ $rc -eq 0 ]]; then echo "QUEUED  $sku  $zone  →  $name" >> '"${LOG}"'
  else
    code=$(echo "$out" | grep -oE "code: [A-Z_]+" | head -1)
    echo "REJECT  $code  $sku  $zone" >> '"${LOG}"'
  fi
' _

QUEUED=$(grep -c ^QUEUED "${LOG}")
REJECTED=$(grep -c ^REJECT "${LOG}")
echo ">>> Submitted: ${QUEUED} queued, ${REJECTED} rejected"
echo

if [[ ${QUEUED} -eq 0 ]]; then
  echo "ERROR: no VMs queued — check quota / network / SKU eligibility"; exit 1
fi

echo ">>> Watching for first to fire (polls every 30s, up to 2h)..."
for i in $(seq 1 240); do
  STATUSES=$(gcloud compute instances list --project="${PROJECT_ID}" --filter="name~qflex" --format="csv[no-heading](name,zone,status)" 2>&1)
  TOTAL=$(echo "$STATUSES" | grep -v "^$" | wc -l)
  [[ $TOTAL -eq 0 ]] && { echo "All requests expired without a grant (2h window). Re-run script."; exit 1; }

  RUNNING=$(echo "$STATUSES" | grep ",RUNNING" | head -1)
  if [[ -n "$RUNNING" ]]; then
    WINNER_NAME=$(echo "$RUNNING" | cut -d, -f1)
    WINNER_ZONE=$(echo "$RUNNING" | cut -d, -f2)
    echo
    echo "🎯 WINNER: ${WINNER_NAME} in ${WINNER_ZONE}"
    echo "$STATUSES"
    echo
    echo ">>> Killing the ${TOTAL} - 1 losers in parallel..."
    echo "$STATUSES" | while IFS=, read name zone status; do
      [[ -z "$name" || "$name" == "$WINNER_NAME" ]] && continue
      ( gcloud compute instances delete "$name" --zone="$zone" --project="${PROJECT_ID}" --quiet 2>&1 | head -1 ) &
    done
    wait
    EXT_IP=$(gcloud compute instances describe "${WINNER_NAME}" --zone="${WINNER_ZONE}" --project="${PROJECT_ID}" --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null)
    if [[ -z "${EXT_IP}" ]]; then
      echo ">>> Adding external IP..."
      gcloud compute instances add-access-config "${WINNER_NAME}" --zone="${WINNER_ZONE}" --project="${PROJECT_ID}"
      EXT_IP=$(gcloud compute instances describe "${WINNER_NAME}" --zone="${WINNER_ZONE}" --project="${PROJECT_ID}" --format="value(networkInterfaces[0].accessConfigs[0].natIP)")
    fi
    echo
    echo "=================================================="
    echo "Winner ready:"
    echo "  Name:     ${WINNER_NAME}"
    echo "  Zone:     ${WINNER_ZONE}"
    echo "  Ext IP:   ${EXT_IP}"
    echo "  Max run:  7 days from grant"
    echo
    echo "  SSH:      gcloud compute ssh ${WINNER_NAME} --zone=${WINNER_ZONE} --tunnel-through-iap"
    echo "  Delete:   gcloud compute instances delete ${WINNER_NAME} --zone=${WINNER_ZONE} --quiet"
    echo "=================================================="
    exit 0
  fi
  echo "[t+$((i*30))s] queued=$(echo "$STATUSES" | grep -c ',PENDING')  total=$TOTAL"
  sleep 30
done

echo ">>> 2h window ended with no grant. Re-run the script."
exit 1
