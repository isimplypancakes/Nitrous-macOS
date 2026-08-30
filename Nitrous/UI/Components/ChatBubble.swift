import SwiftUI

/// A single message as an iMessage-style bubble. `mine` right-aligns and tints;
/// otherwise it's a neutral bubble on the left with an optional avatar + name
/// (shown only for the first message in a group, in multi-party channels).
struct ChatBubble: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var model: AppModel
    let message: Message
    let mine: Bool
    let showHeader: Bool       // first in a group: show name/avatar
    let showAvatar: Bool       // multi-party context
    let channelID: Snowflake

    private var isPending: Bool { message.id.hasPrefix("pending-") }
    @State private var swipe: CGFloat = 0

    /// Time shown beside the sender's name.
    static let headerTime: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    var body: some View {
        if message.isSystem {
            systemLine
        } else {
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                // Sender header: avatar, name and time on their own row so it
                // is unmistakable who is speaking. Shown for everyone else's
                // messages at the start of each group, in DMs as well.
                if showHeader && !mine {
                    HStack(spacing: 8) {
                        AvatarView(url: message.author?.avatarURL,
                                   name: message.author?.displayName ?? "?",
                                   size: 30, seed: message.author?.id ?? "")
                        Text(message.author?.displayName ?? "Unknown")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                        if message.author?.bot == true {
                            Text("BOT").font(.system(size: 9, weight: .heavy))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.white)
                        }
                        if let d = message.date {
                            Text(Self.headerTime.string(from: d))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }

                HStack(alignment: .bottom, spacing: 8) {
                    if mine { Spacer(minLength: 40) }
                    VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                        if message.isReply { replyPreview }
                        bubble
                        if let reacts = message.reactions, !reacts.isEmpty {
                            reactions(reacts)
                        }
                    }
                    if !mine { Spacer(minLength: 40) }
                }
                // Indent the bubbles so they line up under the sender's name.
                .padding(.leading, mine ? 0 : 38)
            }
            .padding(.horizontal, 12)
            .padding(.top, showHeader ? 14 : 2)
            .offset(x: swipe)
            .overlay(alignment: mine ? .leading : .trailing) {
                // Reply affordance revealed by the swipe.
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.accent)
                    .opacity(Double(min(abs(swipe) / 44, 1)))
                    .padding(.horizontal, 12)
            }
            // simultaneousGesture, not gesture: an exclusive drag recognizer
            // swallows the long-press that opens the context menu, which made
            // Reply/Edit/Delete/Copy unreachable.
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { v in
                        // Swipe toward the centre of the screen, iMessage-style.
                        let dx = mine ? min(0, v.translation.width) : max(0, v.translation.width)
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        swipe = max(-60, min(60, dx))
                    }
                    .onEnded { _ in
                        if abs(swipe) > 44 {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            model.beginReply(to: message, in: channelID)
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { swipe = 0 }
                    }
            )
            .contextMenu { contextMenu }
        }
    }

    @ViewBuilder private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.content.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    MarkdownContent(message: message, onAccent: mine)
                    if message.editedTimestamp != nil {
                        Text("(edited)")
                            .font(.caption2)
                            .foregroundStyle(mine ? Brand.onAccent.opacity(0.65) : Color.secondary)
                    }
                }
            }
            attachments
            embeds
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(BubbleGlass(mine: mine))
        .foregroundStyle(mine ? Palette.bubbleMineText : Palette.bubbleOtherText)
        .opacity(isPending ? 0.6 : 1)
        .frame(maxWidth: 268, alignment: mine ? .trailing : .leading)
    }

    @ViewBuilder private var attachments: some View {
        if let atts = message.attachments, !atts.isEmpty {
            ForEach(atts) { att in
                if att.isImage, let url = att.mediaURL {
                    // Reserve the final size up front (from the attachment's own
                    // width/height) so the row doesn't reflow — and the scroll
                    // position doesn't jump — when the image finishes loading.
                    let size = imageBox(for: att)
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                                .overlay(ProgressView())
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Label(att.filename, systemImage: "doc.fill")
                        .font(.subheadline).lineLimit(1)
                }
            }
        }
    }

    /// Fits an image attachment into a max box while keeping its aspect ratio,
    /// so the placeholder and the loaded image occupy identical space.
    private func imageBox(for att: Attachment) -> CGSize {
        let maxW: CGFloat = 236, maxH: CGFloat = 290
        guard let w = att.width, let h = att.height, w > 0, h > 0 else {
            return CGSize(width: maxW, height: 180)
        }
        let scale = min(maxW / CGFloat(w), maxH / CGFloat(h), 1)
        return CGSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale)
    }

    @ViewBuilder private var embeds: some View {
        if let embeds = message.embeds, !embeds.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(embeds.enumerated()), id: \.offset) { _, embed in
                    EmbedCard(embed: embed)
                }
            }
            .padding(.top, 2)
        }
    }

    private var replyPreview: some View {
        Button {
            if let id = message.referencedMessage?.value?.id { model.jump(to: id) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 9))
                Text(message.referencedMessage?.value?.author?.displayName ?? "")
                    .font(.caption.weight(.semibold))
                Text(message.referencedMessage?.value?.content ?? "")
                    .font(.caption).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
    }

    private func reactions(_ reacts: [Reaction]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(reacts.enumerated()), id: \.offset) { _, r in
                Button { model.toggleReaction(message: message, emoji: r.emoji, on: channelID) } label: {
                    HStack(spacing: 4) {
                        if let name = r.emoji.name, r.emoji.id == nil { Text(name).font(.footnote) }
                        else { AsyncImage(url: r.emoji.imageURL) { $0.resizable().scaledToFit() } placeholder: { Color.clear }.frame(width: 15, height: 15) }
                        Text("\(r.count)").font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .modifier(ReactionGlass(mine: r.me))
                    .foregroundStyle(r.me ? Palette.accent : Color.secondary)
                }
                .buttonStyle(.bouncy)
            }
        }
        .frame(maxWidth: 258, alignment: mine ? .trailing : .leading)
    }

    @ViewBuilder private var contextMenu: some View {
        Button { model.beginReply(to: message, in: channelID) } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        ForEach(["❤️", "👍", "😂", "🔥"], id: \.self) { e in
            Button { model.toggleReaction(message: message, emoji: Emoji(id: nil, name: e), on: channelID) } label: {
                Text("React \(e)")
            }
        }
        Button { UIPasteboard.general.string = message.content } label: {
            Label("Copy Text", systemImage: "doc.on.doc")
        }
        if model.isMine(message) {
            Button { model.beginEdit(message, in: channelID) } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) { model.deleteMessage(message, in: channelID) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var systemLine: some View {
        Text("\(message.author?.displayName ?? "Someone") \(message.content)")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
    }
}

/// Applies the right glass treatment to a bubble depending on who sent it.
private struct ReactionGlass: ViewModifier {
    let mine: Bool
    func body(content: Content) -> some View {
        if mine { content.liquidGlass(tint: Palette.accent, cornerRadius: 20) }
        else { content.liquidGlass(cornerRadius: 20) }
    }
}

private struct BubbleGlass: ViewModifier {
    let mine: Bool
    func body(content: Content) -> some View {
        if mine { content.liquidGlassAccent(cornerRadius: 18) }
        else { content.liquidGlass(cornerRadius: 18) }
    }
}

/// iMessage-style animated "typing" bubble.
struct TypingBubble: View {
    @State private var t = 0.0
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle().fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(t == Double(i) ? 1 : 0.35)
                    .scaleEffect(t == Double(i) ? 1.0 : 0.8)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .liquidGlass(cornerRadius: 18)
        .onAppear { withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: false)) { t = 2 } }
    }
}

/// Centered day separator, Messages-style.
struct DaySeparator: View {
    let date: Date
    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }
    private var label: String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }
}
