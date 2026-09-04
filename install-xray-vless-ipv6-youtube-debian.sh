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
NETWORK_STATUS_FILE="${CONFIG_DIR}/vvr-network-status.env"
TRAFFIC_DIR="/var/lib/vvr"
TRAFFIC_DB="${TRAFFIC_DIR}/traffic.db"
TRAFFIC_SETTINGS_FILE="${CONFIG_DIR}/vvr-traffic-settings.env"
TRAFFIC_SCRIPT="/usr/local/libexec/vvr-traffic.py"
TRAFFIC_SERVICE_FILE="/etc/systemd/system/vvr-traffic-api.service"
TRAFFIC_TIMER_FILE="/etc/systemd/system/vvr-traffic-collector.timer"
TRAFFIC_COLLECTOR_SERVICE_FILE="/etc/systemd/system/vvr-traffic-collector.service"
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
  apt-get install -y --no-install-recommends ca-certificates curl openssl unzip python3
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
  confirm_initial_base_outbound
}

confirm_initial_base_outbound() {
  local answer
  case "${BASE_OUTBOUND_MODE}" in
    ipv6)
      case "${SERVER_IPV6}" in
        *:*) ;;
        *)
          warn "当前检测不到 IPv6 出站；仅 IPv6 基础模式很可能无法访问目标。"
          printf '仍要继续使用仅 IPv6 吗？[y/N]: '
          read -r answer
          case "${answer}" in y|Y|yes|YES) ;; *) fail "已取消，请选择其他基础出站模式。" ;; esac
          ;;
      esac
      ;;
    ipv4)
      case "${SERVER_IPV4}" in
        *.*.*.*) ;;
        *)
          warn "当前检测不到 IPv4 出站；仅 IPv4 基础模式很可能无法访问目标。"
          printf '仍要继续使用仅 IPv4 吗？[y/N]: '
          read -r answer
          case "${answer}" in y|Y|yes|YES) ;; *) fail "已取消，请选择其他基础出站模式。" ;; esac
          ;;
      esac
      ;;
    ipv6v4)
      case "${SERVER_IPV6}" in *:*) ;; *) warn "IPv6 当前不可用，IPv6 优先基础模式将使用 IPv4 兜底。" ;; esac
      ;;
    ipv4v6)
      case "${SERVER_IPV4}" in *.*.*.*) ;; *) warn "IPv4 当前不可用，IPv4 优先基础模式将使用 IPv6 兜底。" ;; esac
      ;;
  esac
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
  API_INBOUND=""
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

  API_INBOUND=",
    {
      \"listen\": \"127.0.0.1\",
      \"port\": 10085,
      \"protocol\": \"dokodemo-door\",
      \"tag\": \"api\",
      \"settings\": {\"address\": \"127.0.0.1\"},
      \"streamSettings\": {\"sockopt\": {\"acceptProxyProtocol\": false}}
    }"

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
  "stats": {},
  "policy": {"system": {"statsInboundUplink": true, "statsInboundDownlink": true}, "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}}},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
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
    }${API_INBOUND}${FALLBACK_INBOUND}
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
    },
    {
      "protocol": "freedom",
      "tag": "api"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
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

write_traffic_components() {
  mkdir -p "${TRAFFIC_DIR}" "$(dirname "${TRAFFIC_SCRIPT}")"
  chmod 0755 "${TRAFFIC_DIR}"
  cat > "${TRAFFIC_SCRIPT}" <<'PY'
#!/usr/bin/env python3
import argparse
import json
import os
import sqlite3
import subprocess
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

DB = os.environ.get("VVR_TRAFFIC_DB", "/var/lib/vvr/traffic.db")
XRAY = os.environ.get("VVR_XRAY_BIN", "/usr/local/bin/xray")
API_SERVER = os.environ.get("VVR_XRAY_API", "127.0.0.1:10085")
TOKEN_FILE = os.environ.get("VVR_TRAFFIC_TOKEN_FILE", "/etc/xray/vvr-traffic.token")
SETTINGS_FILE = os.environ.get("VVR_TRAFFIC_SETTINGS_FILE", "/etc/xray/vvr-traffic-settings.env")

def reset_settings():
    settings = {"day": 1, "hour": 0, "minute": 0}
    try:
        with open(SETTINGS_FILE, encoding="utf-8") as handle:
            for line in handle:
                key, sep, value = line.strip().partition("=")
                if sep:
                    value = value.strip().strip("'\"")
                    if key == "RESET_DAY":
                        settings["day"] = int(value)
                    elif key == "RESET_HOUR":
                        settings["hour"] = int(value)
                    elif key == "RESET_MINUTE":
                        settings["minute"] = int(value)
    except (OSError, ValueError):
        pass
    settings["day"] = min(max(settings["day"], 1), 28)
    settings["hour"] = min(max(settings["hour"], 0), 23)
    settings["minute"] = min(max(settings["minute"], 0), 59)
    return settings

def period_key(now=None):
    now = now or datetime.now()
    settings = reset_settings()
    start = datetime(now.year, now.month, settings["day"], settings["hour"], settings["minute"])
    if now < start:
        year, month = (now.year - 1, 12) if now.month == 1 else (now.year, now.month - 1)
        start = datetime(year, month, settings["day"], settings["hour"], settings["minute"])
    return start.strftime("%Y-%m-%d %H:%M")

def db_connect():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    db = sqlite3.connect(DB, timeout=10)
    db.execute("CREATE TABLE IF NOT EXISTS traffic (id INTEGER PRIMARY KEY CHECK (id = 1), month TEXT NOT NULL, total_up INTEGER NOT NULL DEFAULT 0, total_down INTEGER NOT NULL DEFAULT 0, last_up INTEGER NOT NULL DEFAULT 0, last_down INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL)")
    return db

def xray_stats():
    try:
        result = subprocess.run([XRAY, "api", "statsquery", "--server=" + API_SERVER], check=True, capture_output=True, text=True, timeout=10)
        payload = json.loads(result.stdout)
    except Exception:
        return None, None
    values = {item.get("name"): int(item.get("value", 0)) for item in payload.get("stat", [])}
    return values.get("inbound>>>vless-in>>>traffic>>>uplink", 0), values.get("inbound>>>vless-in>>>traffic>>>downlink", 0)

def collect():
    up, down = xray_stats()
    now = datetime.now().isoformat(timespec="seconds")
    period = period_key()
    db = db_connect()
    row = db.execute("SELECT month,total_up,total_down,last_up,last_down FROM traffic WHERE id=1").fetchone()
    if up is None or down is None:
        if row is None or row[0] != period:
            result = {"month": period[:7], "period_start": period, "up": 0, "down": 0, "total": 0, "updated_at": now}
        else:
            result = {"month": period[:7], "period_start": period, "up": row[1], "down": row[2], "total": row[1] + row[2], "updated_at": now}
        db.close()
        return result
    if row is None or row[0] != period:
        total_up = total_down = 0
        last_up = last_down = 0
    else:
        _, total_up, total_down, last_up, last_down = row
    delta_up = up - last_up if up >= last_up else up
    delta_down = down - last_down if down >= last_down else down
    total_up += max(delta_up, 0)
    total_down += max(delta_down, 0)
    db.execute("INSERT INTO traffic(id,month,total_up,total_down,last_up,last_down,updated_at) VALUES(1,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET month=excluded.month,total_up=excluded.total_up,total_down=excluded.total_down,last_up=excluded.last_up,last_down=excluded.last_down,updated_at=excluded.updated_at", (period,total_up,total_down,up,down,now))
    db.commit()
    db.close()
    return {"month": period[:7], "period_start": period, "up": total_up, "down": total_down, "total": total_up + total_down, "updated_at": now}

def reset():
    up, down = xray_stats()
    if up is None or down is None:
        raise RuntimeError("xray stats unavailable")
    now = datetime.now().isoformat(timespec="seconds")
    db = db_connect()
    period = period_key()
    db.execute("INSERT INTO traffic(id,month,total_up,total_down,last_up,last_down,updated_at) VALUES(1,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET month=excluded.month,total_up=0,total_down=0,last_up=excluded.last_up,last_down=excluded.last_down,updated_at=excluded.updated_at", (period,0,0,up,down,now))
    db.commit()
    db.close()
    return {"month": period[:7], "period_start": period, "up": 0, "down": 0, "total": 0, "updated_at": now}

def read_token():
    try:
        with open(TOKEN_FILE, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        query = parse_qs(urlparse(self.path).query)
        token = read_token()
        if token and query.get("token", [""])[0] != token:
            self.send_error(403, "invalid token")
            return
        if urlparse(self.path).path not in ("/", "/api/traffic"):
            self.send_error(404)
            return
        body = json.dumps(collect(), ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):
        return

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--collect", action="store_true")
    parser.add_argument("--reset", action="store_true")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18080)
    args = parser.parse_args()
    if args.reset:
        print(json.dumps(reset(), ensure_ascii=False))
    elif args.collect:
        print(json.dumps(collect(), ensure_ascii=False))
    elif args.serve:
        HTTPServer((args.host, args.port), Handler).serve_forever()
    else:
        parser.error("choose --collect, --reset, or --serve")

if __name__ == "__main__":
    main()
PY
  chmod 0755 "${TRAFFIC_SCRIPT}"
  if [ ! -s "${CONFIG_DIR}/vvr-traffic.token" ]; then
    openssl rand -hex 24 > "${CONFIG_DIR}/vvr-traffic.token"
  fi
  chmod 0600 "${CONFIG_DIR}/vvr-traffic.token"
  if [ ! -s "${TRAFFIC_SETTINGS_FILE}" ]; then
    cat > "${TRAFFIC_SETTINGS_FILE}" <<SETTINGS
RESET_DAY='1'
RESET_HOUR='0'
RESET_MINUTE='0'
SETTINGS
  fi
  chmod 0600 "${TRAFFIC_SETTINGS_FILE}"
  cat > "${TRAFFIC_COLLECTOR_SERVICE_FILE}" <<EOF
[Unit]
Description=VVR Xray traffic collector
After=xray.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 ${TRAFFIC_SCRIPT} --collect
EOF
  cat > "${TRAFFIC_TIMER_FILE}" <<EOF
[Unit]
Description=Collect VVR Xray traffic every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Unit=vvr-traffic-collector.service

[Install]
WantedBy=timers.target
EOF
  cat > "${TRAFFIC_SERVICE_FILE}" <<EOF
[Unit]
Description=VVR traffic API
After=xray.service
Requires=xray.service

[Service]
Type=simple
Environment=VVR_TRAFFIC_DB=${TRAFFIC_DB}
Environment=VVR_XRAY_BIN=${XRAY_BIN}
Environment=VVR_XRAY_API=127.0.0.1:10085
Environment=VVR_TRAFFIC_TOKEN_FILE=${CONFIG_DIR}/vvr-traffic.token
Environment=VVR_TRAFFIC_SETTINGS_FILE=${TRAFFIC_SETTINGS_FILE}
ExecStart=/usr/bin/python3 ${TRAFFIC_SCRIPT} --serve --host 127.0.0.1 --port 18080
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${TRAFFIC_COLLECTOR_SERVICE_FILE}" "${TRAFFIC_TIMER_FILE}" "${TRAFFIC_SERVICE_FILE}"
  systemctl daemon-reload
  systemctl enable --now vvr-traffic-api.service vvr-traffic-collector.timer
}

validate_and_start() {
  local test_output
  test_output="$(mktemp /tmp/vvr-xray-test.XXXXXX)"
  info "正在检查 Xray 配置..."
  if ! XRAY_LOCATION_ASSET="${XRAY_ASSET_DIR}" "${XRAY_BIN}" run -test -config "${CONFIG_FILE}" >"${test_output}" 2>&1; then
    echo "配置检查失败，以下是 Xray 原始错误信息：" >&2
    cat "${test_output}" >&2
    rm -f "${test_output}"
    fail "Xray 配置检查失败。"
  fi
  rm -f "${test_output}"
  info "配置检查通过，正在启动 Xray..."
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
NETWORK_STATUS_FILE="${CONFIG_DIR}/vvr-network-status.env"
TRAFFIC_DIR="/var/lib/vvr"
TRAFFIC_DB="${TRAFFIC_DIR}/traffic.db"
TRAFFIC_SETTINGS_FILE="${CONFIG_DIR}/vvr-traffic-settings.env"
TRAFFIC_SCRIPT="/usr/local/libexec/vvr-traffic.py"
TRAFFIC_SERVICE_FILE="/etc/systemd/system/vvr-traffic-api.service"
TRAFFIC_TIMER_FILE="/etc/systemd/system/vvr-traffic-collector.timer"
TRAFFIC_COLLECTOR_SERVICE_FILE="/etc/systemd/system/vvr-traffic-collector.service"
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

load_network_status() {
  IPV4_STATUS="unknown"
  IPV4_ADDRESS=""
  IPV6_STATUS="unknown"
  IPV6_ADDRESS=""
  NETWORK_STATUS_UPDATED_AT="未检测"
  if [ -f "${NETWORK_STATUS_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${NETWORK_STATUS_FILE}"
  fi
}

show_network_status() {
  load_network_status
  case "${IPV4_STATUS}" in
    available) echo " IPv4：可用（${IPV4_ADDRESS}）" ;;
    unavailable) echo " IPv4：不可用" ;;
    *) echo " IPv4：未检测" ;;
  esac
  case "${IPV6_STATUS}" in
    available) echo " IPv6：可用（${IPV6_ADDRESS}）" ;;
    unavailable) echo " IPv6：不可用" ;;
    *) echo " IPv6：未检测" ;;
  esac
  echo " 检测时间：${NETWORK_STATUS_UPDATED_AT}"
}

refresh_network_status() {
  local ipv4 ipv6
  info "正在检测服务器 IPv4 / IPv6 出站连通性..."
  ipv4="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  ipv6="$(curl -6fsS --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null || true)"
  case "${ipv4}" in
    *.*.*.*) IPV4_STATUS="available"; IPV4_ADDRESS="${ipv4}" ;;
    *) IPV4_STATUS="unavailable"; IPV4_ADDRESS="" ;;
  esac
  case "${ipv6}" in
    *:*) IPV6_STATUS="available"; IPV6_ADDRESS="${ipv6}" ;;
    *) IPV6_STATUS="unavailable"; IPV6_ADDRESS="" ;;
  esac
  NETWORK_STATUS_UPDATED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  cat > "${NETWORK_STATUS_FILE}" <<STATUS
IPV4_STATUS='${IPV4_STATUS}'
IPV4_ADDRESS='${IPV4_ADDRESS}'
IPV6_STATUS='${IPV6_STATUS}'
IPV6_ADDRESS='${IPV6_ADDRESS}'
NETWORK_STATUS_UPDATED_AT='${NETWORK_STATUS_UPDATED_AT}'
STATUS
  chmod 0600 "${NETWORK_STATUS_FILE}"
  echo
  show_network_status
}

outbound_tag_for_mode() {
  case "$1" in
    ipv4) printf '%s' 'direct-ipv4' ;;
    ipv6) printf '%s' 'direct-ipv6' ;;
    ipv4v6) printf '%s' 'direct-ipv4v6' ;;
    ipv6v4) printf '%s' 'direct-ipv6v4' ;;
    *) return 1 ;;
  esac
}

warn_unavailable_outbound_mode() {
  local mode="$1" answer
  load_network_status
  case "${mode}" in
    ipv6)
      if [ "${IPV6_STATUS}" = "unavailable" ]; then
        warn "当前检测不到 IPv6 出站；仅 IPv6 模式的规则很可能无法访问目标。"
        printf '仍要继续使用仅 IPv6 吗？[y/N]: '
        read -r answer
        case "${answer}" in y|Y|yes|YES) ;; *) MENU_CANCELLED=1; return ;; esac
      fi
      ;;
    ipv4)
      if [ "${IPV4_STATUS}" = "unavailable" ]; then
        warn "当前检测不到 IPv4 出站；仅 IPv4 模式的规则很可能无法访问目标。"
        printf '仍要继续使用仅 IPv4 吗？[y/N]: '
        read -r answer
        case "${answer}" in y|Y|yes|YES) ;; *) MENU_CANCELLED=1; return ;; esac
      fi
      ;;
    ipv6v4)
      [ "${IPV6_STATUS}" != "unavailable" ] || warn "IPv6 当前不可用，IPv6 优先模式会自动使用 IPv4 兜底。"
      ;;
    ipv4v6)
      [ "${IPV4_STATUS}" != "unavailable" ] || warn "IPv4 当前不可用，IPv4 优先模式会自动使用 IPv6 兜底。"
      ;;
  esac
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
  MENU_CANCELLED=0
  echo "  1. 仅 IPv4"
  echo "  2. 仅 IPv6"
  echo "  3. IPv4 优先，IPv6 兜底"
  echo "  4. IPv6 优先，IPv4 兜底"
  echo "  0. 返回上一级"
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
    0) MENU_CANCELLED=1; return ;;
    1) SELECTED_OUTBOUND_MODE="ipv4" ;;
    2) SELECTED_OUTBOUND_MODE="ipv6" ;;
    3) SELECTED_OUTBOUND_MODE="ipv4v6" ;;
    4) SELECTED_OUTBOUND_MODE="ipv6v4" ;;
    *) fail "无效的出站模式。" ;;
  esac
  warn_unavailable_outbound_mode "${SELECTED_OUTBOUND_MODE}"
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
  MENU_CHANGED=0
  echo
  echo "选择此规则使用的出站模式："
  choose_outbound_mode "${BASE_OUTBOUND_MODE}"
  [ "${MENU_CANCELLED}" -eq 0 ] || return
  echo "域名匹配类型："
  echo "  1. 精确匹配，例如 api.example.com"
  echo "  2. 后缀匹配，例如 example.com 会匹配其子域名"
  echo "  0. 返回上一级"
  printf '选择匹配类型 [1]: '
  read -r input
  case "${input:-1}" in
    0) MENU_CANCELLED=1; return ;;
    1) route_type="full" ;;
    2) route_type="domain" ;;
    *) fail "无效的域名匹配类型。" ;;
  esac
  while :; do
    printf '输入域名（输入 0 返回）: '
    read -r domain
    case "${domain}" in
      0) MENU_CANCELLED=1; return ;;
      ''|*[!A-Za-z0-9.-]*) echo "域名格式无效。" ;;
      *) break ;;
    esac
  done
  ensure_routes_file
  printf '%s|domain|%s:%s\n' "${SELECTED_OUTBOUND_MODE}" "${route_type}" "${domain}" >> "${ROUTES_FILE}"
  MENU_CHANGED=1
}

add_geosite_rule() {
  local geosite
  MENU_CHANGED=0
  echo
  echo "选择此规则使用的出站模式："
  choose_outbound_mode "${BASE_OUTBOUND_MODE}"
  [ "${MENU_CANCELLED}" -eq 0 ] || return
  while :; do
    printf '输入 geosite 名称（例如 youtube；输入 0 返回）: '
    read -r geosite
    case "${geosite}" in
      0) MENU_CANCELLED=1; return ;;
      ''|*[!A-Za-z0-9._@!:-]*) echo "geosite 名称格式无效。" ;;
      *) break ;;
    esac
  done
  ensure_routes_file
  printf '%s|geosite|%s\n' "${SELECTED_OUTBOUND_MODE}" "${geosite}" >> "${ROUTES_FILE}"
  MENU_CHANGED=1
}

delete_outbound_rule() {
  local input count temp_file
  MENU_CHANGED=0
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
        MENU_CHANGED=1
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
    show_network_status
    echo " 1. 设置基础出站模式"
    echo " 2. 查看全部出站规则"
    echo " 3. 添加域名规则"
    echo " 4. 添加 geosite 规则"
    echo " 5. 删除规则"
    echo " 6. 测试网络与出站规则"
    echo " 0. 返回主菜单"
    echo
    printf '请选择操作: '
    read -r input
    case "${input}" in
      1)
        echo
        choose_outbound_mode "${BASE_OUTBOUND_MODE}"
        [ "${MENU_CANCELLED}" -eq 0 ] || continue
        BASE_OUTBOUND_MODE="${SELECTED_OUTBOUND_MODE}"
        apply_config
        ;;
      2) list_outbound_rules ;;
      3) add_domain_rule; [ "${MENU_CHANGED}" -eq 1 ] || continue; apply_config ;;
      4) add_geosite_rule; [ "${MENU_CHANGED}" -eq 1 ] || continue; apply_config ;;
      5) delete_outbound_rule; [ "${MENU_CHANGED}" -eq 1 ] || continue; apply_config ;;
      6) test_network_and_rules ;;
      0) return ;;
      *) echo "无效选择，请重新输入。" ;;
    esac
    echo
    printf '按回车继续...'
    read -r _
  done
}

build_test_routing_rules() {
  TEST_ROUTING_RULES=""
  ensure_routes_file
  while IFS='|' read -r route_mode route_type route_value; do
    [ -n "${route_mode}" ] || continue
    route_tag="$(outbound_tag_for_mode "${route_mode}" 2>/dev/null || true)"
    [ -n "${route_tag}" ] || continue
    case "${route_type}" in
      domain) route_domain="${route_value}" ;;
      geosite) route_domain="geosite:${route_value}" ;;
      *) continue ;;
    esac
    [ -n "${route_domain}" ] || continue
    TEST_ROUTING_RULES="${TEST_ROUTING_RULES}      {\"type\": \"field\", \"domain\": [\"${route_domain}\"], \"outboundTag\": \"${route_tag}\"},
"
  done < "${ROUTES_FILE}"
}

find_test_port() {
  local attempt=0 candidate
  while [ "${attempt}" -lt 20 ]; do
    candidate=$((39000 + (($$ + attempt) % 1000)))
    if ! command -v ss >/dev/null 2>&1 || ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${candidate}$"; then
      TEST_PORT="${candidate}"
      return
    fi
    attempt=$((attempt + 1))
  done
  fail "无法找到可用的本地测试端口。"
}

ensure_tcpdump() {
  local answer
  command -v tcpdump >/dev/null 2>&1 && return 0

  warn "系统未安装 tcpdump。抓包测试需要安装它。"
  while :; do
    printf '是否现在安装 tcpdump？[Y/n]: '
    read -r answer
    case "${answer}" in
      ''|y|Y|yes|YES)
        command -v apt-get >/dev/null 2>&1 || {
          warn "未找到 apt-get，无法自动安装 tcpdump。"
          return 1
        }
        info "正在更新软件包索引..."
        if ! apt-get update; then
          warn "软件包索引更新失败，未安装 tcpdump。"
          return 1
        fi
        info "正在安装 tcpdump..."
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tcpdump; then
          warn "tcpdump 安装失败。"
          return 1
        fi
        if command -v tcpdump >/dev/null 2>&1; then
          ok "tcpdump 安装完成。"
          return 0
        fi
        warn "安装命令已完成，但仍未找到 tcpdump。"
        return 1
        ;;
      n|N|no|NO)
        info "已取消安装 tcpdump。"
        return 1
        ;;
      *)
        echo "请输入 y 或 n；直接回车默认安装。"
        ;;
    esac
  done
}

capture_outbound_connections() {
  local input filter label status
  ensure_tcpdump || return
  while :; do
    echo
    echo "实时抓取 HTTPS 连接（仅显示包头，不抓取内容）："
    echo "  1. 监听 IPv4 HTTPS 连接"
    echo "  2. 监听 IPv6 HTTPS 连接"
    echo "  3. 同时监听 IPv4 与 IPv6 HTTPS 连接"
    echo "  0. 返回上一级"
    printf '请选择抓包类型: '
    read -r input
    case "${input}" in
      1) filter='ip and tcp port 443'; label='IPv4' ;;
      2) filter='ip6 and tcp port 443'; label='IPv6' ;;
      3) filter='(ip or ip6) and tcp port 443'; label='IPv4 / IPv6' ;;
      0) return ;;
      *) echo "无效选择，请重新输入。"; continue ;;
    esac
    echo
    echo "即将监听 ${label} HTTPS 连接，最长 90 秒，可按 Ctrl+C 提前结束。"
    echo "请关注 VPS 对外连接（VPS 地址.临时端口 > 目标地址.443）。"
    echo "客户端 > VPS:443 属于入站 VLESS 流量，不代表代理出站。"
    echo
    if command -v timeout >/dev/null 2>&1; then
      if timeout 90 tcpdump -ni any -nn -l "${filter}"; then
        :
      else
        status=$?
        case "${status}" in
          124|130) : ;;
          *) warn "tcpdump 已结束，退出码：${status}" ;;
        esac
      fi
    else
      echo "未找到 timeout，将由你按 Ctrl+C 结束抓包。"
      if tcpdump -ni any -nn -l "${filter}"; then
        :
      else
        status=$?
        [ "${status}" -eq 130 ] || warn "tcpdump 已结束，退出码：${status}"
      fi
    fi
    return
  done
}

cleanup_rule_test() {
  if [ -n "${TEST_PID:-}" ] && kill -0 "${TEST_PID}" >/dev/null 2>&1; then
    kill "${TEST_PID}" >/dev/null 2>&1 || true
    wait "${TEST_PID}" 2>/dev/null || true
  fi
  rm -f "${TEST_CONFIG:-}" "${TEST_ACCESS_LOG:-}" "${TEST_ERROR_LOG:-}" "${TEST_RUNTIME_LOG:-}" "${TEST_CHECK_LOG:-}"
  TEST_PID=""
}

write_rule_test_config() {
  build_test_routing_rules
  case "${BASE_OUTBOUND_MODE}" in
    ipv4|ipv6|ipv4v6|ipv6v4) TEST_BASE_TAG="$(outbound_tag_for_mode "${BASE_OUTBOUND_MODE}")" ;;
    *) fail "基础出站模式无效。" ;;
  esac
  cat > "${TEST_CONFIG}" <<CONFIG
{
  "log": {
    "loglevel": "warning",
    "access": "${TEST_ACCESS_LOG}",
    "error": "${TEST_ERROR_LOG}"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${TEST_PORT},
      "protocol": "socks",
      "tag": "rule-test-in",
      "settings": {"udp": false}
    }
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
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
${TEST_ROUTING_RULES}      {"type": "field", "inboundTag": ["rule-test-in"], "outboundTag": "${TEST_BASE_TAG}"}
    ]
  }
}
CONFIG
}

test_selected_outbound_rule() {
  local input count selected_rule route_mode route_type route_value default_url test_url expected_tag http_code actual_tag
  MENU_CHANGED=0
  ensure_routes_file
  count="$(awk 'NF { number++ } END { print number + 0 }' "${ROUTES_FILE}")"
  [ "${count}" -gt 0 ] || { echo "暂无可测试的规则。"; return; }
  list_outbound_rules
  while :; do
    printf '输入要测试的规则编号（0 返回）: '
    read -r input
    case "${input}" in
      0) return ;;
      ''|*[!0-9]*) echo "请输入有效编号。" ;;
      *)
        [ "${input}" -ge 1 ] && [ "${input}" -le "${count}" ] || { echo "编号超出范围。"; continue; }
        selected_rule="$(awk -F'|' -v target="${input}" 'NF { number++ } number == target { print; exit }' "${ROUTES_FILE}")"
        break
        ;;
    esac
  done
  IFS='|' read -r route_mode route_type route_value <<RULE
${selected_rule}
RULE
  expected_tag="$(outbound_tag_for_mode "${route_mode}")"
  if [ "${route_type}" = "domain" ]; then
    default_url="https://${route_value#*:}/"
  else
    default_url=""
  fi
  while :; do
    if [ -n "${default_url}" ]; then
      printf '测试 URL [%s]（输入 0 返回）: ' "${default_url}"
    else
      printf '测试 URL（必须命中该 geosite 规则；输入 0 返回）: '
    fi
    read -r test_url
    test_url="${test_url:-${default_url}}"
    case "${test_url}" in
      0) return ;;
      http://*|https://*)
        case "${test_url}" in *[[:space:]]*) echo "URL 不能包含空格。" ;; *) break ;; esac
        ;;
      *) echo "请输入以 http:// 或 https:// 开头的 URL。" ;;
    esac
  done

  TEST_CONFIG="$(mktemp /tmp/vvr-route-test.XXXXXX)"
  TEST_ACCESS_LOG="${TEST_CONFIG}.access"
  TEST_ERROR_LOG="${TEST_CONFIG}.error"
  TEST_RUNTIME_LOG="${TEST_CONFIG}.runtime"
  TEST_CHECK_LOG="${TEST_CONFIG}.check"
  TEST_PID=""
  trap 'cleanup_rule_test' INT TERM HUP
  find_test_port
  write_rule_test_config

  info "正在检查临时测试配置..."
  if ! XRAY_LOCATION_ASSET="${XRAY_ASSET_DIR}" "${XRAY_BIN}" run -test -config "${TEST_CONFIG}" >"${TEST_CHECK_LOG}" 2>&1; then
    echo "临时测试配置失败，以下是 Xray 原始错误信息：" >&2
    cat "${TEST_CHECK_LOG}" >&2
    cleanup_rule_test
    trap - INT TERM HUP
    return
  fi
  info "正在通过本机临时 SOCKS 测试规则..."
  XRAY_LOCATION_ASSET="${XRAY_ASSET_DIR}" "${XRAY_BIN}" run -config "${TEST_CONFIG}" >"${TEST_RUNTIME_LOG}" 2>&1 &
  TEST_PID=$!
  sleep 1
  if ! kill -0 "${TEST_PID}" >/dev/null 2>&1; then
    echo "临时测试服务启动失败，以下是 Xray 原始错误信息：" >&2
    cat "${TEST_RUNTIME_LOG}" >&2
    cleanup_rule_test
    trap - INT TERM HUP
    return
  fi
  if http_code="$(curl -sS --proxy "socks5h://127.0.0.1:${TEST_PORT}" --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' "${test_url}" 2>&1)"; then
    sleep 1
    actual_tag="$(grep -Eo 'direct-ipv(4v6|6v4|4|6)' "${TEST_ACCESS_LOG}" 2>/dev/null | tail -n 1 || true)"
    if [ "${actual_tag}" = "${expected_tag}" ]; then
      ok "规则测试成功：HTTP ${http_code}，实际命中 $(outbound_mode_label "${route_mode}")。"
    elif [ -n "${actual_tag}" ]; then
      warn "请求成功（HTTP ${http_code}），但实际命中 $(outbound_mode_label "${actual_tag#direct-}")，不是所选规则的 $(outbound_mode_label "${route_mode}")。请检查前序规则。"
    else
      warn "请求成功（HTTP ${http_code}），但未能从临时访问日志确认实际出站标签。"
    fi
  else
    warn "规则测试失败：${http_code}"
  fi
  cleanup_rule_test
  trap - INT TERM HUP
}

test_network_and_rules() {
  local input
  while :; do
    clear 2>/dev/null || true
    echo "=============================="
    echo " 网络与规则测试"
    echo "=============================="
    show_network_status
    echo " 1. 刷新 IPv4 / IPv6 出站状态"
    echo " 2. 测试指定出站规则"
    echo " 3. 实时抓取 IPv4 / IPv6 出站连接"
    echo " 0. 返回出站策略管理"
    echo
    printf '请选择操作: '
    read -r input
    case "${input}" in
      1) refresh_network_status ;;
      2) test_selected_outbound_rule ;;
      3) capture_outbound_connections ;;
      0) return ;;
      *) echo "无效选择，请重新输入。" ;;
    esac
    echo
    printf '按回车继续...'
    read -r _
  done
}

load_traffic_settings() {
  RESET_DAY="1"
  RESET_HOUR="0"
  RESET_MINUTE="0"
  if [ -f "${TRAFFIC_SETTINGS_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${TRAFFIC_SETTINGS_FILE}"
  fi
}

traffic_schedule_label() {
  load_traffic_settings
  printf '每月 %s 日 %02d:%02d' "${RESET_DAY}" "${RESET_HOUR}" "${RESET_MINUTE}"
}

configure_traffic_schedule() {
  local input day hour minute
  load_traffic_settings
  printf '每月重置日期（1-28）[%s]（输入 0 返回）: ' "${RESET_DAY}"
  read -r input
  [ "${input}" = "0" ] && return
  day="${input:-${RESET_DAY}}"
  case "${day}" in ''|*[!0-9]*) echo "日期无效。"; return ;; esac
  [ "${day}" -ge 1 ] && [ "${day}" -le 28 ] || { echo "日期必须为 1 到 28。"; return; }
  printf '重置时间（HH:MM）[%02d:%02d]: ' "${RESET_HOUR}" "${RESET_MINUTE}"
  read -r input
  input="${input:-$(printf '%02d:%02d' "${RESET_HOUR}" "${RESET_MINUTE}")}"
  case "${input}" in
    [0-9][0-9]:[0-9][0-9]) hour="${input%%:*}"; minute="${input##*:}" ;;
    *) echo "时间格式无效，请使用 HH:MM。"; return ;;
  esac
  [ "${hour#0}" -le 23 ] 2>/dev/null || { echo "小时必须为 00 到 23。"; return; }
  [ "${minute#0}" -le 59 ] 2>/dev/null || { echo "分钟必须为 00 到 59。"; return; }
  cat > "${TRAFFIC_SETTINGS_FILE}" <<SETTINGS
RESET_DAY='${day}'
RESET_HOUR='${hour#0}'
RESET_MINUTE='${minute#0}'
SETTINGS
  chmod 0600 "${TRAFFIC_SETTINGS_FILE}"
  ok "流量重置时间已设置为每月 ${day} 日 ${hour}:${minute}。"
  echo "下一次采集或 API 请求时按新周期计算，无需重启 Xray。"
}

traffic_status() {
  if [ ! -x "${TRAFFIC_SCRIPT}" ]; then
    echo "流量统计组件未安装。"
    return 0
  fi
  if ! systemctl is-active --quiet vvr-traffic-api.service; then
    warn "流量 API 服务未运行。"
  fi
  curl -fsS --max-time 5 "http://127.0.0.1:18080/api/traffic?token=$(cat "${CONFIG_DIR}/vvr-traffic.token" 2>/dev/null || true)" || warn "暂时无法读取流量统计。"
  echo
}

traffic_collect_now() {
  [ -x "${TRAFFIC_SCRIPT}" ] || { echo "流量统计组件未安装。"; return; }
  info "正在立即采集流量..."
  if ! /usr/bin/python3 "${TRAFFIC_SCRIPT}" --collect; then
    warn "流量采集失败，请确认 Xray 正常运行。"
  fi
}

traffic_reset() {
  local answer
  printf '确认将当前统计周期累计流量归零？[y/N]: '
  read -r answer
  case "${answer}" in y|Y|yes|YES) ;; *) return ;; esac
  if /usr/bin/python3 "${TRAFFIC_SCRIPT}" --reset; then
    ok "当前统计周期流量已归零。"
  else
    warn "流量统计重置失败。"
  fi
}

server_timezone() {
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl show --property=Timezone --value 2>/dev/null || date '+%Z'
  else
    date '+%Z'
  fi
}

configure_server_timezone() {
  local timezone answer input
  if ! command -v timedatectl >/dev/null 2>&1; then
    warn "未找到 timedatectl，无法通过管理菜单修改服务器时区。"
    echo "请手动安装 systemd 或执行：ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime"
    return
  fi
  echo "当前服务器时区：$(server_timezone)"
  while :; do
    echo "  1. Asia/Shanghai（中国标准时间）"
    echo "  2. UTC（协调世界时）"
    echo "  3. Europe/London（英国时间）"
    echo "  4. America/Los_Angeles（美国太平洋时间）"
    echo "  0. 返回上一级"
    printf '请选择服务器时区: '
    read -r input
    case "${input}" in
      1) timezone='Asia/Shanghai' ;;
      2) timezone='UTC' ;;
      3) timezone='Europe/London' ;;
      4) timezone='America/Los_Angeles' ;;
      0) return ;;
      *) echo "无效选择，请输入 0-4。"; continue ;;
    esac
    if timedatectl list-timezones 2>/dev/null | grep -Fxq "${timezone}"; then
      break
    fi
    echo "系统中未找到时区 ${timezone}，请确认 tzdata 已安装。"
  done
  printf '确认将服务器时区改为 %s？这会影响系统其他服务。[Y/n]: ' "${timezone}"
  read -r answer
  case "${answer}" in
    ''|y|Y|yes|YES) ;;
    n|N|no|NO) echo "已取消修改时区。"; return ;;
    *) echo "输入无效，已取消修改时区。"; return ;;
  esac
  if timedatectl set-timezone "${timezone}"; then
    ok "服务器时区已修改为：$(server_timezone)"
    echo "流量统计会从下一次采集开始使用新时区，无需重启 Xray。"
  else
    warn "服务器时区修改失败。"
  fi
}

manage_traffic() {
  local input
  while :; do
    clear 2>/dev/null || true
    echo "=============================="
    echo " 流量统计与 MiSub API"
    echo "=============================="
    echo " API 地址：127.0.0.1:18080/api/traffic"
    echo " 自动采集：每分钟一次；$(traffic_schedule_label)自动开始新周期"
    echo " 1. 查看当前流量"
    echo " 2. 立即采集一次"
    echo " 3. 重置当前周期流量"
    echo " 4. 查看 MiSub API 信息"
    echo " 5. 设置每月重置时间"
    echo " 6. 修改服务器时区（当前：$(server_timezone)）"
    echo " 0. 返回主菜单"
    echo
    printf '请选择操作: '
    read -r input
    case "${input}" in
      1) traffic_status ;;
      2) traffic_collect_now ;;
      3) traffic_reset ;;
      4)
        echo "接口：http://127.0.0.1:18080/api/traffic"
        echo "令牌：$(cat "${CONFIG_DIR}/vvr-traffic.token" 2>/dev/null || echo '未生成')"
        echo "说明：接口仅监听本机，请通过反向代理安全转发给 MiSub。"
        ;;
      5) configure_traffic_schedule ;;
      6) configure_server_timezone ;;
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

  API_INBOUND=",
    {
      \"listen\": \"127.0.0.1\",
      \"port\": 10085,
      \"protocol\": \"dokodemo-door\",
      \"tag\": \"api\",
      \"settings\": {\"address\": \"127.0.0.1\"}
    }"

  cat > "${CONFIG_FILE}" <<CONFIG
{
  "log": {"loglevel": "warning"},
  "stats": {},
  "policy": {"system": {"statsInboundUplink": true, "statsInboundDownlink": true}, "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}}},
  "api": {"tag": "api", "services": ["StatsService"]},
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
    }${API_INBOUND}${FALLBACK_INBOUND}
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct-ipv4", "settings": {"domainStrategy": "UseIPv4"}},
    {"protocol": "freedom", "tag": "direct-ipv6", "settings": {"domainStrategy": "UseIPv6"}},
    {"protocol": "freedom", "tag": "direct-ipv4v6", "settings": {"domainStrategy": "UseIPv4v6"}},
    {"protocol": "freedom", "tag": "direct-ipv6v4", "settings": {"domainStrategy": "UseIPv6v4"}},
    {"protocol": "blackhole", "tag": "block"},
    {"protocol": "freedom", "tag": "api"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
${FALLBACK_RULES}
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
${ROUTING_RULES}      {"type": "field", "inboundTag": ["vless-in"], "outboundTag": "${BASE_OUTBOUND_TAG}"}
    ]
  }
}
CONFIG
  chmod 0600 "${CONFIG_FILE}"
}

test_config() {
  local test_output
  test_output="$(mktemp /tmp/vvr-xray-test.XXXXXX)"
  info "正在检查 Xray 配置..."
  if ! XRAY_LOCATION_ASSET="${XRAY_ASSET_DIR}" "${XRAY_BIN}" run -test -config "${CONFIG_FILE}" >"${test_output}" 2>&1; then
    echo "配置检查失败，以下是 Xray 原始错误信息：" >&2
    cat "${test_output}" >&2
    rm -f "${test_output}"
    return 1
  fi
  rm -f "${test_output}"
  info "配置检查通过。"
}

apply_config() {
  backup_file="${CONFIG_FILE}.vvr.bak.$(date +%Y%m%d%H%M%S)"
  routes_backup_file="${ROUTES_FILE}.vvr.bak.$(date +%Y%m%d%H%M%S)"
  [ -f "${CONFIG_FILE}" ] && cp -a "${CONFIG_FILE}" "${backup_file}"
  [ -f "${ROUTES_FILE}" ] && cp -a "${ROUTES_FILE}" "${routes_backup_file}"
  write_config
  if ! test_config; then
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
  test_config || fail "Xray 配置检查失败。"
  info "正在重启 Xray..."
  systemctl restart xray
  systemctl is-active --quiet xray || fail "Xray 服务状态异常。"
  ok "Xray 服务已正常运行。"
}

uninstall_xray() {
  warn "即将卸载 Xray，并删除配置、服务文件、二进制和 vvr 管理命令。"
  printf '确认卸载？此操作不可恢复。[y/N]: '
  read -r input
  case "${input}" in y|Y|yes|YES) ;; *) return ;; esac
  systemctl stop xray >/dev/null 2>&1 || true
  systemctl disable xray >/dev/null 2>&1 || true
  systemctl disable --now vvr-traffic-api.service vvr-traffic-collector.timer >/dev/null 2>&1 || true
  rm -f "${SERVICE_FILE}" "${MANAGER_BIN}" "${XRAY_BIN}" "${TRAFFIC_SERVICE_FILE}" "${TRAFFIC_TIMER_FILE}" "${TRAFFIC_COLLECTOR_SERVICE_FILE}" "${TRAFFIC_SCRIPT}"
  rm -rf "${CONFIG_DIR}" "${XRAY_ASSET_DIR}" "${TRAFFIC_DIR}"
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
  echo " 7. 流量统计与 MiSub API"
  echo " 8. 重启 Xray"
  echo " 9. 查看服务状态"
  echo "10. 查看日志"
  echo "11. 重置当前节点"
  echo "12. 卸载并清理环境"
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
      7) manage_traffic ;;
      8) restart_xray ;;
      9) systemctl status xray --no-pager || true ;;
      10) journalctl -u xray -n 80 --no-pager || true ;;
      11) reset_node ;;
      12) uninstall_xray ;;
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
  echo "流量 API：127.0.0.1:18080/api/traffic（令牌见 /etc/xray/vvr-traffic.token）"
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
  write_traffic_components
  write_manager_command
  print_result
}

main "$@"
