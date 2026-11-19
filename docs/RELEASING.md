# Release checklist / 发布检查清单

[English home](../README.md) · [中文首页](../README.zh-CN.md)

## What the current channel means

Aural uses stable version tags and direct GitHub downloads. The current packages are **ad-hoc signed, without Developer ID signing or Apple notarization**. “Stable release” describes the update channel, not certification of every audio setup or Gatekeeper acceptance.

Do not disable Gatekeeper or SIP to satisfy an installation test. Check [distribution and testing limits](TRUST_AND_TESTING.md).

## Before creating a release PR

- [ ] Match the source version, `Resources/Info.plist` display version, and a new build number.
- [ ] Add version-specific Chinese and English notes in `docs/releases/<version>.md`; update the changelog.
- [ ] Run `./Scripts/check.sh` on the host Mac and record the actual results.
- [ ] Run `./Scripts/build-release-assets.sh`, including signature, resource, ZIP/DMG, and checksum checks.
- [ ] Review privacy claims, known limitations, [headphone evidence](HEADPHONE_COMPATIBILITY.md), and third-party notices.
- [ ] Record which exact physical devices and scenarios were tested. Do not turn unrun checklist items into pass claims.

## Hardware acceptance

Use low device volumes and non-sensitive audio. These are per-setup checks, not a statement that every model has passed:

- [ ] App mute and zero gain across output changes, including active spatial effects.
- [ ] Speaker/headphone and multi-device member selection, removal, disconnect, and reconnect.
- [ ] The actual destination when the only custom per-app target becomes unavailable.
- [ ] Media and system-effects routing, Bluetooth timing, and the exact model's listening modes.
- [ ] Sleep/wake, app exit/restart, media-to-call format changes, and explicit Reapply.
- [ ] Clean installation, audio permission denial/grant, update/relaunch, and quit/resource cleanup.

Use [the full testing notes](TRUST_AND_TESTING.md#hardware-acceptance-checklist) and [diagnostics](DEVELOPMENT.md#diagnostics) to attach evidence. Any incomplete physical acceptance must remain distinguishable from automated results.

## Publish and verify

1. Open a `release/<major>.<minor>.<patch>` PR to `main`.
2. Wait for the PR workflow: macOS 15 checks and DMG/ZIP verification must pass. Do not weaken CI to make a release go through.
3. After the release PR is approved for publication and merged, the main workflow validates versions, reruns checks, and builds the assets.
4. The workflow creates a new tag and Release with DMG, legacy-update ZIP, and both SHA-256 files. Existing version tags must not be moved or overwritten.
5. Re-download the published assets and verify checksums, app version/build, bundle signature, and resources. Confirm the intended release is marked latest.

Keep Developer ID signing, hardened-runtime validation, Apple notarization, and clean-user installation acceptance separate from the current ad-hoc build checks. Intel compatibility must not be advertised without separate builds and tests.

## 中文要点

当前“稳定版”指版本和更新通道，不等于 Apple 认证或全硬件验收。发布包仍是 ad-hoc 签名，没有 Developer ID 签名及 Apple 公证。

发版前核对版本、构建号、双语说明、自动门禁和安装包，并如实记录真机测试范围。静音、零音量、音效尾音、设备断连、唯一自定义目标离线、休眠唤醒、通话格式变化、权限及升级都需要单独验收；不能用绿色 CI 代替。

通过 `release/<版本>` PR 发布，先等检查完成，再按明确的发布授权合并。创建新标签，不覆盖旧版本；发布后重新下载并核对实际资产。不要为安装或门禁关闭 Gatekeeper、SIP 或削弱 CI。
