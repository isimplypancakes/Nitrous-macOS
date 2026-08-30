import SwiftUI

/// The Messages tab — a native conversation list modeled on Apple's Messages
/// app: avatar, name, last-message preview, timestamp, swipe actions.
struct MessagesView: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var path: [Channel] = []
    @State private var showNewMessage = false

    private var filtered: [Channel] {
        guard !search.isEmpty else { return model.dmChannels }
        return model.dmChannels.filter {
            model.displayName(for: $0).localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.dmChannels.isEmpty {
                    ContentUnavailableView("No Messages", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Your direct messages will appear here."))
                }
                ForEach(filtered) { channel in
                    Button { path = [channel]; model.selectChannel(channel.id) } label: {
                        ConversationRow(channel: channel)
                    }
                    .buttonStyle(.bouncyRow)
                    .glassCard(vertical: 15)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollContentBackground(.hidden)
            .themedBackground()
            .navigationTitle("Messages")
            .searchable(text: $search, prompt: "Search")
            .navigationDestination(for: Channel.self) { ChatView(channel: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Was a bare Image — nothing to tap.
                    Button { showNewMessage = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.bouncy)
                }
            }
            .sheet(isPresented: $showNewMessage) {
                NewMessageView { channel in
                    showNewMessage = false
                    path = [channel]
                    model.selectChannel(channel.id)
                }
            }
        }
    }
}

private struct ConversationRow: View {
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
        HStack(spacing: 12) {
            if channel.type == .groupDM {
                ZStack {
                    Circle().fill(fallbackColor(for: channel.id).gradient)
                    Image(systemName: "person.2.fill").foregroundStyle(.white).font(.system(size: 18))
                }
                .frame(width: 52, height: 52)
            } else {
                PresenceAvatar(url: other?.avatarURL, name: other?.displayName ?? "?",
                               status: model.presences[other?.id ?? ""], size: 52, seed: other?.id ?? channel.id)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName(for: channel))
                    .font(.body.weight(model.isUnread(channel) ? .bold : .semibold))
                    .foregroundStyle(.primary).lineLimit(1)
                Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if model.isUnread(channel) {
                Circle().fill(Color.accentColor).frame(width: 10, height: 10)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
        }
    }
}
