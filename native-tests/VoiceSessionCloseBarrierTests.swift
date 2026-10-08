import Foundation
import XCTest
@testable import ScribePilot

@MainActor
final class VoiceSessionCloseBarrierTests: XCTestCase {
    func testImmediateNewConversationWaitsForFinalAcknowledgementsAndEnd() async {
        let barrier = VoiceSessionCloseBarrier()
        var events = [String]()
        barrier.close {
            try? await Task.sleep(for: .milliseconds(50))
            events.append("played"); events.append("end")
        }
        await barrier.wait()
        events.append("new session")
        XCTAssertEqual(events, ["played", "end", "new session"])
    }

    func testAdditionalCloseDuringAWaitCannotBeOvertakenByAFreshLaunch() async {
        let barrier = VoiceSessionCloseBarrier()
        var events = [String]()
        barrier.close { try? await Task.sleep(for: .milliseconds(50)); events.append("first end") }
        let waiting = Task { await barrier.wait(); events.append("new session") }
        barrier.close { try? await Task.sleep(for: .milliseconds(50)); events.append("second end") }
        await waiting.value
        XCTAssertEqual(events, ["first end", "second end", "new session"])
    }
}
