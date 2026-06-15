import SwiftUI
import PinkhaCore

/// Application entry point.
@main
struct PinkhaApp: App {
    /// Lives at the App level so the accent color and other prefs
    /// propagate to every view in the hierarchy via the environment.
    /// `@State` + `.environment(settings)` is the iOS 26 shape for
    /// owning an `@Observable` class at the app root — the macro
    /// handles SwiftUI tracking automatically, so the `@StateObject`
    /// / `.environmentObject(_:)` pair from iOS 17 is no longer needed.
    @State private var settings = AppSettings()
    /// Bridges Home Screen Quick Actions (long-press the app icon)
    /// back into SwiftUI. The delegate dispatches via NotificationCenter,
    /// `Composer` listens and triggers the matching flow.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Two-stage splash state. `showingSplash` removes the view from
    /// the tree once dissolve completes; `dismissingSplash` is the
    /// flag the splash itself watches to drive its outgoing scale.
    /// Splitting the two lets the scale animation begin while the
    /// opacity fade is still in progress, so the exit reads as one
    /// continuous motion rather than a hard cut.
    @State private var showingSplash = true
    @State private var dismissingSplash = false

    init() {
        Observability.start()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Note : no app-level `.tint(...)` — accent is opt-in
                // per button. `AppSettings.accentColor` is still
                // available to specific call sites (search spotlight
                // tint, future explicit-accent buttons) but the
                // default for every system control is the neutral
                // material/label color, matching Apple's own apps.
                ContentView()
                    .environment(settings)
                    // User-controlled appearance override : `.system`
                    // returns `nil` so iOS keeps its own choice; the
                    // explicit `.light` / `.dark` modes force the
                    // scheme app-wide. Repaints live when the user
                    // flips the picker in Settings.
                    .preferredColorScheme(settings.appearance.colorScheme)
                    // Wire haptic feedback on every `Button` tap by
                    // default. Children that explicitly opt out
                    // (`.buttonStyle(.plain)`, system Picker rows,
                    // etc.) keep their own behaviour ; everything
                    // else gets a soft selection click for free.
                    .buttonStyle(HapticTapStyle())
                if showingSplash {
                    SplashView(isDismissing: dismissingSplash)
                        // Slow fade-out so the logo doesn't vanish —
                        // it lingers as ContentView starts surfacing.
                        .transition(
                            .opacity.animation(.easeInOut(duration: 0.7))
                        )
                        .zIndex(1)
                }
            }
            .task {
                // Honour the stored appearance preference at cold
                // launch — `AppSettings.init()` can't apply it
                // because no UIWindowScene is connected yet. Doing
                // it here (the first SwiftUI task on screen) is safe :
                // the splash window is already up.
                settings.applyAppearanceToWindows()
                // Hook a window-level pan recognizer that ends
                // editing on a strong downward swipe — fall-back
                // for sheets too short for `.scrollDismissesKeyboard`
                // to engage on its own.
                GlobalKeyboardDismissPan.shared.installIfNeeded()
                // Beat 1 (0.0–0.7s): logo fades + scales in.
                // Beat 2 (0.7–1.5s): hold — gives the eye time to land.
                // Beat 3 (1.5–2.2s): scale-up + fade-out into the app.
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeIn(duration: 0.7)) {
                    dismissingSplash = true
                }
                withAnimation(.easeInOut(duration: 0.7)) {
                    showingSplash = false
                }
            }
        }
    }
}
