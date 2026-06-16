// swift-tools-version: 6.0
import PackageDescription

// PinkhaFeatures — five feature targets that compose the Pinkha UI.
// The dependency order matches the navigation graph: LeafFeature is
// the leaf of the DAG (an open leaf doesn't link anywhere except
// inline doc references); Book rows open a LeafView via
// NavigationLink; the Library home stacks both leaves and books;
// Search hits route to either; Import lands every imported leaf
// back in the Library inbox.
//
// LeafFeature ← BookFeature ← {LibraryFeature, SearchFeature, ImportFeature}
//
// Products are added incrementally as each feature target gains a
// Sources/ tree. Currently in-place: LeafFeature.
let package = Package(
    name: "PinkhaFeatures",
    platforms: [.iOS("26.0"), .macOS("14.0")],
    products: [
        .library(name: "LeafFeature",    targets: ["LeafFeature"]),
        .library(name: "BookFeature",    targets: ["BookFeature"]),
        .library(name: "LibraryFeature", targets: ["LibraryFeature"]),
        .library(name: "ImportFeature",  targets: ["ImportFeature"]),
        .library(name: "SearchFeature",  targets: ["SearchFeature"])
    ],
    dependencies: [
        .package(path: "../PinkhaFFI"),
        .package(path: "../PinkhaCore"),
        .package(path: "../PinkhaDesignSystem"),
        .package(path: "../PinkhaRichText"),
        .package(path: "../PinkhaComposer")
    ],
    targets: [
        .target(
            name: "LeafFeature",
            dependencies: [
                .product(name: "PinkhaFFI",          package: "PinkhaFFI"),
                .product(name: "PinkhaCore",         package: "PinkhaCore"),
                .product(name: "PinkhaDesignSystem", package: "PinkhaDesignSystem"),
                .product(name: "PinkhaRichText",     package: "PinkhaRichText"),
                .product(name: "PinkhaComposer",     package: "PinkhaComposer")
            ],
            path: "Sources/LeafFeature"
        ),
        .target(
            name: "BookFeature",
            dependencies: [
                "LeafFeature",
                .product(name: "PinkhaFFI",          package: "PinkhaFFI"),
                .product(name: "PinkhaCore",         package: "PinkhaCore"),
                .product(name: "PinkhaDesignSystem", package: "PinkhaDesignSystem"),
                .product(name: "PinkhaComposer",     package: "PinkhaComposer")
            ],
            path: "Sources/BookFeature"
        ),
        .target(
            name: "LibraryFeature",
            dependencies: [
                "LeafFeature",
                "BookFeature",
                .product(name: "PinkhaFFI",          package: "PinkhaFFI"),
                .product(name: "PinkhaCore",         package: "PinkhaCore"),
                .product(name: "PinkhaDesignSystem", package: "PinkhaDesignSystem"),
                .product(name: "PinkhaComposer",     package: "PinkhaComposer")
            ],
            path: "Sources/LibraryFeature"
        ),
        .target(
            name: "ImportFeature",
            dependencies: [
                .product(name: "PinkhaFFI",          package: "PinkhaFFI"),
                .product(name: "PinkhaCore",         package: "PinkhaCore"),
                .product(name: "PinkhaDesignSystem", package: "PinkhaDesignSystem"),
                .product(name: "PinkhaComposer",     package: "PinkhaComposer")
            ],
            path: "Sources/ImportFeature"
        ),
        .target(
            name: "SearchFeature",
            dependencies: [
                "LeafFeature",
                "BookFeature",
                .product(name: "PinkhaFFI",          package: "PinkhaFFI"),
                .product(name: "PinkhaCore",         package: "PinkhaCore"),
                .product(name: "PinkhaDesignSystem", package: "PinkhaDesignSystem"),
                .product(name: "PinkhaComposer",     package: "PinkhaComposer")
            ],
            path: "Sources/SearchFeature"
        )
    ]
)
