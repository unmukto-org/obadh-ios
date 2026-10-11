#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install with: brew install xcodegen" >&2
  exit 1
fi

rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cargo fetch --manifest-path "$ROOT_DIR/rust/ObadhBridge/Cargo.toml"

if command -v xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
  "$ROOT_DIR/scripts/build-rust-xcframework.sh"
else
  echo "Skipping xcframework build because full Xcode is not selected." >&2
  echo "Install Xcode, run sudo xcode-select -s /Applications/Xcode.app, then rerun this script." >&2
fi

"$ROOT_DIR/scripts/fetch-sherpa-onnx.sh"

xcodegen generate --spec "$ROOT_DIR/project.yml"
