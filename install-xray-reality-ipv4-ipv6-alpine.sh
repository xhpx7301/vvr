#!/usr/bin/env sh
set -eu

# Alpine installer and manager for VLESS + REALITY with IPv4/IPv6 routing.

XRAY_DIR="/usr/local/xray"
XRAY_BIN="${XRAY_DIR}/xray"
CONFIG_DIR="/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
META_FILE="${CONFIG_DIR}/vless-reality-ip.env"
ROUTES_FILE="${CONFIG_DIR}/vvr-routing.rules"
SERVICE_FILE="/etc/init.d/xray"
LOG_FILE="/var/log/xray.log"
ERR_LOG_FILE="/var/log/xray.err"
MANAGER_BIN="/usr/local/bin/vvr"

DEFAULT_PORT="443"
DEFAULT_SNI="www.sony.com"
DEFAULT_BASE_OUTBOUND_MODE="ipv4"
DEFAULT_INBOUND_MODE="ipv4"
DEFAULT_HAPPY_EYEBALLS_DELAY_MS="100"
DEFAULT_INSTALLER_URL="https://raw.githubusercontent.com/xhpx7301/vvr/main/install-xray-reality-ipv4-ipv6-alpine.sh"
FINGERPRINT="chrome"
SPIDERX="%2F"
TMP_DIR=""

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

need_root() {
  [ "$(id -u)" -eq 0 ] || fail "请使用 root 运行此脚本。"
}

need_alpine() {
  [ -f /etc/alpine-release ] || fail "此脚本仅支持 Alpine Linux。"
  command -v rc-service >/dev/null 2>&1 || fail "未找到 OpenRC。"
}

install_deps() {
  info "安装依赖..."
  apk update
  apk add --no-cache ca-certificates curl wget unzip openssl iproute2
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
  TMP_DIR="$(mktemp -d /tmp/xray-install.XXXXXX)"
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

prompt_port() {
  CURRENT_PORT="${1:-${DEFAULT_PORT}}"
  while :; do
    printf '监听端口 [%s]: ' "${CURRENT_PORT}"
    read -r INPUT
    PORT="${INPUT:-${CURRENT_PORT}}"
    case "${PORT}" in
      ''|*[!0-9]*) echo "端口必须是 1 到 65535 之间的数字。"; continue ;;
    esac
    if [ "${PORT}" -ge 1 ] && [ "${PORT}" -le 65535 ]; then break; fi
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

prompt_inbound_mode() {
  DEFAULT_CHOICE="1"
  [ "${INBOUND_MODE:-${DEFAULT_INBOUND_MODE}}" = "ipv6" ] && DEFAULT_CHOICE="2"
  while :; do
    echo
    echo "节点入站地址族（客户端连接服务器使用的协议）："
    echo "  1. IPv4：$(ipv4_display)（监听 0.0.0.0）"
    echo "  2. IPv6：$(ipv6_display)（监听 ::）"
    printf '选择节点入站 [%s]: ' "${DEFAULT_CHOICE}"
    read -r INPUT
    case "${INPUT:-${DEFAULT_CHOICE}}" in
      1) NEXT_INBOUND_MODE="ipv4" ;;
      2) NEXT_INBOUND_MODE="ipv6" ;;
      *) echo "无效选择，请输入 1 或 2。"; continue ;;
    esac

    if [ "${NEXT_INBOUND_MODE}" = "ipv4" ] && [ -z "${SERVER_IPV4}" ]; then
      warn "当前检测不到 IPv4；生成的 IPv4 节点链接可能无法连接。"
      printf '仍要继续吗？[y/N]: '
      read -r ANSWER
      case "${ANSWER}" in y|Y|yes|YES) ;; *) continue ;; esac
    fi
    if [ "${NEXT_INBOUND_MODE}" = "ipv6" ] && [ -z "${SERVER_IPV6}" ]; then
      warn "当前检测不到 IPv6；生成的 IPv6 节点链接可能无法连接。"
      printf '仍要继续吗？[y/N]: '
      read -r ANSWER
      case "${ANSWER}" in y|Y|yes|YES) ;; *) continue ;; esac
    fi
    INBOUND_MODE="${NEXT_INBOUND_MODE}"
    return
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
  echo "  监听端口：${PORT}"
  echo "  SNI：${SNI}"
  echo "  节点名称：${TAG}"
  echo "  节点入站：${INBOUND_MODE}"
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
    printf '是否停止旧服务并替换现有配置？[y/N]: '
    read -r ANSWER
    case "${ANSWER}" in
      y|Y|yes|YES)
        rc-service xray stop >/dev/null 2>&1 || true
        if [ -f "${CONFIG_FILE}" ]; then
          BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
          cp -a "${CONFIG_FILE}" "${BACKUP_FILE}"
          info "旧配置已备份到 ${BACKUP_FILE}"
        fi
        ;;
      *) fail "已取消，未覆盖现有安装。" ;;
    esac
  fi
}

check_port_available() {
  OLD_PORT="${1:-}"
  if [ "${PORT}" != "${OLD_PORT}" ] && command -v ss >/dev/null 2>&1 && \
     ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${PORT}$"; then
    return 1
  fi
  return 0
}

download_xray() {
  info "下载 Xray-core (${ARCH})..."
  wget -q --show-progress -O "${TMP_DIR}/${XRAY_ZIP}" "${XRAY_URL}"
  mkdir -p "${TMP_DIR}/extract"
  unzip -qo "${TMP_DIR}/${XRAY_ZIP}" -d "${TMP_DIR}/extract"
  [ -f "${TMP_DIR}/extract/xray" ] || fail "安装包中没有 Xray 可执行文件。"
}

install_xray() {
  info "安装 Xray 和规则资源..."
  mkdir -p "${XRAY_DIR}" "${CONFIG_DIR}"
  install -m 0755 "${TMP_DIR}/extract/xray" "${XRAY_BIN}"
  for ASSET in geoip.dat geosite.dat; do
    if [ -f "${TMP_DIR}/extract/${ASSET}" ]; then
      install -m 0644 "${TMP_DIR}/extract/${ASSET}" "${XRAY_DIR}/${ASSET}"
    fi
  done
  [ -f "${XRAY_DIR}/geosite.dat" ] || fail "安装包中没有 geosite.dat，无法使用 geosite 域名规则。"
}

generate_values() {
  info "生成 UUID、REALITY 密钥和 shortId..."
  UUID="$("${XRAY_BIN}" uuid)"
  KEYS="$("${XRAY_BIN}" x25519 2>&1)"
  PRIVATE_KEY="$(printf '%s\n' "${KEYS}" | awk '{line=tolower($0); if (line ~ /private/ && line ~ /key/) {sub(/.*[:=][ \t]*/, "", $0); gsub(/[",]/, "", $0); print $1; exit}}')"
  PUBLIC_KEY="$(printf '%s\n' "${KEYS}" | awk '{line=tolower($0); if (line ~ /public/ && line ~ /key/) {sub(/.*[:=][ \t]*/, "", $0); gsub(/[",]/, "", $0); print $1; exit}}')"
  SHORT_ID="$(openssl rand -hex 8)"
  [ -n "${UUID}" ] || fail "生成 UUID 失败。"
  [ -n "${PRIVATE_KEY}" ] || fail "生成 REALITY 私钥失败。"
  [ -n "${PUBLIC_KEY}" ] || fail "生成 REALITY 公钥失败。"
  [ -n "${SHORT_ID}" ] || fail "生成 shortId 失败。"
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
  case "${INBOUND_MODE}" in
    ipv4) INBOUND_LISTEN="0.0.0.0" ;;
    ipv6) INBOUND_LISTEN="::" ;;
    *) fail "节点入站模式无效。" ;;
  esac

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
      "listen": "${INBOUND_LISTEN}",
      "port": ${PORT},
      "protocol": "vless",
      "tag": "vless-in",
      "settings": {
        "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
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
${ROUTING_RULES}      {"type": "field", "inboundTag": ["vless-in"], "outboundTag": "${BASE_OUTBOUND_TAG}"}
    ]
  }
}
CONFIG
  chmod 0600 "${CONFIG_FILE}"
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
PORT='${PORT}'
SNI='${SNI}'
DEST='${DEST}'
TAG='${TAG}'
UUID='${UUID}'
PRIVATE_KEY='${PRIVATE_KEY}'
PUBLIC_KEY='${PUBLIC_KEY}'
SHORT_ID='${SHORT_ID}'
SERVER_IPV4='${SERVER_IPV4:-}'
SERVER_IPV6='${SERVER_IPV6:-}'
INBOUND_MODE='${INBOUND_MODE}'
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
  INBOUND_MODE="${INBOUND_MODE:-${DEFAULT_INBOUND_MODE}}"
  BASE_OUTBOUND_MODE="${BASE_OUTBOUND_MODE:-${DEFAULT_BASE_OUTBOUND_MODE}}"
  HAPPY_EYEBALLS_DELAY_MS="${HAPPY_EYEBALLS_DELAY_MS:-${DEFAULT_HAPPY_EYEBALLS_DELAY_MS}}"
  SERVER_IPV4="${SERVER_IPV4:-}"
  SERVER_IPV6="${SERVER_IPV6:-}"
  FINGERPRINT="${FINGERPRINT:-chrome}"
  SPIDERX="${SPIDERX:-%2F}"
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
  case "${INBOUND_MODE}" in
    ipv6)
      if [ -n "${SERVER_IPV6}" ]; then URI_HOST="[${SERVER_IPV6}]"; else URI_HOST="[你的服务器IPv6地址]"; fi
      ;;
    *)
      if [ -n "${SERVER_IPV4}" ]; then URI_HOST="${SERVER_IPV4}"; else URI_HOST="你的服务器IPv4地址"; fi
      ;;
  esac
  URI="vless://${UUID}@${URI_HOST}:${PORT}?type=tcp&encryption=none&security=reality&pbk=${PUBLIC_KEY}&fp=${FINGERPRINT}&sni=${SNI}&sid=${SHORT_ID}&spx=${SPIDERX}&flow=xtls-rprx-vision#${TAG}"
}

show_node() {
  load_state
  make_uri
  echo
  echo "节点信息："
  echo "  服务器：${URI_HOST}"
  echo "  端口：${PORT}"
  echo "  SNI：${SNI}"
  echo "  名称：${TAG}"
  echo "  节点入站：${INBOUND_MODE}"
  echo "  基础出站：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")"
  echo
  echo "客户端链接："
  echo "${URI}"
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

apply_config() {
  CONFIG_BACKUP="$(mktemp /tmp/vvr-config.XXXXXX)"
  if [ -f "${CONFIG_FILE}" ]; then cp -a "${CONFIG_FILE}" "${CONFIG_BACKUP}"; else : > "${CONFIG_BACKUP}"; fi

  write_config
  if ! test_config; then
    cp -a "${CONFIG_BACKUP}" "${CONFIG_FILE}"
    restore_pending_routes
    rm -f "${CONFIG_BACKUP}"
    warn "新配置检查失败，已恢复旧配置。"
    return 1
  fi
  if ! rc-service xray restart; then
    cp -a "${CONFIG_BACKUP}" "${CONFIG_FILE}"
    restore_pending_routes
    rc-service xray restart >/dev/null 2>&1 || true
    rm -f "${CONFIG_BACKUP}"
    warn "Xray 重启失败，已恢复旧配置。"
    return 1
  fi
  sleep 1
  if ! rc-service xray status >/dev/null 2>&1; then
    cp -a "${CONFIG_BACKUP}" "${CONFIG_FILE}"
    restore_pending_routes
    rc-service xray restart >/dev/null 2>&1 || true
    rm -f "${CONFIG_BACKUP}"
    warn "Xray 状态异常，已恢复旧配置。"
    return 1
  fi
  rm -f "${CONFIG_BACKUP}"
  discard_pending_routes_backup
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

modify_port() {
  load_state
  OLD_PORT="${PORT}"
  while :; do
    prompt_port "${PORT}"
    if check_port_available "${OLD_PORT}"; then break; fi
    echo "端口 ${PORT} 已被占用，请重新输入。"
    PORT="${OLD_PORT}"
  done
  apply_config && show_node
}

modify_sni() {
  load_state
  prompt_sni "${SNI}"
  apply_config && show_node
}

modify_tag() {
  load_state
  prompt_tag "${TAG}"
  apply_config && show_node
}

modify_inbound_mode() {
  load_state
  detect_network
  OLD_INBOUND_MODE="${INBOUND_MODE}"
  prompt_inbound_mode
  if [ "${INBOUND_MODE}" = "${OLD_INBOUND_MODE}" ]; then
    echo "节点入站未改变。"
    return
  fi
  warn "切换入站会短暂重启 Xray，旧地址族上的节点入口将不再监听。"
  apply_config && show_node
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

regenerate_values() {
  load_state
  warn "将重新生成 UUID、REALITY 密钥和 shortId，旧客户端链接会失效。"
  printf '确认重置当前节点？[y/N]: '
  read -r ANSWER
  case "${ANSWER}" in y|Y|yes|YES) ;; *) return ;; esac
  generate_values
  apply_config && show_node
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
  echo " VLESS + REALITY Alpine 管理面板"
  echo "=============================="
  echo " 1. 查看节点链接与配置"
  echo " 2. 修改监听端口"
  echo " 3. 修改 REALITY SNI"
  echo " 4. 修改节点名称"
  echo " 5. 切换节点入站 IPv4/IPv6"
  echo " 6. 管理 IPv4/IPv6 出站与域名规则"
  echo " 7. 重启 Xray"
  echo " 8. 查看服务状态"
  echo " 9. 查看日志"
  echo "10. 重置当前节点"
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
      1) show_node ;;
      2) modify_port ;;
      3) modify_sni ;;
      4) modify_tag ;;
      5) modify_inbound_mode ;;
      6) manage_outbound ;;
      7) restart_xray ;;
      8) rc-service xray status || true ;;
      9) show_logs ;;
      10) regenerate_values ;;
      11) uninstall_xray ;;
      0) exit 0 ;;
      *) echo "无效选择。" ;;
    esac
    case "${CHOICE}" in
      6) ;;
      *) echo; printf '按回车返回菜单...'; read -r _ ;;
    esac
  done
}

print_result() {
  make_uri
  echo
  ok "Xray VLESS + REALITY IPv4/IPv6 节点安装完成。"
  echo "配置文件：${CONFIG_FILE}"
  echo "规则文件：${ROUTES_FILE}"
  echo "管理菜单：vvr"
  echo "节点入站：${INBOUND_MODE}"
  echo "基础出站：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")"
  echo
  echo "客户端链接："
  echo "${URI}"
  echo
  echo "请在防火墙和云安全组中放行 TCP ${PORT}。"
  [ "${INBOUND_MODE}" != "ipv6" ] || echo "使用 IPv6 入站时，客户端网络也必须支持 IPv6。"
}

installer_main() {
  need_root
  need_alpine
  trap cleanup 0 INT TERM HUP
  install_deps
  detect_arch
  prepare_tmp
  detect_network

  prompt_port "${DEFAULT_PORT}"
  prompt_sni "${DEFAULT_SNI}"
  prompt_tag ""
  INBOUND_MODE="${DEFAULT_INBOUND_MODE}"
  BASE_OUTBOUND_MODE="${DEFAULT_BASE_OUTBOUND_MODE}"
  HAPPY_EYEBALLS_DELAY_MS="${DEFAULT_HAPPY_EYEBALLS_DELAY_MS}"
  prompt_inbound_mode
  prompt_base_outbound_mode
  confirm_inputs

  handle_existing_install
  check_port_available "" || fail "端口 ${PORT} 已被占用。"
  download_xray
  install_xray
  generate_values
  initialize_routes_file
  write_config
  info "检查 Xray 配置..."
  test_config || fail "Xray 配置检查失败。"
  write_openrc_service
  start_service
  save_state
  install_manager
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
