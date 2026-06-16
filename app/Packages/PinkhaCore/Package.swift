// swift-tools-version: 6.0
import PackageDescription

// PinkhaCore — first slice of the cross-cutting utilities split out of
// the app target: Keychain, Sentry-backed Observability, Haptic, and
// UIKit↔SwiftUI bridges (SafariSwitcher, UIKitContextMenu,
// TabSnapshotCache, GlobalKeyboardDismissPan). AppSettings, Resilience,
// and PinkhaStore stay in the app target until their dependencies on
// feature-layer types are untangled in a follow-up slice.
let package = Package(
    name: "PinkhaCore",
    platforms: [.iOS("26.0"), .macOS("14.0")],
    products: [
        .library(name: "PinkhaCore", targets: ["PinkhaCore"])
    ],
    dependencies: [
        .package(path: "../PinkhaFFI"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.49.0")
    ],
    targets: [
        .target(
            name: "PinkhaCore",
            dependencies: [
                .product(name: "PinkhaFFI", package: "PinkhaFFI"),
                .product(name: "Sentry", package: "sentry-cocoa")
            ],
            path: "Sources/PinkhaCore"
        )
    ]
)
