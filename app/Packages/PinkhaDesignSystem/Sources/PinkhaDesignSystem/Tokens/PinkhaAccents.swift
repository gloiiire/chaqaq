#if canImport(UIKit)
import UIKit
#endif
import SwiftUI

// MARK: - Accent palette
//
// pinkha exposes 10 accent choices as an authored, ordered list. Each entry
// is backed by a `UIColor.system*` value — those are already dynamic (light /
// dark / High Contrast / Elevated) so we get accessibility variants for free
// without an Asset Catalog. Adding a brand-only accent later means a Color
// Set in `Resources/Assets.xcassets` and one row here.
//
// The `name` field is the persisted identifier (SQLite / FFI). Never rename
// once shipped without a migration — leaf/book records reference it.

/// One choice in the accent palette. Stable ordering; deterministic ids.
public struct PinkhaAccent: Identifiable, Hashable, Sendable {
    /// Persisted identifier — used as the SQLite key. Never rename.
    public let name: String
    /// Human-facing label. Localise at the call site via `LocalizedStringKey`.
    public let displayNameKey: String
    /// The dynamic UIColor rendering. Adapts to light/dark/HighContrast/Elevated
    /// automatically — do NOT resolve to a static hex.
    public let uiColor: UIColor

    public var id: String { name }
    public var color: Color { Color(uiColor: uiColor) }
}

public enum PinkhaAccentPalette {
    /// Canonical ordered palette. New entries append at the end so persisted
    /// `Leaf.accentColor` names stay valid.
    public static let all: [PinkhaAccent] = [
        .init(name: "red",    displayNameKey: "Red",    uiColor: .systemRed),
        .init(name: "pink",   displayNameKey: "Pink",   uiColor: .systemPink),
        .init(name: "orange", displayNameKey: "Orange", uiColor: .systemOrange),
        .init(name: "yellow", displayNameKey: "Yellow", uiColor: .systemYellow),
        .init(name: "green",  displayNameKey: "Green",  uiColor: .systemGreen),
        .init(name: "cyan",   displayNameKey: "Cyan",   uiColor: .systemCyan),
        .init(name: "blue",   displayNameKey: "Blue",   uiColor: .systemBlue),
        .init(name: "purple", displayNameKey: "Purple", uiColor: .systemPurple),
        .init(name: "brown",  displayNameKey: "Brown",  uiColor: .systemBrown),
        .init(name: "gray",   displayNameKey: "Gray",   uiColor: .systemGray),
    ]

    /// Resolves a persisted accent name to its palette entry. Falls back to
    /// `nil` (caller decides between system tint and hard failure).
    public static func accent(for name: String?) -> PinkhaAccent? {
        guard let name else { return nil }
        return all.first { $0.name == name }
    }

    /// The palette's fallback when nothing is chosen. Uses SwiftUI's own
    /// `.accentColor` (which reads from the environment / Info.plist), so the
    /// app respects the user's system-wide tint if they've overridden it.
    public static let systemDefault: Color = .accentColor
}
