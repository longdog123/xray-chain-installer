#!/usr/bin/env bash
# Exercise diagnostic boundaries with synthetic files and failing commands.
# shellcheck disable=SC1091,SC2034
set -Eeuo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/install.sh"
TEST_DIR="$(mktemp -d /var/tmp/xray-chain-system-errors.XXXXXXXX)"
trap '[[ "$TEST_DIR" == /var/tmp/xray-chain-system-errors.* ]] && rm -rf -- "$TEST_DIR"' EXIT

test_log_redaction() {
  local output
  cat >"${TEST_DIR}/unsafe.log" <<'LOG'
Permission denied opening candidate configuration
{"privateKey":"fixture-private-secret","password":"fixture-password-secret","id":"3d107e9d-771a-41a8-88f3-94a9747a8f27"}
vless://3d107e9d-771a-41a8-88f3-94a9747a8f27@203.0.113.10:443?pbk=fixture-public-secret
unclassified-raw-secret
LOG
  output="$(show_error_log "${TEST_DIR}/unsafe.log" 2>&1)"
  [[ -n "$output" ]]
  [[ "$output" != *fixture-* && "$output" != *3d107e9d* && "$output" != *vless://* && "$output" != *unclassified-raw-secret* ]]
  [[ "$output" == *权限* || "$output" == *permission* ]]
}

test_unknown_log_redaction() {
  local output
  printf 'unclassified-raw-secret\n' >"${TEST_DIR}/unknown.log"
  output="$(show_error_log "${TEST_DIR}/unknown.log" 2>&1)"
  [[ -n "$output" && "$output" != *unclassified-raw-secret* ]]
}

test_atomic_write_failure() {
  local output status=0 target="${TEST_DIR}/atomic-target"
  install() { return 13; }
  output="$(atomic_install "${TEST_DIR}/source" "$target" 0600 root root 2>&1)" || status=$?
  [[ "$status" != 0 && "$output" == *"$target"* ]]
  [[ "$output" == *写入* || "$output" == *复制* || "$output" == *临时* ]]
}

test_atomic_replace_failure() {
  local output status=0 target="${TEST_DIR}/replace-target"
  install() { printf 'candidate' >"${@: -1}"; }
  mv() { return 13; }
  output="$(atomic_install "${TEST_DIR}/source" "$target" 0600 root root 2>&1)" || status=$?
  [[ "$status" != 0 && "$output" == *"$target"* ]]
  [[ "$output" == *替换* || "$output" == *重命名* ]]
  [[ ! -e "${target}.new.$$" ]]
}

test_manager_download_error() {
  local scenario="$1" expected_curl_code="$2" output status=0 target="${TEST_DIR}/${1}.sh"
  local calls="${TEST_DIR}/${1}.calls"
  curl() {
    printf 'call\n' >>"$calls"
    if [[ "$*" != *'--output '* ]]; then
      case "$scenario" in
        ref-network) return 28 ;;
        ref-invalid) printf '{"object":{"sha":"invalid-ref"}}'; return 0 ;;
        *) printf '{"object":{"sha":"0123456789abcdef0123456789abcdef01234567"}}'; return 0 ;;
      esac
    fi
    local destination=''
    while (( $# > 0 )); do
      if [[ "$1" == --output ]]; then destination="$2"; break; fi
      shift
    done
    [[ -n "$destination" ]]
    case "$scenario" in
      script-network) printf 'partial' >"$destination"; return 7 ;;
      script-invalid) printf '#!/usr/bin/env bash\n# XRAY_CHAIN_SCRIPT\nSCRIPT_VERSION="0.2.23"\nif\n' >"$destination" ;;
    esac
  }
  output="$(download_latest_manager "$target" 2>&1)" || status=$?
  [[ "$status" != 0 && ! -e "$target" && -n "$output" ]]
  if [[ "$expected_curl_code" != any ]]; then [[ "$output" == *"$expected_curl_code"* ]]; fi
  case "$scenario" in
    ref-network|ref-invalid)
      [[ "$(wc -l <"$calls")" == 1 ]]
      [[ "$output" == *api.github.com* || "$output" == *引用* || "$output" == *提交* || "$output" == *版本信息* ]]
      ;;
    script-network|script-invalid)
      [[ "$(wc -l <"$calls")" == 2 ]]
      [[ "$output" == *raw.githubusercontent.com* || "$output" == *脚本* ]]
      ;;
  esac
  if [[ "$scenario" == *-invalid ]]; then
    [[ "$output" == *校验* || "$output" == *格式* || "$output" == *无效* || "$output" == *语法* ]]
  fi
}
test_ref_network_failure() { test_manager_download_error ref-network 28; }
test_ref_invalid_response() { test_manager_download_error ref-invalid any; }
test_script_network_failure() { test_manager_download_error script-network 7; }
test_script_invalid_response() { test_manager_download_error script-invalid any; }

prepare_rollback_fixture() {
  local root="${TEST_DIR}/rollback-$1"
  BACKUP_DIR="${root}/backups"
  ROLLBACK_FIXTURE="${BACKUP_DIR}/snapshot"
  mkdir -p "$ROLLBACK_FIXTURE"
  printf yes >"${ROLLBACK_FIXTURE}/was-enabled"
  printf yes >"${ROLLBACK_FIXTURE}/was-active"
  XRAY_BIN="${root}/xray"
  ASSET_DIR="${root}/assets"
  CONFIG_FILE="${root}/config.json"
  STATE_FILE="${root}/state.json"
  SERVICE_FILE="${root}/unit"
  MANAGER_BIN="${root}/manager"
  LEGACY_MANAGER_BIN="${root}/legacy-manager"
  ROLLBACK_CALLS="${root}/calls"
  cleanup_runtime_layout_created_this_run() { printf 'cleanup\n' >>"$ROLLBACK_CALLS"; }
}

test_incomplete_rollback() {
  local output status=0
  prepare_rollback_fixture failed
  restore_one() {
    printf 'restore:%s\n' "$2" >>"$ROLLBACK_CALLS"
    [[ "$2" != "$CONFIG_FILE" ]]
  }
  systemctl() { printf 'service:%s\n' "$*" >>"$ROLLBACK_CALLS"; return 1; }
  output="$(rollback_backup "$ROLLBACK_FIXTURE" 2>&1)" || status=$?
  [[ "$status" == 0 ]]
  [[ "$(grep -c '^restore:' "$ROLLBACK_CALLS")" == 8 ]]
  grep -Fqx "restore:$LEGACY_MANAGER_BIN" "$ROLLBACK_CALLS"
  grep -Fqx cleanup "$ROLLBACK_CALLS"
  [[ "$output" == *"$CONFIG_FILE"* && "$output" == *"$ROLLBACK_FIXTURE"* ]]
  [[ "$output" == *服务* && ( "$output" == *失败* || "$output" == *未恢复* ) ]]
  [[ "$output" != *恢复成功* && "$output" != *已回滚* ]]
}

test_successful_rollback() {
  local output
  prepare_rollback_fixture success
  restore_one() { return 0; }
  systemctl() { return 0; }
  output="$(rollback_backup "$ROLLBACK_FIXTURE" 2>&1)"
  [[ "$output" == *恢复成功* || "$output" == *已恢复* ]]
  [[ "$output" != *恢复失败* && "$output" != *恢复不完整* ]]
}

test_failed_fresh_rollback_preserves_backup() {
  local root="${TEST_DIR}/fresh-incomplete" output status=0 backup
  BIN_DIR="${root}/bin"
  XRAY_BIN="${BIN_DIR}/xray"
  ASSET_DIR="${root}/assets"
  CONFIG_DIR="${root}/config"
  CONFIG_FILE="${CONFIG_DIR}/config.json"
  STATE_FILE="${CONFIG_DIR}/state.json"
  DATA_DIR="${root}/data"
  BACKUP_DIR="${DATA_DIR}/backups"
  SERVICE_FILE="${root}/unit"
  MANAGER_BIN="${root}/manager"
  LEGACY_MANAGER_BIN="${root}/legacy-manager"
  RUNTIME_USER='fixture-runtime-user'
  RUNTIME_GROUP='fixture-runtime-group'
  RUNTIME_USER_MARKER="${DATA_DIR}/user-marker"
  RUNTIME_GROUP_MARKER="${DATA_DIR}/group-marker"
  RUNTIME_USER_CREATED_THIS_RUN='yes'
  RUNTIME_GROUP_CREATED_THIS_RUN='yes'
  backup="${BACKUP_DIR}/snapshot"
  mkdir -p "$BIN_DIR" "$ASSET_DIR" "$CONFIG_DIR" "$backup"
  printf no >"${backup}/was-enabled"
  printf no >"${backup}/was-active"
  : >"$RUNTIME_USER_MARKER"
  : >"$RUNTIME_GROUP_MARKER"
  systemctl() { return 1; }
  userdel() { printf 'user\n' >>"${root}/removed-accounts"; }
  groupdel() { printf 'group\n' >>"${root}/removed-accounts"; }
  # Keep real restore_one and cleanup_runtime_layout_created_this_run. Every
  # managed path is inside this fixture, and service/account commands are mocks.
  output="$(rollback_backup "$backup" 2>&1)" || status=$?
  [[ "$status" == 0 && "$output" == *"$backup"* ]]
  [[ -f "${backup}/was-enabled" && -f "${backup}/was-active" ]]
  [[ "$(<"${backup}/was-enabled")" == no && "$(<"${backup}/was-active")" == no ]]
  [[ ! -e "$RUNTIME_USER_MARKER" && ! -e "$RUNTIME_GROUP_MARKER" ]]
  grep -Fqx user "${root}/removed-accounts"
  grep -Fqx group "${root}/removed-accounts"
}

test_oversized_port_input() {
  valid_port 443
  ! valid_port 18446744073709551617
  ! valid_port 18446744073709617151
}

test_invalid_ipv4_input() {
  valid_ipv4 203.0.113.10
  ! valid_ipv4 18446744073709551617.0.113.10
  ! valid_ipv4 203.0.113.10.
  ! valid_ipv4_or_domain 203.0.113.10.
}

test_oversized_node_selector() {
  local file="${TEST_DIR}/selector-state.json" output status=0
  printf '{"schema":2,"nodes":[{"id":"node-1","number":1}]}\n' >"$file"
  select_node_id "$file" 1
  [[ "$SELECTED_NODE_ID" == node-1 ]]
  output="$(select_node_id "$file" 18446744073709551617 2>&1)" || status=$?
  [[ "$status" != 0 && -n "$output" ]]
  [[ "$output" == *节点* || "$output" == *编号* ]]
}

failures=0
for test_case in test_log_redaction test_unknown_log_redaction \
  test_atomic_write_failure test_atomic_replace_failure \
  test_ref_network_failure test_ref_invalid_response \
  test_script_network_failure test_script_invalid_response \
  test_incomplete_rollback test_successful_rollback test_failed_fresh_rollback_preserves_backup \
  test_oversized_port_input test_invalid_ipv4_input test_oversized_node_selector; do
  set +e
  (set -e; "$test_case") >"${TEST_DIR}/${test_case}.log" 2>&1
  status=$?
  set -e
  if (( status == 0 )); then
    printf 'PASS: %s\n' "$test_case"
  else
    printf 'FAIL: %s\n' "$test_case" >&2
    ((failures += 1))
  fi
done
(( failures == 0 )) || exit 1
printf '系统错误诊断检查通过：14 个场景。\n'
