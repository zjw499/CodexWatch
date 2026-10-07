import SwiftUI

private struct VoiceDiagnosticIndex: Decodable {
    struct Entry: Decodable, Identifiable {
        let id: String
        let owner: String
        let updated: Double
    }
    let reports: [Entry]
}
private struct VoiceDiagnosticDetail: Decodable { let report: VoiceDiagnosticReport }

struct PhoneVoiceDiagnosticsView: View {
    var review = false
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @State private var entries = [VoiceDiagnosticIndex.Entry]()
    @State private var message: String?
    var body: some View {
        List {
            Text("Watch audio tests and conversations send counters automatically. Reports contain no audio or conversation text.")
                .font(.footnote).foregroundStyle(ScribeTheme.muted)
            if review { Text("Opening reports here records an administrator review in the audit history.").font(.footnote) }
            ForEach(entries) { entry in
                NavigationLink {
                    PhoneVoiceDiagnosticDetailView(id: entry.id, review: review)
                } label: {
                    VStack(alignment: .leading) {
                        Text("Audio report \(entry.id.prefix(8))")
                        Text(Date(timeIntervalSince1970: entry.updated), style: .date).font(.caption)
                        if review { Text("Account: \(entry.owner)").font(.caption) }
                    }
                }
            }
            if entries.isEmpty && message == nil { Text("No Watch audio reports received yet.") }
            if let message { Text(message).font(.footnote) }
        }
        .navigationTitle("Watch audio reports").tint(ScribeTheme.red)
        .task { await load() }.refreshable { await load() }
        .onChange(of: workspace.user?.id) { _, _ in entries = []; message = nil }
    }
    private func load() async {
        let owner = workspace.user?.id
        do {
            let index: VoiceDiagnosticIndex = try await workspace.request("\(review ? "admin/voice" : "voice")/diagnostics")
            guard owner == workspace.user?.id else { return }
            entries = index.reports; message = nil
        } catch { if owner == workspace.user?.id { message = error.localizedDescription } }
    }
}

private struct PhoneVoiceDiagnosticDetailView: View {
    let id: String
    let review: Bool
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @Environment(\.dismiss) private var dismiss
    @State private var report: VoiceDiagnosticReport?
    @State private var message: String?
    @State private var deleting = false
    var body: some View {
        List {
            if let report {
                Text("Build \(report.build) · watchOS \(report.watch_os)")
                Text(report.kind == .audioTest ? "Local audio test" : "Conversation audio report")
                if let heard = report.speaker_heard { Text(heard ? "Speaker heard: yes" : "Speaker heard: no") }
                if let transport = report.transport {
                    Section("Connection and playback") {
                        Text("End reason: \(transport.endReason.rawValue)")
                        Text("Uploaded \(transport.uploadedBytes) bytes in \(transport.uploadRequests) requests")
                        Text("Upload time: last \(transport.lastUploadMs) ms · Maximum \(transport.maxUploadMs) ms")
                        Text("Unsent \(transport.pendingUploadBytes) bytes · Peak \(transport.peakUploadBytes)")
                        Text("Received \(transport.receivedAudioBytes) reply bytes")
                        Text("Playback queued \(transport.playbackFrames) frames · Peak \(transport.peakPlaybackFrames)")
                    }
                }
                ForEach(report.results) { result in
                    Section("\(result.id): \(result.phase.title)") {
                        Text("Input \(result.inputFrames) · Worker \(result.drainedFrames)")
                        Text("Converted \(result.convertedFrames) · Batches \(result.batches) · Pending \(result.pendingFrames)")
                        Text("Receiver fault \(result.receiverFailure) · Conversion errors \(result.conversionErrors)")
                        Text("Engine changes \(result.configurationChanges) · Attempts \(result.startupAttempts)")
                        Text("Capture \(Int(result.before.captureRate)) Hz / \(result.before.captureChannels) ch / \(result.before.captureFormat)")
                        Text("Engine at end: \(result.after.engineRunning ? "running" : "stopped") · Speaker frames \(result.renderedFrames)")
                        if let code = result.failureCode { Text(code) }
                        ForEach(Array(result.events.enumerated()), id: \.offset) { _, event in
                            Text("\(event.elapsedMs) ms · Attempt \(event.attempt) · \(event.kind.rawValue) · Input \(event.inputFrames) · Batches \(event.batches)")
                                .font(.caption)
                        }
                    }
                }
                if !review { Button("Delete report", role: .destructive) { deleting = true } }
            }
            if let message { Text(message).font(.footnote) }
        }
        .navigationTitle("Audio report").tint(ScribeTheme.red)
        .task {
            let owner = workspace.user?.id
            do {
                let detail: VoiceDiagnosticDetail = try await workspace.request("\(review ? "admin/voice" : "voice")/diagnostics/\(id)")
                guard owner == workspace.user?.id else { return }
                report = detail.report
            } catch { if owner == workspace.user?.id { message = error.localizedDescription } }
        }
        .onChange(of: workspace.user?.id) { _, _ in report = nil; dismiss() }
        .confirmationDialog("Delete this audio report?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    do { let _: PhoneWorkspace.OK = try await workspace.request("voice/diagnostics/\(id)", method: "DELETE"); dismiss() }
                    catch { message = error.localizedDescription }
                }
            }
        }
    }
}
