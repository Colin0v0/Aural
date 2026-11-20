import Foundation
import CoreAudio
import Testing
@testable import Auxmo
@testable import AuxmoCore

@MainActor
struct ConfigurationOwnershipTests {
    @MainActor private final class Fixture {
        let suite = "Auxmo.ConfigurationOwnership.\(UUID().uuidString)"
        let defaults: UserDefaults
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        init() throws { defaults = try #require(UserDefaults(suiteName: suite)) }
        var store: AppAudioEffectStore { AppAudioEffectStore(defaults: defaults) }
        func model() -> AppModel {
            AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment,
                appAudioRouteStore: AppAudioRouteStore(defaults: defaults), appAudioEffectStore: store, appAudioEffectsEnabled: true)
        }
        func close() { defaults.removePersistentDomain(forName: suite) }
    }

    @Test func wrongTypedEffectsAndPresetsAreNotFirstUseDefaults() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        for malformed: Any in ["bad", 12, true, ["bad": "record"]] {
            fixture.defaults.set(malformed, forKey: "com.colin0v0.auxmo.settings.appAudioEffects")
            fixture.defaults.set(malformed, forKey: "com.colin0v0.auxmo.settings.appAudioEffectPresets")
            #expect(throws: AppAudioEffectStoreError.self) { try fixture.store.load() }
            #expect(throws: AppAudioEffectStoreError.self) { try fixture.store.loadPresets() }
        }
    }

    @Test func corruptEffectsCannotBeOverwrittenButDoNotBlockGainOrMute() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let corrupt = Data("{".utf8)
        fixture.defaults.set(corrupt, forKey: "com.colin0v0.auxmo.settings.appAudioEffects")
        let model = fixture.model(); defer { #expect(model.shutdown()) }
        model.setApplicationAudioEffect(AppAudioEffectSettings(enabled: true), for: fixture.audio.row.id)
        model.setApplicationGain(0.2, for: fixture.audio.row.id)
        model.applyApplication(fixture.audio.row.id)
        let session = try #require(model.sessions[fixture.audio.row.id] as? MemoryAudioSession)
        model.toggleApplicationMute(fixture.audio.row.id)
        #expect(!model.applicationEffectConfigurationAvailable && session.isActive)
        #expect(session.gain == 0.2 && session.muted && session.effect == nil)
        #expect(fixture.defaults.data(forKey: "com.colin0v0.auxmo.settings.appAudioEffects") == corrupt)
    }

    @Test func unknownPresetLibraryBlocksAllPresetWritesButDoesNotClearKnownEffects() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let corrupt = Data("{".utf8)
        fixture.defaults.set(corrupt, forKey: "com.colin0v0.auxmo.settings.appAudioEffectPresets")
        let model = fixture.model(); defer { #expect(model.shutdown()) }
        #expect(model.createApplicationAudioEffectPreset(named: "New", eq: .flat) == nil)
        model.renameApplicationAudioEffectPreset(UUID(), to: "Renamed")
        model.deleteApplicationAudioEffectPreset(UUID())
        #expect(model.duplicateApplicationAudioEffectPreset(UUID()) == nil)
        model.setApplicationAudioEffect(AppAudioEffectSettings(enabled: true), for: fixture.audio.row.id)
        #expect(model.applicationEffectConfigurationAvailable && !model.applicationEffectPresetsAvailable)
        #expect(model.appAudioEffectPersistenceError != nil)
        #expect(fixture.defaults.data(forKey: "com.colin0v0.auxmo.settings.appAudioEffectPresets") == corrupt)
    }

    @Test func validPresetEditDoesNotClearEffectReadFailureOrUnrelatedOperationError() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.defaults.set(Data("{".utf8), forKey: "com.colin0v0.auxmo.settings.appAudioEffects")
        let model = fixture.model(); defer { #expect(model.shutdown()) }
        model.operationError = "输出写入失败"
        #expect(model.createApplicationAudioEffectPreset(named: "Valid", eq: .flat) != nil)
        #expect(model.appAudioEffectPersistenceError != nil && !model.applicationEffectConfigurationAvailable)
        #expect(model.operationError == "输出写入失败")
    }

    @Test func explicitReloadRetainsTapAndDoesNotClearAudioProcessingFailure() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let model = fixture.model(); defer { #expect(model.shutdown()) }
        let id = fixture.audio.row.id
        model.setApplicationGain(0.3, for: id)
        let session = try #require(model.sessions[id] as? MemoryAudioSession)
        fixture.defaults.set(Data("{".utf8), forKey: "com.colin0v0.auxmo.settings.appAudioEffects")
        model.reloadApplicationAudioEffects()
        #expect(session.isActive && session.effect == nil && session.gain == 0.3 && session.stopCount == 0)
        try fixture.store.save([id: AppAudioEffectSettings(enabled: true)])
        model.reloadApplicationAudioEffects()
        #expect(model.sessions[id] === session && session.isActive && session.gain == 0.3)
        fixture.audio.healthError = AudioFailure("真实音频故障")
        model.refresh()
        let failure = try #require(model.mixStates[id]?.failure)
        fixture.audio.healthError = nil
        model.reloadApplicationAudioEffects()
        #expect(model.mixStates[id]?.failure == failure && !session.isActive)
    }

    @Test func invalidNewBatteryRecordNeverReadsOrMigratesTheOldKey() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let key = "com.colin0v0.auxmo.settings.menuBarBatterySource"
        fixture.defaults.set(true, forKey: "com.colin0v0.auxmo.settings.showCurrentDeviceBattery")
        for malformed: Any in ["unknown", 1, ["wrong": true]] {
            fixture.defaults.set(malformed, forKey: key)
            let settings = AppSettings(defaults: fixture.defaults)
            #expect(settings.menuBarBatterySource == nil && settings.readErrors[key] != nil)
            #expect(!(fixture.defaults.object(forKey: key) as? String == "currentOutput"))
        }
    }

    @Test func invalidSettingsStayUnselectedAndExplicitChoiceClearsOnlyThatKey() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.defaults.set("wrong", forKey: "com.colin0v0.auxmo.settings.language")
        fixture.defaults.set("wrong", forKey: "com.colin0v0.auxmo.settings.appearance")
        fixture.defaults.set(1, forKey: "com.colin0v0.auxmo.settings.showHeadphones")
        let settings = AppSettings(defaults: fixture.defaults)
        #expect(settings.language == nil && settings.appearance == nil && settings.showHeadphoneControls == nil)
        #expect(settings.readErrors.count == 3)
        settings.language = .english
        #expect(settings.readErrors.count == 2 && settings.appearance == nil)
        #expect(fixture.defaults.string(forKey: "com.colin0v0.auxmo.settings.appearance") == "wrong")
        settings.showHeadphoneControls = false
        #expect(settings.readErrors.count == 1)
    }

    @Test func invalidLegacyBatteryRecordIsNotMigrated() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.defaults.set("true", forKey: "com.colin0v0.auxmo.settings.showCurrentDeviceBattery")
        let settings = AppSettings(defaults: fixture.defaults)
        #expect(settings.menuBarBatterySource == nil && !settings.readErrors.isEmpty)
        #expect(fixture.defaults.object(forKey: "com.colin0v0.auxmo.settings.menuBarBatterySource") == nil)
    }

    @Test func effectReloadRevokesOldProcessReadRecoveryCredentials() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let model = fixture.model(); defer { #expect(model.shutdown()) }
        let id = fixture.audio.row.id
        model.setApplicationGain(0.3, for: id)
        let session = try #require(model.sessions[id] as? MemoryAudioSession)
        fixture.audio.readError = AudioFailure("临时进程读取失败", status: kAudioHardwareUnknownPropertyError)
        model.refresh()
        let failure = try #require(model.mixStates[id]?.failure)
        fixture.defaults.set(Data("{".utf8), forKey: "com.colin0v0.auxmo.settings.appAudioEffects")
        fixture.audio.readError = nil
        model.reloadApplicationAudioEffects()
        #expect(!session.isActive && session.isSuspendedForOutputChange)
        try fixture.store.save([:])
        model.reloadApplicationAudioEffects()
        #expect(model.mixStates[id]?.failure == failure && !session.isActive)
        // 只有用户明确重试才能在新的配置读取结果上重新确认处理资格。
        model.applyApplication(id)
        #expect(session.isActive && session.gain == 0.3)
    }

    @Test func independentConfigurationSaveFailureCannotBeClearedByAnotherRecord() {
        struct WriteFailure: LocalizedError { var errorDescription: String? { "磁盘写入失败" } }
        var disk = ["saved": 1]
        var rejectWrite = true
        let first = StoredConfiguration(read: { disk }, write: { next in
            if rejectWrite { throw WriteFailure() }; disk = next
        })
        let second = StoredConfiguration(read: { [String: Int]() }, write: { _ in })
        #expect(!first.save(["new": 2]) && first.value == ["saved": 1])
        #expect(second.save(["other": 3]))
        #expect(first.error == "磁盘写入失败")
        rejectWrite = false
        #expect(first.save(["new": 2]) && first.error == nil && disk == ["new": 2])
    }
    @Test func corruptEffectsKeepTheExplicitCustomRouteAndMutedTap() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        fixture.defaults.set(Data("{".utf8), forKey: "com.colin0v0.auxmo.settings.appAudioEffects")
        try AppAudioRouteStore(defaults: fixture.defaults).save([fixture.audio.row.id: .custom(deviceUIDs: ["headphone"])])
        let model = fixture.model(); defer { #expect(model.shutdown()) }
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        model.setApplicationGain(0.4, for: fixture.audio.row.id)
        model.toggleApplicationMute(fixture.audio.row.id)
        let session = try #require(model.sessions[fixture.audio.row.id] as? MemoryAudioSession)
        #expect(session.isActive && session.gain == 0.4 && session.muted && session.effect == nil)
        #expect(session.playbackHistory.allSatisfy { $0 == ["headphone"] })
        #expect(model.appAudioEffectPersistenceError != nil)
    }

    @Test func effectOnlySessionWaitsWithoutUnmutingUntilExplicitBasicManagementOrDisable() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let model = fixture.model(); defer { #expect(model.shutdown()) }
        let id = fixture.audio.row.id
        model.setApplicationAudioEffect(AppAudioEffectSettings(enabled: true), for: id)
        let session = try #require(model.sessions[id] as? MemoryAudioSession)
        #expect(model.mixStates[id]?.managed == false && session.isActive)
        fixture.defaults.set(Data("{".utf8), forKey: "com.colin0v0.auxmo.settings.appAudioEffects")
        model.reloadApplicationAudioEffects()
        #expect(!session.isActive && session.isSuspendedForOutputChange && session.stopCount == 0)
        model.setApplicationGain(0.4, for: id)
        #expect(model.sessions[id] === session && session.isActive && session.effect == nil && session.stopCount == 0)
        #expect(session.gain == 0.4 && model.appAudioEffectPersistenceError != nil)
    }

    @Test func explicitDisableCanReleaseAnEffectOnlySessionEvenIfEffectDataIsUnreadable() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let model = fixture.model(); defer { #expect(model.shutdown()) }
        model.setApplicationAudioEffect(AppAudioEffectSettings(enabled: true), for: fixture.audio.row.id)
        let session = try #require(model.sessions[fixture.audio.row.id] as? MemoryAudioSession)
        fixture.defaults.set(Data("{".utf8), forKey: "com.colin0v0.auxmo.settings.appAudioEffects")
        model.reloadApplicationAudioEffects()
        model.setApplicationEffectsEnabled(false)
        #expect(model.sessions[fixture.audio.row.id] == nil && session.stopCount == 1)
        #expect(!model.applicationEffectConfigurationAvailable)
    }

    @Test func unreadablePresetsDoNotPreventEditingAllManualEffectParametersOrPreview() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let corrupt = Data("{".utf8)
        fixture.defaults.set(corrupt, forKey: "com.colin0v0.auxmo.settings.appAudioEffectPresets")
        let model = fixture.model(); defer { #expect(model.shutdown()) }
        var settings = AppAudioEffectSettings(enabled: true)
        settings.setGain(2, at: 2)
        settings.spatial = AppAudioSpatialSettings(mode: .hall, intensity: 0.2)
        settings.channel.balance = 0.2
        model.setApplicationAudioEffect(settings, for: fixture.audio.row.id)
        let session = try #require(model.sessions[fixture.audio.row.id] as? MemoryAudioSession)
        #expect(session.effect == settings && session.isActive)
        var preview = settings; preview.setGain(3, at: 3)
        model.previewApplicationAudioEffect(preview, for: fixture.audio.row.id)
        #expect(session.effect == preview)
        #expect(try fixture.store.load()[fixture.audio.row.id] == settings)
        try fixture.store.savePresets([])
        model.reloadApplicationAudioEffectPresets()
        #expect(model.applicationEffectPresetsAvailable && session.effect == preview)
        #expect(model.applicationAudioEffect(for: fixture.audio.row.id) == settings)
    }

    @Test func closingABComparisonCanClearBypassEvenWhileEffectsAreUnreadable() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let model = fixture.model(); defer { #expect(model.shutdown()) }
        let id = fixture.audio.row.id
        model.setApplicationAudioEffect(AppAudioEffectSettings(enabled: true), for: id)
        model.setApplicationAudioEffectBypassed(true, for: id)
        fixture.defaults.set(Data("{".utf8), forKey: "com.colin0v0.auxmo.settings.appAudioEffects")
        model.reloadApplicationAudioEffects()
        model.setApplicationAudioEffectBypassed(false, for: id)
        #expect(!model.isApplicationAudioEffectBypassed(for: id))
        try fixture.store.save([id: AppAudioEffectSettings(enabled: true)])
        model.reloadApplicationAudioEffects()
        #expect(model.effectiveApplicationAudioEffect(for: id)?.enabled == true)
    }

}
