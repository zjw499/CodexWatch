import Foundation

struct DesktopTarget: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let platform: String
    let online: Bool
    let hasDDrive: Bool
    let relayState: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case platform
        case online
        case hasDDrive = "has_d_drive"
        case relayState = "relay_state"
    }
}

struct WatchThreadSummary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let preview: String
    let cwd: String?
    let updatedAt: Int
    let status: String
    let unreadReply: Bool
    let planModeEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case preview
        case cwd
        case updatedAt = "updated_at"
        case status
        case unreadReply = "unread_reply"
        case planModeEnabled = "plan_mode_enabled"
    }
}

struct WatchThreadDetail: Codable, Hashable {
    let id: String
    let name: String
    let preview: String
    let cwd: String?
    let updatedAt: Int
    let status: String
    let latestReply: String?
    let latestSnippet: String?
    let changedFilesCount: Int
    let recentToolSummary: String?
    let unreadReply: Bool
    let planModeEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case preview
        case cwd
        case updatedAt = "updated_at"
        case status
        case latestReply = "latest_reply"
        case latestSnippet = "latest_snippet"
        case changedFilesCount = "changed_files_count"
        case recentToolSummary = "recent_tool_summary"
        case unreadReply = "unread_reply"
        case planModeEnabled = "plan_mode_enabled"
    }
}

struct WatchTurnState: Codable, Hashable {
    let turnID: String
    let threadID: String
    let status: String
    let snippet: String?
    let latestMessage: String?
    let pendingQuestionnaireID: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case threadID = "thread_id"
        case status
        case snippet
        case latestMessage = "latest_message"
        case pendingQuestionnaireID = "pending_questionnaire_id"
        case errorMessage = "error_message"
    }
}

struct WorkingFolderNode: Codable, Identifiable, Hashable {
    let token: String
    let absolutePath: String
    let displayName: String
    let parentLabel: String?
    let isPinned: Bool
    let isRecent: Bool

    var id: String { token }

    enum CodingKeys: String, CodingKey {
        case token
        case absolutePath = "absolute_path"
        case displayName = "display_name"
        case parentLabel = "parent_label"
        case isPinned = "is_pinned"
        case isRecent = "is_recent"
    }
}

struct WatchOption: Codable, Hashable {
    let label: String
    let description: String
}

struct WatchQuestion: Codable, Identifiable, Hashable {
    let id: String
    let header: String
    let question: String
    let options: [WatchOption]
    let supportsOtherVoice: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case header
        case question
        case options
        case supportsOtherVoice = "supports_other_voice"
    }
}

struct WatchQuestionnaire: Codable, Identifiable, Hashable {
    let requestID: String
    let itemID: String
    let threadID: String
    let turnID: String
    let questions: [WatchQuestion]
    let createdAt: Date
    let answered: Bool

    var id: String { requestID }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case itemID = "item_id"
        case threadID = "thread_id"
        case turnID = "turn_id"
        case questions
        case createdAt = "created_at"
        case answered
    }
}

struct InboxNotification: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let desktopID: String
    let threadID: String
    let turnID: String?
    let summary: String
    let status: String
    let deepLink: String
    let createdAt: Date
    let read: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case desktopID = "desktop_id"
        case threadID = "thread_id"
        case turnID = "turn_id"
        case summary
        case status
        case deepLink = "deep_link"
        case createdAt = "created_at"
        case read
    }
}

struct ThreadListResponse: Codable {
    let data: [WatchThreadSummary]
}

struct FolderListResponse: Codable {
    let entries: [WorkingFolderNode]
}

struct QuestionnaireListResponse: Codable {
    let data: [WatchQuestionnaire]
}

struct InboxListResponse: Codable {
    let data: [InboxNotification]
}

struct ThreadStartEnvelope: Codable {
    let thread: WatchThreadSummary
    let turn: WatchTurnState?
}

struct QuestionnaireAnswerPayload: Codable {
    struct AnswerValue: Codable {
        let answers: [String]
    }

    let answers: [String: AnswerValue]
}
