# System audio permission / 系统音频权限

[English home](../README.md) · [中文首页](../README.zh-CN.md) · [Testing limits](TRUST_AND_TESTING.md)

## What the permission is for

Per-app volume, mute, output routing, effects, and levels use a Core Audio Process Tap. Auxmo needs system audio recording access to read those app streams; it processes them locally and does not save recordings. Tap creation or a successful callback is not proof of authorization or valid audio. Silence is not evidence of denial either.

The microphone page reads and changes input-device hardware properties. It does not create a microphone recording session.

## Current startup behavior

The source of truth is [StartupPermissions.swift](../Sources/Auxmo/App/StartupPermissions.swift) and [AuxmoApp.swift](../Sources/Auxmo/App/AuxmoApp.swift):

- Read the current authorization status on startup, not just an “asked before” preference. Either an explicit system-audio grant or a screen-capture grant is accepted for app-audio access.
- When access is not authorized, request it once through macOS. The system decides whether to display a prompt; Auxmo does not modify TCC permissions itself.
- On an explicit refusal, offer **Open System Settings** or **Quit**. Neither path enters the main interface or leaves an unusable background instance.
- When the current request has just granted access, relaunch the current app bundle to avoid a stale preflight value overriding the system callback.
- If the query API is unavailable or initialization fails, stop startup rather than assuming authorization.

After startup, permission is rechecked when the panel opens, the app becomes active, audio state is polled, or an app-audio control is used. Revocation stops sessions and clears levels while retaining gain and route intent. Reauthorization can require a relaunch; it does not clear unrelated processing failures.

## Non-public API dependency

macOS does not provide a public Process Tap authorization query. Auxmo isolates `TCCAccessPreflight`, `TCCAccessRequest`, and related non-public TCC symbols in [SystemAudioCaptureAccess.swift](../Sources/AuxmoCore/SystemAudioCaptureAccess.swift). It does not read the TCC database, scrape system logs, or switch authorization backends if those symbols are missing.

This integration can break after a macOS update and is not a basis for claiming a public-API-only Mac App Store build. Queries and requests stay outside the real-time audio callback.

## Verification boundary

Tests inject permission states and callbacks. They cover denial, authorization, unavailable APIs, cancellation, reauthorization, and restart ordering—not the actual system dialog on every macOS version or actual device playback.

Ad-hoc-signed updates may change code identity and affect saved permissions. Quit the older instance before replacing or launching a new build, and follow system prompts. Auxmo does not ask users to disable macOS security protections.

## 中文说明

应用混音、静音、路由、音效和电平需要读取应用音频流，因此需要系统音频录制权限；处理留在本机，不保存录音。创建 tap、回调成功或收到全零数据，都不能单独证明授权状态。麦克风页不建立麦克风录音会话。

当前启动流程把系统音频授权作为进入主界面的条件。系统明确拒绝后只提供“打开系统设置”与“退出”，不会留下禁用的主界面。本次申请刚获授权时会重启当前包，避免旧进程权限缓存影响。接口不可用则停止启动，不假定允许。

权限读取与申请依赖非公开 TCC 接口，系统升级可能影响它；实现不读权限数据库或系统日志、不更换后端，也不在实时回调里查权限。进入应用后仍会复查授权；撤销后停止处理并保留音量、路由意图，恢复授权可能需要重启。

相关测试使用注入状态，不能代替真实权限对话框和硬件验收。ad-hoc 更新可能影响已保存授权，替换版本前先退出旧实例，并遵循系统安全提示。
