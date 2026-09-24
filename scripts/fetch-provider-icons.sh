#!/usr/bin/env bash
# 抓取各 Provider 的官方 logo，转成矢量 PDF 放进 App 资源目录。
# 图标来自 lobehub 的 icons-static-svg，版本固定，保证可重复执行。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/Sources/TokenHealth/Resources/ProviderIcons"
PACKAGE="@lobehub/icons-static-svg@1.95.1"
BASE_URL="https://cdn.jsdelivr.net/npm/$PACKAGE/icons"
SLUGS=(openai anthropic cursor codex kimi zhipu deepseek minimax volcengine opencode)

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert not found. Install it with: brew install librsvg" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

for slug in "${SLUGS[@]}"; do
  target="$OUT_DIR/$slug.pdf"
  if [[ -s "$target" && "$FORCE" -eq 0 ]]; then
    echo "skip  $slug (already present)"
    continue
  fi

  source="$TMP_DIR/$slug.svg"
  if ! curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --max-time 30 -o "$source" "$BASE_URL/$slug.svg"; then
    echo "failed to download $slug from $BASE_URL" >&2
    exit 1
  fi

  if ! rsvg-convert -f pdf -o "$target" "$source"; then
    echo "failed to convert $slug to PDF" >&2
    exit 1
  fi

  if [[ ! -s "$target" ]] || [[ "$(head -c 4 "$target")" != "%PDF" ]]; then
    echo "$slug produced no usable PDF" >&2
    exit 1
  fi
  echo "wrote $slug.pdf"
done

echo "$OUT_DIR"
