import XCTest
@testable import ScribePilot

private final class WorkspaceRecoveryStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class WorkspaceRecoveryTests: XCTestCase {
    private func fixture() throws -> (RecordingQueueStore, PhoneWorkspace, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("fixture.m4a")
        try Data(repeating: 7, count: 2048).write(to: audio)
        let queue = RecordingQueueStore(root: root.appendingPathComponent("queue"))
        queue.setAccount("alice")
        for index in 0..<3 {
            try queue.accept(fileURL: audio, id: "recovery", index: index, isFinal: index == 2, source: "Apple Watch", ownerID: "alice")
        }
        try queue.update("recovery") {
            $0.processingRequested = true; $0.requestedAssistantID = "notes"
            $0.requestedTranscriptionModel = "gpt-4o-transcribe"; $0.requestedProcessingID = "one-request"
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceRecoveryStub.self]
        let credential = WorkspaceCredential(token: "synthetic-token", user: WorkspaceUser(id: "alice", username: "alice", role: "user"), expires: Date().addingTimeInterval(3600).timeIntervalSince1970, server: "https://example.ts.net/workspace")
        let workspace = PhoneWorkspace(session: URLSession(configuration: configuration), credential: credential, assistants: [WorkspaceAssistant(id: "notes", name: "Notes", instructions: "Summarize.", model: "gpt-4.1-mini")])
        return (queue, workspace, root)
    }
    private func remote(_ state: String) -> Data {
        Data("{\"id\":\"recovery\",\"owner\":\"alice\",\"title\":\"Synthetic recording\",\"source\":\"Apple Watch\",\"state\":\"\(state)\",\"created\":1,\"updated\":2,\"expected_parts\":3,\"duration\":90,\"transcript\":\"All three parts recovered.\",\"summary\":\"Saved results\",\"chat\":[]}".utf8)
    }
    func testGatewayFailureRetainsRequestAcrossRelaunchAndResumesEveryPart() async throws {
        let (queue, workspace, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var offline = true
        var received = Set<Int>()
        var processRequests = 0
        let uploading = remote("uploading")
        WorkspaceRecoveryStub.handler = { request in
            let path = request.url!.path
            if path.contains("/parts/") {
                let index = Int(path.split(separator: "/").last!)!
                if offline && index == 1 { return (503, Data()) }
                received.insert(index)
                return (200, Data("{\"ok\":true}".utf8))
            }
            if path.hasSuffix("/process") { processRequests += 1; return (200, Data("{\"ok\":true}".utf8)) }
            return (200, uploading)
        }
        await PhoneOpenAIService(queue: queue, workspace: workspace).processOne("recovery")
        XCTAssertEqual(queue.recording("recovery")?.state, .queued)
        XCTAssertTrue(queue.recording("recovery")!.awaitingConnection)
        XCTAssertEqual(received, [0])
        let reopened = RecordingQueueStore(root: root.appendingPathComponent("queue"))
        reopened.setAccount("alice")
        XCTAssertTrue(reopened.recording("recovery")!.processingRequested!)
        XCTAssertEqual(reopened.recording("recovery")?.requestedProcessingID, "one-request")
        offline = false
        await PhoneOpenAIService(queue: reopened, workspace: workspace).processOne("recovery")
        XCTAssertEqual(received, [0, 1, 2])
        XCTAssertEqual(processRequests, 1)
        XCTAssertEqual(reopened.recording("recovery")?.processingRequested, false)
        XCTAssertEqual(reopened.recording("recovery")?.state, .processing)
        XCTAssertNil(reopened.recording("recovery")?.retryAfter)
    }
    func testCompletedResultsRecoverAfterLostAcknowledgmentAndAnEditConflict() async throws {
        let (queue, workspace, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var processRequests = 0
        let ready = remote("ready")
        WorkspaceRecoveryStub.handler = { request in
            if request.url!.path.hasSuffix("/process") {
                processRequests += 1
                throw URLError(.networkConnectionLost)
            }
            return (200, request.url!.path.contains("/parts/") ? Data("{\"ok\":true}".utf8) : ready)
        }
        let service = PhoneOpenAIService(queue: queue, workspace: workspace)
        await service.processOne("recovery")
        XCTAssertTrue(queue.recording("recovery")!.awaitingConnection)
        try queue.update("recovery") { $0.pendingTitle = "Pending title" }
        WorkspaceRecoveryStub.handler = { request in
            if request.httpMethod == "PATCH" { return (409, Data()) }
            return (200, Data("{\"recordings\":".utf8) + Data("[".utf8) + ready + Data("]}".utf8))
        }
        await service.reconcile()
        XCTAssertEqual(queue.recording("recovery")?.state, .ready)
        XCTAssertEqual(queue.recording("recovery")?.transcript, "All three parts recovered.")
        XCTAssertEqual(queue.recording("recovery")?.processingRequested, false)
        XCTAssertEqual(queue.recording("recovery")?.pendingTitle, "Pending title")
        XCTAssertEqual(processRequests, 1)
    }
    func testOldGatewayFailuresRecoverButAuthorizationErrorsStayActionable() throws {
        let (queue, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try queue.update("recovery") { $0.state = .failed; $0.processingRequested = false; $0.error = "The PC could not complete this request. Try again." }
        let reopened = RecordingQueueStore(root: root.appendingPathComponent("queue"))
        XCTAssertTrue(reopened.recording("recovery")!.awaitingConnection)
        XCTAssertFalse(WorkspaceError.retryable(WorkspaceError.status(401, "Sign in again.")))
        XCTAssertFalse(WorkspaceError.retryable(WorkspaceError.status(422, "Choose an approved model.")))
    }
}
