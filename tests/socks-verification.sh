#!/usr/bin/env bash
# Real SOCKS verification and status probe, with only curl/network and confirmation stubbed.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_worker() {
  local scenario="$1" case_dir="$2" status=0 result=''
  # shellcheck source=../install.sh
  source "${ROOT_DIR}/install.sh"
  STATE_FILE="${case_dir}/state.json"
  SOCKS_HOST='198.51.100.77'
  SOCKS_PORT='1080'
  SOCKS_USER='fixture-user'
  SOCKS_PASS='fixture-password'
  confirm_count=0
  confirm_continue() {
    ((confirm_count += 1))
    [[ "$scenario" == 'allow-unverified' ]] && return 0
    return 42
  }
  systemctl() { printf 'unexpected service access\n' >>"${case_dir}/forbidden"; return 99; }
  curl() {
    python3 - "$case_dir" "$@" <<'CURL'
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
args = sys.argv[2:]
calls = root / "calls.jsonl"
index = len(calls.read_text().splitlines()) if calls.exists() else 0
with calls.open("a") as stream:
    stream.write(json.dumps(args) + "\n")
config = pathlib.Path(args[args.index("--config") + 1])
(root / f"captured-{index}.conf").write_bytes(config.read_bytes())
(root / f"mode-{index}").write_text(oct(config.stat().st_mode & 0o777))
responses = json.loads((root / "responses.json").read_text())
response = responses[min(index, len(responses) - 1)]
if response["code"]:
    print("198.51.100.77 fixture-user fixture-password private diagnostic must not escape", file=sys.stderr)
sys.stdout.write(response["body"])
raise SystemExit(response["code"])
CURL
  }
  if [[ "$scenario" == 'environment' ]]; then
    export NO_PROXY='*' no_proxy='api.ipify.org' HTTPS_PROXY='http://unused.invalid:8080'
  fi
  if [[ "$scenario" == helper-* ]]; then
    printf '%s\n' 'proxy = "socks5h://198.51.100.77:1080"' \
      'proxy-user = "fixture-user:fixture-password"' >"${case_dir}/helper.conf"
    chmod 0600 "${case_dir}/helper.conf"
    result="$(probe_ipv4_with_curl_config "${case_dir}/helper.conf" 2>"${case_dir}/helper.stderr")" || status=$?
  else
    verify_socks_proxy "$case_dir" >"${case_dir}/display" 2>&1 || status=$?
    result="$SOCKS_EXIT_IP"
  fi
  jq -n --argjson status "$status" --arg result "$result" --argjson confirmations "$confirm_count" \
    '{status:$status,result:$result,confirmations:$confirmations}' >"${case_dir}/result.json"
}

if [[ "${1:-}" == '--case' ]]; then
  run_worker "$2" "$3"
  exit
fi
for dependency in jq python3; do command -v "$dependency" >/dev/null || exit 1; done
python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import tempfile

script = str(Path(sys.argv[1]).resolve())
good = {"code": 0, "body": "198.51.100.200"}
failure = lambda code, body="": {"code": code, "body": body}
cases = {
    "success": ([good], None),
    "fallback-second": ([failure(28), good], None),
    "fallback-third": ([failure(22), failure(6), good], None),
    "failed-body-fallback": ([failure(28, good["body"]), good], None),
    "dns-proxy": ([failure(5)], "DNS"),
    "dns-target": ([failure(6)], "DNS"),
    "connection": ([failure(7)], "连接"),
    "timeout": ([failure(28)], "超时"),
    "tls-handshake": ([failure(35)], "TLS"),
    "tls-certificate": ([failure(60)], "TLS"),
    "proxy-handshake": ([failure(97)], "代理"),
    "authentication": ([failure(67)], "代理"),
    "http-error": ([failure(22)], "HTTP"),
    "invalid-body": ([failure(0, "not an IP")], "IPv4"),
    "empty-body": ([failure(0)], "IPv4"),
    "trailing-dot": ([failure(0, "198.51.100.200.")], "IPv4"),
    "embedded-whitespace": ([failure(0, "198.51.100.2 00")], "IPv4"),
    "surrounding-whitespace": ([failure(0, " \r\n198.51.100.200\r\n ")], None),
    "nonzero-body": ([failure(28, good["body"])], "超时"),
    "environment": ([good], None),
    "allow-unverified": ([failure(7)], "连接"),
    "saved-old": ([good], None),
    "saved-new": ([good], None),
    "helper-failed-body": ([failure(28, good["body"])], "silent"),
    "helper-silent-failure": ([failure(97)], "silent"),
    "helper-success": ([good], None),
}
if len(sys.argv) > 2:
    cases = {name: case for name, case in cases.items() if name in sys.argv[2:]}
endpoints = ["https://api.ipify.org", "https://ipv4.icanhazip.com", "https://ifconfig.me/ip"]
failures = []
captured_addresses = {}

def require(condition, description):
    if not condition:
        raise AssertionError(description)

with tempfile.TemporaryDirectory(prefix="puppyip-socks-verification.") as directory:
    for scenario, (responses, error_category) in cases.items():
        root = Path(directory) / scenario
        root.mkdir()
        saved = "203.0.113.20" if scenario == "saved-new" else "203.0.113.10"
        state = json.dumps({"serverAddress": saved}).encode()
        (root / "state.json").write_bytes(state)
        (root / "responses.json").write_text(json.dumps(responses))
        try:
            process = subprocess.run(["bash", script, "--case", scenario, str(root)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
            require(process.returncode == 0, "test worker failed unexpectedly")
            result = json.loads((root / "result.json").read_text())
            expected_success = error_category is None
            require((result["result"] == good["body"]) if expected_success else result["result"] == "",
                    "accepted a failed/invalid response, or rejected a valid fallback")
            require(result["status"] == (0 if expected_success or scenario == "allow-unverified" else
                                         1 if scenario.startswith("helper-") else 42),
                    "verification or confirmation status differs")
            require(result["confirmations"] == int(not expected_success and not scenario.startswith("helper-")),
                    "failure confirmation was skipped/repeated, or successful fallback prompted")
            calls = [json.loads(line) for line in (root / "calls.jsonl").read_text().splitlines()]
            expected_count = len(responses) if expected_success else 3
            require(len(calls) == expected_count, "did not stop at success or try all three endpoints")
            for index, args in enumerate(calls):
                require(args[0] == "--disable", "curl did not disable default curlrc as its first option")
                require("--noproxy" in args and args[args.index("--noproxy") + 1] == "",
                        "NO_PROXY can bypass the intended SOCKS proxy")
                require(args[-1] == endpoints[index], "unexpected endpoint or retry order")
                require(not any(value in " ".join(args) for value in
                                ("198.51.100.77", "fixture-user", "fixture-password")),
                        "proxy endpoint or credentials escaped into curl argv")
                require((root / f"mode-{index}").read_text() == "0o600", "curl config permissions are not private")
                config = (root / f"captured-{index}.conf").read_text()
                require('proxy = "socks5h://198.51.100.77:1080"' in config and
                        'proxy-user = "fixture-user:fixture-password"' in config,
                        "configured SOCKS proxy or authentication was not preserved")
            display = (root / "display").read_text() if (root / "display").exists() else ""
            combined = display + process.stdout.decode() + process.stderr.decode()
            require(not any(value in combined for value in
                            ("fixture-user", "fixture-password", "private diagnostic")),
                    "diagnostics exposed credentials or raw stderr")
            if error_category == "silent":
                require((root / "helper.stderr").read_bytes() == b"", "status probe failure became noisy")
            elif error_category:
                require(error_category in display and "curl" in display,
                        "failure did not include a safe category and numeric curl code")
                require(str(responses[0]["code"]) in display, "curl error code is missing")
                require("198.51.100.77:1080" in display, "failed proxy endpoint is missing")
                require(all(domain in display for domain in
                            ("api.ipify.org", "ipv4.icanhazip.com", "ifconfig.me")),
                        "failed detection sites are missing")
                require("建议" in display, "failure next step is missing")
                if scenario == "proxy-handshake":
                    require("密码错误" not in display, "curl 97 was misdiagnosed as a definite password error")
            else:
                require(not display, "successful fallback printed an unnecessary error")
            require((root / "state.json").read_bytes() == state, "verification modified node state")
            require(not (root / "forbidden").exists(), "verification touched a service")
            if scenario in ("saved-old", "saved-new"):
                captured_addresses[scenario] = (root / "captured-0.conf").read_bytes()
            print(f"PASS: {scenario}", flush=True)
        except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            failures.append(scenario)
            print(f"FAIL: {scenario}: {error}", file=sys.stderr, flush=True)
if len(captured_addresses) == 2:
    require(captured_addresses["saved-old"] == captured_addresses["saved-new"],
            "saved VPS address affected the SOCKS verification request")
if failures:
    raise SystemExit(f"SOCKS verification checks failed: {len(failures)}/{len(cases)}")
print(f"SOCKS verification checks passed: {len(cases)} cases.")
PY
