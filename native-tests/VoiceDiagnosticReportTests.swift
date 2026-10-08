import Foundation
import XCTest
@testable import ScribePilot

final class VoiceDiagnosticReportTests: XCTestCase {
    func testOlderReportHasNoTransportAndNewConversationReportContainsSafeCounters() throws {
        let old = try JSONDecoder().decode(VoiceDiagnosticReport.self, from: JSONEncoder().encode(report()))
        XCTAssertNil(old.transport)
        var value = VoiceDiagnosticReport(request_id: UUID().uuidString, kind: .voiceSession, build: "151",
            watch_os: "26.6", completed: false, route_changes: 0, interruptions: 0, media_resets: 0, results: old.results)
        value.transport = VoiceTransportDiagnostic(endReason: .uploadBacklog, uploadedBytes: 9600,
            uploadRequests: 1, pendingUploadBytes: 96000, peakUploadBytes: 96000, lastUploadMs: 600,
            maxUploadMs: 600, receivedAudioBytes: 48000, playbackFrames: 4800, peakPlaybackFrames: 9600)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(VoiceDiagnosticReport.self, from: data)
        XCTAssertEqual(decoded.kind, .voiceSession)
        XCTAssertEqual(decoded.transport?.endReason, .uploadBacklog)
        XCTAssertEqual(decoded.transport?.maxUploadMs, 600)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("transcript"))
        XCTAssertNil(decoded.transport?.replyPlayback)
        value.transport?.sessionID = UUID().uuidString
        value.transport?.replyPlayback = VoiceReplyPlaybackDiagnostic(scheduledFrames: 9600, completedFrames: 4800, completedItems: 1)
        let withPlayback = try JSONDecoder().decode(VoiceDiagnosticReport.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(withPlayback.transport?.replyPlayback?.completedFrames, 4800)
    }

    private func report() -> VoiceDiagnosticReport {
        var result = VoiceAudioDiagnosticResult(phase: .production)
        result.inputFrames = 1104; result.peakLevel = 0.4
        return VoiceDiagnosticReport(request_id: UUID().uuidString, kind: .voiceStartup, build: "150",
            watch_os: "26.6", completed: false, route_changes: 0, interruptions: 0, media_resets: 0, results: [result])
    }

    func testReportRoundTripContainsCountersAndNoLocalLevelsOrCredentialFields() throws {
        let value = report(); let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(VoiceDiagnosticReport.self, from: data)
        XCTAssertEqual(decoded.results.first?.inputFrames, 1104)
        XCTAssertEqual(decoded.results.first?.peakLevel, 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["peakLevel", "token", "owner_id", "transcript", "portName", "device_id"] {
            XCTAssertFalse(text.contains(forbidden))
        }
    }

    func testLostAckRetryAndFeedbackStayOrderedUntilEachRevisionIsAcknowledged() {
        var original = report(); original = VoiceDiagnosticReport(request_id: original.request_id, kind: .audioTest,
            build: "150", watch_os: "26.6", completed: false, route_changes: 0, interruptions: 0,
            media_resets: 0, results: original.results)
        var feedback = original; feedback.revision = 2; feedback.speaker_heard = true
        var outbox = VoiceDiagnosticOutbox(); outbox.enqueue(original, owner: "alice")
        outbox.enqueue(original, owner: "alice"); outbox.enqueue(feedback, owner: "alice")
        XCTAssertEqual(outbox.entries.map { $0.report.revision }, [1, 2])
        outbox.acknowledge(VoiceDiagnosticReceipt(version: 1, id: original.request_id, revision: 1), owner: "bobby")
        XCTAssertEqual(outbox.entries.count, 2)
        outbox.acknowledge(VoiceDiagnosticReceipt(version: 1, id: original.request_id, revision: 1), owner: "alice")
        XCTAssertEqual(outbox.entries.map { $0.report.revision }, [2])
        outbox.acknowledge(VoiceDiagnosticReceipt(version: 1, id: original.request_id, revision: 2), owner: "alice")
        XCTAssertTrue(outbox.entries.isEmpty)
    }

    func testAccountSwitchDropsOldReportsAndReceiptMustMatchVersionAndRequest() {
        let original = report()
        var outbox = VoiceDiagnosticOutbox(); outbox.enqueue(original, owner: "alice")
        outbox.accountChanged("bobby"); XCTAssertTrue(outbox.entries.isEmpty)
        outbox.enqueue(report(), owner: "bobby"); outbox.accountChanged(nil); XCTAssertTrue(outbox.entries.isEmpty)
        XCTAssertFalse(VoiceDiagnosticReceipt(version: 2, id: original.request_id, revision: 1).accepts(original))
        XCTAssertFalse(VoiceDiagnosticReceipt(version: 1, id: UUID().uuidString, revision: 1).accepts(original))
    }

    func testOutboxBoundsWholeReportsWithoutOrphaningFeedback() {
        var outbox = VoiceDiagnosticOutbox()
        for _ in 0..<12 {
            let original = report(); outbox.enqueue(original, owner: "alice")
            var feedback = original; feedback.revision = 2; outbox.enqueue(feedback, owner: "alice")
        }
        XCTAssertEqual(Set(outbox.entries.map { $0.report.request_id }).count, 10)
        XCTAssertEqual(outbox.entries.count, 20)
        XCTAssertEqual(outbox.entries.first?.report.revision, 1)
    }
}
