import Foundation
import AuralCore

/// 约束用户的路由选择；会话创建/释放仍只能回到 AppModel 的协调入口。
extension AppModel {
    /// 路由入口只在已确认、稳定的多设备组中出现；切换中的半成品组合不允许用户误选。
    var applicationAudioRoutingEnabled: Bool {
        guard applicationRouteConfigurationAvailable, audioCaptureAccess.allowsApplicationAudio,
              outputRouting.phase != .failed,
              !outputRouting.phase.isBusy,
              outputRouting.isSimultaneous,
              let confirmed = outputRouting.confirmed,
              confirmed.intent.isSimultaneous else { return false }
        let configured = outputRouting.configured?.memberUIDs ?? confirmed.intent.memberUIDs
        return Set(configured.filter { !$0.isEmpty }).count > 1
    }

    /// 菜单只展示当前真实可播放的组成员；暂时离线但仍在组内的 UID 会保留在持久化意图里。
    var availableApplicationRouteOutputs: [AudioOutput] {
        applicationRouteContext?.activeOutputs ?? []
    }

    func hasStableApplicationRouteIdentity(_ applicationID: String) -> Bool {
        applicationRouteStorageKey(for: applicationID) != nil
    }

    func applicationAudioRoute(for applicationID: String) -> AppAudioRoute? {
        guard applicationRouteConfigurationAvailable else { return nil }
        guard let key = applicationRouteStorageKey(for: applicationID) else { return .allOutputs }
        return appAudioRoutes[key] ?? .allOutputs
    }

    func effectiveApplicationAudioRoute(for applicationID: String) -> EffectiveAppAudioRoute {
        guard let resolved = resolvedApplicationAudioRoute(for: applicationID) else { return .configurationUnavailable }
        return resolved.effective
    }

    /// 等待意图不等于已成功暂停；只有静音会话确实停止重放且没有清理失败时才显示暂停。
    func applicationRoutePlaybackPaused(for applicationID: String) -> Bool {
        effectiveApplicationAudioRoute(for: applicationID).isWaitingForDevices
            && mixStates[applicationID]?.failure == nil
            && cleanupErrors[applicationID] == nil
            && sessions[applicationID]?.isSuspendedForOutputChange == true
            && sessions[applicationID]?.isActive == false
    }

    func applicationRouteUnavailableDeviceUIDs(for applicationID: String) -> Set<String> {
        resolvedApplicationAudioRoute(for: applicationID)?.unavailableDeviceUIDs ?? []
    }

    func resolvedApplicationAudioRoute(for applicationID: String) -> ResolvedAppAudioRoute? {
        guard let stored = applicationAudioRoute(for: applicationID) else { return nil }
        // 组合切换、失败、缩成单成员或退出模式时仍保留自定义意图。
        // 没有可信的组上下文就等待，不用当前默认设备替代用户选定的目标。
        let context = applicationRouteContext
        return AppAudioRouteResolver.resolve(
            stored: stored,
            configuredDeviceUIDs: context?.configuredUIDs ?? [],
            activeDeviceUIDs: context?.activeOutputs.map(\.uid) ?? []
        )
    }

    /// 设置自定义路由会实际创建/重建应用的 Process Tap 重放链，而不是只改界面勾选。
    func setApplicationAudioRoute(_ route: AppAudioRoute, for applicationID: String) {
        guard applicationRouteConfigurationAvailable else { return }
        guard refreshAudioCaptureAccess() else { return }
        guard let key = applicationRouteStorageKey(for: applicationID) else {
            operationError = "该应用没有稳定身份，不能设置持久应用路由"
            return
        }
        if case .custom(let deviceUIDs) = route {
            guard applicationAudioRoutingEnabled, let context = applicationRouteContext else {
                operationError = "应用路由仅在多设备输出模式下可用"
                return
            }
            guard !deviceUIDs.isEmpty else {
                operationError = "至少选择一台输出设备"
                return
            }
            guard let current = applicationAudioRoute(for: applicationID) else { return }
            let allowed = Set(context.configuredUIDs).union(current.customDeviceUIDs)
            guard deviceUIDs.isSubset(of: allowed) else {
                operationError = "应用路由目标必须来自当前多设备输出组"
                return
            }
        }
        // 全部输出是明确解除限制的操作；即使组已退出，也允许用户取消自定义路由。

        var nextRoutes = appAudioRoutes
        if route == .allOutputs {
            nextRoutes.removeValue(forKey: key)
        } else {
            nextRoutes[key] = route
        }
        guard routes.save(nextRoutes) else { return }
        if let app = applications.first(where: { $0.id == applicationID }) {
            reconcile(app)
        }
    }

    /// 复选框只操作当前可播放成员；暂时离线设备会在按 UID 重连后自动回到自定义集合。
    func toggleApplicationAudioRouteDevice(_ deviceUID: String, for applicationID: String) {
        guard refreshAudioCaptureAccess() else { return }
        guard applicationAudioRoutingEnabled, let context = applicationRouteContext else {
            operationError = "应用路由仅在多设备输出模式下可用"
            return
        }
        guard context.activeOutputs.contains(where: { $0.uid == deviceUID }) else {
            operationError = "应用路由目标必须来自当前多设备输出组"
            return
        }

        guard let current = applicationAudioRoute(for: applicationID) else { return }
        var selected = current.isCustom
            ? current.customDeviceUIDs
            : Set(context.activeOutputs.map(\.uid))
        if selected.contains(deviceUID) {
            // 最后一个输出不允许从应用路由中移除；这是无效操作，不产生顶部错误提示。
            guard selected.count > 1 else { return }
            selected.remove(deviceUID)
        } else {
            selected.insert(deviceUID)
        }
        setApplicationAudioRoute(.custom(deviceUIDs: selected), for: applicationID)
    }

    func resetApplicationAudioRoute(for applicationID: String) {
        setApplicationAudioRoute(.allOutputs, for: applicationID)
    }

    var applicationRouteContext: (configuredUIDs: [String], activeOutputs: [AudioOutput])? {
        guard applicationRouteConfigurationAvailable, audio != nil, outputRouting.phase != .failed,
              !outputRouting.phase.isBusy,
              outputRouting.isSimultaneous,
              let confirmed = outputRouting.confirmed,
              confirmed.intent.isSimultaneous else { return nil }
        let configured = outputRouting.configured?.memberUIDs ?? confirmed.intent.memberUIDs
        let unavailable = Set(outputRouting.unavailableMemberUIDs)
        let active = (confirmed.aggregate?.outputs ?? [confirmed.output]).filter { !unavailable.contains($0.uid) }
        return (configured.filter { !$0.isEmpty }, active)
    }

    func applicationRouteStorageKey(for applicationID: String) -> String? {
        let app = applications.first { $0.id == applicationID }
            ?? playingApplications.first { $0.id == applicationID }
        guard let app, !app.bundleID.isEmpty else { return nil }
        return "bundle:\(app.bundleID)"
    }

    /// 读取失败不覆盖已有真实错误；只有已知的失效/未知属性观察错误可获恢复资格。
}
