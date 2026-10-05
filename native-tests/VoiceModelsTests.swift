import XCTest
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
}
