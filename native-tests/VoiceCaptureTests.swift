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

    private func offlineGraph(outputRate: Double = 48000, outputChannels: AVAudioChannelCount = 1) throws -> (AVAudioEngine, VoiceAudioGraph) {
        let engine = AVAudioEngine()
        let outputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: outputChannels))
        // Establish a different output route before connecting the shared graph.
        // Setting manual rendering afterward would hide an incorrect output override.
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 4096)
        // The offline renderer converts the mixer output to outputFormat. The mixer's
        // automatic connection can retain the simulator's native 44.1 kHz/stereo format.
        // Compare with that automatic connection, rather than the renderer's PCM format.
        let automaticOutput = engine.mainMixerNode.outputFormat(forBus: 0)
        let graph = try VoiceAudioGraph(engine: engine)
        XCTAssertEqual(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate, automaticOutput.sampleRate)
        XCTAssertEqual(engine.mainMixerNode.outputFormat(forBus: 0).channelCount, automaticOutput.channelCount)
        try engine.start()
        return (engine, graph)
    }

    func testOutputIsSilentBeforeAssistantSpeech() throws {
        let (engine, graph) = try offlineGraph()
        defer { engine.stop() }
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 2048))
        XCTAssertEqual(try engine.renderOffline(2048, to: output), .success)
        let channel = try XCTUnwrap(output.floatChannelData?[0])
        XCTAssertTrue((0..<Int(output.frameLength)).allSatisfy { abs(channel[$0]) < 0.00001 })
        XCTAssertFalse(graph.player.isPlaying)
    }

    func testAssistantReplyRemainsAudibleAtDifferentOutputRate() throws {
        let (engine, graph) = try offlineGraph()
        defer { engine.stop() }
        graph.player.scheduleBuffer(try buffer(rate: 24000, frames: 4800, value: 0.25))
        graph.player.play()
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 2048))
        XCTAssertEqual(try engine.renderOffline(2048, to: output), .success)
        let channel = try XCTUnwrap(output.floatChannelData?[0])
        XCTAssertTrue((0..<Int(output.frameLength)).contains { abs(channel[$0]) > 0.1 })
        XCTAssertTrue((0..<Int(output.frameLength)).allSatisfy { abs(channel[$0]) < 0.3 })
    }

    func testDifferentSpeakerFormatsKeepReplyWorking() throws {
        let routes: [(Double, AVAudioChannelCount)] = [
            (16000, 1), (44100, 1), (48000, 1), (48000, 2)
        ]
        for (outputRate, outputChannels) in routes {
            let (engine, graph) = try offlineGraph(outputRate: outputRate, outputChannels: outputChannels)
            defer { engine.stop() }
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 2048))
            XCTAssertEqual(try engine.renderOffline(2048, to: output), .success)
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

    func testReceiverCopiesCallbacksBeforeSourceMemoryIsReused() throws {
        for rate in [16000.0, 24000.0, 44100.0, 48000.0] {
            let packets = CapturedVoicePackets()
            let input = try buffer(rate: rate, frames: Int(rate / 50))
            let receiver = try VoiceInputReceiver(input: input.format) { packets.append($0) }
            defer { receiver.stop(); receiver.clearStoppedInput() }
            for _ in 0..<40 {
                // Only the preallocated ring is touched during receive; conversion is deferred.
                input.floatChannelData![0].update(repeating: 0.25, count: Int(input.frameLength))
                receiver.receive(frames: input.frameLength, from: input.audioBufferList)
                input.floatChannelData![0].update(repeating: 0, count: Int(input.frameLength))
                receiver.drain()
            }
            XCTAssertFalse(packets.result.failed)
            XCTAssertGreaterThanOrEqual(packets.result.packets.count, 3)
            XCTAssertGreaterThan(VoiceAudioStatus.microphoneLevel(try XCTUnwrap(packets.result.packets.first)), 0)
            XCTAssertEqual(receiver.statistics.inputFrames, Int64(rate * 0.8))
            XCTAssertNil(receiver.statistics.startupFailure)
        }
    }

    func testLiveInputConnectsOnlyToSinkAndIsIndependentOfReplyPlayback() throws {
        // Inspect native wiring without starting hardware. Offline rendering cannot
        // exercise a sink or voice-processing I/O, and is only used for reply tests.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let receiver = try VoiceInputReceiver(input: format) { _ in }
        defer { receiver.stop(); receiver.clearStoppedInput() }
        let graph = try VoiceAudioGraph(engine: engine)
        let sink = receiver.attach(to: engine)
        XCTAssertTrue(engine.inputConnectionPoint(for: sink, inputBus: 0)?.node === input)
        let destinations = engine.outputConnectionPoints(for: input, outputBus: 0)
        XCTAssertEqual(destinations.count, 1)
        XCTAssertTrue(destinations.first?.node === sink)
        XCTAssertTrue(engine.inputConnectionPoint(for: engine.mainMixerNode, inputBus: 0)?.node === graph.player)
        XCTAssertFalse(graph.player.isPlaying)
    }

    func testReceiverWorkerDeliversWithoutManualDrain() throws {
        let delivered = expectation(description: "worker delivers a live PCM batch")
        let packets = CapturedVoicePackets()
        let input = try buffer(rate: 24000, frames: 2400)
        let receiver = try VoiceInputReceiver(input: input.format) { packet in
            packets.append(packet)
            delivered.fulfill()
        }
        defer { receiver.stop(); receiver.clearStoppedInput() }
        receiver.start()
        for _ in 0..<2 { receiver.receive(frames: input.frameLength, from: input.audioBufferList) }
        wait(for: [delivered], timeout: 2)
        XCTAssertFalse(packets.result.failed)
        XCTAssertEqual(packets.result.packets.count, 1)
        XCTAssertEqual(receiver.statistics.inputFrames, 4800)
    }

    func testReceiverHandlesPlanarAndInterleavedStereoPCM() throws {
        for interleaved in [false, true] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                                   channels: 2, interleaved: interleaved))
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
            input.frameLength = 960
            let packets = CapturedVoicePackets()
            let receiver = try VoiceInputReceiver(input: format) { packets.append($0) }
            defer { receiver.stop(); receiver.clearStoppedInput() }
            for _ in 0..<30 {
                for audio in UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList) {
                    let samples = try XCTUnwrap(audio.mData?.assumingMemoryBound(to: Float.self))
                    samples.update(repeating: 0.25, count: Int(input.frameLength * audio.mNumberChannels))
                }
                receiver.receive(frames: input.frameLength, from: input.audioBufferList)
                receiver.drain()
            }
            XCTAssertFalse(packets.result.failed)
            XCTAssertGreaterThanOrEqual(packets.result.packets.count, 2)
            XCTAssertGreaterThan(VoiceAudioStatus.microphoneLevel(try XCTUnwrap(packets.result.packets.first)), 0)
            XCTAssertNil(receiver.statistics.startupFailure)
        }
    }

    func testReceiverPreservesVariableCallbackSizesAndOrdering() throws {
        let packets = CapturedVoicePackets()
        let input = try buffer(rate: 24000, frames: 1200)
        let receiver = try VoiceInputReceiver(input: input.format) { packets.append($0) }
        defer { receiver.stop(); receiver.clearStoppedInput() }
        for (frames, value) in [(100, Float(0.25)), (1100, Float(-0.25)), (600, Float(0.5)), (1200, Float(-0.5)), (1200, Float(0)), (600, Float(0.25))] {
            input.frameLength = AVAudioFrameCount(frames)
            input.floatChannelData![0].update(repeating: value, count: frames)
            receiver.receive(frames: input.frameLength, from: input.audioBufferList)
        }
        receiver.drain()
        XCTAssertFalse(packets.result.failed)
        let data = try XCTUnwrap(packets.result.packets.first)
        XCTAssertEqual(data.count, 9600)
        data.withUnsafeBytes { raw in
            for (index, expected) in [(0, 8192), (99, 8192), (100, -8192), (1199, -8192), (1200, 16384),
                                      (1799, 16384), (1800, -16384), (2999, -16384), (3000, 0), (4199, 0), (4200, 8192)] {
                let sample = Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                XCTAssertLessThanOrEqual(abs(sample - expected), 1)
            }
        }
        XCTAssertEqual(receiver.statistics.inputFrames, 4800)
    }

    func testReceiverOverflowEndsCaptureInsteadOfOverwritingUnsentAudio() throws {
        let packets = CapturedVoicePackets()
        let input = try buffer(rate: 24000, frames: 2400)
        let receiver = try VoiceInputReceiver(input: input.format, slots: 2) { packets.append($0) }
        defer { receiver.stop(); receiver.clearStoppedInput() }
        for _ in 0..<3 { receiver.receive(frames: input.frameLength, from: input.audioBufferList) }
        receiver.drain(); receiver.drain()
        XCTAssertTrue(packets.result.failed)
        XCTAssertTrue(packets.result.packets.isEmpty)
        XCTAssertEqual(receiver.statistics.receiverFailure, 1)
        XCTAssertTrue(receiver.statistics.startupFailure?.contains("CAP-01") == true)
    }

    func testReceiverRejectsOversizedOrChangedInputWithoutReadingBeyondBuffers() throws {
        let packets = CapturedVoicePackets()
        let input = try buffer(rate: 24000, frames: 2400)
        let receiver = try VoiceInputReceiver(input: input.format) { packets.append($0) }
        defer { receiver.stop(); receiver.clearStoppedInput() }
        receiver.receive(frames: VoiceInputReceiver.maximumFrames + 1, from: input.audioBufferList)
        receiver.drain()
        XCTAssertTrue(packets.result.failed)
        XCTAssertTrue(packets.result.packets.isEmpty)
        XCTAssertEqual(receiver.statistics.receiverFailure, 2)
        XCTAssertTrue(receiver.statistics.startupFailure?.contains("CAP-02") == true)
    }

    func testReceiverStopDiscardsQueuedInputAndRejectsLateCallbacks() throws {
        let packets = CapturedVoicePackets()
        let input = try buffer(rate: 24000, frames: 2400)
        let receiver = try VoiceInputReceiver(input: input.format) { packets.append($0) }
        receiver.receive(frames: input.frameLength, from: input.audioBufferList)
        receiver.stop(); receiver.clearStoppedInput()
        receiver.receive(frames: input.frameLength, from: input.audioBufferList)
        receiver.drain()
        XCTAssertEqual(receiver.statistics.inputFrames, 2400)
        XCTAssertTrue(packets.result.packets.isEmpty)
        XCTAssertFalse(packets.result.failed)
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
