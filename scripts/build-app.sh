#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/.build/app/TokenHealth.app"

cd "$ROOT"
if python3 -c "import PIL" >/dev/null 2>&1; then
  python3 "$ROOT/scripts/generate-icons.py" >/dev/null
elif [[ -f "$ROOT/AppSupport/TokenHealth.icns" ]]; then
  echo "Pillow is not installed; using existing AppSupport/TokenHealth.icns"
else
  echo "Pillow is required to generate AppSupport/TokenHealth.icns" >&2
  exit 1
fi
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT/.build/release/TokenHealth" "$APP_DIR/Contents/MacOS/TokenHealth"
cp "$ROOT/AppSupport/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/AppSupport/TokenHealth.icns" "$APP_DIR/Contents/Resources/TokenHealth.icns"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
