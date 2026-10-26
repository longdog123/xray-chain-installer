#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# Exercise the real add/deploy/render/rollback path without a VPS or network.
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_worker() {
  local scenario="$1" case_dir="$2"
  # shellcheck source=../install.sh
  source "${ROOT_DIR}/install.sh"
  # Keep observable service boundaries even when production redirects systemctl.
  exec 3>&1
  export PREVIEW_SCENARIO="$scenario"
  BIN_DIR="${case_dir}/bin"
  XRAY_BIN="${BIN_DIR}/xray"
  ASSET_DIR="${case_dir}/assets"
  CONFIG_DIR="${case_dir}/config"
  CONFIG_FILE="${CONFIG_DIR}/config.json"
  STATE_FILE="${CONFIG_DIR}/state.json"
  DATA_DIR="${case_dir}/data"
  BACKUP_DIR="${DATA_DIR}/backups"
  SERVICE_FILE="${case_dir}/xray-chain.service"
  MANAGER_BIN="${case_dir}/puppyip"
  LEGACY_MANAGER_BIN="${case_dir}/xray-chain"
  RUNTIME_GROUP="$(id -gn)"
  mkdir -p "$BIN_DIR" "$ASSET_DIR" "$CONFIG_DIR" "$BACKUP_DIR" "${case_dir}/work"

  cat >"$XRAY_BIN" <<'XRAY'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$*" == 'run -test -c '* ]] || exit 99
jq -e '.inbounds[0].settings.clients | length > 0' "$4" >/dev/null
[[ "$PREVIEW_SCENARIO" != 'validation-failure' ]] || exit 1
printf '__VALIDATED__\n' >&3
XRAY
  chmod 0755 "$XRAY_BIN"
  printf 'fixture-geoip\n' >"${ASSET_DIR}/geoip.dat"
  printf 'fixture-geosite\n' >"${ASSET_DIR}/geosite.dat"
  printf 'fixture-service\n' >"$SERVICE_FILE"
  printf 'old-manager\n' >"$MANAGER_BIN"
  printf 'old-legacy-manager\n' >"$LEGACY_MANAGER_BIN"
  cat >"$STATE_FILE" <<'STATE'
{
  "schema": 2,
  "installedAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-01T00:00:00Z",
  "installerVersion": "fixture",
  "xrayVersion": "v26.3.27",
  "serverAddress": "203.0.113.10",
  "inboundPort": 443,
  "realityTarget": "www.example.com:443",
  "serverName": "www.example.com",
  "realityPublicKey": "fixture-public-key",
  "nextNodeNumber": 2,
  "nodes": [{
    "id": "node-1", "number": 1, "name": "PuppyIP-198.51.100.1",
    "email": "node-1@puppyip.local",
    "uuid": "11111111-1111-4111-8111-111111111111",
    "shortId": "1111111111111111", "spiderX": "/1111111111111111",
    "udpMode": "proxy", "enabled": true, "type": "socks",
    "socksHost": "198.51.100.1", "socksPort": 1080,
    "socksUser": "fixture-user", "exitIp": "198.51.100.1"
  }]
}
STATE
  if [[ "$scenario" == port-* ]]; then
    jq '.inboundPort = 62002 | .nextNodeNumber = 4 | .nodes += [
      (.nodes[0] + {id:"node-2", number:2, name:"Paused exit",
        email:"node-2@puppyip.local", uuid:"22222222-2222-4222-8222-222222222222",
        shortId:"2222222222222222", spiderX:"/2222222222222222", enabled:false,
        socksHost:"198.51.100.2", socksUser:"fixture-paused", exitIp:"198.51.100.2"}),
      (.nodes[0] + {id:"node-3", number:3, name:"Direct exit",
        email:"node-3@puppyip.local", uuid:"33333333-3333-4333-8333-333333333333",
        shortId:"3333333333333333", spiderX:"/3333333333333333", type:"direct",
        socksHost:"", socksPort:0, socksUser:"", exitIp:"203.0.113.10"})
    ]' "$STATE_FILE" >"${STATE_FILE}.new"
    mv -- "${STATE_FILE}.new" "$STATE_FILE"
    case "$scenario" in
      port-split|port-stopped)
        jq '(.nodes[] | select(.id == "node-2") | .inboundPort) = 62007
          | (.nodes[] | select(.id == "node-3") | .inboundPort) = 62008' \
          "$STATE_FILE" >"${STATE_FILE}.new"
        mv -- "${STATE_FILE}.new" "$STATE_FILE"
        ;;
      port-single|port-single-split)
        jq '.nodes = [.nodes[0]] | .nextNodeNumber = 2' "$STATE_FILE" >"${STATE_FILE}.new"
        mv -- "${STATE_FILE}.new" "$STATE_FILE"
        if [[ "$scenario" == 'port-single-split' ]]; then
          jq '.nodes[0].inboundPort = 62007' "$STATE_FILE" >"${STATE_FILE}.new"
          mv -- "${STATE_FILE}.new" "$STATE_FILE"
        fi
        ;;
    esac
  fi
  MODEL_FILE="$STATE_FILE"
  SECRETS_FILE="${case_dir}/initial-secrets.json"
  printf '{"node-1":"fixture-old-password","node-2":"fixture-paused-password"}\n' >"$SECRETS_FILE"
  PRIVATE_KEY='fixture-private-key'
  render_config "$CONFIG_FILE" "${case_dir}/work"
  cp -- "$STATE_FILE" "${case_dir}/old-state.json"
  cp -- "$CONFIG_FILE" "${case_dir}/old-config.json"

  # Boundaries requiring root, a live host, randomness, or operator input.
  require_root() { :; }
  check_platform() { :; }
  require_systemd() { :; }
  acquire_lock() { :; }
  refresh_brand_banner() { :; }
  if [[ "$scenario" != port-* ]]; then
    assert_model_port_available() { :; }
  fi
  ensure_runtime_layout() { :; }
  cleanup_runtime_layout_created_this_run() { :; }
  sleep() {
    if [[ ( "$scenario" == 'preview-interrupt' || "$scenario" == 'port-interrupt' ) && "$1" == '2' ]]; then
      kill -INT "$$"
    fi
  }
  generate_reality_identity() { :; }
  new_temp_dir() { LAST_TEMP_DIR="${case_dir}/work"; }
  curl() { printf 'Unexpected network request\n' >&2; return 99; }
  ufw() { printf 'Status: active\n'; }
  firewall-cmd() { return 1; }
  collect_panel_reserved_ports() { PANEL_RESERVED_PORTS=(62003); }
  PORT_CANDIDATE_CALLS=0
  generate_auto_port_candidate() {
    local -a candidates=(62002 443 62003 62004 62005 62006)
    case "$scenario" in
      port-split|port-stopped) candidates=(62002 62007 62008 443 62003 62004 62005 62006) ;;
      port-single-split) candidates=(62002 62007 443 62003 62004 62005 62006) ;;
    esac
    ((PORT_CANDIDATE_CALLS += 1))
    printf '%s\n' "$PORT_CANDIDATE_CALLS" >"${case_dir}/candidate-count"
    if [[ "$scenario" == 'port-exhaustion-failure' ]]; then
      AUTO_PORT_CANDIDATE=62002
    else
      AUTO_PORT_CANDIDATE="${candidates[$(((PORT_CANDIDATE_CALLS - 1) % ${#candidates[@]}))]}"
    fi
  }
  ss() {
    printf '%s\n' 'tcp LISTEN 0 128 0.0.0.0:62004 0.0.0.0:*' \
      'udp UNCONN 0 0 [::]:62005 [::]:*'
    if [[ "$scenario" == 'port-race-failure' && -e "${case_dir}/work/candidate-state.json" ]]; then
      printf '%s\n' 'tcp LISTEN 0 128 0.0.0.0:62006 0.0.0.0:*'
    fi
  }
  collect_socks_batch_settings() {
    if [[ "$scenario" == 'direct' ]]; then
      ADD_DIRECT_NODE='yes'
      SOCKS_BATCH_ENTRIES=()
    else
      ADD_DIRECT_NODE='no'
      SOCKS_BATCH_ENTRIES=(
        '198.51.100.2:1080:fixture-two:fixture-password-two'
        '198.51.100.3:1080:fixture-three:fixture-password-three'
      )
    fi
  }
  collect_socks_settings() {
    NODE_TYPE='socks'
    SOCKS_HOST='198.51.100.2'
    SOCKS_PORT='1080'
    SOCKS_USER='fixture-edit'
    SOCKS_PASS='fixture-edit-password'
    SOCKS_INPUT_CHANGED='yes'
  }
  prompt_yes_no() { printf -v "$1" '%s' "$3"; }
  verify_socks_proxy() { SOCKS_EXIT_IP="$SOCKS_HOST"; }
  verify_direct_outbound() { SOCKS_EXIT_IP='203.0.113.10'; }
  generate_node_identity() {
    local number
    number="$(jq -r '.nextNodeNumber' "$MODEL_FILE")"
    printf -v UUID '%08d-2222-4222-8222-%012d' "$number" "$number"
    printf -v SHORT_ID '%016d' "$number"
    SPIDER_X="/${SHORT_ID}"
  }
  qrencode() {
    [[ "$1" == '-t' && "$2" == 'ANSIUTF8' && "$3" == vless://* ]]
    [[ "$scenario" != 'qr-error' ]] || return 1
    local identity="${3#vless://}"
    printf '__QR__:%s\n' "${identity%%@*}"
  }
  if [[ "$scenario" == 'preview-render-failure' ]]; then
    show_connection() { return 1; }
  fi
  cat() {
    if [[ "$scenario" == 'preview-output-failure' && "${!#}" == */new-connections.txt ]]; then
      printf '__PREVIEW_OUTPUT_FAILED__\n' >&3
      return 1
    fi
    command cat "$@"
  }

  # Retain atomic_install itself; remove ownership requirements at the OS edge
  # and inject failures in the real transaction's install(1) operation.
  install() {
    local argument destination="${!#}" failure_destination=''
    local -a arguments=()
    case "$scenario" in
      config-write-failure) failure_destination="$CONFIG_FILE" ;;
      state-write-failure) failure_destination="$STATE_FILE" ;;
      manager-write-failure) failure_destination="$LEGACY_MANAGER_BIN" ;;
    esac
    if [[ -n "$failure_destination" && "$destination" == "${failure_destination}.new."* ]]; then
      printf '__WRITE_FAILED__\n' >&3
      return 1
    fi
    while (( $# > 0 )); do
      argument="$1"
      shift
      case "$argument" in
        -o|-g) shift ;;
        *) arguments+=("$argument") ;;
      esac
    done
    if [[ "$destination" == *.new.* ]]; then
      printf '__FILE_INSTALL__\n' >&3
    fi
    command install "${arguments[@]}"
    if [[ "$destination" == "${LEGACY_MANAGER_BIN}.new."* ]]; then
      printf '__FILES_WRITTEN__\n' >&3
    fi
  }
  systemctl() {
    case "${1:-}" in
      restart)
        if [[ ! -e "${case_dir}/restarted" ]]; then
          : >"${case_dir}/restarted"
          cp -- "$STATE_FILE" "${case_dir}/state-at-restart.json"
          cp -- "$CONFIG_FILE" "${case_dir}/config-at-restart.json"
          printf '__FIRST_RESTART__\n' >&3
          [[ "$scenario" != 'restart-failure' && "$scenario" != 'port-restart-failure' ]] || return 1
        fi
        ;;
      is-active)
        if [[ ( "$scenario" == 'health-failure' || "$scenario" == 'port-health-failure' ) \
          && -e "${case_dir}/restarted" ]]; then
          return 1
        fi
        if [[ "$scenario" == 'port-stopped' && ! -e "${case_dir}/restarted" ]]; then
          return 1
        fi
        ;;
      is-enabled|enable|disable|daemon-reload) ;;
      *) printf 'Unexpected systemctl: %s\n' "$*" >&2; return 99 ;;
    esac
  }

  case "$scenario" in
    port-*)
      XRAY_CHAIN_PORT='62099'
      case "$scenario" in
        port-menu)
          installation_complete() { return 0; }
          running_as_installed_manager() { return 0; }
          show_brand_banner() { :; }
          (main)
          ;;
        port-interactive|port-single|port-single-split) main port ;;
        port-paused|port-split|port-stopped) main port node-2 ;;
        *) main port 1 ;;
      esac
      [[ "$XRAY_CHAIN_PORT" == '62099' ]]
      printf '__PORT_DONE__\n'
      ;;
    pause) command_pause 1 ;;
    edit) command_edit 1 ;;
    *) command_add no ;;
  esac
}

if [[ "${1:-}" == '--case' ]]; then
  run_worker "$2" "$3"
  exit
fi

for command_name in jq python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '缺少测试依赖：%s\n' "$command_name" >&2
    exit 1
  }
done

# PTY capture checks the actual terminal-only QR path. The same suite includes
# redirected stdout, where share links must work without attempting QR output.
python3 - "${BASH_SOURCE[0]}" <<'PY'
import errno
from copy import deepcopy
import json
import os
from pathlib import Path
import pty
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote

script = str(Path(sys.argv[1]).resolve())
cases = [
    ("batch", True), ("batch", False), ("direct", True),
    ("validation-failure", True), ("config-write-failure", True),
    ("state-write-failure", True), ("manager-write-failure", True),
    ("restart-failure", True), ("health-failure", True),
    ("preview-render-failure", True), ("preview-output-failure", True),
    ("preview-interrupt", True),
    ("qr-error", True),
    ("pause", True), ("edit", True),
    ("port-active", True), ("port-active", False), ("port-stopped", True),
    ("port-interactive", True), ("port-menu", True), ("port-paused", True),
    ("port-split", True), ("port-single", False), ("port-single-split", False),
    ("port-exhaustion-failure", True), ("port-race-failure", True),
    ("port-restart-failure", True), ("port-health-failure", True),
    ("port-interrupt", True),
]


def capture(scenario, case_dir, terminal):
    command = ["bash", script, "--case", scenario, str(case_dir)]
    if not terminal:
        result = subprocess.run(command, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=30)
        return result.returncode, result.stdout.decode()
    master, slave = pty.openpty()
    interactive = scenario in {"port-interactive", "port-menu"}
    process = subprocess.Popen(command, stdin=slave if interactive else subprocess.DEVNULL,
                               stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    if interactive:
        os.write(master, b"2\n2\n\n0\n" if scenario == "port-menu" else b"2\n")
    chunks = []
    try:
        while True:
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
    return process.wait(timeout=30), b"".join(chunks).decode()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def expected_link(state, node):
    return (
        f"vless://{node['uuid']}@{state['serverAddress']}:{node.get('inboundPort', state['inboundPort'])}"
        "?encryption=none&flow=xtls-rprx-vision&security=reality"
        f"&sni={quote(state['serverName'], safe='')}&fp=chrome"
        f"&pbk={quote(state['realityPublicKey'], safe='')}"
        f"&sid={node['shortId']}&spx={quote(node['spiderX'], safe='')}"
        f"&type=tcp&headerType=none#{quote(node['name'], safe='')}"
    )


def assert_config_groups(state, config):
    groups = {}
    for node in state["nodes"]:
        groups.setdefault(node.get("inboundPort", state["inboundPort"]), []).append(node)
    inbounds = {inbound["port"]: inbound for inbound in config["inbounds"]}
    require(len(inbounds) == len(config["inbounds"]) and set(inbounds) == set(groups),
            "runtime listeners do not match the nodes' effective ports")
    for port, nodes in groups.items():
        inbound = inbounds[port]
        require(inbound["tag"] == ("vless-in" if port == state["inboundPort"] else f"vless-in-{port}"),
                "incorrect listener tag for a node port")
        expected_clients = [
            {"id": node["uuid"], "email": node["email"], "flow": "xtls-rprx-vision"}
            for node in nodes]
        require(sorted(inbound["settings"]["clients"], key=lambda client: client["id"])
                == sorted(expected_clients, key=lambda client: client["id"]),
                "a listener accepts clients belonging to a different port")
        require(sorted(inbound["streamSettings"]["realitySettings"]["shortIds"])
                == sorted(node["shortId"] for node in nodes),
                "a listener accepts short IDs belonging to a different port")
    require(set(config["routing"]["rules"][-1]["inboundTag"]) == {item["tag"] for item in inbounds.values()},
            "fallback routing does not cover every listener")


def assert_port_case(scenario, case_dir, terminal, status, output, failed_deploy):
    require(("__PORT_DONE__" in output) != failed_deploy,
            "port change reported incorrect completion status")
    if failed_deploy:
        require(not re.search(r"入口端口已.*更换", output), "failed port change announced success")
    if scenario in {"port-exhaustion-failure", "port-race-failure"}:
        require("__FILE_INSTALL__" not in output and "__FIRST_RESTART__" not in output,
                "unavailable port changed managed files or restarted the service")
        require("vless://" not in output, "unavailable port produced client links")
        if scenario == "port-exhaustion-failure":
            require((case_dir / "candidate-count").exists(), "random selection was not exercised")
            require((case_dir / "candidate-count").read_text().strip() == "128",
                    "random selection did not stop after 128 excluded candidates")
        else:
            require((case_dir / "work/candidate-state.json").exists(),
                    "port race did not reach candidate configuration validation")
            require("62006" in output and "占用" in output,
                    "port race did not report the newly occupied candidate")
        return
    require(output.count("__FIRST_RESTART__") == 1, "missing port change restart boundary")
    before, after = output.split("__FIRST_RESTART__", 1)
    state = json.loads((case_dir / "work/candidate-state.json").read_text())
    config = json.loads((case_dir / "work/candidate-config.json").read_text())
    old_state = json.loads((case_dir / "old-state.json").read_text())
    old_config = json.loads((case_dir / "old-config.json").read_text())
    selected_id = "node-2" if scenario in {
        "port-interactive", "port-menu", "port-paused", "port-split", "port-stopped"
    } else "node-1"
    old_nodes = {node["id"]: node for node in old_state["nodes"]}
    selected = next(node for node in state["nodes"] if node["id"] == selected_id)
    require(selected.get("inboundPort") == 62006 and state["inboundPort"] == old_state["inboundPort"],
            "port command did not change only the selected node's port")
    expected_state = deepcopy(old_state)
    next(node for node in expected_state["nodes"] if node["id"] == selected_id)["inboundPort"] = 62006
    metadata = {"updatedAt", "installerVersion", "xrayVersion"}
    require({k: v for k, v in state.items() if k not in metadata}
            == {k: v for k, v in expected_state.items() if k not in metadata},
            "port change altered another node, an exit, credentials or enabled state")
    assert_config_groups(state, config)
    expected_config = deepcopy(old_config)
    expected_config["inbounds"] = []
    for inbound in config["inbounds"]:
        expected = deepcopy(old_config["inbounds"][0])
        expected["tag"] = inbound["tag"]
        expected["port"] = inbound["port"]
        expected["settings"]["clients"] = inbound["settings"]["clients"]
        expected["streamSettings"]["realitySettings"]["shortIds"] = inbound["streamSettings"]["realitySettings"]["shortIds"]
        expected_config["inbounds"].append(expected)
    expected_config["routing"]["rules"][-1]["inboundTag"] = config["routing"]["rules"][-1]["inboundTag"]
    require(config == expected_config, "port change altered runtime credentials or routing")
    if selected["enabled"] is False:
        require("状态：已暂停" in before, "selected paused node lost its paused status")
    if scenario in {"port-interactive", "port-menu"}:
        require("请输入节点编号" in before, "interactive port change did not ask which node to change")
    for node in state["nodes"]:
        link = expected_link(state, node)
        if node["id"] != selected_id:
            require(link == expected_link(old_state, old_nodes[node["id"]]), "another node's link changed")
            require(link not in output and f"__QR__:{node['uuid']}" not in output,
                    "port change previewed an unselected node")
            continue
        require(link in before and output.count(link) == 1,
                f"updated link {node['id']} missing before restart or duplicated")
        require(expected_link(old_state, old_nodes[node["id"]]) not in output, "old-port link was displayed")
        qr = f"__QR__:{node['uuid']}"
        require((qr in before) == terminal and output.count(qr) == int(terminal),
                f"incorrect updated QR timing for {node['id']}")
    require(before.index("__VALIDATED__") < before.index("__FILES_WRITTEN__") < before.index("vless://"),
            "updated links appeared before validation or successful file writes")
    old_port = old_nodes[selected_id].get("inboundPort", old_state["inboundPort"])
    require(str(old_port) in before and "62006" in before, "old/new port information missing before restart")
    require("放行" in before and "62006/tcp" in before, "new firewall rule missing before restart")
    require("客户端" in before and ("更新" in before or "重新导入" in before), "client link update advice missing")
    require("待生效" in before and "新节点配置" not in before, "incorrect port-change preview status")
    require("__PORT_DONE__" not in before, "port change reported success before restart")
    require(not re.search(r"入口端口已.*更换", before), "port change announced success before restart")
    if scenario == "port-interrupt":
        require(status == 130, "interrupted port change did not exit with status 130")
        for filename in ("state", "config"):
            require((case_dir / f"{filename}-at-restart.json").read_bytes()
                    == (case_dir / f"old-{filename}.json").read_bytes(),
                    f"interrupted port change restarted before restoring old {filename}")
    elif not failed_deploy:
        require("__PORT_DONE__" in after, "successful port change did not finish")
        require(re.search(r"入口端口已.*更换", after), "successful port change did not report completion")
        require(json.loads((case_dir / "config/state.json").read_text()) == state,
                "successful port change did not persist the displayed state")


failures = []
with tempfile.TemporaryDirectory(prefix="xray-chain-add-preview.") as directory:
    for index, (scenario, terminal) in enumerate(cases):
        case_dir = Path(directory) / str(index)
        case_dir.mkdir()
        status, output = capture(scenario, case_dir, terminal)
        output = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", output).replace("\r", "")
        name = f"{scenario} ({'TTY' if terminal else 'pipe'})"
        try:
            failed_deploy = scenario.endswith("failure") or scenario.endswith("interrupt")
            require((status != 0) == failed_deploy,
                    f"unexpected command status {status}:\n{output}")
            saved_state = json.loads((case_dir / "config/state.json").read_text())
            if failed_deploy:
                for filename in ("state", "config"):
                    require((case_dir / f"config/{filename}.json").read_bytes()
                            == (case_dir / f"old-{filename}.json").read_bytes(),
                            f"failed deployment did not restore old {filename}")
                require("已添加" not in output, "failed deployment announced success")
            if scenario.startswith("port-"):
                assert_port_case(scenario, case_dir, terminal, status, output, failed_deploy)
            elif scenario in {"validation-failure", "config-write-failure",
                            "state-write-failure", "manager-write-failure",
                            "preview-render-failure", "preview-output-failure"}:
                require("vless://" not in output and "__QR__:" not in output,
                        "preview appeared before validation and all writes succeeded")
                if scenario in {"validation-failure", "preview-render-failure"}:
                    require("__FIRST_RESTART__" not in output,
                            "validation/rendering failure restarted the service")
                    require("__FILE_INSTALL__" not in output,
                            "validation/rendering failure wrote managed files")
                if scenario == "preview-output-failure":
                    require("__PREVIEW_OUTPUT_FAILED__" in output,
                            "preview output failure was not exercised")
                    require("__FILES_WRITTEN__" in output,
                            "output failure did not exercise rollback after writes")
            elif scenario == "preview-interrupt":
                require(status == 130, "interrupted preview did not exit with status 130")
                require("__FIRST_RESTART__" in output, "interrupt did not restart the restored service")
                before = output.split("__FIRST_RESTART__", 1)[0]
                require("vless://" in before, "interruption did not occur after displaying the preview")
                for filename in ("state", "config"):
                    require((case_dir / f"{filename}-at-restart.json").read_bytes()
                            == (case_dir / f"old-{filename}.json").read_bytes(),
                            f"interrupt restarted the service before restoring old {filename}")
            else:
                require(output.count("__FIRST_RESTART__") == 1,
                        "missing first service restart boundary")
                before, after = output.split("__FIRST_RESTART__", 1)
                if scenario in {"pause", "edit"}:
                    require("vless://" not in before and "__QR__:" not in before,
                            "non-add operation previewed links before restart")
                    if scenario == "pause":
                        require(saved_state["nodes"][0]["enabled"] is False,
                                "pause did not save the disabled state")
                        require("vless://" not in output, "pause displayed a link")
                    else:
                        require("客户端导入链接" in after, "edit lost its normal final output")
                else:
                    state = json.loads((case_dir / "state-at-restart.json").read_text())
                    config = json.loads((case_dir / "config-at-restart.json").read_text())
                    added = [node for node in state["nodes"] if node["number"] > 1]
                    require(len(added) == (1 if scenario == "direct" else 2),
                            "unexpected number of newly saved nodes")
                    require(sum(len(inbound["settings"]["clients"]) for inbound in config["inbounds"]) == len(state["nodes"]),
                            "installed config does not contain every saved node")
                    ports = [node.get("inboundPort", state["inboundPort"]) for node in state["nodes"]]
                    require(len(set(ports)) == len(ports), "new nodes did not receive independent entrance ports")
                    assert_config_groups(state, config)
                    for node in added:
                        link = expected_link(state, node)
                        require(link in before,
                                f"new link {node['id']} was not visible before restart")
                        require(output.count(link) == 1,
                                f"new link {node['id']} was displayed more than once")
                        qr = f"__QR__:{node['uuid']}"
                        expect_qr = terminal and scenario != "qr-error"
                        require((qr in before) == expect_qr,
                                f"incorrect QR timing/TTY behavior for {node['id']}")
                        require(output.count(qr) == (1 if expect_qr else 0),
                                f"QR for {node['id']} was duplicated")
                    require(expected_link(state, state["nodes"][0]) not in output,
                            "add displayed an existing node's link")
                    first_link = before.index("vless://")
                    require(before.index("__VALIDATED__") < before.index("__FILES_WRITTEN__") < first_link,
                            "preview preceded validation or completion of file writes")
                    require("待生效" in before, "preview did not explain that activation is pending")
                    require("已添加" not in before, "success announced before service restart")
                    if not failed_deploy:
                        require("已添加" in after, "successful add did not report completion")
            print(f"PASS: {name}")
        except (AssertionError, ValueError, OSError) as error:
            failures.append((name, str(error)))
            print(f"FAIL: {name}: {error}", file=sys.stderr)

if failures:
    raise SystemExit(f"新增节点重启前预览检查失败：{len(failures)}/{len(cases)}")
print(f"新增节点重启前预览检查通过：{len(cases)} 个场景。")
PY
