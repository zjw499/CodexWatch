import Foundation

enum VoiceConnectionPolicy {
    static let requestTimeout = 3.0
    static let controlGrace = 10.0
    static func transient(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                    .dnsLookupFailed, .notConnectedToInternet].contains(error.code)
        }
        if let error = error as? VoiceError, case let .status(code) = error {
            return [502, 503, 504].contains(code)
        }
        return false
    }
    static func endAfterControlFailure(_ error: Error, secondsSinceContact: Double) -> Bool {
        !transient(error) || secondsSinceContact >= controlGrace
    }
}
