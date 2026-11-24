import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
ALL_SCRIPTS = sorted(REPO_ROOT.glob("*.sh"))
UNIVERSAL_SCRIPT = REPO_ROOT / "install-xray-vvr.sh"
UNIVERSAL_SOURCE = UNIVERSAL_SCRIPT.read_text(encoding="utf-8")
UNIVERSAL_LIBRARY = UNIVERSAL_SOURCE.rsplit('\ncase "$(basename "$0")" in', 1)[0]


def detect_posix_shell():
    configured = os.environ.get("VVR_TEST_SHELL")
    if configured:
        return configured
    found = shutil.which("sh")
    if found:
        return found
    git = shutil.which("git")
    if git:
        candidate = Path(git).resolve().parent.parent / "bin" / "sh.exe"
        if candidate.is_file():
            return str(candidate)
    return None


SHELL = detect_posix_shell()


@unittest.skipUnless(SHELL, "POSIX shell not found; set VVR_TEST_SHELL")
class AllScriptsStaticTests(unittest.TestCase):
    def test_all_scripts_pass_sh_syntax_check(self):
        self.assertEqual([p.name for p in ALL_SCRIPTS], ["install-xray-vvr.sh"])
        for script in ALL_SCRIPTS:
            with self.subTest(script=script.name):
                res = subprocess.run([SHELL, "-n", str(script)], capture_output=True)
                self.assertEqual(
                    res.returncode,
                    0,
                    (res.stdout + res.stderr).decode("utf-8", errors="replace"),
                )

    def test_all_scripts_support_modern_x25519_password_output(self):
        for script in ALL_SCRIPTS:
            with self.subTest(script=script.name):
                text = script.read_text(encoding="utf-8")
                self.assertIn("^password[ \\t]*:", text)

    def test_no_single_dollar_tmp_typo_or_busybox_mktemp_suffix_in_alpine_scripts(self):
        for script in ALL_SCRIPTS:
            text = script.read_text(encoding="utf-8")
            with self.subTest(script=script.name):
                self.assertNotIn('.tmp.$"', text)
                if "alpine" in script.name or script.name == "install-xray-vvr.sh":
                    self.assertNotIn("XXXXXX.", text)


@unittest.skipUnless(SHELL, "POSIX shell not found; set VVR_TEST_SHELL")
class UniversalScriptTests(unittest.TestCase):
    def run_universal(self, body):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            script = tmp / "test-universal.sh"
            script.write_text(
                UNIVERSAL_LIBRARY + "\n" + body,
                encoding="utf-8",
                newline="\n",
            )
            res = subprocess.run([SHELL, str(script)], capture_output=True, cwd=tmp)
            output = (res.stdout + res.stderr).decode("utf-8", errors="replace")
            self.assertEqual(res.returncode, 0, output)
            return output, tmp

    def test_parse_x25519_legacy_and_modern_formats(self):
        sample_priv = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        sample_pub = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        body = f"""
parse_x25519_keys "Private key: {sample_priv}
Public key: {sample_pub}"
[ "${{PRIVATE_KEY}}" = "{sample_priv}" ]
[ "${{PUBLIC_KEY}}" = "{sample_pub}" ]

PRIVATE_KEY=""
PUBLIC_KEY=""
parse_x25519_keys "PrivateKey: {sample_priv}
Password: {sample_pub}
Hash32: CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
[ "${{PRIVATE_KEY}}" = "{sample_priv}" ]
[ "${{PUBLIC_KEY}}" = "{sample_pub}" ]
"""
        self.run_universal(body)

    def test_write_config_dual_protocol_with_protected_fallback_and_routes(self):
        body = """
CONFIG_DIR="./etc-xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
ROUTES_FILE="${CONFIG_DIR}/vvr-routing.rules"
CLIENTS_FILE="${CONFIG_DIR}/vvr-clients.db"
mkdir -p "${CONFIG_DIR}"
cat > "${CLIENTS_FILE}" <<'CLIENTS'
ipv4|11111111-1111-1111-1111-111111111111|alice-v4
ipv4|22222222-2222-2222-2222-222222222222|bob-v4
ipv6|33333333-3333-3333-3333-333333333333|carol-v6
CLIENTS
cat > "${ROUTES_FILE}" <<'ROUTES'
ipv6|geosite|youtube
happy6v4|domain|domain:example.com
ROUTES
IPV4_PORT="443"
IPV6_PORT="8443"
SNI="www.sony.com"
PRIVATE_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
PUBLIC_KEY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
SHORT_ID="0123456789abcdef"
FALLBACK_MODE="protected"
FALLBACK_PORT="4431"
REALITY_DEST="127.0.0.1:4431"
FALLBACK_LIMIT_MODE="recommended"
FALLBACK_LIMIT_AFTER_BYTES="1048576"
FALLBACK_LIMIT_UPLOAD_BPS="65536"
FALLBACK_LIMIT_UPLOAD_BURST="131072"
FALLBACK_LIMIT_DOWNLOAD_BPS="131072"
FALLBACK_LIMIT_DOWNLOAD_BURST="262144"
SS_PORT="8388"
SS_BIND="::"
SS_FAMILY="ipv6"
SS_NETWORK="tcp,udp"
SS_METHOD="2022-blake3-aes-128-gcm"
SS_PASSWORD="dGVzdC1wYXNzd29yZC0xNg=="
SS_NAME="ss-v6"
BASE_OUTBOUND_MODE="happy4v6"
HAPPY_EYEBALLS_DELAY_MS="150"
write_config
cat "${CONFIG_FILE}"
"""
        output, _ = self.run_universal(body)
        cfg = json.loads(output)
        tags = [item["tag"] for item in cfg["inbounds"]]
        self.assertEqual(tags, ["vless-in-ipv4", "vless-in-ipv6", "reality-fallback", "shadowsocks-in"])
        v4 = cfg["inbounds"][0]
        self.assertEqual(len(v4["settings"]["clients"]), 2)
        self.assertEqual(v4["streamSettings"]["realitySettings"]["dest"], "127.0.0.1:4431")
        self.assertEqual(v4["streamSettings"]["realitySettings"]["limitFallbackUpload"]["bytesPerSec"], 65536)
        ss = cfg["inbounds"][3]
        self.assertEqual(ss["listen"], "::")
        self.assertEqual(ss["port"], 8388)
        self.assertEqual(ss["settings"]["network"], "tcp,udp")
        # Protected fallback uses BASE_OUTBOUND_TAG instead of hardcoded direct-ipv4
        fb_allow = cfg["routing"]["rules"][0]
        self.assertEqual(fb_allow["inboundTag"], ["reality-fallback"])
        self.assertEqual(fb_allow["outboundTag"], "direct-happy-ipv4v6")
        # Default rule covers all 3 active user inbounds
        default_rule = cfg["routing"]["rules"][-1]
        self.assertEqual(default_rule["inboundTag"], ["vless-in-ipv4", "vless-in-ipv6", "shadowsocks-in"])
        self.assertEqual(default_rule["outboundTag"], "direct-happy-ipv4v6")

    def test_write_config_shadowsocks_only(self):
        body = """
CONFIG_DIR="./etc-xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
ROUTES_FILE="${CONFIG_DIR}/vvr-routing.rules"
CLIENTS_FILE="${CONFIG_DIR}/vvr-clients.db"
IPV4_PORT=""
IPV6_PORT=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
FALLBACK_MODE="direct"
FALLBACK_PORT=""
SS_PORT="9443"
SS_BIND="0.0.0.0"
SS_FAMILY="ipv4"
SS_NETWORK="tcp"
SS_METHOD="2022-blake3-aes-128-gcm"
SS_PASSWORD="dGVzdC1wYXNzd29yZC0xNg=="
SS_NAME="ss-only"
BASE_OUTBOUND_MODE="ipv4"
HAPPY_EYEBALLS_DELAY_MS="100"
write_config
cat "${CONFIG_FILE}"
"""
        output, _ = self.run_universal(body)
        cfg = json.loads(output)
        self.assertEqual([item["tag"] for item in cfg["inbounds"]], ["shadowsocks-in"])
        self.assertEqual(cfg["routing"]["rules"][-1]["inboundTag"], ["shadowsocks-in"])

    def test_ss_ipv6_uri_does_not_leak_ipv4(self):
        body = """
SERVER_IPV4="203.0.113.10"
SERVER_IPV6=""
SS_FAMILY="ipv6"
SS_SERVER_HOST=""
SS_PORT="8388"
SS_METHOD="2022-blake3-aes-128-gcm"
SS_PASSWORD="dGVzdC1wYXNzd29yZC0xNg=="
SS_NAME="ss-v6"
make_ss_uri
printf '%s\\n' "${SS_URI}"
"""
        output, _ = self.run_universal(body)
        self.assertNotIn("203.0.113.10", output)
        self.assertIn("@[你的服务器IPv6地址]:8388#ss-v6", output)

    def test_port_conflict_detection_across_all_roles(self):
        body = """
IPV4_PORT="443"
IPV6_PORT="8443"
XHTTP_PORT="2053"
HY2_PORT="443"
SS_PORT="8388"
SS_NETWORK="tcp"
FALLBACK_MODE="protected"
FALLBACK_PORT="4431"
# TCP vs TCP conflicts
port_conflicts_with_configured 8388 vless4 tcp >/dev/null
port_conflicts_with_configured 2053 vless4 tcp >/dev/null
port_conflicts_with_configured 443 xhttp tcp >/dev/null
port_conflicts_with_configured 443 ss tcp >/dev/null
port_conflicts_with_configured 4431 vless6 tcp >/dev/null
# TCP 443 and UDP 443 (Hysteria 2) MUST coexist without conflict
! port_conflicts_with_configured 443 vless4 tcp >/dev/null
! port_conflicts_with_configured 443 hy2 udp >/dev/null
# UDP Hysteria 2 vs TCP-only SS on 8388 does NOT conflict
! port_conflicts_with_configured 8388 hy2 udp >/dev/null
# UDP Hysteria 2 vs TCP+UDP SS on 8388 MUST conflict
SS_NETWORK="tcp,udp"
port_conflicts_with_configured 8388 hy2 udp >/dev/null
port_conflicts_with_configured 443 ss tcp,udp >/dev/null
! port_conflicts_with_configured 9999 ss tcp,udp >/dev/null
"""
        self.run_universal(body)

    def test_write_config_all_four_protocols_with_port_443_coexistence(self):
        body = """
CONFIG_DIR="./etc-xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
ROUTES_FILE="${CONFIG_DIR}/vvr-routing.rules"
CLIENTS_FILE="${CONFIG_DIR}/vvr-clients.db"
mkdir -p "${CONFIG_DIR}"
printf 'ipv4|11111111-1111-1111-1111-111111111111|alice-v4\\n' > "${CLIENTS_FILE}"
: > "${ROUTES_FILE}"
IPV4_PORT="443"
IPV6_PORT=""
SNI="www.sony.com"
PRIVATE_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
PUBLIC_KEY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
SHORT_ID="0123456789abcdef"
FALLBACK_MODE="direct"
FALLBACK_PORT=""
REALITY_DEST="www.sony.com:443"
XHTTP_PORT="2053"
XHTTP_BIND="0.0.0.0"
XHTTP_FAMILY="ipv4"
XHTTP_UUID="44444444-4444-4444-4444-444444444444"
XHTTP_PATH="/secret-xhttp"
XHTTP_MODE="auto"
XHTTP_NAME="xhttp-node"
HY2_PORT="443"
HY2_BIND="0.0.0.0"
HY2_FAMILY="ipv4"
HY2_PASSWORD="0123456789abcdef0123456789abcdef"
HY2_SNI="bing.com"
HY2_CERT_MODE="selfsigned"
HY2_CERT_FILE="/etc/xray/hy2-cert.pem"
HY2_KEY_FILE="/etc/xray/hy2-key.pem"
HY2_INSECURE="1"
HY2_NAME="hy2-node"
SS_PORT="8388"
SS_BIND="0.0.0.0"
SS_FAMILY="ipv4"
SS_NETWORK="tcp"
SS_METHOD="2022-blake3-aes-128-gcm"
SS_PASSWORD="dGVzdC1wYXNzd29yZC0xNg=="
SS_NAME="ss-node"
BASE_OUTBOUND_MODE="ipv4"
HAPPY_EYEBALLS_DELAY_MS="100"
write_config
cat "${CONFIG_FILE}"
"""
        output, _ = self.run_universal(body)
        cfg = json.loads(output)
        inbounds = {item["tag"]: item for item in cfg["inbounds"]}
        self.assertEqual(
            list(inbounds.keys()),
            ["vless-in-ipv4", "vless-xhttp-in", "hysteria2-in", "shadowsocks-in"],
        )
        # VLESS + XHTTP + REALITY schema checks
        xhttp = inbounds["vless-xhttp-in"]
        self.assertEqual(xhttp["protocol"], "vless")
        self.assertEqual(xhttp["settings"]["clients"][0]["flow"], "")
        self.assertEqual(xhttp["streamSettings"]["network"], "xhttp")
        self.assertEqual(xhttp["streamSettings"]["xhttpSettings"], {"path": "/secret-xhttp", "mode": "auto"})
        self.assertEqual(xhttp["streamSettings"]["security"], "reality")
        # Hysteria 2 native Xray inbound schema checks
        hy2 = inbounds["hysteria2-in"]
        self.assertEqual(hy2["protocol"], "hysteria")
        self.assertEqual(hy2["port"], 443)
        self.assertEqual(hy2["settings"]["version"], 2)
        self.assertEqual(hy2["settings"]["clients"][0]["auth"], "0123456789abcdef0123456789abcdef")
        self.assertEqual(hy2["streamSettings"]["network"], "hysteria")
        self.assertEqual(hy2["streamSettings"]["security"], "tls")
        self.assertEqual(hy2["streamSettings"]["tlsSettings"]["alpn"], ["h3"])
        self.assertEqual(hy2["streamSettings"]["hysteriaSettings"], {"version": 2})
        # Default routing covers all 4 protocol inbounds
        self.assertEqual(
            cfg["routing"]["rules"][-1]["inboundTag"],
            ["vless-in-ipv4", "vless-xhttp-in", "hysteria2-in", "shadowsocks-in"],
        )

    def test_xhttp_and_hy2_uri_builders(self):
        body = """
SERVER_IPV4="203.0.113.10"
SERVER_IPV6="2001:db8::1"
SNI="www.sony.com"
PUBLIC_KEY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
SHORT_ID="0123456789abcdef"
FINGERPRINT="chrome"
XHTTP_FAMILY="ipv6"
XHTTP_SERVER_HOST=""
XHTTP_PORT="2053"
XHTTP_UUID="44444444-4444-4444-4444-444444444444"
XHTTP_PATH="/my/path"
XHTTP_MODE="stream-one"
XHTTP_NAME="xhttp-v6"
make_xhttp_uri
printf 'XHTTP=%s\\n' "${XHTTP_URI}"

HY2_FAMILY="ipv4"
HY2_SERVER_HOST=""
HY2_PORT="443"
HY2_PASSWORD="abcdef0123456789"
HY2_SNI="bing.com"
HY2_INSECURE="1"
HY2_NAME="hy2-self"
make_hy2_uri
printf 'HY2_SELF=%s\\n' "${HY2_URI}"

HY2_FAMILY="ipv6"
HY2_SERVER_HOST=""
SERVER_IPV6=""
HY2_INSECURE="0"
HY2_SNI="hy2.example.com"
HY2_NAME="hy2-ca"
make_hy2_uri
printf 'HY2_CA=%s\\n' "${HY2_URI}"
"""
        output, _ = self.run_universal(body)
        lines = dict(line.split("=", 1) for line in output.strip().splitlines())
        self.assertIn("@[2001:db8::1]:2053?", lines["XHTTP"])
        self.assertIn("type=xhttp", lines["XHTTP"])
        self.assertIn("path=%2Fmy%2Fpath", lines["XHTTP"])
        self.assertIn("mode=stream-one", lines["XHTTP"])
        self.assertEqual(
            lines["HY2_SELF"],
            "hysteria2://abcdef0123456789@203.0.113.10:443?sni=bing.com&alpn=h3&insecure=1#hy2-self",
        )
        self.assertNotIn("203.0.113.10", lines["HY2_CA"])
        self.assertNotIn("insecure=1", lines["HY2_CA"])
        self.assertIn("@[你的服务器IPv6地址]:443?sni=hy2.example.com&alpn=h3#hy2-ca", lines["HY2_CA"])

    def test_other_protocols_active_guard(self):
        body = """
CONFIG_DIR="./etc-xray"
CLIENTS_FILE="${CONFIG_DIR}/vvr-clients.db"
mkdir -p "${CONFIG_DIR}"
: > "${CLIENTS_FILE}"
PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
XHTTP_PORT=""; XHTTP_UUID=""
HY2_PORT="443"; HY2_PASSWORD="pass"; HY2_CERT_FILE="/a"; HY2_KEY_FILE="/b"
SS_PORT=""; SS_PASSWORD=""
# Only Hy2 is active -> cannot remove Hy2
! other_protocols_active_excluding hy2
# Enable SS -> now Hy2 can be removed and SS can be removed
SS_PORT="8388"; SS_PASSWORD="pw"
other_protocols_active_excluding hy2
other_protocols_active_excluding ss
"""
        self.run_universal(body)

    def test_exports_and_cli_shortcuts(self):
        body = """
need_root() { :; }
detect_os() { OS_TYPE=debian; INIT_TYPE=systemd; }
CONFIG_DIR="./etc-xray"
META_FILE="${CONFIG_DIR}/vvr.env"
CLIENTS_FILE="${CONFIG_DIR}/vvr-clients.db"
ROUTES_FILE="${CONFIG_DIR}/vvr-routing.rules"
mkdir -p "${CONFIG_DIR}"
printf 'ipv4|11111111-1111-1111-1111-111111111111|alice-v4\\n' > "${CLIENTS_FILE}"
: > "${ROUTES_FILE}"
IPV4_PORT="443"; IPV6_PORT=""
SNI="www.sony.com"; REALITY_DEST="www.sony.com:443"
PRIVATE_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
PUBLIC_KEY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
SHORT_ID="0123456789abcdef"
SERVER_IPV4="203.0.113.10"; SERVER_IPV6=""
XHTTP_PORT="2053"; XHTTP_BIND="0.0.0.0"; XHTTP_FAMILY="ipv4"
XHTTP_UUID="44444444-4444-4444-4444-444444444444"
XHTTP_PATH="/sec"; XHTTP_MODE="auto"; XHTTP_NAME="xhttp-n"; XHTTP_SERVER_HOST="203.0.113.10"
HY2_PORT="443"; HY2_BIND="0.0.0.0"; HY2_FAMILY="ipv4"
HY2_PASSWORD="abcdef0123456789"; HY2_SNI="bing.com"; HY2_CERT_MODE="selfsigned"
HY2_CERT_FILE="/etc/xray/hy2-cert.pem"; HY2_KEY_FILE="/etc/xray/hy2-key.pem"
HY2_INSECURE="1"; HY2_NAME="hy2-n"; HY2_SERVER_HOST="203.0.113.10"
SS_PORT="8388"; SS_BIND="0.0.0.0"; SS_FAMILY="ipv4"; SS_NETWORK="tcp,udp"
SS_METHOD="2022-blake3-aes-128-gcm"; SS_PASSWORD="dGVzdC1wYXNzd29yZC0xNg=="
SS_NAME="ss-n"; SS_SERVER_HOST="203.0.113.10"
save_state

printf 'PORTS=%s\\n' "$(firewall_ports_summary)"
echo "---LINKS---"
manager_main links
echo "---YAML---"
manager_main yaml
echo "---HELP---"
manager_main help
"""
        output, _ = self.run_universal(body)
        self.assertIn("PORTS=TCP 443,2053,8388 | UDP 8388,443", output)
        self.assertIn("vless://11111111-1111-1111-1111-111111111111@203.0.113.10:443?", output)
        self.assertIn("type=xhttp", output)
        self.assertIn("hysteria2://abcdef0123456789@203.0.113.10:443?", output)
        self.assertIn("ss://", output)
        self.assertIn("proxies:", output)
        self.assertIn("flow: xtls-rprx-vision", output)
        self.assertIn("network: xhttp", output)
        self.assertIn("type: hysteria2", output)
        self.assertIn("type: ss", output)
        self.assertIn("udp: true", output)
        self.assertIn("用法：vvr [子命令]", output)

    def test_main_auto_selects_safe_update_or_fresh_install(self):
        body = """
need_root() { :; }
detect_os() { OS_TYPE=debian; INIT_TYPE=systemd; }
installation_complete() { return 0; }
safe_update() { echo "__safe_update__"; }
full_install() { echo "__full_install__:$1"; }
main
"""
        output, _ = self.run_universal(body)
        self.assertIn("__safe_update__", output)
        self.assertNotIn("__full_install__", output)

    def test_multi_client_emails_and_per_user_export_isolation(self):
        body = """
need_root() { :; }
detect_os() { OS_TYPE=debian; INIT_TYPE=systemd; }
CONFIG_DIR="./etc-xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
META_FILE="${CONFIG_DIR}/vvr.env"
CLIENTS_FILE="${CONFIG_DIR}/vvr-clients.db"
XHTTP_CLIENTS_FILE="${CONFIG_DIR}/vvr-xhttp-clients.db"
HY2_CLIENTS_FILE="${CONFIG_DIR}/vvr-hy2-clients.db"
ROUTES_FILE="${CONFIG_DIR}/vvr-routing.rules"
mkdir -p "${CONFIG_DIR}"
cat > "${CLIENTS_FILE}" <<'C'
ipv4|11111111-1111-1111-1111-111111111111|alice
ipv4|22222222-2222-2222-2222-222222222222|bob
C
cat > "${XHTTP_CLIENTS_FILE}" <<'X'
33333333-3333-3333-3333-333333333333|alice
44444444-4444-4444-4444-444444444444|bob
X
cat > "${HY2_CLIENTS_FILE}" <<'H'
alicehy2pass1234|alice
bobhy2pass567890|bob
H
: > "${ROUTES_FILE}"
IPV4_PORT="443"; IPV6_PORT=""
SNI="www.sony.com"; REALITY_DEST="www.sony.com:443"
PRIVATE_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
PUBLIC_KEY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
SHORT_ID="0123456789abcdef"
SERVER_IPV4="203.0.113.10"; SERVER_IPV6=""
XHTTP_PORT="2053"; XHTTP_BIND="0.0.0.0"; XHTTP_FAMILY="ipv4"
XHTTP_UUID="33333333-3333-3333-3333-333333333333"
XHTTP_PATH="/sec"; XHTTP_MODE="auto"; XHTTP_NAME="alice"; XHTTP_SERVER_HOST="203.0.113.10"
HY2_PORT="443"; HY2_BIND="0.0.0.0"; HY2_FAMILY="ipv4"
HY2_PASSWORD="alicehy2pass1234"; HY2_SNI="bing.com"; HY2_CERT_MODE="selfsigned"
HY2_CERT_FILE="/etc/xray/hy2-cert.pem"; HY2_KEY_FILE="/etc/xray/hy2-key.pem"
HY2_INSECURE="1"; HY2_NAME="alice"; HY2_SERVER_HOST="203.0.113.10"
SS_PORT="8388"; SS_BIND="0.0.0.0"; SS_FAMILY="ipv4"; SS_NETWORK="tcp"
SS_METHOD="2022-blake3-aes-128-gcm"; SS_PASSWORD="dGVzdC1wYXNzd29yZC0xNg=="
SS_NAME="shared-ss"; SS_SERVER_HOST="203.0.113.10"
BASE_OUTBOUND_MODE="ipv4"; HAPPY_EYEBALLS_DELAY_MS="100"; BLOCK_PRIVATE_IP="1"
save_state
write_config
echo "---CONFIG---"
cat "${CONFIG_FILE}"
echo "---USERS---"
manager_main users
echo "---USER_ALICE---"
manager_main user alice
"""
        output, _ = self.run_universal(body)
        cfg_text = output.split("---CONFIG---\n", 1)[1].split("\n---USERS---", 1)[0]
        users_text = output.split("---USERS---\n", 1)[1].split("\n---USER_ALICE---", 1)[0]
        alice_text = output.split("---USER_ALICE---\n", 1)[1]

        cfg = json.loads(cfg_text)
        inbounds = {i["tag"]: i for i in cfg["inbounds"]}
        self.assertEqual(
            [c["email"] for c in inbounds["vless-in-ipv4"]["settings"]["clients"]],
            ["alice", "bob"],
        )
        self.assertEqual(
            [c["email"] for c in inbounds["vless-xhttp-in"]["settings"]["clients"]],
            ["alice", "bob"],
        )
        self.assertEqual(
            [c["email"] for c in inbounds["hysteria2-in"]["settings"]["clients"]],
            ["alice", "bob"],
        )
        self.assertEqual(users_text.strip().splitlines(), ["alice", "bob"])
        # Alice bundle contains only Alice's 3 protocols and never leaks Bob or shared SS
        self.assertIn("11111111-1111-1111-1111-111111111111", alice_text)
        self.assertIn("33333333-3333-3333-3333-333333333333", alice_text)
        self.assertIn("alicehy2pass1234", alice_text)
        self.assertIn('name: "alice-vision"', alice_text)
        self.assertIn('name: "alice-xhttp"', alice_text)
        self.assertIn('name: "alice-hy2"', alice_text)
        self.assertNotIn("22222222-2222-2222-2222-222222222222", alice_text)
        self.assertNotIn("44444444-4444-4444-4444-444444444444", alice_text)
        self.assertNotIn("bobhy2pass567890", alice_text)
        self.assertNotIn("\nss://", alice_text)
        self.assertNotIn("shared-ss", alice_text)
        self.assertNotIn("type: ss", alice_text)

    def test_private_ip_block_toggle_and_three_layer_routing_with_custom_outbounds(self):
        body = """
CONFIG_DIR="./etc-xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CLIENTS_FILE="${CONFIG_DIR}/vvr-clients.db"
HY2_CLIENTS_FILE="${CONFIG_DIR}/vvr-hy2-clients.db"
ROUTES_FILE="${CONFIG_DIR}/vvr-routing.rules"
OUTBOUNDS_FILE="${CONFIG_DIR}/vvr-outbounds.db"
USER_ROUTES_FILE="${CONFIG_DIR}/vvr-user-routes.db"
INBOUND_ROUTES_FILE="${CONFIG_DIR}/vvr-inbound-routes.db"
mkdir -p "${CONFIG_DIR}"
printf 'ipv4|11111111-1111-1111-1111-111111111111|alice\\n' > "${CLIENTS_FILE}"
printf 'hy2pass123456789|alice\\n' > "${HY2_CLIENTS_FILE}"
cat > "${OUTBOUNDS_FILE}" <<'OB'
proxy-us|ss|198.51.100.10|8388|aes-256-gcm|my-ss-pass
proxy-warp|socks|127.0.0.1|40000|warpuser|warppass
proxy-open|socks|198.51.100.20|1080||
OB
cat > "${ROUTES_FILE}" <<'RT'
proxy-us|geosite|openai
block|geosite|category-ads-all
RT
printf 'alice|proxy-warp\\n' > "${USER_ROUTES_FILE}"
printf 'hysteria2-in|ipv6\\n' > "${INBOUND_ROUTES_FILE}"

IPV4_PORT="443"; IPV6_PORT=""
SNI="www.sony.com"; REALITY_DEST="www.sony.com:443"
PRIVATE_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
PUBLIC_KEY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
SHORT_ID="0123456789abcdef"
HY2_PORT="443"; HY2_BIND="0.0.0.0"; HY2_FAMILY="ipv4"
HY2_PASSWORD="hy2pass123456789"; HY2_SNI="bing.com"; HY2_CERT_MODE="selfsigned"
HY2_CERT_FILE="/etc/xray/hy2-cert.pem"; HY2_KEY_FILE="/etc/xray/hy2-key.pem"
BASE_OUTBOUND_MODE="ipv4"; HAPPY_EYEBALLS_DELAY_MS="100"

BLOCK_PRIVATE_IP="1"
write_config
echo "---CFG_ON---"
cat "${CONFIG_FILE}"

BLOCK_PRIVATE_IP="0"
write_config
echo "---CFG_OFF---"
cat "${CONFIG_FILE}"
"""
        output, _ = self.run_universal(body)
        cfg_on = json.loads(output.split("---CFG_ON---\n", 1)[1].split("\n---CFG_OFF---", 1)[0])
        cfg_off = json.loads(output.split("---CFG_OFF---\n", 1)[1])

        # Custom outbounds rendered correctly
        outbounds = {o["tag"]: o for o in cfg_on["outbounds"]}
        self.assertEqual(outbounds["proxy-us"]["protocol"], "shadowsocks")
        self.assertEqual(outbounds["proxy-us"]["settings"]["servers"][0]["port"], 8388)
        self.assertEqual(outbounds["proxy-warp"]["protocol"], "socks")
        self.assertEqual(outbounds["proxy-warp"]["settings"]["servers"][0]["users"][0]["user"], "warpuser")
        self.assertNotIn("users", outbounds["proxy-open"]["settings"]["servers"][0])

        # Private IP protection ON -> IPIfNonMatch + private CIDR rule
        self.assertEqual(cfg_on["routing"]["domainStrategy"], "IPIfNonMatch")
        rules = cfg_on["routing"]["rules"]
        self.assertEqual(rules[0]["protocol"], ["bittorrent"])
        self.assertEqual(rules[1]["outboundTag"], "block")
        self.assertIn("127.0.0.0/8", rules[1]["ip"])
        self.assertIn("169.254.0.0/16", rules[1]["ip"])
        self.assertIn("::1/128", rules[1]["ip"])
        # Exact 3-layer routing priority order after protections:
        # Layer 1 (domain/geosite) -> Layer 2 (user) -> Layer 3 (inboundTag) -> Layer 4 (catch-all)
        self.assertEqual(rules[2], {"type": "field", "domain": ["geosite:openai"], "outboundTag": "proxy-us"})
        self.assertEqual(rules[3], {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"})
        self.assertEqual(rules[4], {"type": "field", "user": ["alice"], "outboundTag": "proxy-warp"})
        self.assertEqual(rules[5], {"type": "field", "inboundTag": ["hysteria2-in"], "outboundTag": "direct-ipv6"})
        self.assertEqual(rules[6]["outboundTag"], "direct-ipv4")

        # Private IP protection OFF -> AsIs + no IP block rule
        self.assertEqual(cfg_off["routing"]["domainStrategy"], "AsIs")
        self.assertFalse(any("ip" in r for r in cfg_off["routing"]["rules"]))

    def test_legacy_single_user_xhttp_and_hy2_migration_on_load_state(self):
        body = """
CONFIG_DIR="./etc-xray"
META_FILE="${CONFIG_DIR}/vvr.env"
CLIENTS_FILE="${CONFIG_DIR}/vvr-clients.db"
ROUTES_FILE="${CONFIG_DIR}/vvr-routing.rules"
mkdir -p "${CONFIG_DIR}"
cat > "${META_FILE}" <<'ENV'
XHTTP_PORT='2053'
XHTTP_UUID='55555555-5555-5555-5555-555555555555'
XHTTP_NAME='legacy-x'
HY2_PORT='443'
HY2_PASSWORD='legacy-hy2-password'
HY2_NAME='legacy-h'
HY2_CERT_FILE='/etc/xray/hy2-cert.pem'
HY2_KEY_FILE='/etc/xray/hy2-key.pem'
ENV
load_state
printf 'XC=%s|HC=%s\\n' "$(xhttp_client_count)" "$(hy2_client_count)"
cat "${XHTTP_CLIENTS_FILE}"
cat "${HY2_CLIENTS_FILE}"
"""
        output, _ = self.run_universal(body)
        self.assertIn("XC=1|HC=1", output)
        self.assertIn("55555555-5555-5555-5555-555555555555|legacy-x", output)
        self.assertIn("legacy-hy2-password|legacy-h", output)

    def test_write_service_low_mem_gomemlimit_and_openrc_ulimit_clamp(self):
        body = """
INIT_TYPE="openrc"
SERVICE_FILE="./xray.init"
effective_memory_kb() { echo 65536; }
ulimit() { echo 65535; }
write_service
cat "${SERVICE_FILE}"
"""
        output, _ = self.run_universal(body)
        self.assertIn('rc_ulimit="-n 65535"', output)
        self.assertIn('export GOGC="25"', output)
        self.assertIn('export GOMEMLIMIT="32MiB"', output)


if __name__ == "__main__":
    unittest.main()
