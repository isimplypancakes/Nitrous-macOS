import Foundation

/// Gateway opcodes (v10).
enum GatewayOpcode: Int, Codable {
    case dispatch = 0
    case heartbeat = 1
    case identify = 2
    case presenceUpdate = 3
    case voiceStateUpdate = 4
    case resume = 6
    case reconnect = 7
    case requestGuildMembers = 8
    case invalidSession = 9
    case hello = 10
    case heartbeatAck = 11
}

/// Raw envelope. `d` is decoded lazily per dispatch type.
struct GatewayFrame: Decodable {
    let op: Int
    let s: Int?
    let t: String?
    let d: RawJSON?
}

struct HelloData: Decodable { let heartbeatInterval: Int }

/// READY carries the initial application state for a user session.
///
/// Every collection here is decoded lossily and every optional field tolerated:
/// READY is the single largest payload Discord sends, and a strict decode means
/// one unexpected element logs the user out with no visible reason.
struct ReadyData: Decodable {
    var user: DiscordUser
    var sessionId: String
    var resumeGatewayUrl: String?
    var guilds: [Guild]
    var privateChannels: [Channel]
    var users: [DiscordUser]
    var readState: RawJSON?
    /// Guild IDs in the order Discord has saved for this account (may be empty).
    var guildOrder: [Snowflake] = []
    /// channelID -> last message the user has read.
    var lastReadByChannel: [Snowflake: Snowflake] = [:]

    private enum CodingKeys: String, CodingKey {
        case user, sessionId, resumeGatewayUrl, guilds, privateChannels, users,
             readState, userSettingsProto
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The session is only usable with these two, so they stay required.
        user = try c.decode(DiscordUser.self, forKey: .user)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        resumeGatewayUrl = try? c.decodeIfPresent(String.self, forKey: .resumeGatewayUrl)
        guilds = c.decodeLossyArray(Guild.self, forKey: .guilds) ?? []
        privateChannels = c.decodeLossyArray(Channel.self, forKey: .privateChannels) ?? []
        users = c.decodeLossyArray(DiscordUser.self, forKey: .users) ?? []
        readState = try? c.decodeIfPresent(RawJSON.self, forKey: .readState)
        if let proto = try? c.decodeIfPresent(String.self, forKey: .userSettingsProto) {
            guildOrder = GuildOrderProto.order(fromBase64: proto)
        }
        // read_state arrives either as a bare array or wrapped in {entries:[…]}.
        if let raw = readState?.data,
           let obj = try? JSONSerialization.jsonObject(with: raw) {
            let entries = (obj as? [[String: Any]])
                ?? ((obj as? [String: Any])?["entries"] as? [[String: Any]])
                ?? []
            for e in entries {
                if let id = e["id"] as? String, let last = e["last_message_id"] as? String {
                    lastReadByChannel[id] = last
                }
            }
        }
    }
}

/// A dynamic JSON value so we can re-decode `d` into the right concrete type.
struct RawJSON: Codable {
    let data: Data
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(JSONValue.self) {
            data = (try? JSONEncoder().encode(v)) ?? Data("null".utf8)
        } else {
            data = Data("null".utf8)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(JSONValue(fromData: data))
    }
    func decode<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder) -> T? {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // Never swallow this: a silent decode failure is indistinguishable
            // from "the server sent nothing", which is exactly how the original
            // connection bug hid for two builds.
            Diag.gateway("decode \(T.self) failed: \(Self.describe(error))", .error)
            return nil
        }
    }

    /// Turns a DecodingError into something that names the offending field.
    static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch e {
        case .keyNotFound(let key, let ctx):
            return "missing key '\(key.stringValue)' at \(path(ctx))"
        case .typeMismatch(let type, let ctx):
            return "type mismatch, expected \(type) at \(path(ctx))"
        case .valueNotFound(let type, let ctx):
            return "null value for \(type) at \(path(ctx))"
        case .dataCorrupted(let ctx):
            return "corrupted data at \(path(ctx)): \(ctx.debugDescription)"
        @unknown default:
            return String(describing: e)
        }
    }

    var byteCount: Int { data.count }
}

/// Minimal recursive JSON model used to round-trip arbitrary `d` payloads.
indirect enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), null
    case object([String: JSONValue]), array([JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .null }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        }
    }
    init(fromData data: Data) {
        self = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }
}

// MARK: - Dispatch payloads

struct TypingStart: Decodable {
    let channelId: Snowflake
    let userId: Snowflake
    let guildId: Snowflake?
    let timestamp: Int?
}

struct MessageDeletePayload: Decodable {
    let id: Snowflake
    let channelId: Snowflake
    let guildId: Snowflake?
}

struct MessageReactionPayload: Decodable {
    let userId: Snowflake
    let channelId: Snowflake
    let messageId: Snowflake
    let guildId: Snowflake?
    let emoji: Emoji
}

struct ChannelPinsUpdate: Decodable {
    let channelId: Snowflake
    let guildId: Snowflake?
}
