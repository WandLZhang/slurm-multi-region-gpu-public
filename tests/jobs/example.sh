#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Example end-to-end SBATCH for the my-slurm cluster — runs CIFM 1B inference
# on H200 8-GPU through Pyxis + Enroot, with the workload's code/python deps
# pulled from an Artifact Registry-hosted container and large data inputs cached on /lustre.
#
# This is the canonical reference job. It demonstrates:
#   - Cross-region Slurm Spot allocation (controller us-central1-b → compute
#     wherever capacity sits today, typically us-south1-b H200)
#   - Container-delivered Python stack (no /lustre/python-deps small-file
#     import storm)
#   - Idempotent data lazy-pull from GCS to /lustre on first run
#   - Per-step checkpoint writes to /lustre (parallel POSIX, cross-region OK)
#   - Preempt + requeue resume from latest checkpoint (--requeue + workload's
#     resume logic in upstream gpu_run.py:200-209)
#
# STEPS=10000 + no --time wall makes this an open-ended job so Spot preempts
# get exercised naturally over a long horizon. The workload's resume logic
# (gpu_run.py:200-209) reads the highest existing checkpoint_step{N}.npy from
# /lustre/checkpoints/$JOB and resumes at step N+1 regardless of how many
# requeues have happened. Set STEPS=10 for a one-shot sanity check (~65 min).
#
# Submit from the login VM:
#   sbatch /home/$USER/tests/jobs/example.sh
#
# Pre-req (one-time per cluster, admin runs from controller):
#   cd tests/containers/cifm/
#   gcloud builds submit --tag us-docker.pkg.dev/$PROJECT_ID/workloads/cifm:v1 .

#SBATCH --job-name=example-h200
#SBATCH --partition=gpu
#SBATCH --constraint=h200
#SBATCH --gres=gpu:8
#SBATCH --time=UNLIMITED
#SBATCH --requeue
#SBATCH --output=/gcs/runs/example-%j.out
#SBATCH --error=/gcs/runs/example-%j.err

set -uo pipefail

PROJECT_ID="${PROJECT_ID:-my-slurm}"
# Enroot URI syntax for non-Docker-Hub registries: docker://REGISTRY#PATH:TAG
# (the `#` separates the registry hostname from the image path; using `/`
# instead causes Pyxis to query Docker Hub for the full path → 401).
IMAGE="${IMAGE:-docker://us-docker.pkg.dev#${PROJECT_ID}/workloads/cifm:v1}"
DATA_BUCKET="${DATA_BUCKET:-gs://cifm-staging/data}"

echo "=== boot $(date -u +%FT%TZ) on $(hostname) ==="
echo "  zone: $(curl -s -H 'Metadata-Flavor: Google' http://metadata/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')"
echo "  SLURM_RESTART_COUNT=${SLURM_RESTART_COUNT:-0}  SLURM_JOB_ID=${SLURM_JOB_ID}"
echo "  IMAGE=${IMAGE}"
nvidia-smi -L | head -10
mount | grep -E 'home|lustre|gcsfuse' | head

# Idempotent data stage to /lustre. First job on a fresh cluster pays the
# ~30 sec cross-region cost; every subsequent job (and every requeue) finds
# the files already there and skips. ~12 GB total.
mkdir -p /lustre/cifm/model_checkpoints/'CIFM-ModelV2#1B-DataV2#33M' \
         /lustre/cifm/data \
         /lustre/checkpoints/${SLURM_JOB_ID} \
         /gcs/runs

if [ ! -f /lustre/cifm/model_checkpoints/'CIFM-ModelV2#1B-DataV2#33M'/checkpoint.ckpt ]; then
  echo "=== first-job data stage from ${DATA_BUCKET} → /lustre/cifm/ ==="
  gcloud storage cp "${DATA_BUCKET}/checkpoint.ckpt" \
    /lustre/cifm/model_checkpoints/'CIFM-ModelV2#1B-DataV2#33M'/checkpoint.ckpt
  gcloud storage cp "${DATA_BUCKET}/args.pt" "${DATA_BUCKET}/channel2ensembl.pt" \
    /lustre/cifm/model_checkpoints/'CIFM-ModelV2#1B-DataV2#33M'/
  gcloud storage cp "${DATA_BUCKET}/adata.h5ad" /lustre/cifm/data/
  gcloud storage cp "${DATA_BUCKET}/threshold_gpu_fp32_zenodo1b_2026-04-21.npy" \
    /lustre/cifm/data/threshold_per_channel.npy
fi

echo
echo "=== auth Enroot to Artifact Registry via VM SA's metadata-server access token ==="
# Enroot's netrc-format credentials file. Token TTL is 1 hour — plenty for the
# image import. Once Pyxis pulls + unpacks to /mnt/localssd, the container is
# cached locally and subsequent srun invocations on the same node skip Artifact Registry.
mkdir -p ~/.config/enroot
TOKEN=$(curl -sS -H 'Metadata-Flavor: Google' \
  http://metadata/computeMetadata/v1/instance/service-accounts/default/token \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
cat > ~/.config/enroot/.credentials <<EOF
machine us-docker.pkg.dev login oauth2accesstoken password ${TOKEN}
EOF
chmod 600 ~/.config/enroot/.credentials

echo
echo "=== launching CIFM container (Pyxis pulls + caches to /mnt/localssd on first run) ==="
# Pyxis runs container root FS read-only — bridge gpu_run.py's hardcoded
# ~/cifm/* paths into a writable host dir at /tmp/cifm-workspace.
mkdir -p /tmp/cifm-workspace
LUSTRE_CIFM=/lustre/cifm
RESULTS_MP_DIR=/lustre/checkpoints/${SLURM_JOB_ID}
srun \
  --container-image="${IMAGE}" \
  --container-mounts=/lustre,/gcs,/tmp,${LUSTRE_CIFM}/model_checkpoints:/opt/cifm/VirtualTissue-CIFM/virtualtissue_cifm/model_checkpoints,${LUSTRE_CIFM}/data:/opt/cifm/VirtualTissue-CIFM/data,${RESULTS_MP_DIR}:/opt/cifm/results_mp \
  --export=ALL,STEPS=10000,BS=64 \
  bash -c "
    # Upstream gpu_run.py expects ~/cifm/VirtualTissue-CIFM/{adata.h5ad,results/threshold_per_channel.npy}
    # and ~/cifm/results_mp. The package's model_checkpoints/ + data/ come in via container-mounts above
    # (bind-mounted onto the read-only /opt/cifm/ tree); HOME-relative paths get symlinked from /tmp.
    export HOME=/tmp/cifm-workspace
    mkdir -p \$HOME/cifm/VirtualTissue-CIFM/virtualtissue_cifm \$HOME/cifm/results
    ln -sfn /opt/cifm/VirtualTissue-CIFM/virtualtissue_cifm/model_checkpoints \
            \$HOME/cifm/VirtualTissue-CIFM/virtualtissue_cifm/model_checkpoints
    ln -sfn /opt/cifm/VirtualTissue-CIFM/data/adata.h5ad             \$HOME/cifm/VirtualTissue-CIFM/adata.h5ad
    ln -sfn /opt/cifm/Youtils-ML4CellBio                              \$HOME/cifm/VirtualTissue-CIFM/Youtils-ML4CellBio
    ln -sfn /opt/cifm/VirtualTissue-CIFM/data/threshold_per_channel.npy \$HOME/cifm/results/threshold_per_channel.npy
    ln -sfn /opt/cifm/results_mp                                      \$HOME/cifm/results_mp
    cd \$HOME/cifm/VirtualTissue-CIFM
    exec python3 -u /opt/cifm/cloud-deployment/gpu_run.py
  "
EXIT=$?

echo
echo "=== exit=$EXIT, latest checkpoints on /lustre ==="
ls -lht /lustre/checkpoints/${SLURM_JOB_ID}/ 2>&1 | head -5
exit $EXIT
