import Foundation

actor CodexWatchAPIClient {
    enum APIError: LocalizedError {
        case invalidURL
        case invalidResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "The relay URL is invalid."
            case .invalidResponse:
                return "The relay returned an unexpected response."
            case .server(let message):
                return message
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let relayToken: String?

    init(baseURL: URL, relayToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.relayToken = relayToken
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    func listDesktops() async throws -> [DesktopTarget] {
        try await get(path: "/v1/watch/desktops", as: [DesktopTarget].self)
    }

    func listThreads(desktopID: String, search: String? = nil, cwd: String? = nil) async throws -> [WatchThreadSummary] {
        var query: [URLQueryItem] = []
        if let search {
            query.append(URLQueryItem(name: "search", value: search))
        }
        if let cwd {
            query.append(URLQueryItem(name: "cwd", value: cwd))
        }
        let response: ThreadListResponse = try await get(path: "/v1/watch/desktops/\(desktopID)/threads", query: query, as: ThreadListResponse.self)
        return response.data
    }

    func readThread(desktopID: String, threadID: String) async throws -> WatchThreadDetail {
        try await get(path: "/v1/watch/desktops/\(desktopID)/threads/\(threadID)", as: WatchThreadDetail.self)
    }

    func createThread(desktopID: String, prompt: String?, cwd: String?, planMode: Bool) async throws -> ThreadStartEnvelope {
        let payload = [
            "prompt": prompt as Any,
            "cwd": cwd as Any,
            "plan_mode": planMode,
        ] as [String: Any?]
        return try await post(path: "/v1/watch/desktops/\(desktopID)/threads", jsonObject: payload, as: ThreadStartEnvelope.self)
    }

    func submitTurn(desktopID: String, threadID: String, prompt: String, cwd: String?, planMode: Bool) async throws -> WatchTurnState {
        let payload = [
            "prompt": prompt,
            "cwd": cwd as Any,
            "plan_mode": planMode,
        ] as [String: Any?]
        return try await post(path: "/v1/watch/desktops/\(desktopID)/threads/\(threadID)/turns", jsonObject: payload, as: WatchTurnState.self)
    }

    func getTurn(turnID: String) async throws -> WatchTurnState {
        try await get(path: "/v1/watch/turns/\(turnID)", as: WatchTurnState.self)
    }

    func listQuestionnaires(threadID: String? = nil) async throws -> [WatchQuestionnaire] {
        let response: QuestionnaireListResponse = try await get(
            path: "/v1/watch/questionnaires",
            query: threadID.map { [URLQueryItem(name: "thread_id", value: $0)] } ?? [],
            as: QuestionnaireListResponse.self
        )
        return response.data
    }

    func answerQuestionnaire(requestID: String, answers: [String: [String]]) async throws -> WatchTurnState {
        let mapped = answers.mapValues { QuestionnaireAnswerPayload.AnswerValue(answers: $0) }
        let payload = QuestionnaireAnswerPayload(answers: mapped)
        return try await post(path: "/v1/watch/questionnaires/\(requestID)/answers", body: payload, as: WatchTurnState.self)
    }

    func recentFolders(desktopID: String) async throws -> [WorkingFolderNode] {
        let response: FolderListResponse = try await get(path: "/v1/watch/desktops/\(desktopID)/folders/recents", as: FolderListResponse.self)
        return response.entries
    }

    func favoriteFolders(desktopID: String) async throws -> [WorkingFolderNode] {
        let response: FolderListResponse = try await get(path: "/v1/watch/desktops/\(desktopID)/folders/favorites", as: FolderListResponse.self)
        return response.entries
    }

    func browseFolders(desktopID: String, path: String?) async throws -> [WorkingFolderNode] {
        let query = path.map { [URLQueryItem(name: "path", value: $0)] } ?? []
        let response: FolderListResponse = try await get(path: "/v1/watch/desktops/\(desktopID)/folders/browse", query: query, as: FolderListResponse.self)
        return response.entries
    }

    func searchFolders(desktopID: String, query: String) async throws -> [WorkingFolderNode] {
        let response: FolderListResponse = try await get(
            path: "/v1/watch/desktops/\(desktopID)/folders/search",
            query: [URLQueryItem(name: "q", value: query)],
            as: FolderListResponse.self
        )
        return response.entries
    }

    func addFavorite(desktopID: String, path: String) async throws -> [WorkingFolderNode] {
        let response: FolderListResponse = try await post(
            path: "/v1/watch/desktops/\(desktopID)/folders/favorites",
            jsonObject: ["path": path],
            as: FolderListResponse.self
        )
        return response.entries
    }

    func removeFavorite(desktopID: String, path: String) async throws -> [WorkingFolderNode] {
        let response: FolderListResponse = try await delete(
            path: "/v1/watch/desktops/\(desktopID)/folders/favorites",
            query: [URLQueryItem(name: "path", value: path)],
            as: FolderListResponse.self
        )
        return response.entries
    }

    func listInbox(unreadOnly: Bool = false) async throws -> [InboxNotification] {
        let query = unreadOnly ? [URLQueryItem(name: "unread_only", value: "true")] : []
        let response: InboxListResponse = try await get(path: "/v1/watch/inbox", query: query, as: InboxListResponse.self)
        return response.data
    }

    func markNotificationRead(notificationID: String) async throws -> InboxNotification {
        try await post(path: "/v1/watch/inbox/\(notificationID)/read", jsonObject: [:], as: InboxNotification.self)
    }

    private func get<T: Decodable>(path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addHeaders(to: &request)
        return try await execute(request, as: type)
    }

    private func post<T: Decodable, Body: Encodable>(path: String, body: Body, as type: T.Type) async throws -> T {
        var request = try makeRequest(path: path, method: "POST")
        request.httpBody = try encoder.encode(body)
        return try await execute(request, as: type)
    }

    private func post<T: Decodable>(path: String, jsonObject: [String: Any?], as type: T.Type) async throws -> T {
        var request = try makeRequest(path: path, method: "POST")
        let sanitized = jsonObject.compactMapValues { $0 }
        request.httpBody = try JSONSerialization.data(withJSONObject: sanitized)
        return try await execute(request, as: type)
    }

    private func delete<T: Decodable>(path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addHeaders(to: &request)
        return try await execute(request, as: type)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addHeaders(to: &request)
        return request
    }

    private func addHeaders(to request: inout URLRequest) {
        if let relayToken {
            request.setValue("Bearer \(relayToken)", forHTTPHeaderField: "Authorization")
        }
    }

    private func execute<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw APIError.server(message ?? "The relay request failed.")
        }
        return try decoder.decode(type, from: data)
    }
}
