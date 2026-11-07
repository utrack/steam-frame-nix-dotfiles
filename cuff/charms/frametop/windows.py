"""Browse full displays and shared windows and control their Frametop panels."""
import json
import os
from pathlib import Path
import subprocess
import threading
import time

from cuff import Charm
from cuff import widgets as w

MAX_ROWS = 8


def request(folder, **message):
    env = dict(os.environ)
    for key in ("LD_LIBRARY_PATH", "LD_PRELOAD", "PYTHONPATH", "PYTHONHOME"):
        env.pop(key, None)
    result = subprocess.run(
        ["/usr/bin/python3", "-I", str(Path(__file__).with_name("bridge.py"))],
        input=json.dumps({"frametop": folder, **message}), capture_output=True,
        text=True, timeout=90, env=env,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip().splitlines()[-1] if result.stderr.strip()
                           else "Frametop's window controls could not start.")
    reply = json.loads(result.stdout)
    if not reply["ok"]:
        raise RuntimeError(reply["error"])
    return reply["result"]


def merge_windows(saved, available):
    """Keep saved/offline panels, and include new windows without duplicating them."""
    rows = {r["app"]: dict(r, saved=True) for r in saved}
    for window in available:
        if window["app"] in rows:
            rows[window["app"]]["title"] = window["title"]
        else:
            rows[window["app"]] = dict(window, connected=False, hidden=True, saved=False)
    return sorted(rows.values(), key=lambda row: row.get("kind") != "display")


def action_id(operation, host, app):
    return operation + ":" + json.dumps([host, app])


def operation_for(row, session):
    # A saved selection can outlive its session. Connect must be available to
    # resume it without a separate session control.
    return "disconnect" if row["connected"] and session != "stopped" else "connect"


def status(row, session, streams_supported=True):
    if not row["connected"]:
        return "Disconnected" if row["saved"] else "Available to stream"
    if session == "starting":
        return "Starting session"
    if session == "stopped":
        return "Stopped · tap Connect" if streams_supported else "Start the Frametop desktop"
    state = {"live": "Streaming", "starting": "Starting", "connecting": "Connecting",
             "queued": "Waiting to connect", "lost": "Lost · retrying"}.get(row["state"], row["state"])
    return state + (" · hidden" if row["hidden"] else "")


class Windows(Charm):
    expand_page = True

    def __init__(self, ctx):
        super().__init__(ctx)
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._pending = None
        self._busy = ""
        self._host = ""
        self._offset = 0
        self._hosts = []
        self._rows = []
        self._available = {}
        self._discovery_error = {}
        self._session = "stopped"
        self._streams_supported = False
        self._error = ""
        self._loaded = False
        self._discover_at = 0

    def start(self):
        self._wake.set()
        threading.Thread(target=self._poll, daemon=True, name="frametop-charm").start()

    def _poll(self):
        while True:
            self._wake.wait(2)
            self._wake.clear()
            self._update()

    def _update(self):
        """One worker iteration; a local state poll cannot clear a discovery failure."""
        with self._lock:
            action, self._pending = self._pending, None
            host = self._host
            refresh = time.monotonic() >= self._discover_at
            if not action and not self.ctx.shown and self._loaded:
                return
        error = ""
        folder = self.ctx.settings.get("frametop", "").strip()
        try:
            if action:
                request(folder, **action)
            state = request(folder, op="read", host=host, discover=refresh)
            with self._lock:
                self._hosts = state["hosts"]
                # A computer was selected while this read was in flight.
                if host == self._host:
                    self._host = state["host"]
                    if "available" in state:
                        self._available[self._host] = state["available"]
                    if "discovery_error" in state:
                        self._discovery_error[self._host] = state["discovery_error"]
                    if self._discovery_error.get(self._host):
                        self._available.pop(self._host, None)
                        self._rows = merge_windows(
                            [row for row in state["saved"] if row.get("kind") == "display"], [])
                    else:
                        self._rows = merge_windows(state["saved"], self._available.get(self._host, []))
                    self._offset = min(self._offset, max(0, len(self._rows) - MAX_ROWS))
                    self._session = state["session"]
                    self._streams_supported = state["streams_supported"]
                    if refresh:
                        self._discover_at = time.monotonic() + 15
                self._loaded = True
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
            error = "Frametop took too long to answer." if isinstance(exc, subprocess.TimeoutExpired) else str(exc)
            if action:
                self.ctx.notify(error)
        with self._lock:
            self._error = error
            # Don't clear a tap queued while a background read was in flight.
            if action:
                self._busy = ""
        self.ctx.changed()

    def press(self, button_id):
        with self._lock:
            if self._busy:
                return
            if button_id == "refresh":
                self._discover_at = 0
            elif button_id == "host" and self._hosts:
                index = self._hosts.index(self._host) if self._host in self._hosts else -1
                self._host = self._hosts[(index + 1) % len(self._hosts)]
                self._rows, self._offset, self._discover_at = [], 0, 0
            elif button_id in ("up", "down") and self._rows:
                step = MAX_ROWS if button_id == "down" else -MAX_ROWS
                self._offset = max(0, min(self._offset + step, len(self._rows) - MAX_ROWS))
            elif button_id.startswith(("connect:", "disconnect:")):
                operation, _, target = button_id.partition(":")
                host, app = json.loads(target)
                row = next((r for r in self._rows if r["app"] == app), None)
                if row is None or host != self._host or self._error:
                    return
                if row.get("kind") != "display" and self._discovery_error.get(host):
                    return
                if operation != operation_for(row, self._session):
                    return
                self._pending = {"op": operation, "host": self._host, "app": app}
                self._busy = "Connecting…" if operation == "connect" else "Disconnecting…"
            else:
                return
        self._wake.set()
        self.ctx.changed()

    def page(self):
        with self._lock:
            host, rows, offset = self._host, self._rows, self._offset
            busy, error, session, loaded = self._busy, self._error, self._session, self._loaded
            streams_supported = self._streams_supported
            discovery_error = self._discovery_error.get(host, "")
        header = w.Row([w.Button("host", host or "Computers", style="off" if busy else "normal"),
                        w.Button("refresh", "Refresh", width=64, style="off" if busy else "normal")], height=22)
        children = [header]
        if busy:
            children.append(w.Text(busy, size="small", colour="amber", lines=2))
        if error:
            return w.Column(children + [
                w.Text("Could not load streams", colour="red", size="body"),
                w.Text(error, size="small", lines=4),
                w.Text("Retrying automatically. Tap Refresh to retry now.", size="small", colour="dim", lines=2),
            ], gap=4)
        if not rows and not discovery_error:
            message = (
                "No displays or windows available. Add a display in Remote Displays or open an app on this computer." if host else
                "Add and pair a computer in Frametop Remote Displays." if loaded else "Reading Frametop…")
            return w.Column(children + [w.Text(message, size="small", lines=4, height=90)], gap=4)
        enabled = not busy
        for row in rows[offset:offset + MAX_ROWS]:
            operation = operation_for(row, session)
            children.append(w.Row([
                w.Column([
                    w.Text(row["title"], size="small", height=14),
                    w.Text(status(row, session, streams_supported), size="tiny", height=12,
                           colour="green" if session in ("streams", "desktop") and row.get("state") == "live" else "dim"),
                ], gap=0),
                w.Button(action_id(operation, host, row["app"]), operation.capitalize(), width=62,
                         style=("normal" if operation == "disconnect" else "accent") if enabled else "off"),
            ], height=28))
        if len(rows) > MAX_ROWS:
            children.append(w.Row([
                w.Button("up", "↑", width=32, style="normal" if offset and not busy else "off"),
                w.Text(f"{offset + 1}–{min(offset + MAX_ROWS, len(rows))} / {len(rows)}",
                       align="center", size="small"),
                w.Button("down", "↓", width=32,
                         style="normal" if offset + MAX_ROWS < len(rows) and not busy else "off"),
            ], height=22))
        if discovery_error:
            children.extend([
                w.Text("Windows unavailable", colour="amber", size="body"),
                w.Text(discovery_error, size="small", lines=4),
                w.Text("Retrying automatically. Tap Refresh to retry now.", size="small", colour="dim", lines=2),
            ])
        return w.Column(children, gap=4)

    def sample(self):
        self._host = "Workstation"
        self._hosts = [self._host]
        self._rows = [
            {"app": "window:{00000000-0000-0000-0000-000000000001}", "title": "Editor — project",
             "connected": True, "hidden": False, "saved": True, "state": "live"},
            {"app": "window:{00000000-0000-0000-0000-000000000002}", "title": "Browser",
             "connected": False, "hidden": True, "saved": True, "state": "not running"},
            {"app": "window:{00000000-0000-0000-0000-000000000003}", "title": "Discord",
             "connected": True, "hidden": False, "saved": True, "state": "live"},
            {"app": "window:{00000000-0000-0000-0000-000000000004}", "title": "Terminal",
             "connected": False, "hidden": True, "saved": False},
            {"app": "window:{00000000-0000-0000-0000-000000000005}", "title": "Files",
             "connected": False, "hidden": True, "saved": False},
            {"app": "window:{00000000-0000-0000-0000-000000000006}", "title": "Music",
             "connected": False, "hidden": True, "saved": False},
        ]
        self._rows.insert(0, {"app": "display:workstation-dp-1", "kind": "display", "title": "Display · DP-1",
                             "connected": False, "hidden": True, "saved": True, "state": "not running"})
        self._session = "streams"
        self._streams_supported = self._loaded = True
