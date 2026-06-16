// swift-tools-version: 6.0
import PackageDescription

// PinkhaFFI — wraps the Rust UniFFI-generated C library and the Swift
// bindings into a single Swift module consumed by every higher-level
// package. The xcframework lives at the repo root (built by
// build-xcframework.sh) and is referenced via a relative path so a
// fresh `cargo build` + script run rebuilds it in place without
// touching the package layout.
let package = Package(
    name: "PinkhaFFI",
    platforms: [.iOS("26.0"), .macOS("14.0")],
    products: [
        .library(name: "PinkhaFFI", targets: ["PinkhaFFI"])
    ],
    targets: [
        // The static-library xcframework + headers. Path is resolved
        // relative to this Package.swift — repo root sits three levels up.
        .binaryTarget(
            name: "pinkhaFFI",
            path: "../../../pinkha.xcframework"
        ),
        // Public Swift layer: hand-written Codable mirrors of the Rust
        // domain types + the typed `PinkhaApi` extensions + the
        // uniffi-bindgen output (pinkha.swift).
        .target(
            name: "PinkhaFFI",
            dependencies: ["pinkhaFFI"],
            path: "Sources/PinkhaFFI"
        )
    ]
)
