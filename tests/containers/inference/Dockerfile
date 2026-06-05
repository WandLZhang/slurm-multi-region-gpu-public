# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0
#
# Multi-region Slurm example workload — TinyLlama batch inference with
# progress checkpointing to /lustre.
#
# Fully self-contained — no private buckets, no logins, no gated models, no
# runtime downloads:
#   - model:   TinyLlama/TinyLlama-1.1B-Chat-v1.0 (Apache-2.0, ungated, public
#              on Hugging Face, no token required) — files baked into /opt/model
#              via huggingface_hub.snapshot_download at BUILD time
#   - prompts: vendored in-repo at prompts.jsonl, copied into the image
#   - code:    inference.py (in this dir), copied into the image
#
# The ONLY credential involved anywhere is the compute node's own
# service-account token pulling THIS image from the project's own Artifact
# Registry. Any user in any project can build + run this with zero extra access.
#
# Demonstrates Lustre checkpointing for the multi-region burst cluster:
#   - Spot allocation across regions
#   - Container delivery via Pyxis + Enroot from the project's own GAR
#   - Lustre checkpoint = /lustre/inference/$SLURM_JOB_ID/progress.jsonl
#     (next unprocessed prompt index) + results.jsonl (one line per completed
#     generation), both fsync'd after each prompt
#   - On Spot preempt + --requeue: same JobId rehydrates progress.jsonl from
#     Lustre (cross-region — Managed Lustre is reachable from every burst zone
#     via GLOBAL VPC routing) and resumes generation from next_index
#
# Build + push (admin, one-time per stack version):
#   cd tests/containers/inference/
#   gcloud builds submit --config=cloudbuild.yaml .

FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HUB_DISABLE_TELEMETRY=1
# NOTE: TRANSFORMERS_OFFLINE/HF_HUB_OFFLINE are NOT set here — they would block
# the build-time snapshot_download below. The runtime entrypoint sets them so
# inference runs never reach the network for model weights.

RUN pip install --no-cache-dir transformers==4.46.3 accelerate==1.1.1 huggingface_hub==0.26.2

# Pre-download model files at BUILD time → bake into /opt/model. We use
# snapshot_download (file copy only, no model instantiation) to keep the Cloud
# Build VM RAM ceiling low. Runtime has TRANSFORMERS_OFFLINE=1 so loading hits
# local disk only — proves the runtime needs no network for model weights.
RUN python -c "from huggingface_hub import snapshot_download; \
    snapshot_download('TinyLlama/TinyLlama-1.1B-Chat-v1.0', \
                      local_dir='/opt/model', \
                      allow_patterns=['*.json','*.safetensors','*.model','tokenizer.*','special_tokens_map.json'])"

COPY inference.py /opt/inference.py
COPY prompts.jsonl /opt/prompts.jsonl
COPY entrypoint.sh /usr/local/bin/inference-entrypoint
RUN chmod 0755 /usr/local/bin/inference-entrypoint

ENTRYPOINT ["/usr/local/bin/inference-entrypoint"]
