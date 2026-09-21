#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
DEVICE_ID="${DEVICE_ID:-}"
DEVICE_WAIT_SECONDS="${DEVICE_WAIT_SECONDS:-45}"
BUNDLE_ID="org.unmukto.obadh"
# The physical iPhone runs the RELEASE build by default: it excludes all
# #if DEBUG tooling (e.g. KeyboardDebugChannel) so nothing debug-only ships to
# the phone. Override with CONFIG=Debug only when explicitly needed.
CONFIG="${CONFIG:-Release}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install with: brew install xcodegen" >&2
  exit 1
fi

if [[ ! -d "$ROOT_DIR/Frameworks/ObadhBridge.xcframework" ]]; then
  "$ROOT_DIR/scripts/build-rust-xcframework.sh"
fi

if [[ ! -f "$ROOT_DIR/Config/Signing.local.xcconfig" ]]; then
  team_id="$(
    security find-certificate -a -c "Apple Development" -p \
      | openssl x509 -noout -subject 2>/dev/null \
      | sed -n 's/.*OU=\([^,]*\).*/\1/p' \
      | head -n 1
  )"
  if [[ -z "$team_id" ]]; then
    echo "Could not infer DEVELOPMENT_TEAM from an Apple Development certificate." >&2
    echo "Create Config/Signing.local.xcconfig with: DEVELOPMENT_TEAM = YOUR_TEAM_ID" >&2
    exit 1
  fi
  printf 'DEVELOPMENT_TEAM = %s\n' "$team_id" > "$ROOT_DIR/Config/Signing.local.xcconfig"
fi

resolve_device_info() {
  local device_json
  device_json="$(mktemp -t obadh-devices.XXXXXX.json)"
  xcrun devicectl list devices --json-output "$device_json" >/dev/null
  DEVICE_ID="$DEVICE_ID" python3 - "$device_json" <<'PY'
import json
import os
import sys

path = sys.argv[1]
wanted = os.environ.get("DEVICE_ID", "")
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

for device in payload.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})
    if hardware.get("platform") != "iOS":
        continue
    if hardware.get("reality") != "physical":
        continue
    identifiers = {
        device.get("identifier", ""),
        hardware.get("udid", ""),
        str(hardware.get("ecid", "")),
    }
    if wanted and wanted not in identifiers:
        continue
    print("\t".join([
        device.get("identifier", ""),
        hardware.get("udid", ""),
        properties.get("name", "iOS device"),
        connection.get("tunnelState", "unknown"),
    ]))
    break
PY
  rm -f "$device_json"
}

started_at="$SECONDS"
device_info=""
while true; do
  device_info="$(resolve_device_info)"
  if [[ -z "$device_info" ]]; then
    if [[ -n "$DEVICE_ID" ]]; then
      echo "No paired physical iPhone/iPad matched DEVICE_ID=$DEVICE_ID." >&2
    else
      echo "No paired physical iPhone/iPad found. Connect a device or set DEVICE_ID." >&2
    fi
    exit 1
  fi

  IFS=$'\t' read -r DEVICE_ID DEVICE_UDID DEVICE_NAME TUNNEL_STATE <<<"$device_info"
  if [[ "$TUNNEL_STATE" != "unavailable" ]]; then
    break
  fi

  if (( SECONDS - started_at >= DEVICE_WAIT_SECONDS )); then
    echo "$DEVICE_NAME is paired but currently unavailable to CoreDevice." >&2
    echo "Unlock it, keep it attached by USB, confirm Trust This Computer if prompted, then rerun this script." >&2
    echo "CoreDevice ID: $DEVICE_ID" >&2
    echo "Hardware UDID:  $DEVICE_UDID" >&2
    exit 1
  fi

  sleep 2
done

"$ROOT_DIR/scripts/stamp-build.sh"
xcodegen generate --spec "$ROOT_DIR/project.yml"

xcodebuild \
  -project "$ROOT_DIR/Obadh.xcodeproj" \
  -scheme Obadh \
  -configuration "$CONFIG" \
  -destination "platform=iOS,id=$DEVICE_UDID" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build

app_path="$DERIVED_DATA_DIR/Build/Products/$CONFIG-iphoneos/Obadh.app"
xcrun devicectl device install app --device "$DEVICE_ID" "$app_path"
if ! launch_output="$(
  xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" 2>&1
)"; then
  printf '%s\n' "$launch_output" >&2
  if grep -Eiq 'Locked|could not be unlocked|device was not.*unlocked' <<<"$launch_output"; then
    echo "Installed successfully. Unlock the device and open Obadh manually, or rerun this script to launch it." >&2
    exit 0
  fi
  exit 1
fi
printf '%s\n' "$launch_output"
