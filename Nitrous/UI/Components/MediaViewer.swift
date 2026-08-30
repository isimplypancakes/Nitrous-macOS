import SwiftUI
import AppKit

/// What a media viewer is showing. `id` re-keys the sheet so tapping a second
/// image while one is open swaps the content instead of doing nothing.
struct MediaViewerItem: Identifiable {
    let id = UUID()
    let url: URL
    let isGIF: Bool
    var title: String?
}

/// A near-fullscreen sheet that shows one image or GIF with pinch/button zoom,
/// drag-panning and a fit-to-window reset. Pure media, no chrome.
struct MediaViewer: View {
    let item: MediaViewerItem
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var baseScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            media
                .scaleEffect(scale)
                .offset(pan)
                .onTapGesture(count: 2) { toggleZoom() }
                .gesture(dragWhenZoomed)
                .gesture(MagnifyGesture()
                    .onChanged { value in
                        scale = min(8, max(1, baseScale * value.magnification))
                    }
                    .onEnded { _ in baseScale = scale })

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    Button { zoom(0.67) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { zoom(1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    Button { resetZoom() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    Divider().frame(height: 18)
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.black.opacity(0.55))
                .help("Zoom and close (double-click toggles 2×)")
                if let title = item.title {
                    Text(title)
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                }
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 420)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var media: some View {
        if item.isGIF {
            GIFImage(url: item.url, maxWidth: 1200)
        } else {
            AsyncImage(url: item.url) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fit)
                } else if phase.error == nil {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }

    private var dragWhenZoomed: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 { pan = CGSize(width: pan.width + value.translation.width,
                                            height: pan.height + value.translation.height) }
            }
    }

    private func zoom(_ factor: CGFloat) {
        baseScale = min(8, max(1, scale * factor))
        withAnimation(.snappy(duration: 0.18)) { scale = baseScale }
    }

    private func toggleZoom() {
        baseScale = scale > 1 ? 1 : 2
        withAnimation(.snappy(duration: 0.18)) { scale = baseScale }
        if baseScale == 1 { withAnimation { pan = .zero } }
    }

    private func resetZoom() {
        baseScale = 1
        withAnimation(.snappy(duration: 0.2)) { scale = 1; pan = .zero }
    }
}