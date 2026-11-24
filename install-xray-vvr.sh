#!/usr/bin/env sh
set -eu

# Universal Debian/Ubuntu (systemd) & Alpine Linux (OpenRC) installer and manager
# for Xray-core with VLESS + Vision + REALITY, VLESS + XHTTP + REALITY,
# Hysteria 2 (native Xray inbound), and Shadowsocks in a single process.

XRAY_DIR="/usr/local/xray"
XRAY_BIN="${XRAY_DIR}/xray"
CONFIG_DIR="/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
META_FILE="${CONFIG_DIR}/vvr.env"
ROUTES_FILE="${CONFIG_DIR}/vvr-routing.rules"
CLIENTS_FILE="${CONFIG_DIR}/vvr-clients.db"
XHTTP_CLIENTS_FILE="${CONFIG_DIR}/vvr-xhttp-clients.db"
HY2_CLIENTS_FILE="${CONFIG_DIR}/vvr-hy2-clients.db"
OUTBOUNDS_FILE="${CONFIG_DIR}/vvr-outbounds.db"
USER_ROUTES_FILE="${CONFIG_DIR}/vvr-user-routes.db"
INBOUND_ROUTES_FILE="${CONFIG_DIR}/vvr-inbound-routes.db"
MANAGER_BIN="/usr/local/bin/vvr"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/xray.service"
OPENRC_SERVICE_FILE="/etc/init.d/xray"
LOG_FILE="/var/log/xray.log"
ERR_LOG_FILE="/var/log/xray.err"
SS_INBOUND_TAG="shadowsocks-in"
XHTTP_INBOUND_TAG="vless-xhttp-in"
HY2_INBOUND_TAG="hysteria2-in"
TRAFFIC_DIR="/var/lib/vvr"
TRAFFIC_DB="${TRAFFIC_DIR}/traffic.db"
TRAFFIC_TOKEN_FILE="${CONFIG_DIR}/vvr-traffic.token"
TRAFFIC_SETTINGS_FILE="${CONFIG_DIR}/vvr-traffic-settings.env"
TRAFFIC_API_SETTINGS_FILE="${CONFIG_DIR}/vvr-traffic-api.env"
TRAFFIC_SCRIPT="/usr/local/libexec/vvr-traffic.py"
TRAFFIC_SYSTEMD_SERVICE_FILE="/etc/systemd/system/vvr-traffic-api.service"
TRAFFIC_SYSTEMD_COLLECTOR_FILE="/etc/systemd/system/vvr-traffic-collector.service"
TRAFFIC_SYSTEMD_TIMER_FILE="/etc/systemd/system/vvr-traffic-collector.timer"
TRAFFIC_OPENRC_SERVICE_FILE="/etc/init.d/vvr-traffic-api"
TRAFFIC_OPENRC_CRON_MARKER="# vvr-traffic-collector"

DEFAULT_IPV4_PORT="443"
DEFAULT_IPV6_PORT="8443"
DEFAULT_SNI="www.sony.com"
DEFAULT_FALLBACK_PORT="4431"
DEFAULT_LIMIT_AFTER_BYTES="1048576"
DEFAULT_LIMIT_UPLOAD_BPS="65536"
DEFAULT_LIMIT_UPLOAD_BURST="131072"
DEFAULT_LIMIT_DOWNLOAD_BPS="131072"
DEFAULT_LIMIT_DOWNLOAD_BURST="262144"
DEFAULT_BASE_OUTBOUND_MODE="ipv4"
DEFAULT_HAPPY_EYEBALLS_DELAY_MS="100"
DEFAULT_BLOCK_PRIVATE_IP="1"
DEFAULT_TRAFFIC_ENABLED="0"
DEFAULT_TRAFFIC_API_PORT="18080"
DEFAULT_XRAY_API_PORT="10085"
DEFAULT_XHTTP_PORT="2053"
DEFAULT_XHTTP_MODE="auto"
DEFAULT_XHTTP_NAME="vvr-xhttp"
DEFAULT_HY2_PORT="443"
DEFAULT_HY2_SNI="bing.com"
DEFAULT_HY2_CERT_FILE="${CONFIG_DIR}/hy2-cert.pem"
DEFAULT_HY2_KEY_FILE="${CONFIG_DIR}/hy2-key.pem"
DEFAULT_HY2_NAME="hy2-node"
DEFAULT_SS_PORT="8388"
DEFAULT_SS_NETWORK="tcp"
DEFAULT_SS_METHOD="2022-blake3-aes-128-gcm"
DEFAULT_SS_NAME="ss-node"
FINGERPRINT="chrome"
SPIDERX="%2F"

GITHUB_REPO="${VVR_GITHUB_REPO:-xhpx7301/vvr}"
GITHUB_BRANCH="${VVR_GITHUB_BRANCH:-main}"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}"
DEFAULT_INSTALLER_URL="${GITHUB_RAW_BASE}/install-xray-vvr.sh"

OS_TYPE=""
INIT_TYPE=""
SERVICE_FILE=""
TMP_DIR=""
INSTALL_ROLLBACK_DIR=""
INSTALL_BACKUP_READY="0"
EXISTING_SERVICE_WAS_RUNNING="0"
EXISTING_SERVICE_WAS_ENABLED="0"
INSTALL_COMMITTED="0"
LOW_MEM_THRESHOLD_KB="131072"
LOW_MEM_SWAP_FILE="${VVR_SWAP_FILE:-/swapfile}"
LOW_MEM_SWAP_SIZE_MB="${VVR_SWAP_SIZE_MB:-256}"
LOW_MEM_MODE="0"
MENU_RETURNED="0"
PENDING_ROUTES_BACKUP=""
PENDING_CLIENTS_BACKUP=""
PENDING_XHTTP_CLIENTS_BACKUP=""
PENDING_HY2_CLIENTS_BACKUP=""
PENDING_OUTBOUNDS_BACKUP=""
PENDING_USER_ROUTES_BACKUP=""
PENDING_INBOUND_ROUTES_BACKUP=""

if [ -t 1 ]; then
  BLUE="$(printf '\033[1;34m')"
  YELLOW="$(printf '\033[1;33m')"
  RED="$(printf '\033[1;31m')"
  GREEN="$(printf '\033[1;32m')"
  CYAN="$(printf '\033[1;36m')"
  DIM="$(printf '\033[2m')"
  BOLD="$(printf '\033[1m')"
  RESET="$(printf '\033[0m')"
else
  BLUE=""
  YELLOW=""
  RED=""
  GREEN=""
  CYAN=""
  DIM=""
  BOLD=""
  RESET=""
fi

info() { printf '%s\n' "${BLUE}[INFO]${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}[WARN]${RESET} $*" >&2; }
ok() { printf '%s\n' "${GREEN}[OK]${RESET} $*"; }
fail() { printf '%s\n' "${RED}[ERR]${RESET} $*" >&2; exit 1; }

pause_menu() {
  MSG="${1:-按回车继续...}"
  echo
  printf '%s' "${MSG}"
  read -r _ || true
}

xray_version_short() {
  if [ -x "${XRAY_BIN}" ]; then
    VER_RAW="$("${XRAY_BIN}" version 2>/dev/null | head -n 1 | awk '{print $2}' || true)"
    [ -n "${VER_RAW}" ] && printf 'v%s' "${VER_RAW#v}" || printf '%s' '未知'
  else
    printf '%s' '未安装'
  fi
}

rules_count() {
  ensure_routes_file
  awk 'NF {count++} END {print count+0}' "${ROUTES_FILE}"
}

firewall_ports_summary() {
  TCP_PORTS=""
  UDP_PORTS=""
  if vless_is_configured; then
    if [ "$(client_count ipv4)" -gt 0 ] && [ -n "${IPV4_PORT:-}" ]; then
      TCP_PORTS="${TCP_PORTS:+${TCP_PORTS},}${IPV4_PORT}"
    fi
    if [ "$(client_count ipv6)" -gt 0 ] && [ -n "${IPV6_PORT:-}" ]; then
      TCP_PORTS="${TCP_PORTS:+${TCP_PORTS},}${IPV6_PORT}"
    fi
  fi
  if xhttp_is_configured; then
    TCP_PORTS="${TCP_PORTS:+${TCP_PORTS},}${XHTTP_PORT}"
  fi
  if ss_is_configured; then
    TCP_PORTS="${TCP_PORTS:+${TCP_PORTS},}${SS_PORT}"
    case "${SS_NETWORK:-tcp}" in
      *udp*) UDP_PORTS="${UDP_PORTS:+${UDP_PORTS},}${SS_PORT}" ;;
    esac
  fi
  if hy2_is_configured; then
    UDP_PORTS="${UDP_PORTS:+${UDP_PORTS},}${HY2_PORT}"
  fi
  OUT=""
  [ -z "${TCP_PORTS}" ] || OUT="TCP ${TCP_PORTS}"
  if [ -n "${UDP_PORTS}" ]; then
    OUT="${OUT:+${OUT} | }UDP ${UDP_PORTS}"
  fi
  printf '%s' "${OUT:-无}"
}

show_listening_ports() {
  if ! command -v ss >/dev/null 2>&1; then
    echo "未安装 ss，无法检查监听端口。"
    return 0
  fi
  echo "当前 Xray 相关监听端口："
  ss -H -ltnup 2>/dev/null | grep -i xray || ss -ltnu 2>/dev/null | head -n 20 || true
}

cleanup() {
  if [ -n "${TMP_DIR:-}" ] && [ -d "${TMP_DIR}" ]; then
    rm -rf "${TMP_DIR}"
  fi
}

need_root() {
  [ "$(id -u)" -eq 0 ] || fail "请使用 root 用户运行此脚本。"
}

detect_os() {
  if [ -f /etc/alpine-release ]; then
    command -v rc-service >/dev/null 2>&1 || fail "检测到 Alpine Linux，但未找到 OpenRC (rc-service)。"
    OS_TYPE="alpine"
    INIT_TYPE="openrc"
    SERVICE_FILE="${OPENRC_SERVICE_FILE}"
    return 0
  fi

  IS_DEBIAN_LIKE="0"
  if [ -f /etc/debian_version ]; then
    IS_DEBIAN_LIKE="1"
  elif [ -f /etc/os-release ]; then
    OS_ID=""
    OS_LIKE=""
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
    case "${OS_ID} ${OS_LIKE}" in
      *debian*|*ubuntu*) IS_DEBIAN_LIKE="1" ;;
    esac
  fi

  if [ "${IS_DEBIAN_LIKE}" = "1" ]; then
    command -v apt-get >/dev/null 2>&1 || fail "检测到 Debian/Ubuntu 系统，但未找到 apt-get。"
    command -v systemctl >/dev/null 2>&1 || fail "检测到 Debian/Ubuntu 系统，但未找到 systemctl (systemd)。"
    OS_TYPE="debian"
    INIT_TYPE="systemd"
    SERVICE_FILE="${SYSTEMD_SERVICE_FILE}"
    return 0
  fi

  fail "仅支持 Debian / Ubuntu (systemd) 与 Alpine Linux (OpenRC)。"
}

os_label() {
  case "${OS_TYPE}:${INIT_TYPE}" in
    alpine:openrc) printf '%s' 'Alpine Linux (OpenRC)' ;;
    debian:systemd) printf '%s' 'Debian/Ubuntu (systemd)' ;;
    *) printf '%s' '未知系统' ;;
  esac
}

# --- Service abstraction (systemd & OpenRC) ---

service_is_running() {
  case "${INIT_TYPE}" in
    systemd) systemctl is-active --quiet xray >/dev/null 2>&1 ;;
    openrc) rc-service xray status >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

service_is_enabled() {
  case "${INIT_TYPE}" in
    systemd) systemctl is-enabled --quiet xray >/dev/null 2>&1 ;;
    openrc) [ -e /etc/runlevels/default/xray ] ;;
    *) return 1 ;;
  esac
}

service_daemon_reload() {
  case "${INIT_TYPE}" in
    systemd) systemctl daemon-reload ;;
    openrc) return 0 ;;
  esac
}

service_enable() {
  case "${INIT_TYPE}" in
    systemd) systemctl enable xray >/dev/null 2>&1 || true ;;
    openrc) rc-update add xray default >/dev/null 2>&1 || true ;;
  esac
}

service_disable() {
  case "${INIT_TYPE}" in
    systemd) systemctl disable xray >/dev/null 2>&1 || true ;;
    openrc) rc-update del xray default >/dev/null 2>&1 || true ;;
  esac
}

service_start() {
  case "${INIT_TYPE}" in
    systemd) systemctl start xray ;;
    openrc) rc-service xray start ;;
  esac
}

service_stop() {
  case "${INIT_TYPE}" in
    systemd) systemctl stop xray >/dev/null 2>&1 || true ;;
    openrc) rc-service xray stop >/dev/null 2>&1 || true ;;
  esac
}

service_restart() {
  case "${INIT_TYPE}" in
    systemd) systemctl daemon-reload >/dev/null 2>&1 || true; systemctl restart xray ;;
    openrc) rc-service xray restart ;;
  esac
}

service_status_output() {
  case "${INIT_TYPE}" in
    systemd) systemctl status xray --no-pager || true ;;
    openrc) rc-service xray status || true ;;
  esac
}

service_show_logs() {
  case "${INIT_TYPE}" in
    systemd)
      journalctl -u xray -n 80 --no-pager || echo "暂无日志。"
      ;;
    openrc)
      echo "错误日志：${ERR_LOG_FILE}"
      tail -80 "${ERR_LOG_FILE}" 2>/dev/null || echo "暂无错误日志。"
      echo
      echo "运行日志：${LOG_FILE}"
      tail -80 "${LOG_FILE}" 2>/dev/null || echo "暂无运行日志。"
      ;;
  esac
}

service_follow_logs() {
  echo "实时追踪 Xray 日志中，按 Ctrl+C 返回菜单..."
  echo
  trap 'MENU_RETURNED="1"' INT
  case "${INIT_TYPE}" in
    systemd)
      journalctl -u xray -f -n 30 --no-pager || true
      ;;
    openrc)
      if [ -f "${ERR_LOG_FILE}" ] || [ -f "${LOG_FILE}" ]; then
        tail -f -n 30 "${ERR_LOG_FILE}" "${LOG_FILE}" 2>/dev/null || true
      else
        echo "暂无日志文件。"
      fi
      ;;
  esac
  trap - INT
}

write_service() {
  MEM_SVC_KB="$(effective_memory_kb)"
  SVC_GO_ENV_SD=""
  SVC_GO_ENV_RC=""
  if [ "${MEM_SVC_KB}" -gt 0 ] && [ "${MEM_SVC_KB}" -le "${LOW_MEM_THRESHOLD_KB}" ]; then
    if [ "${MEM_SVC_KB}" -le 81920 ]; then
      GO_MEM_LIMIT="32MiB"
    else
      GO_MEM_LIMIT="64MiB"
    fi
    SVC_GO_ENV_SD="Environment=GOGC=25
Environment=GOMEMLIMIT=${GO_MEM_LIMIT}
"
    SVC_GO_ENV_RC="export GOGC=\"25\"
export GOMEMLIMIT=\"${GO_MEM_LIMIT}\"
"
  fi
  case "${INIT_TYPE}" in
    systemd)
      info "写入 systemd 服务：${SERVICE_FILE}"
      cat > "${SERVICE_FILE}" <<SERVICE
[Unit]
Description=Xray VVR Multi-Protocol Service (VLESS Vision/XHTTP REALITY, Hysteria 2 & Shadowsocks)
Documentation=https://xtls.github.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=XRAY_LOCATION_ASSET=${XRAY_DIR}
${SVC_GO_ENV_SD}ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICE
      chmod 0644 "${SERVICE_FILE}"
      ;;
    openrc)
      info "写入 OpenRC 服务：${SERVICE_FILE}"
      RC_ULIMIT_LINE=""
      HARD_NOFILE="$(ulimit -Hn 2>/dev/null || echo '')"
      case "${HARD_NOFILE}" in
        unlimited) RC_ULIMIT_LINE='rc_ulimit="-n 65536"' ;;
        ''|*[!0-9]*) ;;
        *)
          if [ "${HARD_NOFILE}" -ge 65536 ]; then
            RC_ULIMIT_LINE='rc_ulimit="-n 65536"'
          elif [ "${HARD_NOFILE}" -gt 0 ]; then
            RC_ULIMIT_LINE="rc_ulimit=\"-n ${HARD_NOFILE}\""
          fi
          ;;
      esac
      cat > "${SERVICE_FILE}" <<SERVICE
#!/sbin/openrc-run

name="xray"
description="Xray VVR Multi-Protocol Service (VLESS Vision/XHTTP REALITY, Hysteria 2 & Shadowsocks)"
command="${XRAY_BIN}"
command_args="run -config ${CONFIG_FILE}"
command_background="yes"
pidfile="/run/xray.pid"
output_log="${LOG_FILE}"
error_log="${ERR_LOG_FILE}"
${RC_ULIMIT_LINE}
export XRAY_LOCATION_ASSET="${XRAY_DIR}"
${SVC_GO_ENV_RC}
depend() {
    need net
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
SERVICE
      chmod 0755 "${SERVICE_FILE}"
      ;;
  esac
}

# --- Memory & dependency helpers ---

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

is_low_mem_host() {
  MEM_CHK_KB="$(effective_memory_kb)"
  [ "${MEM_CHK_KB}" -gt 0 ] && [ "${MEM_CHK_KB}" -le "${LOW_MEM_THRESHOLD_KB}" ]
}

ensure_low_mem_swap() {
  MEM_TOTAL_KB="$(effective_memory_kb)"
  SWAP_TOTAL_KB="$(awk '/SwapTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  case "${SWAP_TOTAL_KB}" in ''|*[!0-9]*) SWAP_TOTAL_KB=0 ;; esac

  if [ "${MEM_TOTAL_KB}" -eq 0 ] || [ "${MEM_TOTAL_KB}" -gt "${LOW_MEM_THRESHOLD_KB}" ]; then
    LOW_MEM_MODE="0"
    info "检测到可用内存上限约 $((MEM_TOTAL_KB / 1024)) MiB。"
    return 0
  fi

  LOW_MEM_MODE="1"
  if [ "${SWAP_TOTAL_KB}" -gt 0 ]; then
    info "低内存模式（约 $((MEM_TOTAL_KB / 1024)) MiB RAM，已有约 $((SWAP_TOTAL_KB / 1024)) MiB Swap）。"
    return 0
  fi

  warn "检测到低内存环境（约 $((MEM_TOTAL_KB / 1024)) MiB RAM）且无 Swap，尝试创建 ${LOW_MEM_SWAP_SIZE_MB} MiB 临时 Swap..."
  if [ ! -f "${LOW_MEM_SWAP_FILE}" ]; then
    AVAILABLE_KB="$(df -Pk "$(dirname "${LOW_MEM_SWAP_FILE}")" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
    case "${AVAILABLE_KB}" in ''|*[!0-9]*) AVAILABLE_KB=0 ;; esac
    REQUIRED_KB=$((LOW_MEM_SWAP_SIZE_MB * 1024 + 16384))
    if [ "${AVAILABLE_KB}" -gt 0 ] && [ "${AVAILABLE_KB}" -lt "${REQUIRED_KB}" ]; then
      warn "磁盘剩余空间不足，跳过自动创建 Swap。"
      return 1
    fi
    if ! dd if=/dev/zero of="${LOW_MEM_SWAP_FILE}" bs=1M count="${LOW_MEM_SWAP_SIZE_MB}" >/dev/null 2>&1; then
      rm -f "${LOW_MEM_SWAP_FILE}"
      warn "创建 Swap 文件失败。"
      return 1
    fi
    chmod 0600 "${LOW_MEM_SWAP_FILE}"
    if command -v mkswap >/dev/null 2>&1; then
      MKSWAP_CMD="mkswap"
    elif command -v busybox >/dev/null 2>&1 && busybox mkswap --help >/dev/null 2>&1; then
      MKSWAP_CMD="busybox mkswap"
    else
      rm -f "${LOW_MEM_SWAP_FILE}"
      warn "系统缺少 mkswap，无法格式化 Swap。"
      return 1
    fi
    if ! ${MKSWAP_CMD} "${LOW_MEM_SWAP_FILE}" >/dev/null 2>&1; then
      rm -f "${LOW_MEM_SWAP_FILE}"
      warn "格式化 Swap 文件失败。"
      return 1
    fi
  fi

  if ! swapon "${LOW_MEM_SWAP_FILE}" >/dev/null 2>&1; then
    warn "启用 Swap 失败（容器环境可能禁止 swapon），将继续以低内存模式安装。"
    return 1
  fi
  ok "已启用临时 Swap：${LOW_MEM_SWAP_FILE}"
  return 0
}

install_deps() {
  case "${OS_TYPE}" in
    debian)
      MISSING_PKGS=""
      for PKG in ca-certificates curl openssl unzip iproute2; do
        if ! dpkg-query -W -f='${Status}\n' "${PKG}" 2>/dev/null | grep -qx 'install ok installed'; then
          MISSING_PKGS="${MISSING_PKGS} ${PKG}"
        fi
      done
      if [ -z "${MISSING_PKGS}" ]; then
        info "必要依赖已满足，跳过 apt 更新。"
        return 0
      fi
      info "安装缺失依赖：${MISSING_PKGS# }"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      # shellcheck disable=SC2086
      apt-get install -y --no-install-recommends ${MISSING_PKGS}
      ;;
    alpine)
      MISSING_BASE=""
      MISSING_NET=""
      for PKG in ca-certificates curl openssl; do
        apk info -e "${PKG}" >/dev/null 2>&1 || MISSING_BASE="${MISSING_BASE} ${PKG}"
      done
      for PKG in unzip iproute2; do
        apk info -e "${PKG}" >/dev/null 2>&1 || MISSING_NET="${MISSING_NET} ${PKG}"
      done
      if [ -z "${MISSING_BASE}" ] && [ -z "${MISSING_NET}" ]; then
        info "必要依赖已满足，跳过 apk 安装。"
        return 0
      fi
      if [ "${LOW_MEM_MODE}" = "1" ]; then
        info "以低内存分批模式安装 Alpine 依赖..."
        if [ -n "${MISSING_BASE}" ]; then
          # shellcheck disable=SC2086
          apk add --no-cache ${MISSING_BASE} || fail "基础依赖安装失败，如遇 Killed 请提高内存或配置 Swap。"
        fi
        if [ -n "${MISSING_NET}" ]; then
          # shellcheck disable=SC2086
          apk add --no-cache ${MISSING_NET} || fail "网络和解压依赖安装失败，如遇 Killed 请提高内存或配置 Swap。"
        fi
      else
        info "安装 Alpine 依赖..."
        # shellcheck disable=SC2086
        apk add --no-cache ${MISSING_BASE} ${MISSING_NET} || fail "依赖安装失败。"
      fi
      ;;
  esac
}

prepare_tmp() {
  for TMP_PARENT in "${INSTALL_TMPDIR:-}" /var/tmp /root /tmp; do
    [ -n "${TMP_PARENT}" ] || continue
    [ -d "${TMP_PARENT}" ] || continue
    [ -w "${TMP_PARENT}" ] || continue
    TMP_DIR="$(mktemp -d "${TMP_PARENT}/vvr-install.XXXXXX")"
    return 0
  done
  fail "未找到可写的临时目录。"
}

# --- Rollback protection ---

backup_existing_install() {
  INSTALL_ROLLBACK_DIR="${TMP_DIR}/rollback"
  mkdir -p "${INSTALL_ROLLBACK_DIR}"
  [ -d "${XRAY_DIR}" ] && cp -a "${XRAY_DIR}" "${INSTALL_ROLLBACK_DIR}/xray-dir"
  [ -d "${CONFIG_DIR}" ] && cp -a "${CONFIG_DIR}" "${INSTALL_ROLLBACK_DIR}/config-dir"
  [ -f "${SERVICE_FILE}" ] && cp -a "${SERVICE_FILE}" "${INSTALL_ROLLBACK_DIR}/xray-service"
  [ -f "${MANAGER_BIN}" ] && cp -a "${MANAGER_BIN}" "${INSTALL_ROLLBACK_DIR}/vvr-manager"
  INSTALL_BACKUP_READY="1"
}

rollback_install() {
  [ "${INSTALL_COMMITTED:-0}" = "0" ] || return 0
  [ "${INSTALL_BACKUP_READY:-0}" = "1" ] || return 0
  [ -n "${INSTALL_ROLLBACK_DIR:-}" ] || return 0
  [ -d "${INSTALL_ROLLBACK_DIR}" ] || return 0

  warn "操作未完成，正在恢复原有 Xray 状态..."
  service_stop
  rm -rf "${XRAY_DIR}" "${CONFIG_DIR}"
  rm -f "${SERVICE_FILE}" "${MANAGER_BIN}"
  if [ "${EXISTING_SERVICE_WAS_ENABLED:-0}" != "1" ]; then
    service_disable
  fi
  [ -d "${INSTALL_ROLLBACK_DIR}/xray-dir" ] && cp -a "${INSTALL_ROLLBACK_DIR}/xray-dir" "${XRAY_DIR}"
  [ -d "${INSTALL_ROLLBACK_DIR}/config-dir" ] && cp -a "${INSTALL_ROLLBACK_DIR}/config-dir" "${CONFIG_DIR}"
  [ -f "${INSTALL_ROLLBACK_DIR}/xray-service" ] && cp -a "${INSTALL_ROLLBACK_DIR}/xray-service" "${SERVICE_FILE}"
  [ -f "${INSTALL_ROLLBACK_DIR}/vvr-manager" ] && cp -a "${INSTALL_ROLLBACK_DIR}/vvr-manager" "${MANAGER_BIN}"
  service_daemon_reload >/dev/null 2>&1 || true

  if [ "${EXISTING_SERVICE_WAS_RUNNING:-0}" = "1" ] && [ -f "${SERVICE_FILE}" ]; then
    if service_start >/dev/null 2>&1; then
      ok "旧 Xray 服务已恢复运行。"
    else
      warn "旧文件已恢复，但旧 Xray 服务未能自动启动，请手动检查。"
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

installation_present() {
  [ -f "${SERVICE_FILE}" ] || [ -f "${CONFIG_FILE}" ] || [ -x "${XRAY_BIN}" ]
}

installation_complete() {
  [ -f "${CONFIG_FILE}" ] && [ -f "${SERVICE_FILE}" ] && [ -x "${XRAY_BIN}" ] && [ -f "${META_FILE}" ]
}

# --- Xray download, checksum & streaming extraction ---

detect_arch() {
  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64|amd64) XRAY_ZIP="Xray-linux-64.zip" ;;
    aarch64|arm64) XRAY_ZIP="Xray-linux-arm64-v8a.zip" ;;
    armv7l|armv7) XRAY_ZIP="Xray-linux-arm32-v7a.zip" ;;
    *) fail "暂不支持的 CPU 架构：${ARCH}" ;;
  esac
  if [ -n "${VVR_XRAY_URL:-}" ]; then
    XRAY_URL="${VVR_XRAY_URL}"
  elif [ -n "${XRAY_VERSION:-}" ]; then
    case "${XRAY_VERSION}" in
      v*) XRAY_TAG="${XRAY_VERSION}" ;;
      *) XRAY_TAG="v${XRAY_VERSION}" ;;
    esac
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_TAG}/${XRAY_ZIP}"
  else
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ZIP}"
  fi
}

fetch_url() {
  FETCH_URL="$1"
  FETCH_TARGET="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 10 --max-time 180 -A "vvr-xray-installer" "${FETCH_URL}" -o "${FETCH_TARGET}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${FETCH_TARGET}" "${FETCH_URL}"
  else
    return 1
  fi
}

download_xray() {
  ARCHIVE_PATH="${TMP_DIR}/${XRAY_ZIP}"
  DGST_PATH="${ARCHIVE_PATH}.dgst"
  info "下载 Xray-core (${ARCH})..."
  fetch_url "${XRAY_URL}" "${ARCHIVE_PATH}" || return 1
  [ -s "${ARCHIVE_PATH}" ] || return 1

  if command -v sha256sum >/dev/null 2>&1 && fetch_url "${XRAY_URL}.dgst" "${DGST_PATH}" >/dev/null 2>&1; then
    EXPECTED_SHA="$(awk 'tolower($0) ~ /^sha2-256[ \t]*=/ {sub(/.*=[ \t]*/, ""); gsub(/[^0-9A-Fa-f]/, ""); print tolower($0); exit}' "${DGST_PATH}")"
    if [ -n "${EXPECTED_SHA}" ]; then
      ACTUAL_SHA="$(sha256sum "${ARCHIVE_PATH}" | awk '{print tolower($1)}')"
      if [ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]; then
        rm -f "${ARCHIVE_PATH}" "${DGST_PATH}"
        warn "Xray 安装包 SHA256 校验失败（期望 ${EXPECTED_SHA}，实际 ${ACTUAL_SHA}）。"
        return 1
      fi
      ok "Xray 安装包 SHA256 校验通过。"
    fi
  fi
  rm -f "${DGST_PATH}"
  return 0
}

extract_archive_member() {
  MEMBER="$1"
  TARGET="$2"
  MODE="$3"
  TEMP_TARGET="${TARGET}.tmp.$$"
  rm -f "${TEMP_TARGET}"
  if ! unzip -p "${TMP_DIR}/${XRAY_ZIP}" "${MEMBER}" > "${TEMP_TARGET}"; then
    rm -f "${TEMP_TARGET}"
    return 1
  fi
  chmod "${MODE}" "${TEMP_TARGET}"
  mv -f "${TEMP_TARGET}" "${TARGET}"
}

install_xray_files() {
  info "以流式方式安装 Xray 与规则数据..."
  mkdir -p "${XRAY_DIR}" "${CONFIG_DIR}"
  extract_archive_member xray "${XRAY_BIN}" 0755 || return 1
  extract_archive_member geoip.dat "${XRAY_DIR}/geoip.dat" 0644 || warn "安装包未包含 geoip.dat。"
  extract_archive_member geosite.dat "${XRAY_DIR}/geosite.dat" 0644 || return 1
  rm -f "${TMP_DIR}/${XRAY_ZIP}"
  return 0
}

# --- Network & validation helpers ---

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

check_port_available() {
  CHECK_PORT="$1"
  OLD_PORT="${2:-}"
  CHECK_PROTO="${3:-tcp}"
  [ "${CHECK_PORT}" != "${OLD_PORT}" ] || return 0
  if command -v ss >/dev/null 2>&1; then
    case "${CHECK_PROTO}" in
      *tcp*)
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${CHECK_PORT}$"; then
          return 1
        fi
        ;;
    esac
    case "${CHECK_PROTO}" in
      *udp*)
        if ss -lun 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${CHECK_PORT}$"; then
          return 1
        fi
        ;;
    esac
  fi
  return 0
}

port_conflicts_with_configured() {
  CANDIDATE_PORT="$1"
  IGNORE_ROLE="${2:-}"
  CHECK_PROTO="${3:-tcp}"

  case "${CHECK_PROTO}" in
    *tcp*)
      if [ "${IGNORE_ROLE}" != "vless4" ] && [ -n "${IPV4_PORT:-}" ] && [ "${CANDIDATE_PORT}" = "${IPV4_PORT}" ]; then
        echo "TCP 端口 ${CANDIDATE_PORT} 与 VLESS-Vision IPv4 入站端口冲突。"
        return 0
      fi
      if [ "${IGNORE_ROLE}" != "vless6" ] && [ -n "${IPV6_PORT:-}" ] && [ "${CANDIDATE_PORT}" = "${IPV6_PORT}" ]; then
        echo "TCP 端口 ${CANDIDATE_PORT} 与 VLESS-Vision IPv6 入站端口冲突。"
        return 0
      fi
      if [ "${IGNORE_ROLE}" != "xhttp" ] && [ -n "${XHTTP_PORT:-}" ] && [ "${CANDIDATE_PORT}" = "${XHTTP_PORT}" ]; then
        echo "TCP 端口 ${CANDIDATE_PORT} 与 VLESS-XHTTP 入站端口冲突。"
        return 0
      fi
      if [ "${IGNORE_ROLE}" != "ss" ] && [ -n "${SS_PORT:-}" ] && [ "${CANDIDATE_PORT}" = "${SS_PORT}" ]; then
        echo "TCP 端口 ${CANDIDATE_PORT} 与 Shadowsocks 入站端口冲突。"
        return 0
      fi
      if [ "${IGNORE_ROLE}" != "fallback" ] && [ "${FALLBACK_MODE:-direct}" = "protected" ] && [ -n "${FALLBACK_PORT:-}" ] && [ "${CANDIDATE_PORT}" = "${FALLBACK_PORT}" ]; then
        echo "TCP 端口 ${CANDIDATE_PORT} 与本机回落 Tunnel 端口冲突。"
        return 0
      fi
      if [ "${TRAFFIC_ENABLED:-0}" = "1" ]; then
        if [ "${IGNORE_ROLE}" != "xray_api" ] && [ "${CANDIDATE_PORT}" = "${XRAY_API_PORT:-${DEFAULT_XRAY_API_PORT}}" ]; then
          echo "TCP 端口 ${CANDIDATE_PORT} 与 Xray 内部统计 API 端口冲突。"
          return 0
        fi
        if [ "${IGNORE_ROLE}" != "traffic_api" ] && [ "${CANDIDATE_PORT}" = "${TRAFFIC_API_PORT:-${DEFAULT_TRAFFIC_API_PORT}}" ]; then
          echo "TCP 端口 ${CANDIDATE_PORT} 与流量统计 HTTP API 端口冲突。"
          return 0
        fi
      fi
      ;;
  esac

  case "${CHECK_PROTO}" in
    *udp*)
      if [ "${IGNORE_ROLE}" != "hy2" ] && [ -n "${HY2_PORT:-}" ] && [ "${CANDIDATE_PORT}" = "${HY2_PORT}" ]; then
        echo "UDP 端口 ${CANDIDATE_PORT} 与 Hysteria 2 入站端口冲突。"
        return 0
      fi
      if [ "${IGNORE_ROLE}" != "ss" ] && [ -n "${SS_PORT:-}" ] && [ "${CANDIDATE_PORT}" = "${SS_PORT}" ]; then
        case "${SS_NETWORK:-tcp}" in
          *udp*)
            echo "UDP 端口 ${CANDIDATE_PORT} 与 Shadowsocks (UDP) 入站端口冲突。"
            return 0
            ;;
        esac
      fi
      ;;
  esac

  return 1
}

# --- Credentials & key generation ---

parse_x25519_keys() {
  X25519_INPUT="$1"
  PRIVATE_KEY="$(printf '%s\n' "${X25519_INPUT}" | awk '{line=tolower($0); if (line ~ /private/ && line ~ /key/) {sub(/.*[:=][ \t]*/, "", $0); gsub(/[\r",]/, "", $0); print $1; exit}}')"
  PUBLIC_KEY="$(printf '%s\n' "${X25519_INPUT}" | awk '{line=tolower($0); if ((line ~ /public/ && line ~ /key/) || line ~ /^password[ \t]*:/) {sub(/.*[:=][ \t]*/, "", $0); gsub(/[\r",]/, "", $0); print $1; exit}}')"
  if ! printf '%s\n' "${PRIVATE_KEY}" | grep -Eq '^[A-Za-z0-9_-]{43}$'; then
    return 1
  fi
  if ! printf '%s\n' "${PUBLIC_KEY}" | grep -Eq '^[A-Za-z0-9_-]{43}$'; then
    return 1
  fi
  return 0
}

generate_uuid() {
  UUID_OUTPUT=""
  if ! UUID_OUTPUT="$("${XRAY_BIN}" uuid 2>&1)"; then
    [ -z "${UUID_OUTPUT}" ] || printf '%s\n' "${UUID_OUTPUT}" >&2
    warn "Xray 生成 UUID 失败。"
    return 1
  fi
  UUID="$(printf '%s' "${UUID_OUTPUT}" | tr -d '\r\n[:space:]')"
  if ! printf '%s\n' "${UUID}" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'; then
    warn "Xray 返回的 UUID 格式无效。"
    return 1
  fi
  return 0
}

generate_reality_values() {
  info "生成 REALITY X25519 密钥与 shortId..."
  KEYS=""
  if ! KEYS="$("${XRAY_BIN}" x25519 2>&1)"; then
    [ -z "${KEYS}" ] || printf '%s\n' "${KEYS}" >&2
    warn "Xray 生成 REALITY X25519 密钥失败。"
    return 1
  fi
  if ! parse_x25519_keys "${KEYS}"; then
    warn "无法解析 xray x25519 输出："
    printf '%s\n' "${KEYS}" >&2
    return 1
  fi

  SHORT_ID_OUTPUT=""
  if ! SHORT_ID_OUTPUT="$(openssl rand -hex 8 2>&1)"; then
    [ -z "${SHORT_ID_OUTPUT}" ] || printf '%s\n' "${SHORT_ID_OUTPUT}" >&2
    warn "OpenSSL 生成 shortId 失败。"
    return 1
  fi
  SHORT_ID="$(printf '%s' "${SHORT_ID_OUTPUT}" | tr -d '\r\n[:space:]')"
  if ! printf '%s\n' "${SHORT_ID}" | grep -Eq '^[0-9A-Fa-f]{16}$'; then
    warn "OpenSSL 返回的 shortId 格式无效。"
    return 1
  fi
  return 0
}

generate_ss_password() {
  METHOD_FOR_KEY="${1:-${SS_METHOD:-${DEFAULT_SS_METHOD}}}"
  case "${METHOD_FOR_KEY}" in
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
      KEY_BYTES=32
      ;;
    2022-blake3-aes-128-gcm)
      KEY_BYTES=16
      ;;
    *)
      KEY_BYTES=24
      ;;
  esac
  SS_PASSWORD="$(openssl rand -base64 "${KEY_BYTES}" | tr -d '\r\n')"
  if [ -z "${SS_PASSWORD}" ]; then
    warn "生成 Shadowsocks 密码失败。"
    return 1
  fi
  return 0
}

generate_xhttp_path() {
  RAND_PATH="$(openssl rand -hex 6 2>/dev/null | tr -d '\r\n[:space:]' || true)"
  [ -n "${RAND_PATH}" ] || RAND_PATH="vvrxhttp"
  XHTTP_PATH="/${RAND_PATH}"
}

generate_hy2_password() {
  HY2_PASSWORD="$(openssl rand -hex 16 2>/dev/null | tr -d '\r\n[:space:]' || true)"
  if [ -z "${HY2_PASSWORD}" ]; then
    warn "生成 Hysteria 2 密码失败。"
    return 1
  fi
  return 0
}

generate_hy2_selfsigned_cert() {
  CERT_CN="${1:-${HY2_SNI:-${DEFAULT_HY2_SNI}}}"
  CERT_OUT="${2:-${DEFAULT_HY2_CERT_FILE}}"
  KEY_OUT="${3:-${DEFAULT_HY2_KEY_FILE}}"
  mkdir -p "$(dirname "${CERT_OUT}")" "$(dirname "${KEY_OUT}")"
  info "正在生成 Hysteria 2 自签 ECDSA 证书（CN=${CERT_CN}）..."
  if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "${KEY_OUT}" -out "${CERT_OUT}" -subj "/CN=${CERT_CN}" -days 3650 >/dev/null 2>&1; then
    warn "OpenSSL 生成 Hysteria 2 自签证书失败。"
    return 1
  fi
  chmod 0600 "${KEY_OUT}" "${CERT_OUT}"
  ok "自签证书已生成：${CERT_OUT}"
  return 0
}

# --- State, clients & routes persistence ---

ensure_clients_file() {
  mkdir -p "${CONFIG_DIR}"
  if [ ! -f "${CLIENTS_FILE}" ]; then
    : > "${CLIENTS_FILE}"
    chmod 0600 "${CLIENTS_FILE}"
  fi
}

ensure_xhttp_clients_file() {
  case "${XHTTP_CLIENTS_FILE}" in
    /etc/xray/*) [ "${CONFIG_DIR}" = "/etc/xray" ] || XHTTP_CLIENTS_FILE="${CONFIG_DIR}/${XHTTP_CLIENTS_FILE#/etc/xray/}" ;;
  esac
  mkdir -p "${CONFIG_DIR}"
  if [ ! -f "${XHTTP_CLIENTS_FILE}" ]; then
    : > "${XHTTP_CLIENTS_FILE}"
    chmod 0600 "${XHTTP_CLIENTS_FILE}"
  fi
}

ensure_hy2_clients_file() {
  case "${HY2_CLIENTS_FILE}" in
    /etc/xray/*) [ "${CONFIG_DIR}" = "/etc/xray" ] || HY2_CLIENTS_FILE="${CONFIG_DIR}/${HY2_CLIENTS_FILE#/etc/xray/}" ;;
  esac
  mkdir -p "${CONFIG_DIR}"
  if [ ! -f "${HY2_CLIENTS_FILE}" ]; then
    : > "${HY2_CLIENTS_FILE}"
    chmod 0600 "${HY2_CLIENTS_FILE}"
  fi
}

ensure_outbounds_file() {
  case "${OUTBOUNDS_FILE}" in
    /etc/xray/*) [ "${CONFIG_DIR}" = "/etc/xray" ] || OUTBOUNDS_FILE="${CONFIG_DIR}/${OUTBOUNDS_FILE#/etc/xray/}" ;;
  esac
  mkdir -p "${CONFIG_DIR}"
  if [ ! -f "${OUTBOUNDS_FILE}" ]; then
    : > "${OUTBOUNDS_FILE}"
    chmod 0600 "${OUTBOUNDS_FILE}"
  fi
}

ensure_user_routes_file() {
  case "${USER_ROUTES_FILE}" in
    /etc/xray/*) [ "${CONFIG_DIR}" = "/etc/xray" ] || USER_ROUTES_FILE="${CONFIG_DIR}/${USER_ROUTES_FILE#/etc/xray/}" ;;
  esac
  mkdir -p "${CONFIG_DIR}"
  if [ ! -f "${USER_ROUTES_FILE}" ]; then
    : > "${USER_ROUTES_FILE}"
    chmod 0600 "${USER_ROUTES_FILE}"
  fi
}

ensure_inbound_routes_file() {
  case "${INBOUND_ROUTES_FILE}" in
    /etc/xray/*) [ "${CONFIG_DIR}" = "/etc/xray" ] || INBOUND_ROUTES_FILE="${CONFIG_DIR}/${INBOUND_ROUTES_FILE#/etc/xray/}" ;;
  esac
  mkdir -p "${CONFIG_DIR}"
  if [ ! -f "${INBOUND_ROUTES_FILE}" ]; then
    : > "${INBOUND_ROUTES_FILE}"
    chmod 0600 "${INBOUND_ROUTES_FILE}"
  fi
}

client_count() {
  CLIENT_FAMILY="$1"
  ensure_clients_file
  awk -F '|' -v family="${CLIENT_FAMILY}" '$1 == family && $2 != "" {count++} END {print count+0}' "${CLIENTS_FILE}"
}

total_vless_clients() {
  echo $(( $(client_count ipv4) + $(client_count ipv6) ))
}

xhttp_client_count() {
  ensure_xhttp_clients_file
  CNT="$(awk -F '|' '$1 != "" {count++} END {print count+0}' "${XHTTP_CLIENTS_FILE}")"
  if [ "${CNT}" -eq 0 ] && [ -n "${XHTTP_UUID:-}" ]; then
    echo 1
  else
    echo "${CNT}"
  fi
}

hy2_client_count() {
  ensure_hy2_clients_file
  CNT="$(awk -F '|' '$1 != "" {count++} END {print count+0}' "${HY2_CLIENTS_FILE}")"
  if [ "${CNT}" -eq 0 ] && [ -n "${HY2_PASSWORD:-}" ]; then
    echo 1
  else
    echo "${CNT}"
  fi
}

custom_outbound_count() {
  ensure_outbounds_file
  awk -F '|' '$1 != "" && $2 != "" {count++} END {print count+0}' "${OUTBOUNDS_FILE}"
}

custom_outbound_exists() {
  CHK_TAG="$1"
  ensure_outbounds_file
  awk -F '|' -v tag="${CHK_TAG}" '$1 == tag && $2 != "" {found=1} END {exit !found}' "${OUTBOUNDS_FILE}"
}

xhttp_client_name_exists() {
  CHK_NAME="$1"
  ensure_xhttp_clients_file
  awk -F '|' -v name="${CHK_NAME}" '$1 != "" && $2 == name {found=1} END {exit !found}' "${XHTTP_CLIENTS_FILE}"
}

hy2_client_name_exists() {
  CHK_NAME="$1"
  ensure_hy2_clients_file
  awk -F '|' -v name="${CHK_NAME}" '$1 != "" && $2 == name {found=1} END {exit !found}' "${HY2_CLIENTS_FILE}"
}

reality_keys_ready() {
  [ -n "${PRIVATE_KEY:-}" ] && [ -n "${PUBLIC_KEY:-}" ] && [ -n "${SHORT_ID:-}" ]
}

vless_is_configured() {
  reality_keys_ready && [ "$(total_vless_clients)" -gt 0 ]
}

xhttp_is_configured() {
  reality_keys_ready && [ -n "${XHTTP_PORT:-}" ] && [ "$(xhttp_client_count)" -gt 0 ]
}

hy2_is_configured() {
  [ -n "${HY2_PORT:-}" ] && [ "$(hy2_client_count)" -gt 0 ] && [ -n "${HY2_CERT_FILE:-}" ] && [ -n "${HY2_KEY_FILE:-}" ]
}

ss_is_configured() {
  [ -n "${SS_PORT:-}" ] && [ -n "${SS_PASSWORD:-}" ]
}

other_protocols_active_excluding() {
  EXCLUDE_PROTO="$1"
  OTHER_CNT=0
  if [ "${EXCLUDE_PROTO}" != "vless" ] && vless_is_configured; then OTHER_CNT=$((OTHER_CNT + 1)); fi
  if [ "${EXCLUDE_PROTO}" != "xhttp" ] && xhttp_is_configured; then OTHER_CNT=$((OTHER_CNT + 1)); fi
  if [ "${EXCLUDE_PROTO}" != "hy2" ] && hy2_is_configured; then OTHER_CNT=$((OTHER_CNT + 1)); fi
  if [ "${EXCLUDE_PROTO}" != "ss" ] && ss_is_configured; then OTHER_CNT=$((OTHER_CNT + 1)); fi
  [ "${OTHER_CNT}" -gt 0 ]
}

client_name_exists() {
  CLIENT_FAMILY="$1"
  CLIENT_NAME="$2"
  ensure_clients_file
  awk -F '|' -v family="${CLIENT_FAMILY}" -v name="${CLIENT_NAME}" \
    '$1 == family && $3 == name {found=1} END {exit !found}' "${CLIENTS_FILE}"
}

ensure_routes_file() {
  mkdir -p "${CONFIG_DIR}"
  if [ ! -f "${ROUTES_FILE}" ]; then
    : > "${ROUTES_FILE}"
    chmod 0600 "${ROUTES_FILE}"
  fi
}

backup_routes_for_change() {
  ensure_routes_file
  PENDING_ROUTES_BACKUP="$(mktemp /tmp/vvr-routes.XXXXXX)"
  cp -a "${ROUTES_FILE}" "${PENDING_ROUTES_BACKUP}"
}

backup_clients_for_change() {
  ensure_clients_file
  PENDING_CLIENTS_BACKUP="$(mktemp /tmp/vvr-clients.XXXXXX)"
  cp -a "${CLIENTS_FILE}" "${PENDING_CLIENTS_BACKUP}"
}

backup_xhttp_clients_for_change() {
  ensure_xhttp_clients_file
  PENDING_XHTTP_CLIENTS_BACKUP="$(mktemp /tmp/vvr-xclients.XXXXXX)"
  cp -a "${XHTTP_CLIENTS_FILE}" "${PENDING_XHTTP_CLIENTS_BACKUP}"
}

backup_hy2_clients_for_change() {
  ensure_hy2_clients_file
  PENDING_HY2_CLIENTS_BACKUP="$(mktemp /tmp/vvr-hclients.XXXXXX)"
  cp -a "${HY2_CLIENTS_FILE}" "${PENDING_HY2_CLIENTS_BACKUP}"
}

backup_outbounds_for_change() {
  ensure_outbounds_file
  PENDING_OUTBOUNDS_BACKUP="$(mktemp /tmp/vvr-outbounds.XXXXXX)"
  cp -a "${OUTBOUNDS_FILE}" "${PENDING_OUTBOUNDS_BACKUP}"
}

backup_user_routes_for_change() {
  ensure_user_routes_file
  PENDING_USER_ROUTES_BACKUP="$(mktemp /tmp/vvr-uroutes.XXXXXX)"
  cp -a "${USER_ROUTES_FILE}" "${PENDING_USER_ROUTES_BACKUP}"
}

backup_inbound_routes_for_change() {
  ensure_inbound_routes_file
  PENDING_INBOUND_ROUTES_BACKUP="$(mktemp /tmp/vvr-iroutes.XXXXXX)"
  cp -a "${INBOUND_ROUTES_FILE}" "${PENDING_INBOUND_ROUTES_BACKUP}"
}

restore_all_pending_backups() {
  if [ -n "${PENDING_ROUTES_BACKUP:-}" ] && [ -f "${PENDING_ROUTES_BACKUP}" ]; then
    cp -a "${PENDING_ROUTES_BACKUP}" "${ROUTES_FILE}"; rm -f "${PENDING_ROUTES_BACKUP}"
  fi
  if [ -n "${PENDING_CLIENTS_BACKUP:-}" ] && [ -f "${PENDING_CLIENTS_BACKUP}" ]; then
    cp -a "${PENDING_CLIENTS_BACKUP}" "${CLIENTS_FILE}"; rm -f "${PENDING_CLIENTS_BACKUP}"
  fi
  if [ -n "${PENDING_XHTTP_CLIENTS_BACKUP:-}" ] && [ -f "${PENDING_XHTTP_CLIENTS_BACKUP}" ]; then
    cp -a "${PENDING_XHTTP_CLIENTS_BACKUP}" "${XHTTP_CLIENTS_FILE}"; rm -f "${PENDING_XHTTP_CLIENTS_BACKUP}"
  fi
  if [ -n "${PENDING_HY2_CLIENTS_BACKUP:-}" ] && [ -f "${PENDING_HY2_CLIENTS_BACKUP}" ]; then
    cp -a "${PENDING_HY2_CLIENTS_BACKUP}" "${HY2_CLIENTS_FILE}"; rm -f "${PENDING_HY2_CLIENTS_BACKUP}"
  fi
  if [ -n "${PENDING_OUTBOUNDS_BACKUP:-}" ] && [ -f "${PENDING_OUTBOUNDS_BACKUP}" ]; then
    cp -a "${PENDING_OUTBOUNDS_BACKUP}" "${OUTBOUNDS_FILE}"; rm -f "${PENDING_OUTBOUNDS_BACKUP}"
  fi
  if [ -n "${PENDING_USER_ROUTES_BACKUP:-}" ] && [ -f "${PENDING_USER_ROUTES_BACKUP}" ]; then
    cp -a "${PENDING_USER_ROUTES_BACKUP}" "${USER_ROUTES_FILE}"; rm -f "${PENDING_USER_ROUTES_BACKUP}"
  fi
  if [ -n "${PENDING_INBOUND_ROUTES_BACKUP:-}" ] && [ -f "${PENDING_INBOUND_ROUTES_BACKUP}" ]; then
    cp -a "${PENDING_INBOUND_ROUTES_BACKUP}" "${INBOUND_ROUTES_FILE}"; rm -f "${PENDING_INBOUND_ROUTES_BACKUP}"
  fi
  PENDING_ROUTES_BACKUP=""
  PENDING_CLIENTS_BACKUP=""
  PENDING_XHTTP_CLIENTS_BACKUP=""
  PENDING_HY2_CLIENTS_BACKUP=""
  PENDING_OUTBOUNDS_BACKUP=""
  PENDING_USER_ROUTES_BACKUP=""
  PENDING_INBOUND_ROUTES_BACKUP=""
}

discard_all_pending_backups() {
  rm -f "${PENDING_ROUTES_BACKUP:-}" "${PENDING_CLIENTS_BACKUP:-}" \
    "${PENDING_XHTTP_CLIENTS_BACKUP:-}" "${PENDING_HY2_CLIENTS_BACKUP:-}" \
    "${PENDING_OUTBOUNDS_BACKUP:-}" "${PENDING_USER_ROUTES_BACKUP:-}" \
    "${PENDING_INBOUND_ROUTES_BACKUP:-}" 2>/dev/null || true
  PENDING_ROUTES_BACKUP=""
  PENDING_CLIENTS_BACKUP=""
  PENDING_XHTTP_CLIENTS_BACKUP=""
  PENDING_HY2_CLIENTS_BACKUP=""
  PENDING_OUTBOUNDS_BACKUP=""
  PENDING_USER_ROUTES_BACKUP=""
  PENDING_INBOUND_ROUTES_BACKUP=""
}

save_state() {
  mkdir -p "${CONFIG_DIR}"
  cat > "${META_FILE}" <<STATE
IPV4_PORT='${IPV4_PORT:-}'
IPV6_PORT='${IPV6_PORT:-}'
SNI='${SNI:-${DEFAULT_SNI}}'
REALITY_DEST='${REALITY_DEST:-${SNI:-${DEFAULT_SNI}}:443}'
PRIVATE_KEY='${PRIVATE_KEY:-}'
PUBLIC_KEY='${PUBLIC_KEY:-}'
SHORT_ID='${SHORT_ID:-}'
FALLBACK_MODE='${FALLBACK_MODE:-direct}'
FALLBACK_PORT='${FALLBACK_PORT:-}'
FALLBACK_LIMIT_MODE='${FALLBACK_LIMIT_MODE:-disabled}'
FALLBACK_LIMIT_AFTER_BYTES='${FALLBACK_LIMIT_AFTER_BYTES:-}'
FALLBACK_LIMIT_UPLOAD_BPS='${FALLBACK_LIMIT_UPLOAD_BPS:-}'
FALLBACK_LIMIT_UPLOAD_BURST='${FALLBACK_LIMIT_UPLOAD_BURST:-}'
FALLBACK_LIMIT_DOWNLOAD_BPS='${FALLBACK_LIMIT_DOWNLOAD_BPS:-}'
FALLBACK_LIMIT_DOWNLOAD_BURST='${FALLBACK_LIMIT_DOWNLOAD_BURST:-}'
SERVER_IPV4='${SERVER_IPV4:-}'
SERVER_IPV6='${SERVER_IPV6:-}'
BASE_OUTBOUND_MODE='${BASE_OUTBOUND_MODE:-${DEFAULT_BASE_OUTBOUND_MODE}}'
HAPPY_EYEBALLS_DELAY_MS='${HAPPY_EYEBALLS_DELAY_MS:-${DEFAULT_HAPPY_EYEBALLS_DELAY_MS}}'
BLOCK_PRIVATE_IP='${BLOCK_PRIVATE_IP:-${DEFAULT_BLOCK_PRIVATE_IP}}'
TRAFFIC_ENABLED='${TRAFFIC_ENABLED:-${DEFAULT_TRAFFIC_ENABLED}}'
TRAFFIC_API_PORT='${TRAFFIC_API_PORT:-${DEFAULT_TRAFFIC_API_PORT}}'
XRAY_API_PORT='${XRAY_API_PORT:-${DEFAULT_XRAY_API_PORT}}'
FINGERPRINT='${FINGERPRINT:-chrome}'
SPIDERX='${SPIDERX:-%2F}'
XHTTP_PORT='${XHTTP_PORT:-}'
XHTTP_BIND='${XHTTP_BIND:-}'
XHTTP_FAMILY='${XHTTP_FAMILY:-}'
XHTTP_UUID='${XHTTP_UUID:-}'
XHTTP_PATH='${XHTTP_PATH:-}'
XHTTP_MODE='${XHTTP_MODE:-${DEFAULT_XHTTP_MODE}}'
XHTTP_NAME='${XHTTP_NAME:-${DEFAULT_XHTTP_NAME}}'
XHTTP_SERVER_HOST='${XHTTP_SERVER_HOST:-}'
HY2_PORT='${HY2_PORT:-}'
HY2_BIND='${HY2_BIND:-}'
HY2_FAMILY='${HY2_FAMILY:-}'
HY2_PASSWORD='${HY2_PASSWORD:-}'
HY2_SNI='${HY2_SNI:-${DEFAULT_HY2_SNI}}'
HY2_CERT_MODE='${HY2_CERT_MODE:-selfsigned}'
HY2_CERT_FILE='${HY2_CERT_FILE:-}'
HY2_KEY_FILE='${HY2_KEY_FILE:-}'
HY2_INSECURE='${HY2_INSECURE:-1}'
HY2_NAME='${HY2_NAME:-${DEFAULT_HY2_NAME}}'
HY2_SERVER_HOST='${HY2_SERVER_HOST:-}'
SS_PORT='${SS_PORT:-}'
SS_BIND='${SS_BIND:-}'
SS_FAMILY='${SS_FAMILY:-}'
SS_NETWORK='${SS_NETWORK:-${DEFAULT_SS_NETWORK}}'
SS_METHOD='${SS_METHOD:-${DEFAULT_SS_METHOD}}'
SS_PASSWORD='${SS_PASSWORD:-}'
SS_NAME='${SS_NAME:-${DEFAULT_SS_NAME}}'
SS_SERVER_HOST='${SS_SERVER_HOST:-}'
STATE
  chmod 0600 "${META_FILE}"
}

load_state() {
  [ -f "${META_FILE}" ] || fail "未找到节点信息文件：${META_FILE}。请先运行安装脚本。"
  unset IPV4_PORT IPV6_PORT SNI DEST REALITY_DEST PRIVATE_KEY PUBLIC_KEY SHORT_ID
  unset FALLBACK_MODE FALLBACK_PORT FALLBACK_LIMIT_MODE FALLBACK_LIMIT_AFTER_BYTES
  unset FALLBACK_LIMIT_UPLOAD_BPS FALLBACK_LIMIT_UPLOAD_BURST FALLBACK_LIMIT_DOWNLOAD_BPS FALLBACK_LIMIT_DOWNLOAD_BURST
  unset SERVER_IPV4 SERVER_IPV6 BASE_OUTBOUND_MODE HAPPY_EYEBALLS_DELAY_MS BLOCK_PRIVATE_IP FINGERPRINT SPIDERX
  unset TRAFFIC_ENABLED TRAFFIC_API_PORT XRAY_API_PORT
  unset XHTTP_PORT XHTTP_BIND XHTTP_FAMILY XHTTP_UUID XHTTP_PATH XHTTP_MODE XHTTP_NAME XHTTP_SERVER_HOST
  unset HY2_PORT HY2_BIND HY2_FAMILY HY2_PASSWORD HY2_SNI HY2_CERT_MODE HY2_CERT_FILE HY2_KEY_FILE HY2_INSECURE HY2_NAME HY2_SERVER_HOST
  unset SS_PORT SS_BIND SS_FAMILY SS_NETWORK SS_METHOD SS_PASSWORD SS_NAME SS_SERVER_HOST
  # shellcheck disable=SC1090
  . "${META_FILE}"
  IPV4_PORT="${IPV4_PORT:-}"
  IPV6_PORT="${IPV6_PORT:-}"
  SNI="${SNI:-${DEFAULT_SNI}}"
  PRIVATE_KEY="${PRIVATE_KEY:-}"
  PUBLIC_KEY="${PUBLIC_KEY:-}"
  SHORT_ID="${SHORT_ID:-}"
  FALLBACK_MODE="${FALLBACK_MODE:-direct}"
  FALLBACK_PORT="${FALLBACK_PORT:-}"
  FALLBACK_LIMIT_MODE="${FALLBACK_LIMIT_MODE:-disabled}"
  FALLBACK_LIMIT_AFTER_BYTES="${FALLBACK_LIMIT_AFTER_BYTES:-}"
  FALLBACK_LIMIT_UPLOAD_BPS="${FALLBACK_LIMIT_UPLOAD_BPS:-}"
  FALLBACK_LIMIT_UPLOAD_BURST="${FALLBACK_LIMIT_UPLOAD_BURST:-}"
  FALLBACK_LIMIT_DOWNLOAD_BPS="${FALLBACK_LIMIT_DOWNLOAD_BPS:-}"
  FALLBACK_LIMIT_DOWNLOAD_BURST="${FALLBACK_LIMIT_DOWNLOAD_BURST:-}"
  if [ "${FALLBACK_MODE}" = "protected" ] && [ -n "${FALLBACK_PORT}" ]; then
    REALITY_DEST="127.0.0.1:${FALLBACK_PORT}"
  else
    FALLBACK_MODE="direct"
    FALLBACK_PORT=""
    FALLBACK_LIMIT_MODE="disabled"
    FALLBACK_LIMIT_AFTER_BYTES=""
    FALLBACK_LIMIT_UPLOAD_BPS=""
    FALLBACK_LIMIT_UPLOAD_BURST=""
    FALLBACK_LIMIT_DOWNLOAD_BPS=""
    FALLBACK_LIMIT_DOWNLOAD_BURST=""
    REALITY_DEST="${SNI}:443"
  fi
  BASE_OUTBOUND_MODE="${BASE_OUTBOUND_MODE:-${DEFAULT_BASE_OUTBOUND_MODE}}"
  HAPPY_EYEBALLS_DELAY_MS="${HAPPY_EYEBALLS_DELAY_MS:-${DEFAULT_HAPPY_EYEBALLS_DELAY_MS}}"
  BLOCK_PRIVATE_IP="${BLOCK_PRIVATE_IP:-${DEFAULT_BLOCK_PRIVATE_IP}}"
  case "${BLOCK_PRIVATE_IP}" in 0|false|no|off) BLOCK_PRIVATE_IP="0" ;; *) BLOCK_PRIVATE_IP="1" ;; esac
  TRAFFIC_ENABLED="${TRAFFIC_ENABLED:-${DEFAULT_TRAFFIC_ENABLED}}"
  case "${TRAFFIC_ENABLED}" in 1|true|yes|on) TRAFFIC_ENABLED="1" ;; *) TRAFFIC_ENABLED="0" ;; esac
  TRAFFIC_API_PORT="${TRAFFIC_API_PORT:-${DEFAULT_TRAFFIC_API_PORT}}"
  case "${TRAFFIC_API_PORT}" in ''|*[!0-9]*) TRAFFIC_API_PORT="${DEFAULT_TRAFFIC_API_PORT}" ;; esac
  XRAY_API_PORT="${XRAY_API_PORT:-${DEFAULT_XRAY_API_PORT}}"
  case "${XRAY_API_PORT}" in ''|*[!0-9]*) XRAY_API_PORT="${DEFAULT_XRAY_API_PORT}" ;; esac
  case "${HAPPY_EYEBALLS_DELAY_MS}" in ''|*[!0-9]*) HAPPY_EYEBALLS_DELAY_MS="${DEFAULT_HAPPY_EYEBALLS_DELAY_MS}" ;; esac
  if [ "${HAPPY_EYEBALLS_DELAY_MS}" -lt 25 ] || [ "${HAPPY_EYEBALLS_DELAY_MS}" -gt 2000 ]; then
    HAPPY_EYEBALLS_DELAY_MS="${DEFAULT_HAPPY_EYEBALLS_DELAY_MS}"
  fi
  SERVER_IPV4="${SERVER_IPV4:-}"
  SERVER_IPV6="${SERVER_IPV6:-}"
  FINGERPRINT="${FINGERPRINT:-chrome}"
  SPIDERX="${SPIDERX:-%2F}"

  XHTTP_PORT="${XHTTP_PORT:-}"
  XHTTP_BIND="${XHTTP_BIND:-0.0.0.0}"
  XHTTP_FAMILY="${XHTTP_FAMILY:-}"
  if [ -z "${XHTTP_FAMILY}" ]; then
    case "${XHTTP_BIND}" in ::) XHTTP_FAMILY="ipv6" ;; *) XHTTP_FAMILY="ipv4" ;; esac
  fi
  XHTTP_UUID="${XHTTP_UUID:-}"
  XHTTP_PATH="${XHTTP_PATH:-/vvrxhttp}"
  XHTTP_MODE="${XHTTP_MODE:-${DEFAULT_XHTTP_MODE}}"
  XHTTP_NAME="${XHTTP_NAME:-${DEFAULT_XHTTP_NAME}}"
  if [ -z "${XHTTP_SERVER_HOST:-}" ]; then
    case "${XHTTP_FAMILY}" in
      ipv6) XHTTP_SERVER_HOST="${SERVER_IPV6:-}" ;;
      *) XHTTP_SERVER_HOST="${SERVER_IPV4:-}" ;;
    esac
  fi

  HY2_PORT="${HY2_PORT:-}"
  HY2_BIND="${HY2_BIND:-0.0.0.0}"
  HY2_FAMILY="${HY2_FAMILY:-}"
  if [ -z "${HY2_FAMILY}" ]; then
    case "${HY2_BIND}" in ::) HY2_FAMILY="ipv6" ;; *) HY2_FAMILY="ipv4" ;; esac
  fi
  HY2_PASSWORD="${HY2_PASSWORD:-}"
  HY2_SNI="${HY2_SNI:-${DEFAULT_HY2_SNI}}"
  HY2_CERT_MODE="${HY2_CERT_MODE:-selfsigned}"
  HY2_CERT_FILE="${HY2_CERT_FILE:-}"
  HY2_KEY_FILE="${HY2_KEY_FILE:-}"
  HY2_INSECURE="${HY2_INSECURE:-1}"
  HY2_NAME="${HY2_NAME:-${DEFAULT_HY2_NAME}}"
  if [ -z "${HY2_SERVER_HOST:-}" ]; then
    case "${HY2_FAMILY}" in
      ipv6) HY2_SERVER_HOST="${SERVER_IPV6:-}" ;;
      *) HY2_SERVER_HOST="${SERVER_IPV4:-}" ;;
    esac
  fi

  SS_PORT="${SS_PORT:-}"
  SS_BIND="${SS_BIND:-0.0.0.0}"
  SS_FAMILY="${SS_FAMILY:-}"
  if [ -z "${SS_FAMILY}" ]; then
    case "${SS_BIND}" in ::) SS_FAMILY="ipv6" ;; *) SS_FAMILY="ipv4" ;; esac
  fi
  SS_NETWORK="${SS_NETWORK:-${DEFAULT_SS_NETWORK}}"
  SS_METHOD="${SS_METHOD:-${DEFAULT_SS_METHOD}}"
  SS_PASSWORD="${SS_PASSWORD:-}"
  SS_NAME="${SS_NAME:-${DEFAULT_SS_NAME}}"
  if [ -z "${SS_SERVER_HOST:-}" ]; then
    case "${SS_FAMILY}" in
      ipv6) SS_SERVER_HOST="${SERVER_IPV6:-}" ;;
      *) SS_SERVER_HOST="${SERVER_IPV4:-}" ;;
    esac
  fi
  ensure_clients_file
  ensure_xhttp_clients_file
  ensure_hy2_clients_file
  ensure_outbounds_file
  ensure_user_routes_file
  ensure_inbound_routes_file
  ensure_routes_file

  # Auto-migrate legacy single-user XHTTP / Hysteria 2 credentials into multi-client DBs.
  if [ -n "${XHTTP_UUID:-}" ] && [ ! -s "${XHTTP_CLIENTS_FILE}" ]; then
    printf '%s|%s\n' "${XHTTP_UUID}" "${XHTTP_NAME:-${DEFAULT_XHTTP_NAME}}" > "${XHTTP_CLIENTS_FILE}"
    chmod 0600 "${XHTTP_CLIENTS_FILE}"
  fi
  if [ -n "${HY2_PASSWORD:-}" ] && [ ! -s "${HY2_CLIENTS_FILE}" ]; then
    printf '%s|%s\n' "${HY2_PASSWORD}" "${HY2_NAME:-${DEFAULT_HY2_NAME}}" > "${HY2_CLIENTS_FILE}"
    chmod 0600 "${HY2_CLIENTS_FILE}"
  fi
}

# --- Outbound modes & config generation ---

outbound_mode_label() {
  case "$1" in
    ipv4) printf '%s' '仅 IPv4' ;;
    ipv6) printf '%s' '仅 IPv6' ;;
    ipv4v6) printf '%s' 'IPv4 优先，IPv6 兜底' ;;
    ipv6v4) printf '%s' 'IPv6 优先，IPv4 兜底' ;;
    happy4v6) printf '%s' 'IPv4 优先连接竞速' ;;
    happy6v4) printf '%s' 'IPv6 优先连接竞速' ;;
    block) printf '%s' '屏蔽 / 丢弃 (block)' ;;
    *)
      if custom_outbound_exists "$1" 2>/dev/null; then
        printf '落地代理 (%s)' "$1"
      else
        printf '%s' "未知 ($1)"
      fi
      ;;
  esac
}

outbound_tag_for_mode() {
  case "$1" in
    ipv4) printf '%s' 'direct-ipv4' ;;
    ipv6) printf '%s' 'direct-ipv6' ;;
    ipv4v6) printf '%s' 'direct-ipv4v6' ;;
    ipv6v4) printf '%s' 'direct-ipv6v4' ;;
    happy4v6) printf '%s' 'direct-happy-ipv4v6' ;;
    happy6v4) printf '%s' 'direct-happy-ipv6v4' ;;
    block) printf '%s' 'block' ;;
    *)
      if custom_outbound_exists "$1" 2>/dev/null; then
        printf '%s' "$1"
        return 0
      fi
      return 1
      ;;
  esac
}

build_custom_outbounds_json() {
  CUSTOM_OUTBOUNDS_JSON=""
  ensure_outbounds_file
  while IFS='|' read -r OB_TAG OB_PROTO OB_ADDR OB_PORT OB_F5 OB_F6; do
    [ -n "${OB_TAG}" ] && [ -n "${OB_PROTO}" ] && [ -n "${OB_ADDR}" ] && [ -n "${OB_PORT}" ] || continue
    case "${OB_PROTO}" in
      ss)
        CUSTOM_OUTBOUNDS_JSON="${CUSTOM_OUTBOUNDS_JSON}    {\"protocol\": \"shadowsocks\", \"tag\": \"${OB_TAG}\", \"settings\": {\"servers\": [{\"address\": \"${OB_ADDR}\", \"port\": ${OB_PORT}, \"method\": \"${OB_F5}\", \"password\": \"${OB_F6}\"}]}},
"
        ;;
      socks)
        if [ -n "${OB_F5}" ]; then
          CUSTOM_OUTBOUNDS_JSON="${CUSTOM_OUTBOUNDS_JSON}    {\"protocol\": \"socks\", \"tag\": \"${OB_TAG}\", \"settings\": {\"servers\": [{\"address\": \"${OB_ADDR}\", \"port\": ${OB_PORT}, \"users\": [{\"user\": \"${OB_F5}\", \"pass\": \"${OB_F6}\"}]}]}},
"
        else
          CUSTOM_OUTBOUNDS_JSON="${CUSTOM_OUTBOUNDS_JSON}    {\"protocol\": \"socks\", \"tag\": \"${OB_TAG}\", \"settings\": {\"servers\": [{\"address\": \"${OB_ADDR}\", \"port\": ${OB_PORT}}]}},
"
        fi
        ;;
    esac
  done < "${OUTBOUNDS_FILE}"
}

write_config() {
  ensure_routes_file
  ensure_clients_file
  ensure_xhttp_clients_file
  ensure_hy2_clients_file
  ensure_outbounds_file
  ensure_user_routes_file
  ensure_inbound_routes_file

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

  USER_OVERRIDE_RULES=""
  while IFS='|' read -r UR_USER UR_MODE; do
    [ -n "${UR_USER}" ] && [ -n "${UR_MODE}" ] || continue
    UR_TAG="$(outbound_tag_for_mode "${UR_MODE}" 2>/dev/null || true)"
    [ -n "${UR_TAG}" ] || continue
    USER_OVERRIDE_RULES="${USER_OVERRIDE_RULES}      {\"type\": \"field\", \"user\": [\"${UR_USER}\"], \"outboundTag\": \"${UR_TAG}\"},
"
  done < "${USER_ROUTES_FILE}"

  INBOUND_OVERRIDE_RULES=""
  while IFS='|' read -r IR_INBOUND IR_MODE; do
    [ -n "${IR_INBOUND}" ] && [ -n "${IR_MODE}" ] || continue
    IR_TAG="$(outbound_tag_for_mode "${IR_MODE}" 2>/dev/null || true)"
    [ -n "${IR_TAG}" ] || continue
    INBOUND_OVERRIDE_RULES="${INBOUND_OVERRIDE_RULES}      {\"type\": \"field\", \"inboundTag\": [\"${IR_INBOUND}\"], \"outboundTag\": \"${IR_TAG}\"},
"
  done < "${INBOUND_ROUTES_FILE}"

  BASE_OUTBOUND_TAG="$(outbound_tag_for_mode "${BASE_OUTBOUND_MODE}")" || {
    warn "基础出站模式无效：${BASE_OUTBOUND_MODE}"
    return 1
  }

  IPV4_CLIENTS=""
  IPV6_CLIENTS=""
  while IFS='|' read -r CLIENT_FAMILY CLIENT_UUID CLIENT_NAME; do
    [ -n "${CLIENT_UUID}" ] || continue
    EMAIL_VAL="${CLIENT_NAME:-${CLIENT_UUID}}"
    CLIENT_JSON="{\"id\": \"${CLIENT_UUID}\", \"flow\": \"xtls-rprx-vision\", \"email\": \"${EMAIL_VAL}\"}"
    case "${CLIENT_FAMILY}" in
      ipv4)
        [ -z "${IPV4_CLIENTS}" ] || IPV4_CLIENTS="${IPV4_CLIENTS}, "
        IPV4_CLIENTS="${IPV4_CLIENTS}${CLIENT_JSON}"
        ;;
      ipv6)
        [ -z "${IPV6_CLIENTS}" ] || IPV6_CLIENTS="${IPV6_CLIENTS}, "
        IPV6_CLIENTS="${IPV6_CLIENTS}${CLIENT_JSON}"
        ;;
    esac
  done < "${CLIENTS_FILE}"

  XHTTP_CLIENTS=""
  while IFS='|' read -r XC_UUID XC_NAME; do
    [ -n "${XC_UUID}" ] || continue
    EMAIL_VAL="${XC_NAME:-${XC_UUID}}"
    XC_JSON="{\"id\": \"${XC_UUID}\", \"flow\": \"\", \"email\": \"${EMAIL_VAL}\"}"
    [ -z "${XHTTP_CLIENTS}" ] || XHTTP_CLIENTS="${XHTTP_CLIENTS}, "
    XHTTP_CLIENTS="${XHTTP_CLIENTS}${XC_JSON}"
  done < "${XHTTP_CLIENTS_FILE}"
  if [ -z "${XHTTP_CLIENTS}" ] && [ -n "${XHTTP_UUID:-}" ]; then
    XHTTP_CLIENTS="{\"id\": \"${XHTTP_UUID}\", \"flow\": \"\", \"email\": \"${XHTTP_NAME:-${DEFAULT_XHTTP_NAME}}\"}"
  fi

  HY2_CLIENTS=""
  while IFS='|' read -r HC_PASS HC_NAME; do
    [ -n "${HC_PASS}" ] || continue
    EMAIL_VAL="${HC_NAME:-hy2-user}"
    HC_JSON="{\"auth\": \"${HC_PASS}\", \"email\": \"${EMAIL_VAL}\"}"
    [ -z "${HY2_CLIENTS}" ] || HY2_CLIENTS="${HY2_CLIENTS}, "
    HY2_CLIENTS="${HY2_CLIENTS}${HC_JSON}"
  done < "${HY2_CLIENTS_FILE}"
  if [ -z "${HY2_CLIENTS}" ] && [ -n "${HY2_PASSWORD:-}" ]; then
    HY2_CLIENTS="{\"auth\": \"${HY2_PASSWORD}\", \"email\": \"${HY2_NAME:-${DEFAULT_HY2_NAME}}\"}"
  fi

  REALITY_LIMIT_CONFIG=""
  if [ "${FALLBACK_MODE:-direct}" = "protected" ] && [ "${FALLBACK_LIMIT_MODE:-disabled}" != "disabled" ]; then
    REALITY_LIMIT_CONFIG=",
        \"limitFallbackUpload\": {\"afterBytes\": ${FALLBACK_LIMIT_AFTER_BYTES}, \"bytesPerSec\": ${FALLBACK_LIMIT_UPLOAD_BPS}, \"burstBytesPerSec\": ${FALLBACK_LIMIT_UPLOAD_BURST}},
        \"limitFallbackDownload\": {\"afterBytes\": ${FALLBACK_LIMIT_AFTER_BYTES}, \"bytesPerSec\": ${FALLBACK_LIMIT_DOWNLOAD_BPS}, \"burstBytesPerSec\": ${FALLBACK_LIMIT_DOWNLOAD_BURST}}"
  fi

  INBOUND_JSON=""
  INBOUND_SEP=""
  INBOUND_TAGS=""
  HAS_REALITY_INBOUND="0"

  if reality_keys_ready && [ -n "${IPV4_PORT:-}" ] && [ -n "${IPV4_CLIENTS}" ]; then
    INBOUND_JSON="${INBOUND_JSON}${INBOUND_SEP}
    {
      \"listen\": \"0.0.0.0\",
      \"port\": ${IPV4_PORT},
      \"protocol\": \"vless\",
      \"tag\": \"vless-in-ipv4\",
      \"settings\": {\"clients\": [${IPV4_CLIENTS}], \"decryption\": \"none\"},
      \"streamSettings\": {
        \"network\": \"tcp\",
        \"security\": \"reality\",
        \"realitySettings\": {
          \"show\": false,
          \"dest\": \"${REALITY_DEST}\",
          \"xver\": 0,
          \"serverNames\": [\"${SNI}\"],
          \"privateKey\": \"${PRIVATE_KEY}\",
          \"shortIds\": [\"${SHORT_ID}\"]${REALITY_LIMIT_CONFIG}
        }
      },
      \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"], \"routeOnly\": true}
    }"
    INBOUND_SEP=","
    INBOUND_TAGS="\"vless-in-ipv4\""
    HAS_REALITY_INBOUND="1"
  fi

  if reality_keys_ready && [ -n "${IPV6_PORT:-}" ] && [ -n "${IPV6_CLIENTS}" ]; then
    INBOUND_JSON="${INBOUND_JSON}${INBOUND_SEP}
    {
      \"listen\": \"::\",
      \"port\": ${IPV6_PORT},
      \"protocol\": \"vless\",
      \"tag\": \"vless-in-ipv6\",
      \"settings\": {\"clients\": [${IPV6_CLIENTS}], \"decryption\": \"none\"},
      \"streamSettings\": {
        \"network\": \"tcp\",
        \"security\": \"reality\",
        \"realitySettings\": {
          \"show\": false,
          \"dest\": \"${REALITY_DEST}\",
          \"xver\": 0,
          \"serverNames\": [\"${SNI}\"],
          \"privateKey\": \"${PRIVATE_KEY}\",
          \"shortIds\": [\"${SHORT_ID}\"]${REALITY_LIMIT_CONFIG}
        }
      },
      \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"], \"routeOnly\": true}
    }"
    INBOUND_SEP=","
    [ -z "${INBOUND_TAGS}" ] || INBOUND_TAGS="${INBOUND_TAGS}, "
    INBOUND_TAGS="${INBOUND_TAGS}\"vless-in-ipv6\""
    HAS_REALITY_INBOUND="1"
  fi

  if xhttp_is_configured && [ -n "${XHTTP_CLIENTS}" ]; then
    INBOUND_JSON="${INBOUND_JSON}${INBOUND_SEP}
    {
      \"listen\": \"${XHTTP_BIND:-0.0.0.0}\",
      \"port\": ${XHTTP_PORT},
      \"protocol\": \"vless\",
      \"tag\": \"${XHTTP_INBOUND_TAG}\",
      \"settings\": {\"clients\": [${XHTTP_CLIENTS}], \"decryption\": \"none\"},
      \"streamSettings\": {
        \"network\": \"xhttp\",
        \"xhttpSettings\": {\"path\": \"${XHTTP_PATH:-/vvrxhttp}\", \"mode\": \"${XHTTP_MODE:-auto}\"},
        \"security\": \"reality\",
        \"realitySettings\": {
          \"show\": false,
          \"dest\": \"${REALITY_DEST}\",
          \"xver\": 0,
          \"serverNames\": [\"${SNI}\"],
          \"privateKey\": \"${PRIVATE_KEY}\",
          \"shortIds\": [\"${SHORT_ID}\"]${REALITY_LIMIT_CONFIG}
        }
      },
      \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"], \"routeOnly\": true}
    }"
    INBOUND_SEP=","
    [ -z "${INBOUND_TAGS}" ] || INBOUND_TAGS="${INBOUND_TAGS}, "
    INBOUND_TAGS="${INBOUND_TAGS}\"${XHTTP_INBOUND_TAG}\""
    HAS_REALITY_INBOUND="1"
  fi

  FALLBACK_RULES=""
  if [ "${HAS_REALITY_INBOUND}" = "1" ] && [ "${FALLBACK_MODE:-direct}" = "protected" ] && [ -n "${FALLBACK_PORT:-}" ]; then
    INBOUND_JSON="${INBOUND_JSON}${INBOUND_SEP}
    {
      \"listen\": \"127.0.0.1\",
      \"port\": ${FALLBACK_PORT},
      \"protocol\": \"dokodemo-door\",
      \"tag\": \"reality-fallback\",
      \"settings\": {\"address\": \"${SNI}\", \"port\": 443, \"network\": \"tcp\"},
      \"sniffing\": {\"enabled\": true, \"destOverride\": [\"tls\"], \"routeOnly\": false}
    }"
    INBOUND_SEP=","
    FALLBACK_RULES="      {\"type\": \"field\", \"inboundTag\": [\"reality-fallback\"], \"domain\": [\"full:${SNI}\"], \"outboundTag\": \"${BASE_OUTBOUND_TAG}\"},
      {\"type\": \"field\", \"inboundTag\": [\"reality-fallback\"], \"outboundTag\": \"block\"},
"
  fi

  if hy2_is_configured && [ -n "${HY2_CLIENTS}" ]; then
    INBOUND_JSON="${INBOUND_JSON}${INBOUND_SEP}
    {
      \"listen\": \"${HY2_BIND:-0.0.0.0}\",
      \"port\": ${HY2_PORT},
      \"protocol\": \"hysteria\",
      \"tag\": \"${HY2_INBOUND_TAG}\",
      \"settings\": {\"version\": 2, \"clients\": [${HY2_CLIENTS}]},
      \"streamSettings\": {
        \"network\": \"hysteria\",
        \"security\": \"tls\",
        \"tlsSettings\": {
          \"alpn\": [\"h3\"],
          \"certificates\": [{\"certificateFile\": \"${HY2_CERT_FILE}\", \"keyFile\": \"${HY2_KEY_FILE}\"}]
        },
        \"hysteriaSettings\": {\"version\": 2}
      },
      \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"], \"routeOnly\": true}
    }"
    INBOUND_SEP=","
    [ -z "${INBOUND_TAGS}" ] || INBOUND_TAGS="${INBOUND_TAGS}, "
    INBOUND_TAGS="${INBOUND_TAGS}\"${HY2_INBOUND_TAG}\""
  fi

  if ss_is_configured; then
    INBOUND_JSON="${INBOUND_JSON}${INBOUND_SEP}
    {
      \"listen\": \"${SS_BIND}\",
      \"port\": ${SS_PORT},
      \"protocol\": \"shadowsocks\",
      \"tag\": \"${SS_INBOUND_TAG}\",
      \"settings\": {\"method\": \"${SS_METHOD}\", \"password\": \"${SS_PASSWORD}\", \"network\": \"${SS_NETWORK}\"},
      \"sniffing\": {\"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"], \"routeOnly\": true}
    }"
    [ -z "${INBOUND_TAGS}" ] || INBOUND_TAGS="${INBOUND_TAGS}, "
    INBOUND_TAGS="${INBOUND_TAGS}\"${SS_INBOUND_TAG}\""
  fi

  if [ -z "${INBOUND_JSON}" ]; then
    warn "至少需要一个启用的入站协议。"
    return 1
  fi

  STATS_API_BLOCK=""
  API_RULE=""
  if [ "${TRAFFIC_ENABLED:-0}" = "1" ]; then
    STATS_API_BLOCK="  \"stats\": {},
  \"policy\": {\"system\": {\"statsInboundUplink\": true, \"statsInboundDownlink\": true}, \"levels\": {\"0\": {\"statsUserUplink\": true, \"statsUserDownlink\": true}}},
  \"api\": {\"tag\": \"api\", \"services\": [\"StatsService\"]},
"
    INBOUND_JSON="${INBOUND_JSON},
    {
      \"listen\": \"127.0.0.1\",
      \"port\": ${XRAY_API_PORT:-${DEFAULT_XRAY_API_PORT}},
      \"protocol\": \"dokodemo-door\",
      \"tag\": \"api\",
      \"settings\": {\"address\": \"127.0.0.1\"},
      \"streamSettings\": {\"sockopt\": {\"acceptProxyProtocol\": false}}
    }"
    API_RULE="      {\"type\": \"field\", \"inboundTag\": [\"api\"], \"outboundTag\": \"api\"},
"
  fi

  build_custom_outbounds_json

  PRIVATE_IP_RULE=""
  ROUTING_DOMAIN_STRATEGY="AsIs"
  if [ "${BLOCK_PRIVATE_IP:-${DEFAULT_BLOCK_PRIVATE_IP}}" = "1" ]; then
    ROUTING_DOMAIN_STRATEGY="IPIfNonMatch"
    PRIVATE_IP_RULE="      {\"type\": \"field\", \"ip\": [\"127.0.0.0/8\", \"10.0.0.0/8\", \"100.64.0.0/10\", \"172.16.0.0/12\", \"192.168.0.0/16\", \"169.254.0.0/16\", \"::1/128\", \"fc00::/7\", \"fe80::/10\"], \"outboundTag\": \"block\"},
"
  fi

  mkdir -p "${CONFIG_DIR}"
  cat > "${CONFIG_FILE}" <<CONFIG
{
  "log": {"loglevel": "warning"},
${STATS_API_BLOCK}  "dns": {
    "servers": ["localhost", "1.1.1.1"],
    "queryStrategy": "UseIP"
  },
  "inbounds": [${INBOUND_JSON}
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct-ipv4", "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4"}}},
    {"protocol": "freedom", "tag": "direct-ipv6", "streamSettings": {"sockopt": {"domainStrategy": "UseIPv6"}}},
    {"protocol": "freedom", "tag": "direct-ipv4v6", "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4v6"}}},
    {"protocol": "freedom", "tag": "direct-ipv6v4", "streamSettings": {"sockopt": {"domainStrategy": "UseIPv6v4"}}},
    {"protocol": "freedom", "tag": "direct-happy-ipv4v6", "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4v6", "happyEyeballs": {"tryDelayMs": ${HAPPY_EYEBALLS_DELAY_MS}, "prioritizeIPv6": false}}}},
    {"protocol": "freedom", "tag": "direct-happy-ipv6v4", "streamSettings": {"sockopt": {"domainStrategy": "UseIPv6v4", "happyEyeballs": {"tryDelayMs": ${HAPPY_EYEBALLS_DELAY_MS}, "prioritizeIPv6": true}}}},
${CUSTOM_OUTBOUNDS_JSON}    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "${ROUTING_DOMAIN_STRATEGY}",
    "rules": [
${API_RULE}${FALLBACK_RULES}      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
${PRIVATE_IP_RULE}${ROUTING_RULES}${USER_OVERRIDE_RULES}${INBOUND_OVERRIDE_RULES}      {"type": "field", "inboundTag": [${INBOUND_TAGS}], "outboundTag": "${BASE_OUTBOUND_TAG}"}
    ]
  }
}
CONFIG
  chmod 0600 "${CONFIG_FILE}"
  return 0
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

apply_config() {
  CONFIG_BACKUP="$(mktemp /tmp/vvr-config.XXXXXX)"
  if [ -f "${CONFIG_FILE}" ]; then
    cp -a "${CONFIG_FILE}" "${CONFIG_BACKUP}"
  else
    : > "${CONFIG_BACKUP}"
  fi

  if ! write_config; then
    [ -s "${CONFIG_BACKUP}" ] && cp -a "${CONFIG_BACKUP}" "${CONFIG_FILE}"
    restore_all_pending_backups
    rm -f "${CONFIG_BACKUP}"
    return 1
  fi
  if ! test_config; then
    [ -s "${CONFIG_BACKUP}" ] && cp -a "${CONFIG_BACKUP}" "${CONFIG_FILE}"
    restore_all_pending_backups
    rm -f "${CONFIG_BACKUP}"
    warn "新配置检查失败，已恢复旧配置。"
    return 1
  fi
  if ! service_restart; then
    [ -s "${CONFIG_BACKUP}" ] && cp -a "${CONFIG_BACKUP}" "${CONFIG_FILE}"
    restore_all_pending_backups
    service_restart >/dev/null 2>&1 || true
    rm -f "${CONFIG_BACKUP}"
    warn "Xray 重启失败，已恢复旧配置。"
    return 1
  fi
  sleep 1
  if ! service_is_running; then
    [ -s "${CONFIG_BACKUP}" ] && cp -a "${CONFIG_BACKUP}" "${CONFIG_FILE}"
    restore_all_pending_backups
    service_restart >/dev/null 2>&1 || true
    rm -f "${CONFIG_BACKUP}"
    warn "Xray 服务状态异常，已恢复旧配置。"
    return 1
  fi
  rm -f "${CONFIG_BACKUP}"
  discard_all_pending_backups
  save_state
  ok "配置已应用并生效。"
  return 0
}

# --- URI builders & display ---

make_uri() {
  URI_FAMILY="$1"
  URI_UUID="$2"
  URI_NAME="$3"
  case "${URI_FAMILY}" in
    ipv4)
      URI_PORT="${IPV4_PORT}"
      if [ -n "${SERVER_IPV4:-}" ]; then URI_HOST="${SERVER_IPV4}"; else URI_HOST="你的服务器IPv4地址"; fi
      ;;
    ipv6)
      URI_PORT="${IPV6_PORT}"
      if [ -n "${SERVER_IPV6:-}" ]; then URI_HOST="[${SERVER_IPV6}]"; else URI_HOST="[你的服务器IPv6地址]"; fi
      ;;
    *) return 1 ;;
  esac
  URI="vless://${URI_UUID}@${URI_HOST}:${URI_PORT}?type=tcp&encryption=none&security=reality&pbk=${PUBLIC_KEY}&fp=${FINGERPRINT}&sni=${SNI}&sid=${SHORT_ID}&spx=${SPIDERX}&flow=xtls-rprx-vision#${URI_NAME}"
}

format_uri_host() {
  HOST_FAMILY="$1"
  HOST_OVERRIDE="${2:-}"
  case "${HOST_FAMILY}" in
    ipv6)
      RAW_HOST="${HOST_OVERRIDE:-${SERVER_IPV6:-}}"
      if [ -n "${RAW_HOST}" ]; then
        case "${RAW_HOST}" in \[*\]) printf '%s' "${RAW_HOST}" ;; *:*) printf '[%s]' "${RAW_HOST}" ;; *) printf '%s' "${RAW_HOST}" ;; esac
      else
        printf '%s' '[你的服务器IPv6地址]'
      fi
      ;;
    *)
      RAW_HOST="${HOST_OVERRIDE:-${SERVER_IPV4:-}}"
      if [ -n "${RAW_HOST}" ]; then
        case "${RAW_HOST}" in \[*\]) printf '%s' "${RAW_HOST}" ;; *:*) printf '[%s]' "${RAW_HOST}" ;; *) printf '%s' "${RAW_HOST}" ;; esac
      else
        printf '%s' '你的服务器IPv4地址'
      fi
      ;;
  esac
}

make_xhttp_uri() {
  X_UUID="${1:-${XHTTP_UUID}}"
  X_NAME="${2:-${XHTTP_NAME:-${DEFAULT_XHTTP_NAME}}}"
  XHTTP_URI_HOST="$(format_uri_host "${XHTTP_FAMILY:-ipv4}" "${XHTTP_SERVER_HOST:-}")"
  XHTTP_PATH_ENC="$(printf '%s' "${XHTTP_PATH:-/vvrxhttp}" | sed 's|/|%2F|g')"
  XHTTP_URI="vless://${X_UUID}@${XHTTP_URI_HOST}:${XHTTP_PORT}?type=xhttp&encryption=none&security=reality&pbk=${PUBLIC_KEY}&fp=${FINGERPRINT}&sni=${SNI}&sid=${SHORT_ID}&path=${XHTTP_PATH_ENC}&mode=${XHTTP_MODE:-auto}#${X_NAME}"
}

make_hy2_uri() {
  H_PASS="${1:-${HY2_PASSWORD}}"
  H_NAME="${2:-${HY2_NAME:-${DEFAULT_HY2_NAME}}}"
  HY2_URI_HOST="$(format_uri_host "${HY2_FAMILY:-ipv4}" "${HY2_SERVER_HOST:-}")"
  if [ "${HY2_INSECURE:-1}" = "1" ]; then
    HY2_URI="hysteria2://${H_PASS}@${HY2_URI_HOST}:${HY2_PORT}?sni=${HY2_SNI}&alpn=h3&insecure=1#${H_NAME}"
  else
    HY2_URI="hysteria2://${H_PASS}@${HY2_URI_HOST}:${HY2_PORT}?sni=${HY2_SNI}&alpn=h3#${H_NAME}"
  fi
}

make_ss_uri() {
  SS_URI_HOST="$(format_uri_host "${SS_FAMILY:-ipv4}" "${SS_SERVER_HOST:-}")"
  SS_URI_USER="$(printf '%s' "${SS_METHOD}:${SS_PASSWORD}" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  SS_URI="ss://${SS_URI_USER}@${SS_URI_HOST}:${SS_PORT}#${SS_NAME}"
}

show_vless_clients() {
  echo
  echo "=============================="
  echo " VLESS + Vision + REALITY"
  echo "=============================="
  if vless_is_configured; then
    V4_CNT="$(client_count ipv4)"
    V6_CNT="$(client_count ipv6)"
    echo "状态：已启用（共 $((V4_CNT + V6_CNT)) 个客户端）"
    if [ "${V4_CNT}" -gt 0 ] && [ -n "${IPV4_PORT}" ]; then
      echo "IPv4 入站：0.0.0.0:${IPV4_PORT}（公网：$(ipv4_display)）"
    else
      echo "IPv4 入站：未启用"
    fi
    if [ "${V6_CNT}" -gt 0 ] && [ -n "${IPV6_PORT}" ]; then
      echo "IPv6 入站：[::]:${IPV6_PORT}（公网：$(ipv6_display)）"
    else
      echo "IPv6 入站：未启用"
    fi
    echo "SNI：${SNI}"
    if [ "${FALLBACK_MODE}" = "protected" ]; then
      echo "回落模式：高级保护（127.0.0.1:${FALLBACK_PORT} -> ${SNI}:443，限速：${FALLBACK_LIMIT_MODE}）"
    else
      echo "回落模式：普通（${REALITY_DEST}）"
    fi
    echo "基础出站：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")"
    echo
    NUMBER=0
    while IFS='|' read -r CLIENT_FAMILY CLIENT_UUID CLIENT_NAME; do
      [ -n "${CLIENT_UUID}" ] || continue
      NUMBER=$((NUMBER + 1))
      make_uri "${CLIENT_FAMILY}" "${CLIENT_UUID}" "${CLIENT_NAME}"
      printf '%s. [%s] %s\n%s\n\n' "${NUMBER}" "${CLIENT_FAMILY}" "${CLIENT_NAME}" "${URI}"
    done < "${CLIENTS_FILE}"
    [ "${NUMBER}" -gt 0 ] || echo "（暂无 VLESS 客户端）"
  else
    echo "状态：未启用"
  fi
}

show_xhttp_info() {
  echo
  echo "=============================="
  echo " VLESS + XHTTP + REALITY"
  echo "=============================="
  if xhttp_is_configured; then
    ensure_xhttp_clients_file
    echo "状态：已启用（共 $(xhttp_client_count) 个客户端）"
    echo "监听地址：${XHTTP_BIND}:${XHTTP_PORT}（${XHTTP_FAMILY}）"
    echo "路径/模式：${XHTTP_PATH} | mode=${XHTTP_MODE}"
    echo "SNI：${SNI}（共用 REALITY 密钥与回落配置）"
    echo
    NUMBER=0
    while IFS='|' read -r XC_UUID XC_NAME; do
      [ -n "${XC_UUID}" ] || continue
      NUMBER=$((NUMBER + 1))
      make_xhttp_uri "${XC_UUID}" "${XC_NAME}"
      printf '%s. %s\n%s\n\n' "${NUMBER}" "${XC_NAME}" "${XHTTP_URI}"
    done < "${XHTTP_CLIENTS_FILE}"
    if [ "${NUMBER}" -eq 0 ] && [ -n "${XHTTP_UUID:-}" ]; then
      make_xhttp_uri "${XHTTP_UUID}" "${XHTTP_NAME:-${DEFAULT_XHTTP_NAME}}"
      printf '1. %s\n%s\n' "${XHTTP_NAME:-${DEFAULT_XHTTP_NAME}}" "${XHTTP_URI}"
    fi
  else
    echo "状态：未启用"
  fi
}

show_hy2_info() {
  echo
  echo "=============================="
  echo " Hysteria 2 (UDP / QUIC)"
  echo "=============================="
  if hy2_is_configured; then
    ensure_hy2_clients_file
    echo "状态：已启用（共 $(hy2_client_count) 个客户端）"
    echo "监听地址：${HY2_BIND}:${HY2_PORT}/udp（${HY2_FAMILY}）"
    echo "SNI：${HY2_SNI} | 证书模式：${HY2_CERT_MODE}（insecure=${HY2_INSECURE}）"
    echo "证书路径：${HY2_CERT_FILE}"
    echo
    NUMBER=0
    while IFS='|' read -r HC_PASS HC_NAME; do
      [ -n "${HC_PASS}" ] || continue
      NUMBER=$((NUMBER + 1))
      make_hy2_uri "${HC_PASS}" "${HC_NAME}"
      printf '%s. %s（密码：%s）\n%s\n\n' "${NUMBER}" "${HC_NAME}" "${HC_PASS}" "${HY2_URI}"
    done < "${HY2_CLIENTS_FILE}"
    if [ "${NUMBER}" -eq 0 ] && [ -n "${HY2_PASSWORD:-}" ]; then
      make_hy2_uri "${HY2_PASSWORD}" "${HY2_NAME:-${DEFAULT_HY2_NAME}}"
      printf '1. %s（密码：%s）\n%s\n' "${HY2_NAME:-${DEFAULT_HY2_NAME}}" "${HY2_PASSWORD}" "${HY2_URI}"
    fi
  else
    echo "状态：未启用"
  fi
}

show_ss_info() {
  echo
  echo "=============================="
  echo " Shadowsocks"
  echo "=============================="
  if ss_is_configured; then
    echo "状态：已启用"
    case "${SS_FAMILY}" in
      ipv6)
        echo "入站地址族：IPv6（监听 [::]:${SS_PORT}）"
        echo "公网地址：${SS_SERVER_HOST:-未检测到公网 IPv6}"
        ;;
      *)
        echo "入站地址族：IPv4（监听 0.0.0.0:${SS_PORT}）"
        echo "公网地址：${SS_SERVER_HOST:-未检测到公网 IPv4}"
        ;;
    esac
    echo "加密方法：${SS_METHOD}"
    echo "传输网络：${SS_NETWORK}"
    echo "节点名称：${SS_NAME}"
    echo "密码：${SS_PASSWORD}"
    make_ss_uri
    echo
    echo "客户端链接："
    echo "${SS_URI}"
  else
    echo "状态：未启用"
  fi
}

show_all_nodes() {
  load_state
  show_vless_clients
  show_xhttp_info
  show_hy2_info
  show_ss_info
}

collect_all_uris() {
  FILTER_USER="${1:-}"
  if vless_is_configured; then
    while IFS='|' read -r CLIENT_FAMILY CLIENT_UUID CLIENT_NAME; do
      [ -n "${CLIENT_UUID}" ] || continue
      if [ -n "${FILTER_USER}" ] && [ "${CLIENT_NAME}" != "${FILTER_USER}" ]; then continue; fi
      make_uri "${CLIENT_FAMILY}" "${CLIENT_UUID}" "${CLIENT_NAME}"
      printf '%s\n' "${URI}"
    done < "${CLIENTS_FILE}"
  fi
  if xhttp_is_configured; then
    ensure_xhttp_clients_file
    XC_FOUND=0
    while IFS='|' read -r XC_UUID XC_NAME; do
      [ -n "${XC_UUID}" ] || continue
      XC_FOUND=1
      if [ -n "${FILTER_USER}" ] && [ "${XC_NAME}" != "${FILTER_USER}" ]; then continue; fi
      make_xhttp_uri "${XC_UUID}" "${XC_NAME}"
      printf '%s\n' "${XHTTP_URI}"
    done < "${XHTTP_CLIENTS_FILE}"
    if [ "${XC_FOUND}" -eq 0 ] && [ -n "${XHTTP_UUID:-}" ]; then
      if [ -z "${FILTER_USER}" ] || [ "${XHTTP_NAME:-${DEFAULT_XHTTP_NAME}}" = "${FILTER_USER}" ]; then
        make_xhttp_uri "${XHTTP_UUID}" "${XHTTP_NAME:-${DEFAULT_XHTTP_NAME}}"
        printf '%s\n' "${XHTTP_URI}"
      fi
    fi
  fi
  if hy2_is_configured; then
    ensure_hy2_clients_file
    HC_FOUND=0
    while IFS='|' read -r HC_PASS HC_NAME; do
      [ -n "${HC_PASS}" ] || continue
      HC_FOUND=1
      if [ -n "${FILTER_USER}" ] && [ "${HC_NAME}" != "${FILTER_USER}" ]; then continue; fi
      make_hy2_uri "${HC_PASS}" "${HC_NAME}"
      printf '%s\n' "${HY2_URI}"
    done < "${HY2_CLIENTS_FILE}"
    if [ "${HC_FOUND}" -eq 0 ] && [ -n "${HY2_PASSWORD:-}" ]; then
      if [ -z "${FILTER_USER}" ] || [ "${HY2_NAME:-${DEFAULT_HY2_NAME}}" = "${FILTER_USER}" ]; then
        make_hy2_uri "${HY2_PASSWORD}" "${HY2_NAME:-${DEFAULT_HY2_NAME}}"
        printf '%s\n' "${HY2_URI}"
      fi
    fi
  fi
  if [ -z "${FILTER_USER}" ] && ss_is_configured; then
    make_ss_uri
    printf '%s\n' "${SS_URI}"
  fi
}

list_all_usernames() {
  ensure_clients_file
  ensure_xhttp_clients_file
  ensure_hy2_clients_file
  {
    awk -F '|' '$2 != "" && $3 != "" {print $3}' "${CLIENTS_FILE}"
    awk -F '|' '$1 != "" && $2 != "" {print $2}' "${XHTTP_CLIENTS_FILE}"
    awk -F '|' '$1 != "" && $2 != "" {print $2}' "${HY2_CLIENTS_FILE}"
  } | sort -u
}

show_quick_links() {
  load_state
  URIS="$(collect_all_uris)"
  echo
  echo "${BOLD}========== 全部节点链接（可直接全选复制） ==========${RESET}"
  if [ -n "${URIS}" ]; then
    printf '%s\n' "${URIS}"
  else
    echo "（暂无已启用的节点）"
  fi
  echo "${BOLD}====================================================${RESET}"
  echo "需放行端口：$(firewall_ports_summary)"
}

export_base64_sub() {
  load_state
  FILTER_USER="${1:-}"
  URIS="$(collect_all_uris "${FILTER_USER}")"
  if [ -z "${URIS}" ]; then
    echo "（暂无匹配的节点）"
    return 0
  fi
  echo
  if [ -n "${FILTER_USER}" ]; then
    echo "${BOLD}========== 用户 [${FILTER_USER}] Base64 订阅串 ==========${RESET}"
  else
    echo "${BOLD}========== Base64 合并订阅串 ==========${RESET}"
  fi
  printf '%s\n' "${URIS}" | openssl base64 -A
  echo
  echo "${BOLD}=======================================${RESET}"
}

raw_host_for_yaml() {
  Y_FAM="$1"
  Y_OVR="${2:-}"
  case "${Y_FAM}" in
    ipv6)
      Y_HOST="${Y_OVR:-${SERVER_IPV6:-}}"
      Y_HOST="${Y_HOST#\[}"
      Y_HOST="${Y_HOST%\]}"
      [ -n "${Y_HOST}" ] && printf '%s' "${Y_HOST}" || printf '%s' 'YOUR_SERVER_IPV6'
      ;;
    *)
      Y_HOST="${Y_OVR:-${SERVER_IPV4:-}}"
      [ -n "${Y_HOST}" ] && printf '%s' "${Y_HOST}" || printf '%s' 'YOUR_SERVER_IPV4'
      ;;
  esac
}

export_mihomo_yaml() {
  load_state
  FILTER_USER="${1:-}"
  echo
  if [ -n "${FILTER_USER}" ]; then
    echo "# Clash / Mihomo proxies 节点片段（用户：${FILTER_USER}）"
  else
    echo "# Clash / Mihomo proxies 节点片段（可直接粘贴到 proxies: 下）"
  fi
  echo "proxies:"
  ANY_YAML="0"

  if vless_is_configured; then
    while IFS='|' read -r CLIENT_FAMILY CLIENT_UUID CLIENT_NAME; do
      [ -n "${CLIENT_UUID}" ] || continue
      if [ -n "${FILTER_USER}" ] && [ "${CLIENT_NAME}" != "${FILTER_USER}" ]; then continue; fi
      ANY_YAML="1"
      case "${CLIENT_FAMILY}" in
        ipv6) Y_PORT="${IPV6_PORT}"; Y_SRV="$(raw_host_for_yaml ipv6 "")" ;;
        *) Y_PORT="${IPV4_PORT}"; Y_SRV="$(raw_host_for_yaml ipv4 "")" ;;
      esac
      cat <<YAML
  - name: "${CLIENT_NAME}-vision"
    type: vless
    server: "${Y_SRV}"
    port: ${Y_PORT}
    uuid: "${CLIENT_UUID}"
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: "${SNI}"
    reality-opts:
      public-key: "${PUBLIC_KEY}"
      short-id: "${SHORT_ID}"
    client-fingerprint: ${FINGERPRINT}
YAML
    done < "${CLIENTS_FILE}"
  fi

  if xhttp_is_configured; then
    ensure_xhttp_clients_file
    Y_SRV="$(raw_host_for_yaml "${XHTTP_FAMILY}" "${XHTTP_SERVER_HOST}")"
    XC_YFOUND=0
    while IFS='|' read -r XC_UUID XC_NAME; do
      [ -n "${XC_UUID}" ] || continue
      XC_YFOUND=1
      if [ -n "${FILTER_USER}" ] && [ "${XC_NAME}" != "${FILTER_USER}" ]; then continue; fi
      ANY_YAML="1"
      cat <<YAML
  - name: "${XC_NAME}-xhttp"
    type: vless
    server: "${Y_SRV}"
    port: ${XHTTP_PORT}
    uuid: "${XC_UUID}"
    network: xhttp
    tls: true
    udp: true
    servername: "${SNI}"
    xhttp-opts:
      path: "${XHTTP_PATH}"
      mode: "${XHTTP_MODE}"
    reality-opts:
      public-key: "${PUBLIC_KEY}"
      short-id: "${SHORT_ID}"
    client-fingerprint: ${FINGERPRINT}
YAML
    done < "${XHTTP_CLIENTS_FILE}"
    if [ "${XC_YFOUND}" -eq 0 ] && [ -n "${XHTTP_UUID:-}" ]; then
      if [ -z "${FILTER_USER}" ] || [ "${XHTTP_NAME:-${DEFAULT_XHTTP_NAME}}" = "${FILTER_USER}" ]; then
        ANY_YAML="1"
        cat <<YAML
  - name: "${XHTTP_NAME:-${DEFAULT_XHTTP_NAME}}-xhttp"
    type: vless
    server: "${Y_SRV}"
    port: ${XHTTP_PORT}
    uuid: "${XHTTP_UUID}"
    network: xhttp
    tls: true
    udp: true
    servername: "${SNI}"
    xhttp-opts:
      path: "${XHTTP_PATH}"
      mode: "${XHTTP_MODE}"
    reality-opts:
      public-key: "${PUBLIC_KEY}"
      short-id: "${SHORT_ID}"
    client-fingerprint: ${FINGERPRINT}
YAML
      fi
    fi
  fi

  if hy2_is_configured; then
    ensure_hy2_clients_file
    Y_SRV="$(raw_host_for_yaml "${HY2_FAMILY}" "${HY2_SERVER_HOST}")"
    if [ "${HY2_INSECURE:-1}" = "1" ]; then Y_SKIP="true"; else Y_SKIP="false"; fi
    HC_YFOUND=0
    while IFS='|' read -r HC_PASS HC_NAME; do
      [ -n "${HC_PASS}" ] || continue
      HC_YFOUND=1
      if [ -n "${FILTER_USER}" ] && [ "${HC_NAME}" != "${FILTER_USER}" ]; then continue; fi
      ANY_YAML="1"
      cat <<YAML
  - name: "${HC_NAME}-hy2"
    type: hysteria2
    server: "${Y_SRV}"
    port: ${HY2_PORT}
    password: "${HC_PASS}"
    sni: "${HY2_SNI}"
    alpn:
      - h3
    skip-cert-verify: ${Y_SKIP}
YAML
    done < "${HY2_CLIENTS_FILE}"
    if [ "${HC_YFOUND}" -eq 0 ] && [ -n "${HY2_PASSWORD:-}" ]; then
      if [ -z "${FILTER_USER}" ] || [ "${HY2_NAME:-${DEFAULT_HY2_NAME}}" = "${FILTER_USER}" ]; then
        ANY_YAML="1"
        cat <<YAML
  - name: "${HY2_NAME:-${DEFAULT_HY2_NAME}}-hy2"
    type: hysteria2
    server: "${Y_SRV}"
    port: ${HY2_PORT}
    password: "${HY2_PASSWORD}"
    sni: "${HY2_SNI}"
    alpn:
      - h3
    skip-cert-verify: ${Y_SKIP}
YAML
      fi
    fi
  fi

  if [ -z "${FILTER_USER}" ] && ss_is_configured; then
    ANY_YAML="1"
    Y_SRV="$(raw_host_for_yaml "${SS_FAMILY}" "${SS_SERVER_HOST}")"
    case "${SS_NETWORK:-tcp}" in *udp*) Y_UDP="true" ;; *) Y_UDP="false" ;; esac
    cat <<YAML
  - name: "${SS_NAME}"
    type: ss
    server: "${Y_SRV}"
    port: ${SS_PORT}
    cipher: "${SS_METHOD}"
    password: "${SS_PASSWORD}"
    udp: ${Y_UDP}
YAML
  fi

  [ "${ANY_YAML}" = "1" ] || echo "  # （暂无匹配的节点）"
}

show_user_bundle() {
  TARGET_USER="$1"
  load_state
  URIS="$(collect_all_uris "${TARGET_USER}")"
  if [ -z "${URIS}" ]; then
    warn "未找到用户 [${TARGET_USER}] 的任何节点。"
    return 1
  fi
  echo
  echo "${BOLD}========== 用户 [${TARGET_USER}] 专属纯链接 ==========${RESET}"
  printf '%s\n' "${URIS}"
  echo "${BOLD}====================================================${RESET}"
  export_base64_sub "${TARGET_USER}"
  export_mihomo_yaml "${TARGET_USER}"
}

create_unified_user() {
  load_state
  if ! vless_is_configured && ! xhttp_is_configured && ! hy2_is_configured; then
    warn "当前尚未启用任何支持多客户端的协议（VLESS-Vision / VLESS-XHTTP / Hysteria 2）。"
    return 0
  fi
  prompt_tag "" "新用户名称（将同步创建到已启用协议）" 1 || { MENU_RETURNED="1"; return 0; }
  NEW_USER="${TAG}"

  ADD_V4="0"
  ADD_V6="0"
  ADD_XHTTP="0"
  ADD_HY2="0"

  if vless_is_configured; then
    if [ -n "${IPV4_PORT:-}" ] && [ "$(client_count ipv4)" -gt 0 ] && ! client_name_exists ipv4 "${NEW_USER}"; then
      ADD_V4="1"
    fi
    if [ -n "${IPV6_PORT:-}" ] && [ "$(client_count ipv6)" -gt 0 ] && ! client_name_exists ipv6 "${NEW_USER}"; then
      ADD_V6="1"
    fi
  fi
  if xhttp_is_configured && ! xhttp_client_name_exists "${NEW_USER}"; then
    ADD_XHTTP="1"
  fi
  if hy2_is_configured && ! hy2_client_name_exists "${NEW_USER}"; then
    ADD_HY2="1"
  fi

  if [ "${ADD_V4}" = "0" ] && [ "${ADD_V6}" = "0" ] && [ "${ADD_XHTTP}" = "0" ] && [ "${ADD_HY2}" = "0" ]; then
    warn "用户 [${NEW_USER}] 在所有已启用协议中均已存在。"
    return 0
  fi

  CREATED_LIST=""
  if [ "${ADD_V4}" = "1" ] || [ "${ADD_V6}" = "1" ]; then
    backup_clients_for_change
    if [ "${ADD_V4}" = "1" ]; then
      generate_uuid || { restore_all_pending_backups; return 1; }
      printf 'ipv4|%s|%s\n' "${UUID}" "${NEW_USER}" >> "${CLIENTS_FILE}"
      CREATED_LIST="${CREATED_LIST} VLESS-Vision(IPv4)"
    fi
    if [ "${ADD_V6}" = "1" ]; then
      generate_uuid || { restore_all_pending_backups; return 1; }
      printf 'ipv6|%s|%s\n' "${UUID}" "${NEW_USER}" >> "${CLIENTS_FILE}"
      CREATED_LIST="${CREATED_LIST} VLESS-Vision(IPv6)"
    fi
    chmod 0600 "${CLIENTS_FILE}"
  fi

  if [ "${ADD_XHTTP}" = "1" ]; then
    backup_xhttp_clients_for_change
    generate_uuid || { restore_all_pending_backups; return 1; }
    printf '%s|%s\n' "${UUID}" "${NEW_USER}" >> "${XHTTP_CLIENTS_FILE}"
    chmod 0600 "${XHTTP_CLIENTS_FILE}"
    CREATED_LIST="${CREATED_LIST} VLESS-XHTTP"
  fi

  if [ "${ADD_HY2}" = "1" ]; then
    backup_hy2_clients_for_change
    OLD_HY2_PW="${HY2_PASSWORD:-}"
    generate_hy2_password || { HY2_PASSWORD="${OLD_HY2_PW}"; restore_all_pending_backups; return 1; }
    NEW_HY2_PW="${HY2_PASSWORD}"
    [ -z "${OLD_HY2_PW}" ] || HY2_PASSWORD="${OLD_HY2_PW}"
    printf '%s|%s\n' "${NEW_HY2_PW}" "${NEW_USER}" >> "${HY2_CLIENTS_FILE}"
    chmod 0600 "${HY2_CLIENTS_FILE}"
    CREATED_LIST="${CREATED_LIST} Hysteria2"
  fi

  if apply_config; then
    ok "已为用户 [${NEW_USER}] 创建凭据：${CREATED_LIST}"
    show_user_bundle "${NEW_USER}"
  fi
}

export_user_interactive() {
  load_state
  USERS_LIST="$(list_all_usernames)"
  if [ -z "${USERS_LIST}" ]; then
    echo "（暂无可按用户导出的多协议客户端）"
    return 0
  fi
  echo
  echo "已有用户列表（email 身份）："
  U_NUM=0
  for U_NAME in ${USERS_LIST}; do
    U_NUM=$((U_NUM + 1))
    printf '  %s. %s\n' "${U_NUM}" "${U_NAME}"
  done
  echo "  0. 返回"
  while :; do
    printf '选择要导出的用户编号（0 返回）: '
    read -r INPUT || { MENU_RETURNED="1"; return 0; }
    case "${INPUT}" in
      0|q|Q) MENU_RETURNED="1"; return 0 ;;
      ''|*[!0-9]*) echo "请输入有效编号。" ;;
      *)
        if [ "${INPUT}" -ge 1 ] && [ "${INPUT}" -le "${U_NUM}" ]; then break; fi
        echo "编号超出范围。"
        ;;
    esac
  done
  PICKED_USER="$(printf '%s\n' "${USERS_LIST}" | sed -n "${INPUT}p")"
  show_user_bundle "${PICKED_USER}"
}

export_nodes_menu() {
  while :; do
    load_state
    MENU_RETURNED="0"
    clear 2>/dev/null || true
    echo "=========================================="
    echo " ${CYAN}节点导出与跨协议用户管理${RESET}"
    echo "=========================================="
    echo "  1. 查看纯 URI 链接汇总（一键复制）"
    echo "  2. 导出 Base64 合并订阅串"
    echo "  3. 导出 Clash / Mihomo YAML 节点片段"
    echo "  4. 按用户导出专属链接 / Base64 / Mihomo YAML"
    echo "  5. 一键跨协议新增同名用户（Vision + XHTTP + Hy2）"
    echo "  6. 查看全部协议详细参数"
    echo "  0. 返回主菜单（或输入 q）"
    echo "=========================================="
    printf '请选择操作: '
    read -r CHOICE || return 0
    case "${CHOICE}" in
      '') continue ;;
      1) show_quick_links ;;
      2) export_base64_sub ;;
      3) export_mihomo_yaml ;;
      4) export_user_interactive || true ;;
      5) create_unified_user || true ;;
      6) show_all_nodes ;;
      0|q|Q) return 0 ;;
      *) echo "无效选择。" ;;
    esac
    if [ "${MENU_RETURNED:-0}" = "1" ]; then
      MENU_RETURNED="0"
      continue
    fi
    pause_menu
  done
}

# --- Interactive prompt helpers ---

prompt_port_value() {
  PORT_LABEL="$1"
  CURRENT_PORT="$2"
  ALLOW_ZERO="${3:-0}"
  while :; do
    if [ "${ALLOW_ZERO}" = "1" ]; then
      printf '%s监听端口（输入 0 返回）[%s]: ' "${PORT_LABEL}" "${CURRENT_PORT}"
    else
      printf '%s监听端口 [%s]: ' "${PORT_LABEL}" "${CURRENT_PORT}"
    fi
    read -r INPUT
    if [ "${ALLOW_ZERO}" = "1" ] && [ "${INPUT}" = "0" ]; then
      SELECTED_PORT="0"
      return 1
    fi
    SELECTED_PORT="${INPUT:-${CURRENT_PORT}}"
    case "${SELECTED_PORT}" in
      ''|*[!0-9]*) echo "端口必须是 1 到 65535 之间的数字。"; continue ;;
    esac
    if [ "${SELECTED_PORT}" -ge 1 ] && [ "${SELECTED_PORT}" -le 65535 ]; then
      return 0
    fi
    echo "端口必须在 1 到 65535 之间。"
  done
}

prompt_sni() {
  CURRENT_SNI="${1:-${DEFAULT_SNI}}"
  ALLOW_ZERO="${2:-0}"
  while :; do
    if [ "${ALLOW_ZERO}" = "1" ]; then
      printf 'REALITY SNI（输入 0 返回）[%s]: ' "${CURRENT_SNI}"
    else
      printf 'REALITY SNI [%s]: ' "${CURRENT_SNI}"
    fi
    read -r INPUT
    if [ "${ALLOW_ZERO}" = "1" ] && [ "${INPUT}" = "0" ]; then
      return 1
    fi
    NEXT_SNI="${INPUT:-${CURRENT_SNI}}"
    NEXT_SNI="$(printf '%s' "${NEXT_SNI}" | tr -d '[:space:]')"
    case "${NEXT_SNI}" in
      '') echo "SNI 不能为空。" ;;
      *:*) echo "只输入域名，不要包含端口。" ;;
      */*) echo "只输入域名，不要包含协议或路径。" ;;
      *[!A-Za-z0-9.-]*) echo "SNI 格式无效，只能包含英文、数字、点和短横线。" ;;
      *)
        SNI="${NEXT_SNI}"
        [ "${FALLBACK_MODE:-direct}" = "protected" ] || REALITY_DEST="${SNI}:443"
        return 0
        ;;
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
  LABEL="${2:-节点名称}"
  ALLOW_ZERO="${3:-0}"
  if [ -z "${CURRENT_TAG}" ]; then
    make_default_tag
    CURRENT_TAG="${DEFAULT_TAG}"
  fi
  while :; do
    if [ "${ALLOW_ZERO}" = "1" ]; then
      printf '%s（输入 0 返回）[%s]: ' "${LABEL}" "${CURRENT_TAG}"
    else
      printf '%s [%s]: ' "${LABEL}" "${CURRENT_TAG}"
    fi
    read -r INPUT
    if [ "${ALLOW_ZERO}" = "1" ] && [ "${INPUT}" = "0" ]; then
      return 1
    fi
    TAG="${INPUT:-${CURRENT_TAG}}"
    case "${TAG}" in
      ''|*[!A-Za-z0-9._-]*) echo "${LABEL}只能包含英文、数字、点、下划线和短横线。" ;;
      *) return 0 ;;
    esac
  done
}

prompt_ss_method() {
  CURRENT_METHOD="${1:-${DEFAULT_SS_METHOD}}"
  case "${CURRENT_METHOD}" in
    2022-blake3-aes-128-gcm) DEF_CHOICE=1 ;;
    2022-blake3-aes-256-gcm) DEF_CHOICE=2 ;;
    aes-256-gcm) DEF_CHOICE=3 ;;
    chacha20-ietf-poly1305) DEF_CHOICE=4 ;;
    *) DEF_CHOICE=1 ;;
  esac
  while :; do
    echo "Shadowsocks 加密方式："
    echo "  1. 2022-blake3-aes-128-gcm（推荐，SS-2022 高性能）"
    echo "  2. 2022-blake3-aes-256-gcm（SS-2022 256 位）"
    echo "  3. aes-256-gcm（经典 AEAD，兼容性更好）"
    echo "  4. chacha20-ietf-poly1305（无 AES-NI 的 ARM/低配推荐）"
    printf '请选择 [%s]: ' "${DEF_CHOICE}"
    read -r INPUT
    case "${INPUT:-${DEF_CHOICE}}" in
      1) SS_METHOD="2022-blake3-aes-128-gcm"; return 0 ;;
      2) SS_METHOD="2022-blake3-aes-256-gcm"; return 0 ;;
      3) SS_METHOD="aes-256-gcm"; return 0 ;;
      4) SS_METHOD="chacha20-ietf-poly1305"; return 0 ;;
      *) echo "无效选择，请输入 1 到 4。" ;;
    esac
  done
}

prompt_ss_network() {
  CURRENT_NET="${1:-${DEFAULT_SS_NETWORK}}"
  case "${CURRENT_NET}" in
    tcp,udp) DEF_CHOICE=2 ;;
    *) DEF_CHOICE=1 ;;
  esac
  while :; do
    echo "Shadowsocks 传输网络："
    echo "  1. 仅 TCP（低开销默认）"
    echo "  2. TCP + UDP"
    printf '请选择 [%s]: ' "${DEF_CHOICE}"
    read -r INPUT
    case "${INPUT:-${DEF_CHOICE}}" in
      1) SS_NETWORK="tcp"; return 0 ;;
      2) SS_NETWORK="tcp,udp"; return 0 ;;
      *) echo "无效选择，请输入 1 或 2。" ;;
    esac
  done
}

prompt_ss_family() {
  CURRENT_FAM="${1:-ipv4}"
  case "${CURRENT_FAM}" in ipv6) DEF_CHOICE=2 ;; *) DEF_CHOICE=1 ;; esac
  while :; do
    echo "Shadowsocks 入站地址族："
    echo "  1. IPv4：$(ipv4_display)（监听 0.0.0.0）"
    echo "  2. IPv6：$(ipv6_display)（监听 ::）"
    printf '请选择 [%s]: ' "${DEF_CHOICE}"
    read -r INPUT
    case "${INPUT:-${DEF_CHOICE}}" in
      1)
        [ -n "${SERVER_IPV4}" ] || warn "当前检测不到公网 IPv4，链接将使用占位地址。"
        SS_FAMILY="ipv4"
        SS_BIND="0.0.0.0"
        SS_SERVER_HOST="${SERVER_IPV4:-}"
        return 0
        ;;
      2)
        [ -n "${SERVER_IPV6}" ] || warn "当前检测不到公网 IPv6，链接将使用占位地址。"
        SS_FAMILY="ipv6"
        SS_BIND="::"
        SS_SERVER_HOST="${SERVER_IPV6:-}"
        return 0
        ;;
      *) echo "无效选择，请输入 1 或 2。" ;;
    esac
  done
}

prompt_vless_family() {
  while :; do
    echo "VLESS + REALITY 入站地址族："
    echo "  1. IPv4：$(ipv4_display)（监听 0.0.0.0）"
    echo "  2. IPv6：$(ipv6_display)（监听 ::）"
    printf '请选择 [1]: '
    read -r INPUT
    case "${INPUT:-1}" in
      1)
        if [ -z "${SERVER_IPV4}" ]; then
          warn "当前检测不到公网 IPv4；IPv4 客户端链接可能无法直接连接。"
          printf '仍要继续吗？[y/N]: '
          read -r ANSWER
          case "${ANSWER}" in y|Y|yes|YES) ;; *) continue ;; esac
        fi
        SELECTED_VLESS_FAMILY="ipv4"
        return 0
        ;;
      2)
        if [ -z "${SERVER_IPV6}" ]; then
          warn "当前检测不到公网 IPv6；IPv6 客户端链接可能无法直接连接。"
          printf '仍要继续吗？[y/N]: '
          read -r ANSWER
          case "${ANSWER}" in y|Y|yes|YES) ;; *) continue ;; esac
        fi
        SELECTED_VLESS_FAMILY="ipv6"
        return 0
        ;;
      *) echo "无效选择，请输入 1 或 2。" ;;
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

prompt_limit_int() {
  LIM_LABEL="$1"
  LIM_DEFAULT="$2"
  while :; do
    printf '%s [%s]: ' "${LIM_LABEL}" "${LIM_DEFAULT}"
    read -r INPUT
    LIM_VALUE="${INPUT:-${LIM_DEFAULT}}"
    case "${LIM_VALUE}" in
      ''|*[!0-9]*) echo "请输入非负整数。" ;;
      *) return 0 ;;
    esac
  done
}

prompt_fallback_limit() {
  while :; do
    case "${FALLBACK_LIMIT_MODE:-disabled}" in
      disabled) LIM_DEF=1 ;;
      recommended) LIM_DEF=2 ;;
      *) LIM_DEF=3 ;;
    esac
    echo
    echo "回落限速（仅高级保护模式）："
    echo "  1. 关闭"
    echo "  2. 推荐：前 1 MiB 不限速，上传 64 KiB/s，下载 128 KiB/s"
    echo "  3. 自定义（单位：字节）"
    printf '选择限速模式 [%s]: ' "${LIM_DEF}"
    read -r INPUT
    case "${INPUT:-${LIM_DEF}}" in
      1) clear_fallback_limit; return 0 ;;
      2) set_recommended_fallback_limit; return 0 ;;
      3)
        FALLBACK_LIMIT_MODE="custom"
        prompt_limit_int "限速起始字节数" "${FALLBACK_LIMIT_AFTER_BYTES:-${DEFAULT_LIMIT_AFTER_BYTES}}"
        FALLBACK_LIMIT_AFTER_BYTES="${LIM_VALUE}"
        prompt_limit_int "上传 bytesPerSec" "${FALLBACK_LIMIT_UPLOAD_BPS:-${DEFAULT_LIMIT_UPLOAD_BPS}}"
        FALLBACK_LIMIT_UPLOAD_BPS="${LIM_VALUE}"
        prompt_limit_int "上传 burstBytesPerSec" "${FALLBACK_LIMIT_UPLOAD_BURST:-${DEFAULT_LIMIT_UPLOAD_BURST}}"
        FALLBACK_LIMIT_UPLOAD_BURST="${LIM_VALUE}"
        prompt_limit_int "下载 bytesPerSec" "${FALLBACK_LIMIT_DOWNLOAD_BPS:-${DEFAULT_LIMIT_DOWNLOAD_BPS}}"
        FALLBACK_LIMIT_DOWNLOAD_BPS="${LIM_VALUE}"
        prompt_limit_int "下载 burstBytesPerSec" "${FALLBACK_LIMIT_DOWNLOAD_BURST:-${DEFAULT_LIMIT_DOWNLOAD_BURST}}"
        FALLBACK_LIMIT_DOWNLOAD_BURST="${LIM_VALUE}"
        if [ "${FALLBACK_LIMIT_UPLOAD_BPS}" -le 0 ] || [ "${FALLBACK_LIMIT_DOWNLOAD_BPS}" -le 0 ]; then
          echo "上传与下载 bytesPerSec 必须大于 0，请重新设置。"
          continue
        fi
        if [ "${FALLBACK_LIMIT_UPLOAD_BURST}" -lt "${FALLBACK_LIMIT_UPLOAD_BPS}" ] || [ "${FALLBACK_LIMIT_DOWNLOAD_BURST}" -lt "${FALLBACK_LIMIT_DOWNLOAD_BPS}" ]; then
          echo "burstBytesPerSec 不能小于对应的 bytesPerSec，请重新设置。"
          continue
        fi
        return 0
        ;;
      *) echo "无效选择，请输入 1 到 3。" ;;
    esac
  done
}

prompt_fallback_settings() {
  ALLOW_BACK="${1:-0}"
  case "${FALLBACK_MODE:-direct}" in protected) FB_DEF=2 ;; *) FB_DEF=1 ;; esac
  while :; do
    echo
    echo "REALITY 回落模式："
    echo "  1. 普通：无效连接直接回落到 ${SNI}:443"
    echo "  2. 高级保护：经本机 Tunnel 仅允许 ${SNI}，其他 SNI 直接丢弃（支持限速）"
    [ "${ALLOW_BACK}" != "1" ] || echo "  0. 返回"
    printf '选择回落模式 [%s]: ' "${FB_DEF}"
    read -r INPUT
    if [ "${ALLOW_BACK}" = "1" ] && [ "${INPUT}" = "0" ]; then
      return 1
    fi
    case "${INPUT:-${FB_DEF}}" in
      1)
        FALLBACK_MODE="direct"
        FALLBACK_PORT=""
        REALITY_DEST="${SNI}:443"
        clear_fallback_limit
        return 0
        ;;
      2)
        OLD_FB_PORT="${FALLBACK_PORT:-}"
        while :; do
          prompt_port_value "本机回落 Tunnel " "${FALLBACK_PORT:-${DEFAULT_FALLBACK_PORT}}" "${ALLOW_BACK}" || return 1
          CAND_FB="${SELECTED_PORT}"
          if port_conflicts_with_configured "${CAND_FB}" "fallback"; then
            continue
          fi
          if ! check_port_available "${CAND_FB}" "${OLD_FB_PORT}"; then
            echo "端口 ${CAND_FB} 已被占用，请换一个端口。"
            continue
          fi
          FALLBACK_MODE="protected"
          FALLBACK_PORT="${CAND_FB}"
          REALITY_DEST="127.0.0.1:${FALLBACK_PORT}"
          break
        done
        prompt_fallback_limit
        return 0
        ;;
      *) echo "无效选择，请输入 1 或 2。" ;;
    esac
  done
}

choose_outbound_mode() {
  DEFAULT_MODE="${1:-${DEFAULT_BASE_OUTBOUND_MODE}}"
  ALLOW_BACK="${2:-0}"
  ALLOW_BLOCK="${3:-0}"
  ensure_outbounds_file

  while :; do
    OPT_MAP=""
    OPT_IDX=0
    DEFAULT_CHOICE=1

    for BUILTIN in ipv4 ipv6 ipv4v6 ipv6v4 happy4v6 happy6v4; do
      OPT_IDX=$((OPT_IDX + 1))
      OPT_MAP="${OPT_MAP}${OPT_IDX}|${BUILTIN}
"
      [ "${DEFAULT_MODE}" != "${BUILTIN}" ] || DEFAULT_CHOICE="${OPT_IDX}"
      case "${BUILTIN}" in
        ipv4) echo "  ${OPT_IDX}. 仅 IPv4" ;;
        ipv6) echo "  ${OPT_IDX}. 仅 IPv6" ;;
        ipv4v6) echo "  ${OPT_IDX}. IPv4 优先，IPv6 兜底" ;;
        ipv6v4) echo "  ${OPT_IDX}. IPv6 优先，IPv4 兜底" ;;
        happy4v6) echo "  ${OPT_IDX}. IPv4 优先连接竞速（Happy Eyeballs）" ;;
        happy6v4) echo "  ${OPT_IDX}. IPv6 优先连接竞速（Happy Eyeballs）" ;;
      esac
    done

    if [ "${ALLOW_BLOCK}" = "1" ]; then
      OPT_IDX=$((OPT_IDX + 1))
      OPT_MAP="${OPT_MAP}${OPT_IDX}|block
"
      [ "${DEFAULT_MODE}" != "block" ] || DEFAULT_CHOICE="${OPT_IDX}"
      echo "  ${OPT_IDX}. 屏蔽 / 丢弃 (block)"
    fi

    while IFS='|' read -r OB_TAG OB_PROTO OB_ADDR OB_PORT OB_F5 OB_F6; do
      [ -n "${OB_TAG}" ] && [ -n "${OB_PROTO}" ] || continue
      OPT_IDX=$((OPT_IDX + 1))
      OPT_MAP="${OPT_MAP}${OPT_IDX}|${OB_TAG}
"
      [ "${DEFAULT_MODE}" != "${OB_TAG}" ] || DEFAULT_CHOICE="${OPT_IDX}"
      echo "  ${OPT_IDX}. 落地代理 (${OB_TAG}) [${OB_PROTO} ${OB_ADDR}:${OB_PORT}]"
    done < "${OUTBOUNDS_FILE}"

    [ "${ALLOW_BACK}" != "1" ] || echo "  0. 返回"
    printf '请选择 [%s]: ' "${DEFAULT_CHOICE}"
    read -r INPUT
    if [ "${ALLOW_BACK}" = "1" ] && [ "${INPUT}" = "0" ]; then
      return 1
    fi
    PICK="${INPUT:-${DEFAULT_CHOICE}}"
    case "${PICK}" in
      ''|*[!0-9]*) echo "无效选择，请输入 1 到 ${OPT_IDX}。"; continue ;;
    esac
    PICKED_MODE="$(printf '%s' "${OPT_MAP}" | awk -F '|' -v idx="${PICK}" '$1 == idx {print $2; exit}')"
    if [ -n "${PICKED_MODE}" ]; then
      SELECTED_OUTBOUND_MODE="${PICKED_MODE}"
      return 0
    fi
    echo "无效选择，请输入 1 到 ${OPT_IDX}。"
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
    block)
      return 0
      ;;
    *)
      if custom_outbound_exists "${MODE}" 2>/dev/null; then
        return 0
      fi
      ;;
  esac
  printf '仍要继续吗？[y/N]: '
  read -r ANSWER
  case "${ANSWER}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# --- VLESS + REALITY management ---

enable_vless_protocol() {
  load_state
  if vless_is_configured; then
    echo "VLESS + Vision + REALITY 已启用。"
    return 0
  fi
  echo
  info "初始化 VLESS + Vision + REALITY 入站..."
  detect_network
  if ! reality_keys_ready; then
    prompt_sni "${DEFAULT_SNI}" 1 || return 1
  fi
  prompt_vless_family
  case "${SELECTED_VLESS_FAMILY}" in
    ipv4) DEF_VP="${DEFAULT_IPV4_PORT}"; ROLE="vless4" ;;
    ipv6) DEF_VP="${DEFAULT_IPV6_PORT}"; ROLE="vless6" ;;
  esac
  while :; do
    prompt_port_value "VLESS-Vision (${SELECTED_VLESS_FAMILY}) " "${DEF_VP}" 1 || return 1
    if port_conflicts_with_configured "${SELECTED_PORT}" "${ROLE}" "tcp"; then
      continue
    fi
    if ! check_port_available "${SELECTED_PORT}" "" "tcp"; then
      echo "TCP 端口 ${SELECTED_PORT} 已被占用，请换一个端口。"
      continue
    fi
    break
  done
  case "${SELECTED_VLESS_FAMILY}" in
    ipv4) IPV4_PORT="${SELECTED_PORT}" ;;
    ipv6) IPV6_PORT="${SELECTED_PORT}" ;;
  esac
  if ! reality_keys_ready; then
    prompt_fallback_settings 1 || return 1
    generate_reality_values || return 1
  fi
  prompt_tag "" "初始客户端名称" 1 || return 1
  CLIENT_NAME="${TAG}"
  generate_uuid || return 1
  backup_clients_for_change
  printf '%s|%s|%s\n' "${SELECTED_VLESS_FAMILY}" "${UUID}" "${CLIENT_NAME}" >> "${CLIENTS_FILE}"
  chmod 0600 "${CLIENTS_FILE}"
  if apply_config; then
    show_vless_clients
  fi
}

add_vless_client() {
  load_state
  if ! vless_is_configured; then
    enable_vless_protocol
    return
  fi
  while :; do
    echo
    echo "选择新客户端所属入站："
    echo "  1. IPv4 入站$( [ -n "${IPV4_PORT}" ] && printf '（端口 %s，%s 个客户端）' "${IPV4_PORT}" "$(client_count ipv4)" || printf '（未开启）' )"
    echo "  2. IPv6 入站$( [ -n "${IPV6_PORT}" ] && printf '（端口 %s，%s 个客户端）' "${IPV6_PORT}" "$(client_count ipv6)" || printf '（未开启）' )"
    echo "  0. 返回"
    printf '请选择: '
    read -r INPUT
    case "${INPUT}" in
      1) CLIENT_FAMILY="ipv4"; break ;;
      2) CLIENT_FAMILY="ipv6"; break ;;
      0) MENU_RETURNED="1"; return 0 ;;
      *) echo "无效选择。" ;;
    esac
  done

  if [ "${CLIENT_FAMILY}" = "ipv4" ] && { [ -z "${IPV4_PORT}" ] || port_conflicts_with_configured "${IPV4_PORT}" "vless4" >/dev/null 2>&1; }; then
    while :; do
      prompt_port_value "VLESS IPv4 " "${DEFAULT_IPV4_PORT}" 1 || { MENU_RETURNED="1"; return 0; }
      port_conflicts_with_configured "${SELECTED_PORT}" "vless4" && continue
      check_port_available "${SELECTED_PORT}" "" || { echo "端口 ${SELECTED_PORT} 已被占用。"; continue; }
      IPV4_PORT="${SELECTED_PORT}"
      break
    done
  elif [ "${CLIENT_FAMILY}" = "ipv6" ] && { [ -z "${IPV6_PORT}" ] || port_conflicts_with_configured "${IPV6_PORT}" "vless6" >/dev/null 2>&1; }; then
    while :; do
      prompt_port_value "VLESS IPv6 " "${DEFAULT_IPV6_PORT}" 1 || { MENU_RETURNED="1"; return 0; }
      port_conflicts_with_configured "${SELECTED_PORT}" "vless6" && continue
      check_port_available "${SELECTED_PORT}" "" || { echo "端口 ${SELECTED_PORT} 已被占用。"; continue; }
      IPV6_PORT="${SELECTED_PORT}"
      break
    done
  fi

  while :; do
    prompt_tag "" "客户端名称" 1 || { MENU_RETURNED="1"; return 0; }
    CLIENT_NAME="${TAG}"
    if client_name_exists "${CLIENT_FAMILY}" "${CLIENT_NAME}"; then
      echo "${CLIENT_FAMILY} 入站中已存在同名客户端，请换一个名称。"
      continue
    fi
    break
  done
  generate_uuid || return 1
  backup_clients_for_change
  printf '%s|%s|%s\n' "${CLIENT_FAMILY}" "${UUID}" "${CLIENT_NAME}" >> "${CLIENTS_FILE}"
  chmod 0600 "${CLIENTS_FILE}"
  if apply_config; then
    make_uri "${CLIENT_FAMILY}" "${UUID}" "${CLIENT_NAME}"
    ok "客户端已添加："
    echo "${URI}"
  fi
}

rename_vless_client() {
  load_state
  echo
  echo "编号  入站   客户端名称"
  NUMBER=0
  while IFS='|' read -r CLIENT_FAMILY CLIENT_UUID CLIENT_NAME; do
    [ -n "${CLIENT_UUID}" ] || continue
    NUMBER=$((NUMBER + 1))
    printf '%-4s  %-6s %s\n' "${NUMBER}" "${CLIENT_FAMILY}" "${CLIENT_NAME}"
  done < "${CLIENTS_FILE}"
  [ "${NUMBER}" -gt 0 ] || { echo "（暂无 VLESS 客户端）"; return 0; }
  while :; do
    printf '输入要重命名的客户端编号（0 取消）: '
    read -r INPUT
    case "${INPUT}" in
      0) MENU_RETURNED="1"; return 0 ;;
      ''|*[!0-9]*) echo "请输入有效编号。" ;;
      *) [ "${INPUT}" -ge 1 ] && [ "${INPUT}" -le "${NUMBER}" ] && break; echo "编号超出范围。" ;;
    esac
  done
  TARGET_IDX="${INPUT}"
  TARGET_LINE="$(awk -F '|' -v target="${TARGET_IDX}" 'NF && $2 != "" {count++; if (count == target) {print; exit}}' "${CLIENTS_FILE}")"
  TARGET_FAMILY="$(printf '%s' "${TARGET_LINE}" | cut -d'|' -f1)"
  OLD_NAME="$(printf '%s' "${TARGET_LINE}" | cut -d'|' -f3)"
  while :; do
    prompt_tag "${OLD_NAME}" "新客户端名称" 1 || { MENU_RETURNED="1"; return 0; }
    NEW_NAME="${TAG}"
    if [ "${NEW_NAME}" = "${OLD_NAME}" ]; then
      echo "名称未改变。"
      return 0
    fi
    if client_name_exists "${TARGET_FAMILY}" "${NEW_NAME}"; then
      echo "${TARGET_FAMILY} 入站中已存在同名客户端。"
      continue
    fi
    break
  done
  backup_clients_for_change
  TEMP_CLIENTS="$(mktemp /tmp/vvr-clients-new.XXXXXX)"
  awk -F '|' -v OFS='|' -v target="${TARGET_IDX}" -v newname="${NEW_NAME}" \
    'NF && $2 != "" {count++; if (count == target) $3 = newname} {print}' "${CLIENTS_FILE}" > "${TEMP_CLIENTS}"
  mv "${TEMP_CLIENTS}" "${CLIENTS_FILE}"
  chmod 0600 "${CLIENTS_FILE}"
  if apply_config; then
    ok "客户端已重命名为 ${NEW_NAME}（已同步更新 Xray 用户 email 标识）。"
  fi
}

delete_vless_client() {
  load_state
  echo
  echo "编号  入站   客户端名称"
  NUMBER=0
  while IFS='|' read -r CLIENT_FAMILY CLIENT_UUID CLIENT_NAME; do
    [ -n "${CLIENT_UUID}" ] || continue
    NUMBER=$((NUMBER + 1))
    printf '%-4s  %-6s %s\n' "${NUMBER}" "${CLIENT_FAMILY}" "${CLIENT_NAME}"
  done < "${CLIENTS_FILE}"
  [ "${NUMBER}" -gt 0 ] || { echo "（暂无 VLESS 客户端）"; return 0; }
  if [ "${NUMBER}" -le 1 ] && ! other_protocols_active_excluding "vless"; then
    warn "当前没有其他启用的入站协议，不能删除最后一个 VLESS 客户端。"
    return 0
  fi
  while :; do
    printf '输入要删除的客户端编号（0 取消）: '
    read -r INPUT
    case "${INPUT}" in
      0) MENU_RETURNED="1"; return 0 ;;
      ''|*[!0-9]*) echo "请输入有效编号。" ;;
      *) [ "${INPUT}" -ge 1 ] && [ "${INPUT}" -le "${NUMBER}" ] && break; echo "编号超出范围。" ;;
    esac
  done
  backup_clients_for_change
  TEMP_CLIENTS="$(mktemp /tmp/vvr-clients-new.XXXXXX)"
  awk -F '|' -v target="${INPUT}" 'NF && $2 != "" {count++} count != target {print}' "${CLIENTS_FILE}" > "${TEMP_CLIENTS}"
  mv "${TEMP_CLIENTS}" "${CLIENTS_FILE}"
  chmod 0600 "${CLIENTS_FILE}"
  apply_config || true
}

modify_vless_ports() {
  load_state
  vless_is_configured || { echo "VLESS + REALITY 尚未启用。"; return 0; }
  while :; do
    echo
    echo "  1. 修改 IPv4 入站端口$( [ "$(client_count ipv4)" -gt 0 ] && printf '（当前 %s）' "${IPV4_PORT}" || printf '（无客户端）' )"
    echo "  2. 修改 IPv6 入站端口$( [ "$(client_count ipv6)" -gt 0 ] && printf '（当前 %s）' "${IPV6_PORT}" || printf '（无客户端）' )"
    echo "  0. 返回"
    printf '请选择: '
    read -r INPUT
    case "${INPUT}" in
      1) PORT_FAMILY="ipv4"; CURRENT_PORT="${IPV4_PORT:-${DEFAULT_IPV4_PORT}}"; ROLE="vless4" ;;
      2) PORT_FAMILY="ipv6"; CURRENT_PORT="${IPV6_PORT:-${DEFAULT_IPV6_PORT}}"; ROLE="vless6" ;;
      0) MENU_RETURNED="1"; return 0 ;;
      *) echo "无效选择。"; continue ;;
    esac
    [ "$(client_count "${PORT_FAMILY}")" -gt 0 ] || { echo "该地址族暂无客户端，请先添加客户端。"; continue; }
    OLD_PORT="${CURRENT_PORT}"
    while :; do
      prompt_port_value "VLESS ${PORT_FAMILY} " "${CURRENT_PORT}" 1 || { MENU_RETURNED="1"; return 0; }
      NEW_PORT="${SELECTED_PORT}"
      port_conflicts_with_configured "${NEW_PORT}" "${ROLE}" && continue
      check_port_available "${NEW_PORT}" "${OLD_PORT}" || { echo "端口 ${NEW_PORT} 已被占用，请重新输入。"; continue; }
      break
    done
    case "${PORT_FAMILY}" in ipv4) IPV4_PORT="${NEW_PORT}" ;; ipv6) IPV6_PORT="${NEW_PORT}" ;; esac
    apply_config && show_vless_clients || true
    return 0
  done
}

modify_vless_sni() {
  load_state
  reality_keys_ready || { echo "REALITY 尚未启用。"; return 0; }
  prompt_sni "${SNI}" 1 || { MENU_RETURNED="1"; return 0; }
  apply_config && show_all_nodes || true
}

modify_vless_fallback() {
  load_state
  reality_keys_ready || { echo "REALITY 尚未启用。"; return 0; }
  prompt_fallback_settings 1 || { MENU_RETURNED="1"; return 0; }
  apply_config && show_vless_clients || true
}

regenerate_reality_keys() {
  load_state
  reality_keys_ready || { echo "REALITY 尚未启用。"; return 0; }
  warn "将重新生成 REALITY 密钥和 shortId，所有现有 VLESS-Vision 与 VLESS-XHTTP 链接都将失效。"
  printf '确认重置 REALITY 参数？[y/N]: '
  read -r ANSWER
  case "${ANSWER}" in y|Y|yes|YES) ;; *) MENU_RETURNED="1"; return 0 ;; esac
  generate_reality_values || return 1
  apply_config && show_all_nodes || true
}

manage_vless_menu() {
  while :; do
    load_state
    MENU_RETURNED="0"
    clear 2>/dev/null || true
    echo "=========================================="
    echo " ${CYAN}VLESS + Vision + REALITY 管理${RESET}"
    echo "=========================================="
    if vless_is_configured; then
      echo " IPv4：$( [ "$(client_count ipv4)" -gt 0 ] && printf '端口 %s（%s 个客户端）' "${IPV4_PORT}" "$(client_count ipv4)" || printf '未开启' )"
      echo " IPv6：$( [ "$(client_count ipv6)" -gt 0 ] && printf '端口 %s（%s 个客户端）' "${IPV6_PORT}" "$(client_count ipv6)" || printf '未开启' )"
      echo " SNI ：${SNI} | 回落：${FALLBACK_MODE}"
      echo "------------------------------------------"
      echo "  1. 查看全部 VLESS 客户端链接"
      echo "  2. 添加客户端（IPv4 / IPv6）"
      echo "  3. 重命名客户端"
      echo "  4. 删除客户端"
      echo "  5. 修改 IPv4 / IPv6 监听端口"
      echo "  6. 修改 REALITY SNI"
      echo "  7. 配置 REALITY 回落保护与限速"
      echo "  8. 重置 REALITY 密钥与 shortId"
    else
      echo " 状态：${DIM}○ 未启用${RESET}"
      echo "------------------------------------------"
      echo "  1. 创建并启用 VLESS + REALITY 入站"
    fi
    echo "  0. 返回主菜单（或输入 q）"
    echo "=========================================="
    printf '请选择操作: '
    read -r CHOICE || return 0
    [ -n "${CHOICE}" ] || continue
    if ! vless_is_configured; then
      case "${CHOICE}" in
        1) enable_vless_protocol || true ;;
        0|q|Q) return 0 ;;
        *) echo "无效选择。" ;;
      esac
    else
      case "${CHOICE}" in
        1) show_vless_clients ;;
        2) add_vless_client || true ;;
        3) rename_vless_client || true ;;
        4) delete_vless_client || true ;;
        5) modify_vless_ports || true ;;
        6) modify_vless_sni || true ;;
        7) modify_vless_fallback || true ;;
        8) regenerate_reality_keys || true ;;
        0|q|Q) return 0 ;;
        *) echo "无效选择。" ;;
      esac
    fi
    if [ "${MENU_RETURNED:-0}" = "1" ]; then
      MENU_RETURNED="0"
      continue
    fi
    pause_menu
  done
}

# --- VLESS + XHTTP + REALITY management ---

prompt_xhttp_family() {
  CURRENT_FAM="${1:-ipv4}"
  case "${CURRENT_FAM}" in ipv6) DEF_CHOICE=2 ;; *) DEF_CHOICE=1 ;; esac
  while :; do
    echo "VLESS + XHTTP 入站地址族："
    echo "  1. IPv4：$(ipv4_display)（监听 0.0.0.0）"
    echo "  2. IPv6：$(ipv6_display)（监听 ::）"
    printf '请选择 [%s]: ' "${DEF_CHOICE}"
    read -r INPUT
    case "${INPUT:-${DEF_CHOICE}}" in
      1)
        [ -n "${SERVER_IPV4}" ] || warn "当前检测不到公网 IPv4，链接将使用占位地址。"
        XHTTP_FAMILY="ipv4"
        XHTTP_BIND="0.0.0.0"
        XHTTP_SERVER_HOST="${SERVER_IPV4:-}"
        return 0
        ;;
      2)
        [ -n "${SERVER_IPV6}" ] || warn "当前检测不到公网 IPv6，链接将使用占位地址。"
        XHTTP_FAMILY="ipv6"
        XHTTP_BIND="::"
        XHTTP_SERVER_HOST="${SERVER_IPV6:-}"
        return 0
        ;;
      *) echo "无效选择，请输入 1 或 2。" ;;
    esac
  done
}

prompt_xhttp_mode() {
  CURRENT_XM="${1:-${DEFAULT_XHTTP_MODE}}"
  case "${CURRENT_XM}" in
    auto) DEF_CHOICE=1 ;;
    stream-one) DEF_CHOICE=2 ;;
    packet-up) DEF_CHOICE=3 ;;
    stream-up) DEF_CHOICE=4 ;;
    *) DEF_CHOICE=1 ;;
  esac
  while :; do
    echo "XHTTP 传输模式："
    echo "  1. auto（推荐，自动协商）"
    echo "  2. stream-one（单连接双向流，直连 REALITY 推荐）"
    echo "  3. packet-up（分包上行，适配严格 HTTP 代理/CDN）"
    echo "  4. stream-up（流式上行，上下行分离）"
    printf '请选择 [%s]: ' "${DEF_CHOICE}"
    read -r INPUT
    case "${INPUT:-${DEF_CHOICE}}" in
      1) XHTTP_MODE="auto"; return 0 ;;
      2) XHTTP_MODE="stream-one"; return 0 ;;
      3) XHTTP_MODE="packet-up"; return 0 ;;
      4) XHTTP_MODE="stream-up"; return 0 ;;
      *) echo "无效选择，请输入 1 到 4。" ;;
    esac
  done
}

prompt_xhttp_path() {
  CURRENT_XP="${1:-}"
  ALLOW_ZERO="${2:-0}"
  if [ -z "${CURRENT_XP}" ]; then
    generate_xhttp_path
    CURRENT_XP="${XHTTP_PATH}"
  fi
  while :; do
    if [ "${ALLOW_ZERO}" = "1" ]; then
      printf 'XHTTP 路径（以 / 开头，输入 0 返回）[%s]: ' "${CURRENT_XP}"
    else
      printf 'XHTTP 路径（以 / 开头）[%s]: ' "${CURRENT_XP}"
    fi
    read -r INPUT
    if [ "${ALLOW_ZERO}" = "1" ] && [ "${INPUT}" = "0" ]; then
      return 1
    fi
    NEXT_XP="${INPUT:-${CURRENT_XP}}"
    case "${NEXT_XP}" in
      /*) ;;
      *) NEXT_XP="/${NEXT_XP}" ;;
    esac
    case "${NEXT_XP}" in
      *[!A-Za-z0-9._/-]*) echo "路径只能包含英文、数字、点、下划线、短横线和斜杠。" ;;
      *) XHTTP_PATH="${NEXT_XP}"; return 0 ;;
    esac
  done
}

create_xhttp_inbound() {
  load_state
  if xhttp_is_configured; then
    echo "VLESS + XHTTP + REALITY 已启用：${XHTTP_BIND}:${XHTTP_PORT}"
    return 0
  fi
  detect_network
  if ! reality_keys_ready; then
    prompt_sni "${DEFAULT_SNI}" 1 || { MENU_RETURNED="1"; return 0; }
    prompt_fallback_settings 1 || { MENU_RETURNED="1"; return 0; }
    generate_reality_values || return 1
  fi
  prompt_xhttp_family "ipv4"
  while :; do
    prompt_port_value "VLESS-XHTTP " "${DEFAULT_XHTTP_PORT}" 1 || { MENU_RETURNED="1"; return 0; }
    CAND_XP="${SELECTED_PORT}"
    port_conflicts_with_configured "${CAND_XP}" "xhttp" "tcp" && continue
    check_port_available "${CAND_XP}" "" "tcp" || { echo "TCP 端口 ${CAND_XP} 已被占用，请换一个端口。"; continue; }
    XHTTP_PORT="${CAND_XP}"
    break
  done
  prompt_xhttp_path "" 1 || { MENU_RETURNED="1"; return 0; }
  prompt_xhttp_mode "${DEFAULT_XHTTP_MODE}"
  prompt_tag "${DEFAULT_XHTTP_NAME}" "初始 VLESS-XHTTP 客户端名称" 1 || { MENU_RETURNED="1"; return 0; }
  XHTTP_NAME="${TAG}"
  generate_uuid || return 1
  XHTTP_UUID="${UUID}"
  backup_xhttp_clients_for_change
  printf '%s|%s\n' "${XHTTP_UUID}" "${XHTTP_NAME}" > "${XHTTP_CLIENTS_FILE}"
  chmod 0600 "${XHTTP_CLIENTS_FILE}"
  apply_config && show_xhttp_info || true
}

add_xhttp_client() {
  load_state
  if ! xhttp_is_configured; then
    create_xhttp_inbound
    return
  fi
  while :; do
    prompt_tag "" "新 XHTTP 客户端名称" 1 || { MENU_RETURNED="1"; return 0; }
    NEW_XNAME="${TAG}"
    if xhttp_client_name_exists "${NEW_XNAME}"; then
      echo "VLESS-XHTTP 入站中已存在同名客户端。"
      continue
    fi
    break
  done
  generate_uuid || return 1
  backup_xhttp_clients_for_change
  printf '%s|%s\n' "${UUID}" "${NEW_XNAME}" >> "${XHTTP_CLIENTS_FILE}"
  chmod 0600 "${XHTTP_CLIENTS_FILE}"
  apply_config && show_xhttp_info || true
}

rename_xhttp_client() {
  load_state
  ensure_xhttp_clients_file
  echo
  echo "编号  客户端名称"
  NUMBER=0
  while IFS='|' read -r XC_UUID XC_NAME; do
    [ -n "${XC_UUID}" ] || continue
    NUMBER=$((NUMBER + 1))
    printf '%-4s  %s\n' "${NUMBER}" "${XC_NAME}"
  done < "${XHTTP_CLIENTS_FILE}"
  [ "${NUMBER}" -gt 0 ] || { echo "（暂无 VLESS-XHTTP 客户端）"; return 0; }
  while :; do
    printf '输入要重命名的客户端编号（0 取消）: '
    read -r INPUT
    case "${INPUT}" in
      0) MENU_RETURNED="1"; return 0 ;;
      ''|*[!0-9]*) echo "请输入有效编号。" ;;
      *) [ "${INPUT}" -ge 1 ] && [ "${INPUT}" -le "${NUMBER}" ] && break; echo "编号超出范围。" ;;
    esac
  done
  TARGET_IDX="${INPUT}"
  OLD_NAME="$(awk -F '|' -v target="${TARGET_IDX}" 'NF && $1 != "" {count++; if (count == target) {print $2; exit}}' "${XHTTP_CLIENTS_FILE}")"
  while :; do
    prompt_tag "${OLD_NAME}" "新客户端名称" 1 || { MENU_RETURNED="1"; return 0; }
    NEW_NAME="${TAG}"
    if [ "${NEW_NAME}" = "${OLD_NAME}" ]; then
      echo "名称未改变。"
      return 0
    fi
    if xhttp_client_name_exists "${NEW_NAME}"; then
      echo "VLESS-XHTTP 入站中已存在同名客户端。"
      continue
    fi
    break
  done
  backup_xhttp_clients_for_change
  TEMP_XC="$(mktemp /tmp/vvr-xclients-new.XXXXXX)"
  awk -F '|' -v OFS='|' -v target="${TARGET_IDX}" -v newname="${NEW_NAME}" \
    'NF && $1 != "" {count++; if (count == target) $2 = newname} {print}' "${XHTTP_CLIENTS_FILE}" > "${TEMP_XC}"
  mv "${TEMP_XC}" "${XHTTP_CLIENTS_FILE}"
  chmod 0600 "${XHTTP_CLIENTS_FILE}"
  [ "${TARGET_IDX}" != "1" ] || XHTTP_NAME="${NEW_NAME}"
  if apply_config; then
    ok "XHTTP 客户端已重命名为 ${NEW_NAME}（已同步更新 Xray 用户 email 标识）。"
  fi
}

delete_xhttp_client() {
  load_state
  ensure_xhttp_clients_file
  echo
  echo "编号  客户端名称"
  NUMBER=0
  while IFS='|' read -r XC_UUID XC_NAME; do
    [ -n "${XC_UUID}" ] || continue
    NUMBER=$((NUMBER + 1))
    printf '%-4s  %s\n' "${NUMBER}" "${XC_NAME}"
  done < "${XHTTP_CLIENTS_FILE}"
  [ "${NUMBER}" -gt 0 ] || { echo "（暂无 VLESS-XHTTP 客户端）"; return 0; }
  if [ "${NUMBER}" -le 1 ] && ! other_protocols_active_excluding "xhttp"; then
    warn "当前没有其他启用的入站协议，不能删除最后一个 XHTTP 客户端。"
    return 0
  fi
  while :; do
    printf '输入要删除的客户端编号（0 取消）: '
    read -r INPUT
    case "${INPUT}" in
      0) MENU_RETURNED="1"; return 0 ;;
      ''|*[!0-9]*) echo "请输入有效编号。" ;;
      *) [ "${INPUT}" -ge 1 ] && [ "${INPUT}" -le "${NUMBER}" ] && break; echo "编号超出范围。" ;;
    esac
  done
  backup_xhttp_clients_for_change
  TEMP_XC="$(mktemp /tmp/vvr-xclients-new.XXXXXX)"
  awk -F '|' -v target="${INPUT}" 'NF && $1 != "" {count++} count != target {print}' "${XHTTP_CLIENTS_FILE}" > "${TEMP_XC}"
  mv "${TEMP_XC}" "${XHTTP_CLIENTS_FILE}"
  chmod 0600 "${XHTTP_CLIENTS_FILE}"
  FIRST_REM="$(awk -F '|' 'NF && $1 != "" {print; exit}' "${XHTTP_CLIENTS_FILE}")"
  if [ -z "${FIRST_REM}" ]; then
    XHTTP_PORT=""
    XHTTP_UUID=""
    XHTTP_SERVER_HOST=""
    XHTTP_FAMILY=""
    XHTTP_BIND=""
  else
    XHTTP_UUID="$(printf '%s' "${FIRST_REM}" | cut -d'|' -f1)"
    XHTTP_NAME="$(printf '%s' "${FIRST_REM}" | cut -d'|' -f2)"
  fi
  apply_config || true
}

modify_xhttp_port() {
  load_state
  xhttp_is_configured || { echo "VLESS + XHTTP + REALITY 尚未启用。"; return 0; }
  OLD_XP="${XHTTP_PORT}"
  while :; do
    prompt_port_value "VLESS-XHTTP " "${XHTTP_PORT}" 1 || { MENU_RETURNED="1"; return 0; }
    CAND_XP="${SELECTED_PORT}"
    port_conflicts_with_configured "${CAND_XP}" "xhttp" "tcp" && continue
    check_port_available "${CAND_XP}" "${OLD_XP}" "tcp" || { echo "TCP 端口 ${CAND_XP} 已被占用，请重新输入。"; continue; }
    XHTTP_PORT="${CAND_XP}"
    break
  done
  apply_config && show_xhttp_info || true
}

modify_xhttp_family() {
  load_state
  xhttp_is_configured || { echo "VLESS + XHTTP + REALITY 尚未启用。"; return 0; }
  detect_network
  prompt_xhttp_family "${XHTTP_FAMILY}"
  apply_config && show_xhttp_info || true
}

modify_xhttp_path_or_mode() {
  load_state
  xhttp_is_configured || { echo "VLESS + XHTTP + REALITY 尚未启用。"; return 0; }
  echo "  1. 修改路径（当前：${XHTTP_PATH}）"
  echo "  2. 修改传输模式（当前：${XHTTP_MODE}）"
  echo "  0. 返回"
  printf '请选择: '
  read -r INPUT
  case "${INPUT}" in
    1)
      prompt_xhttp_path "${XHTTP_PATH}" 1 || { MENU_RETURNED="1"; return 0; }
      apply_config && show_xhttp_info || true
      ;;
    2)
      prompt_xhttp_mode "${XHTTP_MODE}"
      apply_config && show_xhttp_info || true
      ;;
    0) MENU_RETURNED="1"; return 0 ;;
    *) echo "无效选择。" ;;
  esac
}

remove_xhttp_inbound() {
  load_state
  xhttp_is_configured || { echo "VLESS + XHTTP + REALITY 尚未启用。"; return 0; }
  if ! other_protocols_active_excluding "xhttp"; then
    warn "当前没有其他启用的入站协议，不能删除最后一个协议。"
    return 0
  fi
  printf '确认删除 VLESS + XHTTP + REALITY 入站及其全部客户端？[y/N]: '
  read -r ANSWER
  case "${ANSWER}" in y|Y|yes|YES) ;; *) MENU_RETURNED="1"; return 0 ;; esac
  backup_xhttp_clients_for_change
  : > "${XHTTP_CLIENTS_FILE}"
  chmod 0600 "${XHTTP_CLIENTS_FILE}"
  XHTTP_PORT=""
  XHTTP_UUID=""
  XHTTP_SERVER_HOST=""
  XHTTP_FAMILY=""
  XHTTP_BIND=""
  apply_config || true
}

manage_xhttp_menu() {
  while :; do
    load_state
    MENU_RETURNED="0"
    clear 2>/dev/null || true
    echo "=========================================="
    echo " ${CYAN}VLESS + XHTTP + REALITY 管理${RESET}"
    echo "=========================================="
    if xhttp_is_configured; then
      echo " 当前：${XHTTP_BIND}:${XHTTP_PORT} | path=${XHTTP_PATH} | mode=${XHTTP_MODE}（$(xhttp_client_count) 个客户端）"
      echo " SNI ：${SNI}（与 Vision 共用 REALITY 密钥）"
      echo "------------------------------------------"
      echo "  1. 查看全部 VLESS-XHTTP 客户端链接"
      echo "  2. 添加 XHTTP 客户端"
      echo "  3. 重命名客户端"
      echo "  4. 删除客户端"
      echo "  5. 修改监听端口"
      echo "  6. 切换入站地址族（IPv4 / IPv6）"
      echo "  7. 修改路径 / 传输模式"
      echo "  8. 修改共用 REALITY SNI"
      echo "  9. 删除 VLESS-XHTTP 入站"
    else
      echo " 状态：${DIM}○ 未启用${RESET}"
      echo "------------------------------------------"
      echo "  1. 创建并启用 VLESS + XHTTP + REALITY 入站"
    fi
    echo "  0. 返回主菜单（或输入 q）"
    echo "=========================================="
    printf '请选择操作: '
    read -r CHOICE || return 0
    [ -n "${CHOICE}" ] || continue
    if ! xhttp_is_configured; then
      case "${CHOICE}" in
        1) create_xhttp_inbound || true ;;
        0|q|Q) return 0 ;;
        *) echo "无效选择。" ;;
      esac
    else
      case "${CHOICE}" in
        1) show_xhttp_info ;;
        2) add_xhttp_client || true ;;
        3) rename_xhttp_client || true ;;
        4) delete_xhttp_client || true ;;
        5) modify_xhttp_port || true ;;
        6) modify_xhttp_family || true ;;
        7) modify_xhttp_path_or_mode || true ;;
        8) modify_vless_sni || true ;;
        9) remove_xhttp_inbound || true ;;
        0|q|Q) return 0 ;;
        *) echo "无效选择。" ;;
      esac
    fi
    if [ "${MENU_RETURNED:-0}" = "1" ]; then
      MENU_RETURNED="0"
      continue
    fi
    pause_menu
  done
}

# --- Hysteria 2 (native Xray inbound) management ---

prompt_hy2_family() {
  CURRENT_FAM="${1:-ipv4}"
  case "${CURRENT_FAM}" in ipv6) DEF_CHOICE=2 ;; *) DEF_CHOICE=1 ;; esac
  while :; do
    echo "Hysteria 2 入站地址族："
    echo "  1. IPv4：$(ipv4_display)（监听 UDP 0.0.0.0）"
    echo "  2. IPv6：$(ipv6_display)（监听 UDP ::）"
    printf '请选择 [%s]: ' "${DEF_CHOICE}"
    read -r INPUT
    case "${INPUT:-${DEF_CHOICE}}" in
      1)
        [ -n "${SERVER_IPV4}" ] || warn "当前检测不到公网 IPv4，链接将使用占位地址。"
        HY2_FAMILY="ipv4"
        HY2_BIND="0.0.0.0"
        HY2_SERVER_HOST="${SERVER_IPV4:-}"
        return 0
        ;;
      2)
        [ -n "${SERVER_IPV6}" ] || warn "当前检测不到公网 IPv6，链接将使用占位地址。"
        HY2_FAMILY="ipv6"
        HY2_BIND="::"
        HY2_SERVER_HOST="${SERVER_IPV6:-}"
        return 0
        ;;
      *) echo "无效选择，请输入 1 或 2。" ;;
    esac
  done
}

prompt_hy2_cert_config() {
  ALLOW_BACK="${1:-0}"
  while :; do
    echo
    echo "Hysteria 2 TLS 证书方式："
    echo "  1. 自动生成自签 ECDSA 证书（免域名，即装即用，链接含 insecure=1）"
    echo "  2. 使用已有域名证书文件（适合已配置 ACME/Let's Encrypt 证书）"
    [ "${ALLOW_BACK}" != "1" ] || echo "  0. 返回"
    printf '请选择 [1]: '
    read -r INPUT
    if [ "${ALLOW_BACK}" = "1" ] && [ "${INPUT}" = "0" ]; then
      return 1
    fi
    case "${INPUT:-1}" in
      1)
        while :; do
          printf '自签证书伪装域名 SNI [%s]: ' "${HY2_SNI:-${DEFAULT_HY2_SNI}}"
          read -r SNI_IN
          NEXT_HSNI="${SNI_IN:-${HY2_SNI:-${DEFAULT_HY2_SNI}}}"
          NEXT_HSNI="$(printf '%s' "${NEXT_HSNI}" | tr -d '[:space:]')"
          case "${NEXT_HSNI}" in
            ''|*[!A-Za-z0-9.-]*) echo "SNI 格式无效。" ;;
            *) HY2_SNI="${NEXT_HSNI}"; break ;;
          esac
        done
        HY2_CERT_MODE="selfsigned"
        HY2_CERT_FILE="${DEFAULT_HY2_CERT_FILE}"
        HY2_KEY_FILE="${DEFAULT_HY2_KEY_FILE}"
        HY2_INSECURE="1"
        return 0
        ;;
      2)
        while :; do
          printf '证书对应域名 SNI（例如 hy2.example.com）: '
          read -r SNI_IN
          SNI_IN="$(printf '%s' "${SNI_IN}" | tr -d '[:space:]')"
          case "${SNI_IN}" in
            ''|*[!A-Za-z0-9.-]*) echo "域名格式无效。" ;;
            *) HY2_SNI="${SNI_IN}"; break ;;
          esac
        done
        while :; do
          printf '证书公钥文件路径 (fullchain.pem): '
          read -r C_FILE
          [ -r "${C_FILE}" ] && break
          echo "文件不存在或不可读：${C_FILE}"
        done
        while :; do
          printf '证书私钥文件路径 (privkey.pem): '
          read -r K_FILE
          [ -r "${K_FILE}" ] && break
          echo "文件不存在或不可读：${K_FILE}"
        done
        HY2_CERT_MODE="custom"
        HY2_CERT_FILE="${C_FILE}"
        HY2_KEY_FILE="${K_FILE}"
        HY2_INSECURE="0"
        return 0
        ;;
      *) echo "无效选择，请输入 1 或 2。" ;;
    esac
  done
}

create_hy2_inbound() {
  load_state
  if hy2_is_configured; then
    echo "Hysteria 2 入站已启用：${HY2_BIND}:${HY2_PORT}/udp"
    return 0
  fi
  info "注意：Xray-core 原生 Hysteria 2 入站需要 Xray-core v26.3+；若启动校验失败，请先在主菜单 10 或运行 vvr update 升级内核。"
  detect_network
  prompt_hy2_family "ipv4"
  while :; do
    prompt_port_value "Hysteria 2 (UDP) " "${DEFAULT_HY2_PORT}" 1 || { MENU_RETURNED="1"; return 0; }
    CAND_HY="${SELECTED_PORT}"
    port_conflicts_with_configured "${CAND_HY}" "hy2" "udp" && continue
    check_port_available "${CAND_HY}" "" "udp" || { echo "UDP 端口 ${CAND_HY} 已被占用，请换一个端口。"; continue; }
    HY2_PORT="${CAND_HY}"
    break
  done
  prompt_hy2_cert_config 1 || { MENU_RETURNED="1"; return 0; }
  if [ "${HY2_CERT_MODE}" = "selfsigned" ]; then
    generate_hy2_selfsigned_cert "${HY2_SNI}" "${HY2_CERT_FILE}" "${HY2_KEY_FILE}" || return 1
  fi
  prompt_tag "${DEFAULT_HY2_NAME}" "初始 Hysteria 2 客户端名称" 1 || { MENU_RETURNED="1"; return 0; }
  HY2_NAME="${TAG}"
  generate_hy2_password || return 1
  backup_hy2_clients_for_change
  printf '%s|%s\n' "${HY2_PASSWORD}" "${HY2_NAME}" > "${HY2_CLIENTS_FILE}"
  chmod 0600 "${HY2_CLIENTS_FILE}"
  apply_config && show_hy2_info || true
}

add_hy2_client() {
  load_state
  if ! hy2_is_configured; then
    create_hy2_inbound
    return
  fi
  while :; do
    prompt_tag "" "新 Hysteria 2 客户端名称" 1 || { MENU_RETURNED="1"; return 0; }
    NEW_HNAME="${TAG}"
    if hy2_client_name_exists "${NEW_HNAME}"; then
      echo "Hysteria 2 入站中已存在同名客户端。"
      continue
    fi
    break
  done
  OLD_HY2_PW="${HY2_PASSWORD:-}"
  generate_hy2_password || { HY2_PASSWORD="${OLD_HY2_PW}"; return 1; }
  NEW_HY2_PW="${HY2_PASSWORD}"
  [ -z "${OLD_HY2_PW}" ] || HY2_PASSWORD="${OLD_HY2_PW}"
  backup_hy2_clients_for_change
  printf '%s|%s\n' "${NEW_HY2_PW}" "${NEW_HNAME}" >> "${HY2_CLIENTS_FILE}"
  chmod 0600 "${HY2_CLIENTS_FILE}"
  apply_config && show_hy2_info || true
}

rename_hy2_client() {
  load_state
  ensure_hy2_clients_file
  echo
  echo "编号  客户端名称"
  NUMBER=0
  while IFS='|' read -r HC_PASS HC_NAME; do
    [ -n "${HC_PASS}" ] || continue
    NUMBER=$((NUMBER + 1))
    printf '%-4s  %s\n' "${NUMBER}" "${HC_NAME}"
  done < "${HY2_CLIENTS_FILE}"
  [ "${NUMBER}" -gt 0 ] || { echo "（暂无 Hysteria 2 客户端）"; return 0; }
  while :; do
    printf '输入要重命名的客户端编号（0 取消）: '
    read -r INPUT
    case "${INPUT}" in
      0) MENU_RETURNED="1"; return 0 ;;
      ''|*[!0-9]*) echo "请输入有效编号。" ;;
      *) [ "${INPUT}" -ge 1 ] && [ "${INPUT}" -le "${NUMBER}" ] && break; echo "编号超出范围。" ;;
    esac
  done
  TARGET_IDX="${INPUT}"
  OLD_NAME="$(awk -F '|' -v target="${TARGET_IDX}" 'NF && $1 != "" {count++; if (count == target) {print $2; exit}}' "${HY2_CLIENTS_FILE}")"
  while :; do
    prompt_tag "${OLD_NAME}" "新客户端名称" 1 || { MENU_RETURNED="1"; return 0; }
    NEW_NAME="${TAG}"
    if [ "${NEW_NAME}" = "${OLD_NAME}" ]; then
      echo "名称未改变。"
      return 0
    fi
    if hy2_client_name_exists "${NEW_NAME}"; then
      echo "Hysteria 2 入站中已存在同名客户端。"
      continue
    fi
    break
  done
  backup_hy2_clients_for_change
  TEMP_HC="$(mktemp /tmp/vvr-hclients-new.XXXXXX)"
  awk -F '|' -v OFS='|' -v target="${TARGET_IDX}" -v newname="${NEW_NAME}" \
    'NF && $1 != "" {count++; if (count == target) $2 = newname} {print}' "${HY2_CLIENTS_FILE}" > "${TEMP_HC}"
  mv "${TEMP_HC}" "${HY2_CLIENTS_FILE}"
  chmod 0600 "${HY2_CLIENTS_FILE}"
  [ "${TARGET_IDX}" != "1" ] || HY2_NAME="${NEW_NAME}"
  if apply_config; then
    ok "Hysteria 2 客户端已重命名为 ${NEW_NAME}（已同步更新 Xray 用户 email 标识）。"
  fi
}

delete_hy2_client() {
  load_state
  ensure_hy2_clients_file
  echo
  echo "编号  客户端名称"
  NUMBER=0
  while IFS='|' read -r HC_PASS HC_NAME; do
    [ -n "${HC_PASS}" ] || continue
    NUMBER=$((NUMBER + 1))
    printf '%-4s  %s\n' "${NUMBER}" "${HC_NAME}"
  done < "${HY2_CLIENTS_FILE}"
  [ "${NUMBER}" -gt 0 ] || { echo "（暂无 Hysteria 2 客户端）"; return 0; }
  if [ "${NUMBER}" -le 1 ] && ! other_protocols_active_excluding "hy2"; then
    warn "当前没有其他启用的入站协议，不能删除最后一个 Hysteria 2 客户端。"
    return 0
  fi
  while :; do
    printf '输入要删除的客户端编号（0 取消）: '
    read -r INPUT
    case "${INPUT}" in
      0) MENU_RETURNED="1"; return 0 ;;
      ''|*[!0-9]*) echo "请输入有效编号。" ;;
      *) [ "${INPUT}" -ge 1 ] && [ "${INPUT}" -le "${NUMBER}" ] && break; echo "编号超出范围。" ;;
    esac
  done
  backup_hy2_clients_for_change
  TEMP_HC="$(mktemp /tmp/vvr-hclients-new.XXXXXX)"
  awk -F '|' -v target="${INPUT}" 'NF && $1 != "" {count++} count != target {print}' "${HY2_CLIENTS_FILE}" > "${TEMP_HC}"
  mv "${TEMP_HC}" "${HY2_CLIENTS_FILE}"
  chmod 0600 "${HY2_CLIENTS_FILE}"
  FIRST_REM="$(awk -F '|' 'NF && $1 != "" {print; exit}' "${HY2_CLIENTS_FILE}")"
  if [ -z "${FIRST_REM}" ]; then
    HY2_PORT=""
    HY2_PASSWORD=""
    HY2_SERVER_HOST=""
    HY2_FAMILY=""
    HY2_BIND=""
  else
    HY2_PASSWORD="$(printf '%s' "${FIRST_REM}" | cut -d'|' -f1)"
    HY2_NAME="$(printf '%s' "${FIRST_REM}" | cut -d'|' -f2)"
  fi
  apply_config || true
}

modify_hy2_port() {
  load_state
  hy2_is_configured || { echo "Hysteria 2 尚未启用。"; return 0; }
  OLD_HY_PORT="${HY2_PORT}"
  while :; do
    prompt_port_value "Hysteria 2 (UDP) " "${HY2_PORT}" 1 || { MENU_RETURNED="1"; return 0; }
    CAND_HY="${SELECTED_PORT}"
    port_conflicts_with_configured "${CAND_HY}" "hy2" "udp" && continue
    check_port_available "${CAND_HY}" "${OLD_HY_PORT}" "udp" || { echo "UDP 端口 ${CAND_HY} 已被占用，请换一个端口。"; continue; }
    HY2_PORT="${CAND_HY}"
    break
  done
  apply_config && show_hy2_info || true
}

modify_hy2_family() {
  load_state
  hy2_is_configured || { echo "Hysteria 2 尚未启用。"; return 0; }
  detect_network
  prompt_hy2_family "${HY2_FAMILY}"
  apply_config && show_hy2_info || true
}

modify_hy2_cert() {
  load_state
  hy2_is_configured || { echo "Hysteria 2 尚未启用。"; return 0; }
  prompt_hy2_cert_config 1 || { MENU_RETURNED="1"; return 0; }
  if [ "${HY2_CERT_MODE}" = "selfsigned" ]; then
    generate_hy2_selfsigned_cert "${HY2_SNI}" "${HY2_CERT_FILE}" "${HY2_KEY_FILE}" || return 1
  fi
  apply_config && show_hy2_info || true
}

remove_hy2_inbound() {
  load_state
  hy2_is_configured || { echo "Hysteria 2 尚未启用。"; return 0; }
  if ! other_protocols_active_excluding "hy2"; then
    warn "当前没有其他启用的入站协议，不能删除最后一个协议。"
    return 0
  fi
  printf '确认删除 Hysteria 2 入站及其全部客户端？[y/N]: '
  read -r ANSWER
  case "${ANSWER}" in y|Y|yes|YES) ;; *) MENU_RETURNED="1"; return 0 ;; esac
  backup_hy2_clients_for_change
  : > "${HY2_CLIENTS_FILE}"
  chmod 0600 "${HY2_CLIENTS_FILE}"
  HY2_PORT=""
  HY2_PASSWORD=""
  HY2_SERVER_HOST=""
  HY2_FAMILY=""
  HY2_BIND=""
  apply_config || true
}

manage_hy2_menu() {
  while :; do
    load_state
    MENU_RETURNED="0"
    clear 2>/dev/null || true
    echo "=========================================="
    echo " ${CYAN}Hysteria 2 (UDP/QUIC) 管理${RESET}"
    echo "=========================================="
    if hy2_is_configured; then
      echo " 当前：${HY2_BIND}:${HY2_PORT}/udp | SNI=${HY2_SNI} | 证书=${HY2_CERT_MODE}（$(hy2_client_count) 个客户端）"
      echo "------------------------------------------"
      echo "  1. 查看全部 Hysteria 2 客户端链接"
      echo "  2. 添加 Hysteria 2 客户端"
      echo "  3. 重命名客户端"
      echo "  4. 删除客户端"
      echo "  5. 修改 UDP 监听端口"
      echo "  6. 切换入站地址族（IPv4 / IPv6）"
      echo "  7. 重新配置证书与 SNI"
      echo "  8. 删除 Hysteria 2 入站"
    else
      echo " 状态：${DIM}○ 未启用${RESET}"
      echo "------------------------------------------"
      echo "  1. 创建并启用 Hysteria 2 入站（Xray 原生）"
    fi
    echo "  0. 返回主菜单（或输入 q）"
    echo "=========================================="
    printf '请选择操作: '
    read -r CHOICE || return 0
    [ -n "${CHOICE}" ] || continue
    if ! hy2_is_configured; then
      case "${CHOICE}" in
        1) create_hy2_inbound || true ;;
        0|q|Q) return 0 ;;
        *) echo "无效选择。" ;;
      esac
    else
      case "${CHOICE}" in
        1) show_hy2_info ;;
        2) add_hy2_client || true ;;
        3) rename_hy2_client || true ;;
        4) delete_hy2_client || true ;;
        5) modify_hy2_port || true ;;
        6) modify_hy2_family || true ;;
        7) modify_hy2_cert || true ;;
        8) remove_hy2_inbound || true ;;
        0|q|Q) return 0 ;;
        *) echo "无效选择。" ;;
      esac
    fi
    if [ "${MENU_RETURNED:-0}" = "1" ]; then
      MENU_RETURNED="0"
      continue
    fi
    pause_menu
  done
}

# --- Shadowsocks management ---

create_ss_inbound() {
  load_state
  if ss_is_configured; then
    echo "Shadowsocks 入站已启用：${SS_BIND}:${SS_PORT}"
    return 0
  fi
  detect_network
  prompt_ss_family "ipv4"
  prompt_ss_method "${DEFAULT_SS_METHOD}"
  prompt_ss_network "${DEFAULT_SS_NETWORK}"
  while :; do
    prompt_port_value "Shadowsocks " "${DEFAULT_SS_PORT}" 1 || { MENU_RETURNED="1"; return 0; }
    CAND_SS="${SELECTED_PORT}"
    port_conflicts_with_configured "${CAND_SS}" "ss" "${SS_NETWORK}" && continue
    check_port_available "${CAND_SS}" "" "${SS_NETWORK}" || { echo "端口 ${CAND_SS} 已被占用，请重新输入。"; continue; }
    SS_PORT="${CAND_SS}"
    break
  done
  prompt_tag "${DEFAULT_SS_NAME}" "Shadowsocks 节点名称" 1 || { MENU_RETURNED="1"; return 0; }
  SS_NAME="${TAG}"
  generate_ss_password "${SS_METHOD}" || return 1
  apply_config && show_ss_info || true
}

modify_ss_port() {
  load_state
  ss_is_configured || { echo "Shadowsocks 尚未启用。"; return 0; }
  OLD_SS_PORT="${SS_PORT}"
  while :; do
    prompt_port_value "Shadowsocks " "${SS_PORT}" 1 || { MENU_RETURNED="1"; return 0; }
    CAND_SS="${SELECTED_PORT}"
    port_conflicts_with_configured "${CAND_SS}" "ss" "${SS_NETWORK}" && continue
    check_port_available "${CAND_SS}" "${OLD_SS_PORT}" "${SS_NETWORK}" || { echo "端口 ${CAND_SS} 已被占用，请重新输入。"; continue; }
    SS_PORT="${CAND_SS}"
    break
  done
  apply_config && show_ss_info || true
}

modify_ss_family() {
  load_state
  ss_is_configured || { echo "Shadowsocks 尚未启用。"; return 0; }
  detect_network
  prompt_ss_family "${SS_FAMILY}"
  apply_config && show_ss_info || true
}

modify_ss_network() {
  load_state
  ss_is_configured || { echo "Shadowsocks 尚未启用。"; return 0; }
  OLD_NET="${SS_NETWORK}"
  prompt_ss_network "${SS_NETWORK}"
  if [ "${SS_NETWORK}" != "${OLD_NET}" ] && [ "${SS_NETWORK}" = "tcp,udp" ]; then
    if port_conflicts_with_configured "${SS_PORT}" "ss" "udp"; then
      return 1
    fi
    if ! check_port_available "${SS_PORT}" "" "udp"; then
      warn "UDP 端口 ${SS_PORT} 已被其他进程占用。"
      return 1
    fi
  fi
  apply_config && show_ss_info || true
}

modify_ss_method_or_password() {
  load_state
  ss_is_configured || { echo "Shadowsocks 尚未启用。"; return 0; }
  echo "  1. 仅重置密码（保持当前加密方式：${SS_METHOD}）"
  echo "  2. 更换加密方式并生成新密码"
  echo "  3. 修改节点名称（当前：${SS_NAME}）"
  echo "  0. 返回"
  printf '请选择: '
  read -r INPUT
  case "${INPUT}" in
    1)
      generate_ss_password "${SS_METHOD}" || return 1
      apply_config && show_ss_info || true
      ;;
    2)
      prompt_ss_method "${SS_METHOD}"
      generate_ss_password "${SS_METHOD}" || return 1
      apply_config && show_ss_info || true
      ;;
    3)
      prompt_tag "${SS_NAME}" "Shadowsocks 节点名称" 1 || { MENU_RETURNED="1"; return 0; }
      SS_NAME="${TAG}"
      save_state
      ok "Shadowsocks 节点名称已更新为 ${SS_NAME}（无需重启 Xray）。"
      show_ss_info
      ;;
    0) MENU_RETURNED="1"; return 0 ;;
    *) echo "无效选择。" ;;
  esac
}

remove_ss_inbound() {
  load_state
  ss_is_configured || { echo "Shadowsocks 尚未启用。"; return 0; }
  if ! other_protocols_active_excluding "ss"; then
    warn "当前没有其他启用的入站协议，不能删除最后一个协议。"
    return 0
  fi
  printf '确认删除 Shadowsocks 入站？[y/N]: '
  read -r ANSWER
  case "${ANSWER}" in y|Y|yes|YES) ;; *) MENU_RETURNED="1"; return 0 ;; esac
  SS_PORT=""
  SS_PASSWORD=""
  SS_SERVER_HOST=""
  SS_FAMILY=""
  SS_BIND=""
  apply_config || true
}

manage_ss_menu() {
  while :; do
    load_state
    MENU_RETURNED="0"
    clear 2>/dev/null || true
    echo "=========================================="
    echo " ${CYAN}Shadowsocks 管理${RESET}"
    echo "=========================================="
    if ss_is_configured; then
      echo " 当前：${SS_BIND}:${SS_PORT}（${SS_METHOD} | ${SS_NETWORK}）"
      echo "------------------------------------------"
      echo "  1. 查看 Shadowsocks 配置与链接"
      echo "  2. 修改监听端口"
      echo "  3. 切换入站地址族（IPv4 / IPv6）"
      echo "  4. 切换传输网络（TCP / TCP+UDP）"
      echo "  5. 重置密码 / 更换加密方式 / 改名"
      echo "  6. 删除 Shadowsocks 入站"
    else
      echo " 状态：${DIM}○ 未启用${RESET}"
      echo "------------------------------------------"
      echo "  1. 创建并启用 Shadowsocks 入站"
    fi
    echo "  0. 返回主菜单（或输入 q）"
    echo "=========================================="
    printf '请选择操作: '
    read -r CHOICE || return 0
    [ -n "${CHOICE}" ] || continue
    if ! ss_is_configured; then
      case "${CHOICE}" in
        1) create_ss_inbound || true ;;
        0|q|Q) return 0 ;;
        *) echo "无效选择。" ;;
      esac
    else
      case "${CHOICE}" in
        1) show_ss_info ;;
        2) modify_ss_port || true ;;
        3) modify_ss_family || true ;;
        4) modify_ss_network || true ;;
        5) modify_ss_method_or_password || true ;;
        6) remove_ss_inbound || true ;;
        0|q|Q) return 0 ;;
        *) echo "无效选择。" ;;
      esac
    fi
    if [ "${MENU_RETURNED:-0}" = "1" ]; then
      MENU_RETURNED="0"
      continue
    fi
    pause_menu
  done
}

# --- Outbound strategy, routing rules & URL tester ---

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
  [ "${NUMBER}" -gt 0 ] || echo "（暂无自定义规则）"
}

add_domain_rule() {
  load_state
  echo "选择此规则使用的出站目标："
  choose_outbound_mode "${BASE_OUTBOUND_MODE}" 1 1 || { MENU_RETURNED="1"; return 0; }
  confirm_outbound_availability "${SELECTED_OUTBOUND_MODE}" || { MENU_RETURNED="1"; return 0; }
  while :; do
    echo "  1. 精确匹配（例如 api.example.com）"
    echo "  2. 后缀匹配（例如 example.com 及其子域名）"
    echo "  0. 返回"
    printf '选择匹配类型 [1]: '
    read -r INPUT
    case "${INPUT:-1}" in
      1) DOMAIN_PREFIX="full"; break ;;
      2) DOMAIN_PREFIX="domain"; break ;;
      0) MENU_RETURNED="1"; return 0 ;;
      *) echo "无效选择。" ;;
    esac
  done
  while :; do
    printf '输入域名（输入 0 返回）: '
    read -r DOMAIN
    case "${DOMAIN}" in
      0) MENU_RETURNED="1"; return 0 ;;
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
  echo "选择此规则使用的出站目标："
  choose_outbound_mode "${BASE_OUTBOUND_MODE}" 1 1 || { MENU_RETURNED="1"; return 0; }
  confirm_outbound_availability "${SELECTED_OUTBOUND_MODE}" || { MENU_RETURNED="1"; return 0; }
  while :; do
    printf '输入 geosite 名称，例如 youtube（输入 0 返回）: '
    read -r GEOSITE
    case "${GEOSITE}" in
      0) MENU_RETURNED="1"; return 0 ;;
      ''|*[!A-Za-z0-9._@!:-]*) echo "geosite 名称格式无效。" ;;
      *) break ;;
    esac
  done
  backup_routes_for_change
  printf '%s|geosite|%s\n' "${SELECTED_OUTBOUND_MODE}" "${GEOSITE}" >> "${ROUTES_FILE}"
  apply_config || true
}

append_geosite_if_missing() {
  PRE_MODE="$1"
  PRE_SITE="$2"
  ensure_routes_file
  if awk -F '|' -v m="${PRE_MODE}" -v s="${PRE_SITE}" '$1 == m && $2 == "geosite" && $3 == s {found=1} END {exit !found}' "${ROUTES_FILE}"; then
    return 0
  fi
  printf '%s|geosite|%s\n' "${PRE_MODE}" "${PRE_SITE}" >> "${ROUTES_FILE}"
}

add_preset_rule() {
  load_state
  echo
  echo "内置常用分流场景预设："
  echo "  1. AI 服务（geosite:openai / anthropic / google-gemini）"
  echo "  2. YouTube（geosite:youtube）"
  echo "  3. 流媒体（geosite:netflix / disney）"
  echo "  4. 广告屏蔽（geosite:category-ads-all -> block）"
  echo "  0. 返回"
  printf '请选择预设: '
  read -r PRESET_CHOICE || { MENU_RETURNED="1"; return 0; }
  case "${PRESET_CHOICE}" in
    0|q|Q|'') MENU_RETURNED="1"; return 0 ;;
    1|2|3)
      echo "选择该预设命中的出站目标："
      choose_outbound_mode "${BASE_OUTBOUND_MODE}" 1 1 || { MENU_RETURNED="1"; return 0; }
      confirm_outbound_availability "${SELECTED_OUTBOUND_MODE}" || { MENU_RETURNED="1"; return 0; }
      backup_routes_for_change
      case "${PRESET_CHOICE}" in
        1)
          append_geosite_if_missing "${SELECTED_OUTBOUND_MODE}" "openai"
          append_geosite_if_missing "${SELECTED_OUTBOUND_MODE}" "anthropic"
          append_geosite_if_missing "${SELECTED_OUTBOUND_MODE}" "google-gemini"
          ;;
        2)
          append_geosite_if_missing "${SELECTED_OUTBOUND_MODE}" "youtube"
          ;;
        3)
          append_geosite_if_missing "${SELECTED_OUTBOUND_MODE}" "netflix"
          append_geosite_if_missing "${SELECTED_OUTBOUND_MODE}" "disney"
          ;;
      esac
      apply_config || true
      ;;
    4)
      backup_routes_for_change
      append_geosite_if_missing "block" "category-ads-all"
      apply_config || true
      ;;
    *) echo "无效选择。" ;;
  esac
}

reorder_rule() {
  ensure_routes_file
  list_rules
  COUNT="$(awk 'NF {count++} END {print count+0}' "${ROUTES_FILE}")"
  if [ "${COUNT}" -lt 2 ]; then
    echo "规则数量不足 2 条，无需调整顺序。"
    return 0
  fi
  while :; do
    printf '输入要移动的规则编号（0 取消）: '
    read -r SRC_IDX
    case "${SRC_IDX}" in
      0) MENU_RETURNED="1"; return 0 ;;
      ''|*[!0-9]*) echo "请输入有效编号。" ;;
      *) [ "${SRC_IDX}" -ge 1 ] && [ "${SRC_IDX}" -le "${COUNT}" ] && break; echo "编号超出范围。" ;;
    esac
  done
  echo "  1. 上移一位（提高优先级）"
  echo "  2. 下移一位（降低优先级）"
  echo "  3. 移到最顶（最高优先级）"
  echo "  0. 取消"
  printf '选择移动方式: '
  read -r MOVE_ACT
  case "${MOVE_ACT}" in
    1)
      [ "${SRC_IDX}" -gt 1 ] || { echo "该规则已在最顶。"; return 0; }
      DST_IDX=$((SRC_IDX - 1))
      ;;
    2)
      [ "${SRC_IDX}" -lt "${COUNT}" ] || { echo "该规则已在最底。"; return 0; }
      DST_IDX=$((SRC_IDX + 1))
      ;;
    3)
      [ "${SRC_IDX}" -gt 1 ] || { echo "该规则已在最顶。"; return 0; }
      DST_IDX=1
      ;;
    0|q|Q|'') MENU_RETURNED="1"; return 0 ;;
    *) echo "无效选择。"; return 0 ;;
  esac
  backup_routes_for_change
  TEMP_RULES="$(mktemp /tmp/vvr-rules-ord.XXXXXX)"
  awk -v src="${SRC_IDX}" -v dst="${DST_IDX}" '
    NF { n++; lines[n] = $0 }
    END {
      item = lines[src]
      if (dst < src) {
        for (i = src; i > dst; i--) lines[i] = lines[i - 1]
      } else {
        for (i = src; i < dst; i++) lines[i] = lines[i + 1]
      }
      lines[dst] = item
      for (i = 1; i <= n; i++) print lines[i]
    }
  ' "${ROUTES_FILE}" > "${TEMP_RULES}"
  mv "${TEMP_RULES}" "${ROUTES_FILE}"
  chmod 0600 "${ROUTES_FILE}"
  apply_config || true
}

user_routes_count() {
  ensure_user_routes_file
  awk -F '|' '$1 != "" && $2 != "" {count++} END {print count+0}' "${USER_ROUTES_FILE}"
}

inbound_routes_count() {
  ensure_inbound_routes_file
  awk -F '|' '$1 != "" && $2 != "" {count++} END {print count+0}' "${INBOUND_ROUTES_FILE}"
}

list_custom_outbounds() {
  ensure_outbounds_file
  echo
  echo "编号  出站标签            协议   服务器地址:端口            详情"
  NUMBER=0
  while IFS='|' read -r OB_TAG OB_PROTO OB_ADDR OB_PORT OB_F5 OB_F6; do
    [ -n "${OB_TAG}" ] && [ -n "${OB_PROTO}" ] || continue
    NUMBER=$((NUMBER + 1))
    case "${OB_PROTO}" in
      ss) DETAIL="method=${OB_F5}" ;;
      socks) [ -n "${OB_F5}" ] && DETAIL="user=${OB_F5}" || DETAIL="无认证" ;;
      *) DETAIL="-" ;;
    esac
    printf '%-4s  %-18s  %-5s  %-25s  %s\n' "${NUMBER}" "${OB_TAG}" "${OB_PROTO}" "${OB_ADDR}:${OB_PORT}" "${DETAIL}"
  done < "${OUTBOUNDS_FILE}"
  [ "${NUMBER}" -gt 0 ] || echo "（暂无外部落地代理）"
}

add_custom_outbound() {
  load_state
  ensure_outbounds_file
  echo
  echo "添加外部落地代理（可用于链式出站、解锁 AI/流媒体，或指定某用户/协议专用落地）："
  while :; do
    printf '落地代理简称（例如 us / jp / warp，自动加前缀 proxy-，输入 0 返回）: '
    read -r OB_SHORT
    case "${OB_SHORT}" in
      0) MENU_RETURNED="1"; return 0 ;;
      ''|*[!A-Za-z0-9._-]*) echo "简称只能包含英文、数字、点、下划线和短横线。" ;;
      *)
        case "${OB_SHORT}" in
          proxy-*) OB_TAG="${OB_SHORT}" ;;
          *) OB_TAG="proxy-${OB_SHORT}" ;;
        esac
        if custom_outbound_exists "${OB_TAG}"; then
          echo "落地代理标签 ${OB_TAG} 已存在，请换一个名称。"
          continue
        fi
        break
        ;;
    esac
  done
  while :; do
    echo "选择落地代理协议："
    echo "  1. Shadowsocks (ss)"
    echo "  2. Socks5 (socks，例如本机 WARP / 外部 Socks5 落地)"
    echo "  0. 返回"
    printf '请选择 [1]: '
    read -r P_IN
    case "${P_IN:-1}" in
      1) OB_PROTO="ss"; break ;;
      2) OB_PROTO="socks"; break ;;
      0) MENU_RETURNED="1"; return 0 ;;
      *) echo "无效选择。" ;;
    esac
  done
  while :; do
    printf '落地服务器地址（IP 或域名，输入 0 返回）: '
    read -r OB_ADDR
    case "${OB_ADDR}" in
      0) MENU_RETURNED="1"; return 0 ;;
      ''|*[[:space:]]*|*\|*|*\"*) echo "服务器地址格式无效（不能包含空格、| 或引号）。" ;;
      *) break ;;
    esac
  done
  prompt_port_value "落地服务器" "1080" 1 || { MENU_RETURNED="1"; return 0; }
  OB_PORT="${SELECTED_PORT}"
  OB_F5=""
  OB_F6=""
  case "${OB_PROTO}" in
    ss)
      echo "选择 Shadowsocks 加密方式："
      echo "  1. 2022-blake3-aes-128-gcm"
      echo "  2. 2022-blake3-aes-256-gcm"
      echo "  3. aes-256-gcm"
      echo "  4. chacha20-ietf-poly1305"
      echo "  5. 手动输入其他加密方式"
      printf '请选择 [1]: '
      read -r M_IN
      case "${M_IN:-1}" in
        1) OB_F5="2022-blake3-aes-128-gcm" ;;
        2) OB_F5="2022-blake3-aes-256-gcm" ;;
        3) OB_F5="aes-256-gcm" ;;
        4) OB_F5="chacha20-ietf-poly1305" ;;
        5)
          printf '输入加密方式名称: '
          read -r OB_F5
          ;;
        *) OB_F5="2022-blake3-aes-128-gcm" ;;
      esac
      case "${OB_F5}" in ''|*[[:space:]]*|*\|*|*\"*) warn "加密方式无效。"; return 1 ;; esac
      while :; do
        printf '输入 Shadowsocks 密码（输入 0 返回）: '
        read -r OB_F6
        case "${OB_F6}" in
          0) MENU_RETURNED="1"; return 0 ;;
          ''|*[[:space:]]*|*\|*|*\"*) echo "密码不能包含空格、| 或引号。" ;;
          *) break ;;
        esac
      done
      ;;
    socks)
      printf 'Socks5 用户名（无认证直接回车）: '
      read -r OB_F5
      case "${OB_F5}" in *\|*|*\"*) warn "用户名不能包含 | 或引号。"; return 1 ;; esac
      if [ -n "${OB_F5}" ]; then
        printf 'Socks5 密码: '
        read -r OB_F6
        case "${OB_F6}" in *\|*|*\"*) warn "密码不能包含 | 或引号。"; return 1 ;; esac
      fi
      ;;
  esac
  backup_outbounds_for_change
  printf '%s|%s|%s|%s|%s|%s\n' "${OB_TAG}" "${OB_PROTO}" "${OB_ADDR}" "${OB_PORT}" "${OB_F5}" "${OB_F6}" >> "${OUTBOUNDS_FILE}"
  chmod 0600 "${OUTBOUNDS_FILE}"
  apply_config || true
}

delete_custom_outbound() {
  load_state
  ensure_outbounds_file
  list_custom_outbounds
  COUNT="$(custom_outbound_count)"
  [ "${COUNT}" -gt 0 ] || return 0
  while :; do
    printf '输入要删除的落地代理编号（0 取消）: '
    read -r INPUT
    case "${INPUT}" in
      0) MENU_RETURNED="1"; return 0 ;;
      ''|*[!0-9]*) echo "请输入有效编号。" ;;
      *) [ "${INPUT}" -ge 1 ] && [ "${INPUT}" -le "${COUNT}" ] && break; echo "编号超出范围。" ;;
    esac
  done
  DEL_TAG="$(awk -F '|' -v target="${INPUT}" '$1 != "" && $2 != "" {count++; if (count == target) {print $1; exit}}' "${OUTBOUNDS_FILE}")"
  if [ "${BASE_OUTBOUND_MODE}" = "${DEL_TAG}" ]; then
    warn "落地代理 ${DEL_TAG} 正被设为【基础出站】，请先切换基础出站后再删除。"
    return 0
  fi
  if awk -F '|' -v tag="${DEL_TAG}" '$1 == tag {found=1} END {exit !found}' "${ROUTES_FILE}"; then
    warn "落地代理 ${DEL_TAG} 正被域名分流规则引用，请先删除对应规则后再删除。"
    return 0
  fi
  if awk -F '|' -v tag="${DEL_TAG}" '$2 == tag {found=1} END {exit !found}' "${USER_ROUTES_FILE}"; then
    warn "落地代理 ${DEL_TAG} 正被用户出站覆盖引用，请先解除后再删除。"
    return 0
  fi
  if awk -F '|' -v tag="${DEL_TAG}" '$2 == tag {found=1} END {exit !found}' "${INBOUND_ROUTES_FILE}"; then
    warn "落地代理 ${DEL_TAG} 正被协议入站出站覆盖引用，请先解除后再删除。"
    return 0
  fi
  backup_outbounds_for_change
  TEMP_OB="$(mktemp /tmp/vvr-outbounds-new.XXXXXX)"
  awk -F '|' -v target="${INPUT}" '$1 != "" && $2 != "" {count++} count != target {print}' "${OUTBOUNDS_FILE}" > "${TEMP_OB}"
  mv "${TEMP_OB}" "${OUTBOUNDS_FILE}"
  chmod 0600 "${OUTBOUNDS_FILE}"
  apply_config || true
}

manage_custom_outbounds_menu() {
  while :; do
    load_state
    MENU_RETURNED="0"
    clear 2>/dev/null || true
    echo "=========================================="
    echo " ${CYAN}外部落地代理管理（链式出站）${RESET}"
    echo "=========================================="
    echo " 已配置落地代理：$(custom_outbound_count) 个"
    echo "------------------------------------------"
    echo "  1. 查看全部外部落地代理"
    echo "  2. 添加外部落地代理（Shadowsocks / Socks5）"
    echo "  3. 删除外部落地代理"
    echo "  0. 返回上一级（或输入 q）"
    echo "=========================================="
    printf '请选择操作: '
    read -r CHOICE || return 0
    [ -n "${CHOICE}" ] || continue
    case "${CHOICE}" in
      1) list_custom_outbounds ;;
      2) add_custom_outbound || true ;;
      3) delete_custom_outbound || true ;;
      0|q|Q) return 0 ;;
      *) echo "无效选择。" ;;
    esac
    if [ "${MENU_RETURNED:-0}" = "1" ]; then
      MENU_RETURNED="0"
      continue
    fi
    pause_menu
  done
}

list_user_routes() {
  ensure_user_routes_file
  echo
  echo "编号  用户标识 (email)        指定默认出站"
  NUMBER=0
  while IFS='|' read -r UR_USER UR_MODE; do
    [ -n "${UR_USER}" ] && [ -n "${UR_MODE}" ] || continue
    NUMBER=$((NUMBER + 1))
    printf '%-4s  %-22s  %s\n' "${NUMBER}" "${UR_USER}" "$(outbound_mode_label "${UR_MODE}")"
  done < "${USER_ROUTES_FILE}"
  [ "${NUMBER}" -gt 0 ] || echo "（暂无按用户出站覆盖，所有用户遵循协议入站与基础出站）"
}

manage_user_routes_menu() {
  while :; do
    load_state
    MENU_RETURNED="0"
    clear 2>/dev/null || true
    echo "=========================================="
    echo " ${CYAN}按用户指定默认出站（第 2 层路由）${RESET}"
    echo "=========================================="
    echo " 优先级：域名/Geosite 规则 > 用户覆盖 > 协议覆盖 > 基础出站"
    list_user_routes
    echo "------------------------------------------"
    echo "  1. 设置 / 修改某用户的默认出站"
    echo "  2. 删除某用户的出站覆盖"
    echo "  0. 返回上一级（或输入 q）"
    echo "=========================================="
    printf '请选择操作: '
    read -r CHOICE || return 0
    [ -n "${CHOICE}" ] || continue
    case "${CHOICE}" in
      1)
        USERS_LIST="$(list_all_usernames)"
        echo
        if [ -n "${USERS_LIST}" ]; then
          echo "当前已有用户："
          U_NUM=0
          for U_NAME in ${USERS_LIST}; do
            U_NUM=$((U_NUM + 1))
            printf '  %s. %s\n' "${U_NUM}" "${U_NAME}"
          done
          echo "  （可直接输入编号，或手动输入用户名，输入 0 返回）"
        fi
        printf '选择用户编号或输入用户名（0 返回）: '
        read -r U_IN
        case "${U_IN}" in ''|0|q|Q) MENU_RETURNED="1"; continue ;; esac
        TARGET_U=""
        case "${U_IN}" in
          *[!0-9]*) TARGET_U="${U_IN}" ;;
          *)
            if [ -n "${USERS_LIST}" ] && [ "${U_IN}" -ge 1 ] && [ "${U_IN}" -le "${U_NUM}" ]; then
              TARGET_U="$(printf '%s\n' "${USERS_LIST}" | sed -n "${U_IN}p")"
            else
              TARGET_U="${U_IN}"
            fi
            ;;
        esac
        case "${TARGET_U}" in
          ''|*[!A-Za-z0-9._-]*) echo "用户名格式无效。"; pause_menu; continue ;;
        esac
        echo "为用户 [${TARGET_U}] 选择默认出站："
        choose_outbound_mode "${BASE_OUTBOUND_MODE}" 1 1 || { MENU_RETURNED="1"; continue; }
        confirm_outbound_availability "${SELECTED_OUTBOUND_MODE}" || { MENU_RETURNED="1"; continue; }
        backup_user_routes_for_change
        TEMP_UR="$(mktemp /tmp/vvr-uroutes-new.XXXXXX)"
        awk -F '|' -v u="${TARGET_U}" '$1 != u && NF {print}' "${USER_ROUTES_FILE}" > "${TEMP_UR}"
        printf '%s|%s\n' "${TARGET_U}" "${SELECTED_OUTBOUND_MODE}" >> "${TEMP_UR}"
        mv "${TEMP_UR}" "${USER_ROUTES_FILE}"
        chmod 0600 "${USER_ROUTES_FILE}"
        apply_config || true
        ;;
      2)
        UR_CNT="$(user_routes_count)"
        if [ "${UR_CNT}" -eq 0 ]; then
          echo "暂无可删除的用户覆盖。"
        else
          printf '输入要删除的编号（0 取消）: '
          read -r DEL_IDX
          case "${DEL_IDX}" in
            0|q|Q|'') MENU_RETURNED="1"; continue ;;
            *[!0-9]*) echo "无效编号。" ;;
            *)
              if [ "${DEL_IDX}" -ge 1 ] && [ "${DEL_IDX}" -le "${UR_CNT}" ]; then
                backup_user_routes_for_change
                TEMP_UR="$(mktemp /tmp/vvr-uroutes-new.XXXXXX)"
                awk -F '|' -v target="${DEL_IDX}" '$1 != "" && $2 != "" {count++} count != target {print}' "${USER_ROUTES_FILE}" > "${TEMP_UR}"
                mv "${TEMP_UR}" "${USER_ROUTES_FILE}"
                chmod 0600 "${USER_ROUTES_FILE}"
                apply_config || true
              else
                echo "编号超出范围。"
              fi
              ;;
          esac
        fi
        ;;
      0|q|Q) return 0 ;;
      *) echo "无效选择。" ;;
    esac
    if [ "${MENU_RETURNED:-0}" = "1" ]; then
      MENU_RETURNED="0"
      continue
    fi
    pause_menu
  done
}

inbound_tag_label() {
  case "$1" in
    vless-in-ipv4) printf '%s' 'VLESS-Vision IPv4 (vless-in-ipv4)' ;;
    vless-in-ipv6) printf '%s' 'VLESS-Vision IPv6 (vless-in-ipv6)' ;;
    vless-xhttp-in) printf '%s' 'VLESS-XHTTP (vless-xhttp-in)' ;;
    hysteria2-in) printf '%s' 'Hysteria 2 (hysteria2-in)' ;;
    shadowsocks-in) printf '%s' 'Shadowsocks (shadowsocks-in)' ;;
    *) printf '%s' "$1" ;;
  esac
}

list_inbound_routes() {
  ensure_inbound_routes_file
  echo
  echo "编号  协议入站                           指定默认出站"
  NUMBER=0
  while IFS='|' read -r IR_TAG IR_MODE; do
    [ -n "${IR_TAG}" ] && [ -n "${IR_MODE}" ] || continue
    NUMBER=$((NUMBER + 1))
    printf '%-4s  %-34s %s\n' "${NUMBER}" "$(inbound_tag_label "${IR_TAG}")" "$(outbound_mode_label "${IR_MODE}")"
  done < "${INBOUND_ROUTES_FILE}"
  [ "${NUMBER}" -gt 0 ] || echo "（暂无按协议入站覆盖，所有入站遵循基础出站）"
}

manage_inbound_routes_menu() {
  while :; do
    load_state
    MENU_RETURNED="0"
    clear 2>/dev/null || true
    echo "=========================================="
    echo " ${CYAN}按协议入站指定默认出站（第 3 层路由）${RESET}"
    echo "=========================================="
    echo " 优先级：域名/Geosite 规则 > 用户覆盖 > 协议覆盖 > 基础出站"
    list_inbound_routes
    echo "------------------------------------------"
    echo "  1. 设置 / 修改某协议入站的默认出站"
    echo "  2. 删除某协议入站的出站覆盖"
    echo "  0. 返回上一级（或输入 q）"
    echo "=========================================="
    printf '请选择操作: '
    read -r CHOICE || return 0
    [ -n "${CHOICE}" ] || continue
    case "${CHOICE}" in
      1)
        echo
        echo "选择要指定的协议入站："
        echo "  1. VLESS-Vision IPv4 (vless-in-ipv4)"
        echo "  2. VLESS-Vision IPv6 (vless-in-ipv6)"
        echo "  3. VLESS-XHTTP (vless-xhttp-in)"
        echo "  4. Hysteria 2 (hysteria2-in)"
        echo "  5. Shadowsocks (shadowsocks-in)"
        echo "  0. 返回"
        printf '请选择: '
        read -r IB_PICK
        case "${IB_PICK}" in
          1) TARGET_IB="vless-in-ipv4" ;;
          2) TARGET_IB="vless-in-ipv6" ;;
          3) TARGET_IB="${XHTTP_INBOUND_TAG}" ;;
          4) TARGET_IB="${HY2_INBOUND_TAG}" ;;
          5) TARGET_IB="${SS_INBOUND_TAG}" ;;
          0|q|Q|'') MENU_RETURNED="1"; continue ;;
          *) echo "无效选择。"; pause_menu; continue ;;
        esac
        echo "为 [$(inbound_tag_label "${TARGET_IB}")] 选择默认出站："
        choose_outbound_mode "${BASE_OUTBOUND_MODE}" 1 1 || { MENU_RETURNED="1"; continue; }
        confirm_outbound_availability "${SELECTED_OUTBOUND_MODE}" || { MENU_RETURNED="1"; continue; }
        backup_inbound_routes_for_change
        TEMP_IR="$(mktemp /tmp/vvr-iroutes-new.XXXXXX)"
        awk -F '|' -v tag="${TARGET_IB}" '$1 != tag && NF {print}' "${INBOUND_ROUTES_FILE}" > "${TEMP_IR}"
        printf '%s|%s\n' "${TARGET_IB}" "${SELECTED_OUTBOUND_MODE}" >> "${TEMP_IR}"
        mv "${TEMP_IR}" "${INBOUND_ROUTES_FILE}"
        chmod 0600 "${INBOUND_ROUTES_FILE}"
        apply_config || true
        ;;
      2)
        IR_CNT="$(inbound_routes_count)"
        if [ "${IR_CNT}" -eq 0 ]; then
          echo "暂无可删除的协议覆盖。"
        else
          printf '输入要删除的编号（0 取消）: '
          read -r DEL_IDX
          case "${DEL_IDX}" in
            0|q|Q|'') MENU_RETURNED="1"; continue ;;
            *[!0-9]*) echo "无效编号。" ;;
            *)
              if [ "${DEL_IDX}" -ge 1 ] && [ "${DEL_IDX}" -le "${IR_CNT}" ]; then
                backup_inbound_routes_for_change
                TEMP_IR="$(mktemp /tmp/vvr-iroutes-new.XXXXXX)"
                awk -F '|' -v target="${DEL_IDX}" '$1 != "" && $2 != "" {count++} count != target {print}' "${INBOUND_ROUTES_FILE}" > "${TEMP_IR}"
                mv "${TEMP_IR}" "${INBOUND_ROUTES_FILE}"
                chmod 0600 "${INBOUND_ROUTES_FILE}"
                apply_config || true
              else
                echo "编号超出范围。"
              fi
              ;;
          esac
        fi
        ;;
      0|q|Q) return 0 ;;
      *) echo "无效选择。" ;;
    esac
    if [ "${MENU_RETURNED:-0}" = "1" ]; then
      MENU_RETURNED="0"
      continue
    fi
    pause_menu
  done
}

toggle_private_ip_block() {
  load_state
  echo
  if [ "${BLOCK_PRIVATE_IP}" = "1" ]; then
    echo "当前状态：已开启（默认拦截 127.0.0.0/8、10.0.0.0/8、172.16.0.0/12、192.168.0.0/16、169.254.0.0/16、::1 等内网/元数据 IP）"
    printf '是否关闭内网 / 回环 IP 屏蔽？（若需通过本机访问内网服务才建议关闭）[y/N]: '
    read -r ANS
    case "${ANS}" in y|Y|yes|YES) BLOCK_PRIVATE_IP="0" ;; *) MENU_RETURNED="1"; return 0 ;; esac
  else
    echo "当前状态：已关闭（domainStrategy=AsIs）"
    printf '是否开启内网 / 回环 IP 屏蔽保护？（推荐开启，防 SSRF 与回环探测）[Y/n]: '
    read -r ANS
    case "${ANS:-Y}" in y|Y|yes|YES) BLOCK_PRIVATE_IP="1" ;; *) MENU_RETURNED="1"; return 0 ;; esac
  fi
  apply_config || true
}

delete_rule() {
  ensure_routes_file
  list_rules
  COUNT="$(awk 'NF {count++} END {print count+0}' "${ROUTES_FILE}")"
  [ "${COUNT}" -gt 0 ] || return 0
  while :; do
    printf '输入要删除的规则编号（0 取消）: '
    read -r INPUT
    case "${INPUT}" in
      0) MENU_RETURNED="1"; return 0 ;;
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
  choose_outbound_mode "${BASE_OUTBOUND_MODE}" 1 || { MENU_RETURNED="1"; return 0; }
  confirm_outbound_availability "${SELECTED_OUTBOUND_MODE}" || { MENU_RETURNED="1"; return 0; }
  if [ "${SELECTED_OUTBOUND_MODE}" = "${BASE_OUTBOUND_MODE}" ]; then
    echo "基础出站未改变。"
    return 0
  fi
  BASE_OUTBOUND_MODE="${SELECTED_OUTBOUND_MODE}"
  apply_config || true
}

set_happy_eyeballs_delay() {
  load_state
  while :; do
    printf 'Happy Eyeballs 连接竞速延迟（25-2000 毫秒，0 返回）[%s]: ' "${HAPPY_EYEBALLS_DELAY_MS}"
    read -r INPUT
    [ "${INPUT}" != "0" ] || { MENU_RETURNED="1"; return 0; }
    INPUT="${INPUT:-${HAPPY_EYEBALLS_DELAY_MS}}"
    case "${INPUT}" in ''|*[!0-9]*) echo "请输入整数。"; continue ;; esac
    if [ "${INPUT}" -ge 25 ] && [ "${INPUT}" -le 2000 ]; then break; fi
    echo "延迟必须在 25 到 2000 毫秒之间。"
  done
  HAPPY_EYEBALLS_DELAY_MS="${INPUT}"
  apply_config || true
}

test_url_routing() {
  load_state
  ensure_routes_file
  while :; do
    printf '输入测试 URL（例如 https://www.youtube.com/，输入 0 返回）: '
    read -r TEST_URL
    case "${TEST_URL}" in
      0) MENU_RETURNED="1"; return 0 ;;
      http://*|https://*)
        case "${TEST_URL}" in *[[:space:]]*) echo "URL 不能包含空格。" ;; *) break ;; esac
        ;;
      *) echo "请输入以 http:// 或 https:// 开头的 URL。" ;;
    esac
  done

  TEST_PORT=""
  ATTEMPT=0
  while [ "${ATTEMPT}" -lt 20 ]; do
    CAND=$((39000 + (($$ + ATTEMPT) % 1000)))
    if check_port_available "${CAND}" ""; then
      TEST_PORT="${CAND}"
      break
    fi
    ATTEMPT=$((ATTEMPT + 1))
  done
  if [ -z "${TEST_PORT}" ]; then
    warn "无法找到可用的本地测试端口。"
    return 1
  fi

  TEST_WORK="$(mktemp -d /tmp/vvr-route-test.XXXXXX)"
  TEST_CFG="${TEST_WORK}/config.json"
  TEST_ACC="${TEST_WORK}/access.log"
  TEST_ERR="${TEST_WORK}/error.log"
  TEST_RUN="${TEST_WORK}/runtime.log"

  TEST_RULE_OUTBOUNDS=""
  TEST_ROUTING_RULES=""
  TEST_RULE_MAP=""
  RULE_NUM=0
  build_custom_outbounds_json
  while IFS='|' read -r R_MODE R_TYPE R_VAL; do
    [ -n "${R_MODE}" ] || continue
    RULE_NUM=$((RULE_NUM + 1))
    case "${R_TYPE}" in
      domain) R_DOM="${R_VAL}" ;;
      geosite) R_DOM="geosite:${R_VAL}" ;;
      *) continue ;;
    esac
    R_TAG="test-rule-${RULE_NUM}"
    R_SOCKOPT=""
    case "${R_MODE}" in
      ipv4) R_STRAT="UseIPv4"; TEST_RULE_OUTBOUNDS="${TEST_RULE_OUTBOUNDS}    {\"protocol\": \"freedom\", \"tag\": \"${R_TAG}\", \"streamSettings\": {\"sockopt\": {\"domainStrategy\": \"${R_STRAT}\"}}},
" ;;
      ipv6) R_STRAT="UseIPv6"; TEST_RULE_OUTBOUNDS="${TEST_RULE_OUTBOUNDS}    {\"protocol\": \"freedom\", \"tag\": \"${R_TAG}\", \"streamSettings\": {\"sockopt\": {\"domainStrategy\": \"${R_STRAT}\"}}},
" ;;
      ipv4v6) R_STRAT="UseIPv4v6"; TEST_RULE_OUTBOUNDS="${TEST_RULE_OUTBOUNDS}    {\"protocol\": \"freedom\", \"tag\": \"${R_TAG}\", \"streamSettings\": {\"sockopt\": {\"domainStrategy\": \"${R_STRAT}\"}}},
" ;;
      ipv6v4) R_STRAT="UseIPv6v4"; TEST_RULE_OUTBOUNDS="${TEST_RULE_OUTBOUNDS}    {\"protocol\": \"freedom\", \"tag\": \"${R_TAG}\", \"streamSettings\": {\"sockopt\": {\"domainStrategy\": \"${R_STRAT}\"}}},
" ;;
      happy4v6) R_STRAT="UseIPv4v6"; TEST_RULE_OUTBOUNDS="${TEST_RULE_OUTBOUNDS}    {\"protocol\": \"freedom\", \"tag\": \"${R_TAG}\", \"streamSettings\": {\"sockopt\": {\"domainStrategy\": \"${R_STRAT}\", \"happyEyeballs\": {\"tryDelayMs\": ${HAPPY_EYEBALLS_DELAY_MS}, \"prioritizeIPv6\": false}}}},
" ;;
      happy6v4) R_STRAT="UseIPv6v4"; TEST_RULE_OUTBOUNDS="${TEST_RULE_OUTBOUNDS}    {\"protocol\": \"freedom\", \"tag\": \"${R_TAG}\", \"streamSettings\": {\"sockopt\": {\"domainStrategy\": \"${R_STRAT}\", \"happyEyeballs\": {\"tryDelayMs\": ${HAPPY_EYEBALLS_DELAY_MS}, \"prioritizeIPv6\": true}}}},
" ;;
      block)
        TEST_RULE_OUTBOUNDS="${TEST_RULE_OUTBOUNDS}    {\"protocol\": \"blackhole\", \"tag\": \"${R_TAG}\"},
"
        ;;
      *)
        if custom_outbound_exists "${R_MODE}"; then
          R_OB_LINE="$(awk -F '|' -v tag="${R_MODE}" '$1 == tag && $2 != "" {print; exit}' "${OUTBOUNDS_FILE}")"
          R_OB_PROTO="$(printf '%s' "${R_OB_LINE}" | cut -d'|' -f2)"
          R_OB_ADDR="$(printf '%s' "${R_OB_LINE}" | cut -d'|' -f3)"
          R_OB_PORT="$(printf '%s' "${R_OB_LINE}" | cut -d'|' -f4)"
          R_OB_F5="$(printf '%s' "${R_OB_LINE}" | cut -d'|' -f5)"
          R_OB_F6="$(printf '%s' "${R_OB_LINE}" | cut -d'|' -f6)"
          case "${R_OB_PROTO}" in
            ss)
              TEST_RULE_OUTBOUNDS="${TEST_RULE_OUTBOUNDS}    {\"protocol\": \"shadowsocks\", \"tag\": \"${R_TAG}\", \"settings\": {\"servers\": [{\"address\": \"${R_OB_ADDR}\", \"port\": ${R_OB_PORT}, \"method\": \"${R_OB_F5}\", \"password\": \"${R_OB_F6}\"}]}},
"
              ;;
            socks)
              if [ -n "${R_OB_F5}" ]; then
                TEST_RULE_OUTBOUNDS="${TEST_RULE_OUTBOUNDS}    {\"protocol\": \"socks\", \"tag\": \"${R_TAG}\", \"settings\": {\"servers\": [{\"address\": \"${R_OB_ADDR}\", \"port\": ${R_OB_PORT}, \"users\": [{\"user\": \"${R_OB_F5}\", \"pass\": \"${R_OB_F6}\"}]}]}},
"
              else
                TEST_RULE_OUTBOUNDS="${TEST_RULE_OUTBOUNDS}    {\"protocol\": \"socks\", \"tag\": \"${R_TAG}\", \"settings\": {\"servers\": [{\"address\": \"${R_OB_ADDR}\", \"port\": ${R_OB_PORT}}]}},
"
              fi
              ;;
            *) continue ;;
          esac
        else
          continue
        fi
        ;;
    esac
    TEST_ROUTING_RULES="${TEST_ROUTING_RULES}      {\"type\": \"field\", \"domain\": [\"${R_DOM}\"], \"outboundTag\": \"${R_TAG}\"},
"
    TEST_RULE_MAP="${TEST_RULE_MAP}${R_TAG}|${R_MODE}|${R_TYPE}|${R_VAL}
"
  done < "${ROUTES_FILE}"

  TEST_BASE_TAG="$(outbound_tag_for_mode "${BASE_OUTBOUND_MODE}")"
  cat > "${TEST_CFG}" <<TCFG
{
  "log": {"loglevel": "info", "access": "${TEST_ACC}", "error": "${TEST_ERR}"},
  "inbounds": [{"listen": "127.0.0.1", "port": ${TEST_PORT}, "protocol": "socks", "tag": "rule-test-in", "settings": {"udp": false}}],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct-ipv4", "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4"}}},
    {"protocol": "freedom", "tag": "direct-ipv6", "streamSettings": {"sockopt": {"domainStrategy": "UseIPv6"}}},
    {"protocol": "freedom", "tag": "direct-ipv4v6", "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4v6"}}},
    {"protocol": "freedom", "tag": "direct-ipv6v4", "streamSettings": {"sockopt": {"domainStrategy": "UseIPv6v4"}}},
    {"protocol": "freedom", "tag": "direct-happy-ipv4v6", "streamSettings": {"sockopt": {"domainStrategy": "UseIPv4v6", "happyEyeballs": {"tryDelayMs": ${HAPPY_EYEBALLS_DELAY_MS}, "prioritizeIPv6": false}}}},
    {"protocol": "freedom", "tag": "direct-happy-ipv6v4", "streamSettings": {"sockopt": {"domainStrategy": "UseIPv6v4", "happyEyeballs": {"tryDelayMs": ${HAPPY_EYEBALLS_DELAY_MS}, "prioritizeIPv6": true}}}},
${CUSTOM_OUTBOUNDS_JSON}${TEST_RULE_OUTBOUNDS}    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
${TEST_ROUTING_RULES}      {"type": "field", "inboundTag": ["rule-test-in"], "outboundTag": "${TEST_BASE_TAG}"}
    ]
  }
}
TCFG

  if ! XRAY_LOCATION_ASSET="${XRAY_DIR}" "${XRAY_BIN}" run -test -config "${TEST_CFG}" >/dev/null 2>&1; then
    warn "临时测试配置校验失败。"
    rm -rf "${TEST_WORK}"
    return 1
  fi

  info "通过本地临时 SOCKS 实例测试规则命中..."
  XRAY_LOCATION_ASSET="${XRAY_DIR}" "${XRAY_BIN}" run -config "${TEST_CFG}" >"${TEST_RUN}" 2>&1 &
  TEST_PID=$!
  sleep 1
  if ! kill -0 "${TEST_PID}" >/dev/null 2>&1; then
    warn "临时测试实例启动失败。"
    cat "${TEST_RUN}" >&2
    rm -rf "${TEST_WORK}"
    return 1
  fi

  HTTP_OK=1
  if ! HTTP_CODE="$(curl -sS --proxy "socks5h://127.0.0.1:${TEST_PORT}" --connect-timeout 8 --max-time 20 -o /dev/null -w '%{http_code}' "${TEST_URL}" 2>&1)"; then
    HTTP_OK=0
  fi
  sleep 1
  kill "${TEST_PID}" >/dev/null 2>&1 || true
  wait "${TEST_PID}" >/dev/null 2>&1 || true

  ACTUAL_TAG="$({
    sed -n 's/.*\[rule-test-in \(->\|>>\) \([^]]*\)\].*/\2/p' "${TEST_ACC}" "${TEST_RUN}" 2>/dev/null || true
  } | tail -n 1)"
  if [ -z "${ACTUAL_TAG}" ]; then
    ACTUAL_TAG="$({ grep -Eo 'test-rule-[0-9]+|direct-happy-ipv(4v6|6v4)|direct-ipv(4v6|6v4|4|6)|proxy-[A-Za-z0-9._-]+' "${TEST_ACC}" 2>/dev/null || true; grep -Eo 'test-rule-[0-9]+|direct-happy-ipv(4v6|6v4)|direct-ipv(4v6|6v4|4|6)|proxy-[A-Za-z0-9._-]+' "${TEST_RUN}" 2>/dev/null || true; } | tail -n 1)"
  fi
  echo
  echo "测试 URL：${TEST_URL}"
  if [ "${HTTP_OK}" = "1" ]; then
    echo "HTTP 状态码：${HTTP_CODE}"
  else
    warn "请求失败：${HTTP_CODE}"
  fi
  case "${ACTUAL_TAG}" in
    test-rule-*)
      MATCHED_LINE="$(printf '%s' "${TEST_RULE_MAP}" | awk -F'|' -v tag="${ACTUAL_TAG}" '$1 == tag {print; exit}')"
      if [ -n "${MATCHED_LINE}" ]; then
        M_MODE="$(printf '%s' "${MATCHED_LINE}" | cut -d'|' -f2)"
        M_TYPE="$(printf '%s' "${MATCHED_LINE}" | cut -d'|' -f3)"
        M_VAL="$(printf '%s' "${MATCHED_LINE}" | cut -d'|' -f4)"
        echo "命中规则 #${ACTUAL_TAG#test-rule-}：${M_TYPE} ${M_VAL}"
        echo "规则出站：$(outbound_mode_label "${M_MODE}")"
      fi
      ;;
    direct-happy-ipv4v6)
      echo "命中规则：基础出站（$(outbound_mode_label happy4v6)）"
      ;;
    direct-happy-ipv6v4)
      echo "命中规则：基础出站（$(outbound_mode_label happy6v4)）"
      ;;
    direct-ipv*)
      echo "命中规则：基础出站（$(outbound_mode_label "${ACTUAL_TAG#direct-}")）"
      ;;
    block)
      echo "命中规则：屏蔽 / 丢弃 (block)"
      ;;
    *)
      if [ -n "${ACTUAL_TAG}" ] && custom_outbound_exists "${ACTUAL_TAG}" 2>/dev/null; then
        echo "命中规则：基础出站（$(outbound_mode_label "${ACTUAL_TAG}")）"
      else
        warn "未能从测试日志识别命中的出站标签。"
      fi
      ;;
  esac
  rm -rf "${TEST_WORK}"
}

manage_outbound_menu() {
  while :; do
    load_state
    MENU_RETURNED="0"
    clear 2>/dev/null || true
    if [ "${BLOCK_PRIVATE_IP}" = "1" ]; then
      PRIV_LABEL="${GREEN}已开启${RESET}"
    else
      PRIV_LABEL="${YELLOW}已关闭${RESET}"
    fi
    echo "===================================================="
    echo " ${CYAN}出站策略、落地代理与三层分流${RESET}"
    echo "===================================================="
    echo " 公网地址：IPv4 $(ipv4_display) | IPv6 $(ipv6_display)"
    echo " 基础出站：$(outbound_mode_label "${BASE_OUTBOUND_MODE}") | 外部落地：$(custom_outbound_count) 个"
    echo " 三层分流：域名 $(rules_count) 条 | 用户覆盖 $(user_routes_count) 条 | 协议覆盖 $(inbound_routes_count) 条"
    echo " 安全保护：内网/回环 IP 屏蔽 ${PRIV_LABEL} | 竞速延迟：${HAPPY_EYEBALLS_DELAY_MS}ms"
    echo "----------------------------------------------------"
    echo "  1. 设置基础出站模式（第 4 层兜底默认）"
    echo "  2. 管理外部落地代理（Shadowsocks / Socks5 链式出站）"
    echo "  3. 查看全部域名 / Geosite 规则"
    echo "  4. 一键添加内置场景预设（AI / YouTube / 流媒体 / 去广告）"
    echo "  5. 添加域名规则（精确 / 后缀）"
    echo "  6. 添加 geosite 规则"
    echo "  7. 调整域名规则优先级顺序（上移 / 下移 / 置顶）"
    echo "  8. 删除域名规则"
    echo "  9. 按用户指定默认出站（第 2 层 user/email 覆盖）"
    echo " 10. 按协议入站指定默认出站（第 3 层 inboundTag 覆盖）"
    echo " 11. 切换内网 / 回环 IP 屏蔽保护（SSRF 防护）"
    echo " 12. 设置 Happy Eyeballs 竞速延迟"
    echo " 13. 按 URL 测试实际命中出站"
    echo " 14. 刷新公网 IPv4 / IPv6 状态"
    echo "  0. 返回主菜单（或输入 q）"
    echo "===================================================="
    printf '请选择操作: '
    read -r CHOICE || return 0
    [ -n "${CHOICE}" ] || continue
    case "${CHOICE}" in
      1) set_base_outbound_mode || true ;;
      2) manage_custom_outbounds_menu; MENU_RETURNED="1" ;;
      3) list_rules ;;
      4) add_preset_rule || true ;;
      5) add_domain_rule || true ;;
      6) add_geosite_rule || true ;;
      7) reorder_rule || true ;;
      8) delete_rule || true ;;
      9) manage_user_routes_menu; MENU_RETURNED="1" ;;
      10) manage_inbound_routes_menu; MENU_RETURNED="1" ;;
      11) toggle_private_ip_block || true ;;
      12) set_happy_eyeballs_delay || true ;;
      13) test_url_routing || true ;;
      14) refresh_network || true ;;
      0|q|Q) return 0 ;;
      *) echo "无效选择。" ;;
    esac
    if [ "${MENU_RETURNED:-0}" = "1" ]; then
      MENU_RETURNED="0"
      continue
    fi
    pause_menu
  done
}

# --- Optional traffic statistics & MiSub / 3X-UI API module ---

sync_traffic_paths() {
  case "${TRAFFIC_TOKEN_FILE}" in
    /etc/xray/*) [ "${CONFIG_DIR}" = "/etc/xray" ] || TRAFFIC_TOKEN_FILE="${CONFIG_DIR}/${TRAFFIC_TOKEN_FILE#/etc/xray/}" ;;
  esac
  case "${TRAFFIC_SETTINGS_FILE}" in
    /etc/xray/*) [ "${CONFIG_DIR}" = "/etc/xray" ] || TRAFFIC_SETTINGS_FILE="${CONFIG_DIR}/${TRAFFIC_SETTINGS_FILE#/etc/xray/}" ;;
  esac
  case "${TRAFFIC_API_SETTINGS_FILE}" in
    /etc/xray/*) [ "${CONFIG_DIR}" = "/etc/xray" ] || TRAFFIC_API_SETTINGS_FILE="${CONFIG_DIR}/${TRAFFIC_API_SETTINGS_FILE#/etc/xray/}" ;;
  esac
}

traffic_is_installed() {
  [ "${TRAFFIC_ENABLED:-0}" = "1" ] && [ -x "${TRAFFIC_SCRIPT}" ]
}

traffic_python_bin() {
  command -v python3 2>/dev/null || printf '%s' '/usr/bin/python3'
}

install_python3_dep() {
  PY_BIN="$(command -v python3 2>/dev/null || true)"
  if [ -n "${PY_BIN}" ] && "${PY_BIN}" -c 'import sqlite3' >/dev/null 2>&1; then
    return 0
  fi
  info "正在安装流量统计所需依赖（python3 + sqlite3）..."
  PAUSED_XRAY="0"
  if is_low_mem_host && service_is_running; then
    info "低内存环境：安装依赖期间临时暂停 Xray 以避免内存不足（安装后自动恢复）..."
    service_stop
    PAUSED_XRAY="1"
  fi
  INSTALL_PY_OK="0"
  case "${OS_TYPE}" in
    alpine)
      apk add --no-cache python3 && INSTALL_PY_OK="1" || INSTALL_PY_OK="0"
      ;;
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq && apt-get install -y -qq python3 && INSTALL_PY_OK="1" || INSTALL_PY_OK="0"
      ;;
  esac
  if [ "${PAUSED_XRAY}" = "1" ]; then
    service_start >/dev/null 2>&1 || true
  fi
  [ "${INSTALL_PY_OK}" = "1" ] || return 1
  PY_BIN="$(command -v python3 2>/dev/null || true)"
  [ -n "${PY_BIN}" ] && "${PY_BIN}" -c 'import sqlite3' >/dev/null 2>&1
}

traffic_api_is_running() {
  case "${INIT_TYPE}" in
    systemd) systemctl is-active --quiet vvr-traffic-api.service >/dev/null 2>&1 ;;
    openrc) rc-service vvr-traffic-api status >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

traffic_api_restart() {
  case "${INIT_TYPE}" in
    systemd)
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable --now vvr-traffic-api.service >/dev/null 2>&1 || true
      systemctl restart vvr-traffic-api.service
      ;;
    openrc)
      rc-update add vvr-traffic-api default >/dev/null 2>&1 || true
      rc-service vvr-traffic-api restart
      ;;
    *) return 1 ;;
  esac
}

traffic_collector_is_active() {
  case "${INIT_TYPE}" in
    systemd) systemctl is-active --quiet vvr-traffic-collector.timer >/dev/null 2>&1 ;;
    openrc) [ -f /etc/crontabs/root ] && grep -Fq "${TRAFFIC_OPENRC_CRON_MARKER}" /etc/crontabs/root ;;
    *) return 1 ;;
  esac
}

traffic_collector_enable() {
  case "${INIT_TYPE}" in
    systemd)
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable --now vvr-traffic-collector.timer
      ;;
    openrc)
      PY_BIN="$(traffic_python_bin)"
      mkdir -p /etc/crontabs
      CRON_TMP="$(mktemp /tmp/vvr-cron.XXXXXX)"
      if [ -f /etc/crontabs/root ]; then
        grep -Fv "${TRAFFIC_OPENRC_CRON_MARKER}" /etc/crontabs/root > "${CRON_TMP}" || true
      fi
      printf '* * * * * VVR_TRAFFIC_DB=%s VVR_XRAY_BIN=%s VVR_XRAY_API=127.0.0.1:%s VVR_TRAFFIC_TOKEN_FILE=%s VVR_TRAFFIC_SETTINGS_FILE=%s %s %s --collect >/dev/null 2>&1 %s\n' \
        "${TRAFFIC_DB}" "${XRAY_BIN}" "${XRAY_API_PORT:-${DEFAULT_XRAY_API_PORT}}" "${TRAFFIC_TOKEN_FILE}" "${TRAFFIC_SETTINGS_FILE}" \
        "${PY_BIN}" "${TRAFFIC_SCRIPT}" "${TRAFFIC_OPENRC_CRON_MARKER}" >> "${CRON_TMP}"
      mv "${CRON_TMP}" /etc/crontabs/root
      chmod 0600 /etc/crontabs/root
      rc-update add crond default >/dev/null 2>&1 || true
      rc-service crond start >/dev/null 2>&1 || true
      ;;
    *) return 1 ;;
  esac
}

traffic_collector_disable() {
  case "${INIT_TYPE}" in
    systemd)
      systemctl disable --now vvr-traffic-collector.timer >/dev/null 2>&1 || true
      ;;
    openrc)
      if [ -f /etc/crontabs/root ]; then
        CRON_TMP="$(mktemp /tmp/vvr-cron.XXXXXX)"
        grep -Fv "${TRAFFIC_OPENRC_CRON_MARKER}" /etc/crontabs/root > "${CRON_TMP}" || true
        mv "${CRON_TMP}" /etc/crontabs/root
        chmod 0600 /etc/crontabs/root
      fi
      ;;
  esac
}

load_traffic_settings() {
  sync_traffic_paths
  RESET_DAY="1"
  RESET_HOUR="0"
  RESET_MINUTE="0"
  COLLECTION_ENABLED="1"
  AUTO_RESET_ENABLED="1"
  if [ -f "${TRAFFIC_SETTINGS_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${TRAFFIC_SETTINGS_FILE}"
  fi
  case "${RESET_DAY}" in ''|*[!0-9]*) RESET_DAY="1" ;; esac
  [ "${RESET_DAY}" -ge 1 ] && [ "${RESET_DAY}" -le 28 ] || RESET_DAY="1"
  case "${RESET_HOUR}" in ''|*[!0-9]*) RESET_HOUR="0" ;; esac
  [ "${RESET_HOUR}" -le 23 ] || RESET_HOUR="0"
  case "${RESET_MINUTE}" in ''|*[!0-9]*) RESET_MINUTE="0" ;; esac
  [ "${RESET_MINUTE}" -le 59 ] || RESET_MINUTE="0"
  case "${COLLECTION_ENABLED}" in 0|false|no|off) COLLECTION_ENABLED="0" ;; *) COLLECTION_ENABLED="1" ;; esac
  case "${AUTO_RESET_ENABLED}" in 0|false|no|off) AUTO_RESET_ENABLED="0" ;; *) AUTO_RESET_ENABLED="1" ;; esac
}

save_traffic_settings() {
  sync_traffic_paths
  mkdir -p "$(dirname "${TRAFFIC_SETTINGS_FILE}")"
  cat > "${TRAFFIC_SETTINGS_FILE}" <<SETTINGS
RESET_DAY='${RESET_DAY}'
RESET_HOUR='${RESET_HOUR}'
RESET_MINUTE='${RESET_MINUTE}'
COLLECTION_ENABLED='${COLLECTION_ENABLED}'
AUTO_RESET_ENABLED='${AUTO_RESET_ENABLED}'
SETTINGS
  chmod 0600 "${TRAFFIC_SETTINGS_FILE}"
}

load_traffic_api_settings() {
  sync_traffic_paths
  TRAFFIC_API_HOST="127.0.0.1"
  unset VVR_TRAFFIC_API_HOST
  if [ -f "${TRAFFIC_API_SETTINGS_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${TRAFFIC_API_SETTINGS_FILE}"
  fi
  case "${VVR_TRAFFIC_API_HOST:-${TRAFFIC_API_HOST}}" in
    0.0.0.0) TRAFFIC_API_HOST="0.0.0.0" ;;
    *) TRAFFIC_API_HOST="127.0.0.1" ;;
  esac
}

traffic_schedule_label() {
  load_traffic_settings
  case "${AUTO_RESET_ENABLED}" in
    0|false|no|off) printf '%s' '已关闭（仅由 MiSub / 手动重置）' ;;
    *) printf '已开启（每月 %s 日 %02d:%02d）' "${RESET_DAY}" "${RESET_HOUR}" "${RESET_MINUTE}" ;;
  esac
}

traffic_auto_collection_label() {
  load_traffic_settings
  case "${COLLECTION_ENABLED}" in
    0|false|no|off) printf '%s' '已关闭（API 仅返回已保存数据）' ;;
    *) printf '%s' '已开启（每分钟自动采集）' ;;
  esac
}

traffic_api_binding_label() {
  load_traffic_api_settings
  case "${TRAFFIC_API_HOST}" in
    0.0.0.0) printf '0.0.0.0:%s（允许服务器 IPv4 访问）' "${TRAFFIC_API_PORT:-${DEFAULT_TRAFFIC_API_PORT}}" ;;
    *) printf '127.0.0.1:%s（仅本机访问）' "${TRAFFIC_API_PORT:-${DEFAULT_TRAFFIC_API_PORT}}" ;;
  esac
}

traffic_api_base_url() {
  load_traffic_api_settings
  T_PORT="${TRAFFIC_API_PORT:-${DEFAULT_TRAFFIC_API_PORT}}"
  if [ "${TRAFFIC_API_HOST}" = "0.0.0.0" ]; then
    if [ -n "${SERVER_IPV4:-}" ]; then
      printf 'http://%s:%s' "${SERVER_IPV4}" "${T_PORT}"
    else
      printf 'http://服务器IPv4地址:%s' "${T_PORT}"
    fi
  else
    printf 'http://127.0.0.1:%s' "${T_PORT}"
  fi
}

write_traffic_script() {
  sync_traffic_paths
  mkdir -p "${TRAFFIC_DIR}" "$(dirname "${TRAFFIC_SCRIPT}")" "${CONFIG_DIR}"
  chmod 0755 "${TRAFFIC_DIR}"
  cat > "${TRAFFIC_SCRIPT}" <<'PY'
#!/usr/bin/env python3
import argparse
from contextlib import closing, contextmanager
from datetime import datetime
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import sqlite3
import subprocess
import threading
from urllib.parse import parse_qs, urlparse

try:
    import fcntl
except ImportError:
    fcntl = None

DB = os.environ.get("VVR_TRAFFIC_DB", "/var/lib/vvr/traffic.db")
XRAY = os.environ.get("VVR_XRAY_BIN", "/usr/local/xray/xray")
API_SERVER = os.environ.get("VVR_XRAY_API", "127.0.0.1:10085")
TOKEN_FILE = os.environ.get("VVR_TRAFFIC_TOKEN_FILE", "/etc/xray/vvr-traffic.token")
SETTINGS_FILE = os.environ.get("VVR_TRAFFIC_SETTINGS_FILE", "/etc/xray/vvr-traffic-settings.env")
EXCLUDED_INBOUNDS = {"api", "reality-fallback"}
_THREAD_LOCK = threading.Lock()
_LAST_BREAKDOWN = ({}, {})


@contextmanager
def traffic_lock():
    with _THREAD_LOCK:
        if fcntl is None:
            yield
            return
        lock_path = DB + ".lock"
        os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)
        with open(lock_path, "a+", encoding="utf-8") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def reset_settings():
    settings = {"day": 1, "hour": 0, "minute": 0, "collection_enabled": True, "auto_reset_enabled": True}
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
                    elif key == "COLLECTION_ENABLED":
                        settings["collection_enabled"] = value.lower() not in ("0", "false", "no", "off")
                    elif key == "AUTO_RESET_ENABLED":
                        settings["auto_reset_enabled"] = value.lower() not in ("0", "false", "no", "off")
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
    os.makedirs(os.path.dirname(DB) or ".", exist_ok=True)
    db = sqlite3.connect(DB, timeout=10)
    db.execute(
        "CREATE TABLE IF NOT EXISTS traffic ("
        "id INTEGER PRIMARY KEY CHECK (id = 1), "
        "month TEXT NOT NULL, "
        "total_up INTEGER NOT NULL DEFAULT 0, "
        "total_down INTEGER NOT NULL DEFAULT 0, "
        "last_up INTEGER NOT NULL DEFAULT 0, "
        "last_down INTEGER NOT NULL DEFAULT 0, "
        "updated_at TEXT NOT NULL)"
    )
    db.execute(
        "CREATE TABLE IF NOT EXISTS traffic_breakdown ("
        "kind TEXT NOT NULL, "
        "name TEXT NOT NULL, "
        "month TEXT NOT NULL, "
        "total_up INTEGER NOT NULL DEFAULT 0, "
        "total_down INTEGER NOT NULL DEFAULT 0, "
        "last_up INTEGER NOT NULL DEFAULT 0, "
        "last_down INTEGER NOT NULL DEFAULT 0, "
        "updated_at TEXT NOT NULL, "
        "PRIMARY KEY (kind, name))"
    )
    return db


def xray_stats_all():
    try:
        result = subprocess.run(
            [XRAY, "api", "statsquery", "--server=" + API_SERVER],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        payload = json.loads(result.stdout)
    except Exception:
        return None, None, {}, {}

    inbounds = {}
    users = {}
    for item in payload.get("stat", []):
        name = item.get("name", "")
        val = int(item.get("value", 0))
        parts = name.split(">>>")
        if len(parts) != 4 or parts[2] != "traffic" or parts[3] not in ("uplink", "downlink"):
            continue
        scope, ident, _, direction = parts
        idx = 0 if direction == "uplink" else 1
        if scope == "inbound":
            if ident in EXCLUDED_INBOUNDS:
                continue
            pair = inbounds.setdefault(ident, [0, 0])
            pair[idx] = val
        elif scope == "user":
            pair = users.setdefault(ident, [0, 0])
            pair[idx] = val

    total_up = sum(pair[0] for pair in inbounds.values())
    total_down = sum(pair[1] for pair in inbounds.values())
    return (
        total_up,
        total_down,
        {k: (v[0], v[1]) for k, v in inbounds.items()},
        {k: (v[0], v[1]) for k, v in users.items()},
    )


def xray_stats():
    global _LAST_BREAKDOWN
    up, down, inbounds, users = xray_stats_all()
    _LAST_BREAKDOWN = (inbounds, users)
    return up, down


def _read_breakdown(db, period):
    inbounds = {}
    users = {}
    for kind, name, month, t_up, t_down in db.execute(
        "SELECT kind,name,month,total_up,total_down FROM traffic_breakdown ORDER BY name"
    ):
        if month != period:
            continue
        entry = {"up": t_up, "down": t_down, "total": t_up + t_down}
        if kind == "inbound":
            inbounds[name] = entry
        elif kind == "user":
            users[name] = entry
    return inbounds, users


def _update_breakdown(db, kind, stats_map, period, now):
    existing = {
        name: (month, t_up, t_down, l_up, l_down)
        for name, month, t_up, t_down, l_up, l_down in db.execute(
            "SELECT name,month,total_up,total_down,last_up,last_down FROM traffic_breakdown WHERE kind=?",
            (kind,),
        )
    }
    for name, (cur_up, cur_down) in stats_map.items():
        row = existing.get(name)
        if row is None:
            total_up = total_down = 0
            last_up = last_down = 0
        elif row[0] != period:
            total_up = total_down = 0
            last_up, last_down = row[3], row[4]
        else:
            _, total_up, total_down, last_up, last_down = row
        delta_up = cur_up - last_up if cur_up >= last_up else cur_up
        delta_down = cur_down - last_down if cur_down >= last_down else cur_down
        total_up += max(delta_up, 0)
        total_down += max(delta_down, 0)
        db.execute(
            "INSERT INTO traffic_breakdown(kind,name,month,total_up,total_down,last_up,last_down,updated_at) "
            "VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(kind,name) DO UPDATE SET "
            "month=excluded.month,total_up=excluded.total_up,total_down=excluded.total_down,"
            "last_up=excluded.last_up,last_down=excluded.last_down,updated_at=excluded.updated_at",
            (kind, name, period, total_up, total_down, cur_up, cur_down, now),
        )


def collect(force=False):
    global _LAST_BREAKDOWN
    with traffic_lock():
        now = datetime.now().isoformat(timespec="seconds")
        period = period_key()
        settings = reset_settings()
        with closing(db_connect()) as db:
            row = db.execute("SELECT month,total_up,total_down,last_up,last_down,updated_at FROM traffic WHERE id=1").fetchone()
            if not settings["auto_reset_enabled"]:
                period = row[0] if row is not None else now[:16].replace("T", " ")
            if not settings["collection_enabled"] and not force:
                if row is None or row[0] != period:
                    return {
                        "month": period[:7], "period_start": period,
                        "up": 0, "down": 0, "total": 0, "updated_at": "暂无",
                        "collection_enabled": False, "inbounds": {}, "users": {},
                    }
                ib_map, usr_map = _read_breakdown(db, period)
                return {
                    "month": period[:7], "period_start": period,
                    "up": row[1], "down": row[2], "total": row[1] + row[2],
                    "updated_at": row[5], "collection_enabled": False,
                    "inbounds": ib_map, "users": usr_map,
                }
            _LAST_BREAKDOWN = ({}, {})
            up, down = xray_stats()
            ib_stats, user_stats = _LAST_BREAKDOWN
            if up is None or down is None:
                if row is None or row[0] != period:
                    return {
                        "month": period[:7], "period_start": period,
                        "up": 0, "down": 0, "total": 0, "updated_at": "暂无",
                        "collection_enabled": settings["collection_enabled"],
                        "inbounds": {}, "users": {},
                    }
                ib_map, usr_map = _read_breakdown(db, period)
                return {
                    "month": period[:7], "period_start": period,
                    "up": row[1], "down": row[2], "total": row[1] + row[2],
                    "updated_at": row[5], "collection_enabled": settings["collection_enabled"],
                    "inbounds": ib_map, "users": usr_map,
                }
            if row is None:
                total_up = total_down = 0
                last_up = last_down = 0
            elif row[0] != period:
                total_up = total_down = 0
                last_up, last_down = row[3], row[4]
            else:
                _, total_up, total_down, last_up, last_down, _ = row
            delta_up = up - last_up if up >= last_up else up
            delta_down = down - last_down if down >= last_down else down
            total_up += max(delta_up, 0)
            total_down += max(delta_down, 0)
            db.execute(
                "INSERT INTO traffic(id,month,total_up,total_down,last_up,last_down,updated_at) "
                "VALUES(1,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET "
                "month=excluded.month,total_up=excluded.total_up,total_down=excluded.total_down,"
                "last_up=excluded.last_up,last_down=excluded.last_down,updated_at=excluded.updated_at",
                (period, total_up, total_down, up, down, now),
            )
            if ib_stats:
                _update_breakdown(db, "inbound", ib_stats, period, now)
            if user_stats:
                _update_breakdown(db, "user", user_stats, period, now)
            db.commit()
            ib_map, usr_map = _read_breakdown(db, period)
            return {
                "month": period[:7], "period_start": period,
                "up": total_up, "down": total_down, "total": total_up + total_down,
                "updated_at": now, "collection_enabled": settings["collection_enabled"],
                "inbounds": ib_map, "users": usr_map,
            }


def reset():
    global _LAST_BREAKDOWN
    with traffic_lock():
        _LAST_BREAKDOWN = ({}, {})
        up, down = xray_stats()
        ib_stats, user_stats = _LAST_BREAKDOWN
        if up is None or down is None:
            raise RuntimeError("xray stats unavailable")
        now = datetime.now().isoformat(timespec="seconds")
        settings = reset_settings()
        period = period_key() if settings["auto_reset_enabled"] else now[:16].replace("T", " ")
        with closing(db_connect()) as db:
            db.execute(
                "INSERT INTO traffic(id,month,total_up,total_down,last_up,last_down,updated_at) "
                "VALUES(1,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET "
                "month=excluded.month,total_up=0,total_down=0,"
                "last_up=excluded.last_up,last_down=excluded.last_down,updated_at=excluded.updated_at",
                (period, 0, 0, up, down, now),
            )
            db.execute("DELETE FROM traffic_breakdown")
            for name, (cur_up, cur_down) in ib_stats.items():
                db.execute(
                    "INSERT INTO traffic_breakdown(kind,name,month,total_up,total_down,last_up,last_down,updated_at) "
                    "VALUES('inbound',?,?,0,0,?,?,?)",
                    (name, period, cur_up, cur_down, now),
                )
            for name, (cur_up, cur_down) in user_stats.items():
                db.execute(
                    "INSERT INTO traffic_breakdown(kind,name,month,total_up,total_down,last_up,last_down,updated_at) "
                    "VALUES('user',?,?,0,0,?,?,?)",
                    (name, period, cur_up, cur_down, now),
                )
            db.commit()
        return {
            "month": period[:7], "period_start": period,
            "up": 0, "down": 0, "total": 0, "updated_at": now,
            "collection_enabled": settings["collection_enabled"],
            "inbounds": {}, "users": {},
        }


def read_token():
    try:
        with open(TOKEN_FILE, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


class Handler(BaseHTTPRequestHandler):
    def _authorized(self, query):
        token = read_token()
        if not token:
            return True
        authorization = self.headers.get("Authorization", "")
        bearer = authorization[7:].strip() if authorization.lower().startswith("bearer ") else ""
        api_key = self.headers.get("X-API-Key", "").strip()
        query_token = query.get("token", [""])[0].strip()
        supplied = bearer or api_key or query_token
        if not hmac.compare_digest(supplied, token):
            source = "bearer" if bearer else "x-api-key" if api_key else "query" if query_token else "missing"
            body = b"invalid token"
            self.send_response(403)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("X-VVR-Auth-Reason", source)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return False
        return True

    def _write_json(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _traffic_payload(self):
        return collect()

    def _xui_inbounds_payload(self):
        traffic = self._traffic_payload()
        return {
            "success": True,
            "obj": [{
                "id": 1,
                "remark": os.environ.get("VVR_INBOUND_REMARK", "vvr-multi-protocol"),
                "tag": "vvr-all",
                "protocol": "vless",
                "up": int(traffic.get("up", 0)),
                "down": int(traffic.get("down", 0)),
                "total": int(traffic.get("total", 0)),
                "enable": True,
            }],
        }

    def do_GET(self):
        query = parse_qs(urlparse(self.path).query)
        if not self._authorized(query):
            return
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path in ("/", "/api/traffic"):
            self._write_json(self._traffic_payload())
            return
        if path == "/panel/api/inbounds/list":
            self._write_json(self._xui_inbounds_payload())
            return
        self.send_error(404)

    def do_POST(self):
        query = parse_qs(urlparse(self.path).query)
        if not self._authorized(query):
            return
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path in ("/panel/api/inbounds/resetAllTraffics", "/api/traffic/reset"):
            try:
                result = reset()
            except Exception as error:
                self._write_json({"success": False, "msg": str(error)}, status=503)
                return
            self._write_json({"success": True, "obj": result})
            return
        self.send_error(404)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-API-Key")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    def log_message(self, *_):
        return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--collect", action="store_true")
    parser.add_argument("--reset", action="store_true")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--host", default=os.environ.get("VVR_TRAFFIC_API_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("VVR_TRAFFIC_API_PORT", "18080")))
    args = parser.parse_args()
    if args.reset:
        print(json.dumps(reset(), ensure_ascii=False))
    elif args.collect:
        print(json.dumps(collect(force=args.force), ensure_ascii=False))
    elif args.serve:
        ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
    else:
        parser.error("choose --collect, --reset, or --serve")


if __name__ == "__main__":
    main()
PY
  chmod 0755 "${TRAFFIC_SCRIPT}"
}

write_traffic_services() {
  sync_traffic_paths
  PY_BIN="$(traffic_python_bin)"
  T_PORT="${TRAFFIC_API_PORT:-${DEFAULT_TRAFFIC_API_PORT}}"
  X_PORT="${XRAY_API_PORT:-${DEFAULT_XRAY_API_PORT}}"
  if [ ! -s "${TRAFFIC_TOKEN_FILE}" ]; then
    openssl rand -hex 24 > "${TRAFFIC_TOKEN_FILE}"
  fi
  chmod 0600 "${TRAFFIC_TOKEN_FILE}"
  if [ ! -s "${TRAFFIC_SETTINGS_FILE}" ]; then
    cat > "${TRAFFIC_SETTINGS_FILE}" <<SETTINGS
RESET_DAY='1'
RESET_HOUR='0'
RESET_MINUTE='0'
COLLECTION_ENABLED='1'
AUTO_RESET_ENABLED='1'
SETTINGS
  fi
  chmod 0600 "${TRAFFIC_SETTINGS_FILE}"
  if [ ! -s "${TRAFFIC_API_SETTINGS_FILE}" ]; then
    cat > "${TRAFFIC_API_SETTINGS_FILE}" <<SETTINGS
VVR_TRAFFIC_API_HOST='127.0.0.1'
SETTINGS
  fi
  chmod 0600 "${TRAFFIC_API_SETTINGS_FILE}"

  case "${INIT_TYPE}" in
    systemd)
      cat > "${TRAFFIC_SYSTEMD_COLLECTOR_FILE}" <<EOF
[Unit]
Description=VVR Xray traffic collector
After=xray.service

[Service]
Type=oneshot
Environment=VVR_TRAFFIC_DB=${TRAFFIC_DB}
Environment=VVR_XRAY_BIN=${XRAY_BIN}
Environment=VVR_XRAY_API=127.0.0.1:${X_PORT}
Environment=VVR_TRAFFIC_TOKEN_FILE=${TRAFFIC_TOKEN_FILE}
Environment=VVR_TRAFFIC_SETTINGS_FILE=${TRAFFIC_SETTINGS_FILE}
ExecStart=${PY_BIN} ${TRAFFIC_SCRIPT} --collect
EOF
      cat > "${TRAFFIC_SYSTEMD_TIMER_FILE}" <<EOF
[Unit]
Description=Collect VVR Xray traffic every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Unit=vvr-traffic-collector.service

[Install]
WantedBy=timers.target
EOF
      cat > "${TRAFFIC_SYSTEMD_SERVICE_FILE}" <<EOF
[Unit]
Description=VVR traffic API
After=xray.service
Requires=xray.service

[Service]
Type=simple
Environment=VVR_TRAFFIC_DB=${TRAFFIC_DB}
Environment=VVR_XRAY_BIN=${XRAY_BIN}
Environment=VVR_XRAY_API=127.0.0.1:${X_PORT}
Environment=VVR_TRAFFIC_TOKEN_FILE=${TRAFFIC_TOKEN_FILE}
Environment=VVR_TRAFFIC_SETTINGS_FILE=${TRAFFIC_SETTINGS_FILE}
Environment=VVR_TRAFFIC_API_PORT=${T_PORT}
EnvironmentFile=-${TRAFFIC_API_SETTINGS_FILE}
ExecStart=${PY_BIN} ${TRAFFIC_SCRIPT} --serve --port ${T_PORT}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
      chmod 0644 "${TRAFFIC_SYSTEMD_COLLECTOR_FILE}" "${TRAFFIC_SYSTEMD_TIMER_FILE}" "${TRAFFIC_SYSTEMD_SERVICE_FILE}"
      ;;
    openrc)
      cat > "${TRAFFIC_OPENRC_SERVICE_FILE}" <<EOF
#!/sbin/openrc-run
description="VVR Xray traffic API"
command="${PY_BIN}"
command_args="${TRAFFIC_SCRIPT} --serve --port ${T_PORT}"
command_background="yes"
pidfile="/run/vvr-traffic-api.pid"
start_stop_daemon_args="--stdout /var/log/vvr-traffic.log --stderr /var/log/vvr-traffic.err"

depend() {
  need net
  after xray
}

start_pre() {
  export VVR_TRAFFIC_DB="${TRAFFIC_DB}"
  export VVR_XRAY_BIN="${XRAY_BIN}"
  export VVR_XRAY_API="127.0.0.1:${X_PORT}"
  export VVR_TRAFFIC_TOKEN_FILE="${TRAFFIC_TOKEN_FILE}"
  export VVR_TRAFFIC_SETTINGS_FILE="${TRAFFIC_SETTINGS_FILE}"
  export VVR_TRAFFIC_API_PORT="${T_PORT}"
  export VVR_TRAFFIC_API_HOST="127.0.0.1"
  [ -f "${TRAFFIC_API_SETTINGS_FILE}" ] && . "${TRAFFIC_API_SETTINGS_FILE}"
  export VVR_TRAFFIC_API_HOST
}
EOF
      chmod 0755 "${TRAFFIC_OPENRC_SERVICE_FILE}"
      ;;
  esac
}

remove_traffic_services() {
  traffic_collector_disable
  case "${INIT_TYPE}" in
    systemd)
      systemctl disable --now vvr-traffic-api.service >/dev/null 2>&1 || true
      rm -f "${TRAFFIC_SYSTEMD_SERVICE_FILE}" "${TRAFFIC_SYSTEMD_COLLECTOR_FILE}" "${TRAFFIC_SYSTEMD_TIMER_FILE}"
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-service vvr-traffic-api stop >/dev/null 2>&1 || true
      rc-update del vvr-traffic-api default >/dev/null 2>&1 || true
      rm -f "${TRAFFIC_OPENRC_SERVICE_FILE}" /var/log/vvr-traffic.log /var/log/vvr-traffic.err
      ;;
  esac
  rm -f "${TRAFFIC_SCRIPT}"
}

traffic_format_bytes() {
  awk -v bytes="${1:-0}" 'BEGIN {
    if (bytes < 1024) printf "%.0f B", bytes
    else if (bytes < 1048576) printf "%.2f KiB", bytes / 1024
    else if (bytes < 1073741824) printf "%.2f MiB", bytes / 1048576
    else if (bytes < 1099511627776) printf "%.2f GiB", bytes / 1073741824
    else printf "%.2f TiB", bytes / 1099511627776
  }'
}

traffic_api_get() {
  sync_traffic_paths
  MAX_T="${1:-4}"
  T_PORT="${TRAFFIC_API_PORT:-${DEFAULT_TRAFFIC_API_PORT}}"
  T_TOKEN="$(cat "${TRAFFIC_TOKEN_FILE}" 2>/dev/null | tr -d '\r\n' || true)"
  if [ -n "${T_TOKEN}" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "${T_TOKEN}" | \
      curl -fsS --max-time "${MAX_T}" -K - "http://127.0.0.1:${T_PORT}/api/traffic" 2>/dev/null || true
  else
    curl -fsS --max-time "${MAX_T}" "http://127.0.0.1:${T_PORT}/api/traffic" 2>/dev/null || true
  fi
}

traffic_dashboard_line() {
  if ! traffic_is_installed; then
    printf '%s' "${DIM}○ 未安装（选 8 可按需启用，默认零内存占用）${RESET}"
    return 0
  fi
  if ! traffic_api_is_running; then
    printf '%s' "${RED}● API 未运行${RESET}（选 8 检查）"
    return 0
  fi
  T_PAY="$(traffic_api_get 2)"
  PY_BIN="$(traffic_python_bin)"
  T_PARSED="$(printf '%s' "${T_PAY}" | "${PY_BIN}" -c 'import json,sys; d=json.load(sys.stdin); print("{}|{}|{}".format(d.get("up",0), d.get("down",0), d.get("total",0)))' 2>/dev/null || true)"
  if [ -n "${T_PARSED}" ]; then
    T_UP="$(printf '%s' "${T_PARSED}" | cut -d'|' -f1)"
    T_DN="$(printf '%s' "${T_PARSED}" | cut -d'|' -f2)"
    T_TOT="$(printf '%s' "${T_PARSED}" | cut -d'|' -f3)"
    printf '%s● 运行中%s | 本期 %s（↑%s / ↓%s）' "${GREEN}" "${RESET}" "$(traffic_format_bytes "${T_TOT}")" "$(traffic_format_bytes "${T_UP}")" "$(traffic_format_bytes "${T_DN}")"
  else
    printf '%s● 运行中%s | 端口 %s' "${GREEN}" "${RESET}" "${TRAFFIC_API_PORT:-${DEFAULT_TRAFFIC_API_PORT}}"
  fi
}

traffic_print_detailed() {
  T_PAY="$1"
  PY_BIN="$(traffic_python_bin)"
  printf '%s' "${T_PAY}" | "${PY_BIN}" -c '
import json, sys
def fmt(b):
    b = float(b or 0)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if b < 1024 or unit == "TiB":
            return "{:.0f} B".format(b) if unit == "B" else "{:.2f} {}".format(b, unit)
        b /= 1024
d = json.load(sys.stdin)
ce = "已开启" if d.get("collection_enabled") else "已关闭"
period = d.get("period_start") or d.get("month") or "未知"
updated = d.get("updated_at") or "暂无"
print(" 统计周期：{}".format(period))
print(" 整机总计：{}  （上传 {} / 下载 {}）".format(fmt(d.get("total", 0)), fmt(d.get("up", 0)), fmt(d.get("down", 0))))
print(" 更新时间：{} | 定时采集：{}".format(updated, ce))
ibs = d.get("inbounds") or {}
if ibs:
    print("\n [按协议入站明细]")
    for k, v in sorted(ibs.items()):
        print("   - {:<18} 合计 {:<12} (↑{} / ↓{})".format(k, fmt(v.get("total", 0)), fmt(v.get("up", 0)), fmt(v.get("down", 0))))
usrs = d.get("users") or {}
if usrs:
    print("\n [按用户 (email) 明细]")
    for k, v in sorted(usrs.items()):
        print("   - {:<18} 合计 {:<12} (↑{} / ↓{})".format(k, fmt(v.get("total", 0)), fmt(v.get("up", 0)), fmt(v.get("down", 0))))
' 2>/dev/null
}

show_traffic_status() {
  load_state
  if ! traffic_is_installed; then
    echo "流量统计模块尚未安装。"
    return 0
  fi
  echo
  if ! traffic_api_is_running; then
    warn "流量统计 API 服务当前未运行。"
  fi
  T_PAY="$(traffic_api_get 5)"
  if [ -n "${T_PAY}" ] && traffic_print_detailed "${T_PAY}"; then
    return 0
  fi
  warn "暂时无法读取流量数据，请确认 Xray 与流量统计 API 服务正常运行。"
  return 1
}

traffic_collect_now() {
  load_state
  traffic_is_installed || { echo "流量统计模块尚未安装。"; return 0; }
  PY_BIN="$(traffic_python_bin)"
  info "正在立即采集 Xray 流量计数器..."
  T_OUT="$(VVR_TRAFFIC_DB="${TRAFFIC_DB}" VVR_XRAY_BIN="${XRAY_BIN}" VVR_XRAY_API="127.0.0.1:${XRAY_API_PORT}" VVR_TRAFFIC_TOKEN_FILE="${TRAFFIC_TOKEN_FILE}" VVR_TRAFFIC_SETTINGS_FILE="${TRAFFIC_SETTINGS_FILE}" "${PY_BIN}" "${TRAFFIC_SCRIPT}" --collect --force 2>/dev/null || true)"
  if [ -n "${T_OUT}" ] && traffic_print_detailed "${T_OUT}"; then
    ok "流量采集完成。"
  else
    warn "流量采集失败，请确认 Xray 正常运行。"
  fi
}

traffic_reset_now() {
  load_state
  traffic_is_installed || { echo "流量统计模块尚未安装。"; return 0; }
  printf '确认将当前统计周期累计流量（含分协议与分用户统计）归零？[y/N]: '
  read -r ANS
  case "${ANS}" in y|Y|yes|YES) ;; *) MENU_RETURNED="1"; return 0 ;; esac
  PY_BIN="$(traffic_python_bin)"
  if VVR_TRAFFIC_DB="${TRAFFIC_DB}" VVR_XRAY_BIN="${XRAY_BIN}" VVR_XRAY_API="127.0.0.1:${XRAY_API_PORT}" VVR_TRAFFIC_TOKEN_FILE="${TRAFFIC_TOKEN_FILE}" VVR_TRAFFIC_SETTINGS_FILE="${TRAFFIC_SETTINGS_FILE}" "${PY_BIN}" "${TRAFFIC_SCRIPT}" --reset >/dev/null 2>&1; then
    ok "当前统计周期累计流量已归零。"
  else
    warn "流量统计重置失败，请确认 Xray 运行中。"
  fi
}

configure_traffic_schedule() {
  MENU_RETURNED="0"
  load_traffic_settings
  echo "当前每月自动重置：$(traffic_schedule_label)"
  case "${AUTO_RESET_ENABLED}" in
    0|false|no|off) SCH_DEF=2 ;;
    *) SCH_DEF=1 ;;
  esac
  while :; do
    echo "  1. 开启每月自动重置并设置时间"
    echo "  2. 关闭每月自动重置（仅由 MiSub / 手动重置）"
    echo "  0. 返回上一级"
    printf '请选择操作 [%s]: ' "${SCH_DEF}"
    read -r INPUT
    case "${INPUT:-${SCH_DEF}}" in
      1) break ;;
      2)
        AUTO_RESET_ENABLED="0"
        save_traffic_settings
        ok "每月自动重置已关闭，当前统计周期和累计流量将持续保留。"
        return 0
        ;;
      0|q|Q) MENU_RETURNED="1"; return 0 ;;
      *) echo "无效选择，请输入 0-2。" ;;
    esac
  done
  while :; do
    printf '每月重置日期（1-28，输入 0 返回）[%s]: ' "${RESET_DAY}"
    read -r INPUT
    [ "${INPUT}" != "0" ] || { MENU_RETURNED="1"; return 0; }
    T_DAY="${INPUT:-${RESET_DAY}}"
    case "${T_DAY}" in ''|*[!0-9]*) echo "日期无效。"; continue ;; esac
    if [ "${T_DAY}" -lt 1 ] || [ "${T_DAY}" -gt 28 ]; then echo "日期必须为 1 到 28。"; continue; fi

    printf '重置时间（HH:MM）[%02d:%02d]: ' "${RESET_HOUR}" "${RESET_MINUTE}"
    read -r INPUT
    INPUT="${INPUT:-$(printf '%02d:%02d' "${RESET_HOUR}" "${RESET_MINUTE}")}"
    case "${INPUT}" in
      [0-9][0-9]:[0-9][0-9]) T_HOUR="${INPUT%%:*}"; T_MIN="${INPUT##*:}" ;;
      *) echo "时间格式无效，请使用 HH:MM。"; continue ;;
    esac
    T_HVAL="${T_HOUR#0}"; [ -n "${T_HVAL}" ] || T_HVAL=0
    T_MVAL="${T_MIN#0}"; [ -n "${T_MVAL}" ] || T_MVAL=0
    if [ "${T_HVAL}" -gt 23 ] || [ "${T_MVAL}" -gt 59 ]; then echo "时间超出范围。"; continue; fi
    break
  done
  RESET_DAY="${T_DAY}"
  RESET_HOUR="${T_HVAL}"
  RESET_MINUTE="${T_MVAL}"
  AUTO_RESET_ENABLED="1"
  save_traffic_settings
  ok "每月自动重置已开启：每月 ${RESET_DAY} 日 $(printf '%02d:%02d' "${RESET_HOUR}" "${RESET_MINUTE}")（无需重启 Xray）。"
}

configure_traffic_collection() {
  MENU_RETURNED="0"
  load_traffic_settings
  case "${COLLECTION_ENABLED}" in
    0|false|no|off) echo "当前定时采集：已关闭"; COL_DEF=2 ;;
    *) echo "当前定时采集：已开启"; COL_DEF=1 ;;
  esac
  while :; do
    echo "  1. 开启定时流量采集（每分钟）"
    echo "  2. 关闭定时流量采集（API 仅返回已保存数据）"
    echo "  3. 立即手动采集一次"
    echo "  0. 返回上一级"
    printf '请选择操作 [%s]: ' "${COL_DEF}"
    read -r INPUT
    case "${INPUT:-${COL_DEF}}" in
      1) NEXT_COL="1"; break ;;
      2) NEXT_COL="0"; break ;;
      3) traffic_collect_now; return 0 ;;
      0|q|Q) MENU_RETURNED="1"; return 0 ;;
      *) echo "无效选择。" ;;
    esac
  done
  printf '确认修改流量采集开关？[Y/n]: '
  read -r ANS
  case "${ANS:-Y}" in y|Y|yes|YES) ;; *) echo "已取消。"; return 0 ;; esac
  COLLECTION_ENABLED="${NEXT_COL}"
  save_traffic_settings
  if [ "${NEXT_COL}" = "1" ]; then
    traffic_collector_enable && ok "定时流量采集已开启。" || warn "启动定时采集失败。"
  else
    traffic_collector_disable
    ok "定时流量采集已关闭（API 仍可读取已保存数据）。"
  fi
}

configure_traffic_api() {
  MENU_RETURNED="0"
  load_state
  load_traffic_api_settings
  echo "当前监听：$(traffic_api_binding_label)"
  while :; do
    echo "  1. 仅本机监听（127.0.0.1，推荐配合反向代理）"
    echo "  2. 允许公网 IPv4 访问（0.0.0.0，需自行放行端口并携带 Token）"
    echo "  3. 修改 API 监听端口（当前：${TRAFFIC_API_PORT}）"
    echo "  0. 返回上一级"
    printf '请选择操作: '
    read -r INPUT
    case "${INPUT}" in
      1)
        NEW_HOST="127.0.0.1"
        cat > "${TRAFFIC_API_SETTINGS_FILE}" <<SETTINGS
VVR_TRAFFIC_API_HOST='${NEW_HOST}'
SETTINGS
        chmod 0600 "${TRAFFIC_API_SETTINGS_FILE}"
        traffic_api_restart && ok "API 监听已切换为仅本机（127.0.0.1:${TRAFFIC_API_PORT}）。" || warn "API 服务重启失败。"
        return 0
        ;;
      2)
        warn "将监听 0.0.0.0:${TRAFFIC_API_PORT}，请确保防火墙仅对可信来源放行或配合 HTTPS 反代。"
        printf '确认切换为 0.0.0.0？[y/N]: '
        read -r ANS
        case "${ANS}" in y|Y|yes|YES) ;; *) return 0 ;; esac
        cat > "${TRAFFIC_API_SETTINGS_FILE}" <<SETTINGS
VVR_TRAFFIC_API_HOST='0.0.0.0'
SETTINGS
        chmod 0600 "${TRAFFIC_API_SETTINGS_FILE}"
        traffic_api_restart && ok "API 监听已切换为 0.0.0.0:${TRAFFIC_API_PORT}。" || warn "API 服务重启失败。"
        return 0
        ;;
      3)
        OLD_TP="${TRAFFIC_API_PORT}"
        while :; do
          prompt_port_value "流量统计 HTTP API " "${TRAFFIC_API_PORT}" 1 || { MENU_RETURNED="1"; return 0; }
          CAND_TP="${SELECTED_PORT}"
          port_conflicts_with_configured "${CAND_TP}" "traffic_api" "tcp" && continue
          check_port_available "${CAND_TP}" "${OLD_TP}" "tcp" || { echo "TCP 端口 ${CAND_TP} 已被占用。"; continue; }
          TRAFFIC_API_PORT="${CAND_TP}"
          break
        done
        save_state
        write_traffic_services
        traffic_api_restart && ok "流量 API 端口已修改为 ${TRAFFIC_API_PORT}。" || warn "API 服务重启失败。"
        return 0
        ;;
      0|q|Q) MENU_RETURNED="1"; return 0 ;;
      *) echo "无效选择。" ;;
    esac
  done
}

rotate_traffic_token() {
  sync_traffic_paths
  warn "重置后旧 API Token 将立即失效，MiSub 等外部面板需同步更新 Token。"
  printf '确认重置 API Token？[y/N]: '
  read -r ANS
  case "${ANS}" in y|Y|yes|YES) ;; *) MENU_RETURNED="1"; return 0 ;; esac
  NEW_TK="$(openssl rand -hex 24 2>/dev/null || true)"
  [ -n "${NEW_TK}" ] || { warn "生成新 Token 失败。"; return 1; }
  TMP_TK="$(mktemp /tmp/vvr-token.XXXXXX)"
  chmod 0600 "${TMP_TK}"
  printf '%s\n' "${NEW_TK}" > "${TMP_TK}"
  mv -f "${TMP_TK}" "${TRAFFIC_TOKEN_FILE}"
  chmod 0600 "${TRAFFIC_TOKEN_FILE}"
  traffic_api_restart || true
  ok "新 API Token 已生效：${NEW_TK}"
}

server_timezone_label() {
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl show --property=Timezone --value 2>/dev/null || date '+%Z'
  else
    date '+%Z'
  fi
}

configure_server_timezone() {
  MENU_RETURNED="0"
  echo "当前服务器时区：$(server_timezone_label)"
  echo "  1. Asia/Shanghai（中国标准时间）"
  echo "  2. UTC（协调世界时）"
  echo "  3. Europe/London（英国时间）"
  echo "  4. America/Los_Angeles（美国太平洋时间）"
  echo "  0. 返回上一级"
  printf '请选择服务器时区: '
  read -r TZ_IN
  case "${TZ_IN}" in
    1) TARGET_TZ="Asia/Shanghai" ;;
    2) TARGET_TZ="UTC" ;;
    3) TARGET_TZ="Europe/London" ;;
    4) TARGET_TZ="America/Los_Angeles" ;;
    0|q|Q|'') MENU_RETURNED="1"; return 0 ;;
    *) echo "无效选择。"; return 0 ;;
  esac
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "${TARGET_TZ}" && ok "服务器时区已更新为 ${TARGET_TZ}。" || warn "修改时区失败。"
  elif [ -f "/usr/share/zoneinfo/${TARGET_TZ}" ]; then
    ln -sf "/usr/share/zoneinfo/${TARGET_TZ}" /etc/localtime
    ok "服务器时区已更新为 ${TARGET_TZ}。"
  else
    warn "未找到时区数据 /usr/share/zoneinfo/${TARGET_TZ}，请先安装 tzdata。"
  fi
}

show_traffic_api_info() {
  load_state
  load_traffic_api_settings
  BASE_URL="$(traffic_api_base_url)"
  echo
  echo "=========================================="
  echo " 流量统计与 MiSub / 3X-UI 对接信息"
  echo "=========================================="
  echo " 监听地址      ：$(traffic_api_binding_label)"
  echo " VVR 详细接口  ：${BASE_URL}/api/traffic（含分协议与分用户明细）"
  echo " MiSub 面板地址：${BASE_URL}"
  echo " 3X-UI 兼容接口：${BASE_URL}/panel/api/inbounds/list"
  echo " 重置接口(POST)：${BASE_URL}/panel/api/inbounds/resetAllTraffics"
  echo " API Token     ：$(cat "${TRAFFIC_TOKEN_FILE}" 2>/dev/null || echo '未生成')"
  echo " 认证请求头    ：Authorization: Bearer <Token>（亦支持 ?token=<Token>）"
  echo " 入站 ID       ：1"
}

install_traffic_module() {
  load_state
  if traffic_is_installed; then
    echo "流量统计模块已安装并启用。"
    return 0
  fi
  echo
  echo "将安装可选【流量统计与 MiSub / 3X-UI API】模块："
  echo "  - 依赖：python3 + sqlite3（如未安装将自动安装）"
  echo "  - 能力：整机 + 分协议 + 分用户(email) 流量统计、每月自动重置、MiSub/3X-UI API"
  if is_low_mem_host; then
    warn "当前检测到低内存环境（<= 128 MiB），启用 Python 流量服务会额外占用约 15-25 MiB 内存。"
  fi
  printf '确认安装并启用流量统计模块？[Y/n]: '
  read -r ANS
  case "${ANS:-Y}" in y|Y|yes|YES) ;; *) MENU_RETURNED="1"; return 0 ;; esac

  while :; do
    prompt_port_value "流量统计 HTTP API " "${TRAFFIC_API_PORT:-${DEFAULT_TRAFFIC_API_PORT}}" 1 || { MENU_RETURNED="1"; return 0; }
    CAND_TP="${SELECTED_PORT}"
    port_conflicts_with_configured "${CAND_TP}" "traffic_api" "tcp" && continue
    check_port_available "${CAND_TP}" "" "tcp" || { echo "TCP 端口 ${CAND_TP} 已被占用，请换一个端口。"; continue; }
    TRAFFIC_API_PORT="${CAND_TP}"
    break
  done

  echo "选择 API 初始监听方式："
  echo "  1. 仅本机（127.0.0.1，安全默认，推荐反代或仅本机 vvr 查看）"
  echo "  2. 允许公网 IPv4（0.0.0.0，便于 MiSub 直接拉取，需携带 Token）"
  printf '请选择 [1]: '
  read -r BIND_IN
  case "${BIND_IN:-1}" in
    2) INIT_API_HOST="0.0.0.0" ;;
    *) INIT_API_HOST="127.0.0.1" ;;
  esac

  install_python3_dep || { warn "安装 python3 / sqlite3 失败，已取消启用流量统计模块。"; return 1; }

  TRAFFIC_ENABLED="1"
  if ! apply_config; then
    TRAFFIC_ENABLED="0"
    warn "启用 Xray 统计接口失败，已回滚。"
    return 1
  fi

  write_traffic_script
  sync_traffic_paths
  mkdir -p "${CONFIG_DIR}"
  cat > "${TRAFFIC_API_SETTINGS_FILE}" <<SETTINGS
VVR_TRAFFIC_API_HOST='${INIT_API_HOST}'
SETTINGS
  chmod 0600 "${TRAFFIC_API_SETTINGS_FILE}"
  write_traffic_services
  traffic_api_restart || warn "流量统计 API 启动失败，请检查服务日志。"
  traffic_collector_enable || warn "定时采集器启动失败。"
  ok "流量统计与 MiSub API 模块安装完成！"
  show_traffic_api_info
}

uninstall_traffic_module() {
  load_state
  if ! traffic_is_installed && [ "${TRAFFIC_ENABLED:-0}" != "1" ]; then
    echo "流量统计模块尚未安装。"
    return 0
  fi
  printf '确认卸载流量统计模块并关闭 Xray 内部 stats/api（恢复极简内存占用）？[y/N]: '
  read -r ANS
  case "${ANS}" in y|Y|yes|YES) ;; *) MENU_RETURNED="1"; return 0 ;; esac
  printf '是否同时删除历史流量数据库 %s？[y/N]: ' "${TRAFFIC_DB}"
  read -r DEL_DB
  remove_traffic_services
  TRAFFIC_ENABLED="0"
  apply_config || true
  case "${DEL_DB}" in
    y|Y|yes|YES) rm -rf "${TRAFFIC_DIR}" "${TRAFFIC_TOKEN_FILE}" "${TRAFFIC_SETTINGS_FILE}" "${TRAFFIC_API_SETTINGS_FILE}" ;;
  esac
  ok "流量统计模块已卸载关闭。"
}

manage_traffic_menu() {
  while :; do
    load_state
    MENU_RETURNED="0"
    clear 2>/dev/null || true
    echo "===================================================="
    echo " ${CYAN}流量统计与 MiSub / 3X-UI API（可选模块）${RESET}"
    echo "===================================================="
    if ! traffic_is_installed; then
      echo " 状态：${DIM}○ 未安装（默认不安装，零额外内存占用）${RESET}"
      echo " 特性：SQLite 累计统计 / 多协议与分用户(email) 明细"
      echo "       每月自动重置 / MiSub & 3X-UI 兼容 HTTP API"
      echo "----------------------------------------------------"
      echo "  1. 安装并启用流量统计与 MiSub API 模块"
      echo "  0. 返回主菜单（或输入 q）"
      echo "===================================================="
      printf '请选择操作: '
      read -r CHOICE || return 0
      [ -n "${CHOICE}" ] || continue
      case "${CHOICE}" in
        1) install_traffic_module || true ;;
        0|q|Q) return 0 ;;
        *) echo "无效选择。" ;;
      esac
    else
      echo " 状态    ：$(traffic_dashboard_line)"
      echo " API 监听：$(traffic_api_binding_label)"
      echo " 定时采集：$(traffic_auto_collection_label)"
      echo " 自动重置：$(traffic_schedule_label)"
      echo "----------------------------------------------------"
      echo "  1. 查看详细流量（整机 + 分协议 + 分用户明细）"
      echo "  2. 立即采集一次（手动同步计数器）"
      echo "  3. 重置当前统计周期累计流量"
      echo "  4. 查看 MiSub / 3X-UI 对接地址与 Token"
      echo "  5. 开启 / 关闭每月自动重置及设置时间"
      echo "  6. 开启 / 关闭定时流量采集"
      echo "  7. 设置 API 监听方式（127.0.0.1 / 0.0.0.0）与端口"
      echo "  8. 重置 API Token（旧 Token 立即失效）"
      echo "  9. 修改服务器时区（当前：$(server_timezone_label)）"
      echo " 10. 卸载并关闭流量统计模块（恢复零额外占用）"
      echo "  0. 返回主菜单（或输入 q）"
      echo "===================================================="
      printf '请选择操作: '
      read -r CHOICE || return 0
      [ -n "${CHOICE}" ] || continue
      case "${CHOICE}" in
        1) show_traffic_status || true ;;
        2) traffic_collect_now || true ;;
        3) traffic_reset_now || true ;;
        4) show_traffic_api_info ;;
        5) configure_traffic_schedule || true ;;
        6) configure_traffic_collection || true ;;
        7) configure_traffic_api || true ;;
        8) rotate_traffic_token || true ;;
        9) configure_server_timezone || true ;;
        10) uninstall_traffic_module || true ;;
        0|q|Q) return 0 ;;
        *) echo "无效选择。" ;;
      esac
    fi
    if [ "${MENU_RETURNED:-0}" = "1" ]; then
      MENU_RETURNED="0"
      continue
    fi
    pause_menu
  done
}

# --- Network refresh, service maintenance & updates ---

sync_protocol_hosts() {
  if xhttp_is_configured; then
    case "${XHTTP_FAMILY}" in
      ipv6) XHTTP_SERVER_HOST="${SERVER_IPV6:-}" ;;
      *) XHTTP_SERVER_HOST="${SERVER_IPV4:-}" ;;
    esac
  fi
  if hy2_is_configured; then
    case "${HY2_FAMILY}" in
      ipv6) HY2_SERVER_HOST="${SERVER_IPV6:-}" ;;
      *) HY2_SERVER_HOST="${SERVER_IPV4:-}" ;;
    esac
  fi
  if ss_is_configured; then
    case "${SS_FAMILY}" in
      ipv6) SS_SERVER_HOST="${SERVER_IPV6:-}" ;;
      *) SS_SERVER_HOST="${SERVER_IPV4:-}" ;;
    esac
  fi
}

refresh_network() {
  load_state
  info "检测服务器公网 IPv4 / IPv6 地址..."
  detect_network
  sync_protocol_hosts
  save_state
  ok "公网地址已更新："
  echo "  IPv4：$(ipv4_display)"
  echo "  IPv6：$(ipv6_display)"
}

restart_xray_interactive() {
  load_state
  if ! test_config; then
    warn "Xray 配置检查失败，未执行重启。"
    return 1
  fi
  if ! service_restart; then
    warn "Xray 服务重启失败。"
    return 1
  fi
  sleep 1
  if ! service_is_running; then
    warn "Xray 服务状态异常，请查看日志。"
    return 1
  fi
  ok "Xray 服务已重启并正常运行。"
}

manage_service_menu() {
  while :; do
    MENU_RETURNED="0"
    clear 2>/dev/null || true
    echo "===================================================="
    echo " ${CYAN}服务状态、端口监听、日志与网络刷新${RESET}"
    echo "===================================================="
    echo " 系统环境：$(os_label) | 内核：$(xray_version_short)"
    echo "----------------------------------------------------"
    echo "  1. 查看服务状态与监听端口"
    echo "  2. 重启 Xray 服务"
    echo "  3. 校验 Xray 配置文件（run -test）"
    echo "  4. 查看最近 80 行日志"
    echo "  5. 实时追踪日志（Ctrl+C 返回）"
    echo "  6. 刷新服务器公网 IPv4 / IPv6 地址"
    echo "  0. 返回主菜单（或输入 q）"
    echo "===================================================="
    printf '请选择操作: '
    read -r CHOICE || return 0
    [ -n "${CHOICE}" ] || continue
    case "${CHOICE}" in
      1)
        service_status_output
        echo
        show_listening_ports
        ;;
      2) restart_xray_interactive || true ;;
      3)
        if test_config; then
          ok "配置文件校验通过：${CONFIG_FILE}"
        else
          warn "配置文件存在错误。"
        fi
        ;;
      4) service_show_logs ;;
      5) service_follow_logs ;;
      6) refresh_network || true ;;
      0|q|Q) return 0 ;;
      *) echo "无效选择。" ;;
    esac
    if [ "${MENU_RETURNED:-0}" = "1" ]; then
      MENU_RETURNED="0"
      continue
    fi
    pause_menu
  done
}

valid_manager_source() {
  [ -f "$1" ] && sh -n "$1" >/dev/null 2>&1 && grep -Fq 'manager_main() {' "$1" && grep -Fq 'manage_hy2_menu() {' "$1" && grep -Fq 'manage_xhttp_menu() {' "$1"
}

fetch_manager_source() {
  FETCH_TARGET="$1"
  INSTALLER_URL="${VVR_INSTALLER_URL:-${DEFAULT_INSTALLER_URL}}"
  fetch_url "${INSTALLER_URL}" "${FETCH_TARGET}"
}

install_manager() {
  SCRIPT_NAME="${0##*/}"
  case "$0" in */*) SCRIPT_PARENT="${0%/*}" ;; *) SCRIPT_PARENT="." ;; esac
  SCRIPT_DIR="$(cd "${SCRIPT_PARENT}" 2>/dev/null && pwd || true)"
  SCRIPT_PATH=""
  [ -z "${SCRIPT_DIR}" ] || SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
  if ! valid_manager_source "${SCRIPT_PATH}"; then
    SCRIPT_PATH="${TMP_DIR}/vvr-manager-source.sh"
    info "正在获取 vvr 管理脚本..."
    if ! fetch_manager_source "${SCRIPT_PATH}" || ! valid_manager_source "${SCRIPT_PATH}"; then
      fail "无法获取有效的 vvr 管理程序；可通过 VVR_INSTALLER_URL 指定脚本地址。"
    fi
  fi
  install -m 0755 "${SCRIPT_PATH}" "${MANAGER_BIN}"
}

show_github_update_status() {
  info "检查 GitHub 最新提交：${GITHUB_REPO} (${GITHUB_BRANCH})"
  API_OUTPUT=""
  if command -v curl >/dev/null 2>&1; then
    API_OUTPUT="$(curl -fsSL --connect-timeout 10 --max-time 20 -H 'Accept: application/vnd.github+json' "${GITHUB_API_URL}/commits/${GITHUB_BRANCH}" 2>/dev/null || true)"
  elif command -v wget >/dev/null 2>&1; then
    API_OUTPUT="$(wget -qO- "${GITHUB_API_URL}/commits/${GITHUB_BRANCH}" 2>/dev/null || true)"
  fi
  COMMIT_SHA="$(printf '%s\n' "${API_OUTPUT}" | sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  COMMIT_DATE="$(printf '%s\n' "${API_OUTPUT}" | sed -n 's/^[[:space:]]*"date":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  COMMIT_MESSAGE="$(printf '%s\n' "${API_OUTPUT}" | sed -n 's/^[[:space:]]*"message":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [ -n "${COMMIT_SHA}" ]; then
    echo "远程提交：${COMMIT_SHA}"
    [ -z "${COMMIT_DATE}" ] || echo "提交时间：${COMMIT_DATE}"
    [ -z "${COMMIT_MESSAGE}" ] || echo "提交说明：${COMMIT_MESSAGE}"
    echo "项目地址：https://github.com/${GITHUB_REPO}/tree/${GITHUB_BRANCH}"
  else
    warn "无法获取 GitHub 提交信息，请检查网络或稍后重试。"
    return 1
  fi
}

upgrade_xray_core() {
  info "开始安全升级 Xray-core（保留所有配置、客户端与规则）..."
  prepare_tmp
  UPGRADE_BACKUP="${TMP_DIR}/xray-backup"
  mkdir -p "${UPGRADE_BACKUP}"
  [ -f "${XRAY_BIN}" ] && cp -a "${XRAY_BIN}" "${UPGRADE_BACKUP}/xray"
  [ -f "${XRAY_DIR}/geoip.dat" ] && cp -a "${XRAY_DIR}/geoip.dat" "${UPGRADE_BACKUP}/geoip.dat"
  [ -f "${XRAY_DIR}/geosite.dat" ] && cp -a "${XRAY_DIR}/geosite.dat" "${UPGRADE_BACKUP}/geosite.dat"

  detect_arch
  if ! download_xray; then
    cleanup
    warn "下载新版 Xray-core 失败，当前版本未受影响。"
    return 1
  fi
  if ! install_xray_files || ! test_config || ! service_restart; then
    warn "新版 Xray 验证或启动失败，正在回滚到旧版本..."
    [ -f "${UPGRADE_BACKUP}/xray" ] && install -m 0755 "${UPGRADE_BACKUP}/xray" "${XRAY_BIN}"
    [ -f "${UPGRADE_BACKUP}/geoip.dat" ] && install -m 0644 "${UPGRADE_BACKUP}/geoip.dat" "${XRAY_DIR}/geoip.dat"
    [ -f "${UPGRADE_BACKUP}/geosite.dat" ] && install -m 0644 "${UPGRADE_BACKUP}/geosite.dat" "${XRAY_DIR}/geosite.dat"
    service_restart >/dev/null 2>&1 || true
    cleanup
    warn "已恢复旧版 Xray。"
    return 1
  fi
  sleep 1
  if ! service_is_running; then
    warn "新版 Xray 服务状态异常，正在回滚到旧版本..."
    [ -f "${UPGRADE_BACKUP}/xray" ] && install -m 0755 "${UPGRADE_BACKUP}/xray" "${XRAY_BIN}"
    [ -f "${UPGRADE_BACKUP}/geoip.dat" ] && install -m 0644 "${UPGRADE_BACKUP}/geoip.dat" "${XRAY_DIR}/geoip.dat"
    [ -f "${UPGRADE_BACKUP}/geosite.dat" ] && install -m 0644 "${UPGRADE_BACKUP}/geosite.dat" "${XRAY_DIR}/geosite.dat"
    service_restart >/dev/null 2>&1 || true
    cleanup
    warn "已恢复旧版 Xray。"
    return 1
  fi
  cleanup
  NEW_VER="$("${XRAY_BIN}" version 2>/dev/null | head -n 1 || echo 'unknown')"
  ok "Xray-core 升级完成：${NEW_VER}"
}

update_manager_script() {
  UPDATE_TMP="$(mktemp /tmp/vvr-manager-update.XXXXXX)"
  if ! fetch_manager_source "${UPDATE_TMP}"; then
    rm -f "${UPDATE_TMP}"
    warn "下载最新 vvr 脚本失败。"
    return 1
  fi
  if ! valid_manager_source "${UPDATE_TMP}"; then
    rm -f "${UPDATE_TMP}"
    warn "远程脚本校验失败，未替换本地 vvr。"
    return 1
  fi
  install -m 0755 "${UPDATE_TMP}" "${MANAGER_BIN}"
  rm -f "${UPDATE_TMP}"
  ok "vvr 管理脚本已更新，即将重新载入..."
  exec "${MANAGER_BIN}" --manage
}

backup_config_snapshot() {
  BACKUP_DIR="${VVR_BACKUP_DIR:-/root}"
  mkdir -p "${BACKUP_DIR}"
  SNAP_FILE="${BACKUP_DIR}/vvr-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  if ! tar -czf "${SNAP_FILE}" -C "$(dirname "${CONFIG_DIR}")" "$(basename "${CONFIG_DIR}")" 2>/dev/null; then
    rm -f "${SNAP_FILE}"
    warn "创建配置备份失败。"
    return 1
  fi
  chmod 0600 "${SNAP_FILE}"
  ok "配置快照已保存：${SNAP_FILE}"
  echo "包含 ${CONFIG_DIR} 下全部配置、密钥、客户端列表、分流规则与证书。"
}

restore_config_snapshot() {
  BACKUP_DIR="${VVR_BACKUP_DIR:-/root}"
  echo
  echo "可用的配置备份快照（${BACKUP_DIR}/vvr-backup-*.tar.gz）："
  FOUND_ANY="0"
  for FILE in "${BACKUP_DIR}"/vvr-backup-*.tar.gz; do
    [ -f "${FILE}" ] || continue
    FOUND_ANY="1"
    echo "  - ${FILE}"
  done
  [ "${FOUND_ANY}" = "1" ] || echo "  （默认目录暂未发现快照文件）"
  echo
  printf '输入要恢复的 .tar.gz 完整路径（输入 0 返回）: '
  read -r RESTORE_PATH || { MENU_RETURNED="1"; return 0; }
  case "${RESTORE_PATH}" in ''|0|q|Q) MENU_RETURNED="1"; return 0 ;; esac
  if [ ! -f "${RESTORE_PATH}" ]; then
    warn "文件不存在：${RESTORE_PATH}"
    return 1
  fi
  printf '确认覆盖当前 %s 并重启 Xray？[y/N]: ' "${CONFIG_DIR}"
  read -r ANSWER || { MENU_RETURNED="1"; return 0; }
  case "${ANSWER}" in y|Y|yes|YES) ;; *) MENU_RETURNED="1"; return 0 ;; esac

  RESTORE_STAGE="$(mktemp -d /tmp/vvr-restore.XXXXXX)"
  if ! tar -xzf "${RESTORE_PATH}" -C "${RESTORE_STAGE}" 2>/dev/null || [ ! -f "${RESTORE_STAGE}/xray/config.json" ]; then
    rm -rf "${RESTORE_STAGE}"
    warn "备份文件格式无效（缺少 xray/config.json）。"
    return 1
  fi
  if ! XRAY_LOCATION_ASSET="${XRAY_DIR}" "${XRAY_BIN}" run -test -config "${RESTORE_STAGE}/xray/config.json" >/dev/null 2>&1; then
    rm -rf "${RESTORE_STAGE}"
    warn "备份中的 config.json 未通过 Xray 校验，未执行恢复。"
    return 1
  fi
  OLD_CFG_BAK="$(mktemp -d /tmp/vvr-restore-old.XXXXXX)"
  [ -d "${CONFIG_DIR}" ] && cp -a "${CONFIG_DIR}" "${OLD_CFG_BAK}/xray"
  rm -rf "${CONFIG_DIR}"
  cp -a "${RESTORE_STAGE}/xray" "${CONFIG_DIR}"
  chmod 0600 "${CONFIG_FILE}" "${META_FILE}" 2>/dev/null || true
  if ! service_restart || ! service_is_running; then
    rm -rf "${CONFIG_DIR}"
    [ -d "${OLD_CFG_BAK}/xray" ] && cp -a "${OLD_CFG_BAK}/xray" "${CONFIG_DIR}"
    service_restart >/dev/null 2>&1 || true
    rm -rf "${RESTORE_STAGE}" "${OLD_CFG_BAK}"
    warn "恢复后 Xray 启动失败，已回滚到原配置。"
    return 1
  fi
  rm -rf "${RESTORE_STAGE}" "${OLD_CFG_BAK}"
  ok "配置快照已恢复并生效！"
}

manage_updates_menu() {
  while :; do
    MENU_RETURNED="0"
    CUR_VER="$(xray_version_short)"
    clear 2>/dev/null || true
    echo "===================================================="
    echo " ${CYAN}内核升级、脚本更新、备份与卸载${RESET}"
    echo "===================================================="
    echo " 当前内核：${CUR_VER}"
    echo " 项目仓库：${GITHUB_REPO} (${GITHUB_BRANCH})"
    echo "----------------------------------------------------"
    echo "  1. 安全升级 Xray-core（保留全部配置）"
    echo "  2. 检查 GitHub 最新提交"
    echo "  3. 更新当前 vvr 管理脚本并重新载入"
    echo "  4. 备份当前配置快照（/etc/xray -> .tar.gz）"
    echo "  5. 从快照恢复配置（含校验与失败回滚）"
    echo "  6. ${RED}卸载并清理 VVR 与 Xray 环境（不可恢复）${RESET}"
    echo "  0. 返回主菜单（或输入 q）"
    echo "===================================================="
    printf '请选择操作: '
    read -r CHOICE || return 0
    [ -n "${CHOICE}" ] || continue
    case "${CHOICE}" in
      1) upgrade_xray_core || true ;;
      2) show_github_update_status || true ;;
      3) update_manager_script || true ;;
      4) backup_config_snapshot || true ;;
      5) restore_config_snapshot || true ;;
      6) uninstall_xray || true ;;
      0|q|Q) return 0 ;;
      *) echo "无效选择。" ;;
    esac
    if [ "${MENU_RETURNED:-0}" = "1" ]; then
      MENU_RETURNED="0"
      continue
    fi
    pause_menu
  done
}

uninstall_xray() {
  warn "即将卸载 Xray 与可选流量统计组件，并删除配置文件、客户端列表、分流规则、服务文件及 vvr 命令。"
  printf '确认卸载？此操作不可恢复。[y/N]: '
  read -r ANSWER
  case "${ANSWER}" in y|Y|yes|YES) ;; *) MENU_RETURNED="1"; return 0 ;; esac
  remove_traffic_services
  service_stop
  service_disable
  rm -f "${SERVICE_FILE}" "${MANAGER_BIN}"
  if [ "${INIT_TYPE}" = "openrc" ]; then
    rm -f "${LOG_FILE}" "${ERR_LOG_FILE}"
  else
    service_daemon_reload >/dev/null 2>&1 || true
  fi
  rm -rf "${CONFIG_DIR}" "${XRAY_DIR}" "${TRAFFIC_DIR}"
  ok "卸载完成。"
  exit 0
}

# --- Main management dashboard ---

manager_menu() {
  load_state
  clear 2>/dev/null || true
  if service_is_running; then
    SVC_STATE="${GREEN}● 运行中${RESET}"
  else
    SVC_STATE="${RED}● 未运行${RESET}"
  fi
  if vless_is_configured; then
    V4_C="$(client_count ipv4)"
    V6_C="$(client_count ipv6)"
    V_PORTS=""
    [ "${V4_C}" -eq 0 ] || [ -z "${IPV4_PORT}" ] || V_PORTS="v4:${IPV4_PORT}(${V4_C})"
    [ "${V6_C}" -eq 0 ] || [ -z "${IPV6_PORT}" ] || V_PORTS="${V_PORTS:+${V_PORTS} }v6:${IPV6_PORT}(${V6_C})"
    VLESS_SUMMARY="${GREEN}●${RESET} ${V_PORTS} | SNI:${SNI}"
  else
    VLESS_SUMMARY="${DIM}○ 未启用${RESET}"
  fi
  if xhttp_is_configured; then
    XHTTP_SUMMARY="${GREEN}●${RESET} ${XHTTP_BIND}:${XHTTP_PORT} | ${XHTTP_MODE} ($(xhttp_client_count) 客户端)"
  else
    XHTTP_SUMMARY="${DIM}○ 未启用${RESET}"
  fi
  if hy2_is_configured; then
    HY2_SUMMARY="${GREEN}●${RESET} ${HY2_BIND}:${HY2_PORT}/udp | ${HY2_CERT_MODE} ($(hy2_client_count) 客户端)"
  else
    HY2_SUMMARY="${DIM}○ 未启用${RESET}"
  fi
  if ss_is_configured; then
    SS_SUMMARY="${GREEN}●${RESET} ${SS_BIND}:${SS_PORT} | ${SS_METHOD} (${SS_NETWORK})"
  else
    SS_SUMMARY="${DIM}○ 未启用${RESET}"
  fi
  if [ "${BLOCK_PRIVATE_IP}" = "1" ]; then
    PRIV_TAG="内网屏蔽:开"
  else
    PRIV_TAG="内网屏蔽:关"
  fi
  ROUTE_SUM="$(outbound_mode_label "${BASE_OUTBOUND_MODE}") | 落地:$(custom_outbound_count) | 规则 $(rules_count)/$(user_routes_count)/$(inbound_routes_count) | ${PRIV_TAG}"

  echo "===================================================="
  echo " ${CYAN}${BOLD}VVR 通用四协议管理面板${RESET}  ${DIM}[$(os_label)]${RESET}"
  echo "===================================================="
  echo " 服务状态    ：${SVC_STATE}  |  Xray $(xray_version_short)"
  echo " 公网地址    ：IPv4 $(ipv4_display) | IPv6 $(ipv6_display)"
  echo " 放行端口    ：$(firewall_ports_summary)"
  echo "----------------------------------------------------"
  echo " VLESS-Vision：${VLESS_SUMMARY}"
  echo " VLESS-XHTTP ：${XHTTP_SUMMARY}"
  echo " Hysteria 2  ：${HY2_SUMMARY}"
  echo " Shadowsocks ：${SS_SUMMARY}"
  echo " 出站与防护  ：${ROUTE_SUM}"
  echo " 流量统计    ：$(traffic_dashboard_line)"
  echo "----------------------------------------------------"
  echo " ${BOLD}[快捷导出与用户]${RESET}"
  echo "   1. 一键查看纯链接（全选直接复制）"
  echo "   2. 节点导出与跨协议用户（按用户 / Base64 / YAML / 建用户）"
  echo " ${BOLD}[四协议入站管理]${RESET}"
  echo "   3. VLESS + Vision + REALITY 管理"
  echo "   4. VLESS + XHTTP + REALITY 管理"
  echo "   5. Hysteria 2 (UDP/QUIC) 管理"
  echo "   6. Shadowsocks 管理"
  echo " ${BOLD}[分流与流量统计]${RESET}"
  echo "   7. 出站策略、落地代理与三层分流"
  echo "   8. 流量统计与 MiSub API（可选模块）"
  echo " ${BOLD}[运维与升级]${RESET}"
  echo "   9. 服务状态、端口监听、日志与公网 IP 刷新"
  echo "  10. 内核升级、脚本更新、备份与卸载"
  echo "   0. 退出面板（或输入 q）"
  echo "===================================================="
  echo " ${DIM}快捷命令：vvr links | sub | yaml | user <名> | traffic | status | logs | backup${RESET}"
  printf '请选择操作: '
}

show_vvr_help() {
  cat <<HELP
用法：vvr [子命令]
  （无参数）      打开交互式管理面板
  links | uri     一键输出全部可用节点纯链接（方便复制）
  sub             输出 Base64 合并订阅串
  yaml | mihomo   输出 Clash / Mihomo proxies YAML 节点片段
  users           列出全部跨协议用户名（email 标识）
  user <用户名>   仅导出该用户的专属纯链接 + Base64 + Mihomo YAML
  traffic         查看当前周期流量统计（整机 + 分协议 + 分用户明细）
  info            输出全部协议详细配置
  status          查看 Xray 服务状态、版本与监听端口
  restart         校验配置并重启 Xray
  logs            查看最近 80 行日志
  follow          实时追踪日志（Ctrl+C 退出）
  refresh         刷新公网 IPv4 / IPv6 地址
  update          安全升级 Xray-core（保留配置）
  backup          打包备份 /etc/xray 配置快照
  help            显示此帮助信息
HELP
}

manager_main() {
  need_root
  detect_os
  case "${1:-}" in
    ''|--manage) ;;
    links|uri) show_quick_links; return 0 ;;
    sub) export_base64_sub "${2:-}"; return 0 ;;
    yaml|mihomo|clash) export_mihomo_yaml "${2:-}"; return 0 ;;
    users)
      load_state
      U_LIST="$(list_all_usernames)"
      if [ -n "${U_LIST}" ]; then
        printf '%s\n' "${U_LIST}"
      else
        echo "（暂无多协议用户）"
      fi
      return 0
      ;;
    user)
      if [ -z "${2:-}" ]; then
        warn "请指定用户名，例如：vvr user alice"
        load_state
        U_LIST="$(list_all_usernames)"
        [ -z "${U_LIST}" ] || { echo "当前可用用户："; printf '  - %s\n' ${U_LIST}; }
        return 1
      fi
      show_user_bundle "$2"
      return $?
      ;;
    traffic) show_traffic_status; return $? ;;
    info) show_all_nodes; return 0 ;;
    status)
      load_state
      echo "系统：$(os_label) | Xray：$(xray_version_short) | 放行端口：$(firewall_ports_summary)"
      service_status_output
      echo
      show_listening_ports
      return 0
      ;;
    restart) restart_xray_interactive; return $? ;;
    logs) service_show_logs; return 0 ;;
    follow) service_follow_logs; return 0 ;;
    refresh) refresh_network; return 0 ;;
    update) upgrade_xray_core; return $? ;;
    backup) backup_config_snapshot; return $? ;;
    help|-h|--help) show_vvr_help; return 0 ;;
    *)
      warn "未知子命令：$1"
      show_vvr_help
      exit 2
      ;;
  esac

  while :; do
    MENU_RETURNED="0"
    manager_menu
    read -r MAIN_CHOICE || exit 0
    [ -n "${MAIN_CHOICE}" ] || continue
    case "${MAIN_CHOICE}" in
      1) show_quick_links ;;
      2) export_nodes_menu ;;
      3) manage_vless_menu ;;
      4) manage_xhttp_menu ;;
      5) manage_hy2_menu ;;
      6) manage_ss_menu ;;
      7) manage_outbound_menu ;;
      8) manage_traffic_menu ;;
      9) manage_service_menu ;;
      10) manage_updates_menu ;;
      0|q|Q) exit 0 ;;
      *) echo "无效选择。" ;;
    esac
    case "${MAIN_CHOICE}" in
      2|3|4|5|6|7|8|9|10) ;;
      *)
        if [ "${MENU_RETURNED:-0}" = "1" ]; then
          MENU_RETURNED="0"
        else
          pause_menu "按回车返回主菜单..."
        fi
        ;;
    esac
  done
}

# --- Installer & safe update flows ---

prompt_initial_protocols() {
  while :; do
    echo
    echo "选择首次安装的协议（可单选，也可用逗号/空格多选，如 1,3 或 1,2,3,4）："
    echo "  1. VLESS + Vision + REALITY（TCP 主力直连，多客户端）"
    echo "  2. VLESS + XHTTP + REALITY（TCP 新一代 XHTTP 传输）"
    echo "  3. Hysteria 2（UDP / QUIC 高速抗丢包，Xray 原生）"
    echo "  4. Shadowsocks（轻量落地 / 中转）"
    echo "  5. 全部安装（黄金全能组合：1 + 2 + 3 + 4）"
    printf '请选择 [1]: '
    read -r INPUT
    SELECTION="${INPUT:-1}"
    INSTALL_VLESS="0"
    INSTALL_XHTTP="0"
    INSTALL_HY2="0"
    INSTALL_SS="0"
    INVALID_SEL="0"
    CLEAN_SEL="$(printf '%s' "${SELECTION}" | tr ',;' '  ')"
    for ITEM in ${CLEAN_SEL}; do
      case "${ITEM}" in
        1) INSTALL_VLESS="1" ;;
        2) INSTALL_XHTTP="1" ;;
        3) INSTALL_HY2="1" ;;
        4) INSTALL_SS="1" ;;
        5) INSTALL_VLESS="1"; INSTALL_XHTTP="1"; INSTALL_HY2="1"; INSTALL_SS="1" ;;
        *) INVALID_SEL="1" ;;
      esac
    done
    if [ "${INVALID_SEL}" = "0" ] && [ $((INSTALL_VLESS + INSTALL_XHTTP + INSTALL_HY2 + INSTALL_SS)) -gt 0 ]; then
      return 0
    fi
    echo "无效选择，请输入 1 到 5（可逗号分隔多选）。"
  done
}

confirm_install_inputs() {
  echo
  echo "安装参数确认（$(os_label)）："
  if [ "${INSTALL_VLESS}" = "1" ]; then
    case "${INITIAL_VLESS_FAMILY}" in
      ipv4) echo "  VLESS-Vision：IPv4（TCP 0.0.0.0:${IPV4_PORT}，客户端：${INITIAL_CLIENT_NAME}）" ;;
      ipv6) echo "  VLESS-Vision：IPv6（TCP [::]:${IPV6_PORT}，客户端：${INITIAL_CLIENT_NAME}）" ;;
    esac
  fi
  if [ "${INSTALL_XHTTP}" = "1" ]; then
    echo "  VLESS-XHTTP ：TCP ${XHTTP_BIND}:${XHTTP_PORT}（path=${XHTTP_PATH} | mode=${XHTTP_MODE} | ${XHTTP_NAME}）"
  fi
  if [ "${INSTALL_VLESS}" = "1" ] || [ "${INSTALL_XHTTP}" = "1" ]; then
    echo "  REALITY 共用：SNI=${SNI}（回落：${FALLBACK_MODE}）"
  fi
  if [ "${INSTALL_HY2}" = "1" ]; then
    echo "  Hysteria 2  ：UDP ${HY2_BIND}:${HY2_PORT}（SNI=${HY2_SNI} | 证书=${HY2_CERT_MODE} | ${HY2_NAME}）"
  fi
  if [ "${INSTALL_SS}" = "1" ]; then
    echo "  Shadowsocks ：${SS_BIND}:${SS_PORT}（${SS_METHOD} | ${SS_NETWORK} | ${SS_NAME}）"
  fi
  echo "  基础出站    ：$(outbound_mode_label "${BASE_OUTBOUND_MODE}")"
  echo
  printf '确认开始安装？[Y/n]: '
  read -r ANSWER
  case "${ANSWER:-Y}" in y|Y|yes|YES) ;; *) fail "已取消安装。" ;; esac
}

safe_update() {
  installation_complete || fail "现有安装不完整，无法安全更新；请使用 --reinstall 重新安装。"
  info "检测到已有完整 VVR 安装，进入安全更新模式（保留全部节点配置与密钥）。"
  trap installer_exit 0
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  ensure_low_mem_swap || true
  install_deps
  prepare_tmp
  if service_is_running; then EXISTING_SERVICE_WAS_RUNNING="1"; fi
  if service_is_enabled; then EXISTING_SERVICE_WAS_ENABLED="1"; fi
  backup_existing_install

  detect_arch
  download_xray || fail "下载 Xray-core 失败。"
  install_xray_files || fail "安装 Xray 文件失败。"
  write_service
  service_daemon_reload
  test_config || fail "新版 Xray 无法校验现有配置，已自动回滚。"
  service_restart || fail "新版 Xray 启动失败，已自动回滚。"
  sleep 2
  service_is_running || fail "新版 Xray 运行异常，已自动回滚。"
  load_state
  if [ "${TRAFFIC_ENABLED:-0}" = "1" ]; then
    write_traffic_script
    write_traffic_services
    traffic_api_restart >/dev/null 2>&1 || true
  fi
  install_manager
  INSTALL_COMMITTED="1"
  ok "安全更新完成！现有节点链接、客户端和分流规则均保持不变。"
}

full_install() {
  INSTALL_MODE="${1:-install}"
  trap installer_exit 0
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  info "检测到系统：$(os_label)"
  ensure_low_mem_swap || true
  install_deps
  detect_arch
  prepare_tmp
  detect_network

  IPV4_PORT=""
  IPV6_PORT=""
  SNI="${DEFAULT_SNI}"
  REALITY_DEST="${DEFAULT_SNI}:443"
  PRIVATE_KEY=""
  PUBLIC_KEY=""
  SHORT_ID=""
  FALLBACK_MODE="direct"
  FALLBACK_PORT=""
  clear_fallback_limit
  XHTTP_PORT=""
  XHTTP_BIND=""
  XHTTP_FAMILY=""
  XHTTP_UUID=""
  XHTTP_PATH=""
  XHTTP_MODE="${DEFAULT_XHTTP_MODE}"
  XHTTP_NAME="${DEFAULT_XHTTP_NAME}"
  XHTTP_SERVER_HOST=""
  HY2_PORT=""
  HY2_BIND=""
  HY2_FAMILY=""
  HY2_PASSWORD=""
  HY2_SNI="${DEFAULT_HY2_SNI}"
  HY2_CERT_MODE="selfsigned"
  HY2_CERT_FILE=""
  HY2_KEY_FILE=""
  HY2_INSECURE="1"
  HY2_NAME="${DEFAULT_HY2_NAME}"
  HY2_SERVER_HOST=""
  SS_PORT=""
  SS_BIND=""
  SS_FAMILY=""
  SS_NETWORK="${DEFAULT_SS_NETWORK}"
  SS_METHOD="${DEFAULT_SS_METHOD}"
  SS_PASSWORD=""
  SS_NAME="${DEFAULT_SS_NAME}"
  SS_SERVER_HOST=""
  BASE_OUTBOUND_MODE="${DEFAULT_BASE_OUTBOUND_MODE}"
  HAPPY_EYEBALLS_DELAY_MS="${DEFAULT_HAPPY_EYEBALLS_DELAY_MS}"
  BLOCK_PRIVATE_IP="${DEFAULT_BLOCK_PRIVATE_IP}"
  TRAFFIC_ENABLED="${DEFAULT_TRAFFIC_ENABLED}"
  TRAFFIC_API_PORT="${DEFAULT_TRAFFIC_API_PORT}"
  XRAY_API_PORT="${DEFAULT_XRAY_API_PORT}"
  INITIAL_VLESS_FAMILY=""
  INITIAL_CLIENT_NAME=""

  prompt_initial_protocols

  if [ "${INSTALL_VLESS}" = "1" ] || [ "${INSTALL_XHTTP}" = "1" ]; then
    echo
    info "配置 REALITY 参数（VLESS-Vision 与 VLESS-XHTTP 共用）"
    prompt_sni "${DEFAULT_SNI}"
  fi

  if [ "${INSTALL_VLESS}" = "1" ]; then
    echo
    info "配置 VLESS + Vision + REALITY"
    prompt_vless_family
    INITIAL_VLESS_FAMILY="${SELECTED_VLESS_FAMILY}"
    case "${INITIAL_VLESS_FAMILY}" in
      ipv4)
        prompt_port_value "VLESS-Vision IPv4 " "${DEFAULT_IPV4_PORT}"
        IPV4_PORT="${SELECTED_PORT}"
        ;;
      ipv6)
        prompt_port_value "VLESS-Vision IPv6 " "${DEFAULT_IPV6_PORT}"
        IPV6_PORT="${SELECTED_PORT}"
        ;;
    esac
    prompt_tag "" "初始 VLESS-Vision 客户端名称"
    INITIAL_CLIENT_NAME="${TAG}"
  fi

  if [ "${INSTALL_XHTTP}" = "1" ]; then
    echo
    info "配置 VLESS + XHTTP + REALITY"
    prompt_xhttp_family "ipv4"
    while :; do
      prompt_port_value "VLESS-XHTTP (TCP) " "${DEFAULT_XHTTP_PORT}"
      port_conflicts_with_configured "${SELECTED_PORT}" "xhttp" "tcp" && continue
      XHTTP_PORT="${SELECTED_PORT}"
      break
    done
    prompt_xhttp_path "" 0
    prompt_xhttp_mode "${DEFAULT_XHTTP_MODE}"
    prompt_tag "${DEFAULT_XHTTP_NAME}" "VLESS-XHTTP 节点名称"
    XHTTP_NAME="${TAG}"
  fi

  if [ "${INSTALL_VLESS}" = "1" ] || [ "${INSTALL_XHTTP}" = "1" ]; then
    prompt_fallback_settings 0
  fi

  if [ "${INSTALL_HY2}" = "1" ]; then
    echo
    info "配置 Hysteria 2 (UDP / QUIC，支持与 TCP 443 共用端口号)"
    prompt_hy2_family "ipv4"
    while :; do
      prompt_port_value "Hysteria 2 (UDP) " "${DEFAULT_HY2_PORT}"
      port_conflicts_with_configured "${SELECTED_PORT}" "hy2" "udp" && continue
      HY2_PORT="${SELECTED_PORT}"
      break
    done
    prompt_hy2_cert_config 0
    prompt_tag "${DEFAULT_HY2_NAME}" "Hysteria 2 节点名称"
    HY2_NAME="${TAG}"
    generate_hy2_password || fail "生成 Hysteria 2 密码失败。"
  fi

  if [ "${INSTALL_SS}" = "1" ]; then
    echo
    info "配置 Shadowsocks"
    prompt_ss_family "ipv4"
    prompt_ss_method "${DEFAULT_SS_METHOD}"
    prompt_ss_network "${DEFAULT_SS_NETWORK}"
    while :; do
      prompt_port_value "Shadowsocks " "${DEFAULT_SS_PORT}"
      port_conflicts_with_configured "${SELECTED_PORT}" "ss" "${SS_NETWORK}" && continue
      SS_PORT="${SELECTED_PORT}"
      break
    done
    prompt_tag "${DEFAULT_SS_NAME}" "Shadowsocks 节点名称"
    SS_NAME="${TAG}"
    generate_ss_password "${SS_METHOD}" || fail "生成 Shadowsocks 密码失败。"
  fi

  while :; do
    echo
    echo "基础出站模式（未命中域名规则的流量）："
    choose_outbound_mode "${DEFAULT_BASE_OUTBOUND_MODE}"
    if confirm_outbound_availability "${SELECTED_OUTBOUND_MODE}"; then
      BASE_OUTBOUND_MODE="${SELECTED_OUTBOUND_MODE}"
      break
    fi
  done

  confirm_install_inputs

  if installation_present; then
    warn "检测到已有 Xray 安装。"
    if [ "${INSTALL_MODE}" != "reinstall" ]; then
      printf '是否替换现有安装与配置？脚本会先备份，失败时自动恢复。[y/N]: '
      read -r ANSWER
      case "${ANSWER}" in y|Y|yes|YES) ;; *) fail "已取消安装。" ;; esac
    fi
    if service_is_running; then EXISTING_SERVICE_WAS_RUNNING="1"; fi
    if service_is_enabled; then EXISTING_SERVICE_WAS_ENABLED="1"; fi
  fi
  backup_existing_install

  download_xray || fail "下载 Xray-core 失败。"
  if [ "${EXISTING_SERVICE_WAS_RUNNING}" = "1" ]; then
    info "停止旧 Xray 服务..."
    service_stop
  fi

  if [ -n "${IPV4_PORT}" ]; then
    check_port_available "${IPV4_PORT}" "" "tcp" || fail "TCP 端口 ${IPV4_PORT} 已被占用。"
  fi
  if [ -n "${IPV6_PORT}" ]; then
    check_port_available "${IPV6_PORT}" "" "tcp" || fail "TCP 端口 ${IPV6_PORT} 已被占用。"
  fi
  if [ -n "${XHTTP_PORT}" ]; then
    check_port_available "${XHTTP_PORT}" "" "tcp" || fail "TCP 端口 ${XHTTP_PORT} 已被占用。"
  fi
  if [ -n "${HY2_PORT}" ]; then
    check_port_available "${HY2_PORT}" "" "udp" || fail "UDP 端口 ${HY2_PORT} 已被占用。"
  fi
  if [ -n "${SS_PORT}" ]; then
    check_port_available "${SS_PORT}" "" "${SS_NETWORK}" || fail "端口 ${SS_PORT} 已被占用。"
  fi
  if [ "${FALLBACK_MODE}" = "protected" ] && [ -n "${FALLBACK_PORT}" ]; then
    check_port_available "${FALLBACK_PORT}" "" "tcp" || fail "回落端口 ${FALLBACK_PORT} 已被占用。"
  fi

  install_xray_files || fail "安装 Xray 文件失败。"

  mkdir -p "${CONFIG_DIR}"
  : > "${ROUTES_FILE}"
  chmod 0600 "${ROUTES_FILE}"
  : > "${CLIENTS_FILE}"
  chmod 0600 "${CLIENTS_FILE}"
  : > "${XHTTP_CLIENTS_FILE}"
  chmod 0600 "${XHTTP_CLIENTS_FILE}"
  : > "${HY2_CLIENTS_FILE}"
  chmod 0600 "${HY2_CLIENTS_FILE}"
  : > "${OUTBOUNDS_FILE}"
  chmod 0600 "${OUTBOUNDS_FILE}"
  : > "${USER_ROUTES_FILE}"
  chmod 0600 "${USER_ROUTES_FILE}"
  : > "${INBOUND_ROUTES_FILE}"
  chmod 0600 "${INBOUND_ROUTES_FILE}"

  if [ "${INSTALL_VLESS}" = "1" ] || [ "${INSTALL_XHTTP}" = "1" ]; then
    generate_reality_values || fail "生成 REALITY 密钥失败。"
  fi
  if [ "${INSTALL_VLESS}" = "1" ]; then
    generate_uuid || fail "生成 VLESS-Vision UUID 失败。"
    printf '%s|%s|%s\n' "${INITIAL_VLESS_FAMILY}" "${UUID}" "${INITIAL_CLIENT_NAME}" > "${CLIENTS_FILE}"
    chmod 0600 "${CLIENTS_FILE}"
  fi
  if [ "${INSTALL_XHTTP}" = "1" ]; then
    generate_uuid || fail "生成 VLESS-XHTTP UUID 失败。"
    XHTTP_UUID="${UUID}"
    printf '%s|%s\n' "${XHTTP_UUID}" "${XHTTP_NAME}" > "${XHTTP_CLIENTS_FILE}"
    chmod 0600 "${XHTTP_CLIENTS_FILE}"
  fi
  if [ "${INSTALL_HY2}" = "1" ]; then
    printf '%s|%s\n' "${HY2_PASSWORD}" "${HY2_NAME}" > "${HY2_CLIENTS_FILE}"
    chmod 0600 "${HY2_CLIENTS_FILE}"
    if [ "${HY2_CERT_MODE}" = "selfsigned" ]; then
      generate_hy2_selfsigned_cert "${HY2_SNI}" "${HY2_CERT_FILE}" "${HY2_KEY_FILE}" || fail "生成 Hysteria 2 自签证书失败。"
    fi
  fi

  write_config || fail "写入 Xray 配置文件失败。"
  info "校验 Xray 配置..."
  test_config || fail "Xray 配置校验失败。"
  write_service
  service_daemon_reload
  service_enable
  service_restart || {
    service_show_logs
    fail "Xray 服务启动失败。"
  }
  sleep 2
  service_is_running || {
    service_show_logs
    fail "Xray 服务状态异常。"
  }
  save_state
  install_manager
  INSTALL_COMMITTED="1"

  echo
  ok "Xray 通用多协议节点安装完成！（$(os_label)）"
  echo "配置文件：${CONFIG_FILE}"
  echo "客户端表：${CLIENTS_FILE}"
  echo "路由规则：${ROUTES_FILE}"
  echo "管理面板：vvr"
  show_all_nodes
  echo "防火墙放行提醒："
  [ -z "${IPV4_PORT}" ] || echo "  - TCP ${IPV4_PORT}（VLESS-Vision IPv4）"
  [ -z "${IPV6_PORT}" ] || echo "  - TCP ${IPV6_PORT}（VLESS-Vision IPv6）"
  [ -z "${XHTTP_PORT}" ] || echo "  - TCP ${XHTTP_PORT}（VLESS-XHTTP）"
  [ -z "${HY2_PORT}" ] || echo "  - UDP ${HY2_PORT}（Hysteria 2）"
  [ -z "${SS_PORT}" ] || echo "  - ${SS_NETWORK} ${SS_PORT}（Shadowsocks）"
}

main() {
  need_root
  detect_os
  case "${1:-}" in
    '')
      if installation_complete; then
        safe_update
      else
        full_install install
      fi
      ;;
    --update)
      safe_update
      ;;
    --reinstall)
      full_install reinstall
      ;;
    --manage)
      shift
      manager_main "$@"
      ;;
    *)
      echo "用法：$0 [--manage|--update|--reinstall]" >&2
      echo "  无参数        首次安装；已有完整安装时自动安全升级内核与管理脚本" >&2
      echo "  --manage      打开 vvr 交互管理面板" >&2
      echo "  --update      安全升级 Xray-core 与 vvr 管理脚本（保留配置）" >&2
      echo "  --reinstall   重新配置并安装（失败自动回滚）" >&2
      exit 2
      ;;
  esac
}

case "$(basename "$0")" in
  vvr) manager_main "$@" ;;
  *) main "$@" ;;
esac
