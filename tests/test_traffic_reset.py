import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import types
import unittest
from contextlib import closing
from datetime import datetime
from unittest.mock import patch


INSTALLER = Path(__file__).resolve().parents[1] / "install-xray-vvr.sh"
SOURCE = INSTALLER.read_text(encoding="utf-8")
TRAFFIC_SOURCE = SOURCE.split('cat > "${TRAFFIC_SCRIPT}" <<\'PY\'\n', 1)[1].split("\nPY\n", 1)[0]
INSTALLER_LIBRARY = SOURCE.rsplit('\ncase "$(basename "$0")" in', 1)[0]


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


class TrafficResetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.settings = Path(self.temp.name) / "settings.env"
        self.traffic = types.ModuleType("vvr_traffic_test")
        exec(compile(TRAFFIC_SOURCE, "vvr-traffic.py", "exec"), self.traffic.__dict__)
        self.traffic.DB = str(Path(self.temp.name) / "traffic.db")
        self.traffic.SETTINGS_FILE = str(self.settings)
        self.traffic.xray_stats = lambda: (110, 220)
        self.clock = patch.object(self.traffic, "datetime", wraps=datetime).start()
        self.addCleanup(patch.stopall)
        self.clock.now.return_value = datetime(2026, 9, 5, 12, 30)

    def configure(self, auto="0", collection="1"):
        self.settings.write_text(
            f"RESET_DAY='1'\nRESET_HOUR='0'\nRESET_MINUTE='0'\n"
            f"COLLECTION_ENABLED='{collection}'\nAUTO_RESET_ENABLED='{auto}'\n",
            encoding="utf-8",
        )

    def seed(self):
        with closing(self.traffic.db_connect()) as db:
            db.execute(
                "INSERT INTO traffic VALUES(1,?,?,?,?,?,?)",
                ("2026-08-01 00:00", 1000, 2000, 100, 200, "2026-08-31T23:59:00"),
            )
            db.commit()

    def test_legacy_settings_default_to_monthly_reset(self):
        for content in (None, "COLLECTION_ENABLED='1'\n"):
            with self.subTest(content=content):
                if content is not None:
                    self.settings.write_text(content, encoding="utf-8")
                self.assertTrue(self.traffic.reset_settings()["auto_reset_enabled"])
        self.seed()
        result = self.traffic.collect()
        self.assertEqual(result["period_start"], "2026-09-01 00:00")
        # Previous period ended at last_up=100, last_down=200; current Xray stats
        # are (110, 220), so only the new-period delta (10 + 20 = 30) is counted.
        self.assertEqual(result["up"], 10)
        self.assertEqual(result["down"], 20)
        self.assertEqual(result["total"], 30)

    def test_monthly_reset_after_xray_restart_counts_new_counter(self):
        self.seed()
        self.traffic.xray_stats = lambda: (5, 15)
        result = self.traffic.collect()
        self.assertEqual(result["period_start"], "2026-09-01 00:00")
        self.assertEqual((result["up"], result["down"], result["total"]), (5, 15, 20))

    def test_disabled_preserves_period_and_collects_across_years(self):
        self.configure()
        self.seed()
        for current in (datetime(2026, 9, 5), datetime(2027, 1, 5)):
            self.clock.now.return_value = current
            result = self.traffic.collect()
            self.assertEqual(result["period_start"], "2026-08-01 00:00")
            self.assertEqual((result["up"], result["down"]), (1010, 2020))
            self.assertTrue(result["collection_enabled"])

    def test_disabled_preserves_saved_data_when_stats_unavailable(self):
        self.configure()
        self.seed()
        self.traffic.xray_stats = lambda: (None, None)
        self.assertEqual(self.traffic.collect()["total"], 3000)

    def test_collection_switch_and_force_remain_independent(self):
        self.configure(collection="0")
        self.seed()
        self.assertEqual(self.traffic.collect()["total"], 3000)
        self.assertEqual(self.traffic.collect(force=True)["total"], 3030)

    def test_counter_restart_keeps_accumulated_traffic(self):
        self.configure()
        self.seed()
        self.traffic.xray_stats = lambda: (5, 10)
        self.assertEqual(self.traffic.collect()["total"], 3015)

    def test_new_database_starts_persistent_period(self):
        self.configure()
        first = self.traffic.collect()
        self.clock.now.return_value = datetime(2026, 10, 2)
        self.assertEqual(self.traffic.collect()["period_start"], first["period_start"])
        self.assertEqual(first["period_start"], "2026-09-05 12:30")

    def test_manual_reset_records_baseline_and_new_period(self):
        self.configure()
        self.seed()
        result = self.traffic.reset()
        self.assertEqual(result["total"], 0)
        self.assertEqual(result["period_start"], "2026-09-05 12:30")
        self.traffic.xray_stats = lambda: (115, 230)
        self.clock.now.return_value = datetime(2026, 10, 5)
        self.assertEqual(self.traffic.collect()["total"], 15)

    def test_multi_protocol_and_per_user_breakdown_excludes_internal_inbounds(self):
        # Restore real xray_stats bound to mocked subprocess output.
        self.traffic = types.ModuleType("vvr_traffic_multi")
        exec(compile(TRAFFIC_SOURCE, "vvr-traffic.py", "exec"), self.traffic.__dict__)
        self.traffic.DB = str(Path(self.temp.name) / "traffic-multi.db")
        self.traffic.SETTINGS_FILE = str(self.settings)
        self.configure(auto="1", collection="1")

        sample_stats = {
            "stat": [
                {"name": "inbound>>>vless-in-ipv4>>>traffic>>>uplink", "value": "100"},
                {"name": "inbound>>>vless-in-ipv4>>>traffic>>>downlink", "value": "500"},
                {"name": "inbound>>>hysteria2-in>>>traffic>>>uplink", "value": "50"},
                {"name": "inbound>>>hysteria2-in>>>traffic>>>downlink", "value": "250"},
                {"name": "inbound>>>api>>>traffic>>>uplink", "value": "99999"},
                {"name": "inbound>>>reality-fallback>>>traffic>>>downlink", "value": "88888"},
                {"name": "user>>>alice>>>traffic>>>uplink", "value": "120"},
                {"name": "user>>>alice>>>traffic>>>downlink", "value": "600"},
                {"name": "user>>>bob>>>traffic>>>uplink", "value": "30"},
                {"name": "user>>>bob>>>traffic>>>downlink", "value": "150"},
            ]
        }
        fake_res = types.SimpleNamespace(stdout=json.dumps(sample_stats))
        with patch.object(self.traffic.subprocess, "run", return_value=fake_res):
            res = self.traffic.collect()
        # Internal api & reality-fallback MUST be excluded from totals and inbounds
        self.assertEqual((res["up"], res["down"], res["total"]), (150, 750, 900))
        self.assertEqual(res["inbounds"]["vless-in-ipv4"]["total"], 600)
        self.assertEqual(res["inbounds"]["hysteria2-in"]["total"], 300)
        self.assertNotIn("api", res["inbounds"])
        self.assertNotIn("reality-fallback", res["inbounds"])
        self.assertEqual(res["users"]["alice"]["total"], 720)
        self.assertEqual(res["users"]["bob"]["total"], 180)

        # Reset clears total and breakdowns using current counter as baseline
        with patch.object(self.traffic.subprocess, "run", return_value=fake_res):
            self.traffic.reset()
            after_reset = self.traffic.collect()
        self.assertEqual(after_reset["total"], 0)
        self.assertEqual(after_reset["users"]["alice"]["total"], 0)

    def request(self, method, path):
        handler = object.__new__(self.traffic.Handler)
        handler.path = path
        handler.headers = {"Authorization": "Bearer test-token"}
        handler.wfile = io.BytesIO()
        handler.send_response = lambda status: self.assertEqual(status, 200)
        handler.send_header = lambda *_: None
        handler.end_headers = lambda: None
        self.traffic.read_token = lambda: "test-token"
        getattr(handler, "do_" + method)()
        return json.loads(handler.wfile.getvalue())

    def test_misub_and_native_api_read_and_reset_when_disabled(self):
        self.configure()
        self.seed()
        response = self.request("GET", "/panel/api/inbounds/list")
        self.assertTrue(response["success"])
        self.assertEqual(response["obj"][0]["total"], 3030)
        for endpoint in ("/panel/api/inbounds/resetAllTraffics", "/api/traffic/reset"):
            self.assertTrue(self.request("POST", endpoint)["success"])
            self.assertEqual(self.request("GET", "/api/traffic")["total"], 0)

    def test_reenabling_resumes_monthly_period(self):
        self.configure()
        self.seed()
        self.traffic.collect()
        self.configure(auto="1")
        self.assertEqual(self.traffic.collect()["period_start"], "2026-09-01 00:00")


@unittest.skipUnless(SHELL, "POSIX shell not found; set VVR_TEST_SHELL")
class TrafficModuleShellTests(unittest.TestCase):
    def run_shell(self, body, input_text="", settings=""):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "settings.env").write_text(settings, encoding="utf-8", newline="\n")
            script = (
                INSTALLER_LIBRARY
                + "\nCONFIG_DIR=./etc-xray\nTRAFFIC_SETTINGS_FILE=./settings.env\n"
                + "ok() { :; }\nwarn() { :; }\n"
                + "traffic_collector_enable() { return 0; }\n"
                + "traffic_collector_disable() { return 0; }\n"
                + body
            )
            script_path = Path(directory, "traffic-shell.sh")
            script_path.write_text(script, encoding="utf-8", newline="\n")
            result = subprocess.run(
                [SHELL, str(script_path)],
                input=input_text.encode("utf-8"),
                capture_output=True,
                cwd=directory,
            )
            output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
            self.assertEqual(result.returncode, 0, output)
            return output

    def test_traffic_disabled_by_default_and_enabled_adds_stats_api(self):
        body = """
CONFIG_DIR="./etc-xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CLIENTS_FILE="${CONFIG_DIR}/vvr-clients.db"
ROUTES_FILE="${CONFIG_DIR}/vvr-routing.rules"
mkdir -p "${CONFIG_DIR}"
printf 'ipv4|11111111-1111-1111-1111-111111111111|alice\\n' > "${CLIENTS_FILE}"
: > "${ROUTES_FILE}"
IPV4_PORT="443"; IPV6_PORT=""
SNI="www.sony.com"; REALITY_DEST="www.sony.com:443"
PRIVATE_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
PUBLIC_KEY="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
SHORT_ID="0123456789abcdef"
BASE_OUTBOUND_MODE="ipv4"; HAPPY_EYEBALLS_DELAY_MS="100"; BLOCK_PRIVATE_IP="1"

TRAFFIC_ENABLED="${DEFAULT_TRAFFIC_ENABLED}"
write_config
echo "---OFF---"
cat "${CONFIG_FILE}"

TRAFFIC_ENABLED="1"
XRAY_API_PORT="10085"
write_config
echo "---ON---"
cat "${CONFIG_FILE}"
"""
        output = self.run_shell(body)
        cfg_off = json.loads(output.split("---OFF---\n", 1)[1].split("\n---ON---", 1)[0])
        cfg_on = json.loads(output.split("---ON---\n", 1)[1])

        self.assertNotIn("stats", cfg_off)
        self.assertNotIn("api", cfg_off)
        self.assertFalse(any(i["tag"] == "api" for i in cfg_off["inbounds"]))

        self.assertIn("stats", cfg_on)
        self.assertEqual(cfg_on["api"], {"tag": "api", "services": ["StatsService"]})
        self.assertTrue(cfg_on["policy"]["levels"]["0"]["statsUserUplink"])
        api_in = [i for i in cfg_on["inbounds"] if i["tag"] == "api"]
        self.assertEqual(len(api_in), 1)
        self.assertEqual(api_in[0]["port"], 10085)
        self.assertEqual(cfg_on["routing"]["rules"][0], {"type": "field", "inboundTag": ["api"], "outboundTag": "api"})

    def test_disabling_preserves_schedule_and_collection(self):
        self.run_shell(
            'configure_traffic_schedule\nload_traffic_settings\n'
            '[ "$AUTO_RESET_ENABLED:$COLLECTION_ENABLED:$RESET_DAY" = "0:1:15" ]\n',
            "2\n",
            "RESET_DAY='15'\n",
        )

    def test_enabling_preserves_disabled_collection(self):
        self.run_shell(
            'configure_traffic_schedule\nload_traffic_settings\n'
            '[ "$AUTO_RESET_ENABLED:$COLLECTION_ENABLED:$RESET_DAY:$RESET_HOUR:$RESET_MINUTE" = "1:0:8:9:5" ]\n',
            "1\n8\n09:05\n",
            "AUTO_RESET_ENABLED='0'\nCOLLECTION_ENABLED='0'\n",
        )

    def test_collection_changes_preserve_disabled_reset(self):
        for choice in ("1", "2"):
            self.run_shell(
                'configure_traffic_collection\nload_traffic_settings\n[ "$AUTO_RESET_ENABLED" = "0" ]\n',
                choice + "\ny\n",
                "AUTO_RESET_ENABLED='0'\n",
            )

    def test_cancel_does_not_enable_reset(self):
        self.run_shell(
            'configure_traffic_schedule\n[ "$MENU_RETURNED" = "1" ]\n'
            'load_traffic_settings\n[ "$AUTO_RESET_ENABLED" = "0" ]\n',
            "1\n0\n",
            "AUTO_RESET_ENABLED='0'\n",
        )


if __name__ == "__main__":
    unittest.main()
