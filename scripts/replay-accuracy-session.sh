#!/bin/zsh
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -ne 1 ]]; then
  print -u2 'Usage: scripts/replay-accuracy-session.sh session.json'
  exit 2
fi
mkdir -p "$TASK_ROOT/build/TypingAccuracyReplay"
# Compile the actual resolver, rather than a second implementation in Python.
swiftc -O -parse-as-library \
  "$TASK_ROOT/Shared/Sources/Keyboard/KeyboardLayout.swift" \
  "$TASK_ROOT/Shared/Sources/Keyboard/KeyboardTouchResolver.swift" \
  "$TASK_ROOT/Tools/TypingAccuracy/Core/TypingAccuracyMetrics.swift" \
  "$TASK_ROOT/Tools/TypingAccuracy/Replay/Replay.swift" \
  -o "$TASK_ROOT/build/TypingAccuracyReplay/replay"
"$TASK_ROOT/build/TypingAccuracyReplay/replay" "$1"
