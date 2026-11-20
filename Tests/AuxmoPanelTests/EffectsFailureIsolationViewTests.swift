import AppKit
import SwiftUI
import Testing
import Vision
@testable import Auxmo
@testable import AuxmoCore

@MainActor
struct EffectsFailureIsolationViewTests {
    @Test(arguments: [false, true])
    func unreadableConfigurationStillRendersTheIndependentRecoveryAction(effectsDamaged: Bool) throws {
        let suite = "Auxmo.EffectsFailureView.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = effectsDamaged ? "com.colin0v0.auxmo.settings.appAudioEffects" : "com.colin0v0.auxmo.settings.appAudioEffectPresets"
        defaults.set(Data("{".utf8), forKey: key)
        let audio = SessionFixture(), hardware = RoutingTestHardware()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false, applicationAudio: audio.environment,
            appAudioRouteStore: AppAudioRouteStore(defaults: defaults), appAudioEffectStore: AppAudioEffectStore(defaults: defaults), appAudioEffectsEnabled: true)
        defer { #expect(model.shutdown()) }
        let host = NSHostingView(rootView: ApplicationAudioEffectView(model: model, applicationID: audio.row.id,
                                                                     appName: audio.row.label, applicationURL: nil))
        host.frame.size = ApplicationAudioEffectMetrics.size
        let window = NSWindow(contentRect: PanelTestSupport.windowFrame(size: ApplicationAudioEffectMetrics.size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        PanelTestSupport.flushLayout(host)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: effectsDamaged ? "/tmp/auxmo-effects-unreadable-settings.png" : "/tmp/auxmo-effects-unreadable-presets.png"))
        // 当前工具链的 SwiftUI 宿主不公开 AX 子树；直接识别真实渲染，验证恢复入口没有被挤出窗口。
        let image = try #require(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined().replacingOccurrences(of: " ", with: "")
        let label = L10n.text(effectsDamaged ? "重新读取音效配置" : "重新读取预设", language: AppSettings.shared.resolvedLanguage)
            .replacingOccurrences(of: " ", with: "")
        #expect(text.contains(label))
        #expect(model.applicationEffectConfigurationAvailable == !effectsDamaged)
        #expect(model.applicationEffectPresetsAvailable == effectsDamaged)

    }

}
