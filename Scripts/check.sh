#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 显式加载当前工具链自带的宏插件，避免 CLT 省略宏加载参数；缺失直接失败。
TOOLCHAIN_USR="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
TESTING_PLUGIN="$TOOLCHAIN_USR/lib/swift/host/plugins/testing/libTestingMacros.dylib"
test -f "$TESTING_PLUGIN"
# 发布文案必须按版本独立维护，避免每次 Release 重复历史功能和旧版安装说明。
./Scripts/check-release-notes.sh
# 产品文档必须能随仓库发布：不接受本地存在、却被忽略的配图或文档链接。
python3 ./Scripts/check-docs.py
# 与 CI 一致串行运行：AppKit 窗口、滚动条与外观测试共享进程级状态。
swift build --build-tests -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN"
./Scripts/prepare-test-resources.sh
swift test --skip-build --no-parallel -Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN"
./Scripts/build-app.sh
APP="${AURAL_BUILD_OUTPUT_ROOT:-dist/build}/${AURAL_BUILD_CONFIGURATION:-debug}/Aural.app"
codesign --verify --strict "$APP"
"$APP/Contents/MacOS/Aural" --diagnose

# 麦克风诊断只读硬件属性，不录音、不切换输入、不写入增益。
"$APP/Contents/MacOS/Aural" --diagnose-inputs
