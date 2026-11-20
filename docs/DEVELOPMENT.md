# Development and diagnostics / 开发与诊断

[English home](../README.md) · [中文首页](../README.zh-CN.md) · [Testing limits](TRUST_AND_TESTING.md)

## Build

Requires macOS 15.4+ and a Swift 6 toolchain. The package uses Swift 5 language mode and has no external Swift package dependencies.

```sh
./Scripts/check.sh
open dist/build/debug/Auxmo.app
```

`check.sh` checks the product documentation, loads the toolchain's TestingMacros plugin, runs tests serially, builds an ad-hoc-signed app, checks its signature, and reads output/input diagnostics on the host Mac. It does not substitute another build system if the toolchain is missing.

- `Scripts/build-app.sh`: local debug app in `dist/build/debug/Auxmo.app`.
- `AUXMO_BUILD_CONFIGURATION=release ./Scripts/build-app.sh`: optimized local app in `dist/build/release/Auxmo.app`.
- `Scripts/check-ci.sh`: hardware-independent checks with a full Xcode/macOS 15 SDK environment, as used by Actions.
- `Scripts/build-release-assets.sh`: DMG, legacy-update ZIP, checksums, and package verification in `dist/releases/<version>/<arch>/`. The default `AUXMO_DMG_LAYOUT=finder` requires Finder access and fails if layout cannot be applied. CI explicitly uses `AUXMO_DMG_LAYOUT=plain` without Finder; it still verifies the app, DMG, ZIP, signatures, resources, and checksums.

App packaging starts in an empty temporary directory and verifies the complete signature before replacing the previous local build. Debug and Release packages cannot overwrite each other. Existing historical assets may be retained under `dist/archive/`; scripts never use that archive as a source or an alternate download.

`Scripts/archive-legacy-build.sh` archives an inactive legacy `dist/Auxmo.app` under `dist/archive/local-builds/`. File-identity checks reject active bundles, including path aliases. Builds also refuse to replace an active destination. To build a separate candidate deliberately, set `AUXMO_BUILD_OUTPUT_ROOT=dist/verification`; this is an explicit output choice, not an automatic retry at another location.

A local signature check is not Apple notarization. See [distribution limits](TRUST_AND_TESTING.md#distribution-and-permissions).

## Diagnostics

The normal reporting path is **Settings → Diagnostics → Export Diagnostics…**. It records current state and recent in-memory events. Review names, IDs, Bluetooth addresses, application identities, and protocol traces before sharing.

The low-level update staging checks remain covered by internal recovery tests and preserve the attached image, installer payload, and recovery backup. No manual Settings action is exposed.

The app and update helper share `~/Library/Logs/Auxmo/update.log`, with one rotated `update.log.1`. Each file is limited to 1 MiB; the lock file is separate. Writers lock across processes, oversized entries keep their UTF-8 tail, and rotation errors are reported without selecting a different log path.

The executable also has explicit diagnostic modes:

```sh
# Read output/input hardware state; no recording or output selection.
./dist/build/debug/Auxmo.app/Contents/MacOS/Auxmo --diagnose
./dist/build/debug/Auxmo.app/Contents/MacOS/Auxmo --diagnose-inputs

# Read app and audio-process state.
./dist/build/debug/Auxmo.app/Contents/MacOS/Auxmo --diagnose-applications

# Scan/connect and read headphone state. Quit the running Auxmo first.
./dist/build/debug/Auxmo.app/Contents/MacOS/Auxmo --diagnose-headphones
```

Headphone diagnostics use real control transports. They are not offline tests, do not prove mode writes or actual audio output, and must not run alongside another Auxmo instance or competing headphone controller.

## Structure

| Directory | Contents |
| --- | --- |
| `Sources/Auxmo/App/` | App startup, permissions, termination, and relaunch |
| `Sources/Auxmo/Model/` | Audio/session coordination and narrow feature façades |
| `Sources/Auxmo/Configuration/` | Independent configuration ownership, settings, and persistence |
| `Sources/Auxmo/ApplicationAudio/` | App/process observations and meter ownership |
| `Sources/Auxmo/UI/` | Common controls, devices, mixer, effects, settings, and status panels |
| `Sources/Auxmo/Updates/` | Download, extraction, staging, and update UI |
| `Sources/Auxmo/Diagnostics/` | Local diagnostic export and headphone diagnostics |
| `Sources/AuxmoCore/` | Core Audio devices, Process Taps, DSP, routing, and headphone protocols |
| `Sources/AuxmoUpdateHelper/` | Update replacement, rollback, and relaunch helper |
| `Sources/AuxmoUpdateSupport/` | Shared bounded update log and cross-process locking |
| `Tests/AuxmoPanelTests/` | Model integration, presentation, and UI layout tests |
| `Tests/AuxmoCoreTests/` | Protocol, routing, PCM, DSP, and lifecycle tests |
| `Tests/AuxmoUpdateHelperTests/` | Installation fault injection and quarantine preservation tests |
| `Tests/AuxmoUpdateSupportTests/` | Log bounds, UTF-8 tails, concurrent writers, and rotation failures |
| `Resources/` | App icon and bundle metadata |
| `ThirdParty/` | Third-party code origins and licenses |

## README and preview assets

For the resource state machine and fault-injection rules, see [Audio lifecycle](AUDIO_LIFECYCLE.md).

```sh
# Validate local links, anchors, and image references without network access.
python3 Scripts/check-docs.py

# Explicitly render both languages from memory fixtures, without real audio hardware.
./Scripts/render-readme-previews.sh
```

The preview test runs separately for each language. Ordinary test runs skip this documentation export; existing regression tests are unchanged. [Image provenance](images/README.md) explains the fixture values and generation process.

## 路由与更新的失败边界

- `StoredConfiguration` 独立持有每份配置的可用性与错误；`ApplicationAudioEffectsLibrary` 只编辑音效/预设，不能操作 tap；`ApplicationMeterController` 独立持有电平源、包络与计时器，不创建或停止会话。`AppModel` 只把已知配置交给同一音频生命周期协调链，不再保存另一份可写配置集合。
- 音效配置不可读时不覆盖坏记录，只禁用音效编辑，已有基础音量/静音/路由仍使用同一 tap 和明确目标；只有音效意图的旧会话先保留静音 tap 等待修复，明确关闭音效或开启基础管理后再协调。预设库单独不可读只禁用自定义预设操作，手动参数与内置预设仍可编辑。读取错误不会因编辑另一份配置而清除。设置未知值显示未选中，明确选择后才写回对应键；语言不可读时仅用系统语言绘制错误界面，不把它保存为恢复结果。
- 没有保存过应用路由是首次使用；已有记录类型错误或无法解码则是配置不可用，不能解释成“全部输出”。保留坏记录，暂停已有混音会话的重放；用户修复配置后，通过“重新读取路由配置”重新加载，不清除独立的音频处理错误。
- 历史设备记录只保留选择意图。判断旧路由仍有效时，必须在当前快照中确认 UID 与 ID；UID 消失时不使用旧 ID 选择设备或授权抢回默认输出。
- 更新保留隔离属性。安装失败时尝试恢复原版本，分别报告安装失败、恢复成功或恢复失败；恢复失败保留 `old` 备份，后续暂存清理不能删除它。启动命令成功后的清理错误单独报告，不回滚已请求启动的新版本。
- helper 的启动命令成功不等于新进程已健康启动。临时目录中的隔离属性测试也不等于真实下载、Gatekeeper 放行或公证验收。
- 更新镜像卸载失败会保留 `extracted/.auxmo-mounted-image` 和挂载路径，后续下载、跳过更新及清理都停止。底层残留检查仍由内部恢复测试覆盖，并保留镜像、安装包与备份；设置页不提供手动入口。

## 中文要点

`check.sh` 是真机上的本地门禁，`check-ci.sh` 需要完整 Xcode 和 macOS 15 SDK。命令成功不代表耳机实际发声、延迟、系统权限体验或长时间稳定性已验收。

优先在设置中导出诊断；命令行耳机诊断会真实连接设备，执行前先退出 Auxmo，不要与其他控制软件竞争通道。分享前检查并移除私人信息。

首页截图来自真实视图的内存夹具，不是实时播放证据。修改文档后运行链接检查；更新截图时使用专用脚本并检查两种语言。发布与真机验证边界见[发布清单](RELEASING.md)和[验证说明](TRUST_AND_TESTING.md#中文说明)。
