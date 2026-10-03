import SwiftUI

struct PhoneMemosView: View {
    @EnvironmentObject private var recorder: PhoneRecorderService
    @EnvironmentObject private var queue: RecordingQueueStore
    @EnvironmentObject private var settings: PhoneOpenAISettings
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var section = 0
    @State private var search = ""
    @State private var showingSettings = false
    @State private var editing = false
    @State private var selected: Set<String> = []
    @State private var removal: PhoneRecordingRemovalRequest?
    @State private var renaming: QueuedRecording?
    @State private var renameTitle = ""
    @State private var errorMessage: String?
    @State private var processingIDs: [String] = []
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var visible: [QueuedRecording] {
        let items = section == 0 ? queue.pending : queue.completed
        return items.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                capturePanel
                setupPanel
                queueHeader
                searchField
                if editing { selectionActions }
                if visible.isEmpty { emptyState }
                else {
                    LazyVStack(spacing: 10) { ForEach(visible) { item in recordingRow(item) } }
                }
                Text("\(workspace.user?.username ?? "Signed out") · Shared OpenAI workspace").font(.caption).foregroundStyle(ScribeTheme.muted)
                    .frame(maxWidth: .infinity).padding(.top, 8)
            }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .background(ScribeTheme.background.ignoresSafeArea()).foregroundStyle(.white)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingSettings) {
            NavigationStack { PhoneSettingsView() }.preferredColorScheme(.dark)
        }
        .onReceive(timer) { _ in recorder.updateElapsedTime() }
        .task {
            while !Task.isCancelled {
                await workspace.refresh()
                do { try await Task.sleep(for: .seconds(12)) } catch { break }
            }
        }
        .onChange(of: section) { _, _ in selected = []; editing = false }
        .onChange(of: search) { _, _ in selected = [] }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { PhoneUploadService.shared.retryPendingRecordings() }
        }
        .sheet(item: $removal) { request in
            PhoneRecordingRemovalView(ids: request.ids) { selected.subtract(request.ids) }
        }
        .confirmationDialog("Choose an assistant", isPresented: Binding(get: { !processingIDs.isEmpty }, set: { if !$0 { processingIDs = [] } }), titleVisibility: .visible) {
            ForEach(workspace.assistants) { assistant in
                Button(assistant.name + " · " + assistant.model) {
                    workspace.selectedAssistantID = assistant.id; workspace.savePreferences()
                    PhoneOpenAIService.shared.process(processingIDs)
                    processingIDs = []; editing = false; selected = []
                }
            }
        } message: { Text("Transcription: \(workspace.transcriptionModel)") }
        .alert("Rename recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Recording title", text: $renameTitle)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let item = renaming {
                    do { try PhoneOpenAIService.shared.rename(item.id, title: renameTitle) }
                    catch { errorMessage = error.localizedDescription }
                }
                renaming = nil
            }
        }
        .alert("Scribe Pilot", isPresented: Binding(get: { displayedError != nil }, set: { if !$0 { clearError() } })) {
            Button("OK") { clearError() }
        } message: { Text(displayedError ?? "Please try again.") }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.title3.weight(.bold)).foregroundStyle(ScribeTheme.red)
                    .frame(width: 40, height: 40).background(ScribeTheme.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("SCRIBE PILOT").font(.system(size: 11, weight: .bold)).tracking(2.2).foregroundStyle(ScribeTheme.muted)
                    Text("Your recordings").font(.system(size: 27, weight: .bold))
                }
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.headline)
                    .frame(width: 44, height: 44).background(ScribeTheme.raised, in: Circle())
            }.accessibilityLabel("Open settings")
        }
    }
    private var capturePanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(recorder.isRecording ? (recorder.isPaused ? "PAUSED" : "RECORDING") : "READY TO CAPTURE",
                      systemImage: "circle.fill")
                    .font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(ScribeTheme.red)
                Spacer()
                Image(systemName: "iphone").foregroundStyle(ScribeTheme.muted)
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(recorder.isRecording ? duration(recorder.elapsedTime) : "Capture the\nconversation.")
                        .font(.system(size: recorder.isRecording ? 40 : 30, weight: .semibold,
                                      design: recorder.isRecording ? .monospaced : .default))
                        .monospacedDigit().contentTransition(.numericText())
                    Text(recorder.isRecording ? "Audio is saved on this iPhone." : "Record now. Review before processing.")
                        .font(.caption).foregroundStyle(ScribeTheme.muted)
                }
                Spacer(minLength: 4)
                Button {
                    if recorder.isRecording { recorder.stopRecording() }
                    else { Task { await recorder.startRecording() } }
                } label: {
                    ZStack {
                        Circle().stroke(ScribeTheme.red.opacity(0.25), lineWidth: 1).frame(width: 94, height: 94)
                        Circle().fill(ScribeTheme.red).frame(width: 78, height: 78)
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                    }
                }.buttonStyle(.plain).accessibilityLabel(recorder.isRecording ? "Finish recording" : "Start recording")
            }
            if recorder.isRecording {
                HStack(spacing: 3) {
                    ForEach(0..<34, id: \.self) { bar in
                        Capsule().fill(ScribeTheme.red.opacity(recorder.isPaused ? 0.25 : 0.85))
                            .frame(height: 4 + (recorder.isPaused ? 0 : recorder.audioLevel) * CGFloat(10 + (bar * 17) % 29))
                    }
                }.frame(height: 42).accessibilityLabel("Microphone level")
                Button {
                    if recorder.isPaused { recorder.resumeRecording() } else { recorder.pauseRecording() }
                } label: {
                    Label(recorder.isPaused ? "Resume recording" : "Pause recording",
                          systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                }.buttonStyle(.bordered).tint(ScribeTheme.muted)
            } else {
                HStack {
                    Label("Watch + iPhone", systemImage: "applewatch")
                    Spacer()
                    Text("Tap to record").foregroundStyle(.white)
                }.font(.caption).foregroundStyle(ScribeTheme.muted)
            }
        }.scribePanel()
    }
    private var setupPanel: some View {
        Button { showingSettings = true } label: {
            HStack(spacing: 11) {
                Image(systemName: settings.ready ? "lock.shield" : "key").foregroundStyle(ScribeTheme.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(settings.readinessLabel).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(workspace.ready ? "\(workspace.selectedAssistant?.name ?? "Assistant") · Process on your PC" : "Recordings stay queued until your workspace is ready")
                        .font(.caption).foregroundStyle(ScribeTheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(ScribeTheme.muted)
            }.padding(15).background(ScribeTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
    private var queueHeader: some View {
        VStack(spacing: 16) {
            Picker("Recordings", selection: $section) {
                Text("Queue · \(queue.pending.count)").tag(0)
                Text("Library · \(queue.completed.count)").tag(1)
            }.pickerStyle(.segmented)
            HStack {
                Text(section == 0 ? "Recording queue" : "Transcript library").font(.title3.weight(.bold))
                Spacer()
                if !visible.isEmpty {
                    Button(editing ? "Done" : "Edit") { editing.toggle(); selected = [] }
                        .font(.subheadline.weight(.semibold)).frame(minWidth: 44, minHeight: 36)
                }
            }
        }
    }
    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(ScribeTheme.muted)
            TextField("Search recordings", text: $search).autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search")
            }
        }.padding(13).background(ScribeTheme.surface, in: RoundedRectangle(cornerRadius: 13))
    }
    private var selectionActions: some View {
        HStack {
            Button(selected.count == visible.count ? "Clear" : "Select all") {
                selected = selected.count == visible.count ? [] : Set(visible.filter { $0.state != .recording }.map(\.id))
            }
            Spacer()
            if section == 0 {
                Button("Process") {
                    processingIDs = Array(selected)
                }.disabled(!settings.ready || !queue.pending.contains { selected.contains($0.id) && $0.canProcess })
            }
            Button(role: .destructive) { removal = PhoneRecordingRemovalRequest(ids: selected) } label: {
                Label("Remove", systemImage: "trash")
            }.disabled(selected.isEmpty)
        }.font(.caption.weight(.semibold))
    }
    private func recordingRow(_ item: QueuedRecording) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if editing {
                Button {
                    if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
                } label: {
                    Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle").font(.title2)
                }.disabled(item.state == .recording).accessibilityLabel("Select \(item.title)").padding(.top, 4)
            } else {
                Image(systemName: item.isWatch ? "applewatch" : "iphone").font(.headline).foregroundStyle(ScribeTheme.muted)
                    .frame(width: 36, height: 42).background(ScribeTheme.raised, in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 7) {
                if item.state == .ready {
                    NavigationLink { PhoneLocalRecordingView(recordingID: item.id) } label: {
                        Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).multilineTextAlignment(.leading)
                    }
                } else { Text(item.title).font(.subheadline.weight(.semibold)) }
                HStack(spacing: 7) {
                    Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    if let seconds = item.duration { Text("·"); Text(duration(seconds)).monospacedDigit() }
                }.font(.caption2).foregroundStyle(ScribeTheme.muted)
                if item.awaitingConnection {
                    Label("Waiting for PC", systemImage: "network").font(.caption.weight(.semibold)).foregroundStyle(ScribeTheme.muted)
                } else { ScribeStateLabel(state: item.state) }
                if item.state == .processing { ProgressView(value: item.progress).tint(ScribeTheme.red) }
                if let error = item.error { Text(error).font(.caption).foregroundStyle(ScribeTheme.muted) }
                if item.state == .receiving, let final = item.finalIndex {
                    Text("\(item.parts.count) of \(final + 1) audio parts received").font(.caption2).foregroundStyle(ScribeTheme.muted)
                    Button("Request missing audio") {
                        PhoneUploadService.shared.requestMissingQueueAudio(item.id)
                    }.font(.caption)
                }
                if item.canProcess && !editing {
                    Button { processingIDs = [item.id] } label: {
                        Label(item.awaitingConnection ? "Retry now" : (item.state == .failed ? "Retry" : "Process"), systemImage: "play.fill")
                            .font(.caption.weight(.bold)).padding(.horizontal, 13).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(ScribeTheme.red).disabled(!settings.ready)
                }
            }
            Spacer(minLength: 0)
            if !editing {
                Menu {
                    Button { renaming = item; renameTitle = item.title } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { removal = PhoneRecordingRemovalRequest(ids: [item.id]) } label: {
                        Label("Remove recording", systemImage: "trash")
                    }.disabled(item.state == .recording)
                } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36).contentShape(Rectangle()) }
                .accessibilityLabel("Actions for \(item.title)")
            }
        }.padding(15).background(ScribeTheme.surface, in: RoundedRectangle(cornerRadius: 17))
    }
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: section == 0 ? "tray" : "doc.text").font(.system(size: 30)).foregroundStyle(ScribeTheme.red)
            Text(search.isEmpty ? (section == 0 ? "A clear queue." : "Your notes start here.") : "No matching recordings.").font(.headline)
            Text(section == 0 ? "Record on your iPhone or Watch. Rename, process, or remove it here."
                 : "Processed transcripts and meeting notes appear in your library.")
                .font(.subheadline).foregroundStyle(ScribeTheme.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 40)
    }
    private func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
    private var displayedError: String? { errorMessage ?? recorder.errorMessage ?? queue.errorMessage }
    private func clearError() { errorMessage = nil; recorder.errorMessage = nil; queue.errorMessage = nil }
}
