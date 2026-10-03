import AVFoundation
import Combine
import Foundation

/// Plays the complete ordered source, fetching one part at a time without plaintext files.
@MainActor
final class PhoneRecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var isLoading = false
    @Published private(set) var partIndex = 0
    @Published private(set) var partCount = 0
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var loader: ((Int) async throws -> Data)?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func play(start: Int = 0, count: Int, loader: @escaping (Int) async throws -> Data) {
        stop()
        guard count > 0, start >= 0, start < count else { return }
        self.loader = loader
        partCount = count
        error = nil
        load(start, generation: generation)
    }
    func pause() { player?.pause(); isPlaying = false; isPaused = player != nil }
    func resume() {
        guard let player else { return }
        isPlaying = player.play(); isPaused = !isPlaying
    }
    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        player?.stop(); player = nil; loader = nil
        isPlaying = false; isPaused = false; isLoading = false
    }
    private func load(_ index: Int, generation expected: UUID) {
        guard expected == generation, let loader else { return }
        partIndex = index; isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await loader(index)
                try Task.checkCancellation()
                guard self.generation == expected else { return }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                let player = try AVAudioPlayer(data: data)
                player.delegate = self; self.player = player
                self.isLoading = false; self.isPaused = false; self.isPlaying = player.play()
                if !self.isPlaying { throw CocoaError(.fileReadCorruptFile) }
            } catch is CancellationError {
                guard self.generation == expected else { return }
                self.stop()
            } catch {
                guard self.generation == expected else { return }
                self.stop(); self.error = "Playback stopped at part \(index + 1): \(error.localizedDescription)"
            }
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let active = self.player, ObjectIdentifier(active) == identity else { return }
            self.player = nil; self.isPlaying = false
            if !flag { self.stop(); self.error = "Playback could not finish this audio part."; return }
            let next = self.partIndex + 1
            if next < self.partCount { self.load(next, generation: self.generation) }
            else { self.stop() }
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}
