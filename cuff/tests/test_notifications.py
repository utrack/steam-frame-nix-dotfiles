"""Notification controls and rendering; optional end-to-end test on a private bus."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock

import dbus
from cuff import ui
from cuff import widgets as w

SOURCE = Path(os.environ.get("CUFF_NOTIFICATIONS_SOURCE",
                            Path(__file__).resolve().parents[1] / "charms/notifications"))
spec = importlib.util.spec_from_file_location("notifications_charm", SOURCE / "notifications.py")
notifications = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notifications)


class Controls(unittest.TestCase):
    def setUp(self):
        self.charm = notifications.Notifications(Mock())
        self.charm.sample()
        self.charm.client = Mock()
        self.charm.client.read.return_value = (
            self.charm._owner, self.charm._dnd, self.charm._unread, self.charm._rows,
        )

    def test_toggle_waits_for_confirmation_and_duplicate_taps_do_not_queue(self):
        self.charm.press("quick:dnd")
        first = self.charm._pending
        self.charm.press("dnd")
        self.assertEqual(first, self.charm._pending)
        self.assertTrue(self.charm._dnd)
        self.assertEqual(self.charm.quick("dnd")["style"], "off")
        self.charm.client.read.return_value = (":sample", False, 2, self.charm._rows)
        self.charm._update()
        self.charm.client.command.assert_called_once_with(":sample", "SetDoNotDisturb", (False,))
        self.assertFalse(self.charm._dnd)
        self.assertFalse(self.charm._busy)

    def test_mark_read_uses_displayed_ids_and_clear_requires_confirmation(self):
        self.charm.press("confirm-clear")
        self.assertIsNone(self.charm._pending)
        self.charm.press("clear")
        self.charm.press("cancel")
        self.assertIsNone(self.charm._pending)
        self.charm.press("mark-read")
        self.assertEqual(self.charm._pending, (":sample", "MarkRead", ([3, 2],)))

    def test_failure_disables_controls_and_does_not_retry_a_write(self):
        self.charm.press("dnd")
        self.charm.client.command.side_effect = RuntimeError("Disconnected")
        self.charm._update()
        self.assertEqual(self.charm.badge(), "!")
        self.assertEqual(self.charm.quick("dnd")["style"], "off")
        self.charm.press("confirm-clear")
        self.assertIsNone(self.charm._pending)
        self.charm._update()
        self.assertEqual(self.charm.client.command.call_count, 1)
        self.assertFalse(self.charm._error)

    def test_restart_discards_selection_and_confirmation(self):
        self.charm._selected, self.charm._confirm_clear = 3, True
        self.charm.client.read.return_value = (":new", True, 0, [])
        self.charm._update()
        self.assertIsNone(self.charm._selected)
        self.assertFalse(self.charm._confirm_clear)

    def test_client_rejects_actions_for_a_replaced_daemon(self):
        client = notifications.Client()
        proxy = Mock()
        client.proxy = Mock(return_value=(":new", proxy))
        with self.assertRaisesRegex(RuntimeError, "restarted"):
            client.command(":old", "ClearHistory", ())
        proxy.ClearHistory.assert_not_called()

    def test_long_message_and_urls_can_be_read_to_the_end(self):
        message = "First line\n\n" + "https://example.org/" + "abcdef" * 100 + "\n" + "界" * 80
        lines = notifications.wrap_text(message)
        self.assertEqual("".join(lines), message.replace("\n", ""))
        self.assertTrue(all(w.font("small").getlength(line) <= (ui.W - 32) * ui.SCALE
                            for line in lines))
        self.charm._rows[0]["body"] = message
        self.charm._selected = 3
        for _ in range(100):
            self.charm.press("next")
        last = (len(self.charm._detail(self.charm._rows[0])) - 1) // notifications.DETAIL_LINES
        self.assertEqual(self.charm._detail_page, last)

    def test_rendered_inbox_and_detail_controls_fit_and_are_touchable(self):
        for detail in (False, True):
            with self.subTest(detail=detail):
                self.charm._selected = 3 if detail else None
                image = ui.render(None, {}, None, [("notifications", "Notices")],
                                  "notifications", self.charm)
                buttons = self.charm._layout.buttons
                self.assertIn("dnd", buttons)
                self.assertIn("back" if detail else "open:3", buttons)
                self.assertIn("remove:3" if detail else "clear", buttons)
                for x0, y0, x1, y1 in buttons.values():
                    self.assertGreater(x1, x0)
                    self.assertGreater(y1, y0)
                    self.assertLessEqual(y1, image.height / ui.SCALE)


@unittest.skipUnless(os.environ.get("CUFF_NOTIFYD_TEST_BINARY"), "requires a private bus and built notifyd")
class Integration(unittest.TestCase):
    def test_charm_controls_the_real_daemon_and_recovers_from_restart(self):
        with tempfile.TemporaryDirectory() as state, tempfile.TemporaryFile() as log:
            client = notifications.Client(os.environ["DBUS_SESSION_BUS_ADDRESS"])
            bus = dbus.SessionBus(private=True)
            process = None

            def start():
                child = subprocess.Popen(
                    [os.environ["CUFF_NOTIFYD_TEST_BINARY"], "--no-vr"],
                    env=dict(os.environ, XDG_STATE_HOME=state), stderr=log,
                )
                deadline = time.monotonic() + 5
                while not bus.name_has_owner(notifications.SERVICE):
                    if child.poll() is not None or time.monotonic() > deadline:
                        child.terminate()
                        child.wait(timeout=5)
                        self.fail("test daemon did not start")
                    time.sleep(.02)
                return child

            try:
                process = start()
                charm = notifications.Notifications(Mock())
                charm.client = client
                charm._update()
                self.assertFalse(charm._error)
                charm.press("quick:dnd")
                charm._update()
                self.assertTrue(charm._dnd)
                obj = bus.get_object(notifications.SERVICE, notifications.OBJECT, introspect=False)
                notes = dbus.Interface(obj, notifications.SERVICE)
                id = int(notes.Notify("Phone", dbus.UInt32(0), "", "From your phone", "<b>Hello</b>",
                                      dbus.Array([], signature="s"), dbus.Dictionary({}, signature="sv"),
                                      dbus.Int32(0)))
                charm._update()
                self.assertEqual(charm.badge(), "1")
                self.assertEqual(charm._rows[0]["body"], "Hello")
                self.assertTrue(charm._rows[0]["quiet"])
                charm.press(f"open:{id}")
                charm._update()
                self.assertEqual(charm.badge(), "DND")
                old_owner = charm._owner
                process.terminate()
                process.wait(timeout=5)
                process = start()
                charm._update()
                self.assertNotEqual(charm._owner, old_owner)
                self.assertEqual(charm._rows[0]["id"], id)
                self.assertIsNone(charm._selected)
                charm.press(f"remove:{id}")
                charm._update()
                self.assertEqual(charm._rows, [])
                charm.press("dnd")
                charm._update()
                self.assertFalse(charm._dnd)
            finally:
                if process is not None:
                    process.terminate()
                    process.wait(timeout=5)
                client.disconnect()
                bus.close()


if __name__ == "__main__":
    unittest.main()
