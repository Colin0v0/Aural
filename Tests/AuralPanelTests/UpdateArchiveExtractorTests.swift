import Foundation
import Testing
@testable import Aural

struct UpdateArchiveExtractorTests {
    private struct Failure: LocalizedError { let errorDescription: String? }
    /// 只在临时目录注入文件操作失败，不依赖当前用户的磁盘权限。
    private final class RefusingRemoval: FileManager, @unchecked Sendable {
        override func removeItem(at URL: URL) throws { throw Failure(errorDescription: "removal denied") }
    }
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Aural.ArchiveTests.\(UUID().uuidString)")
        var directory: URL { root.appendingPathComponent("extracted", isDirectory: true) }
        var mount: URL { directory.appendingPathComponent("mount", isDirectory: true) }
        var record: URL { directory.appendingPathComponent(UpdateArchiveExtractor.mountRecordName) }
        var archive: URL { root.appendingPathComponent("archive.dmg") }
        var commands: [String] = []
        var copyFailure = false
        var detachFailure = false
        var attachFailure = false
        func run(_ command: String, _ arguments: [String]) throws -> String {
            if arguments.first == "attach" {
                commands.append("attach")
                if attachFailure { throw Failure(errorDescription: "attach refused") }
                try FileManager.default.createDirectory(at: mount.appendingPathComponent("Aural.app"), withIntermediateDirectories: true)
            } else if arguments.first == "detach" {
                commands.append("detach")
                if detachFailure { throw Failure(errorDescription: "device busy") }
            } else {
                commands.append("copy")
                if copyFailure { throw Failure(errorDescription: "copy denied") }
                try FileManager.default.copyItem(atPath: arguments[0], toPath: arguments[1])
            }
            return ""
        }
        func close() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("测试目录清理失败：\(error)") }
        }
    }

    @Test func successfulExtractionConfirmsDetachBeforeRemovingTheRecord() throws {
        let fixture = Fixture(); defer { fixture.close() }
        let app = try UpdateArchiveExtractor(run: fixture.run).extractDMG(fixture.archive, to: fixture.directory)
        #expect(FileManager.default.fileExists(atPath: app.path))
        #expect(fixture.commands == ["attach", "copy", "detach"])
        #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
    }

    @Test func detachFailureRetainsMountAndBlocksNextStagingCleanup() throws {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.detachFailure = true
        let error = try #require(throws: UpdateArchiveError.self) {
            try UpdateArchiveExtractor(run: fixture.run).extractDMG(fixture.archive, to: fixture.directory)
        }
        #expect(error.localizedDescription.contains("device busy") && error.localizedDescription.contains(fixture.mount.path))
        #expect(FileManager.default.fileExists(atPath: fixture.record.path))
        #expect(throws: UpdateArchiveError.self) { try AuralUpdateInstaller.removeStaging(at: fixture.root) }
        #expect(throws: UpdateArchiveError.self) {
            try UpdateArchiveExtractor(run: fixture.run).extractDMG(fixture.archive, to: fixture.directory)
        }
        #expect(fixture.commands == ["attach", "copy", "detach"])
    }

    @Test func extractionAndDetachFailuresAreBothReportedWithoutRetrying() throws {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.copyFailure = true; fixture.detachFailure = true
        let error = try #require(throws: UpdateArchiveError.self) {
            try UpdateArchiveExtractor(run: fixture.run).extractDMG(fixture.archive, to: fixture.directory)
        }
        #expect(error.localizedDescription.contains("copy denied") && error.localizedDescription.contains("device busy"))
        #expect(fixture.commands == ["attach", "copy", "detach"])
        #expect(FileManager.default.fileExists(atPath: fixture.record.path))
    }

    @Test func extractionFailureStillDetachesAndReturnsTheOriginalFailure() throws {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.copyFailure = true
        #expect(throws: Failure.self) {
            try UpdateArchiveExtractor(run: fixture.run).extractDMG(fixture.archive, to: fixture.directory)
        }
        #expect(fixture.commands == ["attach", "copy", "detach"])
        #expect(!FileManager.default.fileExists(atPath: fixture.record.path))
    }

    @Test func attachFailureRetainsEvidenceInsteadOfAssumingNothingMounted() throws {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.attachFailure = true
        #expect(throws: UpdateArchiveError.self) {
            try UpdateArchiveExtractor(run: fixture.run).extractDMG(fixture.archive, to: fixture.directory)
        }
        #expect(fixture.commands == ["attach"] && FileManager.default.fileExists(atPath: fixture.record.path))
    }

    @Test func failedDirectoryCleanupReportsThePathAndCannotProceedToMount() throws {
        let fixture = Fixture(); defer { fixture.close() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let extractor = UpdateArchiveExtractor(run: fixture.run, manager: RefusingRemoval())
        let error = try #require(throws: UpdateArchiveError.self) {
            try extractor.extractDMG(fixture.archive, to: fixture.directory)
        }
        #expect(error.localizedDescription.contains("removal denied") && error.localizedDescription.contains(fixture.directory.path))
        #expect(fixture.commands.isEmpty)
    }

    @Test func zipCannotDeleteARetainedDMGMountOrBecomeAnAlternatePath() throws {
        let fixture = Fixture(); defer { fixture.close() }
        fixture.detachFailure = true
        #expect(throws: UpdateArchiveError.self) {
            try UpdateArchiveExtractor(run: fixture.run).extractDMG(fixture.archive, to: fixture.directory)
        }
        #expect(throws: UpdateArchiveError.self) {
            try UpdateArchiveExtractor(run: fixture.run).extractZIP(fixture.archive, to: fixture.directory)
        }
        #expect(fixture.commands == ["attach", "copy", "detach"])
    }
}
