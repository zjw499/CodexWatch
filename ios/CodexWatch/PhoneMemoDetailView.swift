import SwiftUI

struct PhoneMemoDetailView: View {
    @EnvironmentObject private var memoService: PhoneMemoService
    @Environment(\.dismiss) private var dismiss
    let memo: MemoSummary
    @State private var detail: MemoDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let detail {
                    Text(detail.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    HStack(spacing: 8) {
                        Text(detail.source.lowercased().contains("watch") ? "Apple Watch" : "iPhone")
                        Text("•")
                        Text(detail.status.replacingOccurrences(of: "_", with: " ").capitalized)
                        if let count = detail.speakerCount, count > 1 {
                            Text("•")
                            Text("\(count) speakers")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))

                    if let summary = detail.summary, !summary.isEmpty {
                        section(title: "Summary", icon: "sparkles") {
                            Text(summary)
                        }
                    }

                    section(title: "Transcript", icon: "text.quote") {
                        Text(detail.transcript.isEmpty ? "Transcript is not available yet." : detail.transcript)
                            .textSelection(.enabled)
                    }

                    if detail.status == "failed" || detail.status == "email_failed" {
                        Button {
                            Task { await memoService.retry(memo) }
                        } label: {
                            Label("Retry processing", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if !detail.transcript.isEmpty {
                        ShareLink(item: detail.transcript) {
                            Label("Share transcript", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                } else if isLoading {
                    ProgressView("Loading memo")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(20)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .navigationTitle("Memo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        Task {
                            await memoService.delete(memo)
                            dismiss()
                        }
                    } label: {
                        Label("Delete memo", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            do {
                detail = try await PhoneMemoAPIClient.shared.getMemo(id: memo.id)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
        .alert("Memo unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func section<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline.weight(.bold))
                .foregroundStyle(.cyan)
            content()
                .font(.body)
                .foregroundStyle(.white.opacity(0.86))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
