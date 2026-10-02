import XCTest
@testable import ScribePilot

@MainActor
final class RecordingQueueTests: XCTestCase {
    private func fixture() throws -> (RecordingQueueStore, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = root.appendingPathComponent("fixture.m4a")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2048).write(to: input)
        return (RecordingQueueStore(root: root.appendingPathComponent("queue")), root, input)
    }

    func testMissingChunkAndOutOfOrderFinalDoNotAllowProcessing() async throws {
        let (queue, root, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try queue.accept(fileURL: audio, id: "watch-001", index: 2, isFinal: true, source: "Apple Watch")
        try queue.accept(fileURL: audio, id: "watch-001", index: 0, isFinal: false, source: "Apple Watch")
        XCTAssertFalse(try XCTUnwrap(queue.recording("watch-001")).canProcess)
        try queue.accept(fileURL: audio, id: "watch-001", index: 1, isFinal: false, source: "Apple Watch")
        XCTAssertTrue(try XCTUnwrap(queue.recording("watch-001")).canProcess)
    }

    func testDeletedRecordingStaysDeletedAfterLateTransferAndRelaunch() async throws {
        let (queue, root, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try queue.accept(fileURL: audio, id: "watch-002", index: 0, isFinal: true, source: "Apple Watch")
        let stored = queue.audioURL("watch-002", part: try XCTUnwrap(queue.recording("watch-002")?.parts.first))
        try queue.remove(["watch-002"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
        let reopened = RecordingQueueStore(root: root.appendingPathComponent("queue"))
        XCTAssertFalse(try reopened.accept(fileURL: audio, id: "watch-002", index: 1, isFinal: true, source: "Apple Watch"))
        XCTAssertNil(reopened.recording("watch-002"))
        try reopened.update("watch-002") { $0.state = .ready; $0.transcript = "Late provider response" }
        XCTAssertTrue(reopened.recordings.isEmpty)
    }

    func testDuplicateTransferKeepsRenamedTitleAndProcessingCheckpoint() async throws {
        let (queue, root, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try queue.accept(fileURL: audio, id: "watch-003", index: 0, isFinal: true, source: "Apple Watch")
        try queue.rename("watch-003", title: "Weekly review")
        try queue.update("watch-003") { $0.state = .processing; $0.transcripts["0:0"] = "Saved checkpoint" }
        XCTAssertFalse(try queue.accept(fileURL: audio, id: "watch-003", index: 0, isFinal: true, source: "Apple Watch"))
        let reopened = RecordingQueueStore(root: root.appendingPathComponent("queue"))
        let item = try XCTUnwrap(reopened.recording("watch-003"))
        XCTAssertEqual(item.title, "Weekly review")
        XCTAssertEqual(item.parts.count, 1)
        XCTAssertEqual(item.state, .queued)
        XCTAssertEqual(item.transcripts["0:0"], "Saved checkpoint")
    }

    func testInvalidIDCannotWriteOutsideQueue() async throws {
        let (queue, root, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try queue.accept(fileURL: audio, id: "../outside", index: 0, isFinal: true, source: "Apple Watch"))
        XCTAssertTrue(queue.recordings.isEmpty)
    }

    func testUnfinishedRecordingCannotBeRemovedAndCorruptQueueFailsClosed() async throws {
        let (queue, root, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try queue.begin(id: "watch-004", source: "Apple Watch")
        try queue.accept(fileURL: audio, id: "watch-004", index: 0, isFinal: false, source: "Apple Watch")
        XCTAssertThrowsError(try queue.remove(["watch-004"]))
        let state = root.appendingPathComponent("queue/queue.json")
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: state)
        let reopened = RecordingQueueStore(root: root.appendingPathComponent("queue"))
        XCTAssertNotNil(reopened.errorMessage)
        XCTAssertThrowsError(try reopened.accept(fileURL: audio, id: "watch-005", index: 0, isFinal: true, source: "Apple Watch"))
        XCTAssertEqual(try Data(contentsOf: state), corrupt)
    }

    func testProtectedModeRequiresAllConfirmations() async {
        var configuration = OpenAIConfiguration()
        XCTAssertFalse(configuration.safeguardsReady)
        configuration.baaConfirmed = true
        configuration.retentionConfirmed = true
        XCTAssertFalse(configuration.safeguardsReady)
        configuration.safeguardsConfirmed = true
        XCTAssertTrue(configuration.safeguardsReady)
        configuration.retentionConfirmed = false
        XCTAssertFalse(configuration.safeguardsReady)
    }
}
