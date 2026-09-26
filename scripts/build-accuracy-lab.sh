#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
# Include uncommitted experiment sources in the identity; do not stamp or bump
# the production app. Build outputs and personal session traces are excluded.
ACCURACY_FINGERPRINT="$(python3 - <<'PY'
import hashlib
from pathlib import Path
roots = [Path('Tools/TypingAccuracy'), Path('Shared/Sources')]
files = sorted([p for root in roots for p in root.rglob('*.swift')] + [Path('project.yml')])
h = hashlib.sha256()
for p in files:
    h.update(str(p).encode() + b'\0' + p.read_bytes() + b'\0')
print(h.hexdigest())
PY
)"
xcodegen generate
xcodebuild build -project Obadh.xcodeproj -scheme ObadhAccuracyLab \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/TouchAccuracyLabDevice -jobs 2 \
  "ACCURACY_SOURCE_REVISION=$ACCURACY_FINGERPRINT" "$@"
