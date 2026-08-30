import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The conversation: grouped iMessage-style bubbles, day separators, a typing
/// bubble, and a native composer pinned at the bottom. On macOS the member
/// roster is an `.inspector`, and Return sends while Shift+Return inserts a
/// newline — Messages.app muscle memory.
struct ChatView: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var model: AppModel
    let channel: Channel

    @State private var text = ""
    @State private var lastTyping = Date.distantPast
    @State private var highlighted: Snowflake?
    @FocusState private var composerFocused: Bool

    private var messages: [Message] { model.messagesByChannel[channel.id] ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    if model.loadingChannels.contains(channel.id) && messages.isEmpty {
                        ProgressView().padding(.top, 40)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if let sep = daySeparator(at: index) { DaySeparator(date: sep).transition(.opacity) }
                        ChatBubble(message: message,
                                   mine: message.author?.id == model.user?.id,
                                   showHeader: startsGroup(at: index),
                                   showAvatar: channel.guildId != nil,
                                   channelID: channel.id,
                                   onAuthorTap: { profileUser = $0 })
                            .id(message.id)
                            .transition(.asymmetric(insertion: .push(from: .bottom), removal: .opacity))
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Palette.accent.opacity(highlighted == message.id ? 0.28 : 0))
                                    .padding(.horizontal, 6)
                            )
                    }
                    Color.clear.frame(height: 8).id("BOTTOM")
                }
                .padding(.bottom, 6)
                // New-bottom-message arrivals animate in; "Load earlier" prepends
                // leave the last id unchanged and snap into place instead.
                .animation(.snappy(duration: 0.28), value: messages.last?.id)
            }
            .themedBackground(grouped: false)
            .scrollDismissesKeyboard(.interactively)
            // Follow only genuinely-new messages at the bottom. Keying on count
            // would also fire when older history is prepended ("Load earlier"),
            // yanking the view to the bottom mid-read.
            .onChange(of: messages.last?.id) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
            .onAppear {
                model.selectChannel(channel.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
            // Switching conversation re-anchors to the latest message. Keyed on
            // selection so cached channels that keep their view identity still
            // land on the newest message instead of the first.
            .onChange(of: model.selectedChannelID) {
                guard model.selectedChannelID == channel.id else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                }
            }
            .onChange(of: model.scrollTarget) {
                guard let target = model.scrollTarget else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .center) }
                withAnimation(.easeIn(duration: 0.15)) { highlighted = target }
                Haptics.tap()
                // Hold the highlight long enough to actually be seen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                    withAnimation(.easeOut(duration: 0.4)) { highlighted = nil }
                    model.scrollTarget = nil
                }
            }
        }
        .navigationTitle(model.displayName(for: channel))
        .toolbar {
            if AppModel.messageLoggingEnabled {
                ToolbarItem(placement: .automatic) {
                    Button { showRecents = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .help("Message log in this channel")
                }
            }
            // Search works in every conversation — DMs go through the channel
            // search endpoint, guild channels filter by `channel_id`.
            ToolbarItem(placement: .automatic) {
                Button { showChannelSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search this channel (⌘F)")
                .keyboardShortcut("f", modifiers: [.command])
                .popover(isPresented: $showChannelSearch, arrowEdge: .bottom) {
                    ChannelSearchView(channel: channel)
                }
            }
            if channel.guildId != nil {
                ToolbarItem(placement: .automatic) {
                    Button {
                        model.memberPanelGuild = channel.guildId
                        model.showMembersPanel.toggle()
                    } label: {
                        Image(systemName: "person.2.fill")
                    }
                    .help("Members (⌘M)")
                    .keyboardShortcut("m", modifiers: [.command])
                }
            }
        }
        .sheet(isPresented: $showRecents) {
            RecentActivityView(channel: channel)
                .frame(minWidth: 380, minHeight: 460)
        }
        .sheet(item: $profileUser) { user in
            UserProfileView(user: user, guildID: channel.guildId)
        }
        .popover(isPresented: $showGIFPicker, arrowEdge: .bottom) {
            GIFPickerView(channel: channel)
        }
        .popover(isPresented: $showEmojiPicker, arrowEdge: .bottom) {
            EmojiPickerView { emoji in insertEmojiFromPicker(emoji) }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.image, .pdf, .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { stage(urls) }
        }
        .onChange(of: model.editing[channel.id]?.id) {
            if let editing = model.editing[channel.id] {
                text = editing.content
                composerFocused = true
            }
        }
        .onChange(of: model.replyingTo[channel.id]?.id) {
            if model.replyingTo[channel.id] != nil { composerFocused = true }
        }
        .animation(.snappy(duration: 0.22), value: model.replyingTo[channel.id]?.id)
        .animation(.snappy(duration: 0.22), value: model.editing[channel.id]?.id)
        .inspector(isPresented: $model.showMembersPanel) {
            MemberListSidebar(guildID: model.memberPanelGuild ?? channel.guildId)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
    }

    private var titleView: some View {
        HStack(spacing: 6) {
            if channel.guildId != nil {
                Image(systemName: "number").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(model.displayName(for: channel))
                .font(.headline).lineLimit(1)
        }
    }

    @ViewBuilder private var header: some View {
        if messages.isEmpty && !model.loadingChannels.contains(channel.id) {
            VStack(spacing: 10) {
                if channel.guildId != nil {
                    Image(systemName: "number.circle.fill").font(.system(size: 52)).foregroundStyle(.tertiary)
                } else {
                    AvatarView(url: channel.recipients?.first?.avatarURL,
                               name: channel.displayName(currentUserID: model.user?.id), size: 64,
                               seed: channel.recipients?.first?.id ?? channel.id)
                }
                Text(channel.displayName(currentUserID: model.user?.id)).font(.title2.bold())
                Text("This is the beginning of your conversation.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 40).padding(.bottom, 20)
        } else if !messages.isEmpty {
            // Small top affordance to fetch older history.
            Button { if let first = messages.first { Task { await model.loadMessages(channelID: channel.id, before: first.id) } } } label: {
                Text("Load earlier messages").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: Typing indicator

    /// Everyone currently typing in this channel (excluding yourself).
    private var typers: [String] { model.typingNames(in: channel.id) }

    /// "Alex is typing…" pinned at the top of the composer pane, just above the
    /// reply/edit bars and field — where Discord shows it.
    private var typingIndicator: some View {
        HStack(spacing: 7) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { TypingDot(index: $0) }
            }
            Text(typingLabel)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 2)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var typingLabel: String {
        let names = typers
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) is typing"
        case 2: return "\(names[0]) and \(names[1]) are typing"
        default: return "\(names[0]) and \(names.count - 1) others are typing"
        }
    }

    // MARK: Composer

    @State private var showFileImporter = false
    @State private var showRecents = false
    @State private var profileUser: DiscordUser?
    @State private var showGIFPicker = false
    @State private var showEmojiPicker = false
    @State private var showChannelSearch = false

    /// One continuous glass surface: reply/edit context, staged attachments and
    /// the field all share a single pane rather than stacking opaque panels.
    private var composer: some View {
        VStack(spacing: 0) {
            if !typers.isEmpty {
                typingIndicator
            }
            if let reply = model.replyingTo[channel.id] { contextBar(reply: reply) }
            if let edit = model.editing[channel.id] { editBar(edit) }
            if let staged = model.pendingAttachments[channel.id], !staged.isEmpty {
                attachmentTray(staged)
            }
            if !mentionCandidates.isEmpty {
                mentionSuggestions
            } else if !emojiMatches.isEmpty {
                emojiSuggestions
            }

            if canChatHere {
                HStack(alignment: .bottom, spacing: 10) {
                    Button { showFileImporter = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 38, height: 38)
                            .liquidGlassCircle()
                            .contentShape(Circle())
                    }
                    .buttonStyle(.bouncy)
                    .help("Attach files")

                    HStack(alignment: .bottom, spacing: 6) {
                        TextField(placeholder, text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .focused($composerFocused)
                            .padding(.leading, 14).padding(.vertical, 9)
                            .fixedSize(horizontal: false, vertical: true)
                            .onChange(of: text) {
                                emitTyping()
                                // Composer-side `:sob:` → 😭 so the preview matches
                                // what renders in the bubble.
                                text = EmojiShortcodes.expand(in: text)
                            }
                            // Return sends, Shift+Return is a newline — the native
                            // Messages.app contract. Only applies while inside this
                            // field (focused views get the event first).
                            .onKeyPress { press in
                                guard press.key == .return,
                                      !press.modifiers.contains(.command),
                                      !press.modifiers.contains(.control) else {
                                    return .ignored
                                }
                                if press.modifiers.contains(.shift) {
                                    text.append("\n")
                                } else if let top = mentionCandidates.first {
                                    // Return on an open @‑menu completes the pick
                                    // instead of sending a bare "@…".
                                    insertMention(top)
                                } else if canSend {
                                    submit()
                                }
                                return .handled
                            }
                            // ⌘V pastes images straight into the attachment tray.
                            .onPasteCommand(of: [UTType.image]) { providers in
                                Diag.app("paste command fired (composer)")
                                handlePaste(providers)
                            }
                        if canSend {
                            Button(action: submit) {
                                // Filled symbol: the glyph is baked in, so it can't
                                // vanish against the tinted glass.
                                Image(systemName: model.editing[channel.id] != nil
                                      ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                                    .font(.system(size: 28))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(Palette.accent)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.bouncy)
                            .padding(.trailing, 5).padding(.bottom, 4)
                            .keyboardShortcut(.return, modifiers: [])
                        } else {
                            HStack(alignment: .center, spacing: 8) {
                                Button { showGIFPicker = true } label: {
                                    Text("GIF").font(.system(size: 13, weight: .heavy))
                                        .foregroundStyle(Palette.accent)
                                        .frame(minWidth: 34, minHeight: 22)
                                        .contentShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.bouncy)
                                .help("Send a GIF")
                                Button { showEmojiPicker = true } label: {
                                    Image(systemName: "face.smiling")
                                        .font(.system(size: 22)).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Emoji")
                            }
                            .padding(.trailing, 12).padding(.bottom, 7)
                        }
                    }
                    .liquidGlass(cornerRadius: 22, interactive: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                lockedChatBar
            }
        }
        .animation(.snappy(duration: 0.22), value: typers)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
            || !(model.pendingAttachments[channel.id]?.isEmpty ?? true)
    }

    // MARK: Emoji autocomplete

    /// Trailing, um-typed `:partial` in the composer, if any. The expander only
    /// converts complete `:name:` pairs, so an open partial stays untransformed
    /// and can drive suggestions.
    private var emojiPartial: String? {
        guard let r = text.range(of: #":[A-Za-z0-9_+\-]+$"#, options: .regularExpression) else { return nil }
        let partial = String(text[r].dropFirst()).lowercased()
        return partial.isEmpty ? nil : partial
    }

    private var emojiMatches: [(shortcode: String, emoji: String)] {
        guard let partial = emojiPartial else { return [] }
        return EmojiShortcodes.all
            .filter { $0.shortcode.hasPrefix(partial) }
            .prefix(8)
            .map { (shortcode: $0.shortcode, emoji: $0.emoji) }
    }

    /// Replaces the trailing partial with a full shortcode; the composer's
    /// normal expander then swaps it for the actual emoji.
    private func insertEmoji(_ shortcode: String) {
        guard let r = text.range(of: #":[A-Za-z0-9_+\-]+$"#, options: .regularExpression) else { return }
        text.replaceSubrange(r, with: ":\(shortcode): ")
    }

    /// Inserts an emoji picked from the popover straight into the composer.
    private func insertEmojiFromPicker(_ emoji: String) {
        if !text.isEmpty && !text.hasSuffix(" ") { text.append(" ") }
        text.append(emoji)
        text.append(" ")
        composerFocused = true
    }

    private var emojiSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(emojiMatches, id: \.shortcode) { match in
                    Button { insertEmoji(match.shortcode) } label: {
                        HStack(spacing: 5) {
                            Text(match.emoji).font(.body)
                            Text(":\(match.shortcode):")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 4)
        .transition(.opacity)
    }

    // MARK: Channel permissions

    /// Whether the composer should accept input. Locked channels ("can't send
    /// messages") swap the field for a quiet explanation instead.
    private var canChatHere: Bool {
        model.canSendMessages(in: channel)
    }

    private var lockedChatBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.footnote).foregroundStyle(.secondary)
            Text("You don't have permission to send messages in this channel.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 22, interactive: false)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: @ mention autocomplete

    private struct MentionCandidate: Identifiable {
        enum Kind { case everyone, role, user }
        let id: String
        let kind: Kind
        let label: String
        let sublabel: String
        let mention: String
    }

    private var guildForMentions: Guild? {
        guard let id = channel.guildId else { return nil }
        return model.guilds.first { $0.id == id }
    }

    /// The trailing `@token` (its `@` index and token text) when the composer
    /// is mid-mention. Requires the `@` to start a word (or the buffer) so
    /// embedded `<@123>` syntax never matches. A token followed by more text is
    /// already "in the past" and closes the menu.
    private var mentionSpan: (at: String.Index, token: String)? {
        guard channel.guildId != nil, let at = text.lastIndex(of: "@") else { return nil }
        guard at == text.startIndex || " \n\t".contains(text[text.index(before: at)]) else { return nil }
        let after = text.index(after: at)
        var end = after
        while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
        if end < text.endIndex {
            var scan = text.index(after: end)
            while scan < text.endIndex, text[scan].isWhitespace { scan = text.index(after: scan) }
            guard scan == text.endIndex else { return nil }
        }
        return (at, String(text[after..<end]))
    }

    private var mentionQuery: String? { mentionSpan?.token }

    private var mentionCandidates: [MentionCandidate] {
        guard let token = mentionQuery, let guild = guildForMentions else { return [] }
        let needle = token.lowercased()
        var out: [MentionCandidate] = []
        if needle.isEmpty || "everyone".hasPrefix(needle) {
            out.append(.init(id: "@everyone", kind: .everyone, label: "everyone",
                             sublabel: "Notify every member in this server",
                             mention: "@everyone"))
        }
        if needle.isEmpty || "here".hasPrefix(needle) {
            out.append(.init(id: "@here", kind: .everyone, label: "here",
                             sublabel: "Notify online members only",
                             mention: "@here"))
        }
        for role in guild.roles ?? [] where role.id != guild.id {
            guard needle.isEmpty || role.name.lowercased().hasPrefix(needle) else { continue }
            out.append(.init(id: "role:\(role.id)", kind: .role,
                             label: role.name, sublabel: "Role",
                             mention: "<@&\(role.id)>"))
            if out.count >= 28 { break }
        }
        for user in model.members(in: guild.id) {
            let label = model.displayName(of: user, inGuild: guild.id) ?? user.displayName
            guard needle.isEmpty || label.lowercased().hasPrefix(needle) else { continue }
            out.append(.init(id: user.id, kind: .user,
                             label: label, sublabel: user.tag,
                             mention: "<@\(user.id)>"))
            if out.count >= 40 { break }
        }
        return out
    }

    /// Replaces the live `@token` with a real mention (markdown form; Discord
    /// renders it as the name and rings the ping).
    private func insertMention(_ m: MentionCandidate) {
        guard let span = mentionSpan else { return }
        text.replaceSubrange(span.at..<text.endIndex, with: m.mention + " ")
    }

    private func mentionIcon(_ kind: MentionCandidate.Kind) -> String {
        switch kind {
        case .everyone: return "person.3.fill"
        case .role: return "tag.fill"
        case .user: return "person.fill"
        }
    }

    private var mentionSuggestions: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(mentionCandidates) { m in
                    Button { insertMention(m) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: mentionIcon(m.kind))
                                .font(.footnote).foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.label).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                if !m.sublabel.isEmpty {
                                    Text(m.sublabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 3)
        }
        .frame(maxWidth: 300, maxHeight: 210)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .background(Palette.background.opacity(0.97),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        .padding(.top, 4)
        .transition(.opacity)
    }

    /// Stages files chosen via the open panel. Reads data on the main actor's
    /// concurrency but the actual read is off the UI thread inside `stage`.
    private func stage(_ urls: [URL]) {
        for url in urls {
            let accessOK = url.startAccessingSecurityScopedResource()
            defer { if accessOK { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let ext = url.pathExtension
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType
                ?? ((url.isImage == true) ? "image/jpeg" : "application/octet-stream")
            model.stage(.init(filename: url.lastPathComponent, data: data, mime: mime), in: channel.id)
        }
    }

    /// ⌘V for the composer. Delegates to the model so the window-level fallback
    /// (active while the field isn't focused) shares one code path.
    private func handlePaste(_ providers: [NSItemProvider]) {
        model.handleImagePaste(providers, channelID: channel.id)
    }

    /// Thumbnails of images queued for upload, each removable.
    private func attachmentTray(_ staged: [AppModel.PendingAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(staged) { item in
                    ZStack(alignment: .topTrailing) {
                        if let ns = NSImage(data: item.data) {
                            Image(nsImage: ns)
                                .resizable().scaledToFill()
                                .frame(width: 62, height: 62)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 62, height: 62)
                                .overlay(Image(systemName: "doc.fill").foregroundStyle(.secondary))
                        }
                        Button { model.unstage(item.id, in: channel.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.footnote)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .padding(3)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 10)
        }
        .frame(height: 76)
        .transition(.opacity)
    }

    private var placeholder: String {
        if model.editing[channel.id] != nil { return "Edit message" }
        if let r = model.replyingTo[channel.id] {
            return "Reply to \(r.author?.displayName ?? "message")"
        }
        return "Message"
    }

    /// The bar shown above the field while composing a reply.
    private func contextBar(reply: Message) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.footnote).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(reply.author?.displayName ?? "message")")
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                Text(reply.content.isEmpty ? "Attachment" : reply.content)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                withAnimation { model.cancelReply(in: channel.id) }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .transition(.opacity)
    }

    private func editBar(_ message: Message) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil").font(.footnote).foregroundStyle(.orange)
            Text("Editing message").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Spacer()
            Button {
                withAnimation { model.cancelEdit(in: channel.id); text = "" }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .transition(.opacity)
    }

    private func submit() {
        if model.editing[channel.id] != nil {
            model.commitEdit(channelID: channel.id, content: text)
        } else if !(model.pendingAttachments[channel.id]?.isEmpty ?? true) {
            model.sendAttachments(channelID: channel.id, caption: text)
        } else {
            model.sendMessage(channelID: channel.id, content: text)
        }
        text = ""
    }

    private func emitTyping() {
        guard !text.isEmpty, Date().timeIntervalSince(lastTyping) > 8 else { return }
        lastTyping = Date()
        model.sendTyping(channelID: channel.id)
    }

    // MARK: Grouping helpers

    private func startsGroup(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let prev = messages[index - 1], cur = messages[index]
        if prev.author?.id != cur.author?.id { return true }
        if cur.isReply { return true }
        guard let a = prev.date, let b = cur.date else { return true }
        return b.timeIntervalSince(a) > 5 * 60
    }

    private func daySeparator(at index: Int) -> Date? {
        guard let cur = messages[index].date else { return nil }
        if index == 0 { return cur }
        guard let prev = messages[index - 1].date else { return nil }
        return Calendar.current.isDate(cur, inSameDayAs: prev) ? nil : cur
    }
}

extension URL {
    /// Cheap sniff: whether the file looks like an image, for mime fallback.
    var isImage: Bool? {
        guard let type = UTType(filenameExtension: pathExtension) else { return nil }
        return type.conforms(to: .image)
    }
}