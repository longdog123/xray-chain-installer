"""Narrow, cross-platform checks for the hosted CI evidence boundary."""
import hashlib
import importlib.util
import contextlib
import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location("hosted_ci", Path(__file__).with_name("ci.py"))
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class EvidenceTests(unittest.TestCase):
    def test_full_gate_refuses_a_local_run(self):
        with mock.patch.dict(ci.os.environ, {"GITHUB_ACTIONS": "false"}):
            with self.assertRaises(ci.GateError) as error:
                ci.run_hosted()
            self.assertEqual(error.exception.code, "requires_hosted_linux_root")

    def test_all_required_suites_are_mandatory(self):
        self.assertEqual(len(ci.SUITES), 13)
        self.assertIn("entry-address", ci.SUITES)
        self.assertIn("preflight", ci.SUITES)
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ci.GateError) as error:
                ci.require_test_files(Path(folder))
            self.assertEqual(error.exception.code, "missing_required_test")

    def test_official_digest_and_pinned_digest_must_both_match(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            archive, digest = root / "runtime.zip", root / "runtime.dgst"
            archive.write_bytes(b"synthetic-archive")
            expected = hashlib.sha256(archive.read_bytes()).hexdigest()
            digest.write_text("SHA2-256= " + expected + "\n")
            self.assertEqual(ci.verify_archive(archive, digest, expected), expected)
            with self.assertRaises(ci.GateError):
                ci.verify_archive(archive, digest, "0" * 64)
            digest.write_text("SHA2-256= " + "0" * 64 + "\n")
            with self.assertRaises(ci.GateError):
                ci.verify_archive(archive, digest, expected)

    def test_archive_rejects_traversal_and_missing_assets(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for index, names in enumerate((["../xray", "geoip.dat", "geosite.dat"], ["xray"])):
                archive = root / (str(index) + ".zip")
                with zipfile.ZipFile(archive, "w") as bundle:
                    for name in names:
                        bundle.writestr(name, b"synthetic")
                with self.assertRaises(ci.GateError):
                    ci.extract_runtime(archive, root / ("out" + str(index)))

    def test_subprocess_output_is_never_forwarded(self):
        public_output = io.StringIO()
        with contextlib.redirect_stdout(public_output), contextlib.redirect_stderr(public_output):
            status = ci.quiet_run([sys.executable, "-c",
                                   "import sys; print('synthetic-sensitive-output'); sys.exit(9)"], 10)
        self.assertEqual(status, 9)
        self.assertEqual(public_output.getvalue(), "")

    def test_diagnostics_keep_only_known_scenarios_and_source_locations(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "tests").mkdir()
            (root / "install.sh").write_text("# synthetic source\n" * 30)
            (root / "tests/add-preview.sh").write_text('cases = ["direct", "atomic-failure"]\n' * 30)
            output = (
                "PASS: direct (TTY)\n"
                "FAIL: atomic-failure (pipe): synthetic-private-password\n"
                "FAIL: unknown_private_token: synthetic-private-password\n"
                f'In {root.as_posix()}/install.sh line 12:\n'
                "synthetic-private-password\n"
                "    ^-- SC2155 (warning): synthetic-private-password\n"
                'In /external/install.sh line 13:\n'
                "    ^-- SC2086 (info): synthetic-private-password\n"
                "Traceback (most recent call last):\n"
                f'  File "{root.as_posix()}/tests/add-preview.sh", line 9, in synthetic_private_method\n'
                '  File "/external/install.sh", line 7, in synthetic_private_method\n'
                '  File "tests/../install.sh", line 11, in synthetic_private_method\n'
                "AssertionError: synthetic-private-password\n"
            )
            result = ci.extract_diagnostics(io.BytesIO(output.encode()), "add-preview", root)
            self.assertEqual(result["scenario_counts"], {"passed": 1, "failed": 1})
            self.assertEqual(result["failed_scenarios"], [{"scenario": "atomic-failure", "mode": "pipe"}])
            self.assertEqual(result["shellcheck"], [{"source": "install.sh", "line": 12, "code": "SC2155"}])
            self.assertEqual(result["source_locations"], [{"source": "tests/add-preview.sh", "line": 9, "category": "python_traceback"}])
            public = json.dumps(result)
            for rejected in ("synthetic-private", "unknown_private", "external", "SC2086", "synthetic_private_method", root.as_posix()):
                self.assertNotIn(rejected, public)

    def test_subprocess_diagnostics_do_not_forward_raw_output(self):
        result, public = {}, io.StringIO()
        with contextlib.redirect_stdout(public), contextlib.redirect_stderr(public):
            code = ci.quiet_run([sys.executable, "-c",
                                 "import sys; print('FAIL: direct (TTY): synthetic-private-password'); sys.exit(8)"],
                                10, diagnostics=result, suite="add-preview")
        self.assertEqual(code, 8)
        self.assertEqual(result["failed_scenarios"], [{"scenario": "direct", "mode": "TTY"}])
        self.assertNotIn("synthetic-private-password", json.dumps(result))
        self.assertEqual(public.getvalue(), "")

    def test_diagnostics_bound_unstructured_output(self):
        result = ci.extract_diagnostics(io.BytesIO(b"x" * 9000), "add-preview")
        self.assertTrue(result["truncated"])
        self.assertEqual(result["failed_scenarios"], [])
        self.assertNotIn("x" * 10, json.dumps(result))


if __name__ == "__main__":
    unittest.main()
