import AVFoundation
import Foundation
import XCTest
@testable import ScribePilot

private final class CapturedVoicePackets: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    private var failed = false
    func append(_ packet: Data?) {
        lock.lock(); defer { lock.unlock() }
        if let packet { packets.append(packet) } else { failed = true }
    }
    var result: (packets: [Data], failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (packets, failed)
    }
}

private final class SyntheticMicActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    func received(_ count: Int) { lock.lock(); frames += count; lock.unlock() }
    var receivedFrames: Int { lock.lock(); defer { lock.unlock() }; return frames }
}

final class VoiceCaptureTests: XCTestCase {
    private func buffer(rate: Double, frames: Int, value: Float = 0.25) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames))))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<frames { channel[index] = value }
        return buffer
    }

    func testLiveResamplingProducesMonoPCMFromCommonInputRates() throws {
        for rate in [16000.0, 24000.0, 44100.0, 48000.0] {
            let packets = CapturedVoicePackets()
            let input = try buffer(rate: rate, frames: Int(rate / 50))
            let encoder = try VoicePCMEncoder(input: input.format) { packets.append($0) }
            for _ in 0..<40 { encoder.consume(input) }
            XCTAssertFalse(packets.result.failed, "Conversion failed at \(rate) Hz")
            XCTAssertGreaterThanOrEqual(packets.result.packets.count, 3, "No live batches at \(rate) Hz")
            XCTAssertTrue(packets.result.packets.allSatisfy { $0.count == 9600 })
            XCTAssertGreaterThan(VoiceAudioStatus.microphoneLevel(try XCTUnwrap(packets.result.packets.first)), 0)
            XCTAssertEqual(encoder.statistics.inputFrames, Int64(rate * 0.8))
            XCTAssertGreaterThan(encoder.statistics.outputFrames, 18000)
            XCTAssertNil(encoder.statistics.startupFailure)
        }
    }

    func testPartialBuffersAccumulateAndUseLittleEndianPCM() throws {
        let packets = CapturedVoicePackets()
        let input = try buffer(rate: 24000, frames: 1000)
        let encoder = try VoicePCMEncoder(input: input.format) { packets.append($0) }
        encoder.consume(try buffer(rate: 24000, frames: 0))
        XCTAssertEqual(encoder.statistics.inputFrames, 0)
        for _ in 0..<4 { encoder.consume(input) }
        XCTAssertTrue(packets.result.packets.isEmpty)
        encoder.consume(input)
        let batch = try XCTUnwrap(packets.result.packets.first)
        XCTAssertEqual(packets.result.packets.count, 1)
        XCTAssertEqual(batch.count, 9600)
        let sample = batch.withUnsafeBytes { Int16(littleEndian: $0.loadUnaligned(as: Int16.self)) }
        XCTAssertLessThanOrEqual(abs(Int(sample) - 8192), 1)
    }

    func testSilenceIsStillCapturedAndBatchedWithoutInventingMicActivity() throws {
        let packets = CapturedVoicePackets()
        let input = try buffer(rate: 48000, frames: 2400, value: 0)
        let encoder = try VoicePCMEncoder(input: input.format) { packets.append($0) }
        for _ in 0..<20 { encoder.consume(input) }
        XCTAssertFalse(packets.result.failed)
        XCTAssertGreaterThanOrEqual(packets.result.packets.count, 4)
        XCTAssertTrue(packets.result.packets.allSatisfy { VoiceAudioStatus.microphoneLevel($0) == 0 })
        XCTAssertNil(encoder.statistics.startupFailure)
    }

    func testCaptureFailureSeparatesMissingMicFromConversionAndDoesNotBlamePermissions() {
        let missing = VoiceCaptureStatistics().startupFailure ?? ""
        XCTAssertTrue(missing.contains("MIC-01"))
        XCTAssertTrue(missing.contains("permission is allowed"))
        let conversion = VoiceCaptureStatistics(inputFrames: 2400).startupFailure ?? ""
        XCTAssertTrue(conversion.contains("PCM-01"))
        XCTAssertFalse(conversion.contains("permission"))
        XCTAssertNil(VoiceCaptureStatistics(inputFrames: 9600, outputFrames: 4800, batches: 1).startupFailure)
    }

    private func offlineGraph(inputRate: Double = 48000, inputChannels: AVAudioChannelCount = 1,
                              outputRate: Double = 48000, outputChannels: AVAudioChannelCount = 1) throws -> (AVAudioEngine, VoiceAudioGraph, SyntheticMicActivity) {
        let engine = AVAudioEngine()
        let activity = SyntheticMicActivity()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: inputChannels))
        let outputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: outputChannels))
        // Establish a different output route before connecting the shared graph.
        // Setting manual rendering afterward would hide an incorrect output override.
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 4096)
        // The offline renderer converts the mixer output to outputFormat. The mixer's
        // automatic connection can retain the simulator's native 44.1 kHz/stereo format.
        // Compare with that automatic connection, rather than the renderer's PCM format.
        let automaticOutput = engine.mainMixerNode.outputFormat(forBus: 0)
        // A known nonzero synthetic microphone must never reach the speaker mix.
        let source = AVAudioSourceNode(format: format) { _, _, frames, list in
            activity.received(Int(frames))
            for buffer in UnsafeMutableAudioBufferListPointer(list) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for index in 0..<Int(frames) { data[index] = 0.5 }
            }
            return 0
        }
        engine.attach(source)
        let graph = try VoiceAudioGraph(engine: engine, microphone: source, inputFormat: format)
        XCTAssertEqual(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate, automaticOutput.sampleRate)
        XCTAssertEqual(engine.mainMixerNode.outputFormat(forBus: 0).channelCount, automaticOutput.channelCount)
        try engine.start()
        return (engine, graph, activity)
    }

    func testMicrophoneRenderBranchIsInaudibleBeforeAssistantSpeech() throws {
        let (engine, graph, activity) = try offlineGraph()
        defer { engine.stop() }
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 2048))
        XCTAssertEqual(try engine.renderOffline(2048, to: output), .success)
        let channel = try XCTUnwrap(output.floatChannelData?[0])
        XCTAssertTrue((0..<Int(output.frameLength)).allSatisfy { abs(channel[$0]) < 0.00001 })
        XCTAssertGreaterThan(activity.receivedFrames, 0, "Listening must pull microphone input before any reply is playing")
        XCTAssertFalse(graph.player.isPlaying)
    }

    func testAssistantReplyRemainsAudibleWithMutedMicBranchAndDifferentRate() throws {
        let (engine, graph, _) = try offlineGraph()
        defer { engine.stop() }
        graph.player.scheduleBuffer(try buffer(rate: 24000, frames: 4800, value: 0.25))
        graph.player.play()
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 2048))
        XCTAssertEqual(try engine.renderOffline(2048, to: output), .success)
        let channel = try XCTUnwrap(output.floatChannelData?[0])
        XCTAssertTrue((0..<Int(output.frameLength)).contains { abs(channel[$0]) > 0.1 })
        XCTAssertTrue((0..<Int(output.frameLength)).allSatisfy { abs(channel[$0]) < 0.3 })
    }

    func testDifferentMicrophoneAndSpeakerFormatsKeepCaptureAndReplyWorking() throws {
        let routes: [(Double, AVAudioChannelCount, Double, AVAudioChannelCount)] = [
            (16000, 1, 48000, 1), (16000, 1, 48000, 2),
            (48000, 2, 16000, 1), (44100, 1, 48000, 2)
        ]
        for (inputRate, inputChannels, outputRate, outputChannels) in routes {
            let (engine, graph, activity) = try offlineGraph(inputRate: inputRate, inputChannels: inputChannels,
                                                           outputRate: outputRate, outputChannels: outputChannels)
            defer { engine.stop() }
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 2048))
            XCTAssertEqual(try engine.renderOffline(2048, to: output), .success)
            XCTAssertGreaterThan(activity.receivedFrames, 0)
            for index in 0..<Int(outputChannels) {
                let channel = try XCTUnwrap(output.floatChannelData?[index])
                XCTAssertTrue((0..<Int(output.frameLength)).allSatisfy { abs(channel[$0]) < 0.00001 })
            }
            graph.player.scheduleBuffer(try buffer(rate: 24000, frames: 4800, value: 0.25))
            graph.player.play()
            XCTAssertEqual(try engine.renderOffline(2048, to: output), .success)
            let channel = try XCTUnwrap(output.floatChannelData?[0])
            XCTAssertTrue((0..<Int(output.frameLength)).contains { abs(channel[$0]) > 0.05 })
            XCTAssertTrue((0..<Int(output.frameLength)).allSatisfy { abs(channel[$0]) < 0.3 })
        }
    }

    func testStartupErrorsIdentifyEveryStageWithoutLeakingUnderlyingDetails() {
        let underlying = NSError(domain: "com.apple.coreaudio.avfaudio", code: -308,
                                 userInfo: [NSLocalizedDescriptionKey: "private audio or credential text"])
        for stage in VoiceAudioStartupStage.allCases {
            let message = VoiceAudioStartupError(stage: stage, underlying: underlying).localizedDescription
            XCTAssertTrue(message.contains(stage.rawValue))
            XCTAssertTrue(message.contains("Apple -308"))
            XCTAssertTrue(message.contains("audio service stopped"))
            XCTAssertFalse(message.contains("private"))
            XCTAssertFalse(message.contains("permission"))
        }
    }

    func testUnavailableAudioRouteDoesNotInventAnAppleErrorCode() {
        let message = VoiceAudioStartupError(stage: .speaker).localizedDescription
        XCTAssertTrue(message.contains("OUTPUT-01"))
        XCTAssertFalse(message.contains("Apple"))
        XCTAssertFalse(message.contains("service stopped"))
        XCTAssertNil(VoiceAudioStartupError(stage: .conversion, underlying: VoiceError.audioConversion).nativeCode)
    }
}
