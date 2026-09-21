#!/usr/bin/env python3
"""
sim-kbd — MOUSE-FREE iOS Simulator keyboard automation for Obadh.

SAFETY: this tool never controls the Mac cursor. An earlier version drove the
physical mouse via `cliclick`, which could click the desktop if the Simulator
window moved — that whole approach has been removed. Everything here is pure IPC:
`simctl` (install/launch/screenshot/appearance/log/defaults) plus the DEBUG-only
control channel that the extension polls from a file in its own sandbox.

WHY NOT idb/XCUITest: `simctl` has no tap primitive; Meta's idb (the Playwright-
like tool) is archived + Python-3.14-incompatible; XCUITest needs a test target.
So we make the *extension itself* drivable in DEBUG builds (KeyboardDebugChannel)
and select keyboards via the keyboard-daemon prefs — no synthetic touches needed.

PIPELINE (check -> select -> drive -> observe)
    keyboards           enabled keyboards + KeyboardLastUsed
    active              is Obadh presented now? (via lifecycle log)
    select-obadh        make Obadh the presented keyboard, NO mouse (prefs+relaunch)
    debug <cmd>         DEBUG-only control channel (extension must be active):
                          advance                        advanceToNextInputMode()
                          mode:letters|numbers|symbols   switch page
                          glass:regular|clear|translucent|solid   key material
                          dump                           log full state
    shot [out.png]      screenshot (device-pixel PNG)
    rows                detected key-row y-centres (image debug, read-only)

TYPICAL SESSION (compare glass materials on the sim, mouse-free)
    scripts/sim-kbd.py select-obadh
    scripts/sim-kbd.py debug glass:translucent && scripts/sim-kbd.py shot /tmp/a.png
    scripts/sim-kbd.py debug glass:regular     && scripts/sim-kbd.py shot /tmp/b.png
    scripts/sim-kbd.py debug advance           # hand off to the native keyboard
"""
from __future__ import annotations

import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image

# The bundle id comes from Config/Identity.xcconfig (via scripts/bundle-id.sh),
# so a local override for a provisioning quota is picked up automatically instead
# of having to be repeated here. OBADH_APP still wins if it is set.
def _bundle_id() -> str:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        value = subprocess.run(
            [os.path.join(root, "scripts", "bundle-id.sh")],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except Exception:
        value = ""
    # An empty answer is a failure, not an id. Letting it through once produced a
    # keyboard identifier of ".keyboard", which the daemon ignores, so every
    # `select-obadh` silently left the SYSTEM keyboard on screen.
    return value or "org.unmukto.obadh"


OBADH_APP = os.environ.get("OBADH_APP") or _bundle_id()
OBADH_KB = os.environ.get("OBADH_KB", OBADH_APP + ".keyboard")
LOG_PREDICATE = 'subsystem == "org.unmukto.obadh.keyboard"'
DEVICE_W_PT = 440.0


def sh(cmd: list[str], timeout: float = 30) -> str:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout.strip()


def booted_udid() -> str:
    import json

    data = json.loads(sh(["xcrun", "simctl", "list", "devices", "booted", "-j"]))
    for runtime in data["devices"].values():
        for dev in runtime:
            if dev["state"] == "Booted":
                return dev["udid"]
    sys.exit("sim-kbd: no booted simulator")


# ---------------------------------------------------------------------------
# Observation.
# ---------------------------------------------------------------------------
def screenshot(udid: str, path: str = "/tmp/sim-kbd.png") -> Image.Image:
    sh(["xcrun", "simctl", "io", udid, "screenshot", path])
    return Image.open(path)


def obadh_appeared_recently(udid: str, seconds: int = 6) -> bool:
    out = sh([
        "xcrun", "simctl", "spawn", udid, "log", "show",
        "--last", f"{seconds}s", "--predicate", LOG_PREDICATE,
    ])
    return "viewDidAppear" in out


def key_row_centers_pt(img: Image.Image) -> list[float]:
    """Keyboard key-row y-centres (device pt) via brightness banding — read-only,
    for debugging layout. No interaction."""
    a = np.asarray(img.convert("L"), dtype=float)
    h, _ = a.shape
    y0 = int(h * 0.55)
    rowmean = a[y0:, :].mean(axis=1)
    thr = rowmean.mean()
    scale = img.size[0] / DEVICE_W_PT
    bands, inband, start = [], False, 0
    for i, v in enumerate(rowmean):
        if v > thr and not inband:
            inband, start = True, i
        elif v <= thr and inband:
            inband = False
            if i - start > 20:
                bands.append(round((y0 + (start + i) // 2) / scale, 1))
    return bands


# ---------------------------------------------------------------------------
# Selection (no mouse): keyboard-daemon preferences.
# ---------------------------------------------------------------------------
def cmd_select_obadh(udid: str, extra_launch_args: list[str] | None = None) -> None:
    """Make Obadh the presented keyboard with NO mouse: set it as the last-used
    ASCII/NonASCII keyboard while the daemon is live, then relaunch the harness.
    (Cold boot re-normalizes to a system keyboard, so this must run post-boot.)

    Extra CLI words after `select-obadh` replace the default `--gradient-bg`
    launch argument — e.g. `select-obadh --solid` launches on the solid
    background, which measurement scripts prefer (a uniform backdrop behind the
    translucent keyboard material)."""
    prefs = "com.apple.keyboard.preferences"
    subprocess.run(["xcrun", "simctl", "spawn", udid, "defaults", "write", prefs,
                    "KeyboardLastUsed", "-string", OBADH_KB], check=False)
    for field in ("ASCIICapable", "NonASCII"):
        subprocess.run(["xcrun", "simctl", "spawn", udid, "defaults", "write", prefs,
                        "KeyboardLastUsedForLanguage", "-dict-add", field, OBADH_KB], check=False)
    subprocess.run(["xcrun", "simctl", "terminate", udid, OBADH_APP], capture_output=True, check=False)
    time.sleep(1)
    launch_args = extra_launch_args if extra_launch_args else ["--gradient-bg"]
    subprocess.run(["xcrun", "simctl", "launch", udid, OBADH_APP,
                    "--keyboard-test", *launch_args], capture_output=True, check=False)
    time.sleep(3)
    print("obadh" if obadh_appeared_recently(udid, 8) else "select-obadh: not confirmed")


# ---------------------------------------------------------------------------
# DEBUG control channel (file the extension polls from its own sandbox).
# ---------------------------------------------------------------------------
def extension_command_path(udid: str) -> str | None:
    """Path to the DEBUG channel's command file inside the keyboard extension's
    own sandbox (`…/PluginKitPlugin/<uuid>/Library/Caches/obadh-debug/command`),
    located by bundle id so it survives reinstalls. Works on the Simulator
    without App Groups (which unsigned builds don't provision)."""
    pk = os.path.expanduser(
        f"~/Library/Developer/CoreSimulator/Devices/{udid}"
        "/data/Containers/Data/PluginKitPlugin"
    )
    if not os.path.isdir(pk):
        return None
    for entry in os.listdir(pk):
        meta = os.path.join(pk, entry, ".com.apple.mobile_container_manager.metadata.plist")
        ident = subprocess.run(
            ["plutil", "-extract", "MCMMetadataIdentifier", "raw", meta],
            capture_output=True, text=True,
        ).stdout.strip()
        if ident == OBADH_KB:
            return os.path.join(pk, entry, "Library", "Caches", "obadh-debug", "command")
    return None


def cmd_debug(udid: str, command: str) -> None:
    """Write a command to the DEBUG-only agentic control channel (a file the
    extension consumes within ~0.25s while it is the presented keyboard). No-op
    unless a DEBUG build of Obadh is active. See KeyboardDebugChannel.swift."""
    path = extension_command_path(udid)
    if not path:
        sys.exit("sim-kbd: extension container not found (run `select-obadh` first)")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(command)
    print(f"debug: wrote {command!r} -> {path}")


def cmd_keyboards(udid: str) -> None:
    enabled = sh(["xcrun", "simctl", "spawn", udid, "defaults", "read",
                  ".GlobalPreferences", "AppleKeyboards"])
    last = sh(["xcrun", "simctl", "spawn", udid, "defaults", "read",
               "com.apple.keyboard.preferences", "KeyboardLastUsed"])
    print("Enabled keyboards:\n" + (enabled or "  <none>"))
    print(f"\nKeyboardLastUsed: {last or '<unknown>'}")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    udid = booted_udid()
    if cmd == "keyboards":
        cmd_keyboards(udid)
    elif cmd == "active":
        print("obadh" if obadh_appeared_recently(udid) else "system/other (or idle)")
    elif cmd == "select-obadh":
        cmd_select_obadh(udid, sys.argv[2:] or None)
    elif cmd == "debug":
        cmd_debug(udid, sys.argv[2] if len(sys.argv) > 2 else "dump")
    elif cmd == "shot":
        out = sys.argv[2] if len(sys.argv) > 2 else "/tmp/sim-kbd.png"
        screenshot(udid, out)
        print(f"wrote {out}")
    elif cmd == "rows":
        print(key_row_centers_pt(screenshot(udid)))
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
