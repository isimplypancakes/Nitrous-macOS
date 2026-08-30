import Foundation
import SwiftUI

struct Message: Codable, Identifiable, Hashable {
    let id: Snowflake
    var channelId: Snowflake?
    var author: DiscordUser?
    var content: String
    var timestamp: String?
    var editedTimestamp: String?
    var tts: Bool?
    var mentionEveryone: Bool?
    var mentions: [DiscordUser]?
    var attachments: [Attachment]?
    var embeds: [Embed]?
    var reactions: [Reaction]?
    var pinned: Bool?
    var type: Int?
    var referencedMessage: Box<Message>?
    var nonce: String?

    var date: Date? { DiscordTime.parse(timestamp) }
    var editedDate: Date? { DiscordTime.parse(editedTimestamp) }
    var isReply: Bool { referencedMessage?.value != nil }

    /// System messages (joins, pins, boosts) render differently.
    var isSystem: Bool {
        guard let type else { return false }
        return ![0, 19].contains(type) // 0 default, 19 reply
    }
}

/// Boxed indirection so `Message` can reference another `Message` (value type recursion).
final class Box<T: Codable & Hashable>: Codable, Hashable {
    let value: T?
    init(_ value: T?) { self.value = value }
    required init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        value = try? c.decode(T.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
    static func == (l: Box<T>, r: Box<T>) -> Bool { l.value == r.value }
    func hash(into hasher: inout Hasher) { hasher.combine(value) }
}

struct Attachment: Codable, Identifiable, Hashable {
    let id: Snowflake
    var filename: String
    var size: Int?
    var url: String
    var proxyUrl: String?
    var width: Int?
    var height: Int?
    var contentType: String?

    var isImage: Bool {
        if let t = contentType { return t.hasPrefix("image/") }
        let lower = filename.lowercased()
        return [".png", ".jpg", ".jpeg", ".gif", ".webp"].contains { lower.hasSuffix($0) }
    }
    var isVideo: Bool { (contentType?.hasPrefix("video/")) ?? false }
    var mediaURL: URL? { URL(string: url) }
    var aspect: CGFloat? {
        guard let w = width, let h = height, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }
}

struct Embed: Codable, Hashable {
    var title: String?
    var type: String?
    var description: String?
    var url: String?
    var color: Int?
    var timestamp: String?
    var image: EmbedImage?
    var thumbnail: EmbedImage?
    var author: EmbedAuthor?
    var footer: EmbedFooter?
    var fields: [EmbedField]?
    var video: EmbedImage?
    var provider: EmbedProvider?

    /// Link previews Discord renders as a bare image/gif rather than a card.
    var isMediaOnly: Bool { type == "image" || type == "gifv" }
    var hasCardContent: Bool {
        title != nil || description != nil || author != nil
            || !(fields ?? []).isEmpty || footer != nil
    }
    var accent: Color { color.map { Color(hex: UInt32($0)) } ?? Palette.accent }
    var date: Date? { DiscordTime.parse(timestamp) }

    struct EmbedImage: Codable, Hashable { var url: String?; var proxyUrl: String?; var width: Int?; var height: Int? }
    struct EmbedAuthor: Codable, Hashable { var name: String?; var url: String?; var iconUrl: String? }
    struct EmbedFooter: Codable, Hashable { var text: String?; var iconUrl: String? }
    struct EmbedProvider: Codable, Hashable { var name: String?; var url: String? }
    struct EmbedField: Codable, Hashable { var name: String; var value: String; var `inline`: Bool? }
}

struct Reaction: Codable, Hashable {
    var count: Int
    var me: Bool
    var emoji: Emoji
}
