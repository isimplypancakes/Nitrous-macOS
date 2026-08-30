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
    var primaryGuild: PrimaryGuild?

    /// The server tag the user wears (e.g. "RAM") — set by a server they've
    /// joined and adopted as their primary guild.
    struct PrimaryGuild: Codable, Hashable {
        var identityGuildId: Snowflake?
        var identityEnabled: Bool?
        var tag: String?
        var badge: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id, username, globalName, discriminator, avatar, bot, banner,
             accentColor, bio, publicFlags, premiumType, primaryGuild
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
        primaryGuild = try? c.decodeIfPresent(PrimaryGuild.self, forKey: .primaryGuild)
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

    /// The server tag text (e.g. "RAM") if the user is wearing one.
    var displayTag: String? {
        guard let pg = primaryGuild,
              pg.identityEnabled != false,
              let tag = pg.tag, !tag.isEmpty else { return nil }
        return tag
    }

    /// The badge artwork for the worn server tag, if any.
    var displayTagBadgeURL: URL? {
        guard primaryGuild?.identityEnabled != false,
              let guildID = primaryGuild?.identityGuildId,
              let badge = primaryGuild?.badge, !badge.isEmpty else { return nil }
        return CDN.guildTagBadge(guildID: guildID, hash: badge)
    }
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
    /// Full activity list (games, Spotify, custom status…). `[[]]`-tolerant.
    var activities: [Activity]?

    struct PartialUser: Codable, Hashable { let id: Snowflake }

    /// A single rich-presence activity. All fields tolerated: clients and apps
    /// push widely varying shapes and one odd field must never drop the presence.
    struct Activity: Codable, Hashable {
        var name: String?
        var type: Int?
        var state: String?
        var details: String?
        var timestamps: Timestamps?
        var assets: Assets?
        var applicationId: String?
        var id: String?
        var createdAt: Int?
        var emoji: Emoji?
        var party: Party?

        struct Timestamps: Codable, Hashable { var start: Int?; var end: Int? }
        struct Party: Codable, Hashable { var size: [Int]? }
        struct Assets: Codable, Hashable {
            var largeImage: String?
            var smallImage: String?
            var largeText: String?
            var smallText: String?
        }

        var activityType: ActivityType { ActivityType(rawValue: type ?? -1) ?? .playing }
        /// Custom statuses are type 4: `state` is the message, `emoji` the pick.
        var isCustomStatus: Bool { activityType == .customStatus }

        /// The big artwork for the activity (app-assets CDN), if Discord sent one.
        var assetImageURL: URL? {
            CDN.activityAsset(applicationID: applicationId, assetID: assets?.largeImage ?? assets?.smallImage)
        }
        /// The album/rocket icon on the small corner, or the large if none.
        var smallAssetURL: URL? {
            guard let small = assets?.smallImage else { return assetImageURL }
            return CDN.activityAsset(applicationID: applicationId, assetID: small)
        }
    }

    /// Non-custom activities in priority order; custom status handled separately.
    var richActivities: [Activity] {
        (activities ?? []).filter { !$0.isCustomStatus }
    }
    var customStatus: Activity? {
        activities?.first { $0.isCustomStatus }
    }
}

enum ActivityType: Int, Codable, Hashable {
    case playing = 0
    case streaming = 1
    case listening = 2
    case watching = 3
    case customStatus = 4
    case competing = 5
}
