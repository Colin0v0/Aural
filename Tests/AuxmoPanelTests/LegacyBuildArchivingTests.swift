import Foundation
import Testing

struct LegacyBuildArchivingTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Auxmo.LegacyArchiveTests.\(UUID().uuidString)")
        var app: URL { root.appendingPathComponent("Auxmo.app") }
        var executable: URL { app.appendingPathComponent("Contents/MacOS/Auxmo") }
        var archive: URL { root.appendingPathComponent("archive/local-builds") }
        init() throws {
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.3.10", "CFBundleVersion": "38"], format: .xml, options: 0)
            try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
            try Data("keep this".utf8).write(to: app.appendingPathComponent("sentinel"))
            try Data("unused executable fixture".utf8).write(to: executable)
        }
        func run() throws -> Int32 {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [repo.appendingPathComponent("Scripts/archive-legacy-build.sh").path, root.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); return process.terminationStatus
        }
        func close() {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record("测试目录清理失败：\(error)") }
        }
    }

    @Test func inactiveLegacyBuildIsArchivedIntactAndNeverAliasedToAnotherBuild() throws {
        let f = try Fixture(); defer { f.close() }
        #expect(try f.run() == 0)
        #expect(!FileManager.default.fileExists(atPath: f.app.path))
        let archives = try FileManager.default.contentsOfDirectory(at: f.archive, includingPropertiesForKeys: nil)
        let destination = try #require(archives.first).appendingPathComponent("Auxmo.app/sentinel")
        let contents = try String(contentsOf: destination, encoding: .utf8)
        #expect(archives.count == 1 && contents == "keep this")
        #expect(try f.run() == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.archive.path).count == 1)
    }

    @Test func runningLegacyExecutableCannotBeMovedOrTerminated() throws {
        let f = try Fixture(); defer { f.close() }
        // 系统签名的 /bin/sleep 被复制后可能被 AMFI 杀死；编译自己的夹具并等待就绪，才是真正的运行中测试。
        let source = f.root.appendingPathComponent("fixture.c")
        try Data("#include <unistd.h>\nint main(void) { write(1, \"R\", 1); sleep(30); return 0; }\n".utf8).write(to: source)
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", source.path, "-o", f.executable.path]
        try compiler.run(); compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
        let child = Process(); child.executableURL = f.executable; child.arguments = ["30"]
        let ready = Pipe(); child.standardOutput = ready
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        try #require(ready.fileHandleForReading.read(upToCount: 1) == Data("R".utf8))
        #expect(try f.run() != 0)
        #expect(child.isRunning && FileManager.default.fileExists(atPath: f.app.path))
        #expect(!FileManager.default.fileExists(atPath: f.archive.path))
    }

    @Test func symlinkAtTheLegacyPathCannotMoveTheTargetApplication() throws {
        let f = try Fixture(); defer { f.close() }
        let target = f.root.appendingPathComponent("Real.app")
        try FileManager.default.moveItem(at: f.app, to: target)
        try FileManager.default.createSymbolicLink(at: f.app, withDestinationURL: target)
        #expect(try f.run() != 0)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("sentinel").path))
    }
}
