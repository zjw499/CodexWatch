import SwiftUI
import WatchKit

struct WatchAudioDiagnosticView: View {
    @ObservedObject private var test = WatchAudioDiagnosticService.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Test Watch audio").font(.headline)
                Text("The first check uses normal voice capture. Speak throughout the checks. Keep your wrist raised and this screen awake. The last check plays three short tones.")
                    .font(.caption)
                Text("This local test saves and sends no audio.").font(.caption2).foregroundStyle(ScribeTheme.muted)
                if test.isRunning {
                    Text(test.phase.map { "\($0.id): \($0.title)" } ?? "Preparing audio...").font(.caption.bold())
                    ProgressView(value: test.microphoneLevel).tint(ScribeTheme.red).accessibilityLabel("Local microphone activity")
                    Button("Stop test", role: .destructive) { test.cancel() }
                } else {
                    Button(test.results.isEmpty ? "Run audio test" : "Run again") { test.run() }
                        .disabled(scenePhase != .active || isLuminanceReduced)
                }
                if let message = test.message { Text(message).font(.caption) }
                if !test.results.isEmpty {
                    let finding = VoiceAudioDiagnosticFinding.evaluate(test.results)
                    Text("\(finding.rawValue) · Build \(build)").font(.caption.bold())
                    Text(test.results.map { "\($0.id):\($0.marker)" }.joined(separator: "  "))
                        .font(.caption.monospaced()).accessibilityLabel("Audio test comparison")
                    if !test.isRunning { Text(finding.message).font(.caption) }
                    Text("watchOS \(WKInterfaceDevice.current().systemVersion)").font(.caption2)
                }
                if test.completed {
                    Text("Did you hear the final speaker tones?").font(.caption)
                    HStack {
                        Button("Yes") { test.speakerHeard = true }.tint(test.speakerHeard == true ? .green : ScribeTheme.red)
                        Button("No") { test.speakerHeard = false }.tint(test.speakerHeard == false ? .orange : ScribeTheme.red)
                    }
                    Text(test.speakerHeard.map { $0 ? "Speaker heard: yes" : "Speaker heard: no" } ?? "Speaker audibility unconfirmed")
                        .font(.caption2)
                    Text("Send the comparison above and your speaker result when reporting the problem.").font(.caption)
                }
                ForEach(test.results) { result in
                    NavigationLink { WatchAudioDiagnosticDetailView(result: result) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(result.id): \(result.phase.title)").font(.caption.bold())
                            Text(result.phase == .speaker ? "Rendered \(result.renderedFrames) frames" : "Mic \(result.inputFrames) · Batches \(result.batches)")
                                .font(.caption2)
                            if let code = result.failureCode { Text(code).font(.caption2) }
                        }
                    }.disabled(test.isRunning)
                }
                if !test.results.isEmpty {
                    Text("Route changes \(test.routeChanges) · Interruptions \(test.interruptions) · Audio resets \(test.mediaResets)")
                        .font(.caption2).foregroundStyle(ScribeTheme.muted)
                }
            }.padding(.horizontal, 6)
        }
        .background(ScribeTheme.background).tint(ScribeTheme.red)
        .onChange(of: scenePhase) { _, phase in if phase != .active { test.cancel(message: "Test stopped when the app left the foreground.") } }
        .onChange(of: isLuminanceReduced) { _, reduced in if reduced { test.cancel(message: "Test stopped when the screen dimmed. Keep your wrist raised and run again.") } }
        .onDisappear { test.cancel() }
    }
}

private struct WatchAudioDiagnosticDetailView: View {
    let result: VoiceAudioDiagnosticResult
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(result.phase.title).font(.headline)
                Text("Input frames: \(result.inputFrames)\nConverted: \(result.convertedFrames)\nBatches: \(result.batches)\nReceiver fault: \(result.receiverFailure)\nConversion failed: \(result.conversionFailed ? "yes" : "no")\nPeak level: \(result.peakLevel, specifier: "%.3f")\nOutput rendered: \(result.renderedFrames)")
                if let code = result.failureCode { Text(code) }
                snapshot("At start", result.before)
                snapshot("At end", result.after)
            }.font(.caption).padding(.horizontal, 6)
        }.background(ScribeTheme.background)
    }
    private func snapshot(_ title: String, _ value: VoiceAudioDiagnosticSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            Text("Engine: \(value.engineRunning ? "running" : "stopped")\nSession: \(value.category) / \(value.mode)\nIn: \(value.inputPorts.joined(separator: ", "))\nOut: \(value.outputPorts.joined(separator: ", "))\nHardware mic: \(Int(value.hardwareInputRate)) Hz / \(value.hardwareInputChannels) ch\nCapture: \(Int(value.captureRate)) Hz / \(value.captureChannels) ch\nSpeaker: \(Int(value.outputRate)) Hz / \(value.outputChannels) ch\nEcho: \(value.voiceProcessing ? "on" : "off")\nInput muted: \(value.inputMuted ? "yes" : "no")\nVolume: \(value.outputVolume, specifier: "%.2f")")
        }
    }
}
