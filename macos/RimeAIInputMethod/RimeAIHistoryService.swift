import Foundation

final class RimeAIHistoryService: @unchecked Sendable {
    static let shared = RimeAIHistoryService()

    private let lock = NSLock()
    private let databaseURL: URL
    private let vectorIndexURL: URL
    private var store: HistoryStore?

    private init() {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        databaseURL = layout.historyDatabase
        vectorIndexURL = layout.historyVectorIndex
        store = try? HistoryStore(
            databaseURL: databaseURL,
            vectorIndexURL: vectorIndexURL
        )
    }

    func appendAsync(
        _ commit: HistoryCommit,
        completion: (@Sendable (Result<Void, HistoryStoreError>) -> Void)? = nil
    ) {
        guard let store = activeStore() else {
            completion?(.failure(.fileSystem("history store unavailable")))
            return
        }
        store.appendAsync(commit, completion: completion)
    }

    func statistics() throws -> HistoryStoreStatistics {
        guard let store = activeStore() else {
            throw HistoryStoreError.fileSystem("history store unavailable")
        }
        return try store.statistics()
    }

    func recentText(maxCharacters: Int = 600) throws -> String {
        guard let store = activeStore() else {
            throw HistoryStoreError.fileSystem("history store unavailable")
        }
        return try store.recentText(maxCharacters: maxCharacters)
    }

    func relevantSnippets(
        query: String,
        maximumCount: Int = 8
    ) throws -> [CloudHistorySnippet] {
        guard let store = activeStore() else {
            throw HistoryStoreError.fileSystem("history store unavailable")
        }
        return try store.relevantSnippets(
            query: query,
            maximumCount: maximumCount
        )
    }

    func contextSnapshot(
        query: String,
        maxRecentCharacters: Int = 600,
        maximumSnippetCount: Int = 8
    ) throws -> HistoryContextSnapshot {
        guard let store = activeStore() else {
            throw HistoryStoreError.fileSystem("history store unavailable")
        }
        return try store.contextSnapshot(
            query: query,
            maxRecentCharacters: maxRecentCharacters,
            maximumSnippetCount: maximumSnippetCount
        )
    }

    func exportJSONL(to destination: URL) throws {
        guard let store = activeStore() else {
            throw HistoryStoreError.fileSystem("history store unavailable")
        }
        try store.exportJSONL(to: destination)
    }

    @discardableResult
    func clearAll() throws -> Int64 {
        guard let store = activeStore() else {
            throw HistoryStoreError.fileSystem("history store unavailable")
        }
        return try store.clearAll()
    }

    func discardOpenStore() {
        lock.withLock {
            store = nil
        }
    }

    private func activeStore() -> HistoryStore? {
        lock.withLock {
            if let store {
                return store
            }
            let opened = try? HistoryStore(
                databaseURL: databaseURL,
                vectorIndexURL: vectorIndexURL
            )
            store = opened
            return opened
        }
    }
}
