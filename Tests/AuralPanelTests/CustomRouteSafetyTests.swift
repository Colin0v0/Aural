import AppKit
import CoreAudio
import SwiftUI
import Foundation
import Testing
@testable import Aural
@testable import AuralCore

@MainActor
struct CustomRouteSafetyTests {
    @Test func losingTheOnlyCustomTargetPausesInsteadOfPlayingOnSpeakers() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let model = fixture.model, hardware = fixture.hardware, audio = fixture.audio
        #expect(model.startSimultaneousOutput(["speaker", "headphone", "usb"]))
        model.setApplicationGain(0.4, for: fixture.id)
        model.toggleApplicationMute(fixture.id)
        model.setApplicationAudioRoute(.custom(deviceUIDs: ["headphone"]), for: fixture.id)
        model.setApplicationEffectsEnabled(true)
        let effect = AppAudioEffectSettings(enabled: true, preset: .voice)
        model.setApplicationAudioEffect(effect, for: fixture.id)
        let session = try #require(model.sessions[fixture.id] as? MemoryAudioSession)
        #expect(session.playbackHistory.last == ["headphone"])
        let customHistoryOffset = session.playbackHistory.count
        model.levelSource(for: fixture.id).update(0.8)
        hardware.offline.insert(2)
        hardware.inactive.insert("headphone")
        model.refresh()
        #expect(model.applicationAudioRoute(for: fixture.id) == .custom(deviceUIDs: ["headphone"]))
        #expect(model.effectiveApplicationAudioRoute(for: fixture.id) != .allOutputs)
        #expect(!session.isActive)
        #expect(model.applicationRoutePlaybackPaused(for: fixture.id))
        let diagnostic = try #require(model.makeDiagnosticReport().applications.first { $0.id == fixture.id })
        #expect(diagnostic.route.effective == "waitingForDevices")
        #expect(diagnostic.route.effectiveDeviceUIDs.isEmpty)
        #expect(session.isSuspendedForOutputChange)
        #expect(!session.isReleased)
        #expect(session.stopCount == 0)
        #expect(model.levelSource(for: fixture.id).level == nil)
        #expect(model.mixStates[fixture.id]?.failure == nil)
        #expect(model.operationError == nil && model.outputRouting.error == nil)
        #expect(model.sessions[fixture.id] === session)

        hardware.offline.remove(2)
        hardware.inactive.remove("headphone")
        for _ in 0..<3 {
            audio.now = audio.now.addingTimeInterval(0.6)
            model.refresh()
        }
        #expect(model.sessions[fixture.id] === session)
        #expect(session.isActive)
        #expect(session.playbackUIDs == ["headphone"])
        #expect(session.gain == 0.4 && session.muted)
        #expect(session.effect == effect)
        #expect(session.playbackHistory.dropFirst(customHistoryOffset).allSatisfy { $0 == ["headphone"] })
        #expect(session.stopCount == 0)
    }

    @Test func collapsingToASingleRemainingSpeakerStillKeepsTheCustomTapMuted() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        #expect(fixture.model.startSimultaneousOutput(["speaker", "headphone"]))
        fixture.model.setApplicationAudioRoute(.custom(deviceUIDs: ["headphone"]), for: fixture.id)
        let session = try #require(fixture.model.sessions[fixture.id] as? MemoryAudioSession)
        fixture.hardware.offline.insert(2)
        fixture.hardware.inactive.insert("headphone")
        fixture.model.refresh()
        #expect(!session.isActive && session.isSuspendedForOutputChange)
        #expect(session.stopCount == 0)
        #expect(fixture.model.applicationAudioRoute(for: fixture.id) == .custom(deviceUIDs: ["headphone"]))
        #expect(fixture.model.effectiveApplicationAudioRoute(for: fixture.id) != .allOutputs)
    }

    @Test func removingATargetDoesNotRewriteSavedIntentAndReaddingItResumes() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        #expect(fixture.model.startSimultaneousOutput(["speaker", "headphone", "usb"]))
        fixture.model.setApplicationAudioRoute(.custom(deviceUIDs: ["headphone"]), for: fixture.id)
        let session = try #require(fixture.model.sessions[fixture.id] as? MemoryAudioSession)
        let saved = fixture.defaults.data(forKey: "local.aural.settings.appAudioRoutes")
        #expect(fixture.model.updateSimultaneousOutput(["speaker", "usb"]))
        #expect(!session.isActive && session.isSuspendedForOutputChange)
        #expect(fixture.model.applicationAudioRoute(for: fixture.id) == .custom(deviceUIDs: ["headphone"]))
        #expect(fixture.defaults.data(forKey: "local.aural.settings.appAudioRoutes") == saved)
        #expect(session.stopCount == 0)
        #expect(fixture.model.updateSimultaneousOutput(["speaker", "headphone", "usb"]))
        #expect(fixture.model.sessions[fixture.id] === session)
        #expect(session.isActive && session.playbackUIDs == ["headphone"])
        #expect(session.stopCount == 0)
    }

    @Test func partialCustomAvailabilityNeverAddsAnUnselectedSpeaker() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        #expect(fixture.model.startSimultaneousOutput(["speaker", "headphone", "usb"]))
        fixture.model.setApplicationAudioRoute(.custom(deviceUIDs: ["headphone", "usb"]), for: fixture.id)
        let session = try #require(fixture.model.sessions[fixture.id] as? MemoryAudioSession)
        fixture.hardware.offline.insert(2)
        fixture.hardware.inactive.insert("headphone")
        fixture.model.refresh()
        #expect(session.isActive && session.playbackUIDs == ["usb"])
        #expect(fixture.model.applicationAudioRoute(for: fixture.id) == .custom(deviceUIDs: ["headphone", "usb"]))
    }

    @Test func aSavedUnavailableRouteStartsMutedWithoutStartingPlayback() throws {
        let fixture = try Fixture(savedRoute: .custom(deviceUIDs: ["headphone"]))
        defer { fixture.close() }
        let session = try #require(fixture.model.sessions[fixture.id] as? MemoryAudioSession)
        #expect(!session.isActive && session.isSuspendedForOutputChange)
        #expect(!session.isReleased)
        #expect(fixture.model.mixStates[fixture.id]?.failure == nil)
        #expect(fixture.hardware.selections.isEmpty)
        // 用户明确选“全部输出”才解除这次等待，不需要为取消自定义路由先重建输出组。
        fixture.model.setApplicationAudioRoute(.allOutputs, for: fixture.id)
        #expect(fixture.model.applicationAudioRoute(for: fixture.id) == .allOutputs)
        #expect(fixture.model.operationError == nil)
    }

    @Test func explicitAllOutputsIsTheOnlyActionThatMayExpandThePausedRoute() throws {
        let fixture = try Fixture(savedRoute: .custom(deviceUIDs: ["headphone"]))
        defer { fixture.close() }
        fixture.model.setApplicationGain(0.4, for: fixture.id)
        fixture.model.toggleApplicationMute(fixture.id)
        let session = try #require(fixture.model.sessions[fixture.id] as? MemoryAudioSession)
        for _ in 0..<4 { fixture.model.refresh() }
        #expect(session.startSuspendedCount == 1)
        #expect(session.playbackHistory.isEmpty)
        fixture.model.setApplicationAudioRoute(.allOutputs, for: fixture.id)
        #expect(fixture.model.sessions[fixture.id] === session)
        #expect(session.isActive)
        #expect(session.playbackHistory == [["speaker"]])
        #expect(session.gain == 0.4 && session.muted)
        #expect(session.stopCount == 0)
    }

    @Test func waitingDoesNotPauseOtherAppsThatExplicitlyUseAllOutputs() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let id = "bundle:test.browser"
        let group = AudioProcessGroup(id: id, bundleID: "test.browser", processIDs: [43], objectIDs: [43])
        fixture.audio.additionalRows = [ApplicationAudioRow(id: id, bundleID: "test.browser", name: "Chrome",
            applicationURL: nil, group: group, isRunningOutput: true)]
        fixture.model.refresh()
        #expect(fixture.model.startSimultaneousOutput(["speaker", "headphone", "usb"]))
        fixture.model.setApplicationAudioRoute(.custom(deviceUIDs: ["headphone"]), for: fixture.id)
        fixture.model.setApplicationGain(0.6, for: id)
        let music = try #require(fixture.model.sessions[fixture.id] as? MemoryAudioSession)
        let browser = try #require(fixture.model.sessions[id] as? MemoryAudioSession)
        fixture.hardware.offline.insert(2)
        fixture.hardware.inactive.insert("headphone")
        fixture.model.refresh()
        #expect(!music.isActive && music.isSuspendedForOutputChange)
        #expect(browser.isActive)
        #expect(browser.playbackUIDs == ["speaker", "usb"])
        #expect(browser.gain == 0.6)
        #expect(music.stopCount == 0 && browser.stopCount == 0)
    }

    @Test func pauseFailureIsReportedInsteadOfPretendingPlaybackStopped() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        #expect(fixture.model.startSimultaneousOutput(["speaker", "headphone"]))
        fixture.model.setApplicationAudioRoute(.custom(deviceUIDs: ["headphone"]), for: fixture.id)
        let session = try #require(fixture.model.sessions[fixture.id] as? MemoryAudioSession)
        session.failSuspend = true
        fixture.hardware.offline.insert(2)
        fixture.model.refresh()
        #expect(fixture.model.cleanupErrors[fixture.id] != nil)
        #expect(!fixture.model.applicationRoutePlaybackPaused(for: fixture.id))
        #expect(fixture.model.mixStates[fixture.id]?.failure != nil)
        #expect(session.stopCount == 0)
        session.failSuspend = false
    }

    @Test func newAudioProcessesJoinTheSameMutedTapWhileTheTargetIsUnavailable() throws {
        let fixture = try Fixture(savedRoute: .custom(deviceUIDs: ["headphone"]))
        defer { fixture.close() }
        let session = try #require(fixture.model.sessions[fixture.id] as? MemoryAudioSession)
        fixture.audio.objectIDs = [42, 142]
        fixture.model.refresh()
        #expect(fixture.model.sessions[fixture.id] === session)
        #expect(session.group.objectIDs == [42, 142])
        #expect(session.updateProcessesCount == 1)
        #expect(session.startSuspendedCount == 1)
        #expect(session.playbackHistory.isEmpty)
        #expect(session.stopCount == 0)
        #expect(fixture.model.startSimultaneousOutput(["speaker", "headphone"]))
        #expect(fixture.model.sessions[fixture.id] === session)
        #expect(session.isActive && session.playbackUIDs == ["headphone"])
        #expect(session.stopCount == 0)
    }

    @MainActor private final class Fixture {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let suite = "Aural.CustomRouteSafety.\(UUID().uuidString)"
        let defaults: UserDefaults
        let model: AppModel
        var id: String { audio.row.id }

        init(savedRoute: AppAudioRoute? = nil) throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            let store = AppAudioRouteStore(defaults: defaults)
            if let savedRoute { try store.save([audio.row.id: savedRoute]) }
            model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment, appAudioRouteStore: store,
                             appAudioEffectStore: AppAudioEffectStore(defaults: defaults))
        }
        func close() {
            #expect(model.shutdown())
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

@MainActor
struct CustomRoutePresentationTests {
    @Test func pausedRouteUsesANeutralControlAndKeepsTheSavedSelectionInItsMenu() throws {
        let app = ApplicationAudioRow(id: "bundle:test.music", bundleID: "test.music", name: "Music",
                                       applicationURL: nil, group: nil, isRunningOutput: true)
        let row = ApplicationMixerRow(app: app, state: ApplicationMixState(),
            levelSource: ApplicationLevelSource(), metersVisible: false, awaitingStream: false,
            status: "所选输出不可用，已暂停播放", toggleMute: {}, setGain: { _ in }, retryMeter: {},
            applyConfiguration: {}, stopManaging: {}, routingEnabled: false,
            audioRoute: .custom(deviceUIDs: ["headphone"]), routePaused: true)
            .font(PanelStyle.bodyFont).frame(width: PanelMetrics.width)
            .environment(\.appLanguage, .english).background(PanelStyle.canvas)
        let host = NSHostingView(rootView: row)
        host.frame.size = host.fittingSize
        PanelTestSupport.flushLayout(host)
        func controls(_ view: NSView) -> [PanelActionControl] {
            (view as? PanelActionControl).map { [$0] } ?? view.subviews.flatMap(controls)
        }
        let pause = try #require(controls(host).first {
            $0.toolTip == "Selected output unavailable. Playback paused."
        })
        #expect(pause.idleTint == NSColor(PanelStyle.secondary))
        let menu = try #require(pause.makeMenu?())
        #expect(menu.items.first?.state == .off)
        #expect(menu.items.first?.isEnabled == true)
        #expect(menu.items.last?.state == .on)
        #expect(menu.items.last?.isEnabled == false)
        #expect(menu.items.last?.title.contains("unavailable") == true)
        #expect(host.fittingSize.height <= 46)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/aural-route-paused-row.png"))
    }
}
