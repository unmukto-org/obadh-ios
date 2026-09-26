#!/usr/bin/env bash
# Run every native-parity gate we have, serially, and report one verdict.
#
# Serial on purpose: running simulators in parallel is slower on this hardware and
# produces flaky captures (a device that has not finished booting screenshots the
# Apple logo). The iPad landscape gate additionally REQUIRES exclusivity — it
# drives Simulator's Device > Orientation menu, which needs one booted device and
# the window frontmost.
#
# Usage: scripts/parity/all.sh [--skip-build]
#
# Coverage, and what it does NOT cover, is documented in KNOWN-ISSUES.md#ki-007.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH=${OBADH_SCRATCH:?set OBADH_SCRATCH to the directory holding the capture scripts}
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$ROOT/build/parity-all/$STAMP
mkdir -p "$OUT"
failures=0

step() {
  echo
  echo "================ $1 ================"
}

step "1/4  iPhone portrait (6 devices x modern/legacy x light/dark)"
if [[ "${1:-}" == "--skip-build" ]]; then
  SKIP_BUILD=1 bash "$ROOT/scripts/parity/run.sh" 2>&1 | tail -40 | tee "$OUT/iphone-portrait.txt"
else
  bash "$ROOT/scripts/parity/run.sh" 2>&1 | tail -40 | tee "$OUT/iphone-portrait.txt"
fi
grep -q "^parity: PASS" "$OUT/iphone-portrait.txt" || { echo "FAILED"; failures=$((failures+1)); }

step "2/4  iPhone landscape (6 devices)"
bash "$SCRATCH/iphone-landscape-sweep.sh" "$OUT/iphone-landscape" 2>&1 \
  | tee "$OUT/iphone-landscape.txt" | grep -E "^===|PASS|FAIL|ALL"
grep -q "ALL PASS" "$OUT/iphone-landscape.txt" || { echo "FAILED"; failures=$((failures+1)); }

step "3/4  iPad portrait (5 devices)"
mkdir -p "$OUT/ipad-portrait"
for pair in \
  "F9E7967C-A93E-4F3C-9504-7EF5EA1F2087 mini" \
  "AD3DD6F5-AA9E-40C9-B706-F0359CA40DB8 ipad" \
  "D360909D-640D-48E6-AA07-147D292FBC83 pro11" \
  "9792AF7D-2FC2-4E9B-BFE5-7F23AA4B5F29 air13" \
  "05657859-3EDE-4130-9600-E00F73BA14EE pro13"; do
  set -- $pair
  bash "$SCRATCH/capture-ribbon.sh" "$1" "$2" "$OUT/ipad-portrait" >/dev/null 2>&1 || echo "  $2 capture failed"
done
python3 "$ROOT/scripts/parity/ipad-geometry.py" compare "$OUT/ipad-portrait" 2>&1 \
  | tee "$OUT/ipad-portrait.txt" | grep -E "^===|PASS|FAIL|ALL"
grep -q "ALL PASS" "$OUT/ipad-portrait.txt" || { echo "FAILED"; failures=$((failures+1)); }

step "4/4  iPad landscape (5 devices, exclusive)"
mkdir -p "$OUT/ipad-landscape"
for pair in \
  "F9E7967C-A93E-4F3C-9504-7EF5EA1F2087 mini" \
  "AD3DD6F5-AA9E-40C9-B706-F0359CA40DB8 ipad" \
  "D360909D-640D-48E6-AA07-147D292FBC83 pro11" \
  "9792AF7D-2FC2-4E9B-BFE5-7F23AA4B5F29 air13" \
  "05657859-3EDE-4130-9600-E00F73BA14EE pro13"; do
  set -- $pair
  bash "$SCRATCH/rotate-capture.sh" "$1" "$2" "$OUT/ipad-landscape" obadh >/dev/null 2>&1 || echo "  $2 capture failed"
done
python3 "$ROOT/scripts/parity/ipad-geometry.py" compare "$OUT/ipad-landscape" --landscape 2>&1 \
  | tee "$OUT/ipad-landscape.txt" | grep -E "^===|PASS|FAIL|ALL"
grep -q "ALL PASS" "$OUT/ipad-landscape.txt" || { echo "FAILED"; failures=$((failures+1)); }

echo
echo "================================================"
if [[ $failures -eq 0 ]]; then
  echo "ALL GATES PASS   artifacts in $OUT"
else
  echo "$failures GATE(S) FAILED   artifacts in $OUT"
fi
exit $((failures > 0))
