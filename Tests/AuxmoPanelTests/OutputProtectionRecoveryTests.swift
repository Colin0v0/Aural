import CoreAudio
import Foundation
import Testing
@testable import Auxmo
@testable import AuxmoCore

/// 全部硬件和进程数据都在内存中；不切换宿主输出，不操作真实播放器。
@MainActor
struct OutputProtectionRecoveryTests {
    @MainActor private final class Fixture {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let defaults: UserDefaults
        let suite = "Auxmo.OutputProtectionRecovery.\(UUID().uuidString)"
        let model: AppModel
        var id: String { audio.row.id }
        init(headphoneSelected: Bool = false, userSelecting: Bool = false) throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            if headphoneSelected { hardware.selected = 2; hardware.systemSelected = 2 }
            model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                applicationAudio: audio.environment, userIsSelectingOutput: { userSelecting },
                appAudioRouteStore: AppAudioRouteStore(defaults: defaults),
                appAudioEffectStore: AppAudioEffectStore(defaults: defaults), appAudioEffectsEnabled: true)
        }
        func close() {
            #expect(model.shutdown())
            defaults.removePersistentDomain(forName: suite)
        }
        func unknownPropertyRead() {
            audio.readError = AudioFailure("读取音频属性失败（Core Audio 2003332927）",
                                            status: kAudioHardwareUnknownPropertyError)
            model.refresh()
        }
    }

    @Test func disconnectedHeadphoneMutesOnlyTheUnexpectedSpeaker() throws {
        let f = try Fixture(headphoneSelected: true)
        defer { f.close() }
        f.model.setApplicationGain(0.4, for: f.id)
        f.model.toggleApplicationMute(f.id)
        let session = try #require(f.model.sessions[f.id] as? MemoryAudioSession)
        f.hardware.beforeMute = { _ in
            #expect(session.isSuspendedForOutputChange && !session.isActive)
        }
        f.hardware.outputs.removeAll { $0.id == 2 }
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        #expect(f.hardware.muteWrites.count == 1)
        #expect(f.hardware.muteWrites.first?.0 == true && f.hardware.muteWrites.first?.1 == 1)
        #expect(f.hardware.mutedIDs == [1])
        let control = try #require(f.model.audio?.controls[1])
        guard case .available(_, let mute) = control else {
            Issue.record("意外接替设备的静音状态必须在同一轮刷新中读回")
            return
        }
        #expect(mute.muted == true)
        #expect(f.model.outputRouting.confirmed?.output.uid == "speaker")
        #expect(session.gain == 0.4 && session.muted)
        #expect(session.stopCount == 0 && session.suspendCount >= 1)
        for _ in 0..<3 { f.model.refresh() }
        #expect(f.hardware.muteWrites.count == 1)
        // 重连、主动选回耳机，都没有权限取消刚才的扬声器静音。
        f.hardware.outputs.append(AudioOutput(id: 2, uid: "headphone", name: "耳机",
                                              transport: kAudioDeviceTransportTypeBluetooth))
        f.model.selectOutput(2)
        #expect(f.hardware.mutedIDs == [1])
        #expect(f.hardware.muteWrites.allSatisfy { $0.0 })
    }

    /// 旧 UI 快照仍在时，如果 HAL 复用句柄给另一设备，不能向新设备写入静音。
    @Test func reusedOutputHandleCannotReceiveOldDevicesMuteAction() throws {
        let f = try Fixture()
        defer { f.close() }
        let original = try #require(f.model.audio?.outputs.first { $0.id == 2 })
        f.hardware.outputs.removeAll { $0.id == 2 }
        f.hardware.outputs.append(AudioOutput(id: 2, uid: "replacement", name: "其他设备",
                                              transport: kAudioDeviceTransportTypeUSB))
        f.model.setOutputMuted(true, on: original)
        #expect(f.hardware.muteWrites.isEmpty)
        #expect(f.model.operationError != nil)
    }

    /// 用户静音已写入但设备稍后读回时，不能重复写入，也不能立即报错。
    @Test func ordinaryDeviceMuteWaitsForSameDeviceReadback() async throws {
        let f = try Fixture()
        defer { f.close() }
        let headphone = try #require(f.model.audio?.outputs.first { $0.id == 2 })
        f.hardware.deferMute = true
        f.model.setOutputMuted(true, on: headphone)
        #expect(f.model.operationError == nil)
        #expect(f.hardware.muteWrites.count == 1)
        f.hardware.commitMute(on: 2)
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(f.hardware.muteWrites.count == 1)
        #expect(f.model.operationError == nil)
        guard case .available(_, let mute)? = f.model.audio?.controls[2] else {
            Issue.record("设备读回应保持可用")
            return
        }
        #expect(mute.muted == true)
    }

    /// 新设备继承旧数字句柄后，即使新快照已刷新，旧视图操作也不得改变新设备。
    @Test func staleViewCannotMuteReplacementAfterSnapshotRefresh() throws {
        let f = try Fixture()
        defer { f.close() }
        let original = try #require(f.model.audio?.outputs.first { $0.id == 2 })
        f.hardware.outputs.removeAll { $0.id == 2 }
        f.hardware.outputs.append(AudioOutput(id: 2, uid: "replacement", name: "其他设备",
                                              transport: kAudioDeviceTransportTypeUSB))
        f.model.refresh()
        f.model.setOutputMuted(true, on: original)
        #expect(f.hardware.muteWrites.isEmpty)
        #expect(f.model.operationError != nil)
    }

    @Test func groupMuteReportsConfirmedAndFailedMembersWithoutUndoingSuccess() throws {
        let f = try Fixture()
        defer { f.close() }
        #expect(f.model.startSimultaneousOutput(["headphone", "usb"]))
        f.hardware.failMuteIDs.insert(3)
        f.model.setSimultaneousOutputMuted(true)
        #expect(f.hardware.mutedIDs.contains(2))
        #expect(!f.hardware.mutedIDs.contains(3))
        #expect(f.model.operationError?.contains("测试耳机") == true)
        #expect(f.model.operationError?.contains("测试 USB") == true)
        #expect(f.hardware.muteWrites.filter { $0.1 == 2 }.count == 1)
    }

    @Test func offlineButStillEnumeratedHeadphoneCannotRestoreAnInvalidOldRoute() throws {
        let f = try Fixture(headphoneSelected: true)
        defer { f.close() }
        f.model.setApplicationGain(0.4, for: f.id)
        f.hardware.offline.insert(2)
        f.hardware.activePlayback = [2]
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        #expect(!f.hardware.selections.contains(2))
        #expect(f.hardware.mutedIDs == [1])
        #expect(f.model.outputRouting.confirmed?.output.uid == "speaker")
    }

    @Test func unrelatedDeviceDepartureAndSystemEffectsChangesDoNotMuteMediaOutput() throws {
        let f = try Fixture(headphoneSelected: true)
        defer { f.close() }
        f.hardware.outputs.removeAll { $0.id == 3 }
        f.hardware.systemSelected = 1
        f.model.refresh()
        #expect(f.model.outputRouting.confirmed?.output.uid == "headphone")
        #expect(f.hardware.muteWrites.isEmpty)
    }

    @Test func explicitSelectionDoesNotMuteTheUsersChosenOutput() throws {
        let f = try Fixture(headphoneSelected: true)
        defer { f.close() }
        f.model.selectOutput(1)
        #expect(f.model.outputRouting.confirmed?.output.uid == "speaker")
        #expect(f.hardware.muteWrites.isEmpty)
    }

    @Test func externalSystemPickerSelectionDoesNotTriggerUnexpectedOutputProtection() throws {
        let f = try Fixture(headphoneSelected: true, userSelecting: true)
        defer { f.close() }
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        #expect(f.hardware.muteWrites.isEmpty)
        #expect(f.model.outputRouting.confirmed?.output.uid == "speaker")
    }

    @Test func anOpenSystemPickerCannotExemptARealDeviceDisconnection() throws {
        let f = try Fixture(headphoneSelected: true, userSelecting: true)
        defer { f.close() }
        f.hardware.outputs.removeAll { $0.id == 2 }
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        #expect(f.hardware.mutedIDs == [1])
    }

    @Test func anOpenSystemPickerCannotExemptTheLossOfAllSelectedGroupMembers() throws {
        let f = try Fixture(userSelecting: true)
        defer { f.close() }
        #expect(f.model.startSimultaneousOutput(["headphone", "usb"]))
        f.hardware.offline.formUnion([2, 3])
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        #expect(f.model.outputRouting.phase == .awaitingMembers)
        #expect(f.model.outputRouting.configured?.memberUIDs == ["headphone", "usb"])
        #expect(f.hardware.mutedIDs == [1])
    }

    @Test func groupCollapsingToItsRemainingMemberContinuesWithoutMuting() throws {
        let f = try Fixture()
        defer { f.close() }
        #expect(f.model.startSimultaneousOutput(["headphone", "usb"]))
        f.model.setApplicationGain(0.45, for: f.id)
        let session = try #require(f.model.sessions[f.id] as? MemoryAudioSession)
        f.hardware.offline.insert(2); f.hardware.inactive.insert("headphone")
        f.model.refresh()
        #expect(session.isActive && session.playbackUIDs == ["usb"])
        #expect(f.hardware.muteWrites.isEmpty)
        #expect(f.model.outputRouting.configured?.memberUIDs == ["headphone", "usb"])
        #expect(f.model.mixStates[f.id]?.failure == nil)
        #expect(session.gain == 0.45 && session.stopCount == 0)
    }

    @Test func losingAllGroupMembersMutesOnlyTheOutOfGroupSuccessorOnce() throws {
        let f = try Fixture()
        defer { f.close() }
        #expect(f.model.startSimultaneousOutput(["headphone", "usb"]))
        f.model.setApplicationGain(0.4, for: f.id)
        let session = try #require(f.model.sessions[f.id] as? MemoryAudioSession)
        f.hardware.offline.formUnion([2, 3])
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        #expect(f.model.outputRouting.phase == .awaitingMembers)
        #expect(f.hardware.mutedIDs == [1])
        #expect(session.isSuspendedForOutputChange && !session.isActive)
        #expect(session.stopCount == 0)
        #expect(f.model.mixStates[f.id]?.failure == nil)
        for _ in 0..<3 { f.model.refresh() }
        #expect(f.hardware.muteWrites.count == 1)
        f.hardware.offline.remove(3)
        for _ in 0..<3 {
            f.audio.now = f.audio.now.addingTimeInterval(0.6)
            f.model.refresh()
        }
        #expect(session.isActive && session.playbackUIDs == ["usb"])
        #expect(f.hardware.mutedIDs == [1])
        #expect(f.hardware.muteWrites.count == 1)
    }

    @Test func temporaryOutOfGroupSuccessorIsMutedButTheRemainingSelectedMemberStillPlays() throws {
        let f = try Fixture()
        defer { f.close() }
        #expect(f.model.startSimultaneousOutput(["headphone", "usb"]))
        f.model.setApplicationGain(0.4, for: f.id)
        let session = try #require(f.model.sessions[f.id] as? MemoryAudioSession)
        f.hardware.offline.insert(2); f.hardware.inactive.insert("headphone")
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        #expect(f.hardware.mutedIDs == [1])
        #expect(session.isActive && session.playbackUIDs == ["usb"])
        #expect(f.model.outputRouting.confirmed?.output.uid == "usb")
        #expect(f.model.mixStates[f.id]?.failure == nil)
    }

    @Test func groupWithTwoRemainingMembersDoesNotMuteEitherOfThem() throws {
        let f = try Fixture()
        defer { f.close() }
        #expect(f.model.startSimultaneousOutput(["speaker", "headphone", "usb"]))
        f.model.setApplicationGain(0.4, for: f.id)
        let session = try #require(f.model.sessions[f.id] as? MemoryAudioSession)
        f.hardware.offline.insert(2); f.hardware.inactive.insert("headphone")
        f.model.refresh()
        #expect(session.isActive && session.playbackUIDs == ["speaker", "usb"])
        #expect(f.hardware.muteWrites.isEmpty)
    }

    @Test func aSecondDistinctSuccessorGetsItsOwnMuteWithoutTouchingOtherDevices() throws {
        let f = try Fixture()
        defer { f.close() }
        #expect(f.model.startSimultaneousOutput(["headphone"]))
        f.hardware.offline.insert(2)
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        #expect(f.hardware.mutedIDs == [1])
        f.hardware.selected = 3; f.hardware.systemSelected = 3
        f.model.refresh()
        #expect(f.hardware.mutedIDs == [1, 3])
        #expect(f.hardware.muteWrites.map { $0.1 } == [1, 3])
        // 用户取消 USB 的设备静音后，同一等待状态的轮询不能再次擅自静音它。
        let usb = try #require(f.model.audio?.outputs.first { $0.id == 3 })
        f.model.setOutputMuted(false, on: usb)
        f.model.refresh()
        #expect(f.hardware.mutedIDs == [1])
        #expect(f.hardware.muteWrites.count == 3)
        #expect(f.hardware.muteWrites.last?.0 == false && f.hardware.muteWrites.last?.1 == 3)
    }

    @Test func failedDeviceMuteDoesNotConfirmTheNewOutputOrReleaseTheTap() throws {
        let f = try Fixture(headphoneSelected: true)
        defer { f.close() }
        f.model.setApplicationGain(0.3, for: f.id)
        let session = try #require(f.model.sessions[f.id] as? MemoryAudioSession)
        f.hardware.outputs.removeAll { $0.id == 2 }
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.hardware.failMute = true
        f.model.refresh()
        #expect(f.model.outputRouting.phase == .failed)
        #expect(f.model.outputRouting.confirmed == nil)
        #expect(f.hardware.mutedIDs.isEmpty)
        #expect(!session.isActive && session.isSuspendedForOutputChange)
        #expect(session.stopCount == 0)
        f.hardware.failMute = false
    }

    @Test func delayedMuteReadbackWaitsWithoutErrorOrRepeatedWrites() throws {
        let f = try Fixture(headphoneSelected: true)
        defer { f.close() }
        f.model.setApplicationGain(0.4, for: f.id)
        let session = try #require(f.model.sessions[f.id] as? MemoryAudioSession)
        f.hardware.deferMute = true
        f.hardware.outputs.removeAll { $0.id == 2 }
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        #expect(f.model.outputRouting.phase == .awaitingHAL && f.model.outputRouting.error == nil)
        #expect(session.isSuspendedForOutputChange && !session.isActive)
        for _ in 0..<4 { f.model.refresh() }
        #expect(f.hardware.muteWrites.count == 1)
        #expect(f.model.mixStates[f.id]?.failure == nil)
        f.hardware.commitMute(on: 1)
        f.model.refresh()
        #expect(f.model.outputRouting.phase == .stable && f.model.outputRouting.error == nil)
        #expect(f.model.outputRouting.confirmed?.output.uid == "speaker")
        #expect(f.hardware.muteWrites.count == 1 && f.hardware.mutedIDs == [1])
        #expect(session.isActive && session.gain == 0.4 && session.stopCount == 0)
    }

    @Test func unconfirmedHeadphoneMuteCannotPoisonReturnToTheOriginalSpeaker() throws {
        let f = try Fixture()
        defer { f.close() }
        f.hardware.deferMute = true
        f.hardware.selected = 2; f.hardware.systemSelected = 2
        f.model.refresh()
        #expect(f.model.outputRouting.phase == .awaitingHAL)
        // 与报告中的后半段一致：报错目标是耳机，而当前媒体输出后来回到原来的扬声器。
        f.hardware.outputs.removeAll { $0.id == 2 }
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.audio.now = f.audio.now.addingTimeInterval(120)
        f.model.refresh()
        #expect(f.model.outputRouting.error == nil && f.model.outputRouting.phase != .failed)
        #expect(f.model.outputRouting.confirmed?.output.uid == "speaker")
        #expect(f.hardware.muteWrites.map { $0.1 } == [2])
    }

    @Test func persistentMuteMismatchHasAFixedDeadlineAndKeepsTheTapPaused() throws {
        let f = try Fixture(headphoneSelected: true)
        defer { f.close() }
        f.model.setApplicationGain(0.4, for: f.id)
        let session = try #require(f.model.sessions[f.id] as? MemoryAudioSession)
        f.hardware.deferMute = true
        f.hardware.outputs.removeAll { $0.id == 2 }
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        f.audio.now = f.audio.now.addingTimeInterval(2.9)
        f.model.refresh()
        #expect(f.model.outputRouting.error == nil)
        f.audio.now = f.audio.now.addingTimeInterval(0.2)
        f.model.refresh()
        #expect(f.model.outputRouting.phase == .failed)
        #expect(f.model.outputRouting.error?.contains("期限") == true)
        #expect(session.isSuspendedForOutputChange && session.stopCount == 0)
        #expect(f.hardware.muteWrites.count == 1)
        f.hardware.commitMute(on: 1)
        f.model.refresh()
        #expect(f.model.outputRouting.phase == .failed)
    }

    @Test func anotherDevicesMuteCannotConfirmThePendingTarget() throws {
        let f = try Fixture(headphoneSelected: true)
        defer { f.close() }
        f.hardware.deferMute = true
        f.hardware.outputs.removeAll { $0.id == 2 }
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        f.hardware.mutedIDs.insert(3)
        f.model.refresh()
        #expect(f.model.outputRouting.phase == .awaitingHAL && f.model.outputRouting.error == nil)
        f.hardware.commitMute(on: 1)
        f.model.refresh()
        #expect(f.model.outputRouting.confirmed?.output.uid == "speaker")
    }

    @Test func explicitSelectionSupersedesPendingAutomaticMuteWithoutUnmutingDevices() throws {
        let f = try Fixture(headphoneSelected: true)
        defer { f.close() }
        f.hardware.deferMute = true
        f.hardware.outputs.removeAll { $0.id == 2 }
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        f.model.selectOutput(3)
        #expect(f.model.outputRouting.confirmed?.output.uid == "usb")
        #expect(f.model.outputRouting.error == nil && !f.model.outputRouting.phase.isBusy)
        #expect(f.hardware.muteWrites.count == 1 && f.hardware.muteWrites.first?.0 == true)
    }

    @Test func aReplacementHandleRequiresItsOwnMuteConfirmation() throws {
        let f = try Fixture(headphoneSelected: true)
        defer { f.close() }
        f.hardware.deferMute = true
        f.hardware.outputs.removeAll { $0.id == 2 }
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        f.hardware.outputs.removeAll { $0.id == 1 }
        f.hardware.outputs.append(AudioOutput(id: 4, uid: "speaker", name: "扬声器新句柄", transport: kAudioDeviceTransportTypeBuiltIn))
        f.hardware.selected = 4; f.hardware.systemSelected = 4
        f.model.refresh()
        #expect(f.hardware.muteWrites.map { $0.1 } == [1, 4])
        f.hardware.commitMute(on: 1)
        f.model.refresh()
        #expect(f.model.outputRouting.phase == .awaitingHAL)
        f.hardware.commitMute(on: 4)
        f.model.refresh()
        #expect(f.model.outputRouting.confirmed?.output.id == 4 && f.model.outputRouting.error == nil)
    }

    @Test func delayedProtectionOfAnOutsiderPreservesTheUnavailableGroupSelection() throws {
        let f = try Fixture()
        defer { f.close() }
        #expect(f.model.startSimultaneousOutput(["headphone", "usb"]))
        f.hardware.deferMute = true
        f.hardware.offline.formUnion([2, 3])
        f.hardware.selected = 1; f.hardware.systemSelected = 1
        f.model.refresh()
        #expect(f.model.outputRouting.phase == .awaitingHAL)
        f.hardware.commitMute(on: 1)
        f.model.refresh()
        #expect(f.model.outputRouting.phase == .awaitingMembers && f.model.outputRouting.error == nil)
        #expect(f.model.outputRouting.configured?.memberUIDs == ["headphone", "usb"])
        #expect(f.hardware.muteWrites.count == 1)
    }

    @Test func recoveredProcessReadResumesTheSameTapAndPreservesSettings() throws {
        let f = try Fixture()
        defer { f.close() }
        f.model.setApplicationGain(0.37, for: f.id)
        f.model.toggleApplicationMute(f.id)
        let effect = AppAudioEffectSettings(enabled: true, preset: .voice)
        f.model.setApplicationAudioEffect(effect, for: f.id)
        let session = try #require(f.model.sessions[f.id] as? MemoryAudioSession)
        f.unknownPropertyRead()
        #expect(f.model.mixStates[f.id]?.failure != nil)
        #expect(!session.isActive && session.isSuspendedForOutputChange)
        f.audio.now = f.audio.now.addingTimeInterval(2.1)
        f.audio.readError = nil
        f.model.refresh()
        #expect(f.model.processError == nil && f.model.mixStates[f.id]?.failure == nil)
        #expect(f.model.sessions[f.id] === session)
        #expect(session.isActive && session.gain == 0.37 && session.muted && session.effect == effect)
        #expect(session.stopCount == 0)
        #expect(f.hardware.muteWrites.isEmpty)
    }

    @Test func repeatedReadFailuresRetainRecoveryQualificationUntilAnActualSuccessfulRead() throws {
        let f = try Fixture()
        defer { f.close() }
        f.model.setApplicationGain(0.4, for: f.id)
        let session = try #require(f.model.sessions[f.id] as? MemoryAudioSession)
        for _ in 0..<4 { f.unknownPropertyRead(); f.audio.now = f.audio.now.addingTimeInterval(10) }
        #expect(!session.isActive && f.model.mixStates[f.id]?.failure != nil)
        f.audio.readError = nil
        f.model.refresh()
        #expect(f.model.mixStates[f.id]?.failure == nil && session.isActive)
    }

    @Test func processReadDoesNotOverwriteOrClearAnOlderProcessingFailure() throws {
        let f = try Fixture()
        defer { f.close() }
        f.model.setApplicationGain(0.4, for: f.id)
        f.audio.healthError = AudioFailure("注入：真实音频处理失败")
        f.model.refresh()
        let previous = f.model.mixStates[f.id]?.failure
        #expect(previous != nil)
        f.unknownPropertyRead()
        #expect(f.model.mixStates[f.id]?.failure == previous)
        f.audio.healthError = nil; f.audio.readError = nil
        f.model.refresh()
        #expect(f.model.mixStates[f.id]?.failure == previous)
    }

    @Test func aFailedPauseCannotBeAutoClearedByAHealthyProcessRead() throws {
        let f = try Fixture()
        defer { f.close() }
        f.model.setApplicationGain(0.4, for: f.id)
        let session = try #require(f.model.sessions[f.id] as? MemoryAudioSession)
        session.failSuspend = true
        f.unknownPropertyRead()
        #expect(f.model.cleanupErrors[f.id] != nil)
        let failure = f.model.mixStates[f.id]?.failure
        session.failSuspend = false; f.audio.readError = nil
        f.model.refresh()
        #expect(f.model.mixStates[f.id]?.failure == failure)
        #expect(f.model.cleanupErrors[f.id] != nil)
    }

    @Test func aNewNonRecoverableReadFailureRevokesAutomaticRecovery() throws {
        let f = try Fixture()
        defer { f.close() }
        f.model.setApplicationGain(0.4, for: f.id)
        f.unknownPropertyRead()
        f.audio.readError = AudioFailure("注入：未分类的进程读取错误")
        f.model.refresh()
        f.audio.readError = nil
        f.model.refresh()
        #expect(f.model.mixStates[f.id]?.failure?.contains("未分类") == true)
        #expect(f.model.sessions[f.id]?.isActive == false)
    }

    @Test func badObjectProcessReadRecoversOnlyAfterACompleteSuccessfulObservation() throws {
        let f = try Fixture()
        defer { f.close() }
        f.model.setApplicationGain(0.4, for: f.id)
        let session = try #require(f.model.sessions[f.id] as? MemoryAudioSession)
        f.audio.readError = AudioFailure("读取音频属性失败", status: HAL.badObjectStatus)
        f.model.refresh()
        #expect(!session.isActive)
        f.audio.readError = nil
        f.model.refresh()
        #expect(session.isActive && f.model.mixStates[f.id]?.failure == nil)
    }

    @Test func replacingAProcessDoesNotAutomaticallyRecoverTheOldFailure() throws {
        let f = try Fixture()
        defer { f.close() }
        f.model.setApplicationGain(0.4, for: f.id)
        f.unknownPropertyRead()
        f.audio.objectIDs = [142]; f.audio.readError = nil
        f.model.refresh()
        #expect(f.model.mixStates[f.id]?.failure != nil)
        #expect(f.model.sessions[f.id]?.isActive == false)
    }

    @Test func changingTheOutputRevokesTheEarlierReadRecoveryQualification() throws {
        let f = try Fixture()
        defer { f.close() }
        f.model.setApplicationGain(0.4, for: f.id)
        f.unknownPropertyRead()
        f.model.selectOutput(2)
        f.audio.readError = nil
        f.model.refresh()
        #expect(f.model.mixStates[f.id]?.failure != nil)
        #expect(f.model.sessions[f.id]?.isActive == false)
    }

    @Test func missingCustomTargetStillCannotResumeAfterProcessReadRecovery() throws {
        let f = try Fixture()
        defer { f.close() }
        #expect(f.model.startSimultaneousOutput(["speaker", "headphone"]))
        f.model.setApplicationAudioRoute(.custom(deviceUIDs: ["headphone"]), for: f.id)
        f.model.setApplicationGain(0.4, for: f.id)
        f.unknownPropertyRead()
        f.hardware.offline.insert(2); f.hardware.inactive.insert("headphone")
        f.audio.readError = nil
        f.model.refresh()
        #expect(f.model.sessions[f.id]?.isActive == false)
        #expect(f.model.effectiveApplicationAudioRoute(for: f.id).isWaitingForDevices)
        #expect(f.hardware.muteWrites.isEmpty)
    }
}
