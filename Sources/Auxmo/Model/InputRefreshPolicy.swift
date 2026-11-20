import Foundation

/// 输入设备枚举只服务当前可见的麦克风页，隐藏面板或输出页不触发 HAL 扫描。
enum InputRefreshPolicy {
    static func isNeeded(monitorsSystem: Bool,
                         selectedSurfaces: Set<MeterSurface>,
                         visibleSurfaces: Set<MeterSurface>) -> Bool {
        monitorsSystem && !selectedSurfaces.isDisjoint(with: visibleSurfaces)
    }
}

