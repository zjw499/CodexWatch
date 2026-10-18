import AVFoundation
import XCTest
@testable import ScribePilot

@MainActor
final class VoiceReplyPlayerTests: XCTestCase {
    private func makeEngine() throws -> (AVAudioEngine, VoiceReplyPlayer, AVAudioPCMBuffer) {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
        try engine.start()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4800))
        // Offline rendering has no audio device. Its completion point is
        // dataRendered; production defaults to latency-aware dataPlayedBack.
        return (engine, VoiceReplyPlayer(player: player, completionType: .dataRendered), buffer)
    }

    private func pcm(_ sample: Int16, frames: Int = 4800) -> Data {
        let samples = [Int16](repeating: sample.littleEndian, count: frames)
        return samples.withUnsafeBytes { Data($0) }
    }

    private func render(_ blocks: Int, engine: AVAudioEngine, buffer: AVAudioPCMBuffer) async throws -> (positive: Int, negative: Int) {
        var positive = 0, negative = 0
        for _ in 0..<blocks {
            let status = try engine.renderOffline(4800, to: buffer)
            XCTAssertEqual(status, .success)
            if let samples = buffer.floatChannelData?[0] {
                for index in 0..<Int(buffer.frameLength) {
                    if samples[index] > 0.01 { positive += 1 }
                    if samples[index] < -0.01 { negative += 1 }
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return (positive, negative)
    }

    func testActualPCMPlaysAcrossUnderrunsAndLaterRepliesWithoutPausingOrMissingTail() async throws {
        let (engine, reply, buffer) = try makeEngine()
        defer { reply.stop(); engine.stop() }
        var acknowledgements = [String: Int]()
        reply.onItemFinished = { acknowledgements[$0] = $1 }
        for item in ["first", "second", "third"] {
            try reply.append(pcm(8192), item: item)
            reply.finish(item: item)
            let rendered = try await render(5, engine: engine, buffer: buffer)
            XCTAssertEqual(rendered.positive, 4800)
            XCTAssertEqual(acknowledgements[item], 200)
            XCTAssertTrue(reply.player.isPlaying)
            XCTAssertFalse(reply.hasPending)
        }
        XCTAssertEqual(reply.diagnostic.completedFrames, 14400)
        XCTAssertEqual(reply.diagnostic.completedItems, 3)
        XCTAssertEqual(reply.diagnostic.starts, 1)
    }

    func testInterruptionDoesNotAcknowledgeDiscardedAudioAndOldInterruptCannotStopNewReply() async throws {
        let (engine, reply, buffer) = try makeEngine()
        defer { reply.stop(); engine.stop() }
        var completed = [String]()
        reply.onItemFinished = { item, _ in completed.append(item) }
        try reply.append(pcm(8192), item: "discarded")
        XCTAssertFalse(reply.player.isPlaying)
        XCTAssertEqual(reply.interrupt(item: "discarded"), 0)
        try reply.append(pcm(-8192), item: "new")
        reply.finish(item: "new")
        XCTAssertEqual(reply.interrupt(item: "discarded"), 0)
        let rendered = try await render(5, engine: engine, buffer: buffer)
        XCTAssertEqual(rendered.positive, 0); XCTAssertEqual(rendered.negative, 4800)
        XCTAssertEqual(completed, ["new"])
        XCTAssertEqual(reply.diagnostic.scheduledFrames, 9600)
        XCTAssertEqual(reply.diagnostic.completedFrames, 4800)
    }

    func testToolPreambleAndAnswerEachAcknowledgeTheirOwnRenderedAudioOnce() async throws {
        let (engine, reply, buffer) = try makeEngine()
        defer { reply.stop(); engine.stop() }
        var acknowledgements = [(String, Int)]()
        reply.onItemFinished = { acknowledgements.append(($0, $1)) }
        for _ in 0..<2 { try reply.append(pcm(8192), item: "preamble") }
        reply.finish(item: "preamble")
        for _ in 0..<2 { try reply.append(pcm(-8192), item: "answer") }
        reply.finish(item: "answer")
        let rendered = try await render(8, engine: engine, buffer: buffer)
        reply.finish(item: "preamble"); reply.finish(item: "answer")
        XCTAssertEqual(rendered.positive, 9600); XCTAssertEqual(rendered.negative, 9600)
        XCTAssertEqual(acknowledgements.map { $0.0 }, ["preamble", "answer"])
        XCTAssertEqual(acknowledgements.map { $0.1 }, [400, 400])
        XCTAssertEqual(reply.diagnostic.completedItems, 2)
    }
}
