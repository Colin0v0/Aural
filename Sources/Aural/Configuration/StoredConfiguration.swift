import Foundation

/// 每份配置独立持有读取资格和错误。未知数据不能用空集合覆盖，成功写入也不能清除别的配置错误。
@MainActor
final class StoredConfiguration<Value> {
    private let read: () throws -> Value
    private let write: (Value) throws -> Void
    private(set) var value: Value?
    private(set) var error: String?
    var willChange: () -> Void = {}
    var errorDidChange: (String?) -> Void = { _ in }
    var available: Bool { value != nil }

    init(read: @escaping () throws -> Value, write: @escaping (Value) throws -> Void) {
        self.read = read
        self.write = write
        reload()
    }

    @discardableResult
    func reload() -> Bool {
        willChange()
        do {
            value = try read()
            setError(nil)
            return true
        } catch {
            value = nil
            setError(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func save(_ next: Value) -> Bool {
        // 只有明确读到完整配置后才允许覆盖；读取失败时保留磁盘原记录。
        guard available else { return false }
        willChange()
        do {
            try write(next)
            value = next
            setError(nil)
            return true
        } catch {
            setError(error.localizedDescription)
            return false
        }
    }

    private func setError(_ message: String?) {
        guard message != error else { return }
        error = message
        errorDidChange(message)
    }
}
