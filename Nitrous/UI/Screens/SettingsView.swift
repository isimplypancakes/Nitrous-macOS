import SwiftUI

/// The Commad+ appointment: a native Settings window, System Settings-style,
/// holding everything that used to live on the iOS "You" tab plus the other
/// preference screens as sibling tabs rather than pushed panes.
struct SettingsView: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var notifications: NotificationCenterManager

    var body: some View {
        TabView {
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            AppearanceView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 560, height: 460)
    }
}

/// The Accounts pane — an Apple-ID-style profile header, the account list with
/// one-tap switching, your live status, and connection/version facts.
struct AccountsSettingsView: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var model: AppModel
    @State private var showAddAccount = false
    @State private var status: String
    @State private var confirmRemove: Account?

    init() {
        // A menu Picker is idiomatic on macOS; seed it from the live status.
        _status = State(initialValue: "online")
    }

    var body: some View {
        List {
            profileHeader

            Section("Accounts") {
                ForEach(model.accountStore.accounts) { account in
                    accountRow(account)
                }
                Button { showAddAccount = true } label: {
                    Label("Add Account…", systemImage: "plus.circle.fill")
                }
            }

            Section("Status") {
                Picker("Set Status", selection: $status) {
                    Label("Online", systemImage: "circle.fill").tag("online")
                    Label("Idle", systemImage: "moon.fill").tag("idle")
                    Label("Do Not Disturb", systemImage: "minus.circle.fill").tag("dnd")
                    Label("Invisible", systemImage: "circle").tag("invisible")
                }
                .pickerStyle(.menu)
            }

            Section {
                LabeledContent("Connection", value: connectionLabel)
                LabeledContent("Version", value: versionString)
            } footer: {
                Text("Open the Diagnostics tab if something won't connect — it records what happened and can be shared.")
            }

            Section {
                if let active = model.accountStore.activeAccount {
                    Button(role: .destructive) { confirmRemove = active } label: {
                        Text("Log Out").frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .sheet(isPresented: $showAddAccount) { AddAccountSheet() }
        .alert(item: $confirmRemove) { account in
            Alert(title: Text("Log out of \(account.displayName)?"),
                  message: Text("The saved token is removed from this device."),
                  primaryButton: .destructive(Text("Log Out")) { model.logout(id: account.id) },
                  secondaryButton: .cancel())
        }
    }

    private var profileHeader: some View {
        Section {
            HStack(spacing: 16) {
                PresenceAvatar(url: model.user?.avatarURL,
                               name: model.user?.displayName ?? "You",
                               status: model.presences[model.user?.id ?? ""] ?? "online",
                               size: 56,
                               seed: model.user?.id ?? "",
                               ringColor: Palette.secondaryGroupedBg)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.user?.displayName ?? model.accountStore.activeAccount?.displayName ?? "You")
                        .font(.title3.bold())
                    Text(model.user?.tag ?? model.accountStore.activeAccount?.tag ?? "")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
    }

    private func accountRow(_ account: Account) -> some View {
        let active = account.id == model.accountStore.activeID
        return Button {
            if !active { model.switchAccount(to: account.id) }
        } label: {
            HStack(spacing: 12) {
                PresenceAvatar(url: account.avatarURL, name: account.displayName,
                               status: active ? "online" : "offline", size: 36, seed: account.id,
                               ringColor: Palette.secondaryGroupedBg)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayName).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(account.tag).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold)).foregroundStyle(Palette.accent)
                }
            }
        }
        .buttonStyle(.bouncyRow)
        .contextMenu {
            Button(role: .destructive) { confirmRemove = account } label: {
                Label("Log Out", systemImage: "trash")
            }
        }
    }

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var connectionLabel: String {
        switch model.gatewayState {
        case .ready: return "Connected"
        case .connecting, .connected: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Offline"
        }
    }
}

/// Privacy pane. The message log is a VenCord-style recorder of deleted and
/// edited messages — it stays OFF until the user opts in, and everything it
/// records lives only in this app's Application Support folder.
struct PrivacySettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("nitrous.messageLoggerEnabled") private var loggingEnabled = false
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: $loggingEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Message Log")
                        Text("Record deleted and edited messages")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } footer: {
                Text("When enabled, deleted messages leave a \"deleted a message\" note in the transcript, and everything is kept in a private, per-account log you can browse from any channel's toolbar. It never leaves this device.")
            }

            if loggingEnabled {
                Section {
                    LabeledContent("Recorded entries", value: "\(model.messageLog.count)")
                    Button(role: .destructive) { confirmClear = true } label: {
                        Text("Clear Log").frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(.red)
                } header: {
                    Text("Log")
                } footer: {
                    Text("Cleared for all accounts and channels. This cannot be undone.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .alert("Clear the message log?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { model.clearMessageLog() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All recorded deletes and edits are removed from this device. This cannot be undone.")
        }
    }
}