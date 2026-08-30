import SwiftUI
import AppKit

/// Pre-renders avatars down to a fixed point size and caches them in memory.
///
/// `AvatarView` shows the result of this as a *non-resizable* `Image(nsImage:)`.
/// That's the whole point: on this macOS beta the account-card `Menu` label can
/// hand an `AsyncImage`'s raw file back at intrinsic size (a 128pt "huge"
/// picture that dwarfs the sidebar). A non-resizable image always draws at
/// exactly its own pre-scaled size, so no parent can ever inflate it.
enum AvatarCache {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()
    private static let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2

    static func key(named url: URL?, points: CGFloat) -> String {
        "\(url?.absoluteString ?? "")@\(Int(points * scale))"
    }

    static func image(named url: URL?, points: CGFloat) async -> NSImage? {
        guard let url else { return nil }
        let key = key(named: url, points: points)
        if let hit = lock.withLock({ cache[key] }) { return hit }
        guard let data = try? await URLSession.shared.data(from: url).0,
              let raw = NSImage(data: data) else { return nil }
        let down = square(raw, points: points)
        lock.withLock { cache[key] = down }
        return down
    }

    /// Draws the image as a square cover fit into `points` points.
    private static func square(_ image: NSImage, points: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: points, height: points), flipped: false) { _ in
            let target = NSRect(x: 0, y: 0, width: points, height: points)
            let aspect = image.size.width / image.size.height
            var rect = target
            if aspect > 1 {
                rect.size = NSSize(width: target.height * aspect, height: target.height)
            } else {
                rect.size = NSSize(width: target.width, height: target.width / aspect)
            }
            rect.origin.x = (target.width - rect.width) / 2
            rect.origin.y = (target.height - rect.height) / 2
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
            return true
        }
    }
}

/// Circular avatar with initials fallback.
struct AvatarView: View {
    let url: URL?
    let name: String
    var size: CGFloat = 40
    var seed: String = ""

    @State private var rendered: NSImage?

    var body: some View {
        ZStack {
            if let rendered {
                // Deliberately NOT .resizable(): it must draw at exactly `size`.
                Image(nsImage: rendered)
                    .interpolation(.high)
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: AvatarCache.key(named: url, points: size)) {
            rendered = await AvatarCache.image(named: url, points: size)
        }
    }

    private var initials: some View {
        ZStack {
            LinearGradient(colors: [fallbackColor(for: seed.isEmpty ? name : seed).opacity(0.95),
                                    fallbackColor(for: seed.isEmpty ? name : seed).opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

/// Avatar with a presence dot in the corner, ring stroked in the row background.
struct PresenceAvatar: View {
    let url: URL?
    let name: String
    let status: String?
    var size: CGFloat = 40
    var seed: String = ""
    var ringColor: Color = Color(nsColor: .windowBackgroundColor)

    var body: some View {
        AvatarView(url: url, name: name, size: size, seed: seed)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(Palette.presence(status))
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay(Circle().stroke(ringColor, lineWidth: size * 0.06))
            }
    }
}

/// The dim capsule shown beside a name displaying the member's server tag
/// (e.g. "RAM") plus its badge artwork, matching Discord's tag pill.
struct GuildTagPill: View {
    let user: DiscordUser

    var body: some View {
        if let tag = user.displayTag {
            HStack(spacing: 3) {
                if let badgeURL = user.displayTagBadgeURL {
                    AsyncImage(url: badgeURL) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                        else { Color.clear }
                    }
                    .frame(width: 12, height: 12)
                }
                Text(tag)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Color.secondary.opacity(0.16), in: Capsule())
            .foregroundStyle(.secondary)
        }
    }
}

/// Rounded-square server icon (native app-icon feel), image or initials.
struct ServerIcon: View {
    let guild: Guild
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url = guild.iconURL {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                            .frame(width: size, height: size)
                            .clipped()
                    } else { initials }
                }
            } else { initials }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: some View {
        ZStack {
            LinearGradient(colors: [fallbackColor(for: guild.id),
                                    fallbackColor(for: guild.id).opacity(0.75)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(guild.acronym.isEmpty ? "?" : String(guild.acronym.prefix(2)))
                .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
