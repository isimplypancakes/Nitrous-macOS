import SwiftUI

/// The member roster, presented as a native sheet from a channel. Grouped into
/// Online / Offline, with a tappable profile card per member.
struct MemberListView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: DiscordUser?

    private var members: [DiscordUser] {
        model.usersCache.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
    private func isOnline(_ u: DiscordUser) -> Bool {
        ["online", "idle", "dnd"].contains(model.presences[u.id] ?? "offline")
    }
    private var online: [DiscordUser] { members.filter(isOnline) }
    private var offline: [DiscordUser] { members.filter { !isOnline($0) } }

    var body: some View {
        NavigationStack {
            List {
                section("Online — \(online.count)", online, dimmed: false)
                section("Offline — \(offline.count)", offline, dimmed: true)
            }
            .scrollContentBackground(.hidden)
            .themedBackground()
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $selected) { UserProfileView(user: $0) }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ users: [DiscordUser], dimmed: Bool) -> some View {
        if !users.isEmpty {
            Section(title) {
                ForEach(users) { user in
                    Button { selected = user } label: {
                        HStack(spacing: 12) {
                            PresenceAvatar(url: user.avatarURL, name: user.displayName,
                                           status: model.presences[user.id], size: 36, seed: user.id,
                                           ringColor: Palette.secondaryGroupedBg)
                                .opacity(dimmed ? 0.5 : 1)
                            Text(user.displayName).foregroundStyle(dimmed ? .secondary : .primary)
                            if user.bot == true {
                                Text("BOT").font(.system(size: 9, weight: .heavy))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                        }
                    }
                    .foregroundStyle(.primary)
                    .buttonStyle(.bouncyRow)
                    .glassCard(vertical: 9)
                }
            }
        }
    }
}

/// A member's profile card with a shortcut to open a DM.
struct UserProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let user: DiscordUser

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        Rectangle().fill(fallbackColor(for: user.id).gradient).frame(height: 120)
                        AvatarView(url: user.avatarURL, name: user.displayName, size: 84, seed: user.id)
                            .overlay(Circle().stroke(Palette.background, lineWidth: 6))
                            .padding(.leading, 16).offset(y: 42)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Spacer().frame(height: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName).font(.title2.bold())
                            Text(user.tag).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let bio = user.bio, !bio.isEmpty {
                            GroupBox("About Me") { Text(bio).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                        GroupBox {
                            LabeledContent("Member Since",
                                value: user.id.snowflakeDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Unknown")
                        }
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
                            Label("Message", systemImage: "bubble.left.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .ignoresSafeArea(edges: .top)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
