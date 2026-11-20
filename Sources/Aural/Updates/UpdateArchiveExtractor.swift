import Foundation

/// 解包持有挂载的唯一所有权。挂载标记只在确认卸载后删除，后续下载不能扫掉仍在使用的目录。
struct UpdateArchiveExtractor {
    static let mountRecordName = ".aural-mounted-image"
    let run: (String, [String]) throws -> String
    var manager: FileManager = .default

    static func requireUnmounted(_ directory: URL, manager: FileManager = .default) throws {
        let record = directory.appendingPathComponent(mountRecordName)
        guard !manager.fileExists(atPath: record.path) else {
            throw UpdateArchiveError.retainedMount(directory.appendingPathComponent("mount").path)
        }
    }

    static func removeIfPresent(_ url: URL, manager: FileManager = .default) throws {
        guard manager.fileExists(atPath: url.path) else { return }
        do { try manager.removeItem(at: url) }
        catch {
            throw UpdateArchiveError.cleanupFailed(operation: "更新文件清理未完成",
                cleanup: error.localizedDescription, path: url.path)
        }
    }

    func extractDMG(_ archive: URL, to directory: URL) throws -> URL {
        try Self.requireUnmounted(directory, manager: manager)
        try Self.removeIfPresent(directory, manager: manager)
        let mount = directory.appendingPathComponent("mount", isDirectory: true)
        try manager.createDirectory(at: mount, withIntermediateDirectories: true)
        let record = directory.appendingPathComponent(Self.mountRecordName)
        try Data(archive.path.utf8).write(to: record, options: .atomic)
        // attach 抛错也可能已经产生挂载；不猜测系统状态，不删除标记或换一个挂载点重试。
        do {
            _ = try run("/usr/bin/hdiutil", ["attach", archive.path, "-mountpoint", mount.path,
                                         "-nobrowse", "-noautoopen", "-readonly", "-quiet"])
        } catch {
            throw UpdateArchiveError.attachFailed(error.localizedDescription, mount.path)
        }
        let result: Result<URL, Error> = Result {
            let apps = try manager.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "app" }
            guard apps.count == 1, let app = apps.first else { throw AuralUpdateError.invalidArchive }
            let destination = directory.appendingPathComponent(app.lastPathComponent)
            _ = try run("/usr/bin/ditto", [app.path, destination.path])
            return destination
        }
        do { _ = try run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }
        catch {
            let extraction: String?
            switch result { case .success: extraction = nil; case .failure(let original): extraction = original.localizedDescription }
            throw UpdateArchiveError.detachFailed(extraction: extraction, detach: error.localizedDescription, mount: mount.path)
        }
        try manager.removeItem(at: record)
        return try result.get()
    }

    func extractZIP(_ archive: URL, to directory: URL) throws -> URL {
        try Self.requireUnmounted(directory, manager: manager)
        try Self.removeIfPresent(directory, manager: manager)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        let apps = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "app" }
        guard apps.count == 1, let app = apps.first else { throw AuralUpdateError.invalidArchive }
        return app
    }
}

enum UpdateArchiveError: LocalizedError {
    case retainedMount(String)
    case attachFailed(String, String)
    case detachFailed(extraction: String?, detach: String, mount: String)
    case cleanupFailed(operation: String, cleanup: String, path: String)

    var errorDescription: String? {
        switch self {
        case .retainedMount(let mount): return "更新镜像尚未确认卸载，已保留暂存目录：\(mount)"
        case .attachFailed(let error, let mount): return "挂载更新镜像失败：\(error)；已保留挂载记录：\(mount)"
        case .detachFailed(let extraction, let detach, let mount):
            let original = extraction.map { "解包失败：\($0)；" } ?? ""
            return "\(original)卸载更新镜像失败：\(detach)；已保留挂载路径：\(mount)"
        case .cleanupFailed(let operation, let cleanup, let path):
            return "\(operation)；文件清理失败：\(cleanup)；保留路径：\(path)"
        }
    }
}
