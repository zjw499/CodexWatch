import Foundation

private final class VoiceNetworkDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class WatchVoiceClient {
    private let delegate = VoiceNetworkDelegate()
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 3700
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    private func request(_ path: String, credential: VoiceDeviceCredential, method: String, data: Data?, audio: Bool) throws -> URLRequest {
        guard credential.valid, let base = VoiceWire.gatewayURL(credential.gateway_url),
              let url = URL(string: base.absoluteString + "/" + path) else { throw VoiceError.setup }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = data
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue(audio ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }
    private func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw VoiceError.connection }
        guard (200..<300).contains(response.statusCode) else { throw VoiceError.status(response.statusCode) }
    }
    func send<T: Decodable>(_ path: String, credential: VoiceDeviceCredential, method: String = "GET", data: Data? = nil) async throws -> T {
        let (body, response) = try await session.data(for: request(path, credential: credential, method: method, data: data, audio: false))
        try check(response)
        return try JSONDecoder().decode(T.self, from: body)
    }
    func audio(_ data: Data, sequence: Int, sessionID: String, credential: VoiceDeviceCredential) async throws {
        guard VoiceWire.validID(sessionID) else { throw VoiceError.connection }
        let request = try request("sessions/\(sessionID)/audio?sequence=\(sequence)", credential: credential, method: "POST", data: data, audio: true)
        // One retry with identical bytes/sequence handles a lost HTTP acknowledgement.
        do {
            let (_, response) = try await session.data(for: request); try check(response)
        } catch let error as URLError where [.timedOut, .networkConnectionLost].contains(error.code) {
            try Task.checkCancellation()
            let (_, response) = try await session.data(for: request); try check(response)
        }
    }
    func control(_ control: VoiceControl, sessionID: String, credential: VoiceDeviceCredential) async throws {
        guard VoiceWire.validID(sessionID) else { throw VoiceError.connection }
        let _: VoiceOK = try await send("sessions/\(sessionID)/control", credential: credential, method: "POST", data: JSONEncoder().encode(control))
    }
    func stream(sessionID: String, credential: VoiceDeviceCredential, receive: @escaping @MainActor (VoiceEvent) async throws -> Void) async throws {
        guard VoiceWire.validID(sessionID) else { throw VoiceError.connection }
        var request = try request("sessions/\(sessionID)/events", credential: credential, method: "GET", data: nil, audio: false)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        try check(response)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let event = try VoiceWire.event(line: line) {
                try await receive(event)
                if event.type == "ended" { return }
            }
        }
        throw VoiceError.connection
    }
}

struct VoiceOK: Decodable { let ok: Bool }
