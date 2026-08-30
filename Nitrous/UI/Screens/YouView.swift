import SwiftUI

/// The You tab — an Apple-ID-card-style profile header, a native account list
/// with one-tap switching, and grouped settings. This is where account
/// switching lives, the way Settings.app surfaces the Apple ID.
struct YouView: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var model: AppModel
    @State private var showAddAccount = false
    @State private var status = "online"
    @State private var confirmRemove: Account?

    var body: some View {
        NavigationStack {
            List {
                profileHeader

                Section("Accounts") {
                    ForEach(model.accountStore.accounts) { account in
                        accountRow(account)
                    }
                    Button { showAddAccount = true } label: {
                        Label("Add Account", systemImage: "plus.circle.fill")
                    }
                    .glassRow()
                }

                Section("Status") {
                    Picker("Set Status", selection: $status) {
                        Label("Online", systemImage: "circle.fill").tag("online")
                        Label("Idle", systemImage: "moon.fill").tag("idle")
                        Label("Do Not Disturb", systemImage: "minus.circle.fill").tag("dnd")
                        Label("Invisible", systemImage: "circle").tag("invisible")
                    }
                    .pickerStyle(.navigationLink)
                    .glassRow()
                }

                Section("Settings") {
                    NavigationLink { AppearanceView() } label: {
                        HStack {
                            Label("Appearance", systemImage: "paintbrush.fill")
                            Spacer()
                            Text(ThemeStore.shared.current.name)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.glassRow()
                    NavigationLink { NotificationSettingsView() } label: {
                        Label("Notifications", systemImage: "bell.badge.fill")
                    }.glassRow()
                    NavigationLink { SettingsDetail(title: "Privacy & Safety", icon: "lock.shield.fill") } label: {
                        Label("Privacy & Safety", systemImage: "lock.shield.fill")
                    }.glassRow()
                    NavigationLink { SettingsDetail(title: "Voice & Video", icon: "mic.fill") } label: {
                        Label("Voice & Video", systemImage: "mic.fill")
                    }.glassRow()
                }

                Section {
                    LabeledContent("Connection", value: connectionLabel).glassRow()
                    LabeledContent("Version", value: versionString).glassRow()
                    NavigationLink { DiagnosticsView() } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }.glassRow()
                } footer: {
                    Text("Open Diagnostics if something won't connect — it records what happened and can be shared.")
                }

                Section {
                    if let active = model.accountStore.activeAccount {
                        Button(role: .destructive) { confirmRemove = active } label: {
                            Text("Log Out").frame(maxWidth: .infinity)
                        }
                        .glassRow()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .themedBackground()
            .navigationTitle("You")
        }
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
                               status: status, size: 64,
                               seed: model.user?.id ?? "",
                               ringColor: Palette.secondaryGroupedBg)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.user?.displayName ?? model.accountStore.activeAccount?.displayName ?? "You")
                        .font(.title2.bold())
                    Text(model.user?.tag ?? model.accountStore.activeAccount?.tag ?? "")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .glassRow()
    }

    private func accountRow(_ account: Account) -> some View {
        let active = account.id == model.accountStore.activeID
        return Button {
            if !active { model.switchAccount(to: account.id) }
        } label: {
            HStack(spacing: 12) {
                PresenceAvatar(url: account.avatarURL, name: account.displayName,
                               status: active ? status : "offline", size: 40, seed: account.id,
                               ringColor: Palette.secondaryGroupedBg)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayName).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(account.tag).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if active {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Palette.accent)
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) { confirmRemove = account } label: { Label("Log Out", systemImage: "trash") }
        }
        .glassRow()
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

/// Placeholder detail pane so settings rows push like a real settings app.
struct SettingsDetail: View {
    let title: String
    let icon: String
    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: icon).foregroundStyle(Palette.accent)
                    Text(title)
                    Spacer()
                    Text("Coming soon").foregroundStyle(.secondary)
                }
            } footer: {
                Text("This section is scaffolded and ready for its controls.")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
