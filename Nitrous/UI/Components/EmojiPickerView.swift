import SwiftUI

/// Searchable sheet of every emoji in the shortcode table, for reactions.
/// Selecting one calls `onPick` with the unicode emoji and dismisses.
struct EmojiPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let onPick: (String) -> Void

    private var candidates: [(shortcode: String, emoji: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 2)], spacing: 2) {
                    ForEach(candidates, id: \.shortcode) { item in
                        Button {
                            onPick(item.emoji)
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
                .padding(4)
            }
        }
        .padding(12)
        .frame(width: 320, height: 380)
    }
}