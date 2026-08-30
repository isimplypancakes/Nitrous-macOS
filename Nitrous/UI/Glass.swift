import SwiftUI
import AppKit

/// Liquid Glass helpers.
///
/// `glassEffect` ships in macOS 26 (Tahoe) alongside the iOS edition; the
/// deployment target is 14, so every use is gated and falls back to the closest
/// material. Keeping the fallbacks here means call sites stay declarative
/// instead of littered with availability checks.
extension View {

    /// A glass capsule/rounded container — for floating bars and controls.
    /// macOS's glassEffect takes a plain `Shape` (not the iOS `.rect`/.circle
    /// DSL), so pass real shapes: RoundedRectangle / Circle.
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat = 22, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }

    /// Tinted glass, used where the surface should pick up the accent.
    @ViewBuilder
    func liquidGlass(tint: Color, cornerRadius: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            self.background(tint.opacity(0.16), in: shape)
                .background(.ultraThinMaterial, in: shape)
        }
    }

    /// A circular glass control (compose buttons, jump-to-latest).
    @ViewBuilder
    func liquidGlassCircle(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint).interactive(), in: Circle())
            } else {
                self.glassEffect(.regular.interactive(), in: Circle())
            }
        } else {
            self.background(tint?.opacity(0.18) ?? Color.clear, in: Circle())
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// Groups nearby glass elements so they blend as one surface rather than
/// stacking separate blurs. No-op before macOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// Accent-tinted glass for the sender's own bubble. Pre-26 keeps the solid
    /// accent gradient so the dark on-accent text stays legible.
    @ViewBuilder
    func liquidGlassAccent(cornerRadius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(Palette.accent).interactive(), in: shape)
        } else {
            self.background(Palette.accent.gradient, in: shape)
        }
    }
}

/// A glass fill for `List` rows — set as `.listRowBackground` **per row**.
/// Carries a hairline edge so the pane reads as glass even on a near-black
/// theme, where plain glass has nothing to refract and looks flat.
struct GlassRow: View {
    var cornerRadius: CGFloat = 16
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.clear)
            .liquidGlass(cornerRadius: cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                    .allowsHitTesting(false)
            )
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
    }
}

extension View {
    /// Standard glass row background + hidden separator, applied per row.
    func glassRow(cornerRadius: CGFloat = 16) -> some View {
        self.listRowBackground(GlassRow(cornerRadius: cornerRadius))
            .listRowSeparator(.hidden)
    }
}

extension View {
    /// A glass panel for the bottom compose bar, with a hairline top border.
    @ViewBuilder
    func liquidGlassBar() -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0, topTrailingRadius: 22,
                                           style: .continuous)
        // Both overlays must be hit-transparent: an overlay spans the whole bar
        // and would otherwise swallow every click meant for the field or buttons.
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
                .overlay(alignment: .top) {
                    shape.stroke(Color.white.opacity(0.08), lineWidth: 0.75)
                        .mask(Rectangle().frame(height: 1).frame(maxHeight: .infinity, alignment: .top))
                        .allowsHitTesting(false)
                }
        } else {
            self.background(.bar)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.75)
                        .allowsHitTesting(false)
                }
        }
    }
}

/// Screen background: the user's wallpaper when set, otherwise the theme
/// colour. Applied per screen because window containers paint an opaque
/// background over anything placed behind them at the root.
struct ThemedBackground: ViewModifier {
    @ObservedObject private var theme = ThemeStore.shared
    var grouped: Bool = true

    func body(content: Content) -> some View {
        content.background {
            if let wallpaper = theme.wallpaper {
                GeometryReader { geo in
                    Image(nsImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay(Color.black.opacity(theme.wallpaperDim))
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            } else {
                (grouped ? Palette.groupedBg : Palette.background).ignoresSafeArea()
            }
        }
    }
}

extension View {
    func themedBackground(grouped: Bool = true) -> some View {
        modifier(ThemedBackground(grouped: grouped))
    }
}

// MARK: - Bouncy interaction

/// Haptics. On a Mac these only fire on Force-touch / trackpad-capable machines,
/// which is the native behaviour — nothing to special-case.
enum Haptics {
    static func tap(intensity: Float = 0.7) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// The springs used for press feedback.
enum Bounce {
    static let press = Animation.spring(response: 0.20, dampingFraction: 0.58)
    /// Low damping on purpose: the overshoot is what reads as a "jiggle"
    /// rather than a flat scale.
    static let release = Animation.spring(response: 0.40, dampingFraction: 0.38)
    static let pop = Animation.spring(response: 0.34, dampingFraction: 0.58)
}

/// Button style that squashes and lifts like a native glass control.
struct BouncyGlassButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    var haptic: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(configuration.isPressed ? Bounce.press : Bounce.release,
                       value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                guard haptic, pressed else { return }
                Haptics.tap()
            }
    }
}

extension ButtonStyle where Self == BouncyGlassButtonStyle {
    /// `.buttonStyle(.bouncy)` — springy press for glass controls.
    static var bouncy: BouncyGlassButtonStyle { BouncyGlassButtonStyle() }
    /// Subtler squash, for large surfaces like list rows.
    static var bouncyRow: BouncyGlassButtonStyle { BouncyGlassButtonStyle(scale: 0.975) }
}

/// Press-bounce for views that genuinely cannot be a Button.
///
/// Prefer `.buttonStyle(.bouncy)`/`.bouncyRow`: AppKit cancels a button's press
/// state as soon as a scroll begins, whereas a `DragGesture` here competes with
/// the scroll view and makes scrolling feel like it catches.
struct BouncyPress: ViewModifier {
    var scale: CGFloat = 0.96
    var haptic: Bool = true
    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? scale : 1)
            .animation(pressed ? Bounce.press : Bounce.release, value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let moved = max(abs(v.translation.height), abs(v.translation.width))
                        if moved > 6 {
                            if pressed { pressed = false }
                            return
                        }
                        guard !pressed else { return }
                        pressed = true
                        if haptic { Haptics.tap(intensity: 0.6) }
                    }
                    .onEnded { _ in pressed = false }
            )
    }
}

extension View {
    /// Springy press feedback for non-Button surfaces.
    func bouncyPress(scale: CGFloat = 0.96, haptic: Bool = true) -> some View {
        modifier(BouncyPress(scale: scale, haptic: haptic))
    }

    /// A gentle entrance pop, used when a bubble or card first appears.
    func bouncyAppear(_ trigger: Bool = true) -> some View {
        modifier(BouncyAppear(trigger: trigger))
    }
}

/// Scales a view in on first appearance so new content lands with some life
/// instead of snapping into place.
struct BouncyAppear: ViewModifier {
    let trigger: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.92)
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard trigger else { shown = true; return }
                withAnimation(Bounce.pop) { shown = true }
            }
    }
}

/// Wraps a list row's content in its **own** interactive glass card.
///
/// `.listRowBackground` puts the glass behind the row as a separate view, so a
/// press animation on the content leaves the glass sitting still — and it never
/// gets the touch that drives `.interactive()` deformation. Wrapping instead
/// means the glass and content squash together and the glass reacts natively.
extension View {
    func glassCard(cornerRadius: CGFloat = 18,
                   vertical: CGFloat = 12,
                   horizontal: CGFloat = 14) -> some View {
        self
            .padding(.vertical, vertical)
            .padding(.horizontal, horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(cornerRadius: cornerRadius, interactive: true)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                    .allowsHitTesting(false)
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
    }
}