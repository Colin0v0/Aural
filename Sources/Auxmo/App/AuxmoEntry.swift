import AppKit

/// 正常入口仍由 SwiftUI 管理；硬件诊断单独运行，不创建第二个 AppModel 或控制器。
@main
enum AuxmoEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose-headphones") {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.colin0v0.auxmo.app")
                .filter { $0.processIdentifier != getpid() }
            guard running.isEmpty else {
                FileHandle.standardError.write(Data("请先退出正在运行的 Auxmo，再执行耳机诊断，避免控制通道竞争。\n".utf8))
                exit(1)
            }
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task { @MainActor in await HeadphoneDiagnostic.run() }
            NSApplication.shared.run()
        } else {
            AuxmoApp.main()
        }
    }
}
