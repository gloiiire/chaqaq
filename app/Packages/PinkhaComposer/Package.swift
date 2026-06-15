// swift-tools-version: 6.0
import PackageDescription

// PinkhaComposer — composition orchestrator that owns the global create
// bubble's presentation state (sheets, alerts, create mode picker) and
// the cross-feature notification names. Sits one layer above PinkhaCore
// so feature modules (LeafFeature, BookFeature, LibraryFeature) can
// depend on it without depending on each other — breaking the
// Library↔Leaf cycle that previously blocked the multi-target split.
let package = Package(
    name: "PinkhaComposer",
    platforms: [.iOS("26.0"), .macOS("14.0")],
    products: [
        .library(name: "PinkhaComposer", targets: ["PinkhaComposer"])
    ],
    dependencies: [
        .package(path: "../PinkhaFFI"),
        .package(path: "../PinkhaCore")
    ],
    targets: [
        .target(
            name: "PinkhaComposer",
            dependencies: [
                .product(name: "PinkhaFFI", package: "PinkhaFFI"),
                .product(name: "PinkhaCore", package: "PinkhaCore")
            ],
            path: "Sources/PinkhaComposer"
        )
    ]
)
