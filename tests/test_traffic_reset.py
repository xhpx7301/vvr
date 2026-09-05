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


INSTALLER = Path(__file__).resolve().parents[1] / "install-xray-vless-ipv6-youtube-debian.sh"
SOURCE = INSTALLER.read_text(encoding="utf-8")
TRAFFIC_SOURCE = SOURCE.split('cat > "${TRAFFIC_SCRIPT}" <<\'PY\'\n', 1)[1].split("\nPY\n", 1)[0]
MANAGER_SOURCE = SOURCE.split('cat > "${MANAGER_BIN}" <<\'EOF\'\n', 1)[1].split("\nEOF\n", 1)[0]
MANAGER_LIBRARY = MANAGER_SOURCE.rsplit('\nmain "$@"', 1)[0]


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
        self.assertEqual(result["total"], 330)

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


SHELL = os.environ.get("VVR_TEST_SHELL") or shutil.which("sh")


@unittest.skipUnless(SHELL, "Set VVR_TEST_SHELL to a POSIX shell to test menu settings")
class MenuSettingsTests(unittest.TestCase):
    def run_shell(self, body, input_text="", settings=""):
        functions = MANAGER_SOURCE.split("load_traffic_settings() {", 1)[1].split("load_traffic_api_settings() {", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "settings.env").write_text(settings, encoding="utf-8", newline="\n")
            script = (
                "set -eu\nexport PATH=/usr/bin:/bin:$PATH\nTRAFFIC_SETTINGS_FILE=./settings.env\n"
                "ok() { :; }\nwarn() { :; }\nsystemctl() { :; }\n"
                "load_traffic_settings() {" + functions + body
            )
            result = subprocess.run(
                [SHELL, "-c", script], input=input_text.encode("utf-8"),
                capture_output=True, cwd=directory,
            )
            self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode("utf-8", errors="replace"))

    def test_installer_and_generated_manager_syntax(self):
        for source in (SOURCE, MANAGER_SOURCE):
            result = subprocess.run([SHELL, "-n"], input=source.encode("utf-8"), capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_disabling_preserves_schedule_and_collection(self):
        self.run_shell(
            'configure_traffic_schedule\nload_traffic_settings\n'
            '[ "$AUTO_RESET_ENABLED:$COLLECTION_ENABLED:$RESET_DAY" = "0:1:15" ]\n',
            "2\n", "RESET_DAY='15'\n",
        )

    def test_enabling_preserves_disabled_collection(self):
        self.run_shell(
            'configure_traffic_schedule\nload_traffic_settings\n'
            '[ "$AUTO_RESET_ENABLED:$COLLECTION_ENABLED:$RESET_DAY:$RESET_HOUR:$RESET_MINUTE" = "1:0:8:9:5" ]\n',
            "1\n8\n09:05\n", "AUTO_RESET_ENABLED='0'\nCOLLECTION_ENABLED='0'\n",
        )

    def test_collection_changes_preserve_disabled_reset(self):
        for choice in ("1", "2"):
            self.run_shell(
                'configure_traffic_collection\nload_traffic_settings\n[ "$AUTO_RESET_ENABLED" = "0" ]\n',
                choice + "\ny\n", "AUTO_RESET_ENABLED='0'\n",
            )

    def test_cancel_does_not_enable_reset(self):
        self.run_shell(
            'configure_traffic_schedule\n[ "$MENU_RETURNED" = "1" ]\n'
            'load_traffic_settings\n[ "$AUTO_RESET_ENABLED" = "0" ]\n',
            "1\n0\n", "AUTO_RESET_ENABLED='0'\n",
        )


@unittest.skipUnless(SHELL, "Set VVR_TEST_SHELL to a POSIX shell to test menu navigation")
class MenuNavigationTests(unittest.TestCase):
    def assert_outbound_menu_returns(self, choice):
        with tempfile.TemporaryDirectory() as directory:
            script = (
                MANAGER_LIBRARY
                + "\nROUTES_FILE=./routes.rules\nBASE_OUTBOUND_MODE=ipv4\n"
                + "HAPPY_EYEBALLS_DELAY_MS=100\n"
                + "load_state() { :; }\nensure_routes_file() { :; }\n"
                + "refresh_network_status() { :; }\nshow_network_status() { :; }\n"
                + "apply_config() { :; }\n"
                + "manage_outbound_strategy\nprintf '__menu_returned__\\n'\n"
            )
            script_path = Path(directory, "menu-navigation.sh")
            script_path.write_text(script, encoding="utf-8", newline="\n")
            result = subprocess.run(
                [SHELL, str(script_path)], input=(choice + "\n0\n0\n").encode("utf-8"),
                capture_output=True, cwd=directory,
            )
            output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("__menu_returned__", output)

    def test_cancelling_outbound_selector_returns_to_strategy_menu(self):
        for choice in ("1", "3", "4"):
            with self.subTest(choice=choice):
                self.assert_outbound_menu_returns(choice)


if __name__ == "__main__":
    unittest.main()
