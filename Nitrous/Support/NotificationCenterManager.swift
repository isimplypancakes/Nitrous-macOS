import Foundation
import UserNotifications
import UIKit

/// Local notifications for DMs and mentions, across **every** saved account.
///
/// Discord's push service is tied to its own first-party apps, so notifications
/// here come from gateway events this app is already receiving. The active
/// account uses the main session; every other saved account gets a lightweight
/// background gateway (see `BackgroundSessions`) purely to spot mentions.
@MainActor
final class NotificationCenterManager: NSObject, ObservableObject {
    static let shared = NotificationCenterManager()

    @Published private(set) var authorized = false
    /// Set when the user taps a notification, so the app can route to it.
    @Published var pendingRoute: Route?

    struct Route: Equatable {
        var accountID: Snowflake
        var channelID: Snowflake
    }

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Task { @MainActor in
                self.authorized = granted
                Diag.app("notification permission \(granted ? "granted" : "denied")\(error.map { ": \($0.localizedDescription)" } ?? "")")
            }
        }
    }

    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                self.authorized = settings.authorizationStatus == .authorized
            }
        }
    }

    /// Posts a notification for a message, labelled with the receiving account
    /// when more than one is signed in.
    func notify(message: Message, channelName: String, accountID: Snowflake,
                accountName: String, showAccount: Bool) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = message.author?.displayName ?? "New message"
        content.subtitle = showAccount ? "\(channelName) · \(accountName)" : channelName
        content.body = message.content.isEmpty ? "Sent an attachment" : message.content
        content.sound = .default
        content.threadIdentifier = message.channelId ?? channelName
        content.userInfo = [
            "accountID": accountID,
            "channelID": message.channelId ?? ""
        ]
        let request = UNNotificationRequest(identifier: message.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// True when a message should raise a notification: a DM, a direct mention,
    /// or an @everyone/@here — never the user's own messages.
    static func shouldNotify(_ message: Message, currentUserID: Snowflake?, isDM: Bool) -> Bool {
        guard let me = currentUserID, message.author?.id != me else { return false }
        if isDM { return true }
        if message.mentionEveryone == true { return true }
        return message.mentions?.contains { $0.id == me } ?? false
    }
}

extension NotificationCenterManager: UNUserNotificationCenterDelegate {
    /// Show banners even while the app is foregrounded — the message may be for
    /// a different account than the one on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let account = info["accountID"] as? String,
              let channel = info["channelID"] as? String, !channel.isEmpty else { return }
        await MainActor.run {
            NotificationCenterManager.shared.pendingRoute = .init(accountID: account, channelID: channel)
        }
    }
}
