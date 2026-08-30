import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Chooses a background image for the app. Presented as its own window because
/// an open panel shown from inside the Appearance list doesn't get a frame.
/// mac-specific bonus: the app can adopt the machine's actual Desktop Picture,
/// which is how the glass starts to look like it belongs to the screen.
struct BackgroundPickerView: View {
    @EnvironmentObject var theme: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @State private var showOpenPanel = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                preview

                HStack(spacing: 10) {
                    Button { showOpenPanel = true } label: {
                        Label(theme.hasWallpaper ? "Change Photo…" : "Choose Photo…",
                              systemImage: "photo.on.rectangle.angled")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        withAnimation { theme.adoptDesktopPicture() }
                    } label: {
                        Label("Use Desktop Picture", systemImage: "display")
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                    }
                    .buttonStyle(.bordered)
                    .help("Mirror the wallpaper already on this screen behind the app")
                }

                if theme.hasWallpaper {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dim").font(.subheadline.weight(.medium))
                        Slider(value: $theme.wallpaperDim, in: 0...0.8)
                        Text("Darkens the photo so text stays readable.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .liquidGlass(cornerRadius: 14)

                    Button(role: .destructive) {
                        withAnimation { theme.setWallpaper(nil) }
                    } label: {
                        Label("Remove Background", systemImage: "trash")
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }

                Text("Pick a photo to sit behind the app so the glass has something to refract, or mirror this screen's Desktop Picture for a seamless look.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .themedBackground()
        .fileImporter(isPresented: $showOpenPanel,
                      allowedContentTypes: [.image],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            guard let data = try? Data(contentsOf: url) else { return }
            if access { url.stopAccessingSecurityScopedResource() }
            withAnimation { theme.setWallpaper(data) }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if let wallpaper = theme.wallpaper {
                // The image MUST be clipped to a measured width. A bare
                // `scaledToFill` propagates its own intrinsic width and stretches
                // every sibling past the window edge — `.frame(height:)` alone
                // constrains only the height.
                GeometryReader { geo in
                    Image(nsImage: wallpaper)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .overlay(Color.black.opacity(theme.wallpaperDim))
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No background").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}