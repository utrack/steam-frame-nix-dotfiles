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
                raise RuntimeError(
                    "This Frametop build does not include the custom window receiver. "
                    "Streaming without the desktop alone does not add window sharing.")
            return ft
    raise RuntimeError("Frametop not found. Set its folder in Cuff's Frametop streams settings.")


def window_app(value):
    """Canonical KWin UUID, as ft-layout and the window service expect it."""
    return "window:{" + str(uuid.UUID(value.removeprefix("window:").strip("{}"))) + "}"


def source_app(display):
    """A wrist-row identity: a window UUID or a configured full display's ID.

    Sunshine can have several Desktop streams on different ports. Their saved IDs
    distinguish them without confusing a row's identity with its stream's app name.
    """
    if display.get("app", "").startswith("window:"):
        return window_app(display["app"])
    return "display:" + display["id"]


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
        out.append({"app": app, "kind": "window", "title": title(window.get("title") or "Window"),
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
        running = True
    except RuntimeError:
        running, states = False, {}
    finally:
        sock.close()
    saved = []
    for number, h, display in ft.remote_displays(layout):
        if h is not host:
            continue
        try:
            app = source_app(display)
        except ValueError:
            continue
        kind = "window" if app.startswith("window:") else "display"
        label = title(display.get("label") or display["id"])
        saved.append({"app": app, "kind": kind,
                      "title": label if kind == "window" else f"Display · {label}",
                      "connected": not display.get("off", False),
                      "hidden": bool(display.get("hidden")),
                      "state": states.get(number, "not running")})
    streams_supported = callable(getattr(ft, "streams_command", None))
    if running:
        session = "streams" if streams_supported and ft.streams_only() else "desktop"
    else:
        session = "starting" if streams_supported and ft.session_running() else "stopped"
    result = {"hosts": [h["name"] for h in hosts], "host": host["name"] if host else "",
              "session": session, "streams_supported": streams_supported, "saved": saved}
    if refresh and host:
        try:
            _, result["available"] = discover(ft, host)
            result["discovery_error"] = ""
        except (RuntimeError, OSError, ValueError) as exc:
            # Window discovery is independent of the configured full displays.
            result["discovery_error"] = str(exc)
    return result


def control(ft, name, app, connect):
    is_window = app.startswith("window:")
    if is_window:
        app = window_app(app)
    elif not app.startswith("display:"):
        raise ValueError("Unknown streaming source.")
    ft.read_layout_file()
    layout = ft.load_layout()
    host = next((h for h in layout.get("hosts", []) if h.get("name") == name), None)
    if not host:
        raise RuntimeError("This computer is no longer configured. Refresh the list.")
    found = []
    for number, h, display in ft.remote_displays(layout):
        if h is host and source_app(display) == app:
            found.append((number, display))
    if not found:
        if not connect:
            return  # Already removed/disconnected elsewhere.
        if not is_window:
            raise RuntimeError("This display is no longer configured. Add it in Frametop Remote Displays.")
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
        raise ValueError("Unknown streaming operation.")
    control(ft, request["host"], request["app"], operation == "connect")
    if not callable(getattr(ft, "streams_command", None)):
        return {}
    if operation == "connect" and not ft.session_running():
        # Save the selected panel first; the new session loads connected panels at start.
        # A failed discovery or layout write must not start a session.
        try:
            ft.streams_command(["start"])
        except RuntimeError as exc:
            raise RuntimeError(f"Panel selected, but streaming could not start: {exc}") from exc
    elif operation == "disconnect" and ft.streams_only():
        # Only the last connected panel ends a standalone session. Hidden panels
        # and panels from other hosts still count. Upstream rechecks the session
        # type when stopping, so a full desktop is left running.
        ft.read_layout_file()
        if not any(not display.get("off") for _, _, display in ft.remote_displays(ft.load_layout())):
            ft.streams_command(["stop"])
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
