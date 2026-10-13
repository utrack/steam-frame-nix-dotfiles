# Runs on hal2 (fed to its python3 over SSH by hal2-icons): renders the icons of hal2's desktop
# entries as SIZE x SIZE PNGs and writes them to stdout as a tar, with index.json mapping
# lowercase window classes to the PNGs. The keys of an entry, by precedence across all entries:
# StartupWMClass, the desktop file ID (and its last dot-separated part), the Exec basename.
import configparser
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import time

SIZE = int(sys.argv[1]) if len(sys.argv) > 1 else 256
HOME = os.path.expanduser("~")
DATA_HOME = os.environ.get("XDG_DATA_HOME") or f"{HOME}/.local/share"
DATA_DIRS = [DATA_HOME] + (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":")
DATA_DIRS += [f"{DATA_HOME}/flatpak/exports/share", "/var/lib/flatpak/exports/share"]
DATA_DIRS = list(dict.fromkeys(d for d in DATA_DIRS if d))


def read_ini(path, section):
    p = configparser.ConfigParser(interpolation=None, strict=False)
    p.optionxform = str
    try:
        p.read(path, encoding="utf8")
        return dict(p[section]) if p.has_section(section) else {}
    except (configparser.Error, UnicodeDecodeError):
        return {}


def icon_themes():
    theme = read_ini(f"{HOME}/.config/kdeglobals", "Icons").get("Theme")
    if not theme:
        try:
            theme = subprocess.run(["gsettings", "get", "org.gnome.desktop.interface", "icon-theme"],
                                   capture_output=True, text=True).stdout.strip().strip("'")
        except OSError:
            pass
    themes, todo = [], [theme or "breeze", "hicolor"]
    while todo:
        t = todo.pop(0)
        if t in themes:
            continue
        themes.append(t)
        for d in DATA_DIRS:
            inherits = read_ini(f"{d}/icons/{t}/index.theme", "Icon Theme").get("Inherits")
            if inherits:
                todo[0:0] = [i.strip() for i in inherits.split(",") if i.strip()]
                break
    return themes


def icon_index(themes):
    # name -> (theme rank, -size, path) of the best file
    best = {}
    roots = [f"{HOME}/.icons"] + [f"{d}/icons" for d in DATA_DIRS]
    for rank, theme in enumerate(themes):
        for root in roots:
            for dirpath, _dirs, files in os.walk(f"{root}/{theme}"):
                parts = dirpath.split("/")
                size = 4096 if "scalable" in parts else 0
                for p in parts:
                    if m := re.fullmatch(r"(\d+)(?:x\d+)?(?:@(\d+)x?)?", p):
                        size = max(size, int(m[1]) * int(m[2] or 1))
                for f in files:
                    name, ext = os.path.splitext(f)
                    if ext not in (".svg", ".svgz", ".png", ".xpm"):
                        continue
                    score = (rank, -(size or 48) - (1 if ext.startswith(".svg") else 0), f"{dirpath}/{f}")
                    if name not in best or score < best[name]:
                        best[name] = score
    for d in DATA_DIRS + ["/usr/share"]:
        try:
            for f in os.listdir(f"{d}/pixmaps"):
                name, ext = os.path.splitext(f)
                if ext in (".svg", ".png", ".xpm"):
                    best.setdefault(name, (len(themes), 0, f"{d}/pixmaps/{f}"))
        except OSError:
            pass
    return {name: score[2] for name, score in best.items()}


def desktop_entries():
    seen = set()
    for d in DATA_DIRS:
        root = f"{d}/applications"
        for dirpath, _dirs, files in os.walk(root):
            for f in sorted(files):
                if not f.endswith(".desktop"):
                    continue
                path = f"{dirpath}/{f}"
                desktop_id = os.path.relpath(path, root)[:-len(".desktop")].replace("/", "-")
                if desktop_id in seen:
                    continue
                seen.add(desktop_id)
                entry = read_ini(path, "Desktop Entry")
                if entry.get("Type", "Application") == "Application" and entry.get("Icon"):
                    yield desktop_id, entry


def exec_name(cmd):
    for word in cmd.split():
        if word == "env" or "=" in word or word.startswith("-"):
            continue
        return os.path.basename(word.strip("\"'"))
    return ""


def render(src, dst):
    if src.endswith((".svg", ".svgz")):
        cmd = ["rsvg-convert", "-w", str(SIZE), "-h", str(SIZE), "-a", "-o", dst, src]
    else:
        cmd = ["magick", src, "-background", "none", "-resize", f"{SIZE}x{SIZE}",
               "-gravity", "center", "-extent", f"{SIZE}x{SIZE}", f"PNG32:{dst}"]
    return subprocess.run(cmd, capture_output=True).returncode == 0 and os.path.exists(dst)


def main():
    icons = icon_index(icon_themes())
    tiers = [{}, {}, {}]
    for desktop_id, entry in desktop_entries():
        icon = entry["Icon"]
        path = icon if os.path.isabs(icon) and os.path.exists(icon) else icons.get(icon)
        if not path:
            continue
        keys = [[entry.get("StartupWMClass", "")], [desktop_id, desktop_id.rsplit(".", 1)[-1]],
                [exec_name(entry.get("Exec", ""))]]
        for tier, names in zip(tiers, keys):
            for name in names:
                if name:
                    tier.setdefault(name.lower(), path)
    mapping = {}
    for tier in reversed(tiers):
        mapping.update(tier)
    index, rendered = {}, {}
    out = io.BytesIO()
    with tempfile.TemporaryDirectory() as tmp, tarfile.open(fileobj=out, mode="w:gz") as tar:
        for key, src in sorted(mapping.items()):
            if src not in rendered:
                name = f"{len(rendered)}.png"
                rendered[src] = name if render(src, f"{tmp}/{name}") else None
                if rendered[src]:
                    tar.add(f"{tmp}/{name}", name)
            if rendered[src]:
                index[key] = rendered[src]
        data = json.dumps(index, indent=1, sort_keys=True).encode()
        info = tarfile.TarInfo("index.json")
        info.size = len(data)
        info.mtime = int(time.time())
        tar.addfile(info, io.BytesIO(data))
    sys.stdout.buffer.write(out.getvalue())


main()
