import XCTest
@testable import ScribePilot

private final class OpenAIStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class OpenAIClientTests: XCTestCase {
    private func client() -> PhoneOpenAIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIStub.self]
        return PhoneOpenAIClient(session: URLSession(configuration: configuration))
    }

    func testUnconfirmedProtectedWorkflowDoesNotSendAudio() async throws {
        var called = false
        OpenAIStub.handler = { _ in called = true; return (200, Data()) }
        do {
            _ = try await client().transcribe(URL(fileURLWithPath: "/missing-audio.m4a"), key: "test-key", configuration: OpenAIConfiguration())
            XCTFail("Unconfirmed workflow sent audio")
        } catch OpenAIError.setupRequired {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(called)
    }

    func testTranscriptionUsesOnlyOpenAIAndScopesProjectHeaders() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data(repeating: 1, count: 2048).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var configuration = OpenAIConfiguration()
        configuration.protectedMode = false
        configuration.projectID = "proj_test"
        OpenAIStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Project"), "proj_test")
            return (200, Data(#"{"text":"Test recording."}"#.utf8))
        }
        let text = try await client().transcribe(file, key: "test-key", configuration: configuration)
        XCTAssertEqual(text, "Test recording.")
    }

    func testMeetingNotesDisableResponseStorage() async throws {
        var configuration = OpenAIConfiguration()
        configuration.protectedMode = false
        OpenAIStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(payload["store"] as? Bool, false)
            return (200, Data(#"{"output":[{"content":[{"type":"output_text","text":"Meeting notes."}]}]}"#.utf8))
        }
        let notes = try await client().notes(transcript: "Synthetic fixture.", key: "test-key", configuration: configuration)
        XCTAssertEqual(notes, "Meeting notes.")
    }

    func testProviderErrorNeverExposesResponseBody() async {
        OpenAIStub.handler = { _ in (401, Data("sensitive provider content".utf8)) }
        do {
            try await client().testAccess(key: "test-key", configuration: OpenAIConfiguration())
            XCTFail("Invalid key passed")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("sensitive provider content"))
        }
    }
}
