import SwiftUI
import AppKit

/// Renders a single rich-presence activity the way Discord shows it on desktop:
/// an icon, the app name, and the "details / state" pair, plus a live elapsed
/// timer for anything with a start timestamp.
struct RichPresenceView: View {
    let activity: Presence.Activity

    var body: some View {
        HStack(spacing: 8) {
            artwork
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.name ?? "Activity")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let details = activity.details, !details.isEmpty {
                    Text(details).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    if let state = activity.state, !state.isEmpty {
                        Text(state).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let start = activity.timestamps?.start {
                        Text("·").foregroundStyle(.tertiary)
                        ElapsedTimer(startMs: start)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.tertiaryFill.opacity(0.35))
            if let url = activity.assetImageURL {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { symbol }
                }
            } else {
                symbol
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder private var symbol: some View {
        Image(systemName: activity.activityType.symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(activity.activityType == .streaming ? Color.red : Palette.accent)
    }
}

/// A custom status line: the chosen emoji and the message.
struct CustomStatusView: View {
    let activity: Presence.Activity

    var body: some View {
        HStack(spacing: 6) {
            if let emoji = activity.emoji {
                if emoji.imageURL != nil {
                    AsyncImage(url: emoji.imageURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: { Color.clear }
                    .frame(width: 14, height: 14)
                } else if let name = emoji.name {
                    Text(name).font(.caption)
                }
            }
            if let state = activity.state, !state.isEmpty {
                Text(state).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// A live "Elapsed" ticker for activities with a start timestamp.
struct ElapsedTimer: View {
    let startMs: Int
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let seconds = max(0, Int(Date().timeIntervalSince1970) - startMs / 1000)
            if seconds >= 90 {
                Text("\(seconds / 60)m")
            } else {
                Text("\(seconds)s")
            }
        }
        .font(.caption2).foregroundStyle(.tertiary)
    }
}

extension ActivityType {
    /// The per-type SF Symbol so games, Spotify and YouTube get their own icon.
    var symbol: String {
        switch self {
        case .playing: return "gamecontroller.fill"
        case .streaming: return "play.tv.fill"
        case .listening: return "music.note"
        case .watching: return "play.rectangle.fill"
        case .customStatus: return "face.smiling"
        case .competing: return "trophy.fill"
        }
    }
}