import SwiftUI

/// The ⌘F dropdown: searches ONE channel (DMs or a guild channel) and shows
/// results as a small scrollable list with a "jump" affordance that scrolls
/// the conversation straight to the hit. Debounced — typing pauses briefly,
/// then the real Discord search endpoint runs.
struct ChannelSearchView: View {
    @EnvironmentObject var model: AppModel
    let channel: Channel

    @State private var query = ""
    @State private var hits: [Message] = []
    @State private var total = 0
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorText: String?
    @State private var authorFilter: Snowflake?
    @State private var sortNewest = true
    @FocusState private var focused: Bool

    private struct SearchKey: Equatable {
        let query: String
        let author: Snowflake?
        let newest: Bool
    }

    private var senders: [DiscordUser] {
        if let gid = channel.guildId { return model.members(in: gid) }
        if let other = channel.recipients?.first { return model.usersCache[other.id].map { [$0] } ?? [other] }
        return []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \"\(channel.displayName(currentUserID: model.user?.id))\"…",
                          text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(runSearch)
                    .onAppear { focused = true }
                if !query.isEmpty {
                    Button {
                        query = ""
                        hits = []
                        hasSearched = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12).padding(.top, 12)

            HStack(spacing: 12) {
                authorMenu
                sortMenu
                Spacer()
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if hasSearched {
                    Text("\(total) result\(total == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 14).padding(.vertical, 8)

            Divider()

            ScrollView {
                if hasSearched && hits.isEmpty && errorText == nil {
                    VStack(spacing: 6) {
                        Image(systemName: "text.magnifyingglass").font(.title2).foregroundStyle(.tertiary)
                        Text("No messages match that search.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 40)
                } else if let errorText {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.tertiary)
                        Text(errorText).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 30)
                } else if !hasSearched {
                    Text("Search this conversation.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.vertical, 30)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(hits) { message in
                            resultRow(message)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 400)
        .task(id: SearchKey(query: query.trimmingCharacters(in: .whitespaces),
                            author: authorFilter, newest: sortNewest)) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            runSearch()
        }
    }

    private var authorMenu: some View {
        Menu {
            Button("Anyone") { authorFilter = nil }
            ForEach(senders) { user in
                Button(name(of: user)) { authorFilter = user.id }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person")
                Text(senderLabel)
            }
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func name(of user: DiscordUser) -> String {
        model.displayName(of: user, inGuild: channel.guildId) ?? user.displayName
    }

    private func authorName(_ author: DiscordUser?) -> String {
        guard let author else { return "Unknown" }
        return name(of: author)
    }

    private var senderLabel: String {
        guard let authorFilter else { return "Anyone" }
        if let user = senders.first(where: { $0.id == authorFilter }) { return name(of: user) }
        return "Someone"
    }

    private var sortMenu: some View {
        Menu {
            Button("Newest first") { sortNewest = true }
            Button("Oldest first") { sortNewest = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                Text(sortNewest ? "Newest" : "Oldest")
            }
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder private func resultRow(_ message: Message) -> some View {
        Button {
            model.selectChannel(channel.id)
            model.scrollTarget = message.id
        } label: {
            HStack(spacing: 10) {
                PresenceAvatar(url: message.author?.avatarURL, name: authorName(message.author),
                               status: model.presences[message.author?.id ?? ""], size: 26,
                               seed: message.author?.id ?? "")
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(authorName(message.author))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let d = message.date {
                            Text(Self.timeFormatter.string(from: d))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Text(message.content.isEmpty ? "Attachment" : message.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.down.left.to.line")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Divider().padding(.leading, 50)
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            hits = []
            hasSearched = false
            isSearching = false
            return
        }
        isSearching = true
        hasSearched = true
        errorText = nil
        Task {
            do {
                let (found, count) = try await model.searchMessages(in: channel, query: q,
                                                                    authorID: authorFilter,
                                                                    descending: sortNewest)
                hits = found
                total = count
                isSearching = false
            } catch {
                Diag.rest("search in \(channel.id) failed: \(error)", .error)
                errorText = error.localizedDescription
                hits = []
                isSearching = false
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"
        return f
    }()
}