#!/usr/bin/env bash
"${PYTHON:-python3}" - <<'PY'
import importlib.util, json, os, shlex, shutil, statistics, subprocess, sys, urllib.request, zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from xml.sax.saxutils import escape

HOST, PORT = "127.0.0.1", 8000
MODEL = os.environ.get("VB_MODEL") or None
SERVED_MODEL_NAME = os.environ.get("VB_SERVED_MODEL_NAME") or None
TOKENIZER = os.environ.get("VB_TOKENIZER") or None
VLLM_BIN = os.environ.get("VLLM_BIN", "vllm")
OUTPUT_DIR = Path(os.environ.get("VB_OUT", "vbench-results"))
INPUT_LEN = 16 * 1024
BATCHES = int(os.environ.get("VB_BATCHES", "5"))
CONCURRENCIES = [int(x) for x in os.environ.get("VB_CONCURRENCIES", "1,5,10,100").split(",") if x.strip()]
_INPUT_TEXT = None


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


def command(v, result_dir, filename, num_prompts):
    cmd = [
        *v, "bench", "serve", "--host", HOST, "--port", str(PORT),
        "--endpoint", "/v1/completions", "--backend", "openai",
        "--dataset-name", "prefix_repetition", "--num-prompts", str(num_prompts),
        "--max-concurrency", str(num_prompts), "--request-rate", "inf",
        "--prefix-repetition-prefix-len", str(INPUT_LEN),
        "--prefix-repetition-suffix-len", "0",
        "--prefix-repetition-num-prefixes", "1",
        "--prefix-repetition-output-len", "1", "--seed", "0",
        "--disable-shuffle", "--temperature", "0", "--ignore-eos",
        "--save-result", "--save-detailed", "--result-dir", str(result_dir),
        "--result-filename", filename,
    ]
    extras = []
    if MODEL:
        extras += ["--model", MODEL]
    if SERVED_MODEL_NAME:
        extras += ["--served-model-name", SERVED_MODEL_NAME]
    if TOKENIZER:
        extras += ["--tokenizer", TOKENIZER]
    return cmd + extras


def run(cmd):
    result = subprocess.run(cmd, text=True, capture_output=True)
    if result.returncode:
        sys.exit(f"vllm failed: {shlex.join(cmd)}\n{result.stderr[-2000:]}")


def result_info(path, expected):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    ttfts = data.get("ttfts") or []
    errors = data.get("errors") or []
    values = []
    for index in range(expected):
        error = errors[index] if index < len(errors) else None
        if error:
            continue
        if index >= len(ttfts) or ttfts[index] is None:
            continue
        values.append(float(ttfts[index]))
    return values, len(values), expected - len(values)


def first_model():
    if MODEL:
        return MODEL
    try:
        data = json.loads(
            urllib.request.urlopen(f"http://{HOST}:{PORT}/v1/models", timeout=2)
            .read()
            .decode()
        )
        models = data.get("data") or []
        if models:
            return models[0].get("id")
    except Exception:
        pass
    return None


def generated_prompt():
    """Return the exact 16K prompt vLLM uses, when importable.

    vllm bench serve does not write prompt text back into its result JSON, so
    we generate the same deterministic prefix_repetition prompt here.  If vLLM
    is not importable in this interpreter we fall back to a descriptive label;
    the benchmark still runs unchanged because it invokes the vllm executable.
    """
    global _INPUT_TEXT
    if _INPUT_TEXT is not None:
        return _INPUT_TEXT
    fallback = f"prefix_repetition generated prompt (input_len={INPUT_LEN})"
    _INPUT_TEXT = fallback
    if importlib.util.find_spec("vllm") is None:
        return _INPUT_TEXT
    try:
        model_id = first_model()
        if not model_id:
            return _INPUT_TEXT
        from vllm.benchmarks.datasets import PrefixRepetitionRandomDataset
        from vllm.tokenizers import get_tokenizer

        tokenizer = get_tokenizer(model_id, trust_remote_code=True)
        dataset = PrefixRepetitionRandomDataset(random_seed=0, disable_shuffle=True)
        requests = dataset.sample(
            tokenizer=tokenizer,
            num_requests=1,
            prefix_len=INPUT_LEN,
            suffix_len=0,
            num_prefixes=1,
            output_len=1,
        )
        if requests:
            _INPUT_TEXT = requests[0].prompt
    except Exception:
        pass
    return _INPUT_TEXT


def request_details(path, expected, stage, concurrency, batch, input_text):
    """Return one row per requested index, including failures."""
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    ttfts = data.get("ttfts") or []
    errors = data.get("errors") or []
    input_lens = data.get("input_lens") or []
    output_lens = data.get("output_lens") or []
    generated_texts = data.get("generated_texts") or []
    rows = []
    for index in range(expected):
        error = errors[index] if index < len(errors) else None
        raw_ttft = ttfts[index] if index < len(ttfts) else None
        ttft = float(raw_ttft) if raw_ttft is not None else None
        success = not error and ttft is not None and ttft >= 0
        rows.append(
            [
                stage,
                concurrency,
                batch,
                index + 1,
                "success" if success else "failed",
                ttft if ttft is not None else "",
                input_lens[index] if index < len(input_lens) else "",
                output_lens[index] if index < len(output_lens) else "",
                input_text,
                generated_texts[index] if index < len(generated_texts) else "",
                error or "",
                Path(path).name,
            ]
        )
    return rows


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


CACHE_PAIRS = {
    "prefix_cache": (
        ("vllm:prefix_cache_queries_total", "vllm:prefix_cache_hits_total"),
        ("vllm:prefix_cache_queries", "vllm:prefix_cache_hits"),
    ),
    "external_prefix_cache": (
        ("vllm:external_prefix_cache_queries_total", "vllm:external_prefix_cache_hits_total"),
        ("vllm:external_prefix_cache_queries", "vllm:external_prefix_cache_hits"),
    ),
}


def cache_metrics():
    try:
        text = urllib.request.urlopen(
            f"http://{HOST}:{PORT}/metrics", timeout=2
        ).read().decode()
    except Exception:
        return {name: None for name in CACHE_PAIRS}
    result = {}
    for name, pairs in CACHE_PAIRS.items():
        result[name] = None
        for query_name, hit_name in pairs:
            queries = metric_sum(text, query_name)
            hits = metric_sum(text, hit_name)
            if queries is not None and hits is not None:
                result[name] = (queries, hits)
                break
    return result


def cache_rates(before, after):
    rates = {}
    for name in CACHE_PAIRS:
        b = before.get(name)
        a = after.get(name)
        if b is None or a is None or a[0] - b[0] <= 0:
            rates[name] = None
        else:
            rates[name] = (a[1] - b[1]) / (a[0] - b[0])
    return rates


def rate_text(value):
    return f"{value:.2%}" if value is not None else "N/A"


def print_row(stage, avg_ttft, success, rates):
    print(
        f"{stage:<16}{avg_ttft:<12}{success:<10}"
        f"{rate_text(rates['prefix_cache']):<16}"
        f"{rate_text(rates['external_prefix_cache']):<20}"
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
input_text = generated_prompt()
print(f"{'Stage':<16}{'Avg TTFT':<12}{'Success':<10}{'prefix_cache':<16}{'external_prefix_cache':<20}")
print("-" * 74)
before = cache_metrics()
run(command(vllm_bin, json_dir, "warmup.json", 1))
_, ok, failed = result_info(json_dir / "warmup.json", 1)
after = cache_metrics()
print_row("Cache warmup", "-", f"{ok}/{ok + failed}", cache_rates(before, after))
detail_rows = request_details(json_dir / "warmup.json", 1, "warmup", 1, 0, input_text)

raw_sheets = {}
summary_rows = [
    [
        "concurrency",
        "requests",
        "Success",
        "Avg TTFT",
        "min_ttft",
        "max_ttft",
        "prefix_cache",
        "external_prefix_cache",
    ]
]

for concurrency in CONCURRENCIES:
    print(f"\nConcurrency {concurrency}")
    all_values = []
    successes = []
    batch_rates = []
    batch_records = []
    for batch in range(1, BATCHES + 1):
        filename = f"concurrency-{concurrency:03d}-batch-{batch:02d}.json"
        before = cache_metrics()
        run(command(vllm_bin, json_dir, filename, concurrency))
        values, ok, failed = result_info(json_dir / filename, concurrency)
        after = cache_metrics()
        all_values.extend(values)
        successes.append((ok, failed))
        detail_rows.extend(
            request_details(
                json_dir / filename,
                concurrency,
                "benchmark",
                concurrency,
                batch,
                input_text,
            )
        )
        rates = cache_rates(before, after)
        batch_rates.append(rates)
        batch_records.append((batch, values, rates))
        avg = statistics.fmean(values) if values else 0.0
        print_row(f"Batch {batch}/{BATCHES}", f"{avg:.6f}s", f"{ok}/{ok + failed}", rates)
    if not all_values:
        sys.exit(f"concurrency {concurrency} has no successful requests")
    total_ok = sum(ok for ok, _ in successes)
    total_failed = sum(failed for _, failed in successes)
    success_text = f"{total_ok}/{total_ok + total_failed}"

    def average_rate(name):
        rates = [row[name] for row in batch_rates if row[name] is not None]
        return statistics.fmean(rates) if rates else None

    final_rates = {name: average_rate(name) for name in CACHE_PAIRS}
    print("-" * 74)
    print_row(f"Final c{concurrency}", f"{statistics.fmean(all_values):.6f}s", success_text, final_rates)

    raw_rows = [["concurrency", "batch", "request_index", "ttft", "prefix_cache", "external_prefix_cache"]]
    for batch, values, rates in batch_records:
        for index, value in enumerate(values, start=1):
            raw_rows.append(
                [
                    concurrency,
                    batch,
                    index,
                    value,
                    rate_text(rates["prefix_cache"]),
                    rate_text(rates["external_prefix_cache"]),
                ]
            )
    raw_sheets[f"c{concurrency}"] = raw_rows
    summary_rows.append(
        [
            concurrency,
            len(all_values),
            success_text,
            statistics.fmean(all_values),
            min(all_values),
            max(all_values),
            rate_text(final_rates["prefix_cache"]),
            rate_text(final_rates["external_prefix_cache"]),
        ]
    )

write_xlsx(
    run_dir / "result_batch.xlsx",
    {
        "summary": summary_rows,
        **raw_sheets,
        "request_details": [
            [
                "stage",
                "concurrency",
                "batch",
                "request_index",
                "success",
                "ttft",
                "input_tokens",
                "output_tokens",
                "input_text",
                "output_text",
                "error",
                "result_file",
            ],
            *detail_rows,
        ],
    },
)
PY
