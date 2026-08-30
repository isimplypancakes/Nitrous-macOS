import SwiftUI
import Combine
import UIKit

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// A selectable colour scheme.
///
/// `system` keeps the adaptive iOS look; every other theme pins an explicit
/// palette so OLED black stays truly black and the blues stay on-hue.
struct AppTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String
    /// nil = follow the system appearance.
    let scheme: ColorScheme?
    let background: Color?
    let grouped: Color?
    let elevated: Color?
    let bubbleOther: Color?
    let accent: Color?
    let separator: Color?

    static let system = AppTheme(
        id: "system", name: "System", blurb: "Matches iOS light or dark",
        scheme: nil, background: nil, grouped: nil, elevated: nil,
        bubbleOther: nil, accent: nil, separator: nil)

    static let light = AppTheme(
        id: "light", name: "Light", blurb: "Always light",
        scheme: .light, background: nil, grouped: nil, elevated: nil,
        bubbleOther: nil, accent: nil, separator: nil)

    static let dark = AppTheme(
        id: "dark", name: "Dark", blurb: "Always dark",
        scheme: .dark, background: nil, grouped: nil, elevated: nil,
        bubbleOther: nil, accent: nil, separator: nil)

    static let oled = AppTheme(
        id: "oled", name: "OLED Black", blurb: "True black — saves power on OLED",
        scheme: .dark,
        background: Color(hex: 0x000000),
        grouped: Color(hex: 0x000000),
        elevated: Color(hex: 0x0C0C0E),
        bubbleOther: Color(hex: 0x1C1C1F),
        accent: Color(hex: 0x6B74F8),
        separator: Color(hex: 0x1F1F22))

    static let midnight = AppTheme(
        id: "midnight", name: "Midnight", blurb: "Deep navy blue",
        scheme: .dark,
        background: Color(hex: 0x0A0E1A),
        grouped: Color(hex: 0x070A14),
        elevated: Color(hex: 0x121829),
        bubbleOther: Color(hex: 0x1B2340),
        accent: Color(hex: 0x5B8DEF),
        separator: Color(hex: 0x1E2740))

    static let ocean = AppTheme(
        id: "ocean", name: "Ocean", blurb: "Dark blue-teal",
        scheme: .dark,
        background: Color(hex: 0x08161C),
        grouped: Color(hex: 0x051015),
        elevated: Color(hex: 0x0E2029),
        bubbleOther: Color(hex: 0x15303B),
        accent: Color(hex: 0x2FB3C9),
        separator: Color(hex: 0x18333D))

    static let indigoNight = AppTheme(
        id: "indigo", name: "Indigo Night", blurb: "Dark with an indigo cast",
        scheme: .dark,
        background: Color(hex: 0x0E0B1A),
        grouped: Color(hex: 0x0A0814),
        elevated: Color(hex: 0x171128),
        bubbleOther: Color(hex: 0x231A3D),
        accent: Color(hex: 0x8B7BFF),
        separator: Color(hex: 0x261C42))

    static let slate = AppTheme(
        id: "slate", name: "Slate", blurb: "Neutral charcoal",
        scheme: .dark,
        background: Color(hex: 0x15171A),
        grouped: Color(hex: 0x101215),
        elevated: Color(hex: 0x1E2126),
        bubbleOther: Color(hex: 0x2A2E35),
        accent: Color(hex: 0x7C8CA1),
        separator: Color(hex: 0x282C33))

    static let all: [AppTheme] = [.system, .light, .dark, .oled, .midnight, .ocean, .indigoNight, .slate]
}

/// Holds the selected theme and persists it.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    private let key = "nitrous.theme"

    @Published var current: AppTheme {
        didSet { UserDefaults.standard.set(current.id, forKey: key) }
    }

    /// A user-chosen background image. When set, screen backgrounds go clear so
    /// the glass layers float over it.
    ///
    /// iOS gives apps no way to read the system wallpaper — the sandbox has no
    /// API for it — so the user picks their own image (they can choose the same
    /// photo their Home Screen uses).
    @Published var wallpaper: UIImage?
    /// How much to dim the wallpaper so text stays readable over it.
    @Published var wallpaperDim: Double {
        didSet { UserDefaults.standard.set(wallpaperDim, forKey: dimKey) }
    }

    private let dimKey = "nitrous.wallpaperDim"
    private var wallpaperURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wallpaper.jpg")
    }

    var hasWallpaper: Bool { wallpaper != nil }

    func setWallpaper(_ data: Data?) {
        guard let data, let image = UIImage(data: data) else {
            try? FileManager.default.removeItem(at: wallpaperURL)
            wallpaper = nil
            return
        }
        try? data.write(to: wallpaperURL, options: .atomic)
        wallpaper = image
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: key)
        current = AppTheme.all.first { $0.id == saved } ?? .system
        let dim = UserDefaults.standard.object(forKey: dimKey) as? Double
        wallpaperDim = dim ?? 0.35
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("wallpaper.jpg")
        if let data = try? Data(contentsOf: url) { wallpaper = UIImage(data: data) }
    }
}

/// The single app accent.
///
/// Deliberately very light: the glass surfaces render dark over a wallpaper,
/// so a pale lavender reads far better than either the original indigo or a
/// dark one. Applied universally, overriding each theme's own accent.
enum Brand {
    static let accent = Color(hex: 0xDCDAFF)
    /// Text/icons drawn *on top of* the accent (e.g. the sender's own bubble),
    /// which must be dark now that the accent itself is pale.
    static let onAccent = Color(hex: 0x1B1A3A)
}

/// Semantic colours. Falls back to system colours whenever the active theme
/// doesn't override a given role, so `system`/`light`/`dark` stay adaptive.
enum Palette {
    // Read live so any view observing ThemeStore re-renders with new colours.
    private static var t: AppTheme { ThemeStore.shared.current }

    /// One accent everywhere — themes no longer override it.
    static var accent: Color { Brand.accent }
    /// True when a wallpaper is showing, so surfaces should be transparent.
    static var usingWallpaper: Bool { ThemeStore.shared.hasWallpaper }

    static var background: Color {
        usingWallpaper ? .clear : (t.background ?? Color(.systemBackground))
    }
    static var secondaryBg: Color { t.elevated ?? Color(.secondarySystemBackground) }
    static var groupedBg: Color {
        usingWallpaper ? .clear : (t.grouped ?? Color(.systemGroupedBackground))
    }
    static var secondaryGroupedBg: Color { t.elevated ?? Color(.secondarySystemGroupedBackground) }
    static var separator: Color { t.separator ?? Color(.separator) }

    static var label: Color { Color(.label) }
    static var secondary: Color { Color(.secondaryLabel) }
    static var tertiary: Color { Color(.tertiaryLabel) }

    static var bubbleMine: Color { accent }
    static var bubbleMineText: Color { Brand.onAccent }
    static var bubbleOther: Color { t.bubbleOther ?? Color(.secondarySystemFill) }
    static var bubbleOtherText: Color { Color(.label) }

    static func presence(_ status: String?) -> Color {
        switch status {
        case "online": return Color(.systemGreen)
        case "idle": return Color(.systemYellow)
        case "dnd": return Color(.systemRed)
        default: return Color(.systemGray3)
        }
    }
}

/// Deterministic accent for avatars/servers lacking imagery.
func fallbackColor(for seed: String) -> Color {
    let palette: [Color] = [.indigo, .blue, .teal, .green, .orange, .pink, .purple, .cyan]
    var hash = 5381
    for b in seed.utf8 { hash = ((hash << 5) &+ hash) &+ Int(b) }
    return palette[abs(hash) % palette.count]
}
