import Foundation
import Testing
@testable import AuxmoCore

struct ApplicationAudioDynamicsTests {
    @Test func oldSettingsMigrateAndNewSettingsRoundTrip() throws {
        var settings = AppAudioEffectSettings(enabled: true)
        settings.dynamics = .strong
        settings.channel = AppAudioChannelSettings(balance: -0.35, mono: true)
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppAudioEffectSettings.self, from: encoded) == settings)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "dynamics")
        object.removeValue(forKey: "channel")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(AppAudioEffectSettings.self, from: legacy)
        #expect(restored.dynamics == .off)
        #expect(restored.channel == .init())
    }

    @Test func stereoMonoAndBalanceSettleWithoutAmplification() {
        var settings = AppAudioEffectSettings(enabled: true)
        settings.channel = AppAudioChannelSettings(balance: 0.5, mono: true)
        var dsp = AppAudioDynamicsDSP(sampleRate: 48_000)
        dsp.beginBuffer(word: AppAudioDynamicsParameterWord.pack(settings))
        var frame: (left: Float, right: Float) = (0, 0)
        for _ in 0..<2000 {
            frame = (0.8, 0.2)
            dsp.process(&frame, channels: 2)
        }
        #expect(abs(frame.left - 0.25) < 0.001)
        #expect(abs(frame.right - 0.5) < 0.001)
    }

    @Test func dynamicsCompressesLoudFramesAndKeepsStereoLinked() {
        var settings = AppAudioEffectSettings(enabled: true)
        settings.dynamics = .strong
        var dsp = AppAudioDynamicsDSP(sampleRate: 48_000)
        dsp.beginBuffer(word: AppAudioDynamicsParameterWord.pack(settings))
        var frame: (left: Float, right: Float) = (0, 0)
        for _ in 0..<48_000 {
            frame = (0.8, 0.4)
            dsp.process(&frame, channels: 2)
        }
        #expect(frame.left < 0.4)
        #expect(abs(frame.left - 2 * frame.right) < 0.0001)
    }

    @Test func swapCrossfadesAndCanBeSaved() throws {
        var settings = AppAudioEffectSettings(enabled: true)
        settings.channel.swap = true
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppAudioEffectSettings.self, from: encoded).channel.swap)
        var dsp = AppAudioDynamicsDSP(sampleRate: 48_000)
        dsp.beginBuffer(word: AppAudioDynamicsParameterWord.pack(settings))
        var frame: (left: Float, right: Float) = (0, 0)
        for _ in 0..<2000 {
            frame = (0.8, 0.2)
            dsp.process(&frame, channels: 2)
        }
        #expect(abs(frame.left - 0.2) < 0.001)
        #expect(abs(frame.right - 0.8) < 0.001)
    }

    @Test func quietSignalDoesNotReceiveMakeupGain() {
        var settings = AppAudioEffectSettings(enabled: true)
        settings.dynamics = .strong
        var dsp = AppAudioDynamicsDSP(sampleRate: 48_000)
        dsp.beginBuffer(word: AppAudioDynamicsParameterWord.pack(settings))
        var frame: (left: Float, right: Float) = (0, 0)
        for _ in 0..<48_000 {
            frame = (0.001, 0.001)
            dsp.process(&frame, channels: 2)
        }
        #expect(abs(frame.left - 0.001) < 0.00001)
    }

    @Test func nightModeAndSpatialIntensityMemoryPersist() throws {
        var settings = AppAudioEffectSettings(enabled: true)
        settings.dynamics = .night
        settings.spatial.selectMode(.room)
        settings.spatial.setIntensity(0.3)
        settings.spatial.selectMode(.hall)
        settings.spatial.setIntensity(0.7)
        settings.spatial.selectMode(.room)
        #expect(abs(settings.spatial.intensity - 0.3) < 0.001)
        let data = try JSONEncoder().encode(settings)
        var restored = try JSONDecoder().decode(AppAudioEffectSettings.self, from: data)
        #expect(restored.dynamics == .night)
        restored.spatial.selectMode(.hall)
        #expect(abs(restored.spatial.intensity - 0.7) < 0.001)
        #expect(AppAudioDynamicsParameterWord.pack(restored) & 3 == 3)
    }

    @Test func disabledSettingsPackNeutralParameters() {
        var settings = AppAudioEffectSettings(enabled: false)
        settings.dynamics = .strong
        settings.channel = AppAudioChannelSettings(balance: 1, mono: true)
        #expect(AppAudioDynamicsParameterWord.pack(settings) == AppAudioDynamicsParameterWord.pack(nil))
    }
}
