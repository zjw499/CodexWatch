import Combine
import Foundation
import WhisperKit

@MainActor
final class PhoneTranscriptionService: ObservableObject {
    static let shared = PhoneTranscriptionService()

    @Published private(set) var statusMessage = "On-device transcription ready"
    @Published private(set) var isTranscribing = false

    private var whisperKit: WhisperKit?
    private var inFlightPaths = Set<String>()

    func retryPendingRecordings() {
        guard !isTranscribing else { return }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        Task { @MainActor in
            for fileURL in files where ["m4a", "mp3", "wav", "caf"].contains(fileURL.pathExtension.lowercased()) {
                _ = await transcribeAndSubmit(fileURL: fileURL)
            }
        }
    }

    func transcribeAndSubmit(fileURL: URL) async -> Bool {
        guard !inFlightPaths.contains(fileURL.path) else { return false }
        inFlightPaths.insert(fileURL.path)
        isTranscribing = true
        defer {
            inFlightPaths.remove(fileURL.path)
            isTranscribing = !inFlightPaths.isEmpty
        }

        do {
            statusMessage = "Loading on-device Whisper model"
            if whisperKit == nil {
                whisperKit = try await WhisperKit(WhisperKitConfig(model: "small"))
            }

            statusMessage = "Transcribing on iPhone"
            let results = try await whisperKit?.transcribe(audioPath: fileURL.path) ?? []
            let transcript = results
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                throw NSError(
                    domain: "CodexWatch",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "On-device transcription returned no text."]
                )
            }

            PhoneUploadService.shared.enqueueTranscript(
                text: transcript,
                filename: fileURL.lastPathComponent,
                sourceURL: fileURL
            )
            statusMessage = "Transcript queued for email"
            return true
        } catch {
            statusMessage = "On-device transcription failed: \(error.localizedDescription)"
            return false
        }
    }
}
