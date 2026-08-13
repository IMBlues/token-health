#!/usr/bin/env bash
# Build the release DMG and reinstall Token Health (quit running app, replace, relaunch).
# Run from a normal Terminal (not inside a sandboxed shell):
#   bash scripts/install-release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="/Applications/Token Health.app"

echo "==> Building release DMG…"
DMG="$(bash "$ROOT/scripts/build-dmg.sh" | tail -1)"
echo "==> DMG: $DMG"

echo "==> Quitting running Token Health…"
osascript -e 'tell application "Token Health" to quit' >/dev/null 2>&1 || true
pkill -x TokenHealth >/dev/null 2>&1 || true
sleep 1

echo "==> Mounting DMG…"
MOUNT="$(hdiutil attach "$DMG" -nobrowse | tail -1 | awk -F '\t' '{print $NF}')"
if [[ -z "$MOUNT" || "$MOUNT" != /Volumes/* ]]; then
  echo "!! Failed to locate the mounted volume from hdiutil output" >&2
  exit 1
fi
echo "==> Mounted at: $MOUNT"

trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true' EXIT

echo "==> Replacing $APP_PATH…"
rm -rf "$APP_PATH"
cp -R "$MOUNT/Token Health.app" "$APP_PATH"
chown -R "$(whoami):staff" "$APP_PATH" 2>/dev/null || true

echo "==> Detaching DMG…"
hdiutil detach "$MOUNT"
trap - EXIT

echo "==> Launching Token Health…"
open "$APP_PATH"

echo "Installed: $APP_PATH"
