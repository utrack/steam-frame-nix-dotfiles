"""A wrist inbox backed by steamvr-notifyd on the headset's user bus."""
from datetime import datetime
import os
import threading
import time

import dbus
from cuff import Charm, ui
from cuff import widgets as w

SERVICE = "org.freedesktop.Notifications"
OBJECT = "/org/freedesktop/Notifications"
INTERFACE = "org.steamvr.Notifyd1"
PAGE_SIZE = 4
DETAIL_LINES = 12


class Client:
    def __init__(self, address=None):
        self.address = address or f"unix:path=/run/user/{os.getuid()}/bus"
        self.bus = None

    def proxy(self):
        if self.bus is None:
            self.bus = dbus.bus.BusConnection(self.address)
        owner = str(self.bus.get_name_owner(SERVICE))
        # Pin calls to this instance. A restarted daemon must not receive an old tap.
        obj = self.bus.get_object(owner, OBJECT, introspect=False)
        return owner, dbus.Interface(obj, INTERFACE)

    def read(self):
        owner, proxy = self.proxy()
        dnd, unread, entries = proxy.GetState(timeout=3)
        rows = [
            dict(id=int(id), timestamp=int(timestamp), app=str(app), summary=str(summary),
                 body=str(body), read=bool(read), quiet=bool(quiet))
            for id, timestamp, app, summary, body, read, quiet in entries
        ]
        return owner, bool(dnd), int(unread), rows

    def command(self, expected_owner, method, args):
        owner, proxy = self.proxy()
        if owner != expected_owner:
            raise RuntimeError("Notifications restarted. Please try again.")
        if method == "MarkRead":
            args = (dbus.Array(args[0], signature="u"),)
        elif method == "RemoveHistory":
            args = (dbus.UInt32(args[0]),)
        getattr(proxy, method)(*args, timeout=3)

    def disconnect(self):
        if self.bus is not None:
            self.bus.close()
        self.bus = None


def error_message(error):
    if isinstance(error, dbus.DBusException):
        if error.get_dbus_name() in ("org.freedesktop.DBus.Error.UnknownMethod",
                                     "org.freedesktop.DBus.Error.UnknownInterface"):
            return "Update the notification service to enable history and Do Not Disturb."
        return "Notification service unavailable. Retrying…"
    return str(error)


def timestamp_text(timestamp):
    try:
        value = datetime.fromtimestamp(timestamp / 1000)
        return value.strftime("%H:%M" if value.date() == datetime.now().date() else "%d %b %H:%M")
    except (OverflowError, OSError, ValueError):
        return ""


def wrap_text(text):
    """Pixel-wrap every character, including long URLs and newline-separated messages."""
    font, width = w.font("small"), (ui.W - 32) * ui.SCALE
    lines = []
    for paragraph in text.expandtabs(4).split("\n"):
        if not paragraph:
            lines.append("")
        while paragraph:
            low, high = 1, min(len(paragraph), 256)
            while low < high:
                mid = (low + high + 1) // 2
                if font.getlength(paragraph[:mid]) <= width:
                    low = mid
                else:
                    high = mid - 1
            count = low
            if count < len(paragraph):
                space = paragraph.rfind(" ", 0, count + 1)
                if space > 0:
                    count = space
            lines.append(paragraph[:count])
            paragraph = paragraph[count:].lstrip(" ")
    return lines or [""]


class Notifications(Charm):
    expand_page = True

    def __init__(self, ctx):
        super().__init__(ctx)
        self.client = Client()
        self._lock = threading.RLock()
        self._wake = threading.Event()
        self._owner = ""
        self._dnd = False
        self._unread = 0
        self._rows = []
        self._offset = 0
        self._selected = None
        self._detail_page = 0
        self._confirm_clear = False
        self._pending = None
        self._busy = False
        self._error = ""

    def start(self):
        self._wake.set()
        threading.Thread(target=self._poll, daemon=True, name="notifications").start()

    def _poll(self):
        while True:
            self._wake.wait(2)
            self._wake.clear()
            self._update()

    def _update(self):
        with self._lock:
            action, self._pending = self._pending, None
        try:
            if action:
                self.client.command(*action)
            owner, dnd, unread, rows = self.client.read()
            with self._lock:
                if owner != self._owner:
                    self._selected = None
                    self._confirm_clear = False
                    self._offset = 0
                self._owner, self._dnd, self._unread, self._rows = owner, dnd, unread, rows
                self._offset = min(self._offset, max(0, (len(rows) - 1) // PAGE_SIZE * PAGE_SIZE))
                if not any(r["id"] == self._selected for r in rows):
                    self._selected = None
                self._error = ""
        except (dbus.DBusException, OSError, RuntimeError, ValueError) as exc:
            self.client.disconnect()
            with self._lock:
                self._error = error_message(exc)
        finally:
            with self._lock:
                if action:
                    self._busy = False
            self.ctx.changed()

    def _queue(self, method, *args):
        self._pending = (self._owner, method, args)
        self._busy = True
        self._wake.set()

    def press(self, button_id):
        with self._lock:
            if button_id == "retry":
                self._wake.set()
            elif self._busy or self._error or not self._owner:
                return
            elif button_id in ("dnd", "quick:dnd"):
                self._queue("SetDoNotDisturb", not self._dnd)
            elif button_id == "mark-read":
                self._queue("MarkRead", [r["id"] for r in self._rows if not r["read"]])
            elif button_id == "clear":
                self._confirm_clear = True
            elif button_id == "cancel":
                self._confirm_clear = False
            elif button_id == "confirm-clear" and self._confirm_clear:
                self._confirm_clear = False
                self._queue("ClearHistory")
            elif button_id == "back":
                self._selected = None
            elif button_id in ("prev", "next"):
                if self._selected is not None:
                    row = next(r for r in self._rows if r["id"] == self._selected)
                    last = (len(self._detail(row)) - 1) // DETAIL_LINES
                    self._detail_page = max(0, min(last, self._detail_page + (1 if button_id == "next" else -1)))
                else:
                    last = max(0, (len(self._rows) - 1) // PAGE_SIZE * PAGE_SIZE)
                    self._offset = max(0, min(last, self._offset + (PAGE_SIZE if button_id == "next" else -PAGE_SIZE)))
            elif button_id.startswith(("open:", "remove:")):
                operation, value = button_id.split(":", 1)
                row = next((r for r in self._rows if str(r["id"]) == value), None)
                if row is None:
                    return
                if operation == "open":
                    self._selected, self._detail_page = row["id"], 0
                    if not row["read"]:
                        self._queue("MarkRead", [row["id"]])
                else:
                    self._queue("RemoveHistory", row["id"])
            else:
                return
        self.ctx.changed()

    def badge(self):
        with self._lock:
            if self._error:
                return "!"
            return ("99+" if self._unread > 99 else str(self._unread)) if self._unread else ("DND" if self._dnd else None)

    def quick(self, button):
        with self._lock:
            disabled = self._busy or self._error or not self._owner
            return {"text": "DND", "style": "off" if disabled else "on" if self._dnd else "normal"}

    def _detail(self, row):
        return wrap_text(row["summary"] + "\n\n" + row["body"])

    def _pager(self, index, total, enabled):
        return w.Row([
            w.Button("prev", "‹", width=36, style="normal" if enabled and index else "off"),
            w.Text(f"{index + 1} / {total}", size="small", align="center"),
            w.Button("next", "›", width=36, style="normal" if enabled and index + 1 < total else "off"),
        ], height=24)

    def page(self):
        with self._lock:
            return self._page()

    def _page(self):
        enabled = not self._busy and not self._error and bool(self._owner)
        normal = "normal" if enabled else "off"
        children = [w.Button("dnd", f"Do not disturb: {'On' if self._dnd else 'Off'}",
                             height=28, style=("active" if self._dnd else "normal") if enabled else "off")]
        if self._error or not self._owner:
            children += [w.Text(self._error or "Connecting to notifications…", size="small", lines=4),
                         w.Button("retry", "Retry")]
            return w.Column(children, gap=6)
        if self._confirm_clear:
            children += [w.Text("Clear all saved notifications?", size="body", lines=2),
                         w.Row([w.Button("cancel", "Cancel", style=normal),
                                w.Button("confirm-clear", "Clear all", style="warn" if enabled else "off")])]
            return w.Column(children, gap=6)
        if self._selected is not None:
            row = next(r for r in self._rows if r["id"] == self._selected)
            lines = self._detail(row)
            pages = (len(lines) + DETAIL_LINES - 1) // DETAIL_LINES
            self._detail_page = min(self._detail_page, pages - 1)
            children += [
                w.Row([w.Button("back", "‹ Inbox", style=normal),
                       w.Button(f"remove:{row['id']}", "Clear", style=normal)], height=24),
                w.Text(row["app"], size="small", colour="green", scroll=True),
                w.Text(timestamp_text(row["timestamp"]) + (" · Silenced" if row["quiet"] else ""),
                       size="tiny", colour="dim"),
            ]
            start = self._detail_page * DETAIL_LINES
            children += [w.Text(line or " ", size="small", height=15) for line in lines[start:start + DETAIL_LINES]]
            if pages > 1:
                children.append(self._pager(self._detail_page, pages, enabled))
            return w.Column(children, gap=4)
        children.append(w.Row([
            w.Button("mark-read", "Mark all read", style=normal if self._unread else "off"),
            w.Button("clear", "Clear all", style=normal if self._rows else "off"),
        ], height=24))
        if not self._rows:
            children.append(w.Text("No notifications yet.", size="small", colour="dim", height=36))
        for row in self._rows[self._offset:self._offset + PAGE_SIZE]:
            children.append(w.Column([
                w.Text(f"{row['app']} · {timestamp_text(row['timestamp'])}", size="tiny", colour="dim"),
                w.Button(f"open:{row['id']}", row["summary"] or row["body"] or "(No text)",
                         style=("accent" if not row["read"] else "normal") if enabled else "off", height=26),
                w.Text(row["body"], size="small", height=15),
            ], gap=2))
        if len(self._rows) > PAGE_SIZE:
            children.append(self._pager(self._offset // PAGE_SIZE,
                                        (len(self._rows) + PAGE_SIZE - 1) // PAGE_SIZE, enabled))
        return w.Column(children, gap=6)

    def sample(self):
        now = int(time.time() * 1000)
        self._owner, self._dnd, self._unread = ":sample", True, 2
        self._rows = [
            dict(id=3, timestamp=now, app="Messages", summary="Dinner at seven?",
                 body="I'll bring something for dessert.", read=False, quiet=True),
            dict(id=2, timestamp=now - 180000, app="Calendar", summary="Tomorrow · 09:30",
                 body="Coffee with Sam", read=False, quiet=True),
            dict(id=1, timestamp=now - 3600000, app="Downloads", summary="Download complete",
                 body="Your file is ready.", read=True, quiet=False),
        ]
