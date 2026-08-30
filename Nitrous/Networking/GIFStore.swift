import Foundation
import AppKit
import ImageIO

/// Decompressed GIF frames + per-frame delays, decoded once and shared.
final class GIFAnimation {
    let frames: [NSImage]
    let delays: [TimeInterval]
    let size: CGSize

    init?(data: Data) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        var frames: [NSImage] = []
        var delays: [TimeInterval] = []
        for i in 0..<min(count, 320) {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height))))
            var delay: TimeInterval = 0.05
            if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
               let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval
                let clamped = gif[kCGImagePropertyGIFDelayTime] as? TimeInterval
                delay = max(unclamped ?? clamped ?? 0.05, 0.02)
            }
            delays.append(min(delay, 2))
        }
        guard !frames.isEmpty else { return nil }
        self.frames = frames
        self.delays = delays
        let w = max(frames[0].size.width, 1), h = max(frames[0].size.height, 1)
        self.size = CGSize(width: w, height: h)
    }
}

/// One hardened, browser-identity session for every GIF fetch, with small
/// time-stamped caches. Klipy/Tenor CDN URLs expire and reject bare requests,
/// so each fetch presents a real browser identity and entries are dropped
/// after a short TTL rather than cached forever. Everything worth rendering —
/// chat bubbles, the media viewer, the picker grid — goes through here.
enum GIFStore {
    static let ttl: TimeInterval = 8 * 60

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = URLCache(memoryCapacity: 24_000_000, diskCapacity: 96_000_000)
        let session = URLSession(configuration: config)
        session.sessionDescription = "Nitrous.GIFStore"
        return session
    }()

    private static let lock = NSLock()
    private static var dataCache: [String: (data: Data, date: Date)] = [:]
    private static var animCache: [String: GIFAnimation] = [:]

    /// The GIF bytes for a URL, freshly fetched when the previous copy is older
    /// than the TTL (live CDN links expire). `nil` on any failure — callers
    /// surface their own fallback.
    static func data(for url: URL) async -> Data? {
        let key = url.absoluteString
        if let hit = cachedData(key) { return hit }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("image/webp,image/apng,image/avif,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("https://discord.com/", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                Diag.app("gif fetch HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) \(key.prefix(120))", .error)
                return nil
            }
            setData(key, data)
            return data
        } catch {
            Diag.app("gif fetch failed: \(key.prefix(120)) — \(error.localizedDescription)", .error)
            return nil
        }
    }

    /// The animation for a URL, decoded from already-fetched bytes.
    static func animation(for url: URL, data: Data) -> GIFAnimation? {
        let key = url.absoluteString
        lock.lock(); defer { lock.unlock() }
        if let cached = animCache[key] { return cached }
        guard let anim = GIFAnimation(data: data) else { return nil }
        animCache[key] = anim
        if animCache.count > 120 { animCache = [key: anim] }
        return anim
    }

    private static func cachedData(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = dataCache[key], Date().timeIntervalSince(entry.date) < ttl else {
            dataCache[key] = nil
            return nil
        }
        return entry.data
    }

    private static func setData(_ key: String, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if dataCache.count > 160 {
                let cutoff = Date().addingTimeInterval(-ttl)
                dataCache = dataCache.filter { $0.value.date > cutoff }
                if dataCache.count > 160 { dataCache = Dictionary(uniqueKeysWithValues: dataCache.prefix(120).map { ($0.key, $0.value) }) }
            }
        dataCache[key] = (data, Date())
    }
}