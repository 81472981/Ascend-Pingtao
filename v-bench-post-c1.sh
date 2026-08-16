#!/usr/bin/env bash
"${PYTHON:-python3}" - <<'PY'
import json, os, shlex, shutil, statistics, subprocess, sys, urllib.request, zipfile
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


def result_info(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    ok = int(data.get("completed", 1))
    failed = int(data.get("failed", 0))
    return float(data["ttfts"][0]), ok, failed


def metric_sum(text, name):
    total = 0.0
    found = False
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0].split("{", 1)[0] == name:
            try:
                total += float(fields[1])
                found = True
            except ValueError:
                pass
    return total if found else None


TIER_PAIRS = {
    "HBM": (
        ("vllm:gpu_prefix_cache_queries_total", "vllm:gpu_prefix_cache_hits_total"),
        ("vllm:gpu_prefix_cache_queries", "vllm:gpu_prefix_cache_hits"),
    ),
    "DRAM": (
        ("vllm:cpu_prefix_cache_queries_total", "vllm:cpu_prefix_cache_hits_total"),
        ("vllm:cpu_prefix_cache_queries", "vllm:cpu_prefix_cache_hits"),
    ),
    "SSD": (
        ("vllm:disk_prefix_cache_queries_total", "vllm:disk_prefix_cache_hits_total"),
        ("vllm:disk_prefix_cache_queries", "vllm:disk_prefix_cache_hits"),
    ),
}


def tier_metrics():
    try:
        text = urllib.request.urlopen(
            f"http://{HOST}:{PORT}/metrics", timeout=2
        ).read().decode()
    except Exception:
        return {tier: None for tier in TIER_PAIRS}
    result = {}
    for tier, pairs in TIER_PAIRS.items():
        result[tier] = None
        for query_name, hit_name in pairs:
            queries = metric_sum(text, query_name)
            hits = metric_sum(text, hit_name)
            if queries is not None and hits is not None:
                result[tier] = (queries, hits)
                break
    return result


def tier_rates(before, after):
    rates = {}
    for tier in TIER_PAIRS:
        b = before.get(tier)
        a = after.get(tier)
        if b is None or a is None or a[0] - b[0] <= 0:
            rates[tier] = None
        else:
            rates[tier] = (a[1] - b[1]) / (a[0] - b[0])
    return rates


def rate_text(value):
    return f"{value:.2%}" if value is not None else "N/A"


def print_row(stage, avg_ttft, success, rates):
    print(
        f"{stage:<16}{avg_ttft:<12}{success:<10}"
        f"{rate_text(rates['HBM']):<10}{rate_text(rates['DRAM']):<10}"
        f"{rate_text(rates['SSD']):<10}"
    )


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


run_dir = OUTPUT_DIR / datetime.now(timezone(timedelta(hours=8))).strftime("%Y%m%d-%H%M%S")
json_dir = run_dir / "json"
json_dir.mkdir(parents=True, exist_ok=True)
vllm_bin = vllm()
print(f"{'Stage':<16}{'Avg TTFT':<12}{'Success':<10}{'HBM':<10}{'DRAM':<10}{'SSD':<10}")
print("-" * 68)
before = tier_metrics()
run(command(vllm_bin, json_dir, "warmup.json"))
_, ok, failed = result_info(json_dir / "warmup.json")
after = tier_metrics()
print_row("Cache warmup", "-", f"{ok}/{ok + failed}", tier_rates(before, after))
values = []
successes = []
batch_rates = []
for batch in range(1, BATCHES + 1):
    filename = f"concurrency-001-batch-{batch:02d}.json"
    before = tier_metrics()
    run(command(vllm_bin, json_dir, filename))
    value, ok, failed = result_info(json_dir / filename)
    after = tier_metrics()
    values.append(value)
    successes.append((ok, failed))
    rates = tier_rates(before, after)
    batch_rates.append(rates)
    print_row(f"Batch {batch}/{BATCHES}", f"{value:.6f}s", f"{ok}/{ok + failed}", rates)
total_ok = sum(ok for ok, _ in successes)
total_failed = sum(failed for _, failed in successes)
success_text = f"{total_ok}/{total_ok + total_failed}"


def average_rate(tier):
    rates = [row[tier] for row in batch_rates if row[tier] is not None]
    return statistics.fmean(rates) if rates else None


final_rates = {tier: average_rate(tier) for tier in TIER_PAIRS}
print("-" * 68)
print_row("Final", f"{statistics.fmean(values):.6f}s", success_text, final_rates)
raw_rows = [["concurrency", "batch", "ttft_seconds"]]
raw_rows.extend([1, batch, value] for batch, value in enumerate(values, start=1))
summary_rows = [
    [
        "concurrency",
        "requests",
        "Success",
        "Avg TTFT",
        "min_ttft_seconds",
        "max_ttft_seconds",
        "Prefix hit rate-HBM",
        "Prefix hit rate-DRAM",
        "Prefix hit rate-SSD",
    ],
    [
        1,
        len(values),
        success_text,
        statistics.fmean(values),
        min(values),
        max(values),
        rate_text(final_rates["HBM"]),
        rate_text(final_rates["DRAM"]),
        rate_text(final_rates["SSD"]),
    ],
]
write_xlsx(run_dir / "result_c1.xlsx", {"raw": raw_rows, "summary": summary_rows})
PY
