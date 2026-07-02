#!/usr/bin/env sh
set -eu

XRAY_BIN="/usr/local/xray/xray"
XRAY_DIR="/usr/local/xray"
CONFIG_DIR="/etc/xray"
CONFIG_FILE="/etc/xray/config.json"
SERVICE_FILE="/etc/init.d/xray"
LOG_FILE="/var/log/xray.log"
ERR_LOG_FILE="/var/log/xray.err"
META_FILE="/etc/xray/vless-reality.env"
MANAGER_BIN="/usr/local/bin/vvr"
TMP_DIR="/tmp/xray-install.$$"
FINGERPRINT="chrome"
DEFAULT_PORT="443"
DEFAULT_SNI="www.sony.com"
SPIDERX="%2F"

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

fail() {
  echo "${RED}[ERR]${RESET} $*" >&2
  exit 1
}

info() {
  echo "${BLUE}[INFO]${RESET} $*"
}

warn() {
  echo "${YELLOW}[WARN]${RESET} $*"
}

ok() {
  echo "${GREEN}[OK]${RESET} $*"
}

need_root() {
  [ "$(id -u)" = "0" ] || fail "Please run this script as root."
}

need_alpine() {
  [ -f /etc/alpine-release ] || fail "This script only supports Alpine Linux."
  command -v rc-service >/dev/null 2>&1 || fail "OpenRC was not found."
}

prompt_port() {
  while :; do
    printf "请输入监听端口，回车默认 %s: " "$DEFAULT_PORT"
    read -r PORT
    PORT="${PORT:-$DEFAULT_PORT}"
    case "$PORT" in
      *[!0-9]*|"") echo "端口必须是 1 到 65535 之间的数字。" ;;
      *)
        if [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
          break
        fi
        echo "端口必须在 1 到 65535 之间。"
        ;;
    esac
  done
}

prompt_sni() {
  while :; do
    printf "请输入 REALITY SNI，回车默认 %s: " "$DEFAULT_SNI"
    read -r SNI
    SNI="${SNI:-$DEFAULT_SNI}"
    SNI="$(printf "%s" "$SNI" | tr -d '[:space:]')"
    [ -n "$SNI" ] || {
      echo "SNI 不能为空。"
      continue
    }
    case "$SNI" in
      *:*) echo "只需要输入域名，不要带 :443。例如：www.sony.com。" ;;
      */*) echo "只需要输入域名，不要带 https:// 或路径。" ;;
      *) break ;;
    esac
  done
  DEST="${SNI}:443"
}

make_default_tag() {
  RANDOM_SUFFIX="$(LC_ALL=C tr -dc 'A-Za-z' < /dev/urandom | head -c 6)"
  if [ -z "$RANDOM_SUFFIX" ]; then
    RANDOM_SUFFIX="ABCDEF"
  fi
  DEFAULT_TAG="VRL${RANDOM_SUFFIX}"
}

prompt_node_name() {
  make_default_tag
  while :; do
    printf "请输入节点名称，回车默认 %s: " "$DEFAULT_TAG"
    read -r TAG
    TAG="${TAG:-$DEFAULT_TAG}"
    case "$TAG" in
      *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*)
        echo "节点名称只能包含英文、数字、点、下划线和短横线。"
        ;;
      *) break ;;
    esac
  done
}

confirm_inputs() {
  echo
  echo "安装参数确认："
  echo "  监听端口：$PORT"
  echo "  SNI：     $SNI"
  echo "  伪装目标：$DEST"
  echo "  节点名称：$TAG"
  echo
  printf "确认继续安装？[Y/n]: "
  read -r CONFIRM
  case "${CONFIRM:-Y}" in
    y|Y|yes|YES) ;;
    *) fail "已取消安装。" ;;
  esac
}

handle_existing_install() {
  if [ -f "$SERVICE_FILE" ] || [ -f "$CONFIG_FILE" ] || [ -x "$XRAY_BIN" ]; then
    warn "检测到已有 Xray 安装。"
    printf "是否停止旧服务并替换现有 Xray 配置？[y/N]: "
    read -r REINSTALL
    case "$REINSTALL" in
      y|Y|yes|YES)
        if command -v rc-service >/dev/null 2>&1; then
          rc-service xray stop >/dev/null 2>&1 || true
        fi
        if [ -f "$CONFIG_FILE" ]; then
          BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
          cp "$CONFIG_FILE" "$BACKUP_FILE"
          info "Old config backed up to ${BACKUP_FILE}"
        fi
        ;;
      *)
        fail "已取消，避免覆盖现有安装。"
        ;;
    esac
  fi
}

install_deps() {
  info "Installing dependencies..."
  apk update
  apk add --no-cache ca-certificates curl wget unzip openssl iproute2
}

detect_arch() {
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64)
      XRAY_ZIP="Xray-linux-64.zip"
      ;;
    aarch64|arm64)
      XRAY_ZIP="Xray-linux-arm64-v8a.zip"
      ;;
    armv7l)
      XRAY_ZIP="Xray-linux-arm32-v7a.zip"
      ;;
    *)
      fail "Unsupported architecture: $ARCH"
      ;;
  esac
  XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ZIP}"
}

check_port() {
  if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":${PORT} "; then
    fail "Port ${PORT} is already in use."
  fi
}

download_xray() {
  info "Downloading Xray-core for ${ARCH}..."
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  cd "$TMP_DIR"
  wget -O "$XRAY_ZIP" "$XRAY_URL"
  unzip -o "$XRAY_ZIP"
  [ -f xray ] || fail "Xray binary was not found in the release package."
}

install_xray() {
  info "Installing Xray binary..."
  mkdir -p "$XRAY_DIR" "$CONFIG_DIR"
  cp "$TMP_DIR/xray" "$XRAY_BIN"
  chmod +x "$XRAY_BIN"
}

generate_values() {
  info "Generating UUID, REALITY key pair, and shortId..."
  UUID="$("$XRAY_BIN" uuid)"
  KEYS="$("$XRAY_BIN" x25519 2>&1)"
  PRIVATE_KEY="$(printf "%s\n" "$KEYS" | awk '{line=tolower($0); if (line ~ /private/ && line ~ /key/) {sub(/.*[:=][ \t]*/, "", $0); gsub(/[",]/, "", $0); print $1; exit}}')"
  PUBLIC_KEY="$(printf "%s\n" "$KEYS" | awk '{line=tolower($0); if (line ~ /public/ && line ~ /key/) {sub(/.*[:=][ \t]*/, "", $0); gsub(/[",]/, "", $0); print $1; exit}}')"
  SHORT_ID="$(openssl rand -hex 8)"

  [ -n "$UUID" ] || fail "Failed to generate UUID."
  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    warn "Could not parse xray x25519 output:"
    printf "%s\n" "$KEYS"
  fi
  [ -n "$PRIVATE_KEY" ] || fail "Failed to generate REALITY private key."
  [ -n "$PUBLIC_KEY" ] || fail "Failed to generate REALITY public key."
  [ -n "$SHORT_ID" ] || fail "Failed to generate shortId."
}

write_config() {
  info "Writing Xray config..."
  cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "tag": "${TAG}",
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
          "dest": "${DEST}",
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
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

test_config() {
  info "Testing Xray config..."
  "$XRAY_BIN" run -test -config "$CONFIG_FILE"
}

write_openrc_service() {
  info "Writing OpenRC service..."
  cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="/usr/local/xray/xray"
command_args="run -config /etc/xray/config.json"
pidfile="/run/xray.pid"
command_background="yes"
output_log="${LOG_FILE}"
error_log="${ERR_LOG_FILE}"

depend() {
    need net
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
EOF
  chmod +x "$SERVICE_FILE"
}

start_service() {
  info "Enabling and restarting Xray..."
  rc-update add xray default >/dev/null 2>&1 || true
  if ! rc-service xray restart; then
    echo
    warn "Xray failed to start. Recent logs:"
    tail -40 "$ERR_LOG_FILE" 2>/dev/null || tail -40 "$LOG_FILE" 2>/dev/null || true
    fail "Service start failed."
  fi
  sleep 2
  rc-service xray status >/dev/null 2>&1 || fail "Xray service status is abnormal."
  ok "Xray service is running."
}

detect_server_addr() {
  if [ -n "${CUSTOM_IP:-}" ]; then
    SERVER_ADDR="$CUSTOM_IP"
    info "Using CUSTOM_IP: ${SERVER_ADDR}"
    return
  fi

  SERVER_ADDR=""
  for IP_URL in \
    "https://api.ipify.org" \
    "https://ipinfo.io/ip" \
    "https://ifconfig.me" \
    "https://icanhazip.com"; do
    SERVER_ADDR="$(curl -4fsS --max-time 5 "$IP_URL" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$SERVER_ADDR" in
      *.*.*.*) break ;;
      *) SERVER_ADDR="" ;;
    esac
  done

  if [ -z "$SERVER_ADDR" ]; then
    SERVER_ADDR="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  fi
  if [ -z "$SERVER_ADDR" ]; then
    SERVER_ADDR="YOUR_SERVER_IP"
  fi
}

save_metadata() {
  cat > "$META_FILE" <<EOF
PORT=${PORT}
SNI=${SNI}
DEST=${DEST}
TAG=${TAG}
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SERVER_ADDR=${SERVER_ADDR}
FINGERPRINT=${FINGERPRINT}
SPIDERX=${SPIDERX}
EOF
  chmod 600 "$META_FILE"
}

write_manager_command() {
  info "Installing vvr management command..."
  cat > "$MANAGER_BIN" <<'EOF'
#!/usr/bin/env sh
set -eu

XRAY_BIN="/usr/local/xray/xray"
XRAY_DIR="/usr/local/xray"
CONFIG_DIR="/etc/xray"
CONFIG_FILE="/etc/xray/config.json"
SERVICE_FILE="/etc/init.d/xray"
LOG_FILE="/var/log/xray.log"
ERR_LOG_FILE="/var/log/xray.err"
META_FILE="/etc/xray/vless-reality.env"
MANAGER_BIN="/usr/local/bin/vvr"
DEFAULT_SNI="www.sony.com"
DEFAULT_PORT="443"

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

info() { echo "${BLUE}[INFO]${RESET} $*"; }
warn() { echo "${YELLOW}[WARN]${RESET} $*"; }
ok() { echo "${GREEN}[OK]${RESET} $*"; }
fail() { echo "${RED}[ERR]${RESET} $*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" = "0" ] || fail "请使用 root 用户运行 vvr。"
}

load_state() {
  [ -f "$META_FILE" ] || fail "未找到节点信息文件：$META_FILE。请先重新运行安装脚本。"
  # shellcheck disable=SC1090
  . "$META_FILE"
  FINGERPRINT="${FINGERPRINT:-chrome}"
  SPIDERX="${SPIDERX:-%2F}"
  DEST="${DEST:-${SNI}:443}"
}

save_state() {
  cat > "$META_FILE" <<STATE
PORT=${PORT}
SNI=${SNI}
DEST=${DEST}
TAG=${TAG}
UUID=${UUID}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
SERVER_ADDR=${SERVER_ADDR}
FINGERPRINT=${FINGERPRINT}
SPIDERX=${SPIDERX}
STATE
  chmod 600 "$META_FILE"
}

detect_server_addr() {
  if [ -n "${CUSTOM_IP:-}" ]; then
    SERVER_ADDR="$CUSTOM_IP"
    return
  fi

  SERVER_ADDR=""
  for IP_URL in \
    "https://api.ipify.org" \
    "https://ipinfo.io/ip" \
    "https://ifconfig.me" \
    "https://icanhazip.com"; do
    SERVER_ADDR="$(curl -4fsS --max-time 5 "$IP_URL" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$SERVER_ADDR" in
      *.*.*.*) break ;;
      *) SERVER_ADDR="" ;;
    esac
  done

  if [ -z "$SERVER_ADDR" ]; then
    SERVER_ADDR="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  fi
  if [ -z "$SERVER_ADDR" ]; then
    SERVER_ADDR="YOUR_SERVER_IP"
  fi
}

make_uri() {
  URI="vless://${UUID}@${SERVER_ADDR}:${PORT}?type=tcp&encryption=none&security=reality&pbk=${PUBLIC_KEY}&fp=${FINGERPRINT}&sni=${SNI}&sid=${SHORT_ID}&spx=${SPIDERX}&flow=xtls-rprx-vision#${TAG}"
}

show_node() {
  load_state
  make_uri
  echo
  echo "节点信息："
  echo "  服务器：${SERVER_ADDR}"
  echo "  端口：  ${PORT}"
  echo "  SNI：   ${SNI}"
  echo "  名称：  ${TAG}"
  echo
  echo "客户端链接："
  echo "$URI"
}

prompt_port() {
  CURRENT_PORT="$1"
  while :; do
    printf "请输入监听端口，回车默认 %s: " "$CURRENT_PORT"
    read -r NEW_PORT
    NEW_PORT="${NEW_PORT:-$CURRENT_PORT}"
    case "$NEW_PORT" in
      *[!0-9]*|"") echo "端口必须是 1 到 65535 之间的数字。" ;;
      *)
        if [ "$NEW_PORT" -ge 1 ] && [ "$NEW_PORT" -le 65535 ]; then
          PORT="$NEW_PORT"
          break
        fi
        echo "端口必须在 1 到 65535 之间。"
        ;;
    esac
  done
}

prompt_sni() {
  CURRENT_SNI="$1"
  while :; do
    printf "请输入 REALITY SNI，回车默认 %s: " "$CURRENT_SNI"
    read -r NEW_SNI
    NEW_SNI="${NEW_SNI:-$CURRENT_SNI}"
    NEW_SNI="$(printf "%s" "$NEW_SNI" | tr -d '[:space:]')"
    case "$NEW_SNI" in
      "") echo "SNI 不能为空。" ;;
      *:*) echo "只需要输入域名，不要带 :443。例如：www.sony.com。" ;;
      */*) echo "只需要输入域名，不要带 https:// 或路径。" ;;
      *) SNI="$NEW_SNI"; DEST="${SNI}:443"; break ;;
    esac
  done
}

make_default_tag() {
  RANDOM_SUFFIX="$(LC_ALL=C tr -dc 'A-Za-z' < /dev/urandom | head -c 6)"
  [ -n "$RANDOM_SUFFIX" ] || RANDOM_SUFFIX="ABCDEF"
  DEFAULT_TAG="VRL${RANDOM_SUFFIX}"
}

prompt_tag() {
  CURRENT_TAG="$1"
  [ -n "$CURRENT_TAG" ] || {
    make_default_tag
    CURRENT_TAG="$DEFAULT_TAG"
  }
  while :; do
    printf "请输入节点名称，回车默认 %s: " "$CURRENT_TAG"
    read -r NEW_TAG
    NEW_TAG="${NEW_TAG:-$CURRENT_TAG}"
    case "$NEW_TAG" in
      *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*)
        echo "节点名称只能包含英文、数字、点、下划线和短横线。"
        ;;
      *) TAG="$NEW_TAG"; break ;;
    esac
  done
}

check_port_available() {
  OLD_PORT="$1"
  if [ "$PORT" != "$OLD_PORT" ] && command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":${PORT} "; then
    fail "端口 ${PORT} 已被占用，请换一个端口。"
  fi
}

write_config() {
  cat > "$CONFIG_FILE" <<CONFIG
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "tag": "${TAG}",
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
          "dest": "${DEST}",
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
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
CONFIG
}

restart_xray() {
  "$XRAY_BIN" run -test -config "$CONFIG_FILE"
  rc-service xray restart
  ok "Xray 已重启。"
}

modify_node() {
  load_state
  OLD_PORT="$PORT"
  echo
  echo "当前配置："
  echo "  端口：${PORT}"
  echo "  SNI： ${SNI}"
  echo "  名称：${TAG}"
  echo
  prompt_port "$PORT"
  prompt_sni "$SNI"
  prompt_tag "$TAG"
  check_port_available "$OLD_PORT"
  write_config
  restart_xray
  detect_server_addr
  save_state
  show_node
}

service_status() {
  rc-service xray status || true
}

show_logs() {
  echo
  echo "错误日志：${ERR_LOG_FILE}"
  tail -80 "$ERR_LOG_FILE" 2>/dev/null || echo "暂无错误日志。"
  echo
  echo "运行日志：${LOG_FILE}"
  tail -80 "$LOG_FILE" 2>/dev/null || echo "暂无运行日志。"
}

uninstall_xray() {
  echo
  warn "即将卸载 Xray，并删除配置、服务文件、日志和 vvr 管理命令。"
  printf "确认卸载？此操作不可恢复。[y/N]: "
  read -r CONFIRM
  case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *) fail "已取消卸载。" ;;
  esac

  rc-service xray stop >/dev/null 2>&1 || true
  rc-update del xray default >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  rm -rf "$CONFIG_DIR"
  rm -rf "$XRAY_DIR"
  rm -f "$LOG_FILE" "$ERR_LOG_FILE"
  rm -f "$MANAGER_BIN"
  ok "已卸载完成。需要重装时重新运行 GitHub 安装脚本即可。"
}

show_menu() {
  clear 2>/dev/null || true
  echo "=============================="
  echo " VLESS + Reality 管理面板"
  echo "=============================="
  echo " 1. 查看节点链接"
  echo " 2. 修改端口 / SNI / 节点名称"
  echo " 3. 重启 Xray"
  echo " 4. 查看服务状态"
  echo " 5. 查看日志"
  echo " 6. 卸载并清理环境"
  echo " 0. 退出"
  echo
  printf "请选择操作: "
}

main() {
  need_root
  while :; do
    show_menu
    read -r CHOICE
    case "$CHOICE" in
      1) show_node ;;
      2) modify_node ;;
      3) load_state; restart_xray ;;
      4) service_status ;;
      5) show_logs ;;
      6) uninstall_xray; exit 0 ;;
      0) exit 0 ;;
      *) echo "无效选择，请重新输入。" ;;
    esac
    echo
    printf "按回车返回菜单..."
    read -r _
  done
}

main "$@"
EOF
  chmod +x "$MANAGER_BIN"
}

print_result() {
  URI="vless://${UUID}@${SERVER_ADDR}:${PORT}?type=tcp&encryption=none&security=reality&pbk=${PUBLIC_KEY}&fp=${FINGERPRINT}&sni=${SNI}&sid=${SHORT_ID}&spx=${SPIDERX}&flow=xtls-rprx-vision#${TAG}"

  echo
  echo "Xray VLESS + Vision + REALITY installation completed."
  echo
  echo "Server:    ${SERVER_ADDR}"
  echo "Port:      ${PORT}"
  echo "UUID:      ${UUID}"
  echo "PublicKey: ${PUBLIC_KEY}"
  echo "ShortId:   ${SHORT_ID}"
  echo "SNI:       ${SNI}"
  echo "Name:      ${TAG}"
  echo
  echo "Client URL:"
  echo "${URI}"
  echo
  echo "Config:  ${CONFIG_FILE}"
  echo "Service: ${SERVICE_FILE}"
  echo "Panel:   vvr"
  echo
  echo "Management commands:"
  echo "  Panel:   vvr"
  echo "  Start:   rc-service xray start"
  echo "  Stop:    rc-service xray stop"
  echo "  Restart: rc-service xray restart"
  echo "  Status:  rc-service xray status"
  echo "  Log:     tail -f ${LOG_FILE}"
  echo "  Error:   tail -f ${ERR_LOG_FILE}"
}

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

need_root
need_alpine
prompt_port
prompt_sni
prompt_node_name
confirm_inputs
handle_existing_install
install_deps
detect_arch
check_port
download_xray
install_xray
generate_values
write_config
test_config
write_openrc_service
start_service
detect_server_addr
save_metadata
write_manager_command
print_result
