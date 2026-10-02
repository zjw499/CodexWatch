import SwiftUI

struct RecorderView: View {
    @EnvironmentObject private var recorder: AudioRecorderService
    @EnvironmentObject private var queue: RecordingQueueStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var transfer = WatchConnectivityTransferService.shared
    @State private var page = RecorderView.initialPage
    private static var initialPage: Int {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-scribe-watch-queue") { return 1 }
        if ProcessInfo.processInfo.arguments.contains("-scribe-watch-settings") { return 2 }
        #endif
        return 0
    }
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $page) {
            capture.tag(0)
            WatchRecordingQueueView().tag(1)
            WatchProcessingView().tag(2)
        }
        .tabViewStyle(.verticalPage)
        .background(ScribeTheme.background.ignoresSafeArea()).tint(ScribeTheme.red)
        .navigationTitle("")
        .onReceive(timer) { _ in recorder.updateElapsedTime() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { recorder.appDidBecomeActive() } else { recorder.appDidEnterBackground() }
        }
        .alert("Recorder", isPresented: Binding(get: { recorder.errorMessage != nil }, set: { if !$0 { recorder.errorMessage = nil } })) {
            Button("OK") { recorder.errorMessage = nil }
        } message: { Text(recorder.errorMessage ?? "Please try again.") }
    }

    private var capture: some View {
        GeometryReader { geometry in
            let diameter = min(80.0, max(54.0, geometry.size.height * 0.36))
            VStack(spacing: 5) {
                HStack(spacing: 5) {
                    Circle().fill(ScribeTheme.red).frame(width: 5, height: 5)
                    Text("SCRIBE PILOT").font(.system(size: 10, weight: .bold)).tracking(1)
                    Spacer(minLength: 0)
                }.foregroundStyle(ScribeTheme.muted)
                Spacer(minLength: 0)
                Button {
                    if recorder.isRecording {
                        if recorder.isPausedForInterruption { recorder.resumeRecording() }
                        else { recorder.stopRecording() }
                    } else { Task { await recorder.startRecording() } }
                } label: {
                    ZStack {
                        Circle().stroke(ScribeTheme.red.opacity(0.3), lineWidth: 1).frame(width: diameter + 10, height: diameter + 10)
                        Circle().fill(ScribeTheme.red).frame(width: diameter, height: diameter)
                        Image(systemName: recorder.isRecording ? (recorder.isPausedForInterruption ? "play.fill" : "stop.fill") : "mic.fill")
                            .font(.system(size: diameter * 0.29, weight: .bold)).foregroundStyle(.white)
                    }
                }.buttonStyle(.plain).accessibilityLabel(recorder.isRecording ? "Finish recording" : "Start recording")
                Text(recorder.isRecording ? duration(recorder.elapsedTime) : "Record")
                    .font(.system(size: 21, weight: .semibold, design: .monospaced))
                    .monospacedDigit().contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
                Text(recorder.isRecording ? (recorder.isPausedForInterruption ? "PAUSED · AUDIO SAVED" : "RECORDING")
                     : (transfer.meetingStatus ?? "Ready when you are"))
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(ScribeTheme.muted)
                    .lineLimit(2).multilineTextAlignment(.center)
                Spacer(minLength: 0)
                Button { page = 1 } label: {
                    HStack {
                        Image(systemName: "tray")
                        Text("Queue")
                        Spacer(minLength: 2)
                        Text("\(queue.pending.count)").monospacedDigit()
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }.font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 8)
                        .background(ScribeTheme.raised, in: Capsule())
                }.buttonStyle(.plain)
                if recorder.isPausedForInterruption {
                    Button("Finish saved recording") { recorder.stopRecording() }
                        .font(.caption2).foregroundStyle(ScribeTheme.red)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.foregroundStyle(.white)
    }
    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct WatchRecordingQueueView: View {
    @EnvironmentObject private var queue: RecordingQueueStore
    var body: some View {
        List {
            Section {
                if queue.visibleRecordings.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Image(systemName: "tray").foregroundStyle(ScribeTheme.red)
                        Text("Queue is clear").font(.headline)
                        Text("Record now. Review and process on your iPhone.").font(.caption2).foregroundStyle(ScribeTheme.muted)
                    }.padding(.vertical, 10)
                }
                ForEach(queue.visibleRecordings.sorted { $0.createdAt > $1.createdAt }) { recording in
                    NavigationLink { WatchRecordingDetailView(recordingID: recording.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(recording.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            ScribeStateLabel(state: recording.state)
                            Text(recording.createdAt, style: .time).font(.caption2).foregroundStyle(ScribeTheme.muted)
                        }.padding(.vertical, 3)
                    }
                }
            } header: { Text("Recording queue").foregroundStyle(ScribeTheme.muted) }
            .listRowBackground(ScribeTheme.surface)
        }
        .scrollContentBackground(.hidden).background(ScribeTheme.background)
    }
}

struct WatchRecordingDetailView: View {
    @EnvironmentObject private var queue: RecordingQueueStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var transfer = WatchConnectivityTransferService.shared
    @State private var removing = false
    @State private var renaming = false
    @State private var title = ""
    @State private var errorMessage: String?
    let recordingID: String

    var body: some View {
        ScrollView {
            if let item = queue.recording(recordingID) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.headline)
                    ScribeStateLabel(state: item.state)
                    Text(item.state == .ready ? "Open your iPhone for the transcript." : "Audio transfers to your iPhone. Review it there before processing.")
                        .font(.caption2).foregroundStyle(ScribeTheme.muted)
                    if item.state != .ready && item.state != .recording {
                        Button {
                            transfer.retryRecording(item.id)
                        } label: { Label("Retry / process", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(ScribeTheme.red)
                    }
                    Button {
                        title = item.title; renaming = true
                    } label: { Label("Rename", systemImage: "pencil").frame(maxWidth: .infinity) }
                    Button(role: .destructive) { removing = true } label: {
                        Label("Remove", systemImage: "trash").frame(maxWidth: .infinity)
                    }.disabled(item.state == .recording)
                }.padding(.horizontal, 8)
            }
        }
        .background(ScribeTheme.background).navigationTitle("Recording")
        .sheet(isPresented: $renaming) {
            VStack(spacing: 10) {
                Text("Rename").font(.headline)
                TextField("Recording title", text: $title)
                Button("Save") {
                    do { try transfer.renameRecording(recordingID, title: title); renaming = false }
                    catch { errorMessage = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(ScribeTheme.red)
                Button("Cancel") { renaming = false }
            }.padding()
        }
        .confirmationDialog("Remove this recording?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                do { try transfer.removeRecording(recordingID); dismiss() }
                catch { errorMessage = error.localizedDescription }
            }
        } message: { Text("Remove saved audio and results from your Watch, iPhone, and PC workspace when they reconnect.") }
        .alert("Recording queue", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "Please try again.") }
    }
}

struct WatchProcessingView: View {
    @StateObject private var transfer = WatchConnectivityTransferService.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("Shared workspace", systemImage: "lock.shield").font(.headline).foregroundStyle(ScribeTheme.red)
                Text(transfer.openAIReady ? "Configured on iPhone" : "Finish setup on iPhone").font(.headline)
                Text("Sign in, choose models, and create assistants in Scribe Pilot on your iPhone.")
                    .font(.caption2).foregroundStyle(ScribeTheme.muted)
                Label(transfer.protectedWorkflow ? "Protected workflow" : "Standard workflow", systemImage: "iphone")
                    .font(.caption2)
                Text("Your organization's OpenAI connection stays on the PC. Audio is kept until you remove it.").font(.caption2).foregroundStyle(ScribeTheme.muted)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }.background(ScribeTheme.background)
    }
}
