// swift-tools-version: 6.0
import PackageDescription

// PinkhaRichText — UIKit-backed SwiftUI editor that drives `chaqaq`
// (the Rust rich-text core via PinkhaFFI). Owns the entire
// RichTextEditor coordinator, its toolbar pill, mention bar,
// markdown shortcut machinery, and span ↔ NSAttributedString
// conversion. Consumed by LeafFeature (in Phase 7) and any
// other feature that needs an inline editor.
let package = Package(
    name: "PinkhaRichText",
    platforms: [.iOS("26.0"), .macOS("14.0")],
    products: [
        .library(name: "PinkhaRichText", targets: ["PinkhaRichText"])
    ],
    dependencies: [
        .package(path: "../PinkhaFFI"),
        .package(path: "../PinkhaCore"),
        .package(path: "../PinkhaDesignSystem")
    ],
    targets: [
        .target(
            name: "PinkhaRichText",
            dependencies: [
                .product(name: "PinkhaFFI", package: "PinkhaFFI"),
                .product(name: "PinkhaCore", package: "PinkhaCore"),
                .product(name: "PinkhaDesignSystem", package: "PinkhaDesignSystem")
            ],
            path: "Sources/PinkhaRichText"
        )
    ]
)
