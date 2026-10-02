import XCTest
@testable import ScribePilot

@MainActor
final class WorkspaceQueueTests: XCTestCase {
    private func fixture() throws -> (RecordingQueueStore, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("fixture.m4a")
        try Data(repeating: 7, count: 2048).write(to: audio)
        return (RecordingQueueStore(root: root.appendingPathComponent("queue")), root, audio)
    }
    func testDelayedWatchAudioKeepsOriginalOwnerAfterAccountSwitch() throws {
        let (queue, root, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        queue.setAccount("alice")
        try queue.accept(fileURL: audio, id: "watch-delayed", index: 0, isFinal: false, source: "Apple Watch", ownerID: "alice")
        queue.setAccount("bobby")
        try queue.accept(fileURL: audio, id: "watch-delayed", index: 1, isFinal: true, source: "Apple Watch", ownerID: "alice")
        XCTAssertTrue(queue.visibleRecordings.isEmpty)
        XCTAssertEqual(queue.recording("watch-delayed")?.ownerID, "alice")
        XCTAssertThrowsError(try queue.accept(fileURL: audio, id: "watch-delayed", index: 2, isFinal: false, source: "Apple Watch", ownerID: "bobby"))
        queue.setAccount("alice")
        XCTAssertEqual(queue.pending.count, 1)
        queue.setAccount(nil)
        XCTAssertTrue(queue.visibleRecordings.isEmpty)
    }
    func testUnassignedHistoryNeedsExplicitImportAndDeletionPersistsOwner() throws {
        let (queue, root, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try queue.accept(fileURL: audio, id: "older", index: 0, isFinal: true, source: "iPhone")
        queue.setAccount("alice")
        XCTAssertTrue(queue.visibleRecordings.isEmpty)
        XCTAssertEqual(queue.unassigned.count, 1)
        try queue.assign("older", owner: "alice")
        XCTAssertEqual(queue.pending.count, 1)
        XCTAssertThrowsError(try queue.assign("older", owner: "bobby"))
        try queue.remove(["older"])
        let reopened = RecordingQueueStore(root: root.appendingPathComponent("queue"))
        XCTAssertEqual(reopened.removedOwners["older"], "alice")
        try reopened.acknowledgeDeletion("older")
        XCTAssertNil(reopened.removedOwners["older"])
        XCTAssertTrue(reopened.isRemoved("older"))
    }
    func testCompanionEditsBeforeAudioPersistOriginalOwnershipAndPreventResurrection() throws {
        let (queue, root, audio) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        queue.setAccount("bobby")
        try queue.applyCompanionChange("deleted-before-audio", owner: "alice", removing: true)
        let reopened = RecordingQueueStore(root: root.appendingPathComponent("queue"))
        XCTAssertEqual(reopened.removedOwners["deleted-before-audio"], "alice")
        XCTAssertFalse(try reopened.accept(fileURL: audio, id: "deleted-before-audio", index: 0, isFinal: true, source: "Apple Watch", ownerID: "alice"))
        try reopened.applyCompanionChange("renamed-before-audio", owner: "alice", title: "Original owner's title")
        try reopened.accept(fileURL: audio, id: "renamed-before-audio", index: 0, isFinal: true, source: "Apple Watch", ownerID: "alice")
        try reopened.mergeRemote(id: "renamed-before-audio", owner: "alice", title: "Stale server title", source: "Apple Watch", created: Date(), state: .ready, transcript: "Saved transcript", summary: "Saved results", error: nil, partCount: 1, duration: 10, updated: 2)
        XCTAssertEqual(reopened.recording("renamed-before-audio")?.title, "Original owner's title")
        XCTAssertEqual(reopened.recording("renamed-before-audio")?.ownerID, "alice")
        XCTAssertTrue(reopened.visibleRecordings.isEmpty)
        XCTAssertThrowsError(try reopened.applyCompanionChange("renamed-before-audio", owner: "bobby", removing: true))
    }
    func testWorkspaceAddressAndCredentialDecoding() throws {
        XCTAssertNotNil(PhoneWorkspace.validServer("https://example.tail123.ts.net/workspace"))
        XCTAssertNil(PhoneWorkspace.validServer("http://example.tail123.ts.net/workspace"))
        XCTAssertNil(PhoneWorkspace.validServer("https://example.com/workspace"))
        XCTAssertNil(PhoneWorkspace.validServer("https://example.tail123.ts.net/workspace?token=private"))
        let login = Data("{\"token\":\"test\",\"expires\":123456,\"user\":{\"id\":\"alice\",\"username\":\"alice\",\"role\":\"user\"}}".utf8)
        let credential = try JSONDecoder().decode(WorkspaceCredential.self, from: login)
        XCTAssertEqual(credential.server, "")
        XCTAssertEqual(credential.user.id, "alice")
    }
}
