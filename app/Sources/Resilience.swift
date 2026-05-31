import Foundation
import SwiftUI

// MARK: - Erreurs utilisateur

/// Conversion des `PinkhaError` FFI en messages français adaptés à l'utilisateur.
/// Les erreurs techniques (UUID invalide, payload trop grand) sont condensées,
/// les erreurs métier (NotFound, Storage) ont un libellé propre.
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

    /// Vrai si une nouvelle tentative a une chance d'aboutir (storage transitoire).
    var isRecoverable: Bool {
        if case .Storage = self { return true }
        return false
    }
}

// MARK: - Exécution sécurisée

/// Capture l'erreur sans la propager, retourne `nil` en cas d'échec et écrit
/// le message utilisateur dans `errorMessage`. Pattern idiomatique pour les
/// view models qui exposent un `@Published errorMessage`.
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

// MARK: - Alerte avec retry

/// Modificateur SwiftUI : présente un alert depuis un `errorMessage: String?`
/// avec un bouton « Réessayer » optionnel.
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
