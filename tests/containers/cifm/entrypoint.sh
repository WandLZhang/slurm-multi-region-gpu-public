#!/bin/bash
# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0

# CIFM container entrypoint — bridges upstream gpu_run.py's hardcoded
# ~/cifm/VirtualTissue-CIFM/* layout to data on /lustre and per-job checkpoints.
#
# Required env from sbatch:
#   RESULTS_MP_DIR  — per-job dir for checkpoint_step{N}.npy (e.g.
#                     /lustre/checkpoints/$SLURM_JOB_ID)
# Optional:
#   STEPS, BS       — passed through as gpu_run.py env
#   LUSTRE_CIFM     — override /lustre/cifm path

set -euo pipefail

LUSTRE_CIFM="${LUSTRE_CIFM:-/lustre/cifm}"
RESULTS_MP_DIR="${RESULTS_MP_DIR:?must be set, e.g. /lustre/checkpoints/\$SLURM_JOB_ID}"

# Pyxis mounts container root read-only by default. SBATCH bind-mounts a
# writable host dir (e.g. /tmp/cifm-workspace) into a known path; HOME defaults
# to that path so the upstream gpu_run.py finds its expected ~/cifm/* tree.
export HOME="${HOME:-/tmp/cifm-workspace}"
mkdir -p "${HOME}/cifm/VirtualTissue-CIFM/virtualtissue_cifm/model_checkpoints"
ln -sfn "${LUSTRE_CIFM}/model_checkpoints/CIFM-ModelV2#1B-DataV2#33M" \
        "${HOME}/cifm/VirtualTissue-CIFM/virtualtissue_cifm/model_checkpoints/CIFM-ModelV2#1B-DataV2#33M"
ln -sfn "${LUSTRE_CIFM}/data/adata.h5ad"          "${HOME}/cifm/VirtualTissue-CIFM/adata.h5ad"
ln -sfn /opt/cifm/Youtils-ML4CellBio              "${HOME}/cifm/VirtualTissue-CIFM/Youtils-ML4CellBio"
mkdir -p "${HOME}/cifm/results"
ln -sfn "${LUSTRE_CIFM}/data/threshold_per_channel.npy" "${HOME}/cifm/results/threshold_per_channel.npy"
mkdir -p "${RESULTS_MP_DIR}"
ln -sfn "${RESULTS_MP_DIR}" "${HOME}/cifm/results_mp"

cd "${HOME}/cifm/VirtualTissue-CIFM"
exec python3 -u /opt/cifm/cloud-deployment/gpu_run.py "$@"
