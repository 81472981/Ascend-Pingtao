from __future__ import annotations

import hashlib
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "03-DRAM-PrefixCache" / "C5"
RUN_ALL = REPO_ROOT / "03-DRAM-PrefixCache" / "Run-all"
FAKE_VLLM = REPO_ROOT / "tests" / "fake_vllm.py"

try:
    import openpyxl
except ImportError:  # The production scripts intentionally need only stdlib.
    openpyxl = None


class FakeState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.local_queries = 0
        self.local_hits = 0
        self.external_queries = 0
        self.external_hits = 0
        self.keys = 0


class DramHandler(http.server.BaseHTTPRequestHandler):
    state: FakeState

    def log_message(self, fmt, *args):
        pass

    def send_bytes(self, body: bytes, content_type="application/json") -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/v1/models":
            body = json.dumps(
                {"data": [{"id": "fake-model", "root": "fake-model"}]}
            ).encode()
            self.send_bytes(body)
            return
        if path == "/metrics":
            with self.state.lock:
                text = (
                    f"vllm:prefix_cache_queries_total {self.state.local_queries}\n"
                    f"vllm:prefix_cache_hits_total {self.state.local_hits}\n"
                    "vllm:external_prefix_cache_queries_total "
                    f"{self.state.external_queries}\n"
                    "vllm:external_prefix_cache_hits_total "
                    f"{self.state.external_hits}\n"
                )
            self.send_bytes(text.encode(), "text/plain")
            return
        if path == "/metrics/summary":
            with self.state.lock:
                text = f"Mem Storage: fake | Keys: {self.state.keys}"
            self.send_bytes(text.encode(), "text/plain")
            return
        self.send_error(404)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""
        if path == "/reset_prefix_cache":
            self.send_bytes(b"true", "text/plain")
            return
        if path == "/tokenize":
            prompt = json.loads(body)["prompt"]
            words = prompt.split(" ")
            prefix = int(hashlib.sha256(words[0].encode()).hexdigest()[:8], 16)
            tokens = [prefix ^ index for index in range(len(words))]
            self.send_bytes(json.dumps({"tokens": tokens}).encode())
            return
        if path == "/v1/completions":
            request_id = self.headers.get("x-request-id", "")
            prompt_tokens = 16 * 1024
            cacheable_tokens = prompt_tokens - 128
            with self.state.lock:
                self.state.local_queries += prompt_tokens
                self.state.external_queries += prompt_tokens
                if "-r1-" in request_id:
                    self.state.keys += 1
                elif "-r2-" in request_id:
                    self.state.local_hits += cacheable_tokens
                    self.state.external_hits += cacheable_tokens
                elif "-r3-" in request_id:
                    self.state.external_hits += cacheable_tokens
            self.send_bytes(b'{"choices":[{"text":"x"}]}')
            return
        self.send_error(404)


class DramPrefixCacheTest(unittest.TestCase):
    def test_c5_interleaves_stages_and_writes_one_workbook(self) -> None:
        state = FakeState()
        DramHandler.state = state
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DramHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                config = root / "mooncake.json"
                config.write_text(
                    json.dumps({"enable_ssd_offload": False}), encoding="utf-8"
                )
                env = os.environ.copy()
                env.update(
                    {
                        "VLLM_BIN": f"{sys.executable} {FAKE_VLLM}",
                        "FAKE_VLLM_SEND_REQUESTS": "1",
                        "FAKE_VLLM_OMIT_REQUEST_ID": "1",
                        "VB_PORT": str(server.server_address[1]),
                        "VB_MOONCAKE_METRICS_URL": (
                            f"http://127.0.0.1:{server.server_address[1]}"
                            "/metrics/summary"
                        ),
                        "MOONCAKE_CONFIG_PATH": str(config),
                        "VB_RUN_DIR": str(root / "results"),
                        "VB_BATCHES": "2",
                        "VB_EXPECT_CONCURRENCIES": "5",
                        "VB_STORE_STABLE_SECONDS": "0",
                        "VB_STORE_TIMEOUT_SECONDS": "5",
                    }
                )
                completed = subprocess.run(
                    ["bash", "-s"],
                    input=SCRIPT.read_text(encoding="utf-8"),
                    text=True,
                    capture_output=True,
                    check=False,
                    env=env,
                    cwd=REPO_ROOT,
                    timeout=60,
                )
                self.assertEqual(
                    completed.returncode,
                    0,
                    msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
                )

                result_dir = root / "results"
                manifest = json.loads(
                    (result_dir / "p1-manifest.json").read_text(encoding="utf-8")
                )
                requests = list(manifest["requests"].values())
                self.assertEqual(len(requests), 10)
                self.assertEqual(len({row["prompt_sha256"] for row in requests}), 10)
                self.assertEqual(
                    len({row["first_block_sha256"] for row in requests}), 10
                )

                payload = json.loads(
                    (result_dir / "C5-result.json").read_text(encoding="utf-8")
                )
                for stage in ("R1-warmup", "R2-hbm-cache", "R3-dram-cache"):
                    stage_summary = payload["stage_summary"][stage]
                    self.assertEqual(stage_summary["successful_requests"], 10)
                    self.assertEqual(stage_summary["success_rate_percent"], 100)
                    self.assertEqual(stage_summary["ttft_samples"], 10)
                r1_hashes = [row[9] for row in payload["stage_rows"]["R1-warmup"]]
                r2_hashes = [row[9] for row in payload["stage_rows"]["R2-hbm-cache"]]
                r3_hashes = [row[9] for row in payload["stage_rows"]["R3-dram-cache"]]
                self.assertEqual(r1_hashes, r2_hashes)
                self.assertEqual(r1_hashes, r3_hashes)

                workbook = result_dir / "dram-cache-benchmark.xlsx"
                with zipfile.ZipFile(workbook) as archive:
                    self.assertIsNone(archive.testzip())
                    names = archive.read("xl/workbook.xml").decode()
                    for sheet in (
                        "summary",
                        "TTFT-analysis",
                        "R1-warmup",
                        "R2-hbm-cache",
                        "R3-dram-cache",
                        "validation",
                        "P1-manifest",
                    ):
                        self.assertIn(f'name="{sheet}"', names)
                if openpyxl is not None:
                    loaded = openpyxl.load_workbook(workbook, read_only=True)
                    self.assertEqual(
                        loaded.sheetnames,
                        [
                            "summary",
                            "TTFT-analysis",
                            "R1-warmup",
                            "R2-hbm-cache",
                            "R3-dram-cache",
                            "validation",
                            "P1-manifest",
                        ],
                    )
                    summary_headers = [
                        cell.value
                        for cell in next(loaded["summary"].iter_rows(max_row=1))
                    ]
                    self.assertEqual(
                        summary_headers,
                        [
                            "stage",
                            "concurrency",
                            "successful_requests",
                            "total_requests",
                            "success_rate_percent",
                            "ttft_samples",
                            "avg_ttft_seconds",
                            "min_ttft_seconds",
                            "max_ttft_seconds",
                        ],
                    )
                    analysis_headers = [
                        cell.value
                        for cell in next(
                            loaded["TTFT-analysis"].iter_rows(max_row=1)
                        )
                    ]
                    self.assertEqual(
                        analysis_headers,
                        [
                            "concurrency",
                            "R1_avg_ttft_seconds",
                            "R1_success_rate_percent",
                            "R2_avg_ttft_seconds",
                            "R2_success_rate_percent",
                            "R3_avg_ttft_seconds",
                            "R3_success_rate_percent",
                            "R2_vs_R1_change_percent",
                            "R3_vs_R2_change_percent",
                            "R3_vs_R1_change_percent",
                        ],
                    )
                    forbidden = ("sha", "identity", "validation", "cache")
                    self.assertFalse(
                        any(
                            marker in str(header).lower()
                            for header in summary_headers + analysis_headers
                            for marker in forbidden
                        )
                    )
                    loaded.close()
        finally:
            server.shutdown()
            server.server_close()

    def test_run_all_merges_c1_c5_c10_in_one_session(self) -> None:
        state = FakeState()
        DramHandler.state = state
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DramHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                config = root / "mooncake.json"
                config.write_text(
                    json.dumps({"enable_ssd_offload": False}), encoding="utf-8"
                )
                env = os.environ.copy()
                env.pop("VB_RUN_DIR", None)
                env.update(
                    {
                        "VLLM_BIN": f"{sys.executable} {FAKE_VLLM}",
                        "FAKE_VLLM_SEND_REQUESTS": "1",
                        "VB_PORT": str(server.server_address[1]),
                        "VB_MOONCAKE_METRICS_URL": (
                            f"http://127.0.0.1:{server.server_address[1]}"
                            "/metrics/summary"
                        ),
                        "MOONCAKE_CONFIG_PATH": str(config),
                        "VB_BATCHES": "1",
                        "VB_STORE_STABLE_SECONDS": "0",
                        "VB_STORE_TIMEOUT_SECONDS": "5",
                    }
                )
                run_all_text = RUN_ALL.read_text(encoding="utf-8")
                c1_text = (RUN_ALL.parent / "C1").read_text(encoding="utf-8")
                run_all_body = run_all_text.split("<<'PY'\n", 1)[1].rsplit(
                    "\nPY", 1
                )[0]
                c1_body = c1_text.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
                self.assertEqual(run_all_body, c1_body)
                self.assertLess(len(run_all_text.encode("utf-8")), 64 * 1024)
                self.assertLessEqual(
                    max(len(line.encode("utf-8")) for line in run_all_text.splitlines()),
                    1024,
                )
                completed = subprocess.run(
                    ["bash", "-s"],
                    input=run_all_text,
                    text=True,
                    capture_output=True,
                    check=False,
                    env=env,
                    cwd=root,
                    timeout=120,
                )
                self.assertEqual(
                    completed.returncode,
                    0,
                    msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
                )

                result_roots = list((root / "vb-result").iterdir())
                self.assertEqual(len(result_roots), 1)
                self.assertRegex(
                    result_roots[0].name,
                    r"^\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}(?:-\d{2})?$",
                )
                result_dir = result_roots[0]
                self.assertEqual(
                    {path.name for path in result_dir.glob("C*-result.json")},
                    {"C1-result.json", "C5-result.json", "C10-result.json"},
                )
                session = json.loads(
                    (result_dir / "session.json").read_text(encoding="utf-8")
                )
                self.assertEqual(session["completed_concurrencies"], [1, 5, 10])

                manifest = json.loads(
                    (result_dir / "p1-manifest.json").read_text(encoding="utf-8")
                )
                requests = list(manifest["requests"].values())
                self.assertEqual(len(requests), 16)
                self.assertEqual(len({row["prompt_sha256"] for row in requests}), 16)
                self.assertEqual(
                    len({row["first_block_sha256"] for row in requests}), 16
                )

                workbook = result_dir / "dram-cache-benchmark.xlsx"
                with zipfile.ZipFile(workbook) as archive:
                    self.assertIsNone(archive.testzip())
                    names = archive.read("xl/workbook.xml").decode()
                    self.assertEqual(names.count("<sheet "), 7)
                if openpyxl is not None:
                    loaded = openpyxl.load_workbook(workbook, read_only=True)
                    analysis = loaded["TTFT-analysis"]
                    self.assertEqual(analysis.max_row, 4)
                    self.assertEqual(
                        [analysis.cell(row=row, column=1).value for row in range(2, 5)],
                        [1, 5, 10],
                    )
                    loaded.close()
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
