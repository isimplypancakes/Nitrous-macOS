import Foundation

struct DiscordAPIError: LocalizedError {
    var status: Int
    var code: Int?
    var message: String?
    var captchaRequired: Bool = false
    var errorDescription: String? {
        if captchaRequired { return "Discord requires a CAPTCHA for this login. Use a login token instead (see Add Account → Token)." }
        return message ?? "Request failed (HTTP \(status))."
    }
}

/// Result of an email/password login attempt.
enum LoginResult {
    case success(token: String)
    case mfa(ticket: String, totp: Bool, sms: Bool)
    case captcha
}

/// Talks to Discord's REST API. One instance per active account/token.
final class DiscordREST {
    static let apiBase = "https://discord.com/api/v9"
    var token: String?

    private let session: URLSession
    let decoder: JSONDecoder

    init(token: String? = nil) {
        self.token = token
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.httpAdditionalHeaders = ["Accept": "application/json"]
        session = URLSession(configuration: cfg)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    // Client identification (helps requests look like a real client).
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Discord/1.0"
    private static let superProperties: String = {
        let props: [String: Any] = [
            "os": "macOS", "browser": "Discord Mac", "device": "",
            "system_locale": "en-US", "browser_user_agent": userAgent,
            "browser_version": "", "os_version": "14.0", "referrer": "",
            "referring_domain": "", "release_channel": "stable",
            "client_build_number": 250000, "client_event_source": NSNull()
        ]
        let data = (try? JSONSerialization.data(withJSONObject: props)) ?? Data()
        return data.base64EncodedString()
    }()

    private func makeRequest(_ method: String, _ path: String, body: Data? = nil, auth: Bool = true) -> URLRequest {
        var req = URLRequest(url: URL(string: Self.apiBase + path)!)
        req.httpMethod = method
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Self.superProperties, forHTTPHeaderField: "X-Super-Properties")
        req.setValue("en-US", forHTTPHeaderField: "X-Discord-Locale")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if auth, let token { req.setValue(token, forHTTPHeaderField: "Authorization") }
        return req
    }

    /// Core request runner with rate-limit retry and structured error decoding.
    @discardableResult
    private func send(_ req: URLRequest, retries: Int = 2) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return data }

        let path = req.url?.path ?? "?"
        switch http.statusCode {
        case 200...299:
            Diag.rest("\(req.httpMethod ?? "?") \(path) -> \(http.statusCode) (\(data.count) bytes)")
            return data
        case 429 where retries > 0:
            Diag.rest("\(path) rate limited, retrying", .warn)
            let retryAfter = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["retry_after"] as? Double ?? 1
            try await Task.sleep(nanoseconds: UInt64((retryAfter + 0.1) * 1_000_000_000))
            return try await send(req, retries: retries - 1)
        default:
            Diag.rest("\(req.httpMethod ?? "?") \(path) -> \(http.statusCode)", .error)
            var err = DiscordAPIError(status: http.statusCode)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                err.code = obj["code"] as? Int
                err.message = obj["message"] as? String
                if obj["captcha_key"] != nil { err.captchaRequired = true }
            }
            throw err
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send(makeRequest("GET", path))
        return try decoder.decode(T.self, from: data)
    }

    // MARK: Auth

    func login(email: String, password: String) async throws -> LoginResult {
        let body = try JSONSerialization.data(withJSONObject: [
            "login": email, "password": password, "undelete": false,
            "login_source": NSNull(), "gift_code_sha256": NSNull()
        ])
        let req = makeRequest("POST", "/auth/login", body: body, auth: false)
        do {
            let data = try await send(req)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if let token = obj["token"] as? String { return .success(token: token) }
            if let ticket = obj["ticket"] as? String, (obj["mfa"] as? Bool ?? false) {
                return .mfa(ticket: ticket, totp: obj["totp"] as? Bool ?? true, sms: obj["sms"] as? Bool ?? false)
            }
            if obj["captcha_key"] != nil { return .captcha }
            throw DiscordAPIError(status: 400, message: "Unexpected login response.")
        } catch let e as DiscordAPIError where e.captchaRequired {
            return .captcha
        }
    }

    func mfaTotp(code: String, ticket: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "ticket": ticket])
        let data = try await send(makeRequest("POST", "/auth/mfa/totp", body: body, auth: false))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let token = obj["token"] as? String else {
            throw DiscordAPIError(status: 400, message: "Invalid two-factor code.")
        }
        return token
    }

    // MARK: Users & guilds

    func me() async throws -> DiscordUser { try await get("/users/@me") }
    func guilds() async throws -> [Guild] { try await get("/users/@me/guilds") }
    func channels(guildID: Snowflake) async throws -> [Channel] { try await get("/guilds/\(guildID)/channels") }
    func dmChannels() async throws -> [Channel] { try await get("/users/@me/channels") }

    func createDM(recipientID: Snowflake) async throws -> Channel {
        let body = try JSONSerialization.data(withJSONObject: ["recipient_id": recipientID])
        let data = try await send(makeRequest("POST", "/users/@me/channels", body: body))
        return try decoder.decode(Channel.self, from: data)
    }

    // MARK: Messages

    func messages(channelID: Snowflake, limit: Int = 50, before: Snowflake? = nil) async throws -> [Message] {
        var path = "/channels/\(channelID)/messages?limit=\(limit)"
        if let before { path += "&before=\(before)" }
        return try await get(path)
    }

    /// The full member roster for the member panel. READY doesn't carry members
    /// on the user gateway, so this is loaded lazily per guild, like the
    /// official client's member list.
    func guildMembers(guildID: Snowflake, limit: Int = 1000) async throws -> [GuildMember] {
        try await get("/guilds/\(guildID)/members?limit=\(limit)")
    }

    func guildRoles(guildID: Snowflake) async throws -> [Role] {
        try await get("/guilds/\(guildID)/roles")
    }

    /// Public metadata for an application (used to name a Rich Presence app
    /// when the app itself leaves `activity.name` blank). Tolerant: private apps
    /// 403 and we just fall back to the raw client id.
    func applicationInfo(clientID: String) async throws -> (name: String, icon: String?) {
        struct Info: Decodable {
            var name: String?
            var icon: String?
        }
        let info: Info = try await get("/applications/\(clientID)/public")
        return (info.name ?? clientID, info.icon)
    }

    /// Discord's message search, hit per conversation snippet. The FIRST message
    /// of each snippet is the matched message; the rest is its surrounding
    /// context. Tolerant decode: one bad snippet must never kill the whole search.
    struct MessageSearchResponse: Decodable {
        var totalResults: Int = 0
        var messages: [[Message]] = []

        private enum CodingKeys: String, CodingKey { case totalResults, messages }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            totalResults = (try? c.decodeIfPresent(Int.self, forKey: .totalResults)) ?? 0
            messages = c.decodeLossyArray([Message].self, forKey: .messages) ?? []
        }
    }

    func searchMessages(guildID: Snowflake, channelID: Snowflake? = nil, query: String,
                        authorID: Snowflake? = nil, sort: String = "desc",
                        offset: Int = 0, limit: Int = 25) async throws -> MessageSearchResponse {
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "per_page", value: String(limit)),
            URLQueryItem(name: "include_nsfw", value: "true")
        ]
        if let authorID { items.append(URLQueryItem(name: "author_id", value: authorID)) }
        if let channelID { items.append(URLQueryItem(name: "channel_id", value: channelID)) }
        let path = "/guilds/\(guildID)/messages/search"
        guard var comps = URLComponents(string: Self.apiBase + path) else {
            throw DiscordAPIError(status: 0, code: nil, message: "Couldn't build search URL.")
        }
        comps.queryItems = items
        let suffix = comps.url?.query.map { "?\($0)" } ?? ""
        let data = try await send(makeRequest("GET", path + suffix))
        return try decoder.decode(MessageSearchResponse.self, from: data)
    }

    /// DM search is scoped to a single conversation via `/channels/{id}/messages/search`.
    func searchMessages(inChannel channelID: Snowflake, query: String,
                        authorID: Snowflake? = nil, sort: String = "desc",
                        offset: Int = 0, limit: Int = 25) async throws -> MessageSearchResponse {
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "per_page", value: String(limit)),
            URLQueryItem(name: "include_nsfw", value: "true")
        ]
        if let authorID { items.append(URLQueryItem(name: "author_id", value: authorID)) }
        let path = "/channels/\(channelID)/messages/search"
        guard var comps = URLComponents(string: Self.apiBase + path) else {
            throw DiscordAPIError(status: 0, code: nil, message: "Couldn't build search URL.")
        }
        comps.queryItems = items
        let suffix = comps.url?.query.map { "?\($0)" } ?? ""
        let data = try await send(makeRequest("GET", path + suffix))
        return try decoder.decode(MessageSearchResponse.self, from: data)
    }

    // MARK: GIF picker

    /// Klipy is what Discord's own picker serves. Their public API needs a
    /// per-app key (free to create at https://partner.klipy.com); the user
    /// pastes it into the picker and it's stored in UserDefaults. Discord's own
    /// `/gif-picker/*` endpoints are retired (they 404), so favorites are
    /// kept locally.
    static var klipyKey: String {
        UserDefaults.standard.string(forKey: "klipyAPIKey") ?? ""
    }

    func gifTrending(limit: Int = 28) async throws -> [GIFItem] {
        try await klipy("/v2/featured", query: nil, limit: limit)
    }

    func gifSearch(_ text: String, limit: Int = 28) async throws -> [GIFItem] {
        try await klipy("/v2/search", query: text, limit: limit)
    }

    /// Runs directly against `api.klipy.com` (no Discord auth involved) using
    /// the Tenor-compatible v2 API — same `results/[]/media_formats` shape we've
    /// always parsed. An invalid or missing key returns `{"result":false,...}`.
    private func klipy(_ path: String, query: String?, limit: Int) async throws -> [GIFItem] {
        let key = Self.klipyKey
        guard !key.isEmpty else {
            throw DiscordAPIError(status: 0, code: nil,
                                  message: "Browsing GIFs needs a Klipy API key — set one in the GIF picker.")
        }
        var items = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "limit", value: String(min(limit, 50))),
            URLQueryItem(name: "locale", value: "en_US"),
            URLQueryItem(name: "country", value: "US"),
            URLQueryItem(name: "contentfilter", value: "high"),
            URLQueryItem(name: "media_filter", value: "gif,tinygif,mediumgif")
        ]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        guard let base = URLComponents(string: "https://api.klipy.com" + path),
              var comps = URLComponents(url: base.url!, resolvingAgainstBaseURL: false) else {
            throw DiscordAPIError(status: 0, code: nil, message: "Couldn't build Klipy URL.")
        }
        comps.queryItems = items
        guard let url = comps.url else {
            throw DiscordAPIError(status: 0, code: nil, message: "Couldn't build Klipy URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw DiscordAPIError(status: 0, code: nil, message: "Klipy request failed.")
        }
        if http.statusCode != 200 {
            Diag.rest("GET \(path) -> \(http.statusCode)", .error)
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["errors"] as? [String: Any] }
                .flatMap { $0["message"] as? [String] }?.first
            throw DiscordAPIError(status: http.statusCode, code: nil,
                                  message: message ?? "Klipy request failed (HTTP \(http.statusCode))")
        }
        Diag.rest("GET \(path) -> \(http.statusCode) (\(data.count) bytes)")
        return try GIFPayload.items(from: data, hint: query == nil ? "klipy featured" : "klipy search")
    }

    /// Discord keeps gifs favoriteable per account; PUT adds, DELETE removes.
    /// Callers treat failure leniently — these endpoints are on the way out.
    func gifFavorites() async throws -> [GIFItem] {
        let data = try await send(makeRequest("GET", "/gif-picker/favorites?media_format=gif"))
        return try GIFPayload.items(from: data, hint: "favorites")
    }

    func gifSetFavorite(id: String, _ favorited: Bool) async throws {
        _ = try await send(makeRequest(favorited ? "PUT" : "DELETE", "/gif-picker/favorites/\(id)"))
    }

    func sendMessage(channelID: Snowflake, content: String, nonce: String? = nil,
                     replyTo: Snowflake? = nil, stickerIDs: [Snowflake]? = nil) async throws -> Message {
        var payload: [String: Any] = ["content": content, "tts": false]
        if let nonce { payload["nonce"] = nonce }
        if let replyTo {
            payload["message_reference"] = ["message_id": replyTo, "channel_id": channelID]
        }
        if let stickerIDs { payload["sticker_ids"] = stickerIDs }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await send(makeRequest("POST", "/channels/\(channelID)/messages", body: body))
        return try decoder.decode(Message.self, from: data)
    }

    /// Sends a message with file attachments using multipart/form-data.
    func sendMessage(channelID: Snowflake, content: String,
                     attachments: [(filename: String, data: Data, mime: String)],
                     nonce: String? = nil, replyTo: Snowflake? = nil,
                     stickerIDs: [Snowflake]? = nil) async throws -> Message {
        let boundary = "----NitrousBoundary\(UUID().uuidString)"
        var payload: [String: Any] = ["content": content, "tts": false]
        if let nonce { payload["nonce"] = nonce }
        if let replyTo {
            payload["message_reference"] = ["message_id": replyTo, "channel_id": channelID]
        }
        if let stickerIDs { payload["sticker_ids"] = stickerIDs }
        // Discord wants an `attachments` manifest matching the file parts.
        payload["attachments"] = attachments.enumerated().map { i, a in
            ["id": "\(i)", "filename": a.filename]
        }

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"payload_json\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(try JSONSerialization.data(withJSONObject: payload))
        append("\r\n")

        for (i, a) in attachments.enumerated() {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"files[\(i)]\"; filename=\"\(a.filename)\"\r\n")
            append("Content-Type: \(a.mime)\r\n\r\n")
            body.append(a.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")

        var req = makeRequest("POST", "/channels/\(channelID)/messages")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        Diag.rest("uploading \(attachments.count) attachment(s), \(body.count / 1024) KB")
        let data = try await send(req)
        return try decoder.decode(Message.self, from: data)
    }

    func editMessage(channelID: Snowflake, messageID: Snowflake, content: String) async throws -> Message {
        let body = try JSONSerialization.data(withJSONObject: ["content": content])
        let data = try await send(makeRequest("PATCH", "/channels/\(channelID)/messages/\(messageID)", body: body))
        return try decoder.decode(Message.self, from: data)
    }

    func deleteMessage(channelID: Snowflake, messageID: Snowflake) async throws {
        try await send(makeRequest("DELETE", "/channels/\(channelID)/messages/\(messageID)"))
    }

    // MARK: Moderation

    /// Bulk-deletes up to 100 messages (Discord's own cap). Messages older than
    /// 14 days cannot be bulk-deleted — filter them out at the call site.
    func bulkDeleteMessages(channelID: Snowflake, messageIDs: [Snowflake]) async throws {
        guard !messageIDs.isEmpty else { return }
        let ids = Array(Array(messageIDs.prefix(100)))
        let body = try JSONSerialization.data(withJSONObject: ["messages": ids])
        try await send(makeRequest("POST", "/channels/\(channelID)/messages/bulk-delete", body: body))
    }

    /// Clears a member's timeout. `until` is when the time-out lifts.
    func timeoutUser(guildID: Snowflake, userID: Snowflake,
                     until: Date) async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = try JSONSerialization.data(
            withJSONObject: ["communication_disabled_until": formatter.string(from: until)])
        try await send(makeRequest("PATCH", "/guilds/\(guildID)/members/\(userID)", body: body))
    }

    func kickUser(guildID: Snowflake, userID: Snowflake) async throws {
        try await send(makeRequest("DELETE", "/guilds/\(guildID)/members/\(userID)"))
    }

    func banUser(guildID: Snowflake, userID: Snowflake,
                 reason: String? = nil, deleteMessageDays: Int? = 0) async throws {
        var body: [String: Any] = [:]
        if let dayCount = deleteMessageDays { body["delete_message_days"] = dayCount }
        if let reason { body["reason"] = reason }
        let data = try JSONSerialization.data(withJSONObject: body)
        try await send(makeRequest("PUT", "/guilds/\(guildID)/bans/\(userID)", body: data))
    }

    func unbanUser(guildID: Snowflake, userID: Snowflake) async throws {
        try await send(makeRequest("DELETE", "/guilds/\(guildID)/bans/\(userID)"))
    }

    func triggerTyping(channelID: Snowflake) async throws {
        try await send(makeRequest("POST", "/channels/\(channelID)/typing"))
    }

    // MARK: Reactions

    private func encodeEmoji(_ emoji: Emoji) -> String {
        if let id = emoji.id, let name = emoji.name { return "\(name):\(id)" }
        let raw = emoji.name ?? ""
        return raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? raw
    }

    func addReaction(channelID: Snowflake, messageID: Snowflake, emoji: Emoji) async throws {
        let e = encodeEmoji(emoji)
        try await send(makeRequest("PUT", "/channels/\(channelID)/messages/\(messageID)/reactions/\(e)/@me"))
    }

    func removeReaction(channelID: Snowflake, messageID: Snowflake, emoji: Emoji) async throws {
        let e = encodeEmoji(emoji)
        try await send(makeRequest("DELETE", "/channels/\(channelID)/messages/\(messageID)/reactions/\(e)/@me"))
    }
}
