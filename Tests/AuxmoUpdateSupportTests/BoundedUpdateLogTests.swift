import Foundation
import Testing
@testable import AuxmoUpdateSupport

struct BoundedUpdateLogTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Auxmo.LogTests.\(UUID().uuidString)")
        var current: URL { root.appendingPathComponent("update.log") }
        var previous: URL { root.appendingPathComponent("update.log.1") }
        func close() {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("测试目录清理失败：\(error)") }
        }
    }

    @Test func rotationBoundsBothFilesAndKeepsTheNewestEntry() throws {
        let f = Fixture(); defer { f.close() }
        let log = BoundedUpdateLog(directory: f.root, maximumBytes: 64)
        for i in 0..<30 { try log.append("event-\(i)\n") }
        let current = try Data(contentsOf: f.current), previous = try Data(contentsOf: f.previous)
        #expect(current.count <= 64 && previous.count <= 64)
        #expect(String(decoding: current, as: UTF8.self).hasSuffix("event-29\n"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).sorted() == ["update.log", "update.log.1", "update.log.lock"])
    }

    @Test func aSingleOversizedChineseEntryRemainsBoundedAndValidUTF8() throws {
        let f = Fixture(); defer { f.close() }
        try BoundedUpdateLog(directory: f.root, maximumBytes: 32).append(String(repeating: "测试日志", count: 40) + "结束\n")
        let data = try Data(contentsOf: f.current)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(data.count <= 32 && text.hasSuffix("结束\n"))
    }

    @Test func anOversizedLegacyLogIsReadOnlyAtItsBoundedTail() throws {
        let f = Fixture(); defer { f.close() }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        try Data(String(repeating: "遗留记录", count: 500).utf8).write(to: f.current)
        try BoundedUpdateLog(directory: f.root, maximumBytes: 31).append("new\n")
        let previous = try Data(contentsOf: f.previous)
        #expect(previous.count <= 31 && String(data: previous, encoding: .utf8) != nil)
        #expect(try String(contentsOf: f.current, encoding: .utf8) == "new\n")
    }

    @Test func independentWritersCannotInterleaveOrLoseEntries() throws {
        let f = Fixture(); defer { f.close() }
        let directory = f.root
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            do { try BoundedUpdateLog(directory: directory, maximumBytes: 4096).append("writer-\(i)\n") }
            catch { Issue.record("并发写入失败：\(error)") }
        }
        let lines = try String(contentsOf: f.current, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(Set(lines) == Set((0..<100).map { "writer-\($0)" }) && lines.count == 100)
    }

    @Test func unusableLogDirectoryReportsFailureWithoutChoosingAnotherPath() throws {
        let f = Fixture(); defer { f.close() }
        try Data("not a directory".utf8).write(to: f.root)
        #expect(throws: (any Error).self) { try BoundedUpdateLog(directory: f.root).append("entry") }
        #expect(try String(contentsOf: f.root, encoding: .utf8) == "not a directory")
    }

    @Test func rejectedRotationPreservesTheCurrentLog() throws {
        let f = Fixture(); defer { f.close() }
        try FileManager.default.createDirectory(at: f.previous, withIntermediateDirectories: true)
        try Data("old entry".utf8).write(to: f.current)
        #expect(throws: (any Error).self) { try BoundedUpdateLog(directory: f.root, maximumBytes: 10).append("new entry") }
        #expect(try String(contentsOf: f.current, encoding: .utf8) == "old entry")
    }
}
