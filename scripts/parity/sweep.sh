#!/usr/bin/env bash
# Native-parity capture sweep: for each device name, capture
# {modern, legacy host} × {light, dark} × {Obadh, native} — 8 screenshots — on the
# debug harness's mid-gray measurement backdrop, plus the probe log per cell.
#
# Prereqs: both simulator app builds exist (run.sh builds them), the iOS 26.5
# runtime is installed, and nothing else is using the booted simulator. Devices
# are created on demand (named "Obadh Sweep <name>") and keyboards are enabled
# headlessly. MOUSE-FREE by construction: everything is simctl + the DEBUG
# control channel.
#
# Usage: sweep.sh OUT_DIR "iPhone 17 Pro" "iPhone 16" ...
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT=$1; shift
APP_MODERN=$ROOT/build/DerivedData/Build/Products/Debug-iphonesimulator/Obadh.app
APP_LEGACY=$ROOT/build/DerivedData/Build/Products/Debug-Legacy-iphonesimulator/Obadh.app
RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-26-5
APP_ID=$("$ROOT/scripts/bundle-id.sh")
# Never proceed on an empty id: it produces a keyboard called ".keyboard", which
# the daemon quietly ignores, and every capture is then of the system keyboard.
[[ -n "$APP_ID" ]] || { echo "sweep: bundle-id.sh returned nothing"; exit 2; }
KB_ID=$APP_ID.keyboard
mkdir -p "$OUT"

devtype_id() {
  xcrun simctl list devicetypes | grep -F "$1 (com.apple" | sed -E 's/.*\((com[^)]*)\).*/\1/' | head -1
}

ensure_device() {
  local name="Obadh Sweep $1"
  local udid
  udid=$(xcrun simctl list devices -j | python3 -c "
import json,sys
d=json.load(sys.stdin)
for rt,devs in d['devices'].items():
    if '26-5' not in rt: continue
    for dev in devs:
        if dev['name']=='$name': print(dev['udid']); raise SystemExit
" 2>/dev/null)
  if [[ -z "$udid" ]]; then
    local dt; dt=$(devtype_id "$1")
    udid=$(xcrun simctl create "$name" "$dt" "$RUNTIME")
  fi
  echo "$udid"
}

capture_appearance() { # udid slug host appearance
  local udid=$1 slug=$2 host=$3 app=$4
  xcrun simctl ui "$udid" appearance "$app" || true
  sleep 1
  python3 "$ROOT/scripts/sim-kbd.py" select-obadh --measure-bg || true
  sleep 2
  python3 "$ROOT/scripts/sim-kbd.py" debug probe:on || true
  sleep 2
  python3 "$ROOT/scripts/sim-kbd.py" shot "$OUT/$slug-$host-$app-obadh.png"
  python3 "$ROOT/scripts/sim-kbd.py" debug advance || true
  sleep 3
  python3 "$ROOT/scripts/sim-kbd.py" shot "$OUT/$slug-$host-$app-native.png"
  xcrun simctl spawn "$udid" log show --last 3m \
    --predicate 'subsystem == "org.unmukto.obadh.keyboard"' 2>/dev/null \
    | grep -o 'OBADH-PROBE.*' | tail -3 > "$OUT/$slug-$host-$app.probe.txt" || true
}

for NAME in "$@"; do
  slug=$(echo "$NAME" | tr 'A-Z ()' 'a-z---' | tr -s '-' | sed 's/-$//')
  echo "==== $NAME ($slug) ===="
  udid=$(ensure_device "$NAME")
  [[ -z "$udid" ]] && { echo "SKIP $NAME (device type unavailable)"; continue; }
  xcrun simctl shutdown booted 2>/dev/null || true
  # Erase before every sweep. A simulator that has already presented a keyboard
  # ignores the `AppleKeyboards` / `KeyboardLastUsed` writes below, so Obadh is
  # never selected and all eight captures are of the SYSTEM keyboard — which the
  # measurement then compares against itself and reports as an incomplete cell.
  # The sweep used to work only because these devices happened to carry the right
  # state from earlier runs; that made the gate silently dependent on history.
  xcrun simctl erase "$udid" 2>/dev/null || true
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" >/dev/null 2>&1
  sleep 3
  xcrun simctl spawn "$udid" defaults write .GlobalPreferences AppleKeyboards -array \
    "en_US@sw=QWERTY;hw=Automatic" "$KB_ID" "emoji@sw=Emoji" \
    "bn-Translit@sw=QWERTY-Bengali;hw=Automatic" || true

  # Suppress the one-time keyboard tutorials. The QuickPath sheet ("Speed up your
  # typing by sliding your finger…") covers the WHOLE keyboard, so a device that
  # has not already dismissed it yields eight screenshots of the sheet and 24
  # INCOMPLETE cells. This used to pass only because the sweep devices were
  # long-lived and had been through it; erase one and the whole gate silently
  # measures nothing.
  for domain in com.apple.Preferences com.apple.keyboard.preferences .GlobalPreferences; do
    xcrun simctl spawn "$udid" defaults write "$domain" DidShowContinuousPathIntroduction -bool true 2>/dev/null || true
    xcrun simctl spawn "$udid" defaults write "$domain" UIKeyboardDidShowContinuousPathIntroduction -bool true 2>/dev/null || true
    xcrun simctl spawn "$udid" defaults write "$domain" DidShowGestureKeyboardIntroduction -bool true 2>/dev/null || true
  done

  xcrun simctl install "$udid" "$APP_MODERN"
  capture_appearance "$udid" "$slug" modern light
  capture_appearance "$udid" "$slug" modern dark

  xcrun simctl install "$udid" "$APP_LEGACY"
  capture_appearance "$udid" "$slug" legacy light
  capture_appearance "$udid" "$slug" legacy dark

  xcrun simctl shutdown "$udid" 2>/dev/null || true
  echo "==== done $NAME ===="
done
echo "SWEEP COMPLETE: $*"
