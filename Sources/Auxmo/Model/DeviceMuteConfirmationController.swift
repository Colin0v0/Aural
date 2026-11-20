import Foundation

/// 等待同一设备的静音读回，只观察、不重复写入；每个设备的新操作撤销旧确认。
@MainActor
final class DeviceMuteConfirmationController {
    enum Direction: Hashable { case input, output }
    struct Key: Hashable { let direction: Direction; let id: UInt32 }
    private struct Pending { let token: UUID; let task: Task<Void, Never> }
    private var tasks: [Key: Pending] = [:]

    func cancel(_ key: Key) {
        tasks.removeValue(forKey: key)?.task.cancel()
    }

    func cancelAll() {
        for pending in tasks.values { pending.task.cancel() }
        tasks.removeAll()
    }

    func start(key: Key, attempts: Int = 20, intervalNanoseconds: UInt64 = 150_000_000,
               observe: @escaping @MainActor () throws -> Bool,
               finish: @escaping @MainActor (String?) -> Void) {
        cancel(key)
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            for _ in 0..<attempts {
                do { try await Task.sleep(nanoseconds: intervalNanoseconds) }
                catch { return }
                guard let self, !Task.isCancelled, self.tasks[key]?.token == token else { return }
                do {
                    if try observe() {
                        self.tasks.removeValue(forKey: key)
                        finish(nil)
                        return
                    }
                } catch {
                    self.tasks.removeValue(forKey: key)
                    finish(error.localizedDescription)
                    return
                }
            }
            guard let self, !Task.isCancelled, self.tasks[key]?.token == token else { return }
            self.tasks.removeValue(forKey: key)
            finish("设备未在期限内确认静音变更，请刷新后检查")
        }
        tasks[key] = Pending(token: token, task: task)
    }
}
