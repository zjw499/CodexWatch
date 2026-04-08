import SwiftUI

struct ThreadDetailView: View {
    @EnvironmentObject private var store: CodexWatchStore

    private let threadID: String
    private let initialThread: WatchThreadSummary?

    @State private var showingPromptComposer = false

    init(thread: WatchThreadSummary) {
        self.threadID = thread.id
        self.initialThread = thread
    }

    init(threadID: String) {
        self.threadID = threadID
        self.initialThread = nil
    }

    private var detail: WatchThreadDetail? {
        guard store.selectedThreadDetail?.id == threadID else {
            return nil
        }
        return store.selectedThreadDetail
    }

    private var titleText: String {
        detail?.name ?? initialThread?.name ?? "Thread"
    }

    private var threadQuestionnaires: [WatchQuestionnaire] {
        store.questionnaires.filter { $0.threadID == threadID && !$0.answered }
    }

    private var turnState: WatchTurnState? {
        guard store.activeTurn?.threadID == threadID else {
            return nil
        }
        return store.activeTurn
    }

    var body: some View {
        List {
            Section {
                CodexCard(title: titleText, subtitle: detail?.preview ?? initialThread?.preview) {
                    HStack {
                        StatusChip(text: detail?.status ?? initialThread?.status ?? "unknown")
                        if detail?.planModeEnabled == true || initialThread?.planModeEnabled == true {
                            FolderChip(label: "Plan Mode")
                        }
                    }

                    if let cwd = detail?.cwd ?? initialThread?.cwd {
                        FolderChip(label: URL(fileURLWithPath: cwd).lastPathComponent)
                    }
                }
                .listRowBackground(Color.clear)
            }

            if let turnState {
                Section("Turn Status") {
                    CodexCard(title: turnState.status.replacingOccurrences(of: "_", with: " ").capitalized, subtitle: turnState.snippet) {
                        if let latestMessage = turnState.latestMessage, !latestMessage.isEmpty {
                            Text(latestMessage)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(4)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                Button("Voice Follow-Up") {
                    showingPromptComposer = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.16))

                Button("Refresh") {
                    Task {
                        await refreshThread()
                    }
                }
            }

            if !threadQuestionnaires.isEmpty {
                Section("Waiting on You") {
                    ForEach(threadQuestionnaires) { questionnaire in
                        NavigationLink {
                            PlanQuestionnaireView(questionnaire: questionnaire)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(questionnaire.questions.first?.question ?? "Codex needs input")
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                Text("\(questionnaire.questions.count) questions")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }
                }
            }

            if let latestReply = detail?.latestReply, !latestReply.isEmpty {
                Section("Latest Reply") {
                    Text(latestReply)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                        .listRowBackground(Color.white.opacity(0.04))
                }
            }

            if let latestSnippet = detail?.latestSnippet, !latestSnippet.isEmpty, latestSnippet != detail?.latestReply {
                Section("Live Snippet") {
                    Text(latestSnippet)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .listRowBackground(Color.white.opacity(0.04))
                }
            }

            if detail?.recentToolSummary != nil || (detail?.changedFilesCount ?? 0) > 0 {
                Section("Workspace") {
                    if let recentToolSummary = detail?.recentToolSummary {
                        Text(recentToolSummary)
                            .foregroundStyle(.white)
                    }
                    if let changedFilesCount = detail?.changedFilesCount, changedFilesCount > 0 {
                        Text("\(changedFilesCount) files changed")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle(titleText)
        .sheet(isPresented: $showingPromptComposer) {
            PromptComposerView(threadID: threadID, threadName: titleText)
        }
        .task {
            await refreshThread()
        }
        .task(id: turnState?.turnID) {
            await pollTurnIfNeeded()
        }
    }

    private func refreshThread() async {
        if let initialThread {
            await store.openThread(initialThread)
        } else {
            await store.openThread(threadID: threadID)
        }
    }

    private func pollTurnIfNeeded() async {
        guard let state = turnState else { return }

        var shouldContinue = state.status == "running" || state.status == "question_waiting"
        while shouldContinue && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await store.pollActiveTurn()
            await refreshThread()
            guard let next = store.activeTurn, next.turnID == state.turnID else {
                break
            }
            shouldContinue = next.status == "running" || next.status == "question_waiting"
        }
    }
}
