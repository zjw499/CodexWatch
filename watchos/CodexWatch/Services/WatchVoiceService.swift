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
    @Published private(set) var toolMessage: String?
    @Published private(set) var usesPublicWeb = false
    @Published private(set) var turns: [VoiceTurn] = []
    @Published private(set) var configuration: VoiceConfiguration?
    @Published private(set) var setupState: VoiceSetupState = .needsSetup
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var capturedBatches = 0
    @Published private(set) var uploadedBatches = 0
    @Published private(set) var receivedAudio = false
    private let client = WatchVoiceClient()
    private let audio = WatchVoiceAudio()
    private var current: VoiceSessionInfo?
    private var credential: VoiceDeviceCredential?
    private var streamTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var captureWatchdog: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var pendingAudio = VoiceUploadBuffer()
    private var transport = VoiceTransportDiagnostic()
    private var sequence = 0
    private var generation = UUID()
    private var observers: [NSObjectProtocol] = []
    private var desiredState = "listening"
    private var lastAssistantID: String?
    private var voiceScreenReady = false
    private var providerReady = false
    private var captureStarted = false

    private init() {
        if let cache = VoiceDescriptorCache.read(), cache.owner == RecordingQueueStore.shared.accountID {
            configuration = cache.configuration
            if let saved = VoiceKeychain.read(), saved.valid, saved.owner_id == cache.owner,
               saved.gateway_url == cache.configuration.gateway_url {
                setupState = cache.configuration.enabled ? (cache.configuration.assistants.isEmpty ? .needsAssistant : .ready) : .disabled
            }
        }
        audio.onEngineStopped = { [weak self] in
            guard let self, self.isActive else { return }
            self.endAudioFailure(message: "Watch audio stopped after its configuration changed (AUDIO-01). Start a new conversation.")
        }
        audio.onPlaybackFinished = { [weak self] in
            guard let self, self.isActive else { return }
            self.state = self.muted ? "muted" : self.desiredState
            if self.desiredState == "listening" { self.acknowledgePlayback() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
                guard VoiceAudioStatus.interruptionBegan(note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) else { return }
                Task { @MainActor in
                    guard let self, self.captureStarted else { return }
                    self.end(message: "Watch audio was interrupted. Completed text was saved.")
                }
            })
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

    @discardableResult
    func applyAccount(owner: String?, configurationData: Data?, credentialData: Data?) -> VoiceSetupState {
        let oldOwner = VoiceDescriptorCache.read()?.owner
        if owner == nil || oldOwner != owner {
            WatchVoiceDiagnosticReporter.shared.accountChanged(owner)
            end(message: "Your account changed.")
            VoiceKeychain.clear(); VoiceDescriptorCache.clear(); configuration = nil; turns = []; isPresented = false
            lastAssistantID = nil
            WatchShortcutCommandRouter.clearPendingVoiceCommand()
        }
        guard let owner else { return finishSetup(.needsSetup) }
        if let configurationData {
            guard let config = try? JSONDecoder().decode(VoiceConfiguration.self, from: configurationData),
                  config.version == 1, VoiceWire.gatewayURL(config.gateway_url) != nil else { return finishSetup(.updateRequired) }
            configuration = config; VoiceDescriptorCache.save(owner: owner, configuration: config)
        }
        guard let config = configuration else { return finishSetup(.needsSetup) }
        guard config.enabled else {
            end(message: "Watch voice is currently disabled."); VoiceKeychain.clear()
            return finishSetup(.disabled)
        }
        if let credentialData {
            guard let saved = try? JSONDecoder().decode(VoiceDeviceCredential.self, from: credentialData), saved.valid,
                  saved.owner_id == owner, saved.gateway_url == config.gateway_url else { return finishSetup(.needsSetup) }
            if let current = credential, current.token != saved.token { end(message: "Watch voice access was updated.") }
            do {
                try VoiceKeychain.save(saved)
                guard VoiceKeychain.read()?.token == saved.token else { throw VoiceError.setup }
            } catch { return finishSetup(.needsUnlock) }
        }
        guard let saved = try? access(), saved.gateway_url == config.gateway_url else { return finishSetup(.needsSetup) }
        WatchVoiceDiagnosticReporter.shared.retry()
        return finishSetup(config.assistants.isEmpty ? .needsAssistant : .ready)
    }

    private func finishSetup(_ result: VoiceSetupState) -> VoiceSetupState {
        setupState = result
        if !isActive, result != .ready { message = result.message }
        else if result == .ready, message == VoiceSetupState.needsSetup.message || message == VoiceSetupState.needsUnlock.message || message?.hasPrefix("Checking voice setup") == true {
            message = nil
        }
        refreshLaunchers()
        return result
    }

    func showSetupMessage(_ text: String) {
        guard !isActive else { return }
        message = text
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
            _ = finishSetup(!config.enabled ? .disabled : (config.assistants.isEmpty ? .needsAssistant : .ready))
        } catch { message = error.localizedDescription }
    }

    func open(assistantID: String? = nil, conversationID: String? = nil, requestID: String = UUID().uuidString) async {
        guard !VoiceAudioDiagnosticReservation.shared.isHeld else {
            message = "End the Watch audio test before starting a voice conversation."; return
        }
        isPresented = true
        guard !isActive else { return }
        guard !AudioRecorderService.shared.isRecording else { message = VoiceError.audioBusy.localizedDescription; return }
        isActive = true; state = "connecting"; muted = false; message = nil; toolMessage = nil; turns = []
        providerReady = false; captureStarted = false
        microphoneLevel = 0; capturedBatches = 0; uploadedBatches = 0; receivedAudio = false
        pendingAudio = VoiceUploadBuffer(); transport = VoiceTransportDiagnostic()
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
            current = info; assistantName = info.assistant_name; lastAssistantID = info.assistant_id; sequence = 0
            usesPublicWeb = info.web_search == true
            streamTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.client.stream(sessionID: info.id, credential: saved) { [weak self] event in
                        guard let self, self.generation == run, self.isActive else { return }
                        try await self.receive(event, run: run)
                    }
                    if self.generation == run, self.isActive { self.end(message: "The voice connection ended. Completed text was saved.") }
                } catch is CancellationError { }
                catch { if self.generation == run { self.end(message: error.localizedDescription, reason: Self.transportReason(error)) } }
            }
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(2))
                        guard let self, self.generation == run, self.isActive else { return }
                        try await self.client.control(VoiceControl(action: "heartbeat"), sessionID: info.id, credential: saved)
                    } catch is CancellationError { return }
                    catch { if let self, self.generation == run { self.end(message: error.localizedDescription, reason: .network) }; return }
                }
            }
        } catch { if generation == run { end(message: error.localizedDescription) } }
    }

    func showLaunchError(_ message: String) {
        isPresented = true
        guard !isActive else { return }
        self.message = message; state = "ready"; turns = []
    }
    func newConversation() async { await open(assistantID: lastAssistantID) }

    func setVoiceScreenReady(_ ready: Bool) {
        voiceScreenReady = ready
        if !ready, captureStarted || captureTask != nil { end(message: "Conversation ended when the Watch screen became inactive."); return }
        beginCaptureIfReady()
    }

    private func beginCaptureIfReady() {
        guard voiceScreenReady, providerReady, isActive, !captureStarted, captureTask == nil else { return }
        let run = generation
        captureTask = Task { [weak self] in
            guard let self, self.generation == run, self.isActive, self.voiceScreenReady else { return }
            defer { if self.generation == run { self.captureTask = nil } }
            do {
                try Task.checkCancellation()
                try await self.audio.start { [weak self] packet in
                    Task { @MainActor in
                        guard let self, self.generation == run, self.isActive else { return }
                        guard let packet else {
                            self.endAudioFailure(message: self.audio.captureStatistics.startupFailure ?? VoiceError.audioConversion.localizedDescription)
                            return
                        }
                        self.capturedBatches += 1
                        self.microphoneLevel = self.muted ? 0 : VoiceAudioStatus.microphoneLevel(packet)
                        self.enqueueAudio(packet)
                    }
                }
                guard self.generation == run, self.isActive, self.voiceScreenReady else { return }
                self.captureStarted = true
                self.state = self.muted ? "muted" : self.desiredState
                self.captureWatchdog = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self, self.generation == run, self.isActive, self.capturedBatches == 0 else { return }
                    let failure = self.audio.captureStatistics.startupFailure
                        ?? "Watch audio delivery did not start (PCM-02). Start a new conversation."
                    self.endAudioFailure(message: failure)
                }
            } catch is CancellationError { }
            catch {
                if self.generation == run {
                    let failure = error as? VoiceAudioStartupError
                    let message = failure?.stage == .engine ? (self.audio.captureStatistics.startupFailure ?? error.localizedDescription) : error.localizedDescription
                    self.endAudioFailure(message: message, failure: failure)
                }
            }
        }
    }

    private func endAudioFailure(message: String, failure: VoiceAudioStartupError? = nil) {
        guard isActive else { return }
        var result = audio.diagnosticResult
        result.failedStage = failure?.stage; result.nativeCode = failure?.nativeCode
        WatchVoiceDiagnosticReporter.shared.submit(WatchVoiceDiagnosticReporter.report(
            kind: .voiceStartup, completed: false, results: [result]))
        end(message: message, diagnostic: false)
    }

    private func receive(_ event: VoiceEvent, run: UUID) async throws {
        switch event.type {
        case "state":
            desiredState = event.state ?? "listening"
            if desiredState == "listening" { providerReady = true; beginCaptureIfReady() }
            state = captureStarted ? (muted ? "muted" : (audio.hasPendingPlayback ? "speaking" : desiredState)) : "connecting"
            if desiredState == "listening", !audio.hasPendingPlayback { acknowledgePlayback() }
        case "tool": toolMessage = event.message?.isEmpty == false ? event.message : nil
        case "audio":
            guard let encoded = event.audio, let item = event.item_id, let data = Data(base64Encoded: encoded) else { throw VoiceError.connection }
            transport.receivedAudioBytes += data.count
            try audio.play(data, item: item)
            receivedAudio = true
            state = "speaking"
        case "interrupt":
            guard let item = event.item_id, let current, let credential else { return }
            let milliseconds = audio.interrupt(item: item)
            // A slow control acknowledgement must not block incoming captions
            // or the answer to the next question on the event stream.
            Task {
                do { try await client.control(VoiceControl(action: "interrupt", item_id: item, audio_end_ms: milliseconds), sessionID: current.id, credential: credential) }
                catch { if generation == run { end(message: error.localizedDescription, reason: .network) } }
            }
        case "turn":
            if let turn = event.turn {
                if let index = turns.firstIndex(where: { $0.id == turn.id }) { turns[index] = turn }
                else { turns.append(turn) }
            }
        case "ended": end(message: event.message ?? "Conversation ended.", notifyServer: false, reason: .serverEnded)
        default: break
        }
    }

    private func enqueueAudio(_ data: Data) {
        guard !muted, isActive else { return }
        guard pendingAudio.append(data) else { end(message: VoiceError.uploadBacklog.localizedDescription, reason: .uploadBacklog); return }
        guard uploadTask == nil else { return }
        let run = generation
        uploadTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == run { self.uploadTask = nil } }
            do {
                while self.generation == run, self.isActive, !self.pendingAudio.isEmpty {
                    try Task.checkCancellation()
                    guard let batch = self.pendingAudio.take() else { break }
                    guard let current = self.current, let credential = self.credential else { throw VoiceError.setup }
                    let began = Date()
                    try await self.client.audio(batch, sequence: self.sequence, sessionID: current.id, credential: credential)
                    guard self.generation == run else { return }
                    self.transport.lastUploadMs = min(60000, max(0, Int(Date().timeIntervalSince(began) * 1000)))
                    self.transport.maxUploadMs = max(self.transport.maxUploadMs, self.transport.lastUploadMs)
                    self.transport.uploadRequests += 1; self.transport.uploadedBytes += batch.count
                    self.sequence += 1
                    self.uploadedBatches += batch.count / 9600
                }
            } catch is CancellationError { }
            catch { if self.generation == run { self.end(message: error.localizedDescription, reason: .network) } }
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
        muted.toggle(); pendingAudio.clear(); microphoneLevel = 0; state = muted ? "muted" : desiredState
        let value = muted, run = generation
        Task {
            do { try await client.control(VoiceControl(action: "mute", muted: value), sessionID: current.id, credential: credential) }
            catch { if generation == run { end(message: error.localizedDescription) } }
        }
    }

    private static func transportReason(_ error: Error) -> VoiceTransportDiagnostic.EndReason {
        if let error = error as? VoiceError, case .playbackBacklog = error { return .playbackBacklog }
        return .network
    }

    func end(message: String = "Conversation ended.", notifyServer: Bool = true,
             reason: VoiceTransportDiagnostic.EndReason = .closed, diagnostic: Bool = true) {
        guard isActive else { return }
        let previous = current, saved = credential
        let item = audio.hasPendingPlayback ? audio.outputItem : nil
        let milliseconds = item.map { audio.playedMilliseconds(item: $0) }
        if diagnostic {
            transport.endReason = reason
            transport.pendingUploadBytes = pendingAudio.bytes; transport.peakUploadBytes = pendingAudio.peakBytes
            transport.playbackFrames = min(96000, audio.pendingPlaybackFrames)
            transport.peakPlaybackFrames = min(96000, audio.peakPlaybackFrames)
            var report = WatchVoiceDiagnosticReporter.report(kind: .voiceSession, completed: reason == .closed,
                results: [audio.diagnosticResult])
            report.transport = transport
            WatchVoiceDiagnosticReporter.shared.submit(report)
        }
        isActive = false; generation = UUID(); state = "ended"; muted = false; self.message = message; toolMessage = nil
        providerReady = false; captureStarted = false
        microphoneLevel = 0
        audio.stop(); pendingAudio.clear()
        streamTask?.cancel(); uploadTask?.cancel(); heartbeatTask?.cancel(); captureWatchdog?.cancel(); captureWatchdog = nil
        captureTask?.cancel(); captureTask = nil
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
        capturedBatches = 20; uploadedBatches = 20; microphoneLevel = 0.45; receivedAudio = true
        isActive = true; isPresented = true
    }
    #endif
}
