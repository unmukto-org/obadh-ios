#!/usr/bin/env bash
# Native-parity suite: build both simulator configs, capture the device matrix,
# measure geometry + color against native, PASS/FAIL with tolerances.
#
#   scripts/parity/run.sh                          # default device set
#   scripts/parity/run.sh "iPhone 17 Pro"          # subset
#   SKIP_BUILD=1 scripts/parity/run.sh             # reuse existing builds
#
# Exit code: 0 all cells within tolerance, 1 violations, 2 harness failure.
# Artifacts (captures, probe logs, report.json) land in build/parity/<timestamp>.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$ROOT/build/parity/$STAMP
DEFAULT_DEVICES=("iPhone SE (3rd generation)" "iPhone 16" "iPhone 17 Pro" "iPhone Air" "iPhone 16 Plus" "iPhone 17 Pro Max")
DEVICES=("$@")
[[ ${#DEVICES[@]} -eq 0 ]] && DEVICES=("${DEFAULT_DEVICES[@]}")

if [[ -z "${SKIP_BUILD:-}" ]]; then
  for scheme_config in "Obadh Debug" "Obadh-Legacy Debug-Legacy"; do
    set -- $scheme_config
    echo "parity: building $2"
    xcodebuild build -project "$ROOT/Obadh.xcodeproj" -scheme "$1" -configuration "$2" \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$ROOT/build/DerivedData" -jobs 2 CODE_SIGNING_ALLOWED=NO -quiet \
      || { echo "parity: build failed ($2)"; exit 2; }
  done
fi

bash "$ROOT/scripts/parity/sweep.sh" "$OUT" "${DEVICES[@]}" || { echo "parity: sweep failed"; exit 2; }

python3 "$ROOT/scripts/parity/measure.py" "$OUT" --json "$OUT/report.json"
status=$?
echo "parity: artifacts in $OUT"
exit $status
