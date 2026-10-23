import SwiftUI

private struct WorkspaceAgency: Decodable, Identifiable {
    let id: String
    let name: String
    let member_count: Int?
}

struct PhoneAgencyManagementView: View {
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @State private var agencies: [WorkspaceAgency] = []
    @State private var selectedAgency = ""
    @State private var name = ""
    @State private var username = ""
    @State private var role = "admin"
    @State private var invitation: WorkspaceInvitation?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Create agency") {
                TextField("Agency name", text: $name)
                Button("Create agency") {
                    run {
                        let created: WorkspaceAgency = try await workspace.request("operator/agencies", method: "POST",
                            body: JSONEncoder().encode(["name": name]))
                        name = ""; selectedAgency = created.id; invitation = nil; try await load()
                    }
                }.disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            }
            Section("Invite agency member") {
                Picker("Agency", selection: $selectedAgency) {
                    ForEach(agencies) { agency in Text(agency.name).tag(agency.id) }
                }.onChange(of: selectedAgency) { _, _ in invitation = nil }
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Role", selection: $role) { Text("Administrator").tag("admin"); Text("User").tag("user") }
                Button("Create invitation") {
                    run {
                        invitation = try await workspace.request("operator/agencies/\(selectedAgency)/invitations", method: "POST",
                            body: JSONEncoder().encode(["username": username, "role": role]))
                        username = ""
                    }
                }.disabled(busy || selectedAgency.isEmpty || username.isEmpty)
                if let invitation {
                    Text("\(invitation.username) · expires in \(invitation.expires_in_days) days").font(.footnote)
                    Text(invitation.code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).privacySensitive()
                    ShareLink("Share invitation", item: "Scribe Pilot invitation\nAgency: \(agencies.first { $0.id == selectedAgency }?.name ?? "Agency")\nServer: \(workspace.connectionServer)\nUsername: \(invitation.username)\nInvitation code: \(invitation.code)\nExpires in 7 days. In Settings choose Accept invitation and set your password. No VPN setup is needed.")
                }
            }
            Section("Agencies") {
                ForEach(agencies) { agency in
                    LabeledContent(agency.name, value: "\(agency.member_count ?? 0) active")
                }
                Text("Platform access manages agency setup and shared processing settings. Content review remains limited to your own agency.")
                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
            }
            if let message { Section { Text(message).font(.footnote) } }
        }
        .scrollContentBackground(.hidden).background(ScribeTheme.background).tint(ScribeTheme.red)
        .navigationTitle("Manage agencies").navigationBarTitleDisplayMode(.inline)
        .task { run { try await load() } }
    }
    private func load() async throws {
        struct Result: Decodable { let agencies: [WorkspaceAgency] }
        let result: Result = try await workspace.request("operator/agencies")
        agencies = result.agencies
        if !agencies.contains(where: { $0.id == selectedAgency }) { selectedAgency = agencies.first?.id ?? "" }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true; message = nil
        Task { defer { busy = false }; do { try await operation() } catch { message = error.localizedDescription } }
    }
}
