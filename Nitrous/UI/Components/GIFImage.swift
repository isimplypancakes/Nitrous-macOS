import SwiftUI
import AppKit

/// Sniffs a URL to decide how to render media in chat. Discord's own embeds
/// come from klipy/giphy/tenor CDNs, so the host is enough when there's no
/// friendly file extension.
enum MediaLink {
    static func isGIF(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "gif" { return true }
        if ["webp", "png"].contains(ext) { return false }
        let host = (url.host ?? "").lowercased()
        return host.contains("tenor") || host.contains("giphy") || host.contains("klipy")
    }

    static func isVideo(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v", "webm", "mkv"].contains(url.pathExtension.lowercased())
    }

    /// Bare http(s) URLs in a message that look like media we can inline.
    static func mediaURLs(in text: String) -> [URL] {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s<>"]+"#) else { return [] }
        let ns = text as NSString
        var out: [URL] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, let r = Range(m.range, in: text),
                  let url = URL(string: String(text[r])), urlIsMedia(url) else { return }
            if !out.contains(url) { out.append(url) }
        }
        return out
    }

    static func urlIsMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["gif", "png", "jpg", "jpeg", "webp", "avif",
            "mp4", "mov", "m4v", "webm"].contains(ext) { return true }
        let host = (url.host ?? "").lowercased()
        return host.contains("tenor") || host.contains("giphy") || host.contains("klipy")
    }

    /// The text left once every inline media URL has been pulled out, so a
    /// caption renders as its own bubble beside/above the media.
    static func stripped(_ text: String, of urls: [URL]) -> String {
        var s = text
        for url in urls { s = s.replacingOccurrences(of: url.absoluteString, with: "") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// An animated GIF reader. Wraps a loop task around ImageIO frames; the exact
/// same rendering is reused in chat bubbles and the media viewer. With
/// `staticOnly` it shows the first frame instead of animating — used for picker
/// thumbnails so a full grid doesn't decode hundreds of frames per cell.
struct GIFImage: View {
    let url: URL
    var maxWidth: CGFloat = 420
    var staticOnly = false

    @State private var image: NSImage?
    @State private var aspect: CGFloat? = nil
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if failed {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: maxWidth, height: 120)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.title3).foregroundStyle(.secondary)
                            Text("Couldn't load")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
            } else if let aspect {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .overlay(Image(systemName: "photo.fill").foregroundStyle(.secondary))
                    .aspectRatio(aspect, contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: maxWidth, height: 160)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(maxWidth: maxWidth)
        .task(id: url) { await play() }
    }

    @MainActor
    private func play() async {
        guard let data = await GIFStore.data(for: url), !data.isEmpty else {
            failed = true
            return
        }

        // Borderline GIFs — a Discord-user GIF hotlinked from a CDN that
        // answers with a page body, or a truncated download — used to leave
        // `image` nil while failed stayed false, rendering a spinner forever.
        // Every decode path below now lands on `failed` instead.
        let anim = GIFStore.animation(for: url, data: data)
        if !staticOnly, let anim, !anim.frames.isEmpty {
            if aspect == nil, anim.size.height > 0 { aspect = anim.size.width / anim.size.height }
            while !Task.isCancelled {
                for (i, frame) in anim.frames.enumerated() {
                    if Task.isCancelled { return }
                    image = frame
                    try? await Task.sleep(nanoseconds: UInt64(anim.delays[i] * 1_000_000_000))
                }
            }
            return
        }

        // Static decode: single-frame GIFs, and the first frame for grid
        // thumbnails (`staticOnly`). Anything that isn't a decodable image
        // fails loudly instead of pinwheeling.
        if let ns = NSImage(data: data), ns.size.width > 0, ns.size.height > 0 {
            image = ns
            if aspect == nil { aspect = ns.size.width / max(ns.size.height, 1) }
        } else {
            failed = true
        }
    }
}

/// An animated GIF thumbnail for the picker grid. Same hardened loader and
/// animator as chat — what the grid shows is exactly what the message will
/// render. `LazyVGrid` only mounts visible cells, so a handful animate at a
/// time while decoded frames are shared through `GIFStore`.
struct GIFThumb: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                GIFImage(url: url, maxWidth: 400)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}