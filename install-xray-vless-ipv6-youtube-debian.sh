#!/usr/bin/env bash
set -Eeuo pipefail

# Debian installer for VLESS + REALITY with IPv4/IPv6 YouTube split routing.

XRAY_BIN="/usr/local/bin/xray"
XRAY_ASSET_DIR="/usr/local/share/xray"
CONFIG_DIR="/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/xray.service"
META_FILE="${CONFIG_DIR}/vless-ipv6-youtube.env"
TMP_DIR=""

DEFAULT_PORT="443"
DEFAULT_SNI="www.sony.com"
DEFAULT_TAG="vvr-vless-ipv6-youtube"
FINGERPRINT="chrome"

BLUE=""
YELLOW=""
RED=""
GREEN=""
RESET=""
if [ -t 1 ]; then
  BLUE=$'\033[1;34m'
  YELLOW=$'\033[1;33m'
  RED=$'\033[1;31m'
  GREEN=$'\033[1;32m'
  RESET=$'\033[0m'
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
trap cleanup EXIT

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
  [[ "${PORT}" =~ ^[0-9]+$ ]] && [ "${PORT}" -ge 1 ] && [ "${PORT}" -le 65535 ] || fail "端口无效。"

  printf 'Reality SNI [%s]: ' "${DEFAULT_SNI}"
  read -r input
  SNI="${input:-${DEFAULT_SNI}}"
  [[ "${SNI}" =~ ^[A-Za-z0-9.-]+$ ]] || fail "SNI 格式无效。"

  printf '节点名称 [%s]: ' "${DEFAULT_TAG}"
  read -r input
  TAG="${input:-${DEFAULT_TAG}}"

  SERVER_IPV4="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  SERVER_IPV6="$(curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
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
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      }
    }
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
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": ["geosite:youtube"],
        "outboundTag": "direct-ipv6"
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
PUBLIC_KEY='${PUBLIC_KEY}'
SHORT_ID='${SHORT_ID}'
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
  echo "服务状态：systemctl status xray --no-pager"
  echo "日志查看：journalctl -u xray -f"
  echo
  echo "分流策略："
  echo "  普通域名：direct-ipv4（UseIPv4）"
  echo "  YouTube：direct-ipv6（UseIPv6，仅使用 AAAA）"
  echo "  YouTube IPv6 不可用时不会回退到 IPv4。"
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
  print_result
}

main "$@"
