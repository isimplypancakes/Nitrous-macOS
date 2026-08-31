import Foundation
import Combine
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Central coordinator. Owns the account store and, for the active account,
/// the REST + Gateway connection plus all cached runtime state that the UI reads.
/// Reused homegrown errors so helpers stay simple without a network client.
enum ModelError: LocalizedError {
    case offline
    var errorDescription: String? {
        switch self {
        case .offline: return "Not connected to Discord."
        }
    }
}

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
    /// Rich presence (games, Spotify, custom status) per user, if Discord sent any.
    @Published var activitiesByUser: [Snowflake: [Presence.Activity]] = [:]
    @Published var usersCache: [Snowflake: DiscordUser] = [:]
    /// Discord's saved sidebar order, used to sort `guilds`.
    private var savedGuildOrder: [Snowflake] = []
    /// Server folders from the official client; the rail renders one capsule per
    /// folder and leaves unfiled servers as individual icons.
    @Published private(set) var guildFolders: [GuildOrderProto.GuildFolder] = []
    /// Last-read message per channel, used to show unread indicators.
    @Published var lastRead: [Snowflake: Snowflake] = [:]
    /// Channels holding a message that **pings me** and that I haven't opened
    /// yet. The red badges render from this — not from plain unread activity.
    @Published var pingedChannels: Set<Snowflake> = []
    /// Guild-scoped member roster for the member panel, keyed by guild ID.
    @Published var membersByGuild: [Snowflake: [DiscordUser]] = [:]

    /// guild → user → server nickname. Fed by every roster source (READY,
    /// GUILD_CREATE, member requests, REST) so message headers can resolve a
    /// nick for a guild even if that guild's member list was never opened.
    @Published var nicknames: [Snowflake: [Snowflake: String]] = [:]
    /// Why a guild's roster failed to load, if it did — shown in the panel.
    @Published var membersLoadError: [Snowflake: String] = [:]
    /// Which guild the member panel should reflect (set by the server popover
    /// and the chat toolbar before it opens).
    @Published var memberPanelGuild: Snowflake?
    @Published var showMembersPanel = false
    /// VenCord-style logger of deleted/edited messages, newest first. Only
    /// fills in when the user opts in (Settings → Privacy); never sent anywhere.
    @Published private(set) var messageLog: [MessageLogEntry] = []

    /// Gateways for the accounts that aren't currently active.
    let background = BackgroundSessions()

    private var rest: DiscordREST?
    private var gateway: DiscordGateway?
    private var cancellables = Set<AnyCancellable>()
    private var typingPruner: Timer?
    #if os(macOS)
    /// Claims Discord's local RPC IPC socket so apps' Rich Presence `SET_ACTIVITY`
    /// frames land here instead of the official client.
    private var rpcIPC: RichPresenceIPC?
    #endif

    var restClient: DiscordREST? { rest }

    init() {
        // Re-publish account changes so a single @StateObject drives the whole tree.
        accountStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        startTypingPruner()
    }

    var isLoggedIn: Bool { accountStore.activeAccount != nil }

    /// Opt-in message logging (Settings → Privacy). Off by default: the app
    /// records nothing about edits or deletes until the user turns it on.
    static var messageLoggingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "nitrous.messageLoggerEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "nitrous.messageLoggerEnabled") }
    }

    /// Resolves a channel id to its live object, from DMs or any guild.
    /// Convenience for shell views that render the current selection.
    func channel(with id: Snowflake) -> Channel? {
        if let dm = dmChannels.first(where: { $0.id == id }) { return dm }
        for channels in channelsByGuild.values {
            if let ch = channels.first(where: { $0.id == id }) { return ch }
        }
        return nil
    }

    /// Discord's permission algorithm for the signed-in user in a channel:
    /// @everyone base OR'd with every role the user holds, then channel
    /// overwrites (roles highest-position first, then the member's own, which
    /// wins last). A channel with a parent category inherits the category's
    /// overwrites first — Discord resolves permissions top-down — which is what
    /// actually hides channels sat under a locked category. The guild owner
    /// bypasses every rule, like Discord. Guilds that fail to resolve resolve
    /// to 0 — never grant something we can't prove. DMs return everything.
    private func permissionBits(in channel: Channel) -> UInt64 {
        guard let guildID = channel.guildId else { return UInt64.max }
        guard let guild = guilds.first(where: { $0.id == guildID }),
              let me = user?.id else { return 0 }
        if guild.ownerId == me { return UInt64.max }
        let roles = guild.roles ?? []
        let guildChannels = channelsByGuild[guildID] ?? []

        var myRoleIDs = guild.members?.first { $0.user?.id == me }?.roles ?? []
        if !myRoleIDs.contains(guildID) { myRoleIDs.append(guildID) }

        var bits = roles.first { $0.id == guildID }?.permissions.flatMap(UInt64.init) ?? 0
        for role in roles where myRoleIDs.contains(role.id) {
            if let b = role.permissions.flatMap(UInt64.init) { bits |= b }
        }

        func apply(_ allow: UInt64, _ deny: UInt64) {
            bits &= ~deny
            bits |= allow
        }
        func applyOverwrite(_ ow: Channel.Overwrite) {
            if let allow = UInt64(ow.allow), let deny = UInt64(ow.deny) {
                apply(allow, deny)
            }
        }

        // A child channel inherits its parent category's rules before its own.
        let category = channel.parentId.flatMap { cid in
            guildChannels.first { $0.id == cid }
        }
        let catOW = category?.permissionOverwrites ?? []
        let chanOW = channel.permissionOverwrites ?? []

        // Discord's documented order: guild-level, then @everyone's overwrites
        // (so a locked channel starts denied), then each role the member holds
        // by position (a role's allow overrides the @everyone deny), then the
        // member's own overwrite winning last. Each step applies the category
        // overwrite before the channel's.
        if let every = catOW.first(where: { $0.id == guildID && $0.type == 0 }) { applyOverwrite(every) }
        if let every = chanOW.first(where: { $0.id == guildID && $0.type == 0 }) { applyOverwrite(every) }
        let orderedRoles = myRoleIDs
            .filter { $0 != guildID }
            .map { rid in
                (rid: rid, position: roles.first { $0.id == rid }?.position ?? -1)
            }
            .sorted { $0.position > $1.position }
        for entry in orderedRoles {
            if let ow = catOW.first(where: { $0.id == entry.rid && $0.type == 0 }) { applyOverwrite(ow) }
            if let ow = chanOW.first(where: { $0.id == entry.rid && $0.type == 0 }) { applyOverwrite(ow) }
        }
        if let my = catOW.first(where: { $0.id == me && $0.type == 1 }) { applyOverwrite(my) }
        if let my = chanOW.first(where: { $0.id == me && $0.type == 1 }) { applyOverwrite(my) }
        return bits
    }

    /// Runs the same algorithm as `canSendMessages` specifically for the
    /// VIEW_CHANNEL bit, used to hide channels the user isn't allowed to see.
    func canView(_ channel: Channel) -> Bool {
        guard channel.guildId != nil else { return true }
        guard channel.isTextLike else { return false }
        let bits = permissionBits(in: channel)
        if bits == UInt64.max { return true }            // DM
        if bits & (1 << 3) != 0 { return true }          // ADMINISTRATOR
        return bits & (1 << 10) != 0                     // VIEW_CHANNEL
    }

    /// Whether the signed-in user may post text in `channel`. DMs always allow.
    /// Guild channels run Discord's permission algorithm against the cached
    /// roles, the member's roles, and the channel overwrites. Badly-locked
    /// outputs trend to "no" (never grant something we can't prove).
    func canSendMessages(in channel: Channel) -> Bool {
        guard channel.guildId != nil else { return true }   // DM / group DM
        guard channel.isTextLike else { return false }
        let bits = permissionBits(in: channel)
        if bits == UInt64.max { return true }
        let admin = bits & (1 << 3) != 0
        let view   = bits & (1 << 10) != 0
        let send   = bits & (1 << 11) != 0
        if admin { return true }
        // "send messages in threads" (bit 34) isn't needed for plain guild
        // text channels; threads inherit the parent's rules.
        return view && send
    }

    /// Union of the signed-in user's guild-level permission bits, from the
    /// cached role list. Never grants permission we can't prove.
    func myPermissions(in guildID: Snowflake) -> UInt64 {
        guard let guild = guilds.first(where: { $0.id == guildID }),
              let me = user?.id else { return 0 }
        let roles = guild.roles ?? []
        var myRoleIDs = guild.members?.first { $0.user?.id == me }?.roles ?? []
        if !myRoleIDs.contains(guildID) { myRoleIDs.append(guildID) }
        var bits = roles.first { $0.id == guildID }?.permissions.flatMap(UInt64.init) ?? 0
        for role in roles where myRoleIDs.contains(role.id) {
            if let b = role.permissions.flatMap(UInt64.init) { bits |= b }
        }
        return bits
    }

    /// Whether the signed-in user carries moderator-level permissions in the
    /// guild this channel belongs to: kick/ban/moderate/manage-guild, or
    /// manage-messages (deleting and timeouting both ride on it). DMs never
    /// count.
    func canModerate(in channelID: Snowflake) -> Bool {
        guard let channel = channel(with: channelID), let gid = channel.guildId else { return false }
        let bits = myPermissions(in: gid)
        if bits & (1 << 3) != 0 { return true }        // ADMINISTRATOR
        if bits & (1 << 1) != 0 { return true }        // KICK_MEMBERS
        if bits & (1 << 2) != 0 { return true }        // BAN_MEMBERS
        if bits & (1 << 5) != 0 { return true }        // MANAGE_GUILD
        if bits & (1 << 13) != 0 { return true }       // MANAGE_MESSAGES
        if bits & (1 << 40) != 0 { return true }       // MODERATE_MEMBERS
        return false
    }

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
        loadMessageLog(for: account.id)
        bootError = nil
        let rest = DiscordREST(token: account.token)
        self.rest = rest
        let gw = DiscordGateway(token: account.token)
        gw.onEvent = { [weak self] event in self?.handle(event) }
        gateway = gw
        gatewayState = .connecting
        gw.connect()
        #if os(macOS)
        startRichPresenceIPC()
        #endif
    }

    // MARK: Rich Presence IPC capture
    //
    // Games and apps advertise "now playing" over a local IPC socket the
    // official client listens on. We claim that socket and push those
    // SET_ACTIVITY frames back out over the gateway, so the presence appears
    // on this account (and on the user's own profile card) instead.

    private func startRichPresenceIPC() {
        guard rpcIPC == nil else { return }
        let ipc = RichPresenceIPC()
        ipc.onActivity = { [weak self] activity, clientID in
            Task { @MainActor in await self?.applyRPC(activity, clientID: clientID) }
        }
        ipc.start()
        rpcIPC = ipc
    }

    private func applyRPC(_ dict: [String: Any]?, clientID: String?) async {
        guard let me = user?.id else { return }
        guard let dict, !dict.isEmpty else {
            // The app cleared its activity (or sent an empty one).
            activitiesByUser[me] = nil
            broadcastMyPresence()
            Diag.app("RPC: activity cleared")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              var activity = try? JSONDecoder().decode(Presence.Activity.self, from: data) else {
            Diag.app("RPC: SET_ACTIVITY payload didn't decode", .warn)
            return
        }
        if activity.type == nil { activity.type = 0 }
        if activity.applicationId == nil, let clientID { activity.applicationId = clientID }

        var activities = [activity]
        if activity.name?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            // The app often leaves `name` blank; the app registry knows it.
            if let clientID, let appName = await appName(for: clientID) {
                activity.name = appName
                activities = [activity]
            }
        }
        activitiesByUser[me] = activities
        if presences[me] == nil { presences[me] = "online" }
        broadcastMyPresence()
        Diag.app("RPC: presence → \(activity.name ?? "?") \(activity.details.map { "· \($0)" } ?? "")")
    }

    private func appName(for clientID: String) async -> String? {
        guard let rest else { return nil }
        return (try? await rest.applicationInfo(clientID: clientID))?.name
    }

    /// Re-sends our presence (status + current activities) over the gateway —
    /// used after every RPC change and again after reconnect/READY.
    private func broadcastMyPresence() {
        guard let me = user?.id else { return }
        gateway?.updatePresence(status: presences[me] ?? "online",
                                activities: activitiesByUser[me] ?? [])
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
        activitiesByUser = [:]
        pingedChannels = []
        lastRead = [:]
        membersByGuild = [:]
        memberPanelGuild = nil
        showMembersPanel = false
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
            handleEdited(m)
        case .messageDelete(let p):
            handleMessageDeleted(p)
        case .typingStart(let t):
            typingByChannel[t.channelId, default: [:]][t.userId] = Date()
        case .presenceUpdate(let p):
            if let id = p.user?.id {
                if let status = p.status { presences[id] = status }
                if let acts = p.activities { activitiesByUser[id] = acts }
            }
        case .guildCreate(let g):
            mergeGuild(g)
        case .guildMembersChunk(let chunk):
            mergeMembersChunk(chunk)
        case .channelCreate(let c), .channelUpdate(let c):
            mergeChannel(c)
        case .reactionAdd(let p):
            applyReaction(p, added: true)
        case .reactionRemove(let p):
            applyReaction(p, added: false)
        case .messageAck(let p):
            // A ping read on *another* device must vanish here without us ever
            // seeing the message itself — this is that acknowledgement.
            markChannelRead(channelID: p.channelId, lastMessageID: p.messageId, mentionCount: p.mentionCount)
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
        for p in ready.presences {
            guard let id = p.user?.id else { continue }
            if let status = p.status { presences[id] = status }
            if let acts = p.activities { activitiesByUser[id] = acts }
        }
        lastRead = ready.lastReadByChannel
        reconcilePings(from: ready.mentionCountByChannel)
        savedGuildOrder = ready.guildOrder
        guilds = Self.ordered(ready.guilds, by: savedGuildOrder)
        guildFolders = ready.guildFolders
        if !savedGuildOrder.isEmpty {
            Diag.app("applied saved guild order (\(savedGuildOrder.count) entries)")
        }
        if !guildFolders.isEmpty {
            Diag.app("applied \(guildFolders.count) server folders")
        }
        membersByGuild = [:]
        for g in ready.guilds {
            if let ch = g.channels { channelsByGuild[g.id] = ch }
            // Cache guild members so a typist who hasn't messaged this session
            // still resolves to a name for the typing indicator.
            g.members?.compactMap(\.user).forEach { usersCache[$0.id] = $0 }
            cacheNicks(from: g)
            // Ignore *empty* member arrays: lazy/large guilds send one, and
            // caching it would forever mask the real roster.
            if let members = g.members, !members.isEmpty, membersByGuild[g.id] == nil {
                membersByGuild[g.id] = members.compactMap(\.user)
            }
        }
        dmChannels = ready.privateChannels.sorted { ($0.lastMessageId ?? "") > ($1.lastMessageId ?? "") }
        dmChannels.forEach { $0.recipients?.forEach { usersCache[$0.id] = $0 } }
        gatewayState = .ready
        if let me = user?.id, let acts = activitiesByUser[me], !acts.isEmpty {
            // Re-assert whatever Rich Presence activity is active after a
            // reconnect wiped the session's presence.
            broadcastMyPresence()
        }
        if let target = pendingChannelRoute {
            pendingChannelRoute = nil
            selectChannel(target)
        }
        syncBackgroundSessions()
    }

    private func mergeGuild(_ g: Guild) {
        if let idx = guilds.firstIndex(where: { $0.id == g.id }) {
            // Keep the richer roster if a newer GUILD_CREATE carries an empty
            // (lazy-guild) member array; the full roster survives until the
            // member request for it lands.
            var merged = g
            if g.members?.isEmpty != false,
               let existing = guilds[idx].members, !existing.isEmpty {
                merged.members = existing
            }
            guilds[idx] = merged
        } else {
            guilds.append(g)
            guilds = Self.ordered(guilds, by: savedGuildOrder)
        }
        if let ch = g.channels { channelsByGuild[g.id] = ch }
        cacheNicks(from: g)
        if let members = g.members, !members.isEmpty, membersByGuild[g.id] == nil {
            membersByGuild[g.id] = members.compactMap(\.user)
        }
    }

    /// Indexes `nick` per member so `nickname(of:inGuild:)` works even when the
    /// full roster for a guild hasn't been requested yet.
    private func cacheNicks(from g: Guild) {
        indexNicks(g.members ?? [], guildID: g.id)
    }

    private func indexNicks(_ members: [GuildMember], guildID: Snowflake) {
        var map = nicknames[guildID] ?? [:]
        for member in members {
            if let uid = member.user?.id, let nick = member.nick, !nick.isEmpty {
                map[uid] = nick
            }
        }
        nicknames[guildID] = map
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
        else if let me = user?.id, m.author?.id != me, isPing(m) {
            pingedChannels.insert(cid)
        }
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

    /// Pings are the only thing that warrants a red badge — plain unread stays
    /// quiet (bold names), so a badge always means "mention me".
    func isPinged(_ channelID: Snowflake) -> Bool {
        pingedChannels.contains(channelID)
    }

    /// Discord's `read_state.mention_count` is authoritative: it is what the
    /// official clients show, and it already accounts for channels you've read
    /// on other devices. Zero means the ping is gone — clear the badge even if
    /// we never received that mentioning message.
    func reconcilePings(from mentionCounts: [Snowflake: Int]) {
        for (channelID, count) in mentionCounts {
            if count > 0 { pingedChannels.insert(channelID) }
            else { pingedChannels.remove(channelID) }
        }
    }

    /// Acknowledges a channel as read, updating the local last-read marker and
    /// clearing its ping badge. Drives both local selection and the
    /// cross-device `MESSAGE_ACK` event.
    func markChannelRead(channelID: Snowflake, lastMessageID: Snowflake?, mentionCount: Int?) {
        if let last = lastMessageID { lastRead[channelID] = last }
        if let count = mentionCount {
            if count > 0 { pingedChannels.insert(channelID) }
            else { pingedChannels.remove(channelID) }
        } else {
            pingedChannels.remove(channelID)
        }
    }

    /// The membership roster for one guild, for the member panel.
    func members(in guildID: Snowflake) -> [DiscordUser] {
        membersByGuild[guildID] ?? []
    }

    /// Server-specific display name (nick) for a user in a guild, when one is
    /// set and known. Falls back to `nil`. The dedicated cache covers users
    /// whose full guild roster was never requested.
    func nickname(of userID: Snowflake, inGuild guildID: Snowflake?) -> String? {
        guard let guildID else { return nil }
        if let nick = nicknames[guildID]?[userID] { return nick }
        return guilds.first(where: { $0.id == guildID })?.members?
            .first { $0.user?.id == userID }?.nick
    }

    /// The name to show for a message author in a guild channel: their server
    /// nick when they have one, otherwise their global display name.
    func displayName(of user: DiscordUser?, inGuild guildID: Snowflake?) -> String? {
        guard let user else { return nil }
        return nickname(of: user.id, inGuild: guildID) ?? user.displayName
    }

    /// Panel-friendly kicker: fetch members exactly once per guild. READY has
    /// no member list, so the first time a server's roster is shown it comes
    /// from a gateway member request (the desktop client's path) with a REST
    /// fetch backing it up; failures stay nil so a later open retries.
    func ensureMembersLoaded(in guildID: Snowflake) {
        guard rest != nil else { return }
        // Re-request the roster on every open/warm call; Discord dedupes these
        // cheaply and chunk events keep the caches (and nicks) fresh.
        gateway?.requestMembers(guildID: guildID)
        if membersByGuild[guildID] == nil {
            Task { await loadMembers(in: guildID) }
        }
    }

    private func loadMembers(in guildID: Snowflake) async {
        guard let rest else { return }
        do {
            let roster = try await rest.guildMembers(guildID: guildID)
            var users: [DiscordUser] = []
            roster.forEach { member in
                if let user = member.user { usersCache[user.id] = user; users.append(user) }
            }
            membersByGuild[guildID] = users
            membersLoadError[guildID] = nil
            indexNicks(roster, guildID: guildID)
            if let idx = guilds.firstIndex(where: { $0.id == guildID }) {
                var g = guilds[idx]
                g.members = roster
                guilds[idx] = g
                cacheNicks(from: g)
            }
        } catch {
            // If the gateway path already delivered the roster, a REST failure
            // is noise, not an error.
            if membersByGuild[guildID] == nil {
                membersLoadError[guildID] = error.localizedDescription
            }
            Diag.app("member roster load failed for \(guildID): \(error)", .error)
        }
    }

    /// Merges one gateway roster page into the caches. Chunks append to earlier
    /// ones (deduped by user id); the full `GuildMember` records accumulate on
    /// the guild so nicks and roles still resolve.
    private func mergeMembersChunk(_ chunk: GuildMembersChunk) {
        let guildID = chunk.guildId

        var users = membersByGuild[guildID] ?? []
        var seen = Set(users.map(\.id))
        for member in chunk.members {
            if let user = member.user, seen.insert(user.id).inserted { users.append(user) }
            if let user = member.user { usersCache[user.id] = user }
        }
        membersByGuild[guildID] = users
        indexNicks(chunk.members, guildID: guildID)

        for p in chunk.presences {
            guard let id = p.user?.id else { continue }
            if let status = p.status { presences[id] = status }
            if let acts = p.activities { activitiesByUser[id] = acts }
        }

        if let idx = guilds.firstIndex(where: { $0.id == guildID }) {
            var g = guilds[idx]
            var roster = g.members ?? []
            var seenMembers = Set(roster.compactMap(\.user?.id))
            for member in chunk.members {
                if let uid = member.user?.id, seenMembers.insert(uid).inserted { roster.append(member) }
            }
            g.members = roster
            guilds[idx] = g
            cacheNicks(from: g)
        }

        let last = chunk.chunkCount.map { chunk.chunkIndex == $0 - 1 } ?? true
        if last && !chunk.members.isEmpty {
            membersLoadError[guildID] = nil
        }
    }

    /// Clears any recorded failure and tries the roster again.
    func retryMembers(in guildID: Snowflake) {
        membersLoadError[guildID] = nil
        ensureMembersLoaded(in: guildID)
    }

    /// Makes sure a guild's role list is cached so profile cards can name the
    /// member's roles. Gateway GUILD_CREATE usually supplies it; this fetches
    /// it over REST when that never happened (e.g. cache warmed differently).
    func ensureGuildRoles(in guildID: Snowflake) {
        guard rest != nil else { return }
        if let roles = guilds.first(where: { $0.id == guildID })?.roles, !roles.isEmpty { return }
        Task {
            do {
                guard let rest else { return }
                let roles = try await rest.guildRoles(guildID: guildID)
                if !roles.isEmpty, let idx = guilds.firstIndex(where: { $0.id == guildID }) {
                    var g = guilds[idx]
                    g.roles = roles
                    guilds[idx] = g
                }
            } catch {
                Diag.rest("role fetch failed for \(guildID): \(error)", .error)
            }
        }
    }

    /// Message-search wrapper scoped to ONE channel. Both DMs and guild channels
    /// go through `/channels/{id}/messages/search` (the desktop client's
    /// channel-scoped route) — the guild variant with a `channel_id` filter
    /// rejects certain channel types with opaque errors. `hits` are the matched
    /// messages (first element of each snippet), authors cached so the result
    /// rows can name them.
    func searchMessages(in channel: Channel, query: String, authorID: Snowflake? = nil,
                        descending: Bool = true) async throws -> (hits: [Message], total: Int) {
        guard let rest else { throw ModelError.offline }
        let resp = try await rest.searchMessages(inChannel: channel.id,
                                                 query: query, authorID: authorID,
                                                 sort: descending ? "desc" : "asc")
        let hits = resp.messages.compactMap { $0.first }
        hits.forEach { if let a = $0.author { usersCache[a.id] = a } }
        return (hits, resp.totalResults)
    }

    private func isPing(_ m: Message) -> Bool {
        guard let me = user?.id else { return false }
        if m.mentionEveryone == true { return true }
        return m.mentions?.contains { $0.id == me } == true
    }

    func pingedCount(inGuild id: Snowflake) -> Int {
        (channelsByGuild[id] ?? []).filter { $0.isTextLike && isPinged($0.id) }.count
    }

    var pingedDMCount: Int {
        dmChannels.filter { isPinged($0.id) }.count
    }

    func selectChannel(_ id: Snowflake) {
        selectedChannelID = id
        // Opening a channel clears its unread marker and any ping on it.
        if let ch = (dmChannels + channelsByGuild.values.flatMap { $0 }).first(where: { $0.id == id }),
           let latest = ch.lastMessageId {
            lastRead[id] = latest
        }
        pingedChannels.remove(id)
        channelOpenToken &+= 1
        if let guildID = (dmChannels + channelsByGuild.values.flatMap { $0 })
            .first(where: { $0.id == id })?.guildId {
            // Pull the roster early: message headers need server nicknames
            // right away, before the member panel is ever opened.
            ensureMembersLoaded(in: guildID)
        }
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

    /// Sends a guild sticker as a message, with a lightweight optimistic echo
    /// mirroring the way plain sends feel instant.
    func sendSticker(channelID: Snowflake, sticker: GuildSticker) {
        guard let rest else { return }
        let nonce = String(UInt64(Date().timeIntervalSince1970 * 1000))
        if let me = user {
            let optimistic = Message(id: "pending-\(nonce)", channelId: channelID, author: me,
                                     content: "", timestamp: DiscordTime.plainFormatter.string(from: Date()),
                                     nonce: nonce, stickerItems: [
                                        StickerItem(id: sticker.id, name: sticker.name,
                                                    formatType: sticker.formatType,
                                                    packId: nil, isAvailable: true)
                                     ])
            insertMessage(optimistic, dedupe: false)
        }
        Task {
            do {
                _ = try await rest.sendMessage(channelID: channelID, content: "",
                                               nonce: nonce, stickerIDs: [sticker.id])
            } catch {
                Diag.rest("sticker send failed: \(error.localizedDescription)", .error)
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

    /// Stages an image already in hand (right-click → Paste Image): decoded,
    /// flattened to PNG and dropped in the channel's attachment tray.
    func stageImage(_ image: NSImage, in channelID: Snowflake) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            Diag.app("paste image: couldn't encode clipboard image", .warn)
            return
        }
        let item = PendingAttachment(filename: "Pasted image.png", data: png, mime: "image/png")
        stage(item, in: channelID)
    }

    /// ⌘V image staging shared by the composer and the window-level fallback.
    /// An image file from Finder stages the real file; a bare image (screenshot)
    /// is decoded, converted to PNG and staged in the channel's attachment tray.
    func handleImagePaste(_ providers: [NSItemProvider], channelID: Snowflake?) {
        guard let channelID else { return }
        guard let provider = providers.first else {
            Diag.app("paste: no item providers on the pasteboard", .warn)
            return
        }
        let types = provider.registeredTypeIdentifiers
        Diag.app("paste received for channel \(channelID): \(types)")
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let accessOK = url.startAccessingSecurityScopedResource()
                defer { if accessOK { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                let ext = url.pathExtension
                let mime = UTType(filenameExtension: ext)?.preferredMIMEType
                    ?? ((UTType(filenameExtension: ext)?.conforms(to: .image) == true)
                        ? "image/jpeg" : "application/octet-stream")
                let item = PendingAttachment(filename: url.lastPathComponent, data: data, mime: mime)
                DispatchQueue.main.async { self.stage(item, in: channelID) }
            }
        } else {
            loadPastedImage(from: provider,
                            identifiers: provider.registeredTypeIdentifiers,
                            channelID: channelID)
        }
    }

    /// Picks an image directly off a pasteboard (screenshots, copied image
    /// data, and image files pulled from Finder) and stages it in the active
    /// channel's tray. This is the reliable ⌘V path — it runs ahead of the
    /// responder chain, which swallows paste events before SwiftUI's
    /// `.onPasteCommand` can see them. Returns whether anything landed.
    @discardableResult
    func stagePastedImage(from pb: NSPasteboard) -> Bool {
        guard let channelID = selectedChannelID else { return false }
        guard let image = NSImage(pasteboard: pb),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Diag.app("paste: no decodable image on the pasteboard", .warn)
            return false
        }
        stage(.init(filename: "Pasted image.png", data: png, mime: "image/png"), in: channelID)
        Diag.app("paste: staged image in \(channelID)")
        return true
    }

    /// Tries each pasteboard image type until one decodes, so screenshots
    /// (tiff), png and jpeg clipboard data all land in the tray.
    private func loadPastedImage(from provider: NSItemProvider,
                                 identifiers: [String],
                                 channelID: Snowflake) {
        guard let first = identifiers.first else { return }
        provider.loadDataRepresentation(forTypeIdentifier: first) { data, _ in
            if let data, let image = NSImage(data: data),
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                let item = PendingAttachment(filename: "Pasted image.png", data: png, mime: "image/png")
                DispatchQueue.main.async { self.stage(item, in: channelID) }
            } else {
                self.loadPastedImage(from: provider,
                                     identifiers: Array(identifiers.dropFirst()),
                                     channelID: channelID)
            }
        }
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

    // MARK: GIFs

    /// Discord keeps gifs favoriteable per account; PUT adds, DELETE removes.
    /// The picker pulls favorites locally first, then tries to reconcile with
    /// Discord. The sync endpoints are on the way out (they 404 these days),
    /// so load failures keep the local list instead of blowing it away.
    @Published var favoriteGIFs: [GIFItem] = []
    /// Why favorites failed to load, if they did — shown in the picker so an
    /// empty Favorites tab is never mistaken for "you have no favorites".
    @Published var favoritesLoadError: String?

    func reloadFavorites() async {
        guard let rest else { return }
        do {
            favoriteGIFs = try await rest.gifFavorites()
            favoritesLoadError = nil
        } catch {
            Diag.rest("gif favorites sync failed (keeping local): \(error.localizedDescription)", .warn)
            favoritesLoadError = favoriteGIFs.isEmpty ? "Discord GIF favorites are unreachable — favorites still work locally." : nil
        }
    }

    /// Optimistic local flip + best-effort server sync. The sync failure is
    /// silent because the next `reloadFavorites()` reconciles any drift.
    func toggleFavorite(_ gif: GIFItem) {
        let wasFavorite = isFavorite(gif)
        if wasFavorite {
            favoriteGIFs.removeAll { $0.id == gif.id }
        } else {
            favoriteGIFs.insert(gif, at: 0)
        }
        Task {
            try? await rest?.gifSetFavorite(id: gif.id, !wasFavorite)
        }
    }

    func isFavorite(_ gif: GIFItem) -> Bool {
        favoriteGIFs.contains { $0.id == gif.id }
    }

    /// Sends a GIF as a message whose content is the GIF URL — Discord unfurls
    /// it into an image embed the moment it hits the gateway.
    func sendGIF(url: URL, in channelID: Snowflake) {
        sendMessage(channelID: channelID, content: url.absoluteString)
    }

    /// Sends a picked GIF by downloading its bytes and posting them as an
    /// attachment: the file is then hosted on Discord's CDN, so it renders
    /// animated in chat forever instead of a snapshot or a dead klipy link.
    /// If the bytes can't be fetched the URL is sent instead — Discord still
    /// unfurls those into embeds.
    func sendGIF(item: GIFItem, in channelID: Snowflake) {
        guard let url = item.gifURL ?? item.previewURL else {
            Diag.app("send gif: item has no media URL", .warn)
            return
        }
        Task {
            if let data = await GIFStore.data(for: url), !data.isEmpty {
                let filename = "\(item.id.isEmpty ? "gif" : item.id).gif"
                let attachment = PendingAttachment(filename: filename, data: data, mime: "image/gif")
                if !(pendingAttachments[channelID]?.isEmpty ?? true) {
                    // A draft is already staged — ride along with it.
                    stage(attachment, in: channelID)
                } else {
                    pendingAttachments[channelID] = [attachment]
                    sendAttachments(channelID: channelID, caption: "")
                }
            } else {
                Diag.app("send gif: byte fetch failed, sending URL instead", .warn)
                sendMessage(channelID: channelID, content: url.absoluteString)
            }
        }
    }

    // MARK: Message logger (opt-in; Settings → Privacy)

    private func logPath(for accountID: Snowflake) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nitrous", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("messagelog-\(accountID).json")
    }

    private func loadMessageLog(for accountID: Snowflake) {
        guard Self.messageLoggingEnabled,
              let data = try? Data(contentsOf: logPath(for: accountID)),
              let decoded = try? JSONDecoder().decode([MessageLogEntry].self, from: data)
        else { messageLog = []; return }
        messageLog = decoded
    }

    private func persistMessageLog() {
        guard Self.messageLoggingEnabled, !messageLog.isEmpty,
              let id = accountStore.activeID,
              let data = try? JSONEncoder().encode(messageLog) else { return }
        try? data.write(to: logPath(for: id), options: .atomic)
    }

    private func appendLog(_ entry: MessageLogEntry) {
        guard Self.messageLoggingEnabled else { return }
        messageLog.insert(entry, at: 0)
        if messageLog.count > 400 { messageLog = Array(messageLog.prefix(400)) }
        persistMessageLog()
    }

    func clearMessageLog() {
        messageLog = []
        if let id = accountStore.activeID { try? FileManager.default.removeItem(at: logPath(for: id)) }
    }

    /// Entries for one channel, newest first (the Recents sheet).
    func messageLog(in channelID: Snowflake) -> [MessageLogEntry] {
        messageLog.filter { $0.channelID == channelID }
    }

    private func handleMessageDeleted(_ p: MessageDeletePayload) {
        guard var list = messagesByChannel[p.channelId] else { return }
        let victim = list.first(where: { $0.id == p.id })

        if Self.messageLoggingEnabled {
            let author = victim?.author
            appendLog(MessageLogEntry(
                id: "del-\(p.id)", messageID: p.id, channelID: p.channelId,
                guildID: p.guildId, authorID: author?.id, authorName: author?.displayName,
                content: victim?.content, kind: .deleted, timestamp: Date(), editedFrom: nil))
            // Keep the context in the transcript with a system tombstone, just
            // like Discord desktop does for your own workspace.
            if let author {
                let tomb = Message(id: "tomb-\(p.id)", channelId: p.channelId,
                                   author: author, content: "deleted a message",
                                   timestamp: victim?.timestamp ?? DiscordTime.plainFormatter.string(from: Date()),
                                   type: 6)
                if let idx = list.firstIndex(where: { $0.id == p.id }) { list[idx] = tomb }
                else { list.append(tomb) }
            }
        } else {
            list.removeAll { $0.id == p.id }
        }
        messagesByChannel[p.channelId] = list
    }

    private func handleEdited(_ m: Message) {
        guard let cid = m.channelId, let list = messagesByChannel[cid],
              let idx = list.firstIndex(where: { $0.id == m.id }) else { return }
        let before = list[idx]
        if Self.messageLoggingEnabled, m.content != before.content, !m.content.isEmpty {
            appendLog(MessageLogEntry(
                id: "edit-\(m.id)-\(Int(Date().timeIntervalSince1970 * 1_000_000))",
                messageID: m.id, channelID: cid, guildID: nil,
                authorID: before.author?.id, authorName: before.author?.displayName,
                content: m.content, kind: .edited, timestamp: Date(), editedFrom: before.content))
        }
        updateMessage(m)
    }

    // MARK: Moderation

    private func guildID(for channelID: Snowflake) -> Snowflake? {
        channelsByGuild.first { value in value.value.contains { $0.id == channelID } }?.key
    }

    func timeout(_ userID: Snowflake, in channelID: Snowflake, for hours: Int) {
        guard let rest, let gid = guildID(for: channelID) else { return }
        Task {
            do {
                try await rest.timeoutUser(guildID: gid, userID: userID,
                                           until: Date().addingTimeInterval(TimeInterval(hours) * 3600))
                Diag.rest("timeout @\(userID) for \(hours)h", .success)
            } catch { Diag.rest("timeout failed: \(error.localizedDescription)", .error) }
        }
    }

    func kick(_ userID: Snowflake, from channelID: Snowflake) {
        guard let rest, let gid = guildID(for: channelID) else { return }
        Task {
            do { try await rest.kickUser(guildID: gid, userID: userID); Diag.rest("kicked @\(userID)", .success) }
            catch { Diag.rest("kick failed: \(error.localizedDescription)", .error) }
        }
    }

    func ban(_ userID: Snowflake, from channelID: Snowflake, deleteDays: Int = 0) {
        guard let rest, let gid = guildID(for: channelID) else { return }
        Task {
            do {
                try await rest.banUser(guildID: gid, userID: userID, deleteMessageDays: deleteDays)
                Diag.rest("banned @\(userID)", .success)
            } catch { Diag.rest("ban failed: \(error.localizedDescription)", .error) }
        }
    }

    /// Deletes from the cursor message upward under the cursor — the classic
    /// "purge to here" tool. Bulk-delete caps at 100 and skips system rows.
    func purgeUpTo(_ messageID: Snowflake, in channelID: Snowflake) {
        guard let rest else { return }
        let list = messagesByChannel[channelID] ?? []
        guard let idx = list.firstIndex(where: { $0.id == messageID }) else { return }
        let targets = list[idx...].compactMap { ($0.isSystem || $0.id.hasPrefix("tomb-")) ? nil : $0.id }
        guard !targets.isEmpty else { return }
        messagesByChannel[channelID] = Array(list.prefix(idx))
        Task {
            do { try await rest.bulkDeleteMessages(channelID: channelID, messageIDs: targets) }
            catch { Diag.rest("bulk delete failed: \(error.localizedDescription)", .error) }
        }
    }

    // MARK: Derived helpers

    func typingUsers(in channelID: Snowflake) -> [DiscordUser] {
        let cutoff = Date().addingTimeInterval(-9)
        return (typingByChannel[channelID] ?? [:])
            .filter { $0.value > cutoff && $0.key != user?.id }
            .keys
            .compactMap { usersCache[$0] }
    }

    /// Display names for everyone typing. Falls back to "Someone" so a typist
    /// outside the users cache can never kill the indicator.
    func typingNames(in channelID: Snowflake) -> [String] {
        let cutoff = Date().addingTimeInterval(-9)
        return (typingByChannel[channelID] ?? [:])
            .filter { $0.value > cutoff && $0.key != user?.id }
            .keys
            .map { usersCache[$0]?.displayName ?? "Someone" }
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
