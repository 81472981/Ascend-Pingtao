#!/usr/bin/env python3
"""Send concurrent requests to a local OpenAI-compatible LLM server."""

import argparse
import importlib.util
import statistics
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Any

DEFAULT_CONCURRENCY = 10


@dataclass(frozen=True)
class RequestResult:
    request_id: int
    ttft_seconds: float | None
    latency_seconds: float
    prompt_tokens: int | None
    completion_tokens: int | None
    total_tokens: int | None


def load_sender_module() -> ModuleType:
    """Load the adjacent p-send.py module despite the hyphen in its name."""
    sender_path = Path(__file__).resolve().with_name("p-send.py")
    spec = importlib.util.spec_from_file_location("p_send", sender_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load sender module: {sender_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def parse_args(sender: ModuleType) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-c",
        "--concurrency",
        type=int,
        default=DEFAULT_CONCURRENCY,
        help="number of requests sent concurrently (default: %(default)s)",
    )
    parser.add_argument("--prompt-file", type=Path, default=sender.DEFAULT_PROMPT_PATH)
    parser.add_argument("--url", default=sender.DEFAULT_URL)
    parser.add_argument("--metrics-url", default=sender.DEFAULT_METRICS_URL)
    parser.add_argument("--model", default=sender.DEFAULT_MODEL)
    parser.add_argument("--max-tokens", type=int, default=16)
    parser.add_argument("--timeout", type=float, default=1800.0)
    parser.add_argument("--metrics-timeout", type=float, default=10.0)
    return parser.parse_args()


def usage_value(usage: dict[str, Any] | None, key: str) -> int | None:
    if usage is None:
        return None
    value = usage.get(key)
    return value if isinstance(value, int) else None


def send_one(
    sender: ModuleType,
    barrier: threading.Barrier,
    request_id: int,
    args: argparse.Namespace,
    prompt: str,
) -> RequestResult:
    """Wait for all workers and then send one streaming request."""
    barrier.wait()
    result = sender.send_completion(args.url, args.model, prompt, args.max_tokens, args.timeout)
    return RequestResult(
        request_id=request_id,
        ttft_seconds=result.ttft_seconds,
        latency_seconds=result.latency_seconds,
        prompt_tokens=usage_value(result.usage, "prompt_tokens"),
        completion_tokens=usage_value(result.usage, "completion_tokens"),
        total_tokens=usage_value(result.usage, "total_tokens"),
    )


def average(values: list[int | float | None]) -> float | None:
    available_values = [float(value) for value in values if value is not None]
    return statistics.fmean(available_values) if available_values else None


def format_average(value: float | None, unit: str = "") -> str:
    if value is None:
        return "unavailable"
    return f"{value:.3f}{unit}"


def print_cache_summary(
    before: tuple[float, float] | None,
    after: tuple[float, float] | None,
) -> None:
    if before is None or after is None:
        print("Batch prefix cache: unavailable")
        return

    queried_tokens = after[0] - before[0]
    hit_tokens = after[1] - before[1]
    if queried_tokens < 0 or hit_tokens < 0:
        print("Batch prefix cache: unavailable (metrics counters were reset)")
    elif queried_tokens == 0:
        print("Batch prefix cache: hit=0, queried=0, rate=N/A")
    else:
        print(
            "Batch prefix cache: "
            f"hit={hit_tokens:.0f}, queried={queried_tokens:.0f}, "
            f"rate={hit_tokens / queried_tokens:.2%}"
        )


def print_summary(
    concurrency: int,
    results: list[RequestResult],
    failures: list[tuple[int, BaseException]],
    batch_latency_seconds: float,
    metrics_before: tuple[float, float] | None,
    metrics_after: tuple[float, float] | None,
) -> None:
    ttft_values = [result.ttft_seconds for result in results]
    print(f"Requests: total={concurrency}, succeeded={len(results)}, failed={len(failures)}")
    print(f"Average TTFT: {format_average(average(ttft_values), ' s')}")
    print(f"Average E2E time: {format_average(average([result.latency_seconds for result in results]), ' s')}")
    print(f"Batch E2E time: {batch_latency_seconds:.3f} s")
    print(f"Average prompt tokens: {format_average(average([result.prompt_tokens for result in results]))}")
    print(f"Average completion tokens: {format_average(average([result.completion_tokens for result in results]))}")
    print(f"Average total tokens: {format_average(average([result.total_tokens for result in results]))}")
    print_cache_summary(metrics_before, metrics_after)
    if failures:
        print("Failures:")
        for request_id, error in sorted(failures):
            print(f"  request {request_id}: {error}")


def main() -> None:
    sender = load_sender_module()
    args = parse_args(sender)
    if args.concurrency <= 0:
        raise SystemExit("concurrency must be greater than zero")
    if args.max_tokens <= 0:
        raise SystemExit("--max-tokens must be greater than zero")
    if args.timeout <= 0:
        raise SystemExit("--timeout must be greater than zero")
    if args.metrics_timeout <= 0:
        raise SystemExit("--metrics-timeout must be greater than zero")

    prompt = sender.load_prompt(args.prompt_file.expanduser())
    metrics_before = sender.read_prefix_cache_metrics(args.metrics_url, args.metrics_timeout)
    barrier = threading.Barrier(args.concurrency + 1)
    results: list[RequestResult] = []
    failures: list[tuple[int, BaseException]] = []

    with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = {
            executor.submit(send_one, sender, barrier, request_id, args, prompt): request_id
            for request_id in range(1, args.concurrency + 1)
        }
        batch_started_at = time.perf_counter()
        barrier.wait()
        for future in as_completed(futures):
            request_id = futures[future]
            try:
                results.append(future.result())
            except BaseException as error:
                failures.append((request_id, error))
        batch_latency_seconds = time.perf_counter() - batch_started_at

    metrics_after = sender.read_prefix_cache_metrics(args.metrics_url, args.metrics_timeout)
    print_summary(
        args.concurrency,
        results,
        failures,
        batch_latency_seconds,
        metrics_before,
        metrics_after,
    )
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
