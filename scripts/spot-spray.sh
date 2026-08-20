#!/bin/bash
# Spot sibling of flex-spray.sh. Retry-loops SPOT VM creation across every
# zone that carries the SKU until one lands, then stops.
#
# Why a loop and not a single spray: Spot creation is synchronous. A zone that
# returns ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS is reporting this instant,
# not a standing condition. Field-validated 2026-08-10: a 14-zone a4-highgpu-8g
# spray returned 12/12 real stockouts at 17:26:11Z; the same loop landed
# us-west2-c at 17:28:06Z, 38 seconds after that zone had refused. RUNNING at
# 17:35:53Z, so about 8 minutes from grant to usable.
#
# Contrast with the two neighbours:
#   scripts/flex-spray.sh              - FLEX_START, queues 2h, grants 7d runtime
#   scripts/spot-obtainability-poll.sh - RANKS zones by Capacity Advisor score.
#                                        It does not provision anything.
# Neither one provisions Spot. This does.
#
# Standalone. This does not touch the Slurm cluster: it creates ordinary GCE
# VMs, not reservations or nodesets.
#
# Usage:  PROJECT_ID=my-proj MACHINE_TYPE=a3-ultragpu-8g ACCEL=nvidia-h200-141gb \
#           bash scripts/spot-spray.sh
#         ROUNDS=30 SLEEP=20 bash scripts/spot-spray.sh
set -uo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
MACHINE_TYPE="${MACHINE_TYPE:-a4-highgpu-8g}"
ACCEL="${ACCEL:-nvidia-b200}"
ROUNDS="${ROUNDS:-30}"
SLEEP="${SLEEP:-20}"
PREFIX="${PREFIX:-spotspray}"
LOG="${LOG:-/tmp/spot-spray.log}"
# Overridable so the same script can land a *benchmark* box, not just prove
# obtainability. A bare ubuntu-2204-lts image has no CUDA driver, and
# --no-address needs NAT in the region; neither suits a box you want to SSH to
# and run a framework on within the hour.
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2204-lts}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
NET_FLAG="${NET_FLAG:---no-address}"
BOOT_GB="${BOOT_GB:-100}"
: > "$LOG"

echo ">>> project=$PROJECT_ID  machine=$MACHINE_TYPE  accel=$ACCEL"

# Zones that carry the accelerator AND have a subnet in this project. Both
# checks matter: europe-north1-b lists B200 but had no subnet, which reads as a
# capacity failure if you only look at the exit code.
mapfile -t ACCEL_ZONES < <(gcloud compute accelerator-types list --project="$PROJECT_ID" \
  --filter="name~${ACCEL}" --format="value(zone)" 2>/dev/null | sort -u)
mapfile -t SUBNET_REGIONS < <(gcloud compute networks subnets list --project="$PROJECT_ID" \
  --format="value(region)" 2>/dev/null | sort -u)

ZONES=()
for z in "${ACCEL_ZONES[@]}"; do
  r="${z%-*}"
  for sr in "${SUBNET_REGIONS[@]}"; do
    [[ "$r" == "$sr" ]] && { ZONES+=("$z"); break; }
  done
done

if [[ ${#ZONES[@]} -eq 0 ]]; then
  echo "ERROR: no zone has both $ACCEL and a subnet in $PROJECT_ID" >&2; exit 1
fi
echo ">>> ${#ZONES[@]} candidate zones: ${ZONES[*]}"
echo

for round in $(seq 1 "$ROUNDS"); do
  echo "[$(date -u +%H:%M:%SZ)] round $round/$ROUNDS" | tee -a "$LOG"
  for z in "${ZONES[@]}"; do
    r="${z%-*}"
    name="${PREFIX}-${z//-/}"
    if gcloud compute instances create "$name" \
        --project="$PROJECT_ID" --zone="$z" --machine-type="$MACHINE_TYPE" \
        --provisioning-model=SPOT --instance-termination-action=DELETE \
        --image-family="$IMAGE_FAMILY" --image-project="$IMAGE_PROJECT" \
        --boot-disk-size="${BOOT_GB}GB" --boot-disk-type=hyperdisk-balanced \
        --subnet="projects/${PROJECT_ID}/regions/${r}/subnetworks/default" \
        $NET_FLAG --maintenance-policy=TERMINATE >/dev/null 2>&1; then
      echo "*** GRANTED  $z  round $round  $(date -u +%H:%M:%SZ)  name=$name" | tee -a "$LOG"
      echo ">>> waiting for RUNNING (A4 takes about 8 minutes to boot)"
      for _ in $(seq 1 40); do
        s=$(gcloud compute instances describe "$name" --zone="$z" --project="$PROJECT_ID" \
              --format="value(status)" 2>/dev/null)
        echo "    [$(date -u +%H:%M:%SZ)] $s"
        [[ "$s" == "RUNNING" ]] && break
        [[ -z "$s" ]] && { echo "    instance vanished (preempted during boot)"; break; }
        sleep 20
      done
      echo
      echo "Delete when done:"
      echo "  gcloud compute instances delete $name --zone=$z --project=$PROJECT_ID --quiet"
      exit 0
    fi
  done
  sleep "$SLEEP"
done

echo "NO GRANT after $ROUNDS rounds across ${#ZONES[@]} zones" | tee -a "$LOG"
exit 1
