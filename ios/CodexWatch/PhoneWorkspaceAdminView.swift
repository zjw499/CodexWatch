import SwiftUI

struct PhoneWorkspaceAdminView: View {
    @ObservedObject private var workspace = PhoneWorkspace.shared
    @State private var users: [WorkspaceManagedUser] = []
    @State private var recordings: [WorkspaceRecording] = []
    @State private var policy = WorkspacePolicy()
    @State private var username = ""
    @State private var role = "user"
    @State private var invitation: WorkspaceInvitation?
    @State private var busy = false
    @State private var message: String?
    @State private var confirmingPolicy = false
    @State private var disabling: WorkspaceManagedUser?
    var body: some View {
        Form {
            Section("Invite a user") {
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Role", selection: $role) { Text("User").tag("user"); Text("Administrator").tag("admin") }
                Button("Create invitation") {
                    run { invitation = try await workspace.request("admin/invitations", method: "POST", body: JSONEncoder().encode(["username": username, "role": role])); username = "" }
                }.disabled(busy || username.isEmpty)
                if let invitation {
                    Text("Username: \(invitation.username)").font(.footnote)
                    Text(invitation.code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).privacySensitive()
                    ShareLink(item: "Scribe Pilot invitation\nServer: \(workspace.credential?.server ?? PhoneWorkspace.defaultServer)\nUsername: \(invitation.username)\nInvitation code: \(invitation.code)\nExpires in 7 days. In Settings choose Accept invitation and set your password.") {
                        Label("Share invitation", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section("Accounts") {
                ForEach(users) { user in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(user.username) · \(user.role)\(user.active == 0 ? " · disabled" : "")")
                        HStack {
                            Button("Revoke sessions") { run { let _: PhoneWorkspace.OK = try await workspace.request("admin/users/\(user.id)/sessions", method: "DELETE") } }
                            if user.id != workspace.user?.id && user.active == 1 {
                                Button("Disable", role: .destructive) { disabling = user }
                            }
                        }.font(.caption).buttonStyle(.bordered)
                    }
                }
            }
            Section("Shared OpenAI approval") {
                Text("Organization: \(policy.organization_id)").font(.caption).textSelection(.enabled)
                Text("Project: \(policy.project_id)").font(.caption).textSelection(.enabled)
                Toggle("Signed BAA verified", isOn: $policy.baa_verified)
                Toggle("Approved retention verified for this project", isOn: $policy.retention_verified)
                Toggle("PC, storage, and access safeguards verified", isOn: $policy.safeguards_verified)
                TextField("Approval evidence / reference", text: $policy.approval_evidence, axis: .vertical).lineLimit(3...8)
                Button("Save organization approval") { confirmingPolicy = true }.disabled(busy)
                Text("These controls record your organization's verification. They do not provision OpenAI retention. Keep retention unconfirmed until the actual org/project setting is verified. No patient information belongs in this evidence field.")
                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
                Link("OpenAI HIPAA requirements", destination: URL(string: "https://help.openai.com/en/articles/20001069-hipaa-eligible-products-and-functionality")!)
            }
            Section("Organization review") {
                NavigationLink("Review all users' recordings") {
                    List(recordings) { recording in
                        NavigationLink { PhoneRemoteRecordingView(recordingID: recording.id, review: true) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recording.title)
                                Text("\(users.first(where: { $0.id == recording.owner })?.username ?? recording.owner) · \(recording.state)")
                                    .font(.caption).foregroundStyle(ScribeTheme.muted)
                            }
                        }
                    }.scrollContentBackground(.hidden).background(ScribeTheme.background).navigationTitle("Organization recordings")
                    .task { run { recordings = try await workspace.remoteRecordings(review: true) } }
                }
                NavigationLink("Audit log") { PhoneWorkspaceAuditView() }
                Text("Opening another user's content records administrator access in the audit log.")
                    .font(.footnote).foregroundStyle(ScribeTheme.muted)
            }
            if let message { Section { Text(message).font(.footnote) } }
        }
        .scrollContentBackground(.hidden).background(ScribeTheme.background).tint(ScribeTheme.red)
        .navigationTitle("Administrator").navigationBarTitleDisplayMode(.inline)
        .task { await load() }.refreshable { await load() }
        .confirmationDialog("Save the organization's verified approvals?", isPresented: $confirmingPolicy, titleVisibility: .visible) {
            Button("Save approval") { run { policy = try await workspace.request("admin/policy", method: "PUT", body: JSONEncoder().encode(policy)); await workspace.refresh() } }
        }
        .confirmationDialog("Disable \(disabling?.username ?? "account")?", isPresented: Binding(get: { disabling != nil }, set: { if !$0 { disabling = nil } }), titleVisibility: .visible) {
            Button("Disable account", role: .destructive) {
                guard let target = disabling else { return }; disabling = nil
                run { let _: PhoneWorkspace.OK = try await workspace.request("admin/users/\(target.id)/disable", method: "POST"); await load() }
            }
        }
    }
    private func load() async {
        do {
            let response: PhoneWorkspace.Users = try await workspace.request("admin/users"); users = response.users
            policy = try await workspace.request("admin/policy")
        } catch { message = error.localizedDescription }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true; message = nil
        Task { defer { busy = false }; do { try await operation() } catch { message = error.localizedDescription } }
    }
}

struct PhoneWorkspaceAuditView: View {
    @State private var events: [WorkspaceAuditEvent] = []
    @State private var message: String?
    var body: some View {
        List {
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.action.replacingOccurrences(of: "-", with: " ")).font(.headline)
                    Text(Date(timeIntervalSince1970: event.timestamp), style: .date)
                    Text("Actor: \(event.actor)\nTarget: \(event.target)").font(.caption).foregroundStyle(ScribeTheme.muted)
                }
            }
            if events.count >= 100 { Button("Load older events") { Task { await load(offset: events.count) } } }
            if let message { Text(message) }
        }.scrollContentBackground(.hidden).background(ScribeTheme.background).navigationTitle("Audit log")
        .task { await load(offset: 0) }
    }
    private func load(offset: Int) async {
        do {
            let result: PhoneWorkspace.Audit = try await PhoneWorkspace.shared.request("admin/audit?offset=\(offset)")
            if offset == 0 { events = result.events } else { events.append(contentsOf: result.events) }
        } catch { message = error.localizedDescription }
    }
}
