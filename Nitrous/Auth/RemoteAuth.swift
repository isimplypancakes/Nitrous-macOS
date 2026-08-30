import Foundation
import Security
import CryptoKit

/// Discord's remote-auth ("scan the QR code") login, as used by the desktop app.
///
/// Flow: we generate an RSA keypair and hand Discord the public key. It returns
/// a fingerprint, which we render as a QR code. The user scans it with the
/// official Discord app and approves; Discord then hands us a ticket, which we
/// exchange over REST for the account token — encrypted to our public key, so
/// only this device can read it.
@MainActor
final class RemoteAuthClient: ObservableObject {

    enum Phase: Equatable {
        case connecting
        /// QR is ready to scan; payload is the URL encoded in the code.
        case awaitingScan(url: String)
        /// Scanned — waiting for the user to tap Approve in the Discord app.
        case awaitingApproval(user: ScannedUser)
        case success
        case failed(String)
    }

    struct ScannedUser: Equatable {
        var id: String
        var username: String
        var discriminator: String
        var avatarHash: String
        var avatarURL: URL? {
            CDN.avatar(userID: id, hash: avatarHash.isEmpty ? nil : avatarHash,
                       discriminator: discriminator)
        }
    }

    @Published private(set) var phase: Phase = .connecting

    /// Called with the account token once the user approves.
    var onToken: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var heartbeat: Task<Void, Never>?
    private var privateKey: SecKey?
    private var finished = false

    private let endpoint = "wss://remote-auth-gateway.discord.gg/?v=2"

    // MARK: Lifecycle

    func start() {
        phase = .connecting
        finished = false
        guard let (priv, spkiBase64) = Self.makeKeypair() else {
            phase = .failed("Couldn't create a secure key on this device.")
            return
        }
        privateKey = priv
        pendingPublicKey = spkiBase64

        var req = URLRequest(url: URL(string: endpoint)!)
        // The gateway rejects connections without a browser-like Origin.
        req.setValue("https://discord.com", forHTTPHeaderField: "Origin")
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
    }

    func cancel() {
        finished = true
        heartbeat?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private var pendingPublicKey: String?

    // MARK: Socket

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                Task { @MainActor in self.failIfUnfinished("Connection to Discord was lost.") }
            case .success(let message):
                if case .string(let text) = message {
                    Task { @MainActor in self.handle(text) }
                } else if case .data(let d) = message, let text = String(data: d, encoding: .utf8) {
                    Task { @MainActor in self.handle(text) }
                }
                self.receive()
            }
        }
    }

    private func failIfUnfinished(_ message: String) {
        guard !finished else { return }
        finished = true
        heartbeat?.cancel()
        phase = .failed(message)
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = obj["op"] as? String else { return }

        switch op {
        case "hello":
            let interval = (obj["heartbeat_interval"] as? Double) ?? 41250
            startHeartbeat(ms: interval)
            if let key = pendingPublicKey {
                send(["op": "init", "encoded_public_key": key])
            }

        case "nonce_proof":
            // Prove key ownership: decrypt the nonce, then return its SHA-256.
            guard let encrypted = obj["encrypted_nonce"] as? String,
                  let nonce = decrypt(base64: encrypted) else {
                failIfUnfinished("Couldn't verify this device's key.")
                return
            }
            let digest = SHA256.hash(data: nonce)
            send(["op": "nonce_proof", "proof": Data(digest).base64URLEncodedString()])

        case "pending_remote_init":
            guard let fingerprint = obj["fingerprint"] as? String else { return }
            phase = .awaitingScan(url: "https://discord.com/ra/\(fingerprint)")

        case "pending_ticket":
            // The QR was scanned; Discord tells us who is approving.
            guard let payload = obj["encrypted_user_payload"] as? String,
                  let decrypted = decrypt(base64: payload),
                  let joined = String(data: decrypted, encoding: .utf8) else { return }
            // Format: id:discriminator:avatarHash:username
            let parts = joined.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count >= 4 else { return }
            phase = .awaitingApproval(user: ScannedUser(id: parts[0], username: parts[3],
                                                        discriminator: parts[1], avatarHash: parts[2]))

        case "pending_login":
            guard let ticket = obj["ticket"] as? String else { return }
            exchange(ticket: ticket)

        case "cancel":
            failIfUnfinished("The sign-in was cancelled on your phone.")

        default:
            break
        }
    }

    private func startHeartbeat(ms: Double) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
                guard let self, !Task.isCancelled else { return }
                await MainActor.run { self.send(["op": "heartbeat"]) }
            }
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    // MARK: Token exchange

    private func exchange(ticket: String) {
        Task { @MainActor in
            do {
                let encryptedToken = try await Self.postRemoteAuthLogin(ticket: ticket)
                guard let tokenData = decrypt(base64: encryptedToken),
                      let token = String(data: tokenData, encoding: .utf8) else {
                    failIfUnfinished("Couldn't decrypt the login token.")
                    return
                }
                finished = true
                heartbeat?.cancel()
                phase = .success
                onToken?(token)
                cancel()
            } catch {
                failIfUnfinished(error.localizedDescription)
            }
        }
    }

    private static func postRemoteAuthLogin(ticket: String) async throws -> String {
        var req = URLRequest(url: URL(string: "\(DiscordREST.apiBase)/users/@me/remote-auth/login")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["ticket": ticket])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DiscordAPIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                  message: "Discord rejected the sign-in ticket.")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["encrypted_token"] as? String else {
            throw DiscordAPIError(status: 0, message: "Unexpected response from Discord.")
        }
        return token
    }

    // MARK: Crypto

    /// Generates an RSA-2048 keypair, returning the private key and the
    /// base64 SPKI public key Discord expects.
    private static func makeKeypair() -> (SecKey, String)? {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(priv),
              let der = SecKeyCopyExternalRepresentation(pub, &error) as Data? else { return nil }
        // SecKey gives PKCS#1; Discord wants SPKI, so add the RSA algorithm header.
        return (priv, Self.spki(fromPKCS1: der).base64EncodedString())
    }

    /// Wraps a PKCS#1 RSA public key in the SubjectPublicKeyInfo structure.
    private static func spki(fromPKCS1 pkcs1: Data) -> Data {
        // AlgorithmIdentifier for rsaEncryption, then a BIT STRING of the key.
        let rsaOID: [UInt8] = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
                               0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]
        var bitString = Data([0x00])
        bitString.append(pkcs1)
        var body = Data(rsaOID)
        body.append(derEncode(tag: 0x03, bytes: bitString))
        return derEncode(tag: 0x30, bytes: body)
    }

    private static func derEncode(tag: UInt8, bytes: Data) -> Data {
        var out = Data([tag])
        let count = bytes.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var lengthBytes: [UInt8] = []
            var n = count
            while n > 0 { lengthBytes.insert(UInt8(n & 0xFF), at: 0); n >>= 8 }
            out.append(UInt8(0x80 | lengthBytes.count))
            out.append(contentsOf: lengthBytes)
        }
        out.append(bytes)
        return out
    }

    /// RSA-OAEP-SHA256 decryption with our device private key.
    private func decrypt(base64: String) -> Data? {
        guard let key = privateKey,
              let cipher = Data(base64Encoded: base64) else { return nil }
        var error: Unmanaged<CFError>?
        return SecKeyCreateDecryptedData(key, .rsaEncryptionOAEPSHA256,
                                         cipher as CFData, &error) as Data?
    }
}

extension Data {
    /// base64url without padding, which is what the proof field expects.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
