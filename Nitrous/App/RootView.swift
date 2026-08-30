import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The macOS shell: a three-part window built on the app's own terms, not a
/// Discord re-skin. A source-list sidebar for servers and messages, a chat
/// detail pane, and a Settings window for everything personal.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var theme: ThemeStore

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if model.isLoggedIn {
                MainWindow()
                    .overlay {
                        if model.isSwitching {
                            SwitchingOverlay().transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.22), value: model.isSwitching)
            } else {
                LoginView()
            }
        }
        .animation(.default, value: model.isLoggedIn)
    }
}

/// Signed-in shell. Broadcasts the account's token state as `isLoggedIn` flips.
private struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var theme: ThemeStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailPane()
        }
        .navigationSplitViewStyle(.balanced)
        // Window-wide image-paste fallback. Field-level ⌘V works only while the
        // composer is focused; this catches pastes from anywhere else in the
        // window and routes them into the selected channel's attachment tray.
        .onPasteCommand(of: [UTType.image]) { providers in
            model.handleImagePaste(providers, channelID: model.selectedChannelID)
        }
        .onAppear { PasteHook.install(into: model) }
    }
}

/// Intercepts ⌘V before the responder chain can swallow it. The native text
/// field eats paste events before SwiftUI's `.onPasteCommand` fires, so an
/// `NSEvent` local monitor — which runs ahead of everything — is the only way a
/// screenshot pasted into an unfocused composer reliably lands in the tray.
/// Only image-bearing pasteboards are intercepted; text pasting is untouched.
private enum PasteHook {
    private static var monitor: Any?

    /// Pasteboard type identifiers that carry real image content.
    private static let imageTypes = ["public.tiff", "public.png", "public.jpeg", "public.jpg",
                                     "com.compuserve.gif", "public.webp", "public.heic"]

    static func install(into model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  model.selectedChannelID != nil else { return event }
            let pb = NSPasteboard.general
            guard pasteboardCarriesImage(pb) else { return event }
            // Swallow the event only when something actually staged.
            return model.stagePastedImage(from: pb) ? nil : event
        }
    }

    private static func pasteboardCarriesImage(_ pb: NSPasteboard) -> Bool {
        if let types = pb.types, types.contains(where: { imageTypes.contains($0.rawValue) }) { return true }
        // Image files copied out of Finder arrive as a file URL.
        if let string = pb.string(forType: .fileURL),
           let url = URL(string: string),
           ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
               .contains(url.pathExtension.lowercased()) { return true }
        return false
    }
}

/// The chat pane. Shows the selected conversation, or Messages.app-style
/// "select something" empty state when nothing is open yet.
struct DetailPane: View {
    @EnvironmentObject var model: AppModel

    private var selected: Channel? {
        model.selectedChannelID.flatMap { model.channel(with: $0) }
    }

    var body: some View {
        Group {
            if let selected {
                ChatView(channel: selected)
                    .id(selected.id)
            } else {
                ContentUnavailableView(
                    "Select a Conversation",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a direct message or a server channel to start chatting.")
                )
            }
        }
    }
}

/// Brief blurred overlay shown while a switch tears down/rebuilds the session.
private struct SwitchingOverlay: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Switching to \(model.accountStore.activeAccount?.displayName ?? "account")…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}