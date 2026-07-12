import Combine
import Foundation
import WhisperKit

@MainActor
final class PhoneTranscriptionService: ObservableObject {
    static let shared = PhoneTranscriptionService()

    private static let modelName = "small"
    private static let modelRepositoryPath = "models/argmaxinc/whisperkit-coreml"

    @Published private(set) var statusMessage = "On-device transcription ready"
    @Published private(set) var isTranscribing = false

    private var whisperKit: WhisperKit?
    private var inFlightPaths = Set<String>()
    private var removedLegacyCache = false

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
            let transcript = try await transcribeWithAutomaticRepair(fileURL: fileURL)
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
            if isCorruptModelError(error) {
                statusMessage = "Whisper model repair failed. Connect to the internet, then retry."
            } else {
                statusMessage = "On-device transcription failed. Recording saved; retry while online."
            }
            return false
        }
    }

    private func transcribeWithAutomaticRepair(fileURL: URL) async throws -> String {
        do {
            return try await transcribeOnce(fileURL: fileURL)
        } catch {
            guard isCorruptModelError(error) else { throw error }

            statusMessage = "Repairing incomplete Whisper model"
            whisperKit = nil
            try resetModelCache()
            return try await transcribeOnce(fileURL: fileURL)
        }
    }

    private func transcribeOnce(fileURL: URL) async throws -> String {
        if whisperKit == nil {
            statusMessage = "Downloading or loading Whisper model"
            let cacheBase = try modelCacheBaseURL()
            removeLegacyModelCacheIfNeeded()
            whisperKit = try await WhisperKit(WhisperKitConfig(
                model: Self.modelName,
                downloadBase: cacheBase,
                verbose: false,
                load: true
            ))
        }

        guard let whisperKit else {
            throw NSError(
                domain: "CodexWatch",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model could not be loaded."]
            )
        }

        statusMessage = "Transcribing on iPhone"
        let results = try await whisperKit.transcribe(audioPath: fileURL.path)
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func modelCacheBaseURL() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperModels", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func resetModelCache() throws {
        let cacheBase = try modelCacheBaseURL()
        let repository = cacheBase.appendingPathComponent(Self.modelRepositoryPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: repository.path) {
            try FileManager.default.removeItem(at: repository)
        }
    }

    private func removeLegacyModelCacheIfNeeded() {
        guard !removedLegacyCache else { return }
        removedLegacyCache = true

        let legacyRepository = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent(Self.modelRepositoryPath, isDirectory: true)
        try? FileManager.default.removeItem(at: legacyRepository)
    }

    private func isCorruptModelError(_ error: Error) -> Bool {
        let description = String(describing: error).lowercased()
        return description.contains("weight.bin") ||
            description.contains("error parsing mil model") ||
            description.contains("model.mil") ||
            description.contains("model file not found")
    }
}
