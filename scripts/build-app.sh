#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/.build/app/TokenHealth.app"

cd "$ROOT"
python3 "$ROOT/scripts/generate-icons.py" >/dev/null
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT/.build/release/TokenHealth" "$APP_DIR/Contents/MacOS/TokenHealth"
cp "$ROOT/AppSupport/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/AppSupport/TokenHealth.icns" "$APP_DIR/Contents/Resources/TokenHealth.icns"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
