import Testing
import Foundation
@testable import PinkhaCore

// La logique pure de l'export : le nom de fichier que l'utilisateur verra
// dans Fichiers, et le mode d'emploi glissé dans l'archive.
@Suite("Export de la bibliothèque — logique pure")
struct LibraryExportTests {

    /// Le nom doit se trier chronologiquement quand plusieurs sauvegardes
    /// cohabitent dans un dossier, et ne contenir aucun caractère qu'un
    /// système de fichiers refuse. « / » et « : » sont les deux pièges.
    @Test func stampIsSortableAndFilesystemSafe() {
        let date = Date(timeIntervalSince1970: 1_756_800_000)
        let s = LibraryExport.stamp(date)
        #expect(!s.contains("/"))
        #expect(!s.contains(":"))
        #expect(s.hasPrefix("20"))
        // yyyy-MM-dd HHhmm → un tri alphabétique est un tri chronologique.
        #expect(s.count == 16)
    }

    @Test func stampsOrderChronologically() {
        let tot = LibraryExport.stamp(Date(timeIntervalSince1970: 1_700_000_000))
        let tard = LibraryExport.stamp(Date(timeIntervalSince1970: 1_800_000_000))
        #expect(tot < tard)
    }

    /// L'archive doit rester compréhensible sans l'app : c'est tout l'intérêt
    /// d'exporter du SQLite plutôt qu'un format maison.
    @Test func readmeExplainsHowToOpenItWithoutTheApp() {
        let texte = LibraryExport.lisezMoi(horodatage: "2026-09-02 09h00")
        #expect(texte.contains("2026-09-02 09h00"))
        #expect(texte.contains("pinkha.db"))
        #expect(texte.contains("Covers"))
        #expect(texte.lowercased().contains("sqlite"))
    }
}
