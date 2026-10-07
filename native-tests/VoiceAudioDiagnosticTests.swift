import Foundation
import XCTest
@testable import ScribePilot

final class VoiceAudioDiagnosticTests: XCTestCase {
    private func report(working: Set<VoiceAudioDiagnosticPhase>) -> [VoiceAudioDiagnosticResult] {
        VoiceAudioDiagnosticPhase.allCases.map { phase in
            var result = VoiceAudioDiagnosticResult(phase: phase)
            result.before.engineRunning = true; result.after.engineRunning = true
            if working.contains(phase) {
                result.inputFrames = 144000; result.convertedFrames = 72000
                result.batches = 15; result.peakLevel = 0.3
            }
            return result
        }
    }

    func testIncompleteOrDuplicateRunsDoNotClaimAConfigurationCause() {
        let full = report(working: [.meeting])
        XCTAssertEqual(VoiceAudioDiagnosticFinding.evaluate(Array(full.dropLast())), .incomplete)
        var duplicate = full; duplicate[1] = full[0]
        XCTAssertEqual(VoiceAudioDiagnosticFinding.evaluate(duplicate), .incomplete)
        XCTAssertEqual(VoiceAudioDiagnosticFinding.evaluate([]), .incomplete)
    }

    func testHardwareComparisonIsolatesEachAudioConfigurationDifference() {
        let cases: [(Set<VoiceAudioDiagnosticPhase>, VoiceAudioDiagnosticFinding)] = [
            ([], .baseline), ([.meeting], .duplex),
            ([.meeting, .duplex], .voiceMode),
            ([.meeting, .duplex, .voiceMode], .echoProcessing),
            ([.meeting, .duplex, .voiceMode, .echoTap], .receiver),
            ([.meeting, .standardActivation], .activation),
            ([.meeting, .activeOutput], .outputClock),
            ([.production], .currentWorks),
            ([.currentVoice], .productionOnly)
        ]
        for (working, expected) in cases {
            XCTAssertEqual(VoiceAudioDiagnosticFinding.evaluate(report(working: working)), expected)
        }
    }

    func testFramesWithoutBatchesRemainAConversionFailure() {
        var results = report(working: [.meeting, .activeOutput])
        let index = VoiceAudioDiagnosticPhase.allCases.firstIndex(of: .production)!
        results[index].inputFrames = 144000
        XCTAssertEqual(VoiceAudioDiagnosticFinding.evaluate(results), .conversion)
        XCTAssertEqual(results[index].marker, "PCM")
    }

    func testReceiverFaultDoesNotCountAsSuccessfulCapture() {
        var results = report(working: [.meeting, .production])
        let index = VoiceAudioDiagnosticPhase.allCases.firstIndex(of: .production)!
        results[index].receiverFailure = 1
        XCTAssertFalse(results[index].capturedAudio)
        XCTAssertEqual(results[index].marker, "CAP")
        XCTAssertEqual(VoiceAudioDiagnosticFinding.evaluate(results), .conversion)
        results[index].receiverFailure = 0; results[index].conversionFailed = true
        XCTAssertFalse(results[index].capturedAudio)
    }

    func testStoppedEngineAndChangedSessionDoNotClaimSuccessfulVoice() {
        var results = report(working: [.meeting, .production])
        let index = VoiceAudioDiagnosticPhase.allCases.firstIndex(of: .production)!
        results[index].after.engineRunning = false
        XCTAssertEqual(VoiceAudioDiagnosticFinding.evaluate(results), .engineStopped)
        results[index].after.engineRunning = true
        results[index].before.category = "playAndRecord"; results[index].after.category = "record"
        XCTAssertEqual(VoiceAudioDiagnosticFinding.evaluate(results), .sessionChanged)
        results[index].after.category = "playAndRecord"
        results[index].after.outputPorts = ["Bluetooth HFP"]
        XCTAssertEqual(VoiceAudioDiagnosticFinding.evaluate(results), .sessionChanged)
    }

    func testSilentSamplesDoNotClaimTheMicrophoneHeardTheUser() {
        var results = report(working: [.production])
        let index = VoiceAudioDiagnosticPhase.allCases.firstIndex(of: .production)!
        results[index].peakLevel = 0
        XCTAssertEqual(VoiceAudioDiagnosticFinding.evaluate(results), .silentInput)
    }

    func testLaterWarmComparisonsCannotClaimNormalStartupSucceeded() {
        XCTAssertEqual(VoiceAudioDiagnosticPhase.allCases.first, .production)
        let laterOnly = report(working: [.meeting, .duplex, .voiceMode, .activeOutput, .standardActivation])
        XCTAssertEqual(VoiceAudioDiagnosticFinding.evaluate(laterOnly), .outputClock)
        XCTAssertFalse(VoiceAudioDiagnosticFinding.evaluate(laterOnly).message.contains("idle-output"))
        XCTAssertEqual(VoiceAudioDiagnosticFinding.evaluate(report(working: [.production, .activeOutput])), .currentWorks)
    }

    func testRenderingDoesNotClaimTheSpeakerWasAudible() {
        var result = VoiceAudioDiagnosticResult(phase: .speaker)
        result.renderedFrames = 72000
        XCTAssertEqual(result.marker, "rendered")
        XCTAssertFalse(result.capturedAudio)
        XCTAssertFalse(result.marker.contains("heard"))
    }

    func testDiagnosticFailuresShowOnlyStageAndNumericCode() {
        let secret = "private provider payload or device name"
        let failure = VoiceAudioStartupError(stage: .engine,
            underlying: NSError(domain: secret, code: -308, userInfo: [NSLocalizedDescriptionKey: secret]))
        var result = VoiceAudioDiagnosticResult(phase: .currentVoice)
        result.failedStage = failure.stage; result.nativeCode = failure.nativeCode
        XCTAssertEqual(result.failureCode, "START-01, Apple -308")
        XCTAssertFalse(result.failureCode!.contains(secret))
        XCTAssertEqual(result.marker, "error")
    }

    @MainActor
    func testReservationBlocksNewAudioUntilCancelledActivationHasFinished() throws {
        let reservation = VoiceAudioDiagnosticReservation()
        let old = try XCTUnwrap(reservation.acquire())
        // Cancelling a task does not release its reservation; only completed cleanup does.
        XCTAssertNil(reservation.acquire())
        reservation.release(UUID())
        XCTAssertTrue(reservation.isHeld)
        reservation.release(old)
        let current = try XCTUnwrap(reservation.acquire())
        reservation.release(old)
        XCTAssertTrue(reservation.isHeld, "A late callback must not release a newer activity")
        XCTAssertNil(reservation.acquire())
        reservation.release(current)
        XCTAssertFalse(reservation.isHeld)
    }
}
