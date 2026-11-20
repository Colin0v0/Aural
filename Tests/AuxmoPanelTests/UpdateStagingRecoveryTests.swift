import Foundation
import Testing
@testable import Auxmo

struct UpdateStagingRecoveryTests {
    private struct ReadFailure: Error {}
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Auxmo.RecoveryTests.\(UUID().uuidString)")
        var stage: URL { root.appendingPathComponent("stage", isDirectory: true) }
        var record: URL { stage.appendingPathComponent("extracted/" + UpdateArchiveExtractor.mountRecordName) }
        var image: URL { stage.appendingPathComponent("archive.dmg") }
        init() throws {
            try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(image.path.utf8).write(to: record)
            try Data("payload".utf8).write(to: stage.appendingPathComponent("payload"))
        }
        func inventory(images: [[String: Any]] = []) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: ["images": images], format: .xml, options: 0)
        }
        func close() {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("测试目录清理失败：\(error)") }
        }
    }

    @Test func confirmedUnmountedRecordCanBeExplicitlyClearedWithoutDeletingPayload() throws {
        let f = try Fixture(); defer { f.close() }
        var reads = 0
        let recovery = UpdateStagingRecovery(mountedImages: { reads += 1; return try f.inventory() })
        let inspection = try recovery.inspect(f.stage)
        #expect(inspection.canRemoveStaleMarker && FileManager.default.fileExists(atPath: f.record.path))
        try recovery.removeStaleMarker(inspection)
        #expect(reads == 2 && !FileManager.default.fileExists(atPath: f.record.path))
        #expect(try String(contentsOf: f.stage.appendingPathComponent("payload"), encoding: .utf8) == "payload")
    }

    @Test func anAttachedImageWithoutAMountPointStillPreventsCleanup() throws {
        let f = try Fixture(); defer { f.close() }
        let recovery = UpdateStagingRecovery(mountedImages: {
            try f.inventory(images: [["image-path": f.image.path, "system-entities": [["dev-entry": "/dev/disk99"]]]])
        })
        #expect(throws: UpdateRecoveryError.self) { try recovery.inspect(f.stage) }
        #expect(FileManager.default.fileExists(atPath: f.record.path))
    }

    @Test func unexpectedImageMountedInsideStagingAlsoPreventsCleanup() throws {
        let f = try Fixture(); defer { f.close() }
        let recovery = UpdateStagingRecovery(mountedImages: {
            try f.inventory(images: [["image-path": "/tmp/other.dmg", "system-entities": [["mount-point": f.stage.appendingPathComponent("extracted/mount").path]]]])
        })
        #expect(throws: UpdateRecoveryError.self) { try recovery.inspect(f.stage) }
    }

    @Test func incompleteOrFailedInventoryNeverMeansNoMounts() throws {
        let f = try Fixture(); defer { f.close() }
        let invalid = try PropertyListSerialization.data(fromPropertyList: ["images": [["image-path": "/tmp/image.dmg"]]], format: .xml, options: 0)
        #expect(throws: UpdateRecoveryError.self) { try UpdateStagingRecovery(mountedImages: { invalid }).inspect(f.stage) }
        #expect(throws: ReadFailure.self) { try UpdateStagingRecovery(mountedImages: { throw ReadFailure() }).inspect(f.stage) }
        #expect(FileManager.default.fileExists(atPath: f.record.path))
    }

    @Test func backupIsProtectedEvenAfterAnEarlierSuccessfulInspection() throws {
        let f = try Fixture(); defer { f.close() }
        let recovery = UpdateStagingRecovery(mountedImages: { try f.inventory() })
        let inspected = try recovery.inspect(f.stage)
        let backup = f.stage.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        #expect(throws: AuxmoUpdateError.self) { try recovery.removeStaleMarker(inspected) }
        #expect(FileManager.default.fileExists(atPath: backup.path) && FileManager.default.fileExists(atPath: f.record.path))
    }

    @Test func changingRecordOrAttachingAfterInspectionInvalidatesTheOldPermission() throws {
        let f = try Fixture(); defer { f.close() }
        var attached = false
        let recovery = UpdateStagingRecovery(mountedImages: {
            try f.inventory(images: attached ? [["image-path": f.image.path, "system-entities": []]] : [])
        })
        let inspected = try recovery.inspect(f.stage)
        attached = true
        #expect(throws: UpdateRecoveryError.self) { try recovery.removeStaleMarker(inspected) }
        attached = false
        try Data(f.stage.appendingPathComponent("changed.dmg").path.utf8).write(to: f.record)
        #expect(throws: UpdateRecoveryError.self) { try recovery.removeStaleMarker(inspected) }
        #expect(FileManager.default.fileExists(atPath: f.record.path))
    }

    @Test func noRecordIsAnExplicitNoOpWithoutReadingOrDeletingStaging() throws {
        let f = try Fixture(); defer { f.close() }
        try FileManager.default.removeItem(at: f.record)
        let recovery = UpdateStagingRecovery(mountedImages: { throw ReadFailure() })
        let inspected = try recovery.inspect(f.stage)
        #expect(!inspected.canRemoveStaleMarker)
        try recovery.removeStaleMarker(inspected)
        #expect(FileManager.default.fileExists(atPath: f.stage.appendingPathComponent("payload").path))
    }
}
