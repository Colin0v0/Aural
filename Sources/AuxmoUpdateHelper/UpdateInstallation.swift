import Foundation

/// 安装和恢复使用同一套文件操作；测试只注入边界，不启动真实应用或修改系统安全标记。
struct UpdateFileOperations {
    var exists: (URL) -> Bool
    var move: (URL, URL) throws -> Void
    var remove: (URL) throws -> Void

    static var live: Self {
        let manager = FileManager.default
        return Self(exists: { manager.fileExists(atPath: $0.path) },
                    move: { try manager.moveItem(at: $0, to: $1) },
                    remove: { try manager.removeItem(at: $0) })
    }
}

enum UpdateInstallationError: LocalizedError {
    case missingPayload
    case recoveryBackupExists(String)
    case installationFailedRestored(String)
    case rollbackFailed(installation: String, rollback: String, backup: String)
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPayload: return "暂存的新版本不存在"
        case .recoveryBackupExists(let path): return "存在待恢复的旧版本备份，已停止安装：\(path)"
        case .installationFailedRestored(let original): return "新版本安装失败：\(original)；旧版本已恢复到原路径"
        case .rollbackFailed(let installation, let rollback, let backup):
            return "新版本安装失败：\(installation)；恢复旧版本也失败：\(rollback)；保留的旧版本备份：\(backup)"
        case .cleanupFailed(let detail): return "新版本启动命令已成功，但暂存清理失败：\(detail)"
        }
    }
}

struct UpdateInstallation {
    let files: UpdateFileOperations

    init(files: UpdateFileOperations = .live) { self.files = files }

    func perform(app: URL, stage: URL, launch: (URL) throws -> Void) throws {
        let payload = stage.appendingPathComponent("payload", isDirectory: true)
        let backup = stage.appendingPathComponent("old", isDirectory: true)
        // 旧备份可能是上一次恢复失败留下的唯一副本，绝不在新一轮安装中自动删除。
        guard !files.exists(backup) else { throw UpdateInstallationError.recoveryBackupExists(backup.path) }
        guard files.exists(payload) else { throw UpdateInstallationError.missingPayload }
        try files.move(app, backup)
        do {
            try files.move(payload, app)
            // 保留下载包原有的隔离属性。签名完整性不是公证，不运行 xattr 绕过 macOS 的决定。
            try launch(app)
        } catch {
            let installationError = error
            do {
                // 替换可能只完成一部分；删除失败必须停止恢复并保留备份，不冒充回滚成功。
                if files.exists(app) { try files.remove(app) }
                try files.move(backup, app)
            } catch {
                throw UpdateInstallationError.rollbackFailed(installation: installationError.localizedDescription,
                    rollback: error.localizedDescription, backup: backup.path)
            }
            throw UpdateInstallationError.installationFailedRestored(installationError.localizedDescription)
        }
        // 清理失败与安装失败分开：新版本已经启动时，不再因清理错误回滚到旧版本。
        do {
            try files.remove(backup)
            try files.remove(stage)
        } catch {
            throw UpdateInstallationError.cleanupFailed(error.localizedDescription)
        }
    }
}
