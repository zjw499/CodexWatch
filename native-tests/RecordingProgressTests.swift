import Foundation
import XCTest
@testable import ScribePilot

final class RecordingProgressTests: XCTestCase {
    func testUploadedAudioDoesNotClaimCompletedTranscription() {
        var item = QueuedRecording(id: "progress", title: "Saved", source: "Apple Watch", createdAt: Date(), state: .processing)
        item.progress = 1
        XCTAssertEqual(item.processingStatus, "Uploading audio")
        item.serverUploaded = true
        XCTAssertEqual(item.processingStatus, "Transcribing on PC")
        XCTAssertNil(item.processingFraction)
        item.duration = 600; item.transcribedSeconds = 120
        XCTAssertEqual(item.processingFraction, 0.2)
        XCTAssertEqual(item.processingDetail, "02:00 of 10:00 transcribed")
        item.transcribedSeconds = 600
        XCTAssertEqual(item.processingFraction, 0.99)
        item.transcriptionComplete = true; item.processingStage = "summarizing"
        XCTAssertEqual(item.processingStatus, "Creating summary")
        XCTAssertNil(item.processingFraction)
    }

    @MainActor func testRemoteProgressSurvivesReopenAndOldResponsesDecodeSafely() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = RecordingQueueStore(root: root)
        try queue.mergeRemote(id: "progress", owner: "alice", title: "Saved", source: "iPhone", created: Date(),
            state: .processing, transcript: "", summary: "", error: nil, partCount: 2, duration: 600, updated: 2,
            transcribedSeconds: 120, transcriptionComplete: false, processingStage: "transcribing")
        let reopened = try XCTUnwrap(RecordingQueueStore(root: root).recording("progress"))
        XCTAssertEqual(reopened.state, .processing)
        XCTAssertEqual(reopened.processingFraction, 0.2)
        XCTAssertEqual(reopened.processingStatus, "Transcribing on PC")
        try queue.update("progress") { $0.serverUploaded = false; $0.processingRequested = true }
        let interruptedUpload = try XCTUnwrap(RecordingQueueStore(root: root).recording("progress"))
        XCTAssertEqual(interruptedUpload.state, .queued)
        XCTAssertEqual(interruptedUpload.processingRequested, true)
        let old = QueuedRecording(id: "old", title: "Old", source: "iPhone", createdAt: Date(), state: .processing)
        let decoded = try JSONDecoder().decode(QueuedRecording.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.transcribedSeconds)
        XCTAssertNil(decoded.processingStage)
        XCTAssertNil(decoded.transcriptionComplete)
    }
}
