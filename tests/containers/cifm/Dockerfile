# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0

# CIFM 1B inference container — example workload for the wz-slurm cluster.
#
# Build + push (one-time per stack version, admin runs from the controller).
# Cloud Build first pulls the workload tarball from gs://cifm-staging, then
# this Dockerfile docker-builds against it:
#   cd /home/$USER/tests/containers/cifm/
#   gcloud builds submit --config=cloudbuild.yaml .
#
# Researcher SBATCH uses it via:
#   srun --container-image=us-docker.pkg.dev/$PROJECT_ID/workloads/cifm:v1 \
#        --container-mounts=/lustre,/gcs,/tmp \
#        --export=ALL,STEPS=1000,BS=64,RESULTS_MP_DIR=/lustre/checkpoints/$SLURM_JOB_ID
#
# Image is ~6 GB compressed in multi-region US Artifact Registry. First pull
# per node ~25-50 sec from nearest Artifact Registry mirror; Enroot caches to
# /mnt/localssd thereafter (instant on subsequent jobs).

FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# Vanilla pytorch image ships exactly torch 2.5.1+cu124 — ABI-matched against
# PyG's prebuilt torch-2.5.1+cu124 wheels. nvcr.io/nvidia/pytorch:24.10-py3
# bumps to a torch 2.5.0a0+nv24.10 nightly that mismatches PyG's wheel symbol
# expectations and crashes at import time.
RUN pip install --no-cache-dir \
      torch-scatter torch-cluster torch-sparse \
      -f https://data.pyg.org/whl/torch-2.5.1+cu124.html

RUN pip install --no-cache-dir \
      scanpy \
      anndata \
      e3nn \
      lightning \
      torch-geometric \
      lmdb \
      gdown \
      tqdm

# CIFM workload code — Cloud Build's fetch step pulls the canonical tarball
# from gs://cifm-staging into /workspace/cifm-code.tgz; Docker ADD auto-extracts
# .tar.gz when the source is a local file. See cloudbuild.yaml.
ADD cifm-code.tgz /opt/
RUN mv /opt/caltech-ci-fm-gpu* /opt/cifm
ENV PYTHONPATH=/opt/cifm:/opt/cifm/VirtualTissue-CIFM:/opt/cifm/Youtils-ML4CellBio

# Entrypoint bridges upstream gpu_run.py's hardcoded ~/cifm/* layout to data
# on /lustre and the per-job checkpoints dir.
COPY entrypoint.sh /usr/local/bin/cifm-entrypoint
RUN chmod 0755 /usr/local/bin/cifm-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/cifm-entrypoint"]
