import Foundation
import OSLog
import AuxmoCore

enum MeterSurface: Hashable { case popover, controlWindow }

/// 独立拥有电平源、包络和计时器。只消费会话峰值，不创建/停止会话，也不修改全局错误。
@MainActor
final class ApplicationMeterController {
    private static let log = Logger(subsystem: "com.colin0v0.auxmo.app", category: "ApplicationAudio")
    private var sources: [String: ApplicationLevelSource] = [:]
    private var envelopes: [String: AudioLevelEnvelope] = [:]
    private var observedSignals: Set<String> = []
    private var visibleSurfaces: Set<MeterSurface> = []
    private var selectedSections: Set<MeterSurface> = [.popover, .controlWindow]
    private var timer: Timer?
    deinit { timer?.invalidate() }
    var hasVisibleSurface: Bool { !visibleSurfaces.isEmpty }
    var visible: Bool { !visibleSurfaces.isDisjoint(with: selectedSections) }
    var visibleSurfacesSnapshot: Set<MeterSurface> { visibleSurfaces }

    func source(for id: String) -> ApplicationLevelSource {
        if let existing = sources[id] { return existing }
        let created = ApplicationLevelSource(); sources[id] = created
        return created
    }

    func prepare(for rows: [ApplicationAudioRow]) {
        let ids = Set(rows.map(\.id))
        sources = sources.filter { ids.contains($0.key) }
        envelopes = envelopes.filter { ids.contains($0.key) }
        for row in rows { _ = source(for: row.id) }
    }

    func setVisible(_ visible: Bool, surface: MeterSurface) {
        if visible { visibleSurfaces.insert(surface) } else { visibleSurfaces.remove(surface) }
    }

    func setSelected(_ selected: Bool, surface: MeterSurface) {
        if selected { selectedSections.insert(surface) } else { selectedSections.remove(surface) }
    }

    func updateActivity(sessions: [String: any ApplicationAudioSession], tick: @escaping @MainActor () -> Void) {
        if visible {
            guard timer == nil else { return }
            for session in sessions.values { _ = session.consumePeak() }
            envelopes.removeAll()
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in Task { @MainActor in tick() } }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else { shutdown() }
    }

    func refresh(rows: [ApplicationAudioRow], sessions: [String: any ApplicationAudioSession]) {
        guard visible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let ids = Set(rows.map(\.id))
        for app in rows {
            guard let peak = sessions[app.id]?.consumePeak() else { clear(app.id); continue }
            if peak > 0, observedSignals.insert(app.id).inserted {
                Self.log.notice("Received real audio signal for \(app.id, privacy: .public)")
            }
            if envelopes[app.id] == nil { envelopes[app.id] = AudioLevelEnvelope() }
            sources[app.id]?.update(envelopes[app.id]?.update(peak: peak, at: now))
        }
        envelopes = envelopes.filter { ids.contains($0.key) }
    }

    func clear(_ id: String, ended: Bool = false) {
        sources[id]?.update(nil); envelopes.removeValue(forKey: id)
        if ended { observedSignals.remove(id) }
    }

    func clearAll() { for source in sources.values { source.update(nil) }; envelopes.removeAll() }
    func shutdown() { timer?.invalidate(); timer = nil; clearAll() }
}
