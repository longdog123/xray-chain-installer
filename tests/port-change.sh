#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
# Keep the real selector and listener parser; isolate randomness and host data.
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../install.sh
source "${ROOT_DIR}/install.sh"

TEST_DIR="$(mktemp -d /tmp/xray-chain-port-test.XXXXXXXX)"
cleanup_port_test() {
  if [[ "$TEST_DIR" == /tmp/xray-chain-port-test.* && -d "$TEST_DIR" ]]; then
    rm -rf -- "$TEST_DIR"
  fi
}
trap cleanup_port_test EXIT
STATE_FILE="${TEST_DIR}/state.json"
CONFIG_FILE="${TEST_DIR}/config.json"
printf '{"inboundPort":62002}\n' >"$STATE_FILE"
printf '{"inbounds":[{"port":62002}]}\n' >"$CONFIG_FILE"
cp -- "$STATE_FILE" "${TEST_DIR}/old-state.json"
cp -- "$CONFIG_FILE" "${TEST_DIR}/old-config.json"

collect_panel_reserved_ports() { PANEL_RESERVED_PORTS=(62003); }
ss() {
  [[ "$*" == '-H -lntu' ]] || return 99
  printf '%s\n' \
    'tcp LISTEN 0 4096 0.0.0.0:62004 0.0.0.0:*' \
    'udp UNCONN 0 0 [::]:62005 [::]:*'
}
curl() { printf 'Unexpected network request\n' >&2; return 99; }
systemctl() { printf 'Unexpected service operation\n' >&2; return 99; }

assert_equal() {
  local actual="$1" expected="$2" message="$3"
  [[ "$actual" == "$expected" ]] || {
    printf '%s (expected %s, got %s)\n' "$message" "$expected" "$actual" >&2
    return 1
  }
}

test_random_exclusions() {
  local XRAY_CHAIN_PORT='' candidate_calls=0
  local -a candidates=(62002 62007 62008 443 62003 62004 62005 62006)
  generate_auto_port_candidate() {
    AUTO_PORT_CANDIDATE="${candidates[candidate_calls]}"
    ((candidate_calls += 1))
  }
  # Existing node ports have no listeners: stopped nodes still reserve them.
  select_inbound_port 62002 62007 62008
  assert_equal "$INBOUND_PORT" 62006 'Random selection reused an excluded port'
  assert_equal "$candidate_calls" 8 'Not every unsafe candidate was skipped'
  cmp -s -- "$STATE_FILE" "${TEST_DIR}/old-state.json"
  cmp -s -- "$CONFIG_FILE" "${TEST_DIR}/old-config.json"
}

test_exhausted_candidates() {
  local status
  set +e
  (
    set -e
    XRAY_CHAIN_PORT=''
    INBOUND_PORT='61234'
    candidate_calls=0
    reserved_ports=(62002 62007 62008)
    trap 'printf "%s" "$INBOUND_PORT" >"${TEST_DIR}/exhausted-port"; printf "%s" "$candidate_calls" >"${TEST_DIR}/exhausted-attempts"' EXIT
    generate_auto_port_candidate() {
      AUTO_PORT_CANDIDATE="${reserved_ports[candidate_calls % ${#reserved_ports[@]}]}"
      ((candidate_calls += 1))
    }
    select_inbound_port "${reserved_ports[@]}"
  ) >"${TEST_DIR}/exhausted-output" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || {
    printf '128 excluded candidates unexpectedly produced a port\n' >&2
    return 1
  }
  assert_equal "$(<"${TEST_DIR}/exhausted-attempts")" 128 'Wrong retry limit'
  assert_equal "$(<"${TEST_DIR}/exhausted-port")" 61234 'Failed selection changed INBOUND_PORT'
  grep -q '128' "${TEST_DIR}/exhausted-output"
  cmp -s -- "$STATE_FILE" "${TEST_DIR}/old-state.json"
  cmp -s -- "$CONFIG_FILE" "${TEST_DIR}/old-config.json"
}

test_explicit_excluded_port() {
  local status
  set +e
  (
    set -e
    XRAY_CHAIN_PORT='62008'
    INBOUND_PORT='61234'
    trap 'printf "%s" "$INBOUND_PORT" >"${TEST_DIR}/explicit-excluded-port"' EXIT
    select_inbound_port 62002 62007 62008
  ) >"${TEST_DIR}/explicit-excluded-output" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || {
    printf 'Explicit port reused a non-first excluded port\n' >&2
    return 1
  }
  assert_equal "$(<"${TEST_DIR}/explicit-excluded-port")" 61234 'Rejected explicit port changed INBOUND_PORT'
  cmp -s -- "$STATE_FILE" "${TEST_DIR}/old-state.json"
  cmp -s -- "$CONFIG_FILE" "${TEST_DIR}/old-config.json"
}

test_install_explicit_port() {
  local XRAY_CHAIN_PORT='443'
  generate_auto_port_candidate() { printf 'Explicit port unexpectedly used randomness\n' >&2; return 99; }
  select_inbound_port 2>"${TEST_DIR}/explicit-warning"
  assert_equal "$INBOUND_PORT" 443 'Installation no longer honors an explicit common port'
  grep -q '443' "${TEST_DIR}/explicit-warning"
  grep -q '明确设置' "${TEST_DIR}/explicit-warning"
}

test_install_random_port() {
  local XRAY_CHAIN_PORT='' candidate_calls=0
  local -a candidates=(443 62003 62004 62005 62002)
  generate_auto_port_candidate() {
    AUTO_PORT_CANDIDATE="${candidates[candidate_calls]}"
    ((candidate_calls += 1))
  }
  select_inbound_port
  assert_equal "$INBOUND_PORT" 62002 'Installation changed selection without an excluded port'
  assert_equal "$candidate_calls" 5 'Installation stopped filtering unavailable ports'
}

failures=0
for test_case in \
  test_random_exclusions \
  test_exhausted_candidates \
  test_explicit_excluded_port \
  test_install_explicit_port \
  test_install_random_port; do
  set +e
  (set -e; "$test_case")
  status=$?
  set -e
  if [[ "$status" == 0 ]]; then
    printf 'PASS: %s\n' "$test_case"
  else
    printf 'FAIL: %s\n' "$test_case" >&2
    ((failures += 1))
  fi
done
[[ "$failures" == 0 ]] || exit 1
printf '随机入口端口筛选检查通过：5 个场景。\n'
