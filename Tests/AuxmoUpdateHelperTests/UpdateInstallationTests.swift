import Darwin
import Foundation
import Testing
@testable import AuxmoUpdateHelper

struct UpdateInstallationTests {
    private struct InjectedFailure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Auxmo.InstallationTests.\(UUID().uuidString)")
        var app: URL { root.appendingPathComponent("Auxmo.app", isDirectory: true) }
        var stage: URL { root.appendingPathComponent("stage", isDirectory: true) }
        var payload: URL { stage.appendingPathComponent("payload", isDirectory: true) }
        var backup: URL { stage.appendingPathComponent("old", isDirectory: true) }
        init() throws {
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: app.appendingPathComponent("marker"))
            try Data("new".utf8).write(to: payload.appendingPathComponent("marker"))
        }
        func marker(_ directory: URL) throws -> String {
            String(decoding: try Data(contentsOf: directory.appendingPathComponent("marker")), as: UTF8.self)
        }
        func close() {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("测试目录清理失败：\(error)") }
        }
    }

    @Test func successfulInstallationLaunchesThenCleansUp() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var launches = 0
        try UpdateInstallation().perform(app: fixture.app, stage: fixture.stage) { app in
            launches += 1
            let installed = try fixture.marker(app)
            let original = try fixture.marker(fixture.backup)
            #expect(installed == "new" && original == "old")
        }
        #expect(launches == 1 && !FileManager.default.fileExists(atPath: fixture.stage.path))
        #expect(try fixture.marker(fixture.app) == "new")
    }

    @Test func replacementMoveFailureRestoresOldVersionAndReportsOriginalError() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var files = UpdateFileOperations.live
        files.move = { source, destination in
            if source == fixture.payload { throw InjectedFailure("replacement denied") }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        let error = try #require(throws: UpdateInstallationError.self) {
            try UpdateInstallation(files: files).perform(app: fixture.app, stage: fixture.stage) { _ in
                Issue.record("替换失败不能启动新版本")
            }
        }
        guard case .installationFailedRestored(let original) = error else { Issue.record("应报告恢复成功"); return }
        #expect(original == "replacement denied")
        #expect(try fixture.marker(fixture.app) == "old")
        #expect(try fixture.marker(fixture.payload) == "new")
    }

    @Test func launchRefusalRestoresWithoutRemovingSecurityAttributes() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let error = try #require(throws: UpdateInstallationError.self) {
            try UpdateInstallation().perform(app: fixture.app, stage: fixture.stage) { _ in
                throw InjectedFailure("macOS refused launch")
            }
        }
        #expect(error.localizedDescription.contains("macOS refused launch"))
        #expect(try fixture.marker(fixture.app) == "old")
    }

    @Test func failedRemovalDuringRollbackRetainsBackupAndBothErrors() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var files = UpdateFileOperations.live
        files.remove = { path in
            if path == fixture.app { throw InjectedFailure("removal denied") }
            try FileManager.default.removeItem(at: path)
        }
        let error = try #require(throws: UpdateInstallationError.self) {
            try UpdateInstallation(files: files).perform(app: fixture.app, stage: fixture.stage) { _ in
                throw InjectedFailure("launch denied")
            }
        }
        guard case .rollbackFailed(let original, let rollback, let backup) = error else { Issue.record("不能冒充恢复成功"); return }
        #expect(original == "launch denied" && rollback == "removal denied" && backup == fixture.backup.path)
        #expect(try fixture.marker(fixture.backup) == "old")
        #expect(try fixture.marker(fixture.app) == "new")
    }

    @Test func failedRestoreReportsBothFailuresAndTheRecoverableBackupPath() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var files = UpdateFileOperations.live
        files.move = { source, destination in
            if source == fixture.backup { throw InjectedFailure("restore denied") }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        let error = try #require(throws: UpdateInstallationError.self) {
            try UpdateInstallation(files: files).perform(app: fixture.app, stage: fixture.stage) { _ in
                throw InjectedFailure("launch denied")
            }
        }
        guard case .rollbackFailed(let original, let rollback, let backup) = error else { Issue.record("应报告恢复失败"); return }
        #expect(original == "launch denied" && rollback == "restore denied" && backup == fixture.backup.path)
        #expect(try fixture.marker(fixture.backup) == "old")
        #expect(!FileManager.default.fileExists(atPath: fixture.app.path))
    }

    @Test func existingRecoveryBackupBlocksInstallationWithoutDeletingAnything() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try FileManager.default.createDirectory(at: fixture.backup, withIntermediateDirectories: true)
        try Data("recoverable".utf8).write(to: fixture.backup.appendingPathComponent("marker"))
        let error = try #require(throws: UpdateInstallationError.self) {
            try UpdateInstallation().perform(app: fixture.app, stage: fixture.stage) { _ in Issue.record("不能继续安装") }
        }
        guard case .recoveryBackupExists = error else { Issue.record("应明确报告旧备份"); return }
        #expect(try fixture.marker(fixture.backup) == "recoverable")
        #expect(try fixture.marker(fixture.app) == "old")
        #expect(try fixture.marker(fixture.payload) == "new")
    }

    @Test func failureToSaveOldAppDoesNotTouchPayloadOrAttemptLaunch() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var files = UpdateFileOperations.live
        files.move = { _, _ in throw InjectedFailure("cannot save old app") }
        #expect(throws: InjectedFailure.self) {
            try UpdateInstallation(files: files).perform(app: fixture.app, stage: fixture.stage) { _ in
                Issue.record("原应用未备份时不能启动更新")
            }
        }
        #expect(try fixture.marker(fixture.app) == "old")
        #expect(try fixture.marker(fixture.payload) == "new")
    }

    @Test func missingPayloadCannotMoveTheCurrentApp() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try FileManager.default.removeItem(at: fixture.payload)
        let error = try #require(throws: UpdateInstallationError.self) {
            try UpdateInstallation().perform(app: fixture.app, stage: fixture.stage) { _ in Issue.record("不能启动缺失的更新") }
        }
        guard case .missingPayload = error else { Issue.record("应报告缺失的安装包"); return }
        #expect(try fixture.marker(fixture.app) == "old")
        #expect(!FileManager.default.fileExists(atPath: fixture.backup.path))
    }

    @Test func backupCleanupFailureDoesNotRollBackAnAlreadyLaunchedVersion() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var files = UpdateFileOperations.live
        files.remove = { path in
            if path == fixture.backup { throw InjectedFailure("backup cleanup denied") }
            try FileManager.default.removeItem(at: path)
        }
        let error = try #require(throws: UpdateInstallationError.self) {
            try UpdateInstallation(files: files).perform(app: fixture.app, stage: fixture.stage) { _ in }
        }
        guard case .cleanupFailed(let detail) = error else { Issue.record("清理失败不能当作安装失败回滚"); return }
        #expect(detail == "backup cleanup denied")
        #expect(try fixture.marker(fixture.app) == "new")
        #expect(try fixture.marker(fixture.backup) == "old")
    }

    @Test func stagingCleanupFailureIsReportedWithoutRollingBackNewApp() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var files = UpdateFileOperations.live
        files.remove = { path in
            if path == fixture.stage { throw InjectedFailure("stage cleanup denied") }
            try FileManager.default.removeItem(at: path)
        }
        let error = try #require(throws: UpdateInstallationError.self) {
            try UpdateInstallation(files: files).perform(app: fixture.app, stage: fixture.stage) { _ in }
        }
        guard case .cleanupFailed = error else { Issue.record("应报告清理失败"); return }
        #expect(try fixture.marker(fixture.app) == "new")
    }

    @Test func quarantineAttributeIsPreservedThroughReplacementAndLaunchRequest() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let quarantine = Array("0081;00000000;AuxmoTest;".utf8)
        let result = quarantine.withUnsafeBytes { bytes in
            setxattr(fixture.payload.path, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, 0)
        }
        try #require(result == 0)
        try UpdateInstallation().perform(app: fixture.app, stage: fixture.stage) { app in
            var actual = [UInt8](repeating: 0, count: quarantine.count)
            let count = actual.withUnsafeMutableBytes { bytes in
                getxattr(app.path, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, 0)
            }
            #expect(count == quarantine.count && actual == quarantine)
        }
    }
}
