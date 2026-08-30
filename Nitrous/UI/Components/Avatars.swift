import SwiftUI

/// Circular avatar with initials fallback.
struct AvatarView: View {
    let url: URL?
    let name: String
    var size: CGFloat = 40
    var seed: String = ""

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { initials }
                }
            } else { initials }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
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
    var ringColor: Color = Color(.systemBackground)

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

/// Rounded-square server icon (native app-icon feel), image or initials.
struct ServerIcon: View {
    let guild: Guild
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url = guild.iconURL {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { initials }
                }
            } else { initials }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
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
