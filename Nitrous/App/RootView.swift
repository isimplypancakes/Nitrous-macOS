import SwiftUI

/// Native tab-bar shell — the way a first-party iOS app is structured.
/// Servers, Messages, and You, each in its own NavigationStack.
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
                MainTabView()
                    .overlay { if model.isSwitching { SwitchingOverlay() } }
            } else {
                LoginView()
            }
        }
        .animation(.default, value: model.isLoggedIn)
    }
}

struct MainTabView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            ServersView()
                .tabItem { Label("Servers", systemImage: "square.grid.2x2.fill") }
                .tag(0)

            MessagesView()
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(1)
                .badge(model.dmChannels.isEmpty ? 0 : 0)

            YouView()
                .tabItem { Label("You", systemImage: "person.crop.circle.fill") }
                .tag(2)
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
