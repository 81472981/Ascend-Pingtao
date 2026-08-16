#!/usr/bin/env bash
"${PYTHON:-python3}" - <<'PY'
import csv
import json
import os
import shlex
import shutil
import statistics
import subprocess
import sys
from datetime import datetime
from pathlib import Path

HOST = "127.0.0.1"
PORT = 8000
MODEL = None
VLLM_BIN = os.environ.get("VLLM_BIN", "vllm")
OUTPUT_DIR = Path(os.environ.get("VB_OUT", "vbench-results"))
INPUT_LEN = 16 * 1024
BATCHES = 5


def vllm():
    parts = shlex.split(VLLM_BIN)
    if os.path.dirname(parts[0]) and not os.path.isfile(parts[0]):
        sys.exit(f"vllm not found: {parts[0]}")
    if not os.path.dirname(parts[0]) and shutil.which(parts[0]) is None:
        local = Path(".venv/bin") / parts[0]
        if not local.is_file():
            sys.exit(f"vllm not found: {parts[0]}")
        parts[0] = str(local.resolve())
    return parts


def command(vllm_bin, result_dir, filename):
    cmd = [
        *vllm_bin, "bench", "serve", "--host", HOST, "--port", str(PORT),
        "--endpoint", "/v1/completions", "--backend", "openai",
        "--dataset-name", "prefix_repetition", "--num-prompts", "1",
        "--max-concurrency", "1", "--request-rate", "inf",
        "--prefix-repetition-prefix-len", str(INPUT_LEN),
        "--prefix-repetition-suffix-len", "0",
        "--prefix-repetition-num-prefixes", "1",
        "--prefix-repetition-output-len", "1", "--seed", "0",
        "--disable-shuffle", "--temperature", "0", "--ignore-eos",
        "--save-result", "--save-detailed", "--result-dir", str(result_dir),
        "--result-filename", filename,
    ]
    if MODEL:
        cmd += ["--model", MODEL]
    return cmd


def run(cmd):
    result = subprocess.run(cmd, text=True, capture_output=True)
    if result.returncode:
        sys.exit(f"vllm failed: {shlex.join(cmd)}\n" + result.stderr[-2000:])


def ttft(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return float(data["ttfts"][0])


run_dir = OUTPUT_DIR / datetime.now().strftime("%Y%m%d-%H%M%S-%f")
json_dir = run_dir / "json"
json_dir.mkdir(parents=True, exist_ok=True)
vllm_bin = vllm()

print("[1/2] Warming prefix cache with 1 request")
run(command(vllm_bin, json_dir, "warmup.json"))
ttft(json_dir / "warmup.json")

print("[2/2] Running 5 batches at concurrency=1")
values = []
for batch in range(1, BATCHES + 1):
    filename = f"concurrency-001-batch-{batch:02d}.json"
    run(command(vllm_bin, json_dir, filename))
    value = ttft(json_dir / filename)
    values.append(value)
    print(f"  Batch {batch}/{BATCHES}: TTFT={value:.6f}s")

raw_path = run_dir / "raw_ttft_c1.csv"
with raw_path.open("w", encoding="utf-8-sig", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["concurrency", "batch", "ttft_seconds"])
    for batch, value in enumerate(values, start=1):
        writer.writerow([1, batch, f"{value:.9f}"])

summary_path = run_dir / "summary_ttft_c1.csv"
with summary_path.open("w", encoding="utf-8-sig", newline="") as f:
    writer = csv.writer(f)
    writer.writerow(["concurrency", "requests", "mean_ttft_seconds", "min_ttft_seconds", "max_ttft_seconds"])
    writer.writerow([1, len(values), f"{statistics.fmean(values):.9f}", f"{min(values):.9f}", f"{max(values):.9f}"])

print(f"Mean TTFT: {statistics.fmean(values):.6f}s")
print(f"Raw records: {raw_path}")
print(f"Summary:     {summary_path}")
PY
