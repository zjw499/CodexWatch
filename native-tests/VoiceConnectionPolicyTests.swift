import Foundation
import XCTest
@testable import ScribePilot

final class VoiceConnectionPolicyTests: XCTestCase {
    func testLostControlAckDoesNotEndAConversationWhoseAudioStillFlows() {
        let failures: [Error] = [URLError(.timedOut), URLError(.networkConnectionLost), VoiceError.status(503)]
        for error in failures {
            XCTAssertFalse(VoiceConnectionPolicy.endAfterControlFailure(error, secondsSinceContact: 1.7))
            XCTAssertTrue(VoiceConnectionPolicy.endAfterControlFailure(error, secondsSinceContact: 10))
        }
    }
    func testExpiredCredentialsAndEndedSessionsStopDespiteHealthyRecentAudio() {
        for code in [401, 404, 409, 410, 422] {
            XCTAssertTrue(VoiceConnectionPolicy.endAfterControlFailure(VoiceError.status(code), secondsSinceContact: 0))
        }
    }
}
