#!/bin/bash
# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
#
# Example end-to-end SBATCH for the multi-region Slurm cluster — trains nanoGPT
# (char-level tinyshakespeare, baked into the container at build time) on H200
# 8-GPU through Pyxis + Enroot, checkpointing to /lustre and resuming from
# ckpt.pt after Spot preempt + --requeue.
#
# Demonstrates with zero external deps (no private bucket, no login):
#   - Cross-region Slurm Spot allocation, weight-ordered "down the ladder"
#     (W1 us-south1-b H200 → W2 us-west1-c → W3 us-central1-b → ...)
#   - Container-delivered code + data from the project's own Artifact Registry,
#     authed by the node's service-account metadata token
#   - Per-eval ckpt.pt write to /lustre/checkpoints/$SLURM_JOB_ID/ (parallel
#     POSIX, persists across the requeue regardless of which region the next
#     VM lands in)
#   - Preempt + --requeue brings the SAME JobId up on the next-Weight free
#     nodeset; entrypoint sees existing ckpt.pt and relaunches nanoGPT with
#     init_from=resume continuing from the saved iter_num. SLURM_RESTART_COUNT>0
#     confirms the path fired.
#
# Submit from the login VM:
#   sbatch ~/tests/jobs/example.sh
# Quick sanity check with a small iter cap:
#   sbatch --export=ALL,MAX_ITERS=300 ~/tests/jobs/example.sh

#SBATCH --job-name=nanogpt
#SBATCH --partition=gpu
#SBATCH --constraint=h200
#SBATCH --gres=gpu:8
#SBATCH --time=UNLIMITED
#SBATCH --requeue
#SBATCH --output=/gcs/runs/nanogpt-%j.out
#SBATCH --error=/gcs/runs/nanogpt-%j.err

set -uo pipefail

# PROJECT_ID resolution must work on the COMPUTE VM (where this runs), not just
# the login VM. Compute VMs don't have a `gcloud config` set, so we read the
# project from the metadata server — always available on any GCE VM with no
# setup required. The gcloud-config fallback is for off-cluster manual testing.
PROJECT_ID="${PROJECT_ID:-$(curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata/computeMetadata/v1/project/project-id 2>/dev/null \
  || gcloud config get-value project 2>/dev/null)}"
[ -n "$PROJECT_ID" ] || { echo "FATAL: PROJECT_ID could not be resolved" >&2; exit 1; }
# Enroot URI syntax for non-Docker-Hub registries: docker://REGISTRY#PATH:TAG
# (the `#` separates the registry hostname from the image path; using `/`
# instead causes Pyxis to query Docker Hub for the full path → 401).
IMAGE="${IMAGE:-docker://us-docker.pkg.dev#${PROJECT_ID}/workloads/nanogpt:v2}"
# Checkpoint to /gcs (multi-region US bucket with HNS, mounted via gcsfuse on
# every node) — the burst-compatible tier per docs/REFERENCE.md. When a Spot
# preempt lands the requeue on a different region, the new VM reads ckpt.pt
# from its closest physical replica of the multi-region bucket. /lustre is
# zonal in us-central1 and is the right tier for tightly-coupled MPI in-region,
# not for multi-region burst checkpoint/resume.
OUT_DIR="/gcs/checkpoints/${SLURM_JOB_ID}"

echo "=== boot $(date -u +%FT%TZ) on $(hostname) ==="
echo "  zone: $(curl -s -H 'Metadata-Flavor: Google' http://metadata/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')"
echo "  SLURM_RESTART_COUNT=${SLURM_RESTART_COUNT:-0}  SLURM_JOB_ID=${SLURM_JOB_ID}"
echo "  IMAGE=${IMAGE}"
nvidia-smi -L | head -10
mount | grep -E 'home|lustre|gcsfuse' | head

mkdir -p "${OUT_DIR}" /gcs/runs

echo
echo "=== auth Enroot to Artifact Registry via VM SA's metadata-server access token ==="
# Token TTL is 1 hour — plenty for the image import. Once Pyxis pulls + unpacks
# to /mnt/localssd, the container is cached locally and subsequent srun
# invocations on the same node skip the pull.
mkdir -p ~/.config/enroot
TOKEN=$(curl -sS -H 'Metadata-Flavor: Google' \
  http://metadata/computeMetadata/v1/instance/service-accounts/default/token \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
cat > ~/.config/enroot/.credentials <<EOF
machine us-docker.pkg.dev login oauth2accesstoken password ${TOKEN}
EOF
chmod 600 ~/.config/enroot/.credentials

echo
echo "=== launching nanoGPT container (Pyxis pulls + caches to /mnt/localssd on first run) ==="
srun \
  --container-image="${IMAGE}" \
  --container-mounts=/lustre,/gcs,/tmp \
  --export=ALL,OUT_DIR="${OUT_DIR}",MAX_ITERS="${MAX_ITERS:-5000}" \
  /usr/local/bin/nanogpt-entrypoint
EXIT=$?

echo
echo "=== exit=$EXIT, checkpoints on /lustre ==="
ls -lht "${OUT_DIR}/" 2>&1 | head -5
exit $EXIT
