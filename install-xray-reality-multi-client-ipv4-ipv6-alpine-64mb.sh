#!/usr/bin/env sh
set -eu

# Low-memory Alpine installer and multi-client manager for VLESS + REALITY.
# IPv4 and IPv6 use independent inbounds and client lists.

XRAY_DIR="/usr/local/xray"
XRAY_BIN="${XRAY_DIR}/xray"
CONFIG_DIR="/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
META_FILE="${CONFIG_DIR}/vless-reality-ip.env"
ROUTES_FILE="${CONFIG_DIR}/vvr-routing.rules"
CLIENTS_FILE="${CONFIG_DIR}/vvr-clients.db"
SERVICE_FILE="/etc/init.d/xray"
LOG_FILE="/var/log/xray.log"
ERR_LOG_FILE="/var/log/xray.err"
MANAGER_BIN="/usr/local/bin/vvr"

DEFAULT_IPV4_PORT="443"
DEFAULT_IPV6_PORT="8443"
DEFAULT_SNI="www.sony.com"
DEFAULT_BASE_OUTBOUND_MODE="ipv4"
DEFAULT_HAPPY_EYEBALLS_DELAY_MS="100"
DEFAULT_INSTALLER_URL="https://raw.githubusercontent.com/xhpx7301/vvr/main/install-xray-reality-multi-client-ipv4-ipv6-alpine-64mb.sh"
FINGERPRINT="chrome"
SPIDERX="%2F"
TMP_DIR=""
INSTALL_ROLLBACK_DIR=""
INSTALL_BACKUP_READY="0"
EXISTING_SERVICE_WAS_RUNNING="0"
EXISTING_SERVICE_WAS_ENABLED="0"
INSTALL_COMMITTED="0"
LOW_MEM_THRESHOLD_KB="131072"
LOW_MEM_SWAP_FILE="${VVR_SWAP_FILE:-/swapfile}"
LOW_MEM_SWAP_SIZE_MB="${VVR_SWAP_SIZE_MB:-256}"

if [ -t 1 ]; then
  BLUE="$(printf '\033[1;34m')"
  YELLOW="$(printf '\033[1;33m')"
  RED="$(printf '\033[1;31m')"
  GREEN="$(printf '\033[1;32m')"
  RESET="$(printf '\033[0m')"
else
  BLUE=""
  YELLOW=""
  RED=""
  GREEN=""
  RESET=""
fi

info() { printf '%s\n' "${BLUE}[INFO]${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}[WARN]${RESET} $*" >&2; }
ok() { printf '%s\n' "${GREEN}[OK]${RESET} $*"; }
fail() { printf '%s\n' "${RED}[ERR]${RESET} $*" >&2; exit 1; }

cleanup() {
  if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
    rm -rf "${TMP_DIR}"
  fi
}

backup_existing_install() {
  INSTALL_ROLLBACK_DIR="${TMP_DIR}/rollback"
  mkdir -p "${INSTALL_ROLLBACK_DIR}"

  if [ -d "${XRAY_DIR}" ]; then
    cp -a "${XRAY_DIR}" "${INSTALL_ROLLBACK_DIR}/xray-dir"
  fi
  if [ -d "${CONFIG_DIR}" ]; then
    cp -a "${CONFIG_DIR}" "${INSTALL_ROLLBACK_DIR}/config-dir"
  fi
  if [ -f "${SERVICE_FILE}" ]; then
    cp -a "${SERVICE_FILE}" "${INSTALL_ROLLBACK_DIR}/xray-service"
  fi
  if [ -f "${MANAGER_BIN}" ]; then
    cp -a "${MANAGER_BIN}" "${INSTALL_ROLLBACK_DIR}/vvr-manager"
  fi
  INSTALL_BACKUP_READY="1"
}

rollback_install() {
  [ "${INSTALL_COMMITTED:-0}" = "0" ] || return 0
  [ "${INSTALL_BACKUP_READY:-0}" = "1" ] || return 0
  [ -n "${INSTALL_ROLLBACK_DIR:-}" ] || return 0
  [ -d "${INSTALL_ROLLBACK_DIR}" ] || return 0

  warn "安装未完成，正在恢复安装前的 Xray 状态..."
  rc-service xray stop >/dev/null 2>&1 || true

  rm -rf "${XRAY_DIR}" "${CONFIG_DIR}"
  rm -f "${SERVICE_FILE}" "${MANAGER_BIN}"
  if [ "${EXISTING_SERVICE_WAS_ENABLED:-0}" != "1" ]; then
    rc-update del xray default >/dev/null 2>&1 || true
  fi
  if [ -d "${INSTALL_ROLLBACK_DIR}/xray-dir" ]; then
    cp -a "${INSTALL_ROLLBACK_DIR}/xray-dir" "${XRAY_DIR}"
  fi
  if [ -d "${INSTALL_ROLLBACK_DIR}/config-dir" ]; then
    cp -a "${INSTALL_ROLLBACK_DIR}/config-dir" "${CONFIG_DIR}"
  fi
  if [ -f "${INSTALL_ROLLBACK_DIR}/xray-service" ]; then
    cp -a "${INSTALL_ROLLBACK_DIR}/xray-service" "${SERVICE_FILE}"
  fi
  if [ -f "${INSTALL_ROLLBACK_DIR}/vvr-manager" ]; then
    cp -a "${INSTALL_ROLLBACK_DIR}/vvr-manager" "${MANAGER_BIN}"
  fi

  if [ "${EXISTING_SERVICE_WAS_RUNNING:-0}" = "1" ] && [ -f "${SERVICE_FILE}" ]; then
    if rc-service xray start >/dev/null 2>&1; then
      ok "旧 Xray 服务已恢复运行。"
    else
      warn "旧文件已恢复，但旧 Xray 服务未能自动启动，请运行：rc-service xray start"
    fi
  fi
}

installer_exit() {
  STATUS=$?
  trap - 0 INT TERM HUP
  if [ "${STATUS}" -ne 0 ]; then
    rollback_install
  fi
  cleanup
  exit "${STATUS}"
}

need_root() {
  [ "$(id -u)" -eq 0 ] || fail "请使用 root 运行此脚本。"
}

need_alpine() {
  [ -f /etc/alpine-release ] || fail "此脚本仅支持 Alpine Linux。"
  command -v rc-service >/dev/null 2>&1 || fail "未找到 OpenRC。"
}

effective_memory_kb() {
  MEM_TOTAL_KB="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  case "${MEM_TOTAL_KB}" in ''|*[!0-9]*) MEM_TOTAL_KB=0 ;; esac

  for LIMIT_FILE in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
    [ -r "${LIMIT_FILE}" ] || continue
    LIMIT_BYTES="$(cat "${LIMIT_FILE}" 2>/dev/null || true)"
    case "${LIMIT_BYTES}" in ''|max|*[!0-9]*) continue ;; esac
    LIMIT_KB=$((LIMIT_BYTES / 1024))
    [ "${LIMIT_KB}" -gt 0 ] || continue
    if [ "${MEM_TOTAL_KB}" -eq 0 ] || [ "${LIMIT_KB}" -lt "${MEM_TOTAL_KB}" ]; then
      MEM_TOTAL_KB="${LIMIT_KB}"
    fi
  done
  printf '%s' "${MEM_TOTAL_KB}"
}

ensure_low_mem_swap() {
  MEM_TOTAL_KB="$(effective_memory_kb)"
  SWAP_TOTAL_KB="$(awk '/SwapTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  case "${SWAP_TOTAL_KB}" in ''|*[!0-9]*) SWAP_TOTAL_KB=0 ;; esac

  if [ "${MEM_TOTAL_KB}" -eq 0 ] || [ "${MEM_TOTAL_KB}" -gt "${LOW_MEM_THRESHOLD_KB}" ]; then
    info "可用内存上限约为 $((MEM_TOTAL_KB / 1024)) MiB，无需低内存安装保护。"
    return 0
  fi
  if [ "${SWAP_TOTAL_KB}" -gt 0 ]; then
    info "检测到约 $((SWAP_TOTAL_KB / 1024)) MiB Swap。"
    return 0
  fi

  warn "检测到内存上限约为 $((MEM_TOTAL_KB / 1024)) MiB 且没有 Swap。"
  info "尝试创建 ${LOW_MEM_SWAP_SIZE_MB} MiB 临时安装 Swap：${LOW_MEM_SWAP_FILE}"

  if [ ! -f "${LOW_MEM_SWAP_FILE}" ]; then
    AVAILABLE_KB="$(df -Pk "$(dirname "${LOW_MEM_SWAP_FILE}")" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
    case "${AVAILABLE_KB}" in ''|*[!0-9]*) AVAILABLE_KB=0 ;; esac
    REQUIRED_KB=$((LOW_MEM_SWAP_SIZE_MB * 1024 + 16384))
    if [ "${AVAILABLE_KB}" -gt 0 ] && [ "${AVAILABLE_KB}" -lt "${REQUIRED_KB}" ]; then
      warn "磁盘空间不足，无法创建 ${LOW_MEM_SWAP_SIZE_MB} MiB Swap。"
      return 1
    fi
    if ! dd if=/dev/zero of="${LOW_MEM_SWAP_FILE}" bs=1M count="${LOW_MEM_SWAP_SIZE_MB}" >/dev/null 2>&1; then
      warn "创建 Swap 文件失败。"
      rm -f "${LOW_MEM_SWAP_FILE}"
      return 1
    fi
    chmod 0600 "${LOW_MEM_SWAP_FILE}"
    if command -v mkswap >/dev/null 2>&1; then
      MKSWAP=mkswap
    elif command -v busybox >/dev/null 2>&1 && busybox mkswap --help >/dev/null 2>&1; then
      MKSWAP="busybox mkswap"
    else
      warn "系统没有 mkswap，无法格式化 Swap 文件。"
      rm -f "${LOW_MEM_SWAP_FILE}"
      return 1
    fi
    if ! ${MKSWAP} "${LOW_MEM_SWAP_FILE}" >/dev/null 2>&1; then
      warn "格式化 Swap 文件失败。"
      rm -f "${LOW_MEM_SWAP_FILE}"
      return 1
    fi
  fi

  if ! swapon "${LOW_MEM_SWAP_FILE}" >/dev/null 2>&1; then
    warn "启用 Swap 失败；当前 VPS 或容器可能禁止 swapon。"
    return 1
  fi
  ok "已启用低内存安装 Swap。"
  return 0
}

install_deps() {
  info "以低内存模式安装依赖..."
  # 分成两个较小事务，降低 apk 解包和脚本执行时的瞬时内存。
  if ! apk add --no-cache ca-certificates curl openssl; then
    fail "基础依赖安装失败。若日志中出现 Killed，请提高容器内存上限或在宿主机启用 Swap。"
  fi
  if ! apk add --no-cache unzip iproute2; then
    fail "网络和解压依赖安装失败。若日志中出现 Killed，请提高容器内存上限或在宿主机启用 Swap。"
  fi
}

detect_arch() {
  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64|amd64) XRAY_ZIP="Xray-linux-64.zip" ;;
    aarch64|arm64) XRAY_ZIP="Xray-linux-arm64-v8a.zip" ;;
    armv7l|armv7) XRAY_ZIP="Xray-linux-arm32-v7a.zip" ;;
    *) fail "暂不支持的 CPU 架构：${ARCH}" ;;
  esac
  XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ZIP}"
}

prepare_tmp() {
  for TMP_PARENT in "${INSTALL_TMPDIR:-}" /var/tmp /root /tmp; do
    [ -n "${TMP_PARENT}" ] || continue
    [ -d "${TMP_PARENT}" ] || continue
    [ -w "${TMP_PARENT}" ] || continue
    TMP_DIR="$(mktemp -d "${TMP_PARENT}/xray-install.XXXXXX")"
    info "临时目录：${TMP_DIR}"
    return
  done
  fail "未找到可写的临时目录。"
}

detect_network() {
  SERVER_IPV4=""
  SERVER_IPV6=""

  if [ -n "${CUSTOM_IPV4:-${CUSTOM_IP:-}}" ]; then
    SERVER_IPV4="${CUSTOM_IPV4:-${CUSTOM_IP}}"
  else
    SERVER_IPV4="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
    case "${SERVER_IPV4}" in
      *.*.*.*) ;;
      *) SERVER_IPV4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')" ;;
    esac
  fi
  case "${SERVER_IPV4}" in *.*.*.*) ;; *) SERVER_IPV4="" ;; esac

  if [ -n "${CUSTOM_IPV6:-}" ]; then
    SERVER_IPV6="${CUSTOM_IPV6}"
  else
    SERVER_IPV6="$(curl -6fsS --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
    case "${SERVER_IPV6}" in
      *:*) ;;
      *) SERVER_IPV6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')" ;;
    esac
  fi
  case "${SERVER_IPV6}" in *:*) ;; *) SERVER_IPV6="" ;; esac
}

ipv4_display() {
  if [ -n "${SERVER_IPV4:-}" ]; then printf '%s' "${SERVER_IPV4}"; else printf '%s' '未检测到公网地址'; fi
}

ipv6_display() {
  if [ -n "${SERVER_IPV6:-}" ]; then printf '%s' "${SERVER_IPV6}"; else printf '%s' '未检测到公网地址'; fi
}

prompt_port_value() {
  PORT_LABEL="$1"
  CURRENT_PORT="$2"
  while :; do
    printf '%s监听端口 [%s]: ' "${PORT_LABEL}" "${CURRENT_PORT}"
    read -r INPUT
    SELECTED_PORT="${INPUT:-${CURRENT_PORT}}"
    case "${SELECTED_PORT}" in
      ''|*[!0-9]*) echo "端口必须是 1 到 65535 之间的数字。"; continue ;;
    esac
    if [ "${SELECTED_PORT}" -ge 1 ] && [ "${SELECTED_PORT}" -le 65535 ]; then break; fi
    echo "端口必须在 1 到 65535 之间。"
  done
}

prompt_sni() {
  CURRENT_SNI="${1:-${DEFAULT_SNI}}"
  while :; do
    printf 'REALITY SNI [%s]: ' "${CURRENT_SNI}"
    read -r INPUT
    SNI="${INPUT:-${CURRENT_SNI}}"
    SNI="$(printf '%s' "${SNI}" | tr -d '[:space:]')"
    case "${SNI}" in
      '') echo "SNI 不能为空。" ;;
      *:*) echo "只输入域名，不要包含端口。" ;;
      */*) echo "只输入域名，不要包含协议或路径。" ;;
      *[!A-Za-z0-9.-]*) echo "SNI 格式无效。" ;;
      *) DEST="${SNI}:443"; break ;;
    esac
  done
}

make_default_tag() {
  RANDOM_SUFFIX="$(LC_ALL=C tr -dc 'A-Za-z' < /dev/urandom | head -c 6 || true)"
  [ -n "${RANDOM_SUFFIX}" ] || RANDOM_SUFFIX="ABCDEF"
  DEFAULT_TAG="vvr-${RANDOM_SUFFIX}"
}

prompt_tag() {
  CURRENT_TAG="${1:-}"
  if [ -z "${CURRENT_TAG}" ]; then
    make_default_tag
    CURRENT_TAG="${DEFAULT_TAG}"
  fi
  while :; do
    printf '节点名称 [%s]: ' "${CURRENT_TAG}"
    read -r INPUT
    TAG="${INPUT:-${CURRENT_TAG}}"
    case "${TAG}" in
      ''|*[!A-Za-z0-9._-]*) echo "节点名称只能包含英文、数字、点、下划线和短横线。" ;;
      *) break ;;
    esac
  done
}

outbound_mode_label() {
  case "$1" in
    ipv4) printf '%s' '仅 IPv4' ;;
    ipv6) printf '%s' '仅 IPv6' ;;
    ipv4v6) printf '%s' 'IPv4 优先，IPv6 兜底' ;;
    ipv6v4) printf '%s' 'IPv6 优先，IPv4 兜底' ;;
    happy4v6) printf '%s' 'IPv4 优先连接竞速' ;;
    happy6v4) printf '%s' 'IPv6 优先连接竞速' ;;
    *) printf '%s' '未知' ;;
  esac
}

choose_outbound_mode() {
  DEFAULT_MODE="${1:-${DEFAULT_BASE_OUTBOUND_MODE}}"
  case "${DEFAULT_MODE}" in
    ipv4) DEFAULT_CHOICE=1 ;;
    ipv6) DEFAULT_CHOICE=2 ;;
    ipv4v6) DEFAULT_CHOICE=3 ;;
    ipv6v4) DEFAULT_CHOICE=4 ;;
    happy4v6) DEFAULT_CHOICE=5 ;;
    happy6v4) DEFAULT_CHOICE=6 ;;
    *) DEFAULT_CHOICE=1 ;;
  esac
  while :; do
    echo "  1. 仅 IPv4"
    echo "  2. 仅 IPv6"
    echo "  3. IPv4 优先，IPv6 兜底"
    echo "  4. IPv6 优先，IPv4 兜底"
    echo "  5. IPv4 优先连接竞速（Happy Eyeballs）"
    echo "  6. IPv6 优先连接竞速（Happy Eyeballs）"
    printf '请选择 [%s]: ' "${DEFAULT_CHOICE}"
    read -r INPUT
    case "${INPUT:-${DEFAULT_CHOICE}}" in
      1) SELECTED_OUTBOUND_MODE="ipv4" ;;
      2) SELECTED_OUTBOUND_MODE="ipv6" ;;
      3) SELECTED_OUTBOUND_MODE="ipv4v6" ;;
      4) SELECTED_OUTBOUND_MODE="ipv6v4" ;;
      5) SELECTED_OUTBOUND_MODE="happy4v6" ;;
      6) SELECTED_OUTBOUND_MODE="happy6v4" ;;
      *) echo "无效选择，请输入 1 到 6。"; continue ;;
    esac
    return
  done
}

confirm_outbound_availability() {
  MODE="$1"
  case "${MODE}" in
    ipv4)
      [ -n "${SERVER_IPV4}" ] && return 0
      warn "当前检测不到 IPv4 出站，仅 IPv4 模式可能无法访问目标。"
      ;;
    ipv6)
      [ -n "${SERVER_IPV6}" ] && return 0
      warn "当前检测不到 IPv6 出站，仅 IPv6 模式可能无法访问目标。"
      ;;
    ipv4v6|happy4v6)
      [ -n "${SERVER_IPV4}" ] || warn "当前检测不到 IPv4，将主要由 IPv6 接管。"
      return 0
      ;;
    ipv6v4|happy6v4)
      [ -n "${SERVER_IPV6}" ] || warn "当前检测不到 IPv6，将主要由 IPv4 接管。"
      return 0
      ;;
  esac
  printf '仍要继续吗？[y/N]: '
  read -r ANSWER
  case "${ANSWER}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

prompt_base_outbound_mode() {
  while :; do
    echo
    echo "基础出站模式（未命中域名规则的流量）："
    choose_outbound_mode "${BASE_OUTBOUND_MODE:-${DEFAULT_BASE_OUTBOUND_MODE}}"
    if confirm_outbound_availability "${SELECTED_OUTBOUND_MODE}"; then
      BASE_OUTBOUND_MODE="${SELECTED_OUTBOUND_MODE}"
      return
    fi
  done
}

confirm_inputs() {
  echo
  echo "安装参数确认："
  echo "  IPv4 入站：0.0.0.0:${IPV4_PORT}"
  echo "  IPv6 入站：[::]:${IPV6_PORT}"
  echo "  SNI：${SNI}"
  echo "  初始 IPv4 客户端：${IPV4_CLIENT_NAME}"
  echo "  初始 IPv6 客户端：${IPV6_CLIENT_NAME}"
  echo "  基础出站：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")"
  echo "  初始规则：无"
  echo
  printf '确认继续安装？[Y/n]: '
  read -r ANSWER
  case "${ANSWER:-Y}" in y|Y|yes|YES) ;; *) fail "已取消安装。" ;; esac
}

handle_existing_install() {
  if [ -f "${SERVICE_FILE}" ] || [ -f "${CONFIG_FILE}" ] || [ -x "${XRAY_BIN}" ]; then
    warn "检测到已有 Xray 安装。"
    printf '是否替换现有安装和配置？脚本会先备份，失败时自动恢复。[y/N]: '
    read -r ANSWER
    case "${ANSWER}" in
      y|Y|yes|YES)
        if rc-service xray status >/dev/null 2>&1; then
          EXISTING_SERVICE_WAS_RUNNING="1"
        fi
        if [ -e /etc/runlevels/default/xray ]; then
          EXISTING_SERVICE_WAS_ENABLED="1"
        fi
        backup_existing_install
        info "旧安装已临时备份；下载完成后才会停止旧服务并执行替换。"
        ;;
      *) fail "已取消，未覆盖现有安装。" ;;
    esac
  else
    backup_existing_install
  fi
}

prepare_for_replacement() {
  if [ "${EXISTING_SERVICE_WAS_RUNNING:-0}" = "1" ]; then
    info "停止旧 Xray 服务，开始替换安装..."
    rc-service xray stop >/dev/null 2>&1 || fail "无法停止旧 Xray 服务。"
  fi
}

check_port_available() {
  CHECK_PORT="$1"
  OLD_PORT="${2:-}"
  if [ "${CHECK_PORT}" != "${OLD_PORT}" ] && command -v ss >/dev/null 2>&1 && \
     ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${CHECK_PORT}$"; then
    return 1
  fi
  return 0
}

download_xray() {
  info "下载 Xray-core (${ARCH})..."
  wget -O "${TMP_DIR}/${XRAY_ZIP}" "${XRAY_URL}"
  [ -s "${TMP_DIR}/${XRAY_ZIP}" ] || fail "Xray 安装包下载失败。"
}

extract_archive_member() {
  MEMBER="$1"
  TARGET="$2"
  MODE="$3"
  TEMP_TARGET="${TARGET}.tmp.$"
  rm -f "${TEMP_TARGET}"
  if ! unzip -p "${TMP_DIR}/${XRAY_ZIP}" "${MEMBER}" > "${TEMP_TARGET}"; then
    rm -f "${TEMP_TARGET}"
    return 1
  fi
  chmod "${MODE}" "${TEMP_TARGET}"
  mv -f "${TEMP_TARGET}" "${TARGET}"
}

install_xray() {
  info "以流式方式安装 Xray 和规则资源..."
  mkdir -p "${XRAY_DIR}" "${CONFIG_DIR}"
  extract_archive_member xray "${XRAY_BIN}" 0755 || fail "安装包中没有 Xray 可执行文件。"
  extract_archive_member geoip.dat "${XRAY_DIR}/geoip.dat" 0644 || warn "安装包中没有 geoip.dat。"
  extract_archive_member geosite.dat "${XRAY_DIR}/geosite.dat" 0644 || fail "安装包中没有 geosite.dat，无法使用 geosite 域名规则。"
  rm -f "${TMP_DIR}/${XRAY_ZIP}"
}

generate_uuid() {
  UUID_OUTPUT=""
  if ! UUID_OUTPUT="$("${XRAY_BIN}" uuid 2>&1)"; then
    [ -z "${UUID_OUTPUT}" ] || printf '%s\n' "${UUID_OUTPUT}" >&2
    fail "Xray 生成 UUID 失败；如果显示 Killed，说明当时触发了内存限制。"
  fi
  UUID="$(printf '%s' "${UUID_OUTPUT}" | tr -d '\r\n[:space:]')"
  if ! printf '%s\n' "${UUID}" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'; then
    fail "Xray 返回的 UUID 格式无效。"
  fi
}

generate_reality_values() {
  info "生成 REALITY 密钥和 shortId..."
  KEYS=""
  if ! KEYS="$("${XRAY_BIN}" x25519 2>&1)"; then
    [ -z "${KEYS}" ] || printf '%s\n' "${KEYS}" >&2
    fail "Xray 生成 REALITY X25519 密钥失败；如果显示 Killed，说明当时触发了内存限制。"
  fi
  PRIVATE_KEY="$(printf '%s\n' "${KEYS}" | awk '{line=tolower($0); if (line ~ /private/ && line ~ /key/) {sub(/.*[:=][ \t]*/, "", $0); gsub(/[\r",]/, "", $0); print $1; exit}}')"
  PUBLIC_KEY="$(printf '%s\n' "${KEYS}" | awk '{line=tolower($0); if ((line ~ /public/ && line ~ /key/) || line ~ /^password[ \t]*:/) {sub(/.*[:=][ \t]*/, "", $0); gsub(/[\r",]/, "", $0); print $1; exit}}')"
  if ! printf '%s\n' "${PRIVATE_KEY}" | grep -Eq '^[A-Za-z0-9_-]{43}$'; then
    fail "无法从 Xray 输出中解析有效的 REALITY 私钥。"
  fi
  if ! printf '%s\n' "${PUBLIC_KEY}" | grep -Eq '^[A-Za-z0-9_-]{43}$'; then
    fail "无法从 Xray 输出中解析有效的 REALITY 公钥；当前 Xray 可能使用了未兼容的输出格式。"
  fi
  info "REALITY X25519 密钥已生成并解析。"

  SHORT_ID_OUTPUT=""
  if ! SHORT_ID_OUTPUT="$(openssl rand -hex 8 2>&1)"; then
    [ -z "${SHORT_ID_OUTPUT}" ] || printf '%s\n' "${SHORT_ID_OUTPUT}" >&2
    fail "OpenSSL 生成 shortId 失败。"
  fi
  SHORT_ID="$(printf '%s' "${SHORT_ID_OUTPUT}" | tr -d '\r\n[:space:]')"
  if ! printf '%s\n' "${SHORT_ID}" | grep -Eq '^[0-9A-Fa-f]{16}$'; then
    fail "OpenSSL 返回的 shortId 格式无效。"
  fi
  info "shortId 已生成。"
}

ensure_clients_file() {
  if [ ! -f "${CLIENTS_FILE}" ]; then
    : > "${CLIENTS_FILE}"
    chmod 0600 "${CLIENTS_FILE}"
  fi
}

initialize_clients_file() {
  mkdir -p "${CONFIG_DIR}"
  {
    printf 'ipv4|%s|%s\n' "${IPV4_UUID}" "${IPV4_CLIENT_NAME}"
    printf 'ipv6|%s|%s\n' "${IPV6_UUID}" "${IPV6_CLIENT_NAME}"
  } > "${CLIENTS_FILE}"
  chmod 0600 "${CLIENTS_FILE}"
  info "已创建初始 IPv4 与 IPv6 客户端。"
}

client_count() {
  CLIENT_FAMILY="$1"
  ensure_clients_file
  awk -F '|' -v family="${CLIENT_FAMILY}" '$1 == family {count++} END {print count+0}' "${CLIENTS_FILE}"
}

client_name_exists() {
  CLIENT_FAMILY="$1"
  CLIENT_NAME="$2"
  ensure_clients_file
  awk -F '|' -v family="${CLIENT_FAMILY}" -v name="${CLIENT_NAME}" \
    '$1 == family && $3 == name {found=1} END {exit !found}' "${CLIENTS_FILE}"
}

ensure_routes_file() {
  if [ ! -f "${ROUTES_FILE}" ]; then
    : > "${ROUTES_FILE}"
    chmod 0600 "${ROUTES_FILE}"
  fi
}

initialize_routes_file() {
  mkdir -p "${CONFIG_DIR}"
  : > "${ROUTES_FILE}"
  chmod 0600 "${ROUTES_FILE}"
  info "初始路由规则文件已建立（当前无自定义规则）。"
}

outbound_tag_for_mode() {
  case "$1" in
    ipv4) printf '%s' 'direct-ipv4' ;;
    ipv6) printf '%s' 'direct-ipv6' ;;
    ipv4v6) printf '%s' 'direct-ipv4v6' ;;
    ipv6v4) printf '%s' 'direct-ipv6v4' ;;
    happy4v6) printf '%s' 'direct-happy-ipv4v6' ;;
    happy6v4) printf '%s' 'direct-happy-ipv6v4' ;;
    *) return 1 ;;
  esac
}

write_config() {
  ensure_routes_file
  ROUTING_RULES=""
  while IFS='|' read -r ROUTE_MODE ROUTE_TYPE ROUTE_VALUE; do
    [ -n "${ROUTE_MODE}" ] || continue
    ROUTE_TAG="$(outbound_tag_for_mode "${ROUTE_MODE}" 2>/dev/null || true)"
    [ -n "${ROUTE_TAG}" ] || continue
    case "${ROUTE_TYPE}" in
      domain) ROUTE_DOMAIN="${ROUTE_VALUE}" ;;
      geosite) ROUTE_DOMAIN="geosite:${ROUTE_VALUE}" ;;
      *) continue ;;
    esac
    [ -n "${ROUTE_DOMAIN}" ] || continue
    ROUTING_RULES="${ROUTING_RULES}      {\"type\": \"field\", \"domain\": [\"${ROUTE_DOMAIN}\"], \"outboundTag\": \"${ROUTE_TAG}\"},
"
  done < "${ROUTES_FILE}"

  BASE_OUTBOUND_TAG="$(outbound_tag_for_mode "${BASE_OUTBOUND_MODE}")" || fail "基础出站模式无效。"
  ensure_clients_file
  IPV4_CLIENTS=""
  IPV6_CLIENTS=""
  while IFS='|' read -r CLIENT_FAMILY CLIENT_UUID CLIENT_NAME; do
    [ -n "${CLIENT_UUID}" ] || continue
    CLIENT_JSON="{\"id\": \"${CLIENT_UUID}\", \"flow\": \"xtls-rprx-vision\"}"
    case "${CLIENT_FAMILY}" in
      ipv4)
        [ -z "${IPV4_CLIENTS}" ] || IPV4_CLIENTS="${IPV4_CLIENTS},"
        IPV4_CLIENTS="${IPV4_CLIENTS}${CLIENT_JSON}"
        ;;
      ipv6)
        [ -z "${IPV6_CLIENTS}" ] || IPV6_CLIENTS="${IPV6_CLIENTS},"
        IPV6_CLIENTS="${IPV6_CLIENTS}${CLIENT_JSON}"
        ;;
    esac
  done < "${CLIENTS_FILE}"

  mkdir -p "${CONFIG_DIR}"
  cat > "${CONFIG_FILE}" <<CONFIG
{
  "log": {"loglevel": "warning"},
  "dns": {
    "servers": ["localhost", "1.1.1.1"],
    "queryStrategy": "UseIP"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${IPV4_PORT},
      "protocol": "vless",
      "tag": "vless-in-ipv4",
      "settings": {
        "clients": [${IPV4_CLIENTS}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    },
    {
      "listen": "::",
      "port": ${IPV6_PORT},
      "protocol": "vless",
      "tag": "vless-in-ipv6",
      "settings": {
        "clients": [${IPV6_CLIENTS}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct-ipv4", "settings": {"domainStrategy": "UseIPv4"}},
    {"protocol": "freedom", "tag": "direct-ipv6", "settings": {"domainStrategy": "UseIPv6"}},
    {"protocol": "freedom", "tag": "direct-ipv4v6", "settings": {"domainStrategy": "UseIPv4v6"}},
    {"protocol": "freedom", "tag": "direct-ipv6v4", "settings": {"domainStrategy": "UseIPv6v4"}},
    {"protocol": "freedom", "tag": "direct-happy-ipv4v6", "settings": {"domainStrategy": "UseIPv4v6"}, "streamSettings": {"sockopt": {"happyEyeballs": {"tryDelayMs": ${HAPPY_EYEBALLS_DELAY_MS}, "prioritizeIPv6": false}}}},
    {"protocol": "freedom", "tag": "direct-happy-ipv6v4", "settings": {"domainStrategy": "UseIPv6v4"}, "streamSettings": {"sockopt": {"happyEyeballs": {"tryDelayMs": ${HAPPY_EYEBALLS_DELAY_MS}, "prioritizeIPv6": true}}}},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
${ROUTING_RULES}      {"type": "field", "inboundTag": ["vless-in-ipv4", "vless-in-ipv6"], "outboundTag": "${BASE_OUTBOUND_TAG}"}
    ]
  }
}
CONFIG
  chmod 0600 "${CONFIG_FILE}"
  info "Xray 配置文件已写入。"
}

test_config() {
  TEST_OUTPUT="$(mktemp /tmp/vvr-xray-test.XXXXXX)"
  if ! XRAY_LOCATION_ASSET="${XRAY_DIR}" "${XRAY_BIN}" run -test -config "${CONFIG_FILE}" >"${TEST_OUTPUT}" 2>&1; then
    cat "${TEST_OUTPUT}" >&2
    rm -f "${TEST_OUTPUT}"
    return 1
  fi
  rm -f "${TEST_OUTPUT}"
  return 0
}

save_state() {
  cat > "${META_FILE}" <<STATE
IPV4_PORT='${IPV4_PORT}'
IPV6_PORT='${IPV6_PORT}'
SNI='${SNI}'
DEST='${DEST}'
PRIVATE_KEY='${PRIVATE_KEY}'
PUBLIC_KEY='${PUBLIC_KEY}'
SHORT_ID='${SHORT_ID}'
SERVER_IPV4='${SERVER_IPV4:-}'
SERVER_IPV6='${SERVER_IPV6:-}'
BASE_OUTBOUND_MODE='${BASE_OUTBOUND_MODE}'
HAPPY_EYEBALLS_DELAY_MS='${HAPPY_EYEBALLS_DELAY_MS}'
FINGERPRINT='${FINGERPRINT}'
SPIDERX='${SPIDERX}'
STATE
  chmod 0600 "${META_FILE}"
}

load_state() {
  [ -f "${META_FILE}" ] || fail "未找到节点信息文件：${META_FILE}。请重新运行安装脚本。"
  # shellcheck disable=SC1090
  . "${META_FILE}"
  DEST="${DEST:-${SNI}:443}"
  IPV4_PORT="${IPV4_PORT:-${DEFAULT_IPV4_PORT}}"
  IPV6_PORT="${IPV6_PORT:-${DEFAULT_IPV6_PORT}}"
  BASE_OUTBOUND_MODE="${BASE_OUTBOUND_MODE:-${DEFAULT_BASE_OUTBOUND_MODE}}"
  HAPPY_EYEBALLS_DELAY_MS="${HAPPY_EYEBALLS_DELAY_MS:-${DEFAULT_HAPPY_EYEBALLS_DELAY_MS}}"
  SERVER_IPV4="${SERVER_IPV4:-}"
  SERVER_IPV6="${SERVER_IPV6:-}"
  FINGERPRINT="${FINGERPRINT:-chrome}"
  SPIDERX="${SPIDERX:-%2F}"
  ensure_clients_file
}

write_openrc_service() {
  info "写入 OpenRC 服务..."
  cat > "${SERVICE_FILE}" <<SERVICE
#!/sbin/openrc-run

name="xray"
description="Xray VLESS REALITY IPv4/IPv6 service"
command="${XRAY_BIN}"
command_args="run -config ${CONFIG_FILE}"
command_background="yes"
pidfile="/run/xray.pid"
output_log="${LOG_FILE}"
error_log="${ERR_LOG_FILE}"
export XRAY_LOCATION_ASSET="${XRAY_DIR}"

depend() {
    need net
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
SERVICE
  chmod 0755 "${SERVICE_FILE}"
}

start_service() {
  info "启用并启动 Xray..."
  rc-update add xray default >/dev/null 2>&1 || true
  if ! rc-service xray restart; then
    tail -40 "${ERR_LOG_FILE}" 2>/dev/null || tail -40 "${LOG_FILE}" 2>/dev/null || true
    fail "Xray 服务启动失败。"
  fi
  sleep 2
  rc-service xray status >/dev/null 2>&1 || fail "Xray 服务状态异常。"
  ok "Xray 服务已启动。"
}

valid_manager_source() {
  [ -f "$1" ] && sh -n "$1" >/dev/null 2>&1 && grep -Fq 'manager_main() {' "$1"
}

fetch_manager_source() {
  FETCH_TARGET="$1"
  INSTALLER_URL="${VVR_INSTALLER_URL:-${DEFAULT_INSTALLER_URL}}"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 "${INSTALLER_URL}" -o "${FETCH_TARGET}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${FETCH_TARGET}" "${INSTALLER_URL}"
  else
    return 1
  fi
}

install_manager() {
  SCRIPT_NAME="${0##*/}"
  case "$0" in */*) SCRIPT_PARENT="${0%/*}" ;; *) SCRIPT_PARENT="." ;; esac
  SCRIPT_DIR="$(cd "${SCRIPT_PARENT}" 2>/dev/null && pwd || true)"
  SCRIPT_PATH=""
  [ -z "${SCRIPT_DIR}" ] || SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
  if ! valid_manager_source "${SCRIPT_PATH}"; then
    SCRIPT_PATH="${TMP_DIR}/vvr-manager-source.sh"
    info "当前安装方式没有可复用的脚本文件，正在获取 vvr 管理程序..."
    if ! fetch_manager_source "${SCRIPT_PATH}" || ! valid_manager_source "${SCRIPT_PATH}"; then
      fail "无法获取有效的 vvr 管理程序；可通过 VVR_INSTALLER_URL 指定脚本地址。"
    fi
  fi
  install -m 0755 "${SCRIPT_PATH}" "${MANAGER_BIN}"
}

make_uri() {
  URI_FAMILY="$1"
  URI_UUID="$2"
  URI_NAME="$3"
  case "${URI_FAMILY}" in
    ipv4)
      URI_PORT="${IPV4_PORT}"
      if [ -n "${SERVER_IPV4}" ]; then URI_HOST="${SERVER_IPV4}"; else URI_HOST="你的服务器IPv4地址"; fi
      ;;
    ipv6)
      URI_PORT="${IPV6_PORT}"
      if [ -n "${SERVER_IPV6}" ]; then URI_HOST="[${SERVER_IPV6}]"; else URI_HOST="[你的服务器IPv6地址]"; fi
      ;;
    *) return 1 ;;
  esac
  URI="vless://${URI_UUID}@${URI_HOST}:${URI_PORT}?type=tcp&encryption=none&security=reality&pbk=${PUBLIC_KEY}&fp=${FINGERPRINT}&sni=${SNI}&sid=${SHORT_ID}&spx=${SPIDERX}&flow=xtls-rprx-vision#${URI_NAME}"
}

show_clients() {
  load_state
  echo
  echo "节点配置："
  echo "  IPv4 入站：0.0.0.0:${IPV4_PORT}（公网地址：$(ipv4_display)）"
  echo "  IPv6 入站：[::]:${IPV6_PORT}（公网地址：$(ipv6_display)）"
  echo "  SNI：${SNI}"
  echo "  基础出站：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")"
  echo
  echo "客户端链接："
  NUMBER=0
  while IFS='|' read -r CLIENT_FAMILY CLIENT_UUID CLIENT_NAME; do
    [ -n "${CLIENT_UUID}" ] || continue
    NUMBER=$((NUMBER + 1))
    make_uri "${CLIENT_FAMILY}" "${CLIENT_UUID}" "${CLIENT_NAME}"
    printf '%s. [%s] %s\n%s\n\n' "${NUMBER}" "${CLIENT_FAMILY}" "${CLIENT_NAME}" "${URI}"
  done < "${CLIENTS_FILE}"
  [ "${NUMBER}" -gt 0 ] || echo "（暂无客户端）"
}

restore_pending_routes() {
  if [ -n "${PENDING_ROUTES_BACKUP:-}" ] && [ -f "${PENDING_ROUTES_BACKUP}" ]; then
    cp -a "${PENDING_ROUTES_BACKUP}" "${ROUTES_FILE}"
    rm -f "${PENDING_ROUTES_BACKUP}"
  fi
  PENDING_ROUTES_BACKUP=""
}

discard_pending_routes_backup() {
  if [ -n "${PENDING_ROUTES_BACKUP:-}" ] && [ -f "${PENDING_ROUTES_BACKUP}" ]; then
    rm -f "${PENDING_ROUTES_BACKUP}"
  fi
  PENDING_ROUTES_BACKUP=""
}

backup_routes_for_change() {
  ensure_routes_file
  PENDING_ROUTES_BACKUP="$(mktemp /tmp/vvr-routes.XXXXXX)"
  cp -a "${ROUTES_FILE}" "${PENDING_ROUTES_BACKUP}"
}

restore_pending_clients() {
  if [ -n "${PENDING_CLIENTS_BACKUP:-}" ] && [ -f "${PENDING_CLIENTS_BACKUP}" ]; then
    cp -a "${PENDING_CLIENTS_BACKUP}" "${CLIENTS_FILE}"
    rm -f "${PENDING_CLIENTS_BACKUP}"
  fi
  PENDING_CLIENTS_BACKUP=""
}

discard_pending_clients_backup() {
  if [ -n "${PENDING_CLIENTS_BACKUP:-}" ] && [ -f "${PENDING_CLIENTS_BACKUP}" ]; then
    rm -f "${PENDING_CLIENTS_BACKUP}"
  fi
  PENDING_CLIENTS_BACKUP=""
}

backup_clients_for_change() {
  ensure_clients_file
  PENDING_CLIENTS_BACKUP="$(mktemp /tmp/vvr-clients.XXXXXX)"
  cp -a "${CLIENTS_FILE}" "${PENDING_CLIENTS_BACKUP}"
}

apply_config() {
  CONFIG_BACKUP="$(mktemp /tmp/vvr-config.XXXXXX)"
  if [ -f "${CONFIG_FILE}" ]; then cp -a "${CONFIG_FILE}" "${CONFIG_BACKUP}"; else : > "${CONFIG_BACKUP}"; fi

  write_config
  if ! test_config; then
    cp -a "${CONFIG_BACKUP}" "${CONFIG_FILE}"
    restore_pending_routes
    restore_pending_clients
    rm -f "${CONFIG_BACKUP}"
    warn "新配置检查失败，已恢复旧配置。"
    return 1
  fi
  if ! rc-service xray restart; then
    cp -a "${CONFIG_BACKUP}" "${CONFIG_FILE}"
    restore_pending_routes
    restore_pending_clients
    rc-service xray restart >/dev/null 2>&1 || true
    rm -f "${CONFIG_BACKUP}"
    warn "Xray 重启失败，已恢复旧配置。"
    return 1
  fi
  sleep 1
  if ! rc-service xray status >/dev/null 2>&1; then
    cp -a "${CONFIG_BACKUP}" "${CONFIG_FILE}"
    restore_pending_routes
    restore_pending_clients
    rc-service xray restart >/dev/null 2>&1 || true
    rm -f "${CONFIG_BACKUP}"
    warn "Xray 状态异常，已恢复旧配置。"
    return 1
  fi
  rm -f "${CONFIG_BACKUP}"
  discard_pending_routes_backup
  discard_pending_clients_backup
  save_state
  ok "配置已应用。"
  return 0
}

refresh_network() {
  load_state
  info "检测 IPv4 / IPv6 连通性..."
  detect_network
  save_state
  echo "IPv4：$(ipv4_display)"
  echo "IPv6：$(ipv6_display)"
}

modify_ports() {
  load_state
  OLD_IPV4_PORT="${IPV4_PORT}"
  OLD_IPV6_PORT="${IPV6_PORT}"
  while :; do
    prompt_port_value "IPv4 " "${IPV4_PORT}"
    IPV4_PORT="${SELECTED_PORT}"
    if check_port_available "${IPV4_PORT}" "${OLD_IPV4_PORT}"; then break; fi
    echo "端口 ${IPV4_PORT} 已被占用，请重新输入。"
    IPV4_PORT="${OLD_IPV4_PORT}"
  done
  while :; do
    prompt_port_value "IPv6 " "${IPV6_PORT}"
    IPV6_PORT="${SELECTED_PORT}"
    [ "${IPV6_PORT}" != "${IPV4_PORT}" ] || { echo "IPv4 与 IPv6 入站请使用不同端口。"; IPV6_PORT="${OLD_IPV6_PORT}"; continue; }
    if check_port_available "${IPV6_PORT}" "${OLD_IPV6_PORT}"; then break; fi
    echo "端口 ${IPV6_PORT} 已被占用，请重新输入。"
    IPV6_PORT="${OLD_IPV6_PORT}"
  done
  apply_config && show_clients
}

modify_sni() {
  load_state
  prompt_sni "${SNI}"
  apply_config && show_clients
}

choose_client_family() {
  while :; do
    echo "  1. IPv4 入站（端口 ${IPV4_PORT}）"
    echo "  2. IPv6 入站（端口 ${IPV6_PORT}）"
    echo "  0. 返回"
    printf '选择客户端所属入站: '
    read -r INPUT
    case "${INPUT}" in
      1) CLIENT_FAMILY="ipv4"; return 0 ;;
      2) CLIENT_FAMILY="ipv6"; return 0 ;;
      0) return 1 ;;
      *) echo "无效选择。" ;;
    esac
  done
}

add_client() {
  load_state
  choose_client_family || return
  while :; do
    prompt_tag ""
    CLIENT_NAME="${TAG}"
    if client_name_exists "${CLIENT_FAMILY}" "${CLIENT_NAME}"; then
      echo "${CLIENT_FAMILY} 入站中已存在同名客户端，请换一个名称。"
      continue
    fi
    break
  done
  generate_uuid
  backup_clients_for_change
  printf '%s|%s|%s\n' "${CLIENT_FAMILY}" "${UUID}" "${CLIENT_NAME}" >> "${CLIENTS_FILE}"
  chmod 0600 "${CLIENTS_FILE}"
  if apply_config; then
    make_uri "${CLIENT_FAMILY}" "${UUID}" "${CLIENT_NAME}"
    ok "客户端已添加。"
    echo "${URI}"
  fi
}

delete_client() {
  load_state
  echo
  echo "编号  入站   客户端名称"
  NUMBER=0
  while IFS='|' read -r CLIENT_FAMILY CLIENT_UUID CLIENT_NAME; do
    [ -n "${CLIENT_UUID}" ] || continue
    NUMBER=$((NUMBER + 1))
    printf '%-4s  %-6s %s\n' "${NUMBER}" "${CLIENT_FAMILY}" "${CLIENT_NAME}"
  done < "${CLIENTS_FILE}"
  [ "${NUMBER}" -gt 0 ] || { echo "（暂无客户端）"; return; }
  while :; do
    printf '输入要删除的客户端编号（0 取消）: '
    read -r INPUT
    case "${INPUT}" in
      0) return ;;
      ''|*[!0-9]*) echo "请输入有效编号。" ;;
      *) [ "${INPUT}" -le "${NUMBER}" ] && break; echo "编号超出范围。" ;;
    esac
  done
  backup_clients_for_change
  TEMP_CLIENTS="$(mktemp /tmp/vvr-clients-new.XXXXXX)"
  awk -F '|' -v target="${INPUT}" 'NF {count++} count != target {print}' "${CLIENTS_FILE}" > "${TEMP_CLIENTS}"
  mv "${TEMP_CLIENTS}" "${CLIENTS_FILE}"
  chmod 0600 "${CLIENTS_FILE}"
  apply_config || true
}

manage_clients() {
  while :; do
    load_state
    echo
    echo "=============================="
    echo " 多客户端管理"
    echo "=============================="
    echo " IPv4 客户端：$(client_count ipv4) 个"
    echo " IPv6 客户端：$(client_count ipv6) 个"
    echo " 1. 查看全部客户端链接"
    echo " 2. 添加客户端"
    echo " 3. 删除客户端"
    echo " 0. 返回主菜单"
    printf '请选择操作: '
    read -r CHOICE
    case "${CHOICE}" in
      1) show_clients ;;
      2) add_client ;;
      3) delete_client ;;
      0) return ;;
      *) echo "无效选择。" ;;
    esac
    echo
    printf '按回车继续...'
    read -r _
  done
}

list_rules() {
  load_state
  ensure_routes_file
  echo
  echo "基础出站：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")"
  echo "规则文件：${ROUTES_FILE}"
  echo "编号  出站模式                 规则"
  NUMBER=0
  while IFS='|' read -r ROUTE_MODE ROUTE_TYPE ROUTE_VALUE; do
    [ -n "${ROUTE_MODE}" ] || continue
    NUMBER=$((NUMBER + 1))
    case "${ROUTE_TYPE}" in
      domain) DISPLAY_RULE="${ROUTE_VALUE}" ;;
      geosite) DISPLAY_RULE="geosite:${ROUTE_VALUE}" ;;
      *) DISPLAY_RULE="无效：${ROUTE_TYPE}|${ROUTE_VALUE}" ;;
    esac
    printf '%-4s  %-24s %s\n' "${NUMBER}" "$(outbound_mode_label "${ROUTE_MODE}")" "${DISPLAY_RULE}"
  done < "${ROUTES_FILE}"
  [ "${NUMBER}" -gt 0 ] || echo "（暂无域名规则）"
}

add_domain_rule() {
  load_state
  echo "选择此规则使用的出站模式："
  choose_outbound_mode "${BASE_OUTBOUND_MODE}"
  confirm_outbound_availability "${SELECTED_OUTBOUND_MODE}" || return
  while :; do
    echo "  1. 精确匹配，例如 api.example.com"
    echo "  2. 后缀匹配，例如 example.com 及其子域名"
    echo "  0. 返回"
    printf '选择匹配类型 [1]: '
    read -r INPUT
    case "${INPUT:-1}" in
      1) DOMAIN_PREFIX="full"; break ;;
      2) DOMAIN_PREFIX="domain"; break ;;
      0) return ;;
      *) echo "无效选择。" ;;
    esac
  done
  while :; do
    printf '输入域名（输入 0 返回）: '
    read -r DOMAIN
    case "${DOMAIN}" in
      0) return ;;
      ''|*[!A-Za-z0-9.-]*) echo "域名格式无效。" ;;
      *) break ;;
    esac
  done
  backup_routes_for_change
  printf '%s|domain|%s:%s\n' "${SELECTED_OUTBOUND_MODE}" "${DOMAIN_PREFIX}" "${DOMAIN}" >> "${ROUTES_FILE}"
  apply_config || true
}

add_geosite_rule() {
  load_state
  echo "选择此规则使用的出站模式："
  choose_outbound_mode "${BASE_OUTBOUND_MODE}"
  confirm_outbound_availability "${SELECTED_OUTBOUND_MODE}" || return
  while :; do
    printf '输入 geosite 名称，例如 youtube（输入 0 返回）: '
    read -r GEOSITE
    case "${GEOSITE}" in
      0) return ;;
      ''|*[!A-Za-z0-9._@!:-]*) echo "geosite 名称格式无效。" ;;
      *) break ;;
    esac
  done
  backup_routes_for_change
  printf '%s|geosite|%s\n' "${SELECTED_OUTBOUND_MODE}" "${GEOSITE}" >> "${ROUTES_FILE}"
  apply_config || true
}

delete_rule() {
  ensure_routes_file
  list_rules
  COUNT="$(awk 'NF {count++} END {print count+0}' "${ROUTES_FILE}")"
  [ "${COUNT}" -gt 0 ] || return
  while :; do
    printf '输入要删除的规则编号（0 取消）: '
    read -r INPUT
    case "${INPUT}" in
      0) return ;;
      ''|*[!0-9]*) echo "请输入有效编号。" ;;
      *)
        if [ "${INPUT}" -ge 1 ] && [ "${INPUT}" -le "${COUNT}" ]; then break; fi
        echo "编号超出范围。"
        ;;
    esac
  done
  backup_routes_for_change
  TEMP_RULES="$(mktemp /tmp/vvr-rules-new.XXXXXX)"
  awk -v target="${INPUT}" 'NF {count++} count != target {print}' "${ROUTES_FILE}" > "${TEMP_RULES}"
  mv "${TEMP_RULES}" "${ROUTES_FILE}"
  chmod 0600 "${ROUTES_FILE}"
  apply_config || true
}

set_base_outbound_mode() {
  load_state
  detect_network
  echo "当前基础出站：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")"
  choose_outbound_mode "${BASE_OUTBOUND_MODE}"
  confirm_outbound_availability "${SELECTED_OUTBOUND_MODE}" || return
  [ "${SELECTED_OUTBOUND_MODE}" != "${BASE_OUTBOUND_MODE}" ] || { echo "基础出站未改变。"; return; }
  BASE_OUTBOUND_MODE="${SELECTED_OUTBOUND_MODE}"
  apply_config || true
}

set_happy_eyeballs_delay() {
  load_state
  while :; do
    printf '连接竞速延迟（25-2000 毫秒）[%s]: ' "${HAPPY_EYEBALLS_DELAY_MS}"
    read -r INPUT
    INPUT="${INPUT:-${HAPPY_EYEBALLS_DELAY_MS}}"
    case "${INPUT}" in ''|*[!0-9]*) echo "请输入整数。"; continue ;; esac
    if [ "${INPUT}" -ge 25 ] && [ "${INPUT}" -le 2000 ]; then break; fi
    echo "延迟必须在 25 到 2000 毫秒之间。"
  done
  HAPPY_EYEBALLS_DELAY_MS="${INPUT}"
  apply_config || true
}

manage_outbound() {
  load_state
  info "刷新 IPv4 / IPv6 状态..."
  detect_network
  save_state
  while :; do
    load_state
    echo
    echo "=============================="
    echo " IPv4 / IPv6 出站与域名规则"
    echo "=============================="
    echo " 当前基础出站：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")"
    echo " Happy Eyeballs 延迟：${HAPPY_EYEBALLS_DELAY_MS}ms"
    echo " 1. 设置基础出站模式"
    echo " 2. 查看全部域名规则"
    echo " 3. 添加域名规则"
    echo " 4. 添加 geosite 规则"
    echo " 5. 删除规则"
    echo " 6. 刷新 IPv4 / IPv6 状态"
    echo " 7. 设置连接竞速延迟"
    echo " 0. 返回主菜单"
    printf '请选择操作: '
    read -r CHOICE
    case "${CHOICE}" in
      1) set_base_outbound_mode ;;
      2) list_rules ;;
      3) add_domain_rule ;;
      4) add_geosite_rule ;;
      5) delete_rule ;;
      6) refresh_network ;;
      7) set_happy_eyeballs_delay ;;
      0) return ;;
      *) echo "无效选择。" ;;
    esac
    echo
    printf '按回车继续...'
    read -r _
  done
}

restart_xray() {
  load_state
  test_config || fail "Xray 配置检查失败。"
  rc-service xray restart
  rc-service xray status >/dev/null 2>&1 || fail "Xray 服务状态异常。"
  ok "Xray 已重启。"
}

regenerate_reality() {
  load_state
  warn "将重新生成 REALITY 密钥和 shortId，所有现有客户端链接都需要更新。"
  printf '确认重置 REALITY 参数？[y/N]: '
  read -r ANSWER
  case "${ANSWER}" in y|Y|yes|YES) ;; *) return ;; esac
  generate_reality_values
  apply_config && show_clients
}

show_logs() {
  echo "错误日志：${ERR_LOG_FILE}"
  tail -80 "${ERR_LOG_FILE}" 2>/dev/null || echo "暂无错误日志。"
  echo
  echo "运行日志：${LOG_FILE}"
  tail -80 "${LOG_FILE}" 2>/dev/null || echo "暂无运行日志。"
}

uninstall_xray() {
  warn "即将卸载 Xray，并删除配置、规则、日志和 vvr 管理命令。"
  printf '确认卸载？此操作不可恢复。[y/N]: '
  read -r ANSWER
  case "${ANSWER}" in y|Y|yes|YES) ;; *) return ;; esac
  rc-service xray stop >/dev/null 2>&1 || true
  rc-update del xray default >/dev/null 2>&1 || true
  rm -f "${SERVICE_FILE}" "${LOG_FILE}" "${ERR_LOG_FILE}" "${MANAGER_BIN}"
  rm -rf "${CONFIG_DIR}" "${XRAY_DIR}"
  ok "已卸载完成。"
  exit 0
}

manager_menu() {
  load_state
  clear 2>/dev/null || true
  echo "=============================="
  echo " VLESS + REALITY 双入站多客户端管理"
  echo "=============================="
  echo " 1. 查看全部客户端链接与配置"
  echo " 2. 管理客户端（添加/删除）"
  echo " 3. 修改 REALITY SNI"
  echo " 4. 修改 IPv4/IPv6 入站端口"
  echo " 5. 管理 IPv4/IPv6 出站与域名规则"
  echo " 6. 刷新公网 IPv4/IPv6 地址"
  echo " 7. 重启 Xray"
  echo " 8. 查看服务状态"
  echo " 9. 查看日志"
  echo "10. 重置 REALITY 密钥"
  echo "11. 卸载并清理环境"
  echo " 0. 退出"
  printf '请选择操作: '
}

manager_main() {
  need_root
  need_alpine
  while :; do
    manager_menu
    read -r CHOICE
    case "${CHOICE}" in
      1) show_clients ;;
      2) manage_clients ;;
      3) modify_sni ;;
      4) modify_ports ;;
      5) manage_outbound ;;
      6) refresh_network ;;
      7) restart_xray ;;
      8) rc-service xray status || true ;;
      9) show_logs ;;
      10) regenerate_reality ;;
      11) uninstall_xray ;;
      0) exit 0 ;;
      *) echo "无效选择。" ;;
    esac
    case "${CHOICE}" in
      2|5) ;;
      *) echo; printf '按回车返回菜单...'; read -r _ ;;
    esac
  done
}

print_result() {
  echo
  ok "Xray VLESS + REALITY IPv4/IPv6 双入站多客户端节点安装完成。"
  echo "配置文件：${CONFIG_FILE}"
  echo "客户端文件：${CLIENTS_FILE}"
  echo "规则文件：${ROUTES_FILE}"
  echo "管理菜单：vvr"
  echo "IPv4 入站：0.0.0.0:${IPV4_PORT}"
  echo "IPv6 入站：[::]:${IPV6_PORT}"
  echo "基础出站：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")"
  show_clients
  echo "请在防火墙和云安全组中放行 TCP ${IPV4_PORT} 和 ${IPV6_PORT}。"
  echo "IPv6 客户端所在网络必须支持 IPv6。"
}

installer_main() {
  need_root
  need_alpine
  trap installer_exit 0
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  if ! ensure_low_mem_swap; then
    warn "无法自动启用 Swap，将继续采用分批安装；如果仍出现 Killed，请在宿主机提高内存限制。"
  fi
  install_deps
  detect_arch
  prepare_tmp
  detect_network

  prompt_port_value "IPv4 " "${DEFAULT_IPV4_PORT}"
  IPV4_PORT="${SELECTED_PORT}"
  while :; do
    prompt_port_value "IPv6 " "${DEFAULT_IPV6_PORT}"
    IPV6_PORT="${SELECTED_PORT}"
    [ "${IPV6_PORT}" != "${IPV4_PORT}" ] && break
    echo "IPv4 与 IPv6 入站请使用不同端口。"
  done
  prompt_sni "${DEFAULT_SNI}"
  prompt_tag "vvr-ipv4"
  IPV4_CLIENT_NAME="${TAG}"
  prompt_tag "vvr-ipv6"
  IPV6_CLIENT_NAME="${TAG}"
  BASE_OUTBOUND_MODE="${DEFAULT_BASE_OUTBOUND_MODE}"
  HAPPY_EYEBALLS_DELAY_MS="${DEFAULT_HAPPY_EYEBALLS_DELAY_MS}"
  [ -n "${SERVER_IPV4}" ] || warn "未检测到公网 IPv4，IPv4 链接将使用占位地址。"
  [ -n "${SERVER_IPV6}" ] || warn "未检测到公网 IPv6，IPv6 链接将使用占位地址。"
  prompt_base_outbound_mode
  confirm_inputs

  handle_existing_install
  download_xray
  prepare_for_replacement
  check_port_available "${IPV4_PORT}" "" || fail "端口 ${IPV4_PORT} 已被占用。"
  check_port_available "${IPV6_PORT}" "" || fail "端口 ${IPV6_PORT} 已被占用。"
  install_xray
  generate_uuid
  IPV4_UUID="${UUID}"
  generate_uuid
  IPV6_UUID="${UUID}"
  generate_reality_values
  initialize_routes_file
  initialize_clients_file
  write_config
  info "检查 Xray 配置..."
  test_config || fail "Xray 配置检查失败。"
  write_openrc_service
  start_service
  save_state
  install_manager
  INSTALL_COMMITTED="1"
  print_result
}

case "$(basename "$0")" in
  vvr) manager_main "$@" ;;
  *)
    case "${1:-}" in
      '') installer_main ;;
      --manage) manager_main ;;
      *)
        echo "用法：$0 [--manage]" >&2
        exit 2
        ;;
    esac
    ;;
esac
