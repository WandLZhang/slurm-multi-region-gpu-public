#!/bin/bash
# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0

# scripts/spot-obtainability-poll.sh
#
# DRY RUN: poll the Capacity Advisor for Spot API (Compute beta) for each Spot
# nodeset and propose updated Slurm `node_conf.Weight` values driven by LIVE
# obtainability instead of the static share-of-pool numbers in
# docs/capacity_strategy.md.
#
# Why this exists: share-of-pool ranks zones by how much capacity *exists*, not
# by whether you can *get* it. Field-validated (real BulkInsert): zones the API
# scored 0.9 provisioned in full; zones it scored 0.1/60s stocked out — even
# when a raw free-capacity count looked plentiful. So the
# right Slurm priority signal is the API's obtainability, not a static table.
#
# SKU PREFERENCE IS PRESERVED. Researchers select GPU class with
# `--constraint=h200|h100mega|h100`; the partition's default ordering still puts
# H200 (W1-4) above H100 Mega (W5-7) above H100 vanilla (W8-11). This script
# only re-orders zones *within* each SKU tier by live obtainability. It never
# promotes a lower GPU class above a higher one.
#
# Output: a proposed weight per nodeset and (if CLUSTER_YAML is set) a unified
# diff against blueprints/cluster.yaml. Nothing is written unless APPLY=1.
#
# After APPLY=1 patches cluster.yaml you must redeploy for it to take effect
# (`gcluster deploy ...`). For a *running* cluster you can instead push weights
# live on the controller without a redeploy:
#     scontrol update nodename=<nodeset-prefix>-[0-N] weight=<W>   # per nodeset
# (node Weight is runtime-mutable; this is the cron-friendly path.)
#
# Usage (dry run):   PROJECT_ID=my-proj CLUSTER_YAML=blueprints/cluster.yaml ./scripts/spot-obtainability-poll.sh
# Usage (apply):     PROJECT_ID=my-proj CLUSTER_YAML=blueprints/cluster.yaml APPLY=1 ./scripts/spot-obtainability-poll.sh
# Usage (cron):      0 6 * * *  PROJECT_ID=my-proj ./scripts/spot-obtainability-poll.sh >> /var/log/obtain-poll.log 2>&1

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
CLUSTER_YAML="${CLUSTER_YAML:-}"     # path to blueprints/cluster.yaml to diff/patch
APPLY="${APPLY:-0}"                  # 1 = write weights back into CLUSTER_YAML
SIZE="${SIZE:-1}"                    # VMs/nodeset to score (match node_count_dynamic_max)
TOKEN="$(gcloud auth print-access-token)"
API="https://compute.googleapis.com/compute/beta/projects/${PROJECT_ID}/regions"

# Nodesets, in SKU-tier order. Keep in sync with blueprints/cluster.yaml ids.
#   id | machine_type | region | zone[,zone...] | tier
# tier 1 = H200 (weights 1-4), 2 = H100 Mega (5-7), 3 = H100 vanilla (8-11)
NODESETS=(
  "h200_spot_southb|a3-ultragpu-8g|us-south1|us-south1-b|1"
  "h200_spot_west1c|a3-ultragpu-8g|us-west1|us-west1-c|1"
  "h200_spot_central1b|a3-ultragpu-8g|us-central1|us-central1-b|1"
  "h200_spot_east4b|a3-ultragpu-8g|us-east4|us-east4-b|1"
  "h100mega_spot_central|a3-megagpu-8g|us-central1|us-central1-c,us-central1-a,us-central1-b|2"
  "h100mega_spot_west1|a3-megagpu-8g|us-west1|us-west1-a,us-west1-b|2"
  "h100mega_spot_east4|a3-megagpu-8g|us-east4|us-east4-a,us-east4-b|2"
  "h100_spot_east4|a3-highgpu-8g|us-east4|us-east4-a,us-east4-b|3"
  "h100_spot_west1|a3-highgpu-8g|us-west1|us-west1-a,us-west1-b|3"
  "h100_spot_east5|a3-highgpu-8g|us-east5|us-east5-a|3"
  "h100_spot_central|a3-highgpu-8g|us-central1|us-central1-a,us-central1-b,us-central1-c|3"
)
# First weight assigned to each tier (tier sizes: 4 / 3 / 4).
declare -A TIER_BASE=( [1]=1 [2]=5 [3]=8 )

# advice() region zonesCSV machineType -> "obtainability uptimeSeconds landedZone"
# On any error returns "0 0 -" so the nodeset sinks to the bottom of its tier.
advice() {
  local region="$1" zones="$2" mt="$3"
  local zjson
  zjson=$(echo "$zones" | tr ',' '\n' | sed 's#^#{"zone":"zones/#; s#$#"}#' | paste -sd, -)
  local body
  body=$(printf '{"instanceProperties":{"scheduling":{"provisioningModel":"SPOT"}},"instanceFlexibilityPolicy":{"instanceSelections":{"s":{"machineTypes":["%s"]}}},"distributionPolicy":{"zones":[%s],"targetShape":"ANY_SINGLE_ZONE"},"size":%s}' "$mt" "$zjson" "$SIZE")
  local resp
  resp=$(curl -s -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
            "${API}/${region}/advice/capacity" -d "$body" 2>/dev/null) || { echo "0 0 -"; return; }
  local ob up zone
  ob=$(echo "$resp"   | jq -r '.recommendations[0].scores.obtainability // 0')
  up=$(echo "$resp"   | jq -r '(.recommendations[0].scores.estimatedUptime // "0s") | sub("s$";"")')
  zone=$(echo "$resp" | jq -r '.recommendations[0].shards[0].zone // "-" | split("/") | last')
  [[ -z "$ob" || "$ob" == "null" ]] && ob=0
  [[ -z "$up" || "$up" == "null" ]] && up=0
  echo "$ob $up $zone"
}

echo "=== Spot obtainability poll @ $(date -u +%FT%TZ) ==="
echo "    project=$PROJECT_ID  size=$SIZE  apply=$APPLY  cluster_yaml=${CLUSTER_YAML:-<none>}"
echo ""

# Collect: lines "tier|sortkey|id|ob|up|zone". sortkey = obtainability*100000+uptime.
ROWS=()
for ns in "${NODESETS[@]}"; do
  IFS='|' read -r id mt region zones tier <<<"$ns"
  read -r ob up zone < <(advice "$region" "$zones" "$mt")
  sortkey=$(awk -v o="$ob" -v u="$up" 'BEGIN{printf "%d", (o*100000)+u}')
  ROWS+=("${tier}|${sortkey}|${id}|${ob}|${up}|${zone}")
done

# Rank within each tier by sortkey desc, assign sequential weights from TIER_BASE.
MAP="$(mktemp)"; trap 'rm -f "$MAP"' EXIT
printf "%-24s %-14s %8s %9s %16s %s\n" "nodeset" "machineType" "obtain" "uptime" "land_zone" "weight"
printf -- "----------------------------------------------------------------------------------------\n"
for tier in 1 2 3; do
  w=${TIER_BASE[$tier]}
  while IFS='|' read -r t sortkey id ob up zone; do
    [[ "$t" == "$tier" ]] || continue
    # recover machine_type for display
    mt=$(printf '%s\n' "${NODESETS[@]}" | awk -F'|' -v i="$id" '$1==i{print $2}')
    printf "%-24s %-14s %8s %8ss %16s %d\n" "$id" "$mt" "$ob" "$up" "$zone" "$w"
    echo "${id}=${w}" >> "$MAP"
    w=$((w+1))
    # -s (stable): equal obtainability keeps current cluster.yaml order, so a
    # tier with no real signal (e.g. all 0.1/60s) is not churned pointlessly.
  done < <(printf '%s\n' "${ROWS[@]}" | sort -s -t'|' -k1,1n -k2,2rn)
done

# If a cluster.yaml was given, show the diff (and apply when APPLY=1).
if [[ -n "$CLUSTER_YAML" ]]; then
  if [[ ! -f "$CLUSTER_YAML" ]]; then echo "ERROR: CLUSTER_YAML not found: $CLUSTER_YAML" >&2; exit 1; fi
  PATCHED="$(mktemp)"
  # Block-aware Weight rewrite: track the current module id, replace only the
  # Weight: line inside a known nodeset's node_conf. Preserves all comments/format.
  awk -v mapfile="$MAP" '
    BEGIN { while ((getline l < mapfile) > 0) { n=split(l,a,"="); w[a[1]]=a[2] } }
    /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ { cur=$0
      sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/,"",cur); sub(/[[:space:]].*$/,"",cur) }
    /^[[:space:]]+Weight:[[:space:]]*[0-9]+/ && (cur in w) {
      sub(/Weight:[[:space:]]*[0-9]+/, "Weight: " w[cur]); print; next }
    { print }
  ' "$CLUSTER_YAML" > "$PATCHED"

  echo ""
  if diff -u "$CLUSTER_YAML" "$PATCHED" > /tmp/_obtain_diff 2>/dev/null; then
    echo "cluster.yaml weights already match live obtainability — no change."
  else
    echo "=== proposed cluster.yaml weight changes ==="
    sed 's/^/    /' /tmp/_obtain_diff
    if [[ "$APPLY" == "1" ]]; then
      cp "$PATCHED" "$CLUSTER_YAML"
      echo ">>> APPLIED to $CLUSTER_YAML. Redeploy (gcluster deploy) or push live via scontrol update."
    else
      echo ">>> DRY RUN. Re-run with APPLY=1 to write these weights."
    fi
  fi
  rm -f "$PATCHED" /tmp/_obtain_diff
fi

echo ""
echo "=== Done ==="
