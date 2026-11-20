import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import AuxmoCore

/// 执行真正的会话代码；只替换 HAL 返回值，不创建真实音频设备。
@MainActor
struct ProcessAudioSessionCleanupTests {
    @Test func successfulStopIsOrderedAndIdempotent() throws {
        let fixture = ProcessHardwareFixture()
        let session = fixture.session()
        try session.start()
        fixture.events.removeAll()
        try session.stop()
        #expect(fixture.events == [.stopIO, .destroyIO, .destroyAggregate, .destroyTap])
        #expect(session.isReleased && !session.isActive && !session.isSuspendedForOutputChange)
        #expect(fixture.renderState == nil)
        fixture.events.removeAll()
        try session.stop()
        #expect(fixture.events.isEmpty)
    }

    @Test func tapUpdateFailureStillStopsPlaybackButDoesNotClaimSuspended() throws {
        let fixture = ProcessHardwareFixture()
        let session = fixture.session()
        try session.start()
        fixture.errors[.updateTap] = HAL.badObjectStatus
        fixture.events.removeAll()
        let error = try #require(throws: AudioResourceFailures.self) { try session.suspendForOutputChange() }
        #expect(error.failures.first?.status == HAL.badObjectStatus)
        #expect(fixture.events == [.updateTap, .stopIO, .destroyIO, .destroyAggregate])
        #expect(!session.isActive && !session.isReleased && !session.isSuspendedForOutputChange)
        #expect(fixture.descriptions.last?.deviceUID == "headphone")
        fixture.errors.removeAll()
        try session.suspendForOutputChange()
        #expect(session.isSuspendedForOutputChange)
        try session.stop()
    }

    @Test func pauseRetainsBothFailuresAndCallbackMemoryUntilARealRetry() throws {
        let fixture = ProcessHardwareFixture()
        let session = fixture.session()
        try session.start()
        fixture.errors[.updateTap] = HAL.badObjectStatus
        fixture.errors[.stopIO] = kAudioHardwareIllegalOperationError
        fixture.events.removeAll()
        let error = try #require(throws: AudioResourceFailures.self) { try session.suspendForOutputChange() }
        #expect(error.failures.map(\.status) == [HAL.badObjectStatus, kAudioHardwareIllegalOperationError])
        #expect(fixture.events == [.updateTap, .stopIO])
        #expect(fixture.renderState != nil)
        #expect(fixture.renderState?.outputEnabled.load(ordering: .acquiring) == false)
        #expect(session.isActive && !session.isSuspendedForOutputChange)
        fixture.renderState?.callbacks.store(1, ordering: .relaxed)
        fixture.renderState?.peak.publish(0.8)
        #expect(session.consumePeak() == nil)
        #expect(throws: AudioFailure.self) { try session.checkHealth() }
        fixture.errors.removeAll()
        try session.suspendForOutputChange()
        #expect(session.isSuspendedForOutputChange && !session.isActive)
        try session.stop()
    }

    @Test func missingAggregateMustBeConfirmedBeforeReleasingCallback() throws {
        for present in [true, false] {
            let fixture = ProcessHardwareFixture()
            let session = fixture.session()
            try session.start()
            fixture.errors[.stopIO] = HAL.badDeviceStatus
            fixture.errors[.destroyIO] = HAL.badObjectStatus
            fixture.errors[.destroyAggregate] = HAL.badDeviceStatus
            fixture.devicePresent = present
            fixture.events.removeAll()
            if present {
                #expect(throws: AudioFailure.self) { try session.stop() }
                #expect(fixture.events == [.stopIO, .deviceExists])
                #expect(session.isActive && fixture.renderState != nil)
                fixture.errors.removeAll()
                try session.stop()
            } else {
                try session.stop()
                #expect(session.isReleased && fixture.renderState == nil)
                #expect(fixture.events.filter { $0 == .deviceExists }.count == 3)
                #expect(fixture.events.last == .destroyTap)
            }
        }
    }

    @Test func failedDisappearanceReadCannotReleaseCallbackMemory() throws {
        let fixture = ProcessHardwareFixture()
        let session = fixture.session()
        try session.start()
        fixture.errors[.stopIO] = HAL.badDeviceStatus
        fixture.errors[.deviceExists] = kAudioHardwareNotReadyError
        #expect(throws: AudioFailure.self) { try session.stop() }
        #expect(fixture.renderState != nil && session.isActive)
        fixture.errors.removeAll()
        try session.stop()
    }

    @Test(arguments: [ProcessHardwareFixture.Step.stopIO, .destroyIO, .destroyAggregate, .destroyTap])
    func retryResumesAtTheFailedReleaseStep(step: ProcessHardwareFixture.Step) throws {
        let fixture = ProcessHardwareFixture()
        let session = fixture.session()
        try session.start()
        fixture.errors[step] = kAudioHardwareIllegalOperationError
        #expect(throws: AudioFailure.self) { try session.stop() }
        #expect(!session.isReleased)
        // tap 销毁失败不能先丢弃描述，否则重试前连进程集合也无法更新。
        if step == .destroyTap {
            fixture.errors.removeAll()
            try session.updateProcesses(to: fixture.group)
        }
        fixture.events.removeAll()
        fixture.errors.removeAll()
        try session.stop()
        #expect(fixture.events.first == step)
        #expect(session.isReleased && fixture.renderState == nil)
    }

    @Test(arguments: [ProcessHardwareFixture.Step.createTap, .tapFormat, .createAggregate, .outputFormat, .createIO, .startIO])
    func partialStartNeverLosesResourceOwnership(step: ProcessHardwareFixture.Step) throws {
        let fixture = ProcessHardwareFixture()
        let session = fixture.session()
        fixture.errors[step] = kAudioHardwareIllegalOperationError
        #expect(throws: (any Error).self) { try session.start() }
        if step == .createTap { #expect(session.isReleased) }
        else { #expect(session.isSuspendedForOutputChange && !session.isActive) }
        fixture.errors.removeAll()
        try session.stop()
        #expect(session.isReleased && fixture.renderState == nil)
    }

    @Test func startAndUnregisterFailureRetainsContext() throws {
        let fixture = ProcessHardwareFixture()
        let session = fixture.session()
        fixture.errors[.startIO] = kAudioHardwareIllegalOperationError
        fixture.errors[.destroyIO] = kAudioHardwareUnsupportedOperationError
        #expect(throws: AudioResourceFailures.self) { try session.start() }
        #expect(fixture.renderState != nil && !session.isReleased && !session.isSuspendedForOutputChange)
        fixture.errors.removeAll()
        try session.stop()
        #expect(fixture.renderState == nil && session.isReleased)
    }

    @Test func repeatedSuspensionAndSwitchKeepOneTapAndUserSettings() throws {
        let fixture = ProcessHardwareFixture()
        let session = fixture.session()
        try session.setGain(0.3)
        session.setMuted(true)
        try session.start()
        for _ in 0..<30 {
            try session.suspendForOutputChange()
            try session.suspendForOutputChange()
            #expect(session.isSuspendedForOutputChange)
            try session.switchOutput(to: fixture.output, playbackRoute: .single(fixture.output))
            #expect(session.isActive && !session.isSuspendedForOutputChange)
            #expect(fixture.renderState?.target.load(ordering: .relaxed) == Float(0).bitPattern)
        }
        #expect(fixture.events.filter { $0 == .createTap }.count == 1)
        #expect(!fixture.events.contains(.destroyTap))
        #expect(session.gain == 0.3 && session.muted)
        try session.stop()
    }

    @Test func switchFailurePreservesOldRouteAndOneMuteTap() throws {
        let fixture = ProcessHardwareFixture()
        let session = fixture.session()
        try session.start()
        fixture.errors[.createAggregate] = kAudioHardwareIllegalOperationError
        let speaker = AudioOutput(id: 2, uid: "speaker", name: "扬声器", transport: kAudioDeviceTransportTypeBuiltIn)
        #expect(throws: (any Error).self) { try session.switchOutput(to: speaker, playbackRoute: .single(speaker)) }
        #expect(session.output == fixture.output && session.playbackRoute == .single(fixture.output))
        #expect(session.isSuspendedForOutputChange && !session.isActive)
        #expect(fixture.events.filter { $0 == .createTap }.count == 1)
        fixture.errors.removeAll()
        try session.stop()
    }

    @Test func absentTapIsConfirmedSeparatelyFromPlaybackDevice() throws {
        let fixture = ProcessHardwareFixture()
        let session = fixture.session()
        try session.startSuspended()
        fixture.errors[.destroyTap] = HAL.badObjectStatus
        #expect(throws: AudioFailure.self) { try session.stop() }
        #expect(!session.isReleased && session.isSuspendedForOutputChange)
        fixture.tapPresent = false
        try session.stop()
        #expect(session.isReleased)
        #expect(!fixture.events.contains(.deviceExists))
    }

    @Test func nestedCleanupFailuresKeepEveryOriginalStatus() {
        let first = AudioFailure("开始失败", status: 1)
        let nested = AudioResourceFailures(failures: [AudioFailure("解绑失败", status: 2), AudioFailure("停止失败", status: 3)])
        let combined = AudioResourceFailures([first, nested], operation: "启动")
        #expect(combined.failures.map(\.status) == [1, 2, 3])
    }

    @Test func deterministicFaultStormNeverDropsUnreleasedOwnership() throws {
        let steps: [ProcessHardwareFixture.Step] = [.updateTap, .stopIO, .destroyIO, .destroyAggregate]
        for iteration in 0..<240 {
            let fixture = ProcessHardwareFixture()
            let session = fixture.session()
            try session.start()
            let step = steps[iteration % steps.count]
            fixture.errors[step] = iteration % 2 == 0 ? HAL.badDeviceStatus : kAudioHardwareIllegalOperationError
            #expect(throws: AudioResourceFailures.self) { try session.suspendForOutputChange() }
            #expect(!session.isReleased)
            fixture.errors.removeAll()
            try session.suspendForOutputChange()
            #expect(session.isSuspendedForOutputChange)
            try session.switchOutput(to: fixture.output, playbackRoute: .single(fixture.output))
            #expect(session.isActive)
            try session.stop()
            #expect(session.isReleased && fixture.renderState == nil)
        }
    }

    @Test func diagnosticSnapshotReportsTheExactUnfinishedStepWithoutHALReads() throws {
        let fixture = ProcessHardwareFixture()
        let session = fixture.session()
        try session.start()
        #expect(session.resourceSnapshot.playbackStage == .running)
        fixture.errors[.destroyIO] = kAudioHardwareIllegalOperationError
        #expect(throws: (any Error).self) { try session.suspendForOutputChange() }
        fixture.events.removeAll()
        let snapshot = session.resourceSnapshot
        #expect(snapshot.playbackStage == .registered && snapshot.tapIsUnbound)
        #expect(snapshot.tapID == 100 && snapshot.aggregateID == 200 && !snapshot.replayEnabled)
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(AudioSessionResourceSnapshot.self, from: encoded) == snapshot)
        #expect(fixture.events.isEmpty)
        fixture.errors.removeAll()
        try session.stop()
        #expect(session.resourceSnapshot.playbackStage == .absent && session.resourceSnapshot.tapID == nil)
    }

    @Test func successfulUnbindingIsNotRolledBackWhenStoppingFails() throws {
        let fixture = ProcessHardwareFixture()
        let session = fixture.session()
        try session.start()
        fixture.errors[.stopIO] = kAudioHardwareIllegalOperationError
        #expect(throws: AudioResourceFailures.self) { try session.suspendForOutputChange() }
        #expect(session.resourceSnapshot.tapIsUnbound)
        #expect(session.resourceSnapshot.playbackStage == .running && !session.resourceSnapshot.replayEnabled)
        #expect(!session.isSuspendedForOutputChange)
        fixture.errors.removeAll()
        try session.suspendForOutputChange()
        #expect(session.isSuspendedForOutputChange)
        try session.stop()
    }

    @Test func failedMeteringStartReleasesTheUnmutedTapRatherThanKeepingMuteProtection() throws {
        let fixture = ProcessHardwareFixture()
        fixture.errors[.startIO] = kAudioHardwareIllegalOperationError
        let session = ProcessAudioSession(group: fixture.group, output: fixture.output,
                                          mode: .metering, hardware: fixture.hardware)
        #expect(throws: (any Error).self) { try session.start() }
        #expect(session.isReleased && !session.isSuspendedForOutputChange)
        #expect(fixture.descriptions.first?.muteBehavior == .unmuted)
        #expect(fixture.events.last == .destroyTap && fixture.renderState == nil)
    }
}

@MainActor
final class ProcessHardwareFixture {
    enum Step: String, CaseIterable {
        case createTap, updateTap, tapFormat, createAggregate, outputFormat, createIO, startIO
        case stopIO, destroyIO, destroyAggregate, destroyTap, deviceExists, tapExists
    }
    var errors: [Step: OSStatus] = [:]
    var events: [Step] = []
    var devicePresent = true
    var tapPresent = true
    var descriptions: [CATapDescription] = []
    weak var renderState: RenderState?
    let output = AudioOutput(id: 1, uid: "headphone", name: "测试耳机", transport: kAudioDeviceTransportTypeBluetooth)
    let group = AudioProcessGroup(id: "bundle:test.player", bundleID: "test.player", processIDs: [10], objectIDs: [20])
    let format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
        mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)

    func session() -> ProcessAudioSession { ProcessAudioSession(group: group, output: output, hardware: hardware) }
    private func status(_ step: Step) -> OSStatus {
        events.append(step)
        return errors[step] ?? noErr
    }
    private func check(_ step: Step) throws { try HAL.check(status(step), step.rawValue) }

    var hardware: ProcessAudioHardware {
        ProcessAudioHardware(createTap: { description in
            try self.check(.createTap); self.descriptions.append(description); return 100
        }, updateTap: { _, description in
            try self.check(.updateTap); self.descriptions.append(description)
        }, tapFormat: { _ in try self.check(.tapFormat); return self.format }, createAggregate: { _ in
            try self.check(.createAggregate); return 200
        }, outputFormat: { _ in try self.check(.outputFormat); return self.format }, createIO: { _, context in
            try self.check(.createIO)
            self.renderState = Unmanaged<RenderState>.fromOpaque(context).takeUnretainedValue()
            return auxmoAudioCallback
        }, startIO: { _, _ in self.status(.startIO) }, stopIO: { _, _ in self.status(.stopIO) },
            destroyIO: { _, _ in self.status(.destroyIO) }, destroyAggregate: { _ in self.status(.destroyAggregate) },
            destroyTap: { _ in self.status(.destroyTap) }, deviceExists: { _ in
            try self.check(.deviceExists); return self.devicePresent
        }, tapExists: { _ in try self.check(.tapExists); return self.tapPresent }, validateOutput: { _ in },
            processRoutes: { _ in [] })
    }
}
