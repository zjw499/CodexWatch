import XCTest
import AVFoundation
@testable import ScribePilot

final class VoiceModelsTests: XCTestCase {
    func testLegacyAssistantDecodesWithoutVoiceAndNewProfileRoundTrips() throws {
        let old = Data(#"{"id":"assistant-1","name":"Meeting","instructions":"Use the transcript","model":"gpt-4.1-mini"}"#.utf8)
        var assistant = try JSONDecoder().decode(WorkspaceAssistant.self, from: old)
        XCTAssertFalse(assistant.voiceSettings.enabled)
        assistant.voiceSettings.enabled = true
        assistant.voiceSettings.voice = "cedar"
        let restored = try JSONDecoder().decode(WorkspaceAssistant.self, from: JSONEncoder().encode(assistant))
        XCTAssertTrue(restored.voiceSettings.enabled)
        XCTAssertEqual(restored.voiceSettings.voice, "cedar")
        XCTAssertEqual(restored.model, "gpt-4.1-mini")
    }
    func testGatewayRejectsRedirectLikeAddressesAndWorkspacePaths() {
        XCTAssertNotNil(VoiceWire.gatewayURL("https://pc.example.ts.net:8443/voice/v1"))
        for value in ["http://pc.example.ts.net:8443/voice/v1", "https://evil.example:8443/voice/v1",
                      "https://pc.example.ts.net/workspace", "https://pc.example.ts.net:8443/voice/v1?token=secret",
                      "https://user@pc.example.ts.net:8443/voice/v1", "https://pc.example.ts.net:8443/voice/v1#fragment"] {
            XCTAssertNil(VoiceWire.gatewayURL(value))
        }
    }
    func testSavedLaunchCannotExecuteAfterAccountChangeOrExpiry() {
        let launch = VoiceLaunchRequest(ownerID: "alice", assistantID: "assistant-1")
        XCTAssertTrue(launch.valid(owner: "alice"))
        XCTAssertFalse(launch.valid(owner: "bob"))
        XCTAssertFalse(launch.valid(owner: nil))
        XCTAssertFalse(launch.valid(owner: "alice", now: launch.expires))
    }
    func testEventParserHandlesHeartbeatVersionAndInterruptedTurn() throws {
        XCTAssertNil(try VoiceWire.event(line: ": heartbeat"))
        XCTAssertNil(try VoiceWire.event(line: "id: 1"))
        let event = try XCTUnwrap(VoiceWire.event(line: #"data: {"version":1,"id":2,"type":"turn","turn":{"id":"turn-1","role":"assistant","text":"Answer","final":true,"interrupted":true}}"#))
        XCTAssertEqual(event.turn?.text, "Answer")
        XCTAssertEqual(event.turn?.interrupted, true)
        XCTAssertThrowsError(try VoiceWire.event(line: #"data: {"version":2,"id":1,"type":"ended"}"#))
    }

    func testSetupReceiptRequiresCurrentAccountDeviceAndRequest() throws {
        let credential = VoiceDeviceCredential(version: 1, token: "synthetic-device-token", owner_id: "alice",
            expires: Date().timeIntervalSince1970 + 600, gateway_url: "https://pc.example.ts.net:8443/voice/v1", device_id: "watch-1")
        let binding = WatchVoiceBinding(parentHash: "synthetic-hash", credential: credential, setupRequestID: "request-1")
        let good = VoiceSetupReceipt(version: 1, requestID: "request-1", ownerID: "alice", deviceID: "watch-1", state: .ready)
        XCTAssertTrue(binding.accepts(good, owner: "alice"))
        XCTAssertFalse(binding.accepts(good, owner: "bob"))
        XCTAssertFalse(binding.accepts(good, owner: nil))
        for bad in [VoiceSetupReceipt(version: 1, requestID: "request-old", ownerID: "alice", deviceID: "watch-1", state: .ready),
                    VoiceSetupReceipt(version: 1, requestID: "request-1", ownerID: "bob", deviceID: "watch-1", state: .ready),
                    VoiceSetupReceipt(version: 1, requestID: "request-1", ownerID: "alice", deviceID: "watch-2", state: .ready),
                    VoiceSetupReceipt(version: 2, requestID: "request-1", ownerID: "alice", deviceID: "watch-1", state: .ready)] {
            XCTAssertFalse(binding.accepts(bad, owner: "alice"))
        }
        let receiptData = try JSONEncoder().encode(good)
        XCTAssertEqual(try JSONDecoder().decode(VoiceSetupReceipt.self, from: receiptData), good)
        XCTAssertFalse(String(decoding: receiptData, as: UTF8.self).contains(credential.token))
    }

    func testOlderWatchBindingDecodesButCannotConfirmANewSetup() throws {
        let old = Data(#"{"parentHash":"old-hash","credential":{"version":1,"token":"synthetic","owner_id":"alice","expires":9999999999,"gateway_url":"https://pc.example.ts.net:8443/voice/v1","device_id":"watch-1"}}"#.utf8)
        let binding = try JSONDecoder().decode(WatchVoiceBinding.self, from: old)
        XCTAssertNil(binding.setupRequestID)
        XCTAssertNil(binding.receipt)
        XCTAssertFalse(binding.accepts(VoiceSetupReceipt(version: 1, requestID: "request-1", ownerID: "alice", deviceID: "watch-1", state: .ready), owner: "alice"))
    }

    func testEndedOrUnknownAudioInterruptionDoesNotEndConversation() {
        XCTAssertTrue(VoiceAudioStatus.interruptionBegan(AVAudioSession.InterruptionType.began.rawValue))
        XCTAssertFalse(VoiceAudioStatus.interruptionBegan(AVAudioSession.InterruptionType.ended.rawValue))
        XCTAssertFalse(VoiceAudioStatus.interruptionBegan(nil))
        XCTAssertFalse(VoiceAudioStatus.interruptionBegan(99))
    }

    func testMicrophoneMeterHandlesSilenceSignalAndMalformedPCM() {
        XCTAssertEqual(VoiceAudioStatus.microphoneLevel(Data()), 0)
        XCTAssertEqual(VoiceAudioStatus.microphoneLevel(Data([0])), 0)
        XCTAssertEqual(VoiceAudioStatus.microphoneLevel(Data(repeating: 0, count: 9600)), 0)
        XCTAssertGreaterThan(VoiceAudioStatus.microphoneLevel(Data([0, 16, 0, 240])), 0)
        XCTAssertEqual(VoiceAudioStatus.microphoneLevel(Data([255, 127, 0, 128])), 1)
    }
}
