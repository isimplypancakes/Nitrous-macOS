import SwiftUI

/// A Discord rich embed, rendered as a glass card with the embed's accent
/// stripe. Covers author, title/link, description, fields (inline grouping),
/// image, thumbnail, footer and timestamp.
struct EmbedCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    let embed: Embed

    var body: some View {
        if embed.isMediaOnly || !embed.hasCardContent {
            // Discord shows plain image/gif link previews without a card.
            mediaOnly
        } else {
            card
        }
    }

    // MARK: Card

    private var card: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(embed.accent)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        author
                        title
                        description
                    }
                    Spacer(minLength: 0)
                    thumbnail
                }
                fields
                image
                footer
            }
            .padding(11)
        }
        .frame(maxWidth: 250, alignment: .leading)
        .liquidGlass(cornerRadius: 10)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if let u = embed.url, let url = URL(string: u) { openURL(url) } }

    }

    @ViewBuilder private var author: some View {
        if let a = embed.author, let name = a.name {
            HStack(spacing: 6) {
                if let icon = a.iconUrl, let url = URL(string: icon) {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        .frame(width: 18, height: 18).clipShape(Circle())
                }
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var title: some View {
        if let t = embed.title {
            Text(t)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(embed.url != nil ? Palette.accent : Palette.label)
                .lineLimit(3)
        }
    }

    @ViewBuilder private var description: some View {
        if let d = embed.description, !d.isEmpty {
            Text(DiscordMarkdown.inline(d, model: model, message: nil,
                                        onAccent: false, revealSpoilers: true))
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(12)
        }
    }

    /// Inline fields pack up to three per row, matching Discord's grid.
    @ViewBuilder private var fields: some View {
        if let all = embed.fields, !all.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(rows(of: all).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, f in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name)
                                    .font(.caption.weight(.bold))
                                    .lineLimit(1)
                                Text(DiscordMarkdown.inline(f.value, model: model, message: nil,
                                                            onAccent: false, revealSpoilers: true))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    /// Groups consecutive inline fields into rows of three; non-inline fields
    /// occupy a row on their own.
    private func rows(of fields: [Embed.EmbedField]) -> [[Embed.EmbedField]] {
        var out: [[Embed.EmbedField]] = []
        var current: [Embed.EmbedField] = []
        for f in fields {
            if f.inline == true {
                current.append(f)
                if current.count == 3 { out.append(current); current = [] }
            } else {
                if !current.isEmpty { out.append(current); current = [] }
                out.append([f])
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    @ViewBuilder private var thumbnail: some View {
        if let t = embed.thumbnail, let u = t.url, let url = URL(string: u) {
            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder private var image: some View {
        if let i = embed.image ?? embed.video, let u = i.url, let url = URL(string: u) {
            let box = fit(width: i.width, height: i.height, maxW: 226, maxH: 250)
            AsyncImage(url: url) { phase in
                if let img = phase.image { img.resizable().scaledToFill() }
                else { RoundedRectangle(cornerRadius: 8).fill(.quaternary).overlay(ProgressView()) }
            }
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .center) {
                if embed.video != nil {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(radius: 4)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        let text = embed.footer?.text
        let stamp = embed.date.map { $0.formatted(date: .abbreviated, time: .shortened) }
        if text != nil || stamp != nil {
            HStack(spacing: 6) {
                if let icon = embed.footer?.iconUrl, let url = URL(string: icon) {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        .frame(width: 15, height: 15).clipShape(Circle())
                }
                Text([text, stamp].compactMap { $0 }.joined(separator: " • "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: Media-only previews

    @ViewBuilder private var mediaOnly: some View {
        if let i = embed.image ?? embed.thumbnail ?? embed.video,
           let u = i.url, let url = URL(string: u) {
            let box = fit(width: i.width, height: i.height, maxW: 236, maxH: 260)
            AsyncImage(url: url) { phase in
                if let img = phase.image { img.resizable().scaledToFill() }
                else { RoundedRectangle(cornerRadius: 10).fill(.quaternary).overlay(ProgressView()) }
            }
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { if let u = embed.url, let link = URL(string: u) { openURL(link) } }
    
        }
    }

    /// Reserves aspect-correct space so loading media doesn't reflow the row.
    private func fit(width: Int?, height: Int?, maxW: CGFloat, maxH: CGFloat) -> CGSize {
        guard let w = width, let h = height, w > 0, h > 0 else {
            return CGSize(width: maxW, height: 150)
        }
        let scale = min(maxW / CGFloat(w), maxH / CGFloat(h), 1)
        return CGSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale)
    }
}
