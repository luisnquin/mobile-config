#!/usr/bin/env python3
"""Drive the key daemon with synthetic evdev events and check what the panel
renders. The daemon reads packed input_event structs from a fifo under
--keys-raw, so the whole chain runs without a keypad or a phone.

Both processes run against a writable copy of the fixture, which carries the
device's own backlight nodes, so a toggle is observable as a file write."""

import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time

PANEL = os.environ.get("PANEL", "panel")
FIXTURE = os.environ.get("FIXTURE", os.path.join(os.path.dirname(__file__), "fixture"))

EV_KEY, EV_SYN = 0x01, 0x00
KEY_POWER, KEY_VOLUMEUP, KEY_VOLUMEDOWN = 116, 115, 114
HOLD_MS, REPEAT_MS = 200, 100
BACKLIGHT = "/sys/class/leds/lcd-backlight"
TORCH = "/sys/class/leds/torch-light0"

failures = []


def check(name, ok, detail=""):
    suffix = f"  -- {detail}" if detail and not ok else ""
    print(f"{'ok  ' if ok else 'FAIL'} {name}{suffix}")
    if not ok:
        failures.append(name)


def plain(s):
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", s)


def screen(raw):
    """The renderer moves the cursor per line instead of emitting newlines, so
    the visible screen is reassembled the way /dev/vcs1 shows it."""
    parts = re.split(r"\x1b\[(\d+);1H", raw)
    rows = {}
    for i in range(1, len(parts) - 1, 2):
        rows[int(parts[i])] = plain(parts[i + 1]).rstrip()
    return "\n".join(rows[k] for k in sorted(rows))


def selected(text):
    """Menu rows are `> name` padded to a column, then a detail the entry
    reports for itself, so only the first field names the entry."""
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith(">"):
            return re.split(r"\s{2,}", stripped[1:].strip())[0]
    return None


class Rig:
    def __init__(self, tmp):
        self.root = os.path.join(tmp, "root")
        shutil.copytree(FIXTURE, self.root, symlinks=True)
        os.makedirs(os.path.join(self.root, "run", "display"), exist_ok=True)
        self.write_brightness(200)

        self.fifo = os.path.join(tmp, "events")
        self.sock = os.path.join(tmp, "keys.sock")
        os.mkfifo(self.fifo)

        common = ["--root", self.root, "--backlight", BACKLIGHT,
                  "--state-dir", "/run/display", "--socket", self.sock]
        self.daemon = subprocess.Popen(
            [PANEL, "keys", "--keys", self.fifo, "--keys-raw",
             "--hold-ms", str(HOLD_MS), "--repeat-ms", str(REPEAT_MS),
             "--default-brightness", "200"] + common,
            stderr=subprocess.PIPE)
        self.events = open(self.fifo, "wb", buffering=0)
        self.wait_for_socket()

        self.master, slave = pty.openpty()
        self.panel = subprocess.Popen(
            [PANEL, "--interval", "3600", "--now", "1770000000",
             "--service", "sshd:22", "--service", "tailscaled"] + common,
            stdin=slave, stdout=slave, stderr=subprocess.DEVNULL)
        os.close(slave)

    def path(self, p):
        return os.path.join(self.root, p.lstrip("/"))

    def write_brightness(self, v):
        with open(self.path(BACKLIGHT + "/brightness"), "w") as f:
            f.write(f"{v}\n")

    def brightness(self):
        with open(self.path(BACKLIGHT + "/brightness")) as f:
            return int(f.read().strip() or 0)

    def torch(self):
        with open(self.path(TORCH + "/brightness")) as f:
            return int(f.read().strip() or 0)

    def wait_for_socket(self, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(self.sock):
                return
            time.sleep(0.02)
        raise SystemExit("key daemon never created its socket")

    def send(self, code, value):
        self.events.write(struct.pack("qqHHi", 0, 0, EV_KEY, code, value))
        self.events.write(struct.pack("qqHHi", 0, 0, EV_SYN, 0, 0))

    def tap(self, code):
        self.send(code, 1)
        time.sleep(HOLD_MS / 2000.0)
        self.send(code, 0)

    def hold(self, code, ms=HOLD_MS * 2):
        self.send(code, 1)
        time.sleep(ms / 1000.0)
        self.send(code, 0)

    def drain(self, seconds=0.4):
        out = b""
        deadline = time.time() + seconds
        while time.time() < deadline:
            ready, _, _ = select.select([self.master], [], [], 0.05)
            if ready:
                try:
                    out += os.read(self.master, 1 << 20)
                except OSError:
                    break
        return screen(out.decode("utf-8", "replace"))

    def press(self, code, seconds=0.45):
        self.tap(code)
        return self.drain(seconds)

    def close(self):
        for p in (self.panel, self.daemon):
            if p.poll() is None:
                p.send_signal(signal.SIGTERM)
        for p in (self.panel, self.daemon):
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
        self.events.close()
        os.close(self.master)


def step_to(rig, target, view):
    for _ in range(len(view) + 2):
        text = rig.press(KEY_VOLUMEDOWN)
        if selected(text) == target:
            return text
    return text


def main():
    tmp = tempfile.mkdtemp(prefix="panel-keys-")
    rig = None
    try:
        rig = Rig(tmp)
        first = rig.drain(1.2)
        check("dashboard paints on start", "THOMPSON" in first,
              repr(first[:120]))

        rig.tap(KEY_POWER)
        time.sleep(0.4)
        check("power tap toggles the backlight off", rig.brightness() == 0,
              f"brightness={rig.brightness()}")

        # A dark panel spends the first press waking up; a hold has to survive
        # that or the menu is unreachable from off.
        rig.hold(KEY_POWER)
        time.sleep(0.2)
        text = rig.drain(0.6)
        check("hold from a dark panel wakes it", rig.brightness() == 200,
              f"brightness={rig.brightness()}")
        check("hold from a dark panel opens the menu", "MENU" in text)
        check("menu starts on the first entry", selected(text) == "backlight",
              f"selected={selected(text)!r}")

        text = rig.press(KEY_VOLUMEDOWN)
        check("volume down steps forward", selected(text) == "torch",
              f"selected={selected(text)!r}")

        text = rig.press(KEY_VOLUMEUP)
        check("volume up steps back", selected(text) == "backlight",
              f"selected={selected(text)!r}")

        text = rig.press(KEY_VOLUMEUP)
        check("selection wraps at the top", selected(text) == "back",
              f"selected={selected(text)!r}")

        # This keypad reports no EV_REP, so extra steps can only come from the
        # synthesized repeat.
        before = selected(text)
        rig.hold(KEY_VOLUMEDOWN, ms=HOLD_MS + REPEAT_MS * 3 + 80)
        after = selected(rig.drain(0.6))
        check("holding volume repeats past one step",
              after not in (before, "backlight"), f"{before!r} -> {after!r}")

        menu = ["backlight", "torch", "boot log", "errors", "kernel logs",
                "units", "network", "reboot", "back"]
        step_to(rig, "back", menu)
        text = rig.press(KEY_POWER, 0.8)
        check("power on 'back' closes the menu", "THOMPSON" in text)

        rig.hold(KEY_POWER)
        time.sleep(0.2)
        rig.drain(0.5)
        step_to(rig, "network", menu)
        text = rig.press(KEY_POWER, 1.2)
        check("network opens a pager",
              "scroll" in text and "back" in text, repr(text[-160:]))

        text = rig.press(KEY_POWER, 0.8)
        check("power leaves the pager for the menu", "MENU" in text)

        step_to(rig, "torch", menu)
        rig.press(KEY_POWER, 0.4)
        check("selecting torch turns it on", rig.torch() > 0,
              f"torch={rig.torch()}")
        rig.press(KEY_POWER, 0.4)
        check("selecting torch again turns it off", rig.torch() == 0,
              f"torch={rig.torch()}")

        # No system bus under the fixture root, so this is a no-op rather
        # than an actual reboot -- selecting it should just leave the menu up.
        step_to(rig, "reboot", menu)
        text = rig.press(KEY_POWER, 0.8)
        check("selecting reboot is a no-op without a bus", "MENU" in text)

        # With no panel attached the power key is just the on/off switch.
        rig.panel.send_signal(signal.SIGTERM)
        rig.panel.wait(timeout=3)
        time.sleep(0.4)
        level = rig.brightness()
        rig.tap(KEY_POWER)
        time.sleep(0.4)
        check("power still toggles with no panel attached",
              rig.brightness() != level, f"{level} -> {rig.brightness()}")
    finally:
        if rig:
            rig.close()
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print(f"\n{len(failures)} failed: {', '.join(failures)}")
        return 1
    print("\nall key tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
