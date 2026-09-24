#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/.build/app/Token Health.app"
LEGACY_APP_DIR="$ROOT/.build/app/TokenHealth.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
COMPILER_VERSION="$(swiftc --version 2>&1 | sed -n 's/.*Apple Swift version \([^ ]*\).*/\1/p' | head -n 1)"
BUILD_KEY="${SDK_VERSION}-${COMPILER_VERSION:-unknown}"
SCRATCH_PATH="$ROOT/.build/swift-$BUILD_KEY"
MODULE_CACHE_PATH="$ROOT/.build/module-cache-$BUILD_KEY"
BUILT_BINARY="$SCRATCH_PATH/release/TokenHealth"

cd "$ROOT"
if python3 -c "import PIL" >/dev/null 2>&1; then
  if ! python3 "$ROOT/scripts/generate-icons.py" >/dev/null 2>&1; then
    if [[ -f "$ROOT/AppSupport/TokenHealth.icns" ]]; then
      echo "Icon generation failed; using existing AppSupport/TokenHealth.icns"
    else
      exit 1
    fi
  fi
elif [[ -f "$ROOT/AppSupport/TokenHealth.icns" ]]; then
  echo "Pillow is not installed; using existing AppSupport/TokenHealth.icns"
else
  echo "Pillow is required to generate AppSupport/TokenHealth.icns" >&2
  exit 1
fi
mkdir -p "$MODULE_CACHE_PATH"
SDKROOT="$SDK_PATH" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_PATH/clang" \
  SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_PATH/swiftpm" \
  swift build --disable-sandbox -c release --scratch-path "$SCRATCH_PATH"

BUILT_SDK="$(xcrun vtool -show-build "$BUILT_BINARY" | awk '/^[[:space:]]+sdk / { print $2; exit }')"
if [[ "$BUILT_SDK" != "$SDK_VERSION" ]]; then
  echo "Built with macOS SDK $BUILT_SDK; expected active SDK $SDK_VERSION" >&2
  exit 1
fi

RESOURCE_BUNDLE="$SCRATCH_PATH/release/TokenHealth_TokenHealth.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Missing $RESOURCE_BUNDLE; the Provider logo resources did not build." >&2
  exit 1
fi

rm -rf "$APP_DIR" "$LEGACY_APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILT_BINARY" "$APP_DIR/Contents/MacOS/TokenHealth"
cp "$ROOT/AppSupport/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/AppSupport/TokenHealth.icns" "$APP_DIR/Contents/Resources/TokenHealth.icns"
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
