// An Always On or temporarily inactive screen is still the conversation screen.
// Foreground visibility gates startup; leaving the app ends an existing session.
struct VoiceScreenLifecycle {
    enum Phase { case active, inactive, background }
    var isVisible = false
    var phase = Phase.inactive
    var isDimmed = false

    var canStartCapture: Bool { isVisible && phase == .active && !isDimmed }
    var canContinueCapture: Bool { isVisible && phase != .background }
}
