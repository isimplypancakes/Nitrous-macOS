import SwiftUI

/// Discord markdown → SwiftUI.
///
/// Inline styling (bold/italic/strike/code/links, mentions, custom-emoji
/// shortcodes, spoilers) is resolved into an `AttributedString`; block-level
/// syntax (headings, `-#` subtext, `>` quotes, fenced code) is split into
/// `Block`s and laid out by `MarkdownContent`, because those change layout,
/// not just character attributes.
enum DiscordMarkdown {

    enum Block: Identifiable {
        case heading(level: Int, raw: String)   // 1–3, plus 4 = -# subtext
        case quote(raw: String)
        case code(String)
        case paragraph(raw: String)
        var id: String {
            switch self {
            case .heading(let l, let r): return "h\(l):\(r)"
            case .quote(let r): return "q:\(r)"
            case .code(let r): return "c:\(r)"
            case .paragraph(let r): return "p:\(r)"
            }
        }
    }

    /// Splits message content into block-level pieces.
    static func blocks(_ content: String) -> [Block] {
        var blocks: [Block] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []
        var quote: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(raw: paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(raw: quote.joined(separator: "\n"))); quote = [] }
        }

        while i < lines.count {
            let line = lines[i]

            // Fenced code block ```
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flushParagraph(); flushQuote()
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                i += 1 // consume closing fence
                blocks.append(.code(body.joined(separator: "\n")))
                continue
            }

            if let h = heading(for: line) {
                flushParagraph(); flushQuote()
                blocks.append(.heading(level: h.0, raw: h.1))
            } else if line.hasPrefix("> ") || line == ">" {
                flushParagraph()
                quote.append(String(line.dropFirst(line.hasPrefix("> ") ? 2 : 1)))
            } else {
                flushQuote()
                paragraph.append(line)
            }
            i += 1
        }
        flushParagraph(); flushQuote()
        return blocks
    }

    private static func heading(for line: String) -> (Int, String)? {
        if line.hasPrefix("### ") { return (3, String(line.dropFirst(4))) }
        if line.hasPrefix("## ")  { return (2, String(line.dropFirst(3))) }
        if line.hasPrefix("# ")   { return (1, String(line.dropFirst(2))) }
        if line.hasPrefix("-# ")  { return (4, String(line.dropFirst(3))) }
        return nil
    }

    /// True when a string carries a `:name:` custom emoji token. Used to swap
    /// the plain text render for the image-aware flow renderer.
    static func containsCustomEmoji(_ s: String) -> Bool {
        guard s.contains("<a:") || s.contains("<:") else { return false }
        guard let re = try? NSRegularExpression(pattern: "<a?:[A-Za-z0-9_]+:[0-9]+>") else { return false }
        return re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: Inline

    /// Inline render: mentions/emoji/spoilers + AttributedString markdown.
    @MainActor
    static func inline(_ raw: String, model: AppModel, message: Message?,
                       onAccent: Bool, revealSpoilers: Bool) -> AttributedString {
        var text = raw
        text = replace(text, pattern: "<a?:([a-zA-Z0-9_]+):[0-9]+>", with: ":$1:")
        text = replaceMatches(text, pattern: "<#([0-9]+)>") { id in
            let name = model.channelsByGuild.values.flatMap { $0 }.first { $0.id == id }?.name
            return "#\(name ?? "channel")"
        }
        var mentions: [String] = []
        text = replaceMatches(text, pattern: "<@!?([0-9]+)>") { id in
            let token = "@\(model.usersCache[id]?.displayName ?? "user")"
            mentions.append(token); return token
        }
        if message?.mentionEveryone == true { mentions += ["@everyone", "@here"] }

        // Extract spoiler contents, leaving the inner text in place.
        var spoilers: [String] = []
        text = replaceMatches(text, pattern: "\\|\\|(.+?)\\|\\|") { inner in
            spoilers.append(inner); return inner
        }

        // Discord's `__underline__` must survive the markdown parser, which
        // would otherwise read the underscores as bold. Pull each pair out,
        // parse, then restore degree runs with an underline attribute.
        var underlines: [String] = []
        text = replaceMatches(text, pattern: "__([^_\\n]+?)__") { inner in
            underlines.append(inner)
            return "\u{E000}U\(underlines.count)\u{E001}"
        }

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attr = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        attr.foregroundColor = onAccent ? Brand.onAccent : Palette.label

        for token in Set(mentions) {
            attr.color(occurrencesOf: token, with: onAccent ? Brand.onAccent : Palette.accent,
                       bold: true, background: onAccent ? nil : Palette.accent.opacity(0.15))
        }
        for (index, inner) in underlines.enumerated() {
            attr.underline(occurrencesOf: "\u{E000}U\(index + 1)\u{E001}", replacingWith: inner)
        }
        // Masked until revealed.
        if !revealSpoilers {
            let mask = onAccent ? Brand.onAccent.opacity(0.85) : Palette.label
            for s in Set(spoilers) {
                attr.color(occurrencesOf: s, with: mask, bold: false, background: mask)
            }
        }
        return attr
    }

    private static func replace(_ s: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static func replaceMatches(_ s: String, pattern: String, transform: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return s }
        let ns = s as NSString
        var result = ""; var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            result += transform(ns.substring(with: match.range(at: 1)))
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}

extension AttributedString {
    mutating func color(occurrencesOf sub: String, with color: Color, bold: Bool, background: Color?) {
        guard !sub.isEmpty else { return }
        var start = startIndex
        while start < endIndex, let r = self[start..<endIndex].range(of: sub) {
            self[r].foregroundColor = color
            if bold { self[r].font = .body.weight(.semibold) }
            if let background { self[r].backgroundColor = background }
            start = r.upperBound
        }
    }

    /// Swaps a parser-protection marker back to its real text, underlined.
    /// The attribute survives the Text renderer on macOS 13+.
    mutating func underline(occurrencesOf marker: String, replacingWith inner: String) {
        guard let r = range(of: marker) else { return }
        let lower = r.lowerBound
        let upper = r.upperBound
        self.replaceSubrange(lower..<upper, with: AttributedString(inner))
        if let after = self[lower..<endIndex].range(of: inner) {
            self[after].underlineStyle = Text.LineStyle(pattern: .solid)
        }
    }
}

/// Lays out parsed markdown blocks. Spoilers reveal on tap.
struct MarkdownContent: View {
    @EnvironmentObject var model: AppModel
    let message: Message
    let onAccent: Bool
    /// Renders arbitrary text instead of `message.content` — used by bubbles
    /// that split media links out of a message's caption.
    var textOverride: String?
    @State private var revealed = false

    init(message: Message, onAccent: Bool, textOverride: String? = nil) {
        self.message = message
        self.onAccent = onAccent
        self.textOverride = textOverride
    }

    /// A light-weight renderer for standalone caption text (no referenced
    /// message — creation timestamps etc. are irrelevant).
    init(text: String, onAccent: Bool) {
        self.message = Message(id: "", channelId: nil, author: nil, content: text, timestamp: "")
        self.onAccent = onAccent
        self.textOverride = text
    }

    private var content: String { textOverride ?? message.content }
    private var hasSpoiler: Bool { content.contains("||") }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(DiscordMarkdown.blocks(EmojiShortcodes.expand(in: content))) { block in
                view(for: block)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if hasSpoiler { withAnimation(.easeOut(duration: 0.15)) { revealed = true } } }
    }

    @ViewBuilder
    private func view(for block: DiscordMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let raw):
            if DiscordMarkdown.containsCustomEmoji(raw) {
                EmojiFlowText(raw: raw, message: message, onAccent: onAccent,
                              font: headingFont(level), revealed: revealed,
                              color: level == 4 ? .secondary : (onAccent ? Brand.onAccent : Palette.label))
            } else {
                Text(inline(raw))
                    .font(headingFont(level))
                    .foregroundStyle(level == 4 ? AnyShapeStyle(.secondary) : AnyShapeStyle(onAccent ? Brand.onAccent : Palette.label))
                    .padding(.top, level <= 3 ? 2 : 0)
                    .textSelection(.enabled)
            }
        case .paragraph(let raw):
            if DiscordMarkdown.containsCustomEmoji(raw) {
                EmojiFlowText(raw: raw, message: message, onAccent: onAccent,
                              font: .body, revealed: revealed)
            } else {
                Text(inline(raw)).font(.body).textSelection(.enabled)
            }
        case .quote(let raw):
            if DiscordMarkdown.containsCustomEmoji(raw) {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(onAccent ? Brand.onAccent.opacity(0.6) : Palette.accent)
                        .frame(width: 3)
                    EmojiFlowText(raw: raw, message: message, onAccent: onAccent,
                                  font: .body, revealed: revealed,
                                  color: onAccent ? Brand.onAccent.opacity(0.75) : .secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(onAccent ? Brand.onAccent.opacity(0.6) : Palette.accent)
                        .frame(width: 3)
                    Text(inline(raw)).font(.body)
                        .foregroundStyle(onAccent ? AnyShapeStyle(Brand.onAccent.opacity(0.75)) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let body):
            Text(body)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(onAccent ? Brand.onAccent : Palette.label)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(onAccent ? AnyShapeStyle(Color.black.opacity(0.10)) : AnyShapeStyle(Palette.tertiaryFill),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func inline(_ raw: String) -> AttributedString {
        DiscordMarkdown.inline(raw, model: model, message: message, onAccent: onAccent, revealSpoilers: revealed)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .headline
        default: return .caption   // -# subtext
        }
    }
}

/// Word-wrapping renderer for message text that contains server emoji. Custom
/// emoji tokens are split out and drawn as inline CDN images; everything else
/// stays plain Text so mentions, spoilers and markdown keep working. Wrapping
/// happens per word (via `FlowLayout`), which is what lets the images sit
/// inline with the text instead of tunnelling the whole line through one Text.
struct EmojiFlowText: View {
    @EnvironmentObject var model: AppModel
    let raw: String
    let message: Message
    let onAccent: Bool
    let font: Font
    let revealed: Bool
    var color: Color = .primary

    private enum Chunk: Identifiable {
        case word(String)
        case emoji(name: String, animated: Bool, id: String)

        var id: String {
            switch self {
            case .word(let w): return "w\(w)"
            case .emoji(let name, let animated, let id): return "e\(animated ? "a" : "")\(id)\(name)"
            }
        }
    }

    private var chunks: [Chunk] {
        guard let re = try? NSRegularExpression(pattern: #"(<a?:[A-Za-z0-9_]+:[0-9]+>|\s+)"#) else {
            return words(from: raw)
        }
        let ns = raw as NSString
        var out: [Chunk] = []; var last = 0
        re.enumerateMatches(in: raw, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            if m.range.location > last {
                out += words(from: ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            }
            let segment = ns.substring(with: m.range)
            if segment.hasPrefix("<"), let t = try? NSRegularExpression(pattern: #"^<a?:([A-Za-z0-9_]+):([0-9]+)>$"#),
               let tm = t.firstMatch(in: segment, options: [], range: NSRange(location: 0, length: segment.count)) {
                out.append(.emoji(name: (segment as NSString).substring(with: tm.range(at: 1)),
                                  animated: segment.hasPrefix("<a:"),
                                  id: (segment as NSString).substring(with: tm.range(at: 2))))
            } // whitespace-only segments add no chunk; FlowLayout spacing stands in.
            last = m.range.location + m.range.length
        }
        if last < ns.length { out += words(from: ns.substring(from: last)) }
        return out
    }

    private func words(from s: String) -> [Chunk] {
        s.split(separator: " ").filter { !$0.isEmpty }.map { .word(String($0)) }
    }

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(chunks) { chunk in
                switch chunk {
                case .word(let w):
                    Text(DiscordMarkdown.inline(w, model: model, message: message,
                                               onAccent: onAccent, revealSpoilers: revealed))
                        .font(font)
                        .foregroundStyle(color)
                        .frame(maxWidth: 190, alignment: .leading)
                case .emoji(let name, let animated, let id):
                    if let url = CDN.emoji(id: Snowflake(id), animated: animated) {
                        AsyncImage(url: url) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFit()
                            } else {
                                Color.clear.frame(width: 20, height: 20)
                            }
                        }
                        .frame(width: 20, height: 20)
                        .padding(.bottom, 1)
                        .accessibilityLabel(":\(name):")
                        .help(":\(name):")
                    }
                }
            }
        }
    }
}
