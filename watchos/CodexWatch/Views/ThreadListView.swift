import SwiftUI

struct ThreadListView: View {
    @EnvironmentObject private var store: CodexWatchStore
    @State private var searchTerm = ""
    @State private var isSearching = false

    var body: some View {
        List {
            if let currentFolder = store.currentFolder {
                Section {
                    CodexCard(title: "Folder Filter", subtitle: currentFolder.parentLabel) {
                        HStack {
                            FolderChip(label: currentFolder.displayName)
                            Spacer()
                            Button("Clear") {
                                store.clearCurrentFolder()
                                Task {
                                    await store.loadThreads()
                                }
                            }
                            .font(.caption2)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                Button(isSearching ? "Searching..." : "Search by Voice") {
                    Task {
                        await runVoiceSearch()
                    }
                }
                .disabled(isSearching)

                if !searchTerm.isEmpty {
                    Button("Show All Threads") {
                        searchTerm = ""
                        Task {
                            await store.loadThreads()
                        }
                    }
                }
            }

            Section(searchTerm.isEmpty ? "Recent Threads" : "Search Results") {
                if store.threads.isEmpty {
                    Text("No threads found for this desktop.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }

                ForEach(store.threads) { thread in
                    NavigationLink {
                        ThreadDetailView(thread: thread)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(thread.name)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer()
                                StatusChip(text: thread.status)
                            }

                            Text(thread.preview)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(2)

                            HStack(spacing: 6) {
                                if let cwd = thread.cwd {
                                    FolderChip(label: URL(fileURLWithPath: cwd).lastPathComponent)
                                }
                                if thread.planModeEnabled {
                                    StatusChip(text: "question_waiting")
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.04))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Threads")
        .task {
            await store.loadThreads()
        }
    }

    private func runVoiceSearch() async {
        isSearching = true
        defer { isSearching = false }

        do {
            let term = try await DictationService.requestTextInput(suggestions: ["Recent", "Plan mode", "Bridge"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return }
            searchTerm = term
            await store.loadThreads(search: term)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }
}
