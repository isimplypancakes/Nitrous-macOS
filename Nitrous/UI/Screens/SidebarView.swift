import SwiftUI

/// The source list. This is the macOS home for **Servers** and **Messages**:
/// servers up top so the guilds you care about are reachable first, with all
/// direct messages collapsed behind a single Discord-style "Home" toggle at the
/// top of the list. Expand it to reveal DM conversations below.
struct SidebarView: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var notifications: NotificationCenterManager
    @State private var showNewMessage = false
    @State private var showAddAccount = false
    @State private var dmsExpanded = false
    @State private var showProfileCard = false
    @State private var openServer: Snowflake?
    @State private var expandedFolders: Set<String> = []

    private var connectionLabel: String {
        switch model.gatewayState {
        case .ready: return ""
        case .connecting, .connected: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Offline"
        }
    }

    /// A compact icon rail is plenty for guilds; only opening the DM list
    /// widens the column to fit names. Collapsing it shrinks back to the rail.
    private var wide: Bool { dmsExpanded }

    var body: some View {
        List(selection: $model.selectedChannelID) {
            accountCard
                .listRowBackground(Color.clear)

            if !connectionLabel.isEmpty {
                Label(connectionLabel, systemImage: "network")
                    .font(.caption).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let error = model.bootError, model.guilds.isEmpty && model.dmChannels.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title).foregroundStyle(.orange)
                        Text("Can't Connect").font(.headline)
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") { model.retry() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .glassCard()
                }
            }

            Section {
                DisclosureGroup(isExpanded: $dmsExpanded) {
                    if model.dmChannels.isEmpty {
                        Text("No direct messages yet.")
                            .font(.caption).foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(model.dmChannels) { channel in
                        ConversationRow(channel: channel)
                            .tag(channel.id)
                    }
                } label: {
                    dmHeader
                }
            }

            Section {
                if model.guilds.isEmpty {
                    Text("No servers yet — they appear here automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(railItems) { item in
                    switch item {
                    case .guild(let guild):
                        serverPopupButton(guild)
                    case .folder(let folder):
                        DisclosureGroup(isExpanded: folderBinding(folder)) {
                            ForEach(folder.guilds(in: model.guilds)) { guild in
                                serverPopupButton(guild)
                            }
                        } label: {
                            folderCapsule(folder)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationSplitViewColumnWidth(min: wide ? 240 : 42,
                                        ideal: wide ? 280 : 50,
                                        max: wide ? 400 : 84)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNewMessage = true } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Message")
            }
            ToolbarItem(placement: .automatic) { ConnectionBadge() }
        }
        .sheet(isPresented: $showNewMessage) {
            NewMessageView { channel in
                showNewMessage = false
                model.selectChannel(channel.id)
            }
        }
        .sheet(isPresented: $showAddAccount) { AddAccountSheet() }
        .onAppear { notifications.refreshAuthorization() }
    }

    // MARK: Rows

    private var dmHeader: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { dmsExpanded.toggle() }
            } label: {
                ZStack {
                    Circle().fill(isActiveDM ? Palette.accent : Color.primary.opacity(0.06))
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isActiveDM ? Brand.onAccent : Palette.accent)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .help("Direct Messages")
            let pinged = model.pingedDMCount
            if pinged > 0 {
                Text("\(pinged)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
                    .help("\(pinged) mentioned conversation\(pinged == 1 ? "" : "s")")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// Is the open conversation a DM (nothing selected in a guild)?
    private var isActiveDM: Bool {
        guard let sel = model.selectedChannelID else { return false }
        return model.channel(with: sel)?.guildId == nil
    }

    private var accountCard: some View {
        Button { showProfileCard = true } label: {
            PresenceAvatar(url: model.user?.avatarURL,
                           name: model.user?.displayName ?? "You",
                           status: model.presences[model.user?.id ?? ""],
                           size: 34,
                           seed: model.user?.id ?? "")
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(model.user?.displayName ?? "Your profile")
        .popover(isPresented: $showProfileCard, arrowEdge: .trailing) {
            if let user = model.user {
                UserProfileView(user: user, showsAccountSwitcher: true)
            }
        }
    }

    /// Clicking a server icon pops the server's name + channels out beside it,
    /// exactly like the official client, so the rail never grows a channel tree.
    private func serverPopupButton(_ guild: Guild) -> some View {
        Button { openServer = openServer == guild.id ? nil : guild.id } label: {
            serverRow(guild)
        }
        .buttonStyle(.plain)
        .popover(isPresented: serverPopupBinding(guild), arrowEdge: .trailing) {
            ServerChannelView(guild: guild, tagText: guildTagText(guild)) { channelID in
                openServer = nil
                model.selectChannel(channelID)
            } onShowMembers: {
                openServer = nil
                model.memberPanelGuild = guild.id
                model.showMembersPanel = true
            }
        }
    }

    private func serverPopupBinding(_ guild: Guild) -> Binding<Bool> {
        Binding(get: { openServer == guild.id },
                set: { if !$0 { openServer = nil } })
    }

    /// One rail entry per item the user can click: an unfiled server as its own
    /// icon, or a folder capsule. Discord keeps a folder's members consecutive
    /// in the saved order, so emitting the folder and skipping its members to
    /// the right reconstructs the rail exactly.
    enum RailItem: Identifiable {
        case guild(Guild)
        case folder(GuildOrderProto.GuildFolder)
        var id: String {
            switch self {
            case .guild(let g): return "g:\(g.id)"
            case .folder(let f): return "f:\(f.id ?? f.guildIds.joined())"
            }
        }
    }

    private var railItems: [RailItem] {
        let folders = model.guildFolders
        let memberOf = Dictionary(grouping: folders.flatMap { folder in
            folder.guildIds.map { ($0, folder) }
        }, by: \.0).mapValues { $0.first!.1 }
        var emittedFolders: Set<String> = []
        return model.guilds.compactMap { guild -> RailItem? in
            if let folder = memberOf[guild.id],
               isRealFolder(folder) {
                let key = folderKey(folder)
                guard !emittedFolders.contains(key) else { return nil }
                emittedFolders.insert(key)
                return .folder(folder)
            }
            return .guild(guild)
        }
    }

    /// A folder record is a *real* folder when Discord gave it an id or a name,
    /// or when it holds more than one server. Discord keeps *every* guild in a
    /// folder record — unfiled ones are single-guild entries with nothing else
    /// set — so anything else renders as an ordinary server icon.
    private func isRealFolder(_ folder: GuildOrderProto.GuildFolder) -> Bool {
        folder.id != nil
            || folder.name?.isEmpty == false
            || folder.guildIds.count > 1
    }

    private func folderKey(_ folder: GuildOrderProto.GuildFolder) -> String {
        folder.id ?? folder.name ?? folder.guildIds.joined()
    }

    private func folderBinding(_ folder: GuildOrderProto.GuildFolder) -> Binding<Bool> {
        let key = folderKey(folder)
        return Binding(
            get: { expandedFolders.contains(key) },
            set: { if $0 { expandedFolders.insert(key) } else { expandedFolders.remove(key) } }
        )
    }

    /// A compact folder capsule: overlapping member icons on a tinted tile
    /// (folder color when Discord saved one), name underneath. Clicking expands
    /// the members into the rail.
    private func folderCapsule(_ folder: GuildOrderProto.GuildFolder) -> some View {
        let members = folder.guilds(in: model.guilds)
        let preview = members.prefix(3)
        return VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(folder.colorValue?.opacity(0.30) ?? Color.primary.opacity(0.10))
                HStack(spacing: -4) {
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, guild in
                        ServerIcon(guild: guild, size: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            }
            .frame(width: 34, height: 34)
            Text(folder.name?.isEmpty == false ? folder.name! : "Folder")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help("\(folder.name ?? "Folder") — \(members.count) server\(members.count == 1 ? "" : "s")")
        .padding(.vertical, 2)
    }

    private func serverRow(_ guild: Guild) -> some View {
        let active = guild.id == model.selectedGuildID
        let pinged = model.pingedCount(inGuild: guild.id)
        return HStack(spacing: 8) {
            ServerIcon(guild: guild, size: 34)
                .overlay(
                    Circle().stroke(Palette.accent, lineWidth: active ? 2.5 : 0)
                )
                .overlay(alignment: .bottomTrailing) {
                    if let tag = guild.tags.first {
                        Image(systemName: tag.symbol)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Brand.onAccent)
                            .padding(2.5)
                            .background(Palette.accent, in: Circle())
                            .offset(x: 1, y: 1)
                            .help(tag.label)
                    }
                }
                .help(guildTagText(guild))
            if pinged > 0 {
                Text("\(pinged)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.red, in: Capsule())
                    .help("\(pinged) mentioned channel\(pinged == 1 ? "" : "s")")
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
    }

    /// "Guild Name · Verified" shown as the icon's tooltip, since the sidebar
    /// deliberately dropped server names in favor of icons.
    private func guildTagText(_ guild: Guild) -> String {
        var text = guild.name
        for tag in guild.tags { text += " · \(tag.label)" }
        return text
    }
}

/// A conversation row for a DM, Messages.app-style: avatar, name, preview.
struct ConversationRow: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var model: AppModel
    let channel: Channel

    private var other: DiscordUser? { model.otherUser(in: channel) }
    private var preview: String {
        if let last = model.messagesByChannel[channel.id]?.last {
            return last.content.isEmpty ? "Attachment" : last.content
        }
        if channel.type == .groupDM {
            return "\(channel.participantIDs(excluding: nil).count) members"
        }
        return " "
    }

    var body: some View {
        HStack(spacing: 10) {
            if channel.type == .groupDM {
                ZStack {
                    Circle().fill(fallbackColor(for: channel.id).gradient)
                    Image(systemName: "person.2.fill").foregroundStyle(.white).font(.system(size: 15))
                }
                .frame(width: 40, height: 40)
            } else {
                PresenceAvatar(url: other?.avatarURL, name: other?.displayName ?? "?",
                               status: model.presences[other?.id ?? ""], size: 40,
                               seed: other?.id ?? channel.id)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName(for: channel))
                    .font(.callout.weight(model.isUnread(channel) ? .bold : .medium))
                    .foregroundStyle(.primary).lineLimit(1)
                Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.isPinged(channel.id) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
            }
            if let latest = channel.lastMessageId, let date = latest.snowflakeDate {
                Text(SidebarView.dmTime.string(from: date))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

extension SidebarView {
    /// Compact "h:mm" timestamp for the DM list.
    static let dmTime: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm"
        return f
    }()
}

/// The view that pops out next to a server icon: server header, then its
/// channels — the same shape the official client gives you on the icon rail.
struct ServerChannelView: View {
    @EnvironmentObject var model: AppModel
    let guild: Guild
    let tagText: String
    let onSelectChannel: (Snowflake) -> Void
    let onShowMembers: () -> Void

    private var channels: [Channel] { model.channelsByGuild[guild.id] ?? [] }
    private var textChannels: [Channel] {
        channels.filter { !$0.isCategory && $0.isTextLike && model.canView($0) }
            .sorted { $0.sortPosition < $1.sortPosition }
    }
    private var categories: [Channel] {
        channels.filter(\.isCategory)
            .filter { category in
                // Skip categories whose every child is invisible to the user.
                channels.contains { $0.parentId == category.id && $0.isTextLike && model.canView($0) }
            }
            .sorted { $0.sortPosition < $1.sortPosition }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ServerIcon(guild: guild, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(guild.name)
                        .font(.headline).lineLimit(1)
                        .help(tagText)
                    if let count = guild.memberCount {
                        Text("\(count) members").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Channels")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    if textChannels.isEmpty && categories.isEmpty {
                        Text("No channels").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(textChannels) { channel in
                        channelRow(channel)
                    }
                    ForEach(categories) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.name ?? "Category")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.top, 4)
                            ForEach(channels.filter { $0.parentId == category.id && $0.isTextLike && model.canView($0) }
                                .sorted { $0.sortPosition < $1.sortPosition }) { child in
                                channelRow(child)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 14) {
                Button(action: onShowMembers) {
                    Label("Members", systemImage: "person.2.fill")
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .help("View this server's members")
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .frame(width: 280, height: 440)
        .onAppear {
            let perms = channels.filter { !$0.isCategory && $0.isTextLike && !model.canView($0) }
            if !perms.isEmpty {
                Diag.app("\(guild.name): hiding \(perms.count) of \(channels.count) channels \(perms.prefix(3).compactMap(\.name).joined(separator: ", "))")
            }
        }
    }

    private func channelRow(_ channel: Channel) -> some View {
        let selected = model.selectedChannelID == channel.id
        let unread = model.isUnread(channel)
        return Button { onSelectChannel(channel.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "number")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(channel.name ?? "channel")
                    .fontWeight(unread ? .semibold : .regular)
                    .foregroundStyle(selected ? Palette.accent : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if model.isPinged(channel.id) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selected ? Palette.accent.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }
}

/// A compact live connection indicator for the window toolbar.
struct ConnectionBadge: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        switch model.gatewayState {
        case .ready:
            EmptyView()
        case .connecting, .connected, .reconnecting:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
            }
            .help("Connecting to Discord")
        case .disconnected:
            Image(systemName: "wifi.slash")
                .foregroundStyle(.secondary)
                .font(.footnote)
                .help("Disconnected — check your connection")
        }
    }
}