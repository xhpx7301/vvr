#!/usr/bin/env sh
set -eu

# Debian installer for VLESS + REALITY with IPv4/IPv6 YouTube split routing.

XRAY_BIN="/usr/local/bin/xray"
XRAY_ASSET_DIR="/usr/local/share/xray"
CONFIG_DIR="/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/xray.service"
META_FILE="${CONFIG_DIR}/vless-ipv6-youtube.env"
ROUTES_FILE="${CONFIG_DIR}/vvr-routing.rules"
MANAGER_BIN="/usr/local/bin/vvr"
TMP_DIR=""

DEFAULT_PORT="443"
DEFAULT_SNI="www.sony.com"
DEFAULT_TAG="vvr-vless-ipv6-youtube"
DEFAULT_FALLBACK_PORT="4431"
DEFAULT_LIMIT_AFTER_BYTES="1048576"
DEFAULT_LIMIT_UPLOAD_BPS="65536"
DEFAULT_LIMIT_UPLOAD_BURST="131072"
DEFAULT_LIMIT_DOWNLOAD_BPS="131072"
DEFAULT_LIMIT_DOWNLOAD_BURST="262144"
DEFAULT_BASE_OUTBOUND_MODE="ipv4"
FINGERPRINT="chrome"

BLUE=""
YELLOW=""
RED=""
GREEN=""
RESET=""
if [ -t 1 ]; then
  BLUE="$(printf '\033[1;34m')"
  YELLOW="$(printf '\033[1;33m')"
  RED="$(printf '\033[1;31m')"
  GREEN="$(printf '\033[1;32m')"
  RESET="$(printf '\033[0m')"
fi

info() { printf '%s\n' "${BLUE}INFO${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}WARN${RESET} $*" >&2; }
ok() { printf '%s\n' "${GREEN} OK ${RESET} $*"; }
fail() { printf '%s\n' "${RED}ERROR${RESET} $*" >&2; exit 1; }

cleanup() {
  if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup 0

need_root() {
  [ "$(id -u)" -eq 0 ] || fail "请使用 root 运行此脚本。"
}

check_debian() {
  [ -f /etc/debian_version ] || fail "此脚本仅支持 Debian 及其兼容系统。"
}

install_dependencies() {
  command -v apt-get >/dev/null 2>&1 || fail "未找到 apt-get。"
  info "安装必要依赖..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl openssl unzip
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) XRAY_ZIP="Xray-linux-64.zip" ;;
    aarch64|arm64) XRAY_ZIP="Xray-linux-arm64-v8a.zip" ;;
    armv7l|armv7) XRAY_ZIP="Xray-linux-arm32-v7a.zip" ;;
    *) fail "暂不支持的 CPU 架构：$(uname -m)" ;;
  esac
  XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ZIP}"
}

prepare_tmp() {
  TMP_DIR="$(mktemp -d /tmp/xray-install.XXXXXX)"
}

download_xray() {
  local archive extract_dir
  archive="${TMP_DIR}/${XRAY_ZIP}"
  extract_dir="${TMP_DIR}/extract"
  info "下载最新 Xray-core..."
  curl -fL --retry 3 -A "vvr-xray-installer" "${XRAY_URL}" -o "${archive}"
  mkdir -p "${extract_dir}" "${XRAY_ASSET_DIR}"
  unzip -qo "${archive}" -d "${extract_dir}"
  [ -f "${extract_dir}/xray" ] || fail "安装包中没有找到 Xray 可执行文件。"
  install -m 0755 "${extract_dir}/xray" "${XRAY_BIN}"
  for asset in geoip.dat geosite.dat; do
    if [ -f "${extract_dir}/${asset}" ]; then
      install -m 0644 "${extract_dir}/${asset}" "${XRAY_ASSET_DIR}/${asset}"
    fi
  done
  [ -f "${XRAY_ASSET_DIR}/geosite.dat" ] || fail "安装包中没有找到 geosite.dat，无法使用 YouTube 规则。"
  "${XRAY_BIN}" version | head -n 1
}

prompt_values() {
  local input
  printf '监听端口 [%s]: ' "${DEFAULT_PORT}"
  read -r input
  PORT="${input:-${DEFAULT_PORT}}"
  case "${PORT}" in
    ''|*[!0-9]*) fail "端口无效。" ;;
  esac
  [ "${PORT}" -ge 1 ] && [ "${PORT}" -le 65535 ] || fail "端口无效。"

  printf 'Reality SNI [%s]: ' "${DEFAULT_SNI}"
  read -r input
  SNI="${input:-${DEFAULT_SNI}}"
  case "${SNI}" in
    ''|*[!A-Za-z0-9.-]*) fail "SNI 格式无效。" ;;
  esac

  printf '节点名称 [%s]: ' "${DEFAULT_TAG}"
  read -r input
  TAG="${input:-${DEFAULT_TAG}}"

  prompt_fallback_mode
  prompt_base_outbound_mode

  SERVER_IPV4="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  SERVER_IPV6="$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
}

prompt_base_outbound_mode() {
  local input

  echo
  echo "基础出站模式（未命中规则的流量使用此模式）："
  echo "  1. 仅 IPv4"
  echo "  2. 仅 IPv6"
  echo "  3. IPv4 优先，IPv6 兜底"
  echo "  4. IPv6 优先，IPv4 兜底"
  printf '选择基础出站模式 [1]: '
  read -r input
  case "${input:-1}" in
    1) BASE_OUTBOUND_MODE="ipv4" ;;
    2) BASE_OUTBOUND_MODE="ipv6" ;;
    3) BASE_OUTBOUND_MODE="ipv4v6" ;;
    4) BASE_OUTBOUND_MODE="ipv6v4" ;;
    *) fail "无效的基础出站模式。" ;;
  esac
}

prompt_fallback_mode() {
  local input

  echo
  echo "Reality 回落模式："
  echo "  1. 普通：无效连接直接回落到 ${SNI}:443。"
  echo "  2. 高级：经本机 Tunnel 回落，仅允许 ${SNI}，其他 SNI 丢弃。"
  printf '选择回落模式 [1]: '
  read -r input

  case "${input:-1}" in
    1)
      FALLBACK_MODE="direct"
      REALITY_DEST="${SNI}:443"
      FALLBACK_PORT=""
      FALLBACK_LIMIT_MODE="disabled"
      FALLBACK_LIMIT_AFTER_BYTES=""
      FALLBACK_LIMIT_UPLOAD_BPS=""
      FALLBACK_LIMIT_UPLOAD_BURST=""
      FALLBACK_LIMIT_DOWNLOAD_BPS=""
      FALLBACK_LIMIT_DOWNLOAD_BURST=""
      ;;
    2)
      FALLBACK_MODE="protected"
      while :; do
        printf '本机 Tunnel 监听端口 [%s]: ' "${DEFAULT_FALLBACK_PORT}"
        read -r input
        FALLBACK_PORT="${input:-${DEFAULT_FALLBACK_PORT}}"
        case "${FALLBACK_PORT}" in
          ''|*[!0-9]*) echo "端口无效。"; continue ;;
        esac
        [ "${FALLBACK_PORT}" -ge 1 ] && [ "${FALLBACK_PORT}" -le 65535 ] || {
          echo "端口无效。"
          continue
        }
        [ "${FALLBACK_PORT}" != "${PORT}" ] || {
          echo "Tunnel 端口不能与 Reality 监听端口相同。"
          continue
        }
        if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${FALLBACK_PORT}$"; then
          echo "端口 ${FALLBACK_PORT} 已被占用，请换一个端口。"
          continue
        fi
        break
      done
      REALITY_DEST="127.0.0.1:${FALLBACK_PORT}"
      prompt_fallback_limit
      ;;
    *) fail "无效的回落模式。" ;;
  esac
}

prompt_fallback_limit() {
  local input

  echo
  echo "回落限速（仅高级保护模式）："
  echo "  1. 关闭"
  echo "  2. 推荐：前 1 MiB 不限速，上传 64 KiB/s，下载 128 KiB/s"
  echo "  3. 自定义：单位为字节"
  printf '选择限速模式 [1]: '
  read -r input

  case "${input:-1}" in
    1)
      FALLBACK_LIMIT_MODE="disabled"
      FALLBACK_LIMIT_AFTER_BYTES=""
      FALLBACK_LIMIT_UPLOAD_BPS=""
      FALLBACK_LIMIT_UPLOAD_BURST=""
      FALLBACK_LIMIT_DOWNLOAD_BPS=""
      FALLBACK_LIMIT_DOWNLOAD_BURST=""
      ;;
    2)
      FALLBACK_LIMIT_MODE="recommended"
      FALLBACK_LIMIT_AFTER_BYTES="${DEFAULT_LIMIT_AFTER_BYTES}"
      FALLBACK_LIMIT_UPLOAD_BPS="${DEFAULT_LIMIT_UPLOAD_BPS}"
      FALLBACK_LIMIT_UPLOAD_BURST="${DEFAULT_LIMIT_UPLOAD_BURST}"
      FALLBACK_LIMIT_DOWNLOAD_BPS="${DEFAULT_LIMIT_DOWNLOAD_BPS}"
      FALLBACK_LIMIT_DOWNLOAD_BURST="${DEFAULT_LIMIT_DOWNLOAD_BURST}"
      ;;
    3)
      FALLBACK_LIMIT_MODE="custom"
      prompt_limit_value "限速开始前的字节数" "${DEFAULT_LIMIT_AFTER_BYTES}" FALLBACK_LIMIT_AFTER_BYTES
      prompt_limit_value "上传 bytesPerSec" "${DEFAULT_LIMIT_UPLOAD_BPS}" FALLBACK_LIMIT_UPLOAD_BPS
      prompt_limit_value "上传 burstBytesPerSec" "${DEFAULT_LIMIT_UPLOAD_BURST}" FALLBACK_LIMIT_UPLOAD_BURST
      prompt_limit_value "下载 bytesPerSec" "${DEFAULT_LIMIT_DOWNLOAD_BPS}" FALLBACK_LIMIT_DOWNLOAD_BPS
      prompt_limit_value "下载 burstBytesPerSec" "${DEFAULT_LIMIT_DOWNLOAD_BURST}" FALLBACK_LIMIT_DOWNLOAD_BURST
      [ "${FALLBACK_LIMIT_UPLOAD_BPS}" -gt 0 ] || fail "上传 bytesPerSec 必须大于 0。"
      [ "${FALLBACK_LIMIT_DOWNLOAD_BPS}" -gt 0 ] || fail "下载 bytesPerSec 必须大于 0。"
      [ "${FALLBACK_LIMIT_UPLOAD_BURST}" -ge "${FALLBACK_LIMIT_UPLOAD_BPS}" ] || fail "上传 burstBytesPerSec 不能小于 bytesPerSec。"
      [ "${FALLBACK_LIMIT_DOWNLOAD_BURST}" -ge "${FALLBACK_LIMIT_DOWNLOAD_BPS}" ] || fail "下载 burstBytesPerSec 不能小于 bytesPerSec。"
      ;;
    *) fail "无效的限速模式。" ;;
  esac
}

prompt_limit_value() {
  local label="$1" default="$2" variable="$3" input
  while :; do
    printf '%s [%s]: ' "${label}" "${default}"
    read -r input
    input="${input:-${default}}"
    case "${input}" in
      ''|*[!0-9]*) echo "请输入非负整数。" ;;
      *)
        case "${variable}" in
          FALLBACK_LIMIT_AFTER_BYTES) FALLBACK_LIMIT_AFTER_BYTES="${input}" ;;
          FALLBACK_LIMIT_UPLOAD_BPS) FALLBACK_LIMIT_UPLOAD_BPS="${input}" ;;
          FALLBACK_LIMIT_UPLOAD_BURST) FALLBACK_LIMIT_UPLOAD_BURST="${input}" ;;
          FALLBACK_LIMIT_DOWNLOAD_BPS) FALLBACK_LIMIT_DOWNLOAD_BPS="${input}" ;;
          FALLBACK_LIMIT_DOWNLOAD_BURST) FALLBACK_LIMIT_DOWNLOAD_BURST="${input}" ;;
          *) fail "内部错误：未知限速参数。" ;;
        esac
        return
        ;;
    esac
  done
}

generate_values() {
  local keys
  info "生成 UUID 和 REALITY 密钥..."
  UUID="$("${XRAY_BIN}" uuid)"
  keys="$("${XRAY_BIN}" x25519 2>&1)"
  PRIVATE_KEY="$(printf '%s\n' "${keys}" | awk '{line=tolower($0); if (line ~ /private/ && line ~ /key/) {sub(/.*[:=][ \t]*/, "", $0); gsub(/[",]/, "", $0); print $1; exit}}')"
  PUBLIC_KEY="$(printf '%s\n' "${keys}" | awk '{line=tolower($0); if (line ~ /public/ && line ~ /key/) {sub(/.*[:=][ \t]*/, "", $0); gsub(/[",]/, "", $0); print $1; exit}}')"
  SHORT_ID="$(openssl rand -hex 8)"
  [ -n "${UUID}" ] || fail "生成 UUID 失败。"
  [ -n "${PRIVATE_KEY}" ] || fail "生成 REALITY 私钥失败。"
  [ -n "${PUBLIC_KEY}" ] || fail "生成 REALITY 公钥失败。"
}

handle_existing_install() {
  if [ -e "${CONFIG_FILE}" ] || [ -e "${SERVICE_FILE}" ] || [ -x "${XRAY_BIN}" ]; then
    warn "检测到已有 Xray 安装。"
    printf '是否备份并替换现有配置？[y/N]: '
    read -r answer
    case "${answer}" in
      y|Y|yes|YES)
        systemctl stop xray >/dev/null 2>&1 || true
        if [ -f "${CONFIG_FILE}" ]; then
          cp -a "${CONFIG_FILE}" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        fi
        ;;
      *) fail "已取消，未覆盖现有安装。" ;;
    esac
  fi
}

write_config() {
  FALLBACK_INBOUND=""
  FALLBACK_RULES=""
  REALITY_LIMIT_CONFIG=""
  ROUTING_RULES=""

  if [ ! -f "${ROUTES_FILE}" ]; then
    printf '%s\n' 'ipv6|geosite|youtube' > "${ROUTES_FILE}"
    chmod 0600 "${ROUTES_FILE}"
  fi

  while IFS='|' read -r route_mode route_type route_value; do
    [ -n "${route_mode}" ] || continue
    case "${route_mode}" in
      ipv4) route_tag="direct-ipv4" ;;
      ipv6) route_tag="direct-ipv6" ;;
      ipv4v6) route_tag="direct-ipv4v6" ;;
      ipv6v4) route_tag="direct-ipv6v4" ;;
      *) continue ;;
    esac
    case "${route_type}" in
      domain) route_domain="${route_value}" ;;
      geosite) route_domain="geosite:${route_value}" ;;
      *) continue ;;
    esac
    [ -n "${route_domain}" ] || continue
    ROUTING_RULES="${ROUTING_RULES}      {\"type\": \"field\", \"domain\": [\"${route_domain}\"], \"outboundTag\": \"${route_tag}\"},
"
  done < "${ROUTES_FILE}"

  case "${BASE_OUTBOUND_MODE}" in
    ipv4) BASE_OUTBOUND_TAG="direct-ipv4" ;;
    ipv6) BASE_OUTBOUND_TAG="direct-ipv6" ;;
    ipv4v6) BASE_OUTBOUND_TAG="direct-ipv4v6" ;;
    ipv6v4) BASE_OUTBOUND_TAG="direct-ipv6v4" ;;
    *) fail "基础出站模式无效。" ;;
  esac

  if [ "${FALLBACK_MODE}" = "protected" ]; then
    FALLBACK_INBOUND=",
    {
      \"listen\": \"127.0.0.1\",
      \"port\": ${FALLBACK_PORT},
      \"protocol\": \"dokodemo-door\",
      \"tag\": \"reality-fallback\",
      \"settings\": {
        \"address\": \"${SNI}\",
        \"port\": 443,
        \"network\": \"tcp\"
      },
      \"sniffing\": {
        \"enabled\": true,
        \"destOverride\": [\"tls\"],
        \"routeOnly\": false
      }
    }"
    FALLBACK_RULES="      {
        \"type\": \"field\",
        \"inboundTag\": [\"reality-fallback\"],
        \"domain\": [\"full:${SNI}\"],
        \"outboundTag\": \"direct-ipv4\"
      },
      {
        \"type\": \"field\",
        \"inboundTag\": [\"reality-fallback\"],
        \"outboundTag\": \"block\"
      },"
  fi

  if [ "${FALLBACK_LIMIT_MODE}" != "disabled" ]; then
    REALITY_LIMIT_CONFIG=",
          \"limitFallbackUpload\": {
            \"afterBytes\": ${FALLBACK_LIMIT_AFTER_BYTES},
            \"bytesPerSec\": ${FALLBACK_LIMIT_UPLOAD_BPS},
            \"burstBytesPerSec\": ${FALLBACK_LIMIT_UPLOAD_BURST}
          },
          \"limitFallbackDownload\": {
            \"afterBytes\": ${FALLBACK_LIMIT_AFTER_BYTES},
            \"bytesPerSec\": ${FALLBACK_LIMIT_DOWNLOAD_BPS},
            \"burstBytesPerSec\": ${FALLBACK_LIMIT_DOWNLOAD_BURST}
          }"
  fi

  mkdir -p "${CONFIG_DIR}"
  chmod 0755 "${CONFIG_DIR}"
  cat > "${CONFIG_FILE}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      "localhost",
      "1.1.1.1"
    ],
    "queryStrategy": "UseIP"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "tag": "vless-in",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]${REALITY_LIMIT_CONFIG}
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }${FALLBACK_INBOUND}
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct-ipv4",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct-ipv6",
      "settings": {
        "domainStrategy": "UseIPv6"
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct-ipv4v6",
      "settings": {
        "domainStrategy": "UseIPv4v6"
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct-ipv6v4",
      "settings": {
        "domainStrategy": "UseIPv6v4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
${FALLBACK_RULES}
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      },
${ROUTING_RULES}      {
        "type": "field",
        "inboundTag": ["vless-in"],
        "outboundTag": "${BASE_OUTBOUND_TAG}"
      }
    ]
  }
}
EOF
  chmod 0600 "${CONFIG_FILE}"
}

write_metadata() {
  cat > "${META_FILE}" <<EOF
PORT='${PORT}'
SNI='${SNI}'
TAG='${TAG}'
UUID='${UUID}'
PRIVATE_KEY='${PRIVATE_KEY}'
PUBLIC_KEY='${PUBLIC_KEY}'
SHORT_ID='${SHORT_ID}'
REALITY_DEST='${REALITY_DEST}'
FALLBACK_MODE='${FALLBACK_MODE}'
FALLBACK_PORT='${FALLBACK_PORT}'
FALLBACK_LIMIT_MODE='${FALLBACK_LIMIT_MODE}'
FALLBACK_LIMIT_AFTER_BYTES='${FALLBACK_LIMIT_AFTER_BYTES}'
FALLBACK_LIMIT_UPLOAD_BPS='${FALLBACK_LIMIT_UPLOAD_BPS}'
FALLBACK_LIMIT_UPLOAD_BURST='${FALLBACK_LIMIT_UPLOAD_BURST}'
FALLBACK_LIMIT_DOWNLOAD_BPS='${FALLBACK_LIMIT_DOWNLOAD_BPS}'
FALLBACK_LIMIT_DOWNLOAD_BURST='${FALLBACK_LIMIT_DOWNLOAD_BURST}'
BASE_OUTBOUND_MODE='${BASE_OUTBOUND_MODE}'
SERVER_IPV4='${SERVER_IPV4}'
SERVER_IPV6='${SERVER_IPV6}'
EOF
  chmod 0600 "${META_FILE}"
}

write_service() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Xray VLESS REALITY IPv6 YouTube split node
Documentation=https://xtls.github.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=XRAY_LOCATION_ASSET=${XRAY_ASSET_DIR}
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${SERVICE_FILE}"
}

validate_and_start() {
  info "检查 Xray 配置..."
  XRAY_LOCATION_ASSET="${XRAY_ASSET_DIR}" "${XRAY_BIN}" run -test -config "${CONFIG_FILE}"
  systemctl daemon-reload
  systemctl enable --now xray
  sleep 2
  systemctl is-active --quiet xray || {
    journalctl -u xray -n 80 --no-pager || true
    fail "Xray 启动失败。"
  }
}

write_manager_command() {
  info "正在安装 vvr 管理命令..."
  cat > "${MANAGER_BIN}" <<'EOF'
#!/usr/bin/env sh
set -eu

XRAY_BIN="/usr/local/bin/xray"
XRAY_ASSET_DIR="/usr/local/share/xray"
CONFIG_DIR="/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
META_FILE="${CONFIG_DIR}/vless-ipv6-youtube.env"
ROUTES_FILE="${CONFIG_DIR}/vvr-routing.rules"
SERVICE_FILE="/etc/systemd/system/xray.service"
MANAGER_BIN="/usr/local/bin/vvr"

DEFAULT_PORT="443"
DEFAULT_SNI="www.sony.com"
DEFAULT_TAG="vvr-vless-ipv6-youtube"
DEFAULT_FALLBACK_PORT="4431"
DEFAULT_LIMIT_AFTER_BYTES="1048576"
DEFAULT_LIMIT_UPLOAD_BPS="65536"
DEFAULT_LIMIT_UPLOAD_BURST="131072"
DEFAULT_LIMIT_DOWNLOAD_BPS="131072"
DEFAULT_LIMIT_DOWNLOAD_BURST="262144"
DEFAULT_BASE_OUTBOUND_MODE="ipv4"
FINGERPRINT="chrome"

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

info() { printf '%s\n' "${BLUE}INFO${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}WARN${RESET} $*"; }
ok() { printf '%s\n' "${GREEN} OK ${RESET} $*"; }
fail() { printf '%s\n' "${RED}ERROR${RESET} $*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || fail "请使用 root 运行 vvr。"
}

load_state() {
  [ -f "${META_FILE}" ] || fail "未找到节点信息文件：${META_FILE}。请重新运行安装脚本。"
  # shellcheck disable=SC1090
  . "${META_FILE}"
  [ -n "${PRIVATE_KEY:-}" ] || fail "节点信息缺少 Reality 私钥。请重新运行最新版安装脚本。"
  FINGERPRINT="${FINGERPRINT:-chrome}"
  FALLBACK_MODE="${FALLBACK_MODE:-direct}"
  FALLBACK_PORT="${FALLBACK_PORT:-}"
  FALLBACK_LIMIT_MODE="${FALLBACK_LIMIT_MODE:-disabled}"
  FALLBACK_LIMIT_AFTER_BYTES="${FALLBACK_LIMIT_AFTER_BYTES:-}"
  FALLBACK_LIMIT_UPLOAD_BPS="${FALLBACK_LIMIT_UPLOAD_BPS:-}"
  FALLBACK_LIMIT_UPLOAD_BURST="${FALLBACK_LIMIT_UPLOAD_BURST:-}"
  FALLBACK_LIMIT_DOWNLOAD_BPS="${FALLBACK_LIMIT_DOWNLOAD_BPS:-}"
  FALLBACK_LIMIT_DOWNLOAD_BURST="${FALLBACK_LIMIT_DOWNLOAD_BURST:-}"
  BASE_OUTBOUND_MODE="${BASE_OUTBOUND_MODE:-${DEFAULT_BASE_OUTBOUND_MODE}}"
  if [ "${FALLBACK_MODE}" = "protected" ]; then
    FALLBACK_PORT="${FALLBACK_PORT:-${DEFAULT_FALLBACK_PORT}}"
    REALITY_DEST="127.0.0.1:${FALLBACK_PORT}"
  else
    FALLBACK_MODE="direct"
    FALLBACK_LIMIT_MODE="disabled"
    FALLBACK_LIMIT_AFTER_BYTES=""
    FALLBACK_LIMIT_UPLOAD_BPS=""
    FALLBACK_LIMIT_UPLOAD_BURST=""
    FALLBACK_LIMIT_DOWNLOAD_BPS=""
    FALLBACK_LIMIT_DOWNLOAD_BURST=""
    REALITY_DEST="${SNI}:443"
  fi
}

save_state() {
  cat > "${META_FILE}" <<STATE
PORT='${PORT}'
SNI='${SNI}'
TAG='${TAG}'
UUID='${UUID}'
PRIVATE_KEY='${PRIVATE_KEY}'
PUBLIC_KEY='${PUBLIC_KEY}'
SHORT_ID='${SHORT_ID}'
REALITY_DEST='${REALITY_DEST}'
FALLBACK_MODE='${FALLBACK_MODE}'
FALLBACK_PORT='${FALLBACK_PORT}'
FALLBACK_LIMIT_MODE='${FALLBACK_LIMIT_MODE}'
FALLBACK_LIMIT_AFTER_BYTES='${FALLBACK_LIMIT_AFTER_BYTES}'
FALLBACK_LIMIT_UPLOAD_BPS='${FALLBACK_LIMIT_UPLOAD_BPS}'
FALLBACK_LIMIT_UPLOAD_BURST='${FALLBACK_LIMIT_UPLOAD_BURST}'
FALLBACK_LIMIT_DOWNLOAD_BPS='${FALLBACK_LIMIT_DOWNLOAD_BPS}'
FALLBACK_LIMIT_DOWNLOAD_BURST='${FALLBACK_LIMIT_DOWNLOAD_BURST}'
BASE_OUTBOUND_MODE='${BASE_OUTBOUND_MODE}'
SERVER_IPV4='${SERVER_IPV4:-}'
SERVER_IPV6='${SERVER_IPV6:-}'
STATE
  chmod 0600 "${META_FILE}"
}

make_uri() {
  if [ -n "${SERVER_IPV4:-}" ]; then
    host="${SERVER_IPV4}"
  elif [ -n "${SERVER_IPV6:-}" ]; then
    host="[${SERVER_IPV6}]"
  else
    host="你的服务器地址"
  fi
  URI="vless://${UUID}@${host}:${PORT}?type=tcp&encryption=none&security=reality&pbk=${PUBLIC_KEY}&fp=${FINGERPRINT}&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#${TAG}"
}

show_node() {
  load_state
  make_uri
  echo
  echo "节点信息："
  echo "  服务器：${host}"
  echo "  端口：  ${PORT}"
  echo "  SNI：   ${SNI}"
  echo "  名称：  ${TAG}"
  echo "  基础出站：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")"
  if [ "${FALLBACK_MODE}" = "protected" ]; then
    echo "  回落：  高级保护（${REALITY_DEST}）"
    echo "  Tunnel：127.0.0.1:${FALLBACK_PORT}"
    case "${FALLBACK_LIMIT_MODE}" in
      recommended|custom) echo "  限速：  上传 ${FALLBACK_LIMIT_UPLOAD_BPS} B/s，下载 ${FALLBACK_LIMIT_DOWNLOAD_BPS} B/s" ;;
      *) echo "  限速：  关闭" ;;
    esac
  else
    echo "  回落：  普通（${REALITY_DEST}）"
  fi
  echo
  echo "客户端链接："
  echo "${URI}"
}

prompt_port() {
  local input
  while :; do
    printf '监听端口 [%s]: ' "${PORT}"
    read -r input
    input="${input:-${PORT}}"
    case "${input}" in
      ''|*[!0-9]*) echo "端口无效。" ;;
      *)
        [ "${input}" -ge 1 ] && [ "${input}" -le 65535 ] || { echo "端口无效。"; continue; }
        if [ "${FALLBACK_MODE}" = "protected" ] && [ "${input}" = "${FALLBACK_PORT}" ]; then
          echo "监听端口不能与 Tunnel 端口相同。"
          continue
        fi
        PORT="${input}"
        return
        ;;
    esac
  done
}

prompt_sni() {
  local input
  while :; do
    printf 'Reality SNI [%s]: ' "${SNI}"
    read -r input
    input="${input:-${SNI}}"
    case "${input}" in
      ''|*[!A-Za-z0-9.-]*) echo "SNI 格式无效。" ;;
      *)
        SNI="${input}"
        [ "${FALLBACK_MODE}" = "protected" ] || REALITY_DEST="${SNI}:443"
        return
        ;;
    esac
  done
}

prompt_tag() {
  local input
  while :; do
    printf '节点名称 [%s]: ' "${TAG}"
    read -r input
    input="${input:-${TAG}}"
    case "${input}" in
      ''|*[!A-Za-z0-9._-]*) echo "节点名称只能包含英文、数字、点、下划线和短横线。" ;;
      *) TAG="${input}"; return ;;
    esac
  done
}

clear_fallback_limit() {
  FALLBACK_LIMIT_MODE="disabled"
  FALLBACK_LIMIT_AFTER_BYTES=""
  FALLBACK_LIMIT_UPLOAD_BPS=""
  FALLBACK_LIMIT_UPLOAD_BURST=""
  FALLBACK_LIMIT_DOWNLOAD_BPS=""
  FALLBACK_LIMIT_DOWNLOAD_BURST=""
}

set_recommended_fallback_limit() {
  FALLBACK_LIMIT_MODE="recommended"
  FALLBACK_LIMIT_AFTER_BYTES="${DEFAULT_LIMIT_AFTER_BYTES}"
  FALLBACK_LIMIT_UPLOAD_BPS="${DEFAULT_LIMIT_UPLOAD_BPS}"
  FALLBACK_LIMIT_UPLOAD_BURST="${DEFAULT_LIMIT_UPLOAD_BURST}"
  FALLBACK_LIMIT_DOWNLOAD_BPS="${DEFAULT_LIMIT_DOWNLOAD_BPS}"
  FALLBACK_LIMIT_DOWNLOAD_BURST="${DEFAULT_LIMIT_DOWNLOAD_BURST}"
}

prompt_limit_value() {
  local label="$1" default="$2" variable="$3" input
  while :; do
    printf '%s [%s]: ' "${label}" "${default}"
    read -r input
    input="${input:-${default}}"
    case "${input}" in
      ''|*[!0-9]*) echo "请输入非负整数。" ;;
      *)
        case "${variable}" in
          FALLBACK_LIMIT_AFTER_BYTES) FALLBACK_LIMIT_AFTER_BYTES="${input}" ;;
          FALLBACK_LIMIT_UPLOAD_BPS) FALLBACK_LIMIT_UPLOAD_BPS="${input}" ;;
          FALLBACK_LIMIT_UPLOAD_BURST) FALLBACK_LIMIT_UPLOAD_BURST="${input}" ;;
          FALLBACK_LIMIT_DOWNLOAD_BPS) FALLBACK_LIMIT_DOWNLOAD_BPS="${input}" ;;
          FALLBACK_LIMIT_DOWNLOAD_BURST) FALLBACK_LIMIT_DOWNLOAD_BURST="${input}" ;;
          *) fail "内部错误：未知限速参数。" ;;
        esac
        return
        ;;
    esac
  done
}

prompt_fallback_limit() {
  local input default after upload upload_burst download download_burst
  case "${FALLBACK_LIMIT_MODE}" in
    disabled) default=1 ;;
    recommended) default=2 ;;
    *) default=3 ;;
  esac

  echo
  echo "回落限速："
  echo "  1. 关闭"
  echo "  2. 推荐：前 1 MiB 不限速，上传 64 KiB/s，下载 128 KiB/s"
  echo "  3. 自定义：单位为字节"
  printf '选择限速模式 [%s]: ' "${default}"
  read -r input
  case "${input:-${default}}" in
    1) clear_fallback_limit ;;
    2) set_recommended_fallback_limit ;;
    3)
      FALLBACK_LIMIT_MODE="custom"
      after="${FALLBACK_LIMIT_AFTER_BYTES:-${DEFAULT_LIMIT_AFTER_BYTES}}"
      upload="${FALLBACK_LIMIT_UPLOAD_BPS:-${DEFAULT_LIMIT_UPLOAD_BPS}}"
      upload_burst="${FALLBACK_LIMIT_UPLOAD_BURST:-${DEFAULT_LIMIT_UPLOAD_BURST}}"
      download="${FALLBACK_LIMIT_DOWNLOAD_BPS:-${DEFAULT_LIMIT_DOWNLOAD_BPS}}"
      download_burst="${FALLBACK_LIMIT_DOWNLOAD_BURST:-${DEFAULT_LIMIT_DOWNLOAD_BURST}}"
      prompt_limit_value "限速开始前的字节数" "${after}" FALLBACK_LIMIT_AFTER_BYTES
      prompt_limit_value "上传 bytesPerSec" "${upload}" FALLBACK_LIMIT_UPLOAD_BPS
      prompt_limit_value "上传 burstBytesPerSec" "${upload_burst}" FALLBACK_LIMIT_UPLOAD_BURST
      prompt_limit_value "下载 bytesPerSec" "${download}" FALLBACK_LIMIT_DOWNLOAD_BPS
      prompt_limit_value "下载 burstBytesPerSec" "${download_burst}" FALLBACK_LIMIT_DOWNLOAD_BURST
      [ "${FALLBACK_LIMIT_UPLOAD_BPS}" -gt 0 ] || fail "上传 bytesPerSec 必须大于 0。"
      [ "${FALLBACK_LIMIT_DOWNLOAD_BPS}" -gt 0 ] || fail "下载 bytesPerSec 必须大于 0。"
      [ "${FALLBACK_LIMIT_UPLOAD_BURST}" -ge "${FALLBACK_LIMIT_UPLOAD_BPS}" ] || fail "上传 burstBytesPerSec 不能小于 bytesPerSec。"
      [ "${FALLBACK_LIMIT_DOWNLOAD_BURST}" -ge "${FALLBACK_LIMIT_DOWNLOAD_BPS}" ] || fail "下载 burstBytesPerSec 不能小于 bytesPerSec。"
      ;;
    *) fail "无效的限速模式。" ;;
  esac
}

configure_fallback() {
  local input default
  case "${FALLBACK_MODE}" in
    protected) default=2 ;;
    *) default=1 ;;
  esac

  echo
  echo "Reality 回落设置："
  echo "  1. 普通：无效连接直接回落到 ${SNI}:443。"
  echo "  2. 高级：经本机 Tunnel 回落，仅允许 ${SNI}，其他 SNI 丢弃。"
  printf '选择回落模式 [%s]: ' "${default}"
  read -r input

  case "${input:-${default}}" in
    1)
      FALLBACK_MODE="direct"
      FALLBACK_PORT=""
      REALITY_DEST="${SNI}:443"
      clear_fallback_limit
      ;;
    2)
      FALLBACK_MODE="protected"
      while :; do
        printf '本机 Tunnel 监听端口 [%s]: ' "${FALLBACK_PORT:-${DEFAULT_FALLBACK_PORT}}"
        read -r input
        input="${input:-${FALLBACK_PORT:-${DEFAULT_FALLBACK_PORT}}}"
        case "${input}" in
          ''|*[!0-9]*) echo "端口无效。" ;;
          *)
            [ "${input}" -ge 1 ] && [ "${input}" -le 65535 ] || { echo "端口无效。"; continue; }
            [ "${input}" != "${PORT}" ] || { echo "Tunnel 端口不能与 Reality 监听端口相同。"; continue; }
            FALLBACK_PORT="${input}"
            break
            ;;
        esac
      done
      REALITY_DEST="127.0.0.1:${FALLBACK_PORT}"
      prompt_fallback_limit
      ;;
    *) fail "无效的回落模式。" ;;
  esac
}

outbound_mode_label() {
  case "$1" in
    ipv4) printf '%s' '仅 IPv4' ;;
    ipv6) printf '%s' '仅 IPv6' ;;
    ipv4v6) printf '%s' 'IPv4 优先，IPv6 兜底' ;;
    ipv6v4) printf '%s' 'IPv6 优先，IPv4 兜底' ;;
    *) printf '%s' '未知' ;;
  esac
}

choose_outbound_mode() {
  local default="$1" input
  echo "  1. 仅 IPv4"
  echo "  2. 仅 IPv6"
  echo "  3. IPv4 优先，IPv6 兜底"
  echo "  4. IPv6 优先，IPv4 兜底"
  case "${default}" in
    ipv4) default=1 ;;
    ipv6) default=2 ;;
    ipv4v6) default=3 ;;
    ipv6v4) default=4 ;;
    *) default=1 ;;
  esac
  printf '选择出站模式 [%s]: ' "${default}"
  read -r input
  case "${input:-${default}}" in
    1) SELECTED_OUTBOUND_MODE="ipv4" ;;
    2) SELECTED_OUTBOUND_MODE="ipv6" ;;
    3) SELECTED_OUTBOUND_MODE="ipv4v6" ;;
    4) SELECTED_OUTBOUND_MODE="ipv6v4" ;;
    *) fail "无效的出站模式。" ;;
  esac
}

ensure_routes_file() {
  if [ ! -f "${ROUTES_FILE}" ]; then
    printf '%s\n' 'ipv6|geosite|youtube' > "${ROUTES_FILE}"
    chmod 0600 "${ROUTES_FILE}"
  fi
}

list_outbound_rules() {
  local number=0 route_mode route_type route_value
  ensure_routes_file
  echo
  echo "基础出站：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")"
  echo "规则文件：${ROUTES_FILE}"
  echo "编号  出站模式                 规则"
  while IFS='|' read -r route_mode route_type route_value; do
    [ -n "${route_mode}" ] || continue
    number=$((number + 1))
    case "${route_type}" in
      domain) route_display="${route_value}" ;;
      geosite) route_display="geosite:${route_value}" ;;
      *) route_display="无效：${route_type}|${route_value}" ;;
    esac
    printf '%-4s  %-23s  %s\n' "${number}" "$(outbound_mode_label "${route_mode}")" "${route_display}"
  done < "${ROUTES_FILE}"
  [ "${number}" -gt 0 ] || echo "（暂无自定义规则）"
}

add_domain_rule() {
  local input route_type domain
  echo
  echo "选择此规则使用的出站模式："
  choose_outbound_mode "${BASE_OUTBOUND_MODE}"
  echo "域名匹配类型："
  echo "  1. 精确匹配，例如 api.example.com"
  echo "  2. 后缀匹配，例如 example.com 会匹配其子域名"
  printf '选择匹配类型 [1]: '
  read -r input
  case "${input:-1}" in
    1) route_type="full" ;;
    2) route_type="domain" ;;
    *) fail "无效的域名匹配类型。" ;;
  esac
  while :; do
    printf '输入域名: '
    read -r domain
    case "${domain}" in
      ''|*[!A-Za-z0-9.-]*) echo "域名格式无效。" ;;
      *) break ;;
    esac
  done
  ensure_routes_file
  printf '%s|domain|%s:%s\n' "${SELECTED_OUTBOUND_MODE}" "${route_type}" "${domain}" >> "${ROUTES_FILE}"
}

add_geosite_rule() {
  local geosite
  echo
  echo "选择此规则使用的出站模式："
  choose_outbound_mode "${BASE_OUTBOUND_MODE}"
  while :; do
    printf '输入 geosite 名称（例如 youtube，不要带 geosite: 前缀）: '
    read -r geosite
    case "${geosite}" in
      ''|*[!A-Za-z0-9._@!:-]*) echo "geosite 名称格式无效。" ;;
      *) break ;;
    esac
  done
  ensure_routes_file
  printf '%s|geosite|%s\n' "${SELECTED_OUTBOUND_MODE}" "${geosite}" >> "${ROUTES_FILE}"
}

delete_outbound_rule() {
  local input count temp_file
  ensure_routes_file
  count="$(awk 'END { print NR }' "${ROUTES_FILE}")"
  [ "${count}" -gt 0 ] || { echo "暂无可删除的规则。"; return; }
  list_outbound_rules
  while :; do
    printf '输入要删除的规则编号（0 取消）: '
    read -r input
    case "${input}" in
      0) return ;;
      ''|*[!0-9]*) echo "请输入有效编号。" ;;
      *)
        [ "${input}" -ge 1 ] && [ "${input}" -le "${count}" ] || { echo "编号超出范围。"; continue; }
        temp_file="${ROUTES_FILE}.tmp.$$"
        awk -v line="${input}" 'NR != line { print }' "${ROUTES_FILE}" > "${temp_file}"
        mv "${temp_file}" "${ROUTES_FILE}"
        chmod 0600 "${ROUTES_FILE}"
        return
        ;;
    esac
  done
}

manage_outbound_strategy() {
  local input
  load_state
  ensure_routes_file
  while :; do
    clear 2>/dev/null || true
    echo "=============================="
    echo " 出站策略管理"
    echo "=============================="
    echo " 当前基础出站：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")"
    echo " 1. 设置基础出站模式"
    echo " 2. 查看全部出站规则"
    echo " 3. 添加域名规则"
    echo " 4. 添加 geosite 规则"
    echo " 5. 删除规则"
    echo " 0. 返回主菜单"
    echo
    printf '请选择操作: '
    read -r input
    case "${input}" in
      1) echo; choose_outbound_mode "${BASE_OUTBOUND_MODE}"; BASE_OUTBOUND_MODE="${SELECTED_OUTBOUND_MODE}"; apply_config ;;
      2) list_outbound_rules ;;
      3) add_domain_rule; apply_config ;;
      4) add_geosite_rule; apply_config ;;
      5) delete_outbound_rule; apply_config ;;
      0) return ;;
      *) echo "无效选择，请重新输入。" ;;
    esac
    echo
    printf '按回车继续...'
    read -r _
  done
}

write_config() {
  FALLBACK_INBOUND=""
  FALLBACK_RULES=""
  REALITY_LIMIT_CONFIG=""
  ROUTING_RULES=""

  ensure_routes_file
  while IFS='|' read -r route_mode route_type route_value; do
    [ -n "${route_mode}" ] || continue
    case "${route_mode}" in
      ipv4) route_tag="direct-ipv4" ;;
      ipv6) route_tag="direct-ipv6" ;;
      ipv4v6) route_tag="direct-ipv4v6" ;;
      ipv6v4) route_tag="direct-ipv6v4" ;;
      *) continue ;;
    esac
    case "${route_type}" in
      domain) route_domain="${route_value}" ;;
      geosite) route_domain="geosite:${route_value}" ;;
      *) continue ;;
    esac
    [ -n "${route_domain}" ] || continue
    ROUTING_RULES="${ROUTING_RULES}      {\"type\": \"field\", \"domain\": [\"${route_domain}\"], \"outboundTag\": \"${route_tag}\"},
"
  done < "${ROUTES_FILE}"

  case "${BASE_OUTBOUND_MODE}" in
    ipv4) BASE_OUTBOUND_TAG="direct-ipv4" ;;
    ipv6) BASE_OUTBOUND_TAG="direct-ipv6" ;;
    ipv4v6) BASE_OUTBOUND_TAG="direct-ipv4v6" ;;
    ipv6v4) BASE_OUTBOUND_TAG="direct-ipv6v4" ;;
    *) fail "基础出站模式无效。" ;;
  esac

  if [ "${FALLBACK_MODE}" = "protected" ]; then
    FALLBACK_INBOUND=",
    {
      \"listen\": \"127.0.0.1\",
      \"port\": ${FALLBACK_PORT},
      \"protocol\": \"dokodemo-door\",
      \"tag\": \"reality-fallback\",
      \"settings\": {
        \"address\": \"${SNI}\",
        \"port\": 443,
        \"network\": \"tcp\"
      },
      \"sniffing\": {
        \"enabled\": true,
        \"destOverride\": [\"tls\"],
        \"routeOnly\": false
      }
    }"
    FALLBACK_RULES="      {
        \"type\": \"field\",
        \"inboundTag\": [\"reality-fallback\"],
        \"domain\": [\"full:${SNI}\"],
        \"outboundTag\": \"direct-ipv4\"
      },
      {
        \"type\": \"field\",
        \"inboundTag\": [\"reality-fallback\"],
        \"outboundTag\": \"block\"
      },"
  fi

  if [ "${FALLBACK_LIMIT_MODE}" != "disabled" ]; then
    REALITY_LIMIT_CONFIG=",
          \"limitFallbackUpload\": {
            \"afterBytes\": ${FALLBACK_LIMIT_AFTER_BYTES},
            \"bytesPerSec\": ${FALLBACK_LIMIT_UPLOAD_BPS},
            \"burstBytesPerSec\": ${FALLBACK_LIMIT_UPLOAD_BURST}
          },
          \"limitFallbackDownload\": {
            \"afterBytes\": ${FALLBACK_LIMIT_AFTER_BYTES},
            \"bytesPerSec\": ${FALLBACK_LIMIT_DOWNLOAD_BPS},
            \"burstBytesPerSec\": ${FALLBACK_LIMIT_DOWNLOAD_BURST}
          }"
  fi

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
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]${REALITY_LIMIT_CONFIG}
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }${FALLBACK_INBOUND}
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct-ipv4", "settings": {"domainStrategy": "UseIPv4"}},
    {"protocol": "freedom", "tag": "direct-ipv6", "settings": {"domainStrategy": "UseIPv6"}},
    {"protocol": "freedom", "tag": "direct-ipv4v6", "settings": {"domainStrategy": "UseIPv4v6"}},
    {"protocol": "freedom", "tag": "direct-ipv6v4", "settings": {"domainStrategy": "UseIPv6v4"}},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
${FALLBACK_RULES}
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
${ROUTING_RULES}      {"type": "field", "inboundTag": ["vless-in"], "outboundTag": "${BASE_OUTBOUND_TAG}"}
    ]
  }
}
CONFIG
  chmod 0600 "${CONFIG_FILE}"
}

apply_config() {
  backup_file="${CONFIG_FILE}.vvr.bak.$(date +%Y%m%d%H%M%S)"
  routes_backup_file="${ROUTES_FILE}.vvr.bak.$(date +%Y%m%d%H%M%S)"
  [ -f "${CONFIG_FILE}" ] && cp -a "${CONFIG_FILE}" "${backup_file}"
  [ -f "${ROUTES_FILE}" ] && cp -a "${ROUTES_FILE}" "${routes_backup_file}"
  write_config
  if ! XRAY_LOCATION_ASSET="${XRAY_ASSET_DIR}" "${XRAY_BIN}" run -test -config "${CONFIG_FILE}"; then
    [ -f "${backup_file}" ] && cp -a "${backup_file}" "${CONFIG_FILE}"
    [ -f "${routes_backup_file}" ] && cp -a "${routes_backup_file}" "${ROUTES_FILE}"
    fail "新配置测试失败，已恢复旧配置。"
  fi
  if ! systemctl restart xray; then
    [ -f "${backup_file}" ] && cp -a "${backup_file}" "${CONFIG_FILE}"
    [ -f "${routes_backup_file}" ] && cp -a "${routes_backup_file}" "${ROUTES_FILE}"
    systemctl restart xray >/dev/null 2>&1 || true
    journalctl -u xray -n 80 --no-pager || true
    fail "Xray 重启失败，已恢复旧配置。"
  fi
  sleep 2
  if ! systemctl is-active --quiet xray; then
    [ -f "${backup_file}" ] && cp -a "${backup_file}" "${CONFIG_FILE}"
    [ -f "${routes_backup_file}" ] && cp -a "${routes_backup_file}" "${ROUTES_FILE}"
    systemctl restart xray >/dev/null 2>&1 || true
    journalctl -u xray -n 80 --no-pager || true
    fail "Xray 服务状态异常，已恢复旧配置。"
  fi
  save_state
  ok "配置已应用。"
}

modify_port() {
  load_state
  old_port="${PORT}"
  prompt_port
  if [ "${PORT}" != "${old_port}" ] && command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${PORT}$"; then
    fail "端口 ${PORT} 已被占用，请换一个端口。"
  fi
  apply_config
}
modify_sni() { load_state; prompt_sni; apply_config; }
modify_tag() { load_state; prompt_tag; apply_config; }
modify_fallback() {
  load_state
  old_fallback_mode="${FALLBACK_MODE}"
  old_fallback_port="${FALLBACK_PORT}"
  configure_fallback
  if [ "${FALLBACK_MODE}" = "protected" ] && { [ "${FALLBACK_MODE}" != "${old_fallback_mode}" ] || [ "${FALLBACK_PORT}" != "${old_fallback_port}" ]; }; then
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${FALLBACK_PORT}$"; then
      fail "Tunnel 端口 ${FALLBACK_PORT} 已被占用，请换一个端口。"
    fi
  fi
  apply_config
}

reset_node() {
  local keys
  load_state
  warn "将重新生成 UUID、Reality 密钥和 shortId，旧客户端链接会失效。"
  printf '确认重置当前节点？[y/N]: '
  read -r input
  case "${input}" in y|Y|yes|YES) ;; *) return ;; esac
  UUID="$("${XRAY_BIN}" uuid)"
  keys="$("${XRAY_BIN}" x25519 2>&1)"
  PRIVATE_KEY="$(printf '%s\n' "${keys}" | awk '{line=tolower($0); if (line ~ /private/ && line ~ /key/) {sub(/.*[:=][ \t]*/, "", $0); gsub(/[",]/, "", $0); print $1; exit}}')"
  PUBLIC_KEY="$(printf '%s\n' "${keys}" | awk '{line=tolower($0); if (line ~ /public/ && line ~ /key/) {sub(/.*[:=][ \t]*/, "", $0); gsub(/[",]/, "", $0); print $1; exit}}')"
  SHORT_ID="$(openssl rand -hex 8)"
  [ -n "${UUID}" ] && [ -n "${PRIVATE_KEY}" ] && [ -n "${PUBLIC_KEY}" ] || fail "生成节点凭据失败。"
  apply_config
}

restart_xray() {
  XRAY_LOCATION_ASSET="${XRAY_ASSET_DIR}" "${XRAY_BIN}" run -test -config "${CONFIG_FILE}"
  systemctl restart xray
  systemctl is-active --quiet xray || fail "Xray 服务状态异常。"
  ok "Xray 已重启。"
}

uninstall_xray() {
  warn "即将卸载 Xray，并删除配置、服务文件、二进制和 vvr 管理命令。"
  printf '确认卸载？此操作不可恢复。[y/N]: '
  read -r input
  case "${input}" in y|Y|yes|YES) ;; *) return ;; esac
  systemctl stop xray >/dev/null 2>&1 || true
  systemctl disable xray >/dev/null 2>&1 || true
  rm -f "${SERVICE_FILE}" "${MANAGER_BIN}" "${XRAY_BIN}"
  rm -rf "${CONFIG_DIR}" "${XRAY_ASSET_DIR}"
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "已卸载完成。"
  exit 0
}

show_menu() {
  load_state
  clear 2>/dev/null || true
  echo "=============================="
  echo " VLESS + Reality IPv6 管理面板"
  echo "=============================="
  echo " 1. 查看节点链接与当前配置"
  echo " 2. 修改监听端口"
  echo " 3. 修改 Reality SNI"
  echo " 4. 修改节点名称"
  echo " 5. 配置 Reality 回落与限速"
  echo " 6. 管理出站策略（基础：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")）"
  echo " 7. 重启 Xray"
  echo " 8. 查看服务状态"
  echo " 9. 查看日志"
  echo "10. 重置当前节点"
  echo "11. 卸载并清理环境"
  echo " 0. 退出"
  echo
  printf '请选择操作: '
}

main() {
  need_root
  while :; do
    show_menu
    read -r choice
    case "${choice}" in
      1) show_node ;;
      2) modify_port ;;
      3) modify_sni ;;
      4) modify_tag ;;
      5) modify_fallback ;;
      6) manage_outbound_strategy ;;
      7) restart_xray ;;
      8) systemctl status xray --no-pager || true ;;
      9) journalctl -u xray -n 80 --no-pager || true ;;
      10) reset_node ;;
      11) uninstall_xray ;;
      0) exit 0 ;;
      *) echo "无效选择，请重新输入。" ;;
    esac
    echo
    printf '按回车返回菜单...'
    read -r _
  done
}

main "$@"
EOF
  chmod 0755 "${MANAGER_BIN}"
}

print_result() {
  local host uri
  if [ -n "${SERVER_IPV4}" ]; then
    host="${SERVER_IPV4}"
  elif [ -n "${SERVER_IPV6}" ]; then
    host="[${SERVER_IPV6}]"
  else
    host="你的服务器地址"
  fi
  uri="vless://${UUID}@${host}:${PORT}?type=tcp&encryption=none&security=reality&pbk=${PUBLIC_KEY}&fp=${FINGERPRINT}&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#${TAG}"
  echo
  ok "Xray VLESS Reality 节点安装完成。"
  echo "配置文件：${CONFIG_FILE}"
  echo "管理菜单：vvr"
  echo "服务状态：systemctl status xray --no-pager"
  echo "日志查看：journalctl -u xray -f"
  echo
  echo "分流策略："
  case "${BASE_OUTBOUND_MODE}" in
    ipv4) echo "  基础出站：仅 IPv4" ;;
    ipv6) echo "  基础出站：仅 IPv6" ;;
    ipv4v6) echo "  基础出站：IPv4 优先，IPv6 兜底" ;;
    ipv6v4) echo "  基础出站：IPv6 优先，IPv4 兜底" ;;
  esac
  echo "  自定义规则文件：${ROUTES_FILE}"
  echo
  if [ "${FALLBACK_MODE}" = "protected" ]; then
    echo "Reality 回落：高级保护模式"
    echo "  Reality dest：${REALITY_DEST}"
    echo "  Tunnel：127.0.0.1:${FALLBACK_PORT} -> ${SNI}:443"
    echo "  仅允许 TLS SNI 为 ${SNI} 的回落请求，其他请求会被丢弃。"
    case "${FALLBACK_LIMIT_MODE}" in
      recommended|custom)
        echo "  回落限速：上传 ${FALLBACK_LIMIT_UPLOAD_BPS} B/s，下载 ${FALLBACK_LIMIT_DOWNLOAD_BPS} B/s"
        echo "  限速起始：每个连接前 ${FALLBACK_LIMIT_AFTER_BYTES} 字节；突发上传/下载分别为 ${FALLBACK_LIMIT_UPLOAD_BURST}/${FALLBACK_LIMIT_DOWNLOAD_BURST} B。"
        ;;
      *) echo "  回落限速：关闭" ;;
    esac
  else
    echo "Reality 回落：普通模式（${REALITY_DEST}）"
  fi
  echo
  echo "客户端链接："
  echo "${uri}"
  echo
  warn "请确认 VPS 到 YouTube 的 IPv6 可达，并检查 IPv6 的 GeoIP 归属。"
}

main() {
  need_root
  check_debian
  install_dependencies
  detect_arch
  prepare_tmp
  handle_existing_install
  download_xray
  prompt_values
  generate_values
  write_config
  write_metadata
  write_service
  validate_and_start
  write_manager_command
  print_result
}

main "$@"
