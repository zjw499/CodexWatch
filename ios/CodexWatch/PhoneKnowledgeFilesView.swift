import SwiftUI
import UniformTypeIdentifiers

struct PhoneKnowledgeFilesView: View {
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @Environment(\.dismiss) private var dismiss
    let assistantID: String
    let assistantName: String
    @State private var files: [KnowledgeFile] = []
    @State private var limits: KnowledgeFileList?
    @State private var importing = false
    @State private var working = false
    @State private var pending: KnowledgeUpload?
    @State private var removing: KnowledgeFile?
    @State private var message: String?
    @State private var parentToken: String?
    @State private var resuming: KnowledgeFile?
    @State private var progress: KnowledgeUploadProgress?

    var body: some View {
        List {
            Section(assistantName) {
                ForEach(files) { file in
                    if file.state == "ready" {
                    NavigationLink {
                        PhoneKnowledgePreviewView(assistantID: assistantID, file: file)
                    } label: { fileLabel(file) }
                    .swipeActions { Button("Remove", role: .destructive) { removing = file } }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            fileLabel(file)
                            if let reason = file.error_message {
                                Text(reason + (file.error_code.map { " (\($0))" } ?? ""))
                                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
                            }
                            Button("Resume upload") { resuming = file; importing = true }
                                .disabled(working)
                        }
                        .swipeActions { Button("Remove", role: .destructive) { removing = file } }
                    }
                }
                if files.isEmpty { Text("No knowledge files yet.").foregroundStyle(ScribeTheme.muted) }
                Button { resuming = nil; importing = true } label: { Label("Add files", systemImage: "plus.circle") }
                    .disabled(working || limits == nil || files.count >= (limits?.max_files ?? 20)).accessibilityIdentifier("knowledge-add-files")
                if working {
                    if let progress {
                        if progress.reading { ProgressView("Upload saved · reading file…") }
                        else {
                            ProgressView(value: Double(progress.uploadedBytes), total: Double(progress.totalBytes))
                            Text("Uploaded \(ByteCountFormatter.string(fromByteCount: Int64(progress.uploadedBytes), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(progress.totalBytes), countStyle: .file))")
                                .font(.caption)
                        }
                    } else { ProgressView("Preparing file…") }
                }
                if pending != nil, !working {
                    Button("Retry upload") { uploadPending() }
                }
            }
            Section {
                if let limits {
                    Text("PDF, Word (.docx), text, Markdown, and CSV. Up to \(min(limits.max_bytes, KnowledgeUpload.maxBytes) / (1024 * 1024)) MB per file, \(limits.max_files) files and \(limits.totalBytes / (1024 * 1024)) MB per assistant. Each file can contain up to \(limits.characters.formatted()) text characters; PDFs up to \(limits.pdfPages.formatted()) pages. PDFs need selectable text; scanned images are not read.")
                } else {
                    Text("PDF, Word (.docx), text, Markdown, and CSV. Connecting to check upload limits…")
                }
                Text("Files stay in your protected PC workspace. Relevant text is sent to the approved voice model when needed. Start a new conversation after adding files. Removing a file ends any active conversation using this assistant; answers already saved in History remain until you delete the conversation.")
                Text("Interrupted uploads keep encrypted progress on the PC. Choose Resume upload and select the original file to continue, including after reopening the app. Keep Scribe Pilot open while uploading.")
            }.font(.footnote).foregroundStyle(ScribeTheme.muted)
            if let message { Text(message).font(.footnote).foregroundStyle(ScribeTheme.muted) }
        }
        .navigationTitle("Knowledge files").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(ScribeTheme.background).tint(ScribeTheme.red)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .plainText, .commaSeparatedText,
            UTType(filenameExtension: "docx") ?? .data, UTType(filenameExtension: "md") ?? .plainText], allowsMultipleSelection: resuming == nil) { result in
            switch result {
            case .success(let urls):
                let readLimit = limits?.max_bytes ?? 0
                let resumeID = resuming?.id
                resuming = nil; working = true; message = nil; progress = nil
                Task {
                    defer { working = false }
                    do {
                        for url in urls {
                            try checkAccount()
                            let value = try await Task.detached { try KnowledgeUpload.read(url, maxBytes: readLimit, id: resumeID) }.value
                            try checkAccount()
                            pending = value
                            _ = try await workspace.uploadKnowledge(value, assistantID: assistantID) { progress = $0 }
                            try checkAccount()
                            pending = nil
                            try await loadFiles()
                        }
                        await workspace.refresh()
                    } catch is CancellationError { }
                    catch { showUploadError(error); await reload() }
                }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .task {
            parentToken = workspace.credential?.token
            await reload()
        }
        .refreshable { await reload() }
        .onChange(of: workspace.credential?.token) { _, _ in
            pending = nil; files = []; limits = nil; message = nil; progress = nil; dismiss()
        }
        .confirmationDialog("Remove this knowledge file?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let file = removing {
                Button("Remove file", role: .destructive) {
                    working = true
                    Task {
                        defer { working = false; removing = nil }
                        do {
                            try checkAccount()
                            try await workspace.removeKnowledge(assistantID, fileID: file.id)
                            if pending?.id == file.id { pending = nil }
                            await reload(); await workspace.refresh()
                        } catch { message = error.localizedDescription }
                    }
                }
            }
        } message: { Text("Future conversations will no longer retrieve this file. Saved answers remain in History.") }
    }
    private func fileLabel(_ file: KnowledgeFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(file.filename, systemImage: "doc.text").privacySensitive()
            Text(file.state == "ready" ? "Ready · \(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))" :
                 "\(file.state == "reading" ? "Reading file" : "Upload incomplete") · \(ByteCountFormatter.string(fromByteCount: Int64(file.uploadedBytes), countStyle: .file)) saved")
                .font(.caption).foregroundStyle(ScribeTheme.muted)
        }
    }
    private func showUploadError(_ error: Error) {
        if error is URLError {
            message = "The connection interrupted this upload. Saved batches remain on the PC. Retry, or choose Resume upload and select the original file."
        } else { message = error.localizedDescription }
    }
    private func checkAccount() throws {
        guard parentToken != nil, parentToken == workspace.credential?.token else { throw KnowledgeFileError.account }
    }
    private func reload() async {
        do { try checkAccount(); try await loadFiles() }
        catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
    private func loadFiles() async throws {
        let value = try await workspace.knowledgeFiles(assistantID)
        try checkAccount()
        files = value.files; limits = value
    }
    private func uploadPending() {
        guard let pending else { return }
        working = true; message = nil; progress = nil
        Task {
            defer { working = false }
            do {
                try checkAccount()
                _ = try await workspace.uploadKnowledge(pending, assistantID: assistantID) { progress = $0 }
                try checkAccount()
                self.pending = nil; await reload(); await workspace.refresh()
            } catch is CancellationError { }
            catch { showUploadError(error); await reload() }
        }
    }
}

private struct PhoneKnowledgePreviewView: View {
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @Environment(\.dismiss) private var dismiss
    let assistantID: String
    let file: KnowledgeFile
    @State private var text = ""
    @State private var nextOffset: Int? = 0
    @State private var working = false
    @State private var message: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Extracted text available to the assistant").font(.caption).foregroundStyle(ScribeTheme.muted)
                Text(text).textSelection(.enabled).privacySensitive()
                if working { ProgressView() }
                if nextOffset != nil { Button("Load more") { Task { await load() } }.disabled(working) }
                if let message { Text(message).font(.footnote).foregroundStyle(ScribeTheme.muted) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle(file.filename).navigationBarTitleDisplayMode(.inline)
        .background(ScribeTheme.background).tint(ScribeTheme.red)
        .task { await load() }
        .onChange(of: workspace.credential?.token) { _, _ in text = ""; dismiss() }
    }
    private func load() async {
        guard !working, let offset = nextOffset else { return }
        working = true
        defer { working = false }
        do {
            let preview = try await workspace.knowledgePreview(assistantID, fileID: file.id, offset: offset)
            text += preview.text; nextOffset = preview.next_offset
        } catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
}
