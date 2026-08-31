import SwiftUI
import AppKit
import AVKit

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
    var onAuthorTap: (DiscordUser) -> Void = { _ in }

    private var isPending: Bool { message.id.hasPrefix("pending-") }
    private var isTombstone: Bool { message.id.hasPrefix("tomb-") || message.isSystem }

    /// Moderating someone else's message requires a real guild channel — DMs
    /// have no moderation surface, and your own messages belong in the menu
    /// above — plus the signed-in user actually holding mod permissions.
    /// The API stays the final gatekeeper either way.
    private var isModeratable: Bool {
        guard !isPending, !isTombstone,
              let author = message.author,
              author.id != model.user?.id,
              model.channel(with: channelID)?.guildId != nil,
              model.canModerate(in: channelID)
        else { return false }
        return true
    }

    @State private var pendingMod: ModAction?
    @State private var hovered = false
    @State private var viewerItem: MediaViewerItem?
    @State private var showEmojiPicker = false

    /// The guild this channel belongs to, for nickname-aware naming.
    private var guildID: Snowflake? { model.channel(with: channelID)?.guildId }

    /// Name to show for an author in this channel: server nick when available,
    /// otherwise the global display name.
    private func displayName(of author: DiscordUser?) -> String? {
        model.displayName(of: author, inGuild: guildID)
    }

    /// Whether this message calls out the signed-in user: it name-mentions me,
    /// pings everyone, or replies to one of my messages.
    private var isPing: Bool {
        if message.mentionEveryone == true { return true }
        if let me = model.user?.id,
           message.mentions?.contains(where: { $0.id == me }) == true { return true }
        return isReplyToMe
    }

    private var isReplyToMe: Bool {
        guard let me = model.user?.id else { return false }
        return message.referencedMessage?.value?.author?.id == me
    }

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
                        if let author = message.author {
                            HStack(spacing: 8) {
                                Button { onAuthorTap(author) } label: {
                                    AvatarView(url: author.avatarURL,
                                               name: displayName(of: author) ?? "?",
                                               size: 30, seed: author.id)
                                }
                                .buttonStyle(.plain)
                                .help("View \(displayName(of: author) ?? "profile")'s profile")
                                Button { onAuthorTap(author) } label: {
                                    Text(displayName(of: author) ?? "Unknown")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.primary)
                                }
                                .buttonStyle(.plain)
                                .help("View \(displayName(of: author) ?? "profile")'s profile")
                            }
                            .contextMenu { authorContextMenu(author) }
                        } else {
                            Text("Unknown")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.primary)
                        }
                        if message.author?.bot == true {
                            Text("BOT").font(.system(size: 9, weight: .heavy))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(Brand.onAccent)
                        }
                        if let author = message.author {
                            GuildTagPill(user: author)
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
                .onHover { hovered = $0 }
                .animation(.snappy(duration: 0.18), value: hovered)
                // Quick actions float in the empty gutters on either side, so
                // they never cover the bubble text (Discord/Chat-reply style).
                .overlay(alignment: mine ? .leading : .trailing) {
                    if hovered && !isPending { quickActions }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, showHeader ? 14 : 2)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .background {
                // Attention grabber: an accent wash across the whole row (and a
                // small pill, see above) when the message calls out the reader.
                if isPing {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Palette.accent.opacity(0.11))
                }
            }
            .contextMenu { menuItems }
            .confirmationDialog(dialogTitle,
                                isPresented: Binding(
                                    get: { pendingMod != nil },
                                    set: { if !$0 { pendingMod = nil } }),
                                titleVisibility: .visible,
                                presenting: pendingMod) { mod in
                Button(mod.primaryTitle, role: .destructive) { perform(mod) }
                Button("Cancel", role: .cancel) { pendingMod = nil }
            } message: { mod in
                Text(dialogMessage(for: mod))
            }
            .sheet(item: $viewerItem) { MediaViewer(item: $0) }
            .sheet(isPresented: $showEmojiPicker) {
                EmojiPickerView(guildEmojis: currentGuildEmojis) { pick in react(pick) }
            }
        }
    }

    private enum ModAction: Identifiable, Equatable {
        case deleteMessage
        case timeout(hours: Int)
        case kick
        case ban
        case purge

        var id: String {
            switch self {
            case .deleteMessage: return "delete-message"
            case .timeout(let h): return "timeout-\(h)"
            case .kick: return "kick"
            case .ban: return "ban"
            case .purge: return "purge"
            }
        }
        var primaryTitle: String {
            switch self {
            case .deleteMessage: return "Delete Message"
            case .timeout: return "Time Out"
            case .kick: return "Kick"
            case .ban: return "Ban"
            case .purge: return "Delete"
            }
        }
    }

    private var dialogTitle: String {
        switch pendingMod {
        case .deleteMessage: return "Delete \(name)'s message?"
        case .timeout(let h): return "Time out \(name) for \(h) hour\(h == 1 ? "" : "s")?"
        case .kick: return "Kick \(name) from this server?"
        case .ban: return "Ban \(name) from this server?"
        case .purge: return "Delete messages up to here?"
        case nil: return ""
        }
    }

    private var name: String { message.author?.displayName ?? "this member" }

    private func dialogMessage(for mod: ModAction) -> String {
        switch mod {
        case .deleteMessage:
            return "This removes the message from the channel for everyone. This can't be undone."
        case .timeout:
            return "They'll be unable to send messages in any channel, pinned to the server, for the duration."
        case .kick:
            return "They'll be removed from this server. They can rejoin with a new invite."
        case .ban:
            return "They'll be permanently removed, and their messages from the last 7 days deleted."
        case .purge:
            let list = model.messagesByChannel[channelID] ?? []
            if let idx = list.firstIndex(where: { $0.id == message.id }) {
                let n = list[idx...].count(where: { !($0.isSystem || $0.id.hasPrefix("tomb-")) })
                return n == 0 ? "Nothing left to delete." : "This deletes \(n) message\(n == 1 ? "" : "s") in this channel."
            }
            return "This deletes every message in this channel from the latest one up to and including this one."
        }
    }

    private func perform(_ mod: ModAction) {
        defer { pendingMod = nil }
        guard let author = message.author else { return }
        switch mod {
        case .deleteMessage: model.deleteMessage(message, in: channelID)
        case .timeout(let h): model.timeout(author.id, in: channelID, for: h)
        case .kick: model.kick(author.id, from: channelID)
        case .ban: model.ban(author.id, from: channelID, deleteDays: 7)
        case .purge: model.purgeUpTo(message.id, in: channelID)
        }
    }

    @ViewBuilder private var bubble: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            // Slash-command messages carry no visible app tag otherwise — a
            // muted "App /command" line reads exactly like Discord's.
            if let cmd = message.interaction?.name, !cmd.isEmpty { interactionLine(cmd) }
            splitBubble
            // A message that spawned a thread shows a tappable preview of it.
            if let thread = message.thread { threadPreview(thread) }
        }
        .opacity(isPending ? 0.6 : 1)
        .frame(maxWidth: 520, alignment: mine ? .trailing : .leading)
    }

    private func interactionLine(_ cmd: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold))
            Text("/\(cmd)").font(.caption.weight(.semibold))
        }
        .foregroundStyle(Palette.accent)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Palette.accent.opacity(0.12), in: Capsule())
    }

    private func threadPreview(_ thread: Channel) -> some View {
        Button { model.selectChannel(thread.id) } label: {
            HStack(spacing: 7) {
                Image(systemName: "number").font(.footnote).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.name ?? "Thread").font(.subheadline.weight(.medium)).lineLimit(1)
                    if let topic = thread.topic, !topic.isEmpty {
                        Text(topic).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 340, alignment: .leading)
    }

    private var contentMedia: [URL] { MediaLink.mediaURLs(in: message.content) }
    private var caption: String { MediaLink.stripped(message.content, of: contentMedia) }
    private var hasInlineMedia: Bool { !contentMedia.isEmpty }

    /// Media is pulled into its own capsule so a caption reads as a separate
    /// message, exactly like Discord splits text + upload.
    @ViewBuilder private var splitBubble: some View {
        if hasInlineMedia {
            VStack(alignment: .leading, spacing: 5) {
                if !caption.isEmpty { capsule { textSlice(caption) } }
                capsule { mediaCapsule }
            }
        } else {
            // Single capsule: text then its attachments/embeds, as before.
            capsule {
                VStack(alignment: .leading, spacing: 1) {
                    textSlice(caption)
                    attachments
                    embeds()
                    stickers
                }
            }
        }
    }

    @ViewBuilder private var mediaCapsule: some View {
        VStack(alignment: .leading, spacing: 6) {
            mediaGallery(contentMedia)
            attachments
            embeds(deduping: contentMedia)
            stickers
        }
    }

    /// Sticker attachments. Sticker-only messages are mostly empty *except*
    /// this, so the capsule must still grow to hold a big one.
    @ViewBuilder private var stickers: some View {
        if let items = message.stickerItems, !items.isEmpty {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(items) { item in
                    StickerThumb(item: item)
                }
            }
            .padding(.top, stickerOnly ? 4 : 6)
            .padding(.horizontal, stickerOnly ? -2 : 0)
        }
    }

    private var stickerOnly: Bool {
        !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && !messageHasMedia
    }

    private var messageHasMedia: Bool {
        guard let atts = message.attachments, !atts.isEmpty else { return false }
        return atts.contains { att in
            guard let url = URL(string: att.url) else { return false }
            return MediaLink.urlIsMedia(url)
        }
    }

    /// One glass container: padding + bubble fill + text color. Encapsulates
    /// the iMessage capsule so split bubbles look like separate messages.
    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(BubbleGlass(mine: mine))
            // Both sides share the same neutral glass now, so both use the
            // standard label color — no dark-on-Accent ink in dark mode.
            .foregroundStyle(Palette.label)
    }

    @ViewBuilder private func textSlice(_ caption: String) -> some View {
        if !caption.isEmpty {
            // `.textSelection(.enabled)` routes right-clicks to the field's
            // own select/copy menu on macOS and makes the message context menu
            // unreliable ("half the time nothing happens"). Copy lives in the
            // context menu; selection was the trade-off, and it cost the menu.
            MarkdownContent(text: caption, onAccent: false)
            if message.editedTimestamp != nil {
                Text("(edited)")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    @ViewBuilder private func mediaGallery(_ urls: [URL]) -> some View {
        ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
            if MediaLink.isVideo(url) {
                VideoAttachmentView(url: url, title: url.lastPathComponent)
            } else {
                Button {
                    viewerItem = MediaViewerItem(url: url, isGIF: MediaLink.isGIF(url), title: nil)
                } label: {
                    Group {
                        if MediaLink.isGIF(url) {
                            GIFImage(url: url, maxWidth: 400)
                        } else {
                            AsyncImage(url: url) { phase in
                                if let img = phase.image {
                                    img.resizable().scaledToFit()
                                } else {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(.quaternary)
                                        .overlay(ProgressView())
                                }
                            }
                            .frame(maxWidth: 400, maxHeight: 320)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var attachments: some View {
        if let atts = message.attachments, !atts.isEmpty {
            ForEach(atts) { att in
                if att.isVideo, let url = att.mediaURL {
                    VideoAttachmentView(url: url, title: att.filename)
                } else if att.isImage, let url = att.mediaURL {
                    // Reserve the final size up front (from the attachment's own
                    // width/height) so the row doesn't reflow — and the scroll
                    // position doesn't jump — when the image finishes loading.
                    let size = imageBox(for: att)
                    if att.filename.uppercased().hasPrefix("SPOILER_") {
                        SpoilerMediaAttachment(url: url, isGIF: MediaLink.isGIF(url), size: size)
                    } else {
                        Button {
                            viewerItem = MediaViewerItem(url: url, isGIF: MediaLink.isGIF(url), title: att.filename)
                        } label: {
                            Group {
                                if MediaLink.isGIF(url) {
                                    // Animated GIF attachments (including GIFs sent
                                    // from the picker, which upload as .gif files)
                                    // play through our frame animator.
                                    GIFImage(url: url, maxWidth: size.width)
                                } else {
                                    AsyncImage(url: url) { phase in
                                        if let img = phase.image {
                                            img.resizable().scaledToFill()
                                        } else {
                                            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                                                .overlay(ProgressView())
                                        }
                                    }
                                }
                            }
                            .frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                } else if let url = att.mediaURL ?? URL(string: att.proxyUrl ?? "") {
                    Button { saveRemoteFile(url: url, filename: att.filename) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.fill").font(.body)
                            Text(att.filename).font(.subheadline).lineLimit(1)
                            Image(systemName: "arrow.down.circle")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Save \(att.filename)")
                }
            }
        }
    }

    /// Fits an image attachment into a max box while keeping its aspect ratio,
    /// so the placeholder and the loaded image occupy identical space.
    private func imageBox(for att: Attachment) -> CGSize {
        let maxW: CGFloat = 420, maxH: CGFloat = 420
        guard let w = att.width, let h = att.height, w > 0, h > 0 else {
            return CGSize(width: maxW, height: 240)
        }
        let scale = min(maxW / CGFloat(w), maxH / CGFloat(h), 1)
        return CGSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale)
    }

    @ViewBuilder private func embeds(deduping contentMedia: [URL] = []) -> some View {
        if let embeds = message.embeds, !embeds.isEmpty {
            // A message whose content carries the media URL also gets a link
            // embed server-side — skip embeds that duplicate what we already
            // rendered inline so a sent GIF never shows twice.
            let filtered = embeds.filter { embed in
                guard let raw = embed.url ?? embed.image?.url, let url = URL(string: raw) else { return true }
                return !contentMedia.contains(url)
            }
            if !filtered.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(filtered.enumerated()), id: \.offset) { _, embed in
                        EmbedCard(embed: embed)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var replyPreview: some View {
        Button {
            if let id = message.referencedMessage?.value?.id { model.jump(to: id) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 9))
                Text(displayName(of: message.referencedMessage?.value?.author) ?? "")
                    .font(.caption.weight(.semibold))
                Text(message.referencedMessage?.value?.content ?? "")
                    .font(.caption).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
    }

    /// Discord-style hover bar: Reply + quick reacts, floated in the empty gutter
    /// on the leading side (own messages) or trailing side (others) so it never
    /// covers the bubble text. The ⋯ exposes the full action sheet (copy, edit,
    /// moderation) one click anywhere makes discoverable — no right-click hunts.
    private var quickActions: some View {
        HStack(spacing: 6) {
            BubbleBarButton(icon: "arrowshape.turn.up.left", help: "Reply") {
                model.beginReply(to: message, in: channelID)
            }
            ForEach(["❤️", "👍", "😂", "🔥"], id: \.self) { e in
                BubbleBarButton(emoji: e, help: "React \(e)") {
                    model.toggleReaction(message: message, emoji: Emoji(id: nil, name: e), on: channelID)
                }
            }
            BubbleBarButton(icon: "plus.circle", help: "More reactions") {
                showEmojiPicker = true
            }
            Menu { menuItems } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
        // The bar floats outside the row's hover zone in the gutter; keep it
        // alive while the pointer is over it so it can't vanish mid-click.
        .onHover { hovered = $0 }
        .contextMenu { menuItems }
    }

    /// The emoji of the guild this bubble belongs to, for the reaction picker.
    private var currentGuildEmojis: [Emoji] {
        guard let gid = model.channel(with: channelID)?.guildId else { return [] }
        return model.guilds.first { $0.id == gid }?.emojis ?? []
    }

    private func react(_ emoji: Emoji) {
        model.toggleReaction(message: message, emoji: emoji, on: channelID)
    }

    private var messageLink: String {
        let guild = model.channel(with: channelID)?.guildId ?? "@me"
        return "https://discord.com/channels/\(guild)/\(channelID)/\(message.id)"
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
        .frame(maxWidth: 510, alignment: mine ? .trailing : .leading)
    }

    /// Right-click on a member's name/avatar in the message header: profile and
    /// copy shortcuts, plus moderation (timeout / kick / ban / purge-to-here)
    /// when the signed-in user holds permissions in this server.
    @ViewBuilder private func authorContextMenu(_ author: DiscordUser) -> some View {
        Button { onAuthorTap(author) } label: {
            Label("View Profile", systemImage: "person.crop.circle")
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(author.id, forType: .string)
        } label: {
            Label("Copy User ID", systemImage: "number")
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("https://discord.com/users/\(author.id)", forType: .string)
        } label: {
            Label("Copy Profile Link", systemImage: "link")
        }
        if model.canModerate(in: channelID), author.id != model.user?.id {
            Divider()
            Menu {
                ForEach([1, 24, 168], id: \.self) { hours in
                    Button("\(hours) Hour\(hours == 1 ? "" : "s")") { pendingMod = .timeout(hours: hours) }
                }
                Divider()
                Button(role: .destructive) { pendingMod = .kick } label: { Label("Kick", systemImage: "person.fill.xmark") }
                Button(role: .destructive) { pendingMod = .ban } label: { Label("Ban", systemImage: "person.badge.minus") }
            } label: {
                Label("Moderate", systemImage: "gavel")
            }
            Button(role: .destructive) { pendingMod = .purge } label: {
                Label("Delete Up to Here", systemImage: "arrow.up.trash")
            }
        }
    }

    /// The full per-message action sheet, shared between the right-click
    /// context menu and the ⋯ button on the hover bar — so moderation can never
    /// be hiding in a place you wouldn't think to look.
    @ViewBuilder private var menuItems: some View {
        Button { model.beginReply(to: message, in: channelID) } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        ForEach(["❤️", "👍", "😂", "🔥"], id: \.self) { e in
            Button { model.toggleReaction(message: message, emoji: Emoji(id: nil, name: e), on: channelID) } label: {
                Text("React \(e)")
            }
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
        } label: {
            Label("Copy Text", systemImage: "doc.on.doc")
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.id, forType: .string)
        } label: {
            Label("Copy ID", systemImage: "number")
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(messageLink)", forType: .string)
        } label: {
            Label("Copy Link", systemImage: "link")
        }
        if let att = message.attachments?.first, let url = att.mediaURL {
            Button { saveRemoteFile(url: url, filename: att.filename) } label: {
                Label("Save Attachment…", systemImage: "square.and.arrow.down")
            }
        }
        if isModeratable {
            Divider()
            Button(role: .destructive) { pendingMod = .deleteMessage } label: {
                Label("Delete Message", systemImage: "trash")
            }
            Menu {
                ForEach([1, 24, 168], id: \.self) { hours in
                    Button("\(hours) Hour\(hours == 1 ? "" : "s")") { pendingMod = .timeout(hours: hours) }
                }
                Divider()
                Button(role: .destructive) { pendingMod = .kick } label: { Label("Kick", systemImage: "person.fill.xmark") }
                Button(role: .destructive) { pendingMod = .ban } label: { Label("Ban", systemImage: "person.badge.minus") }
            } label: {
                Label("Moderate", systemImage: "gavel")
            }
            Button(role: .destructive) {
                pendingMod = .purge
            } label: {
                Label("Delete Up to Here", systemImage: "arrow.up.trash")
            }
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
        Text("\(displayName(of: message.author) ?? "Someone") \(message.content)")
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
    }
}

/// Downloads an attachment's bytes after the user picks where (native
/// NSSavePanel). Shared by the attachment buttons and the context menu.
/// Main-actor safe: the panel runs there; the network fetch is off-thread.
@MainActor
func saveRemoteFile(url: URL, filename: String) {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = filename
    let response = panel.runModal()
    guard response == .OK, let dest = panel.url else { return }
    Task {
        do {
            Diag.app("saving \(filename): GET \(url.absoluteString)")
            let (data, _) = try await URLSession.shared.data(from: url)
            try data.write(to: dest)
            Diag.app("saved \(filename) (\(data.count) bytes)")
            NSSound.beep()
        } catch {
            Diag.app("failed to save \(filename): \(error.localizedDescription)", .error)
        }
    }
}

/// An inline video player for mp4/mov attachments and pasted video URLs.
/// Muted, click-to-play — the system controller brings playback controls.
/// Wraps AppKit's `AVPlayerView`; SwiftUI's `VideoPlayer` bridge crashes
/// (SIGABRT in `_AVKit_SwiftUI` metadata init), so it's deliberately avoided.
struct VideoAttachmentView: View {
    let url: URL
    let title: String
    /// GIF-style embeds auto-play muted and loop, matching how Discord shows
    /// a gifv/mp4 sent through the built-in GIF picker.
    var autoLoop = false
    @State private var player: AVPlayer?

    private static let aspect: CGFloat = 16.0 / 9.0

    var body: some View {
        Group {
            if let player {
                if autoLoop {
                    NativeVideoPlayer(player: player, autoLoop: true)
                        .onAppear {
                            player.isMuted = true
                            player.play()
                        }
                } else {
                    NativeVideoPlayer(player: player)
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary)
                    Button {
                        let p = AVPlayer(url: url)
                        p.isMuted = autoLoop
                        player = p
                        if autoLoop { p.play() }
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Palette.accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Play \(title)")
                }
            }
        }
        .frame(maxWidth: 560, maxHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            Button { saveRemoteFile(url: url, filename: title) } label: {
                Label("Save Video…", systemImage: "square.and.arrow.down")
            }
        }
    }
}

/// AppKit-hosted player view. Kept dumb on purpose — a loop observer for
/// GIF-style embeds is the only customization.
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    var autoLoop = false

    func makeCoordinator() -> Coordinator { Coordinator(player, autoLoop) }

    final class Coordinator: NSObject {
        let player: AVPlayer
        let autoLoop: Bool
        private var observer: NSObjectProtocol?

        init(_ player: AVPlayer, _ autoLoop: Bool) {
            self.player = player
            self.autoLoop = autoLoop
            super.init()
        }

        func installLoop() {
            guard autoLoop, observer == nil, let item = player.currentItem else { return }
            let name = AVPlayerItem.didPlayToEndTimeNotification
            observer = NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) {
                [weak self] _ in
                guard let self else { return }
                self.player.seek(to: .zero) { _ in self.player.play() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        context.coordinator.installLoop()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

/// A `SPOILER_`-prefixed image attachment: blurred and locked until tapped,
/// then it renders normally. Matches Discord's blur-squint-reveal behaviour.
struct SpoilerMediaAttachment: View {
    let url: URL
    let isGIF: Bool
    let size: CGSize
    @State private var revealed = false

    var body: some View {
        ZStack {
            Group {
                if isGIF {
                    GIFImage(url: url, maxWidth: size.width)
                } else {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                        }
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .blur(radius: revealed ? 0 : 26)

            if !revealed {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.72))
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "eye.slash")
                                .font(.title2).foregroundStyle(.secondary)
                            Text("Spoiler")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.22)) { revealed = true }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .compositingGroup()
    }
}

/// One small round button used by the hover quick-actions bar.
struct BubbleBarButton: View {
    var icon: String?
    var emoji: String?
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let icon {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            }
            if let emoji {
                Text(emoji).font(.system(size: 12))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
        .help(help)
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
    /// Same neutral glass for both sides — the accent-tinted rim used to ring
    /// out around photos (their corner radius is smaller than the bubble's),
    /// which read as a mismatch. First-party look wins.
    func body(content: Content) -> some View {
        content.liquidGlass(cornerRadius: 18)
    }
}

/// iMessage-style animated "typing" indicator bubble.
struct TypingBubble: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in TypingDot(index: i) }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .liquidGlass(cornerRadius: 18)
    }
}

/// A single dot in a typing indicator. Each dot runs its own staggered spring,
/// so a trio ripples like the real Messages bubble instead of pulsing in sync.
struct TypingDot: View {
    let index: Int
    @State private var lifted = false

    var body: some View {
        Circle().fill(Color.secondary)
            .frame(width: 7, height: 7)
            .scaleEffect(lifted ? 1.25 : 0.65)
            .opacity(lifted ? 1 : 0.35)
            .onAppear {
                withAnimation(
                    .spring(response: 0.3, dampingFraction: 0.55)
                        .delay(Double(index) * 0.16)
                        .repeatForever(autoreverses: true)
                ) { lifted = true }
            }
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

/// A sticker inside a message bubble. Format 4 is a real GIF (animated); the
/// rest are PNG/APNG/LOTTIE, which the CDN serves as a PNG still. Sticker-only
/// messages grow it large, otherwise it sits as a row beneath the text.
struct StickerThumb: View {
    let item: StickerItem
    var large = false

    private var size: CGFloat { large ? 160 : 64 }

    var body: some View {
        Group {
            if let url = item.imageURL {
                if item.formatType == 4 {
                    GIFImage(url: url, maxWidth: size)
                } else {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else if phase.error != nil {
                            placeholder
                        } else {
                            placeholder.overlay(ProgressView().controlSize(.small))
                        }
                    }
                    .frame(width: size, height: size)
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .help(item.name ?? "Sticker")
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "face.smiling").foregroundStyle(.secondary))
    }
}