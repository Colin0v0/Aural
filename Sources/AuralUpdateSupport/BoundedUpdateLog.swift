import Darwin
import Foundation

/// App 和 helper 共用的有界日志。独立锁文件在轮转时保持不变，避免两个进程同时覆盖日志。
public struct BoundedUpdateLog: Sendable {
    public let directory: URL
    public let maximumBytes: Int

    public init(directory: URL, maximumBytes: Int = 1_048_576) {
        precondition(maximumBytes > 0)
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    public func append(_ message: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("update.log.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posixFailure("打开日志锁", path: lockURL.path) }
        guard flock(fd, LOCK_EX) == 0 else {
            let failure = posixFailure("取得日志锁", path: lockURL.path)
            if close(fd) != 0 { report(posixFailure("关闭日志锁", path: lockURL.path)) }
            throw failure
        }
        // 日志写入与释放锁的错误分别保留；不更换文件位置，也不让日志失败中断已授权的安装。
        let result: Result<Void, Error> = Result { try appendLocked(message) }
        let unlockError: Error? = flock(fd, LOCK_UN) == 0 ? nil : posixFailure("释放日志锁", path: lockURL.path)
        let closeError: Error? = close(fd) == 0 ? nil : posixFailure("关闭日志锁", path: lockURL.path)
        if let unlockError { report(unlockError) }
        if let closeError { report(closeError) }
        try result.get()
        if let unlockError { throw unlockError }
        if let closeError { throw closeError }
    }

    private func appendLocked(_ message: String) throws {
        let url = directory.appendingPathComponent("update.log")
        try requireRegularFile(url)
        try requireRegularFile(directory.appendingPathComponent("update.log.1"))
        let incoming = boundedUTF8Tail(Data(message.utf8))
        guard FileManager.default.fileExists(atPath: url.path) else {
            try incoming.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forReadingFrom: url)
        let previous: Data?
        do {
            let size = try handle.seekToEnd()
            if size + UInt64(incoming.count) > UInt64(maximumBytes) {
                try handle.seek(toOffset: size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0)
                previous = boundedUTF8Tail(try handle.read(upToCount: maximumBytes) ?? Data())
            } else { previous = nil }
            try handle.close()
        } catch {
            do { try handle.close() } catch { report(error) }
            throw error
        }
        if let previous {
            try previous.write(to: directory.appendingPathComponent("update.log.1"), options: .atomic)
            try incoming.write(to: url, options: .atomic)
        } else {
            let writer = try FileHandle(forWritingTo: url)
            do { try writer.seekToEnd(); try writer.write(contentsOf: incoming); try writer.close() }
            catch {
                do { try writer.close() } catch { report(error) }
                throw error
            }
        }
    }

    /// 单条超长信息和旧版遗留的大文件只保留末尾，切点跳过 UTF-8 续字节，保证汉字不被截坏。
    private func boundedUTF8Tail(_ data: Data) -> Data {
        var tail = data.suffix(maximumBytes)
        while let first = tail.first, first & 0xC0 == 0x80 { tail = tail.dropFirst() }
        return Data(tail)
    }

    private func requireRegularFile(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError,
                              userInfo: [NSLocalizedDescriptionKey: "日志路径不是普通文件：\(url.path)"])
            }
        } else if errno != ENOENT { throw posixFailure("读取日志文件属性", path: url.path) }
    }

    private func posixFailure(_ operation: String, path: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "\(operation)失败（\(code)）：\(path)"])
    }

    private func report(_ error: Error) {
        FileHandle.standardError.write(Data("更新日志失败：\(error.localizedDescription)\n".utf8))
    }

    public static func record(_ message: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Aural", isDirectory: true)
        let log = BoundedUpdateLog(directory: directory)
        do { try log.append(message) } catch { log.report(error) }
    }
}
