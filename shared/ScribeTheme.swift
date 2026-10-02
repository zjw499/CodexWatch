import SwiftUI

enum ScribeTheme {
    static let background = Color(red: 0.105, green: 0.12, blue: 0.135)
    static let surface = Color(red: 0.16, green: 0.18, blue: 0.20)
    static let raised = Color(red: 0.21, green: 0.23, blue: 0.25)
    static let red = Color(red: 0.95, green: 0.22, blue: 0.26)
    static let muted = Color(red: 0.68, green: 0.71, blue: 0.74)
    static let border = Color.white.opacity(0.09)
}

struct ScribePanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(ScribeTheme.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).stroke(ScribeTheme.border, lineWidth: 1) }
    }
}

extension View {
    func scribePanel() -> some View { modifier(ScribePanel()) }
}

struct ScribeStateLabel: View {
    let state: RecordingState
    var body: some View {
        Label(state.label, systemImage: state.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state == .failed ? ScribeTheme.red : ScribeTheme.muted)
    }
}
