#!/bin/bash
# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0

# Direct end-to-end H200 + GCS-FUSE + POSIX-style I/O validation,
# without Slurm. Provisions a single Spot a3-ultragpu-8g VM in us-south1-b,
# mounts the gs://cifm-staging bucket via Cloud Storage FUSE, runs the
# Caltech CI-FM 1B inference workload reading and writing through the
# POSIX file paths, then optionally tears the VM down.
#
# This is a V1.5 fallback for the multi-week Slurm-on-GCP image build
# blocker (slurm-gcp v6.12.1 ansible playbook tries to install the
# deprecated stackdriver-agent which is not available on Ubuntu 22.04).
# It still proves the customer-doc claim: H200 Spot in us-south1-b +
# GCS FUSE = a working POSIX-shaped researcher experience.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${ZONE:-us-south1-b}"
VM_NAME="${VM_NAME:-wz-cifm-h200-spot}"
SUBNET="${SUBNET:-default}"
IMAGE_FAMILY="${IMAGE_FAMILY:-pytorch-2-9-cu129-ubuntu-2204-nvidia-580}"
IMAGE_PROJECT="${IMAGE_PROJECT:-deeplearning-platform-release}"

echo "==> Create Spot a3-ultragpu-8g VM in $ZONE"
gcloud compute instances create "$VM_NAME" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --machine-type=a3-ultragpu-8g \
  --image-family="$IMAGE_FAMILY" \
  --image-project="$IMAGE_PROJECT" \
  --boot-disk-type=hyperdisk-balanced \
  --boot-disk-size=300 \
  --scopes=cloud-platform \
  --network-interface=network=default,subnet="$SUBNET",nic-type=GVNIC \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --maintenance-policy=TERMINATE \
  --no-restart-on-failure

echo
echo "==> Wait for SSH"
for i in {1..30}; do
  if gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --tunnel-through-iap --command="echo ok" 2>/dev/null; then
    break
  fi
  echo "  ... try $i/30"
  sleep 10
done

echo
echo "==> Install gcsfuse + mount gs://cifm-staging at /cifm (read-only)"
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --tunnel-through-iap --command='
set -euo pipefail
export GCSFUSE_REPO=gcsfuse-$(lsb_release -c -s)
echo "deb [signed-by=/usr/share/keyrings/cloud.google.asc] https://packages.cloud.google.com/apt $GCSFUSE_REPO main" | sudo tee /etc/apt/sources.list.d/gcsfuse.list
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.asc
sudo apt-get update -qq && sudo apt-get install -y -qq gcsfuse
sudo mkdir -p /cifm && sudo chmod 777 /cifm
gcsfuse --implicit-dirs -o ro --foreground=false cifm-staging /cifm &
sleep 5
ls -lh /cifm/data/ | head
'

echo
echo "==> Smoke test: nvidia-smi + GCS FUSE read of CIFM weights metadata"
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --tunnel-through-iap --command='
set -euo pipefail
nvidia-smi
echo
ls -lh /cifm/data/args.pt /cifm/data/channel2ensembl.pt /cifm/data/zenodo_1b_checkpoint.ckpt
echo
python3 -c "import torch; print(\"cuda_available:\", torch.cuda.is_available()); print(\"device_count:\", torch.cuda.device_count()); [print(f\"  GPU {i}:\", torch.cuda.get_device_name(i), torch.cuda.get_device_properties(i).total_memory // 2**30, \"GiB\") for i in range(torch.cuda.device_count())]"
'

echo
echo "==> SUCCESS — VM still running. To run the real CIFM inference + tear down:"
echo "    gcloud compute ssh $VM_NAME --zone=$ZONE --project=$PROJECT_ID --tunnel-through-iap"
echo "    gcloud compute instances delete $VM_NAME --zone=$ZONE --project=$PROJECT_ID --quiet"
