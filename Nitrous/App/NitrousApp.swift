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
                .onAppear {
                    model.boot()
                    notifications.refreshAuthorization()
                }
                // A tap on a notification routes to that account and channel.
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
    }
}
