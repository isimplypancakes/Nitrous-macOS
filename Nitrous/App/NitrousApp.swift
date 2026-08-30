import SwiftUI

@main
struct NitrousApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var theme = ThemeStore.shared
    @StateObject private var notifications = NotificationCenterManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(theme)
                .environmentObject(notifications)
                .tint(Palette.accent)
                .preferredColorScheme(theme.current.scheme)
                .frame(minWidth: 820, minHeight: 540)
                .onAppear {
                    model.boot()
                    notifications.refreshAuthorization()
                }
                // A click on a notification routes to that account and channel.
                .onChange(of: notifications.pendingRoute) {
                    if let route = notifications.pendingRoute {
                        notifications.pendingRoute = nil
                        model.route(to: route)
                    }
                }
                .onChange(of: scenePhase) {
                    if scenePhase == .active { notifications.refreshAuthorization() }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            // A single chat window — this isn't a document app.
            CommandGroup(replacing: .newItem) {}
        }

        // System Settings-style preferences window (Cmd+,).
        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(theme)
                .environmentObject(notifications)
                .tint(Palette.accent)
                .preferredColorScheme(theme.current.scheme)
        }
    }
}