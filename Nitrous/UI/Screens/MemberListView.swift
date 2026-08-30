import SwiftUI

/// The member roster shown in the window's `.inspector`. Grouped into
/// Online / Offline, with a tappable profile card per member.
struct MemberListSidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: DiscordUser?
    var guildID: Snowflake?

    private var members: [DiscordUser] {
        if let guildID { return model.members(in: guildID) }
        return model.usersCache.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
    private var loading: Bool {
        guard guildID != nil else { return false }
        return model.membersByGuild[guildID!] == nil
    }
    private var rosterError: String? {
        guard let guildID else { return nil }
        return model.membersLoadError[guildID]
    }
    /// The name a member is shown under in this guild (nick when they have one).
    private func listName(_ user: DiscordUser) -> String {
        model.nickname(of: user.id, inGuild: guildID) ?? user.displayName
    }
    private func isOnline(_ u: DiscordUser) -> Bool {
        ["online", "idle", "dnd"].contains(model.presences[u.id] ?? "offline")
    }
    private var online: [DiscordUser] { members.filter(isOnline) }
    private var offline: [DiscordUser] { members.filter { !isOnline($0) } }

    var body: some View {
        List {
            if let rosterError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2).foregroundStyle(.tertiary)
                    Text("Couldn't load members.")
                        .font(.callout.weight(.medium))
                    Text(rosterError)
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Button("Try Again") {
                        if let guildID { model.retryMembers(in: guildID) }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if loading && members.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if members.isEmpty {
                Text("No members yet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                section("Online — \(online.count)", online, dimmed: false)
                section("Offline — \(offline.count)", offline, dimmed: true)
            }
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Text(guildName ?? "Members")
                    .font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                Button { model.showMembersPanel = false } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Hide members")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
        .task(id: guildID) {
            if let guildID { await MainActor.run {
                model.ensureMembersLoaded(in: guildID)
                model.ensureGuildRoles(in: guildID)
            } }
        }
        .sheet(item: $selected) { UserProfileView(user: $0, guildID: guildID) }
    }

    private var guildName: String? {
        guard let guildID else { return nil }
        return model.guilds.first(where: { $0.id == guildID })?.name
    }

    @ViewBuilder
    private func section(_ title: String, _ users: [DiscordUser], dimmed: Bool) -> some View {
        if !users.isEmpty {
            Section(title) {
                ForEach(users) { user in
                    Button { selected = user } label: {
                        HStack(spacing: 12) {
                            PresenceAvatar(url: user.avatarURL, name: listName(user),
                                           status: model.presences[user.id], size: 32, seed: user.id,
                                           ringColor: Palette.secondaryGroupedBg)
                                .opacity(dimmed ? 0.5 : 1)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(listName(user))
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(dimmed ? .secondary : .primary)
                                        .lineLimit(1)
                                    if user.bot == true {
                                        Text("BOT").font(.system(size: 9, weight: .heavy))
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 3))
                                            .foregroundStyle(.white)
                                    }
                                }
                                // Rich presence preview: custom status then the
                                // top rich activity, exactly the desktop hierarchy.
                                if let acts = model.activitiesByUser[user.id] {
                                    if let cs = acts.first(where: { $0.isCustomStatus }) {
                                        CustomStatusView(activity: cs).opacity(dimmed ? 0.6 : 1)
                                    }
                                    if let rich = acts.first(where: { !$0.isCustomStatus }) {
                                        RichPresenceView(activity: rich)
                                            .opacity(dimmed ? 0.6 : 1)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.bouncyRow)
                }
            }
        }
    }
}

/// A member's profile card: banner, status, server tag, bio, rich presence and
/// a shortcut to open a DM. Reused from the account switcher (with the account
/// list) and when clicking any author's avatar or name in a conversation.
struct UserProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let user: DiscordUser
    var showsAccountSwitcher = false
    /// When set, the profile is shown in a specific server's context: the
    /// server nickname leads and the member's roles are listed beneath it.
    var guildID: Snowflake?

    private var displayName: String {
        model.displayName(of: user, inGuild: guildID) ?? user.displayName
    }

    private var memberRoles: [Role] {
        guard let guildID,
              let guild = model.guilds.first(where: { $0.id == guildID }),
              let member = guild.members?.first(where: { $0.user?.id == user.id }),
              let ids = member.roles,
              let guildRoles = guild.roles else { return [] }
        // @everyone's id equals the guild's id — never shown.
        return guildRoles
            .filter { $0.id != guildID && ids.contains($0.id) }
            .sorted { ($0.position, $0.name) > ($1.position, $1.name) }
    }

    private var roleChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(memberRoles) { role in
                let color = role.uiColor.map { Color(hex: UInt32($0)) } ?? Color.secondary
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(role.name).font(.caption).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(color.opacity(0.12), in: Capsule())
                .foregroundStyle(color)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(fallbackColor(for: user.id).gradient).frame(height: 120)
                    AvatarView(url: user.avatarURL, name: displayName, size: 84, seed: user.id)
                        .overlay(Circle().stroke(Palette.background, lineWidth: 6))
                        .padding(.leading, 16).offset(y: 42)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Spacer().frame(height: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(displayName).font(.title2.bold()).lineLimit(1)
                            GuildTagPill(user: user)
                        }
                        HStack(spacing: 5) {
                            Circle().fill(Palette.presence(model.presences[user.id])).frame(width: 9, height: 9)
                            Text(user.tag).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !memberRoles.isEmpty {
                            roleChips
                        }
                    }
                    if let acts = model.activitiesByUser[user.id], !acts.isEmpty {
                        let custom = acts.first { $0.isCustomStatus }
                        let rich = acts.filter { !$0.isCustomStatus }
                        GroupBox("Activity") {
                            VStack(alignment: .leading, spacing: 8) {
                                if let custom { CustomStatusView(activity: custom) }
                                if !rich.isEmpty {
                                    ForEach(Array(rich.enumerated()), id: \.offset) { _, a in
                                        RichPresenceView(activity: a)
                                    }
                                }
                                if custom == nil && rich.isEmpty {
                                    Text("Nothing to show").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let bio = user.bio, !bio.isEmpty {
                        GroupBox("About Me") { Text(bio).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    GroupBox {
                        LabeledContent("Member Since",
                            value: user.id.snowflakeDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Unknown")
                    }
                    if user.id != model.user?.id {
                        Button {
                            Task {
                                if let rest = model.restClient,
                                   let channel = try? await rest.createDM(recipientID: user.id) {
                                    if !model.dmChannels.contains(where: { $0.id == channel.id }) {
                                        model.dmChannels.insert(channel, at: 0)
                                    }
                                    model.selectChannel(channel.id)
                                }
                                dismiss()
                            }
                        } label: {
                            Label("Message", systemImage: "bubble.left.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }

                    if showsAccountSwitcher {
                        Divider().padding(.top, 6)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Switch Account").font(.headline)
                            ForEach(model.accountStore.accounts) { account in
                                let active = account.id == model.accountStore.activeID
                                Button {
                                    if !active { model.switchAccount(to: account.id) }
                                } label: {
                                    HStack {
                                        Text(account.displayName).foregroundStyle(.primary)
                                        Spacer(minLength: 8)
                                        if active {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(Palette.accent)
                                        }
                                    }
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(active)
                            }
                            Text("Or manage in Settings → Accounts.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(width: 380)
        .frame(minHeight: 480)
        .task(id: guildID) {
            if let guildID { await MainActor.run {
                model.ensureMembersLoaded(in: guildID)
                model.ensureGuildRoles(in: guildID)
            } }
        }
    }
}