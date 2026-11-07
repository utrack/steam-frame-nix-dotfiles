"""One JSON request on stdin, one JSON reply on stdout, using the installed ft-layout.

Run with the host's Python, isolated from Cuff's Nix Python and library paths.
All writes go through Frametop's existing layout operations; this charm neither
owns ft-stream processes nor changes pairing, input, or global visibility settings.
"""
import contextlib
import importlib
import json
import os
from pathlib import Path
import re
import sys
import uuid


def load_frametop(folder):
    roots = [Path(folder).expanduser()] if folder else [
        Path.home() / ".local/share/frametop/releases/current",
        Path.home() / "frametop",
        Path.home() / "dev/frametop",
    ]
    for root in roots:
        if (root / "layout/ft_layout.py").is_file():
            sys.path.insert(0, str(root / "layout"))
            ft = importlib.import_module("ft_layout")
            if not hasattr(ft, "list_window_streams"):
                raise RuntimeError("Update Frametop to a version with direct window streaming.")
            return ft
    raise RuntimeError("Frametop not found. Set its folder in Cuff's Frametop windows settings.")


def window_app(value):
    """Canonical KWin UUID, as ft-layout and the window service expect it."""
    return "window:{" + str(uuid.UUID(value.removeprefix("window:").strip("{}"))) + "}"


def title(value):
    return re.sub(r"[\x00-\x1f\x7f]", " ", str(value)).strip()[:80] or "Window"


def discover(ft, host):
    client, windows = ft.list_window_streams(host, timeout=8)
    out = []
    for window in windows:
        try:
            app = window_app(window["id"])
            width, height = ft.stream_size(
                max(64, min(8192, int(window["width"]))),
                max(64, min(8192, int(window["height"]))),
            )
        except (KeyError, TypeError, ValueError, AttributeError):
            continue
        out.append({"app": app, "title": title(window.get("title") or "Window"),
                    "width": width, "height": height})
    return client, out


def read_state(ft, name="", refresh=False):
    # Unlike load_layout's UI fallback, report broken config instead of an empty list.
    ft.read_layout_file()
    layout = ft.load_layout()
    hosts = [h for h in layout.get("hosts", []) if h.get("name") and h.get("address")]
    host = next((h for h in hosts if h["name"] == name), None)
    if not name and hosts:
        host = hosts[0]
    sock = ft.screens_socket()
    try:
        reply = sock.ask("remotes", timeout=0.5)
        states = {int(e.split(":")[0]): e.split(":")[2] for e in reply.split()[2:]}
        desktop = True
    except RuntimeError:
        desktop, states = False, {}
    finally:
        sock.close()
    saved = []
    for number, h, display in ft.remote_displays(layout):
        if h is not host or not display.get("app", "").startswith("window:"):
            continue
        try:
            app = window_app(display["app"])
        except ValueError:
            continue
        saved.append({"app": app, "title": title(display.get("label") or display["id"]),
                      "connected": not display.get("off", False),
                      "hidden": bool(display.get("hidden")),
                      "state": states.get(number, "not running")})
    result = {"hosts": [h["name"] for h in hosts], "host": host["name"] if host else "",
              "desktop": desktop, "saved": saved}
    if refresh and host:
        try:
            _, result["available"] = discover(ft, host)
            result["discovery_error"] = ""
        except (RuntimeError, OSError, ValueError) as exc:
            # The UI hides saved panels too until discovery succeeds again.
            result["discovery_error"] = str(exc)
    return result


def control(ft, name, app, connect):
    app = window_app(app)
    ft.read_layout_file()
    layout = ft.load_layout()
    host = next((h for h in layout.get("hosts", []) if h.get("name") == name), None)
    if not host:
        raise RuntimeError("This computer is no longer configured. Refresh the window list.")
    found = []
    for number, h, display in ft.remote_displays(layout):
        if h is host and display.get("app", "").startswith("window:"):
            if window_app(display["app"]) == app:
                found.append((number, display))
    if not found:
        if not connect:
            return  # Already removed/disconnected elsewhere.
        # Revalidate discovery at the tap: titles, sizes and pairing may have changed.
        client, available = discover(ft, host)
        window = next((w for w in available if w["app"] == app), None)
        if window is None:
            raise RuntimeError("That window has closed. Refresh the window list.")
        ft.remote_command([
            "add", name, host["address"], app, "--client", client,
            "--label", window["title"], "--size", f"{window['width']}x{window['height']}",
            "--fps", "60", "--bitrate", "15000",
        ])
        return
    # Fresh screen numbers from the layout, never a cached row index. Set visibility
    # before connecting so a previously hidden panel comes back where it was.
    for number, _ in found:
        ft.set_hidden(str(number), not connect)
    ft.remote_command(["connect" if connect else "disconnect",
                       *(display["id"] for _, display in found)])


def handle(ft, request):
    operation = request["op"]
    if operation == "read":
        return read_state(ft, request.get("host", ""), request.get("discover", False))
    if operation not in ("connect", "disconnect"):
        raise ValueError("Unknown window operation.")
    control(ft, request["host"], request["app"], operation == "connect")
    return {}


def main():
    # Distrobox and podman must run on SteamOS, outside Nix's runtime libraries.
    os.environ["XDG_RUNTIME_DIR"] = f"/run/user/{os.getuid()}"
    os.environ["PATH"] = f"{Path.home()}/.local/bin:/usr/local/bin:/usr/bin:/bin"
    try:
        request = json.load(sys.stdin)
        with contextlib.redirect_stdout(sys.stderr):
            result = handle(load_frametop(request.get("frametop", "")), request)
        reply = {"ok": True, "result": result}
    except Exception as exc:  # Return an actionable error without killing Cuff.
        reply = {"ok": False, "error": str(exc)}
    print(json.dumps(reply))


if __name__ == "__main__":
    main()
