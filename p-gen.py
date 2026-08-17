#!/usr/bin/env python3
"""Generate a Chinese prompt containing exactly 128K model tokens.

The tokenizer determines token boundaries, so the same text can have different
token counts for different models. By default this script uses Qwen3-1.7B's
tokenizer. Numbered prompts are stored as UTF-8 text in ``/root/prompts``.
"""

import argparse
import os
import sys
from pathlib import Path

TARGET_TOKEN_COUNT = 128 * 1024
DEFAULT_MODEL = "/mnt/weight/Qwen/Qwen3-1.7B"
DEFAULT_OUTPUT_DIR = Path("/root/prompts")
CHINESE_TEXT = (
    "清晨的阳光越过群山照进村庄，人们推开窗户开始新的一天。"
    "河流沿着田野缓缓前行，微风吹动树叶，也带来泥土与花草的气息。"
    "学校里传来朗朗书声，孩子们认真阅读历史、科学、文学与艺术。"
    "他们提出问题，相互讨论，用耐心和好奇心寻找可靠的答案。"
    "城市中的道路逐渐繁忙，工程师维护设备，医生照顾病人，工人制造产品。"
    "每个人都在自己的岗位上积累经验，并把知识传递给后来的人。"
    "到了傍晚，天空染上温暖的颜色，灯光依次亮起，家人围坐分享一天的见闻。"
    "夜深之后，星光安静地落在大地上，新的故事仍在记忆与想象中继续生长。"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help="Hugging Face model ID or local tokenizer directory",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help="directory for numbered prompt files (default: /root/prompts)",
    )
    return parser.parse_args()


def load_tokenizer(model: str):
    # When this file is executed directly, tools/bisect shadows Python's
    # standard-library bisect module. It breaks imports inside transformers.
    script_dir = str(Path(__file__).resolve().parent)
    sys.path = [entry for entry in sys.path if str(Path(entry or ".").resolve()) != script_dir]
    try:
        from transformers import AutoTokenizer
    except ModuleNotFoundError as error:
        raise SystemExit("transformers is required: pip install transformers") from error

    return AutoTokenizer.from_pretrained(model, trust_remote_code=True)


def build_prompt(tokenizer) -> str:
    """Build text that round-trips to exactly TARGET_TOKEN_COUNT tokens."""
    template_token_count = len(tokenizer.encode(CHINESE_TEXT, add_special_tokens=False))
    if template_token_count == 0:
        raise RuntimeError("the Chinese template produced no tokens")

    repeat_count = TARGET_TOKEN_COUNT // template_token_count + 2
    source_text = CHINESE_TEXT * repeat_count
    source_token_ids = tokenizer.encode(source_text, add_special_tokens=False, verbose=False)
    if len(source_token_ids) < TARGET_TOKEN_COUNT:
        raise RuntimeError("failed to construct enough source tokens")

    prompt = tokenizer.decode(
        source_token_ids[:TARGET_TOKEN_COUNT],
        clean_up_tokenization_spaces=False,
        skip_special_tokens=False,
    )
    verified_token_ids = tokenizer.encode(prompt, add_special_tokens=False, verbose=False)
    if len(verified_token_ids) != TARGET_TOKEN_COUNT:
        raise RuntimeError(
            "tokenizer decode/encode did not preserve the requested length: "
            f"expected {TARGET_TOKEN_COUNT}, got {len(verified_token_ids)}; no file was written"
        )
    return prompt


def is_numbered_prompt(path: Path) -> bool:
    return path.is_file() and path.suffix == ".txt" and path.stem.isdigit() and int(path.stem) > 0


def next_output_path(output_dir: Path) -> Path:
    existing_count = sum(is_numbered_prompt(path) for path in output_dir.iterdir())
    return output_dir / f"{existing_count + 1}.txt"


def main() -> None:
    # transformers may probe optional ML backends during lazy imports. The
    # prompt generator only needs tokenizers, so explicitly disable them.
    os.environ.setdefault("USE_TORCH", "0")
    os.environ.setdefault("USE_TF", "0")
    os.environ.setdefault("USE_FLAX", "0")

    args = parse_args()
    output_dir = args.output_dir.expanduser()
    tokenizer = load_tokenizer(args.model)
    prompt = build_prompt(tokenizer)

    output_dir.mkdir(parents=True, exist_ok=True)
    output_path = next_output_path(output_dir)
    with output_path.open("x", encoding="utf-8", newline="") as output_file:
        output_file.write(prompt)

    print(f"Created {output_path} ({TARGET_TOKEN_COUNT} tokens with {args.model})")


if __name__ == "__main__":
    main()
