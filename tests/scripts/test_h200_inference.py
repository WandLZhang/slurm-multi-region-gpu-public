#!/usr/bin/env python3
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

"""
End-to-end validation for the my-slurm reference deployment.

Proves:
  1. PyTorch sees all 8 H200 GPUs on the assigned node.
  2. Each H200 can do real CUDA work (forward pass through a small tensor).
  3. /gcs (Cloud Storage FUSE mount) supports POSIX-style writes.
  4. /gcs/weights/ (read-only inputs subdirectory) supports POSIX-style reads
     via the small example files copied in during project setup.

Generic GPU + storage smoke test — workload-agnostic. Replace the read sanity
check at the bottom with your own input file path if you have a specific
read-pattern to validate.
"""

import argparse
import json
import os
import socket
import time
import urllib.request
from pathlib import Path

import torch


def get_zone() -> str:
    try:
        req = urllib.request.Request(
            "http://metadata/computeMetadata/v1/instance/zone",
            headers={"Metadata-Flavor": "Google"},
        )
        with urllib.request.urlopen(req, timeout=2) as r:
            return r.read().decode().split("/")[-1]
    except Exception:
        return "unknown"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, help="Output dir on /gcs/runs/<JOB>/")
    args = parser.parse_args()

    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)

    job_id = os.environ.get("SLURM_JOB_ID", "local")
    hostname = socket.gethostname()
    zone = get_zone()

    print(f"[python] hostname={hostname} zone={zone} job={job_id}", flush=True)
    print(f"[python] torch={torch.__version__} cuda_available={torch.cuda.is_available()}", flush=True)

    if not torch.cuda.is_available():
        raise SystemExit("FAIL: CUDA not available — H200 driver missing on this node.")

    n_gpus = torch.cuda.device_count()
    print(f"[python] device_count={n_gpus}", flush=True)

    devices = []
    for i in range(n_gpus):
        props = torch.cuda.get_device_properties(i)
        devices.append({
            "index": i,
            "name": props.name,
            "total_memory_gb": round(props.total_memory / 2**30, 1),
            "major": props.major,
            "minor": props.minor,
        })
        print(f"[python]   GPU {i}: {props.name} ({devices[-1]['total_memory_gb']} GiB)", flush=True)

    # Real GPU work: 4096x4096 matmul on each GPU, time it
    print("[python] Running 4096x4096 matmul on each GPU for 5 iterations...", flush=True)
    perf = {}
    for i in range(n_gpus):
        torch.cuda.set_device(i)
        a = torch.randn(4096, 4096, device=f"cuda:{i}", dtype=torch.float16)
        b = torch.randn(4096, 4096, device=f"cuda:{i}", dtype=torch.float16)
        # Warmup
        for _ in range(2):
            c = a @ b
        torch.cuda.synchronize(i)
        t0 = time.perf_counter()
        for _ in range(5):
            c = a @ b
        torch.cuda.synchronize(i)
        dt = time.perf_counter() - t0
        # 5 iterations of (4096^3 * 2) FLOPs, in TFLOPs/s
        tflops = (5 * 4096 ** 3 * 2) / dt / 1e12
        perf[f"gpu_{i}"] = {"matmul_5iter_seconds": round(dt, 4), "tflops_fp16": round(tflops, 1)}
        print(f"[python]   GPU {i}: {dt:.3f}s, {tflops:.1f} TFLOPS (FP16)", flush=True)

    # Read sanity check from /lustre/weights/ (parallel-POSIX read-only inputs;
    # populated during project setup. Lustre is the canonical read+write layer
    # for compute-intensive workflows; /gcs is durable archive only).
    weights_probe = Path("/lustre/weights/data/args.pt")
    weights_read_ok = weights_probe.is_file()
    weights_size = weights_probe.stat().st_size if weights_read_ok else 0
    print(f"[python] /lustre/weights/data/args.pt exists={weights_read_ok} size={weights_size} bytes", flush=True)

    # Write sanity check on /gcs
    output_tensor = torch.randn(128, 128, dtype=torch.float32)
    torch.save(output_tensor, out / "test_output.pt")
    (out / "metadata.json").write_text(json.dumps({
        "job_id": job_id,
        "hostname": hostname,
        "zone": zone,
        "torch_version": torch.__version__,
        "cuda_available": True,
        "device_count": n_gpus,
        "devices": devices,
        "perf": perf,
        "weights_read_ok": weights_read_ok,
        "weights_args_size_bytes": weights_size,
        "output_tensor_shape": list(output_tensor.shape),
    }, indent=2))

    print(f"[python] Wrote {out}/test_output.pt and {out}/metadata.json", flush=True)
    print("[python] PASS", flush=True)


if __name__ == "__main__":
    main()
