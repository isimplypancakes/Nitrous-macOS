import Foundation

enum ChannelType: Int, Codable {
    case guildText = 0
    case dm = 1
    case guildVoice = 2
    case groupDM = 3
    case guildCategory = 4
    case guildAnnouncement = 5
    case announcementThread = 10
    case publicThread = 11
    case privateThread = 12
    case guildStageVoice = 13
    case guildForum = 15
    case unknown = -1

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = ChannelType(rawValue: raw) ?? .unknown
    }
}

struct Channel: Codable, Identifiable, Hashable {
    let id: Snowflake
    var type: ChannelType
    var guildId: Snowflake?
    var name: String?
    var topic: String?
    var position: Int?
    var parentId: Snowflake?          // category, or thread parent
    var lastMessageId: Snowflake?
    var recipients: [DiscordUser]?    // DM / group DM (REST shape)
    /// The gateway sends only IDs here; names are resolved from the user cache.
    var recipientIds: [Snowflake]?
    var icon: String?                 // group DM icon
    var ownerId: Snowflake?
    var nsfw: Bool?
    var permissionOverwrites: [Overwrite]?

    struct Overwrite: Codable, Hashable {
        let id: Snowflake
        var type: Int
        var allow: String
        var deny: String
    }

    var isTextLike: Bool {
        switch type {
        case .guildText, .guildAnnouncement, .dm, .groupDM,
             .publicThread, .privateThread, .announcementThread:
            return true
        default: return false
        }
    }

    var isCategory: Bool { type == .guildCategory }
    var isVoice: Bool { type == .guildVoice || type == .guildStageVoice }

    /// All participant IDs regardless of which shape the payload used.
    func participantIDs(excluding me: Snowflake?) -> [Snowflake] {
        let ids = recipientIds ?? recipients?.map(\.id) ?? []
        return ids.filter { $0 != me }
    }

    /// Best display name for the channel including DM synthesis.
    func displayName(currentUserID: Snowflake?) -> String {
        if let name, !name.isEmpty { return name }
        switch type {
        case .dm:
            let other = recipients?.first { $0.id != currentUserID } ?? recipients?.first
            return other?.displayName ?? "Direct Message"
        case .groupDM:
            let names = (recipients ?? []).map { $0.displayName }
            return names.isEmpty ? "Group" : names.joined(separator: ", ")
        default:
            return "channel"
        }
    }

    var iconURL: URL? {
        switch type {
        case .dm:
            return recipients?.first?.avatarURL
        case .groupDM:
            return CDN.channelIcon(channelID: id, hash: icon)
        default:
            return nil
        }
    }

    var sortPosition: Int { position ?? 0 }
}
