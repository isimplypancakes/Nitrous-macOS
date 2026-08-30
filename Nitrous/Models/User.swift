import Foundation

struct DiscordUser: Codable, Identifiable, Hashable {
    let id: Snowflake
    var username: String
    var globalName: String?
    var discriminator: String?
    var avatar: String?
    var bot: Bool?
    var banner: String?
    var accentColor: Int?
    var bio: String?
    var publicFlags: Int?
    var premiumType: Int?

    private enum CodingKeys: String, CodingKey {
        case id, username, globalName, discriminator, avatar, bot, banner,
             accentColor, bio, publicFlags, premiumType
    }

    /// Tolerant decode: READY and member chunks include partial user objects
    /// that may omit `username`, and a strict decode there would discard the
    /// whole enclosing payload.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Snowflake.self, forKey: .id)
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) as? String ?? "unknown"
        globalName = try? c.decodeIfPresent(String.self, forKey: .globalName)
        discriminator = try? c.decodeIfPresent(String.self, forKey: .discriminator)
        avatar = try? c.decodeIfPresent(String.self, forKey: .avatar)
        bot = try? c.decodeIfPresent(Bool.self, forKey: .bot)
        banner = try? c.decodeIfPresent(String.self, forKey: .banner)
        accentColor = try? c.decodeIfPresent(Int.self, forKey: .accentColor)
        bio = try? c.decodeIfPresent(String.self, forKey: .bio)
        publicFlags = try? c.decodeIfPresent(Int.self, forKey: .publicFlags)
        premiumType = try? c.decodeIfPresent(Int.self, forKey: .premiumType)
    }

    init(id: Snowflake, username: String, globalName: String? = nil,
         discriminator: String? = nil, avatar: String? = nil, bot: Bool? = nil) {
        self.id = id; self.username = username; self.globalName = globalName
        self.discriminator = discriminator; self.avatar = avatar; self.bot = bot
    }

    /// The name Discord shows: display (global) name, else username.
    var displayName: String { globalName ?? username }

    /// "username" for the new handle system, else "username#1234".
    var tag: String {
        if let d = discriminator, d != "0", !d.isEmpty { return "\(username)#\(d)" }
        return username
    }

    var avatarURL: URL? { CDN.avatar(userID: id, hash: avatar, discriminator: discriminator) }
    var bannerURL: URL? { CDN.banner(userID: id, hash: banner) }
}

struct GuildMember: Codable, Hashable {
    var user: DiscordUser?
    var nick: String?
    var avatar: String?
    var roles: [Snowflake]?
    var joinedAt: String?
    var premiumSince: String?
    var pending: Bool?
    var communicationDisabledUntil: String?
}

/// Presence status: online / idle / dnd / offline / invisible.
struct Presence: Codable, Hashable {
    var user: PartialUser?
    var status: String?
    var activities: [Activity]?

    struct PartialUser: Codable, Hashable { let id: Snowflake }
    struct Activity: Codable, Hashable {
        var name: String?
        var type: Int?
        var state: String?
        var details: String?
    }
}
