import SwiftUI

/// Application entry point.
@main
struct PinkhaApp: App {
    init() {
        Observability.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
