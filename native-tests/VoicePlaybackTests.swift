import XCTest
@testable import ScribePilot

final class VoicePlaybackTests: XCTestCase {
    func testWaitingAndStreamGapsDoNotCountAsHeardAudio() throws {
        var playback = VoicePlaybackLedger()
        let first = try XCTUnwrap(playback.schedule(item: "answer", frames: 4800, renderFrame: 240000, audibleFrame: 239000))
        XCTAssertEqual(playback.playedFrames(item: "answer", audibleFrame: 240000), 0)
        XCTAssertEqual(playback.playedFrames(item: "answer", audibleFrame: 242400), 2400)
        playback.complete(first.id)
        let second = try XCTUnwrap(playback.schedule(item: "answer", frames: 4800, renderFrame: 300000, audibleFrame: 299000))
        XCTAssertEqual(playback.playedFrames(item: "answer", audibleFrame: 300000), 4800)
        XCTAssertEqual(playback.playedFrames(item: "answer", audibleFrame: 302400), 7200)
        playback.complete(second.id)
        XCTAssertEqual(playback.playedFrames(item: "answer", audibleFrame: 900000), 9600)
    }

    func testPlaybackBackpressureAndInterruptionReset() throws {
        var playback = VoicePlaybackLedger()
        _ = try XCTUnwrap(playback.schedule(item: "answer", frames: 96000, renderFrame: 0, audibleFrame: 0))
        XCTAssertNil(playback.schedule(item: "answer", frames: 1, renderFrame: 0, audibleFrame: 0))
        XCTAssertEqual(playback.playedFrames(item: "answer", audibleFrame: 2400), 2400)
        playback.reset()
        XCTAssertTrue(playback.pending.isEmpty)
        _ = try XCTUnwrap(playback.schedule(item: "next", frames: 4800, renderFrame: 0, audibleFrame: 0))
        XCTAssertEqual(playback.playedFrames(item: "next", audibleFrame: 0), 0)
        XCTAssertEqual(playback.playedFrames(item: "answer", audibleFrame: 4800), 0)
    }
}
