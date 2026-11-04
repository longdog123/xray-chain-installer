#!/usr/bin/env bash
# XRAY_CHAIN_SCRIPT
# Standalone VLESS + REALITY + Vision -> SOCKS5 chain installer.

set -Eeuo pipefail
umask 077

SCRIPT_VERSION="0.2.23"
CURRENT_STATE_SCHEMA=2
SERVICE_NAME="xray-chain.service"
RUNTIME_USER="xray-chain"
RUNTIME_GROUP="xray-chain"
DEFAULT_XRAY_VERSION="v26.3.27"
DEFAULT_REALITY_TARGET="www.bing.com:443"
KNOWN_BAD_REALITY_TARGET="www.microsoft.com:443"
MAX_BATCH_SIZE=50
AUTO_PORT_MIN=62001
AUTO_PORT_MAX=65534
INSTALLER_RAW_URL="https://raw.githubusercontent.com/longdog123/xray-chain-installer/main/install.sh"
INSTALLER_REPOSITORY="longdog123/xray-chain-installer"
INSTALLER_BRANCH="main"
INSTALLER_API_URL="https://api.github.com/repos/${INSTALLER_REPOSITORY}"
INSTALLER_RAW_BASE="https://raw.githubusercontent.com/${INSTALLER_REPOSITORY}"
MAX_INSTALLER_BYTES=1048576
TUTORIAL_URL="https://puppyip.com/tutorials#vps-chain"
STATUS_PROBE_CONCURRENCY=8

BIN_DIR="/usr/local/lib/xray-chain"
XRAY_BIN="${BIN_DIR}/xray"
ASSET_DIR="/usr/local/share/xray-chain"
CONFIG_DIR="/etc/xray-chain"
CONFIG_FILE="${CONFIG_DIR}/config.json"
STATE_FILE="${CONFIG_DIR}/state.json"
DATA_DIR="/var/lib/xray-chain"
BACKUP_DIR="${DATA_DIR}/backups"
BBR_STATE_FILE="${DATA_DIR}/bbr-state.json"
BBR_SYSCTL_FILE="/etc/sysctl.d/99-zz-puppyip-bbr.conf"
BBR_MODULES_FILE="/etc/modules-load.d/puppyip-bbr.conf"
BBR_MANAGED_HEADER="# Managed by PuppyIP Xray Chain"
RUNTIME_USER_MARKER="${DATA_DIR}/runtime-user-created"
RUNTIME_GROUP_MARKER="${DATA_DIR}/runtime-group-created"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
MANAGER_BIN="/usr/local/sbin/puppyip"
LEGACY_MANAGER_BIN="/usr/local/sbin/xray-chain"
LOCK_FILE="/run/lock/xray-chain.lock"
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
OS_RELEASE_FILE="/etc/os-release"

declare -a TEMP_DIRS=()
declare -a SOCKS_BATCH_ENTRIES=()
declare -a NEW_NODE_IDS=()
declare -a PANEL_RESERVED_PORTS=()
LAST_TEMP_DIR=''
BRAND_BANNER_SHOWN='no'
TUTORIAL_HINT_SHOWN='no'
PROGRESS_LINE_ACTIVE='no'
PROMPT_SPACE_ACTIVE='no'

# Values populated while collecting settings and building the candidate model.
# Initializing them here makes accidental use before prompting fail predictably.
SERVER_ADDRESS=''
INBOUND_PORT=''
SOCKS_HOST=''
SOCKS_PORT=''
SOCKS_USER=''
SOCKS_PASS=''
REALITY_TARGET=''
TARGET_HOST=''
TARGET_PORT=''
SERVER_NAME=''
NODE_NAME=''
SOCKS_EXIT_IP=''
SOCKS_INPUT_CHANGED='no'
NODE_SETTINGS_CHANGED='no'
NODE_TYPE='socks'
ADD_DIRECT_NODE='no'
UUID=''
SHORT_ID=''
SPIDER_X='/'
PRIVATE_KEY=''
PUBLIC_KEY=''
MODEL_FILE=''
SECRETS_FILE=''
SELECTED_NODE_ID=''
AUTO_PORT_CANDIDATE=''
SOCKS_BATCH_RAW=''
SOCKS_BATCH_ERROR_INDEX=''
RUNTIME_USER_CREATED_THIS_RUN='no'
RUNTIME_GROUP_CREATED_THIS_RUN='no'
BBR_CHANGED='no'

if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'
  C_CYAN=$'\033[36m'
  C_PAW_FILL=$'\033[1;97m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_CYAN=""
  C_PAW_FILL=""
  C_YELLOW=""
  C_RED=""
  C_BOLD=""
  C_RESET=""
fi

info() { finish_progress_line; printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { finish_progress_line; printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { finish_progress_line; printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

interactive_progress_enabled() {
  [[ -t 1 && -t 2 && "${TERM:-dumb}" != 'dumb' ]]
}

show_progress_line() {
  local current="$1" total="$2" label="$3" width=24 percent filled empty
  local filled_text empty_text
  (( total > 0 && current >= 0 && current <= total )) || return 1

  if ! interactive_progress_enabled; then
    printf '%s[+]%s [%s/%s] %s\n' "$C_GREEN" "$C_RESET" "$current" "$total" "$label"
    return 0
  fi

  percent=$((current * 100 / total))
  filled=$((percent * width / 100))
  empty=$((width - filled))
  printf -v filled_text '%*s' "$filled" ''
  printf -v empty_text '%*s' "$empty" ''
  filled_text="${filled_text// /#}"
  empty_text="${empty_text// /-}"
  printf '\r\033[2K%s[%s%s]%s %3s%% %s' \
    "$C_GREEN" "$filled_text" "$empty_text" "$C_RESET" "$percent" "$label"
  PROGRESS_LINE_ACTIVE='yes'
}

clear_progress_line() {
  if [[ "$PROGRESS_LINE_ACTIVE" == 'yes' ]] && interactive_progress_enabled; then
    printf '\r\033[2K'
  fi
  PROGRESS_LINE_ACTIVE='no'
}

show_activity_line() {
  local label="$1" elapsed="$2" tick="$3" width=24 block=6 range position i bar=''
  range=$((width - block))
  position=$((tick % (range * 2)))
  (( position <= range )) || position=$((range * 2 - position))
  for ((i = 0; i < width; i++)); do
    if (( i >= position && i < position + block )); then
      bar+='#'
    else
      bar+='-'
    fi
  done
  printf '\r\033[2K%s[%s]%s %s · %s 秒' \
    "$C_GREEN" "$bar" "$C_RESET" "$label" "$elapsed"
  PROGRESS_LINE_ACTIVE='yes'
}

finish_progress_line() {
  if [[ "$PROGRESS_LINE_ACTIVE" == 'yes' ]] && interactive_progress_enabled; then
    printf '\n'
  fi
  PROGRESS_LINE_ACTIVE='no'
}

run_logged_task() {
  local label="$1" log_file="$2" pid started tick=0 status=0
  shift 2

  if ! interactive_progress_enabled; then
    "$@" >>"$log_file" 2>&1
    return
  fi

  "$@" >>"$log_file" 2>&1 &
  pid=$!
  started=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    show_activity_line "$label" "$((SECONDS - started))" "$tick"
    tick=$((tick + 1))
    sleep 0.2
  done
  wait "$pid" || status=$?
  clear_progress_line
  return "$status"
}

read_download_percent() {
  local progress_file="$1" value=''
  [[ -r "$progress_file" ]] || { printf '0'; return 0; }
  value="$(tr '\r' '\n' <"$progress_file" \
    | grep -Eo '[0-9]+([.][0-9]+)?%' \
    | tail -n 1 || true)"
  value="${value%\%}"
  value="${value%%.*}"
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  (( value <= 100 )) || value=100
  printf '%s' "$value"
}

run_download_task() {
  local label="$1" progress_file="$2" pid percent status=0
  shift 2

  : >"$progress_file"
  "$@" >"$progress_file" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    percent="$(read_download_percent "$progress_file")"
    show_progress_line "$percent" 100 "$label"
    sleep 0.2
  done
  wait "$pid" || status=$?
  if (( status == 0 )); then
    show_progress_line 100 100 "$label"
    finish_progress_line
  else
    clear_progress_line
  fi
  return "$status"
}

reserve_prompt_space() {
  if interactive_progress_enabled; then
    # Reserve one row below the hidden input so terminal overlays do not cover
    # the prompt. Keep scrollback intact and show only one action.
    printf '\n\n\033[2A\r'
    printf '\033[1B\r\033[2K%s↓ 输入会隐藏，粘贴后按回车%s\033[1A\r' \
      "$C_CYAN" "$C_RESET"
    PROMPT_SPACE_ACTIVE='yes'
  fi
}

release_prompt_space() {
  if [[ "$PROMPT_SPACE_ACTIVE" == 'yes' ]] && interactive_progress_enabled; then
    # Remove only the temporary prompt row and reuse its first row for the
    # next status line. This does not clear or reset terminal history.
    printf '\r\033[2K\033[1B\r\033[2K\033[1A\r'
  else
    printf '\n'
  fi
  PROMPT_SPACE_ACTIVE='no'
}

show_supported_system_advice() {
  warn "请改用 Ubuntu 24.04 LTS（64 位）后重试；重装前请备份数据。"
}

die_unsupported_system() {
  printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
  show_supported_system_advice
  exit 1
}

die_unsupported_architecture() {
  printf '%s[x]%s 暂不支持 CPU 架构：%s\n' "$C_RED" "$C_RESET" "$1" >&2
  warn "请改用 Ubuntu 24.04 LTS（amd64 或 arm64）。"
  exit 1
}

show_brand_banner() {
  local row i
  BRAND_BANNER_SHOWN='yes'
  printf '\n'
  while IFS= read -r row; do
    printf '      '
    for ((i = 0; i < ${#row}; i++)); do
      if [[ ${row:i:1} == '#' ]]; then
        printf '%s██%s' "$C_PAW_FILL" "$C_RESET"
      else
        printf '  '
      fi
    done
    printf '\n'
  done <<'PAW_LOGO'
   ##   ##
  #### ####
   ##   ##
##         ##
###       ###
 ##  ###  ##
   #######
  #########
  #########
  #########
   #######
     ###
PAW_LOGO
  printf '\n              %s%sPuppyIP.com%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf '%s  原生住宅静态 IP · 固定地区 · 长期使用%s\n' "$C_BOLD" "$C_RESET"
  show_tutorial_hint '  '
  printf '\n'
}

show_brand_footer() {
  printf '\n%s%sPuppyIP.com%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf '%s原生住宅静态 IP · 固定地区 · 长期使用%s\n' "$C_BOLD" "$C_RESET"
  show_tutorial_hint
}

show_tutorial_hint() {
  local indent="${1:-}"
  [[ "$TUTORIAL_HINT_SHOWN" != 'yes' ]] || return 0
  printf '%s%s教程：%s%s\n' "$indent" "$C_CYAN" "$TUTORIAL_URL" "$C_RESET"
  printf '%s选择：VPS配置教程 → VPS 链式代理配置\n' "$indent"
  TUTORIAL_HINT_SHOWN='yes'
}

refresh_brand_banner() {
  # Never clear the terminal: users must be able to scroll back and inspect
  # the complete installation history. Direct commands still show the brand
  # once, while menu operations reuse the banner already printed by main.
  [[ "$BRAND_BANNER_SHOWN" == 'yes' ]] || show_brand_banner
}

show_error_log() {
  local log_file="$1" matched='no' pattern message
  [[ -s "$log_file" ]] || return 0
  printf '%s---- 错误原因摘要 ----%s\n' "$C_RED" "$C_RESET" >&2
  # Never echo arbitrary subprocess text: Xray errors may contain credentials.
  while IFS='|' read -r pattern message; do
    pattern="${pattern//;/|}"
    if grep -Eiq -- "$pattern" "$log_file"; then
      printf '  %s\n' "$message" >&2
      matched='yes'
    fi
  done <<'CAUSES'
permission denied;operation not permitted;read-only file system|文件权限不足或文件系统只读；请检查目标目录权限和挂载状态。
no space left;disk quota exceeded|磁盘空间或配额不足；请用 df -h 和 df -i 检查空间及 inode。
could not get lock;unable to acquire.*lock;dpkg.*locked|系统软件包锁被占用；请等待其他 apt/dpkg 操作结束后重试。
could not resolve;temporary failure in name resolution;name or service not known|DNS 解析失败；请检查 VPS 的 DNS 和到目标域名的网络。
timed out;timeout was reached;connection timeout|网络请求超时；请检查 VPS 到提示目标的网络可达性。
connection refused;failed to connect;network is unreachable;no route to host|连接被拒绝或网络/路由不可达；请检查目标端口和 VPS 网络。
certificate verify;ssl certificate;tls handshake;ssl connect error|TLS 握手或证书校验失败；请检查系统时间、CA 证书和目标站点。
address already in use;failed to listen|监听端口冲突或无法绑定；请用 ss -lntup 检查入口端口，不要直接停止其他面板。
invalid.*key;failed to parse.*key;empty.*key|密钥字段校验失败；请检查 REALITY 密钥与核心版本，勿重新生成已有线路凭据。
invalid.*uuid;failed.*uuid|节点 UUID 格式校验失败；请检查该节点的保存状态和配置。
invalid.*json;invalid character;unexpected.*token;unexpected.*end;failed to.*config|配置语法或结构校验失败；请检查配置格式、字段及核心版本是否匹配。
geoip.*not found;geosite.*not found;failed to load.*dat|Geo 数据读取失败；请检查 geoip.dat、geosite.dat 是否完整且可读。
unable to locate package;no installation candidate;unmet dependencies;dpkg was interrupted|软件源或软件包状态异常；请修复 apt 软件源或未完成的 dpkg 操作后重试。
requested URL returned error|下载服务返回 HTTP 错误；请检查目标发布文件是否存在及网络访问限制。
CAUSES
  if [[ "$matched" == 'no' ]]; then
    printf '  底层错误未能自动分类；请按本次失败步骤检查对应文件或服务。原始输出可能含连接凭据，未直接显示。\n' >&2
  fi
}

show_socks_promo() {
  local mode="${1:-add}"
  printf '\n%s%shttps://PuppyIP.com%s · 原生住宅静态 IP\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  if [[ "$mode" == 'edit' ]]; then
    printf 'SOCKS5：IP:端口:用户名:密码\n'
    printf '直接回车 = 保留当前出口\n'
  else
    printf 'SOCKS5（支持批量，最多 %s 条）：IP:端口:用户名:密码\n' "$MAX_BATCH_SIZE"
    printf '直接回车 = 使用 VPS 本机 IP\n'
  fi
}

show_management_hint() {
  info "管理菜单：输入 puppyip"
}

cleanup() {
  local path
  for path in "${TEMP_DIRS[@]:-}"; do
    if [[ ( "$path" == /var/tmp/xray-chain.* || "$path" == /tmp/xray-chain.* ) && -d "$path" ]]; then
      rm -rf -- "$path"
    fi
  done
}
trap cleanup EXIT

new_temp_dir() {
  local path temp_base='/var/tmp'
  [[ -d "$temp_base" ]] || temp_base='/tmp'
  if ! path="$(mktemp -d "${temp_base}/xray-chain.XXXXXXXX")"; then
    warn "创建 PuppyIP 临时目录失败：${temp_base}；请检查目录权限、磁盘空间及 inode。"
    return 1
  fi
  TEMP_DIRS+=("$path")
  LAST_TEMP_DIR="$path"
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行，例如：sudo bash install.sh"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 \
    || die_unsupported_system "当前环境未安装 systemd，本脚本无法继续。"
  [[ -d /run/systemd/system ]] \
    || die_unsupported_system "当前环境没有运行 systemd；本脚本不支持无 systemd 的容器环境。"
}

acquire_lock() {
  command -v flock >/dev/null 2>&1 || die "缺少 flock（util-linux），无法安全执行并发保护。"
  mkdir -p "$(dirname "$LOCK_FILE")" || die "创建操作锁目录失败：$(dirname "$LOCK_FILE")；请检查权限和磁盘空间。"
  exec 9>"$LOCK_FILE" || die "打开操作锁失败：${LOCK_FILE}；请检查目录权限和文件属性。"
  flock -n 9 || die "另一个 PuppyIP 安装或管理操作正在运行（锁：${LOCK_FILE}）；请等待该操作结束后重试。"
}

installation_complete() {
  [[ -r "$STATE_FILE" && -r "$CONFIG_FILE" && -x "$XRAY_BIN" \
    && -f "${ASSET_DIR}/geoip.dat" && -f "${ASSET_DIR}/geosite.dat" \
    && -r "$SERVICE_FILE" ]]
}

check_platform() {
  local ID='' VERSION_ID='' PRETTY_NAME='unknown'
  [[ -r "$OS_RELEASE_FILE" ]] \
    || die_unsupported_system "无法识别当前操作系统，本脚本无法继续。"
  # shellcheck disable=SC1090
  . "$OS_RELEASE_FILE"
  case "${ID:-}" in
    ubuntu)
      case "${VERSION_ID:-}" in
        22.04|24.04|26.04) ;;
        *)
          die_unsupported_system \
            "当前系统 ${PRETTY_NAME:-unknown} 不在支持范围内；仅支持仍在范围内的 Ubuntu LTS 版本。"
          ;;
      esac
      ;;
    debian)
      case "${VERSION_ID%%.*}" in
        12|13) ;;
        *)
          die_unsupported_system \
            "当前系统 ${PRETTY_NAME:-unknown} 不在支持范围内；当前仅支持 Debian 12 或 Debian 13。"
          ;;
      esac
      ;;
    *)
      die_unsupported_system \
        "当前系统 ${PRETTY_NAME:-unknown} 不受支持；仅支持列表中的原版 Ubuntu 或 Debian。"
      ;;
  esac
  command -v apt-get >/dev/null 2>&1 \
    || die_unsupported_system "当前系统未找到 apt-get，本脚本无法继续。"
  if ! command -v dpkg >/dev/null 2>&1 || ! command -v dpkg-query >/dev/null 2>&1; then
    die_unsupported_system "当前系统未找到 dpkg/dpkg-query，本脚本无法继续。"
  fi
  map_arch >/dev/null
}

unit_file_is_installed() {
  local unit="$1"
  systemctl list-unit-files --type=service --no-legend "$unit" 2>/dev/null \
    | grep -q "^${unit}[[:space:]]"
}

detect_existing_proxy_stacks() {
  local -a detected=()
  if unit_file_is_installed 'x-ui.service' || [[ -d /usr/local/x-ui ]]; then
    detected+=('x-ui / 3x-ui')
  fi
  if unit_file_is_installed 's-ui.service' || [[ -d /usr/local/s-ui ]]; then
    detected+=('S-UI')
  fi
  if unit_file_is_installed 'xray.service' \
    || [[ -d /etc/xray || -d /usr/local/etc/xray ]]; then
    detected+=('独立 Xray')
  fi
  if unit_file_is_installed 'v2ray.service' \
    || [[ -d /etc/v2ray || -d /usr/local/etc/v2ray ]]; then
    detected+=('独立 V2Ray')
  fi
  if unit_file_is_installed 'sing-box.service' && [[ ! -d /usr/local/s-ui ]]; then
    detected+=('独立 sing-box')
  fi

  (( ${#detected[@]} > 0 )) || return 0
  info "检测到 ${detected[*]}；已避开其端口，不会修改原配置。"
}

install_dependencies() {
  local work_dir="$1" log_file package missing='no'
  local -a required_packages=(ca-certificates curl unzip jq openssl iproute2 util-linux sqlite3 kmod procps)
  log_file="${work_dir}/dependencies.log"

  for package in "${required_packages[@]}"; do
    if ! dpkg-query -W -f='${Status}\n' "$package" 2>/dev/null | grep -Fqx 'install ok installed'; then
      missing='yes'
      break
    fi
  done

  export DEBIAN_FRONTEND=noninteractive
  if [[ "$missing" == 'yes' ]]; then
    if ! run_logged_task "更新软件源" "$log_file" apt-get update; then
      show_error_log "$log_file"
      die "apt 软件源索引更新失败，未进入节点部署；请按上方原因修复后执行 apt-get update。"
    fi
    if ! run_logged_task "安装系统依赖" "$log_file" apt-get install -y "${required_packages[@]}"; then
      show_error_log "$log_file"
      die "apt 安装系统依赖失败，未进入节点部署；请按上方原因检查软件包状态、磁盘或 apt 锁后重试。"
    fi
  fi

  if ! command -v qrencode >/dev/null 2>&1; then
    if ! run_logged_task "安装二维码组件" "$log_file" apt-get install -y qrencode; then
      warn "二维码组件 qrencode 安装失败，将只显示链接；可在修复 apt 后执行 apt-get install -y qrencode。"
    fi
  fi
}

managed_bbr_file() {
  local file="$1" first_line=''
  [[ -f "$file" ]] || return 1
  IFS= read -r first_line <"$file" || true
  [[ "$first_line" == "$BBR_MANAGED_HEADER" ]]
}

valid_kernel_setting_token() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

read_sysctl_value() {
  sysctl -n "$1" 2>/dev/null | tr -d '\r\n' || true
}

bbr_state_is_valid() {
  [[ -r "$BBR_STATE_FILE" ]] || return 1
  jq -e '
    .managedBy == "PuppyIP Xray Chain"
    and (.previousCongestionControl | type == "string" and test("^[A-Za-z0-9_-]+$"))
    and (.previousDefaultQdisc | type == "string" and test("^[A-Za-z0-9_-]+$"))
  ' "$BBR_STATE_FILE" >/dev/null 2>&1
}

restore_bbr_settings() {
  local previous_cc previous_qdisc restore_failed='no'
  [[ -e "$BBR_STATE_FILE" ]] || return 0
  if ! bbr_state_is_valid; then
    warn "BBR 恢复记录格式异常，已保留 ${BBR_STATE_FILE} 供人工检查。"
    return 0
  fi

  previous_cc="$(jq -er '.previousCongestionControl' "$BBR_STATE_FILE")"
  previous_qdisc="$(jq -er '.previousDefaultQdisc' "$BBR_STATE_FILE")"
  managed_bbr_file "$BBR_SYSCTL_FILE" && rm -f -- "$BBR_SYSCTL_FILE"
  managed_bbr_file "$BBR_MODULES_FILE" && rm -f -- "$BBR_MODULES_FILE"

  if command -v modprobe >/dev/null 2>&1; then
    modprobe "sch_${previous_qdisc}" >/dev/null 2>&1 || true
    modprobe "tcp_${previous_cc}" >/dev/null 2>&1 || true
  fi
  if ! command -v sysctl >/dev/null 2>&1 \
    || ! sysctl -q -w "net.core.default_qdisc=${previous_qdisc}" >/dev/null 2>&1 \
    || ! sysctl -q -w "net.ipv4.tcp_congestion_control=${previous_cc}" >/dev/null 2>&1; then
    restore_failed='yes'
  fi

  if [[ "$restore_failed" == 'yes' ]]; then
    warn "BBR 恢复失败：无法写回原 TCP 拥塞控制或默认 qdisc；请检查 sysctl 权限和内核支持，恢复记录保留在 ${BBR_STATE_FILE}。"
    return 0
  fi
  rm -f -- "$BBR_STATE_FILE"
  info "已恢复原 TCP 设置。"
}

configure_bbr() {
  local preference current_cc current_qdisc available previous_cc previous_qdisc
  local work_dir state_candidate sysctl_candidate modules_candidate
  BBR_CHANGED='no'
  preference="${XRAY_CHAIN_ENABLE_BBR:-1}"
  case "${preference,,}" in
    1|true|yes|on|'') ;;
    0|false|no|off)
      info "已跳过 BBR。"
      return 0
      ;;
    *)
      warn "XRAY_CHAIN_ENABLE_BBR 设置无效，已跳过 BBR；请使用 1（启用）或 0（跳过）。"
      return 0
      ;;
  esac

  if ! command -v sysctl >/dev/null 2>&1; then
    warn "无法启用 BBR：未找到 sysctl，已跳过；请检查 procps 是否安装。"
    return 0
  fi
  current_cc="$(read_sysctl_value net.ipv4.tcp_congestion_control)"
  current_qdisc="$(read_sysctl_value net.core.default_qdisc)"
  if ! valid_kernel_setting_token "$current_cc" \
    || ! valid_kernel_setting_token "$current_qdisc"; then
    warn "无法启用 BBR：读取 net.ipv4.tcp_congestion_control 或 net.core.default_qdisc 失败，已跳过；请检查内核和 sysctl 权限。"
    return 0
  fi
  if [[ "$current_cc" == 'bbr' ]]; then
    info "BBR 已启用。"
    return 0
  fi

  if [[ -e "$BBR_SYSCTL_FILE" ]] && ! managed_bbr_file "$BBR_SYSCTL_FILE"; then
    warn "BBR 已跳过：${BBR_SYSCTL_FILE} 不属于 PuppyIP，未覆盖；请先检查该文件的来源。"
    return 0
  fi
  if [[ -e "$BBR_MODULES_FILE" ]] && ! managed_bbr_file "$BBR_MODULES_FILE"; then
    warn "BBR 已跳过：${BBR_MODULES_FILE} 不属于 PuppyIP，未覆盖；请先检查该文件的来源。"
    return 0
  fi
  if [[ -e "$BBR_STATE_FILE" ]]; then
    if ! bbr_state_is_valid; then
      warn "BBR 恢复记录格式异常：${BBR_STATE_FILE}，已跳过；请保留该文件并检查内容，勿直接覆盖。"
      return 0
    fi
    previous_cc="$(jq -er '.previousCongestionControl' "$BBR_STATE_FILE")"
    previous_qdisc="$(jq -er '.previousDefaultQdisc' "$BBR_STATE_FILE")"
  else
    previous_cc="$current_cc"
    previous_qdisc="$current_qdisc"
  fi

  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe sch_fq >/dev/null 2>&1 || true
  fi
  available="$(read_sysctl_value net.ipv4.tcp_available_congestion_control)"
  if [[ " ${available} " != *' bbr '* ]]; then
    warn "内核可用拥塞控制中没有 bbr，已跳过；可用 sysctl net.ipv4.tcp_available_congestion_control 检查内核支持。"
    return 0
  fi

  new_temp_dir
  work_dir="$LAST_TEMP_DIR"
  state_candidate="${work_dir}/bbr-state.json"
  sysctl_candidate="${work_dir}/99-zz-puppyip-bbr.conf"
  modules_candidate="${work_dir}/puppyip-bbr.conf"
  if ! jq -n \
    --arg managed_by 'PuppyIP Xray Chain' \
    --arg previous_cc "$previous_cc" \
    --arg previous_qdisc "$previous_qdisc" '
      {
        managedBy: $managed_by,
        previousCongestionControl: $previous_cc,
        previousDefaultQdisc: $previous_qdisc
      }
    ' >"$state_candidate"; then
    warn "生成 BBR 恢复记录失败，已跳过；请检查 jq、临时目录权限和磁盘空间。"
    return 0
  fi
  printf '%s\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' \
    "$BBR_MANAGED_HEADER" >"$sysctl_candidate"
  printf '%s\ntcp_bbr\nsch_fq\n' "$BBR_MANAGED_HEADER" >"$modules_candidate"
  if ! install -d -o root -g root -m 0755 "$(dirname "$BBR_SYSCTL_FILE")" \
    "$(dirname "$BBR_MODULES_FILE")"; then
    warn "创建 BBR 配置目录失败，已跳过；请检查 /etc/sysctl.d 和 /etc/modules-load.d 的权限及磁盘空间。"
    return 0
  fi

  if [[ ! -e "$BBR_STATE_FILE" ]] \
    && ! atomic_install "$state_candidate" "$BBR_STATE_FILE" 0600 root root; then
    warn "保存 BBR 恢复记录失败：${BBR_STATE_FILE}，已跳过；请检查上方文件写入错误。"
    return 0
  fi
  if ! atomic_install "$sysctl_candidate" "$BBR_SYSCTL_FILE" 0644 root root \
    || ! atomic_install "$modules_candidate" "$BBR_MODULES_FILE" 0644 root root \
    || ! sysctl -q -w net.core.default_qdisc=fq >/dev/null 2>&1 \
    || ! sysctl -q -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 \
    || [[ "$(read_sysctl_value net.core.default_qdisc)" != 'fq' ]] \
    || [[ "$(read_sysctl_value net.ipv4.tcp_congestion_control)" != 'bbr' ]]; then
    warn "BBR 配置写入、sysctl 应用或生效检查失败，正在恢复原 TCP 设置；请检查文件权限及内核支持。"
    restore_bbr_settings
    return 0
  fi

  BBR_CHANGED='yes'
  info "BBR 已启用。"
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    if systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 \
      && sleep 1 \
      && systemctl is-active --quiet "$SERVICE_NAME"; then
      :
    else
      warn "应用 BBR 后 ${SERVICE_NAME} 未保持运行；请执行 puppyip status 检查服务，修复原因后执行 systemctl restart ${SERVICE_NAME}。"
      systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
  fi
}

map_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '64' ;;
    aarch64|arm64) printf 'arm64-v8a' ;;
    armv7l|armv7) printf 'arm32-v7a' ;;
    *) die_unsupported_architecture "$(uname -m)" ;;
  esac
}

download_file() {
  local output="$1" url="$2" max_time="$3" show_progress="${4:-no}"
  local label="${5:-下载文件}" log_file status
  local -a curl_args=(
    --fail
    --show-error
    --location
    --retry 3
    --connect-timeout 10
    --max-time "$max_time"
    --output "$output"
  )

  if [[ "$show_progress" != 'yes' ]] || ! interactive_progress_enabled; then
    curl --silent "${curl_args[@]}" "$url"
    return
  fi

  log_file="${output}.download.log"
  if run_download_task "$label" "$log_file" curl --progress-bar "${curl_args[@]}" "$url"; then
    rm -f -- "$log_file"
    return 0
  else
    status=$?
  fi
  show_error_log "$log_file"
  return "$status"
}

resolve_xray_version() {
  local tag="${XRAY_VERSION:-$DEFAULT_XRAY_VERSION}" response status
  if [[ "$tag" == 'latest' ]]; then
    if response="$(curl --fail --silent --show-error --location --retry 3 \
      --connect-timeout 10 --max-time 30 \
      -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: xray-chain-installer' \
      'https://api.github.com/repos/XTLS/Xray-core/releases/latest' 2>/dev/null)"; then
      :
    else
      status=$?
      die "获取 Xray 最新版本失败（api.github.com，curl 代码 ${status}）；请检查 VPS 到 GitHub API 的网络后重试。"
    fi
    tag="$(jq -er '.tag_name' <<<"$response" 2>/dev/null)" \
      || die "Xray 最新版本响应缺少有效版本信息；请检查 GitHub API 是否可达，未下载核心。"
  fi
  [[ "$tag" =~ ^v[0-9][0-9A-Za-z.-]*$ ]] || die "Xray 版本号不合法：$tag"
  printf '%s' "$tag"
}

download_xray() {
  local destination="$1"
  local arch tag asset base_url zip_file digest_file expected actual member
  local -A archive_members=()
  arch="$(map_arch)"
  tag="$(resolve_xray_version)"
  asset="Xray-linux-${arch}.zip"
  base_url="https://github.com/XTLS/Xray-core/releases/download/${tag}"
  zip_file="${destination}/${asset}"
  digest_file="${zip_file}.dgst"

  if ! download_file "$zip_file" "${base_url}/${asset}" 300 yes "下载 Xray-core ${tag}"; then
    die "下载 Xray-core ${tag}（${asset}）失败，来源 github.com/XTLS/Xray-core；请检查 VPS 到 GitHub 的网络和磁盘空间后重试。"
  fi
  if ! download_file "$digest_file" "${base_url}/${asset}.dgst" 30; then
    die "下载 Xray-core ${tag} 的 ${asset}.dgst 摘要文件失败；请检查 VPS 到 GitHub 的网络后重试，未使用未经校验的压缩包。"
  fi

  expected="$(awk -F'= *' '/^SHA2-256=/{print $2; exit}' "$digest_file" | tr -d '[:space:]')"
  [[ "$expected" =~ ^[0-9A-Fa-f]{64}$ ]] || die "Xray ${tag} 的 ${asset}.dgst 未包含有效 SHA2-256；已停止安装，请检查官方发布文件后重试。"
  actual="$(sha256sum "$zip_file" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "Xray ${tag} 的 ${asset} SHA-256 校验失败，与官方摘要不符；已停止安装，请重新下载，勿跳过校验。"

  while IFS= read -r member; do
    case "$member" in
      ''|/*|*/*|*\\*) die "Xray 压缩包包含不安全路径：${member}" ;;
    esac
    [[ -z "${archive_members[$member]+present}" ]] || die "Xray 压缩包包含重复文件：${member}"
    archive_members["$member"]='present'
  done < <(unzip -Z1 "$zip_file")
  [[ -n "${archive_members[xray]+present}" \
    && -n "${archive_members[geoip.dat]+present}" \
    && -n "${archive_members[geosite.dat]+present}" ]] \
    || die "Xray 压缩包缺少必要文件。"

  mkdir -p "${destination}/xray"
  unzip -q "$zip_file" -d "${destination}/xray" \
    || die "解压 Xray ${tag} 的 ${asset} 失败；请检查压缩包、临时目录权限及磁盘空间，未部署本次核心。"
  [[ -f "${destination}/xray/xray" && ! -L "${destination}/xray/xray" ]] || die "Xray 压缩包缺少安全的 xray 文件。"
  [[ -f "${destination}/xray/geoip.dat" && ! -L "${destination}/xray/geoip.dat" ]] || die "Xray 压缩包缺少安全的 geoip.dat。"
  [[ -f "${destination}/xray/geosite.dat" && ! -L "${destination}/xray/geosite.dat" ]] || die "Xray 压缩包缺少安全的 geosite.dat。"
  chmod 0755 "${destination}/xray/xray"
  printf '%s' "$tag" >"${destination}/xray-version"
}

stage_installed_xray() {
  local destination="$1" version
  [[ -x "$XRAY_BIN" && ! -L "$XRAY_BIN" \
    && -f "${ASSET_DIR}/geoip.dat" && ! -L "${ASSET_DIR}/geoip.dat" \
    && -f "${ASSET_DIR}/geosite.dat" && ! -L "${ASSET_DIR}/geosite.dat" ]] || return 1

  version="$(state_value '.xrayVersion' '')"
  [[ "$version" =~ ^v?[0-9][0-9A-Za-z.-]*$ ]] || return 1

  mkdir -p "${destination}/xray"
  cp -- "$XRAY_BIN" "${destination}/xray/xray"
  cp -- "${ASSET_DIR}/geoip.dat" "${destination}/xray/geoip.dat"
  cp -- "${ASSET_DIR}/geosite.dat" "${destination}/xray/geosite.dat"
  chmod 0755 "${destination}/xray/xray"
  printf '%s' "$version" >"${destination}/xray-version"
}

prompt_default() {
  local variable="$1" label="$2" default_value="$3" answer
  if [[ -n "$default_value" ]]; then
    if ! read -r -p "${label} [${default_value}]: " answer; then
      die "未读取到输入：${label}。"
    fi
    answer="${answer:-$default_value}"
  else
    if ! read -r -p "${label}: " answer; then
      die "未读取到输入：${label}。"
    fi
  fi
  printf -v "$variable" '%s' "$answer"
}

prompt_yes_no() {
  local variable="$1" label="$2" default_value="$3" input_answer suffix
  if [[ "$default_value" == "yes" ]]; then
    suffix='[y=同意 / n=不同意 / 回车=同意]'
  else
    suffix='[y=同意 / n=不同意 / 回车=不同意]'
  fi
  while true; do
    if ! read -r -p "${label} ${suffix}: " input_answer; then input_answer=''; fi
    input_answer="${input_answer:-$default_value}"
    case "${input_answer,,}" in
      y|yes|是)
        printf -v "$variable" 'yes'
        return 0
        ;;
      n|no|否)
        printf -v "$variable" 'no'
        return 0
        ;;
      *) warn "请输入 y（同意）或 n（不同意）。" ;;
    esac
  done
}

confirm_destructive_action() {
  local label="$1" confirmed='no'
  prompt_yes_no confirmed "$label" 'no'
  [[ "$confirmed" == 'yes' ]]
}

confirm_continue() {
  local label="$1" confirmed='no'
  if [[ ! -t 0 ]]; then
    [[ "${XRAY_CHAIN_ALLOW_UNVERIFIED:-0}" == "1" ]] || die "非交互模式下验证失败；若确认继续，请设置 XRAY_CHAIN_ALLOW_UNVERIFIED=1。"
    return 0
  fi
  prompt_yes_no confirmed "$label" 'no'
  [[ "$confirmed" == 'yes' ]] || die "已取消。"
}

valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  port="${port#"${port%%[!0]*}"}"
  [[ -n "$port" && ${#port} -le 5 ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
}

valid_ipv4() {
  local address="$1" octet
  local -a octets=()
  [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$address"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
}

valid_domain_name() {
  local value="${1,,}" label
  local -a labels=()
  [[ -n "$value" && ${#value} -le 253 ]] || return 1
  [[ "$value" =~ ^[a-z0-9.-]+$ ]] || return 1
  [[ "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
  IFS='.' read -r -a labels <<<"$value"
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
}

valid_ipv4_or_domain() {
  local value="$1"
  if [[ "$value" =~ ^[0-9.]+$ ]]; then
    valid_ipv4 "$value"
  else
    valid_domain_name "$value"
  fi
}

parse_socks5_entry() {
  local input="$1" host remainder port auth user='' pass=''
  [[ "$input" == *:* ]] || return 1
  host="${input%%:*}"
  remainder="${input#*:}"
  port="${remainder%%:*}"

  if [[ "$remainder" == *:* ]]; then
    auth="${remainder#*:}"
    [[ "$auth" == *:* ]] || return 1
    user="${auth%%:*}"
    pass="${auth#*:}"
    [[ -n "$user" && -n "$pass" ]] || return 1
    [[ ! "$user" =~ [[:cntrl:]] && ! "$pass" =~ [[:cntrl:]] ]] || return 1
  fi

  valid_ipv4_or_domain "$host" || return 1
  valid_port "$port" || return 1
  SOCKS_HOST="$host"
  SOCKS_PORT="$port"
  SOCKS_USER="$user"
  SOCKS_PASS="$pass"
}

parse_socks5_batch_input() {
  local input="$1" normalized entry index=0
  local -a candidates=()
  SOCKS_BATCH_ENTRIES=()
  SOCKS_BATCH_ERROR_INDEX=''
  normalized="${input//$'\r'/ }"
  normalized="${normalized//$'\n'/ }"
  normalized="${normalized//$'\t'/ }"
  read -r -a candidates <<<"$normalized"
  (( ${#candidates[@]} > 0 )) || return 1
  (( ${#candidates[@]} <= MAX_BATCH_SIZE )) || return 2

  for entry in "${candidates[@]}"; do
    ((index += 1))
    if ! parse_socks5_entry "$entry"; then
      SOCKS_BATCH_ERROR_INDEX="$index"
      SOCKS_BATCH_ENTRIES=()
      return 3
    fi
    SOCKS_BATCH_ENTRIES+=("$entry")
  done
}

read_hidden_socks_batch_input() {
  local prompt="$1" line
  SOCKS_BATCH_RAW=''
  reserve_prompt_space
  if ! IFS= read -r -s -p "$prompt" line; then
    release_prompt_space
    die "未读取到 SOCKS5 信息。"
  fi
  SOCKS_BATCH_RAW="$line"

  # SSH clients normally send a multi-line paste as one burst. Briefly drain
  # any complete lines already waiting so pasted rows remain one operation.
  while IFS= read -r -s -t 0.20 line; do
    SOCKS_BATCH_RAW+=$'\n'"$line"
  done
  release_prompt_space
}

strip_ipv6_brackets() {
  local value="$1"
  value="${value#[}"
  value="${value%]}"
  printf '%s' "$value"
}

detect_public_ipv4() {
  local endpoint result=''
  local connect_timeout="${1:-4}" max_time="${2:-6}"
  local -a endpoints=(
    'https://api.ipify.org'
    'https://ipv4.icanhazip.com'
    'https://ifconfig.me/ip'
  )
  for endpoint in "${endpoints[@]}"; do
    if ! result="$(curl --disable -4 --fail --silent --show-error --noproxy '*' \
      --connect-timeout "$connect_timeout" --max-time "$max_time" "$endpoint" 2>/dev/null)"; then
      continue
    fi
    result="${result//[[:space:]]/}"
    if valid_ipv4 "$result"; then
      printf '%s' "$result"
      return 0
    fi
  done
  return 1
}

eligible_share_ipv4() {
  local address="$1" a b c d
  valid_ipv4 "$address" || return 1
  IFS='.' read -r a b c d <<<"$address"
  a=$((10#$a)); b=$((10#$b)); c=$((10#$c))
  # scope=global also includes private addresses; they are not public entrances.
  (( a != 0 && a != 10 && a != 127 && a < 224 )) || return 1
  (( a != 100 || b < 64 || b > 127 )) || return 1
  (( a != 169 || b != 254 )) || return 1
  (( a != 172 || b < 16 || b > 31 )) || return 1
  (( a != 192 || (b != 168 && (b != 0 || c != 0) && (b != 88 || c != 99)) )) || return 1
  (( a != 198 || (b != 18 && b != 19) )) || return 1
}

resolve_share_address() {
  local saved local_json local_addresses address detected candidate=''
  local candidate_count=0
  saved="$(jq -er '.serverAddress' "$STATE_FILE")" || return 1
  if [[ "${XRAY_CHAIN_AUTO_ADDRESS:-1}" == '0' ]] || ! valid_ipv4 "$saved"; then
    printf '%s' "$saved"
    return 0
  fi
  if ! local_json="$(ip -j -4 address show scope global 2>/dev/null)" \
    || ! local_addresses="$(jq -er '
      if type != "array" then error("invalid address list") else
        [.[] | .addr_info[]? | select(.family == "inet" and .scope == "global")
          | .local | select(type == "string")] | unique | .[]
      end' <<<"$local_json" 2>/dev/null)"; then
    printf '%s' "$saved"
    return 0
  fi
  while IFS= read -r address; do
    if [[ "$address" == "$saved" ]]; then
      printf '%s' "$saved"
      return 0
    fi
    if eligible_share_ipv4 "$address"; then
      candidate="$address"
      ((candidate_count += 1))
    fi
  done <<<"$local_addresses"
  if (( candidate_count == 1 )); then
    # Reuse the direct-exit probe from this display, including a failed probe.
    if (( $# > 0 )); then
      detected="$1"
    else
      detected="$(detect_public_ipv4 2 3 2>/dev/null || true)"
    fi
    if [[ "$detected" == "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  fi
  printf '%s' "$saved"
}

detect_display_direct_ip() {
  local detected
  detected="$(detect_public_ipv4 2 3 2>/dev/null || true)"
  eligible_share_ipv4 "$detected" || return 1
  printf '%s' "$detected"
}

resolve_display_addresses() {
  local STATE_FILE="$1"
  RESOLVED_DIRECT_IP=''
  if jq -e 'any(.nodes[]?; .type == "direct")' "$STATE_FILE" >/dev/null; then
    RESOLVED_DIRECT_IP="$(detect_display_direct_ip || true)"
    RESOLVED_SHARE_ADDRESS="$(resolve_share_address "$RESOLVED_DIRECT_IP")"
  else
    RESOLVED_SHARE_ADDRESS="$(resolve_share_address)"
  fi
}

state_value() {
  local filter="$1" fallback="${2:-}"
  if [[ -r "$STATE_FILE" ]]; then
    jq -er "$filter // empty" "$STATE_FILE" 2>/dev/null || printf '%s' "$fallback"
  else
    printf '%s' "$fallback"
  fi
}

port_is_listening() {
  local port="$1"
  ss -H -lntu 2>/dev/null \
    | awk -v suffix=":${port}" '
        {
          for (field = 1; field <= NF; field += 1) {
            if ($field ~ (suffix "$")) found = 1
          }
        }
        END {exit !found}
      '
}

add_panel_reserved_port() {
  local candidate="$1" existing
  valid_port "$candidate" || return 0
  for existing in "${PANEL_RESERVED_PORTS[@]:-}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  PANEL_RESERVED_PORTS+=("$candidate")
}

sqlite_table_exists() {
  local database="$1" table="$2" result
  [[ -r "$database" ]] || return 1
  result="$(sqlite3 -readonly -batch -noheader -cmd '.timeout 1000' "$database" \
    "PRAGMA query_only=ON; SELECT count(*) FROM sqlite_master WHERE type='table' AND name='${table}';" \
    2>/dev/null || true)"
  [[ "$result" == '1' ]]
}

add_sqlite_query_ports() {
  local database="$1" query="$2" candidate
  while IFS= read -r candidate; do
    add_panel_reserved_port "$candidate"
  done < <(sqlite3 -readonly -batch -noheader -cmd '.timeout 1000' "$database" \
    "PRAGMA query_only=ON; ${query}" 2>/dev/null || true)
}

collect_xui_database_ports() {
  local database="$1"
  [[ -r "$database" ]] || return 0
  if sqlite_table_exists "$database" 'settings'; then
    add_sqlite_query_ports "$database" \
      "SELECT value FROM settings WHERE key IN ('webPort','subPort');"
  fi
  if sqlite_table_exists "$database" 'inbounds'; then
    add_sqlite_query_ports "$database" 'SELECT port FROM inbounds;'
  fi
}

collect_sui_database_ports() {
  local database="$1"
  [[ -r "$database" ]] || return 0
  if sqlite_table_exists "$database" 'settings'; then
    add_sqlite_query_ports "$database" \
      "SELECT value FROM settings WHERE key IN ('webPort','subPort');"
  fi
  if sqlite_table_exists "$database" 'inbounds'; then
    add_sqlite_query_ports "$database" \
      "SELECT json_extract(options, '$.listen_port') FROM inbounds WHERE json_valid(options);"
  fi
}

collect_panel_reserved_ports() {
  local database
  PANEL_RESERVED_PORTS=()
  command -v sqlite3 >/dev/null 2>&1 || return 0

  for database in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db; do
    collect_xui_database_ports "$database"
  done
  for database in /usr/local/s-ui/db/s-ui.db /usr/local/s-ui/s-ui.db /etc/s-ui/s-ui.db; do
    collect_sui_database_ports "$database"
  done
}

panel_port_is_reserved() {
  local candidate="$1" reserved
  for reserved in "${PANEL_RESERVED_PORTS[@]:-}"; do
    [[ "$reserved" == "$candidate" ]] && return 0
  done
  return 1
}

port_is_common_or_panel_port() {
  case "$1" in
    22|53|80|433|443|2053|2083|2087|2095|2096|3000|3389|5432|6379|8080|8443|8888|10000|27017|51820|54321)
      return 0
      ;;
    *) return 1 ;;
  esac
}

generate_auto_port_candidate() {
  local random_value range_size
  random_value="$(od -An -N4 -tu4 /dev/urandom | tr -d '[:space:]')"
  [[ "$random_value" =~ ^[0-9]+$ ]] || die "无法从系统安全随机源选择端口。"
  range_size="$((AUTO_PORT_MAX - AUTO_PORT_MIN + 1))"
  AUTO_PORT_CANDIDATE="$((AUTO_PORT_MIN + random_value % range_size))"
}

select_inbound_port() {
  local requested="${XRAY_CHAIN_PORT:-}" candidate attempt
  local excluded_ports=" $* "
  collect_panel_reserved_ports
  if [[ -n "$requested" ]]; then
    valid_port "$requested" \
      || die "XRAY_CHAIN_PORT 必须是 1-65535 的单个整数端口。"
    [[ "$excluded_ports" != *" $requested "* ]] || die "指定入口端口 ${requested}/tcp 已分配给现有节点；请用 puppyip list 查看占用，或取消 XRAY_CHAIN_PORT 设置后使用随机端口。"
    if port_is_listening "$requested"; then
      die "指定端口 ${requested} 已被现有 TCP 或 UDP 服务占用。"
    fi
    if panel_port_is_reserved "$requested"; then
      die "指定端口 ${requested} 已保存在 x-ui/3x-ui 或 S-UI 配置中，即使面板当前停止也不能使用。"
    fi
    if port_is_common_or_panel_port "$requested"; then
      warn "指定端口 ${requested} 常用于系统、Web、面板或其他代理；已按你的明确设置继续。"
    fi
    INBOUND_PORT="$requested"
    return
  fi

  for ((attempt = 1; attempt <= 128; attempt += 1)); do
    generate_auto_port_candidate
    candidate="$AUTO_PORT_CANDIDATE"
    [[ "$excluded_ports" == *" $candidate "* ]] && continue
    port_is_common_or_panel_port "$candidate" && continue
    panel_port_is_reserved "$candidate" && continue
    if ! port_is_listening "$candidate"; then
      INBOUND_PORT="$candidate"
      return
    fi
  done
  die "连续 128 次未找到可用高位端口，请检查现有监听服务后重试。"
}

model_inbound_ports() {
  jq -r '. as $s | if (.schema // 1) == 2 then
    [.nodes[] | (.inboundPort // $s.inboundPort)] | unique[]
    else .inboundPort end' "$1"
}

assert_model_port_available() {
  local file="$1" port installed_ports=''
  if [[ -r "$STATE_FILE" ]]; then
    installed_ports="$(model_inbound_ports "$STATE_FILE" 2>/dev/null || true)"
  fi
  while IFS= read -r port; do
    port_is_listening "$port" || continue
    if [[ $'\n'"$installed_ports"$'\n' == *$'\n'"$port"$'\n'* ]] \
      && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      continue
    fi
    die "端口 ${port}/tcp 在确认配置期间被其他程序占用，请重新运行。"
  done < <(model_inbound_ports "$file")
}

collect_global_settings() {
  local detected_ip reality_migrated='no'

  detected_ip="$(detect_public_ipv4 || true)"
  SERVER_ADDRESS="$detected_ip"
  if ! valid_ipv4_or_domain "$SERVER_ADDRESS"; then
    prompt_default SERVER_ADDRESS "未能自动识别公网 IPv4，请输入 VPS 公网 IPv4 或域名" ''
  fi
  SERVER_ADDRESS="$(strip_ipv6_brackets "$SERVER_ADDRESS")"
  valid_ipv4_or_domain "$SERVER_ADDRESS" \
    || die "客户端连接地址仅支持公网 IPv4 或域名，请不要附加端口。"

  select_inbound_port
  REALITY_TARGET="${XRAY_CHAIN_REALITY_TARGET:-$DEFAULT_REALITY_TARGET}"
  [[ "$REALITY_TARGET" == *:* ]] || REALITY_TARGET="${REALITY_TARGET}:443"
  if [[ "$REALITY_TARGET" == "$KNOWN_BAD_REALITY_TARGET" ]]; then
    if [[ -n "${XRAY_CHAIN_REALITY_TARGET:-}" ]]; then
      die "${KNOWN_BAD_REALITY_TARGET} 在当前稳定版 Xray 中存在已知 REALITY 握手问题，请换一个目标。"
    fi
    REALITY_TARGET="$DEFAULT_REALITY_TARGET"
    reality_migrated='yes'
  fi
  if [[ "$REALITY_TARGET" =~ ^([A-Za-z0-9.-]+):([0-9]+)$ ]]; then
    TARGET_HOST="${BASH_REMATCH[1]}"
    TARGET_PORT="${BASH_REMATCH[2]}"
  else
    die "REALITY 目标格式应为 域名:端口，例如 www.bing.com:443。"
  fi
  valid_domain_name "$TARGET_HOST" || die "REALITY 目标必须使用有效域名。"
  valid_port "$TARGET_PORT" || die "REALITY 目标端口不合法。"
  SERVER_NAME="${XRAY_CHAIN_REALITY_SNI:-$TARGET_HOST}"
  valid_domain_name "$SERVER_NAME" || die "REALITY SNI 必须是有效域名。"
  if [[ "$reality_migrated" == 'yes' ]]; then
    warn "旧版 REALITY 目标已迁移为 ${DEFAULT_REALITY_TARGET}。"
  fi
}

safe_socks_endpoint() {
  local host="$1" port="$2"
  if valid_ipv4_or_domain "$host" && [[ "$port" =~ ^[0-9]{1,5}$ ]] && valid_port "$port"; then
    printf '%s:%s' "$host" "$port"
  else
    printf '地址未识别'
  fi
}

socks_entry_error_endpoint() {
  local entry="$1" host remainder
  host="${entry%%:*}"
  remainder="${entry#*:}"
  safe_socks_endpoint "$host" "${remainder%%:*}"
}

socks_operation_label() {
  local mode="${1:-add}" identifier="${2:-}" total="${3:-}"
  if [[ "$mode" == 'batch' && "$identifier" =~ ^[0-9]+$ && "$total" =~ ^[0-9]+$ ]]; then
    printf '批量新增第 %s/%s 条' "$identifier" "$total"
  elif [[ "$mode" == 'edit' && "$identifier" =~ ^node-[0-9]+$ ]]; then
    printf '编辑节点 %s' "$identifier"
  elif [[ "$mode" == 'edit' ]]; then
    printf '编辑所选节点'
  else
    printf '新增线路'
  fi
}

collect_socks_settings() {
  local mode="$1" node_id="${2:-}" socks_entry direct_ip context
  context="$(socks_operation_label "$mode" "$node_id")"
  SOCKS_INPUT_CHANGED='no'
  show_socks_promo "$mode"

  if [[ "$mode" == 'edit' ]]; then
    NODE_TYPE="$(jq -er --arg id "$node_id" '.nodes[] | select(.id == $id) | (.type // "socks")' "$MODEL_FILE")"
    SOCKS_HOST="$(jq -r --arg id "$node_id" '.nodes[] | select(.id == $id) | (.socksHost // "")' "$MODEL_FILE")"
    SOCKS_PORT="$(jq -r --arg id "$node_id" '.nodes[] | select(.id == $id) | (.socksPort // 0)' "$MODEL_FILE")"
    SOCKS_USER="$(jq -r --arg id "$node_id" '.nodes[] | select(.id == $id) | (.socksUser // "")' "$MODEL_FILE")"
    SOCKS_PASS="$(jq -r --arg id "$node_id" '.[$id] // ""' "$SECRETS_FILE")"
    if [[ "$NODE_TYPE" == 'direct' ]]; then
      direct_ip="$(detect_display_direct_ip || true)"
      printf '当前出口：VPS 本机直连 · %s\n' "${direct_ip:-未验证}"
      IFS= read -r -s -p "SOCKS5: " socks_entry \
        || die "${context}：未读取到节点出口信息；本次修改已取消，节点原配置保留。"
    else
      printf '当前 SOCKS5：%s\n' "$(safe_socks_endpoint "$SOCKS_HOST" "$SOCKS_PORT")"
      IFS= read -r -s -p "SOCKS5: " socks_entry \
        || die "${context}：未读取到节点出口信息；本次修改已取消，节点原配置保留。"
    fi
  else
    NODE_TYPE='socks'
    SOCKS_HOST=''
    SOCKS_PORT=''
    SOCKS_USER=''
    SOCKS_PASS=''
    IFS= read -r -s -p "SOCKS5: " socks_entry \
      || die "${context}：未读取到 SOCKS5 信息；本次新增已取消。"
  fi
  printf '\n'

  if [[ -z "$socks_entry" ]]; then
    if [[ "$mode" != 'edit' ]]; then
      NODE_TYPE='direct'
      SOCKS_INPUT_CHANGED='yes'
    fi
    return 0
  fi
  parse_socks5_entry "$socks_entry" \
    || die "${context} · SOCKS5 $(socks_entry_error_endpoint "$socks_entry")：格式错误；应为 IP:端口:用户名:密码，无认证时可填 IP:端口。请核对后重新操作，本次未写入配置。"
  NODE_TYPE='socks'
  SOCKS_INPUT_CHANGED='yes'
}

collect_socks_batch_settings() {
  local parse_status normalized entry
  local -a input_entries=()
  ADD_DIRECT_NODE='no'
  show_socks_promo
  read_hidden_socks_batch_input "SOCKS5: "

  if [[ "$SOCKS_BATCH_RAW" =~ ^[[:space:]]*$ ]]; then
    ADD_DIRECT_NODE='yes'
    SOCKS_BATCH_ENTRIES=()
    SOCKS_BATCH_RAW=''
    return 0
  fi

  if parse_socks5_batch_input "$SOCKS_BATCH_RAW"; then
    :
  else
    parse_status=$?
    case "$parse_status" in
      1) die "SOCKS5 信息不能为空；本批未写入配置，请重新输入。" ;;
      2) die "单次最多添加 ${MAX_BATCH_SIZE} 条 SOCKS5；本批未写入配置，请分批操作。" ;;
      3)
        normalized="${SOCKS_BATCH_RAW//$'\r'/ }"
        normalized="${normalized//$'\n'/ }"
        normalized="${normalized//$'\t'/ }"
        read -r -a input_entries <<<"$normalized"
        entry="${input_entries[$((SOCKS_BATCH_ERROR_INDEX - 1))]}"
        die "批量新增第 ${SOCKS_BATCH_ERROR_INDEX}/${#input_entries[@]} 条 · SOCKS5 $(socks_entry_error_endpoint "$entry")：格式错误；应为 IP:端口:用户名:密码，无认证时可填 IP:端口。本批全部未写入配置，请修正后重新添加。"
        ;;
      *) die "无法解析 SOCKS5 批量输入；本批未写入配置，请核对格式后重试。" ;;
    esac
  fi
  SOCKS_BATCH_RAW=''
}

verify_direct_outbound() {
  local exit_ip
  exit_ip="$(detect_public_ipv4 || true)"
  if ! valid_ipv4 "$exit_ip"; then
    die "无法验证 VPS 本机公网 IPv4，未创建直连节点；请确认 VPS 可以直接访问互联网后重试。"
  fi
  SOCKS_EXIT_IP="$exit_ip"
}

curl_config_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

verify_socks_proxy() {
  local work_dir="$1" proxy_host proxy_user proxy_pass config_path diagnostic_path exit_ip
  local mode="${2:-add}" identifier="${3:-}" total="${4:-}" context confirmation
  proxy_host="$SOCKS_HOST"
  [[ "$proxy_host" == *:* ]] && proxy_host="[${proxy_host}]"
  proxy_user="$(curl_config_escape "$SOCKS_USER")"
  proxy_pass="$(curl_config_escape "$SOCKS_PASS")"
  config_path="${work_dir}/curl-socks.conf"
  diagnostic_path="${work_dir}/curl-socks-errors.txt"

  {
    printf 'proxy = "socks5h://%s:%s"\n' "$(curl_config_escape "$proxy_host")" "$SOCKS_PORT"
    if [[ -n "$SOCKS_USER" ]]; then
      printf 'proxy-user = "%s:%s"\n' "$proxy_user" "$proxy_pass"
    fi
    printf 'connect-timeout = 8\nmax-time = 15\nsilent\nshow-error\nfail\n'
  } >"$config_path"
  chmod 0600 "$config_path"

  SOCKS_EXIT_IP=''
  if exit_ip="$(probe_ipv4_with_curl_config "$config_path" "$diagnostic_path")" \
    && valid_ipv4 "$exit_ip"; then
    SOCKS_EXIT_IP="$exit_ip"
    rm -f -- "$diagnostic_path"
  else
    context="$(socks_operation_label "$mode" "$identifier" "$total")"
    warn "${context} · SOCKS5 $(safe_socks_endpoint "$SOCKS_HOST" "$SOCKS_PORT")：出口验证失败。"
    if [[ -s "$diagnostic_path" ]]; then cat -- "$diagnostic_path" >&2; fi
    rm -f -- "$diagnostic_path"
    case "$mode" in
      batch)
        warn "此时本批尚未部署；输入 y 仅允许这条未验证线路加入待部署配置，随后继续处理其余条目。回车或 n 取消本批全部新增，已有线路配置保留。"
        confirmation="${context}：仍要将这条未验证线路加入本批吗？"
        ;;
      edit)
        warn "输入 y 允许所选节点使用这个未验证出口；回车或 n 取消本次修改，节点原配置保留。"
        confirmation="${context}：仍要使用这个未验证出口吗？"
        ;;
      *)
        warn "输入 y 允许这条未验证线路加入待部署配置；回车或 n 取消本次新增，已有线路配置保留。"
        confirmation='仍要添加这条未验证线路吗？'
        ;;
    esac
    confirm_continue "$confirmation"
  fi
}

verify_reality_target() {
  if ! timeout 15 openssl s_client -connect "$REALITY_TARGET" -servername "$SERVER_NAME" -tls1_3 -brief \
    </dev/null >/dev/null 2>&1; then
    warn "REALITY 目标检测未通过：${REALITY_TARGET}（SNI：${SERVER_NAME}）；TCP 连接或 TLS 1.3 握手失败/超时，请检查目标 DNS、端口和 TLS 支持后重试或更换目标。"
    confirm_continue "仍要使用这个 REALITY 目标吗？"
  fi
}

generate_reality_identity() {
  local candidate_xray="$1" key_output
  if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]]; then
    return
  fi
  key_output="$($candidate_xray x25519 2>&1)"
  PRIVATE_KEY="$(awk -F': *' 'tolower($1) ~ /^private/ {print $2; exit}' <<<"$key_output" | tr -d '[:space:]')"
  PUBLIC_KEY="$(awk -F': *' 'tolower($1) ~ /^(password|public)/ {print $2; exit}' <<<"$key_output" | tr -d '[:space:]')"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || die "无法解析 xray x25519 输出。"
}

generate_node_identity() {
  local candidate_xray="$1"
  UUID="$($candidate_xray uuid | tr -d '[:space:]')"
  [[ "$UUID" =~ ^[0-9A-Fa-f-]{36}$ ]] || die "Xray 未能生成有效 UUID。"
  SHORT_ID="$(openssl rand -hex 8)"
  SPIDER_X="/$(openssl rand -hex 8)"
}

generate_unique_node_identity() {
  local candidate_xray="$1" exclude_id="${2:-}" attempt
  for attempt in {1..10}; do
    generate_node_identity "$candidate_xray"
    if ! jq -e \
      --arg exclude "$exclude_id" \
      --arg uuid "$UUID" \
      --arg short_id "$SHORT_ID" \
      --arg spider_x "$SPIDER_X" '
        .nodes[]
        | select(.id != $exclude)
        | select(.uuid == $uuid or .shortId == $short_id or .spiderX == $spider_x)
      ' "$MODEL_FILE" >/dev/null; then
      return 0
    fi
  done
  die "连续生成到重复的节点凭据，请检查系统随机数后重试。"
}

validate_model() {
  local file="$1" allow_empty="${2:-no}" allow_empty_json='false'
  [[ "$allow_empty" == 'yes' ]] && allow_empty_json='true'
  jq -e --argjson allow_empty "$allow_empty_json" '
    .schema == 2
    and (.installedAt | type == "string" and length > 0)
    and (.serverAddress | type == "string" and length > 0)
    and (.inboundPort | type == "number" and floor == . and . >= 1 and . <= 65535)
    and (.realityTarget | type == "string" and length > 0)
    and (.serverName | type == "string" and length > 0)
    and (.realityPublicKey | type == "string" and length > 0)
    and (.nextNodeNumber | type == "number" and floor == . and . >= 1)
    and (.nodes | type == "array")
    and ($allow_empty or (.nodes | length > 0))
    and (all(.nodes[];
      (.id | type == "string" and test("^node-[1-9][0-9]*$"))
      and (.number | type == "number" and floor == . and . >= 1)
      and (.id == ("node-" + (.number | tostring)))
      and (.name | type == "string" and length > 0 and length <= 128)
      and (.email == (.id + "@puppyip.local"))
      and (.uuid | type == "string" and test("^[0-9A-Fa-f-]{36}$"))
      and (.shortId | type == "string" and test("^[0-9A-Fa-f]{2,16}$") and (length % 2 == 0))
      and (.spiderX | type == "string" and startswith("/") and length <= 256)
      and (.udpMode == "block" or .udpMode == "proxy")
      and (.enabled | type == "boolean")
      and ((has("inboundPort") | not)
        or (.inboundPort | type == "number" and floor == . and . >= 1 and . <= 65535))
      and ((.type // "socks") == "socks" or (.type // "socks") == "direct")
      and (
        if (.type // "socks") == "socks" then
          (.socksHost | type == "string" and length > 0)
          and (.socksPort | type == "number" and . >= 1 and . <= 65535)
          and (.socksUser | type == "string")
          and (.exitIp | type == "string")
        else
          ((.socksHost // "") == "")
          and ((.socksPort // 0) == 0)
          and ((.socksUser // "") == "")
          and (.exitIp | type == "string" and test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))
        end
      )
    ))
    and (([.nodes[].id] | unique | length) == (.nodes | length))
    and (([.nodes[].number] | unique | length) == (.nodes | length))
    and (([.nodes[].uuid] | unique | length) == (.nodes | length))
    and (([.nodes[].email] | unique | length) == (.nodes | length))
    and (([.nodes[].shortId] | unique | length) == (.nodes | length))
    and (([.nodes[].spiderX] | unique | length) == (.nodes | length))
    and ((.nodes | length) == 0 or .nextNodeNumber > ([.nodes[].number] | max))
  ' "$file" >/dev/null || die "状态数据不完整或格式错误，未修改现有服务。"
}

validate_model_secrets() {
  jq -e --slurpfile state "$MODEL_FILE" '
    . as $secrets
    | all($state[0].nodes[];
        (.type // "socks") == "direct"
        or .socksUser == ""
        or (($secrets[.id] // "") | length > 0)
      )
  ' "$SECRETS_FILE" >/dev/null \
    || die "现有配置缺少某个节点的 SOCKS5 密码，无法安全修改。"
}

load_model() {
  local work_dir="$1" candidate_xray="$2" schema private_key legacy_pass
  MODEL_FILE="${work_dir}/model.json"
  SECRETS_FILE="${work_dir}/secrets.json"
  [[ -r "$STATE_FILE" && -r "$CONFIG_FILE" ]] || die "未找到完整的 xray-chain 安装状态。"
  schema="$(jq -r '.schema // 1' "$STATE_FILE" 2>/dev/null)" || die "状态文件不是有效 JSON。"

  private_key="$(config_reality_private_key "$CONFIG_FILE" 2>/dev/null)" \
    || die "现有配置缺少一致的 REALITY 私钥，未修改现有服务。"
  if [[ "$schema" == '2' ]]; then
    jq '.nodes |= map(. + {
      type: (.type // "socks"),
      enabled: (if has("enabled") then .enabled else true end)
    })' "$STATE_FILE" >"$MODEL_FILE"
    jq -n --slurpfile state "$MODEL_FILE" --slurpfile config "$CONFIG_FILE" '
      reduce ($state[0].nodes[] | select((.type // "socks") == "socks")) as $node ({};
        . + {($node.id):
          ([ $config[0].outbounds[]?
             | select(.tag == ("socks-out-" + $node.id))
             | (.settings.pass // "") ][0] // "")
        }
      )
    ' >"$SECRETS_FILE"
  elif [[ "$schema" == '1' ]]; then
    legacy_pass="$(jq -er '.outbounds[] | select(.tag == "socks-out") | .settings.pass // ""' "$CONFIG_FILE" 2>/dev/null || true)"
    jq -n \
      --slurpfile old "$STATE_FILE" '
      ($old[0]) as $o
      | {
          schema: 2,
          installedAt: ($o.installedAt // (now | todateiso8601)),
          updatedAt: ($o.updatedAt // (now | todateiso8601)),
          installerVersion: ($o.installerVersion // "legacy"),
          xrayVersion: ($o.xrayVersion // "unknown"),
          serverAddress: $o.serverAddress,
          inboundPort: $o.inboundPort,
          realityTarget: $o.realityTarget,
          serverName: $o.serverName,
          realityPublicKey: $o.publicKey,
          nextNodeNumber: 2,
          nodes: [
            {
              id: "node-1",
              number: 1,
              name: ($o.nodeName // "PuppyIP-1"),
              email: "node-1@puppyip.local",
              uuid: $o.uuid,
              shortId: $o.shortId,
              spiderX: "/",
              udpMode: ($o.udpMode // "block"),
              enabled: true,
              type: "socks",
              socksHost: $o.socksHost,
              socksPort: $o.socksPort,
              socksUser: ($o.socksUser // ""),
              exitIp: ""
            }
          ]
        }
    ' >"$MODEL_FILE"
    jq -n --arg pass "$legacy_pass" '{"node-1": $pass}' >"$SECRETS_FILE"
    warn "检测到旧版单节点配置；本次修改会自动迁移为多节点格式。"
  else
    die "不支持的状态版本：schema ${schema}"
  fi

  chmod 0600 "$MODEL_FILE" "$SECRETS_FILE"
  PRIVATE_KEY="$private_key"
  PUBLIC_KEY="$(jq -r '.realityPublicKey // ""' "$MODEL_FILE")"
  generate_reality_identity "$candidate_xray"
  jq --arg public_key "$PUBLIC_KEY" '.realityPublicKey = $public_key' "$MODEL_FILE" >"${MODEL_FILE}.new"
  mv -f -- "${MODEL_FILE}.new" "$MODEL_FILE"
  validate_model "$MODEL_FILE"
  validate_model_secrets
}

initialize_model() {
  local work_dir="$1" version="$2" candidate_xray="$3" now
  MODEL_FILE="${work_dir}/model.json"
  SECRETS_FILE="${work_dir}/secrets.json"
  collect_global_settings
  verify_reality_target
  PRIVATE_KEY=''
  PUBLIC_KEY=''
  generate_reality_identity "$candidate_xray"
  now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  jq -n \
    --arg installed_at "$now" \
    --arg installer_version "$SCRIPT_VERSION" \
    --arg xray_version "$version" \
    --arg server_address "$SERVER_ADDRESS" \
    --argjson inbound_port "$INBOUND_PORT" \
    --arg reality_target "$REALITY_TARGET" \
    --arg server_name "$SERVER_NAME" \
    --arg public_key "$PUBLIC_KEY" '
    {
      schema: 2,
      installedAt: $installed_at,
      updatedAt: $installed_at,
      installerVersion: $installer_version,
      xrayVersion: $xray_version,
      serverAddress: $server_address,
      inboundPort: $inbound_port,
      realityTarget: $reality_target,
      serverName: $server_name,
      realityPublicKey: $public_key,
      nextNodeNumber: 1,
      nodes: []
    }
  ' >"$MODEL_FILE"
  printf '{}\n' >"$SECRETS_FILE"
  chmod 0600 "$MODEL_FILE" "$SECRETS_FILE"
  validate_model "$MODEL_FILE" yes
}

make_unique_node_name() {
  local source="${SOCKS_EXIT_IP:-$SOCKS_HOST}" exclude_id="${1:-}" base name suffix=1
  source="${source:0:96}"
  base="PuppyIP-${source}"
  name="$base"
  while jq -e --arg name "$name" --arg exclude "$exclude_id" \
    '.nodes[] | select(.id != $exclude and .name == $name)' "$MODEL_FILE" >/dev/null; do
    ((suffix += 1))
    name="${base}-${suffix}"
  done
  printf '%s' "$name"
}

append_current_node_to_model() {
  local candidate_xray="$1" number node_id email udp_mode model_tmp secrets_tmp node_port
  local XRAY_CHAIN_PORT=''
  local -a reserved_ports=()
  generate_unique_node_identity "$candidate_xray"
  number="$(jq -er '.nextNodeNumber' "$MODEL_FILE")"
  node_id="node-${number}"
  email="${node_id}@puppyip.local"
  if [[ "$(jq '.nodes | length' "$MODEL_FILE")" == '0' ]]; then
    node_port="$(jq -er '.inboundPort' "$MODEL_FILE")"
  else
    mapfile -t reserved_ports < <(jq -r '. as $s
      | [.inboundPort, (.nodes[] | (.inboundPort // $s.inboundPort))] | unique[]' "$MODEL_FILE")
    select_inbound_port "${reserved_ports[@]}"
    node_port="$INBOUND_PORT"
  fi
  NODE_NAME="$(make_unique_node_name)"
  if [[ "$NODE_TYPE" == 'direct' ]]; then
    udp_mode='proxy'
    SOCKS_HOST=''
    SOCKS_PORT='0'
    SOCKS_USER=''
    SOCKS_PASS=''
  else
    [[ "$NODE_TYPE" == 'socks' ]] || die "未知节点出口类型：${NODE_TYPE}"
    udp_mode="${XRAY_CHAIN_UDP_MODE:-proxy}"
    [[ "$udp_mode" == 'block' || "$udp_mode" == 'proxy' ]] \
      || die "XRAY_CHAIN_UDP_MODE 只能是 block 或 proxy。"
  fi
  model_tmp="${MODEL_FILE}.new"
  secrets_tmp="${SECRETS_FILE}.new"
  jq \
    --arg id "$node_id" \
    --argjson number "$number" \
    --arg name "$NODE_NAME" \
    --arg email "$email" \
    --argjson inbound_port "$node_port" \
    --arg uuid "$UUID" \
    --arg short_id "$SHORT_ID" \
    --arg spider_x "$SPIDER_X" \
    --arg udp_mode "$udp_mode" \
    --arg type "$NODE_TYPE" \
    --arg socks_host "$SOCKS_HOST" \
    --argjson socks_port "$SOCKS_PORT" \
    --arg socks_user "$SOCKS_USER" \
    --arg exit_ip "$SOCKS_EXIT_IP" '
      .nodes += [{
        id: $id,
        number: $number,
        name: $name,
        email: $email,
        inboundPort: $inbound_port,
        uuid: $uuid,
        shortId: $short_id,
        spiderX: $spider_x,
        udpMode: $udp_mode,
        enabled: true,
        type: $type,
        socksHost: $socks_host,
        socksPort: $socks_port,
        socksUser: $socks_user,
        exitIp: $exit_ip
      }]
      | .nextNodeNumber = ($number + 1)
    ' "$MODEL_FILE" >"$model_tmp"
  jq --arg id "$node_id" --arg type "$NODE_TYPE" --arg pass "$SOCKS_PASS" '
      if $type == "socks" then . + {($id): $pass} else del(.[$id]) end
    ' \
    "$SECRETS_FILE" >"$secrets_tmp"
  mv -f -- "$model_tmp" "$MODEL_FILE"
  mv -f -- "$secrets_tmp" "$SECRETS_FILE"
  chmod 0600 "$MODEL_FILE" "$SECRETS_FILE"
  SELECTED_NODE_ID="$node_id"
  validate_model "$MODEL_FILE"
  validate_model_secrets
}

append_node_to_model() {
  local candidate_xray="$1"
  collect_socks_settings add
  if [[ "$NODE_TYPE" == 'direct' ]]; then
    verify_direct_outbound
  else
    verify_socks_proxy "$(dirname "$MODEL_FILE")"
  fi
  append_current_node_to_model "$candidate_xray"
}

append_batch_nodes_to_model() {
  local candidate_xray="$1" entry index=0 total
  collect_socks_batch_settings
  NEW_NODE_IDS=()
  total="${#SOCKS_BATCH_ENTRIES[@]}"

  if [[ "$ADD_DIRECT_NODE" == 'yes' ]]; then
    NODE_TYPE='direct'
    SOCKS_HOST=''
    SOCKS_PORT='0'
    SOCKS_USER=''
    SOCKS_PASS=''
    show_progress_line 0 1 "正在检测 VPS 本机公网 IP"
    verify_direct_outbound
    append_current_node_to_model "$candidate_xray"
    NEW_NODE_IDS+=("$SELECTED_NODE_ID")
    ADD_DIRECT_NODE='no'
    clear_progress_line
    return 0
  fi

  for entry in "${SOCKS_BATCH_ENTRIES[@]}"; do
    ((index += 1))
    parse_socks5_entry "$entry" || die "批量新增第 ${index}/${total} 条 · SOCKS5 $(socks_entry_error_endpoint "$entry")：验证前解析失败；本批未写入配置，请核对格式后重新添加。"
    NODE_TYPE='socks'
    show_progress_line "$index" "$total" "正在验证 SOCKS5 · ${index}/${total}"
    verify_socks_proxy "$(dirname "$MODEL_FILE")" batch "$index" "$total"
    append_current_node_to_model "$candidate_xray"
    NEW_NODE_IDS+=("$SELECTED_NODE_ID")
  done

  SOCKS_BATCH_ENTRIES=()
  SOCKS_PASS=''
  NODE_TYPE='socks'
  clear_progress_line
}

update_node_socks_in_model() {
  local node_id="$1" old_exit old_name old_udp suggested update_name='yes'
  local udp_mode settings_changed='no' model_tmp secrets_tmp
  NODE_SETTINGS_CHANGED='no'
  old_exit="$(jq -er --arg id "$node_id" '.nodes[] | select(.id == $id) | .exitIp' "$MODEL_FILE")"
  old_name="$(jq -er --arg id "$node_id" '.nodes[] | select(.id == $id) | .name' "$MODEL_FILE")"
  old_udp="$(jq -er --arg id "$node_id" '.nodes[] | select(.id == $id) | .udpMode' "$MODEL_FILE")"
  SOCKS_EXIT_IP="$old_exit"
  collect_socks_settings edit "$node_id"
  if [[ "$SOCKS_INPUT_CHANGED" == 'yes' ]]; then
    settings_changed='yes'
    if [[ "$NODE_TYPE" == 'direct' ]]; then
      verify_direct_outbound
    else
      verify_socks_proxy "$(dirname "$MODEL_FILE")" edit "$node_id"
    fi
  fi

  # Changing an exit must never silently change an existing node's UDP
  # behavior. New nodes default to proxy; legacy block values remain intact.
  udp_mode="$old_udp"
  [[ "$settings_changed" == 'yes' ]] || return 0

  NODE_NAME="$old_name"
  if [[ "$SOCKS_INPUT_CHANGED" == 'yes' ]]; then
    suggested="$(make_unique_node_name "$node_id")"
    if [[ "$suggested" != "$old_name" ]]; then
      prompt_yes_no update_name "线路名称改为 ${suggested}？" 'yes'
      [[ "$update_name" == 'yes' ]] && NODE_NAME="$suggested"
    fi
  fi
  model_tmp="${MODEL_FILE}.new"
  secrets_tmp="${SECRETS_FILE}.new"
  jq \
    --arg id "$node_id" \
    --arg name "$NODE_NAME" \
    --arg type "$NODE_TYPE" \
    --arg socks_host "$SOCKS_HOST" \
    --argjson socks_port "$SOCKS_PORT" \
    --arg socks_user "$SOCKS_USER" \
    --arg udp_mode "$udp_mode" \
    --arg exit_ip "$SOCKS_EXIT_IP" '
      (.nodes[] | select(.id == $id)) |= (
        .name = $name
        | .type = $type
        | .socksHost = $socks_host
        | .socksPort = $socks_port
        | .socksUser = $socks_user
        | .udpMode = $udp_mode
        | .exitIp = $exit_ip
      )
    ' "$MODEL_FILE" >"$model_tmp"
  jq --arg id "$node_id" --arg type "$NODE_TYPE" --arg pass "$SOCKS_PASS" '
      if $type == "socks" then . + {($id): $pass} else del(.[$id]) end
    ' \
    "$SECRETS_FILE" >"$secrets_tmp"
  mv -f -- "$model_tmp" "$MODEL_FILE"
  mv -f -- "$secrets_tmp" "$SECRETS_FILE"
  chmod 0600 "$MODEL_FILE" "$SECRETS_FILE"
  validate_model "$MODEL_FILE"
  validate_model_secrets
  NODE_SETTINGS_CHANGED='yes'
  if [[ -n "$old_exit" && "$old_exit" != "$SOCKS_EXIT_IP" ]]; then
    info "该节点的实际出口已从 ${old_exit} 更新为 ${SOCKS_EXIT_IP:-未验证}。"
  fi
}

rotate_node_identity_in_model() {
  local node_id="$1" candidate_xray="$2" model_tmp
  generate_unique_node_identity "$candidate_xray" "$node_id"
  model_tmp="${MODEL_FILE}.new"
  jq \
    --arg id "$node_id" \
    --arg uuid "$UUID" \
    --arg short_id "$SHORT_ID" \
    --arg spider_x "$SPIDER_X" '
      (.nodes[] | select(.id == $id)) |= (
        .uuid = $uuid | .shortId = $short_id | .spiderX = $spider_x
      )
    ' "$MODEL_FILE" >"$model_tmp"
  mv -f -- "$model_tmp" "$MODEL_FILE"
  chmod 0600 "$MODEL_FILE"
  validate_model "$MODEL_FILE"
}

set_node_enabled_in_model() {
  local node_id="$1" enabled="$2" model_tmp
  [[ "$enabled" == 'true' || "$enabled" == 'false' ]] \
    || die "节点状态必须是 true 或 false。"
  model_tmp="${MODEL_FILE}.new"
  jq --arg id "$node_id" --argjson enabled "$enabled" '
      (.nodes[] | select(.id == $id) | .enabled) = $enabled
    ' "$MODEL_FILE" >"$model_tmp"
  mv -f -- "$model_tmp" "$MODEL_FILE"
  chmod 0600 "$MODEL_FILE"
  validate_model "$MODEL_FILE"
}

remove_node_from_model() {
  local node_id="$1" model_tmp secrets_tmp
  (( $(jq '.nodes | length' "$MODEL_FILE") > 1 )) \
    || die "不能删除最后一个节点；如不再使用，请选择“卸载全部”。"
  model_tmp="${MODEL_FILE}.new"
  secrets_tmp="${SECRETS_FILE}.new"
  jq --arg id "$node_id" '.nodes |= map(select(.id != $id))' "$MODEL_FILE" >"$model_tmp"
  jq --arg id "$node_id" 'del(.[$id])' "$SECRETS_FILE" >"$secrets_tmp"
  mv -f -- "$model_tmp" "$MODEL_FILE"
  mv -f -- "$secrets_tmp" "$SECRETS_FILE"
  chmod 0600 "$MODEL_FILE" "$SECRETS_FILE"
  validate_model "$MODEL_FILE"
  validate_model_secrets
}

render_config() {
  local output="$1" work_dir="$2" state_file="${3:-$MODEL_FILE}" secrets_file="${4:-$SECRETS_FILE}"
  local private_key_file
  private_key_file="${work_dir}/reality-private-key"
  printf '%s' "$PRIVATE_KEY" >"$private_key_file"
  chmod 0600 "$private_key_file"

  jq -n \
    --slurpfile state "$state_file" \
    --slurpfile secrets "$secrets_file" \
    --rawfile private_key "$private_key_file" \
    '
    ($state[0]) as $s
    | ($secrets[0]) as $passwords
    | ($s.nodes | group_by(.inboundPort // $s.inboundPort)) as $port_groups
    | def inbound_tag($port):
        if $port == $s.inboundPort then "vless-in" else "vless-in-" + ($port | tostring) end;
    {
      log: {loglevel: "warning"},
      inbounds: [
        $port_groups[] as $nodes
        | ($nodes[0].inboundPort // $s.inboundPort) as $port
        |
        {
          tag: inbound_tag($port),
          listen: "0.0.0.0",
          port: $port,
          protocol: "vless",
          settings: {
            clients: [
              $nodes[] | {
                id: .uuid,
                email: .email,
                flow: "xtls-rprx-vision"
              }
            ],
            decryption: "none"
          },
          sniffing: {
            enabled: true,
            destOverride: ["http", "tls", "quic"],
            routeOnly: true
          },
          streamSettings: {
            network: "raw",
            security: "reality",
            realitySettings: {
              show: false,
              target: $s.realityTarget,
              xver: 0,
              serverNames: [$s.serverName],
              privateKey: $private_key,
              shortIds: [$nodes[].shortId]
            }
          }
        }
      ],
      outbounds: (
        [{tag: "blocked", protocol: "blackhole", settings: {}}]
        + [
            $s.nodes[] as $node
            | if ($node.type // "socks") == "direct" then
                {
                  tag: ("direct-out-" + $node.id),
                  protocol: "freedom",
                  settings: {domainStrategy: "AsIs"}
                }
              else
                {
                  tag: ("socks-out-" + $node.id),
                  protocol: "socks",
                  settings: (
                    {address: $node.socksHost, port: $node.socksPort}
                    + if $node.socksUser == "" then {}
                      else {
                        user: $node.socksUser,
                        pass: ($passwords[$node.id] // "")
                      }
                      end
                  )
                }
              end
          ]
      ),
      routing: {
        domainStrategy: "AsIs",
        rules: (
          [
            {type: "field", ip: ["geoip:private"], outboundTag: "blocked"},
            {type: "field", protocol: ["bittorrent"], outboundTag: "blocked"}
          ]
          + [
              $s.nodes[]
              | select(.enabled == false)
              | {
                  type: "field",
                  user: [.email],
                  outboundTag: "blocked"
                }
            ]
          + [
              $s.nodes[]
              | select(.enabled != false and .udpMode == "block")
              | {
                  type: "field",
                  user: [.email],
                  network: "udp",
                  outboundTag: "blocked"
                }
            ]
          + [
              $s.nodes[]
              | select(.enabled != false)
              | {
                  type: "field",
                  user: [.email],
                  outboundTag: (
                    if (.type // "socks") == "direct" then
                      "direct-out-" + .id
                    else
                      "socks-out-" + .id
                    end
                  )
                }
            ]
          + [{
              type: "field",
              inboundTag: [$port_groups[] | inbound_tag(.[0].inboundPort // $s.inboundPort)],
              outboundTag: "blocked"
            }]
        )
      }
    }
    ' >"$output"
  chmod 0600 "$output"
}

render_state() {
  local output="$1" version="$2"
  validate_model "$MODEL_FILE"
  jq \
    --arg updated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg installer_version "$SCRIPT_VERSION" \
    --arg xray_version "$version" '
      .schema = 2
      | .updatedAt = $updated_at
      | .installerVersion = $installer_version
      | .xrayVersion = $xray_version
    ' "$MODEL_FILE" >"$output"
  chmod 0600 "$output"
}

canonical_state_identity() {
  local file="$1"
  jq -cS '
    def normalized_enabled:
      if has("enabled") then .enabled else true end;
    . as $state
    | if (.schema // 1) == 2 then
      {
        serverAddress,
        inboundPort,
        realityTarget,
        serverName,
        realityPublicKey,
        nextNodeNumber,
        nodes: ([
          .nodes[]
          | {
              id,
              number,
              name,
              email,
              inboundPort: (.inboundPort // $state.inboundPort),
              uuid,
              shortId,
              spiderX,
              udpMode,
              enabled: normalized_enabled,
              type: (.type // "socks"),
              socksHost,
              socksPort,
              socksUser,
              exitIp
            }
        ] | sort_by(.number))
      }
    else
      . as $old
      | {
          serverAddress: $old.serverAddress,
          inboundPort: $old.inboundPort,
          realityTarget: $old.realityTarget,
          serverName: $old.serverName,
          realityPublicKey: $old.publicKey,
          nextNodeNumber: 2,
          nodes: [{
            id: "node-1",
            number: 1,
            name: ($old.nodeName // "PuppyIP-1"),
            email: "node-1@puppyip.local",
            inboundPort: $old.inboundPort,
            uuid: $old.uuid,
            shortId: $old.shortId,
            spiderX: "/",
            udpMode: ($old.udpMode // "block"),
            enabled: true,
            type: "socks",
            socksHost: $old.socksHost,
            socksPort: $old.socksPort,
            socksUser: ($old.socksUser // ""),
            exitIp: ""
          }]
        }
    end
  ' "$file"
}

canonical_config_secrets() {
  local state_file="$1" config_file="$2"
  jq -cS -n --slurpfile state "$state_file" --slurpfile config "$config_file" '
    ($state[0]) as $s
    | ($config[0]) as $c
    | def password_for($tag):
        ([ $c.outbounds[]?
           | select(.tag == $tag)
           | (.settings.pass // "") ][0] // "__missing_outbound__");
      if ($s.schema // 1) == 2 then
        reduce ($s.nodes[] | select((.type // "socks") == "socks")) as $node ({};
          . + {($node.id): password_for("socks-out-" + $node.id)}
        )
      else
        {"node-1": password_for("socks-out")}
      end
  '
}

canonical_runtime_identity() {
  local state_file="$1" config_file="$2"
  jq -cS -n --slurpfile state "$state_file" --slurpfile config "$config_file" '
    ($state[0]) as $s
    | ($config[0]) as $c
    | def normalized_nodes($source):
        if ($source.schema // 1) == 2 then
          $source.nodes
        else
          [{
            id: "node-1",
            number: 1,
            type: "socks"
          }]
        end;
      def outbound_tag($schema; $node):
        if $schema == 2 then
          if ($node.type // "socks") == "direct" then
            "direct-out-" + $node.id
          else
            "socks-out-" + $node.id
          end
        else
          "socks-out"
        end;
      (($s.schema // 1) == 2) as $schema2
    | (if $schema2 then 2 else 1 end) as $schema
    | (normalized_nodes($s)) as $nodes
    | ([ $nodes[] | outbound_tag($schema; .) ]) as $expected_outbound_tags
    | {
        inbounds: ([
          $c.inbounds[]?
          | select((.tag // "") | test("^vless-in(-[0-9]+)?$"))
          | . as $inbound
          | {
          tag: $inbound.tag,
          listen: ($inbound.listen // ""),
          port: ($inbound.port // null),
          protocol: ($inbound.protocol // ""),
          clients: ([
            $inbound.settings.clients[]?
            | {id: (.id // ""), flow: (.flow // "")}
          ] | sort_by(.id, .flow)),
          network: ($inbound.streamSettings.network // ""),
          security: ($inbound.streamSettings.security // ""),
          target: ($inbound.streamSettings.realitySettings.target // ""),
          serverNames: (($inbound.streamSettings.realitySettings.serverNames // []) | sort),
          privateKey: ($inbound.streamSettings.realitySettings.privateKey // ""),
          shortIds: (($inbound.streamSettings.realitySettings.shortIds // []) | sort)
        }] | sort_by(.port, .tag)),
        nodeOutbounds: ([
          $nodes[] as $node
          | (outbound_tag($schema; $node)) as $tag
          | ([ $c.outbounds[]? | select(.tag == $tag) ][0] // {}) as $outbound
          | {
              id: $node.id,
              matchCount: ([ $c.outbounds[]? | select(.tag == $tag) ] | length),
              protocol: ($outbound.protocol // ""),
              address: ($outbound.settings.address // ""),
              port: ($outbound.settings.port // 0),
              user: ($outbound.settings.user // ""),
              domainStrategy: ($outbound.settings.domainStrategy // "")
            }
        ] | sort_by(.id)),
        extraInbounds: ([
          $c.inbounds[]? | select(((.tag // "") | test("^vless-in(-[0-9]+)?$")) | not)
        ] | sort_by(.tag // "")),
        extraOutbounds: ([
          $c.outbounds[]?
          | select((.tag // "") != "blocked")
          | select(([ $expected_outbound_tags[] == (.tag // "") ] | any) | not)
        ] | sort_by(.tag // ""))
      }
  '
}

config_reality_private_key() {
  local config_file="$1"
  jq -er '
    [.inbounds[]
     | select((.tag // "") | test("^vless-in(-[0-9]+)?$"))
     | .streamSettings.realitySettings.privateKey] | unique
    | select(length == 1 and (.[0] | type == "string" and length > 0)) | .[0]
  ' "$config_file"
}

assert_upgrade_invariants() {
  local old_state="$1" old_config="$2" candidate_state="$3" candidate_config="$4"
  local old_identity new_identity old_runtime new_runtime
  local old_secrets new_secrets old_private_key new_private_key

  old_identity="$(canonical_state_identity "$old_state")" \
    || die "无法读取升级前的节点身份；为防止覆盖，已停止更新。"
  new_identity="$(canonical_state_identity "$candidate_state")" \
    || die "无法读取候选节点身份；为防止覆盖，已停止更新。"
  [[ "$old_identity" == "$new_identity" ]] \
    || die "候选配置改变了端口、节点身份、出口或 REALITY 参数；已停止更新，现有服务未修改。"

  old_runtime="$(canonical_runtime_identity "$old_state" "$old_config")" \
    || die "无法核对升级前的 Xray 运行配置；已停止更新。"
  new_runtime="$(canonical_runtime_identity "$candidate_state" "$candidate_config")" \
    || die "无法核对候选 Xray 运行配置；已停止更新。"
  [[ "$old_runtime" == "$new_runtime" ]] \
    || die "现有状态与 Xray 运行配置不一致，或候选配置会改变节点行为；为防止覆盖，已停止更新。"

  old_secrets="$(canonical_config_secrets "$old_state" "$old_config")" \
    || die "无法核对升级前的 SOCKS5 凭据；已停止更新。"
  new_secrets="$(canonical_config_secrets "$candidate_state" "$candidate_config")" \
    || die "无法核对候选 SOCKS5 凭据；已停止更新。"
  [[ "$old_secrets" == "$new_secrets" ]] \
    || die "候选配置未完整保留 SOCKS5 凭据；已停止更新，现有服务未修改。"

  old_private_key="$(config_reality_private_key "$old_config")" \
    || die "无法读取升级前的 REALITY 私钥；已停止更新。"
  new_private_key="$(config_reality_private_key "$candidate_config")" \
    || die "无法读取候选 REALITY 私钥；已停止更新。"
  [[ "$old_private_key" == "$new_private_key" ]] \
    || die "候选配置改变了 REALITY 私钥；已停止更新，现有服务未修改。"
}

render_service() {
  local output="$1"
  cat >"$output" <<'EOF'
[Unit]
Description=Standalone Xray chained proxy
Documentation=https://xtls.github.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xray-chain
Group=xray-chain
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray-chain
ExecStart=/usr/local/lib/xray-chain/xray run -c /etc/xray-chain/config.json
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RuntimeDirectory=xray-chain
WorkingDirectory=/run/xray-chain
UMask=0077
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$output"
}

prepare_existing_upgrade_candidate() {
  local work_dir="$1" version="$2"
  load_model "$work_dir" "${work_dir}/xray/xray"
  render_state "${work_dir}/candidate-state.json" "$version"
  assert_model_port_available "${work_dir}/candidate-state.json"
  render_config "${work_dir}/candidate-config.json" "$work_dir" \
    "${work_dir}/candidate-state.json" "$SECRETS_FILE"
  render_service "${work_dir}/xray-chain.service"
  validate_config "${work_dir}/xray/xray" "${work_dir}/xray" \
    "${work_dir}/candidate-config.json"
  assert_upgrade_invariants "$STATE_FILE" "$CONFIG_FILE" \
    "${work_dir}/candidate-state.json" "${work_dir}/candidate-config.json"
  if ! prepare_manager_copy "${work_dir}/manager"; then
    die "无法取得并校验当前安装脚本的固定提交副本；现有节点和服务未修改。"
  fi
}

resolve_installer_commit() {
  local commit="${XRAY_CHAIN_INSTALLER_COMMIT:-}" response
  if [[ -z "$commit" ]]; then
    response="$(curl --fail --silent --show-error --location --retry 3 \
      --proto '=https' --tlsv1.2 --max-filesize "$MAX_INSTALLER_BYTES" \
      --connect-timeout 10 --max-time 30 \
      -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: puppyip-xray-chain-installer' \
      "${INSTALLER_API_URL}/git/ref/heads/${INSTALLER_BRANCH}")" || return 1
    commit="$(jq -er '.object.sha' <<<"$response")" || return 1
  fi
  [[ "$commit" =~ ^[0-9A-Fa-f]{40}$ ]] || return 1
  printf '%s' "${commit,,}"
}

prepare_manager_copy() {
  local output="$1" source_path source_real destination_real commit='local' source_url size
  source_path="$SCRIPT_SOURCE"
  source_real="$(readlink -f "$source_path" 2>/dev/null || printf '%s' "$source_path")"
  destination_real="$(readlink -f "$MANAGER_BIN" 2>/dev/null || printf '%s' "$MANAGER_BIN")"

  if [[ -n "$source_path" && -r "$source_path" && -f "$source_path" ]]; then
    if [[ "$source_real" == "$destination_real" ]]; then
      cp -- "$MANAGER_BIN" "$output" || return 1
    else
      cp -- "$source_path" "$output" || return 1
    fi
  else
    # bash <(curl ...) executes from a pipe. Once Bash consumes that pipe it
    # cannot be copied again. Resolve main once, then download by immutable
    # commit instead of fetching a moving branch a second time.
    commit="$(resolve_installer_commit)" || return 1
    source_url="${INSTALLER_RAW_BASE}/${commit}/install.sh"
    if ! curl --fail --silent --show-error --location --retry 3 \
      --proto '=https' --tlsv1.2 --max-filesize "$MAX_INSTALLER_BYTES" \
      --connect-timeout 10 --max-time 30 --output "$output" "$source_url"; then
      rm -f -- "$output"
      return 1
    fi
  fi

  size="$(wc -c <"$output" | tr -d '[:space:]')"
  if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size < 1 || size > MAX_INSTALLER_BYTES )) \
    || [[ -L "$output" ]] \
    || ! grep -q '^# XRAY_CHAIN_SCRIPT$' "$output" \
    || ! grep -Fqx "SCRIPT_VERSION=\"${SCRIPT_VERSION}\"" "$output" \
    || ! bash -n "$output"; then
    rm -f -- "$output"
    return 1
  fi
  chmod 0755 "$output"
}

validate_config() {
  local candidate_xray="$1" candidate_assets="$2" candidate_config="$3" log_file
  log_file="${candidate_config}.validation.log"
  if ! XRAY_LOCATION_ASSET="$candidate_assets" "$candidate_xray" run -test -c "$candidate_config" \
    >"$log_file" 2>&1; then
    show_error_log "$log_file"
    die "Xray 候选配置校验失败，未部署本次节点修改；请按上方诊断检查端口、连接参数及 Geo 数据后重试。"
  fi
}

ensure_runtime_layout() {
  local group_created='no' user_created='no'
  if ! getent group "$RUNTIME_GROUP" >/dev/null 2>&1; then
    groupadd --system "$RUNTIME_GROUP" || die "创建 Xray 运行组 ${RUNTIME_GROUP} 失败；请检查系统账户工具和同名组，未开始文件部署。"
    group_created='yes'
    RUNTIME_GROUP_CREATED_THIS_RUN='yes'
  fi
  if ! id -u "$RUNTIME_USER" >/dev/null 2>&1; then
    if ! useradd --system --gid "$RUNTIME_GROUP" --home-dir /nonexistent --shell /usr/sbin/nologin "$RUNTIME_USER"; then
      if [[ "$group_created" == 'yes' ]]; then
        groupdel "$RUNTIME_GROUP" >/dev/null 2>&1 || true
        RUNTIME_GROUP_CREATED_THIS_RUN='no'
      fi
      die "创建 Xray 运行用户 ${RUNTIME_USER} 失败；请检查系统账户工具、同名用户与用户组，未开始文件部署。"
    fi
    user_created='yes'
    RUNTIME_USER_CREATED_THIS_RUN='yes'
  fi
  install -d -o root -g root -m 0755 "$BIN_DIR" "$ASSET_DIR" \
    || die "创建 Xray 程序或 Geo 数据目录失败：${BIN_DIR}、${ASSET_DIR}；请检查权限及磁盘空间。"
  install -d -o root -g "$RUNTIME_GROUP" -m 0750 "$CONFIG_DIR" \
    || die "创建节点配置目录失败：${CONFIG_DIR}；请检查运行组、权限及磁盘空间。"
  install -d -o root -g root -m 0700 "$DATA_DIR" "$BACKUP_DIR" \
    || die "创建状态或备份目录失败：${DATA_DIR}、${BACKUP_DIR}；请检查权限及磁盘空间。"
  if [[ "$group_created" == 'yes' ]]; then
    : >"$RUNTIME_GROUP_MARKER"
  fi
  if [[ "$user_created" == 'yes' ]]; then
    : >"$RUNTIME_USER_MARKER"
  fi
}

cleanup_runtime_layout_created_this_run() {
  local backup_path="${1:-}"
  if [[ "$RUNTIME_USER_CREATED_THIS_RUN" == 'yes' ]]; then
    userdel "$RUNTIME_USER" >/dev/null 2>&1 || true
    rm -f -- "$RUNTIME_USER_MARKER"
    RUNTIME_USER_CREATED_THIS_RUN='no'
  fi
  if [[ "$RUNTIME_GROUP_CREATED_THIS_RUN" == 'yes' ]]; then
    groupdel "$RUNTIME_GROUP" >/dev/null 2>&1 || true
    rm -f -- "$RUNTIME_GROUP_MARKER"
    RUNTIME_GROUP_CREATED_THIS_RUN='no'
  fi
  if [[ -n "$backup_path" && "$backup_path" == "${BACKUP_DIR}/"* \
    && ! -e "${backup_path}/xray" && ! -e "${backup_path}/config.json" \
    && ! -e "${backup_path}/state.json" ]]; then
    rm -f -- "${backup_path}/was-enabled" "${backup_path}/was-active"
    rmdir -- "$backup_path" 2>/dev/null || true
  fi
  rmdir -- "$CONFIG_DIR" "$BIN_DIR" "$ASSET_DIR" "$BACKUP_DIR" "$DATA_DIR" 2>/dev/null || true
}

commit_runtime_layout() {
  RUNTIME_USER_CREATED_THIS_RUN='no'
  RUNTIME_GROUP_CREATED_THIS_RUN='no'
}

atomic_install() {
  local source="$1" destination="$2" mode="$3" owner="$4" group="$5" temp_file
  temp_file="${destination}.new.$$"
  if ! install -o "$owner" -g "$group" -m "$mode" "$source" "$temp_file"; then
    warn "写入文件失败：${destination}（准备临时副本）；请检查源文件、目标目录权限、磁盘空间及 inode。"
    rm -f -- "$temp_file"
    return 1
  fi
  if ! mv -f -- "$temp_file" "$destination"; then
    warn "替换文件失败：${destination}；请检查目标目录权限、只读挂载或文件属性。"
    rm -f -- "$temp_file"
    return 1
  fi
}

backup_copy_if_present() {
  local source="$1" destination="$2"
  if [[ -f "$source" ]]; then
    if ! cp -a -- "$source" "$destination"; then
      warn "备份文件失败：${source}；请检查文件可读性以及备份目录权限和磁盘空间。"
      return 1
    fi
  fi
}

create_backup() {
  local backup_path timestamp
  timestamp="$(date -u +'%Y%m%dT%H%M%SZ')-$$"
  backup_path="${BACKUP_DIR}/${timestamp}"
  install -d -o root -g root -m 0700 "$backup_path" || return 1

  if ! backup_copy_if_present "$XRAY_BIN" "${backup_path}/xray" \
    || ! backup_copy_if_present "${ASSET_DIR}/geoip.dat" "${backup_path}/geoip.dat" \
    || ! backup_copy_if_present "${ASSET_DIR}/geosite.dat" "${backup_path}/geosite.dat" \
    || ! backup_copy_if_present "$CONFIG_FILE" "${backup_path}/config.json" \
    || ! backup_copy_if_present "$STATE_FILE" "${backup_path}/state.json" \
    || ! backup_copy_if_present "$SERVICE_FILE" "${backup_path}/service" \
    || ! backup_copy_if_present "$MANAGER_BIN" "${backup_path}/manager" \
    || ! backup_copy_if_present "$LEGACY_MANAGER_BIN" "${backup_path}/legacy-manager"; then
    if [[ "$backup_path" == "${BACKUP_DIR}/"* ]]; then
      rm -rf -- "$backup_path"
    fi
    return 1
  fi

  if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    printf 'yes' >"${backup_path}/was-enabled"
  else
    printf 'no' >"${backup_path}/was-enabled"
  fi
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    printf 'yes' >"${backup_path}/was-active"
  else
    printf 'no' >"${backup_path}/was-active"
  fi
  printf '%s' "$backup_path"
}

restore_one() {
  local backup_file="$1" destination="$2"
  if [[ -f "$backup_file" ]]; then
    cp -a -- "$backup_file" "$destination" || return 1
  else
    rm -f -- "$destination" || return 1
  fi
}

rollback_backup() {
  local backup_path="$1" restore_failed='no' service_failed='no' item destination
  local -a restore_sources=(xray geoip.dat geosite.dat config.json state.json service manager legacy-manager)
  local -a restore_destinations=("$XRAY_BIN" "${ASSET_DIR}/geoip.dat" "${ASSET_DIR}/geosite.dat"
    "$CONFIG_FILE" "$STATE_FILE" "$SERVICE_FILE" "$MANAGER_BIN" "$LEGACY_MANAGER_BIN")
  warn "部署失败，正在恢复修改前的文件..."
  if ! systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1; then
    service_failed='yes'
    warn "回滚时停止服务失败：${SERVICE_NAME}；仍会尝试恢复全部文件。"
  fi
  for item in "${!restore_sources[@]}"; do
    destination="${restore_destinations[$item]}"
    if ! restore_one "${backup_path}/${restore_sources[$item]}" "$destination"; then
      restore_failed='yes'
      warn "回滚文件恢复失败：${destination}；请检查文件权限和磁盘空间，备份位于 ${backup_path}。"
    fi
  done
  if ! systemctl daemon-reload >/dev/null 2>&1; then
    service_failed='yes'
    warn "回滚时重新加载 systemd 服务配置失败；请检查 systemctl daemon-reload。"
  fi

  if [[ "$(cat "${backup_path}/was-enabled" 2>/dev/null || true)" == 'yes' ]]; then
    if ! systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; then
      service_failed='yes'
      warn "回滚时恢复 ${SERVICE_NAME} 开机启动失败；请检查 systemctl is-enabled ${SERVICE_NAME}。"
    fi
  else
    if ! systemctl disable "$SERVICE_NAME" >/dev/null 2>&1; then
      service_failed='yes'
      warn "回滚时关闭 ${SERVICE_NAME} 开机启动失败；请检查 systemctl is-enabled ${SERVICE_NAME}。"
    fi
  fi
  if [[ "$(cat "${backup_path}/was-active" 2>/dev/null || true)" == 'yes' ]]; then
    if ! systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 \
      || ! systemctl is-active --quiet "$SERVICE_NAME"; then
      service_failed='yes'
      warn "回滚后服务未恢复运行：${SERVICE_NAME}；请执行 puppyip status 检查配置和监听。"
    fi
  fi
  if [[ "$restore_failed" == 'yes' || "$service_failed" == 'yes' ]]; then
    warn "自动恢复不完整；请保留备份 ${backup_path}，按上方失败项目检查文件和服务，勿继续覆盖安装。"
    # Keep even a first-install backup's service-state records for diagnosis.
    cleanup_runtime_layout_created_this_run
  else
    warn "修改前的文件及服务状态已恢复。"
    cleanup_runtime_layout_created_this_run "$backup_path"
  fi
  return 0
}

deploy_full() {
  local work_dir="$1" backup_path manager_ready="$2" service_step=''
  if ! backup_path="$(create_backup)"; then
    cleanup_runtime_layout_created_this_run
    die "无法在 ${BACKUP_DIR} 创建完整部署备份，未修改现有服务；请检查目录权限、源文件可读性及磁盘空间。"
  fi
  if ! atomic_install "${work_dir}/xray/xray" "$XRAY_BIN" 0755 root root \
    || ! atomic_install "${work_dir}/xray/geoip.dat" "${ASSET_DIR}/geoip.dat" 0644 root root \
    || ! atomic_install "${work_dir}/xray/geosite.dat" "${ASSET_DIR}/geosite.dat" 0644 root root \
    || ! atomic_install "${work_dir}/candidate-config.json" "$CONFIG_FILE" 0640 root "$RUNTIME_GROUP" \
    || ! atomic_install "${work_dir}/candidate-state.json" "$STATE_FILE" 0600 root root \
    || ! atomic_install "${work_dir}/xray-chain.service" "$SERVICE_FILE" 0644 root root; then
    rollback_backup "$backup_path"
    die "Xray 程序、数据或节点文件部署失败；具体文件及恢复结果见上方提示。"
  fi

  if [[ "$manager_ready" == 'yes' ]]; then
    if ! atomic_install "${work_dir}/manager" "$MANAGER_BIN" 0755 root root \
      || ! atomic_install "${work_dir}/manager" "$LEGACY_MANAGER_BIN" 0755 root root; then
      rollback_backup "$backup_path"
      die "安装管理命令 ${MANAGER_BIN} 或 ${LEGACY_MANAGER_BIN} 失败；具体文件及恢复结果见上方提示。"
    fi
  else
    warn "无法保存脚本副本；以后可重新运行远程脚本进行管理。"
  fi

  if ! systemctl daemon-reload >/dev/null 2>&1; then
    service_step='加载 systemd 配置'
  elif ! systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; then
    service_step='设置开机启动'
  elif ! systemctl restart "$SERVICE_NAME" >/dev/null 2>&1; then
    service_step='重启服务'
  fi
  if [[ -n "$service_step" ]]; then
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager >"${work_dir}/service-failure.log" 2>&1 || true
    show_error_log "${work_dir}/service-failure.log"
    rollback_backup "$backup_path"
    die "${SERVICE_NAME} ${service_step}失败；恢复结果见上方。请执行 puppyip status 检查，勿直接重新安装。"
  fi

  sleep 1
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager >"${work_dir}/service-failure.log" 2>&1 || true
    show_error_log "${work_dir}/service-failure.log"
    rollback_backup "$backup_path"
    die "${SERVICE_NAME} 启动后未保持运行；恢复结果见上方，请执行 puppyip status 检查配置和端口占用。"
  fi
  commit_runtime_layout
}

deploy_model_change() {
  local work_dir="$1" version="$2" backup_path manager_ready='no'
  local preview_file='' previous_int_trap
  shift 2
  render_state "${work_dir}/candidate-state.json" "$version"
  assert_model_port_available "${work_dir}/candidate-state.json"
  render_config "${work_dir}/candidate-config.json" "$work_dir" \
    "${work_dir}/candidate-state.json" "$SECRETS_FILE"
  validate_config "${work_dir}/xray/xray" "${work_dir}/xray" "${work_dir}/candidate-config.json"
  if ! prepare_manager_copy "${work_dir}/manager"; then
    die "无法取得并校验安装脚本的固定提交副本，未部署任何服务文件；请稍后重试。"
  fi
  manager_ready='yes'
  if (( $# > 0 )); then
    preview_file="${work_dir}/new-connections.txt"
    prepare_connection_preview "${work_dir}/candidate-state.json" "$preview_file" "$@"
  fi
  ensure_runtime_layout
  if ! backup_path="$(create_backup)"; then
    cleanup_runtime_layout_created_this_run
    die "无法在 ${BACKUP_DIR} 创建完整修改前备份，未修改现有服务；请检查目录权限、源文件可读性及磁盘空间。"
  fi
  if ! atomic_install "${work_dir}/candidate-config.json" "$CONFIG_FILE" 0640 root "$RUNTIME_GROUP" \
    || ! atomic_install "${work_dir}/candidate-state.json" "$STATE_FILE" 0600 root root; then
    rollback_backup "$backup_path"
    die "写入节点配置 ${CONFIG_FILE} 或状态 ${STATE_FILE} 失败；具体文件及恢复结果见上方提示。"
  fi
  if [[ "$manager_ready" == 'yes' ]]; then
    if ! atomic_install "${work_dir}/manager" "$MANAGER_BIN" 0755 root root \
      || ! atomic_install "${work_dir}/manager" "$LEGACY_MANAGER_BIN" 0755 root root; then
      rollback_backup "$backup_path"
      die "更新管理命令 ${MANAGER_BIN} 或 ${LEGACY_MANAGER_BIN} 失败；具体文件及恢复结果见上方提示。"
    fi
  fi
  if [[ -n "$preview_file" ]]; then
    previous_int_trap="$(trap -p INT)"
    trap 'trap "" INT; rollback_backup "$backup_path"; warn "操作已取消；节点修改的恢复结果见上方提示。"; exit 130' INT
    if ! cat -- "$preview_file"; then
      rollback_backup "$backup_path"
      die "输出本批节点链接和二维码失败；请检查终端输出，节点修改的恢复结果见上方提示。"
    fi
    # Allow terminal output to travel before restarting its possible proxy path.
    if [[ -t 1 ]]; then sleep 2; fi
    if [[ -n "$previous_int_trap" ]]; then
      eval "$previous_int_trap"
    else
      trap - INT
    fi
  fi
  if ! systemctl restart "$SERVICE_NAME" >/dev/null 2>&1; then
    rollback_backup "$backup_path"
    die "应用节点修改时重启 ${SERVICE_NAME} 失败；恢复结果见上方，请执行 puppyip status 检查。"
  fi
  sleep 1
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    rollback_backup "$backup_path"
    die "应用节点修改后 ${SERVICE_NAME} 未保持运行；恢复结果见上方，请执行 puppyip status 检查配置和端口。"
  fi
  commit_runtime_layout
}

uri_encode() {
  jq -rn --arg value "$1" '$value | @uri'
}

build_share_link() {
  local selector="${1:-}" schema address uuid port sni public_key short_id spider_x node authority node_json
  [[ -r "$STATE_FILE" ]] || die "未找到安装状态：$STATE_FILE"
  schema="$(jq -r '.schema // 1' "$STATE_FILE")"
  address="$(jq -er '.serverAddress' "$STATE_FILE")"
  if [[ -n "${2:-}" ]]; then
    valid_ipv4_or_domain "$2" || die "客户端显示地址无效。"
    address="$2"
  fi
  port="$(jq -er '.inboundPort' "$STATE_FILE")"
  sni="$(jq -er '.serverName' "$STATE_FILE")"
  if [[ "$schema" == '2' ]]; then
    select_node_id "$STATE_FILE" "$selector"
    node_json="$(jq -cer --arg id "$SELECTED_NODE_ID" '.nodes[] | select(.id == $id)' "$STATE_FILE")"
    port="$(jq -r --argjson default_port "$port" '.inboundPort // $default_port' <<<"$node_json")"
    uuid="$(jq -r '.uuid' <<<"$node_json")"
    public_key="$(jq -er '.realityPublicKey' "$STATE_FILE")"
    short_id="$(jq -r '.shortId' <<<"$node_json")"
    spider_x="$(jq -r '.spiderX' <<<"$node_json")"
    node="$(jq -r '.name' <<<"$node_json")"
  else
    uuid="$(jq -er '.uuid' "$STATE_FILE")"
    public_key="$(jq -er '.publicKey' "$STATE_FILE")"
    short_id="$(jq -er '.shortId' "$STATE_FILE")"
    spider_x='/'
    node="$(jq -er '.nodeName' "$STATE_FILE")"
    SELECTED_NODE_ID='node-1'
  fi
  authority="$address"
  [[ "$authority" == *:* ]] && authority="[${authority}]"

  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&spx=%s&type=tcp&headerType=none#%s' \
    "$uuid" "$authority" "$port" "$(uri_encode "$sni")" "$(uri_encode "$public_key")" \
    "$(uri_encode "$short_id")" "$(uri_encode "$spider_x")" "$(uri_encode "$node")"
}

print_node_list_file() {
  local file="$1" schema direct_ip="${2:-}"
  schema="$(jq -r '.schema // 1' "$file")"
  if (( $# < 2 )) && jq -e 'any(.nodes[]?; .type == "direct")' "$file" >/dev/null; then
    direct_ip="$(detect_display_direct_ip || true)"
  fi
  printf '\n%s已配置节点%s\n' "$C_BOLD" "$C_RESET"
  if [[ "$schema" == '2' ]]; then
    jq -r --arg direct_ip "${direct_ip:-未验证}" '
      .inboundPort as $default_port | .nodes[] |
      (if (.type // "socks") == "direct" then
        "  \(.number)) \(.name)\n     状态：\(if .enabled == false then "已暂停（原链接已保留）" else "已启用" end)\n     出口：VPS 本机直连 · 公网 IPv4：\($direct_ip)"
      else
        "  \(.number)) \(.name)\n     状态：\(if .enabled == false then "已暂停（原链接已保留）" else "已启用" end)\n     SOCKS5：\(.socksHost):\(.socksPort) · 实际出口：\(if .exitIp == "" then "未验证" else .exitIp end)"
      end) + "\n     入口端口：\(.inboundPort // $default_port)/tcp"
    ' "$file"
  else
    jq -r '"  1) \(.nodeName)\n     状态：已启用\n     SOCKS5：\(.socksHost):\(.socksPort) · 实际出口：旧版未记录\n     入口端口：\(.inboundPort)/tcp"' "$file"
  fi
}

select_node_id() {
  local file="$1" selector="${2:-}" count schema answer selector_number
  schema="$(jq -r '.schema // 1' "$file")"
  if [[ "$schema" != '2' ]]; then
    SELECTED_NODE_ID='node-1'
    return
  fi
  count="$(jq '.nodes | length' "$file")"
  (( count > 0 )) || die "当前没有可用节点。"
  if [[ -z "$selector" && "$count" == '1' ]]; then
    SELECTED_NODE_ID="$(jq -r '.nodes[0].id' "$file")"
    return
  fi
  if [[ -z "$selector" ]]; then
    [[ -t 0 ]] || die "存在多个节点；请先执行 puppyip list 查看编号，再在命令后指定一个编号。"
    print_node_list_file "$file"
    if ! read -r -p '请输入节点编号: ' answer; then
      die "未读取到节点编号。"
    fi
    selector="$answer"
  fi
  selector="${selector#\#}"
  if [[ "$selector" =~ ^[0-9]+$ ]]; then
    selector_number="${selector#"${selector%%[!0]*}"}"
    SELECTED_NODE_ID="$(jq -r --arg number "$selector_number" \
      '.nodes[] | select((.number | tostring) == $number) | .id' "$file")"
  else
    SELECTED_NODE_ID="$(jq -r --arg id "$selector" \
      '.nodes[] | select(.id == $id) | .id' "$file")"
  fi
  [[ -n "$SELECTED_NODE_ID" ]] || die "找不到指定节点；请执行 puppyip list 查看现有编号，再带正确编号重试。"
}

node_outbound_type() {
  local node_id="$1" schema
  schema="$(jq -r '.schema // 1' "$STATE_FILE")"
  if [[ "$schema" == '2' ]]; then
    jq -er --arg id "$node_id" '.nodes[] | select(.id == $id) | (.type // "socks")' "$STATE_FILE"
  else
    printf 'socks'
  fi
}

node_enabled() {
  local node_id="$1" schema
  schema="$(jq -r '.schema // 1' "$STATE_FILE")"
  if [[ "$schema" == '2' ]]; then
    jq -er --arg id "$node_id" '
      .nodes[] | select(.id == $id) | if .enabled == false then "false" else "true" end
    ' "$STATE_FILE"
  else
    printf 'true'
  fi
}

show_connection() {
  local selector="${1:-}" footer="${2:-yes}" link node_id outbound_type exit_ip enabled schema
  local qr_mode="${3:-auto}" display_address="${4:-}" display_direct_ip="${5:-}" resolved_direct='no'
  local RESOLVED_SHARE_ADDRESS RESOLVED_DIRECT_IP
  select_node_id "$STATE_FILE" "$selector"
  node_id="$SELECTED_NODE_ID"
  if [[ -z "$display_address" ]]; then
    resolve_display_addresses "$STATE_FILE"
    display_address="$RESOLVED_SHARE_ADDRESS"
    display_direct_ip="$RESOLVED_DIRECT_IP"
    resolved_direct='yes'
  elif (( $# >= 5 )); then
    resolved_direct='yes'
  fi
  link="$(build_share_link "$node_id" "$display_address")"
  outbound_type="$(node_outbound_type "$node_id")"
  enabled="$(node_enabled "$node_id")"
  schema="$(jq -r '.schema // 1' "$STATE_FILE")"
  if [[ "$schema" == '2' ]]; then
    exit_ip="$(jq -r --arg id "$node_id" \
      '.nodes[] | select(.id == $id) | .exitIp' "$STATE_FILE")"
  else
    exit_ip=''
  fi
  printf '\n%s客户端导入链接 · %s%s\n' "$C_BOLD" \
    "$(jq -r --arg id "$node_id" \
      'if (.schema // 1) == 2 then (.nodes[] | select(.id == $id) | .name) else .nodeName end' "$STATE_FILE")" \
    "$C_RESET"
  if [[ "$enabled" == 'false' ]]; then
    printf '%s状态：已暂停（链接已保留）%s\n' \
      "$C_YELLOW" "$C_RESET"
  fi
  printf '%s\n\n' "$link"
  if command -v qrencode >/dev/null 2>&1 \
    && [[ "$qr_mode" == 'yes' || ( "$qr_mode" == 'auto' && -t 1 ) ]]; then
    qrencode -t ANSIUTF8 "$link" || true
  fi
  if [[ "$outbound_type" == 'direct' ]]; then
    if [[ "$resolved_direct" == 'yes' ]]; then
      exit_ip="$display_direct_ip"
    # Preserve the explicit-address API for callers without an exit-IP context.
    elif [[ -n "$display_address" ]] && valid_ipv4 "$display_address" \
      && [[ "$display_address" != "$(jq -er '.serverAddress' "$STATE_FILE")" ]]; then
      exit_ip="$display_address"
    fi
    printf '\n出口 IP：%s（VPS 本机）\n' "${exit_ip:-未验证}"
  else
    printf '\n出口 IP：%s\n' "${exit_ip:-未验证}"
  fi
  if [[ "$footer" == 'yes' ]]; then
    show_brand_footer
  fi
  return 0
}

show_all_connections() {
  local schema node_id display_address="${1:-}"
  local RESOLVED_SHARE_ADDRESS RESOLVED_DIRECT_IP
  local -a display_context=("$display_address")
  if [[ -z "$display_address" ]]; then
    resolve_display_addresses "$STATE_FILE"
    display_context=("$RESOLVED_SHARE_ADDRESS" "$RESOLVED_DIRECT_IP")
  elif (( $# >= 2 )); then
    display_context=("$display_address" "$2")
  fi
  schema="$(jq -r '.schema // 1' "$STATE_FILE")"
  if [[ "$schema" == '2' ]]; then
    while IFS= read -r node_id; do
      show_connection "$node_id" no auto "${display_context[@]}"
    done < <(jq -r '.nodes | sort_by(.number)[] | .id' "$STATE_FILE")
  else
    show_connection node-1 no auto "${display_context[@]}"
  fi
  show_brand_footer
}

show_connections_by_id() {
  local node_id RESOLVED_SHARE_ADDRESS RESOLVED_DIRECT_IP
  (( $# > 0 )) || return 0
  resolve_display_addresses "$STATE_FILE"
  for node_id in "$@"; do
    show_connection "$node_id" no auto "$RESOLVED_SHARE_ADDRESS" "$RESOLVED_DIRECT_IP"
  done
  show_brand_footer
}

prepare_connection_preview() (
  local candidate_state="$1" output="$2" qr_mode='no' node_id
  local RESOLVED_SHARE_ADDRESS RESOLVED_DIRECT_IP
  shift 2
  [[ ! -t 1 ]] || qr_mode='yes'
  # Render before changing installed files; retain the original terminal's QR mode.
  STATE_FILE="$candidate_state"
  resolve_display_addresses "$STATE_FILE"
  {
    info "节点配置已保存，当前待生效；以下链接将在重启成功后可用。"
    for node_id in "$@"; do
      show_connection "$node_id" no "$qr_mode" "$RESOLVED_SHARE_ADDRESS" "$RESOLVED_DIRECT_IP"
    done
    show_brand_footer
    warn "即将重启 PuppyIP 服务；若 SSH 经过这台 VPS 的代理，连接可能中断。" 2>&1
    info "重连后可输入 puppyip show all 再次查看链接和二维码。"
  } >"$output"
)

print_firewall_hint() {
  local port
  local -a ports=("$@")
  if (( ${#ports[@]} == 0 )); then
    [[ -r "$STATE_FILE" ]] || return 0
    mapfile -t ports < <(model_inbound_ports "$STATE_FILE")
  fi
  for port in "${ports[@]}"; do
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
      warn "UFW 正在运行。如尚未放行，请执行：ufw allow ${port}/tcp"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
      warn "firewalld 正在运行。如尚未放行，请执行：firewall-cmd --permanent --add-port=${port}/tcp && firewall-cmd --reload"
    fi
    warn "还要在云厂商安全组中放行 ${port}/tcp（脚本不会自动修改防火墙）。"
  done
}

script_version_from_file() {
  local file="$1"
  [[ -r "$file" ]] || return 0
  awk -F'"' '/^SCRIPT_VERSION="[^"]+"$/ {print $2; exit}' "$file"
}

download_latest_manager() {
  local output="$1" response commit size version version_count curl_status
  local -a curl_options=(
    --fail --silent --show-error --location --retry 0
    --proto '=https' --proto-redir '=https' --tlsv1.2
    --connect-timeout 3 --max-time 5 --max-filesize "$MAX_INSTALLER_BYTES"
  )
  if response="$(curl "${curl_options[@]}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: puppyip-xray-chain-installer' \
    "${INSTALLER_API_URL}/git/ref/heads/${INSTALLER_BRANCH}" 2>/dev/null)"; then
    :
  else
    curl_status=$?
    warn "获取 PuppyIP 最新提交失败（api.github.com，curl 代码 ${curl_status}：$(socks_probe_error_category "$curl_status")）；请检查 VPS 到 GitHub API 的网络后重试。"
    return 1
  fi
  if ! commit="$(jq -er '.object.sha' <<<"$response" 2>/dev/null)" \
    || [[ ! "$commit" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    warn "GitHub 最新提交响应格式无效（api.github.com）；未下载或执行新脚本，请稍后重试并检查网络响应是否被替换。"
    return 1
  fi
  if curl "${curl_options[@]}" --output "$output" \
    "${INSTALLER_RAW_BASE}/${commit,,}/install.sh" 2>/dev/null; then
    :
  else
    curl_status=$?
    warn "下载 PuppyIP 更新脚本失败（raw.githubusercontent.com，curl 代码 ${curl_status}：$(socks_probe_error_category "$curl_status")）；请检查该域名的网络访问及临时目录空间后重试。"
    rm -f -- "$output"
    return 1
  fi
  if [[ ! -f "$output" || -L "$output" ]]; then
    warn "更新脚本文件校验失败：下载结果不是普通文件；请检查临时目录权限，未执行更新。"
    return 1
  fi
  size="$(wc -c <"$output" | tr -d '[:space:]')" || return 1
  version="$(script_version_from_file "$output")" || return 1
  version_count="$(grep -c '^SCRIPT_VERSION=' "$output" || true)"
  if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size < 1 || size > MAX_INSTALLER_BYTES )) \
    || [[ "$version_count" != '1' || ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || ! grep -q '^# XRAY_CHAIN_SCRIPT$' "$output" \
    || ! bash -n "$output" 2>/dev/null; then
    warn "下载的 PuppyIP 脚本未通过完整性、版本格式或 Bash 语法校验；未执行更新，请检查网络后重新运行，勿跳过校验。"
    rm -f -- "$output"
    return 1
  fi
  chmod 0600 "$output"
}

maybe_update_manager() {
  local work_dir candidate version upgrade_status=0 menu_status=0
  info "正在检查 PuppyIP 管理脚本更新..."
  if ! new_temp_dir; then
    die "无法创建更新临时目录，已停止本次菜单操作；请修复后重新输入 puppyip。"
  fi
  work_dir="$LAST_TEMP_DIR"
  candidate="${work_dir}/latest-manager.sh"
  if ! download_latest_manager "$candidate"; then
    die "PuppyIP 更新检查失败，已停止本次菜单操作；具体阶段和原因见上方，处理后重新输入 puppyip。"
  fi
  version="$(script_version_from_file "$candidate")"
  if ! semantic_version_is_newer "$version" "$SCRIPT_VERSION"; then
    if ! installation_upgrade_needed; then
      info "当前管理脚本为 ${SCRIPT_VERSION}，无需更新。"
      return 0
    fi
    [[ "$version" == "$SCRIPT_VERSION" ]] \
      || die "现有安装版本不一致，且远端脚本更旧；已停止操作以避免降级，请检查安装。"
    info "当前版本为 ${version}，正在修复安装版本或状态不一致的问题。"
  else
    info "发现 PuppyIP ${version}，正在自动更新；现有节点和链接会保留。"
  fi
  warn "更新会重启 PuppyIP 服务；若 SSH 经过本机代理，连接可能中断。"
  # A separate shell keeps errexit and rollback active inside the updater.
  bash "$candidate" upgrade || upgrade_status=$?
  if (( upgrade_status != 0 )); then
    die "PuppyIP ${version} 自动更新失败（退出码 ${upgrade_status}），已停止本次菜单操作；请根据上方错误及恢复结果修复后重试。"
  fi
  if [[ "$(installed_state_version)" != "$version" \
    || "$(installed_manager_version "$MANAGER_BIN")" != "$version" \
    || "$(installed_manager_version "$LEGACY_MANAGER_BIN")" != "$version" ]]; then
    die "自动更新结果未通过版本核对，已停止本次菜单操作；请检查安装后重试。"
  fi
  info "正在进入 PuppyIP ${version} 管理菜单。"
  # The parent still has the old functions loaded. Run the installed copy once,
  # then exit so returning from its menu cannot reopen the old menu.
  bash "$MANAGER_BIN" --menu-after-update "$version" || menu_status=$?
  exit "$menu_status"
}

semantic_version_is_newer() {
  local left="${1#v}" right="${2#v}" index
  local -a left_parts right_parts
  [[ "$left" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ \
    && "$right" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS='.' read -r -a left_parts <<<"$left"
  IFS='.' read -r -a right_parts <<<"$right"
  for index in 0 1 2; do
    if (( 10#${left_parts[$index]} > 10#${right_parts[$index]} )); then
      return 0
    fi
    if (( 10#${left_parts[$index]} < 10#${right_parts[$index]} )); then
      return 1
    fi
  done
  return 1
}

installed_state_version() {
  jq -r '.installerVersion // "unknown"' "$STATE_FILE" 2>/dev/null || printf 'unknown'
}

installed_state_schema() {
  jq -r '.schema // 1' "$STATE_FILE" 2>/dev/null || printf 'unknown'
}

installed_manager_version() {
  local file="$1" version
  version="$(script_version_from_file "$file")"
  printf '%s' "${version:-missing}"
}

assert_upgrade_not_downgrade() {
  local installed_version
  for installed_version in \
    "$(installed_state_version)" \
    "$(installed_manager_version "$MANAGER_BIN")" \
    "$(installed_manager_version "$LEGACY_MANAGER_BIN")"; do
    if semantic_version_is_newer "$installed_version" "$SCRIPT_VERSION"; then
      die "检测到现有版本 ${installed_version} 比当前脚本 ${SCRIPT_VERSION} 更新；为防止降级破坏节点，已停止操作。请使用仓库 main 的最新一键命令。"
    fi
  done
}

installation_upgrade_needed() {
  [[ "$(installed_state_schema)" == "$CURRENT_STATE_SCHEMA" \
    && "$(installed_state_version)" == "$SCRIPT_VERSION" \
    && "$(installed_manager_version "$MANAGER_BIN")" == "$SCRIPT_VERSION" \
    && "$(installed_manager_version "$LEGACY_MANAGER_BIN")" == "$SCRIPT_VERSION" ]] \
    && return 1
  return 0
}

command_upgrade() {
  local work_dir version
  refresh_brand_banner
  require_root
  check_platform
  require_systemd
  installation_complete || die "现有安装不完整；为防止覆盖旧节点，不能自动升级。请先备份 /etc/xray-chain 和 /var/lib/xray-chain。"
  assert_upgrade_not_downgrade
  acquire_lock
  new_temp_dir
  work_dir="$LAST_TEMP_DIR"
  show_progress_line 1 3 "检查依赖并读取现有安装"
  install_dependencies "$work_dir"
  stage_installed_xray "$work_dir" \
    || die "现有 Xray-core 或 Geo 数据不完整；为防止覆盖旧节点，已停止更新。"
  version="$(<"${work_dir}/xray-version")"
  show_progress_line 2 3 "迁移并核对全部节点与凭据"
  prepare_existing_upgrade_candidate "$work_dir" "$version"
  show_progress_line 3 3 "备份并安全应用当前版本"
  finish_progress_line
  ensure_runtime_layout
  deploy_full "$work_dir" yes
  configure_bbr
  info "PuppyIP Chain 已原地更新到 ${SCRIPT_VERSION}；现有链接和二维码无需重新导入。"
}

handle_existing_remote_run() {
  local state_version
  show_brand_banner
  require_root
  check_platform
  require_systemd
  assert_upgrade_not_downgrade
  state_version="$(installed_state_version)"

  if ! installation_upgrade_needed; then
    info "当前已是 PuppyIP Chain ${SCRIPT_VERSION}，继续添加新线路。"
    command_add
    return 0
  fi

  info "正在将现有安装（${state_version}）更新到 PuppyIP Chain ${SCRIPT_VERSION}。"
  printf '现有节点和链接会保留。\n'
  warn "更新会重启 PuppyIP 服务；若 SSH 经过本机代理，连接可能中断。"
  # Keep this direct call outside a conditional so upgrade failures remain fatal.
  command_upgrade
  if installation_upgrade_needed; then
    die "更新结果未通过版本核对，已停止操作，不会继续新增线路。"
  fi
  info "继续添加新线路。"
  command_add
}

command_install() {
  local work_dir version manager_ready='no'
  show_brand_banner
  require_root
  check_platform
  require_systemd
  if installation_complete; then
    assert_upgrade_not_downgrade
    if installation_upgrade_needed; then
      command_upgrade
    else
      configure_bbr
      info "当前已是 PuppyIP Chain ${SCRIPT_VERSION}，现有节点和服务未修改。"
    fi
    show_management_hint
    return
  fi
  if [[ -e "$STATE_FILE" || -e "$CONFIG_FILE" ]]; then
    warn "检测到旧状态或配置，但安装组件不完整。"
    die "为防止覆盖现有节点，脚本不会自动重新安装。请先备份 /etc/xray-chain 和 /var/lib/xray-chain，再检查缺失组件。"
  fi
  if [[ -e "$XRAY_BIN" || -e "$SERVICE_FILE" ]]; then
    warn "检测到不完整的旧安装；继续后会备份残留文件并重新安装。"
    confirm_continue "确认修复安装吗？"
  fi
  acquire_lock
  new_temp_dir
  work_dir="$LAST_TEMP_DIR"
  show_progress_line 1 5 "检查系统并准备依赖"
  install_dependencies "$work_dir"
  collect_panel_reserved_ports
  detect_existing_proxy_stacks
  download_xray "$work_dir"
  version="$(<"${work_dir}/xray-version")"

  refresh_brand_banner
  show_progress_line 3 5 "配置节点出口"
  finish_progress_line
  initialize_model "$work_dir" "$version" "${work_dir}/xray/xray"
  append_batch_nodes_to_model "${work_dir}/xray/xray"
  show_progress_line 4 5 "验证配置并启动服务"
  render_state "${work_dir}/candidate-state.json" "$version"
  assert_model_port_available "${work_dir}/candidate-state.json"
  render_config "${work_dir}/candidate-config.json" "$work_dir" \
    "${work_dir}/candidate-state.json" "$SECRETS_FILE"
  render_service "${work_dir}/xray-chain.service"
  validate_config "${work_dir}/xray/xray" "${work_dir}/xray" "${work_dir}/candidate-config.json"
  if ! prepare_manager_copy "${work_dir}/manager"; then
    die "无法取得并校验安装脚本的固定提交副本，未部署任何服务文件；请稍后重试。"
  fi
  manager_ready='yes'

  ensure_runtime_layout
  deploy_full "$work_dir" "$manager_ready"
  refresh_brand_banner
  show_progress_line 5 5 "检查并启用 BBR"
  configure_bbr
  info "安装完成。"
  print_firewall_hint
  show_connections_by_id "${NEW_NODE_IDS[@]}"
  show_management_hint
}

prepare_existing_operation() {
  local work_dir="$1"
  [[ -r "$STATE_FILE" && -r "$CONFIG_FILE" ]] || die "PuppyIP Chain 尚未安装。"
  stage_installed_xray "$work_dir" || die "读取或复制现有 Xray-core/Geo 数据失败；请检查 ${XRAY_BIN} 和 ${ASSET_DIR} 下的 geoip.dat、geosite.dat，以及磁盘空间。请先保留备份并恢复缺失组件，勿直接重新安装覆盖节点。"
  load_model "$work_dir" "${work_dir}/xray/xray"
}

command_list() {
  require_root
  [[ -r "$STATE_FILE" ]] || die "PuppyIP Chain 尚未安装。"
  print_node_list_file "$STATE_FILE"
}

command_show() {
  local selector="${1:-}"
  require_root
  [[ -r "$STATE_FILE" ]] || die "PuppyIP Chain 尚未安装。"
  if [[ "$selector" == 'all' || -z "$selector" ]]; then
    show_all_connections
  else
    show_connection "$selector"
  fi
}

command_add() {
  local show_hint="${1:-yes}" work_dir version node_id
  local -a new_ports=()
  refresh_brand_banner
  require_root
  check_platform
  require_systemd
  acquire_lock
  new_temp_dir
  work_dir="$LAST_TEMP_DIR"
  prepare_existing_operation "$work_dir"
  version="$(jq -er '.xrayVersion' "$MODEL_FILE")"
  append_batch_nodes_to_model "${work_dir}/xray/xray"
  for node_id in "${NEW_NODE_IDS[@]}"; do
    new_ports+=("$(jq -er --arg id "$node_id" '. as $s | .nodes[]
      | select(.id == $id) | (.inboundPort // $s.inboundPort)' "$MODEL_FILE")")
  done
  print_firewall_hint "${new_ports[@]}"
  info "正在校验并统一应用 ${#NEW_NODE_IDS[@]} 个新节点..."
  deploy_model_change "$work_dir" "$version" "${NEW_NODE_IDS[@]}"
  refresh_brand_banner
  info "已添加 ${#NEW_NODE_IDS[@]} 个出口。"
  [[ "$show_hint" != 'yes' ]] || show_management_hint
}

command_port() {
  local selector="${1:-}" work_dir version old_port new_port node_id node_name
  local XRAY_CHAIN_PORT=''
  local -a reserved_ports=()
  (( $# <= 1 )) || die "用法：puppyip port [节点编号]，一次只更换一条节点的入口端口。"
  refresh_brand_banner
  require_root
  check_platform
  require_systemd
  acquire_lock
  new_temp_dir
  work_dir="$LAST_TEMP_DIR"
  prepare_existing_operation "$work_dir"
  select_node_id "$MODEL_FILE" "$selector"
  node_id="$SELECTED_NODE_ID"
  version="$(jq -er '.xrayVersion' "$MODEL_FILE")"
  old_port="$(jq -er --arg id "$node_id" '. as $s | .nodes[]
    | select(.id == $id) | (.inboundPort // $s.inboundPort)' "$MODEL_FILE")"
  node_name="$(jq -er --arg id "$node_id" '.nodes[] | select(.id == $id) | .name' "$MODEL_FILE")"
  mapfile -t reserved_ports < <(jq -r '. as $s
    | [.inboundPort, (.nodes[] | (.inboundPort // $s.inboundPort))] | unique[]' "$MODEL_FILE")
  select_inbound_port "${reserved_ports[@]}"
  new_port="$INBOUND_PORT"
  jq --arg id "$node_id" --argjson port "$new_port" \
    '(.nodes[] | select(.id == $id) | .inboundPort) = $port' "$MODEL_FILE" >"${MODEL_FILE}.new"
  mv -f -- "${MODEL_FILE}.new" "$MODEL_FILE"
  validate_model "$MODEL_FILE"
  info "节点 ${node_name} · 入口端口：${old_port} → ${new_port}"
  warn "请更新这条节点在客户端中的端口，或重新导入下面的新链接。"
  print_firewall_hint "$new_port"
  info "正在校验并应用新端口..."
  deploy_model_change "$work_dir" "$version" "$node_id"
  info "入口端口已从 ${old_port} 更换为 ${new_port}；请更新客户端连接。"
  show_management_hint
}

command_edit() {
  local selector="${1:-}" work_dir version previous_schema
  refresh_brand_banner
  require_root
  check_platform
  require_systemd
  acquire_lock
  new_temp_dir
  work_dir="$LAST_TEMP_DIR"
  prepare_existing_operation "$work_dir"
  select_node_id "$MODEL_FILE" "$selector"
  previous_schema="$(jq -r '.schema // 1' "$STATE_FILE")"
  version="$(jq -er '.xrayVersion' "$MODEL_FILE")"
  update_node_socks_in_model "$SELECTED_NODE_ID"
  if [[ "$NODE_SETTINGS_CHANGED" == 'yes' || "$previous_schema" != '2' ]]; then
    info "正在校验并应用修改..."
    deploy_model_change "$work_dir" "$version"
    refresh_brand_banner
    if [[ "$NODE_SETTINGS_CHANGED" == 'yes' ]]; then
      info "节点出口已更新；客户端原链接无需修改。"
    else
      info "旧节点格式已安全迁移，节点出口和客户端链接均未改变。"
    fi
  else
    info "未修改节点出口。"
  fi
  show_connection "$SELECTED_NODE_ID"
}

command_set_enabled() {
  local selector="${1:-}" requested="$2" ask_confirmation="${3:-no}"
  local work_dir version node_name node_number current target action prompt
  refresh_brand_banner
  require_root
  check_platform
  require_systemd
  acquire_lock
  new_temp_dir
  work_dir="$LAST_TEMP_DIR"
  prepare_existing_operation "$work_dir"
  select_node_id "$MODEL_FILE" "$selector"
  node_name="$(jq -er --arg id "$SELECTED_NODE_ID" '.nodes[] | select(.id == $id) | .name' "$MODEL_FILE")"
  node_number="$(jq -er --arg id "$SELECTED_NODE_ID" '.nodes[] | select(.id == $id) | .number' "$MODEL_FILE")"
  current="$(jq -er --arg id "$SELECTED_NODE_ID" \
    '.nodes[] | select(.id == $id) | .enabled | tostring' "$MODEL_FILE")"

  case "$requested" in
    pause) target='false' ;;
    resume) target='true' ;;
    toggle)
      if [[ "$current" == 'true' ]]; then target='false'; else target='true'; fi
      ;;
    *) die "未知线路状态操作：${requested}" ;;
  esac

  if [[ "$target" == 'false' ]]; then
    action='暂停'
    prompt="暂停 ${node_name}？"
  else
    action='启用'
    prompt="启用 ${node_name}？"
  fi

  if [[ "$current" == "$target" ]]; then
    info "${node_name} 已处于${action}状态，无需重复操作。"
    print_node_list_file "$MODEL_FILE"
    return 0
  fi

  if [[ "$ask_confirmation" == 'yes' ]] && ! confirm_destructive_action "$prompt"; then
    info "已取消${action}。"
    return 0
  fi

  version="$(jq -er '.xrayVersion' "$MODEL_FILE")"
  set_node_enabled_in_model "$SELECTED_NODE_ID" "$target"
  info "正在应用线路状态..."
  deploy_model_change "$work_dir" "$version"
  refresh_brand_banner
  if [[ "$target" == 'false' ]]; then
    info "已暂停 ${node_name}。"
    info "恢复命令：puppyip resume ${node_number}"
  else
    info "已启用 ${node_name}。"
  fi
  print_node_list_file "$STATE_FILE"
}

command_pause() {
  command_set_enabled "${1:-}" pause no
}

command_resume() {
  command_set_enabled "${1:-}" resume no
}

command_toggle_enabled() {
  command_set_enabled "${1:-}" toggle yes
}

command_remove() {
  local selector="${1:-}" assume_yes="${2:-}" work_dir version node_name
  refresh_brand_banner
  require_root
  check_platform
  require_systemd
  acquire_lock
  new_temp_dir
  work_dir="$LAST_TEMP_DIR"
  prepare_existing_operation "$work_dir"
  select_node_id "$MODEL_FILE" "$selector"
  node_name="$(jq -er --arg id "$SELECTED_NODE_ID" '.nodes[] | select(.id == $id) | .name' "$MODEL_FILE")"
  if [[ "$assume_yes" != '--yes' ]] \
    && ! confirm_destructive_action "确认删除 ${node_name}？"; then
    info "已取消删除。"
    return 0
  fi
  version="$(jq -er '.xrayVersion' "$MODEL_FILE")"
  remove_node_from_model "$SELECTED_NODE_ID"
  deploy_model_change "$work_dir" "$version"
  info "已删除 ${node_name}。"
  print_node_list_file "$STATE_FILE"
}

command_reset() {
  local selector="${1:-}" assume_yes="${2:-}" work_dir version node_name
  refresh_brand_banner
  require_root
  check_platform
  require_systemd
  acquire_lock
  new_temp_dir
  work_dir="$LAST_TEMP_DIR"
  prepare_existing_operation "$work_dir"
  select_node_id "$MODEL_FILE" "$selector"
  node_name="$(jq -er --arg id "$SELECTED_NODE_ID" '.nodes[] | select(.id == $id) | .name' "$MODEL_FILE")"
  if [[ "$assume_yes" != '--yes' ]]; then
    if ! confirm_destructive_action "重置 ${node_name}？旧链接会失效。"; then
      info "已取消重置。"
      return 0
    fi
  fi
  version="$(jq -er '.xrayVersion' "$MODEL_FILE")"
  rotate_node_identity_in_model "$SELECTED_NODE_ID" "${work_dir}/xray/xray"
  deploy_model_change "$work_dir" "$version"
  refresh_brand_banner
  info "节点凭据已重置，请重新导入下面的新链接。"
  show_connection "$SELECTED_NODE_ID"
}

status_state_is_valid() {
  local schema="$1"
  if [[ "$schema" == '2' ]]; then
    jq -e '
      .schema == 2
      and (.inboundPort | type == "number" and floor == . and . >= 1 and . <= 65535)
      and (.nodes | type == "array" and length > 0)
      and all(.nodes[];
        (.id | type == "string" and test("^node-[1-9][0-9]*$"))
        and (.number | type == "number" and floor == . and . >= 1)
        and ((has("inboundPort") | not)
          or (.inboundPort | type == "number" and floor == . and . >= 1 and . <= 65535))
        and (.name | type == "string" and length > 0)
        and ((has("enabled") | not) or (.enabled | type == "boolean"))
        and ((.type // "socks") == "socks" or (.type // "socks") == "direct")
        and ((.exitIp // "") | type == "string")
        and (
          if (.type // "socks") == "socks" then
            (.socksHost | type == "string" and length > 0)
            and (.socksPort | type == "number" and . >= 1 and . <= 65535)
          else
            true
          end
        )
      )
    ' "$STATE_FILE" >/dev/null 2>&1
  elif [[ "$schema" == '1' ]]; then
    jq -e '
      ((.schema // 1) == 1)
      and (.inboundPort | type == "number" and floor == . and . >= 1 and . <= 65535)
      and (.nodeName | type == "string" and length > 0)
      and (.socksHost | type == "string" and length > 0)
      and (.socksPort | type == "number" and . >= 1 and . <= 65535)
    ' "$STATE_FILE" >/dev/null 2>&1
  else
    return 1
  fi
}

status_tcp_port_is_listening() {
  local port="$1"
  ss -H -lnt 2>/dev/null \
    | awk -v suffix=":${port}" '
        {
          for (field = 1; field <= NF; field += 1) {
            if ($field ~ (suffix "$")) found = 1
          }
        }
        END { exit(found ? 0 : 1) }
      '
}

socks_probe_error_category() {
  case "$1" in
    0) printf '检测站未返回有效 IPv4' ;;
    5|6) printf 'DNS 解析失败' ;;
    7) printf '连接失败或被拒绝' ;;
    28) printf '连接或响应超时' ;;
    35|51|58|59|60|64|66|77|80|82|83|90|91) printf 'TLS 握手或证书校验失败' ;;
    67|97) printf '代理握手、认证或上游拒绝' ;;
    22) printf '检测站返回 HTTP 错误' ;;
    *) printf '请求失败' ;;
  esac
}

socks_probe_error_advice() {
  case "$1" in
    0) printf '检查出口响应是否被认证页或拦截页替换' ;;
    5|6) printf '检查 DNS 与目标地址拼写后重试' ;;
    7) printf '检查目标地址、端口与服务是否可达' ;;
    28) printf '检查目标连通性与出口网络后重试' ;;
    35|51|58|59|60|64|66|77|80|82|83|90|91) printf '检查系统时间、CA 证书及出口 TLS 连接' ;;
    67|97) printf '检查代理协议、认证信息及上游服务' ;;
    22) printf '稍后重试，并检查出口能否访问检测站' ;;
    *) printf '根据 curl 代码检查请求环境后重试' ;;
  esac
}

probe_ipv4_with_curl_config() {
  local config_path="$1" diagnostic_path="${2:-}" endpoint domain result curl_status attempt=0
  local -a endpoints=(
    'https://api.ipify.org'
    'https://ipv4.icanhazip.com'
    'https://ifconfig.me/ip'
  )
  if [[ -n "$diagnostic_path" ]]; then
    : >"$diagnostic_path" || return 1
    chmod 0600 "$diagnostic_path" || return 1
  fi
  for endpoint in "${endpoints[@]}"; do
    ((attempt += 1))
    if result="$(curl --disable --noproxy '' -4 --config "$config_path" \
      "$endpoint" 2>/dev/null)"; then
      curl_status=0
    else
      curl_status=$?
    fi
    result="${result#"${result%%[![:space:]]*}"}"
    result="${result%"${result##*[![:space:]]}"}"
    if (( curl_status == 0 )) \
      && [[ "$result" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
      && valid_ipv4 "$result"; then
      printf '%s' "$result"
      return 0
    fi
    if [[ -n "$diagnostic_path" ]]; then
      domain="${endpoint#https://}"
      domain="${domain%%/*}"
      printf '  检测点 %s/3 %s：%s（curl 代码 %s）；建议：%s。\n' "$attempt" "$domain" \
        "$(socks_probe_error_category "$curl_status")" "$curl_status" \
        "$(socks_probe_error_advice "$curl_status")" >>"$diagnostic_path" || return 1
    fi
  done
  return 1
}

write_status_probe_result() {
  local result_file="$1" status="$2" exit_ip="${3:-}"
  printf '%s\n%s\n' "$status" "$exit_ip" >"$result_file"
  if (( $# > 3 )); then printf '%s\n' "${@:4}" >>"$result_file"; fi
  chmod 0600 "$result_file"
}

probe_status_node() {
  local node_id="$1" node_type="$2" schema="$3" work_dir="$4" result_file="$5"
  local tag outbound address port user='' password='' proxy_host config_path diagnostic_path target detected_ip=''
  config_path="${work_dir}/status-${node_id}.curl"
  diagnostic_path="${work_dir}/status-${node_id}.diagnostic"
  if [[ "$node_type" == 'direct' ]]; then
    target='VPS 本机直连'
  else
    if [[ "$schema" == '2' ]]; then tag="socks-out-${node_id}"; else tag='socks-out'; fi
    write_status_probe_result "$result_file" failed '' \
      "配置读取失败：${CONFIG_FILE} 中缺少或无法读取出口 ${tag}。" \
      '建议：先核对该线路的出口配置或恢复已验证的备份，再重新检查状态。'
    outbound="$(jq -cer --arg tag "$tag" \
      '.outbounds[] | select(.tag == $tag)' "$CONFIG_FILE" 2>/dev/null)" || return 0
    write_status_probe_result "$result_file" failed '' \
      "配置字段无效：${CONFIG_FILE} 中出口 ${tag} 的地址、端口或认证字段不完整。" \
      '建议：检查该线路的 SOCKS5 地址、端口和认证字段；状态检测未修改配置。'
    address="$(jq -er '.settings.address' <<<"$outbound" 2>/dev/null)" || return 0
    port="$(jq -er '.settings.port' <<<"$outbound" 2>/dev/null)" || return 0
    user="$(jq -r '.settings.user // ""' <<<"$outbound" 2>/dev/null)" || return 0
    password="$(jq -r '.settings.pass // ""' <<<"$outbound" 2>/dev/null)" || return 0
    valid_ipv4_or_domain "$address" || return 0
    valid_port "$port" || return 0
    [[ ! "$user" =~ [[:cntrl:]] && ! "$password" =~ [[:cntrl:]] ]] || return 0
    [[ -z "$user" || -n "$password" ]] || return 0
    proxy_host="$address"
    [[ "$proxy_host" == *:* ]] && proxy_host="[${proxy_host}]"
    target="SOCKS5 ${proxy_host}:${port}"
  fi
  write_status_probe_result "$result_file" failed '' "检测出口：${target}" \
    '未取得有效检测结果；建议检查本机运行环境后重新执行 puppyip status。'
  {
    if [[ "$node_type" == 'direct' ]]; then
      printf 'proxy = ""\nnoproxy = "*"\n'
    else
      printf 'proxy = "socks5h://%s:%s"\n' "$(curl_config_escape "$proxy_host")" "$port"
    fi
    if [[ -n "$user" ]]; then
      printf 'proxy-user = "%s:%s"\n' \
        "$(curl_config_escape "$user")" "$(curl_config_escape "$password")"
    fi
    printf 'connect-timeout = 4\nmax-time = 6\nsilent\nfail\n'
  } >"$config_path"
  chmod 0600 "$config_path"

  if detected_ip="$(probe_ipv4_with_curl_config "$config_path" "$diagnostic_path")" \
    && valid_ipv4 "$detected_ip"; then
    write_status_probe_result "$result_file" ok "$detected_ip"
  elif [[ -s "$diagnostic_path" ]]; then
    write_status_probe_result "$result_file" failed '' "检测出口：${target}"
    cat -- "$diagnostic_path" >>"$result_file"
  fi
  rm -f -- "$config_path" "$diagnostic_path" || true
}

show_status_node_health() {
  local schema="$1" work_dir="$2" unavailable_reason="${3:-}"
  local node_id node_port pid completed=0 total_enabled=0 status detected_ip expected_ip detail
  local -a node_ids=() running_pids=() result_lines=()
  local -A numbers=() names=() types=() enabled=() expected=() result_files=()
  local -A ports=() port_ready=()

  if [[ "$schema" == '2' ]]; then
    mapfile -t node_ids < <(jq -r '.nodes | sort_by(.number)[] | .id' "$STATE_FILE")
    for node_id in "${node_ids[@]}"; do
      numbers[$node_id]="$(jq -er --arg id "$node_id" \
        '.nodes[] | select(.id == $id) | .number' "$STATE_FILE")"
      names[$node_id]="$(jq -er --arg id "$node_id" \
        '.nodes[] | select(.id == $id) | .name' "$STATE_FILE")"
      types[$node_id]="$(jq -er --arg id "$node_id" \
        '.nodes[] | select(.id == $id) | (.type // "socks")' "$STATE_FILE")"
      enabled[$node_id]="$(jq -r --arg id "$node_id" \
        '.nodes[] | select(.id == $id) | if .enabled == false then "false" else "true" end' \
        "$STATE_FILE")"
      expected[$node_id]="$(jq -r --arg id "$node_id" \
        '.nodes[] | select(.id == $id) | (.exitIp // "")' "$STATE_FILE")"
      ports[$node_id]="$(jq -er --arg id "$node_id" \
        '. as $state | .nodes[] | select(.id == $id) | (.inboundPort // $state.inboundPort)' "$STATE_FILE")"
    done
  else
    node_ids=('node-1')
    numbers['node-1']='1'
    names['node-1']="$(jq -r '.nodeName // "PuppyIP-1"' "$STATE_FILE")"
    types['node-1']='socks'
    enabled['node-1']='true'
    expected['node-1']=''
    ports['node-1']="$(jq -er '.inboundPort' "$STATE_FILE")"
  fi

  printf '\n%s线路出口检测（实时）%s\n' "$C_BOLD" "$C_RESET"
  if [[ -n "$unavailable_reason" ]]; then
    for node_id in "${node_ids[@]}"; do
      printf '  %s) %s\n' "${numbers[$node_id]}" "${names[$node_id]}"
      printf '     入口：%s/tcp\n' "${ports[$node_id]}"
      if [[ "${enabled[$node_id]}" == 'false' ]]; then
        printf '     状态：已暂停（未检测）\n'
      else
        printf '     状态：不可用（%s）\n' "$unavailable_reason"
      fi
    done
    return 0
  fi

  for node_id in "${node_ids[@]}"; do
    [[ "${enabled[$node_id]}" == 'true' ]] || continue
    node_port="${ports[$node_id]}"
    if [[ -z "${port_ready[$node_port]:-}" ]]; then
      if status_tcp_port_is_listening "$node_port"; then
        port_ready[$node_port]='yes'
      else
        port_ready[$node_port]='no'
      fi
    fi
    [[ "${port_ready[$node_port]}" == 'yes' ]] || continue
    total_enabled=$((total_enabled + 1))
    result_files[$node_id]="${work_dir}/status-${node_id}.result"
  done

  if (( total_enabled > 0 )); then
    if interactive_progress_enabled; then
      show_progress_line 0 "$total_enabled" "正在检测线路出口"
    else
      info "正在检测 ${total_enabled} 条线路出口..."
    fi
    for node_id in "${node_ids[@]}"; do
      [[ "${enabled[$node_id]}" == 'true' ]] || continue
      [[ "${port_ready[${ports[$node_id]}]}" == 'yes' ]] || continue
      probe_status_node "$node_id" "${types[$node_id]}" "$schema" "$work_dir" \
        "${result_files[$node_id]}" &
      running_pids+=("$!")
      if (( ${#running_pids[@]} >= STATUS_PROBE_CONCURRENCY )); then
        wait "${running_pids[0]}" || true
        running_pids=("${running_pids[@]:1}")
        completed=$((completed + 1))
        if interactive_progress_enabled; then
          show_progress_line "$completed" "$total_enabled" "正在检测线路出口"
        fi
      fi
    done
    for pid in "${running_pids[@]}"; do
      wait "$pid" || true
      completed=$((completed + 1))
      if interactive_progress_enabled; then
        show_progress_line "$completed" "$total_enabled" "正在检测线路出口"
      fi
    done
    finish_progress_line
  fi

  for node_id in "${node_ids[@]}"; do
    printf '  %s) %s\n' "${numbers[$node_id]}" "${names[$node_id]}"
    printf '     入口：%s/tcp\n' "${ports[$node_id]}"
    if [[ "${enabled[$node_id]}" == 'false' ]]; then
      printf '     状态：已暂停（未检测）\n'
      continue
    fi
    if [[ "${port_ready[${ports[$node_id]}]}" != 'yes' ]]; then
      printf '     状态：不可用（入口端口未监听）\n'
      printf '     建议：运行 ss -lntp 检查 %s/tcp，并用 journalctl -u %s -n 50 --no-pager 查看服务启动原因。\n' \
        "${ports[$node_id]}" "$SERVICE_NAME"
      continue
    fi
    result_lines=()
    if [[ -r "${result_files[$node_id]}" ]]; then
      mapfile -t result_lines <"${result_files[$node_id]}"
    fi
    status="${result_lines[0]:-failed}"
    detected_ip="${result_lines[1]:-}"
    expected_ip="${expected[$node_id]}"
    if [[ "$status" == 'ok' ]] && valid_ipv4 "$detected_ip"; then
      if [[ -n "$expected_ip" && "$expected_ip" != "$detected_ip" ]]; then
        printf '     出口 IP：%s · 与记录不一致（记录：%s）\n' "$detected_ip" "$expected_ip"
      else
        printf '     出口 IP：%s · 正常\n' "$detected_ip"
      fi
    else
      printf '     出口检测：失败\n'
      if (( ${#result_lines[@]} > 2 )); then
        for detail in "${result_lines[@]:2}"; do printf '     %s\n' "$detail"; done
      else
        printf '     未取得检测结果；建议检查本机运行环境后重新执行 puppyip status。\n'
      fi
    fi
  done
}

command_status() {
  local version_output node_count enabled_count paused_count port service_state service_label
  local validation_log tcp_cc default_qdisc schema config_valid='no' command_code
  local unavailable_reason='' work_dir entry_label=''
  local -a ports=()
  require_root
  [[ -e "$STATE_FILE" ]] || die "状态文件不存在：${STATE_FILE}。请核对安装目录或恢复已验证的备份；未执行线路检测。"
  [[ -f "$STATE_FILE" && -r "$STATE_FILE" ]] || die "状态文件不可读：${STATE_FILE}。请检查文件类型、属主与读取权限；未执行线路检测。"
  [[ -e "$CONFIG_FILE" ]] || die "Xray 配置文件不存在：${CONFIG_FILE}。请核对安装目录或恢复已验证的备份；未执行线路检测。"
  [[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || die "Xray 配置文件不可读：${CONFIG_FILE}。请检查文件类型、属主与读取权限；未执行线路检测。"
  [[ -e "$XRAY_BIN" ]] || die "Xray 程序不存在：${XRAY_BIN}。请核对安装目录并修复核心程序；未执行线路检测。"
  [[ -f "$XRAY_BIN" && -x "$XRAY_BIN" ]] || die "Xray 程序不可执行：${XRAY_BIN}。请检查文件类型和执行权限；未执行线路检测。"
  if version_output="$($XRAY_BIN version 2>/dev/null)"; then
    :
  else
    command_code=$?
    die "Xray 程序运行失败：${XRAY_BIN}（退出码 ${command_code}）。请检查程序架构、运行库及文件权限；未执行线路检测。"
  fi
  schema="$(jq -er '.schema // 1' "$STATE_FILE" 2>/dev/null)" \
    || die "状态文件无法解析：${STATE_FILE}。请检查 JSON 格式或恢复已验证的备份；未执行线路检测。"
  status_state_is_valid "$schema" \
    || die "状态文件格式不受支持或节点字段不完整：${STATE_FILE}。请核对版本及节点字段或恢复已验证的备份；未执行线路检测。"
  if [[ "$schema" == '2' ]]; then
    node_count="$(jq '.nodes | length' "$STATE_FILE")"
    enabled_count="$(jq '[.nodes[] | select(.enabled != false)] | length' "$STATE_FILE")"
  else
    node_count='1'
    enabled_count='1'
  fi
  paused_count="$((node_count - enabled_count))"
  mapfile -t ports < <(model_inbound_ports "$STATE_FILE")
  for port in "${ports[@]}"; do
    [[ -z "$entry_label" ]] || entry_label+='、'
    if status_tcp_port_is_listening "$port"; then
      entry_label+="${port}/tcp（监听中）"
    else
      entry_label+="${port}/tcp（未监听）"
    fi
  done
  service_state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  if [[ "$service_state" == 'active' ]]; then
    service_label='正常'
  else
    service_label="异常（${service_state:-未知}）"
  fi
  tcp_cc="$(read_sysctl_value net.ipv4.tcp_congestion_control)"
  default_qdisc="$(read_sysctl_value net.core.default_qdisc)"
  tcp_cc="${tcp_cc:-unknown}"
  default_qdisc="${default_qdisc:-unknown}"
  printf '\n%sPuppyIP Chain 状态%s\n' "$C_BOLD" "$C_RESET"
  printf '  核心：%s\n' "${version_output%%$'\n'*}"
  printf '  服务：%s\n  节点：%s（启用 %s · 暂停 %s）\n  入口：%s\n' \
    "$service_label" "$node_count" "$enabled_count" "$paused_count" "$entry_label"
  printf '  TCP：%s · qdisc %s\n' "$tcp_cc" "$default_qdisc"
  new_temp_dir
  work_dir="$LAST_TEMP_DIR"
  validation_log="${work_dir}/status-validation.log"
  if XRAY_LOCATION_ASSET="$ASSET_DIR" "$XRAY_BIN" run -test -c "$CONFIG_FILE" \
    >"$validation_log" 2>&1; then
    config_valid='yes'
    printf '  配置：正常\n'
  else
    command_code=$?
    printf '  配置：异常（配置校验失败，退出码 %s）\n' "$command_code"
    printf '  文件：%s\n  建议：检查配置字段、文件权限与核心版本，或恢复已验证的备份；本次未改配置。\n' "$CONFIG_FILE"
  fi
  if [[ "$service_state" != 'active' ]]; then
    unavailable_reason='服务未运行'
    printf '  服务单元：%s\n' "$SERVICE_NAME"
    case "$service_state" in
      inactive) printf '  建议：服务当前已停止；先确认是否主动停用，再查看启动记录。\n' ;;
      failed) printf '  建议：服务启动或运行失败；先查看错误记录，修复后再手动启动。\n' ;;
      *) printf '  建议：无法确认服务正在运行；先检查服务单元是否存在及 systemd 状态。\n' ;;
    esac
    printf '  查看命令：systemctl status %s --no-pager；journalctl -u %s -n 50 --no-pager\n' \
      "$SERVICE_NAME" "$SERVICE_NAME"
  elif [[ "$config_valid" != 'yes' ]]; then
    unavailable_reason='配置校验失败'
  fi
  show_status_node_health "$schema" "$work_dir" "$unavailable_reason"
  if [[ "$config_valid" != 'yes' ]]; then
    show_error_log "$validation_log"
  fi
}

command_logs() {
  require_root
  journalctl -u "$SERVICE_NAME" -n 100 --no-pager
}

command_update() {
  local work_dir version
  refresh_brand_banner
  require_root
  check_platform
  require_systemd
  installation_complete \
    || die "现有安装不完整；为防止覆盖旧节点，不能自动更新 Xray。请先备份 /etc/xray-chain 和 /var/lib/xray-chain。"
  assert_upgrade_not_downgrade
  acquire_lock
  new_temp_dir
  work_dir="$LAST_TEMP_DIR"
  show_progress_line 1 4 "检查依赖并读取现有安装"
  install_dependencies "$work_dir"
  XRAY_VERSION="${XRAY_VERSION:-latest}" download_xray "$work_dir"
  version="$(<"${work_dir}/xray-version")"
  show_progress_line 3 4 "迁移并核对全部节点与凭据"
  prepare_existing_upgrade_candidate "$work_dir" "$version"
  show_progress_line 4 4 "备份并安全更新 Xray-core"
  finish_progress_line
  ensure_runtime_layout
  deploy_full "$work_dir" yes
  configure_bbr
  info "Xray-core 已更新到 ${version}；全部现有节点和链接保持不变。"
}

command_uninstall() {
  local purge_answer='no'
  refresh_brand_banner
  require_root
  require_systemd
  acquire_lock
  if [[ "${1:-}" != '--yes' ]]; then
    if ! confirm_destructive_action "卸载 PuppyIP Chain？将删除程序和当前配置。"; then
      info "已取消卸载。"
      return 0
    fi
  fi

  if [[ "${2:-}" == '--purge' ]]; then
    purge_answer='yes'
  elif [[ -t 0 ]]; then
    prompt_yes_no purge_answer "同时删除历史备份（备份中可能含旧 SOCKS 密码）？" 'no'
  fi

  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  restore_bbr_settings
  rm -f -- "$SERVICE_FILE" "$XRAY_BIN" "${ASSET_DIR}/geoip.dat" "${ASSET_DIR}/geosite.dat" \
    "$CONFIG_FILE" "$STATE_FILE" "$MANAGER_BIN" "$LEGACY_MANAGER_BIN"
  systemctl daemon-reload
  rmdir "$CONFIG_DIR" "$BIN_DIR" "$ASSET_DIR" 2>/dev/null || true
  if [[ -f "$RUNTIME_USER_MARKER" ]]; then
    userdel "$RUNTIME_USER" >/dev/null 2>&1 || true
    rm -f -- "$RUNTIME_USER_MARKER"
  fi
  if [[ -f "$RUNTIME_GROUP_MARKER" ]]; then
    groupdel "$RUNTIME_GROUP" >/dev/null 2>&1 || true
    rm -f -- "$RUNTIME_GROUP_MARKER"
  fi

  if [[ "$purge_answer" == 'yes' ]]; then
    if [[ "$DATA_DIR" == '/var/lib/xray-chain' && -d "$DATA_DIR" ]]; then
      rm -rf -- "$DATA_DIR"
      info "历史备份也已删除，无法恢复。"
    fi
  else
    warn "历史备份保留在 ${BACKUP_DIR}；其中可能包含旧凭据。"
  fi
  info "PuppyIP Chain 已卸载。"
}

show_menu() {
  local node_count='0' enabled_count='0'
  if [[ -r "$STATE_FILE" ]]; then
    if [[ "$(jq -r '.schema // 1' "$STATE_FILE")" == '2' ]]; then
      node_count="$(jq '.nodes | length' "$STATE_FILE")"
      enabled_count="$(jq '[.nodes[] | select(.enabled != false)] | length' "$STATE_FILE")"
    else
      node_count='1'
      enabled_count='1'
    fi
  fi
  printf '\n%sPuppyIP Chain 简易管理%s · 共 %s 条线路，%s 条启用\n' \
    "$C_BOLD" "$C_RESET" "$node_count" "$enabled_count"
  printf '  1) 新增本机直连或批量 SOCKS5 出口\n'
  printf '  2) 更换指定线路的入口端口（随机）\n'
  printf '  3) 查看线路、链接和二维码\n'
  printf '  4) 更换线路的出口 IP\n'
  printf '  5) 暂停或启用线路\n'
  printf '  6) 删除线路\n'
  printf '  7) 重新生成线路链接（旧链接会失效）\n'
  printf '  8) 检查是否正常运行\n'
  printf '  9) 查看运行日志\n'
  printf ' 10) 更新 Xray 程序\n'
  printf ' 11) 卸载 PuppyIP Chain\n'
  printf '  0) 退出\n'
}

running_as_installed_manager() {
  local source_real manager_real legacy_real
  source_real="$(readlink -f -- "$SCRIPT_SOURCE" 2>/dev/null || printf '%s' "$SCRIPT_SOURCE")"
  manager_real="$(readlink -f -- "$MANAGER_BIN" 2>/dev/null || printf '%s' "$MANAGER_BIN")"
  legacy_real="$(readlink -f -- "$LEGACY_MANAGER_BIN" 2>/dev/null || printf '%s' "$LEGACY_MANAGER_BIN")"
  [[ "$source_real" == "$manager_real" || "$source_real" == "$legacy_real" ]]
}

usage() {
  cat <<EOF
用法：
  sudo bash install.sh install
  sudo puppyip                         自动检查脚本更新并打开管理菜单
  sudo puppyip add                     新增一个或批量新增 SOCKS5 出口
  sudo puppyip list                    查看节点摘要
  sudo puppyip show [all|节点编号]     显示链接和二维码
  sudo puppyip edit [节点编号]         更换节点出口 IP
  sudo puppyip pause [节点编号]        暂停节点并保留原链接
  sudo puppyip resume [节点编号]       启用节点并恢复原链接
  sudo puppyip remove [节点编号]       删除节点
  sudo puppyip reset [节点编号]        重置节点凭据
  sudo puppyip port [节点编号]         随机更换指定节点的入口端口
  sudo puppyip upgrade                 原地迁移并更新管理脚本
  sudo puppyip update                  更新 Xray-core 并安全迁移状态
  sudo puppyip status|logs
  sudo puppyip uninstall

兼容命令：sudo xray-chain

可选环境变量：
  XRAY_VERSION=v26.3.27              指定 Xray-core 版本；update 默认获取 latest
  XRAY_CHAIN_REALITY_TARGET=域名:443 自定义 REALITY 目标
  XRAY_CHAIN_REALITY_SNI=域名        自定义 REALITY SNI；默认与目标域名一致
  XRAY_CHAIN_PORT=62001              指定首次安装的首节点端口；其余节点自动选择高位端口
  XRAY_CHAIN_UDP_MODE=block|proxy     新节点 UDP 策略；默认 proxy
  XRAY_CHAIN_ENABLE_BBR=1|0           自动启用 BBR；默认 1，设为 0 时不修改 TCP 参数
  XRAY_CHAIN_AUTO_ADDRESS=1|0         查看时自动使用当前本机公网 IP；固定数字中转入口设为 0
  XRAY_CHAIN_ALLOW_UNVERIFIED=1      非交互模式允许跳过失败的联网验证
EOF
}

pause_menu() {
  [[ -t 0 ]] || return 0
  printf '\n'
  read -r -p '按回车返回菜单...' _ || true
  refresh_brand_banner
}

run_management_menu() {
  local command
  while true; do
    show_menu
    if ! read -r -p '请选择要做的操作 [0-11]: ' command; then
      printf '\n'
      exit 0
    fi
    case "$command" in
      1) command_add no; pause_menu ;;
      2) command_port; pause_menu ;;
      3) command_show all; pause_menu ;;
      4) command_edit; pause_menu ;;
      5) command_toggle_enabled; pause_menu ;;
      6) command_remove; pause_menu ;;
      7) command_reset; pause_menu ;;
      8) command_status; pause_menu ;;
      9) command_logs; pause_menu ;;
      10) command_update; pause_menu ;;
      11)
        command_uninstall
        if installation_complete; then pause_menu; else exit 0; fi
        ;;
      0) exit 0 ;;
      *) warn "无效选项。" ;;
    esac
  done
}

main() {
  local command="${1:-}"
  case "$command" in
    --menu-after-update)
      require_root
      [[ $# -eq 2 && "${2:-}" == "$SCRIPT_VERSION" ]] \
        || die "更新菜单交接版本不匹配，请重新输入 puppyip。"
      running_as_installed_manager && installation_complete \
        || die "更新菜单交接的安装不完整，请检查安装后重试。"
      if installation_upgrade_needed; then
        die "更新菜单交接未通过版本核对，请检查安装后重试。"
      fi
      show_brand_banner
      run_management_menu
      ;;
    install) command_install ;;
    add) command_add ;;
    port) shift; command_port "$@" ;;
    list) command_list ;;
    show) shift; command_show "${1:-}" ;;
    edit|reconfigure) shift; command_edit "${1:-}" ;;
    pause) shift; command_pause "${1:-}" ;;
    resume|enable) shift; command_resume "${1:-}" ;;
    remove|delete) shift; command_remove "${1:-}" "${2:-}" ;;
    reset) shift; command_reset "${1:-}" "${2:-}" ;;
    upgrade) command_upgrade; show_management_hint ;;
    status) command_status ;;
    logs) command_logs ;;
    update) command_update ;;
    uninstall) shift; command_uninstall "${1:-}" "${2:-}" ;;
    -h|--help|help) usage ;;
    '')
      if [[ ! -t 0 ]]; then
        die "安装需要交互输入，请使用 bash <(curl -fsSL ${INSTALLER_RAW_URL}) 或先下载脚本再运行；不要使用 curl | bash。"
      fi
      if ! installation_complete; then
        command_install
        return
      fi
      if ! running_as_installed_manager; then
        handle_existing_remote_run
        return
      fi
      show_brand_banner
      require_root
      maybe_update_manager
      run_management_menu
      ;;
    *) usage; die "未知命令：$command" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
