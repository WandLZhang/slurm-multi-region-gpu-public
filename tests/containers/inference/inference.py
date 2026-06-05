#!/usr/bin/env python3
# Copyright 2026 Google LLC.
# SPDX-License-Identifier: Apache-2.0
"""
TinyLlama batch text-generation with resume-from-Lustre checkpoint.

State on /lustre (Managed Lustre, zonal in us-central1 but reachable from every
burst region via GLOBAL VPC routing):

    $OUT_DIR/progress.jsonl   single line: {"next_index": N}
                              N = index of next unprocessed prompt
    $OUT_DIR/results.jsonl    one line per completed prompt:
                              {"index": i, "prompt": ..., "completion": ...,
                               "job_id": ..., "restart": ..., "node": ...}

On Spot preempt + --requeue, the same $SLURM_JOB_ID gets a fresh VM in any of
the burst regions; this script reads progress.jsonl from /lustre (cross-region
read works on the same default VPC with GLOBAL routing) and resumes at
next_index — already-completed prompts are not re-run.

Atomicity: results.jsonl is appended + fsynced BEFORE progress.jsonl is
rewritten via write-temp-then-rename. Worst-case window between flush and
rename produces at-most one duplicated prompt on resume. Acceptable for an
at-least-once batch inference demo.
"""
import json
import os
import socket
import sys
import time
from pathlib import Path

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

MODEL_DIR    = os.environ.get("MODEL_DIR",    "/opt/model")
PROMPTS_PATH = os.environ.get("PROMPTS_PATH", "/opt/prompts.jsonl")
OUT_DIR      = Path(os.environ["OUT_DIR"])           # required: /lustre/inference/$SLURM_JOB_ID
MAX_NEW      = int(os.environ.get("MAX_NEW_TOKENS", "200"))
JOB_ID       = os.environ.get("SLURM_JOB_ID", "local")
RESTART      = int(os.environ.get("SLURM_RESTART_COUNT", "0"))
NODE         = socket.gethostname()

OUT_DIR.mkdir(parents=True, exist_ok=True)
progress_path = OUT_DIR / "progress.jsonl"
results_path  = OUT_DIR / "results.jsonl"
timings_path  = OUT_DIR / "timings.jsonl"   # one row per prompt: {i, gen_ms, result_write_ms, progress_write_ms, out_tier}


def load_progress() -> int:
    if not progress_path.exists():
        return 0
    with progress_path.open() as f:
        for line in f:
            try:
                return int(json.loads(line)["next_index"])
            except (ValueError, KeyError):
                pass
    return 0


def save_progress(next_index: int) -> None:
    tmp = progress_path.with_suffix(".jsonl.tmp")
    with tmp.open("w") as f:
        f.write(json.dumps({"next_index": next_index}) + "\n")
        f.flush()
        os.fsync(f.fileno())
    tmp.replace(progress_path)


def main() -> int:
    prompts = [json.loads(l) for l in Path(PROMPTS_PATH).read_text().splitlines() if l.strip()]
    t_lp0 = time.perf_counter()
    start = load_progress()
    load_progress_ms = (time.perf_counter() - t_lp0) * 1000.0
    out_tier = OUT_DIR.parts[1] if len(OUT_DIR.parts) > 1 else "?"
    print(f"=== load_progress: {load_progress_ms:.2f}ms (tier={out_tier}) ===", flush=True)
    label = "RESUME" if start > 0 else "FRESH"
    print(f"=== {label} on {NODE}: job={JOB_ID} restart={RESTART} "
          f"prompts={len(prompts)} resume_from={start} ===", flush=True)
    if start >= len(prompts):
        print("=== all prompts already processed; nothing to do ===", flush=True)
        return 0

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"loading model from {MODEL_DIR} on {device} ...", flush=True)
    t0 = time.time()
    tok = AutoTokenizer.from_pretrained(MODEL_DIR)
    model = AutoModelForCausalLM.from_pretrained(MODEL_DIR, torch_dtype=torch.bfloat16).to(device)
    model.eval()
    print(f"model loaded in {time.time() - t0:.1f}s", flush=True)

    with results_path.open("a") as results_f, timings_path.open("a") as timings_f:
        for i in range(start, len(prompts)):
            prompt = prompts[i]["prompt"]
            messages = [{"role": "user", "content": prompt}]
            input_ids = tok.apply_chat_template(messages, return_tensors="pt",
                                                add_generation_prompt=True).to(device)
            t_gen0 = time.perf_counter()
            with torch.no_grad():
                out = model.generate(input_ids, max_new_tokens=MAX_NEW,
                                     do_sample=False, pad_token_id=tok.eos_token_id)
            if device == "cuda":
                torch.cuda.synchronize()
            gen_ms = (time.perf_counter() - t_gen0) * 1000.0
            completion = tok.decode(out[0][input_ids.shape[1]:], skip_special_tokens=True).strip()

            record = {"index": i, "prompt": prompt, "completion": completion,
                      "job_id": JOB_ID, "restart": RESTART, "node": NODE,
                      "out_tier": out_tier}
            t_r0 = time.perf_counter()
            results_f.write(json.dumps(record, ensure_ascii=False) + "\n")
            results_f.flush()
            os.fsync(results_f.fileno())
            result_write_ms = (time.perf_counter() - t_r0) * 1000.0

            t_p0 = time.perf_counter()
            save_progress(i + 1)
            progress_write_ms = (time.perf_counter() - t_p0) * 1000.0

            # Persist per-prompt timings to a sidecar so Task 8's analyzer has
            # the actual measured write costs (the results.jsonl rows can't
            # carry their own write-time since the write happens BEFORE we can
            # measure it).
            timings_f.write(json.dumps({
                "index": i, "gen_ms": gen_ms,
                "result_write_ms": result_write_ms,
                "progress_write_ms": progress_write_ms,
                "out_tier": out_tier, "node": NODE,
                "job_id": JOB_ID, "restart": RESTART,
            }) + "\n")
            timings_f.flush()

            print(f"[{i+1}/{len(prompts)}] gen={gen_ms:.0f}ms "
                  f"res={result_write_ms:.1f}ms "
                  f"prog={progress_write_ms:.1f}ms tier={out_tier}", flush=True)

    print(f"=== done: processed {len(prompts) - start} prompts in this run "
          f"(total {len(prompts)}); ckpt at {progress_path} ===", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
