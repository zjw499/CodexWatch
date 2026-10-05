import AppIntents
import AVFoundation
import ClockKit
import Combine
import Foundation

@MainActor
final class WatchVoiceService: ObservableObject {
    static let shared = WatchVoiceService()
    @Published var isPresented = false
    @Published private(set) var isActive = false
    @Published private(set) var muted = false
    @Published private(set) var state = "ready"
    @Published private(set) var assistantName = "Assistant"
    @Published private(set) var message: String?
    @Published private(set) var turns: [VoiceTurn] = []
    @Published private(set) var configuration: VoiceConfiguration?
    private let client = WatchVoiceClient()
    private let audio = WatchVoiceAudio()
    private var current: VoiceSessionInfo?
    private var credential: VoiceDeviceCredential?
    private var streamTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pendingAudio: [Data] = []
    private var sequence = 0
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private var desiredState = "listening"

    private init() {
        if let cache = VoiceDescriptorCache.read(), cache.owner == RecordingQueueStore.shared.accountID {
            configuration = cache.configuration
        }
        audio.onPlaybackFinished = { [weak self] in
            guard let self, self.isActive else { return }
            self.state = self.muted ? "muted" : self.desiredState
            if self.desiredState == "listening" { self.acknowledgePlayback() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.end(message: "Watch audio was interrupted. Completed text was saved.") } })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.end(message: "Watch audio restarted. Start a new conversation.") } })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                Task { @MainActor in self?.end(message: "The audio route disconnected. Start a new conversation.") }
            })
    }

    private func access() throws -> VoiceDeviceCredential {
        guard let saved = VoiceKeychain.read(), saved.valid, saved.owner_id == RecordingQueueStore.shared.accountID else { throw VoiceError.setup }
        return saved
    }

    func applyAccount(owner: String?, configurationData: Data?, credentialData: Data?) {
        let oldOwner = VoiceDescriptorCache.read()?.owner
        if owner == nil || oldOwner != owner {
            end(message: "Your account changed.")
            VoiceKeychain.clear(); VoiceDescriptorCache.clear(); configuration = nil; turns = []; isPresented = false
            WatchShortcutCommandRouter.clearPendingVoiceCommand()
        }
        guard let owner else { refreshLaunchers(); return }
        if let configurationData, let config = try? JSONDecoder().decode(VoiceConfiguration.self, from: configurationData), config.version == 1 {
            configuration = config
            VoiceDescriptorCache.save(owner: owner, configuration: config)
            if !config.enabled { end(message: "Watch voice is currently disabled."); VoiceKeychain.clear() }
        }
        if let credentialData, let saved = try? JSONDecoder().decode(VoiceDeviceCredential.self, from: credentialData), saved.owner_id == owner {
            if let current = credential, current.token != saved.token { end(message: "Watch voice access was updated.") }
            do { try VoiceKeychain.save(saved) } catch { message = "Set a Watch passcode, then send Watch voice setup from your iPhone again." }
        }
        refreshLaunchers()
    }

    private func refreshLaunchers() {
        CodexWatchWatchShortcuts.updateAppShortcutParameters()
        CLKComplicationServer.sharedInstance().reloadComplicationDescriptors()
        for complication in CLKComplicationServer.sharedInstance().activeComplications ?? [] {
            CLKComplicationServer.sharedInstance().reloadTimeline(for: complication)
        }
    }

    func refresh() async {
        do {
            let saved = try access()
            let config: VoiceConfiguration = try await client.send("config", credential: saved)
            guard saved.owner_id == RecordingQueueStore.shared.accountID else { return }
            guard config.version == 1, config.gateway_url == saved.gateway_url else { throw VoiceError.version }
            configuration = config
            VoiceDescriptorCache.save(owner: saved.owner_id, configuration: config)
            if !config.enabled { end(message: "Watch voice is currently disabled.") }
            refreshLaunchers()
        } catch { message = error.localizedDescription }
    }

    func open(assistantID: String? = nil, conversationID: String? = nil, requestID: String = UUID().uuidString) async {
        isPresented = true
        guard !isActive else { return }
        guard !AudioRecorderService.shared.isRecording else { message = VoiceError.audioBusy.localizedDescription; return }
        isActive = true; state = "connecting"; muted = false; message = nil; turns = []
        generation = UUID()
        let run = generation
        do {
            let saved = try access()
            credential = saved
            let granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard generation == run, isActive else { return }
            guard granted else { throw VoiceError.microphone }
            // Recheck after permission UI; a meeting shortcut may have arrived while waiting.
            guard !AudioRecorderService.shared.isRecording else { throw VoiceError.audioBusy }
            if let conversationID {
                guard VoiceWire.validID(conversationID) else { throw VoiceError.connection }
                let detail: VoiceConversation = try await client.send("conversations/\(conversationID)", credential: saved)
                guard generation == run, isActive else { return }
                turns = detail.turns ?? []
            }
            let info: VoiceSessionInfo = try await client.send("sessions", credential: saved, method: "POST",
                data: JSONEncoder().encode(VoiceSessionRequest(request_id: requestID, assistant_id: assistantID, conversation_id: conversationID)))
            guard generation == run, isActive else {
                try? await client.control(VoiceControl(action: "end"), sessionID: info.id, credential: saved); return
            }
            guard info.version == 1, info.state != "ended", VoiceWire.validID(info.id) else { throw VoiceError.connection }
            current = info; assistantName = info.assistant_name; sequence = 0
            streamTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.client.stream(sessionID: info.id, credential: saved) { [weak self] event in
                        guard let self, self.generation == run, self.isActive else { return }
                        try await self.receive(event, run: run)
                    }
                    if self.generation == run, self.isActive { self.end(message: "The voice connection ended. Completed text was saved.") }
                } catch is CancellationError { }
                catch { if self.generation == run { self.end(message: error.localizedDescription) } }
            }
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(2))
                        guard let self, self.generation == run, self.isActive else { return }
                        try await self.client.control(VoiceControl(action: "heartbeat"), sessionID: info.id, credential: saved)
                    } catch is CancellationError { return }
                    catch { if let self, self.generation == run { self.end(message: error.localizedDescription) }; return }
                }
            }
        } catch { if generation == run { end(message: error.localizedDescription) } }
    }

    private func receive(_ event: VoiceEvent, run: UUID) async throws {
        switch event.type {
        case "state":
            desiredState = event.state ?? "listening"
            if state == "connecting", desiredState == "listening" {
                try audio.start { [weak self] packet in
                    Task { @MainActor in
                        guard let self, self.generation == run, self.isActive else { return }
                        guard let packet else { self.end(message: VoiceError.audioRoute.localizedDescription); return }
                        self.enqueueAudio(packet)
                    }
                }
            }
            state = muted ? "muted" : (audio.hasPendingPlayback ? "speaking" : desiredState)
            if desiredState == "listening", !audio.hasPendingPlayback { acknowledgePlayback() }
        case "audio":
            guard let encoded = event.audio, let item = event.item_id, let data = Data(base64Encoded: encoded) else { throw VoiceError.connection }
            try audio.play(data, item: item)
            state = "speaking"
        case "interrupt":
            guard let item = event.item_id, let current, let credential else { return }
            let milliseconds = audio.interrupt(item: item)
            try await client.control(VoiceControl(action: "interrupt", item_id: item, audio_end_ms: milliseconds), sessionID: current.id, credential: credential)
        case "turn":
            if let turn = event.turn {
                if let index = turns.firstIndex(where: { $0.id == turn.id }) { turns[index] = turn }
                else { turns.append(turn) }
            }
        case "ended": end(message: event.message ?? "Conversation ended.", notifyServer: false)
        default: break
        }
    }

    private func enqueueAudio(_ data: Data) {
        guard !muted, isActive else { return }
        guard pendingAudio.count < 10 else { end(message: VoiceError.slow.localizedDescription); return }
        pendingAudio.append(data)
        guard uploadTask == nil else { return }
        let run = generation
        uploadTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == run { self.uploadTask = nil } }
            do {
                while self.generation == run, self.isActive, !self.pendingAudio.isEmpty {
                    try Task.checkCancellation()
                    let batch = self.pendingAudio.removeFirst()
                    guard let current = self.current, let credential = self.credential else { throw VoiceError.setup }
                    try await self.client.audio(batch, sequence: self.sequence, sessionID: current.id, credential: credential)
                    guard self.generation == run else { return }
                    self.sequence += 1
                }
            } catch is CancellationError { }
            catch { if self.generation == run { self.end(message: error.localizedDescription) } }
        }
    }

    private func acknowledgePlayback() {
        guard isActive, let current, let credential, let item = audio.outputItem else { return }
        let milliseconds = audio.playedMilliseconds(item: item), run = generation
        Task {
            do { try await client.control(VoiceControl(action: "played", item_id: item, audio_end_ms: milliseconds), sessionID: current.id, credential: credential) }
            catch { if generation == run { end(message: error.localizedDescription) } }
        }
    }

    func toggleMute() {
        guard isActive, let current, let credential else { return }
        muted.toggle(); pendingAudio = []; state = muted ? "muted" : desiredState
        let value = muted, run = generation
        Task {
            do { try await client.control(VoiceControl(action: "mute", muted: value), sessionID: current.id, credential: credential) }
            catch { if generation == run { end(message: error.localizedDescription) } }
        }
    }

    func end(message: String = "Conversation ended.", notifyServer: Bool = true) {
        guard isActive else { return }
        let previous = current, saved = credential
        let item = audio.hasPendingPlayback ? audio.outputItem : nil
        let milliseconds = item.map { audio.playedMilliseconds(item: $0) }
        isActive = false; generation = UUID(); state = "ended"; muted = false; self.message = message
        audio.stop(); pendingAudio = []
        streamTask?.cancel(); uploadTask?.cancel(); heartbeatTask?.cancel()
        streamTask = nil; uploadTask = nil; heartbeatTask = nil; current = nil; credential = nil
        if notifyServer, let previous, let saved {
            Task {
                if let item, let milliseconds {
                    try? await client.control(VoiceControl(action: "interrupt", item_id: item, audio_end_ms: milliseconds), sessionID: previous.id, credential: saved)
                }
                try? await client.control(VoiceControl(action: "end"), sessionID: previous.id, credential: saved)
            }
        }
    }

    func history(offset: Int = 0) async throws -> [VoiceConversation] {
        let saved = try access()
        let page: VoiceHistory = try await client.send("conversations?offset=\(offset)", credential: saved)
        guard saved.owner_id == RecordingQueueStore.shared.accountID else { throw VoiceError.setup }
        return page.conversations
    }
    func detail(_ id: String) async throws -> VoiceConversation {
        guard VoiceWire.validID(id) else { throw VoiceError.connection }
        let saved = try access()
        let detail: VoiceConversation = try await client.send("conversations/\(id)", credential: saved)
        guard saved.owner_id == RecordingQueueStore.shared.accountID else { throw VoiceError.setup }
        return detail
    }
    func delete(_ id: String) async throws {
        guard VoiceWire.validID(id) else { throw VoiceError.connection }
        let _: VoiceOK = try await client.send("conversations/\(id)", credential: access(), method: "DELETE")
    }
    #if DEBUG
    func loadPreview() {
        assistantName = "Everyday assistant"; state = "speaking"; message = nil
        turns = [VoiceTurn(id: "preview-user", role: "user", text: "Help me plan my afternoon.", final: true, interrupted: false),
                 VoiceTurn(id: "preview-assistant", role: "assistant", text: "Start with your most important task, then leave time for a walk. What needs to be finished today?", final: true, interrupted: false)]
        isPresented = true
    }
    #endif
}
