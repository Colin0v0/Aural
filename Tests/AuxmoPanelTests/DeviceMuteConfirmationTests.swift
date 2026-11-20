import Foundation
import Testing
@testable import Auxmo

@MainActor
struct DeviceMuteConfirmationTests {
    @Test func delayedReadbackConfirmsWithoutRepeatedWrites() async throws {
        let controller = DeviceMuteConfirmationController()
        let key = DeviceMuteConfirmationController.Key(direction: .output, id: 1)
        var reads = 0
        var result: String??
        controller.start(key: key, attempts: 4, intervalNanoseconds: 1_000_000, observe: {
            reads += 1
            return reads == 2
        }, finish: { result = .some($0) })
        for _ in 0..<100 where result == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(reads == 2)
        #expect(result != nil && result! == nil)
    }

    @Test func timeoutIsReportedAndNewRequestSupersedesOldOne() async throws {
        let controller = DeviceMuteConfirmationController()
        let key = DeviceMuteConfirmationController.Key(direction: .input, id: 2)
        var oldFinished = false
        var result: String??
        controller.start(key: key, attempts: 5, intervalNanoseconds: 1_000_000,
                         observe: { false }, finish: { _ in oldFinished = true })
        controller.start(key: key, attempts: 2, intervalNanoseconds: 1_000_000,
                         observe: { false }, finish: { result = .some($0) })
        for _ in 0..<100 where result == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(!oldFinished)
        #expect(result != nil && result! != nil)
    }
}
