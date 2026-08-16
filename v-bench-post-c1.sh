#!/usr/bin/env bash
"${PYTHON:-python3}" - <<'PY'
import json, os, shlex, shutil, statistics, subprocess, sys, zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from xml.sax.saxutils import escape

HOST, PORT, MODEL = "127.0.0.1", 8000, None
VLLM_BIN = os.environ.get("VLLM_BIN", "vllm")
OUTPUT_DIR = Path(os.environ.get("VB_OUT", "vbench-results"))
INPUT_LEN, BATCHES = 16 * 1024, 5


def vllm():
    parts = shlex.split(VLLM_BIN)
    exe = parts[0]
    if os.path.dirname(exe) and not os.path.isfile(exe):
        sys.exit(f"vllm not found: {exe}")
    if not os.path.dirname(exe) and shutil.which(exe) is None:
        exe = str((Path(".venv/bin") / exe).resolve())
        if not os.path.isfile(exe):
            sys.exit(f"vllm not found: {parts[0]}")
        parts[0] = exe
    return parts


def command(v, result_dir, filename):
    cmd = [
        *v, "bench", "serve", "--host", HOST, "--port", str(PORT),
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
    return cmd + (["--model", MODEL] if MODEL else [])


def run(cmd):
    result = subprocess.run(cmd, text=True, capture_output=True)
    if result.returncode:
        sys.exit(f"vllm failed: {shlex.join(cmd)}\n{result.stderr[-2000:]}")


def ttft(path):
    return float(json.loads(Path(path).read_text(encoding="utf-8"))["ttfts"][0])


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
                cells.append(f'<c r="{ref}" t="inlineStr"><is><t>{escape(str(value))}</t></is></c>')
        body.append(f'<row r="{row_index}">{"".join(cells)}</row>')
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>' + ''.join(body) + '</sheetData></worksheet>'


def write_xlsx(path, sheets):
    ct = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    sx = ""
    for index, (name, rows) in enumerate(sheets.items(), start=1):
        ct += f'<Override PartName="/xl/worksheets/sheet{index}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        rels += f'<Relationship Id="rId{index}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{index}.xml"/>'
        sx += f'<sheet name="{escape(name)}" sheetId="{index}" r:id="rId{index}"/>'
    sid = len(sheets) + 1
    ct += '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>'
    rels += f'<Relationship Id="rId{sid}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
    wb = f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>{sx}</sheets></workbook>'
    root = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
    styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"/>'
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", ct)
        z.writestr("_rels/.rels", root)
        z.writestr("xl/workbook.xml", wb)
        z.writestr("xl/_rels/workbook.xml.rels", rels)
        z.writestr("xl/styles.xml", styles)
        for index, (_, rows) in enumerate(sheets.items(), start=1):
            z.writestr(f"xl/worksheets/sheet{index}.xml", sheet_xml(rows))


run_dir = OUTPUT_DIR / datetime.now(timezone(timedelta(hours=8))).strftime("%H%M%S")
json_dir = run_dir / "json"
json_dir.mkdir(parents=True, exist_ok=True)
vllm_bin = vllm()
print("Cache warmup request")
run(command(vllm_bin, json_dir, "warmup.json"))
ttft(json_dir / "warmup.json")
values = []
for batch in range(1, BATCHES + 1):
    filename = f"concurrency-001-batch-{batch:02d}.json"
    run(command(vllm_bin, json_dir, filename))
    value = ttft(json_dir / filename)
    values.append(value)
    print(f"  Batch {batch}/{BATCHES}: Avg TTFT={value:.6f}s")
raw_rows = [["concurrency", "batch", "ttft_seconds"]]
raw_rows.extend([1, batch, value] for batch, value in enumerate(values, start=1))
summary_rows = [
    ["concurrency", "requests", "Avg TTFT", "min_ttft_seconds", "max_ttft_seconds"],
    [1, len(values), statistics.fmean(values), min(values), max(values)],
]
write_xlsx(run_dir / "result_c1.xlsx", {"raw": raw_rows, "summary": summary_rows})
print(f"Final Avg TTFT: {statistics.fmean(values):.6f}s")
PY
