#!/bin/bash
set -euo pipefail
APP="$1"
[[ -e "$APP" ]] || exit 0
EXECUTABLE="$APP/Contents/MacOS/Aural"
[[ -f "$EXECUTABLE" ]] || { echo "无法确认应用可执行文件，未移动任何文件：$APP" >&2; exit 1; }
ERRORS="$(mktemp)"
trap 'STATUS=$?; rm -f "$ERRORS"; exit "$STATUS"' EXIT
# 按实际文件身份查询映射/打开的可执行文件，不能用 argv 字符串忽略 /var 与 /private/var 等路径别名。
if PIDS="$(/usr/sbin/lsof -t -- "$EXECUTABLE" 2>"$ERRORS")"; then
    echo "应用仍在使用中，请先正常退出；未移动任何文件：${APP}（PID：${PIDS}）" >&2
    exit 1
else
    STATUS=$?
    # lsof 的 1 且没有诊断表示没有匹配打开文件；任何其他失败都不能作为“应用已退出”的证据。
    if [[ "$STATUS" != "1" || -s "$ERRORS" ]]; then
        cat "$ERRORS" >&2
        echo "无法确认应用是否仍在使用，未移动任何文件：$APP" >&2
        exit 1
    fi
fi
