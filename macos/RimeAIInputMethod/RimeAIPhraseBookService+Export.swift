import Foundation

extension RimeAIPhraseBookService {
    // MARK: - Language profile export (P1-4)

    func exportJSON(to destination: URL) throws {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        try store.exportJSON(to: destination)
    }

    /// Aggregated export of all three learning layers (P1-4): L1 phrasebook
    /// entries/mappings, the L2 user LM (gzip-decoded), and every L3 style
    /// profile currently on disk.
    func exportLanguageProfile(to destination: URL) throws {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        try LanguageProfileExporter.export(
            phrasebook: store,
            languageProfileDirectory: layout.languageProfileDirectory,
            to: destination
        )
    }
}
