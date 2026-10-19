import Foundation

extension RimeAIPhraseBookService {
    // MARK: - Domain lexicons (settings page)

    func lexicons() throws -> [DomainLexicon] {
        guard let lexiconStore = activeLexiconStore() else {
            throw DomainLexiconError.fileSystem(
                "domain lexicon store unavailable"
            )
        }
        return try lexiconStore.lexicons()
    }

    func lexiconEntries(
        lexiconId: String,
        limit: Int = 500
    ) throws -> [DomainLexiconEntry] {
        guard let lexiconStore = activeLexiconStore() else {
            throw DomainLexiconError.fileSystem(
                "domain lexicon store unavailable"
            )
        }
        return try lexiconStore.entries(lexiconId: lexiconId, limit: limit)
    }

    @discardableResult
    func installLexiconDictYAML(
        source: String,
        domain: String
    ) throws -> LexiconInstallResult {
        guard let lexiconStore = activeLexiconStore() else {
            throw DomainLexiconError.fileSystem(
                "domain lexicon store unavailable"
            )
        }
        let result = try lexiconStore.installDictYaml(
            source,
            domain: domain
        )
        refreshSnapshotAsync()
        return result
    }

    @discardableResult
    func setLexiconEnabled(
        id: String,
        isEnabled: Bool
    ) throws -> Bool {
        guard let lexiconStore = activeLexiconStore() else {
            throw DomainLexiconError.fileSystem(
                "domain lexicon store unavailable"
            )
        }
        let updated = try lexiconStore.setEnabled(id: id, isEnabled: isEnabled)
        refreshSnapshotAsync()
        return updated
    }

    @discardableResult
    func uninstallLexicon(id: String) throws -> Bool {
        guard let lexiconStore = activeLexiconStore() else {
            throw DomainLexiconError.fileSystem(
                "domain lexicon store unavailable"
            )
        }
        let removed = try lexiconStore.uninstall(id: id)
        refreshSnapshotAsync()
        return removed
    }

    @discardableResult
    func setLexiconEntryBlocked(
        lexiconId: String,
        text: String,
        isBlocked: Bool
    ) throws -> Int {
        guard let lexiconStore = activeLexiconStore() else {
            throw DomainLexiconError.fileSystem(
                "domain lexicon store unavailable"
            )
        }
        let affected = try lexiconStore.setEntryBlocked(
            lexiconId: lexiconId,
            text: text,
            isBlocked: isBlocked
        )
        refreshSnapshotAsync()
        return affected
    }
}
