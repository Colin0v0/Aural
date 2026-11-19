import Foundation
import Testing
import AuralCore
@testable import Aural

@MainActor
struct DiagnosticsExportTests {
    @Test func eventLogIsBoundedAndSuppressesRepeatedIdenticalErrors() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let log = DiagnosticEventLog(capacity: 2, dedupeWindow: 5, now: { start })

        log.record(category: "applicationFailure", message: "same error", at: start)
        log.record(category: "applicationFailure", message: "same error", at: start.addingTimeInterval(1))
        log.record(category: "routing", message: "phase=failed", at: start.addingTimeInterval(2))
        log.record(category: "cleanup", message: "tap release failed", at: start.addingTimeInterval(3))

        let events = log.snapshot()
        #expect(events.count == 2)
        #expect(events.map(\.category) == ["routing", "cleanup"])
    }

    @Test func eventLogPrunesExpiredDedupeEntries() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let log = DiagnosticEventLog(capacity: 10, dedupeWindow: 5, now: { start })

        log.record(category: "audio", message: "first", at: start)
        log.record(category: "audio", message: "second", at: start.addingTimeInterval(10))
        log.record(category: "audio", message: "third", at: start.addingTimeInterval(20))

        #expect(log.dedupeKeyCount == 1)
    }

    @Test func reportContainsCurrentErrorsAndRecentEventHistory() throws {
        let hardware = RoutingTestHardware()
        hardware.failSnapshot = true
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false)
        model.operationError = "测试操作失败"

        let report = model.makeDiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(report.schemaVersion == 1)
        #expect(report.errors.audio == "快照读取失败")
        #expect(report.errors.operation == "测试操作失败")
        #expect(report.recentEvents.contains { $0.category == "audio" && $0.message == "快照读取失败" })
        #expect(report.recentEvents.contains { $0.category == "operation" && $0.message == "测试操作失败" })

        let data = try AuralDiagnosticExporter.data(for: report)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"schemaVersion\" : 1"))
        #expect(json.contains("快照读取失败"))
        #expect(!json.lowercased().contains("audio samples"))
        #expect(!json.lowercased().contains("pcm"))
    }

}
