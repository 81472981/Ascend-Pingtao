#!/usr/bin/env python3
"""Tiny fake ``vllm bench serve`` used by the v-bench-post test suite.

It does not contact a real server.  It validates the command shape that
v-bench-post relies on and writes a detailed result JSON in the same layout
that vllm bench serve writes when using ``--save-result --save-detailed``.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def arg_value(args: list[str], name: str) -> str:
    if name not in args:
        raise SystemExit(f"missing expected argument: {name}")
    index = args.index(name)
    if index + 1 >= len(args):
        raise SystemExit(f"missing value for argument: {name}")
    return args[index + 1]


def main() -> None:
    argv = sys.argv[1:]
    if argv[:2] != ["bench", "serve"]:
        raise SystemExit("fake vllm expects 'bench serve' as the first arguments")
    args = argv[2:]

    expected_flags = {
        "--save-result": True,
        "--save-detailed": True,
        "--ignore-eos": True,
        "--disable-shuffle": True,
    }
    for flag, expected in expected_flags.items():
        if (flag in args) != expected:
            raise SystemExit(f"unexpected {flag} presence")

    dataset_name = arg_value(args, "--dataset-name")
    if dataset_name != "prefix_repetition":
        raise SystemExit(f"unexpected dataset-name: {dataset_name}")
    if arg_value(args, "--prefix-repetition-suffix-len") != "0":
        raise SystemExit("suffix length must be 0 for completely identical prompts")
    if arg_value(args, "--prefix-repetition-num-prefixes") != "1":
        raise SystemExit("num-prefixes must be 1 for completely identical prompts")
    if int(arg_value(args, "--prefix-repetition-prefix-len")) != 16 * 1024:
        raise SystemExit("prefix length must be 16384")

    num_prompts = int(arg_value(args, "--num-prompts"))
    if arg_value(args, "--max-concurrency") != str(num_prompts):
        raise SystemExit("max-concurrency must match num-prompts")
    if arg_value(args, "--request-rate") != "inf":
        raise SystemExit("request-rate must be inf")

    result_dir = Path(arg_value(args, "--result-dir"))
    result_filename = arg_value(args, "--result-filename")
    result_dir.mkdir(parents=True, exist_ok=True)

    batch_number = 0 if result_filename == "warmup.json" else 1
    if "batch-" in result_filename:
        try:
            batch_number = int(result_filename.rsplit("-batch-", maxsplit=1)[1].split(".")[0])
        except ValueError:
            pass

    # Deterministic, easy-to-check TTFT values.  The tiny formula makes the
    # test able to calculate the exact expected mean for every concurrency.
    ttfts = [
        0.010 + batch_number * 0.001 + index * 0.0001
        for index in range(num_prompts)
    ]
    result = {
        "date": "20260816-000000",
        "backend": "openai",
        "model_id": "fake-model",
        "num_prompts": num_prompts,
        "request_rate": "inf",
        "max_concurrency": num_prompts,
        "completed": num_prompts,
        "failed": 0,
        "total_input_tokens": num_prompts * 16384,
        "total_output_tokens": num_prompts,
        "input_lens": [16384] * num_prompts,
        "output_lens": [1] * num_prompts,
        "ttfts": ttfts,
        "itls": [[0.001]] * num_prompts,
        "errors": [""] * num_prompts,
    }

    output_path = result_dir / result_filename
    output_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"fake vllm wrote {output_path}")


if __name__ == "__main__":
    main()
