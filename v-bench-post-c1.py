#!/usr/bin/env python3
"""Concurrency=1 TTFT benchmark for a local vLLM server.

This is a deliberately small copy of the full benchmark.  It warms the prefix
cache once, then runs 5 recorded batches at concurrency=1 and writes CSV files.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import shlex
import shutil
import statistics
import subprocess
from datetime import datetime
from pathlib import Path


INPUT_LEN = 16 * 1024
OUTPUT_LEN = 1
SEED = 0
BATCHES = 5


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--model", default=None)
    parser.add_argument("--served-model-name", default=None)
    parser.add_argument("--vllm-bin", default="vllm")
    parser.add_argument("--output-dir", type=Path, default=Path("vbench-results"))
    parser.add_argument("--timeout", type=float, default=0.0)
    return parser.parse_args()


def resolve_vllm(vllm_bin: str) -> list[str]:
    parts = shlex.split(vllm_bin)
    executable = parts[0]
    if os.path.dirname(executable):
        if not os.path.isfile(executable):
            raise SystemExit(f"vllm executable does not exist: {executable}")
    elif shutil.which(executable) is None:
        local = Path(".venv/bin") / executable
        if local.is_file():
            parts[0] = str(local.resolve())
        else:
            raise SystemExit(f"could not find vllm: {executable}")
    return parts


def build_command(
    vllm: list[str],
    args: argparse.Namespace,
    result_dir: Path,
    result_filename: str,
) -> list[str]:
    command = [
        *vllm,
        "bench",
        "serve",
        "--host",
        args.host,
        "--port",
        str(args.port),
        "--endpoint",
        "/v1/completions",
        "--backend",
        "openai",
        "--dataset-name",
        "prefix_repetition",
        "--num-prompts",
        "1",
        "--max-concurrency",
        "1",
        "--request-rate",
        "inf",
        "--prefix-repetition-prefix-len",
        str(INPUT_LEN),
        "--prefix-repetition-suffix-len",
        "0",
        "--prefix-repetition-num-prefixes",
        "1",
        "--prefix-repetition-output-len",
        str(OUTPUT_LEN),
        "--seed",
        str(SEED),
        "--disable-shuffle",
        "--temperature",
        "0",
        "--ignore-eos",
        "--save-result",
        "--save-detailed",
        "--result-dir",
        str(result_dir),
        "--result-filename",
        result_filename,
    ]
    if args.model:
        command.extend(["--model", args.model])
    if args.served_model_name:
        command.extend(["--served-model-name", args.served_model_name])
    return command


def run_vllm(command: list[str], timeout: float) -> None:
    print("  +", shlex.join(command))
    completed = subprocess.run(
        command,
        text=True,
        capture_output=True,
        timeout=timeout if timeout > 0 else None,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"vllm failed (exit={completed.returncode})\n"
            + "\n".join(completed.stderr.splitlines()[-30:])
        )


def read_ttft(path: Path) -> float:
    data = json.loads(path.read_text(encoding="utf-8"))
    ttfts = data.get("ttfts")
    errors = data.get("errors") or []
    if not isinstance(ttfts, list) or not ttfts:
        raise RuntimeError(f"no ttfts in {path}")
    if errors and errors[0] is not None:
        raise RuntimeError(f"request failed: {errors[0]}")
    return float(ttfts[0])


def main() -> None:
    args = parse_args()
    vllm = resolve_vllm(args.vllm_bin)
    run_dir = args.output_dir.expanduser().resolve() / datetime.now().strftime(
        "%Y%m%d-%H%M%S-%f"
    )
    json_dir = run_dir / "json"
    json_dir.mkdir(parents=True, exist_ok=True)

    print("Warming prefix cache")
    run_vllm(build_command(vllm, args, json_dir, "warmup.json"), args.timeout)
    read_ttft(json_dir / "warmup.json")

    values: list[float] = []
    for batch in range(1, BATCHES + 1):
        filename = f"concurrency-001-batch-{batch:02d}.json"
        print(f"Batch {batch}/{BATCHES}")
        run_vllm(build_command(vllm, args, json_dir, filename), args.timeout)
        ttft = read_ttft(json_dir / filename)
        values.append(ttft)
        print(f"  TTFT={ttft:.6f}s")

    raw_path = run_dir / "raw_ttft.csv"
    with raw_path.open("w", encoding="utf-8-sig", newline="") as file:
        writer = csv.writer(file)
        writer.writerow(["concurrency", "batch", "ttft_seconds"])
        for batch, value in enumerate(values, start=1):
            writer.writerow([1, batch, f"{value:.9f}"])

    summary_path = run_dir / "summary_ttft.csv"
    with summary_path.open("w", encoding="utf-8-sig", newline="") as file:
        writer = csv.writer(file)
        writer.writerow(
            ["concurrency", "requests", "mean_ttft_seconds", "min_ttft_seconds", "max_ttft_seconds"]
        )
        writer.writerow(
            [1, len(values), f"{statistics.fmean(values):.9f}", f"{min(values):.9f}", f"{max(values):.9f}"]
        )

    print(f"Raw records: {raw_path}")
    print(f"Summary:     {summary_path}")
    print(f"Mean TTFT:   {statistics.fmean(values):.6f}s")


if __name__ == "__main__":
    main()
