import SwiftUI

/// Notification preferences. Explains the multi-account behaviour, because
/// "notifications for accounts you aren't using" is unusual enough to warrant it.
struct NotificationSettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var notifications: NotificationCenterManager
    @EnvironmentObject var theme: ThemeStore

    var body: some View {
        List {
            Section {
                HStack {
                    Label("Notifications", systemImage: "bell.badge.fill")
                    Spacer()
                    Text(notifications.authorized ? "On" : "Off")
                        .foregroundStyle(notifications.authorized ? Color.green : Color.secondary)
                }
                .glassRow()

                if !notifications.authorized {
                    Button {
                        notifications.requestAuthorization()
                    } label: {
                        Label("Allow Notifications", systemImage: "checkmark.circle.fill")
                    }
                    .glassRow()

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open iOS Settings", systemImage: "gear")
                    }
                    .glassRow()
                }
            } footer: {
                Text("You'll be notified for direct messages and mentions.")
            }

            Section {
                ForEach(model.accountStore.accounts) { account in
                    HStack(spacing: 12) {
                        AvatarView(url: account.avatarURL, name: account.displayName,
                                   size: 32, seed: account.id)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.displayName).font(.body.weight(.medium))
                            Text(account.id == model.accountStore.activeID ? "Active" : "Watching in background")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "bell.fill")
                            .font(.footnote)
                            .foregroundStyle(notifications.authorized ? Palette.accent : Color.secondary)
                    }
                    .glassRow()
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Every signed-in account stays connected, so you get notifications even for accounts you aren't currently using. Tapping one switches to that account and opens the conversation.")
            }
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { notifications.refreshAuthorization() }
    }
}
