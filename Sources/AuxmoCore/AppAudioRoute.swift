import Foundation

/// 应用路由保存的是用户意图，而不是当时那一组设备的快照。
/// `allOutputs` 会在多设备组变化时自动跟随；`custom` 只保留用户明确勾选的设备集合。
public enum AppAudioRoute: Codable, Equatable, Sendable {
    case allOutputs
    case custom(deviceUIDs: Set<String>)

    public var customDeviceUIDs: Set<String> {
        guard case .custom(let deviceUIDs) = self else { return [] }
        return deviceUIDs
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case deviceUIDs
    }

    private enum Kind: String, Codable {
        case allOutputs
        case custom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .allOutputs:
            self = .allOutputs
        case .custom:
            let values = try container.decode([String].self, forKey: .deviceUIDs)
            // 路由集合必须稳定且可复现；重复或空 UID 是损坏数据，不能静默修正。
            guard !values.isEmpty,
                  values.allSatisfy({ !$0.isEmpty }),
                  Set(values).count == values.count else {
                throw DecodingError.dataCorruptedError(
                    forKey: .deviceUIDs,
                    in: container,
                    debugDescription: "应用路由包含空值或重复设备 UID"
                )
            }
            self = .custom(deviceUIDs: Set(values))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allOutputs:
            try container.encode(Kind.allOutputs, forKey: .kind)
        case .custom(let deviceUIDs):
            guard !deviceUIDs.isEmpty, deviceUIDs.allSatisfy({ !$0.isEmpty }) else {
                throw EncodingError.invalidValue(
                    deviceUIDs,
                    EncodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "应用路由不能保存空设备集合"
                    )
                )
            }
            try container.encode(Kind.custom, forKey: .kind)
            // Set 没有稳定顺序；排序后再编码，避免相同配置产生不同持久化结果。
            try container.encode(deviceUIDs.sorted(), forKey: .deviceUIDs)
        }
    }
}

/// 运行时可用性不写回持久化意图；没有目标是明确的等待状态，不是“全部输出”。
public enum EffectiveAppAudioRoute: Equatable, Sendable {
    case allOutputs
    case custom(deviceUIDs: Set<String>)
    case waitingForDevices
    case configurationUnavailable

    public var isCustom: Bool {
        switch self {
        case .custom, .waitingForDevices: return true
        case .allOutputs, .configurationUnavailable: return false
        }
    }
    public var isWaitingForDevices: Bool { self == .waitingForDevices }
    public var customDeviceUIDs: Set<String> {
        guard case .custom(let uids) = self else { return [] }
        return uids
    }
}

/// 保存用户选择，另报当前可以播放的子集；离线或移出组都不能悄悄扩大输出范围。
public struct ResolvedAppAudioRoute: Equatable, Sendable {
    public let persisted: AppAudioRoute
    public let effective: EffectiveAppAudioRoute
    public let unavailableDeviceUIDs: Set<String>

    public init(persisted: AppAudioRoute, effective: EffectiveAppAudioRoute,
                unavailableDeviceUIDs: Set<String>) {
        self.persisted = persisted
        self.effective = effective
        self.unavailableDeviceUIDs = unavailableDeviceUIDs
    }
}

/// 纯函数路由约束，集合决策不进入实时音频回调。
public enum AppAudioRouteResolver {
    public static func resolve(stored: AppAudioRoute,
                               configuredDeviceUIDs: [String],
                               activeDeviceUIDs: [String]) -> ResolvedAppAudioRoute {
        let configured = Set(configuredDeviceUIDs.filter { !$0.isEmpty })
        let active = Set(activeDeviceUIDs.filter { configured.contains($0) })
        switch stored {
        case .allOutputs:
            return ResolvedAppAudioRoute(persisted: stored, effective: .allOutputs,
                                         unavailableDeviceUIDs: [])
        case .custom(let requested):
            let targets = requested.intersection(active)
            // 保留完整请求，包括已经移出组的设备。只有新的明确选择才能修改它。
            return ResolvedAppAudioRoute(
                persisted: stored,
                effective: targets.isEmpty ? .waitingForDevices : .custom(deviceUIDs: targets),
                unavailableDeviceUIDs: requested.subtracting(active)
            )
        }
    }
}
