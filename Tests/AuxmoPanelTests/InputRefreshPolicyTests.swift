import Testing
@testable import Auxmo

struct InputRefreshPolicyTests {
    /// 隐藏面板和输出页都不能让后台轮询读取麦克风设备。
    @Test func inputRefreshRequiresVisibleMicrophoneSurface() {
        #expect(!InputRefreshPolicy.isNeeded(monitorsSystem: true,
                                             selectedSurfaces: [],
                                             visibleSurfaces: [.popover]))
        #expect(!InputRefreshPolicy.isNeeded(monitorsSystem: true,
                                             selectedSurfaces: [.popover],
                                             visibleSurfaces: []))
        #expect(!InputRefreshPolicy.isNeeded(monitorsSystem: true,
                                             selectedSurfaces: [.popover],
                                             visibleSurfaces: [.controlWindow]))
        #expect(InputRefreshPolicy.isNeeded(monitorsSystem: true,
                                            selectedSurfaces: [.popover],
                                            visibleSurfaces: [.popover]))
        #expect(InputRefreshPolicy.isNeeded(monitorsSystem: true,
                                            selectedSurfaces: [.popover, .controlWindow],
                                            visibleSurfaces: [.controlWindow]))
        #expect(!InputRefreshPolicy.isNeeded(monitorsSystem: false,
                                             selectedSurfaces: [.popover],
                                             visibleSurfaces: [.popover]))
    }
}
