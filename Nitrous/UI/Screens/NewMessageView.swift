import SwiftUI

/// Start a new direct message. Lists people already known to this session
/// (DM partners, message authors, relationships) and opens or creates the DM.
struct NewMessageView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onOpen: (Channel) -> Void

    @State private var search = ""
    @State private var busy: Snowflake?
    @State private var error: String?

    /// Everyone we know about, minus self and bots-with-no-DM value.
    private var people: [DiscordUser] {
        let all = model.usersCache.values.filter { $0.id != model.user?.id }
        let filtered = search.isEmpty ? all : all.filter {
            $0.displayName.localizedCaseInsensitiveContains(search)
                || $0.username.localizedCaseInsensitiveContains(search)
        }
        return filtered.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if people.isEmpty {
                    ContentUnavailableView("No People", systemImage: "person.2",
                        description: Text(search.isEmpty
                            ? "People you share servers or DMs with will appear here."
                            : "No one matches “\(search)”."))
                }
                ForEach(people) { user in
                    Button { open(user) } label: {
                        HStack(spacing: 12) {
                            PresenceAvatar(url: user.avatarURL, name: user.displayName,
                                           status: model.presences[user.id], size: 40, seed: user.id)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.displayName)
                                    .font(.body.weight(.medium)).foregroundStyle(.primary)
                                Text(user.tag).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if busy == user.id { ProgressView() }
                        }
                    }
                    .buttonStyle(.bouncyRow)
                    .glassCard(vertical: 10)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .themedBackground()
            .navigationTitle("New Message")
            .searchable(text: $search, prompt: "Search people")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    /// Reuse an existing DM when there is one, otherwise ask Discord to open it.
    private func open(_ user: DiscordUser) {
        if let existing = model.dmChannels.first(where: {
            $0.type == .dm && $0.participantIDs(excluding: model.user?.id).first == user.id
        }) {
            onOpen(existing)
            return
        }
        guard let rest = model.restClient else { return }
        busy = user.id
        error = nil
        Task {
            do {
                let channel = try await rest.createDM(recipientID: user.id)
                if !model.dmChannels.contains(where: { $0.id == channel.id }) {
                    model.dmChannels.insert(channel, at: 0)
                }
                busy = nil
                onOpen(channel)
            } catch {
                busy = nil
                self.error = error.localizedDescription
            }
        }
    }
}
