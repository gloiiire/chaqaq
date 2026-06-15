// swift-tools-version: 6.0
import PackageDescription

// PinkhaDesignSystem — reusable visual components shared across features.
// Sits above PinkhaCore so it can consume AppSettings / Haptic / etc.
// for theme-aware rendering, and above PinkhaFFI so it can render
// FFI types like PropertyValueFfi in PropertyInputRow.
let package = Package(
    name: "PinkhaDesignSystem",
    platforms: [.iOS("26.0"), .macOS("14.0")],
    products: [
        .library(name: "PinkhaDesignSystem", targets: ["PinkhaDesignSystem"])
    ],
    dependencies: [
        .package(path: "../PinkhaFFI"),
        .package(path: "../PinkhaCore")
    ],
    targets: [
        .target(
            name: "PinkhaDesignSystem",
            dependencies: [
                .product(name: "PinkhaFFI", package: "PinkhaFFI"),
                .product(name: "PinkhaCore", package: "PinkhaCore")
            ],
            path: "Sources/PinkhaDesignSystem"
        )
    ]
)
