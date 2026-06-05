#!/bin/bash
# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0

# scripts/calendar-poll.sh
#
# DRY RUN: discover bookable Calendar Mode windows for H100/H100Mega/H200/B200
# across CONUS, print a one-line per opportunity so an admin can decide
# whether to claim it manually with `gcloud compute future-reservations create`.
#
# Set CALENDAR_AUTOBOOK=1 to actually create the Future Reservation when an
# opportunity is found. Default off so this script is safe to schedule daily
# without surprise commitments.
#
# Usage (cron):  0 6 * * *  /opt/wz-slurm/scripts/calendar-poll.sh >> /var/log/calendar-poll.log 2>&1

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
CALENDAR_AUTOBOOK="${CALENDAR_AUTOBOOK:-0}"

# Per-SKU minimum VM count.
# a4x-highgpu-4g (GB200 NVL72) is rack-scale: must be a multiple of 16 VMs.
# Everything else accepts vm_count=1 from the API.
SKUS=(
  "a3-ultragpu-8g:1"   # 8x H200 141GB
  "a3-megagpu-8g:1"    # 8x H100 80GB w/ NVLink
  "a3-highgpu-8g:1"    # 8x H100 80GB
  "a4-highgpu-8g:1"    # 8x B200 180GB
  "a4x-highgpu-4g:16"  # GB200 NVL72 — rack-scale (4 GPUs/VM × 16 VMs = 64 chips)
)
REGIONS=("us-central1" "us-south1" "us-east4" "us-east5" "us-west1")
WINDOW_FROM=$(date -u -v+1d +%Y-%m-%d 2>/dev/null || date -u -d '+1 day' +%Y-%m-%d)
WINDOW_TO=$(date -u -v+60d +%Y-%m-%d 2>/dev/null || date -u -d '+60 day' +%Y-%m-%d)

# Cross-platform epoch parser: GNU date uses -d, BSD/macOS uses -j -f
to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%S" "${1%.*}" +%s 2>/dev/null || echo 0
}

echo "=== Calendar Mode poll @ $(date -u +%FT%TZ) ==="
echo "    project=$PROJECT_ID  window=$WINDOW_FROM..$WINDOW_TO  autobook=$CALENDAR_AUTOBOOK"

for sku_spec in "${SKUS[@]}"; do
  sku="${sku_spec%%:*}"
  vm_count="${sku_spec##*:}"
  for region in "${REGIONS[@]}"; do
    OUT=$(gcloud compute advice calendar-mode \
      --project="$PROJECT_ID" \
      --machine-type="$sku" \
      --vm-count="$vm_count" \
      --region="$region" \
      --duration-range=min=7d,max=30d \
      --start-time-range="from=$WINDOW_FROM,to=$WINDOW_TO" \
      --format=json 2>/dev/null) || continue

    LOC=$(echo "$OUT" | jq -r '.[0].recommendations[0].recommendationsPerSpec.spec.location // empty')
    if [[ -z "$LOC" ]]; then
      continue   # nothing bookable for this sku/region
    fi

    START=$(echo "$OUT" | jq -r '.[0].recommendations[0].recommendationsPerSpec.spec.startTime')
    END=$(echo "$OUT"   | jq -r '.[0].recommendations[0].recommendationsPerSpec.spec.endTime')
    ZONE=$(basename "$LOC")
    DUR_DAYS=$(( ( $(to_epoch "$END") - $(to_epoch "$START") ) / 86400 ))

    echo "BOOKABLE  $sku  $ZONE  ${DUR_DAYS}d  $START → $END  ${vm_count}VMs"

    if [[ "$CALENDAR_AUTOBOOK" == "1" ]]; then
      RES_NAME="odu-cal-$(echo "$sku" | tr -d -)-$(date +%s)"
      gcloud compute future-reservations create "$RES_NAME" \
        --project="$PROJECT_ID" \
        --reservation-mode=CALENDAR \
        --zone="$ZONE" \
        --vm-count="$vm_count" \
        --machine-type="$sku" \
        --start-time="$START" \
        --end-time="$END" 2>&1 | sed 's/^/    /'
    fi
  done
done

echo "=== Done ==="
