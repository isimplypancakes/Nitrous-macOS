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

    static func emoji(id: Snowflake?, animated: Bool) -> URL? {
        guard let id else { return nil }
        return URL(string: "\(base)/emojis/\(id).\(animated ? "gif" : "png")?size=64")
    }
}
