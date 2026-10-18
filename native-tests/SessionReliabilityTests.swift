import XCTest
@testable import ScribePilot

final class SessionReliabilityTests: XCTestCase {
    func testWatchCanValidateStaleLocalExpiryWithoutGainingOfflineAccess() {
        let expired = VoiceDeviceCredential(version: 1, token: "synthetic-token", owner_id: "alice",
            expires: Date().timeIntervalSince1970 - 60, gateway_url: "https://pc.example.ts.net:8443/voice/v1", device_id: "watch")
        XCTAssertFalse(expired.valid)
        XCTAssertTrue(expired.canAuthenticate)
        let renewed = expired.renewed(until: Date().timeIntervalSince1970 + 3600)
        XCTAssertTrue(renewed.valid)
        XCTAssertEqual(renewed.token, expired.token)
        XCTAssertEqual(renewed.owner_id, expired.owner_id)
        XCTAssertEqual(renewed.device_id, expired.device_id)
        XCTAssertEqual(renewed.gateway_url, expired.gateway_url)
        for expiry in [expired.expires - 1, Double.nan, Double.infinity, Date().timeIntervalSince1970 + 400 * 86400] {
            XCTAssertEqual(expired.renewed(until: expiry).expires, expired.expires)
        }
    }

    func testDelayedRenewalCannotShortenExpiry() {
        let now = Date().timeIntervalSince1970
        XCTAssertTrue(SessionRenewal.accepts(now + 30 * 86400, after: now + 3600, now: now))
        XCTAssertFalse(SessionRenewal.accepts(now + 3600, after: now + 30 * 86400, now: now))
        XCTAssertFalse(SessionRenewal.accepts(now - 1, after: now - 2, now: now))
    }

    func testOldAndNewSessionInfoDecodeSafeStartupErrors() throws {
        let old = Data(#"{"version":1,"id":"session","conversation_id":"conversation","assistant_id":"assistant","assistant_name":"Notes","state":"connecting"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(VoiceSessionInfo.self, from: old).message)
        let failed = Data(#"{"version":1,"id":"session","conversation_id":"conversation","assistant_id":"assistant","assistant_name":"Notes","state":"ended","message":"The PC voice service needs its organization API key restored."}"#.utf8)
        XCTAssertTrue(try XCTUnwrap(JSONDecoder().decode(VoiceSessionInfo.self, from: failed).message).contains("PC voice service"))
    }

    @MainActor
    func testShortcutAssistantQueryExcludesOtherAccountsAndDisabledVoice() async throws {
        let previousAccount = RecordingQueueStore.shared.accountID
        let previousCache = VoiceDescriptorCache.read()
        defer {
            RecordingQueueStore.shared.setAccount(previousAccount)
            if let previousCache { VoiceDescriptorCache.save(owner: previousCache.owner, configuration: previousCache.configuration) }
            else { VoiceDescriptorCache.clear() }
        }
        let config = VoiceConfiguration(version: 1, enabled: true, gateway_url: "https://pc.example.ts.net:8443/voice/v1",
            default_assistant_id: "assistant", assistants: [VoiceAssistantDescriptor(id: "assistant", name: "Notes", model: "gpt-realtime-2.1", voice: "marin")],
            models: ["gpt-realtime-2.1"], voices: ["marin"], session_seconds: 600, idle_seconds: 120)
        VoiceDescriptorCache.save(owner: "alice", configuration: config)
        RecordingQueueStore.shared.setAccount("alice")
        let own = try await VoiceAssistantQuery().suggestedEntities()
        XCTAssertEqual(own.map(\.id), ["assistant"])
        RecordingQueueStore.shared.setAccount("bob")
        let other = try await VoiceAssistantQuery().suggestedEntities()
        XCTAssertTrue(other.isEmpty)
        RecordingQueueStore.shared.setAccount("alice")
        VoiceDescriptorCache.save(owner: "alice", configuration: VoiceConfiguration(version: 1, enabled: false,
            gateway_url: config.gateway_url, default_assistant_id: config.default_assistant_id, assistants: config.assistants,
            models: config.models, voices: config.voices, session_seconds: config.session_seconds, idle_seconds: config.idle_seconds))
        let disabled = try await VoiceAssistantQuery().suggestedEntities()
        XCTAssertTrue(disabled.isEmpty)
        RecordingQueueStore.shared.setAccount(nil)
        let signedOut = try await VoiceAssistantQuery().suggestedEntities()
        XCTAssertTrue(signedOut.isEmpty)
    }
}
