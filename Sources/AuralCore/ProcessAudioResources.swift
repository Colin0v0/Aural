import AudioToolbox
import CoreAudio
import Foundation

/// 诊断只读所有权事实，不查询 HAL、不包含音频样本，便于区分停止、注销和销毁分别卡在哪一步。
public struct AudioSessionResourceSnapshot: Codable, Equatable, Sendable {
    public enum PlaybackStage: String, Codable, Sendable {
        case absent, aggregate, registered, running
    }
    public let tapID: AudioObjectID?
    public let tapIsUnbound: Bool
    public let playbackStage: PlaybackStage
    public let aggregateID: AudioDeviceID?
    public let replayEnabled: Bool
}

/// 只替换 HAL 边界，不替换会话决策；故障注入测试和产品使用完全相同的生命周期代码。
@MainActor
struct ProcessAudioHardware {
    var createTap: (CATapDescription) throws -> AudioObjectID
    var updateTap: (AudioObjectID, CATapDescription) throws -> Void
    var tapFormat: (AudioObjectID) throws -> AudioStreamBasicDescription
    var createAggregate: ([String: Any]) throws -> AudioDeviceID
    var outputFormat: (AudioDeviceID) throws -> AudioStreamBasicDescription
    var createIO: (AudioDeviceID, UnsafeMutableRawPointer) throws -> AudioDeviceIOProcID
    var startIO: (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus
    var stopIO: (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus
    var destroyIO: (AudioDeviceID, AudioDeviceIOProcID) -> OSStatus
    var destroyAggregate: (AudioDeviceID) -> OSStatus
    var destroyTap: (AudioObjectID) -> OSStatus
    var deviceExists: (AudioDeviceID) throws -> Bool
    var tapExists: (AudioObjectID) throws -> Bool
    var validateOutput: (AudioOutput) throws -> Void
    var processRoutes: (AudioProcessGroup) throws -> [ProcessOutputRoute]

    static var live: Self {
        Self(createTap: { description in
            var tapID: AudioObjectID = 0
            try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "创建应用音频捕获")
            return tapID
        }, updateTap: { try AudioHardwareTap(id: $0).setDescription($1) }, tapFormat: {
            try HAL.read($0, HAL.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription())
        }, createAggregate: { description in
            var deviceID: AudioDeviceID = 0
            try HAL.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID), "创建应用输出设备")
            return deviceID
        }, outputFormat: {
            try HAL.read($0, HAL.address(kAudioDevicePropertyStreamFormat, scope: kAudioDevicePropertyScopeOutput),
                         initial: AudioStreamBasicDescription())
        }, createIO: { deviceID, context in
            var ioProc: AudioDeviceIOProcID?
            try HAL.check(AudioDeviceCreateIOProcID(deviceID, auralAudioCallback, context, &ioProc), "创建实时音频回调")
            guard let ioProc else { throw AudioFailure("系统未返回音频回调句柄") }
            return ioProc
        }, startIO: AudioDeviceStart, stopIO: AudioDeviceStop, destroyIO: AudioDeviceDestroyIOProcID,
             destroyAggregate: AudioHardwareDestroyAggregateDevice, destroyTap: AudioHardwareDestroyProcessTap,
             deviceExists: HAL.deviceExists, tapExists: HAL.tapExists, validateOutput: { output in
            guard try HAL.ids(output.id, HAL.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)).isEmpty else {
                throw AudioFailure("本阶段仅支持独立输出设备，不接管带输入流的双工音频接口")
            }
            guard try HAL.ids(output.id, HAL.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)).count == 1 else {
                throw AudioFailure("本阶段仅支持单个输出流的设备")
            }
        }, processRoutes: { group in
            try group.objectIDs.map { object in
                let running: UInt32 = try HAL.read(object, HAL.address(kAudioProcessPropertyIsRunningOutput), initial: 0)
                let devices = try HAL.ids(object, HAL.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput))
                return ProcessOutputRoute(isRunningOutput: running != 0,
                    deviceUIDs: try devices.map { try HAL.string($0, kAudioDevicePropertyDeviceUID) })
            }
        })
    }
}

/// 多步操作失败保存每一步的状态码，而不是把第一条错误覆盖成最后一条文案。
struct AudioResourceFailures: LocalizedError {
    let failures: [AudioFailure]
    init(failures: [AudioFailure]) { self.failures = failures }
    init(_ errors: [Error], operation: String) {
        failures = errors.flatMap { error in
            if let combined = error as? AudioResourceFailures { return combined.failures }
            return [HAL.operationFailure(error, operation: operation)]
        }
    }
    var errorDescription: String? { failures.map(\.message).joined(separator: "；") }
}

/// tap 和重放端分别持有所有权；暂停只释放重放，明确停止才允许释放静音 tap。
@MainActor
final class ProcessAudioResources {
    private struct Tap {
        let id: AudioObjectID
        let description: CATapDescription
    }

    private final class Callback {
        let deviceID: AudioDeviceID
        let ioProc: AudioDeviceIOProcID
        let renderState: RenderState
        let format: AudioStreamBasicDescription
        private var context: Unmanaged<RenderState>?

        init(deviceID: AudioDeviceID, state: RenderState, format: AudioStreamBasicDescription,
             createIO: (AudioDeviceID, UnsafeMutableRawPointer) throws -> AudioDeviceIOProcID) throws {
            self.deviceID = deviceID
            self.renderState = state
            self.format = format
            // HAL 持有的原始指针有独立 retain；所有者意外销毁时也不能让回调访问已释放内存。
            let context = Unmanaged.passRetained(state)
            do { ioProc = try createIO(deviceID, context.toOpaque()) }
            catch { context.release(); throw error }
            self.context = context
        }

        func releaseContext() {
            context?.release()
            context = nil
        }

        deinit {
            // 正常注销会释放 retain；若注销失败却失去会话所有者，只关重放，保留上下文至进程退出。
            // 这里不能用 deinit 冒充 HAL 注销成功，也不能换另一条输出链路。
            renderState.outputEnabled.store(false, ordering: .releasing)
        }
    }

    private enum Playback {
        case absent
        case aggregate(AudioDeviceID)
        case registered(Callback)
        case running(Callback)
    }

    private let hardware: ProcessAudioHardware
    private var tap: Tap?
    private var playback: Playback = .absent

    init(hardware: ProcessAudioHardware) { self.hardware = hardware }

    var description: CATapDescription? { tap?.description }
    var hasTap: Bool { tap != nil }
    var isActive: Bool { if case .running = playback { return true }; return false }
    var isReleased: Bool { !hasTap && playbackAbsent }
    var isSuspended: Bool { hasTap && description?.deviceUID == nil && playbackAbsent }
    private var playbackAbsent: Bool { if case .absent = playback { return true }; return false }

    private var callback: Callback? {
        switch playback {
        case .registered(let callback), .running(let callback): return callback
        case .absent, .aggregate: return nil
        }
    }
    var renderState: RenderState? { callback?.renderState }
    var activeFormat: AudioStreamBasicDescription? { callback?.format }
    var playbackDeviceID: AudioDeviceID? {
        switch playback {
        case .absent: return nil
        case .aggregate(let deviceID): return deviceID
        case .registered(let callback), .running(let callback): return callback.deviceID
        }
    }

    var snapshot: AudioSessionResourceSnapshot {
        let stage: AudioSessionResourceSnapshot.PlaybackStage
        switch playback {
        case .absent: stage = .absent
        case .aggregate: stage = .aggregate
        case .registered: stage = .registered
        case .running: stage = .running
        }
        return AudioSessionResourceSnapshot(tapID: tap?.id, tapIsUnbound: hasTap && description?.deviceUID == nil,
            playbackStage: stage, aggregateID: playbackDeviceID,
            replayEnabled: renderState?.outputEnabled.load(ordering: .acquiring) == true)
    }

    func createTap(_ description: CATapDescription) throws {
        guard isReleased else { throw AudioFailure("该应用已接管，不能重复启动") }
        let tapID = try hardware.createTap(description)
        guard tapID != 0 else { throw AudioFailure("系统未返回应用捕获句柄") }
        tap = Tap(id: tapID, description: description)
    }

    func updateTap(_ description: CATapDescription) throws {
        guard let tap else { throw AudioFailure("应用静音捕获尚未创建") }
        do { try hardware.updateTap(tap.id, description) }
        catch { throw HAL.operationFailure(error, operation: "更新应用静音捕获") }
        // 写入成功立即记录事实，后续停止回调失败不能把 tap 描述退回旧值。
        self.tap = Tap(id: tap.id, description: description)
    }

    func startPlayback(route: ApplicationPlaybackRoute, mode: ApplicationAudioMode,
                       gain: Float, effect: AppAudioEffectSettings?) throws {
        guard let tap, playbackAbsent else { throw AudioFailure("旧重放资源尚未释放，不能重复启动") }
        let format = try hardware.tapFormat(tap.id)
        try ProcessAudioSession.validate(format)
        let deviceID = try hardware.createAggregate(route.aggregateDescription(
            tapUUID: tap.description.uuid, aggregateUID: "local.aural.tap.\(UUID().uuidString)"))
        guard deviceID != 0 else { throw AudioFailure("系统未返回应用输出句柄") }
        playback = .aggregate(deviceID)
        try ProcessAudioSession.requireMatchingPCM(captured: format, current: hardware.outputFormat(deviceID))
        let state = RenderState(sampleRate: format.mSampleRate, initialGain: 0, mode: mode,
                                effect: mode == .mixing ? effect : nil)
        state.target.store(gain.bitPattern, ordering: .relaxed)
        let callback = try Callback(deviceID: deviceID, state: state, format: format, createIO: hardware.createIO)
        playback = .registered(callback)
        try HAL.check(hardware.startIO(deviceID, callback.ioProc), "启动应用音频处理")
        playback = .running(callback)
    }

    func silencePlayback() {
        renderState?.outputEnabled.store(false, ordering: .releasing)
    }

    /// 每一步成功才推进状态；失败保留尚未释放的准确资源，重试不会重放已完成的销毁步骤。
    func stopPlayback() throws {
        silencePlayback()
        if case .running(let callback) = playback {
            try HAL.checkTeardown(hardware.stopIO(callback.deviceID, callback.ioProc), "停止音频回调",
                                  isObjectPresent: { try hardware.deviceExists(callback.deviceID) })
            playback = .registered(callback)
        }
        if case .registered(let callback) = playback {
            try HAL.checkTeardown(hardware.destroyIO(callback.deviceID, callback.ioProc), "释放音频回调",
                                  isObjectPresent: { try hardware.deviceExists(callback.deviceID) })
            callback.releaseContext()
            playback = .aggregate(callback.deviceID)
        }
        if case .aggregate(let deviceID) = playback {
            try HAL.checkTeardown(hardware.destroyAggregate(deviceID), "释放应用输出设备",
                                  isObjectPresent: { try hardware.deviceExists(deviceID) })
            playback = .absent
        }
    }

    func stop() throws {
        try stopPlayback()
        guard let tap else { return }
        try HAL.checkTeardown(hardware.destroyTap(tap.id), "释放应用音频捕获",
                              isObjectPresent: { try hardware.tapExists(tap.id) })
        self.tap = nil
    }
}
