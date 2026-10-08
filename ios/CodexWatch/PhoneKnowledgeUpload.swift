import CryptoKit
import Foundation

struct KnowledgeFile: Decodable, Identifiable {
    let id: String
    let filename: String
    let bytes: Int
    let state: String
    let characters: Int
    let upload_version: Int?
    let chunk_bytes: Int?
    let uploaded_bytes: Int?
    let error_code: String?
    let error_message: String?
    var uploadedBytes: Int { min(bytes, max(0, uploaded_bytes ?? (state == "ready" ? bytes : 0))) }
}
struct KnowledgeFileList: Decodable {
    let files: [KnowledgeFile]
    let max_bytes: Int
    let max_files: Int
    let max_total_bytes: Int?
    let max_characters: Int?
    let max_pdf_pages: Int?
    var totalBytes: Int { max_total_bytes ?? 5 * max_bytes }
    var characters: Int { max_characters ?? 500_000 }
    var pdfPages: Int { max_pdf_pages ?? 250 }
}
struct KnowledgePreview: Decodable {
    let file: KnowledgeFile
    let text: String
    let next_offset: Int?
}
struct KnowledgeRequestFailure: Decodable { let detail: String }

enum KnowledgeFileError: LocalizedError {
    case unsupported, size(Int), empty, account, protocolMismatch
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Choose a PDF, Word (.docx), text, Markdown, or CSV file."
        case .size(let limit): return "Choose a file up to \(limit / (1024 * 1024)) MB, or split it into smaller files."
        case .empty: return "This file is empty. Choose a file with readable text."
        case .account: return "Your account changed. Open this assistant from Settings again."
        case .protocolMismatch: return "The PC returned an invalid upload position. Refresh and retry."
        }
    }
}

struct KnowledgeUpload: Sendable {
    static let maxBytes = 100 * 1024 * 1024
    let id: String
    let filename: String
    let data: Data
    let sha256: String

    static func read(_ url: URL, maxBytes requestedLimit: Int = maxBytes, id: String? = nil) throws -> KnowledgeUpload {
        let limit = max(0, min(requestedLimit, maxBytes))
        guard ["pdf", "docx", "txt", "md", "csv"].contains(url.pathExtension.lowercased()) else {
            throw KnowledgeFileError.unsupported
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit {
            throw KnowledgeFileError.size(limit)
        }
        var data = Data()
        while let part = try handle.read(upToCount: 65536), !part.isEmpty {
            guard data.count <= limit - part.count else { throw KnowledgeFileError.size(limit) }
            data.append(part)
        }
        guard !data.isEmpty else { throw KnowledgeFileError.empty }
        return KnowledgeUpload(id: id ?? UUID().uuidString, filename: url.lastPathComponent.precomposedStringWithCanonicalMapping, data: data,
                               sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

struct KnowledgeUploadProgress {
    let uploadedBytes: Int
    let totalBytes: Int
    let reading: Bool
}

extension PhoneWorkspace {
    func knowledgeFiles(_ assistantID: String) async throws -> KnowledgeFileList {
        guard VoiceWire.validID(assistantID) else { throw WorkspaceError.missingAssistant }
        return try await request("assistants/\(assistantID)/knowledge")
    }
    func knowledgePreview(_ assistantID: String, fileID: String, offset: Int = 0) async throws -> KnowledgePreview {
        guard VoiceWire.validID(assistantID), VoiceWire.validID(fileID), offset >= 0 else { throw WorkspaceError.missingAssistant }
        return try await request("assistants/\(assistantID)/knowledge/\(fileID)?offset=\(offset)")
    }
    func uploadKnowledge(_ upload: KnowledgeUpload, assistantID: String,
                         onProgress: ((KnowledgeUploadProgress) -> Void)? = nil) async throws -> KnowledgeFile {
        guard VoiceWire.validID(assistantID), VoiceWire.validID(upload.id), let captured = credential else {
            throw WorkspaceError.signIn
        }
        struct Begin: Encodable { let filename: String; let bytes: Int; let sha256: String }
        let path = "assistants/\(assistantID)/knowledge/\(upload.id)"
        let metadata = try JSONEncoder().encode(Begin(filename: upload.filename, bytes: upload.data.count, sha256: upload.sha256))
        var file: KnowledgeFile = try await knowledgeRetry { try await request(path, method: "PUT", body: metadata) }
        guard captured.token == credential?.token else { throw KnowledgeFileError.account }
        if file.state == "ready" { return file }
        // Optional fields allow safe operation with older PCs during rollout.
        guard file.upload_version == 1, let chunkBytes = file.chunk_bytes else {
            onProgress?(KnowledgeUploadProgress(uploadedBytes: 0, totalBytes: upload.data.count, reading: false))
            let data = try await rawRequest(path + "/content", method: "PUT", body: upload.data, contentType: "application/octet-stream")
            guard captured.token == credential?.token else { throw KnowledgeFileError.account }
            return try JSONDecoder().decode(KnowledgeFile.self, from: data)
        }
        guard chunkBytes > 0, chunkBytes <= 1024 * 1024, file.bytes == upload.data.count else { throw KnowledgeFileError.protocolMismatch }
        // A lost final response can leave reading in progress. Wait for its result
        // rather than starting another parser or sending the body again.
        for _ in 0..<45 where file.state == "reading" {
            onProgress?(KnowledgeUploadProgress(uploadedBytes: file.uploadedBytes, totalBytes: upload.data.count, reading: true))
            try await Task.sleep(for: .seconds(2))
            file = try await knowledgeRetry { try await request(path, method: "PUT", body: metadata) }
            guard captured.token == credential?.token else { throw KnowledgeFileError.account }
        }
        if file.state == "ready" { return file }
        guard let offset = file.uploaded_bytes, offset >= 0, offset <= upload.data.count,
              offset == upload.data.count || offset % chunkBytes == 0 else { throw KnowledgeFileError.protocolMismatch }
        var position = offset
        onProgress?(KnowledgeUploadProgress(uploadedBytes: position, totalBytes: upload.data.count, reading: false))
        while position < upload.data.count {
            try Task.checkCancellation()
            guard captured.token == credential?.token else { throw KnowledgeFileError.account }
            let end = min(position + chunkBytes, upload.data.count)
            let batch = upload.data.subdata(in: position..<end)
            let batchPath = path + "/chunks/\(position / chunkBytes)"
            file = try await knowledgeRetry {
                let data = try await rawRequest(batchPath, method: "PUT", body: batch, contentType: "application/octet-stream")
                return try JSONDecoder().decode(KnowledgeFile.self, from: data)
            }
            guard captured.token == credential?.token else { throw KnowledgeFileError.account }
            guard file.id == upload.id, file.uploaded_bytes == end || file.state == "ready" else { throw KnowledgeFileError.protocolMismatch }
            if file.state == "ready" { return file }
            position = end
            onProgress?(KnowledgeUploadProgress(uploadedBytes: position, totalBytes: upload.data.count, reading: false))
        }
        onProgress?(KnowledgeUploadProgress(uploadedBytes: position, totalBytes: upload.data.count, reading: true))
        file = try await knowledgeRetry { try await request(path + "/complete", method: "POST") }
        guard captured.token == credential?.token else { throw KnowledgeFileError.account }
        guard file.state == "ready" else { throw KnowledgeFileError.protocolMismatch }
        return file
    }
    private func knowledgeRetry<T>(_ operation: () async throws -> T) async throws -> T {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                guard !Task.isCancelled, attempt < 2, WorkspaceError.retryable(error) else { throw error }
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw KnowledgeFileError.protocolMismatch
    }
    func removeKnowledge(_ assistantID: String, fileID: String) async throws {
        guard VoiceWire.validID(assistantID), VoiceWire.validID(fileID) else { throw WorkspaceError.missingAssistant }
        let _: OK = try await request("assistants/\(assistantID)/knowledge/\(fileID)", method: "DELETE")
    }
}
