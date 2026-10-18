import SwiftUI

struct PhoneVoicePolicyView: View {
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @State private var policy = VoicePolicy()
    @State private var message: String?
    @State private var busy = false
    var body: some View {
        Form {
            Section("Watch voice availability") {
                Toggle("Enable Watch voice", isOn: $policy.enabled)
                Toggle("Administrator pilot for device testing", isOn: $policy.pilot_enabled)
                Toggle("Realtime Modified Retention verified", isOn: $policy.realtime_retention_verified)
                Toggle("Physical Watch audio and network tests passed", isOn: $policy.device_acceptance_verified)
                TextField("Verification evidence / reference", text: $policy.approval_evidence, axis: .vertical).lineLimit(3...6)
                Text("The pilot permits only administrators after Realtime retention is verified. Enable voice for everyone after Watch mic, speaker, echo handling, and phone-free tests pass.")
                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
            }
            Section("Conversation limits") {
                Stepper("Session: \(policy.session_seconds / 60) minutes", value: $policy.session_seconds, in: 60...3600, step: 60)
                Stepper("Inactivity: \(policy.idle_seconds) seconds", value: $policy.idle_seconds, in: 30...600, step: 30)
                Stepper("Active conversations: \(policy.max_active_sessions ?? 1)", value: Binding(
                    get: { policy.max_active_sessions ?? 1 }, set: { policy.max_active_sessions = $0 }), in: 1...16)
                Text("Each Watch runs one conversation at a time.").font(.footnote).foregroundStyle(ScribeTheme.muted)
            }
            Section("Public web search") {
                Toggle("Allow public web search", isOn: Binding(
                    get: { policy.public_web_search_enabled ?? false }, set: { policy.public_web_search_enabled = $0 }))
                Text("Live web search is outside the organization's BAA. Enable it only on assistants for public, non-sensitive conversations. Calculations and time run on the PC.")
                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
            }
            Button("Save voice policy") {
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        policy = try await workspace.request("admin/voice/policy", method: "PUT", body: JSONEncoder().encode(policy))
                        await workspace.refreshVoice(); message = "Voice policy saved."
                    } catch { message = error.localizedDescription }
                }
            }.disabled(busy)
            if let message { Text(message).font(.footnote) }
        }
        .scrollContentBackground(.hidden).background(ScribeTheme.background).tint(ScribeTheme.red)
        .navigationTitle("Watch voice policy")
        .task {
            do { policy = try await workspace.request("admin/voice/policy") }
            catch { message = error.localizedDescription }
        }
    }
}
