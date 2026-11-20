import Foundation
import AuxmoCore

/// 安全静音只负责已存在会话的状态下发和发现计时器；不创建会话，也不改变用户的逐应用意图。
@MainActor
final class GlobalSafetyMuteController {
    private var refreshTimer: Timer?

    /// 先处理已有会话，再由调用方协调新会话。失败通过回调交还模型记录，不吞掉 HAL 错误。
    func apply(enabled: Bool,
               sessions: [String: any ApplicationAudioSession],
               states: [String: ApplicationMixState],
               keepsMixing: (String, ApplicationMixState) -> Bool,
               recordError: (String, String) -> Void) {
        for (key, session) in sessions {
            guard let state = states[key] else { continue }
            if session.mode == .mixing {
                if enabled {
                    session.setMuted(true)
                } else if keepsMixing(key, state) {
                    // 不再保留 mixing 的会话由调用方释放；这里不能先解除来源静音。
                    session.setMuted(state.muted)
                }
            } else {
                do { try session.setSafetyMute(enabled) }
                catch { recordError(key, "\(session.group.label)：\(error.localizedDescription)") }
            }
        }
    }

    /// 所有 mixing 会话复用同一入口，避免创建或切换设备时漏下全局静音。
    func applyPlaybackState(session: any ApplicationAudioSession, state: ApplicationMixState,
                            effect: AppAudioEffectSettings?, enabled: Bool) throws {
        try session.setGain(state.gain)
        session.setMuted(state.effectiveMuted(globalSafetyMute: enabled))
        session.setEffect(effect)
    }

    /// 只控制定时器生命周期；是否仍允许刷新由模型在每次回调时确认。
    func setRefreshActive(_ active: Bool, tick: @escaping @MainActor () -> Void) {
        stopRefresh()
        guard active else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    deinit { refreshTimer?.invalidate() }
}
