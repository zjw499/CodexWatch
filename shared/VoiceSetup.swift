import Foundation

enum VoiceSetupState: String, Codable {
    case ready, needsSetup, needsUnlock, disabled, needsAssistant, updateRequired
    var message: String {
        switch self {
        case .ready: return "Watch voice is connected. No setup code is needed."
        case .needsSetup: return "Sign in to Scribe Pilot on your iPhone once. Watch voice connects automatically when your unlocked Watch is nearby. No code is needed."
        case .needsUnlock: return "Unlock your Watch and enable a Watch passcode, then try Talk again."
        case .disabled: return "Watch voice is currently disabled for this account."
        case .needsAssistant: return "Enable voice conversations on an assistant in iPhone Settings."
        case .updateRequired: return "Update Scribe Pilot on both your iPhone and Watch. Voice reconnects automatically."
        }
    }
}

enum SessionRenewal {
    static let header = "X-Scribe-Session-Expires"
    static func accepts(_ expiry: Double, after current: Double, now: Double = Date().timeIntervalSince1970) -> Bool {
        expiry.isFinite && expiry > current && expiry > now && expiry <= now + 366 * 86400
    }
}

struct VoiceStartupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Contains no credential. A receipt proves that this particular setup reached the Watch.
struct VoiceSetupReceipt: Codable, Equatable {
    let version: Int
    let requestID: String
    let ownerID: String
    let deviceID: String
    let state: VoiceSetupState
}

struct WatchVoiceBinding: Codable {
    let parentHash: String
    let credential: VoiceDeviceCredential
    var setupRequestID: String?
    var receipt: VoiceSetupReceipt?

    func accepts(_ receipt: VoiceSetupReceipt, owner: String?) -> Bool {
        receipt.version == 1 && credential.valid && owner == credential.owner_id
            && receipt.ownerID == owner && receipt.deviceID == credential.device_id
            && setupRequestID == receipt.requestID && VoiceWire.validID(receipt.requestID)
    }
}
