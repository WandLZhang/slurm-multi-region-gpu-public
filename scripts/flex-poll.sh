#!/bin/bash
# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0

# scripts/flex-poll.sh
#
# DRY RUN: discover whether a fresh DWS Flex-Start request would be reasonable
# in each (sku, zone) pair, given the current per-project Flex queue state.
# Prints whether each pair is eligible or skipped (already pending).
#
# Set FLEX_SUBMIT=1 to actually submit a Flex-Start request per eligible pair.
# Default off — most days the cluster pivots to Spot when Flex isn't there,
# which is the architecture's intended failover path.
#
# Submit conservatively: never more than ONE in-flight request per (sku, zone).
#
# Usage (cron):  5 6 * * *  /opt/wz-slurm/scripts/flex-poll.sh >> /var/log/flex-poll.log 2>&1

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
FLEX_SUBMIT="${FLEX_SUBMIT:-0}"
MAX_RUN_SECS="${MAX_RUN_SECS:-604800}"   # 7 days, the Flex-Start max

# (sku, zone, vm_count) tuples. Per-SKU vm_count override needed because
# a4x-highgpu-4g (GB200 NVL72) is rack-scale (multiple of 16 VMs).
TARGETS=(
  "a3-ultragpu-8g:us-south1-b:1"      # H200
  "a3-ultragpu-8g:us-central1-b:1"
  "a3-ultragpu-8g:us-east4-b:1"
  "a3-ultragpu-8g:us-west1-c:1"
  "a3-megagpu-8g:us-central1-c:1"     # H100 Mega
  "a3-highgpu-8g:us-central1-a:1"     # H100
  "a4-highgpu-8g:us-east1-b:1"        # B200
  "a4x-highgpu-4g:us-central1-a:16"   # GB200 NVL72 rack
)

echo "=== Flex-Start poll @ $(date -u +%FT%TZ) ==="
echo "    project=$PROJECT_ID  submit=$FLEX_SUBMIT"

for target in "${TARGETS[@]}"; do
  IFS=: read -r sku zone vm_count <<<"$target"

  PENDING=$(gcloud compute reservations list \
    --project="$PROJECT_ID" \
    --filter="zone~$zone AND status=PROVISIONING AND machineType~$sku" \
    --format='value(name)' 2>/dev/null | head -1)

  if [[ -n "$PENDING" ]]; then
    echo "SKIP     $sku  $zone  (pending: $PENDING)"
    continue
  fi

  echo "ELIGIBLE $sku  $zone  ${vm_count}VMs (no in-flight Flex request)"

  if [[ "$FLEX_SUBMIT" == "1" ]]; then
    RES_NAME="odu-flex-$(echo "$sku" | tr -d -)-${zone}-$(date +%s)"
    gcloud compute reservations create "$RES_NAME" \
      --project="$PROJECT_ID" \
      --zone="$zone" \
      --vm-count="$vm_count" \
      --machine-type="$sku" \
      --provisioning-model=FLEX_START \
      --max-run-duration="${MAX_RUN_SECS}s" 2>&1 | sed 's/^/    /'
  fi
done

echo "=== Done ==="
