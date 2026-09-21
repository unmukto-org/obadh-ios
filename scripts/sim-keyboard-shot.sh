#!/usr/bin/env bash
# Drive the Obadh keyboard on the booted iOS Simulator and screenshot it.
#
# The Simulator can't focus a field or switch keyboards via `simctl` alone, so
# this uses `cliclick` (brew install cliclick) to tap the field + open the globe
# switcher + pick Obadh. Coordinates are derived from the Simulator window
# geometry; if the switch misses, adjust OBADH_* offsets below.
#
# Usage:
#   scripts/sim-keyboard-shot.sh [--build] [--appearance dark|light] [out.png]
#
# Observe the extension loading live in another shell:
#   xcrun simctl spawn booted log stream --predicate \
#     'subsystem == "org.unmukto.obadh.keyboard"'
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DD=/tmp/obadh-sim-dd
APP_BUNDLE=org.unmukto.obadh
KB_BUNDLE=org.unmukto.obadh.keyboard
OUT="${!#:-/tmp/obadh-keyboard.png}"; [[ "$OUT" == --* ]] && OUT=/tmp/obadh-keyboard.png
APPEARANCE=""
DO_BUILD=0
while [[ $# -gt 0 ]]; do case "$1" in
  --build) DO_BUILD=1; shift;;
  --appearance) APPEARANCE="$2"; shift 2;;
  *) shift;;
esac; done

command -v cliclick >/dev/null || { echo "need: brew install cliclick" >&2; exit 1; }
UDID="$(xcrun simctl list devices booted -j | python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print(next(x["udid"] for v in d.values() for x in v if x["state"]=="Booted"))')"

if [[ $DO_BUILD == 1 ]]; then
  xcodebuild -project "$ROOT_DIR/Obadh.xcodeproj" -scheme Obadh \
    -destination "id=$UDID" -configuration Debug -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=NO build >/dev/null
  xcrun simctl install "$UDID" "$DD/Build/Products/Debug-iphonesimulator/Obadh.app"
fi

# Enable Obadh + bias it as the presented keyboard (idempotent).
xcrun simctl spawn "$UDID" defaults read .GlobalPreferences AppleKeyboards | grep -q "$KB_BUNDLE" \
  || xcrun simctl spawn "$UDID" defaults write .GlobalPreferences AppleKeyboards -array-add "$KB_BUNDLE"
[[ -n "$APPEARANCE" ]] && xcrun simctl ui "$UDID" appearance "$APPEARANCE"

xcrun simctl terminate "$UDID" "$APP_BUNDLE" 2>/dev/null || true
xcrun simctl launch "$UDID" "$APP_BUNDLE" --keyboard-test >/dev/null
sleep 2
open -a Simulator; osascript -e 'tell application "System Events" to tell process "Simulator" to set frontmost to true' || true

# Map device points -> Mac screen points from the Simulator window geometry.
read -r WX WY WW <<<"$(osascript -e 'tell application "System Events" to tell process "Simulator"
set p to position of window 1
set s to size of window 1
return (item 1 of p) & " " & (item 2 of p) & " " & (item 1 of s)
end tell')"
SCALE="$(python3 -c "print(($WW-14)/440.0)")"
mac() { python3 -c "print(int($WX+7+$1*$SCALE), int($WY+26+$2*$SCALE))"; }

read -r GX GY <<<"$(mac 40 916)"     # globe key (bottom-left)
read -r OX OY <<<"$(mac 78 756)"     # "Obadh" row in the globe switcher menu
cliclick "dd:$GX,$GY" w:650 "du:$GX,$GY"   # press-and-hold globe -> switcher
sleep 1
cliclick "c:$OX,$OY"                        # pick Obadh
sleep 2

xcrun simctl io "$UDID" screenshot "$OUT"
echo "wrote $OUT"
xcrun simctl spawn "$UDID" log show --last 20s --predicate 'subsystem == "org.unmukto.obadh.keyboard"' 2>/dev/null | grep OBADH-LIFECYCLE | tail -2 || true
