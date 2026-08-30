import Foundation
import Combine
import SwiftUI

/// Central coordinator. Owns the account store and, for the active account,
/// the REST + Gateway connection plus all cached runtime state that the UI reads.
@MainActor
final class AppModel: ObservableObject {
    let accountStore = AccountStore()

    // Session identity
    @Published var user: DiscordUser?
    @Published var gatewayState: GatewayState = .disconnected
    @Published var isSwitching = false
    @Published var bootError: String?

    // Guild / channel graph
    @Published var guilds: [Guild] = []
    @Published var channelsByGuild: [Snowflake: [Channel]] = [:]
    @Published var dmChannels: [Channel] = []

    // Selection: nil guild == Direct Messages home.
    @Published var selectedGuildID: Snowflake?
    @Published var selectedChannelID: Snowflake?
    /// Bumped on every channel tap so the shell closes its drawer even when the
    /// same channel is selected again (SwiftUI's onChange ignores equal values).
    @Published var channelOpenToken = 0
    /// Message the composer is replying to, per channel.
    @Published var replyingTo: [Snowflake: Message] = [:]
    /// Message currently being edited, per channel.
    @Published var editing: [Snowflake: Message] = [:]
    /// Set to scroll the transcript to a message (reply jump).
    @Published var scrollTarget: Snowflake?
    /// Images staged in the composer, per channel, before sending.
    @Published var pendingAttachments: [Snowflake: [PendingAttachment]] = [:]
    /// Channel to open once the next session finishes connecting.
    var pendingChannelRoute: Snowflake?

    // Message + realtime caches
    @Published var messagesByChannel: [Snowflake: [Message]] = [:]
    @Published var loadingChannels: Set<Snowflake> = []
    @Published var typingByChannel: [Snowflake: [Snowflake: Date]] = [:]
    @Published var presences: [Snowflake: String] = [:]
    @Published var usersCache: [Snowflake: DiscordUser] = [:]
    /// Discord's saved sidebar order, used to sort `guilds`.
    private var savedGuildOrder: [Snowflake] = []
    /// Last-read message per channel, used to show unread indicators.
    @Published var lastRead: [Snowflake: Snowflake] = [:]

    /// Gateways for the accounts that aren't currently active.
    let background = BackgroundSessions()

    private var rest: DiscordREST?
    private var gateway: DiscordGateway?
    private var cancellables = Set<AnyCancellable>()
    private var typingPruner: Timer?

    var restClient: DiscordREST? { rest }

    init() {
        // Re-publish account changes so a single @StateObject drives the whole tree.
        accountStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        startTypingPruner()
    }

    var isLoggedIn: Bool { accountStore.activeAccount != nil }

    // MARK: Boot / connection

    func boot() {
        guard let account = accountStore.activeAccount else { return }
        // Ask once, the first time there's actually an account to notify about.
        if !UserDefaults.standard.bool(forKey: "nitrous.askedNotifications") {
            UserDefaults.standard.set(true, forKey: "nitrous.askedNotifications")
            NotificationCenterManager.shared.requestAuthorization()
        }
        #if DEBUG
        if account.token == "demo" { loadDemo(); return }
        #endif
        connect(with: account)
    }

    private func connect(with account: Account) {
        Diag.app("connecting session for \(account.tag) (\(account.id))")
        teardown()
        bootError = nil
        let rest = DiscordREST(token: account.token)
        self.rest = rest
        let gw = DiscordGateway(token: account.token)
        gw.onEvent = { [weak self] event in self?.handle(event) }
        gateway = gw
        gatewayState = .connecting
        gw.connect()
    }

    private func teardown() {
        gateway?.disconnect()
        gateway = nil
        rest = nil
        user = nil
        guilds = []
        channelsByGuild = [:]
        dmChannels = []
        messagesByChannel = [:]
        typingByChannel = [:]
        presences = [:]
        selectedGuildID = nil
        selectedChannelID = nil
    }

    /// Re-establish the session for the active account (used by the error retry).
    func retry() {
        guard let account = accountStore.activeAccount else { return }
        connect(with: account)
    }

    // MARK: Account management

    func switchAccount(to id: Snowflake) {
        guard id != accountStore.activeID, let account = accountStore.accounts.first(where: { $0.id == id }) else { return }
        isSwitching = true
        accountStore.setActive(id)
        connect(with: account)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.isSwitching = false }
    }

    /// Validate a raw token against /users/@me, then persist + activate the account.
    func addAccount(token: String) async throws {
        Diag.auth("validating token (\(token.count) chars)")
        let probe = DiscordREST(token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        let me = try await probe.me()
        Diag.auth("token valid for \(me.tag)", .success)
        let account = Account(id: me.id, token: probe.token ?? token, username: me.username,
                              globalName: me.globalName, discriminator: me.discriminator,
                              avatar: me.avatar, addedAt: Date())
        accountStore.upsert(account, makeActive: true)
        connect(with: account)
    }

    func login(email: String, password: String) async throws -> LoginResult {
        try await DiscordREST().login(email: email, password: password)
    }

    func completeMFA(code: String, ticket: String) async throws {
        let token = try await DiscordREST().mfaTotp(code: code, ticket: ticket)
        try await addAccount(token: token)
    }

    func logout(id: Snowflake) {
        defer { syncBackgroundSessions() }
        let wasActive = id == accountStore.activeID
        accountStore.remove(id: id)
        if wasActive {
            if let next = accountStore.activeAccount { connect(with: next) }
            else { teardown() }
        }
    }

    // MARK: Event handling

    private func handle(_ event: GatewayEvent) {
        switch event {
        case .connectionStateChanged(let state):
            gatewayState = state
        case .ready(let ready):
            applyReady(ready)
        case .resumed:
            gatewayState = .ready
        case .messageCreate(let m):
            insertMessage(m, dedupe: true)
        case .messageUpdate(let m):
            updateMessage(m)
        case .messageDelete(let p):
            messagesByChannel[p.channelId]?.removeAll { $0.id == p.id }
        case .typingStart(let t):
            typingByChannel[t.channelId, default: [:]][t.userId] = Date()
        case .presenceUpdate(let p):
            if let id = p.user?.id, let status = p.status { presences[id] = status }
        case .guildCreate(let g):
            mergeGuild(g)
        case .channelCreate(let c), .channelUpdate(let c):
            mergeChannel(c)
        case .reactionAdd(let p):
            applyReaction(p, added: true)
        case .reactionRemove(let p):
            applyReaction(p, added: false)
        case .failed(let message):
            Diag.app("session failed: \(message)", .error)
            bootError = message
        }
    }

    private func applyReady(_ ready: ReadyData) {
        bootError = nil
        user = ready.user
        accountStore.refreshProfile(id: ready.user.id, from: ready.user)
        usersCache[ready.user.id] = ready.user
        ready.users.forEach { usersCache[$0.id] = $0 }
        lastRead = ready.lastReadByChannel
        savedGuildOrder = ready.guildOrder
        guilds = Self.ordered(ready.guilds, by: savedGuildOrder)
        if !savedGuildOrder.isEmpty {
            Diag.app("applied saved guild order (\(savedGuildOrder.count) entries)")
        }
        for g in ready.guilds {
            if let ch = g.channels { channelsByGuild[g.id] = ch }
        }
        dmChannels = ready.privateChannels.sorted { ($0.lastMessageId ?? "") > ($1.lastMessageId ?? "") }
        dmChannels.forEach { $0.recipients?.forEach { usersCache[$0.id] = $0 } }
        gatewayState = .ready
        if let target = pendingChannelRoute {
            pendingChannelRoute = nil
            selectChannel(target)
        }
        syncBackgroundSessions()
    }

    private func mergeGuild(_ g: Guild) {
        if let idx = guilds.firstIndex(where: { $0.id == g.id }) { guilds[idx] = g }
        else {
            guilds.append(g)
            guilds = Self.ordered(guilds, by: savedGuildOrder)
        }
        if let ch = g.channels { channelsByGuild[g.id] = ch }
    }

    /// Sorts to Discord's saved order. Servers missing from that list (joined
    /// since the order was last saved) keep their READY order at the end.
    static func ordered(_ guilds: [Guild], by order: [Snowflake]) -> [Guild] {
        guard !order.isEmpty else { return guilds }
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return guilds.enumerated().sorted { a, b in
            let ra = rank[a.element.id], rb = rank[b.element.id]
            switch (ra, rb) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    // MARK: DM naming
    //
    // The gateway sends DM participants as bare IDs, so names and avatars have
    // to come from the user cache rather than the channel itself.

    func otherUser(in channel: Channel) -> DiscordUser? {
        if let id = channel.participantIDs(excluding: user?.id).first, let u = usersCache[id] { return u }
        return channel.recipients?.first { $0.id != user?.id }
    }

    func displayName(for channel: Channel) -> String {
        if let name = channel.name, !name.isEmpty { return name }
        switch channel.type {
        case .dm:
            return otherUser(in: channel)?.displayName ?? "Direct Message"
        case .groupDM:
            let names = channel.participantIDs(excluding: user?.id).compactMap { usersCache[$0]?.displayName }
            return names.isEmpty ? "Group" : names.joined(separator: ", ")
        default:
            return channel.displayName(currentUserID: user?.id)
        }
    }

    func avatarURL(for channel: Channel) -> URL? {
        switch channel.type {
        case .dm: return otherUser(in: channel)?.avatarURL
        case .groupDM: return channel.iconURL
        default: return nil
        }
    }

    private func mergeChannel(_ c: Channel) {
        guard let gid = c.guildId else { return }
        var list = channelsByGuild[gid] ?? []
        if let idx = list.firstIndex(where: { $0.id == c.id }) { list[idx] = c } else { list.append(c) }
        channelsByGuild[gid] = list
    }

    private func insertMessage(_ m: Message, dedupe: Bool) {
        guard let cid = m.channelId else { return }
        // Messages in the open channel are read as they arrive.
        if cid == selectedChannelID { lastRead[cid] = m.id }
        notifyIfNeeded(m, channelID: cid)
        if let author = m.author { usersCache[author.id] = author }
        var list = messagesByChannel[cid] ?? []
        if dedupe, let idx = list.firstIndex(where: { $0.id == m.id }) { list[idx] = m }
        else if dedupe, let nonce = m.nonce, let idx = list.firstIndex(where: { $0.nonce == nonce }) { list[idx] = m }
        else { list.append(m) }
        messagesByChannel[cid] = list
        // Clear the typing indicator for the author once their message lands.
        typingByChannel[cid]?[m.author?.id ?? ""] = nil
    }

    private func updateMessage(_ m: Message) {
        guard let cid = m.channelId, var list = messagesByChannel[cid],
              let idx = list.firstIndex(where: { $0.id == m.id }) else { return }
        var merged = list[idx]
        merged.content = m.content
        merged.editedTimestamp = m.editedTimestamp
        merged.embeds = m.embeds ?? merged.embeds
        merged.attachments = m.attachments ?? merged.attachments
        list[idx] = merged
        messagesByChannel[cid] = list
    }

    private func applyReaction(_ p: MessageReactionPayload, added: Bool) {
        guard var list = messagesByChannel[p.channelId],
              let idx = list.firstIndex(where: { $0.id == p.messageId }) else { return }
        var msg = list[idx]
        var reactions = msg.reactions ?? []
        let isMe = p.userId == user?.id
        if let rIdx = reactions.firstIndex(where: { $0.emoji.name == p.emoji.name && $0.emoji.id == p.emoji.id }) {
            reactions[rIdx].count += added ? 1 : -1
            if isMe { reactions[rIdx].me = added }
            if reactions[rIdx].count <= 0 { reactions.remove(at: rIdx) }
        } else if added {
            reactions.append(Reaction(count: 1, me: isMe, emoji: p.emoji))
        }
        msg.reactions = reactions
        list[idx] = msg
        messagesByChannel[p.channelId] = list
    }

    // MARK: Selection & message loading

    func selectGuild(_ id: Snowflake?) {
        selectedGuildID = id
        if let id, let channels = channelsByGuild[id] {
            // Auto-select the first text channel like Discord does.
            let firstText = channels
                .filter { $0.isTextLike }
                .sorted { $0.sortPosition < $1.sortPosition }
                .first
            if let firstText { selectChannel(firstText.id) }
        }
    }

    /// A channel is unread when its newest message is past the last-read marker.
    func isUnread(_ channel: Channel) -> Bool {
        guard let latest = channel.lastMessageId else { return false }
        guard let read = lastRead[channel.id] else { return true }
        // Snowflakes sort chronologically by numeric value.
        guard let l = UInt64(latest), let r = UInt64(read) else { return false }
        return l > r
    }

    func unreadCount(inGuild id: Snowflake) -> Int {
        (channelsByGuild[id] ?? []).filter { $0.isTextLike && isUnread($0) }.count
    }

    func selectChannel(_ id: Snowflake) {
        selectedChannelID = id
        // Opening a channel clears its unread marker locally.
        if let ch = (dmChannels + channelsByGuild.values.flatMap { $0 }).first(where: { $0.id == id }),
           let latest = ch.lastMessageId {
            lastRead[id] = latest
        }
        channelOpenToken &+= 1
        if messagesByChannel[id] == nil { Task { await loadMessages(channelID: id) } }
    }

    func loadMessages(channelID: Snowflake, before: Snowflake? = nil) async {
        guard let rest else { return }
        loadingChannels.insert(channelID)
        defer { loadingChannels.remove(channelID) }
        do {
            let fetched = try await rest.messages(channelID: channelID, limit: 50, before: before)
            let chronological = fetched.reversed().map { $0 }
            chronological.forEach { if let a = $0.author { usersCache[a.id] = a } }
            if before == nil {
                messagesByChannel[channelID] = chronological
            } else {
                var existing = messagesByChannel[channelID] ?? []
                existing.insert(contentsOf: chronological, at: 0)
                messagesByChannel[channelID] = existing
            }
        } catch {
            // Leave whatever we had; surface transient errors silently for now.
        }
    }

    func sendMessage(channelID: Snowflake, content: String, replyTo: Snowflake? = nil) {
        guard let rest else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let reference = replyTo ?? replyingTo[channelID]?.id
        replyingTo[channelID] = nil
        let nonce = String(UInt64(Date().timeIntervalSince1970 * 1000))
        // Optimistic echo so the composer feels instant.
        if let me = user {
            let optimistic = Message(id: "pending-\(nonce)", channelId: channelID, author: me,
                                     content: trimmed, timestamp: DiscordTime.plainFormatter.string(from: Date()),
                                     nonce: nonce)
            insertMessage(optimistic, dedupe: false)
        }
        Task {
            do {
                _ = try await rest.sendMessage(channelID: channelID, content: trimmed,
                                               nonce: nonce, replyTo: reference)
            } catch {
                Diag.rest("send failed: \(error.localizedDescription)", .error)
                messagesByChannel[channelID]?.removeAll { $0.id == "pending-\(nonce)" }
            }
        }
    }

    // MARK: Notifications

    /// Raises a local notification for the active account when a DM or mention
    /// arrives in a channel the user isn't currently looking at.
    private func notifyIfNeeded(_ message: Message, channelID: Snowflake) {
        guard channelID != selectedChannelID else { return }
        guard let account = accountStore.activeAccount else { return }
        let isDM = dmChannels.contains { $0.id == channelID }
        guard NotificationCenterManager.shouldNotify(message, currentUserID: user?.id, isDM: isDM)
        else { return }
        let name: String
        if isDM, let dm = dmChannels.first(where: { $0.id == channelID }) {
            name = displayName(for: dm)
        } else if let ch = channelsByGuild.values.flatMap({ $0 }).first(where: { $0.id == channelID }) {
            name = "#\(ch.name ?? "channel")"
        } else {
            name = "Message"
        }
        NotificationCenterManager.shared.notify(
            message: message, channelName: name, accountID: account.id,
            accountName: account.displayName,
            showAccount: accountStore.accounts.count > 1)
    }

    /// Keeps background gateways in step with the saved accounts.
    func syncBackgroundSessions() {
        background.sync(accounts: accountStore.accounts,
                        activeID: accountStore.activeID,
                        multiAccount: accountStore.accounts.count > 1)
    }

    /// Handles a notification tap: switch accounts if needed, then open the channel.
    func route(to route: NotificationCenterManager.Route) {
        if route.accountID != accountStore.activeID {
            switchAccount(to: route.accountID)
            // The channel only exists once that session's READY lands.
            pendingChannelRoute = route.channelID
        } else {
            selectChannel(route.channelID)
        }
    }

    // MARK: Attachments

    struct PendingAttachment: Identifiable, Equatable {
        let id = UUID()
        var filename: String
        var data: Data
        var mime: String
    }

    func stage(_ attachment: PendingAttachment, in channelID: Snowflake) {
        pendingAttachments[channelID, default: []].append(attachment)
    }
    func unstage(_ id: UUID, in channelID: Snowflake) {
        pendingAttachments[channelID]?.removeAll { $0.id == id }
        if pendingAttachments[channelID]?.isEmpty == true { pendingAttachments[channelID] = nil }
    }

    /// Sends staged files (with optional caption) and clears the tray.
    func sendAttachments(channelID: Snowflake, caption: String) {
        guard let rest, let staged = pendingAttachments[channelID], !staged.isEmpty else { return }
        let reference = replyingTo[channelID]?.id
        replyingTo[channelID] = nil
        pendingAttachments[channelID] = nil
        let files = staged.map { (filename: $0.filename, data: $0.data, mime: $0.mime) }
        Task {
            do {
                _ = try await rest.sendMessage(channelID: channelID,
                                               content: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                                               attachments: files, replyTo: reference)
            } catch {
                Diag.rest("attachment upload failed: \(error.localizedDescription)", .error)
                bootError = "Couldn't upload: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Reply / edit / delete

    func beginReply(to message: Message, in channelID: Snowflake) {
        editing[channelID] = nil
        replyingTo[channelID] = message
    }
    func cancelReply(in channelID: Snowflake) { replyingTo[channelID] = nil }

    func beginEdit(_ message: Message, in channelID: Snowflake) {
        replyingTo[channelID] = nil
        editing[channelID] = message
    }
    func cancelEdit(in channelID: Snowflake) { editing[channelID] = nil }

    func commitEdit(channelID: Snowflake, content: String) {
        guard let rest, let target = editing[channelID] else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        editing[channelID] = nil
        guard !trimmed.isEmpty else { return }
        // Optimistic: show the new text immediately.
        if var list = messagesByChannel[channelID],
           let idx = list.firstIndex(where: { $0.id == target.id }) {
            list[idx].content = trimmed
            messagesByChannel[channelID] = list
        }
        Task {
            do { _ = try await rest.editMessage(channelID: channelID, messageID: target.id, content: trimmed) }
            catch { Diag.rest("edit failed: \(error.localizedDescription)", .error) }
        }
    }

    func deleteMessage(_ message: Message, in channelID: Snowflake) {
        guard let rest else { return }
        let snapshot = messagesByChannel[channelID]
        messagesByChannel[channelID]?.removeAll { $0.id == message.id }
        Task {
            do { try await rest.deleteMessage(channelID: channelID, messageID: message.id) }
            catch {
                Diag.rest("delete failed: \(error.localizedDescription)", .error)
                messagesByChannel[channelID] = snapshot   // put it back
            }
        }
    }

    /// True when the message was written by the signed-in account.
    func isMine(_ message: Message) -> Bool { message.author?.id == user?.id }

    /// Scrolls the transcript to a message, loading nothing — used by reply jumps.
    func jump(to id: Snowflake) { scrollTarget = id }

    func toggleReaction(message: Message, emoji: Emoji, on channelID: Snowflake) {
        guard let rest else { return }
        let mine = message.reactions?.first { $0.emoji.name == emoji.name }?.me ?? false
        Task {
            do {
                if mine { try await rest.removeReaction(channelID: channelID, messageID: message.id, emoji: emoji) }
                else { try await rest.addReaction(channelID: channelID, messageID: message.id, emoji: emoji) }
            } catch {}
        }
    }

    func sendTyping(channelID: Snowflake) {
        Task { try? await rest?.triggerTyping(channelID: channelID) }
    }

    // MARK: Derived helpers

    func typingUsers(in channelID: Snowflake) -> [DiscordUser] {
        let cutoff = Date().addingTimeInterval(-9)
        return (typingByChannel[channelID] ?? [:])
            .filter { $0.value > cutoff && $0.key != user?.id }
            .keys
            .compactMap { usersCache[$0] }
    }

    private func startTypingPruner() {
        typingPruner = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let cutoff = Date().addingTimeInterval(-9)
                var changed = false
                for (cid, users) in self.typingByChannel {
                    let pruned = users.filter { $0.value > cutoff }
                    if pruned.count != users.count { self.typingByChannel[cid] = pruned; changed = true }
                }
                if changed { self.objectWillChange.send() }
            }
        }
    }
}
