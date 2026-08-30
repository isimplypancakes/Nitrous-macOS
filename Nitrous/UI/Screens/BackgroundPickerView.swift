import SwiftUI
import PhotosUI

/// Chooses a background image for the app. Lives on its own screen because a
/// PhotosPicker presented from inside the Appearance List didn't open.
struct BackgroundPickerView: View {
    @EnvironmentObject var theme: ThemeStore
    @State private var pick: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                preview

                PhotosPicker(selection: $pick, matching: .images, photoLibrary: .shared()) {
                    Label(theme.hasWallpaper ? "Change Photo" : "Choose Photo",
                          systemImage: "photo.on.rectangle.angled")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .liquidGlass(cornerRadius: 14, interactive: true)
                .foregroundStyle(Palette.accent)
                .bouncyPress()

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
                    .liquidGlass(cornerRadius: 14)
                }

                Text("Pick a photo to sit behind the app so the glass has something to refract. Choose the same image as your Home Screen wallpaper for a seamless look — iOS doesn't let apps read the system wallpaper directly.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .themedBackground()
        .navigationTitle("Background")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pick) {
            guard let pick else { return }
            Task {
                let data = try? await pick.loadTransferable(type: Data.self)
                await MainActor.run { withAnimation { theme.setWallpaper(data) } }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemFill))
            if let wallpaper = theme.wallpaper {
                // The image MUST be clipped to a measured width. A bare
                // `scaledToFill` propagates its own intrinsic width and stretches
                // every sibling past the screen edge — `.frame(height:)` alone
                // constrains only the height.
                GeometryReader { geo in
                    Image(uiImage: wallpaper)
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
