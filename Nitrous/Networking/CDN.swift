import Foundation

/// Builds Discord CDN URLs for avatars, icons, banners and emoji.
enum CDN {
    static let base = "https://cdn.discordapp.com"

    static func avatar(userID: Snowflake, hash: String?, discriminator: String?) -> URL? {
        if let hash {
            let ext = hash.hasPrefix("a_") ? "gif" : "png"
            return URL(string: "\(base)/avatars/\(userID)/\(hash).\(ext)?size=256")
        }
        // Default avatar index: new system uses (id >> 22) % 6, legacy uses discriminator % 5.
        let index: Int
        if let d = discriminator, let dv = Int(d), dv != 0 {
            index = dv % 5
        } else if let idv = UInt64(userID) {
            index = Int((idv >> 22) % 6)
        } else {
            index = 0
        }
        return URL(string: "\(base)/embed/avatars/\(index).png")
    }

    static func icon(guildID: Snowflake, hash: String?) -> URL? {
        guard let hash else { return nil }
        let ext = hash.hasPrefix("a_") ? "gif" : "png"
        return URL(string: "\(base)/icons/\(guildID)/\(hash).\(ext)?size=240")
    }

    static func banner(userID: Snowflake, hash: String?) -> URL? {
        guard let hash else { return nil }
        let ext = hash.hasPrefix("a_") ? "gif" : "png"
        return URL(string: "\(base)/banners/\(userID)/\(hash).\(ext)?size=600")
    }

    static func channelIcon(channelID: Snowflake, hash: String?) -> URL? {
        guard let hash else { return nil }
        return URL(string: "\(base)/channel-icons/\(channelID)/\(hash).png?size=240")
    }

    /// The badge artwork a server shows next to a member's server tag.
    static func guildTagBadge(guildID: Snowflake, hash: String) -> URL? {
        URL(string: "\(base)/guild-tag-badges/\(guildID)/\(hash).png?size=64")
    }

    static func emoji(id: Snowflake?, animated: Bool) -> URL? {
        guard let id else { return nil }
        return URL(string: "\(base)/emojis/\(id).\(animated ? "gif" : "png")?size=64")
    }

    /// A sticker asset. Format 4 is a true GIF (animated); PNG/APNG/LOTTIE all
    /// serve a PNG, and even LOTTIE's JSON has a static preview available.
    static func sticker(id: Snowflake, formatType: Int?) -> URL? {
        let ext = formatType == 4 ? "gif" : "png"
        return URL(string: "\(base)/stickers/\(id).\(ext)")
    }

    /// Rich-presence artwork for a registered application, e.g. the Spotify
    /// album cover or a game's splash art.
    static func activityAsset(applicationID: String?, assetID: String?) -> URL? {
        guard let applicationID, let assetID, !assetID.contains("spotify:") else { return nil }
        // Nested queries (e.g. &w/&h) arrive quoted; strip leading quotes.
        let cleaned = assetID.removingPercentEncoding ?? assetID
        return URL(string: "\(base)/app-assets/\(applicationID)/\(String(cleaned.drop(while: { $0 == "\"" }))).png?size=160")
    }
}
