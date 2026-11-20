#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 迁移只针对旧的本地构建目录，不生成指向 Debug/Release 的别名，也不强退任何应用。
ROOT="${1:-dist}"
[[ -d "$ROOT" ]] || exit 0
ROOT="$(cd "$ROOT" && pwd -P)"
LEGACY="$ROOT/Auxmo.app"
[[ -e "$LEGACY" ]] || exit 0
if [[ -L "$LEGACY" || ! -d "$LEGACY" ]]; then
    echo "旧构建路径不是普通应用目录，拒绝自动迁移：$LEGACY" >&2; exit 1
fi
./Scripts/assert-app-idle.sh "$LEGACY"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$LEGACY/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$LEGACY/Contents/Info.plist")"
ARCHIVE="$ROOT/archive/local-builds"
mkdir -p "$ARCHIVE"
DESTINATION="$(mktemp -d "$ARCHIVE/legacy.XXXXXX")"
mv "$LEGACY" "$DESTINATION/Auxmo.app"
printf '旧本地构建 %s（%s）已归档：%s\n' "$VERSION" "$BUILD" "$DESTINATION/Auxmo.app"
