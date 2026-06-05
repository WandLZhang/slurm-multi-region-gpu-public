#!/bin/bash
# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0
#
# nanoGPT container entrypoint — trains Karpathy's nanoGPT (char-level
# tinyshakespeare, baked into the image at build time) across all visible GPUs
# via torchrun DDP, checkpointing to a per-job dir on /lustre and resuming from
# it after a Spot preempt + --requeue.

set -euo pipefail

OUT_DIR="${OUT_DIR:?must be set, e.g. /lustre/checkpoints/\$SLURM_JOB_ID}"
mkdir -p "${OUT_DIR}"

# torch/torchrun want a writable HOME + cache; container root is read-only.
export HOME=/tmp
export TORCHINDUCTOR_CACHE_DIR=/tmp/torchinductor
export TRITON_CACHE_DIR=/tmp/triton

NGPU="$(nvidia-smi -L 2>/dev/null | wc -l)"
[ "${NGPU:-0}" -ge 1 ] || NGPU=1

# nanoGPT asserts gradient_accumulation_steps % ddp_world_size == 0 and then
# divides it by the world size. The shakespeare_char config ships
# gradient_accumulation_steps=1, which fails on any multi-GPU node. Set it to
# the GPU count (1 accum step per GPU) so DDP works for any nproc_per_node.
GRAD_ACCUM="${GRAD_ACCUM:-$NGPU}"

# Resume iff a checkpoint already exists in THIS job's out_dir — i.e. this is a
# Spot preempt + --requeue of the same JobId (out_dir persists on /lustre across
# the requeue). nanoGPT's init_from=resume reloads ckpt.pt (model + optimizer +
# iter_num) and continues. A fresh job starts from scratch.
if [ -f "${OUT_DIR}/ckpt.pt" ]; then
  INIT_FROM=resume
  echo "=== RESUME from ${OUT_DIR}/ckpt.pt (SLURM_RESTART_COUNT=${SLURM_RESTART_COUNT:-0}) ==="
else
  INIT_FROM=scratch
  echo "=== FRESH run → ${OUT_DIR} ==="
fi

cd /opt/nanogpt
echo "=== nanoGPT char-shakespeare on ${NGPU} GPU(s), init_from=${INIT_FROM}, grad_accum=${GRAD_ACCUM} ==="

# always_save_checkpoint=True → write ckpt.pt every eval_interval (not only on
# val-loss improvement) so the resume path has something to reload quickly.
# compile=False keeps the container robust (no triton/inductor build at start).
exec torchrun --standalone --nproc_per_node="${NGPU}" train.py \
  config/train_shakespeare_char.py \
  --out_dir="${OUT_DIR}" \
  --init_from="${INIT_FROM}" \
  --always_save_checkpoint=True \
  --compile=False \
  --gradient_accumulation_steps="${GRAD_ACCUM}" \
  --eval_interval="${EVAL_INTERVAL:-50}" \
  --eval_iters="${EVAL_ITERS:-20}" \
  --log_interval="${LOG_INTERVAL:-10}" \
  --max_iters="${MAX_ITERS:-5000}"
