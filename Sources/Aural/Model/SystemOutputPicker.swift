import AppKit
import CoreGraphics

/// 用户正在系统界面选择输出时，默认变化应被视为明确意图，而不是 AirPods 抢占。
enum SystemOutputPicker {
    static func isInUse() -> Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" {
            return true
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let controlCenterPIDs = Set(NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.controlcenter"
        ).map(\.processIdentifier))
        let menuBarLayer = Int(CGWindowLevelForKey(.statusWindow))
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  controlCenterPIDs.contains(pid) else { return false }
            return (window[kCGWindowLayer as String] as? Int) != menuBarLayer
        }
    }
}
