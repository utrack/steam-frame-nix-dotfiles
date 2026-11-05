"""Offline checks: no real sockets, hosts, pairing keys or layout files are used."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

SOURCE = Path(os.environ.get("CUFF_FRAMETOP_SOURCE", Path(__file__).resolve().parents[1] / "charms/frametop"))
APP = "window:{00000000-0000-0000-0000-000000000001}"
OTHER = "window:{00000000-0000-0000-0000-000000000002}"


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


bridge = module("frametop_bridge", SOURCE / "bridge.py")
windows = module("frametop_windows", SOURCE / "windows.py")


class Controls(unittest.TestCase):
    def setUp(self):
        self.host = {"name": "Workstation", "address": "192.0.2.10", "displays": []}
        self.ft = Mock()
        self.ft.load_layout.return_value = {"hosts": [self.host]}
        self.ft.remote_displays.return_value = []
        self.ft.stream_size.side_effect = lambda w, h: (w // 2 * 2, h // 2 * 2)
        self.ft.list_window_streams.return_value = ("paired-client", [
            {"id": APP[7:], "title": "Editor\n$(touch unwanted)", "width": 1921, "height": 1081},
        ])

    def test_new_window_reuses_verified_pairing_and_sanitizes_metadata(self):
        bridge.control(self.ft, "Workstation", APP, True)
        self.ft.remote_command.assert_called_once_with([
            "add", "Workstation", "192.0.2.10", APP, "--client", "paired-client",
            "--label", "Editor $(touch unwanted)", "--size", "1920x1080",
            "--fps", "60", "--bitrate", "15000",
        ])

    def test_closed_window_does_not_add_or_pair(self):
        with self.assertRaisesRegex(RuntimeError, "closed"):
            bridge.control(self.ft, "Workstation", OTHER, True)
        self.ft.remote_command.assert_not_called()
        self.ft.set_hidden.assert_not_called()

    def test_failed_discovery_does_not_start_a_window(self):
        self.ft.list_window_streams.side_effect = RuntimeError("host offline")
        with self.assertRaisesRegex(RuntimeError, "offline"):
            bridge.control(self.ft, "Workstation", APP, True)
        self.ft.remote_command.assert_not_called()

    def test_existing_window_uses_current_screen_number_without_discovery(self):
        self.ft.remote_displays.return_value = [(117, self.host, {"id": "editor", "app": APP})]
        bridge.control(self.ft, "Workstation", APP.upper().replace("WINDOW:", "window:"), True)
        self.ft.set_hidden.assert_called_once_with("117", False)
        self.ft.remote_command.assert_called_once_with(["connect", "editor"])
        self.ft.list_window_streams.assert_not_called()

    def test_disconnect_is_scoped_to_window_and_host(self):
        second_host = {"name": "Other computer", "address": "192.0.2.11"}
        self.ft.remote_displays.return_value = [
            (105, self.host, {"id": "editor", "app": APP}),
            (106, self.host, {"id": "browser", "app": OTHER}),
            (107, second_host, {"id": "other-editor", "app": APP}),
            (108, self.host, {"id": "monitor", "app": "monitor"}),
        ]
        bridge.control(self.ft, "Workstation", APP, False)
        self.ft.set_hidden.assert_called_once_with("105", True)
        self.ft.remote_command.assert_called_once_with(["disconnect", "editor"])
        self.ft.list_window_streams.assert_not_called()

    def test_discovery_failure_keeps_saved_panels_controllable(self):
        self.ft.remote_displays.return_value = [
            (101, self.host, {"id": "editor", "app": APP, "hidden": True}),
        ]
        self.ft.screens_socket.return_value.ask.return_value = "ok 1 101:123:live:1920x1080"
        self.ft.list_window_streams.side_effect = RuntimeError("host offline")
        state = bridge.read_state(self.ft, "Workstation", True)
        self.assertTrue(state["desktop"])
        self.assertEqual(state["saved"][0]["app"], APP)
        self.assertEqual(state["saved"][0]["state"], "live")
        self.assertEqual(state["discovery_error"], "host offline")
        self.ft.screens_socket.return_value.close.assert_called_once()


class WristPage(unittest.TestCase):
    def setUp(self):
        self.ctx = Mock(settings={})
        self.charm = windows.Windows(self.ctx)
        self.charm.sample()

    def test_rapid_taps_cannot_queue_overlapping_actions(self):
        self.charm.press(windows.action_id("disconnect", "Workstation", APP))
        first = self.charm._pending.copy()
        self.charm.press(windows.action_id("connect", "Workstation", OTHER))
        self.charm.press("host")
        self.assertEqual(self.charm._pending, first)
        self.assertEqual(first, {"op": "disconnect", "host": "Workstation", "app": APP})

    def test_stale_button_cannot_target_the_replacement_row(self):
        self.charm._rows = [self.charm._rows[1]]
        self.charm.press(windows.action_id("disconnect", "Workstation", APP))
        self.assertIsNone(self.charm._pending)

    def test_stale_button_cannot_target_a_different_computer(self):
        self.charm._host = "Another workstation"
        self.charm.press(windows.action_id("disconnect", "Workstation", APP))
        self.assertIsNone(self.charm._pending)

    def test_page_and_touch_targets_fit_the_wrist_panel(self):
        ui = windows.w.ui
        image = ui.render(None, {}, None, [("frametop", "Windows")], "frametop", self.charm)
        layout = self.charm._layout
        x0, y0, x1, y1 = 16, ui.PAGE_Y + 4, ui.W - 16, image.height / ui.SCALE - 12
        self.assertGreater(image.height, ui.H_OPEN * ui.SCALE)
        for button, (left, top, right, bottom) in layout.buttons.items():
            with self.subTest(button=button):
                self.assertTrue(x0 <= left < right <= x1)
                self.assertTrue(y0 <= top < bottom <= y1)
        self.assertIn(windows.action_id("disconnect", "Workstation", APP), layout.buttons)
        self.assertIn(windows.action_id("connect", "Workstation", OTHER), layout.buttons)
        actions = [button for button in layout.buttons if button.startswith(("connect:", "disconnect:"))]
        self.assertEqual(len(actions), len(self.charm._rows))

    def test_button_changes_with_state_and_rejects_a_stale_action(self):
        self.charm._rows[0]["connected"] = False
        self.charm.press(windows.action_id("disconnect", "Workstation", APP))
        self.assertIsNone(self.charm._pending)
        layout = windows.w.Layout(self.charm.page())
        self.assertIn(windows.action_id("connect", "Workstation", APP), layout.buttons)
        self.assertNotIn(windows.action_id("disconnect", "Workstation", APP), layout.buttons)

    def test_long_list_can_reach_last_window_without_wrapping(self):
        for index in range(6, 19):
            self.charm._rows.append(dict(self.charm._rows[1], app=f"window:{index}", title=f"Window {index}"))
        self.charm.press("up")
        self.assertEqual(self.charm._offset, 0)
        for _ in range(4):
            self.charm.press("down")
        self.assertEqual(self.charm._offset, len(self.charm._rows) - windows.MAX_ROWS)
        layout = windows.w.Layout(self.charm.page())
        self.assertIn(windows.action_id("connect", "Workstation", self.charm._rows[-1]["app"]), layout.buttons)

    def test_discovery_merges_by_identity_and_preserves_disconnected_panels(self):
        rows = windows.merge_windows(
            [{"app": APP, "title": "Old title", "connected": False, "hidden": True}],
            [{"app": APP, "title": "New title"}, {"app": OTHER, "title": "Browser"}],
        )
        self.assertEqual(len(rows), 2)
        self.assertTrue(rows[0]["saved"])
        self.assertFalse(rows[0]["connected"])
        self.assertEqual(rows[0]["title"], "New title")
        self.assertFalse(rows[1]["saved"])

    def test_bridge_runs_without_shell_or_nix_library_paths(self):
        with patch.dict(os.environ, {"LD_LIBRARY_PATH": "/nix/test", "PYTHONPATH": "/nix/test"}):
            with patch.object(windows.subprocess, "run", return_value=Mock(
                    returncode=0, stdout='{"ok":true,"result":{}}')) as run:
                windows.request("/some folder", op="disconnect", host="A;B", app=APP)
        args, kwargs = run.call_args
        self.assertEqual(args[0][:2], ["/usr/bin/python3", "-I"])
        self.assertNotIn("shell", kwargs)
        self.assertNotIn("LD_LIBRARY_PATH", kwargs["env"])
        self.assertNotIn("PYTHONPATH", kwargs["env"])
        self.assertEqual(json.loads(kwargs["input"])["host"], "A;B")


@unittest.skipUnless(os.environ.get("FRAMETOP_TEST_ROOT"), "set FRAMETOP_TEST_ROOT for real ft-layout checks")
class LayoutIntegration(unittest.TestCase):
    """Exercise the real layout writer/commands against private files and a fake compositor."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.ft = module("cuff_test_layout", Path(os.environ["FRAMETOP_TEST_ROOT"]) / "layout/ft_layout.py")
        self.ft.LAYOUT_PATH = str(root / "layout.json")
        self.ft.CONF_PATH = str(root / "frametop.conf")
        self.socket = Mock()
        self.socket.ask.side_effect = lambda text, **_: "ok 0" if text == "remotes" else "ok restored"
        self.ft.screens_socket = Mock(return_value=self.socket)
        self.ft.run_stream = Mock(return_value=(0, "paired\n", ""))
        self.ft.remote_anchor = Mock(return_value=((0, 1, 0), 0))
        self.ft.place_remotes = Mock()
        self.display = {"id": "editor", "client": "saved-client", "app": APP, "label": "Editor",
                        "screen": 111, "off": True, "hidden": True, "size": [1920, 1080],
                        "pos": [1, 2, -3], "face": [0, 0], "metres": 1.5}
        self.other = {"id": "monitor", "app": "monitor", "client": "other-client", "screen": 101}
        self.host = {"name": "Workstation", "address": "192.0.2.10",
                     "input": False, "mic": True, "displays": [self.other, self.display]}
        self.ft.save_layout({"hosts": [self.host], "visibility": {"mode": "dashboard"}})
        self.before = self.ft.read_layout_file()

    def test_connect_disconnect_persists_both_flags_and_preserves_pose_and_other_panels(self):
        with contextlib.redirect_stdout(io.StringIO()):
            bridge.control(self.ft, "Workstation", APP, True)
        state = self.ft.read_layout_file()
        connected = state["hosts"][0]["displays"][1]
        self.assertFalse(connected.get("off", False))
        self.assertFalse(connected.get("hidden", False))
        self.assertEqual(connected["pos"], self.display["pos"])
        self.assertEqual(state["hosts"][0]["displays"][0], self.other)
        self.assertEqual(state["visibility"], self.before["visibility"])
        self.ft.run_stream.assert_not_called()
        self.assertTrue(any(c.args[0].startswith("remote 111 start ") for c in self.socket.ask.call_args_list))
        with contextlib.redirect_stdout(io.StringIO()):
            bridge.control(self.ft, "Workstation", APP, False)
        state = self.ft.read_layout_file()
        self.assertEqual(state["hosts"], self.before["hosts"])
        commands = [c.args[0] for c in self.socket.ask.call_args_list]
        self.assertLess(commands.index("conceal 111"), commands.index("remote 111 stop"))

    def test_adding_uses_the_real_layout_writer_and_keeps_saved_identity(self):
        self.ft.list_window_streams = Mock(return_value=("saved-client", [
            {"id": OTHER[7:], "title": "Browser", "width": 1601, "height": 901},
        ]))
        with contextlib.redirect_stdout(io.StringIO()):
            bridge.control(self.ft, "Workstation", OTHER, True)
        displays = self.ft.read_layout_file()["hosts"][0]["displays"]
        self.assertEqual(displays[:2], self.host["displays"])
        self.assertEqual(displays[2]["app"], OTHER)
        self.assertEqual(displays[2]["client"], "saved-client")
        self.assertEqual(displays[2]["size"], [1600, 900])
        self.assertFalse(displays[2].get("off", False))
        self.assertFalse(displays[2].get("hidden", False))
        self.ft.run_stream.assert_called_once_with("pair", "192.0.2.10", "--id", "saved-client", timeout=30)

    def test_corrupt_layout_is_never_overwritten(self):
        Path(self.ft.LAYOUT_PATH).write_text("{broken")
        with self.assertRaises(RuntimeError):
            bridge.control(self.ft, "Workstation", APP, True)
        self.assertEqual(Path(self.ft.LAYOUT_PATH).read_text(), "{broken")
        self.socket.ask.assert_not_called()
        self.ft.run_stream.assert_not_called()


if __name__ == "__main__":
    unittest.main()
