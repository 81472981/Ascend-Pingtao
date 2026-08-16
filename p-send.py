#!/usr/bin/env python3
"""Send /root/prompts/1.txt to a local OpenAI-compatible LLM server."""

import argparse
import json
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_PROMPT_PATH = Path("/root/prompts/1.txt")
DEFAULT_URL = "http://127.0.0.1:8000/v1/completions"
DEFAULT_METRICS_URL = "http://127.0.0.1:8000/metrics"
DEFAULT_MODEL = "Qwen3-1.7B"

PREFIX_CACHE_METRIC_PAIRS = (
    ("vllm:prefix_cache_queries_total", "vllm:prefix_cache_hits_total"),
    ("vllm:gpu_prefix_cache_queries_total", "vllm:gpu_prefix_cache_hits_total"),
)


@dataclass(frozen=True)
class CompletionResult:
    text: str
    usage: dict[str, Any] | None
    ttft_seconds: float | None
    latency_seconds: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prompt-file", type=Path, default=DEFAULT_PROMPT_PATH)
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--metrics-url", default=DEFAULT_METRICS_URL)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--max-tokens", type=int, default=16)
    parser.add_argument("--timeout", type=float, default=1800.0)
    parser.add_argument("--metrics-timeout", type=float, default=10.0)
    return parser.parse_args()


def load_prompt(path: Path) -> str:
    prompt_path = path.expanduser()
    if not prompt_path.is_file():
        raise FileNotFoundError(f"prompt file does not exist: {prompt_path}")

    prompt = prompt_path.read_text(encoding="utf-8")
    if not prompt:
        raise ValueError(f"prompt file is empty: {prompt_path}")
    return prompt


def send_completion(url: str, model: str, prompt: str, max_tokens: int, timeout: float) -> CompletionResult:
    """Stream one completion and measure time to its first generated token."""
    payload = json.dumps(
        {
            "model": model,
            "prompt": prompt,
            "max_tokens": max_tokens,
            "temperature": 0,
            "stream": True,
            "stream_options": {"include_usage": True},
        },
        ensure_ascii=False,
    ).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )

    started_at = time.perf_counter()
    text_parts: list[str] = []
    usage: dict[str, Any] | None = None
    ttft_seconds: float | None = None

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            for raw_line in response:
                chunk_received_at = time.perf_counter()
                line = raw_line.decode("utf-8").strip()
                if not line.startswith("data:"):
                    continue

                event_data = line.removeprefix("data:").strip()
                if event_data == "[DONE]":
                    break

                try:
                    chunk = json.loads(event_data)
                except json.JSONDecodeError as error:
                    raise RuntimeError(f"server returned invalid stream JSON: {event_data[:1000]}") from error

                if not isinstance(chunk, dict):
                    raise RuntimeError("server returned a non-object stream chunk")
                if "error" in chunk:
                    raise RuntimeError(f"server returned a streaming error: {chunk['error']}")

                chunk_usage = chunk.get("usage")
                if isinstance(chunk_usage, dict):
                    usage = chunk_usage

                choices = chunk.get("choices")
                if not isinstance(choices, list) or not choices:
                    continue
                first_choice = choices[0]
                if not isinstance(first_choice, dict):
                    continue
                text = first_choice.get("text")
                if not isinstance(text, str) or not text:
                    continue

                if ttft_seconds is None:
                    ttft_seconds = chunk_received_at - started_at
                text_parts.append(text)
    except urllib.error.HTTPError as error:
        error_body = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"server returned HTTP {error.code}: {error_body}") from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"failed to connect to {url}: {error.reason}") from error

    return CompletionResult(
        text="".join(text_parts),
        usage=usage,
        ttft_seconds=ttft_seconds,
        latency_seconds=time.perf_counter() - started_at,
    )


def _sum_prometheus_metric(metrics_text: str, metric_name: str) -> float | None:
    """Sum all labelled series for one Prometheus counter."""
    total = 0.0
    found = False
    for raw_line in metrics_text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 2:
            continue
        sample_name = fields[0].split("{", maxsplit=1)[0]
        if sample_name != metric_name:
            continue
        try:
            total += float(fields[1])
        except ValueError:
            continue
        found = True
    return total if found else None


def read_prefix_cache_metrics(url: str, timeout: float) -> tuple[float, float] | None:
    """Read cumulative queried-token and hit-token counters from vLLM."""
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            metrics_text = response.read().decode("utf-8", errors="replace")
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        return None

    for query_name, hit_name in PREFIX_CACHE_METRIC_PAIRS:
        queries = _sum_prometheus_metric(metrics_text, query_name)
        hits = _sum_prometheus_metric(metrics_text, hit_name)
        if queries is not None and hits is not None:
            return queries, hits

    return None


def print_cache_delta(
    before: tuple[float, float] | None,
    after: tuple[float, float] | None,
) -> None:
    if before is None or after is None:
        print("Prefix cache: unavailable")
        return

    queried_tokens = after[0] - before[0]
    hit_tokens = after[1] - before[1]
    if queried_tokens < 0 or hit_tokens < 0:
        print("Prefix cache: unavailable (metrics counters were reset)")
        return

    if queried_tokens:
        print(
            f"Prefix cache: hit={hit_tokens:.0f}, queried={queried_tokens:.0f}, rate={hit_tokens / queried_tokens:.2%}"
        )
    else:
        print("Prefix cache: hit=0, queried=0, rate=N/A")


def print_result(
    result: CompletionResult,
    metrics_before: tuple[float, float] | None,
    metrics_after: tuple[float, float] | None,
) -> None:
    """Print TTFT first, followed by the other key metrics and response text."""
    if result.ttft_seconds is None:
        print("TTFT: unavailable (no generated token)")
    else:
        print(f"TTFT: {result.ttft_seconds:.3f} s")
    print(f"E2E time: {result.latency_seconds:.3f} s")
    if result.usage is not None:
        print(
            "Tokens: "
            f"prompt={result.usage.get('prompt_tokens', 'N/A')}, "
            f"completion={result.usage.get('completion_tokens', 'N/A')}, "
            f"total={result.usage.get('total_tokens', 'N/A')}"
        )
    else:
        print("Tokens: unavailable")
    print_cache_delta(metrics_before, metrics_after)
    print("LLM response:")
    print(result.text)


def main() -> None:
    args = parse_args()
    if args.max_tokens <= 0:
        raise SystemExit("--max-tokens must be greater than zero")
    if args.timeout <= 0:
        raise SystemExit("--timeout must be greater than zero")
    if args.metrics_timeout <= 0:
        raise SystemExit("--metrics-timeout must be greater than zero")

    prompt_path = args.prompt_file.expanduser()
    prompt = load_prompt(prompt_path)

    metrics_before = read_prefix_cache_metrics(args.metrics_url, args.metrics_timeout)
    result = send_completion(args.url, args.model, prompt, args.max_tokens, args.timeout)

    metrics_after = read_prefix_cache_metrics(args.metrics_url, args.metrics_timeout)
    print_result(result, metrics_before, metrics_after)


if __name__ == "__main__":
    main()
