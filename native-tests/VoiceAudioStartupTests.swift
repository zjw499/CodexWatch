import Foundation
import XCTest
@testable import ScribePilot

private final class StartupPackets: @unchecked Sendable {
    var packets = [Data]()
    func append(_ data: Data?) { if let data { packets.append(data) } }
}

final class VoiceAudioStartupTests: XCTestCase {
    func testShortPhysicalCaptureIsNotDeclaredReadyOrAConverterError() {
        let short = VoiceCaptureStatistics(inputFrames: 1104, outputFrames: 552,
                                          drainedFrames: 1104, pendingFrames: 552)
        XCTAssertEqual(VoiceAudioStartupGuard.decide(elapsedMs: 400, attempt: 1,
            engineRunning: true, configurationChanged: false, statistics: short), .wait)
        XCTAssertEqual(VoiceAudioStartupGuard.decide(elapsedMs: 5000, attempt: 1,
            engineRunning: true, configurationChanged: false, statistics: short), .failed)
        XCTAssertTrue(short.startupFailure?.contains("MIC-02") == true)
        XCTAssertFalse(short.startupFailure?.contains("conversion failed") == true)
    }

    func testNegotiatingOrStoppedEngineHasOnlyTwoStartupRebuilds() {
        for running in [true, false] {
            XCTAssertEqual(VoiceAudioStartupGuard.decide(elapsedMs: 250, attempt: 1,
                engineRunning: running, configurationChanged: true, statistics: VoiceCaptureStatistics()), .wait)
            for attempt in 1...3 {
                XCTAssertEqual(VoiceAudioStartupGuard.decide(elapsedMs: 350, attempt: attempt,
                    engineRunning: running, configurationChanged: true, statistics: VoiceCaptureStatistics()),
                    attempt < 3 ? .rebuild : .failed)
            }
        }
        XCTAssertEqual(VoiceAudioStartupGuard.decide(elapsedMs: 1000, attemptElapsedMs: 50, attempt: 2,
            engineRunning: false, configurationChanged: true, statistics: VoiceCaptureStatistics()), .wait)
    }

    func testFaultsFailWithoutRebuildingAndReadyRequiresRunningAudioBatches() {
        for fault in [VoiceCaptureStatistics(receiverFailure: 1), VoiceCaptureStatistics(conversionErrors: 1)] {
            XCTAssertEqual(VoiceAudioStartupGuard.decide(elapsedMs: 350, attempt: 1,
                engineRunning: true, configurationChanged: true, statistics: fault), .failed)
        }
        let ready = VoiceCaptureStatistics(inputFrames: 9600, outputFrames: 4800, batches: 1)
        XCTAssertEqual(VoiceAudioStartupGuard.decide(elapsedMs: 250, attempt: 1,
            engineRunning: true, configurationChanged: false, statistics: ready), .ready)
        XCTAssertNotEqual(VoiceAudioStartupGuard.decide(elapsedMs: 250, attempt: 1,
            engineRunning: false, configurationChanged: false, statistics: ready), .ready)
    }

    func testOnlyCommittedAttemptDeliversBufferedPacketsInOrderAndStopDropsLateCallbacks() {
        let result = StartupPackets()
        let abandoned = VoiceAudioStartupDelivery { result.append($0) }
        abandoned.receive(Data([1])); abandoned.stop(); abandoned.commit(); abandoned.receive(Data([2]))
        XCTAssertTrue(result.packets.isEmpty)
        let current = VoiceAudioStartupDelivery { result.append($0) }
        current.receive(Data([3])); current.receive(Data([4]))
        XCTAssertTrue(result.packets.isEmpty)
        current.commit(); current.commit(); current.receive(Data([5])); current.stop(); current.receive(Data([6]))
        XCTAssertEqual(result.packets, [Data([3]), Data([4]), Data([5])])
    }
}
