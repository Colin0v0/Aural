import AppKit
import Foundation

enum ApplicationShutdownResult: Equatable {
    case complete
    case waiting
    case failed(String)
}

/// 退出是独立事务：等待 HAL 确认不等于失败；真正失败必须得到用户决定，不能静默取消退出。
@MainActor
final class ApplicationTermination {
    private enum State {
        case idle
        case waiting(deadline: TimeInterval)
        case finished
    }
    private var state: State = .idle
    private let attempt: () -> ApplicationShutdownResult
    private let confirmUncleanExit: (String) -> Bool
    private let cancelRestart: () -> Void
    private let cancelShutdown: () -> Void
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 3, attempt: @escaping () -> ApplicationShutdownResult,
         confirmUncleanExit: @escaping (String) -> Bool, cancelRestart: @escaping () -> Void,
         cancelShutdown: @escaping () -> Void) {
        self.timeout = timeout
        self.attempt = attempt
        self.confirmUncleanExit = confirmUncleanExit
        self.cancelRestart = cancelRestart
        self.cancelShutdown = cancelShutdown
    }

    func request(at now: TimeInterval) -> NSApplication.TerminateReply {
        switch state {
        case .waiting: return .terminateLater
        case .finished: return .terminateNow
        case .idle: break
        }
        state = .waiting(deadline: now + timeout)
        guard let decision = evaluate(at: now) else { return .terminateLater }
        return decision ? .terminateNow : .terminateCancel
    }

    /// 时钟由调用方提供单调时间，反复观察不延长截止时间，也不重发销毁命令。
    func poll(at now: TimeInterval) -> Bool? {
        guard case .waiting = state else { return nil }
        return evaluate(at: now)
    }

    private func evaluate(at now: TimeInterval) -> Bool? {
        switch attempt() {
        case .complete:
            state = .finished
            return true
        case .waiting:
            guard case .waiting(let deadline) = state, now >= deadline else { return nil }
            return resolveFailure("系统未在期限内完成音频资源释放。")
        case .failed(let message):
            return resolveFailure(message)
        }
    }

    private func resolveFailure(_ message: String) -> Bool {
        // 未完整清理时不能顺带启动更新或重启 helper；强行退出也必须是用户的明确决定。
        cancelRestart()
        let shouldExit = confirmUncleanExit(message)
        if shouldExit { state = .finished }
        else { state = .idle; cancelShutdown() }
        return shouldExit
    }

    static func makeFailureAlert(_ message: String, language: AppLanguage) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("音频资源尚未完整释放", language: language)
        alert.informativeText = L10n.text(message, language: language) + "\n\n" + L10n.text(
            "仍然退出会结束 Aural 的音频处理，应用原声可能恢复，残留多输出设备可能需要手动移除。", language: language)
        alert.addButton(withTitle: L10n.text("取消", language: language))
        alert.addButton(withTitle: L10n.text("仍然退出", language: language))
        return alert
    }
}
