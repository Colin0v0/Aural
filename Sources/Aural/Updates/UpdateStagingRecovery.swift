import Darwin
import Foundation

/// 检查结果是一次性凭据；清理前重新读完整系统清单及同一标记，不能拿旧结果授权删除。
struct UpdateStagingInspection: Equatable, Sendable {
    let stage: URL
    let marker: Data?
    let markerInode: UInt64?
    var canRemoveStaleMarker: Bool { marker != nil }
}

struct UpdateStagingRecovery {
    var mountedImages: () throws -> Data = Self.readMountedImages
    var manager: FileManager = .default

    func inspect(_ stage: URL) throws -> UpdateStagingInspection {
        let backup = stage.appendingPathComponent("old", isDirectory: true)
        guard !manager.fileExists(atPath: backup.path) else { throw AuralUpdateError.recoveryBackupExists(backup.path) }
        let marker = stage.appendingPathComponent("extracted", isDirectory: true)
            .appendingPathComponent(UpdateArchiveExtractor.mountRecordName)
        guard manager.fileExists(atPath: marker.path) else {
            return UpdateStagingInspection(stage: stage, marker: nil, markerInode: nil)
        }
        var info = stat()
        guard lstat(marker.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0, info.st_size <= 16_384 else {
            throw UpdateRecoveryError.invalidRecord(marker.path)
        }
        let data = try Data(contentsOf: marker)
        guard let image = String(data: data, encoding: .utf8), image.hasPrefix("/") else {
            throw UpdateRecoveryError.invalidRecord(marker.path)
        }
        // 完整清单解析失败时不能推断为零挂载；未挂载的磁盘实体仍按已连接镜像处理。
        try confirmNoAttachedImage(try mountedImages(), stage: stage, recordedImage: URL(fileURLWithPath: image))
        return UpdateStagingInspection(stage: stage, marker: data, markerInode: UInt64(info.st_ino))
    }

    func removeStaleMarker(_ inspection: UpdateStagingInspection) throws {
        guard inspection.canRemoveStaleMarker else { return }
        let current = try inspect(inspection.stage)
        guard current == inspection else { throw UpdateRecoveryError.changedSinceInspection }
        let marker = inspection.stage.appendingPathComponent("extracted", isDirectory: true)
            .appendingPathComponent(UpdateArchiveExtractor.mountRecordName)
        // 只删除已证明失效的挂载标记。旧应用备份、payload 和其他暂存文件一律不在这里删除。
        try manager.removeItem(at: marker)
    }

    private func confirmNoAttachedImage(_ data: Data, stage: URL, recordedImage: URL) throws {
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = root as? [String: Any], let images = dictionary["images"] as? [[String: Any]] else {
            throw UpdateRecoveryError.incompleteMountInventory
        }
        for image in images {
            guard let path = image["image-path"] as? String, path.hasPrefix("/"),
                  let entities = image["system-entities"] as? [[String: Any]] else {
                throw UpdateRecoveryError.incompleteMountInventory
            }
            if within(URL(fileURLWithPath: path), stage) || normalized(URL(fileURLWithPath: path)) == normalized(recordedImage) {
                throw UpdateRecoveryError.imageStillAttached(path)
            }
            for entity in entities {
                if let value = entity["mount-point"] {
                    guard let mount = value as? String, mount.hasPrefix("/") else { throw UpdateRecoveryError.incompleteMountInventory }
                    if within(URL(fileURLWithPath: mount), stage) { throw UpdateRecoveryError.imageStillAttached(mount) }
                }
            }
        }
    }

    private func normalized(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    private func within(_ url: URL, _ directory: URL) -> Bool {
        let path = normalized(url), root = normalized(directory)
        return path == root || path.hasPrefix(root + "/")
    }

    private static func readMountedImages() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let output = Pipe(); process.standardOutput = output
        // stderr 保持可见但不混入 plist；先排空 stdout，再等待退出，避免大清单填满管道。
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateRecoveryError.inventoryCommandFailed(process.terminationStatus) }
        return data
    }
}

enum UpdateRecoveryError: LocalizedError {
    case busy
    case invalidRecord(String)
    case incompleteMountInventory
    case inventoryCommandFailed(Int32)
    case imageStillAttached(String)
    case changedSinceInspection

    var errorDescription: String? {
        switch self {
        case .busy: return "更新操作正在进行，请完成或取消后再检查残留"
        case .invalidRecord(let path): return "更新挂载记录无法确认，已保留：\(path)"
        case .incompleteMountInventory: return "无法读取完整镜像清单，未清理任何文件"
        case .inventoryCommandFailed(let code): return "读取镜像清单失败（退出码 \(code)），未清理任何文件"
        case .imageStillAttached(let path): return "更新镜像仍连接，请先在 Finder 中推出，再重新检查：\(path)"
        case .changedSinceInspection: return "更新现场已变化，请重新检查；未删除任何文件"
        }
    }
}
