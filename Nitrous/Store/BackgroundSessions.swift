import Foundation

/// Keeps a lightweight gateway connection open for every saved account that
/// isn't the active one, so their DMs and mentions still raise notifications.
///
/// These sessions deliberately hold almost no state: just enough to know who
/// the user is, which channels are DMs, and what each channel is called.
@MainActor
final class BackgroundSessions: ObservableObject {

    private struct Session {
        let gateway: DiscordGateway
        var userID: Snowflake?
        var accountName: String
        var dmChannelIDs: Set<Snowflake> = []
        var channelNames: [Snowflake: String] = [:]
    }

    private var sessions: [Snowflake: Session] = [:]
    /// Accounts we should keep watching (everything except the active one).
    private var watching: Set<Snowflake> = []

    /// Reconciles background connections against the saved accounts.
    func sync(accounts: [Account], activeID: Snowflake?, multiAccount: Bool) {
        let wanted = Set(accounts.filter { $0.id != activeID }.map(\.id))

        // Drop sessions for accounts that were removed or became active.
        for id in sessions.keys where !wanted.contains(id) {
            sessions[id]?.gateway.disconnect()
            sessions.removeValue(forKey: id)
            Diag.app("background session stopped for \(id)")
        }
        watching = wanted

        // Start sessions for newly-inactive accounts.
        for account in accounts where wanted.contains(account.id) && sessions[account.id] == nil {
            start(account, showAccountName: multiAccount)
        }
    }

    func stopAll() {
        sessions.values.forEach { $0.gateway.disconnect() }
        sessions.removeAll()
        watching.removeAll()
    }

    private func start(_ account: Account, showAccountName: Bool) {
        let gateway = DiscordGateway(token: account.token)
        var session = Session(gateway: gateway, accountName: account.displayName)
        gateway.onEvent = { [weak self] event in
            self?.handle(event, for: account.id, showAccountName: showAccountName)
        }
        sessions[account.id] = session
        session.userID = nil
        Diag.app("background session starting for \(account.tag)")
        gateway.connect()
    }

    private func handle(_ event: GatewayEvent, for accountID: Snowflake, showAccountName: Bool) {
        guard var session = sessions[accountID] else { return }
        switch event {
        case .ready(let ready):
            session.userID = ready.user.id
            session.dmChannelIDs = Set(ready.privateChannels.map(\.id))
            for channel in ready.privateChannels {
                let others = channel.participantIDs(excluding: ready.user.id)
                    .compactMap { id in ready.users.first { $0.id == id }?.displayName }
                session.channelNames[channel.id] = channel.name?.nilIfEmpty
                    ?? others.first ?? "Direct Message"
            }
            for guild in ready.guilds {
                for channel in guild.channels ?? [] where channel.isTextLike {
                    session.channelNames[channel.id] = "#\(channel.name ?? "channel")"
                }
            }
            sessions[accountID] = session
            Diag.app("background session ready for \(session.accountName)")

        case .messageCreate(let message):
            guard let channelID = message.channelId else { return }
            let isDM = session.dmChannelIDs.contains(channelID)
            guard NotificationCenterManager.shouldNotify(message, currentUserID: session.userID, isDM: isDM)
            else { return }
            NotificationCenterManager.shared.notify(
                message: message,
                channelName: session.channelNames[channelID] ?? "Message",
                accountID: accountID,
                accountName: session.accountName,
                showAccount: showAccountName)

        case .channelCreate(let channel):
            if channel.type == .dm || channel.type == .groupDM {
                session.dmChannelIDs.insert(channel.id)
                sessions[accountID] = session
            }

        case .failed(let reason):
            Diag.app("background session for \(session.accountName) failed: \(reason)", .warn)

        default:
            break
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
