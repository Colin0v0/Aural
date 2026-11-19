# Development and diagnostics / 开发与诊断

[English home](../README.md) · [中文首页](../README.zh-CN.md) · [Testing limits](TRUST_AND_TESTING.md)

## Build

Requires macOS 15.4+ and a Swift 6 toolchain. The package uses Swift 5 language mode and has no external Swift package dependencies.

```sh
./Scripts/check.sh
open dist/Aural.app
```

`check.sh` checks the product documentation, loads the toolchain's TestingMacros plugin, runs tests serially, builds an ad-hoc-signed app, checks its signature, and reads output/input diagnostics on the host Mac. It does not substitute another build system if the toolchain is missing.

- `Scripts/build-app.sh`: local debug app in `dist/Aural.app`.
- `AURAL_BUILD_CONFIGURATION=release ./Scripts/build-app.sh`: optimized local app.
- `Scripts/check-ci.sh`: hardware-independent checks with a full Xcode/macOS 15 SDK environment, as used by Actions.
- `Scripts/build-release-assets.sh`: DMG, legacy-update ZIP, checksums, and package verification. This invokes Finder while preparing the DMG layout.

A local signature check is not Apple notarization. See [distribution limits](TRUST_AND_TESTING.md#distribution-and-permissions).

## Diagnostics

The normal reporting path is **Settings → Diagnostics → Export Diagnostics…**. It records current state and recent in-memory events. Review names, IDs, Bluetooth addresses, application identities, and protocol traces before sharing.

The executable also has explicit diagnostic modes:

```sh
# Read output/input hardware state; no recording or output selection.
./dist/Aural.app/Contents/MacOS/Aural --diagnose
./dist/Aural.app/Contents/MacOS/Aural --diagnose-inputs

# Read app and audio-process state.
./dist/Aural.app/Contents/MacOS/Aural --diagnose-applications

# Scan/connect and read headphone state. Quit the running Aural first.
./dist/Aural.app/Contents/MacOS/Aural --diagnose-headphones
```

Headphone diagnostics use real control transports. They are not offline tests, do not prove mode writes or actual audio output, and must not run alongside another Aural instance or competing headphone controller.

## Structure

| Directory | Contents |
| --- | --- |
| `Sources/Aural/` | SwiftUI/AppKit panels, settings, diagnostics, and app coordination |
| `Sources/AuralCore/` | Core Audio devices, Process Taps, DSP, routing, and headphone protocols |
| `Tests/AuralPanelTests/` | Model integration, presentation, and UI layout tests |
| `Tests/AuralCoreTests/` | Protocol, routing, PCM, DSP, and lifecycle tests |
| `Resources/` | App icon and bundle metadata |
| `ThirdParty/` | Third-party code origins and licenses |

## README and preview assets

```sh
# Validate local links, anchors, and image references without network access.
python3 Scripts/check-docs.py

# Explicitly render both languages from memory fixtures, without real audio hardware.
./Scripts/render-readme-previews.sh
```

The preview test runs separately for each language. Ordinary test runs skip this documentation export; existing regression tests are unchanged. [Image provenance](images/README.md) explains the fixture values and generation process.

## 中文要点

`check.sh` 是真机上的本地门禁，`check-ci.sh` 需要完整 Xcode 和 macOS 15 SDK。命令成功不代表耳机实际发声、延迟、系统权限体验或长时间稳定性已验收。

优先在设置中导出诊断；命令行耳机诊断会真实连接设备，执行前先退出 Aural，不要与其他控制软件竞争通道。分享前检查并移除私人信息。

首页截图来自真实视图的内存夹具，不是实时播放证据。修改文档后运行链接检查；更新截图时使用专用脚本并检查两种语言。发布与真机验证边界见[发布清单](RELEASING.md)和[验证说明](TRUST_AND_TESTING.md#中文说明)。
