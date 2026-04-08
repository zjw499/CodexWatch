import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: CodexWatchStore

    @State private var replyNotifications = true
    @State private var questionNotifications = true
    @State private var offlineNotifications = true

    var body: some View {
        List {
            if let desktop = store.selectedDesktop {
                Section("Desktop") {
                    CodexCard(title: desktop.name, subtitle: desktop.platform.capitalized) {
                        HStack {
                            StatusChip(text: desktop.online ? "running" : "offline")
                            if desktop.hasDDrive {
                                FolderChip(label: "D: enabled")
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }

            Section("Defaults") {
                Toggle(
                    "Plan Mode by Default",
                    isOn: Binding(
                        get: { store.defaultPlanMode },
                        set: { store.setDefaultPlanMode($0) }
                    )
                )
                .tint(.white)

                if let currentFolder = store.currentFolder {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current Working Folder")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                        Text(currentFolder.absolutePath)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }

                    Button("Clear Working Folder") {
                        store.clearCurrentFolder()
                    }
                }
            }

            Section("Notifications") {
                Toggle("Reply Ready", isOn: $replyNotifications)
                    .tint(.white)
                Toggle("Question Waiting", isOn: $questionNotifications)
                    .tint(.white)
                Toggle("Desktop Offline", isOn: $offlineNotifications)
                    .tint(.white)
            }

            Section("Privacy") {
                Text("Folder browsing is limited to the D: allowlist exposed by the trusted desktop relay.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Settings")
    }
}
