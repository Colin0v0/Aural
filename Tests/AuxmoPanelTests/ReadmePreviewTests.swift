import AppKit
import CoreAudio
import SwiftUI
import Testing
@testable import Auxmo
@testable import AuxmoCore

/// 文档截图使用真实视图和内存设备，不访问蓝牙、不捕获音频、不修改系统输出。
/// 只由独立脚本显式执行；不能把示例读数当成真实播放或硬件验收证据。
@MainActor
struct ReadmePreviewTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUXMO_RENDER_README"] == "1"))
    func renderProductPreviews() throws {
        let code = try #require(ProcessInfo.processInfo.environment["AUXMO_README_LANGUAGE"])
        try #require(["en", "zh"].contains(code))
        let language: AppLanguage = code == "en" ? .english : .chinese
        let defaults = UserDefaults.standard
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        // 进程内参数域覆盖，不把文档演示设置写入用户的持久化偏好。
        var arguments = originalArguments
        arguments["com.colin0v0.auxmo.settings.language"] = language.rawValue
        arguments["com.colin0v0.auxmo.settings.appearance"] = "light"
        arguments["com.colin0v0.auxmo.settings.showHeadphones"] = true
        arguments["com.colin0v0.auxmo.settings.showSimultaneousOutput"] = true
        arguments["com.colin0v0.auxmo.settings.appAudioEffectsEnabled"] = true
        // 显式覆盖电量来源，避免初始化时触发旧版偏好迁移写盘。
        arguments["com.colin0v0.auxmo.settings.menuBarBatterySource"] = "off"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        #expect(AppSettings.shared.resolvedLanguage == language)

        let output = try #require(ProcessInfo.processInfo.environment["AUXMO_README_OUTPUT_DIR"])
        let directory = URL(fileURLWithPath: output).appendingPathComponent(code, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Auxmo.ReadmePreview.\(UUID().uuidString)"
        let storage = try #require(UserDefaults(suiteName: suite))
        defer { storage.removePersistentDomain(forName: suite) }
        let hardware = RoutingTestHardware()
        hardware.outputs = [
            AudioOutput(id: 1, uid: "speaker", name: code == "en" ? "MacBook Speakers" : "MacBook 扬声器",
                        transport: kAudioDeviceTransportTypeBuiltIn),
            AudioOutput(id: 2, uid: "headphone", name: "AirPods Pro",
                        transport: kAudioDeviceTransportTypeBluetooth)
        ]
        let controls: [AudioDeviceID: AudioDeviceControlState] = [
            1: .available(volume: AudioDeviceVolume(scalar: 0.4, writable: true),
                          mute: AudioDeviceMute(muted: false, writable: true)),
            2: .available(volume: AudioDeviceVolume(scalar: 0.6, writable: true),
                          mute: AudioDeviceMute(muted: false, writable: true))
        ]
        var hal = hardware.hardware
        hal.snapshot = {
            let snapshot = hardware.snapshot
            return SystemAudioSnapshot(outputs: snapshot.outputs, selectedID: snapshot.selectedID, controls: controls)
        }
        let rows = [row("com.google.Chrome", name: "Chrome", objectID: 42),
                    row("com.apple.Music", name: "Music", objectID: 43)]
        let environment = ApplicationAudioEnvironment(readApplications: { _ in (rows, 2) },
            hasMixerConflict: { false }, makeSession: { group, output, route, mode in
                MemoryAudioSession(group: group, output: output, route: route, mode: mode)
            }, now: Date.init, captureAccess: { .authorized })
        let model = AppModel(outputHardware: hal, startsMonitoring: false, applicationAudio: environment,
                             appAudioRouteStore: AppAudioRouteStore(defaults: storage),
                             appAudioEffectStore: AppAudioEffectStore(defaults: storage),
                             appAudioEffectsEnabled: true)
        defer { #expect(model.shutdown()) }
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        model.setApplicationGain(0.35, for: rows[0].id)
        model.setApplicationGain(0.7, for: rows[1].id)
        model.setApplicationAudioRoute(.custom(deviceUIDs: ["speaker"]), for: rows[0].id)
        model.setApplicationAudioRoute(.custom(deviceUIDs: ["headphone"]), for: rows[1].id)
        model.setApplicationAudioEffect(AppAudioEffectSettings(enabled: true, preset: .music), for: rows[1].id)

        let layout = PanelPresentationLayout()
        let panel = AudioPanel(model: model, layout: layout, openSettings: {}, panelSizeChanged: { _ in },
                               surface: .controlWindow)
        let host = NSHostingView(rootView: panel)
        host.appearance = NSAppearance(named: .aqua)
        host.frame.size = CGSize(width: PanelMetrics.width, height: 500)
        for _ in 0..<4 {
            PanelTestSupport.flushLayout(host)
            host.frame.size = layout.size
        }
        #expect(host.bounds.height > 180)
        try save(host, to: directory.appendingPathComponent("hero.png"))

        try render(ApplicationVolumeSection(model: model, metersVisible: false,
                                           routingEnabled: true, effectsEnabled: true)
                    .padding(.vertical, 14).frame(width: PanelMetrics.width),
                   language: language, to: directory.appendingPathComponent("mixer.png"))
        try render(SimultaneousOutputEditor(outputs: hardware.outputs, controls: controls,
                        selectedUIDs: ["speaker", "headphone"], toggleMember: { _ in },
                        setVolume: { _, _ in }, setMuted: { _, _ in })
                    .padding(.vertical, 14).frame(width: PanelMetrics.width),
                   language: language, to: directory.appendingPathComponent("outputs.png"))
        try render(ApplicationAudioEffectView(model: model, applicationID: rows[1].id,
                                              appName: "Music", applicationURL: nil),
                   language: language, to: directory.appendingPathComponent("effects.png"))

        let controller = HeadphoneController(appleHardware: AppleHeadphoneHardware(
            isSupported: { _ in true }, validateTarget: { _ in }, snapshot: { _ in
                AppleHeadphoneSnapshot(noiseMode: .transparency,
                    supportedNoiseModes: [.cancellation, .transparency, .adaptive], wearState: .bothEars)
            }, requestMode: { _, _ in Issue.record("文档预览不能写入耳机模式") },
            waitForReadback: { await Task.yield() },
            battery: { _ in AppleHeadphoneBattery(left: 85, right: 82, caseLevel: 70) }))
        controller.updateOutput(hardware.outputs[1])
        defer { controller.shutdown() }
        #expect(controller.phase == .ready)
        try render(HeadphoneSection(controller: controller, output: hardware.outputs[1])
                    .frame(width: PanelMetrics.width),
                   language: language, to: directory.appendingPathComponent("headphones.png"))
    }

    private func row(_ bundle: String, name: String, objectID: UInt32) -> ApplicationAudioRow {
        let id = "bundle:\(bundle)"
        let group = AudioProcessGroup(id: id, bundleID: bundle, processIDs: [Int32(objectID)], objectIDs: [objectID])
        return ApplicationAudioRow(id: id, bundleID: bundle, name: name, applicationURL: nil,
                                   group: group, isRunningOutput: true)
    }

    private func render<V: View>(_ view: V, language: AppLanguage, to url: URL) throws {
        let host = NSHostingView(rootView: view
            .font(PanelStyle.bodyFont).foregroundStyle(PanelStyle.ink)
            .environment(\.appLanguage, language).environment(\.colorScheme, .light)
            .background(PanelStyle.canvas))
        host.appearance = NSAppearance(named: .aqua)
        host.frame.size = host.fittingSize
        PanelTestSupport.flushLayout(host)
        try save(host, to: url)
    }

    private func save<V: View>(_ host: NSHostingView<V>, to url: URL) throws {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
