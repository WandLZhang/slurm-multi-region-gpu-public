# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0
#
# nanoGPT example-workload container for the multi-region Slurm cluster.
#
# Fully self-contained — no private buckets, no logins, no model downloads:
#   - code:  karpathy/nanoGPT cloned at build time (public, MIT license)
#   - data:  tinyshakespeare vendored in-repo (input.txt) and tokenized at
#            build time → train.bin/val.bin baked into the image
#   - model: trained from scratch, so there is nothing to fetch at runtime
#
# The ONLY credential involved anywhere is the compute node's own
# service-account token pulling this image from the project's own Artifact
# Registry. Any user in any project can build + run this with zero extra access.

FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

# nanoGPT's runtime deps beyond the torch base.
RUN pip install --no-cache-dir numpy requests tiktoken

# Upstream nanoGPT — public, MIT. Shallow clone of the default branch.
RUN git clone --depth 1 https://github.com/karpathy/nanoGPT /opt/nanogpt

WORKDIR /opt/nanogpt

# Vendored tinyshakespeare → tokenize at BUILD time so train.bin/val.bin/meta.pkl
# ship inside the image. prepare.py uses the local input.txt as-is (it only
# downloads when input.txt is absent), so the build needs no network for data.
COPY input.txt /opt/nanogpt/data/shakespeare_char/input.txt
RUN python data/shakespeare_char/prepare.py

COPY entrypoint.sh /usr/local/bin/nanogpt-entrypoint
RUN chmod 0755 /usr/local/bin/nanogpt-entrypoint

ENTRYPOINT ["/usr/local/bin/nanogpt-entrypoint"]
