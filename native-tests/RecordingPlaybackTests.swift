import Combine
import XCTest
@testable import ScribePilot

@MainActor
final class RecordingPlaybackTests: XCTestCase {
    private func wav(seconds: Double = 0.1) -> Data {
        let frames = Int(seconds * 16000)
        var data = Data()
        func word(_ value: UInt32) { var value = value.littleEndian; data.append(Data(bytes: &value, count: 4)) }
        func short(_ value: UInt16) { var value = value.littleEndian; data.append(Data(bytes: &value, count: 2)) }
        data.append(Data("RIFF".utf8)); word(UInt32(36 + frames * 2)); data.append(Data("WAVEfmt ".utf8))
        word(16); short(1); short(1); word(16000); word(32000); short(2); short(16)
        data.append(Data("data".utf8)); word(UInt32(frames * 2)); data.append(Data(repeating: 0, count: frames * 2))
        return data
    }
    func testFullRecordingAdvancesThroughEveryPartInOrder() async {
        let player = PhoneRecordingPlayer()
        let finalPart = expectation(description: "Final source part loaded")
        var indexes: [Int] = []
        player.play(count: 3) { index in
            indexes.append(index)
            if index == 2 { finalPart.fulfill() }
            return self.wav()
        }
        await fulfillment(of: [finalPart], timeout: 30)
        XCTAssertEqual(indexes, [0, 1, 2])
        player.stop()
    }
    func testLateAudioCannotResumeAfterStop() async {
        let player = PhoneRecordingPlayer()
        var pending: CheckedContinuation<Data, Error>?
        let loading = expectation(description: "Loading source")
        player.play(count: 2) { _ in
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation; loading.fulfill()
            }
        }
        await fulfillment(of: [loading], timeout: 5)
        player.stop()
        pending?.resume(returning: wav())
        await Task.yield()
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isLoading)
        XCTAssertFalse(player.isPaused)
    }
    func testMissingMiddlePartStopsWithVisibleErrorInsteadOfSkipping() async {
        let player = PhoneRecordingPlayer()
        let failed = expectation(description: "Missing part reported")
        var indexes: [Int] = []
        let observation = player.$error.compactMap { $0 }.sink { _ in failed.fulfill() }
        player.play(count: 3) { index in
            indexes.append(index)
            if index == 1 { throw CocoaError(.fileNoSuchFile) }
            return self.wav()
        }
        await fulfillment(of: [failed], timeout: 10)
        XCTAssertEqual(indexes, [0, 1])
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.error?.contains("part 2") == true)
        observation.cancel()
    }
}
