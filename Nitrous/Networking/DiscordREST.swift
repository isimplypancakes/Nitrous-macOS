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
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Discord/1.0"
    private static let superProperties: String = {
        let props: [String: Any] = [
            "os": "iOS", "browser": "Discord iOS", "device": "iPhone",
            "system_locale": "en-US", "browser_user_agent": userAgent,
            "browser_version": "", "os_version": "17.0", "referrer": "",
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

    func sendMessage(channelID: Snowflake, content: String, nonce: String? = nil, replyTo: Snowflake? = nil) async throws -> Message {
        var payload: [String: Any] = ["content": content, "tts": false]
        if let nonce { payload["nonce"] = nonce }
        if let replyTo {
            payload["message_reference"] = ["message_id": replyTo, "channel_id": channelID]
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await send(makeRequest("POST", "/channels/\(channelID)/messages", body: body))
        return try decoder.decode(Message.self, from: data)
    }

    /// Sends a message with file attachments using multipart/form-data.
    func sendMessage(channelID: Snowflake, content: String,
                     attachments: [(filename: String, data: Data, mime: String)],
                     nonce: String? = nil, replyTo: Snowflake? = nil) async throws -> Message {
        let boundary = "----NitrousBoundary\(UUID().uuidString)"
        var payload: [String: Any] = ["content": content, "tts": false]
        if let nonce { payload["nonce"] = nonce }
        if let replyTo {
            payload["message_reference"] = ["message_id": replyTo, "channel_id": channelID]
        }
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
