#!/bin/bash
# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
#
# GCS-target variant of inference.sh — same workload, checkpoints land on
# /gcs/inference/$JOB instead of /lustre/inference/$JOB. Used by the
# benchmark in docs/storage_comparison.md to compare per-prompt write
# latency and cross-region cold-read latency between the two tiers.

#SBATCH --job-name=inference-gcs
#SBATCH --partition=gpu
#SBATCH --constraint=h200
#SBATCH --gres=gpu:8
#SBATCH --time=UNLIMITED
#SBATCH --requeue
#SBATCH --output=/gcs/runs/inference-gcs-%j.out
#SBATCH --error=/gcs/runs/inference-gcs-%j.err

set -uo pipefail

# PROJECT_ID resolution on the compute VM (no `gcloud config` there); metadata
# server is always available on GCE.
PROJECT_ID="${PROJECT_ID:-$(curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata/computeMetadata/v1/project/project-id 2>/dev/null \
  || gcloud config get-value project 2>/dev/null)}"
[ -n "$PROJECT_ID" ] || { echo "FATAL: PROJECT_ID could not be resolved" >&2; exit 1; }

IMAGE="${IMAGE:-docker://us-docker.pkg.dev#${PROJECT_ID}/workloads/inference:v2}"
OUT_DIR="/gcs/inference/${SLURM_JOB_ID}"

echo "=== boot $(date -u +%FT%TZ) on $(hostname) ==="
echo "  zone: $(curl -s -H 'Metadata-Flavor: Google' http://metadata/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')"
echo "  SLURM_RESTART_COUNT=${SLURM_RESTART_COUNT:-0}  SLURM_JOB_ID=${SLURM_JOB_ID}"
echo "  IMAGE=${IMAGE}"
echo "  OUT_DIR=${OUT_DIR}  (gcs tier)"
nvidia-smi -L | head -10

mkdir -p "${OUT_DIR}" /gcs/runs

mkdir -p ~/.config/enroot
TOKEN=$(curl -sS -H 'Metadata-Flavor: Google' \
  http://metadata/computeMetadata/v1/instance/service-accounts/default/token \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
cat > ~/.config/enroot/.credentials <<EOF
machine us-docker.pkg.dev login oauth2accesstoken password ${TOKEN}
EOF
chmod 600 ~/.config/enroot/.credentials

srun \
  --container-image="${IMAGE}" \
  --container-mounts=/lustre,/gcs,/tmp \
  --export=ALL,OUT_DIR="${OUT_DIR}" \
  /usr/local/bin/inference-entrypoint
EXIT=$?

echo "=== exit=$EXIT, /gcs checkpoint state ==="
ls -lh "${OUT_DIR}/" 2>&1 | head
exit $EXIT
