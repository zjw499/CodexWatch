import Foundation

enum VoiceSetupState: String, Codable {
    case ready, needsSetup, needsUnlock, disabled, needsAssistant, updateRequired
    var message: String {
        switch self {
        case .ready: return "Watch voice is connected. No setup code is needed."
        case .needsSetup: return "Open Scribe Pilot on your iPhone, then Settings > Watch voice > Connect Watch voice. No code is needed."
        case .needsUnlock: return "Unlock your Watch and enable a Watch passcode, then connect Watch voice again on your iPhone."
        case .disabled: return "Watch voice is currently disabled for this account."
        case .needsAssistant: return "Enable voice conversations on an assistant in iPhone Settings."
        case .updateRequired: return "Update Scribe Pilot on both your iPhone and Watch, then connect Watch voice again."
        }
    }
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
