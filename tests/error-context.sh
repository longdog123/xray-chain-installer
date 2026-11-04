#!/usr/bin/env bash
# Exercise real SOCKS collection/validation and prompts with synthetic endpoints only.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_worker() {
  local scenario="$1" case_dir="$2"
  # shellcheck source=../install.sh
  source "${ROOT_DIR}/install.sh"
  MODEL_FILE="${case_dir}/model.json"
  STATE_FILE="${case_dir}/installed.json"
  SECRETS_FILE="${case_dir}/secrets.json"
  show_socks_promo() { :; }
  read_hidden_socks_batch_input() { SOCKS_BATCH_RAW="$(cat "${case_dir}/input")"; }
  append_current_node_to_model() {
    printf 'appended\n' >>"${case_dir}/appended"
    SELECTED_NODE_ID="node-${index}"
  }
  curl() {
    # Ten successful entries, then the same gateway with a different account fails.
    if [[ "$scenario" == batch-* && "$SOCKS_USER" != 'secret-user-11' ]]; then
      printf '198.51.100.200'
      return 0
    fi
    printf 'raw-secret-user raw-secret-password raw-internal-host\n' >&2
    return 28
  }
  case "$scenario" in
    batch-*)
      append_batch_nodes_to_model unused-xray
      printf 'reached-deploy\n' >"${case_dir}/deployed"
      ;;
    input-batch|input-unsafe)
      collect_socks_batch_settings
      ;;
    input-edit)
      collect_socks_settings edit node-27
      ;;
    edit-failure)
      update_node_socks_in_model node-27
      printf 'reached-deploy\n' >"${case_dir}/deployed"
      ;;
    single-failure)
      SOCKS_HOST='gateway.example.test'
      SOCKS_PORT='1080'
      SOCKS_USER='secret-user-11'
      SOCKS_PASS='secret-password-11'
      verify_socks_proxy "$case_dir"
      ;;
  esac
}

if [[ "${1:-}" == '--case' ]]; then
  run_worker "$2" "$3"
  exit
fi
python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import errno, json, os, pty, re, select, subprocess, sys, tempfile, time
from pathlib import Path

script = str(Path(sys.argv[1]).resolve())
cases = ["batch-last-cancel", "batch-last-allow", "batch-last-noninteractive",
         "input-batch", "input-unsafe", "input-edit", "edit-failure", "single-failure"]
if len(sys.argv) > 2:
    cases = [case for case in cases if case in sys.argv[2:]]
failed = []

def require(condition, message):
    if not condition:
        raise AssertionError(message)

def run_terminal(arguments, answer):
    master, slave = pty.openpty()
    process = subprocess.Popen(arguments, stdin=slave, stdout=slave, stderr=slave,
                               env=dict(os.environ, TERM="xterm"))
    os.close(slave)
    output = bytearray()
    answered = False
    deadline = time.monotonic() + 15
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
                if not answered and "[y=同意 / n=不同意 / 回车=不同意]:".encode() in output:
                    os.write(master, answer)
                    answered = True
            if process.poll() is not None:
                # Drain the remaining PTY output before checking the exit status.
                if not select.select([master], [], [], .1)[0]:
                    break
        require(process.poll() is not None or answered, "TTY prompt was not reached")
        returncode = process.wait(timeout=3)
        require(answered, "default-deny confirmation was not shown")
        return returncode, output.decode()
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)

with tempfile.TemporaryDirectory(prefix="puppyip-error-context.") as directory:
    for scenario in cases:
        root = Path(directory) / scenario
        root.mkdir()
        model = {"nodes": [{"id": "node-27", "number": 27,
            "name": "secret-name-must-not-display", "type": "socks",
            "socksHost": "198.51.100.3", "socksPort": 1080,
            "socksUser": "stored-secret-user", "udpMode": "proxy", "exitIp": "198.51.100.200"}]}
        state = json.dumps(model).encode()
        for filename in ("model.json", "installed.json"):
            (root / filename).write_bytes(state)
        (root / "secrets.json").write_text(json.dumps({"node-27": "stored-secret-password"}))
        entries = [f"198.51.100.77:1080:secret-user-{i}:secret-password-{i}" for i in range(1, 12)]
        if scenario == "input-batch":
            entries[10] = "198.51.100.77:1080:secret-user-11"
        elif scenario == "input-unsafe":
            entries[10] = "invalid@secret-user-11:1080:secret-user-11:secret-password-11"
        (root / "input").write_text("\n".join(entries))
        args = ["bash", script, "--case", scenario, str(root)]
        try:
            if scenario in ("batch-last-cancel", "batch-last-allow"):
                status, output = run_terminal(args, b"y\n" if scenario.endswith("allow") else b"\n")
            else:
                stdin = b"198.51.100.77:1080:secret-user-11\n" if scenario == "input-edit" else (
                    b"198.51.100.77:1080:secret-user-11:secret-password-11\n" if scenario == "edit-failure" else b"")
                process = subprocess.run(args, input=stdin, stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT, timeout=15)
                status, output = process.returncode, process.stdout.decode()
            require(status == (0 if scenario == "batch-last-allow" else 1), "unexpected confirmation/exit behavior")
            clean = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", output)
            for secret in ("secret-user", "secret-password", "secret-name", "raw-internal-host", "socks5://", "vless://"):
                require(secret not in output, "credentials, raw data or link escaped into diagnostics")
            require((root / "installed.json").read_bytes() == state, "installed state changed before deployment")
            if scenario.startswith("batch-"):
                require("第 11/11 条" in clean and "198.51.100.77:1080" in clean, "missing exact batch ordinal or gateway")
                require("本批尚未部署" in clean and "取消本批全部新增" in clean, "batch confirmation scope is unclear")
                require((root / "deployed").exists() == (scenario == "batch-last-allow"), "cancelled batch proceeded to deployment")
                count = len((root / "appended").read_text().splitlines())
                require(count == (11 if scenario == "batch-last-allow" else 10), "failed item silently skipped or appended")
                require(clean.count("出口验证失败") == 1, "success output became noisy or failure was repeated")
                if scenario != "batch-last-noninteractive":
                    require(re.search(r"\r?\n\[!\].*第 11/11 条", clean), "TTY progress swallowed failure context")
            elif scenario in ("input-batch", "input-unsafe"):
                endpoint = "地址未识别" if scenario == "input-unsafe" else "198.51.100.77:1080"
                require("第 11/11 条" in clean and endpoint in clean, "invalid batch entry lacks safe context")
            elif scenario in ("input-edit", "edit-failure"):
                require("node-27" in clean and "198.51.100.77:1080" in clean, "edit error lacks selected node or new gateway")
                require((root / "model.json").read_bytes() == state, "rejected edit changed the candidate model")
            else:
                require("gateway.example.test:1080" in clean, "single add failure lacks gateway")
            if scenario not in ("input-batch", "input-unsafe", "input-edit"):
                for domain in ("api.ipify.org", "ipv4.icanhazip.com", "ifconfig.me"):
                    require(domain in clean, "failed detection site is unidentified")
                require("curl 代码 28" in clean and "建议" in clean, "failure lacks code or next step")
            print(f"PASS: {scenario}", flush=True)
        except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            failed.append(scenario)
            print(f"FAIL: {scenario}: {error}", file=sys.stderr, flush=True)
if failed:
    raise SystemExit(f"SOCKS error context checks failed: {len(failed)}/{len(cases)}")
print(f"SOCKS error context checks passed: {len(cases)} cases.")
PY
