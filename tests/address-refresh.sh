#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# Read-only display refresh: real show/link/QR paths, isolated address discovery.
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_worker() {
  local scenario="$1" case_dir="$2"
  # shellcheck source=../install.sh
  source "${ROOT_DIR}/install.sh"
  STATE_FILE="${case_dir}/state.json"
  CONFIG_FILE="${case_dir}/config.json"
  MODEL_FILE="${case_dir}/render-state.json"
  SECRETS_FILE="${case_dir}/secrets.json"
  PRIVATE_KEY='fixture-private-key'
  render_config "$CONFIG_FILE" "$case_dir" "$MODEL_FILE" "$SECRETS_FILE"
  cp -- "$STATE_FILE" "${case_dir}/before-state.json"
  cp -- "$CONFIG_FILE" "${case_dir}/before-config.json"
  unset XRAY_CHAIN_AUTO_ADDRESS
  [[ "$scenario" != 'disabled' ]] || export XRAY_CHAIN_AUTO_ADDRESS=0
  require_root() { :; }
  prompt_yes_no() { printf 'Unexpected confirmation\n' >>"${case_dir}/forbidden"; return 99; }
  systemctl() { printf 'Unexpected service operation\n' >>"${case_dir}/forbidden"; return 99; }
  ip() {
    printf '%s\n' "$*" >>"${case_dir}/ip-calls"
    [[ "$*" == '-j -4 address show scope global' ]] || return 99
    [[ "$scenario" != 'ip-failure' ]] || return 1
    cat -- "${case_dir}/local-addresses.json"
    [[ "$scenario" != 'ip-failed-json' ]]
  }
  curl() {
    printf '%s\n' "${!#}" >>"${case_dir}/curl-calls"
    case "${!#}" in
      https://api.ipify.org|https://ipv4.icanhazip.com|https://ifconfig.me/ip) ;;
      *) printf 'Unexpected network endpoint\n' >>"${case_dir}/forbidden"; return 99 ;;
    esac
    [[ "$scenario" != 'probe-failure' ]] || return 28
    if [[ "$scenario" == 'probe-fallback' && "${!#}" != 'https://ifconfig.me/ip' ]]; then return 28; fi
    cat -- "${case_dir}/probe-address"
    [[ "$scenario" != 'probe-failed-body' ]]
  }
  qrencode() {
    [[ "$1" == '-t' && "$2" == 'ANSIUTF8' && "$3" == vless://* ]] || return 99
    printf '%s\n' "$3" >>"${case_dir}/qr-links"
  }

  case "$scenario" in
    pure-builder) build_share_link node-2; printf '\n' ;;
    override-builder) build_share_link node-2 '203.0.113.20'; printf '\n' ;;
    override-connection) show_connection node-2 no yes '203.0.113.20' ;;
    override-all) show_all_connections '203.0.113.20' ;;
    single) command_show 2 ;;
    no-leak)
      command_show all
      printf '__DEFAULT_BUILDER__\n'
      build_share_link node-2
      printf '\n'
      ;;
    repeated)
      command_show all
      printf '__NEXT_SHOW__\n'
      printf '%s\n' '[{"addr_info":[{"family":"inet","local":"203.0.113.30","scope":"global"}]}]' \
        >"${case_dir}/local-addresses.json"
      printf '203.0.113.30' >"${case_dir}/probe-address"
      command_show all
      ;;
    *) command_show all ;;
  esac
}

if [[ "${1:-}" == '--case' ]]; then
  run_worker "$2" "$3"
  exit
fi

for dependency in jq python3; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf '缺少测试依赖：%s\n' "$dependency" >&2
    exit 1
  }
done

python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import errno
import json
import os
from pathlib import Path
import pty
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

script = str(Path(sys.argv[1]).resolve())
cases = [
    ("shared", True), ("mixed", True), ("independent", True),
    ("mixed", False), ("single", True), ("schema1", True), ("repeated", True),
    ("saved-present", True), ("domain", False), ("disabled", False),
    ("multiple-public", False), ("nat", False), ("probe-failure", False),
    ("probe-fallback", True), ("probe-failed-body", False), ("ip-failed-json", False),
    ("invalid-probe", False), ("ip-failure", False), ("invalid-json", False),
    ("invalid-local", False), ("private-10", False), ("private-172", False),
    ("private-192", False), ("loopback", False), ("cgnat", False), ("link-local", False),
    ("mixed-private", False), ("duplicate-public", False),
    ("pure-builder", False), ("override-builder", False),
    ("override-connection", False), ("override-all", True), ("no-leak", True),
]
if len(sys.argv) > 2:
    cases = [case for case in cases if case[0] in sys.argv[2:]]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def fixture(scenario, folder):
    count = 30 if scenario in {"shared", "mixed", "independent"} else 3
    nodes = []
    for number in range(1, count + 1):
        node = dict(id=f"node-{number}", number=number, name=f"Fixture exit {number}",
                    email=f"node-{number}@puppyip.local",
                    uuid=f"{number:08d}-1111-4111-8111-{number:012d}",
                    shortId=f"{number:016d}", spiderX=f"/fixture/{number}?mode=test",
                    udpMode="block" if number % 3 == 1 else "proxy",
                    enabled=number % 4 != 2, type="direct" if number % 3 == 0 else "socks",
                    socksHost=f"198.51.100.{number}", socksPort=1080 + number,
                    socksUser=f"fixture-user-{number}", exitIp=f"198.51.100.{number}")
        if node["type"] == "direct":
            node.update(socksHost="", socksPort=0, socksUser="", exitIp="203.0.113.10")
        if scenario == "independent" or (scenario != "shared" and number % 2 == 0):
            node["inboundPort"] = 62000 + number
        nodes.append(node)
    state = dict(schema=2, installedAt="2026-01-01T00:00:00Z", updatedAt="2026-01-01T00:00:00Z",
                 installerVersion="fixture", xrayVersion="v26.3.27", serverAddress="203.0.113.10",
                 inboundPort=443, realityTarget="www.example.com:443", serverName="www.example.com",
                 realityPublicKey="fixture-public-key", nextNodeNumber=count + 1, nodes=nodes)
    if scenario == "domain":
        state["serverAddress"] = "fixed-entry.example.com"
    (folder / "render-state.json").write_text(json.dumps(state))
    (folder / "secrets.json").write_text(json.dumps({node["id"]: f"fixture-password-{node['number']}"
                                                    for node in nodes if node["type"] == "socks"}))
    if scenario == "schema1":
        state = dict(schema=1, serverAddress=state["serverAddress"], inboundPort=8443,
                     serverName=state["serverName"], publicKey=state["realityPublicKey"],
                     uuid=nodes[0]["uuid"], shortId=nodes[0]["shortId"], nodeName="Legacy fixture")
    (folder / "state.json").write_text(json.dumps(state))
    local = ["203.0.113.20"]
    probe = "203.0.113.20"
    if scenario == "saved-present":
        local = ["203.0.113.10", "203.0.113.20"]
    elif scenario == "multiple-public":
        local = ["203.0.113.20", "198.51.100.21"]
    elif scenario == "nat":
        probe = "198.51.100.99"
    elif scenario == "invalid-probe":
        probe = "999.0.0.1"
    elif scenario == "invalid-local":
        local = ["999.0.0.1"]
    elif scenario in {"private-10", "private-172", "private-192", "loopback", "cgnat", "link-local"}:
        local = [{"private-10": "10.0.0.2", "private-172": "172.16.0.2", "private-192": "192.168.0.2",
                  "loopback": "127.0.0.2", "cgnat": ".".join(map(str, (100, 64, 0, 2))), "link-local": "169.254.1.2"}[scenario]]
        probe = local[0]
    elif scenario == "mixed-private":
        local += ["10.0.0.2", "172.31.0.2", "192.168.1.2", "127.0.0.2", ".".join(map(str, (100, 127, 0, 2)))]
    elif scenario == "duplicate-public":
        local *= 2
    addresses = [{"ifname": "fixture0", "addr_info": [
        {"family": "inet", "local": address, "scope": "global"} for address in local]}]
    (folder / "local-addresses.json").write_text("{bad-json" if scenario == "invalid-json" else json.dumps(addresses))
    (folder / "probe-address").write_text(probe)
    return state


def link(state, node, address):
    return (f"vless://{node['uuid']}@{address}:{node.get('inboundPort', state['inboundPort'])}"
            "?encryption=none&flow=xtls-rprx-vision&security=reality"
            f"&sni={quote(state['serverName'], safe='')}&fp=chrome"
            f"&pbk={quote(state.get('realityPublicKey', state.get('publicKey')), safe='')}"
            f"&sid={node['shortId']}&spx={quote(node['spiderX'], safe='')}"
            f"&type=tcp&headerType=none#{quote(node['name'], safe='')}")


def capture(scenario, folder, terminal):
    command = ["bash", script, "--case", scenario, str(folder)]
    if not terminal:
        process = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, timeout=40)
        return process.returncode, process.stdout.decode()
    master, slave = pty.openpty()
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
                               start_new_session=True)
    os.close(slave)
    chunks = []
    deadline = time.monotonic() + 40
    with selectors.DefaultSelector() as selector:
        selector.register(master, selectors.EVENT_READ)
        try:
            while True:
                if time.monotonic() > deadline:
                    os.killpg(process.pid, signal.SIGKILL)
                    raise AssertionError("show waited for input or exceeded its test timeout")
                if not selector.select(0.2):
                    continue
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                chunks.append(chunk)
        finally:
            os.close(master)
            process.wait(timeout=5)
    return process.returncode, b"".join(chunks).decode()


def lines(folder, filename):
    path = folder / filename
    return path.read_text().splitlines() if path.exists() else []


failures = []
with tempfile.TemporaryDirectory(prefix="puppyip-address-fixture.") as directory:
    for index, (scenario, terminal) in enumerate(cases):
        folder = Path(directory) / str(index)
        folder.mkdir()
        name = f"{scenario} ({'TTY' if terminal else 'pipe'})"
        try:
            state = fixture(scenario, folder)
            status, output = capture(scenario, folder, terminal)
            require(status == 0, f"unexpected status {status}: {output}")
            output = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", output).replace("\r", "")
            nodes = state.get("nodes", [dict(id="node-1", uuid=state.get("uuid"), shortId=state.get("shortId"),
                                            spiderX="/", name=state.get("nodeName"))])
            if scenario in {"single", "pure-builder", "override-builder", "override-connection"}:
                nodes = [node for node in nodes if node["id"] == "node-2"]
            refreshed = scenario in {"shared", "mixed", "independent", "single", "schema1", "repeated", "probe-fallback", "no-leak",
                                     "mixed-private", "duplicate-public", "override-builder", "override-connection", "override-all"}
            address = "203.0.113.20" if refreshed else state["serverAddress"]
            expected = [link(state, node, address) for node in nodes]
            if scenario == "repeated":
                expected += [link(state, node, "203.0.113.30") for node in nodes]
            qr_expected = expected[:] if terminal or scenario == "override-connection" else []
            if scenario == "no-leak":
                expected += [link(state, nodes[1], state["serverAddress"])]
            actual = re.findall(r"^vless://[^\s]+$", output, flags=re.MULTILINE)
            require(actual == expected, f"displayed links differ beyond the expected address (expected {address})")
            require(lines(folder, "qr-links") == qr_expected, "QR inputs did not exactly match displayed links")
            if scenario not in {"pure-builder", "override-builder"}:
                expected_exits = []
                for display_address in ([address, "203.0.113.30"] if scenario == "repeated" else [address]):
                    for node in nodes:
                        if node.get("type") == "direct":
                            exit_address = display_address if refreshed else node["exitIp"]
                            expected_exits.append(f"{exit_address}（VPS 本机）")
                        else:
                            expected_exits.append(node.get("exitIp", "未验证"))
                require(re.findall(r"^出口 IP：([^\n]+)$", output, flags=re.MULTILINE) == expected_exits,
                        "displayed direct exit did not refresh, or a SOCKS exit changed")
            for filename in ("state", "config"):
                require((folder / f"{filename}.json").read_bytes() == (folder / f"before-{filename}.json").read_bytes(),
                        f"show modified saved {filename}")
            require(not lines(folder, "forbidden"), "show performed a service, confirmation or unexpected network operation")
            ip_calls = lines(folder, "ip-calls")
            curl_calls = lines(folder, "curl-calls")
            pure = scenario in {"domain", "disabled", "pure-builder", "override-builder", "override-connection", "override-all"}
            require(len(ip_calls) == (0 if pure else 2 if scenario == "repeated" else 1),
                    "local address discovery did not occur exactly once per show")
            if pure or scenario in {"saved-present", "multiple-public", "ip-failure", "ip-failed-json", "invalid-json", "invalid-local",
                                    "private-10", "private-172", "private-192", "loopback", "cgnat", "link-local"}:
                require(not curl_calls, "ambiguous, fixed or unsafe local address triggered public probing")
            else:
                expected_probes = 2 if scenario == "repeated" else 3 if scenario in {"probe-failure", "probe-failed-body", "probe-fallback", "invalid-probe"} else 1
                require(len(curl_calls) == expected_probes, "public probing was repeated per node or cached between shows")
            if scenario == "single":
                require("状态：已暂停" in output, "single paused node lost its displayed state")
            print(f"PASS: {name}", flush=True)
        except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            failures.append(name)
            print(f"FAIL: {name}: {error}", file=sys.stderr, flush=True)

if failures:
    raise SystemExit(f"只读地址刷新检查失败：{len(failures)}/{len(cases)}")
print(f"只读地址刷新检查通过：{len(cases)} 个场景。")
PY
