import XCTest
@testable import ScribePilot

final class VoiceScreenLifecycleTests: XCTestCase {
    func testWristLoweringAndDisplayDimmingKeepAnExistingConversation() {
        var screen = VoiceScreenLifecycle(isVisible: true, phase: .active, isDimmed: false)
        XCTAssertTrue(screen.canStartCapture)
        screen.isDimmed = true
        XCTAssertFalse(screen.canStartCapture)
        XCTAssertTrue(screen.canContinueCapture)
        screen.phase = .inactive
        XCTAssertTrue(screen.canContinueCapture)
        screen.isDimmed = false
        screen.phase = .active
        XCTAssertTrue(screen.canContinueCapture)
    }

    func testColdLaunchWaitsForAnAwakeForegroundScreen() {
        var screen = VoiceScreenLifecycle()
        XCTAssertFalse(screen.canStartCapture)
        screen.isVisible = true
        XCTAssertFalse(screen.canStartCapture)
        screen.phase = .active
        screen.isDimmed = true
        XCTAssertFalse(screen.canStartCapture)
        screen.isDimmed = false
        XCTAssertTrue(screen.canStartCapture)
    }

    func testDimmingDuringStartupAllowsTheSameCaptureToFinish() {
        var screen = VoiceScreenLifecycle(isVisible: true, phase: .active, isDimmed: false)
        XCTAssertTrue(screen.canStartCapture)
        screen.phase = .inactive
        screen.isDimmed = true
        XCTAssertFalse(screen.canStartCapture)
        XCTAssertTrue(screen.canContinueCapture)
    }

    func testLeavingTheAppOrDismissingTheVoiceScreenEndsCapture() {
        var screen = VoiceScreenLifecycle(isVisible: true, phase: .inactive, isDimmed: true)
        screen.phase = .background
        XCTAssertFalse(screen.canContinueCapture)
        screen.phase = .active
        screen.isVisible = false
        XCTAssertFalse(screen.canStartCapture)
        XCTAssertFalse(screen.canContinueCapture)
    }
}
