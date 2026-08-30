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

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var attr = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        attr.foregroundColor = onAccent ? Brand.onAccent : Palette.label

        for token in Set(mentions) {
            attr.color(occurrencesOf: token, with: onAccent ? Brand.onAccent : Palette.accent,
                       bold: true, background: onAccent ? nil : Palette.accent.opacity(0.15))
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
            Text(inline(raw))
                .font(headingFont(level))
                .foregroundStyle(level == 4 ? AnyShapeStyle(.secondary) : AnyShapeStyle(onAccent ? Brand.onAccent : Palette.label))
                .padding(.top, level <= 3 ? 2 : 0)
        case .paragraph(let raw):
            Text(inline(raw)).font(.body)
        case .quote(let raw):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(onAccent ? Brand.onAccent.opacity(0.6) : Palette.accent)
                    .frame(width: 3)
                Text(inline(raw)).font(.body)
                    .foregroundStyle(onAccent ? AnyShapeStyle(Brand.onAccent.opacity(0.75)) : AnyShapeStyle(.secondary))
            }
            .fixedSize(horizontal: false, vertical: true)
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
