import Foundation
import AuxmoCore

/// 只读展示投影；不创建会话、不触碰配置持久化。
extension AppModel {
    var selectedOutput: AudioOutput? {
        guard let audio else { return nil }
        return audio.outputs.first { $0.id == audio.selectedID }
    }

    /// 菜单栏“跟随当前输出”只认系统当前实际输出，不借用另一副已连接耳机。
    var menuBarBatteryCurrentOutput: MenuBarBatteryCurrentOutput {
        guard let output = selectedOutput else { return .unsupported }
        if output.isAuxmoMultiOutput {
            guard let route = multiOutputRoute, route.uid == output.uid else { return .unsupported }
            return .multiOutput(memberUIDs: route.outputs.map(\.uid))
        }
        guard !output.isAggregate else { return .unsupported }
        return .direct(deviceUID: output.uid)
    }

    /// 菜单栏设备图标始终跟随当前系统输出，不能受菜单栏电量固定设备影响。
    func menuBarDeviceSymbol() -> String? {
        guard let output = selectedOutput else { return nil }
        return menuBarDeviceSymbol(for: output)
    }

    private func menuBarDeviceSymbol(for output: AudioOutput) -> String {
        if output.isAuxmoMultiOutput || output.isAggregate { return "rectangle.on.rectangle" }
        return output.symbol
    }

    /// 只有已经回读电量的可控耳机能进入菜单栏候选；未知值不生成占位候选。
    var menuBarBatteryCandidates: [MenuBarBatteryCandidate] {
        headphones.entries.compactMap { entry in
            guard let reading = entry.controller.state.battery, reading.hasLevel else { return nil }
            return MenuBarBatteryCandidate(deviceUID: entry.id,
                                           displayName: entry.output.name,
                                           reading: reading)
        }
    }

    func menuBarBattery(for source: MenuBarBatterySource?) -> MenuBarBatteryCandidate? {
        guard let source else { return nil }
        return MenuBarBatteryResolver.resolve(
            source: source,
            currentOutput: menuBarBatteryCurrentOutput,
            candidates: menuBarBatteryCandidates
        )
    }

}
