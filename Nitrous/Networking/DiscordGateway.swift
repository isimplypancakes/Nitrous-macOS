import Foundation

/// High-level events emitted from the Gateway to the app layer.
enum GatewayEvent {
    case ready(ReadyData)
    case resumed
    case messageCreate(Message)
    case messageUpdate(Message)
    case messageDelete(MessageDeletePayload)
    case typingStart(TypingStart)
    case presenceUpdate(Presence)
    case guildCreate(Guild)
    case channelCreate(Channel)
    case channelUpdate(Channel)
    case reactionAdd(MessageReactionPayload)
    case reactionRemove(MessageReactionPayload)
    case messageAck(MessageAckPayload)
    case guildMembersChunk(GuildMembersChunk)
    case connectionStateChanged(GatewayState)
    case failed(String)
}

enum GatewayState: Equatable {
    case disconnected
    case connecting
    case connected
    case ready
    case reconnecting
}

/// Maintains the Discord Gateway (v10) WebSocket for one account.
/// Handles HELLO/heartbeat, IDENTIFY, RESUME, dispatch decoding and reconnection.
final class DiscordGateway {
    private let gatewayURL = "wss://gateway.discord.gg/?v=10&encoding=json"
    private let token: String
    private let decoder: JSONDecoder

    private var task: URLSessionWebSocketTask?
    private var session: URLSession
    private var heartbeatTimer: Task<Void, Never>?
    private var sequence: Int?
    private var sessionId: String?
    private var resumeURL: String?
    private var lastAckReceived = true
    private var shouldReconnect = true
    private var isResuming = false
    private var attempts = 0

    /// Delivered on the main actor for direct store mutation.
    var onEvent: ((GatewayEvent) -> Void)?

    init(token: String) {
        self.token = token
        session = URLSession(configuration: .default)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    // MARK: Lifecycle

    func connect() {
        shouldReconnect = true
        attempts = 0
        openSocket(resume: false)
    }

    func disconnect() {
        shouldReconnect = false
        heartbeatTimer?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        emit(.connectionStateChanged(.disconnected))
    }

    private func openSocket(resume: Bool) {
        isResuming = resume
        emit(.connectionStateChanged(resume ? .reconnecting : .connecting))
        let urlString = (resume ? resumeURL : nil).map { "\($0)?v=10&encoding=json" } ?? gatewayURL
        guard let url = URL(string: urlString) else { return }
        let t = session.webSocketTask(with: url)
        // URLSessionWebSocketTask defaults to a 1 MiB limit. A real user's READY
        // is routinely several MB, so the receive fails before any parsing can
        // happen — which presents as an endless connect/disconnect loop rather
        // than an error. This single line is what made the app unusable.
        t.maximumMessageSize = 32 * 1024 * 1024
        task = t
        Diag.gateway("opening socket (resume: \(resume)) -> \(url.host ?? "?")")
        t.resume()
        receive()
    }

    // MARK: Receive loop

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                let ns = error as NSError
                Diag.gateway("receive failed: \(error.localizedDescription) [\(ns.domain) \(ns.code)]", .error)
                self.handleClose(error: error)
            case .success(let message):
                switch message {
                case .string(let text): self.handleFrame(Data(text.utf8))
                case .data(let data): self.handleFrame(data)
                @unknown default: break
                }
                self.receive()
            }
        }
    }

    private func handleClose(error: Error? = nil) {
        heartbeatTimer?.cancel()
        let code = task?.closeCode.rawValue ?? 0
        Diag.gateway("closed (code \(code) — \(Self.closeMeaning(code)))",
                     code == 1000 ? .info : .warn)
        emit(.connectionStateChanged(.disconnected))

        // Some codes can never succeed on retry; looping on them is what made
        // this look like an endless "Connecting…" with no explanation.
        if let fatal = Self.fatalMessage(for: code) {
            shouldReconnect = false
            Diag.gateway("fatal: \(fatal)", .error)
            emit(.failed(fatal))
            return
        }
        guard shouldReconnect else { return }

        attempts += 1
        if attempts > 6 {
            let detail = error?.localizedDescription ?? "close code \(code)"
            Diag.gateway("giving up after \(attempts) attempts (\(detail))", .error)
            emit(.failed("Couldn't stay connected. Last error: \(detail)"))
            return
        }

        let backoff = min(30.0, pow(2.0, Double(attempts)))
        Diag.gateway("reconnecting in \(Int(backoff))s (attempt \(attempts))")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            guard let self, self.shouldReconnect else { return }
            self.openSocket(resume: self.sessionId != nil && self.resumeURL != nil)
        }
    }

    /// Human meaning for the close codes Discord actually sends.
    static func closeMeaning(_ code: Int) -> String {
        switch code {
        case 0: return "no code / transport failure"
        case 1000: return "normal"
        case 1001: return "going away"
        case 1006: return "abnormal — connection dropped"
        case 1009: return "message too big for the client buffer"
        case 4000: return "unknown error"
        case 4001: return "unknown opcode"
        case 4002: return "decode error — we sent malformed data"
        case 4003: return "not authenticated"
        case 4004: return "authentication failed — bad token"
        case 4005: return "already authenticated"
        case 4007: return "invalid resume sequence"
        case 4008: return "rate limited"
        case 4009: return "session timed out"
        case 4010: return "invalid shard"
        case 4011: return "sharding required"
        case 4012: return "invalid API version"
        case 4013: return "invalid intents"
        case 4014: return "disallowed intents"
        default: return "unrecognized"
        }
    }

    /// Non-retryable failures, phrased for the user.
    static func fatalMessage(for code: Int) -> String? {
        switch code {
        case 4004: return "Discord rejected your login. Sign in again."
        case 4010, 4011: return "This account needs sharding, which this client doesn't support."
        case 4012: return "This client is using an unsupported Discord API version."
        case 4013, 4014: return "Discord rejected the connection's permissions."
        default: return nil
        }
    }

    // MARK: Frame handling

    private func handleFrame(_ data: Data) {
        guard let frame = try? decoder.decode(GatewayFrame.self, from: data) else {
            Diag.gateway("unparseable frame (\(data.count) bytes)", .error)
            return
        }
        if let t = frame.t {
            Diag.gateway("<- \(t) (\(data.count) bytes)")
        }
        if let s = frame.s { sequence = s }

        switch GatewayOpcode(rawValue: frame.op) {
        case .hello:
            if let hello = frame.d?.decode(HelloData.self, using: decoder) {
                Diag.gateway("<- HELLO, heartbeat every \(hello.heartbeatInterval)ms")
                startHeartbeat(interval: hello.heartbeatInterval)
            }
            if isResuming { sendResume() } else { sendIdentify() }
        case .heartbeat:
            sendHeartbeat()
        case .heartbeatAck:
            lastAckReceived = true
        case .reconnect:
            reconnectResuming()
        case .invalidSession:
            // Cannot resume — reidentify from scratch after a short delay.
            sessionId = nil; resumeURL = nil
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.sendIdentify()
            }
        case .dispatch:
            handleDispatch(type: frame.t, payload: frame.d)
        default:
            break
        }
    }

    private func handleDispatch(type: String?, payload: RawJSON?) {
        guard let type, let payload else { return }
        switch type {
        case "READY":
            if let ready = payload.decode(ReadyData.self, using: decoder) {
                sessionId = ready.sessionId
                resumeURL = ready.resumeGatewayUrl
                attempts = 0
                Diag.gateway("READY: \(ready.guilds.count) guilds, \(ready.privateChannels.count) DMs, user \(ready.user.username)", .success)
                emit(.connectionStateChanged(.ready))
                emit(.ready(ready))
            } else {
                // Never fail silently: without this the app sits on an empty
                // server list with no explanation (the original device bug).
                emit(.failed("Couldn't read Discord's session data."))
            }
        case "RESUMED":
            emit(.connectionStateChanged(.ready)); emit(.resumed)
        case "MESSAGE_CREATE":
            if let m = payload.decode(Message.self, using: decoder) { emit(.messageCreate(m)) }
        case "MESSAGE_UPDATE":
            if let m = payload.decode(Message.self, using: decoder) { emit(.messageUpdate(m)) }
        case "MESSAGE_DELETE":
            if let p = payload.decode(MessageDeletePayload.self, using: decoder) { emit(.messageDelete(p)) }
        case "TYPING_START":
            if let p = payload.decode(TypingStart.self, using: decoder) { emit(.typingStart(p)) }
        case "PRESENCE_UPDATE":
            if let p = payload.decode(Presence.self, using: decoder) { emit(.presenceUpdate(p)) }
        case "GUILD_CREATE":
            if let g = payload.decode(Guild.self, using: decoder) { emit(.guildCreate(g)) }
        case "CHANNEL_CREATE":
            if let c = payload.decode(Channel.self, using: decoder) { emit(.channelCreate(c)) }
        case "CHANNEL_UPDATE":
            if let c = payload.decode(Channel.self, using: decoder) { emit(.channelUpdate(c)) }
        case "MESSAGE_REACTION_ADD":
            if let p = payload.decode(MessageReactionPayload.self, using: decoder) { emit(.reactionAdd(p)) }
        case "MESSAGE_REACTION_REMOVE":
            if let p = payload.decode(MessageReactionPayload.self, using: decoder) { emit(.reactionRemove(p)) }
        case "MESSAGE_ACK":
            if let p = payload.decode(MessageAckPayload.self, using: decoder) { emit(.messageAck(p)) }
        case "GUILD_MEMBERS_CHUNK":
            if let c = payload.decode(GuildMembersChunk.self, using: decoder) { emit(.guildMembersChunk(c)) }
        default:
            break
        }
    }

    // MARK: Outbound

    private func sendIdentify() {
        Diag.gateway("-> IDENTIFY")
        let properties: [String: Any] = [
            "os": "macOS", "browser": "Discord Mac", "device": "",
            "system_locale": "en-US", "release_channel": "stable",
            "client_version": "1.0", "os_version": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        let payload: [String: Any] = [
            "op": GatewayOpcode.identify.rawValue,
            "d": [
                "token": token,
                "capabilities": 16381,
                "properties": properties,
                "presence": ["status": "online", "since": 0, "activities": [], "afk": false],
                "compress": false,
                "client_state": ["guild_versions": [:]]
            ]
        ]
        sendJSON(payload)
    }

    private func sendResume() {
        guard let sessionId else { sendIdentify(); return }
        Diag.gateway("-> RESUME (seq \(sequence ?? 0))")
        let payload: [String: Any] = [
            "op": GatewayOpcode.resume.rawValue,
            "d": ["token": token, "session_id": sessionId, "seq": sequence ?? 0]
        ]
        sendJSON(payload)
    }

    private func reconnectResuming() {
        heartbeatTimer?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        openSocket(resume: sessionId != nil && resumeURL != nil)
    }

    private func startHeartbeat(interval ms: Int) {
        heartbeatTimer?.cancel()
        lastAckReceived = true
        heartbeatTimer = Task { [weak self] in
            // Jitter the first beat as the docs recommend.
            try? await Task.sleep(nanoseconds: UInt64(Double(ms) * 0.5 * 1_000_000))
            while let self, !Task.isCancelled {
                if !self.lastAckReceived {
                    self.reconnectResuming()
                    return
                }
                self.lastAckReceived = false
                self.sendHeartbeat()
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            }
        }
    }

    private func sendHeartbeat() {
        // `d` must be JSON null when we have no sequence yet. Passing a Swift
        // Optional here makes JSONSerialization fail, which silently drops the
        // heartbeat and gets the connection closed by the server.
        let payload: [String: Any] = [
            "op": GatewayOpcode.heartbeat.rawValue,
            "d": sequence.map { $0 as Any } ?? NSNull()
        ]
        sendJSON(payload)
    }

    /// Asks Discord to stream a guild's full roster as `GUILD_MEMBERS_CHUNK`
    /// events — the desktop client's own path. `query: ""` + `limit: 0` means
    /// "everyone", which user tokens are allowed to request over the gateway
    /// even where the REST members endpoint is locked down.
    func requestMembers(guildID: Snowflake) {
        Diag.gateway("-> REQUEST_GUILD_MEMBERS \(guildID)")
        let payload: [String: Any] = [
            "op": GatewayOpcode.requestGuildMembers.rawValue,
            "d": ["guild_id": guildID, "query": "", "limit": 0, "presences": true]
        ]
        sendJSON(payload)
    }

    /// Broadcasts the user's own presence: status plus whatever activities the
    /// Rich Presence IPC listener fed in. Discord fills in id/created_at itself.
    func updatePresence(status: String, activities: [Presence.Activity]) {
        let enc = JSONEncoder()
        var acts: [Any] = []
        for a in activities {
            if let data = try? enc.encode(a),
               let obj = try? JSONSerialization.jsonObject(with: data) { acts.append(obj) }
        }
        let payload: [String: Any] = [
            "op": GatewayOpcode.presenceUpdate.rawValue,
            "d": ["status": status, "since": 0, "activities": acts, "afk": false]
        ]
        sendJSON(payload)
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else {
            Diag.gateway("failed to serialize outbound payload op \(obj["op"] ?? "?")", .error)
            return
        }
        task?.send(.string(str)) { error in
            if let error { Diag.gateway("send failed: \(error.localizedDescription)", .error) }
        }
    }

    private func emit(_ event: GatewayEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }
}
