import Foundation
import SwiftUI

/// One GIF from the picker. Backed by the public Giphy API (Discord's own
/// `/gif-picker/*` endpoints were retired — they 404), while the parser still
/// tolerates the Tenor/Klipy shapes Discord used to serve.
struct GIFItem: Identifiable, Hashable {
    var id: String
    var title: String?
    var previewURL: URL?
    var gifURL: URL?
    var videoURL: URL?
    var width: Int?
    var height: Int?

    /// Pre-computed aspect for stable grid cells that don't reflow on load.
    var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }
}

/// Tolerant decoder for whatever GIF provider's JSON arrives:
///
/// - Giphy (`api.giphy.com/v1/gifs/*`): `{data:[{id,title,images:{...}}]}`
/// - Tenor (`api.tenor.com/v1/*`): `{results:[{id,media_formats:{gif,tinygif}}]}`
/// - Klipy / legacy Discord: `{items|results|data:[{media_formats|formats:{gif}}]}`
///
/// The gif list itself can arrive as a top-level array or under `data`,
/// `results`, `items`, `entries`, `gifs` — the walker recurses through the
/// whole payload so the key names don't matter. When nothing decodes, the raw
/// body head is surfaced so a provider change is never a silent blank grid.
enum GIFPayload {
    struct PayloadError: LocalizedError {
        let hint: String
        let head: String
        var errorDescription: String? {
            "\(hint): unexpected payload — \(head)"
        }
    }

    static func items(from data: Data, hint: String = "gif-provider") throws -> [GIFItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw PayloadError(hint: hint, head: head(of: data))
        }
        var items: [GIFItem] = []
        var seen = Set<String>()
        for node in candidateNodes(in: root) {
            guard let dict = node as? [String: Any], let item = item(from: dict), item.gifURL != nil else { continue }
            let key = item.id.isEmpty ? item.gifURL!.absoluteString : item.id
            if seen.contains(key) { continue }
            seen.insert(key)
            items.append(item)
        }
        if items.isEmpty {
            throw PayloadError(hint: hint, head: head(of: data))
        }
        return items
    }

    /// Finds the first JSON array that reads as a list of GIF entries,
    /// recursing through the whole payload so the key names don't matter.
    private static func candidateNodes(in value: Any) -> [Any] {
        if let array = value as? [Any] {
            if array.first is [String: Any] { return array }
            for element in array {
                let inside = candidateNodes(in: element)
                if !inside.isEmpty { return inside }
            }
            return []
        }
        guard let dict = value as? [String: Any] else { return [] }
        for key in ["items", "results", "data", "entries", "gifs", "media"] {
            if let array = dict[key] as? [Any] {
                let inside = candidateNodes(in: array)
                if !inside.isEmpty { return inside }
            }
        }
        for (_, value) in dict where value is [String: Any] {
            let inside = candidateNodes(in: value)
            if !inside.isEmpty { return inside }
        }
        return []
    }

    private static func head(of data: Data) -> String {
        String(data: data.prefix(300), encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ") ?? "<non-text body>"
    }

    /// One GIF item from any provider. Returns nil when the dict has nothing
    /// we recognize as media.
    static func item(from dict: [String: Any]) -> GIFItem? {
        let id = string(dict["id"]) ?? string(dict["gif_id"]) ?? string(dict["tenor_id"]) ?? ""
        let tenorFormats = (dict["media"] as? [[String: Any]])?.first
        let media = (dict["media_formats"] as? [String: Any])
            ?? (dict["formats"] as? [String: Any])
            ?? tenorFormats

        func block(_ container: [String: Any]?, _ key: String) -> Media? {
            guard let container, let entry = container[key] as? [String: Any] else { return nil }
            return mediaBlock(from: entry)
        }

        // Giphy nests every rendition under `images`; pick small animated for
        // the grid and a modestly-sized file for sending.
        let giphy = dict["images"] as? [String: Any]
        let giphyPreview = giphyRendition(giphy, keys: ["fixed_width_small", "downsized_small", "fixed_width", "preview_gif", "preview"])
        let giphyGif = giphyRendition(giphy, keys: ["downsized", "downsized_medium", "downsized_large", "original"])
        let giphyVideo = giphyRendition(giphy, keys: ["original_mp4", "preview_mp4"])

        // Sending prefers mediumgif — Klipy's 498px `gif` approaches the
        // attachment cap, while mediumgif (640px) stays small.
        let gif = block(media, "mediumgif") ?? block(dict, "gif") ?? block(media, "gif")
            ?? giphyGif ?? urlField(dict["src"]) ?? urlField(dict["url"])
        guard let gifURL = gif?.url else { return nil }
        let tiny: Media? = block(dict, "tinygif") ?? block(media, "tinygif") ?? giphyPreview
            ?? (url: gifURL, width: nil, height: nil)
        let video = block(dict, "mp4") ?? block(media, "mp4") ?? giphyVideo

        return GIFItem(id: id,
                       title: firstNonEmpty(["title", "content_description", "h1_title", "description"], in: dict),
                       previewURL: tiny?.url,
                       gifURL: gifURL,
                       videoURL: video?.url,
                       width: gif?.width ?? int(dict["width"]) ?? widthHeight(dict)?.width,
                       height: gif?.height ?? int(dict["height"]) ?? widthHeight(dict)?.height)
    }

    private static func firstNonEmpty(_ keys: [String], in dict: [String: Any]) -> String? {
        for key in keys where key != "title" {
            if let value = string(dict[key]), !value.isEmpty { return value }
        }
        if let value = string(dict["title"]), !value.isEmpty { return value }
        return nil
    }

    private typealias Media = (url: URL?, width: Int?, height: Int?)

    /// Pulls an image rendition block (`{url,width,height,...}`) out of a
    /// Giphy `images` dict — keys differ wildly, so a stubborn helper is
    /// worth it. `width`/`height` arrive as strings.
    private static func giphyRendition(_ images: [String: Any]?, keys: [String]) -> Media? {
        guard let images else { return nil }
        for key in keys {
            if let block = images[key] as? [String: Any], let media = mediaBlock(from: block) { return media }
        }
        return nil
    }

    private static func mediaBlock(from block: [String: Any]) -> Media? {
        guard let raw = string(block["url"]) ?? string(block["src"]), !raw.isEmpty,
              let url = URL(string: raw) else { return nil }
        var width = int(block["width"]) ?? int(block["w"])
        var height = int(block["height"]) ?? int(block["h"])
        if let dims = block["dims"] as? [Any], dims.count >= 2 {
            width = int(dims[0]); height = int(dims[1])
        }
        return (url, width, height)
    }

    private static func urlField(_ value: Any?) -> Media? {
        guard let s = string(value), let url = URL(string: s) else { return nil }
        return (url, nil, nil)
    }

    private static func widthHeight(_ dict: [String: Any]) -> (width: Int, height: Int)? {
        guard let w = int(dict["width"]), let h = int(dict["height"]) else { return nil }
        return (w, h)
    }

    private static func string(_ value: Any?) -> String? {
        value as? String ?? (value as? NSNumber).map { "\($0)" }
    }

    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let i = Int(s) { return i }
        return nil
    }
}