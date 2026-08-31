import SwiftUI

/// Searchable sheet of emoji for reactions and the composer: the current
/// guild's custom emoji first, then every emoji in the shortcode table.
/// Selecting one calls `onPick` with the emoji and dismisses.
struct EmojiPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var guildEmojis: [Emoji] = []
    let onPick: (Emoji) -> Void

    private var q: String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var customCandidates: [Emoji] {
        guard !q.isEmpty else { return guildEmojis }
        return guildEmojis.filter {
            ($0.name ?? "").contains(q) || ($0.id ?? "").contains(q)
        }
    }

    private var unicodeCandidates: [(shortcode: String, emoji: String)] {
        guard !q.isEmpty else { return EmojiShortcodes.all }
        return EmojiShortcodes.all.filter {
            $0.shortcode.contains(q) || $0.emoji.contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search emoji…", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if customCandidates.isEmpty && unicodeCandidates.isEmpty {
                        Text("No matches")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    if !customCandidates.isEmpty {
                        Text("This server")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 2)], spacing: 2) {
                            ForEach(customCandidates, id: \.identifiableID) { emoji in
                                Button {
                                    onPick(emoji)
                                    dismiss()
                                } label: {
                                    if let url = emoji.imageURL {
                                        AsyncImage(url: url) { phase in
                                            if let img = phase.image {
                                                img.resizable().scaledToFit()
                                            } else {
                                                Color.clear
                                            }
                                        }
                                        .frame(width: 22, height: 22)
                                        .frame(width: 40, height: 40)
                                    } else {
                                        Text(emoji.name ?? "?").font(.system(size: 20))
                                            .frame(width: 40, height: 40).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .help(":\(emoji.name ?? "emoji"):")
                            }
                        }
                    }
                    Text("Emoji")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 2)], spacing: 2) {
                        ForEach(unicodeCandidates, id: \.shortcode) { item in
                            Button {
                                onPick(Emoji(id: nil, name: item.emoji))
                                dismiss()
                            } label: {
                                Text(item.emoji)
                                    .font(.system(size: 22))
                                    .frame(width: 40, height: 40)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(":\(item.shortcode):")
                        }
                    }
                }
                .padding(4)
            }
        }
        .padding(12)
        .frame(width: 320, height: 380)
    }
}