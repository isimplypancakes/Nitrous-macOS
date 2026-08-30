#if os(macOS)
import Foundation

/// Local RPC server that speaks the desktop Discord IPC protocol to apps that
/// want to show Rich Presence (games, spotify-alikes, etc). Apps connect to
/// `/tmp/discord-ipc-N`, handshake, then send `SET_ACTIVITY` frames. That's the
/// job the official client usually does; this server claims the same socket so
/// the calls land here and the activity can be broadcast on THIS account.
final class RichPresenceIPC {

    /// Called for every `SET_ACTIVITY` frame.
    /// - activity: the `args.activity` JSON dict (nil when the app clears).
    /// - clientID: the app's Discord application id (from the handshake).
    var onActivity: ((_ activity: [String: Any]?, _ clientID: String?) -> Void)?

    private enum Opcode: Int {
        case handshake = 0, frame = 1, close = 2, ping = 3, pong = 4
    }

    private let candidates: [String]
    private var listenFds: [Int32] = []
    private var acceptThreads: [Thread] = []
    private let running = Locked(true)

    init(candidates: [String] = ["/tmp/discord-ipc-0"]) {
        self.candidates = candidates
    }

    deinit { stop() }

    func start() {
        guard running.value else { return }
        for path in candidates where bindAndListen(path) {
            Diag.app("RPC: listening on \(path)")
        }
        if listenFds.isEmpty {
            Diag.app("RPC: no IPC socket could be bound", .warn)
        }
    }

    func stop() {
        guard running.value else { return }
        running.value = false
        acceptThreads = []
        for fd in listenFds { close(fd) }
        listenFds = []
    }

    // MARK: Server socket

    /// Binds a unix listening socket at `path`. If another client (e.g. the
    /// official Discord app) already holds it, the stale socket file is unlinked
    /// and rebound so the next app connection routes to us instead.
    private func bindAndListen(_ path: String) -> Bool {
        guard let cPath = (path as NSString).utf8String else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        guard strlen(cPath) < MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size else {
            close(fd)
            return false
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { memcpy($0, cPath, strlen(cPath)) }

        if !bindSocket(fd, &addr) {
            unlink(cPath)
            if !bindSocket(fd, &addr) {
                close(fd)
                return false
            }
            Diag.app("RPC: took over IPC socket at \(path)", .warn)
        }
        guard listen(fd, 8) == 0 else { close(fd); return false }
        listenFds.append(fd)
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "RPC-accept"
        thread.start()
        acceptThreads.append(thread)
        return true
    }

    private func bindSocket(_ fd: Int32, _ addr: inout sockaddr_un) -> Bool {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private func acceptLoop(_ listener: Int32) {
        while running.value {
            let conn = accept(listener, nil, nil)
            if conn < 0 {
                if errno == EINTR { continue }
                break
            }
            let thread = Thread { [weak self] in self?.connectionLoop(conn) }
            thread.name = "RPC-conn"
            thread.start()
        }
    }

    // MARK: Frame I/O

    private func connectionLoop(_ conn: Int32) {
        defer { close(conn) }
        var clientID: String?
        while running.value {
            guard let (opRaw, payload) = readFrame(conn), let op = Opcode(rawValue: Int(opRaw)) else { break }
            var didClose = false
            switch op {
            case .handshake:
                let json = jsonObject(payload) as? [String: Any]
                if let id = json?["client_id"] as? String, Self.isReasonableClientID(id) {
                    clientID = id
                    writeFrame(conn, opcode: .handshake, json: #"{"v":1,"client_id":"294882584201003009","config":{}}"#)
                } else {
                    didClose = true
                }
            case .frame:
                guard let obj = jsonObject(payload) as? [String: Any] else { break }
                let cmd = obj["cmd"] as? String
                let nonce = obj["nonce"]
                if cmd == "SET_ACTIVITY" {
                    let args = obj["args"] as? [String: Any]
                    let activity = args?["activity"] as? [String: Any]
                    onActivity?(activity, clientID)
                    if (args?["no_respond"] as? Bool) != true {
                        writeFrame(conn, opcode: .frame, json: """
                            {"cmd":"SET_ACTIVITY","data":{"valid":true,"evt":"SET_ACTIVITY","response":{}},"evt":null,"nonce":\(nonceJSON(nonce))}
                            """)
                    }
                } else {
                    // Unknown command (GET_GUILDS, SUBSCRIBE…): acknowledge so the
                    // app doesn't hang waiting, but do nothing with it.
                    writeFrame(conn, opcode: .frame, json: """
                        {"cmd":\(jsonString(cmd)),"data":{"code":0},"evt":null,"nonce":\(nonceJSON(nonce))}
                        """)
                }
            case .ping:
                writeFrame(conn, opcode: .pong, raw: payload)
            case .close:
                didClose = true
            case .pong:
                break // stray inbound pong; ignore
            }
            if didClose { break }
        }
    }

    /// A frame is a little-endian 8-byte header (opcode uint32, length uint32)
    /// followed by exactly `length` payload bytes. Reads loop until complete.
    private func readFrame(_ conn: Int32) -> (UInt32, Data)? {
        var header = [UInt8](repeating: 0, count: 8)
        var got = 0
        while got < 8 {
            let n = header[got...].withUnsafeMutableBytes { ptr in
                read(conn, ptr.baseAddress, 8 - got)
            }
            if n <= 0 { return nil }
            got += n
        }
        let op = UInt32(header[0]) | UInt32(header[1]) << 8 | UInt32(header[2]) << 16 | UInt32(header[3]) << 24
        let len = UInt64(header[4]) | UInt64(header[5]) << 8
            | UInt64(header[6]) << 16 | UInt64(header[7]) << 24
        guard len <= 16 * 1024 * 1024 else { return nil }
        var body = Data(count: Int(len))
        got = 0
        while got < len {
            let n = body.withUnsafeMutableBytes { ptr in
                read(conn, ptr.baseAddress!.advanced(by: got), Int(len) - got)
            }
            if n <= 0 { return nil }
            got += n
        }
        return (op, body)
    }

    private func writeFrame(_ conn: Int32, opcode: Opcode, raw: Data) {
        var header = Data([UInt8](repeating: 0, count: 8))
        let op = UInt32(opcode.rawValue)
        header[0] = UInt8(op & 0xFF)
        header[1] = UInt8((op >> 8) & 0xFF)
        header[2] = UInt8((op >> 16) & 0xFF)
        header[3] = UInt8((op >> 24) & 0xFF)
        let len = UInt32(raw.count)
        header[4] = UInt8(len & 0xFF)
        header[5] = UInt8((len >> 8) & 0xFF)
        header[6] = UInt8((len >> 16) & 0xFF)
        header[7] = UInt8((len >> 24) & 0xFF)
        var out = header
        out.append(raw)
        var written = 0
        while written < out.count {
            let n = out[written...].withUnsafeBytes { ptr in
                write(conn, ptr.baseAddress, out.count - written)
            }
            if n <= 0 { return }
            written += n
        }
    }

    private func writeFrame(_ conn: Int32, opcode: Opcode, json: String) {
        writeFrame(conn, opcode: opcode, raw: json.data(using: .utf8) ?? Data())
    }

    private func jsonObject(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    /// Validates the handshake `client_id`. It's the app's own snowflake id and
    /// we don't gate on it — just refuse garbage.
    private static func isReasonableClientID(_ id: String?) -> Bool {
        guard let id, id.count >= 15 else { return false }
        return UInt64(id) != nil
    }

    /// Nonce echo for replies: usually a string or an integer JSON literal.
    private func nonceJSON(_ nonce: Any?) -> String {
        guard let nonce else { return "null" }
        if let s = nonce as? String { return jsonString(s) }
        if let n = nonce as? NSNumber,
           let data = try? JSONSerialization.data(withJSONObject: n),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "null"
    }

    private func jsonString(_ s: String?) -> String {
        guard let s else { return "null" }
        if let data = try? JSONSerialization.data(withJSONObject: s),
           let out = String(data: data, encoding: .utf8) { return out }
        return String(describing: s)
    }
}

/// Tiny thread-safe boolean for the accept loops.
private final class Locked<T> {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
#endif