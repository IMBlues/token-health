#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/AppSupport/Info.plist")"
APP_DIR="$ROOT/.build/app/Token Health.app"
STAGING="$ROOT/.build/dmg/Token Health"
DIST="$ROOT/dist"
DMG="$DIST/TokenHealth-$VERSION.dmg"

"$ROOT/scripts/build-app.sh"

rm -rf "$STAGING"
mkdir -p "$STAGING" "$DIST"
cp -R "$APP_DIR" "$STAGING/Token Health.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "Token Health $VERSION" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

echo "$DMG"
