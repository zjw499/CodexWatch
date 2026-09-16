import SwiftUI

struct PhoneMemosView: View {
    @EnvironmentObject private var recorder: PhoneRecorderService
    @EnvironmentObject private var uploader: PhoneUploadService
    @EnvironmentObject private var memoService: PhoneMemoService
    @Environment(\.scenePhase) private var scenePhase
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
        let sorted = filtered.sorted {
            (MeetingDate.parse($0.createdAt) ?? .distantPast) > (MeetingDate.parse($1.createdAt) ?? .distantPast)
        }
        var result: [(String, [MemoSummary])] = []
        for memo in sorted {
            let month = monthTitle(memo.createdAt)
            if result.last?.0 == month { result[result.count - 1].1.append(memo) }
            else { result.append((month, [memo])) }
        }
        return result
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.07, blue: 0.08), .black, .black],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    destinationCard
                    searchBar
                    if memoService.errorMessage != nil {
                        Label("Connection unavailable. Saved recordings will retry.", systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if recorder.isRecording {
                        activeRecordingCard
                    }
                    if uploader.activeRecordingID != nil || ![
                        "Ready",
                        "Ready for watch recordings",
                        "Transcript delivered",
                        "Saved in Notion",
                    ].contains(uploader.statusMessage) {
                        watchRelayCard
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
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }

            recordButton
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                PhoneSettingsView()
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await memoService.loadDestination()
            while !Task.isCancelled {
                await memoService.refresh()
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
            }
        }
        .refreshable {
            await memoService.refresh()
        }
        .onReceive(timer) { _ in
            recorder.updateElapsedTime()
        }
        .task(id: uploader.finalUploadSequence) {
            await memoService.refresh()
        }
        .alert("Recording could not start", isPresented: Binding(
            get: { recorder.errorMessage != nil },
            set: { if !$0 { recorder.errorMessage = nil } }
        )) {
            Button("OK") { recorder.errorMessage = nil }
        } message: {
            Text(recorder.errorMessage ?? "Please try again.")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SCRIBE PILOT")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(.white.opacity(0.45))
                Text("Meetings")
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
            TextField("Search meetings", text: $searchText)
                .foregroundStyle(.white)
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                Text(memoService.destination?.isNotion == true ? "NOTION MEETING NOTES" : "MEETING DESTINATION")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.3)
                Spacer()
                if let raw = memoService.destination?.url, let url = URL(string: raw) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right").frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Open meeting library in Notion")
                }
            }
            .foregroundStyle(accent)
            Text(memoService.destination?.name ?? "Connecting to your workspace")
                .font(.headline)
                .foregroundStyle(.white)
            Text(memoService.destination?.isNotion == true
                ? "Record once. Summary, action items, and the full transcript appear together."
                : "Record on your Watch or iPhone. Follow each meeting here.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(17)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(accent.opacity(0.2), lineWidth: 1) }
    }

    private var activeRecordingCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(coral)
                .frame(width: 10, height: 10)
                .shadow(color: coral, radius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text("Meeting in progress")
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

    private var watchRelayCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(uploader.finalChunkReceived ? "Preparing your meeting" : "Saving your recording")
                    .font(.subheadline.weight(.bold))
                Text(uploader.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
            Spacer()
            if uploader.receivedChunkCount > 0 {
                Text("\(min(uploader.uploadedChunkCount, uploader.receivedChunkCount))/\(uploader.receivedChunkCount)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(accent)
            }
        }
        .padding(15)
        .foregroundStyle(.white)
        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.opacity(0.28), lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(accent)
            Text(searchText.isEmpty ? "Be present. Keep the details." : "No matching meetings")
                .font(.headline)
            Text(searchText.isEmpty ? "Start a meeting on your Watch or iPhone. Your notes will appear here when they are ready." : "Try a different meeting title.")
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
                Text(recorder.isRecording ? "Finish meeting" : "Record meeting")
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
        guard let date = MeetingDate.parse(value) else { return "Earlier meetings" }
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
                if let summary = memo.summary, !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.white.opacity(0.58)).lineLimit(2)
                }
                if memo.notionURL != nil {
                    Text("Saved in Notion").font(.caption2.weight(.medium)).foregroundStyle(.mint)
                }
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
        guard let date = MeetingDate.parse(value) else { return "Date unavailable" }
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
        case "failed", "email_failed", "notion_failed": return "exclamationmark.triangle.fill"
        default: return "ellipsis.circle"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "done": return .green
        case "failed", "email_failed", "notion_failed": return .orange
        default: return .blue
        }
    }
}
