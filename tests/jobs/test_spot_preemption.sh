#!/bin/bash
# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0

#SBATCH --job-name=preempt-demo
#SBATCH --partition=gpu
#SBATCH --gres=gpu:8
#SBATCH --time=12:00:00
#SBATCH --requeue
#SBATCH --output=/gcs/runs/preempt-%j.out
#SBATCH --error=/gcs/runs/preempt-%j.err

set -euo pipefail
echo "=== boot $(date -u +%FT%TZ) on $(hostname) in $(curl -s -H 'Metadata-Flavor: Google' http://metadata/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}') ==="
echo "SLURM restart count: ${SLURM_RESTART_COUNT:-0}"
nvidia-smi -L
echo
echo "=== mounts ==="
mount | grep -E "lustre|nfs|gcsfuse" || true
echo
echo "=== ensure torch + numpy ==="
python3 -c "import torch, numpy; print(f'torch={torch.__version__} numpy={numpy.__version__} cuda={torch.cuda.is_available()}')" || \
  pip install --quiet --user numpy 'torch==2.5.1+cu124' --index-url https://download.pytorch.org/whl/cu124 2>&1 | tail -3
echo
mkdir -p /lustre/checkpoints/${SLURM_JOB_ID}
python3 /home/$USER/tests/scripts/test_long_inference.py \
  --checkpoint-dir /lustre/checkpoints/${SLURM_JOB_ID} \
  --steps 60 --seconds-per-step 60
echo
echo "=== checkpoint listing on /lustre ==="
ls -lh /lustre/checkpoints/${SLURM_JOB_ID}/
