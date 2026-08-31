import Foundation

/// A guild (server).
///
/// Discord sends two different shapes for this object. Bot gateways and the
/// REST API put `name`/`icon` at the top level; the **user** gateway nests them
/// under `properties`. We decode both, because getting this wrong silently
/// empties the entire server list.
struct Guild: Codable, Identifiable, Hashable {
    let id: Snowflake
    var name: String
    var icon: String?
    var banner: String?
    var ownerId: Snowflake?
    var channels: [Channel]?
    var roles: [Role]?
    var emojis: [Emoji]?
    var stickers: [GuildSticker]?
    var memberCount: Int?
    var members: [GuildMember]?
    var features: [String]?

    var iconURL: URL? { CDN.icon(guildID: id, hash: icon) }

    /// Uppercase initials used when a guild has no icon (matches Discord's fallback).
    var acronym: String {
        name.split(separator: " ").compactMap { $0.first }.map(String.init).joined()
    }

    /// Visible "tags" Discord stamps on a server (verified / partnered).
    var tags: [(symbol: String, label: String)] {
        let f = Set(features ?? [])
        var out: [(symbol: String, label: String)] = []
        if f.contains("VERIFIED") { out.append(("checkmark.seal.fill", "Verified")) }
        if f.contains("PARTNERED") { out.append(("star.fill", "Partner")) }
        return out
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, banner, ownerId, channels, roles, emojis, stickers, memberCount, members, properties, features
    }

    /// The nested form used by the user gateway.
    private struct Properties: Decodable {
        var name: String?
        var icon: String?
        var banner: String?
        var ownerId: Snowflake?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let props = try? c.decodeIfPresent(Properties.self, forKey: .properties)

        // `id` may live at the top level in both shapes.
        id = try c.decode(Snowflake.self, forKey: .id)
        members = c.decodeLossyArray(GuildMember.self, forKey: .members)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) as? String
            ?? props?.name
            ?? "Unknown Server"
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) as? String ?? props?.icon
        banner = (try? c.decodeIfPresent(String.self, forKey: .banner)) as? String ?? props?.banner
        ownerId = (try? c.decodeIfPresent(Snowflake.self, forKey: .ownerId)) as? Snowflake ?? props?.ownerId

        // Collections are lossy: a single unparseable channel must not discard the guild.
        channels = c.decodeLossyArray(Channel.self, forKey: .channels)
        roles = c.decodeLossyArray(Role.self, forKey: .roles)
        emojis = c.decodeLossyArray(Emoji.self, forKey: .emojis)
        stickers = c.decodeLossyArray(GuildSticker.self, forKey: .stickers)
        features = c.decodeLossyArray(String.self, forKey: .features)
        memberCount = try? c.decodeIfPresent(Int.self, forKey: .memberCount)
    }

    init(id: Snowflake, name: String, icon: String? = nil, banner: String? = nil,
         ownerId: Snowflake? = nil, channels: [Channel]? = nil, roles: [Role]? = nil,
         emojis: [Emoji]? = nil, stickers: [GuildSticker]? = nil, memberCount: Int? = nil, members: [GuildMember]? = nil) {
        self.id = id; self.name = name; self.icon = icon; self.banner = banner
        self.ownerId = ownerId; self.channels = channels; self.roles = roles
        self.emojis = emojis; self.stickers = stickers; self.memberCount = memberCount; self.members = members
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(banner, forKey: .banner)
        try c.encodeIfPresent(ownerId, forKey: .ownerId)
        try c.encodeIfPresent(channels, forKey: .channels)
        try c.encodeIfPresent(roles, forKey: .roles)
        try c.encodeIfPresent(emojis, forKey: .emojis)
        try c.encodeIfPresent(stickers, forKey: .stickers)
        try c.encodeIfPresent(memberCount, forKey: .memberCount)
        try c.encodeIfPresent(members, forKey: .members)
        try c.encodeIfPresent(features, forKey: .features)
    }
}

struct Role: Codable, Identifiable, Hashable {
    let id: Snowflake
    var name: String
    var color: Int
    var position: Int
    var permissions: String?
    var hoist: Bool?

    var uiColor: Int? { color == 0 ? nil : color }

    private enum CodingKeys: String, CodingKey { case id, name, color, position, permissions, hoist }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Snowflake.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) as? String ?? "role"
        color = (try? c.decodeIfPresent(Int.self, forKey: .color)) as? Int ?? 0
        position = (try? c.decodeIfPresent(Int.self, forKey: .position)) as? Int ?? 0
        permissions = try? c.decodeIfPresent(String.self, forKey: .permissions)
        hoist = try? c.decodeIfPresent(Bool.self, forKey: .hoist)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(color, forKey: .color); try c.encode(position, forKey: .position)
        try c.encodeIfPresent(permissions, forKey: .permissions)
        try c.encodeIfPresent(hoist, forKey: .hoist)
    }
}

struct Emoji: Codable, Identifiable, Hashable {
    let id: Snowflake?
    var name: String?
    var animated: Bool?

    var identifiableID: String { id ?? name ?? UUID().uuidString }
    var id2: String { identifiableID }
    var imageURL: URL? { CDN.emoji(id: id, animated: animated ?? false) }
}

/// A guild sticker, decoded from GUILD_CREATE so the composer can offer the
/// server's own sticker sheet alongside the emoji picker.
struct GuildSticker: Codable, Identifiable, Hashable {
    let id: Snowflake
    var name: String
    var formatType: Int?
    var available: Bool?

    init(id: Snowflake, name: String, formatType: Int? = nil, available: Bool? = nil) {
        self.id = id; self.name = name; self.formatType = formatType; self.available = available
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Snowflake.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) as? String ?? "sticker"
        formatType = try? c.decodeIfPresent(Int.self, forKey: .formatType)
        available = try? c.decodeIfPresent(Bool.self, forKey: .available)
    }

    var imageURL: URL? { CDN.sticker(id: id, formatType: formatType) }
}

/// Minimal unavailable-guild marker from READY before GUILD_CREATE fills it in.
struct UnavailableGuild: Codable, Hashable {
    let id: Snowflake
    var unavailable: Bool?
}
