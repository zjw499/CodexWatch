import SwiftUI

struct DesktopPickerView: View {
    @EnvironmentObject private var store: CodexWatchStore

    var body: some View {
        List {
            Section("Available Desktops") {
                ForEach(store.desktops) { desktop in
                    Button {
                        Task {
                            await store.selectDesktop(desktop)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(desktop.name)
                                    .foregroundStyle(.white)
                                Spacer()
                                Circle()
                                    .fill(desktop.online ? .green : .gray)
                                    .frame(width: 8, height: 8)
                            }
                            HStack(spacing: 6) {
                                Text(desktop.platform.capitalized)
                                if desktop.hasDDrive {
                                    Text("D:")
                                }
                                Text(desktop.relayState.capitalized)
                            }
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.06))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("Codex Watch")
    }
}
