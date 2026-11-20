import Foundation
import Testing
@testable import Aural
@testable import AuralCore

@MainActor
struct RouteConfigurationFailureTests {
    @MainActor private final class Fixture {
        let suite = "Aural.RouteConfigurationFailure.\(UUID().uuidString)"
        let defaults: UserDefaults
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let store: AppAudioRouteStore
        var id: String { audio.row.id }
        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            store = AppAudioRouteStore(defaults: defaults)
        }
        func model() -> AppModel {
            AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                applicationAudio: audio.environment, appAudioRouteStore: store,
                appAudioEffectStore: AppAudioEffectStore(defaults: defaults))
        }
        func close(_ model: AppModel) {
            #expect(model.shutdown())
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @Test func missingConfigurationIsDifferentFromUnreadableConfiguration() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        defer { fixture.close(model) }
        #expect(model.applicationRouteConfigurationAvailable)
        #expect(model.applicationAudioRoute(for: fixture.id) == .allOutputs)
        #expect(model.appAudioRoutePersistenceError == nil)
    }

    @Test func wrongTypedRecordIsRejectedInsteadOfSilentlyBecomingAnEmptyStore() throws {
        let malformed: [Any] = ["invalid", 42, true, ["route": "invalid"]]
        for value in malformed {
            let fixture = try Fixture()
            fixture.defaults.set(value, forKey: "local.aural.settings.appAudioRoutes")
            #expect(throws: AppAudioRouteStoreError.self) { try fixture.store.load() }
            let model = fixture.model()
            defer { fixture.close(model) }
            #expect(!model.applicationRouteConfigurationAvailable)
            #expect(model.applicationAudioRoute(for: fixture.id) == nil)
            #expect(model.effectiveApplicationAudioRoute(for: fixture.id) == .configurationUnavailable)
            #expect(model.appAudioRoutePersistenceError != nil)
            #expect(fixture.audio.sessions.isEmpty)
        }
    }

    @Test func corruptJSONBlocksPlaybackAndCannotBeOverwrittenWithAllOutputs() throws {
        let fixture = try Fixture()
        let corrupt = Data("{".utf8)
        fixture.defaults.set(corrupt, forKey: "local.aural.settings.appAudioRoutes")
        let model = fixture.model()
        defer { fixture.close(model) }
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        model.setApplicationGain(0.5, for: fixture.id)
        model.toggleApplicationMute(fixture.id)
        model.applyApplication(fixture.id)
        model.setApplicationAudioRoute(.allOutputs, for: fixture.id)
        #expect(!model.applicationAudioRoutingEnabled)
        #expect(fixture.audio.sessions.isEmpty)
        #expect(fixture.defaults.data(forKey: "local.aural.settings.appAudioRoutes") == corrupt)
        let report = model.makeDiagnosticReport()
        let row = try #require(report.applications.first { $0.id == fixture.id })
        #expect(row.route.stored == "configurationUnavailable")
        #expect(row.route.resolved == "configurationUnavailable" && row.route.effective == "configurationUnavailable")
    }

    @Test func failedReloadRetainsMutedTapAndSuccessfulReloadResumesOnlyTheSavedTarget() throws {
        let fixture = try Fixture()
        try fixture.store.save([fixture.id: .custom(deviceUIDs: ["headphone"])])
        let model = fixture.model()
        defer { fixture.close(model) }
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        model.setApplicationGain(0.4, for: fixture.id)
        let session = try #require(model.sessions[fixture.id] as? MemoryAudioSession)
        #expect(session.isActive && session.playbackUIDs == ["headphone"])
        fixture.defaults.set(Data("{".utf8), forKey: "local.aural.settings.appAudioRoutes")
        model.reloadApplicationAudioRoutes()
        #expect(!session.isActive && session.isSuspendedForOutputChange && session.stopCount == 0)
        #expect(model.applicationAudioRoute(for: fixture.id) == nil)
        model.applyApplication(fixture.id)
        #expect(!session.isActive)
        try fixture.store.save([fixture.id: .custom(deviceUIDs: ["headphone"])])
        model.reloadApplicationAudioRoutes()
        #expect(model.applicationRouteConfigurationAvailable && model.appAudioRoutePersistenceError == nil)
        #expect(model.sessions[fixture.id] === session && session.isActive)
        #expect(session.gain == 0.4 && session.stopCount == 0)
        #expect(session.playbackHistory.allSatisfy { $0 == ["headphone"] })
    }

    @Test func validReloadDoesNotClearAnEarlierProcessingFailure() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        defer { fixture.close(model) }
        model.setApplicationGain(0.4, for: fixture.id)
        fixture.audio.healthError = AudioFailure("真实处理失败")
        model.refresh()
        let failure = model.mixStates[fixture.id]?.failure
        try #require(failure != nil)
        fixture.defaults.set(Data("{".utf8), forKey: "local.aural.settings.appAudioRoutes")
        model.reloadApplicationAudioRoutes()
        try fixture.store.save([:])
        fixture.audio.healthError = nil
        model.reloadApplicationAudioRoutes()
        #expect(model.mixStates[fixture.id]?.failure == failure)
        #expect(model.sessions[fixture.id]?.isActive == false)
    }

    @Test func stagingCleanupCannotDeleteAnUnrestoredBackup() throws {
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("Aural.BackupGuard.\(UUID().uuidString)")
        defer {
            do { try FileManager.default.removeItem(at: stage) }
            catch { Issue.record("测试清理失败：\(error)") }
        }
        let backup = stage.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let marker = backup.appendingPathComponent("recoverable")
        try Data("old app".utf8).write(to: marker)
        #expect(throws: AuralUpdateError.self) { try AuralUpdateInstaller.removeStaging(at: stage) }
        #expect(try Data(contentsOf: marker) == Data("old app".utf8))
    }
}
