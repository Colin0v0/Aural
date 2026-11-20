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

    /// 视图保留点击时看到的 UID，防止 ID 已被复用时误选新设备。
    func selectOutputDevice(_ output: AudioOutput) {
        guard !output.isAggregate,
              audio?.outputs.contains(where: { $0.id == output.id && $0.uid == output.uid }) == true else {
            operationError = "所选输出设备身份已变化，请刷新后重新选择"; return
        }
        do { try validateOutputControlIdentity(output) }
        catch { operationError = error.localizedDescription; refreshAudio(); return }
        requestOutput(.single(output.uid))
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
    func setOutputVolume(_ value: Float, on output: AudioOutput) {
        let id = output.id
        guard audio?.outputs.contains(where: { $0.id == id && $0.uid == output.uid }) == true else {
            operationError = "所选输出设备已断开，请刷新。"; return
        }
        do {
            try validateOutputControlIdentity(output)
            try SystemAudio.setVolume(value, on: id)
            operationError = nil
        }
        catch { operationError = error.localizedDescription }
        refreshAudio()
    }

    func setOutputMuted(_ muted: Bool, on output: AudioOutput) {
        let id = output.id
        guard audio?.outputs.contains(where: { $0.id == id && $0.uid == output.uid }) == true else {
            operationError = "所选输出设备已断开，请刷新。"; return
        }
        let key = DeviceMuteConfirmationController.Key(direction: .output, id: id)
        deviceMuteConfirmations.cancel(key)
        do {
            try validateOutputControlIdentity(output)
            try outputHardware.setMute(muted, id)
            operationError = nil
        } catch let pending as AudioDeviceMutePending where pending.deviceID == id && pending.muted == muted {
            operationError = nil
            deviceMuteConfirmations.start(key: key, observe: { [weak self] in
                guard let self, !self.isShutdown, !self.isShuttingDown else {
                    throw AudioFailure("应用正在退出")
                }
                let snapshot = try self.outputHardware.snapshot()
                guard snapshot.outputs.contains(where: { $0.id == id && $0.uid == output.uid }),
                      try self.outputHardware.isAlive(id) else {
                    throw AudioFailure("设备身份已变化或已断开，请刷新后重新操作")
                }
                guard case .available(_, let actual)? = snapshot.controls[id] else {
                    throw AudioFailure("无法读取设备静音状态")
                }
                if let error = actual.error { throw AudioFailure(error) }
                return actual.muted == muted
            }, finish: { [weak self] error in
                guard let self, !self.isShutdown, !self.isShuttingDown else { return }
                if let error { self.operationError = error }
                self.refreshAudio()
            })
        } catch { operationError = error.localizedDescription }
        refreshAudio()
    }

    /// 每次写入前复查同一 ID 和 UID，设备变化时直接拒绝，不查找替代目标。
    private func validateOutputControlIdentity(_ expected: AudioOutput) throws {
        let current = try outputHardware.snapshot()
        guard current.outputs.contains(where: { $0.id == expected.id && $0.uid == expected.uid }),
              try outputHardware.isAlive(expected.id) else {
            throw AudioFailure("设备身份已变化或已断开，请刷新后重新操作")
        }
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
        var completed: [String] = []
        for (index, output) in outputs.enumerated() {
            do {
                try validateOutputControlIdentity(output)
                try SystemAudio.setVolume(value, on: output.id)
                // 写入成功不代表读回确认；只把实际匹配的成员列为完成。
                let actual = try SystemAudio.volume(of: output.id)
                guard let scalar = actual.scalar, abs(scalar - value) <= 0.01 else {
                    throw AudioFailure("设备尚未确认音量")
                }
                completed.append(output.name)
            } catch {
                let remaining = outputs[(index + 1)...].map(\.name)
                operationError = "多设备音量未全部确认。已确认：\(completed.joined(separator: "、"))；失败或未确认：\(output.name)（\(error.localizedDescription)）；未操作：\(remaining.joined(separator: "、"))"
                refreshAudio()
                return
            }
        }
        operationError = nil
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
        var completed: [String] = []
        for (index, output) in outputs.enumerated() {
            // 用户的新组操作取代同一设备上一轮尚未结束的手动读回确认。
            deviceMuteConfirmations.cancel(.init(direction: .output, id: output.id))
            do {
                try validateOutputControlIdentity(output)
                try outputHardware.setMute(muted, output.id)
                completed.append(output.name)
            } catch {
                let remaining = outputs[(index + 1)...].map(\.name)
                operationError = "多设备静音未全部确认。已确认：\(completed.joined(separator: "、"))；失败或待确认：\(output.name)（\(error.localizedDescription)）；未操作：\(remaining.joined(separator: "、"))"
                refreshAudio()
                return
            }
        }
        operationError = nil
        refreshAudio()
    }

}
