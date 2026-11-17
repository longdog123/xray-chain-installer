#!/usr/bin/env python3
"""Complete hosted Linux gate; only allowlisted evidence reaches public output."""
import datetime
import hashlib
import json
import os
import platform
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUITES = (
    "integration", "add-preview", "port-change", "rollback", "auto-update",
    "static", "socks-verification", "address-refresh", "system-errors",
    "status-errors", "error-context", "entry-address", "preflight",
)
XRAY_TAG = "v26.3.27"
XRAY_ARCHIVE_SHA256 = "23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"
PACKAGES = (
    "bash", "ca-certificates", "curl", "unzip", "jq", "openssl", "iproute2",
    "util-linux", "sqlite3", "kmod", "procps", "passwd", "python3", "git",
    "coreutils", "diffutils", "findutils", "grep", "sed", "gawk", "shellcheck",
)


class GateError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    pending = path.with_suffix(".pending")
    pending.write_text(json.dumps(report, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    pending.chmod(0o644)
    pending.replace(path)


def extract_diagnostics(output, suite, root=ROOT):
    """Parse fixed test formats, never retain message text or arbitrary paths."""
    if suite not in SUITES:
        raise GateError("diagnostic_suite")
    source_paths = [root / "install.sh", *sorted((root / "tests").glob("*.sh"))]
    sources = {}
    for path in source_paths:
        relative = path.relative_to(root).as_posix()
        if not re.fullmatch(r"install\.sh|tests/[A-Za-z0-9_-]+\.sh", relative):
            continue
        if path.is_symlink() or not path.is_file():
            continue
        bound = len(path.read_text(encoding="utf-8").splitlines())
        for spelling in (relative, "./" + relative, path.as_posix()):
            sources[spelling] = (relative, bound)
    fixture = (root / "tests" / (suite + ".sh")).read_text(encoding="utf-8")
    # Identifiers must also occur in the public test source, not just match a
    # permissive character class that could expose a token from raw output.
    scenarios = {m[1] for m in re.findall(r"(['\"])([A-Za-z0-9_-]{1,80})\1", fixture)}
    scenarios.update(re.findall(r"^(test_[A-Za-z0-9_]{1,75})\(\)\s*\{", fixture, re.M))
    result = {"scenario_counts": {"passed": 0, "failed": 0}, "failed_scenarios": [],
              "shellcheck": [], "source_locations": [], "category_counts": {},
              "rejected_scenario_count": 0, "truncated": False}
    context, consumed = None, 0

    def location(raw, number):
        entry = sources.get(raw)
        if entry and 0 < int(number) <= entry[1]:
            return {"source": entry[0], "line": int(number)}
        return None

    def append_unique(key, value):
        if value not in result[key]:
            if len(result[key]) < 100:
                result[key].append(value)
            else:
                result["truncated"] = True

    while True:
        raw = output.readline(8193)
        if not raw:
            break
        consumed += len(raw)
        if consumed > 4 * 1024 * 1024 or (len(raw) > 8192 and not raw.endswith(b"\n")):
            result["truncated"] = True
            break
        line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
        case = re.fullmatch(r"(PASS|FAIL): ([A-Za-z0-9_-]{1,80})(?: \((TTY|pipe)\))?(?:: .*)?", line)
        if case:
            status, name, mode = case.groups()
            known = name in scenarios or (
                suite == "entry-address" and "malformed-" in scenarios
                and re.fullmatch(r"malformed-[0-9]{1,3}", name))
            if known:
                result["scenario_counts"]["passed" if status == "PASS" else "failed"] += 1
                if status == "FAIL":
                    record = {"scenario": name}
                    if mode:
                        record["mode"] = mode
                    append_unique("failed_scenarios", record)
            else:
                result["rejected_scenario_count"] += 1
        header = re.fullmatch(r"In (.+) line ([0-9]{1,7}):", line)
        if header:
            context = location(*header.groups())
        check = re.match(r"^\s*[\^~\- ]+\s(SC[0-9]{4}) \((?:error|warning|info|style)\):", line)
        if check and context:
            append_unique("shellcheck", dict(context, code=check.group(1)))
        trace = re.fullmatch(r'\s*File "([^"]+)", line ([0-9]{1,7})(?:, in .*)?', line)
        if trace:
            entry = location(*trace.groups())
            if entry:
                append_unique("source_locations", dict(entry, category="python_traceback"))
        shell = re.match(r"^(.+): line ([0-9]{1,7}):", line)
        if shell:
            entry = location(*shell.groups())
            if entry:
                append_unique("source_locations", dict(entry, category="shell_error"))
        for pattern, category in (
                (r"^Traceback \(most recent call last\):$", "python_traceback"),
                (r"^AssertionError(?::|$)", "assertion_error"),
                (r"^SyntaxError(?::|$)", "syntax_error"),
                (r"^FileNotFoundError(?::|$)", "file_not_found"),
                (r"^subprocess.TimeoutExpired(?::|$)", "subprocess_timeout")):
            if re.match(pattern, line):
                result["category_counts"][category] = result["category_counts"].get(category, 0) + 1
    return result


def quiet_run(command, timeout, env=None, cwd=None, diagnostics=None, suite=None):
    # Never retain or forward raw test/tool output, even on failure or timeout.
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                   env=env, cwd=cwd, start_new_session=(os.name == "posix"))
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            process.wait()
            code = 124
        if diagnostics is not None:
            output.seek(0)
            diagnostics.update(extract_diagnostics(output, suite))
        return code


def require_test_files(root):
    if any(not (root / "tests" / (name + ".sh")).is_file() for name in SUITES):
        raise GateError("missing_required_test")


def verify_archive(archive, digest, pinned=XRAY_ARCHIVE_SHA256):
    entries = re.findall(r"^SHA2-256=\s*([0-9a-fA-F]{64})\s*$", digest.read_text(), re.M)
    actual = sha(archive)
    if len(entries) != 1 or actual != entries[0].lower() or actual != pinned:
        raise GateError("runtime_checksum")
    return actual


def extract_runtime(archive, destination):
    required = {"xray", "geoip.dat", "geosite.dat"}
    with zipfile.ZipFile(archive) as bundle:
        members = bundle.infolist()
        names = [item.filename for item in members]
        if len(names) != len(set(names)) or not required.issubset(names):
            raise GateError("runtime_archive_structure")
        for item in members:
            if (not item.filename or "/" in item.filename or "\\" in item.filename
                    or item.filename in (".", "..")
                    or stat.S_ISLNK(item.external_attr >> 16)):
                raise GateError("runtime_archive_structure")
        destination.mkdir(mode=0o700)
        for name in sorted(required):
            (destination / name).write_bytes(bundle.read(name))
    (destination / "xray").chmod(0o755)


def isolated_suite(name, runtime, outcome):
    """Already inside private mount, network and PID namespaces."""
    for mountpoint in ("/tmp", "/var/tmp"):
        if quiet_run(["mount", "-t", "tmpfs", "-o", "size=2G,mode=1777,nosuid,nodev",
                      "tmpfs", mountpoint], 10):
            raise GateError("temporary_filesystem_isolation")
    env = dict(os.environ, XRAY_TEST_BIN=str(runtime / "xray"),
               XRAY_TEST_ASSET_DIR=str(runtime), PYTHONDONTWRITEBYTECODE="1")
    started = stamp()
    tick = time.monotonic()
    diagnostics = {}
    code = quiet_run(["bash", str(ROOT / "tests" / (name + ".sh"))], 300, env, ROOT,
                     diagnostics=diagnostics, suite=name)
    residuals = sum(len(list(Path(base).iterdir())) for base in ("/tmp", "/var/tmp"))
    save_report(outcome, {
        "suite": "tests/" + name + ".sh", "started_at_utc": started,
        "completed_at_utc": stamp(), "elapsed_seconds": round(time.monotonic() - tick, 3),
        "exit_code": code, "status": "passed" if code == 0 else "failed",
        "diagnostics": diagnostics,
        "temporary_entries_before_namespace_release": residuals,
    })
    return code


def run_hosted():
    # No accidental fallback to the retired local Linux environment.
    if (os.environ.get("GITHUB_ACTIONS") != "true" or sys.platform != "linux"
            or os.geteuid() != 0):
        raise GateError("requires_hosted_linux_root")
    report_path = Path(os.environ["CI_REPORT_PATH"])
    paths = [ROOT / "install.sh", ROOT / ".github/workflows/tests.yml"]
    paths += sorted((ROOT / "tests").glob("*.sh"))
    paths += [ROOT / "tests/ci.py", ROOT / "tests/ci_unit.py"]
    hashes = {p.relative_to(ROOT).as_posix(): sha(p) for p in paths}
    report = {
        "schema": 1, "kind": "github_hosted_linux_regressions", "status": "running",
        "started_at_utc": stamp(), "source_sha": os.environ.get("CI_SOURCE_SHA", ""),
        "workflow_sha": os.environ.get("CI_WORKFLOW_SHA", ""),
        "workflow_file_sha256": hashes[".github/workflows/tests.yml"],
        "run_id": os.environ.get("CI_RUN_ID", ""), "run_attempt": os.environ.get("CI_RUN_ATTEMPT", ""),
        "repository": os.environ.get("CI_REPOSITORY", ""), "ref": os.environ.get("CI_REF", ""),
        "file_sha256": hashes, "timing_clock": "monotonic; UTC timestamps recorded separately",
        "environment": {"os": "ubuntu-24.04", "architecture": platform.machine(),
                        "root_for_fixture_ownership": True, "per_suite_network": "isolated"},
        "stages": [],
        "results": [{"suite": "tests/" + name + ".sh", "status": "not_run"} for name in SUITES],
        "cleanup": {"raw_logs_uploaded": False, "runtime_download_retained": None,
                    "temporary_storage": "per-suite tmpfs discarded on namespace exit"},
        "exclusions": ["No deployment or production credentials, state, configuration or customer data",
                       "No real VPS IP replacement, external client connectivity or cloud firewall validation",
                       "Real fixed Xray validates generated configuration; no external protocol session",
                       "Artifact contains no raw logs, fixtures, private keys, passwords or share links"],
    }
    save_report(report_path, report)
    private = None
    try:
        require_test_files(ROOT)
        # sudo changes Git's trust boundary, so whitelist only this checkout.
        os.environ.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="safe.directory", GIT_CONFIG_VALUE_0=str(ROOT))
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, stderr=subprocess.DEVNULL).decode().strip()
        if head != report["source_sha"] or not report["ref"].startswith("refs/heads/codex/"):
            raise GateError("source_identity")
        version = re.search(r'^SCRIPT_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$', (ROOT / "install.sh").read_text(), re.M)
        if not version:
            raise GateError("installer_version")
        report["installer_version"] = version.group(1)
        env = dict(os.environ, DEBIAN_FRONTEND="noninteractive", PYTHONDONTWRITEBYTECODE="1")
        for label, command, timeout in (
            ("package_index", ["apt-get", "update", "-qq"], 180),
            ("test_dependencies", ["apt-get", "install", "-y", "--no-install-recommends", *PACKAGES], 300),
            ("runner_unit_tests", ["python3", str(ROOT / "tests/ci_unit.py")], 30),
        ):
            tick = time.monotonic()
            code = quiet_run(command, timeout, env, ROOT)
            report["stages"].append({"stage": label, "exit_code": code,
                                     "elapsed_seconds": round(time.monotonic() - tick, 3)})
            save_report(report_path, report)
            if code:
                raise GateError(label)
        package_output = subprocess.check_output(
            ["dpkg-query", "-W", "-f=${Package}\t${Version}\n", *PACKAGES],
            stderr=subprocess.DEVNULL, timeout=15,
        ).decode()
        versions = dict(line.split("\t", 1) for line in package_output.splitlines())
        if set(versions) != set(PACKAGES) or any(
                not re.fullmatch(r"[A-Za-z0-9.+:~_-]+", value) for value in versions.values()):
            raise GateError("dependency_versions")
        report["environment"]["package_versions"] = versions
        with tempfile.TemporaryDirectory(prefix="puppyip-ci-", dir=os.environ["CI_PRIVATE_ROOT"]) as directory:
            private = Path(directory)
            base = "https://github.com/XTLS/Xray-core/releases/download/" + XRAY_TAG + "/Xray-linux-64.zip"
            for suffix in ("", ".dgst"):
                command = ["curl", "--disable", "--fail", "--silent", "--show-error", "--location",
                           "--proto", "=https", "--proto-redir", "=https", "--retry", "2",
                           "--connect-timeout", "10", "--max-time", "120", "--max-filesize", "104857600",
                           "--output", str(private / ("runtime.zip" + suffix)), base + suffix]
                code = quiet_run(command, 400)
                if code:
                    report["runtime_download_exit_code"] = code
                    raise GateError("runtime_digest_download" if suffix else "runtime_archive_download")
            archive_hash = verify_archive(private / "runtime.zip", private / "runtime.zip.dgst")
            runtime = private / "runtime"
            extract_runtime(private / "runtime.zip", runtime)
            raw_version = subprocess.check_output([str(runtime / "xray"), "version"], stderr=subprocess.DEVNULL).decode()
            if not re.match(r"Xray 26\.3\.27 .*linux/amd64", raw_version):
                raise GateError("runtime_version")
            report["runtime"] = {"version": XRAY_TAG, "archive_sha256": archive_hash,
                                 "official_dgst_file_sha256": sha(private / "runtime.zip.dgst"),
                                 "official_dgst_matched": True, "pinned_sha256_matched": True,
                                 "files_sha256": {name: sha(runtime / name) for name in ("xray", "geoip.dat", "geosite.dat")}}
            for index, name in enumerate(SUITES):
                outcome = private / (name + ".json")
                command = ["unshare", "--mount", "--net", "--pid", "--fork", "--kill-child=SIGKILL", "--mount-proc",
                           "python3", str(ROOT / "tests/ci.py"), "--isolated-suite", name, str(runtime), str(outcome)]
                started, tick = stamp(), time.monotonic()
                code = quiet_run(command, 330, env, ROOT)
                completed, elapsed = stamp(), round(time.monotonic() - tick, 3)
                if outcome.is_file():
                    result = json.loads(outcome.read_text())
                    if result["exit_code"] != code:
                        raise GateError("suite_exit_mismatch")
                else:
                    result = {"suite": "tests/" + name + ".sh", "status": "failed", "exit_code": code,
                              "failure_code": "isolation_or_suite_timeout"}
                result["isolation_started_at_utc"] = started
                result["isolation_completed_at_utc"] = completed
                result["isolation_elapsed_seconds"] = elapsed
                result["namespace_process_exit_observed"] = True
                report["results"][index] = result
                save_report(report_path, report)
                print(name + ": " + result["status"] + " (exit " + str(code) + ")", flush=True)
        report["source_unchanged"] = all(sha(ROOT / name) == value for name, value in hashes.items())
        report["status"] = "passed" if report["source_unchanged"] and all(r["status"] == "passed" for r in report["results"]) else "failed"
    except GateError as error:
        report.update(status="failed", failure_code=error.code)
    except Exception:
        # Exception text can contain raw subprocess output or local paths.
        report.update(status="failed", failure_code="runner_internal_error")
    finally:
        report["cleanup"]["private_runtime_created"] = private is not None
        report["cleanup"]["runtime_download_retained"] = private is not None and private.exists()
        if private is not None:
            report["cleanup"]["private_runtime_removed"] = not private.exists()
        report["completed_at_utc"] = stamp()
        save_report(report_path, report)
    print("Hosted gate: " + report["status"] + ("; " + report["failure_code"] if "failure_code" in report else ""))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    try:
        if len(sys.argv) == 5 and sys.argv[1] == "--isolated-suite" and sys.argv[2] in SUITES:
            sys.exit(isolated_suite(sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4])))
        sys.exit(run_hosted())
    except GateError as error:
        print("Hosted gate stopped: " + error.code)
        sys.exit(1)
