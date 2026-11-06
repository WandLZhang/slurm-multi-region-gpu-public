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
# DURATION_MIN and DURATION_MAX set the block lengths to look for. The default,
# 7d to 30d, finds blocks longer than one 7-day Flex-start run. Calendar blocks
# can be as short as 1 day, so set DURATION_MIN=1d to see the shorter ones.
# WINDOW_DAYS sets how far ahead to look for a start (default 60). Over a long
# window the advice API can skip short blocks, so shorten it along with
# DURATION_MIN, for example WINDOW_DAYS=21.
#
# Usage (cron):  0 6 * * *  /opt/wz-slurm/scripts/calendar-poll.sh >> /var/log/calendar-poll.log 2>&1

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
CALENDAR_AUTOBOOK="${CALENDAR_AUTOBOOK:-0}"
DURATION_MIN="${DURATION_MIN:-7d}"
DURATION_MAX="${DURATION_MAX:-30d}"
WINDOW_DAYS="${WINDOW_DAYS:-60}"

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
# A GPU Calendar request must start at least 87 hours after it's submitted,
# so search for start times from 88 hours out.
WINDOW_FROM=$(date -u -v+88H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+88 hours' +%Y-%m-%dT%H:%M:%SZ)
WINDOW_TO=$(date -u -v+"${WINDOW_DAYS}"d +%Y-%m-%d 2>/dev/null || date -u -d "+${WINDOW_DAYS} day" +%Y-%m-%d)

# Cross-platform epoch parser: GNU date uses -d, BSD/macOS uses -j -f
to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%S" "${1%.*}" +%s 2>/dev/null || echo 0
}

echo "=== Calendar Mode poll @ $(date -u +%FT%TZ) ==="
echo "    project=$PROJECT_ID  window=$WINDOW_FROM..$WINDOW_TO  duration=$DURATION_MIN..$DURATION_MAX  autobook=$CALENDAR_AUTOBOOK"

for sku_spec in "${SKUS[@]}"; do
  sku="${sku_spec%%:*}"
  vm_count="${sku_spec##*:}"
  for region in "${REGIONS[@]}"; do
    OUT=$(gcloud compute advice calendar-mode \
      --project="$PROJECT_ID" \
      --machine-type="$sku" \
      --vm-count="$vm_count" \
      --region="$region" \
      --duration-range="min=$DURATION_MIN,max=$DURATION_MAX" \
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
      RES_NAME="cal-$(echo "$sku" | tr -d -)-$(date +%s)"
      # Flags from the Calendar mode docs. future-reservations create counts
      # VMs with --total-count; --vm-count only exists on the advice command.
      gcloud compute future-reservations create "$RES_NAME" \
        --project="$PROJECT_ID" \
        --zone="$ZONE" \
        --machine-type="$sku" \
        --total-count="$vm_count" \
        --start-time="$START" \
        --end-time="$END" \
        --reservation-mode=CALENDAR \
        --deployment-type=DENSE \
        --planning-status=SUBMITTED \
        --require-specific-reservation \
        --reservation-name="$RES_NAME" \
        --share-setting=local \
        --auto-delete-auto-created-reservations 2>&1 | sed 's/^/    /'
    fi
  done
done

echo "=== Done ==="
