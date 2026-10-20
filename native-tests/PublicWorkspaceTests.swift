import XCTest
@testable import ScribePilot

private final class PublicWorkspaceStub: URLProtocol {
    static var handler: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handler?(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class PublicWorkspaceTests: XCTestCase {
    func testProductionDefaultAndLegacyAddressesUseTheInternetConnection() {
        XCTAssertEqual(PhoneWorkspace.validServer(PhoneWorkspace.defaultServer)?.absoluteString, PhoneWorkspace.defaultServer)
        for old in [PhoneWorkspace.legacyServer, PhoneWorkspace.legacyServer + "/", "https://zwyattpc.tail488e93.ts.net:443/workspace"] {
            XCTAssertEqual(PhoneWorkspace.validServer(old)?.absoluteString, PhoneWorkspace.defaultServer)
        }
        XCTAssertEqual(PhoneWorkspace.validServer("https://other.ts.net/workspace/")?.absoluteString, "https://other.ts.net/workspace")
        XCTAssertEqual(PhoneWorkspace.validServer(PhoneWorkspace.defaultServer + "/")?.absoluteString, PhoneWorkspace.defaultServer)
    }

    func testPublicAddressValidationRejectsCredentialsAndUnapprovedDestinations() {
        for value in ["http://zwyattpc.tail488e93.ts.net:8443/app", "https://example.com:8443/app",
                      "https://user@zwyattpc.tail488e93.ts.net:8443/app", "https://other.ts.net:8443/app?token=secret",
                      "https://other.ts.net:8443/app#fragment", "https://other.ts.net/app",
                      "https://other.ts.net:8443/workspace", "https://other.ts.net:9443/app",
                      "https://other.ts.net:8443/app/../workspace"] {
            XCTAssertNil(PhoneWorkspace.validServer(value), value)
        }
    }

    func testSavedSessionsAndPendingRevocationsUsePublicRequestsWithoutChangingAccount() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublicWorkspaceStub.self]
        let credential = WorkspaceCredential(token: "synthetic-session", user: WorkspaceUser(id: "alice", username: "alice", role: "user"),
                                             expires: Date().timeIntervalSince1970 + 3600, server: PhoneWorkspace.legacyServer)
        let workspace = PhoneWorkspace(session: URLSession(configuration: configuration), credential: credential, assistants: [])
        var requests = 0
        PublicWorkspaceStub.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.host, "zwyattpc.tail488e93.ts.net")
            XCTAssertEqual(request.url?.port, 8443)
            XCTAssertEqual(request.url?.path, requests == 1 ? "/app/api/me" : "/app/api/session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), requests == 1 ? "Bearer synthetic-session" : "Bearer pending-session")
        }
        defer { PublicWorkspaceStub.handler = nil }
        _ = try await workspace.rawRequest("me")
        _ = try await workspace.rawRequest("session", method: "DELETE", base: PhoneWorkspace.legacyServer, token: "pending-session")
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(workspace.user?.id, "alice")
        XCTAssertEqual(workspace.credential?.token, credential.token)
        XCTAssertEqual(workspace.credential?.expires, credential.expires)
    }
}
