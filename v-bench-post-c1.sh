#!/usr/bin/env bash
"${PYTHON:-python3}" - <<'PY'
import json
import os
import shlex
import shutil
import statistics
import subprocess
import sys
import zipfile
from datetime import datetime
from pathlib import Path
from xml.sax.saxutils import escape

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


def col_name(index):
    name = ""
    while index >= 0:
        name = chr(65 + index % 26) + name
        index = index // 26 - 1
    return name


def sheet_xml(rows):
    body = []
    for row_index, row in enumerate(rows, start=1):
        cells = []
        for col_index, value in enumerate(row):
            ref = f"{col_name(col_index)}{row_index}"
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                cells.append(f'<c r="{ref}"><v>{value}</v></c>')
            else:
                cells.append(
                    f'<c r="{ref}" t="inlineStr"><is><t>{escape(str(value))}</t></is></c>'
                )
        body.append(f'<row r="{row_index}">{"".join(cells)}</row>')
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        f'<sheetData>{"".join(body)}</sheetData></worksheet>'
    )


def write_xlsx(path, sheets):
    content_types = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
        '<Default Extension="xml" ContentType="application/xml"/>',
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
    ]
    workbook_rels = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
    ]
    sheets_xml = []
    for index, (name, rows) in enumerate(sheets.items(), start=1):
        sheet_file = f"xl/worksheets/sheet{index}.xml"
        content_types.append(
            f'<Override PartName="/{sheet_file}" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        )
        workbook_rels.append(
            f'<Relationship Id="rId{index}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{index}.xml"/>'
        )
        sheets_xml.append(
            f'<sheet name="{escape(name)}" sheetId="{index}" r:id="rId{index}"/>'
        )

    styles_id = len(sheets) + 1
    content_types.append(
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    )
    workbook_rels.append(
        f'<Relationship Id="rId{styles_id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    )
    content_types.append("</Types>")
    workbook_rels.append("</Relationships>")

    workbook = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        f'<sheets>{"".join(sheets_xml)}</sheets></workbook>'
    )
    root_rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        "</Relationships>"
    )
    styles = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"/>'
    )

    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", "".join(content_types))
        archive.writestr("_rels/.rels", root_rels)
        archive.writestr("xl/workbook.xml", workbook)
        archive.writestr("xl/_rels/workbook.xml.rels", "".join(workbook_rels))
        archive.writestr("xl/styles.xml", styles)
        for index, (_, rows) in enumerate(sheets.items(), start=1):
            archive.writestr(f"xl/worksheets/sheet{index}.xml", sheet_xml(rows))


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

raw_rows = [["concurrency", "batch", "ttft_seconds"]]
raw_rows.extend([1, batch, value] for batch, value in enumerate(values, start=1))

summary_rows = [
    ["concurrency", "requests", "mean_ttft_seconds", "min_ttft_seconds", "max_ttft_seconds"],
    [1, len(values), statistics.fmean(values), min(values), max(values)],
]

result_path = run_dir / "result_c1.xlsx"
write_xlsx(result_path, {"raw": raw_rows, "summary": summary_rows})

print(f"Mean TTFT: {statistics.fmean(values):.6f}s")
print(f"Result:     {result_path}")
PY
