#!/bin/bash
# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0
#
# TinyLlama inference container entrypoint — checkpoint-resume aware.
#
# Required env from sbatch:
#   OUT_DIR  — per-job dir on /lustre, e.g. /lustre/inference/$SLURM_JOB_ID

set -euo pipefail

OUT_DIR="${OUT_DIR:?must be set, e.g. /lustre/inference/\$SLURM_JOB_ID}"
mkdir -p "${OUT_DIR}"

# Writable HOME/cache; container root is read-only, /tmp is bind-mounted.
export HOME=/tmp
export HF_HOME=/tmp/hf
export TRANSFORMERS_CACHE=/tmp/hf
export TRANSFORMERS_OFFLINE=1     # belt-and-suspenders: do not touch network

exec python3 -u /opt/inference.py
