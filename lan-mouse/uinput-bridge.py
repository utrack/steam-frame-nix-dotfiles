#!/usr/bin/env python3
"""Runs a lan-mouse daemon with its dummy emulation backend, and replays the events it logs
on a uinput mouse and keyboard.

Usage: uinput-bridge.py <keycodes> <lan-mouse command...>

<keycodes>: lines "<name> <code>" for lan-mouse's key names (scancode::Linux), as the dummy
backend logs keys by name. The devices are on the USB bus, so Frametop's input relay takes
them as a mouse and a keyboard (it skips virtual-bus devices). Other log lines go to stderr.
"""
import fcntl
import os
import re
import struct
import subprocess
import sys

EV_SYN, EV_KEY, EV_REL = 0x00, 0x01, 0x02
REL_X, REL_Y, REL_HWHEEL, REL_WHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES = 0x00, 0x01, 0x06, 0x08, 0x0B, 0x0C
BTN_LEFT, BTN_TASK = 0x110, 0x117
BUTTONS = {"left": 0x110, "right": 0x111, "middle": 0x112, "back": 0x113, "forward": 0x114}
BUS_USB = 0x03
VENDOR = 0x4C4D  # "LM"
EVENT = struct.Struct("llHHi")
# libinput scroll units per wheel notch; a notch is 120 in the hi-res axes
UNITS_PER_NOTCH = 15


def _ioc(direction, kind, nr, size):
    return (direction << 30) | (size << 16) | (ord(kind) << 8) | nr


UI_DEV_CREATE = _ioc(0, "U", 1, 0)
UI_DEV_SETUP = _ioc(1, "U", 3, 92)
UI_SET_EVBIT = _ioc(1, "U", 100, 4)
UI_SET_KEYBIT = _ioc(1, "U", 101, 4)
UI_SET_RELBIT = _ioc(1, "U", 102, 4)


class Device:
    def __init__(self, name, product, keys, rels=()):
        self.fd = os.open("/dev/uinput", os.O_WRONLY)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
        for code in keys:
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        if rels:
            fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_REL)
            for code in rels:
                fcntl.ioctl(self.fd, UI_SET_RELBIT, code)
        fcntl.ioctl(self.fd, UI_DEV_SETUP, struct.pack("HHHH80sI", BUS_USB, VENDOR, product, 1, name.encode(), 0))
        fcntl.ioctl(self.fd, UI_DEV_CREATE)

    def send(self, *events):
        os.write(self.fd, b"".join(EVENT.pack(0, 0, t, c, v) for t, c, v in events)
                 + EVENT.pack(0, 0, EV_SYN, 0, 0))


class Scroll:
    """Hi-res scroll for one axis, with a whole-notch event every 120."""

    def __init__(self, low, high):
        self.low, self.high, self.hires, self.notches = low, high, 0.0, 0.0

    def events(self, hires):
        self.hires += hires
        step = int(self.hires)
        self.hires -= step
        self.notches += step
        notch = int(self.notches / 120)
        self.notches -= notch * 120
        return [(EV_REL, self.high, step)] * bool(step) + [(EV_REL, self.low, notch)] * bool(notch)


def main():
    with open(sys.argv[1]) as f:
        keycodes = {name: int(code) for name, code in (line.split() for line in f if line.strip())}
    mouse = Device("lan-mouse hal2 mouse", 1, range(BTN_LEFT, BTN_TASK + 1),
                   (REL_X, REL_Y, REL_HWHEEL, REL_WHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES))
    keyboard = Device("lan-mouse hal2 keyboard", 2, range(1, 0x100))
    # sign: lan-mouse's positive is down / right, REL_WHEEL's positive is up
    scroll = {"0": (Scroll(REL_WHEEL, REL_WHEEL_HI_RES), -1), "1": (Scroll(REL_HWHEEL, REL_HWHEEL_HI_RES), 1)}
    rest = [0.0, 0.0]  # sub-count motion, carried over

    event = re.compile(r"received event: \(\d+\) (\w[\w-]*) ?\((.*?)\)?$")
    proc = subprocess.Popen(sys.argv[2:], stderr=subprocess.PIPE, text=True, bufsize=1)
    for line in proc.stderr:
        m = event.search(line.rstrip("\n"))
        if not m:
            sys.stderr.write(line)
            continue
        kind, args = m.group(1), [a.strip() for a in m.group(2).split(",")]
        try:
            if kind == "motion":
                rest[0] += float(args[0])
                rest[1] += float(args[1])
                dx, dy = int(rest[0]), int(rest[1])
                rest[0] -= dx
                rest[1] -= dy
                if dx or dy:
                    mouse.send(*[(EV_REL, REL_X, dx)] * bool(dx), *[(EV_REL, REL_Y, dy)] * bool(dy))
            elif kind == "button":
                code = BUTTONS.get(args[0]) or int(args[0])
                mouse.send((EV_KEY, code, int(args[1])))
            elif kind in ("scroll", "scroll-120"):
                axis, sign = scroll.get(args[0], scroll["0"])
                value = float(args[1]) * (120 / UNITS_PER_NOTCH if kind == "scroll" else 1)
                events = axis.events(sign * value)
                if events:
                    mouse.send(*events)
            elif kind == "key":
                code = keycodes[args[0]] if args[0] in keycodes else int(args[0])
                if 0 < code < 0x100:
                    keyboard.send((EV_KEY, code, int(args[1])))
        except (ValueError, KeyError, IndexError):
            sys.stderr.write(f"uinput-bridge: unparsed {line}")
    sys.exit(proc.wait())


if __name__ == "__main__":
    main()
