import SwiftUI

/// Theme picker. Each row previews the theme's own colours so the choice is
/// visible before committing to it.
struct AppearanceView: View {
    @EnvironmentObject var theme: ThemeStore
    @State private var showBackgroundPicker = false

    private var adaptive: [AppTheme] { [.system, .light, .dark] }
    private var dark: [AppTheme] { [.oled, .midnight, .ocean, .indigoNight, .slate] }

    var body: some View {
        List {
            Section("Appearance") {
                ForEach(adaptive) { row($0) }
            }
            Section {
                ForEach(dark) { row($0) }
            } header: {
                Text("Dark Themes")
            } footer: {
                Text("OLED Black uses true black, which switches pixels off entirely on OLED displays.")
            }

            Section {
                Button { showBackgroundPicker = true } label: {
                    HStack {
                        Label(theme.hasWallpaper ? "Background" : "Choose Background",
                              systemImage: "photo.on.rectangle.angled")
                        Spacer()
                        if theme.hasWallpaper {
                            Text("On").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.bouncyRow)
            } header: {
                Text("Background")
            } footer: {
                Text("Pick a photo to sit behind the app so the glass has something to refract. Choose the same image as your Desktop Picture for a seamless look — or use the “Use Desktop Picture” button and let the app mirror it exactly.")
            }
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .sheet(isPresented: $showBackgroundPicker) {
            BackgroundPickerView()
                .frame(width: 520, height: 560)
        }
    }

    private func row(_ t: AppTheme) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { theme.current = t }
        } label: {
            HStack(spacing: 14) {
                swatch(t)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(t.blurb).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if theme.current.id == t.id {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.bouncyRow)
    }

    /// A miniature of the theme: background, a bubble and the accent.
    private func swatch(_ t: AppTheme) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(t.background ?? Color(nsColor: .windowBackgroundColor))
            VStack(alignment: .leading, spacing: 3) {
                Capsule()
                    .fill(t.bubbleOther ?? Color.primary.opacity(0.07))
                    .frame(width: 22, height: 7)
                Capsule()
                    .fill(t.accent ?? Palette.accent)
                    .frame(width: 15, height: 7)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(6)
        }
        .frame(width: 46, height: 46)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}