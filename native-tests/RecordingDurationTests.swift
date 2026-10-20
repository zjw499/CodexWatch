import AVFoundation
import XCTest
@testable import ScribePilot

@MainActor
final class RecordingDurationTests: XCTestCase {
    private func fixture() throws -> (RecordingQueueStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (RecordingQueueStore(root: root), root)
    }

    private func audio(in root: URL, seconds: Double, suffix: String = "wav") throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + "." + suffix)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        memset(try XCTUnwrap(buffer.floatChannelData)[0], 0, Int(frames) * MemoryLayout<Float>.size)
        try autoreleasepool {
            let settings: [String: Any] = suffix == "m4a"
                ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
                : format.settings
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        }
        return url
    }

    func testWatchPartsSumOnceDespiteDuplicateAndOutOfOrderDelivery() throws {
        let (queue, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try audio(in: root, seconds: 30)
        let final = try audio(in: root, seconds: 13)
        try queue.accept(fileURL: final, id: "watch", index: 1, isFinal: true, source: "Apple Watch")
        XCTAssertEqual(queue.recording("watch")?.durationDescription(), "00:13 received")
        try queue.accept(fileURL: first, id: "watch", index: 0, isFinal: false, source: "Apple Watch")
        XCTAssertEqual(try XCTUnwrap(queue.recording("watch")?.duration), 43, accuracy: 0.001)
        XCTAssertEqual(queue.recording("watch")?.durationDescription(), "00:43")
        XCTAssertFalse(try queue.accept(fileURL: first, id: "watch", index: 0, isFinal: false, source: "Apple Watch"))
        XCTAssertEqual(try XCTUnwrap(queue.recording("watch")?.duration), 43, accuracy: 0.001)
        XCTAssertEqual(RecordingQueueStore(root: root).recording("watch")?.duration, 43)
    }

    func testExistingQueueWithoutDurationBackfillsFromAudioOnReopen() throws {
        let (queue, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try audio(in: root, seconds: 12)
        try queue.accept(fileURL: file, id: "legacy", index: 0, isFinal: true, source: "Apple Watch")
        let snapshot = root.appendingPathComponent("queue.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: snapshot)) as? [String: Any])
        var records = try XCTUnwrap(json["recordings"] as? [[String: Any]])
        records[0].removeValue(forKey: "duration")
        var parts = try XCTUnwrap(records[0]["parts"] as? [[String: Any]])
        parts[0].removeValue(forKey: "duration")
        records[0]["parts"] = parts; json["recordings"] = records
        try JSONSerialization.data(withJSONObject: json).write(to: snapshot)
        XCTAssertEqual(RecordingQueueStore(root: root).recording("legacy")?.duration, 12)
        XCTAssertEqual(RecordingQueueStore(root: root).recording("legacy")?.duration, 12)
    }

    func testEmptyServerDurationDoesNotEraseLocallyMeasuredDuration() throws {
        let (queue, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try audio(in: root, seconds: 8)
        try queue.accept(fileURL: file, id: "local", index: 0, isFinal: true, source: "iPhone", ownerID: "alice")
        try queue.mergeRemote(id: "local", owner: "alice", title: "Saved", source: "iPhone", created: Date(),
                              state: .queued, transcript: "", summary: "", error: nil, partCount: 1, duration: nil, updated: 1)
        XCTAssertEqual(queue.recording("local")?.duration, 8)
    }

    func testAACFileDurationIsMeasuredAndUnreadableAudioStaysUnknown() throws {
        let (_, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try audio(in: root, seconds: 2, suffix: "m4a")
        XCTAssertEqual(try XCTUnwrap(RecordingDuration.measured(at: file)), 2, accuracy: 0.15)
        XCTAssertNil(RecordingDuration.measured(at: root.appendingPathComponent("missing.m4a")))
    }

    func testDurationFormattingAndLiveCaptureDoNotUseWallClockTime() {
        XCTAssertEqual(RecordingDuration.display(83), "01:23")
        XCTAssertEqual(RecordingDuration.display(3_723), "1:02:03")
        XCTAssertEqual(RecordingDuration.display(nil), "Duration unavailable")
        XCTAssertEqual(RecordingDuration.display(.infinity), "Duration unavailable")
        XCTAssertEqual(RecordingDuration.display(-1), "Duration unavailable")
        let recording = QueuedRecording(id: "live", title: "Live", source: "iPhone", createdAt: .distantPast, state: .recording)
        XCTAssertEqual(recording.durationDescription(activeDuration: 7), "00:07")
    }

    func testHistoricalCompletedTranscriptionProvidesDurationButPartialTextDoesNot() throws {
        let json = """
        {"id":"remote","owner":"alice","title":"Saved","source":"Apple Watch","state":"ready","created":1,"updated":1,"expected_parts":2,"transcript":"","summary":"","chat":[],"transcribed_seconds":42,"transcription_complete":true}
        """
        let completed = try JSONDecoder().decode(WorkspaceRecording.self, from: Data(json.utf8))
        XCTAssertEqual(completed.recordedDuration, 42)
        let partial = try JSONDecoder().decode(WorkspaceRecording.self, from: Data(json.replacingOccurrences(of: "true", with: "false").utf8))
        XCTAssertNil(partial.recordedDuration)
    }
}
