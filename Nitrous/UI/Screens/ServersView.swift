import SwiftUI

/// Root of the Servers tab: a native list of the user's servers.
/// Selecting one pushes its channel list, which pushes into a chat.
struct ServersView: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var model: AppModel
    @State private var search = ""

    private var filtered: [Guild] {
        guard !search.isEmpty else { return model.guilds }
        return model.guilds.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var statusDescription: String {
        switch model.gatewayState {
        case .ready: return "Join a server to see it here."
        case .connecting, .connected: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Offline."
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.bootError, model.guilds.isEmpty {
                    // A failed session used to look identical to an empty one.
                    // Show the reason and a way out.
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.largeTitle).foregroundStyle(.orange)
                            Text("Can't Connect").font(.headline)
                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Try Again") { model.retry() }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                } else if model.guilds.isEmpty {
                    ContentUnavailableView("No Servers",
                        systemImage: "square.grid.2x2",
                        description: Text(statusDescription))
                }
                ForEach(filtered) { guild in
                    NavigationLink(value: guild) {
                        HStack(spacing: 12) {
                            ServerIcon(guild: guild, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(guild.name).font(.body.weight(.semibold))
                                if let count = guild.memberCount {
                                    Text("\(count.formatted()) members")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            let unread = model.unreadCount(inGuild: guild.id)
                            if unread > 0 {
                                Text("\(unread)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color.red, in: Capsule())
                            }
                        }
                    }
                    .glassCard()
                }
                .buttonStyle(.bouncyRow)
            }
            .scrollContentBackground(.hidden)
            .themedBackground()
            .navigationTitle("Servers")
            .searchable(text: $search, prompt: "Search servers")
            .navigationDestination(for: Guild.self) { ChannelListView(guild: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ConnectionBadge() }
            }
        }
    }
}

/// Channel list for a single server — grouped by category using native
/// inset-grouped sections. Rows push into the chat.
struct ChannelListView: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var model: AppModel
    let guild: Guild

    private var channels: [Channel] { model.channelsByGuild[guild.id] ?? [] }

    var body: some View {
        List {
            let uncategorized = channels
                .filter { !$0.isCategory && $0.parentId == nil }
                .sorted { $0.sortPosition < $1.sortPosition }
            if !uncategorized.isEmpty {
                Section { ForEach(uncategorized) { channelRow($0) } }
            }
            ForEach(categories) { cat in
                Section(cat.name?.capitalized ?? "") {
                    ForEach(children(of: cat.id)) { channelRow($0) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle(guild.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Channel.self) { channel in
            ChatView(channel: channel)
        }
    }

    private var categories: [Channel] {
        channels.filter { $0.isCategory }.sorted { $0.sortPosition < $1.sortPosition }
    }
    private func children(of catID: Snowflake) -> [Channel] {
        channels.filter { $0.parentId == catID && !$0.isCategory }
            .sorted { $0.sortPosition < $1.sortPosition }
    }

    @ViewBuilder
    private func channelRow(_ channel: Channel) -> some View {
        channelRowBody(channel)
            .buttonStyle(.bouncyRow)
            .glassCard(cornerRadius: 16, vertical: 11)
    }

    @ViewBuilder
    private func channelRowBody(_ channel: Channel) -> some View {
        if channel.isVoice {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary).frame(width: 22)
                Text(channel.name ?? "voice").foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            NavigationLink(value: channel) {
                let unread = model.isUnread(channel)
                HStack(spacing: 10) {
                    Image(systemName: "number").foregroundStyle(.secondary).frame(width: 22)
                    Text(channel.name ?? "channel")
                        .fontWeight(unread ? .semibold : .regular)
                    Spacer()
                    if unread {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    }
                }
            }
        }
    }
}

/// A compact live connection indicator for nav bars.
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
        case .disconnected:
            Image(systemName: "wifi.slash").foregroundStyle(.secondary).font(.footnote)
        }
    }
}
