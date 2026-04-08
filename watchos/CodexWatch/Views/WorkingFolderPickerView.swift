import SwiftUI

struct WorkingFolderPickerView: View {
    @EnvironmentObject private var store: CodexWatchStore

    let rootPath: String?

    @State private var searchQuery = ""
    @State private var isSearching = false

    init(rootPath: String? = nil) {
        self.rootPath = rootPath
    }

    private var selectedPath: String? {
        store.currentFolder?.absolutePath
    }

    private var currentScopeTitle: String {
        if let rootPath {
            return URL(fileURLWithPath: rootPath).lastPathComponent
        }
        return "Working Folder"
    }

    var body: some View {
        List {
            if store.selectedDesktop?.hasDDrive == false {
                Section {
                    CodexCard(title: "D: Unavailable", subtitle: "This desktop does not expose an approved D: workspace.") {
                        Text("Choose another desktop or update the desktop relay allowlist.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    if let currentFolder = store.currentFolder {
                        CodexCard(title: currentFolder.displayName, subtitle: currentFolder.parentLabel) {
                            HStack {
                                Button("Clear") {
                                    store.clearCurrentFolder()
                                }
                                .font(.caption2)

                                Spacer()

                                Button(isPinned(path: currentFolder.absolutePath) ? "Unpin" : "Pin") {
                                    Task {
                                        await store.toggleFavorite(path: currentFolder.absolutePath, isFavorite: !isPinned(path: currentFolder.absolutePath))
                                    }
                                }
                                .font(.caption2)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }

                    if let rootPath {
                        Button("Use This Folder") {
                            store.setCurrentFolder(folderNode(for: rootPath))
                        }
                    }

                    Button(isSearching ? "Searching..." : "Search D: by Voice") {
                        Task {
                            await searchByVoice()
                        }
                    }
                    .disabled(isSearching)

                    if !searchQuery.isEmpty {
                        Button("Back to Browse") {
                            searchQuery = ""
                            Task {
                                if let rootPath {
                                    await store.browse(path: rootPath)
                                } else {
                                    await store.browse(path: nil)
                                }
                            }
                        }
                    }
                }

                if rootPath == nil && searchQuery.isEmpty && !store.recentFolders.isEmpty {
                    Section("Recents") {
                        ForEach(store.recentFolders) { folder in
                            folderButton(for: folder)
                        }
                    }
                }

                if rootPath == nil && searchQuery.isEmpty && !store.favoriteFolders.isEmpty {
                    Section("Favorites") {
                        ForEach(store.favoriteFolders) { folder in
                            folderButton(for: folder)
                        }
                    }
                }

                Section(searchQuery.isEmpty ? "Browse D:" : "Search Results") {
                    ForEach(store.browsedFolders) { folder in
                        if searchQuery.isEmpty {
                            NavigationLink {
                                WorkingFolderPickerView(rootPath: folder.absolutePath)
                            } label: {
                                folderRow(for: folder)
                            }
                        } else {
                            folderButton(for: folder)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle(currentScopeTitle)
        .task(id: rootPath ?? "__root__") {
            if let rootPath {
                await store.browse(path: rootPath)
            } else {
                try? await store.refreshHome()
                await store.browse(path: nil)
            }
        }
    }

    @ViewBuilder
    private func folderButton(for folder: WorkingFolderNode) -> some View {
        Button {
            store.setCurrentFolder(folder)
        } label: {
            folderRow(for: folder)
        }
        .listRowBackground(selectedPath == folder.absolutePath ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
    }

    private func folderRow(for folder: WorkingFolderNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(folder.displayName)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if selectedPath == folder.absolutePath {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if let parentLabel = folder.parentLabel {
                Text(parentLabel)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                if folder.isRecent {
                    FolderChip(label: "Recent")
                }
                if folder.isPinned || isPinned(path: folder.absolutePath) {
                    FolderChip(label: "Pinned")
                }
            }
        }
    }

    private func searchByVoice() async {
        isSearching = true
        defer { isSearching = false }

        do {
            let query = try await DictationService.requestTextInput(suggestions: ["Projects", "Bridge", "Archive"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            searchQuery = query
            await store.searchFolders(query: query)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func isPinned(path: String) -> Bool {
        store.favoriteFolders.contains(where: { $0.absolutePath == path })
    }

    private func folderNode(for path: String) -> WorkingFolderNode {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        return WorkingFolderNode(
            token: path,
            absolutePath: path,
            displayName: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
            parentLabel: parent == path ? nil : parent,
            isPinned: isPinned(path: path),
            isRecent: store.recentFolders.contains(where: { $0.absolutePath == path })
        )
    }
}
