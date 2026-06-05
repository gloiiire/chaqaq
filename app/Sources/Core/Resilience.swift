import Foundation
import SwiftUI

// MARK: - User-facing error messages

/// Maps `PinkhaError` FFI values to user-readable messages.
/// Technical errors (invalid UUID, oversized payload) are condensed;
/// domain errors (NotFound, Storage) have their own distinct wording.
extension PinkhaError {
    var userMessage: String {
        switch self {
        case .NotFound:
            return "This item could not be found. It may have been deleted."
        case .InvalidOperation(let detail):
            return "Invalid operation: \(detail)"
        case .Storage(let detail):
            // Detail messages from the Rust side are typically user-friendly
            // for import errors (e.g. "textbundle root does not exist: ...")
            // and informative even when technical. Surfacing the detail beats
            // a generic message that hides what actually went wrong.
            return detail.isEmpty
                ? "A storage error occurred. Please try again in a moment."
                : detail
        }
    }

    /// `true` if a retry has a reasonable chance of succeeding (transient storage error).
    var isRecoverable: Bool {
        if case .Storage = self { return true }
        return false
    }
}

// MARK: - Safe execution helper

/// Executes `work`, returns its value on success, or writes a user-readable error
/// message into `errorMessage` and returns `nil` on failure.
/// Idiomatic pattern for view models that expose a `@Published errorMessage`.
///
/// Side effect: unexpected failures (transient storage errors, anything not a
/// `PinkhaError`) are forwarded to Sentry. `NotFound` and `InvalidOperation`
/// are user-facing expected states and stay silent to avoid alert fatigue.
@discardableResult
func tryCatch<T>(into errorMessage: inout String?, _ work: () throws -> T) -> T? {
    do {
        return try work()
    } catch let err as PinkhaError {
        if case .Storage = err {
            Observability.capture(err)
        }
        errorMessage = err.userMessage
    } catch {
        Observability.capture(error)
        errorMessage = error.localizedDescription
    }
    return nil
}

// MARK: - Alert with retry

/// SwiftUI view modifier: presents an alert driven by an `errorMessage: String?` binding,
/// with an optional "Retry" button.
extension View {
    func errorAlert(
        message: Binding<String?>,
        onRetry: (() -> Void)? = nil
    ) -> some View {
        alert(
            "Error",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            if let onRetry {
                Button("Retry") {
                    message.wrappedValue = nil
                    onRetry()
                }
            }
            Button("OK", role: .cancel) {
                message.wrappedValue = nil
            }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
