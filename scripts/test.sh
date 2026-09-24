#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

# 本机只装了 CommandLineTools，没有 Xcode：swift-testing 的 Testing.framework
# 不在 SwiftPM 默认搜索路径里，必须显式喂进去，否则连既有测试都编译不过。
if [[ ! -d "$FRAMEWORKS/Testing.framework" ]]; then
  echo "Testing.framework not found at $FRAMEWORKS" >&2
  exit 1
fi

cd "$ROOT"
exec swift test \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  "$@"
