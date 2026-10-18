import XCTest
@testable import ScribePilot

private final class KnowledgeStub: URLProtocol {
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
    override func stopLoading() { }
}

@MainActor
final class KnowledgeUploadTests: XCTestCase {
    private func workspace() -> PhoneWorkspace {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KnowledgeStub.self]
        let credential = WorkspaceCredential(token: "synthetic-token", user: WorkspaceUser(id: "alice", username: "alice", role: "user"), expires: Date().addingTimeInterval(3600).timeIntervalSince1970, server: "https://example.ts.net/workspace")
        return PhoneWorkspace(session: URLSession(configuration: configuration), credential: credential, assistants: [WorkspaceAssistant(id: "notes", name: "Notes", instructions: "Answer from files", model: "gpt-4.1-mini")])
    }
    private func descriptor(_ state: String) -> Data {
        Data("{\"id\":\"file-1\",\"filename\":\"Orbit.txt\",\"bytes\":5,\"state\":\"\(state)\",\"characters\":5}".utf8)
    }
    func testLostUploadAcknowledgementRetriesSameIDWithoutSendingContentAgain() async throws {
        let workspace = workspace()
        let upload = KnowledgeUpload(id: "file-1", filename: "Orbit.txt", data: Data("Orbit".utf8), sha256: String(repeating: "a", count: 64))
        var ready = false, bodies = 0
        var paths: [String] = []
        let uploading = descriptor("uploading"), completed = descriptor("ready")
        KnowledgeStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
            paths.append(request.url!.path)
            if request.url!.path.hasSuffix("/content") {
                bodies += 1; ready = true
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
                throw URLError(.networkConnectionLost)
            }
            return (200, ready ? completed : uploading)
        }
        do {
            _ = try await workspace.uploadKnowledge(upload, assistantID: "notes")
            XCTFail("First acknowledgement must fail")
        } catch { XCTAssertTrue(error is URLError) }
        let restored = try await workspace.uploadKnowledge(upload, assistantID: "notes")
        XCTAssertEqual(restored.state, "ready")
        XCTAssertEqual(bodies, 1)
        XCTAssertEqual(paths, ["/workspace/api/assistants/notes/knowledge/file-1", "/workspace/api/assistants/notes/knowledge/file-1/content", "/workspace/api/assistants/notes/knowledge/file-1"])
    }
    func testKnowledgeErrorsShowExtractionReasonAndRejectPathInjection() async throws {
        let workspace = workspace()
        var requests = 0
        KnowledgeStub.handler = { _ in
            requests += 1
            return (422, Data(#"{"detail":"No readable text was found. Scanned PDFs need a text layer"}"#.utf8))
        }
        do { _ = try await workspace.knowledgePreview("notes", fileID: "file-1"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("text layer")) }
        do { _ = try await workspace.knowledgeFiles("../other-owner"); XCTFail() }
        catch { XCTAssertEqual(requests, 1) }
    }
    func testBatchedUploadRetriesLostAcknowledgementAndResumesOnlyMissingBytes() async throws {
        let workspace = workspace()
        let size = 1024 * 1024
        let upload = KnowledgeUpload(id: "file-1", filename: "Large.pdf", data: Data(repeating: 65, count: size + 7), sha256: String(repeating: "a", count: 64))
        var saved = 0, ready = false, interrupted = true
        var batches: [Int] = [], attempts = 0, completions = 0
        var progress: [Int] = []
        func file() -> Data {
            Data("{\"id\":\"file-1\",\"filename\":\"Large.pdf\",\"bytes\":\(size + 7),\"state\":\"\(ready ? "ready" : "uploading")\",\"characters\":0,\"upload_version\":1,\"chunk_bytes\":\(size),\"uploaded_bytes\":\(saved)}".utf8)
        }
        KnowledgeStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
            let path = request.url!.path
            XCTAssertFalse(path.hasSuffix("/content"))
            if path.contains("/chunks/") {
                let index = Int(path.split(separator: "/").last!)!
                batches.append(index)
                if index == 0 {
                    saved = size
                    if batches.count == 1 { throw URLError(.networkConnectionLost) }
                } else {
                    attempts += 1
                    if interrupted { throw URLError(.networkConnectionLost) }
                    saved = size + 7
                }
            } else if path.hasSuffix("/complete") {
                completions += 1; ready = true
                if completions == 1 { throw URLError(.networkConnectionLost) }
            }
            return (200, file())
        }
        do {
            _ = try await workspace.uploadKnowledge(upload, assistantID: "notes") { progress.append($0.uploadedBytes) }
            XCTFail("A sustained connection loss must stop after bounded retries")
        } catch { XCTAssertTrue(error is URLError) }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(batches, [0, 0, 1, 1, 1])
        interrupted = false
        let result = try await workspace.uploadKnowledge(upload, assistantID: "notes") { progress.append($0.uploadedBytes) }
        XCTAssertEqual(result.state, "ready")
        XCTAssertEqual(batches, [0, 0, 1, 1, 1, 1])
        XCTAssertEqual(completions, 2)
        XCTAssertTrue(progress.contains(size) && progress.contains(size + 7))
    }
    func testInvalidSavedOffsetDoesNotSendAnyFileBytes() async throws {
        let workspace = workspace()
        let upload = KnowledgeUpload(id: "file-1", filename: "Large.pdf", data: Data(repeating: 65, count: 2 * 1024 * 1024), sha256: String(repeating: "a", count: 64))
        var requests = 0
        KnowledgeStub.handler = { request in
            requests += 1
            XCTAssertFalse(request.url!.path.contains("/chunks/"))
            return (200, Data(#"{"id":"file-1","filename":"Large.pdf","bytes":2097152,"state":"uploading","characters":0,"upload_version":1,"chunk_bytes":1048576,"uploaded_bytes":7}"#.utf8))
        }
        do { _ = try await workspace.uploadKnowledge(upload, assistantID: "notes"); XCTFail() }
        catch { XCTAssertTrue(error is KnowledgeFileError) }
        XCTAssertEqual(requests, 1)
    }
    func testSavedUploadProgressAndReaderFailureDecodeWithoutBreakingOldDescriptors() throws {
        let old = try JSONDecoder().decode(KnowledgeFile.self, from: descriptor("uploading"))
        XCTAssertNil(old.upload_version)
        XCTAssertEqual(old.uploadedBytes, 0)
        let failed = try JSONDecoder().decode(KnowledgeFile.self, from: Data(#"{"id":"file-1","filename":"Orbit.pdf","bytes":42,"state":"failed","characters":0,"upload_version":1,"chunk_bytes":1048576,"uploaded_bytes":42,"error_code":"FILE_NO_TEXT","error_message":"No readable text was found"}"#.utf8))
        XCTAssertEqual(failed.uploadedBytes, 42)
        XCTAssertEqual(failed.error_code, "FILE_NO_TEXT")
    }
    func testFileReaderRejectsOversizedEmptyAndUnsupportedFilesAndHashesAcceptedText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Orbit.txt")
        try Data("hello".utf8).write(to: url)
        let accepted = try KnowledgeUpload.read(url)
        XCTAssertEqual(accepted.data, Data("hello".utf8))
        XCTAssertEqual(accepted.sha256, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(try KnowledgeUpload.read(url, id: "existing-upload").id, "existing-upload")
        try Data().write(to: url)
        XCTAssertThrowsError(try KnowledgeUpload.read(url))
        // A sparse file checks the 100 MB guard without allocating its full body.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(KnowledgeUpload.maxBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try KnowledgeUpload.read(url))
        XCTAssertThrowsError(try KnowledgeUpload.read(root.appendingPathComponent("image.png")))
    }
    func testReaderHonorsServerLimitAndDecodesLegacyAndExpandedLimits() throws {
        let old = try JSONDecoder().decode(KnowledgeFileList.self, from: Data(#"{"files":[],"max_bytes":10485760,"max_files":20}"#.utf8))
        XCTAssertEqual(old.totalBytes, 50 * 1024 * 1024)
        XCTAssertEqual(old.pdfPages, 250)
        let expanded = try JSONDecoder().decode(KnowledgeFileList.self, from: Data(#"{"files":[],"max_bytes":104857600,"max_files":20,"max_total_bytes":524288000,"max_characters":2000000,"max_pdf_pages":1000}"#.utf8))
        XCTAssertEqual(expanded.totalBytes, 500 * 1024 * 1024)
        XCTAssertEqual(expanded.characters, 2_000_000)
        XCTAssertEqual(expanded.pdfPages, 1000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 65, count: 11 * 1024 * 1024).write(to: url)
        XCTAssertEqual(try KnowledgeUpload.read(url).data.count, 11 * 1024 * 1024)
        XCTAssertThrowsError(try KnowledgeUpload.read(url, maxBytes: old.max_bytes))
        XCTAssertThrowsError(try KnowledgeUpload.read(url, maxBytes: 0))
    }
    func testKnowledgeSourcesDecodeAsLabelsWithoutExternalLinksAndLegacyDefaultsStayPrivate() throws {
        let source = try JSONDecoder().decode(VoiceSource.self, from: Data(#"{"title":"Orbit.pdf · Page 2","url":"knowledge://file-1#3","kind":"knowledge","file_id":"file-1","location":"Page 2"}"#.utf8))
        XCTAssertNil(source.link)
        XCTAssertEqual(source.location, "Page 2")
        let old = try JSONDecoder().decode(VoiceAssistantSettings.self, from: Data(#"{"enabled":true,"web_search":true}"#.utf8))
        XCTAssertFalse(old.knowledge_public)
        var publicFiles = old; publicFiles.knowledge_public = true
        XCTAssertTrue(try JSONDecoder().decode(VoiceAssistantSettings.self, from: JSONEncoder().encode(publicFiles)).knowledge_public)
        let oldAssistant = try JSONDecoder().decode(WorkspaceAssistant.self, from: Data(#"{"id":"notes","name":"Notes","instructions":"Answer","model":"gpt-4.1-mini"}"#.utf8))
        XCTAssertNil(oldAssistant.knowledge_file_count)
    }
}
