#!/bin/bash
# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0

# End-to-end validation: prove that the wz-slurm reference deployment can
# run a Slurm job on an H200 (Spot or Flex), with the three-layer storage
# model in place — /home (Filestore, user code), /lustre (Managed Lustre,
# parallel-POSIX read-only inputs + write-heavy checkpoints), /gcs (GCS-FUSE,
# durable archive for sbatch stdout + long-term sharing).
#
# Submit from the login node:
#   sbatch /home/$USER/tests/jobs/test_h200_e2e.sh

#SBATCH --job-name=h200-e2e
#SBATCH --partition=gpu
#SBATCH --gres=gpu:8
#SBATCH --time=00:30:00
#SBATCH --requeue
#SBATCH --output=/gcs/runs/test-%j.out
#SBATCH --error=/gcs/runs/test-%j.err

set -euo pipefail

echo "============================================================"
echo " wz-slurm end-to-end validation"
echo " Job: ${SLURM_JOB_ID}  Node: $(hostname)"
echo " Zone: $(curl -s -H 'Metadata-Flavor: Google' http://metadata/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')"
echo " Date: $(date -u +%FT%TZ)"
echo "============================================================"

mkdir -p /gcs/runs/${SLURM_JOB_ID}

echo
echo "--- nvidia-smi ---"
nvidia-smi

echo
echo "--- Storage mounts ---"
mount | grep -E "lustre|nfs|gcsfuse" || true

echo
echo "--- Read sanity check on /lustre/weights (parallel-POSIX read-only inputs) ---"
ls -lh /lustre/weights/data/args.pt /lustre/weights/data/channel2ensembl.pt 2>&1 || echo "WARN: /lustre/weights not readable"

echo
echo "--- Run PyTorch H200 detection script ---"
python3 /home/${USER}/tests/scripts/test_h200_inference.py \
  --output /gcs/runs/${SLURM_JOB_ID}/

echo
echo "--- Write sanity check on /gcs (read-write) ---"
ls -lh /gcs/runs/${SLURM_JOB_ID}/

echo
echo "============================================================"
echo " SUCCESS: end-to-end validation complete."
echo "============================================================"
