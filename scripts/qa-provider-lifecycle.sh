#!/usr/bin/env bash
# 加 provider / 删 provider 的真机 QA。
#
# 单元测试挡不住这条路上的崩溃：那条路走的是 WebKit 的 per-identifier data store，
# 而 swift-testing 进程不是真正的 App bundle —— 同样的调用在测试里永远是绿的，
# 只有在真 App 里才段错误。所以这里真的构建、真的以 App 身份跑一遍。
#
# 构建产物复制一份、换掉 bundle id 再跑，免得 QA 动到你自己那份的 WebKit 数据。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/app/Token Health.app"
QA_BUNDLE_ID="local.token-health.qa"
QA_DIR="$ROOT/.build/qa/Token Health QA.app"
QA_WEBKIT_DIR="$HOME/Library/WebKit/$QA_BUNDLE_ID"

bash "$ROOT/scripts/build-app.sh" >/dev/null

rm -rf "$QA_DIR"
mkdir -p "$(dirname "$QA_DIR")"
cp -R "$APP" "$QA_DIR"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $QA_BUNDLE_ID" "$QA_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$QA_DIR" 2>/dev/null

LOG="$(mktemp)"
set +e
"$QA_DIR/Contents/MacOS/TokenHealth" --qa-provider-lifecycle >"$LOG" 2>&1
status=$?
set -e

cat "$LOG"

# QA 用的是自己的 bundle id，跑完把它的 WebKit 数据一并清掉。
rm -rf "$QA_WEBKIT_DIR"

if [[ $status -ne 0 ]]; then
  rm -f "$LOG"
  echo >&2
  echo "QA FAILED: 退出码 $status$( [[ $status -eq 139 ]] && echo '（139 = 段错误，正是删 provider 那条路上的崩法）')" >&2
  exit 1
fi

if ! grep -q "^QA OK$" "$LOG"; then
  rm -f "$LOG"
  echo "QA FAILED: 进程正常退出，但没打印 QA OK" >&2
  exit 1
fi

rm -f "$LOG"
echo "provider 生命周期 QA 通过：添加、删除、删除从未建过会话的账号，都没崩。"
