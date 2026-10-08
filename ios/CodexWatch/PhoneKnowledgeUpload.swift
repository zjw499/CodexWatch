import CryptoKit
import Foundation

struct KnowledgeFile: Decodable, Identifiable {
    let id: String
    let filename: String
    let bytes: Int
    let state: String
    let characters: Int
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
    case unsupported, size(Int), empty, account
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Choose a PDF, Word (.docx), text, Markdown, or CSV file."
        case .size(let limit): return "Choose a file up to \(limit / (1024 * 1024)) MB, or split it into smaller files."
        case .empty: return "This file is empty. Choose a file with readable text."
        case .account: return "Your account changed. Open this assistant from Settings again."
        }
    }
}

struct KnowledgeUpload: Sendable {
    static let maxBytes = 100 * 1024 * 1024
    let id: String
    let filename: String
    let data: Data
    let sha256: String

    static func read(_ url: URL, maxBytes requestedLimit: Int = maxBytes) throws -> KnowledgeUpload {
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
        return KnowledgeUpload(id: UUID().uuidString, filename: url.lastPathComponent, data: data,
                               sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
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
    func uploadKnowledge(_ upload: KnowledgeUpload, assistantID: String) async throws -> KnowledgeFile {
        guard VoiceWire.validID(assistantID), VoiceWire.validID(upload.id), let captured = credential else {
            throw WorkspaceError.signIn
        }
        struct Begin: Encodable { let filename: String; let bytes: Int; let sha256: String }
        let path = "assistants/\(assistantID)/knowledge/\(upload.id)"
        let file: KnowledgeFile = try await request(path, method: "PUT", body: JSONEncoder().encode(
            Begin(filename: upload.filename, bytes: upload.data.count, sha256: upload.sha256)))
        guard captured.token == credential?.token else { throw KnowledgeFileError.account }
        if file.state == "ready" { return file }
        let data = try await rawRequest(path + "/content", method: "PUT", body: upload.data, contentType: "application/octet-stream")
        guard captured.token == credential?.token else { throw KnowledgeFileError.account }
        return try JSONDecoder().decode(KnowledgeFile.self, from: data)
    }
    func removeKnowledge(_ assistantID: String, fileID: String) async throws {
        guard VoiceWire.validID(assistantID), VoiceWire.validID(fileID) else { throw WorkspaceError.missingAssistant }
        let _: OK = try await request("assistants/\(assistantID)/knowledge/\(fileID)", method: "DELETE")
    }
}
