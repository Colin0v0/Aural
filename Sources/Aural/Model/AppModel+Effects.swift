import Foundation
import AuralCore

/// 音效编辑只委托配置所有者；只有参数确实保存后才更新会话。
extension AppModel {
    /// 未知配置只允许界面绘制禁用占位；真实处理必须通过下面的可用性检查。
    func applicationAudioEffect(for applicationID: String) -> AppAudioEffectSettings {
        guard let key = applicationRouteStorageKey(for: applicationID),
              let effect = effects.effect(for: key) else { return .disabled }
        return effect
    }

    func effectiveApplicationAudioEffect(for applicationID: String) -> AppAudioEffectSettings? {
        guard let key = applicationRouteStorageKey(for: applicationID) else { return nil }
        return effects.effective(for: key)
    }

    func isApplicationAudioEffectBypassed(for applicationID: String) -> Bool {
        guard let key = applicationRouteStorageKey(for: applicationID) else { return false }
        return effects.bypassedKeys.contains(key)
    }

    func setApplicationAudioEffectBypassed(_ bypassed: Bool, for applicationID: String) {
        guard let key = applicationRouteStorageKey(for: applicationID), !bypassed || effects.settings.available else { return }
        effects.setBypassed(bypassed, for: key)
        if let session = sessions[applicationID], session.mode == .mixing {
            session.setEffect(effectiveApplicationAudioEffect(for: applicationID))
        }
    }

    func previewApplicationAudioEffect(_ settings: AppAudioEffectSettings, for applicationID: String) {
        guard effects.settings.available, effects.enabled, settings.isValid,
              !isApplicationAudioEffectBypassed(for: applicationID) else { return }
        updateApplicationEffectSession(applicationID, preview: settings)
    }

    func setApplicationEffectsEnabled(_ enabled: Bool) {
        effects.setEnabled(enabled)
        for app in applications { reconcile(app) }
    }

    func setApplicationAudioEffect(_ settings: AppAudioEffectSettings, for applicationID: String) {
        guard let key = applicationRouteStorageKey(for: applicationID) else { return }
        guard effects.setEffect(settings, for: key) else { return }
        updateApplicationEffectSession(applicationID)
    }

    private func updateApplicationEffectSession(_ id: String, preview: AppAudioEffectSettings? = nil) {
        if let session = sessions[id], session.mode == .mixing {
            session.setEffect(preview ?? effectiveApplicationAudioEffect(for: id))
        } else if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
    }

    @discardableResult
    func createApplicationAudioEffectPreset(named name: String, eq: AppAudioEffectEQ) -> AppAudioEffectCustomPreset? {
        effects.createPreset(named: name, eq: eq)
    }

    func renameApplicationAudioEffectPreset(_ id: UUID, to name: String) { effects.renamePreset(id, to: name) }

    @discardableResult
    func duplicateApplicationAudioEffectPreset(_ id: UUID) -> AppAudioEffectCustomPreset? {
        effects.duplicatePreset(id, language: AppSettings.shared.resolvedLanguage)
    }

    func reloadApplicationAudioEffectPresets() { effects.presets.reload() }

    func deleteApplicationAudioEffectPreset(_ id: UUID) {
        if effects.deletePreset(id) { for app in applications { reconcile(app) } }
    }

}
