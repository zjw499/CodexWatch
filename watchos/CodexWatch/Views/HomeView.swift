import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: CodexWatchStore
    @State private var showingNewPrompt = false

    var body: some View {
        List {
            if let desktop = store.selectedDesktop {
                Section {
                    CodexCard(title: desktop.name, subtitle: desktop.online ? "Desktop online" : "Desktop offline") {
                        HStack {
                            StatusChip(text: desktop.online ? "running" : "offline")
                            if let currentFolder = store.currentFolder {
                                FolderChip(label: currentFolder.displayName)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                NavigationLink("Continue Thread") {
                    ThreadListView()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.16))

                Button("New Thread") {
                    showingNewPrompt = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.16))

                NavigationLink("Working Folder") {
                    WorkingFolderPickerView()
                }
                .buttonStyle(.plain)
            }

            Section("Recent Threads") {
                ForEach(store.threads.prefix(5)) { thread in
                    NavigationLink {
                        ThreadDetailView(thread: thread)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(thread.name)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer()
                                if thread.unreadReply {
                                    Circle()
                                        .fill(.green)
                                        .frame(width: 8, height: 8)
                                }
                            }
                            Text(thread.preview)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                StatusChip(text: thread.status)
                                if let cwd = thread.cwd {
                                    FolderChip(label: URL(fileURLWithPath: cwd).lastPathComponent)
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.04))
                }
            }

            if !store.questionnaires.isEmpty {
                Section("Waiting on You") {
                    NavigationLink {
                        PlanQuestionnaireView(questionnaire: store.questionnaires[0])
                    } label: {
                        Text(store.questionnaires[0].questions.first?.question ?? "Codex needs input")
                    }
                }
            }

            Section("Inbox") {
                ForEach(store.inbox.prefix(5)) { item in
                    NavigationLink {
                        ThreadDetailView(threadID: item.threadID)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.summary)
                                .font(.caption)
                                .foregroundStyle(item.read ? .white.opacity(0.6) : .white)
                                .lineLimit(2)
                            HStack(spacing: 6) {
                                StatusChip(text: item.status)
                                Text(item.type.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.04))
                }
            }

            Section {
                NavigationLink("Settings") {
                    SettingsView()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Codex")
        .sheet(isPresented: $showingNewPrompt) {
            PromptComposerView()
        }
        .task {
            do {
                try await store.refreshHome()
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}
