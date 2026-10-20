import XCTest
@testable import ScribePilot

@MainActor
final class AccountDeletionTests: XCTestCase {
    func testDeletedOwnerSurvivesRelaunchAndRejectsLateWatchAudioAndServerReply() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("synthetic.m4a")
        try Data(repeating: 7, count: 128).write(to: audio)
        let queue = RecordingQueueStore(root: root.appendingPathComponent("queue"))
        queue.setAccount("alice")
        try queue.accept(fileURL: audio, id: "alice-recording", index: 0, isFinal: true, source: "Apple Watch", ownerID: "alice")
        try queue.accept(fileURL: audio, id: "bob-recording", index: 0, isFinal: true, source: "Apple Watch", ownerID: "bobby")
        try queue.deleteAccount("alice")
        let reopened = RecordingQueueStore(root: root.appendingPathComponent("queue"))
        XCTAssertTrue(reopened.deletedOwners.contains("alice"))
        XCTAssertNil(reopened.recording("alice-recording"))
        XCTAssertNotNil(reopened.recording("bob-recording"))
        XCTAssertFalse(try reopened.accept(fileURL: audio, id: "delayed-alice", index: 0, isFinal: true, source: "Apple Watch", ownerID: "alice"))
        try reopened.mergeRemote(id: "late-server", owner: "alice", title: "Synthetic", source: "iPhone", created: Date(), state: .ready,
                                 transcript: "Synthetic", summary: "Synthetic", error: nil, partCount: 1, duration: 1, updated: 1)
        XCTAssertNil(reopened.recording("late-server"))
        reopened.setAccount("alice")
        XCTAssertNil(reopened.accountID)
        reopened.setAccount("bobby")
        XCTAssertEqual(reopened.visibleRecordings.map(\.id), ["bob-recording"])
    }
}
