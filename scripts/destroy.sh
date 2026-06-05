#!/bin/bash
# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0

# Tear down the wz-slurm reference deployment cleanly.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-wz-slurm}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> gcluster destroy ($DEPLOYMENT_NAME)"
cd "$REPO_ROOT/cluster-toolkit"
./gcluster destroy "$REPO_ROOT/$DEPLOYMENT_NAME" --auto-approve || {
  echo "WARN: gcluster destroy returned non-zero — continuing with manual sweep"
}

echo
echo "==> Manual sweep: GCE instances"
gcloud compute instances list --project="$PROJECT_ID" --format="table(name,zone,status)" 2>&1 | head -20

echo
echo "==> Manual sweep: persistent disks"
gcloud compute disks list --project="$PROJECT_ID" --format="table(name,zone,sizeGb,status)" 2>&1 | head -20

echo
echo "==> Manual sweep: GCS buckets"
gcloud storage buckets list --project="$PROJECT_ID" --format="value(name)" 2>&1 | head -20

echo
echo "==> Manual sweep: Filestore instances"
gcloud filestore instances list --project="$PROJECT_ID" --format="table(name,location,state)" 2>&1 | head -20

echo
echo "==> Manual sweep: VPC networks"
gcloud compute networks list --project="$PROJECT_ID" --format="table(name)" 2>&1 | head -20

echo
echo "==> Done. Verify all cluster resources are gone before re-deploying."
