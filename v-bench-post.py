
"""Run vLLM ``bench serve`` batches and summarize per-request TTFT.

The script is intended for a local vLLM-compatible server that has prefix
caching enabled.  Every request uses the same prompt (``prefix_repetition``
dataset with one prefix and no suffix), so after the first warmup request the
server should be able to hit its prefix cache.

For each configured concurrency it launches ``vllm bench serve`` once per
batch.  Each launch saves a detailed result JSON containing the per-request
``ttfts`` list.  Those values are collected into a raw CSV and a summary CSV.
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
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8000
DEFAULT_ENDPOINT = "/v1/completions"
DEFAULT_BACKEND = "openai"
DEFAULT_CONCURRENCIES = (1, 5, 10, 100)
DEFAULT_BATCHES = 5
DEFAULT_INPUT_LEN = 16 * 1024
DEFAULT_OUTPUT_LEN = 1
DEFAULT_SEED = 0
DEFAULT_OUTPUT_DIR = Path("vbench-results")
DEFAULT_VLLM_BIN = "vllm"


@dataclass(frozen=True)
class RawRecord:
    concurrency: int
    batch: int
    request_index: int
    ttft_seconds: float
    prompt_tokens: int | None
    output_tokens: int | None
    result_file: str


@dataclass(frozen=True)
class BatchOutcome:
    concurrency: int
    batch: int
    records: list[RawRecord]
    failed: int
    result_file: Path
    duration_seconds: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    parser.add_argument("--backend", default=DEFAULT_BACKEND)
    parser.add_argument(
        "--model",
        default=None,
        help="Model name sent to the server. If omitted, vllm bench serve "
        "fetches the first model from the server.",
    )
    parser.add_argument(
        "--served-model-name",
        default=None,
        help="Served model name when it differs from --model.",
    )
    parser.add_argument(
        "--tokenizer",
        default=None,
        help="Tokenizer name or path. If omitted, vllm derives it from the model.",
    )
    parser.add_argument(
        "--trust-remote-code",
        action="store_true",
        help="Pass --trust-remote-code to vllm bench serve.",
    )
    parser.add_argument(
        "--concurrencies",
        default=",".join(str(item) for item in DEFAULT_CONCURRENCIES),
        help="Comma-separated concurrency levels.",
    )
    parser.add_argument("--batches", type=int, default=DEFAULT_BATCHES)
    parser.add_argument(
        "--input-len",
        type=int,
        default=DEFAULT_INPUT_LEN,
        help="Exact prompt length in tokens (16K = 16384).",
    )
    parser.add_argument("--output-len", type=int, default=DEFAULT_OUTPUT_LEN)
    parser.add_argument(
        "--seed",
        type=int,
        default=DEFAULT_SEED,
        help="vLLM dataset seed. Keep it fixed so every batch uses the same prompt.",
    )
    parser.add_argument(
        "--vllm-bin",
        default=DEFAULT_VLLM_BIN,
        help="vllm executable or a command prefix such as 'python -m vllm'.",
    )
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument(
        "--timeout",
        type=float,
        default=0.0,
        help="Per-batch subprocess timeout in seconds. 0 means no timeout.",
    )
    parser.add_argument(
        "--keep-json",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Keep detailed JSON files written by vllm bench serve. "
        "Use --no-keep-json to delete them after extracting raw records.",
    )
    parser.add_argument(
        "--skip-warmup",
        action="store_true",
        help="Skip the initial cache-warmup request. Intended for debugging only.",
    )
    return parser.parse_args()


def parse_concurrencies(raw: str) -> list[int]:
    values: list[int] = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            value = int(part)
        except ValueError as error:
            raise SystemExit(f"invalid concurrency value: {part!r}") from error
        if value <= 0:
            raise SystemExit("concurrency values must be greater than zero")
        if value not in values:
            values.append(value)
    if not values:
        raise SystemExit("--concurrencies must contain at least one value")
    return values


def resolve_command_prefix(vllm_bin: str) -> list[str]:
    parts = shlex.split(vllm_bin)
    if not parts:
        raise SystemExit("--vllm-bin cannot be empty")

    executable = parts[0]
    if os.path.dirname(executable):
        if not os.path.isfile(executable):
            raise SystemExit(f"vllm executable does not exist: {executable}")
    elif shutil.which(executable) is None:
        # A project-local virtualenv is common for vLLM setups.
        local_candidate = Path(".venv/bin") / executable
        if local_candidate.is_file():
            parts[0] = str(local_candidate.resolve())
        else:
            raise SystemExit(
                f"could not find vllm executable '{executable}'. "
                "Activate the virtualenv or pass --vllm-bin."
            )
    return parts


def build_vllm_command(
    command_prefix: list[str],
    args: argparse.Namespace,
    *,
    num_prompts: int,
    result_dir: Path,
    result_filename: str,
) -> list[str]:
    """Build one ``vllm bench serve`` invocation."""
    command = [
        *command_prefix,
        "bench",
        "serve",
        "--host",
        args.host,
        "--port",
        str(args.port),
        "--endpoint",
        args.endpoint,
        "--backend",
        args.backend,
        "--dataset-name",
        "prefix_repetition",
        "--num-prompts",
        str(num_prompts),
        "--max-concurrency",
        str(num_prompts),
        "--request-rate",
        "inf",
        "--prefix-repetition-prefix-len",
        str(args.input_len),
        "--prefix-repetition-suffix-len",
        "0",
        "--prefix-repetition-num-prefixes",
        "1",
        "--prefix-repetition-output-len",
        str(args.output_len),
        "--seed",
        str(args.seed),
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
    if args.tokenizer:
        command.extend(["--tokenizer", args.tokenizer])
    if args.trust_remote_code:
        command.append("--trust-remote-code")
    return command


def run_vllm(command: list[str], timeout: float) -> subprocess.CompletedProcess[str]:
    print(f"  + {shlex.join(command)}")
    started_at = time.perf_counter()
    completed = subprocess.run(
        command,
        text=True,
        capture_output=True,
        timeout=timeout if timeout > 0 else None,
        check=False,
    )
    elapsed = time.perf_counter() - started_at
    if completed.returncode != 0:
        stdout_tail = "\n".join(completed.stdout.splitlines()[-30:])
        stderr_tail = "\n".join(completed.stderr.splitlines()[-30:])
        raise RuntimeError(
            "vllm bench serve failed "
            f"(exit={completed.returncode}, elapsed={elapsed:.3f}s)\n"
            f"stdout tail:\n{stdout_tail}\n"
            f"stderr tail:\n{stderr_tail}"
        )
    print(f"    completed in {elapsed:.3f}s")
    return completed


def _optional_int(value: object) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def parse_vllm_result(
    result_path: Path,
    *,
    concurrency: int,
    batch: int,
) -> tuple[list[RawRecord], int]:
    """Extract successful per-request TTFT values from a vllm JSON result."""
    try:
        data = json.loads(result_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"could not read vllm result {result_path}: {error}") from error

    ttfts = data.get("ttfts")
    if not isinstance(ttfts, list):
        raise RuntimeError(
            f"vllm result {result_path} has no per-request 'ttfts' list. "
            "Make sure --save-result and --save-detailed were used."
        )

    input_lens = data.get("input_lens") or []
    output_lens = data.get("output_lens") or []
    errors = data.get("errors") or []
    records: list[RawRecord] = []
    failed = 0

    for index in range(concurrency):
        error = errors[index] if index < len(errors) else None
        if error is not None:
            failed += 1
            continue
        if index >= len(ttfts):
            failed += 1
            continue

        raw_ttft = ttfts[index]
        if raw_ttft is None:
            failed += 1
            continue
        try:
            ttft_seconds = float(raw_ttft)
        except (TypeError, ValueError):
            failed += 1
            continue
        if ttft_seconds < 0:
            failed += 1
            continue

        records.append(
            RawRecord(
                concurrency=concurrency,
                batch=batch,
                request_index=index + 1,
                ttft_seconds=ttft_seconds,
                prompt_tokens=(
                    _optional_int(input_lens[index])
                    if index < len(input_lens)
                    else None
                ),
                output_tokens=(
                    _optional_int(output_lens[index])
                    if index < len(output_lens)
                    else None
                ),
                result_file=result_path.name,
            )
        )
    return records, failed


def run_batch(
    command_prefix: list[str],
    args: argparse.Namespace,
    *,
    concurrency: int,
    batch: int,
    json_dir: Path,
) -> BatchOutcome:
    result_filename = f"concurrency-{concurrency:03d}-batch-{batch:02d}.json"
    command = build_vllm_command(
        command_prefix,
        args,
        num_prompts=concurrency,
        result_dir=json_dir,
        result_filename=result_filename,
    )
    started_at = time.perf_counter()
    run_vllm(command, args.timeout)
    duration_seconds = time.perf_counter() - started_at

    result_path = json_dir / result_filename
    if not result_path.is_file():
        raise RuntimeError(f"vllm did not create expected result file: {result_path}")
    records, failed = parse_vllm_result(
        result_path,
        concurrency=concurrency,
        batch=batch,
    )
    if not records:
        raise RuntimeError(
            f"batch concurrency={concurrency}, batch={batch} produced no usable TTFT records"
        )
    return BatchOutcome(
        concurrency=concurrency,
        batch=batch,
        records=records,
        failed=failed,
        result_file=result_path,
        duration_seconds=duration_seconds,
    )


def run_warmup(
    command_prefix: list[str],
    args: argparse.Namespace,
    json_dir: Path,
) -> None:
    result_filename = "warmup.json"
    command = build_vllm_command(
        command_prefix,
        args,
        num_prompts=1,
        result_dir=json_dir,
        result_filename=result_filename,
    )
    run_vllm(command, args.timeout)
    result_path = json_dir / result_filename
    if not result_path.is_file():
        raise RuntimeError(f"vllm did not create warmup result file: {result_path}")
    records, failed = parse_vllm_result(
        result_path,
        concurrency=1,
        batch=0,
    )
    if failed or not records:
        raise RuntimeError("warmup request failed; refusing to run recorded batches")


def percentile(sorted_values: list[float], percent: float) -> float:
    if not sorted_values:
        raise ValueError("cannot compute percentile of an empty list")
    if len(sorted_values) == 1:
        return sorted_values[0]
    rank = (percent / 100.0) * (len(sorted_values) - 1)
    lower = int(rank)
    upper = min(lower + 1, len(sorted_values) - 1)
    weight = rank - lower
    return sorted_values[lower] * (1.0 - weight) + sorted_values[upper] * weight


def summarize(
    concurrency: int,
    records: list[RawRecord],
    failed: int,
) -> dict[str, object]:
    values = sorted(record.ttft_seconds for record in records)
    return {
        "concurrency": concurrency,
        "batches": len({record.batch for record in records}),
        "requests": len(records),
        "failed_requests": failed,
        "Avg TTFT": statistics.fmean(values),
        "median_ttft_seconds": statistics.median(values),
        "p50_ttft_seconds": percentile(values, 50.0),
        "p95_ttft_seconds": percentile(values, 95.0),
        "p99_ttft_seconds": percentile(values, 99.0),
        "min_ttft_seconds": values[0],
        "max_ttft_seconds": values[-1],
        "std_ttft_seconds": statistics.stdev(values) if len(values) > 1 else 0.0,
    }


def write_raw_csv(path: Path, records: list[RawRecord]) -> None:
    fieldnames = [
        "concurrency",
        "batch",
        "request_index",
        "ttft_seconds",
        "prompt_tokens",
        "output_tokens",
        "result_file",
    ]
    with path.open("w", encoding="utf-8-sig", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        for record in records:
            writer.writerow(
                {
                    "concurrency": record.concurrency,
                    "batch": record.batch,
                    "request_index": record.request_index,
                    "ttft_seconds": f"{record.ttft_seconds:.9f}",
                    "prompt_tokens": (
                        "" if record.prompt_tokens is None else record.prompt_tokens
                    ),
                    "output_tokens": (
                        "" if record.output_tokens is None else record.output_tokens
                    ),
                    "result_file": record.result_file,
                }
            )


def write_summary_csv(path: Path, summaries: list[dict[str, object]]) -> None:
    fieldnames = list(summaries[0].keys())
    with path.open("w", encoding="utf-8-sig", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        for summary in summaries:
            row = {
                key: (f"{value:.9f}" if isinstance(value, float) else value)
                for key, value in summary.items()
            }
            writer.writerow(row)


def print_summaries(summaries: list[dict[str, object]]) -> None:
    print("\nTTFT summary:")
    for summary in summaries:
        concurrency = summary["concurrency"]
        mean = summary["Avg TTFT"]
        median = summary["median_ttft_seconds"]
        p99 = summary["p99_ttft_seconds"]
        print(
            f"  concurrency={concurrency}: requests={summary['requests']}, "
            f"failed={summary['failed_requests']}, "
            f"mean={float(mean):.6f}s, median={float(median):.6f}s, "
            f"p99={float(p99):.6f}s"
        )


def main() -> None:
    args = parse_args()
    if args.input_len <= 0:
        raise SystemExit("--input-len must be greater than zero")
    if args.output_len <= 0:
        raise SystemExit("--output-len must be greater than zero")
    if args.batches <= 0:
        raise SystemExit("--batches must be greater than zero")
    if args.timeout < 0:
        raise SystemExit("--timeout cannot be negative")

    concurrencies = parse_concurrencies(args.concurrencies)
    command_prefix = resolve_command_prefix(args.vllm_bin)
    output_root = args.output_dir.expanduser().resolve()
    run_dir = output_root / datetime.now(timezone(timedelta(hours=8))).strftime("%H%M%S")
    json_dir = run_dir / "json"
    json_dir.mkdir(parents=True, exist_ok=True)

    raw_csv_path = run_dir / "raw_ttft.csv"
    summary_csv_path = run_dir / "summary_ttft.csv"
    all_records: list[RawRecord] = []
    summaries: list[dict[str, object]] = []

    print(f"Output directory: {run_dir}")
    print(
        f"Concurrencies: {concurrencies}; batches per concurrency: {args.batches}"
    )

    if not args.skip_warmup:
        print("\n[1/3] Warming prefix cache with one request")
        run_warmup(command_prefix, args, json_dir)
    else:
        print("\n[1/3] Warmup skipped (--skip-warmup)")

    print("\n[2/3] Running recorded batches")
    total_failed = 0
    for concurrency in concurrencies:
        scenario_records: list[RawRecord] = []
        scenario_failed = 0
        print(f"\n  concurrency={concurrency}")
        for batch in range(1, args.batches + 1):
            outcome = run_batch(
                command_prefix,
                args,
                concurrency=concurrency,
                batch=batch,
                json_dir=json_dir,
            )
            scenario_records.extend(outcome.records)
            scenario_failed += outcome.failed
            total_failed += outcome.failed
            print(
                f"    batch {batch}/{args.batches}: "
                f"{len(outcome.records)} recorded, "
                f"{outcome.failed} failed, "
                f"{outcome.duration_seconds:.3f}s"
            )
        all_records.extend(scenario_records)
        summaries.append(summarize(concurrency, scenario_records, scenario_failed))

    print("\n[3/3] Writing CSV results")
    write_raw_csv(raw_csv_path, all_records)
    write_summary_csv(summary_csv_path, summaries)
    print_summaries(summaries)

    if not args.keep_json:
        for path in json_dir.glob("*.json"):
            path.unlink()
        json_dir.rmdir()
        print(f"Detailed JSON files removed from {json_dir}")

    print(f"\nRaw TTFT records: {raw_csv_path}")
    print(f"TTFT summary:      {summary_csv_path}")
    if total_failed:
        print(f"Warning: {total_failed} request(s) failed and were excluded.")


if __name__ == "__main__":
    main()
