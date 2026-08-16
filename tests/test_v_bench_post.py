from __future__ import annotations

import csv
import importlib.util
from importlib.machinery import SourceFileLoader
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "v-bench-post.py"
C1_SHELL_SCRIPT = REPO_ROOT / "v-bench-post-c1.sh"
FAKE_VLLM = REPO_ROOT / "tests" / "fake_vllm.py"


def load_script_module():
    spec = importlib.util.spec_from_file_location(
        "v_bench_post",
        SCRIPT,
        loader=SourceFileLoader("v_bench_post", str(SCRIPT)),
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load script: {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class VBencPostTest(unittest.TestCase):
    def run_script(self, output_dir: Path, *extra_args: str) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(SCRIPT),
            "--vllm-bin",
            f"{sys.executable} {FAKE_VLLM}",
            "--output-dir",
            str(output_dir),
            *extra_args,
        ]
        return subprocess.run(
            command,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_end_to_end_with_fake_vllm(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir) / "results"
            completed = self.run_script(
                output_dir,
                "--concurrencies",
                "1,5",
                "--batches",
                "3",
            )
            self.assertEqual(
                completed.returncode,
                0,
                msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
            )

            run_dirs = list(output_dir.iterdir())
            self.assertEqual(len(run_dirs), 1)
            run_dir = run_dirs[0]
            self.assertTrue((run_dir / "raw_ttft.csv").is_file())
            self.assertTrue((run_dir / "summary_ttft.csv").is_file())
            self.assertTrue((run_dir / "json" / "warmup.json").is_file())

            with (run_dir / "raw_ttft.csv").open(
                encoding="utf-8-sig", newline=""
            ) as raw_file:
                raw_rows = list(csv.DictReader(raw_file))

            # Warmup is excluded; recorded requests are 1*3 + 5*3.
            self.assertEqual(len(raw_rows), 18)
            self.assertEqual(
                {int(row["concurrency"]) for row in raw_rows},
                {1, 5},
            )
            self.assertEqual(
                {int(row["batch"]) for row in raw_rows},
                {1, 2, 3},
            )
            self.assertEqual({int(row["prompt_tokens"]) for row in raw_rows}, {16384})
            self.assertEqual({int(row["output_tokens"]) for row in raw_rows}, {1})

            with (run_dir / "summary_ttft.csv").open(
                encoding="utf-8-sig", newline=""
            ) as summary_file:
                summary_rows = list(csv.DictReader(summary_file))
            self.assertEqual(len(summary_rows), 2)
            by_concurrency = {
                int(row["concurrency"]): row for row in summary_rows
            }

            # For concurrency=1 and batch=1..3, values are
            # 0.011, 0.012, 0.013; mean is 0.012.
            self.assertAlmostEqual(
                float(by_concurrency[1]["Avg TTFT"]),
                0.012,
                places=9,
            )

            # For concurrency=5 and batch=1..3, each batch has
            # 0.011, 0.0111, 0.0112, 0.0113, 0.0114
            # 0.012, 0.0121, ...
            # 0.013, 0.0131, ...
            # Overall mean = 0.012 + mean(0..4)*0.0001 = 0.0122.
            self.assertAlmostEqual(
                float(by_concurrency[5]["Avg TTFT"]),
                0.0122,
                places=9,
            )
            self.assertEqual(int(by_concurrency[1]["requests"]), 3)
            self.assertEqual(int(by_concurrency[5]["requests"]), 15)
            self.assertEqual(int(by_concurrency[1]["failed_requests"]), 0)
            self.assertEqual(int(by_concurrency[5]["failed_requests"]), 0)

    def test_command_validation_is_forwarded_to_vllm(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            fake_vllm_script = Path(temp_dir) / "bad-vllm"
            fake_vllm_script.write_text(
                "#!/bin/sh\n"
                'echo "fake vllm refusing to run" >&2\n'
                "exit 3\n",
                encoding="utf-8",
            )
            os.chmod(fake_vllm_script, 0o755)

            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--vllm-bin",
                    str(fake_vllm_script),
                    "--output-dir",
                    str(Path(temp_dir) / "results"),
                    "--concurrencies",
                    "1",
                    "--batches",
                    "1",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("vllm bench serve failed", completed.stderr)

    def test_parse_vllm_result_excludes_failed_requests(self) -> None:
        module = load_script_module()
        with tempfile.TemporaryDirectory() as temp_dir:
            result_path = Path(temp_dir) / "concurrency-002-batch-01.json"
            result_path.write_text(
                (
                    '{"ttfts": [0.010, null, 0.030], '
                    '"input_lens": [16384, 16384, 16384], '
                    '"output_lens": [1, 1, 1], '
                    '"errors": [null, "connection error", null]}'
                ),
                encoding="utf-8",
            )
            records, failed = module.parse_vllm_result(
                result_path,
                concurrency=3,
                batch=1,
            )
            self.assertEqual(failed, 1)
            self.assertEqual([record.ttft_seconds for record in records], [0.010, 0.030])
            self.assertEqual([record.request_index for record in records], [1, 3])

    def test_c1_shell_script_with_fake_vllm(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir) / "results"
            env = os.environ.copy()
            env["VLLM_BIN"] = f"{sys.executable} {FAKE_VLLM}"
            env["VB_OUT"] = str(output_dir)
            completed = subprocess.run(
                ["bash", str(C1_SHELL_SCRIPT)],
                text=True,
                capture_output=True,
                check=False,
                env=env,
            )
            self.assertEqual(
                completed.returncode,
                0,
                msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
            )
            run_dir = next(output_dir.iterdir())
            result_path = run_dir / "result_c1.xlsx"
            self.assertTrue(result_path.is_file())
            with zipfile.ZipFile(result_path) as archive:
                self.assertEqual(archive.testzip(), None)
                sheet_names = archive.read("xl/workbook.xml").decode()
                self.assertIn('name="raw"', sheet_names)
                self.assertIn('name="summary"', sheet_names)
                raw_xml = archive.read("xl/worksheets/sheet1.xml").decode()
                summary_xml = archive.read("xl/worksheets/sheet2.xml").decode()
                self.assertIn("<t>ttft</t>", raw_xml)
                self.assertIn("<t>prefix_cache</t>", raw_xml)
                self.assertIn("<t>external_prefix_cache</t>", raw_xml)
                self.assertIn("Avg TTFT", summary_xml)
                self.assertIn("Success", summary_xml)
                self.assertIn("prefix_cache", summary_xml)
                self.assertIn("external_prefix_cache", summary_xml)
                self.assertIn("0.013", summary_xml)


if __name__ == "__main__":
    unittest.main()
