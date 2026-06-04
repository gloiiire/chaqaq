import SwiftUI

/// Application entry point.
@main
struct PinkhaApp: App {
    /// Lives at the App level so the accent color and other prefs
    /// propagate to every view in the hierarchy via the environment.
    @StateObject private var settings = AppSettings()

    init() {
        Observability.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .tint(settings.accentColor)
        }
    }
}
