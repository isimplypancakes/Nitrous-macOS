import SwiftUI
import PhotosUI

/// The conversation screen: grouped iMessage-style bubbles, day separators,
/// a typing bubble, and a native composer pinned via safeAreaInset.
struct ChatView: View {
    @EnvironmentObject var theme: ThemeStore
    @EnvironmentObject var model: AppModel
    let channel: Channel

    @State private var text = ""
    @State private var lastTyping = Date.distantPast
    @State private var showMembers = false
    @State private var highlighted: Snowflake?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @FocusState private var composerFocused: Bool

    private var messages: [Message] { model.messagesByChannel[channel.id] ?? [] }
    private var isGroupContext: Bool { channel.guildId != nil || channel.type == .groupDM }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    header
                    if model.loadingChannels.contains(channel.id) && messages.isEmpty {
                        ProgressView().padding(.top, 40)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if let sep = daySeparator(at: index) { DaySeparator(date: sep) }
                        ChatBubble(message: message,
                                   mine: message.author?.id == model.user?.id,
                                   showHeader: startsGroup(at: index),
                                   showAvatar: isGroupContext,
                                   channelID: channel.id)
                            .id(message.id)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Palette.accent.opacity(highlighted == message.id ? 0.28 : 0))
                                    .padding(.horizontal, 6)
                            )
                    }
                    if !model.typingUsers(in: channel.id).isEmpty {
                        HStack { TypingBubble(); Spacer() }
                            .padding(.horizontal, 12).padding(.top, 6)
                    }
                    Color.clear.frame(height: 8).id("BOTTOM")
                }
                .padding(.bottom, 6)
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
            .onChange(of: model.scrollTarget) {
                guard let target = model.scrollTarget else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .center) }
                withAnimation(.easeIn(duration: 0.15)) { highlighted = target }
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                // Hold the highlight long enough to actually be seen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                    withAnimation(.easeOut(duration: 0.4)) { highlighted = nil }
                    model.scrollTarget = nil
                }
            }
        }
        .navigationTitle(model.displayName(for: channel))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { titleView }
            if channel.guildId != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showMembers = true } label: { Image(systemName: "person.2.fill") }
                }
            }
        }
        // The floating tab bar overlaps the compose bar and wins hit-testing,
        // which made the field and attach button completely untappable. Hiding
        // it in a conversation also matches Messages.app and frees the space.
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) { composer }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { loadPickedPhotos() }
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
        .sheet(isPresented: $showMembers) { MemberListView() }
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

    // MARK: Composer

    /// One continuous glass surface: reply/edit context, staged attachments and
    /// the field all share a single pane rather than stacking opaque panels.
    private var composer: some View {
        VStack(spacing: 0) {
            if let reply = model.replyingTo[channel.id] { contextBar(reply: reply) }
            if let edit = model.editing[channel.id] { editBar(edit) }
            if let staged = model.pendingAttachments[channel.id], !staged.isEmpty {
                attachmentTray(staged)
            }

            HStack(alignment: .bottom, spacing: 10) {
                // A plain button driving `.photosPicker(isPresented:)` on the
                // main view — a PhotosPicker placed inside a safeAreaInset
                // doesn't reliably present its sheet.
                Button { showPhotoPicker = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 38, height: 38)
                        .liquidGlassCircle()
                        .contentShape(Circle())
                }
                .buttonStyle(.bouncy)

                HStack(alignment: .bottom, spacing: 6) {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .padding(.leading, 14).padding(.vertical, 9)
                        .onChange(of: text) { emitTyping() }
                    if canSend {
                        // Matches the "+" control: same glass circle, same
                        // springy press.
                        Button(action: submit) {
                            Image(systemName: model.editing[channel.id] != nil
                                  ? "checkmark" : "arrow.up")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(Palette.accent)
                                .frame(width: 32, height: 32)
                                .liquidGlassCircle(tint: Palette.accent)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.bouncy)
                        .padding(.trailing, 5).padding(.bottom, 4)
                    } else {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 22)).foregroundStyle(.secondary)
                            .padding(.trailing, 12).padding(.bottom, 7)
                    }
                }
                .liquidGlass(cornerRadius: 22, interactive: true)
            }
            // Inset to match the chat's own margins so the bar doesn't run
            // the full width of the screen.
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        // No full-width bar behind the composer: the field is its own glass
        // surface and floats, so the transcript and wallpaper stay visible.
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
            || !(model.pendingAttachments[channel.id]?.isEmpty ?? true)
    }

    /// Thumbnails of images queued for upload, each removable.
    private func attachmentTray(_ staged: [AppModel.PendingAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(staged) { item in
                    ZStack(alignment: .topTrailing) {
                        if let ui = UIImage(data: item.data) {
                            Image(uiImage: ui)
                                .resizable().scaledToFill()
                                .frame(width: 62, height: 62)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    /// Reads the picked photos into memory and stages them.
    private func loadPickedPhotos() {
        let items = photoItems
        guard !items.isEmpty else { return }
        photoItems = []
        Task {
            for (i, item) in items.enumerated() {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let name = "image_\(Int(Date().timeIntervalSince1970))_\(i).jpg"
                model.stage(.init(filename: name, data: data, mime: "image/jpeg"), in: channel.id)
            }
        }
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
