import SwiftUI

/// The current guild's sticker sheet, opened from the composer. Picking one
/// sends it as a message via `onSend`. Only available stickers are shown.
struct StickerPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let stickers: [GuildSticker]
    let onSend: (GuildSticker) -> Void

    private var available: [GuildSticker] {
        stickers.filter { $0.available != false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stickers")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .textCase(.uppercase)
            if available.isEmpty {
                Text("This server has no stickers.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                        ForEach(available) { sticker in
                            Button {
                                onSend(sticker)
                                dismiss()
                            } label: {
                                VStack(spacing: 4) {
                                    StickerThumb(item: StickerItem(id: sticker.id, name: sticker.name,
                                                                   formatType: sticker.formatType,
                                                                   packId: nil, isAvailable: true))
                                    Text(sticker.name)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.bouncyRow)
                        }
                    }
                    .padding(2)
                }
            }
        }
        .padding(12)
        .frame(width: 380, height: 340)
    }
}