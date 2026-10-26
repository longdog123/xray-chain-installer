#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# Real menu/update orchestration, with isolated downloads and upgrade subprocesses.
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_worker() {
  local scenario="$1" case_dir="$2" candidate_version
  # shellcheck source=../install.sh
  source "${ROOT_DIR}/install.sh"
  export AUTO_CASE_DIR="$case_dir" AUTO_SCENARIO="$scenario" AUTO_SOURCE="${ROOT_DIR}/install.sh"
  export AUTO_REEXEC_MENU='no'
  MANAGER_BIN="${case_dir}/installed/puppyip"
  LEGACY_MANAGER_BIN="${case_dir}/installed/xray-chain"
  STATE_FILE="${case_dir}/installed/state.json"
  mkdir -p "${case_dir}/installed"
  printf '#!/usr/bin/env bash\n# XRAY_CHAIN_SCRIPT\nSCRIPT_VERSION="%s"\n' "$SCRIPT_VERSION" >"$MANAGER_BIN"
  cp -- "$MANAGER_BIN" "$LEGACY_MANAGER_BIN"
  cp -- "$MANAGER_BIN" "${case_dir}/old-manager"
  jq -n --arg version "$SCRIPT_VERSION" '{schema:2,installerVersion:$version,nodes:[{id:"node-1"}]}' >"$STATE_FILE"
  cp -- "$STATE_FILE" "${case_dir}/old-state.json"
  printf '%s' "$SCRIPT_VERSION" >"${case_dir}/old-version"
  candidate_version='99.10.2'
  case "$scenario" in
    same) candidate_version="$SCRIPT_VERSION" ;;
    older) candidate_version='0.0.1' ;;
    invalid-version) candidate_version='not-a-version' ;;
  esac

  require_root() { printf '__ROOT__\n'; }
  installation_complete() { return 0; }
  running_as_installed_manager() { return 0; }
  show_brand_banner() { printf '__BANNER__\n'; }
  show_menu() {
    if [[ "$AUTO_REEXEC_MENU" == 'yes' ]]; then
      printf '__NEW_MENU__\n'
      if [[ "$AUTO_SCENARIO" == 'menu-exit' ]]; then exit 7; fi
    else
      printf '__OLD_MENU__\n'
    fi
  }
  command_add() { printf '__ADD__\n'; }
  command_status() { printf '__STATUS__\n'; }
  systemctl() { printf 'Unexpected service operation\n' >&2; return 99; }
  new_temp_dir() {
    [[ "$AUTO_SCENARIO" != 'temp-failure' ]] || return 1
    LAST_TEMP_DIR="$(mktemp -d /tmp/xray-chain.autoupdate-test.XXXXXXXX)"
    TEMP_DIRS+=("$LAST_TEMP_DIR")
    printf '%s\n' "$LAST_TEMP_DIR" >>"${AUTO_CASE_DIR}/temp-dirs"
  }
  curl() {
    local destination='' url="${!#}" previous='' argument
    python3 -c 'import json,sys; open(sys.argv[1], "a").write(json.dumps(sys.argv[2:]) + "\n")' \
      "${AUTO_CASE_DIR}/curl-calls.jsonl" "$@"
    for argument in "$@"; do
      if [[ "$previous" == '--output' || "$previous" == '-o' ]]; then destination="$argument"; fi
      previous="$argument"
    done
    if [[ "$url" == https://api.github.com/* ]]; then
      [[ "$AUTO_SCENARIO" != 'api-failure' ]] || return 28
      case "$AUTO_SCENARIO" in
        malformed-json) printf '{broken-json' ;;
        invalid-sha) printf '{"object":{"sha":"../main"}}' ;;
        *) printf '{"object":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' ;;
      esac
      return 0
    fi
    [[ "$url" == 'https://raw.githubusercontent.com/longdog123/xray-chain-installer/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/install.sh' ]] || {
      printf 'Unexpected download URL: %s\n' "$url" >&2
      return 99
    }
    [[ -n "$destination" ]] || return 99
    if [[ "$AUTO_SCENARIO" == 'download-failure' ]]; then
      printf 'partial download' >"$destination"
      return 28
    fi
    cp -- "${AUTO_CASE_DIR}/candidate.sh" "$destination"
  }

  {
    printf '%s\n' 'MANAGER_BIN="${AUTO_CASE_DIR}/installed/puppyip"' \
      'LEGACY_MANAGER_BIN="${AUTO_CASE_DIR}/installed/xray-chain"' \
      'STATE_FILE="${AUTO_CASE_DIR}/installed/state.json"'
    declare -f require_root installation_complete running_as_installed_manager show_brand_banner \
      show_menu command_add command_status systemctl new_temp_dir curl
  } >"${case_dir}/boundaries.sh"
  {
    printf '#!/usr/bin/env bash\n# XRAY_CHAIN_SCRIPT\nSCRIPT_VERSION="%s"\n' "$candidate_version"
    cat <<'CANDIDATE'
set -Eeuo pipefail
if [[ "${1:-}" == 'upgrade' ]]; then
  printf '__UPGRADE__\n'
  printf '%s\n' "$0" >"${AUTO_CASE_DIR}/executed-candidate"
  if [[ "$AUTO_SCENARIO" == 'upgrade-failure' ]]; then
    false
    printf '__ERREXIT_IGNORED__\n'
  fi
  cp -- "$0" "${AUTO_CASE_DIR}/installed/puppyip"
  if [[ "$AUTO_SCENARIO" != 'manager-mismatch' ]]; then
    cp -- "$0" "${AUTO_CASE_DIR}/installed/xray-chain"
  fi
  if [[ "$AUTO_SCENARIO" != 'state-mismatch' ]]; then
    jq --arg version "$SCRIPT_VERSION" '.installerVersion = $version' \
      "${AUTO_CASE_DIR}/installed/state.json" >"${AUTO_CASE_DIR}/installed/state.new"
    mv -- "${AUTO_CASE_DIR}/installed/state.new" "${AUTO_CASE_DIR}/installed/state.json"
  fi
  if [[ "$AUTO_SCENARIO" == 'post-update-failure' ]]; then
    false
  fi
  exit 0
fi
printf '__REEXEC_ENV__:%s\n' "${XRAY_CHAIN_AUTO_UPDATE:-unset}"
candidate_version="$SCRIPT_VERSION"
# shellcheck disable=SC1090
source "$AUTO_SOURCE"
# shellcheck disable=SC1090
source "${AUTO_CASE_DIR}/boundaries.sh"
printf -v SCRIPT_VERSION '%s' "$candidate_version"
export AUTO_REEXEC_MENU='yes'
main
CANDIDATE
  } >"${case_dir}/candidate.sh"
  case "$scenario" in
    duplicate-version) printf 'SCRIPT_VERSION="99.10.3"\n' >>"${case_dir}/candidate.sh" ;;
    missing-marker) sed -i '/^# XRAY_CHAIN_SCRIPT$/d' "${case_dir}/candidate.sh" ;;
    bad-syntax) printf 'if then\n' >>"${case_dir}/candidate.sh" ;;
    oversized) head -c 1048577 /dev/zero >>"${case_dir}/candidate.sh" ;;
  esac
  if [[ "$scenario" == 'disabled' ]]; then
    export XRAY_CHAIN_AUTO_UPDATE=0
  else
    unset XRAY_CHAIN_AUTO_UPDATE
  fi
  case "$scenario" in
    add) main add ;;
    status) main status ;;
    *) main ;;
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

python3 - "${BASH_SOURCE[0]}" <<'PY'
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

script = str(Path(sys.argv[1]).resolve())
cases = ["new", "same", "older", "api-failure", "malformed-json", "invalid-sha",
         "download-failure", "invalid-version", "duplicate-version", "missing-marker",
         "bad-syntax", "oversized", "upgrade-failure", "manager-mismatch",
         "state-mismatch", "post-update-failure", "menu-exit", "temp-failure", "disabled", "add", "status"]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def capture(scenario, case_dir):
    master, slave = pty.openpty()
    process = subprocess.Popen(["bash", script, "--case", scenario, str(case_dir)],
                               stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    os.write(master, b"0\n")
    chunks = []
    deadline = time.monotonic() + 20
    with selectors.DefaultSelector() as selector:
        selector.register(master, selectors.EVENT_READ)
        try:
            while True:
                if time.monotonic() >= deadline:
                    os.killpg(process.pid, signal.SIGKILL)
                    raise AssertionError("menu/update hung, possibly waiting for confirmation")
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
    output = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", b"".join(chunks).decode()).replace("\r", "")
    return process.returncode, output


def option(arguments, flag):
    if flag in arguments:
        return arguments[arguments.index(flag) + 1]
    return next((argument.split("=", 1)[1] for argument in arguments if argument.startswith(flag + "=")), None)


failures = []
with tempfile.TemporaryDirectory(prefix="xray-chain-auto-update.") as directory:
    for scenario in cases:
        case_dir = Path(directory) / scenario
        case_dir.mkdir()
        try:
            status, output = capture(scenario, case_dir)
            require(status == (7 if scenario == "menu-exit" else 0),
                    f"unexpected exit status {status}: {output}")
            calls_file = case_dir / "curl-calls.jsonl"
            calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
            expected_calls = 0 if scenario in {"disabled", "add", "status", "temp-failure"} else (
                1 if scenario in {"api-failure", "malformed-json", "invalid-sha"} else 2)
            require(len(calls) == expected_calls,
                    f"expected {expected_calls} download calls, observed {len(calls)}")
            for arguments in calls:
                require(arguments[-1].startswith("https://"), "download did not use HTTPS")
                require(option(arguments, "--max-time") == "5", "download lacks a five-second total timeout")
                require(option(arguments, "--connect-timeout") == "3", "download lacks a three-second connection timeout")
                require(option(arguments, "--retry") in {None, "0"}, "menu download can retry and delay entry")
                require(option(arguments, "--proto") == "=https" and option(arguments, "--proto-redir") == "=https",
                        "download or redirects can downgrade from HTTPS")
            if len(calls) > 1:
                require(calls[0][-1].endswith("/git/ref/heads/main"), "version check did not resolve main")
                require(calls[1][-1].endswith("/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/install.sh"),
                        "candidate was not pinned to the resolved commit")
            if scenario in {"new", "post-update-failure", "menu-exit"}:
                require(output.count("__UPGRADE__") == 1 and output.count("__NEW_MENU__") == 1,
                        "new version did not upgrade and enter its menu exactly once")
                require("__OLD_MENU__" not in output, "old menu was shown after successful handoff")
                require("__REEXEC_ENV__:0" in output, "new menu did not receive the no-repeat-check setting")
                require("重启" in output[:output.index("__UPGRADE__")], "automatic restart was not explained before upgrade")
                state = json.loads((case_dir / "installed/state.json").read_text())
                old_state = json.loads((case_dir / "old-state.json").read_text())
                require(state == dict(old_state, installerVersion="99.10.2"), "upgrade changed preserved state")
                require((case_dir / "installed/puppyip").read_bytes() == (case_dir / "installed/xray-chain").read_bytes(),
                        "successful update left different management commands")
                if scenario == "post-update-failure":
                    after_upgrade = output.split("__UPGRADE__", 1)[1]
                    require("[!]" in after_upgrade and "收尾" in after_upgrade,
                            "committed update did not explain its finishing failure")
            elif scenario in {"add", "status"}:
                require(f"__{scenario.upper()}__" in output, "explicit command did not run")
                require("__OLD_MENU__" not in output and "__UPGRADE__" not in output, "explicit command entered automatic update")
            else:
                require(output.count("__OLD_MENU__") == 1 and "__NEW_MENU__" not in output,
                        "skipped or failed update did not continue the old menu")
                require("__REEXEC_ENV__" not in output, "failed/unnecessary update executed the candidate menu")
                if scenario in {"same", "older"}:
                    require("无需更新" in output and "[!]" not in output,
                            "an equal/older valid candidate was treated as a failed download")
                attempted = scenario in {"upgrade-failure", "manager-mismatch", "state-mismatch"}
                require(output.count("__UPGRADE__") == int(attempted), "unexpected candidate execution")
                if scenario not in {"same", "older", "disabled"}:
                    require("[!]" in output, "update failure did not warn before continuing")
                if not attempted or scenario == "upgrade-failure":
                    require((case_dir / "installed/state.json").read_bytes() == (case_dir / "old-state.json").read_bytes(),
                            "skipped or failed upgrade changed installed state")
                    for filename in ("puppyip", "xray-chain"):
                        require((case_dir / f"installed/{filename}").read_bytes() == (case_dir / "old-manager").read_bytes(),
                                "skipped or failed upgrade changed a management command")
            require("__ERREXIT_IGNORED__" not in output, "conditional execution swallowed the upgrade's set -e")
            if expected_calls:
                require("__ROOT__" in output, "automatic update was entered without the root check")
            dirs_file = case_dir / "temp-dirs"
            for name in dirs_file.read_text().splitlines() if dirs_file.exists() else []:
                require(not Path(name).exists(), "automatic update left its temporary directory behind")
            for arguments in calls:
                destination = option(arguments, "--output") or option(arguments, "-o")
                if destination:
                    require(not Path(destination).exists(), "downloaded candidate or partial file was not cleaned")
            print(f"PASS: {scenario}", flush=True)
        except (AssertionError, OSError, ValueError) as error:
            failures.append(scenario)
            print(f"FAIL: {scenario}: {error}", file=sys.stderr, flush=True)

if failures:
    raise SystemExit(f"菜单自动更新检查失败：{len(failures)}/{len(cases)}")
print(f"菜单自动更新检查通过：{len(cases)} 个场景。")
PY
