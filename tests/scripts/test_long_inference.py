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
Long-running checkpointed H200 workload, used to demonstrate that Slurm
`--requeue` + the resume hook + GCS-FUSE checkpointing make Spot preemption
invisible to the researcher.

Each iteration:
  1. Picks up the last completed step from /gcs/checkpoints/$JOB_ID/
  2. Does real GPU work (matmul on every visible H200)
  3. Writes step_<N>.npy to /gcs/checkpoints/$JOB_ID/

If the VM is preempted mid-iteration, Slurm requeues the job; on the new VM
we read the highest existing step number from /gcs/checkpoints/$JOB_ID/ and
resume from there.

Usage (under sbatch):
  python3 test_long_inference.py --checkpoint-dir /gcs/checkpoints/$SLURM_JOB_ID --steps 10 --seconds-per-step 30
"""

import argparse
import json
import os
import socket
import time
import urllib.request
from pathlib import Path

import numpy as np
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


def find_last_checkpoint(ckpt_dir: Path) -> int:
    """Highest step_<N>.npy already on disk; -1 if none."""
    if not ckpt_dir.exists():
        return -1
    nums = []
    for p in ckpt_dir.glob("step_*.npy"):
        try:
            nums.append(int(p.stem.split("_")[1]))
        except ValueError:
            continue
    return max(nums) if nums else -1


def run_step(step: int, seconds_per_step: float) -> dict:
    """Real GPU work on every visible device — returns timing per device."""
    n = torch.cuda.device_count()
    timings = {}
    end_at = time.perf_counter() + seconds_per_step
    iter_count = 0
    while time.perf_counter() < end_at:
        for i in range(n):
            torch.cuda.set_device(i)
            a = torch.randn(8192, 8192, device=f"cuda:{i}", dtype=torch.float16)
            b = torch.randn(8192, 8192, device=f"cuda:{i}", dtype=torch.float16)
            c = a @ b
            torch.cuda.synchronize(i)
            timings.setdefault(f"gpu_{i}_iters", 0)
            timings[f"gpu_{i}_iters"] += 1
        iter_count += 1
    timings["wall_iters"] = iter_count
    return timings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint-dir", required=True)
    parser.add_argument("--steps", type=int, default=10)
    parser.add_argument("--seconds-per-step", type=float, default=30.0)
    args = parser.parse_args()

    ckpt_dir = Path(args.checkpoint_dir)
    ckpt_dir.mkdir(parents=True, exist_ok=True)

    job_id = os.environ.get("SLURM_JOB_ID", "local")
    hostname = socket.gethostname()
    zone = get_zone()
    print(f"[boot] job={job_id} host={hostname} zone={zone} cuda={torch.cuda.is_available()} ngpu={torch.cuda.device_count()}", flush=True)

    last = find_last_checkpoint(ckpt_dir)
    print(f"[resume] last completed step on disk: {last}", flush=True)

    for step in range(last + 1, args.steps):
        t0 = time.perf_counter()
        timings = run_step(step, args.seconds_per_step)
        dt = time.perf_counter() - t0

        ckpt = {
            "step": step,
            "wrote_at": time.time(),
            "host": hostname,
            "zone": zone,
            "duration_seconds": round(dt, 3),
            "timings": timings,
        }
        # Save as a small npy of metadata so the next process sees the file
        np.save(ckpt_dir / f"step_{step}.npy", np.array([json.dumps(ckpt)], dtype=object), allow_pickle=True)
        print(f"[step {step}] {dt:.1f}s on {hostname} ({zone})  ckpt → {ckpt_dir / f'step_{step}.npy'}", flush=True)

    print(f"[done] all {args.steps} steps complete (last host: {hostname}, {zone})", flush=True)


if __name__ == "__main__":
    main()
