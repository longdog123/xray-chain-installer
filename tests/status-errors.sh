#!/usr/bin/env bash
# Exercise real status rendering and parallel probes using synthetic local files.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_worker() {
  local scenario="$1" case_dir="$2"
  # shellcheck source=../install.sh
  source "${ROOT_DIR}/install.sh"
  STATE_FILE="${case_dir}/state.json"
  CONFIG_FILE="${case_dir}/config.json"
  XRAY_BIN="${case_dir}/xray"
  ASSET_DIR="${case_dir}/assets"
  export STATUS_TEST_SCENARIO="$scenario"
  export HTTPS_PROXY='http://unused.invalid:8080' ALL_PROXY='socks5h://unused.invalid:1080'
  export https_proxy="$HTTPS_PROXY" all_proxy="$ALL_PROXY" NO_PROXY='*' no_proxy='*'
  require_root() { :; }
  interactive_progress_enabled() { return 1; }
  read_sysctl_value() { printf 'fixture'; }
  status_tcp_port_is_listening() { [[ "$scenario" != 'unlistening' ]]; }
  confirm_continue() { printf 'confirmation\n' >>"${case_dir}/forbidden"; return 99; }
  systemctl() {
    [[ "$*" == "is-active $SERVICE_NAME" ]] || {
      printf 'service mutation\n' >>"${case_dir}/forbidden"; return 99;
    }
    case "$scenario" in
      inactive|failed|unknown-service) printf '%s\n' "${scenario/unknown-service/unknown}"; return 3 ;;
      *) printf 'active\n' ;;
    esac
  }
  curl() {
    python3 - "$case_dir" "$scenario" "$@" <<'CURL'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
scenario = sys.argv[2]
args = sys.argv[3:]
config = ""
mode = None
if "--config" in args:
    path = pathlib.Path(args[args.index("--config") + 1])
    config = path.read_text()
    mode = path.stat().st_mode & 0o777
node = "node-1" if "198.51.100.11" in config else "node-2" if "198.51.100.22" in config else "node-3"
with (folder / (node + ".calls")).open("a") as stream:
    stream.write(json.dumps(dict(args=args, config=config, mode=mode)) + "\n")
if scenario in {"normal", "mismatch", "direct-environment"}:
    print("203.0.113.99" if scenario == "mismatch" else "203.0.113.10")
    raise SystemExit(0)
print("fixture-user fixture-password RAW_PRIVATE_DIAGNOSTIC", file=sys.stderr)
print("203.0.113.254")  # A nonzero response body must not become a valid exit.
raise SystemExit({"node-1": 28, "node-2": 97, "node-3": 6}[node])
CURL
  }
  command_status
}

if [[ "${1:-}" == '--case' ]]; then
  run_worker "$2" "$3"
  exit
fi
for dependency in jq python3; do command -v "$dependency" >/dev/null || exit 1; done
python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

script = str(Path(sys.argv[1]).resolve())
cases = ["probe-errors", "normal", "mismatch", "direct-environment", "missing-state", "missing-config",
         "missing-core", "core-failure", "invalid-state", "invalid-schema", "invalid-config", "inactive",
         "failed", "unknown-service", "unlistening", "missing-outbound", "invalid-outbound"]
if len(sys.argv) > 2:
    cases = [case for case in cases if case in sys.argv[2:]]
endpoints = ["https://api.ipify.org", "https://ipv4.icanhazip.com", "https://ifconfig.me/ip"]
failures = []

def require(condition, message):
    if not condition:
        raise AssertionError(message)

def fixture(folder, scenario):
    nodes = []
    for number in range(1, 5):
        nodes.append(dict(id=f"node-{number}", number=number, name=f"Fixture {number}",
                          type="direct" if number == 3 else "socks", enabled=number != 4,
                          inboundPort=62000+number, exitIp="203.0.113.10",
                          socksHost=f"198.51.100.{number * 11}", socksPort=1080+number))
    state = dict(schema=2, inboundPort=443, nodes=nodes)
    outbounds = [dict(tag=f"socks-out-node-{number}", protocol="socks",
                      settings=dict(address=f"198.51.100.{number * 11}", port=1080+number,
                                    user="fixture-user", **{"pass": "fixture-password"}))
                 for number in (1, 2, 4)]
    if scenario == "missing-outbound":
        outbounds = outbounds[1:]
    if scenario == "invalid-outbound":
        outbounds[0]["settings"]["port"] = 70000
    if scenario == "invalid-schema":
        state["schema"] = 999
    (folder / "state.json").write_text("{invalid" if scenario == "invalid-state" else json.dumps(state))
    (folder / "config.json").write_text(json.dumps(dict(outbounds=outbounds)))
    (folder / "assets").mkdir()
    core = folder / "xray"
    core.write_text('''#!/usr/bin/env bash
if [[ "$1" == version ]]; then
  [[ "$STATUS_TEST_SCENARIO" != core-failure ]] || exit 126
  printf 'Xray fixture\\n'
  exit 0
fi
if [[ "$STATUS_TEST_SCENARIO" == invalid-config ]]; then
  printf 'invalid config fixture-password RAW_PRIVATE_DIAGNOSTIC\\n' >&2
  exit 23
fi
exit 0
''')
    core.chmod(0o700)
    for target in ("state", "config", "core"):
        if scenario == "missing-" + target:
            (core if target == "core" else folder / (target + ".json")).unlink()

with tempfile.TemporaryDirectory(prefix="puppyip-status-errors.") as directory:
    for scenario in cases:
        folder = Path(directory) / scenario
        folder.mkdir()
        fixture(folder, scenario)
        originals = {path: path.read_bytes() for path in folder.iterdir() if path.is_file()}
        try:
            process = subprocess.run(["bash", script, "--case", scenario, str(folder)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            output = (process.stdout + process.stderr).decode()
            early_failure = scenario in {"missing-state", "missing-config", "missing-core", "core-failure", "invalid-state", "invalid-schema"}
            require((process.returncode != 0) == early_failure, "unexpected status command exit code")
            require(not any(value in output for value in ("fixture-user", "fixture-password", "RAW_PRIVATE_DIAGNOSTIC", "203.0.113.254")),
                    "status exposed credentials, raw diagnostic or a failed response body")
            require(all(path.read_bytes() == value for path, value in originals.items()), "status modified saved files")
            require(not (folder / "forbidden").exists(), "status prompted or mutated a service")
            calls = {f"node-{number}": [json.loads(line) for line in (folder / f"node-{number}.calls").read_text().splitlines()]
                     if (folder / f"node-{number}.calls").exists() else [] for number in range(1, 5)}
            require(not calls["node-4"], "paused node was probed")
            unavailable = early_failure or scenario in {"invalid-config", "inactive", "failed", "unknown-service", "unlistening"}
            if unavailable:
                require(not any(calls.values()), "unavailable installation was probed")
                require("建议" in output or "请" in output, "failure has no actionable next step")
                if scenario.startswith("missing-"):
                    label = {"missing-state": "state.json", "missing-config": "config.json", "missing-core": "xray"}[scenario]
                    require(label in output and "不存在" in output, "missing installation file was not identified")
                    require("尚未安装" not in output, "damaged installation was reported as never installed")
                elif scenario in {"invalid-state", "invalid-schema"}:
                    require("state.json" in output, "invalid state did not identify its file")
                elif scenario == "core-failure":
                    require("xray" in output and "126" in output, "core execution failure lacks path or code")
                elif scenario == "invalid-config":
                    require("配置校验失败" in output and "config.json" in output and "23" in output,
                            "failed config validation lacks path or exit code")
                elif scenario in {"inactive", "failed", "unknown-service"}:
                    require("xray-chain.service" in output and "journalctl" in output,
                            "service failure lacks unit and next diagnostic command")
                else:
                    require("62001" in output and "ss -lntp" in output, "unlistening port lacks inspection command")
                print(f"PASS: {scenario}", flush=True)
                continue
            blocks = {int(number): body for number, body in re.findall(r"^  (\d+)\) Fixture \d+\n(.*?)(?=^  \d+\)|\Z)", output, re.M | re.S)}
            require(len(blocks) == 4, "node identities were lost")
            require(blocks[4].strip() == "入口：62004/tcp\n     状态：已暂停（未检测）", "paused output became noisy")
            healthy = scenario in {"normal", "mismatch", "direct-environment"}
            for number in (1, 2, 3):
                records = calls[f"node-{number}"]
                local_error = number == 1 and scenario in {"missing-outbound", "invalid-outbound"}
                require(len(records) == (0 if local_error else 1 if healthy else 3), "probe count increased or a local error reached network")
                if healthy:
                    phrase = "出口 IP：203.0.113.99 · 与记录不一致（记录：203.0.113.10）" if scenario == "mismatch" else "出口 IP：203.0.113.10 · 正常"
                    require(blocks[number].strip() == f"入口：{62000+number}/tcp\n     {phrase}", "successful status output changed or became noisy")
                elif local_error:
                    require("配置" in blocks[number] and "socks-out-node-1" in blocks[number] and "建议" in blocks[number],
                            "invalid outbound has no specific local diagnosis")
                else:
                    target = "VPS 本机直连" if number == 3 else f"198.51.100.{number * 11}:{1080+number}"
                    code = {1: 28, 2: 97, 3: 6}[number]
                    category = {1: "超时", 2: "代理", 3: "DNS"}[number]
                    require(target in blocks[number], "failed node does not identify its actual outbound target")
                    require(category in blocks[number] and f"curl 代码 {code}" in blocks[number] and "建议" in blocks[number],
                            "failed node has no safe category, curl code or next step")
                    require(all(endpoint.split("//")[1].split("/")[0] in blocks[number] for endpoint in endpoints), "failed node does not identify every probe site")
                    require(not any(f"curl 代码 {other}" in blocks[number] for other in (6, 28, 97) if other != code),
                            "parallel diagnostic results mixed different nodes")
                    require("密码错误" not in blocks[number] and "被墙" not in blocks[number], "diagnostic asserts an unproven cause")
                for index, record in enumerate(records):
                    require(record["args"][-1] == endpoints[index], "probe order changed")
                    if record["config"]:
                        require(record["mode"] == 0o600, "status curl config is not private")
                        require("connect-timeout = 4" in record["config"] and "max-time = 6" in record["config"], "probe timeouts changed")
                    if number == 3 and scenario == "direct-environment":
                        require('proxy = ""' in record["config"] or ("--noproxy" in record["args"] and "*" in record["args"]),
                                "direct status can use an ambient proxy")
            print(f"PASS: {scenario}", flush=True)
        except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            failures.append(scenario)
            print(f"FAIL: {scenario}: {error}", file=sys.stderr, flush=True)
if failures:
    raise SystemExit(f"Status diagnostic checks failed: {len(failures)}/{len(cases)}")
print(f"Status diagnostic checks passed: {len(cases)} cases.")
PY
