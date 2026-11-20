import Foundation
import AuxmoCore

/// 输出控制不保存设备句柄，不拥有资源；每次操作使用协调器当前确认的事实。
extension AppModel {
    func selectOutput(_ id: UInt32) {
        guard let target = audio?.outputs.first(where: { $0.id == id }), !target.isAggregate else {
            operationError = "请选择真实输出设备"; return
        }
        requestOutput(.single(target.uid))
    }

    /// 返回值只表示已经确认，不把等待中的请求冒充成功；视图直接观察阶段，不用 Bool 回滚勾选。
    @discardableResult
    func startSimultaneousOutput(_ outputUIDs: [String]) -> Bool {
        requestOutput(.simultaneous(outputUIDs))
        return outputRouting.phase == .confirmed
    }

    @discardableResult
    func updateSimultaneousOutput(_ outputUIDs: [String]) -> Bool {
        startSimultaneousOutput(outputUIDs)
    }

    func toggleSimultaneousMember(_ uid: String) {
        // 连点基于协调器最后的意图计算，而非视图里另存的旧勾选。
        let base: [String]
        if let queued = outputRouting.queued { base = queued.memberUIDs }
        else if outputRouting.phase.isBusy, let desired = outputRouting.desired { base = desired.memberUIDs }
        else if outputRouting.isSimultaneous { base = outputRouting.selectedMemberUIDs }
        else { base = [] }
        guard base != [uid] else { return }
        var next = base
        if next.contains(uid) { next.removeAll { $0 == uid } } else { next.append(uid) }
        requestOutput(.simultaneous(next))
    }

    func dismissSimultaneousOutputError() { routing.dismissError(); refresh() }

    func stopSimultaneousOutput() {
        guard !isShutdown, !isShuttingDown else { return }
        routing.stop(at: routingNow); refresh()
    }

    /// 这些状态只来自用户在本界面发起的路由切换。
    /// 先把 APP 绑定迁移到新输出，再刷新，不能把主动切换误报成外部设备变化。
    func setOutputVolume(_ value: Float, on id: UInt32) {
        guard audio?.outputs.contains(where: { $0.id == id }) == true else {
            operationError = "所选输出设备已断开，请刷新。"; return
        }
        do { try SystemAudio.setVolume(value, on: id); operationError = nil }
        catch { operationError = error.localizedDescription }
        refreshAudio()
    }

    func setOutputMuted(_ muted: Bool, on id: UInt32) {
        guard audio?.outputs.contains(where: { $0.id == id }) == true else {
            operationError = "所选输出设备已断开，请刷新。"; return
        }
        do { try outputHardware.setMute(muted, id); operationError = nil }
        catch { operationError = error.localizedDescription }
        refreshAudio()
    }

    private var simultaneousOutputs: [AudioOutput] {
        guard let confirmed = outputRouting.confirmed, confirmed.intent.isSimultaneous else { return [] }
        if let aggregate = confirmed.aggregate { return aggregate.outputs }
        return [confirmed.output]
    }

    /// 统一音量只在所有成员都能写出时才执行，避免只改动其中一台造成无声或突响。
    func setSimultaneousOutputVolume(_ value: Float) {
        let outputs = simultaneousOutputs
        guard !outputs.isEmpty else { return }
        let controlStates = outputs.map { audio?.controls[$0.id] }
        let allWritable = controlStates.allSatisfy { state in
            guard case .available(let volume, _) = state else { return false }
            return volume.scalar != nil && volume.writable
        }
        guard allWritable else {
            operationError = "多设备输出中的设备不支持统一音量，请分别调节成员设备"
            return
        }
        do {
            for output in outputs { try SystemAudio.setVolume(value, on: output.id) }
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
        refreshAudio()
    }

    /// 静音同样要求所有成员具备可写控制，不能把部分成功说成整体静音。
    func setSimultaneousOutputMuted(_ muted: Bool) {
        let outputs = simultaneousOutputs
        guard !outputs.isEmpty else { return }
        let controlStates = outputs.map { audio?.controls[$0.id] }
        let allWritable = controlStates.allSatisfy { state in
            guard case .available(_, let mute) = state else { return false }
            return mute.writable
        }
        guard allWritable else {
            operationError = "多设备输出中的设备不支持统一静音，请分别调节成员设备"
            return
        }
        do {
            for output in outputs { try outputHardware.setMute(muted, output.id) }
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
        refreshAudio()
    }

}
