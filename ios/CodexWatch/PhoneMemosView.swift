import SwiftUI

struct PhoneMemosView: View {
    @EnvironmentObject private var recorder: PhoneRecorderService
    @EnvironmentObject private var uploader: PhoneUploadService
    @EnvironmentObject private var memoService: PhoneMemoService
    @State private var searchText = ""
    @State private var showingSettings = false
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private let accent = Color(red: 0.20, green: 0.77, blue: 0.95)
    private let coral = Color(red: 1.0, green: 0.35, blue: 0.27)

    private var sections: [(String, [MemoSummary])] {
        let filtered = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? memoService.memos
            : memoService.memos.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.originalFilename.localizedCaseInsensitiveContains(searchText)
            }
        let groups = Dictionary(grouping: filtered) { monthTitle($0.createdAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    searchBar
                    if recorder.isRecording {
                        activeRecordingCard
                    }
                    if sections.isEmpty {
                        emptyState
                    } else {
                        ForEach(sections, id: \.0) { section, memos in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section)
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.white.opacity(0.62))
                                    .padding(.horizontal, 4)
                                ForEach(memos) { memo in
                                    NavigationLink {
                                        PhoneMemoDetailView(memo: memo)
                                    } label: {
                                        MemoRow(memo: memo)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 96)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            recordButton
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                PhoneSettingsView()
            }
        }
        .task {
            await memoService.refresh()
        }
        .refreshable {
            await memoService.refresh()
        }
        .onReceive(timer) { _ in
            recorder.updateElapsedTime()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("CODEX WATCH")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(.white.opacity(0.45))
                Text("Memos")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .foregroundStyle(.white)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.45))
            TextField("Search memos", text: $searchText)
                .foregroundStyle(.white)
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var activeRecordingCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(coral)
                .frame(width: 10, height: 10)
                .shadow(color: coral, radius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text("Recording now")
                    .font(.subheadline.weight(.bold))
                Text(formatDuration(recorder.elapsedTime) + "  •  Tap stop when finished")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(15)
        .foregroundStyle(.white)
        .background(coral.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(coral.opacity(0.38), lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(accent)
            Text(searchText.isEmpty ? "Your next thought starts here." : "No matching memos")
                .font(.headline)
            Text(searchText.isEmpty ? "Record on your iPhone or watch. The PC will transcribe and file it here." : "Try a different title or filename.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.52))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
        .foregroundStyle(.white)
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stopRecording()
            } else {
                Task { await recorder.startRecording() }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle.fill")
                Text(recorder.isRecording ? "Finish recording" : "Record")
            }
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 27)
            .padding(.vertical, 15)
            .background(recorder.isRecording ? coral : accent, in: Capsule())
            .shadow(color: (recorder.isRecording ? coral : accent).opacity(0.28), radius: 18, y: 8)
        }
        .padding(.bottom, 18)
    }

    private func monthTitle(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: value) ?? Date()
        let display = DateFormatter()
        display.dateFormat = "MMMM yyyy"
        return display.string(from: date)
    }

    private func formatDuration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "--:--" }
        let seconds = max(0, Int(duration))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MemoRow: View {
    let memo: MemoSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: memo.source.lowercased().contains("watch") ? "applewatch" : "iphone")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(memo.title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 7) {
                    Text(dateText(memo.createdAt))
                    Text("•")
                    Text(durationText(memo.durationSeconds))
                    if let speakerCount = memo.speakerCount, speakerCount > 1 {
                        Text("•")
                        Label("\(speakerCount)", systemImage: "person.2")
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.48))
            }
            Spacer(minLength: 4)
            Image(systemName: statusIcon(memo.status))
                .font(.caption.weight(.bold))
                .foregroundStyle(statusColor(memo.status))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
        }
    }

    private func dateText(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { return "Recently" }
        let display = DateFormatter()
        display.dateFormat = "EEE, MMM d, h:mm a"
        return display.string(from: date)
    }

    private func durationText(_ value: Double?) -> String {
        guard let value else { return "Audio" }
        return String(format: "%d min", max(1, Int(value / 60)))
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "done": return "checkmark.circle.fill"
        case "failed", "email_failed": return "exclamationmark.triangle.fill"
        default: return "ellipsis.circle"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "done": return .green
        case "failed", "email_failed": return .orange
        default: return .blue
        }
    }
}
