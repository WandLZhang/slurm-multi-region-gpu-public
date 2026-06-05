#!/bin/bash
# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
#
# Example end-to-end inference SBATCH for the multi-region Slurm cluster —
# runs TinyLlama-1.1B-Chat batch generation over a vendored prompt set on H200,
# checkpointing progress to /lustre and resuming from progress.jsonl after
# Spot preempt + --requeue.
#
# Demonstrates the multi-region cluster doing INFERENCE with LUSTRE
# checkpointing (the alternative storage tier to /gcs — Managed Lustre is
# zonal in us-central1 but reachable cross-region over GLOBAL VPC routing):
#   - Cross-region Slurm Spot allocation, weight-ordered "down the ladder"
#   - Container-delivered code + weights from the project's own Artifact Registry
#   - Per-prompt progress.jsonl + results.jsonl on /lustre/inference/$JOB/
#   - Preempt + --requeue brings the SAME JobId up on the next-Weight free
#     nodeset; entrypoint reads progress.jsonl from /lustre (cross-region —
#     same default VPC GLOBAL routing) and resumes at next_index
#
# Submit from the login VM:
#   sbatch ~/tests/jobs/inference.sh

#SBATCH --job-name=inference
#SBATCH --partition=gpu
#SBATCH --constraint=h200
#SBATCH --gres=gpu:8
#SBATCH --time=UNLIMITED
#SBATCH --requeue
#SBATCH --output=/gcs/runs/inference-%j.out
#SBATCH --error=/gcs/runs/inference-%j.err

set -uo pipefail

# PROJECT_ID resolution must work on the COMPUTE VM (where this runs), not just
# the login VM. Compute VMs don't have a `gcloud config` set, so we read the
# project from the metadata server — always available on any GCE VM.
PROJECT_ID="${PROJECT_ID:-$(curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata/computeMetadata/v1/project/project-id 2>/dev/null \
  || gcloud config get-value project 2>/dev/null)}"
[ -n "$PROJECT_ID" ] || { echo "FATAL: PROJECT_ID could not be resolved" >&2; exit 1; }

# Enroot URI syntax for non-Docker-Hub registries: docker://REGISTRY#PATH:TAG
# (the `#` separates the registry hostname from the image path; using `/`
# instead causes Pyxis to query Docker Hub for the full path → 401).
IMAGE="${IMAGE:-docker://us-docker.pkg.dev#${PROJECT_ID}/workloads/inference:v2}"

# Checkpoint to /lustre — the Managed Lustre share, zonal in us-central1 but
# reachable from every burst region via GLOBAL VPC routing. /lustre is the
# right tier for tightly-coupled MPI and for batch jobs that want a single
# parallel POSIX surface; for multi-region burst checkpoint/resume see
# example.sh which uses /gcs (the multi-region bucket with locally-cacheable
# physical replicas in every burst region).
OUT_DIR="/lustre/inference/${SLURM_JOB_ID}"

echo "=== boot $(date -u +%FT%TZ) on $(hostname) ==="
echo "  zone: $(curl -s -H 'Metadata-Flavor: Google' http://metadata/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')"
echo "  SLURM_RESTART_COUNT=${SLURM_RESTART_COUNT:-0}  SLURM_JOB_ID=${SLURM_JOB_ID}"
echo "  IMAGE=${IMAGE}"
echo "  OUT_DIR=${OUT_DIR}"
nvidia-smi -L | head -10
mount | grep -E 'home|lustre|gcsfuse' | head

mkdir -p "${OUT_DIR}" /gcs/runs

echo
echo "=== auth Enroot to Artifact Registry via VM SA's metadata-server access token ==="
mkdir -p ~/.config/enroot
TOKEN=$(curl -sS -H 'Metadata-Flavor: Google' \
  http://metadata/computeMetadata/v1/instance/service-accounts/default/token \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
cat > ~/.config/enroot/.credentials <<EOF
machine us-docker.pkg.dev login oauth2accesstoken password ${TOKEN}
EOF
chmod 600 ~/.config/enroot/.credentials

echo
echo "=== launching TinyLlama inference container ==="
srun \
  --container-image="${IMAGE}" \
  --container-mounts=/lustre,/gcs,/tmp \
  --export=ALL,OUT_DIR="${OUT_DIR}" \
  /usr/local/bin/inference-entrypoint
EXIT=$?

echo
echo "=== exit=$EXIT, lustre checkpoint state ==="
ls -lh "${OUT_DIR}/" 2>&1 | head -10
[ -f "${OUT_DIR}/progress.jsonl" ] && echo "progress: $(cat ${OUT_DIR}/progress.jsonl)"
[ -f "${OUT_DIR}/results.jsonl" ] && echo "results lines: $(wc -l < ${OUT_DIR}/results.jsonl)"
exit $EXIT
