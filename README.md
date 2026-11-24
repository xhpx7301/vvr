# VVR — Xray 通用四协议一键安装与管理脚本

面向 **Debian / Ubuntu (`systemd`)** 与 **Alpine Linux (`OpenRC`)** 的单文件通用 Xray-core 节点部署与管理工具，单进程原生整合四大主流协议、统一多用户与三层分流、以及可选流量统计与 MiSub / 3X-UI API 模块。

## 快速开始

```sh
curl -fsSL https://raw.githubusercontent.com/xhpx7301/vvr/main/install-xray-vvr.sh -o install-xray-vvr.sh
chmod +x install-xray-vvr.sh
./install-xray-vvr.sh
```

安装完成后直接运行 `vvr` 即可打开交互式管理面板。

---

## 核心特性

- **双系统自适应 & 低内存保护**：
  - 自动识别 Debian/Ubuntu (`systemd`) 与 Alpine Linux (`OpenRC`)，统一安装路径与 `vvr` 体验。
  - 自动检测物理内存与 cgroup v1/v2 上限；`<= 128 MiB` 且无 Swap 时自动尝试创建临时 Swap，并使用 `unzip -p` 流式解压，降低峰值内存占用。
- **单进程四大主流协议自由组合**：
  - **VLESS + Vision + REALITY**：TCP 主力直连，支持 IPv4/IPv6 双栈多客户端、高级回落保护（本机 Tunnel SNI 白名单 + 上传/下载回落限速）。
  - **VLESS + XHTTP + REALITY**：TCP 新一代 XHTTP 传输（`auto`/`stream-one`/`packet-up`/`stream-up`），与 Vision 共用 REALITY 密钥与 SNI，支持多客户端。
  - **Hysteria 2（Xray-core v26.3+ 原生入站）**：UDP / QUIC 高速抗丢包，支持多客户端独立密码；默认自动签发 ECDSA P-256 自签证书（免域名即装即用，链接自动带 `insecure=1`），也支持已有域名证书；**TCP 与 UDP 端口独立校验**（支持 TCP 443 与 UDP 443 共存）。
  - **Shadowsocks 2022 / AEAD**：默认 `2022-blake3-aes-128-gcm`（可选 `2022-blake3-aes-256-gcm`、`aes-256-gcm`、`chacha20-ietf-poly1305`），支持 IPv4/IPv6 与 `tcp` / `tcp,udp`。
- **统一多用户（`email` 身份）与按用户导出**：
  - Vision / XHTTP / Hysteria 2 均自动写入 Xray `email` 身份。
  - 支持在面板中一键跨协议新增同名用户，并通过 `vvr user <用户名>` 仅导出该用户的专属纯链接 + Base64 + Mihomo YAML（不泄露其他用户或共享 SS 凭据）。
- **外部落地代理 + 三层分流 + 默认内网防护**：
  - **外部落地代理（链式出站）**：支持管理外部 `Shadowsocks` 与 `Socks5`（含本机 WARP）落地出站，可用于基础出站或任意分流规则目标。
  - **三层优先级路由**：`域名/Geosite 规则`（含 AI / YouTube / 流媒体 / 去广告一键预设与上移/下移/置顶排序）→ `按用户 (user/email) 覆盖` → `按协议入站 (inboundTag) 覆盖` → `基础兜底出站`。
  - **默认内网 / 回环 IP 屏蔽**：默认拦截 `127.0.0.0/8`、RFC1918 私网、云元数据 `169.254.0.0/16` 与 IPv6 内网段（免加载 `geoip.dat`，省内存且防 SSRF，可在菜单一键开关）。
  - **本地 URL 命中测试**：通过临时本地 SOCKS 实例实测任意 URL 命中的规则编号与实际出站（支持直连、`block` 与落地代理）。
- **可选流量统计与 MiSub / 3X-UI API 模块（默认不安装）**：
  - 首次安装**默认关闭且不安装 `python3`**，对 64MB 小内存 VPS 零额外占用。
  - 需要时在 `vvr` 主菜单选 **`8`** 一键安装启用：自动安装 `python3 + sqlite3`，支持 Debian `systemd`（service + timer）与 Alpine `OpenRC`（init.d + crond）。
  - 支持整机总流量 + **按协议入站明细** + **按用户（`email`）明细**、每月自定义时间自动重置、手动清零，并提供 MiSub / 3X-UI 兼容接口（`/panel/api/inbounds/list`、`/api/traffic`），随时可一键卸载关闭以恢复零占用。
- **安全校验与无痛升级**：
  - 下载 Xray-core 自动校验 `.dgst` SHA256；再次无参运行或执行 `--update` 会安全升级内核并保留所有配置、密钥、规则与流量数据，失败自动回滚。
  - 支持 `/etc/xray` 配置快照一键打包备份与带校验的恢复回滚。

---

## 命令与快捷方式

| 命令 | 说明 |
| --- | --- |
| `./install-xray-vvr.sh` | 首次安装；若已存在完整安装，自动执行安全升级 |
| `./install-xray-vvr.sh --update` | 安全升级 Xray-core 与 `vvr` 脚本（保留全部配置） |
| `./install-xray-vvr.sh --reinstall` | 重新配置并安装（自动备份，失败回滚） |
| `vvr` | 打开交互式管理面板（1–10 精简布局，`0`/`q` 返回，空回车刷新） |
| `vvr links` / `vvr uri` | 一键输出全部纯 URI 链接（方便全选复制） |
| `vvr sub` | 输出 Base64 合并订阅串 |
| `vvr yaml` / `vvr mihomo` | 输出 Clash / Mihomo `proxies:` YAML 节点片段 |
| `vvr users` | 列出全部跨协议用户名（`email` 身份） |
| `vvr user <用户名>` | 仅导出该用户的专属纯链接 + Base64 + Mihomo YAML |
| `vvr traffic` | 查看当前周期流量统计（整机 + 分协议 + 分用户明细） |
| `vvr status` / `vvr restart` | 查看服务状态与监听端口 / 校验配置并重启 |
| `vvr logs` / `vvr follow` | 查看最近 80 行日志 / 实时追踪日志 |
| `vvr refresh` | 刷新服务器公网 IPv4 / IPv6 地址 |
| `vvr backup` / `vvr update` | 打包备份 `/etc/xray` 快照 / 安全升级 Xray-core |

## 常用环境变量

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `XRAY_VERSION` | 锁定要安装的 Xray-core 版本（如 `v26.3.27`） | `latest` |
| `VVR_XRAY_URL` | 自定义 Xray-core zip 下载地址（用于镜像源） | GitHub Release |
| `CUSTOM_IPV4` / `CUSTOM_IPV6` | 手动指定用于生成链接的公网 IPv4 / IPv6 | 自动检测 |
| `VVR_SWAP_FILE` / `VVR_SWAP_SIZE_MB` | 低内存临时 Swap 文件路径与大小 (MiB) | `/swapfile` / `256` |
| `VVR_GITHUB_REPO` / `VVR_GITHUB_BRANCH` | 脚本自更新使用的仓库与分支 | `xhpx7301/vvr` / `main` |

---

## 本地测试

```sh
python3 -m unittest discover -s tests -v
```

在 Windows 上如未将 `sh` 加入 `PATH`，可通过 `VVR_TEST_SHELL` 指定 Git Bash 的 `sh.exe`：

```powershell
$env:VVR_TEST_SHELL = "C:\Program Files\Git\bin\sh.exe"
python -m unittest discover -s tests -v
```
