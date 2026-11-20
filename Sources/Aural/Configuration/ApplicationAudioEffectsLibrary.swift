import Foundation
import AuralCore

/// 音效配置和预设库各自持有读取资格；本对象不拥有 tap、不协调输出，也不修改全局操作错误。
@MainActor
final class ApplicationAudioEffectsLibrary {
    let settings: StoredConfiguration<[String: AppAudioEffectSettings]>
    let presets: StoredConfiguration<[AppAudioEffectCustomPreset]>
    private(set) var enabled: Bool
    private(set) var bypassedKeys: Set<String> = []
    private(set) var actionError: String?
    var willChange: () -> Void = {}

    init(store: AppAudioEffectStore, enabled: Bool) {
        settings = StoredConfiguration(read: store.load, write: store.save)
        presets = StoredConfiguration(read: store.loadPresets, write: store.savePresets)
        self.enabled = enabled
    }

    var error: String? {
        let messages = [settings.error, presets.error, actionError].compactMap { $0 }
        var seen: Set<String> = []
        let unique = messages.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: "；")
    }

    func effect(for key: String) -> AppAudioEffectSettings? {
        guard let known = settings.value else { return nil }
        return known[key] ?? .disabled
    }

    func effective(for key: String) -> AppAudioEffectSettings? {
        guard enabled, !bypassedKeys.contains(key), let effect = effect(for: key), effect.enabled else { return nil }
        return effect
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        willChange(); self.enabled = enabled
    }

    func setBypassed(_ bypassed: Bool, for key: String) {
        guard !bypassed || settings.available else { return }
        willChange()
        if bypassed { bypassedKeys.insert(key) } else { bypassedKeys.remove(key) }
    }

    @discardableResult
    func setEffect(_ effect: AppAudioEffectSettings, for key: String) -> Bool {
        guard var next = settings.value else { return false }
        guard effect.isValid else {
            fail(effect.eq.isValid ? "空间效果强度必须在 0～100% 之间" : "应用音效增益必须在 -12～12 dB 之间")
            return false
        }
        next[key] = effect
        guard settings.save(next) else { return false }
        clearActionError()
        return true
    }

    func createPreset(named name: String, eq: AppAudioEffectEQ) -> AppAudioEffectCustomPreset? {
        guard let known = presets.value else { return nil }
        let preset = AppAudioEffectCustomPreset(name: name.trimmingCharacters(in: .whitespacesAndNewlines), eq: eq)
        guard preset.isValid else { fail("预设名称不能为空，且不能超过 40 个字符"); return nil }
        guard !known.contains(where: { $0.name == preset.name }) else { fail("已存在同名预设"); return nil }
        guard presets.save(known + [preset]) else { return nil }
        clearActionError()
        return preset
    }

    func renamePreset(_ id: UUID, to name: String) {
        guard var next = presets.value, let index = next.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { fail("预设名称不能为空，且不能超过 40 个字符"); return }
        guard !next.contains(where: { $0.id != id && $0.name == trimmed }) else { fail("已存在同名预设"); return }
        next[index].name = trimmed
        if presets.save(next) { clearActionError() }
    }

    func duplicatePreset(_ id: UUID, language: AppLanguage) -> AppAudioEffectCustomPreset? {
        guard let known = presets.value, let source = known.first(where: { $0.id == id }) else { return nil }
        var name = L10n.format("%@ 副本", language: language, arguments: [source.name])
        var number = 2
        while known.contains(where: { $0.name == name }) {
            name = L10n.format("%@ 副本 %d", language: language, arguments: [source.name, number])
            number += 1
        }
        return createPreset(named: name, eq: source.eq)
    }

    @discardableResult
    func deletePreset(_ id: UUID) -> Bool {
        guard let known = presets.value, var effects = settings.value,
              known.contains(where: { $0.id == id }) else { return false }
        var changed = false
        for (key, effect) in effects {
            guard case .custom(let presetID) = effect.preset, presetID == id else { continue }
            var updated = effect; updated.preset = .manual
            effects[key] = updated; changed = true
        }
        // 先解除引用再删预设。若第二次写入失败，预设仍在且音色不变；明确保留该配置的错误。
        if changed, !settings.save(effects) { return false }
        guard presets.save(known.filter { $0.id != id }) else { return false }
        clearActionError()
        return true
    }

    func reload() {
        settings.reload(); presets.reload()
        // 重新读取只恢复配置资格，不清理独立的校验/编辑错误或任何音频会话错误。
    }

    private func fail(_ message: String) { willChange(); actionError = message }
    private func clearActionError() { willChange(); actionError = nil }
}
