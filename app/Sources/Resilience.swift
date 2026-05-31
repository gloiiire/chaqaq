import Foundation
import SwiftUI

// MARK: - User-facing error messages

/// Maps `PinkhaError` FFI values to French user-readable messages.
/// Technical errors (invalid UUID, oversized payload) are condensed;
/// domain errors (NotFound, Storage) have their own distinct wording.
extension PinkhaError {
    var userMessage: String {
        switch self {
        case .NotFound:
            return "Cet élément est introuvable. Il a peut-être été supprimé."
        case .InvalidOperation(let detail):
            return "Opération invalide : \(detail)"
        case .Storage:
            return "Une erreur de stockage est survenue. Réessaie dans un instant."
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
@discardableResult
func tryCatch<T>(into errorMessage: inout String?, _ work: () throws -> T) -> T? {
    do {
        return try work()
    } catch let err as PinkhaError {
        errorMessage = err.userMessage
    } catch {
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
            "Erreur",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            if let onRetry {
                Button("Réessayer") {
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
