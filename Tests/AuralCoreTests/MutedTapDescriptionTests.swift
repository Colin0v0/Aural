import CoreAudio
import Testing
@testable import AuralCore

@MainActor
struct MutedTapDescriptionTests {
    private let group = AudioProcessGroup(id: "bundle:test.music", bundleID: "test.music",
                                          processIDs: [12], objectIDs: [42])
    private let output = AudioOutput(id: 1, uid: "headphone", name: "耳机",
                                    transport: kAudioDeviceTransportTypeBluetooth)

    @Test func waitingTapIsUnboundAndContinuouslyMutesWithoutAnIOReader() {
        let description = ProcessAudioSession.makeTapDescription(group: group, route: .single(output),
                                                                  mode: .mixing, suspended: true)
        #expect(description.muteBehavior == .muted)
        #expect(description.deviceUID == nil)
        #expect(description.stream == nil)
        #expect(description.isPrivate)
        #expect(description.processes == group.objectIDs)
        #expect(!description.isExclusive)
    }

    @Test func activeMixingAndReadOnlyMeteringKeepDistinctMuteSemantics() {
        let mixing = ProcessAudioSession.makeTapDescription(group: group, route: .single(output),
                                                             mode: .mixing, suspended: false)
        let meter = ProcessAudioSession.makeTapDescription(group: group, route: .single(output),
                                                           mode: .metering, suspended: false)
        #expect(mixing.muteBehavior == .muted)
        #expect(mixing.deviceUID == output.uid)
        #expect(meter.muteBehavior == .unmuted)
    }

    @Test func readOnlyMeterCannotStartAMuteOnlySession() throws {
        let session = ProcessAudioSession(group: group, output: output, mode: .metering)
        // 在访问任何 HAL 对象前拒绝无效模式，不把只读计量悄悄变为混音。
        #expect(throws: AudioFailure.self) { try session.startSuspended() }
        #expect(session.isReleased)
    }
}
