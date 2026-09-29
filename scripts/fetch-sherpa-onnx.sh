#!/usr/bin/env bash
# Fetches the pinned sherpa-onnx iOS framework used by voice typing (containing app
# only; the keyboard never links it). One dynamic framework with ONNX Runtime linked
# in statically. Pinned by version AND checksum, so a changed upstream asset fails
# loudly instead of shipping something unreviewed.
set -euo pipefail

VERSION="1.13.8"
ASSET="sherpa-onnx-v${VERSION}-ios-shared-onnxruntime-static.xcframework.zip"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/${ASSET}"
SHA256="e259a7d3b38ad7dec49bb078252a30bb42ede8355e2bb130cf8c1c78ed131f75"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT_DIR/Frameworks/SherpaOnnxC.xcframework"
STAMP="$DEST/.obadh-version"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" ]]; then
  echo "sherpa-onnx $VERSION already present"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading sherpa-onnx $VERSION"
curl -fsSL -o "$TMP/$ASSET" "$URL"
echo "$SHA256  $TMP/$ASSET" | shasum -a 256 -c -
unzip -q "$TMP/$ASSET" -d "$TMP/out"
rm -rf "$DEST"
mkdir -p "$ROOT_DIR/Frameworks"
mv "$TMP/out/SherpaOnnxC.xcframework" "$DEST"
echo "$VERSION" > "$STAMP"
echo "Installed $DEST"
