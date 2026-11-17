#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# Real address transaction/link/render paths; synthetic files and no live network.
set -Eeuo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_worker() {
  local scenario="$1" case_dir="$2" value="$3" status=0 node_id display_output
  # shellcheck source=../install.sh
  source "${ENTRY_ADDRESS_SCRIPT:-${ROOT_DIR}/install.sh}"
  STATE_FILE="${case_dir}/state.json"
  CONFIG_FILE="${case_dir}/config.json"
  CONFIG_DIR="$case_dir"
  DATA_DIR="${case_dir}/data"
  BACKUP_DIR="${DATA_DIR}/backups"
  LOCK_FILE="${case_dir}/operation.lock"
  XRAY_BIN="${case_dir}/xray"
  ASSET_DIR="${case_dir}/assets"
  SERVICE_FILE="${case_dir}/xray-chain.service"
  MANAGER_BIN="${case_dir}/puppyip"
  LEGACY_MANAGER_BIN="${case_dir}/xray-chain"
  PRIVATE_KEY='fixture-private-key'
  unset XRAY_CHAIN_ADDRESS XRAY_CHAIN_AUTO_ADDRESS XRAY_CHAIN_PORT
  [[ "$scenario" != 'display-disabled-all-pipe' ]] || export XRAY_CHAIN_AUTO_ADDRESS=0
  # These boundary functions are called indirectly by the sourced production code.
  # shellcheck disable=SC2317
  require_root() { :; }
  # shellcheck disable=SC2317
  systemctl() { printf 'service\n' >>"${case_dir}/forbidden"; return 99; }
  # shellcheck disable=SC2317
  confirm_continue() { printf 'confirmation\n' >>"${case_dir}/forbidden"; return 99; }
  # shellcheck disable=SC2317
  getent() { printf 'dns\n' >>"${case_dir}/forbidden"; return 99; }
  # shellcheck disable=SC2317
  dig() { printf 'dns\n' >>"${case_dir}/forbidden"; return 99; }
  # shellcheck disable=SC2317
  host() { printf 'dns\n' >>"${case_dir}/forbidden"; return 99; }
  # shellcheck disable=SC2317
  ip() {
    printf '%s\n' "$*" >>"${case_dir}/ip-calls"
    [[ "$*" == '-j -4 address show scope global' ]] || return 99
    [[ "$scenario" != 'auto-ip-failure' ]] || return 1
    cat -- "${case_dir}/local-addresses.json"
  }
  # shellcheck disable=SC2317
  curl() {
    printf '%s\n' "${!#}" >>"${case_dir}/curl-calls"
    case "${!#}" in
      https://api.ipify.org|https://ipv4.icanhazip.com|https://ifconfig.me/ip) ;;
      *) printf 'network\n' >>"${case_dir}/forbidden"; return 99 ;;
    esac
    cat -- "${case_dir}/public-address"
    [[ "$scenario" != 'auto-probe-failure' ]]
  }
  jq() {
    local argument candidate_generation='no'
    for argument in "$@"; do
      # Match the literal jq program, whose $address is a jq variable.
      # shellcheck disable=SC2016
      [[ "$argument" != '.serverAddress = $address' ]] || candidate_generation='yes'
    done
    if [[ "$scenario" == 'precision-loss' && "$candidate_generation" == 'yes' ]]; then
      command jq "$@" | python3 -c '
import pathlib, re, sys
raw = sys.stdin.buffer.read()
changed, count = re.subn(rb"(\"externalId\"\s*:\s*)9007199254740993(?![0-9])",
                         rb"\g<1>9007199254740992", raw, count=1)
assert count == 1, "precision injection target missing"
pathlib.Path(sys.argv[1]).write_text("candidate-only\n")
sys.stdout.buffer.write(changed)
' "${case_dir}/precision-injected"
    else
      command jq "$@"
    fi
  }
  # Preserve the actual atomic implementation; only adapt ownership for hosted non-root runners.
  # shellcheck disable=SC2317
  install() {
    local owner='' group='' mode='' destination="${!#}" argument directory='no'
    local -a arguments=()
    while (( $# > 0 )); do
      argument="$1"; shift
      case "$argument" in
        -o) owner="$1"; shift ;;
        -g) group="$1"; shift ;;
        -m) mode="$1"; arguments+=("-m" "$1"); shift ;;
        -m*) mode="${argument#-m}"; arguments+=("$argument") ;;
        -d) directory='yes'; arguments+=("$argument") ;;
        *) arguments+=("$argument") ;;
      esac
    done
    if [[ "$directory" == 'no' && "$destination" == */state.json* ]]; then
      [[ "$owner" == root && "$group" == root && "$mode" == 0600 ]] || {
        printf 'ownership\n' >>"${case_dir}/forbidden"; return 99;
      }
    fi
    printf '%s\n' "$destination" >>"${case_dir}/install-calls"
    if [[ "$scenario" == 'backup-failure' && "$destination" == "$BACKUP_DIR"/entry-address.*/state.json ]]; then
      return 73
    fi
    command install "${arguments[@]}"
  }
  # shellcheck disable=SC2317
  mv() {
    if [[ "${!#}" == "$STATE_FILE" ]]; then
      printf 'replace\n' >>"${case_dir}/replacements"
      [[ "$scenario" != 'atomic-failure' ]] || return 74
    fi
    command mv "$@"
  }
  # shellcheck disable=SC2317
  qrencode() { printf '%s\n' "$3" >>"${case_dir}/qr-links"; }
  # shellcheck disable=SC2317
  generate_reality_identity() { PUBLIC_KEY='fixture-public-key'; }
  # shellcheck disable=SC2317
  generate_unique_node_identity() {
    UUID='ffffffff-ffff-4fff-8fff-ffffffffffff'; SHORT_ID='ffffffffffffffff'; SPIDER_X='/new-fixture';
  }
  # shellcheck disable=SC2317
  select_inbound_port() { INBOUND_PORT=63000; }
  mkdir -p "$BACKUP_DIR" "${case_dir}/model-work"

  if [[ "$scenario" == initial-* ]]; then
    [[ "$scenario" == 'initial-default' ]] || export XRAY_CHAIN_ADDRESS="$value"
    set +e
    ( set -e; collect_global_settings; printf '%s\n' "$SERVER_ADDRESS" >"${case_dir}/initial-address" ) \
      >"${case_dir}/display" 2>&1
    status=$?
    set -e
  else
    if [[ "$(jq -r '.schema // 1' "$STATE_FILE")" == 2 ]]; then
      render_config "$CONFIG_FILE" "$case_dir" "$STATE_FILE" "${case_dir}/secrets.json"
    fi
    command cp -- "$CONFIG_FILE" "${case_dir}/before-config.json"
    while IFS= read -r node_id; do build_share_link "$node_id"; printf '\n'; done \
      <"${case_dir}/node-ids" >"${case_dir}/before-links"
    if [[ "$scenario" == 'lock-busy' ]]; then
      exec 8>"$LOCK_FILE"
      flock -n 8
    fi
    display_output="${case_dir}/display"
    [[ "$scenario" != display-* ]] || display_output='/dev/stdout'
    set +e
    (
      set -e
      case "$scenario" in
        display-command-all-tty) command_show all ;;
        display-command-single-tty) command_show 2 ;;
        display-main-all-pipe) main show all ;;
        display-standalone-noqr-tty) show_connection node-2 no no ;;
        display-standalone-qr-pipe) show_connection node-3 no yes ;;
        display-all-tty|display-disabled-all-pipe|display-legacy-all-tty) show_all_connections ;;
        display-by-id-tty) show_connections_by_id node-2 node-3 ;;
        display-preview-tty|display-preview-pipe)
          prepare_connection_preview "$STATE_FILE" "${case_dir}/preview.txt" node-2 node-3
          cat -- "${case_dir}/preview.txt"
          ;;
        display-list-pipe) command_list ;;
        display-list-helper-pipe) print_node_list_file "$STATE_FILE" ;;
        empty-tty|domain-tty|no-argument) command_address ;;
        cli) main address "$value" ;;
        extra-argument) command_address "$value" unexpected ;;
        *) command_address "$value" ;;
      esac
    ) >"$display_output" 2>&1
    status=$?
    set -e
    while IFS= read -r node_id; do build_share_link "$node_id"; printf '\n'; done \
      <"${case_dir}/node-ids" >"${case_dir}/after-links"
    if [[ "$status" == 0 && "$scenario" == 'domain-retained' ]]; then
      load_model "${case_dir}/model-work" "$XRAY_BIN"
      render_config "${case_dir}/candidate-config.json" "$case_dir" "$MODEL_FILE" "$SECRETS_FILE"
      assert_upgrade_invariants "$STATE_FILE" "$CONFIG_FILE" "$MODEL_FILE" "${case_dir}/candidate-config.json"
      NODE_TYPE='socks'; SOCKS_HOST='192.0.2.90'; SOCKS_PORT=2080
      SOCKS_USER='fixture-new-user'; SOCKS_PASS='fixture-new-password'; SOCKS_EXIT_IP='192.0.2.91'
      append_current_node_to_model "$XRAY_BIN"
      command cp -- "$MODEL_FILE" "${case_dir}/after-add-model.json"
      STATE_FILE="$MODEL_FILE" build_share_link "$SELECTED_NODE_ID" >"${case_dir}/after-add-link"
      show_all_connections '' '' >"${case_dir}/shown-links"
      show_connection node-1 no yes >"${case_dir}/shown-qr"
    fi
  fi
  printf '%s\n' "$status" >"${case_dir}/status"
}

if [[ "${1:-}" == '--case' ]]; then
  run_worker "$2" "$3" "$4"
  exit
fi
for dependency in jq python3 flock; do command -v "$dependency" >/dev/null || exit 1; done
python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import copy
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

script = str(Path(sys.argv[1]).resolve())
domain = "entry.example.com"
cases = [(name, "Entry.Example.COM.") for name in
         ("shared", "mixed", "independent", "all-paused", "schema1", "cli", "domain-retained")]
cases += [("ipv4", "203.0.113.30"), ("same", "Entry.Example.COM."), ("empty-tty", ""),
          ("domain-tty", "Entry.Example.COM."), ("no-argument", ""), ("empty-argument", ""),
          ("extra-argument", domain), ("backup-failure", domain), ("atomic-failure", domain), ("lock-busy", domain)]
cases += [("large-number", domain), ("precision-loss", domain)]
cases += [(name, "auto") for name in ("auto", "auto-ambiguous", "auto-nat", "auto-private", "auto-ip-failure", "auto-probe-failure")]
cases += [("malformed-" + str(index), value) for index, value in enumerate([
    "https://fixture-user:fixture-password@entry.example.com", "entry.example.com:443", "localhost",
    "bad..example.com", "entry_example.com", "-bad.example.com", "203.0.113.999",
    "entry.example.com/fixture-password", "entry.example.com\nfixture-password", "entry.example.com.."])]
cases += [("initial-domain", "Entry.Example.COM."), ("initial-ipv4", "203.0.113.30"),
          ("initial-default", ""), ("initial-invalid", "https://fixture-user:fixture-password@entry.example.com")]
cases += [(name, domain) for name in (
    "display-command-all-tty", "display-command-single-tty", "display-main-all-pipe",
    "display-standalone-noqr-tty", "display-standalone-qr-pipe", "display-all-tty",
    "display-by-id-tty", "display-preview-tty", "display-preview-pipe", "display-list-pipe",
    "display-list-helper-pipe", "display-legacy-all-tty", "display-disabled-all-pipe")]
if len(sys.argv) > 2:
    cases = [case for case in cases if case[0] in sys.argv[2:]]
failures = []

def require(condition, message):
    if not condition:
        raise AssertionError(message)

def lines(path):
    return path.read_text().splitlines() if path.exists() else []

def fixture(folder, scenario):
    count = 30 if scenario in {"shared", "mixed", "independent", "all-paused"} else 3
    nodes = []
    for number in range(1, count+1):
        node = dict(id=f"node-{number}", number=number, email=f"node-{number}@puppyip.local",
                    name=f"Fixture {number}", uuid=f"{number:08d}-1111-4111-8111-{number:012d}",
                    shortId=f"{number:016d}", spiderX=f"/fixture/{number}?mode=test", enabled=number % 3 != 2,
                    type="direct" if number % 3 == 0 else "socks", udpMode="block" if number % 2 else "proxy",
                    socksHost=f"198.51.100.{number}", socksPort=1080+number,
                    socksUser=f"fixture-user-{number}", exitIp=f"198.51.100.{number}", unknownNodeField={"keep": number})
        if node["type"] == "direct":
            node.update(socksHost="", socksPort=0, socksUser="", exitIp="203.0.113.10", udpMode="proxy")
        if scenario == "independent" or (scenario != "shared" and number % 2 == 0):
            node["inboundPort"] = 62000+number
        if scenario == "all-paused":
            node["enabled"] = False
        nodes.append(node)
    state = dict(schema=2, serverAddress=domain if scenario == "same" or scenario.startswith("display-") else "203.0.113.10",
                 inboundPort=443, realityTarget="www.example.com:443", serverName="www.example.com",
                 realityPublicKey="fixture-public-key", installedAt="2026-01-01T00:00:00Z",
                 updatedAt="2026-01-02T00:00:00Z", installerVersion="fixture", xrayVersion="v26.3.27",
                 nextNodeNumber=count+1, nodes=nodes, unknownTopLevel={"nested": [1, None, "preserve"]})
    if scenario in {"large-number", "precision-loss"}:
        # Python ints preserve the source lexemes exactly; no binary float round-trip.
        state["externalId"] = 9007199254740993
        state["unknownTopLevel"]["precision"] = {
            "externalId": 123456789012345678901234567891,
            "nested": [9007199254740995, -9007199254740993],
            "text": '9007199254740993 1.2300e+21 "123"',
        }
    if scenario in {"schema1", "display-legacy-all-tty"}:
        state = {key: value for key, value in state.items() if key not in {"nodes", "nextNodeNumber", "realityPublicKey"}}
        state.update(schema=1, publicKey="fixture-public-key", uuid=nodes[0]["uuid"], shortId=nodes[0]["shortId"],
                     nodeName="Legacy fixture", socksHost="198.51.100.1", socksPort=1081, socksUser="fixture-user", udpMode="block")
        nodes = nodes[:1]
    (folder / "state.json").write_text(json.dumps(state, indent=2) + "\n")
    (folder / "state.json").chmod(0o600)
    (folder / "node-ids").write_text("\n".join(node["id"] for node in nodes) + "\n")
    (folder / "secrets.json").write_text(json.dumps({node["id"]: f"fixture-password-{node['number']}" for node in nodes if node["type"] == "socks"}))
    for name in ("config.json", "puppyip", "xray-chain", "xray-chain.service"):
        (folder / name).write_text("synthetic protected file\n")
    (folder / "assets").mkdir()
    for name in ("geoip.dat", "geosite.dat"):
        (folder / "assets" / name).write_text("fixture asset\n")
    core = folder / "xray"
    core.write_text('#!/usr/bin/env bash\nprintf "core invoked\\n" >>"$(dirname "$0")/forbidden"\nexit 99\n')
    core.chmod(0o700)
    local = ["203.0.113.20"]
    public = "203.0.113.20"
    if scenario == "auto-ambiguous": local.append("203.0.113.21")
    if scenario == "auto-nat": public = "203.0.113.21"
    if scenario == "auto-private": local = ["10.0.0.2"]
    (folder / "local-addresses.json").write_text(json.dumps([dict(addr_info=[dict(family="inet", scope="global", local=ip) for ip in local])]))
    (folder / "public-address").write_text(public)
    return state

with tempfile.TemporaryDirectory(prefix="puppyip-entry-address.") as directory:
    for scenario, argument in cases:
        folder = Path(directory) / scenario
        folder.mkdir()
        old = fixture(folder, scenario)
        before = (folder / "state.json").read_bytes()
        protected = {path: path.read_bytes() for path in [folder / name for name in
                     ("xray", "puppyip", "xray-chain", "xray-chain.service", "secrets.json", "assets/geoip.dat", "assets/geosite.dat")]}
        master = slave = None
        process = None
        try:
            command = ["bash", script, "--case", scenario, str(folder), argument]
            if scenario.startswith("display-") and scenario.endswith("-tty"):
                master, slave = pty.openpty()
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave)
                os.close(slave); slave = None
                chunks = []
                deadline = time.monotonic() + 60
                while True:
                    if time.monotonic() >= deadline:
                        raise subprocess.TimeoutExpired(command, 60)
                    if select.select([master], [], [], 0.1)[0]:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        chunks.append(chunk)
                    elif process.poll() is not None:
                        break
                process.wait(timeout=5)
                stdout, stderr = b"".join(chunks).replace(b"\r\n", b"\n"), b""
            elif scenario in {"empty-tty", "domain-tty"}:
                master, slave = pty.openpty()
                process = subprocess.Popen(command, stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                os.write(master, (argument + "\n").encode())
                stdout, stderr = process.communicate(timeout=60)
            else:
                process = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
                stdout, stderr = process.stdout, process.stderr
            require(process.returncode == 0, "fixture worker failed outside the address operation")
            status = int((folder / "status").read_text())
            output = ((folder / "display").read_text() if (folder / "display").exists() else "") + (stdout + stderr).decode()
            failure = scenario.startswith("malformed-") or scenario in {"no-argument", "empty-argument", "extra-argument", "backup-failure", "atomic-failure", "lock-busy", "precision-loss", "auto-ambiguous", "auto-nat", "auto-private", "auto-ip-failure", "auto-probe-failure", "initial-invalid"}
            require((status != 0) == failure, "address operation success/failure differs from the contract")
            require(not any(secret in output for secret in ("fixture-password", "fixture-user", "fixture-private-key")), "error output exposed credentials or private material")
            require(not (folder / "forbidden").exists(), "address operation invoked DNS, core, service, confirmation or wrong ownership")
            require(all(path.read_bytes() == value for path, value in protected.items()), "address operation changed a protected file")
            if scenario.startswith("initial-"):
                require((folder / "state.json").read_bytes() == before, "initial settings modified an installed state")
                if not failure:
                    expected = domain if scenario == "initial-domain" else "203.0.113.30" if scenario == "initial-ipv4" else "203.0.113.20"
                    require((folder / "initial-address").read_text().strip() == expected, "initial environment address was ignored or not normalized")
                require(len(lines(folder / "curl-calls")) == (1 if scenario == "initial-default" else 0), "explicit initial address unexpectedly probed the network")
            else:
                display_case = scenario.startswith("display-")
                unchanged = failure or display_case or scenario in {"same", "empty-tty"}
                target = old["serverAddress"] if unchanged else "203.0.113.20" if scenario == "auto" else "203.0.113.30" if scenario == "ipv4" else domain
                expected = copy.deepcopy(old); expected["serverAddress"] = target
                require(json.loads((folder / "state.json").read_text()) == expected, "state changed beyond serverAddress (including unknown fields, metadata or schema)")
                if unchanged:
                    require((folder / "state.json").read_bytes() == before, "failed/no-op address operation rewrote the original state")
                if scenario == "precision-loss":
                    require(lines(folder / "precision-injected") == ["candidate-only"], "candidate-only precision fault was not injected")
                    require("数字" in output and "原状态" in output, "precision loss was not rejected with its specific safe diagnostic")
                    require(not lines(folder / "install-calls") and not lines(folder / "replacements"),
                            "precision loss was detected only after backup or state-write operations")
                if scenario == "large-number":
                    saved_text = (folder / "state.json").read_text()
                    require('"externalId": 9007199254740993' in saved_text and
                            '"externalId": 123456789012345678901234567891' in saved_text,
                            "large unknown integers were rounded or converted to exponent notation")
                require((folder / "config.json").read_bytes() == (folder / "before-config.json").read_bytes(), "address operation rewrote runtime config")
                old_links = lines(folder / "before-links"); new_links = lines(folder / "after-links")
                require(len(new_links) == len(old_links), "address operation changed the node count")
                for previous, current in zip(old_links, new_links):
                    parsed = urlsplit(current)
                    require(parsed.hostname == target, "not all nodes use the shared address")
                    require(current == previous.replace("@" + old["serverAddress"] + ":", "@" + target + ":", 1),
                            "a link changed port, UUID, SNI, public key, short ID, SpiderX or remark")
                backups = list((folder / "data/backups").glob("entry-address.*/state.json"))
                if not unchanged or scenario == "atomic-failure":
                    require(len(backups) == 1 and backups[0].read_bytes() == before, "missing exact pre-change state backup")
                    require(backups[0].stat().st_mode & 0o777 == 0o600, "state backup permissions are not private")
                elif scenario != "backup-failure":
                    require(not backups, "no-op or rejected input created a state backup")
                if not unchanged:
                    require((folder / "state.json").stat().st_mode & 0o777 == 0o600, "installed state permissions are not private")
                    require(lines(folder / "replacements") == ["replace"], "state did not use a single atomic replacement")
                    require((folder / "operation.lock").exists(), "address mutation did not acquire the operation lock")
                require(not list(folder.glob("state.json.new.*")), "failed atomic install leaked its temporary state")
                if not scenario.startswith("auto") and scenario != "domain-retained" and not display_case:
                    require(not lines(folder / "curl-calls") and not lines(folder / "ip-calls"), "explicit address or no-op performed network discovery")
                if scenario == "auto":
                    require(len(lines(folder / "ip-calls")) == 1 and len(lines(folder / "curl-calls")) == 1, "auto did not use one local/public agreement check")
                if display_case:
                    selected = list(range(len(new_links)))
                    if scenario in {"display-command-single-tty", "display-standalone-noqr-tty"}:
                        selected = [1]
                    elif scenario == "display-standalone-qr-pipe":
                        selected = [2]
                    elif scenario in {"display-by-id-tty", "display-preview-tty", "display-preview-pipe"}:
                        selected = [1, 2]
                    listed = scenario in {"display-list-pipe", "display-list-helper-pipe"}
                    wanted = [] if listed else [new_links[index] for index in selected]
                    shown = [line for line in output.splitlines() if line.startswith("vless://")]
                    require(shown == wanted, "a display entry replaced the saved domain or changed another link field")
                    qr_expected = wanted if scenario.endswith("-tty") or scenario == "display-standalone-qr-pipe" else []
                    if scenario == "display-standalone-noqr-tty": qr_expected = []
                    require(lines(folder / "qr-links") == qr_expected, "a display entry's QR inputs differ from its domain links")
                    require(not lines(folder / "ip-calls"), "saved domain triggered local-IP entrance discovery")
                    require(len(lines(folder / "curl-calls")) == (0 if scenario == "display-legacy-all-tty" else 1),
                            "display duplicated direct-exit probes or did not discover the current exit")
                    if listed:
                        require("公网 IPv4：203.0.113.20" in output, "node list did not display the actual new direct-exit IP")
                        require(all("实际出口：" + node["exitIp"] in output for node in expected["nodes"] if node["type"] == "socks"),
                                "node list changed a SOCKS exit")
                    elif expected.get("schema") == 2:
                        for index in selected:
                            node = expected["nodes"][index]
                            exit_ip = "203.0.113.20（VPS 本机）" if node["type"] == "direct" else node["exitIp"]
                            require("出口 IP：" + exit_ip in output, "direct exit did not use its detected IP or a SOCKS exit changed")
                if scenario == "domain-retained":
                    added = json.loads((folder / "after-add-model.json").read_text())
                    require(added["serverAddress"] == domain and added["nodes"][:-1] == expected["nodes"], "adding a node changed the domain or previous nodes")
                    added_link = urlsplit((folder / "after-add-link").read_text())
                    require(added_link.hostname == domain and added_link.port == added["nodes"][-1]["inboundPort"],
                            "the newly added node did not export the saved domain and its own port")
                    shown = [line for line in lines(folder / "shown-links") if line.startswith("vless://")]
                    require(shown == new_links, "display replaced the saved domain or changed link parameters")
                    require(lines(folder / "qr-links") == new_links[:1], "domain QR input differs from the corresponding share link")
            print(f"PASS: {scenario}", flush=True)
        except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            failures.append(scenario)
            print(f"FAIL: {scenario}: {error}", file=sys.stderr, flush=True)
        finally:
            if isinstance(process, subprocess.Popen) and process.poll() is None:
                process.kill()
                process.communicate()
            if master is not None: os.close(master)
            if slave is not None: os.close(slave)
if failures:
    raise SystemExit(f"Entry address checks failed: {len(failures)}/{len(cases)}")
print(f"Entry address checks passed: {len(cases)} cases.")
PY
