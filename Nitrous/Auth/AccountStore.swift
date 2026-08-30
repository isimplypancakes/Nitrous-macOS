import Foundation

/// One saved account. The token is the credential; profile fields cache what to show
/// in the switcher so we can render it before the network comes up.
struct Account: Codable, Identifiable, Hashable {
    var id: Snowflake            // Discord user id
    var token: String
    var username: String
    var globalName: String?
    var discriminator: String?
    var avatar: String?
    var addedAt: Date

    var displayName: String { globalName ?? username }
    var tag: String {
        if let d = discriminator, d != "0", !d.isEmpty { return "\(username)#\(d)" }
        return username
    }
    var avatarURL: URL? { CDN.avatar(userID: id, hash: avatar, discriminator: discriminator) }
}

/// Persists the set of logged-in accounts and which one is active.
/// The list is encrypted at rest in the keychain; the active id lives in defaults.
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var activeID: Snowflake?

    private let keychainAccount = "accounts-v1"
    private let activeKey = "nitrous.activeAccountID"

    init() { load() }

    var activeAccount: Account? { accounts.first { $0.id == activeID } }

    // MARK: Mutations

    /// Insert or replace an account, refreshing its cached profile and making it active.
    func upsert(_ account: Account, makeActive: Bool = true) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            var existing = account
            existing.addedAt = accounts[idx].addedAt
            accounts[idx] = existing
        } else {
            accounts.append(account)
        }
        if makeActive { activeID = account.id }
        persist()
    }

    /// Update cached profile fields (called after /users/@me resolves).
    func refreshProfile(id: Snowflake, from user: DiscordUser) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].username = user.username
        accounts[idx].globalName = user.globalName
        accounts[idx].discriminator = user.discriminator
        accounts[idx].avatar = user.avatar
        persist()
    }

    func remove(id: Snowflake) {
        accounts.removeAll { $0.id == id }
        if activeID == id { activeID = accounts.first?.id }
        persist()
    }

    func setActive(_ id: Snowflake) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeID = id
        UserDefaults.standard.set(id, forKey: activeKey)
    }

    // MARK: Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            Keychain.set(data, account: keychainAccount)
        }
        UserDefaults.standard.set(activeID, forKey: activeKey)
    }

    private func load() {
        if let data = Keychain.get(account: keychainAccount),
           let saved = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = saved
        }
        let stored = UserDefaults.standard.string(forKey: activeKey)
        activeID = accounts.contains { $0.id == stored } ? stored : accounts.first?.id
    }
}
