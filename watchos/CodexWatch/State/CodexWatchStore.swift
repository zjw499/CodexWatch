import Foundation
import SwiftUI

@MainActor
final class CodexWatchStore: ObservableObject {
    private enum PreferenceKeys {
        static let defaultPlanMode = "codexwatch.defaultPlanMode"
        static let selectedDesktopID = "codexwatch.selectedDesktopID"
        static let currentFolderPath = "codexwatch.currentFolderPath"
    }

    @Published var desktops: [DesktopTarget] = []
    @Published var selectedDesktop: DesktopTarget?
    @Published var threads: [WatchThreadSummary] = []
    @Published var selectedThreadDetail: WatchThreadDetail?
    @Published var inbox: [InboxNotification] = []
    @Published var questionnaires: [WatchQuestionnaire] = []
    @Published var recentFolders: [WorkingFolderNode] = []
    @Published var favoriteFolders: [WorkingFolderNode] = []
    @Published var browsedFolders: [WorkingFolderNode] = []
    @Published var currentFolder: WorkingFolderNode?
    @Published var activeTurn: WatchTurnState?
    @Published var defaultPlanMode = false
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let api: CodexWatchAPIClient

    init(api: CodexWatchAPIClient) {
        self.api = api
        self.defaultPlanMode = UserDefaults.standard.bool(forKey: PreferenceKeys.defaultPlanMode)
    }

    func loadBootstrap() async {
        isLoading = true
        defer { isLoading = false }

        do {
            desktops = try await api.listDesktops()
            let savedDesktopID = UserDefaults.standard.string(forKey: PreferenceKeys.selectedDesktopID)
            selectedDesktop = selectedDesktop ?? desktops.first(where: { $0.id == savedDesktopID }) ?? desktops.first
            try await refreshHome()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshHome() async throws {
        guard let desktop = selectedDesktop else { return }
        async let threadLoad = api.listThreads(desktopID: desktop.id)
        async let inboxLoad = api.listInbox(unreadOnly: false)
        async let recentLoad = api.recentFolders(desktopID: desktop.id)
        async let favoriteLoad = api.favoriteFolders(desktopID: desktop.id)
        async let questionnaireLoad = api.listQuestionnaires()

        threads = try await threadLoad
        inbox = try await inboxLoad
        recentFolders = try await recentLoad
        favoriteFolders = try await favoriteLoad
        questionnaires = try await questionnaireLoad

        if currentFolder == nil {
            currentFolder = restoredFolderNode()
        }
    }

    func loadThreads(search: String? = nil) async {
        guard let desktop = selectedDesktop else { return }
        do {
            threads = try await api.listThreads(desktopID: desktop.id, search: search, cwd: currentFolder?.absolutePath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectDesktop(_ desktop: DesktopTarget) async {
        selectedDesktop = desktop
        selectedThreadDetail = nil
        activeTurn = nil
        UserDefaults.standard.set(desktop.id, forKey: PreferenceKeys.selectedDesktopID)
        do {
            try await refreshHome()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openThread(_ thread: WatchThreadSummary) async {
        guard let desktop = selectedDesktop else { return }
        do {
            selectedThreadDetail = try await api.readThread(desktopID: desktop.id, threadID: thread.id)
            try await refreshQuestionnaires()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openThread(threadID: String) async {
        guard let desktop = selectedDesktop else { return }
        do {
            selectedThreadDetail = try await api.readThread(desktopID: desktop.id, threadID: threadID)
            try await refreshQuestionnaires()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createThread(prompt: String, planMode: Bool) async {
        guard let desktop = selectedDesktop else { return }
        do {
            let result = try await api.createThread(
                desktopID: desktop.id,
                prompt: prompt,
                cwd: currentFolder?.absolutePath,
                planMode: planMode
            )
            activeTurn = result.turn
            try await refreshHome()
            await openThread(result.thread)
            try await refreshQuestionnaires()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submitPrompt(to threadID: String, prompt: String, planMode: Bool) async {
        guard let desktop = selectedDesktop else { return }
        do {
            activeTurn = try await api.submitTurn(
                desktopID: desktop.id,
                threadID: threadID,
                prompt: prompt,
                cwd: currentFolder?.absolutePath,
                planMode: planMode
            )
            try await refreshQuestionnaires()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pollActiveTurn() async {
        guard let activeTurn else { return }
        do {
            self.activeTurn = try await api.getTurn(turnID: activeTurn.turnID)
            if selectedThreadDetail?.id == activeTurn.threadID {
                try await openThreadSnapshot(threadID: activeTurn.threadID)
            }
            try await refreshQuestionnaires()
            try await refreshInbox()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshQuestionnaires() async throws {
        questionnaires = try await api.listQuestionnaires(threadID: selectedThreadDetail?.id)
    }

    func answer(questionnaire: WatchQuestionnaire, answers: [String: [String]]) async {
        do {
            activeTurn = try await api.answerQuestionnaire(requestID: questionnaire.requestID, answers: answers)
            try await refreshQuestionnaires()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func browse(path: String?) async {
        guard let desktop = selectedDesktop else { return }
        do {
            browsedFolders = try await api.browseFolders(desktopID: desktop.id, path: path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func searchFolders(query: String) async {
        guard let desktop = selectedDesktop else { return }
        do {
            browsedFolders = try await api.searchFolders(desktopID: desktop.id, query: query)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleFavorite(path: String, isFavorite: Bool) async {
        guard let desktop = selectedDesktop else { return }
        do {
            if isFavorite {
                favoriteFolders = try await api.addFavorite(desktopID: desktop.id, path: path)
            } else {
                favoriteFolders = try await api.removeFavorite(desktopID: desktop.id, path: path)
            }
            try await refreshHome()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshInbox() async throws {
        inbox = try await api.listInbox(unreadOnly: false)
    }

    func markNotificationRead(_ notification: InboxNotification) async {
        do {
            _ = try await api.markNotificationRead(notificationID: notification.id)
            try await refreshInbox()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleDeepLink(_ url: URL) async {
        guard url.host == "thread" || url.pathComponents.count >= 2 else { return }
        let threadID = url.host == "thread" ? url.lastPathComponent : url.pathComponents[1]
        if let match = threads.first(where: { $0.id == threadID }) {
            await openThread(match)
            return
        }

        await openThread(threadID: threadID)
    }

    func setCurrentFolder(_ folder: WorkingFolderNode?) {
        currentFolder = folder
        UserDefaults.standard.set(folder?.absolutePath, forKey: PreferenceKeys.currentFolderPath)
    }

    func setDefaultPlanMode(_ enabled: Bool) {
        defaultPlanMode = enabled
        UserDefaults.standard.set(enabled, forKey: PreferenceKeys.defaultPlanMode)
    }

    func clearCurrentFolder() {
        currentFolder = nil
        UserDefaults.standard.removeObject(forKey: PreferenceKeys.currentFolderPath)
    }

    private func openThreadSnapshot(threadID: String) async throws {
        guard let desktop = selectedDesktop else { return }
        selectedThreadDetail = try await api.readThread(desktopID: desktop.id, threadID: threadID)
    }

    private func restoredFolderNode() -> WorkingFolderNode? {
        guard let path = UserDefaults.standard.string(forKey: PreferenceKeys.currentFolderPath), !path.isEmpty else {
            return nil
        }
        if let match = (favoriteFolders + recentFolders + browsedFolders).first(where: { $0.absolutePath == path }) {
            return match
        }

        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        return WorkingFolderNode(
            token: path,
            absolutePath: path,
            displayName: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
            parentLabel: parent == path ? nil : parent,
            isPinned: favoriteFolders.contains(where: { $0.absolutePath == path }),
            isRecent: recentFolders.contains(where: { $0.absolutePath == path })
        )
    }
}
