#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# Read-only display refresh: real show/link/QR paths, isolated address discovery.
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_worker() {
  local scenario="$1" case_dir="$2" network_scenario="${1#list-}"
  network_scenario="${network_scenario#socks-only-}"
  network_scenario="${network_scenario#edit-direct-}"
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
  cp -- "$MODEL_FILE" "${case_dir}/before-render-state.json"
  cp -- "$SECRETS_FILE" "${case_dir}/before-secrets.json"
  unset XRAY_CHAIN_AUTO_ADDRESS
  [[ "$network_scenario" != 'disabled' ]] || export XRAY_CHAIN_AUTO_ADDRESS=0
  require_root() { :; }
  prompt_yes_no() { printf 'Unexpected confirmation\n' >>"${case_dir}/forbidden"; return 99; }
  systemctl() { printf 'Unexpected service operation\n' >>"${case_dir}/forbidden"; return 99; }
  ip() {
    printf '%s\n' "$*" >>"${case_dir}/ip-calls"
    [[ "$*" == '-j -4 address show scope global' ]] || return 99
    [[ "$network_scenario" != 'ip-failure' ]] || return 1
    cat -- "${case_dir}/local-addresses.json"
    [[ "$network_scenario" != 'ip-failed-json' ]]
  }
  curl() {
    printf '%s\n' "${!#}" >>"${case_dir}/curl-calls"
    case "${!#}" in
      https://api.ipify.org|https://ipv4.icanhazip.com|https://ifconfig.me/ip) ;;
      *) printf 'Unexpected network endpoint\n' >>"${case_dir}/forbidden"; return 99 ;;
    esac
    [[ "$network_scenario" != 'probe-failure' ]] || return 28
    if [[ "$network_scenario" == 'probe-fallback' && "${!#}" != 'https://ifconfig.me/ip' ]]; then return 28; fi
    cat -- "${case_dir}/probe-address"
    [[ "$network_scenario" != 'probe-failed-body' ]]
  }
  qrencode() {
    [[ "$1" == '-t' && "$2" == 'ANSIUTF8' && "$3" == vless://* ]] || return 99
    printf '%s\n' "$3" >>"${case_dir}/qr-links"
  }

  case "$scenario" in
    standalone-connection) show_connection node-2 ;;
    standalone-direct) show_connection node-3 ;;
    standalone-all) show_all_connections ;;
    by-id) show_connections_by_id node-2 node-3 ;;
    preview)
      prepare_connection_preview "$STATE_FILE" "${case_dir}/preview.txt" node-2 node-3
      cat -- "${case_dir}/preview.txt"
      ;;
    list|list-*) print_node_list_file "$STATE_FILE" ;;
    edit-direct|edit-direct-*)
      collect_socks_settings edit node-3 <<< ''
      printf '__INPUT_CHANGED__:%s\n' "$SOCKS_INPUT_CHANGED"
      ;;
    pure-builder) build_share_link node-2; printf '\n' ;;
    override-builder) build_share_link node-2 '203.0.113.20'; printf '\n' ;;
    override-connection) show_connection node-2 no yes '203.0.113.20' ;;
    override-all) show_all_connections '203.0.113.20' ;;
    override-direct) show_connection node-3 no yes 'fixed-entry.example.com' '198.51.100.30' ;;
    override-all-direct) show_all_connections 'fixed-entry.example.com' '198.51.100.30' ;;
    override-failed-direct) show_connection node-3 no yes 'fixed-entry.example.com' '' ;;
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
    ("standalone-connection", True), ("standalone-direct", True), ("standalone-all", True),
    ("by-id", True), ("preview", True), ("preview", False), ("list", False),
    ("list-domain", False), ("list-disabled", False), ("list-probe-failure", False),
    ("override-direct", False), ("override-all-direct", True), ("override-failed-direct", False),
    ("socks-only-domain", False), ("socks-only-disabled", False), ("socks-only-saved-present", False),
    ("edit-direct", False), ("edit-direct-probe-failure", False),
]
if len(sys.argv) > 2:
    cases = [case for case in cases if case[0] in sys.argv[2:]]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def network_scenario(scenario):
    for prefix in ("list-", "socks-only-", "edit-direct-"):
        if scenario.startswith(prefix):
            scenario = scenario[len(prefix):]
    return scenario


def fixture(scenario, folder):
    count = 30 if scenario in {"shared", "mixed", "independent", "standalone-all", "list"} else 3
    if scenario.startswith("socks-only-"):
        count = 2
    scenario = network_scenario(scenario)
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
            probe_address = (folder / "probe-address").read_text()
            status, output = capture(scenario, folder, terminal)
            require(status == 0, f"unexpected status {status}: {output}")
            output = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", output).replace("\r", "")
            nodes = state.get("nodes", [dict(id="node-1", uuid=state.get("uuid"), shortId=state.get("shortId"),
                                            spiderX="/", name=state.get("nodeName"))])
            if scenario in {"single", "pure-builder", "override-builder", "override-connection", "standalone-connection"}:
                nodes = [node for node in nodes if node["id"] == "node-2"]
            elif scenario in {"standalone-direct", "override-direct", "override-failed-direct"}:
                nodes = [node for node in nodes if node["id"] == "node-3"]
            elif scenario in {"by-id", "preview"}:
                nodes = [node for node in nodes if node["id"] in {"node-2", "node-3"}]
            refreshed = scenario in {"shared", "mixed", "independent", "single", "schema1", "repeated", "probe-fallback", "no-leak",
                                     "mixed-private", "duplicate-public", "override-builder", "override-connection", "override-all",
                                     "standalone-connection", "standalone-direct", "standalone-all", "by-id", "preview", "list"}
            address = "203.0.113.20" if refreshed else state["serverAddress"]
            if scenario in {"override-direct", "override-all-direct", "override-failed-direct"}:
                address = "fixed-entry.example.com"
            expected = [link(state, node, address) for node in nodes]
            if scenario == "repeated":
                expected += [link(state, node, "203.0.113.30") for node in nodes]
            qr_expected = expected[:] if terminal or scenario in {"override-connection", "override-direct", "override-failed-direct"} else []
            if scenario == "no-leak":
                expected += [link(state, nodes[1], state["serverAddress"])]
            list_only = scenario == "list" or scenario.startswith("list-")
            edit_only = scenario == "edit-direct" or scenario.startswith("edit-direct-")
            if list_only or edit_only:
                expected = []
                qr_expected = []
            actual = re.findall(r"^vless://[^\s]+$", output, flags=re.MULTILINE)
            require(actual == expected, f"displayed links differ beyond the expected address (expected {address})")
            require(lines(folder, "qr-links") == qr_expected, "QR inputs did not exactly match displayed links")
            probe_failed = network_scenario(scenario) in {
                "probe-failure", "probe-failed-body", "invalid-probe",
                "private-10", "private-172", "private-192", "loopback", "cgnat", "link-local"
            }
            direct_address = "未验证" if probe_failed else probe_address
            if scenario in {"override-direct", "override-all-direct"}:
                direct_address = "198.51.100.30"
            elif scenario == "override-failed-direct":
                direct_address = "未验证"
            elif scenario == "override-all":
                direct_address = address
            if edit_only:
                require(re.findall(r"当前出口：VPS 本机直连 · ([^\n]+)", output) == [direct_address],
                        "edit prompt did not refresh the direct exit")
                require("__INPUT_CHANGED__:no" in output, "empty edit input was treated as an outbound change")
            elif list_only:
                require(re.findall(r"VPS 本机直连 · 公网 IPv4：([^\n]+)", output)
                        == [direct_address] * sum(node["type"] == "direct" for node in nodes),
                        "node list did not refresh every direct exit")
                require(re.findall(r"实际出口：([^\n]+)", output) == [node["exitIp"] for node in nodes if node["type"] == "socks"],
                        "node list changed a SOCKS exit")
                require("已暂停" in output and len(re.findall(r"入口端口：", output)) == len(nodes),
                        "node list lost paused status or per-node ports")
            elif scenario not in {"pure-builder", "override-builder"}:
                expected_exits = []
                for display_address in ([address, "203.0.113.30"] if scenario == "repeated" else [address]):
                    for node in nodes:
                        if node.get("type") == "direct":
                            exit_address = display_address if scenario == "repeated" else direct_address
                            expected_exits.append(f"{exit_address}（VPS 本机）")
                        else:
                            expected_exits.append(node.get("exitIp", "未验证"))
                require(re.findall(r"^出口 IP：([^\n]+)$", output, flags=re.MULTILINE) == expected_exits,
                        "displayed direct exit did not refresh, or a SOCKS exit changed")
            for filename in ("state", "config", "render-state", "secrets"):
                require((folder / f"{filename}.json").read_bytes() == (folder / f"before-{filename}.json").read_bytes(),
                        f"show modified saved {filename}")
            require(not lines(folder, "forbidden"), "show performed a service, confirmation or unexpected network operation")
            ip_calls = lines(folder, "ip-calls")
            curl_calls = lines(folder, "curl-calls")
            environment = network_scenario(scenario)
            pure = scenario in {"pure-builder", "override-builder", "override-connection", "override-all",
                                "override-direct", "override-all-direct", "override-failed-direct"}
            no_local_lookup = pure or list_only or edit_only or environment in {"domain", "disabled"}
            require(len(ip_calls) == (0 if no_local_lookup else 2 if scenario == "repeated" else 1),
                    "local address discovery did not occur exactly once per show")
            no_probe_needed = scenario.startswith("socks-only-") and environment in {"domain", "disabled", "saved-present"}
            if pure or no_probe_needed:
                require(not curl_calls, "pure builder or explicit display context triggered public probing")
            else:
                expected_probes = 2 if scenario == "repeated" else 3 if environment in {"probe-failure", "probe-failed-body", "probe-fallback", "invalid-probe"} else 1
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
