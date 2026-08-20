#!/usr/bin/env python3
"""Build the compact, integrity-checked Run-all terminal-paste wrapper."""

from __future__ import annotations

import argparse
import base64
import hashlib
import os
from pathlib import Path
import sys
import textwrap
import zlib


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Run-all.payload"
TARGET = ROOT / "Run-all"


def render(source: bytes) -> bytes:
    digest = hashlib.sha256(source).hexdigest()
    encoded = base64.b85encode(zlib.compress(source, level=9)).decode("ascii")
    chunks = "\n".join(
        f"    b'{line}'" for line in textwrap.wrap(encoded, width=96)
    )
    wrapper = f"""#!/usr/bin/env bash
# Generated from Run-all.payload. Copy this complete file into Bash.
set -o pipefail
"${{PYTHON:-python3}}" - <<'PY' | bash
import base64
import hashlib
import sys
import zlib

encoded = (
{chunks}
)
payload = zlib.decompress(base64.b85decode(encoded))
expected = '{digest}'
actual = hashlib.sha256(payload).hexdigest()
if actual != expected:
    raise SystemExit(f'Run-all integrity check failed: {{actual}} != {{expected}}')
sys.stdout.buffer.write(payload)
PY
"""
    return wrapper.encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = render(SOURCE.read_bytes())
    if args.check:
        if not TARGET.is_file() or TARGET.read_bytes() != expected:
            print("Run-all is stale; rebuild it with this script", file=sys.stderr)
            return 1
        return 0
    temporary = TARGET.with_suffix(".tmp")
    temporary.write_bytes(expected)
    os.chmod(temporary, 0o755)
    temporary.replace(TARGET)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
