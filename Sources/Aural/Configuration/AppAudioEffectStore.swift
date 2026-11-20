import Foundation
import AuralCore

enum AppAudioEffectStoreError: LocalizedError {
    case readFailed
    case writeFailed
    case presetsReadFailed
    case presetsWriteFailed

    var errorDescription: String? {
        switch self {
        case .readFailed:
            return "应用音效配置无法读取，请检查本地设置"
        case .writeFailed:
            return "应用音效配置无法保存，请检查本地设置"
        case .presetsReadFailed:
            return "音效预设无法读取，请检查本地设置"
        case .presetsWriteFailed:
            return "音效预设无法保存，请检查本地设置"
        }
    }
}

/// 音效配置只按稳定 bundle 身份保存，不使用 PID 或临时音频对象。
final class AppAudioEffectStore {
    private static let key = "local.aural.settings.appAudioEffects"
    private static let presetsKey = "local.aural.settings.appAudioEffectPresets"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> [String: AppAudioEffectSettings] {
        guard let raw = defaults.object(forKey: Self.key) else { return [:] }
        guard let data = raw as? Data else { throw AppAudioEffectStoreError.readFailed }
        do {
            let settings = try JSONDecoder().decode([String: AppAudioEffectSettings].self, from: data)
            guard settings.keys.allSatisfy({ $0.hasPrefix("bundle:") }),
                  settings.values.allSatisfy(\.isValid) else {
                throw AppAudioEffectStoreError.readFailed
            }
            // 旧三段记录被解码成十段后立即覆盖磁盘格式，避免每次启动都重复显示迁移状态。
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(settings)
            if encoded != data { defaults.set(encoded, forKey: Self.key) }
            return settings
        } catch {
            throw AppAudioEffectStoreError.readFailed
        }
    }

    func save(_ settings: [String: AppAudioEffectSettings]) throws {
        guard settings.keys.allSatisfy({ $0.hasPrefix("bundle:") }),
              settings.values.allSatisfy(\.isValid) else {
            throw AppAudioEffectStoreError.writeFailed
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(settings)
            defaults.set(data, forKey: Self.key)
        } catch {
            throw AppAudioEffectStoreError.writeFailed
        }
    }

    /// 自定义预设属于整个应用，而不是某个具体 App；窗口和所有应用行共享同一份预设库。
    func loadPresets() throws -> [AppAudioEffectCustomPreset] {
        guard let raw = defaults.object(forKey: Self.presetsKey) else { return [] }
        guard let data = raw as? Data else { throw AppAudioEffectStoreError.presetsReadFailed }
        do {
            let presets = try JSONDecoder().decode([AppAudioEffectCustomPreset].self, from: data)
            guard presets.allSatisfy(\.isValid),
                  Set(presets.map(\.id)).count == presets.count,
                  Set(presets.map(\.name)).count == presets.count else {
                throw AppAudioEffectStoreError.presetsReadFailed
            }
            return presets
        } catch {
            throw AppAudioEffectStoreError.presetsReadFailed
        }
    }

    func savePresets(_ presets: [AppAudioEffectCustomPreset]) throws {
        guard presets.allSatisfy(\.isValid),
              Set(presets.map(\.id)).count == presets.count,
              Set(presets.map(\.name)).count == presets.count else {
            throw AppAudioEffectStoreError.presetsWriteFailed
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            defaults.set(try encoder.encode(presets), forKey: Self.presetsKey)
        } catch {
            throw AppAudioEffectStoreError.presetsWriteFailed
        }
    }
}
