import Foundation

/// Tagged union of every navigation destination reachable from the
/// Library tab's `NavigationStack`. Previously the stack only held
/// leaf ids (`[String]`) and shelves were pushed via closure-based
/// `NavigationLink(destination:)` — that mixed pattern caused the
/// "swipe back from a leaf created inside a shelf jumps to the root
/// tab" bug : appending a leaf id to the path while a closure-pushed
/// shelf was on the stack made iOS rebuild the stack to honour the
/// path, dropping the shelf.
///
/// With a single typed path each push is symmetric : append `.shelf(id)`
/// to drill into a shelf, append `.leaf(id)` to open an editor.
/// Swipe-back / programmatic pop just truncates the array — no surprise
/// jumps. Both cases are `Hashable` so `NavigationLink(value:)` accepts
/// them.
public enum LibraryRoute: Hashable, Codable {
    case leaf(String)
    case shelf(String)
}
