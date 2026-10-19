import Foundation

/// Process-side singleton bridging the input method and the settings UI
/// to the L1 phrasebook (LP-002/LP-006), mirroring the layout of
/// `RimeAIHistoryService`.
///
/// 读路径（候选填充、混输个人词表）只读进程内快照：击键路径绝不
/// 触碰 SQLite，全部查询在后台队列刷新快照时完成。写路径（设置页、
/// 混输学习）仍走存储队列，成功后异步刷新快照。
final class RimeAIPhraseBookService: @unchecked Sendable {
    static let shared = RimeAIPhraseBookService()

    /// 快照的最长服役时间：超过后下一次读路径顺手触发一次后台刷新，
    /// 吸收其他进程（固化循环）写入的变化。
    private static let snapshotStalenessSeconds: TimeInterval = 30
    private static let snapshotEntryLimit = 100_000
    private static let snapshotLexiconEntryLimit = 100_000
    static let englishTokenLimit = 512

    private let lock = NSLock()
    private let refreshQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.phrasebook-snapshot",
        qos: .utility
    )
    private let databaseURL: URL
    private var store: PhraseBookStore?
    private var lexiconStore: DomainLexiconStore?

    struct ReadSnapshot: Sendable {
        let domainMappings: [String: String]
        let entries: [PhraseBookEntry]
        /// Enabled lexicon entries (unblocked, all mounted domains),
        /// wrapped for fusion. Queried with the same domain rule as
        /// learned entries: caller's domain or `global`.
        let lexiconEntries: [PhraseBookEntry]
        let loadedAt: TimeInterval

        static let cold = ReadSnapshot(
            domainMappings: [:],
            entries: [],
            lexiconEntries: [],
            loadedAt: -.infinity
        )
    }

    private var snapshot = ReadSnapshot.cold
    private var isRefreshing = false

    /// Serial queue for whole-artifact operations (aggregate export vs
    /// permanent clear). Both touch the same files across L1/L2/L3, and
    /// both are user-triggered from the settings UI — running them on the
    /// global concurrent queue would let a clear interleave with an
    /// in-flight export and produce a half-cleared export file.
    static let artifactOperationQueue = DispatchQueue(
        label: "rimeai.phrasebook.artifact-operations"
    )

    private init() {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        databaseURL = layout.phraseBookDatabase
        store = try? PhraseBookStore(databaseURL: databaseURL)
        refreshSnapshotAsync()
    }

    /// Candidate-injection lookup for the current composition. Memory-only:
    /// reads the process snapshot, never the database.
    func phrases(
        matchingPinyin pinyin: String,
        bundleIdentifier: String
    ) -> [PhraseBookEntry] {
        let snap = currentSnapshot()
        let trimmed = pinyin.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        guard !trimmed.isEmpty else {
            return []
        }
        let domain = snap.domainMappings[bundleIdentifier]
            ?? PhraseBookDomain.global
        // 与设计文档 §4 的融合排序一致：精确命中 > 本域 > 学习短语
        // （auto/user/llm）优先于词库短语 > 频次（学习 count vs 词库
        // weight）> 最近使用。
        func precedes(_ lhs: PhraseBookEntry, _ rhs: PhraseBookEntry) -> Bool {
            let lhsExact = lhs.pinyinKeys == trimmed
            let rhsExact = rhs.pinyinKeys == trimmed
            if lhsExact != rhsExact {
                return lhsExact
            }
            let lhsDomain = lhs.domain == domain
            let rhsDomain = rhs.domain == domain
            if lhsDomain != rhsDomain {
                return lhsDomain
            }
            let lhsLearned = lhs.source != .lexicon
            let rhsLearned = rhs.source != .lexicon
            if lhsLearned != rhsLearned {
                return lhsLearned
            }
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.lastUsedAt > rhs.lastUsedAt
        }
        func matches(_ entry: PhraseBookEntry) -> Bool {
            (entry.domain == domain || entry.domain == PhraseBookDomain.global)
                && (entry.pinyinKeys == trimmed
                    || entry.pinyinKeys.hasPrefix(trimmed))
        }
        let matched = snap.entries.filter(matches)
            + snap.lexiconEntries.filter(matches)
        return Array(matched.sorted(by: precedes).prefix(5))
    }

    /// Current bundle→domain mapping from the in-memory snapshot
    /// (typing-path safe, P2-4). nil = unmapped → daemon treats the
    /// request as global, identical to the pre-domain protocol.
    func domain(forBundleIdentifier bundleIdentifier: String) -> String? {
        currentSnapshot().domainMappings[bundleIdentifier]
    }

    func entries(
        domain: String? = nil,
        limit: Int = 500
    ) throws -> [PhraseBookEntry] {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        return try store.entries(domain: domain, limit: limit)
    }

    func statistics() throws -> PhraseBookStatistics {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        return try store.statistics()
    }

    func domainMappings() throws -> [PhraseDomainMapping] {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        return try store.domainMappings()
    }

    @discardableResult
    func setProtected(id: String, isProtected: Bool) throws -> Bool {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        let updated = try store.setProtected(id: id, isProtected: isProtected)
        refreshSnapshotAsync()
        return updated
    }

    /// Settings-page curation: adds a protected user phrase.
    @discardableResult
    func addUserPhrase(
        text: String,
        pinyinKeys: String,
        domain: String = PhraseBookDomain.global
    ) throws -> PhraseBookEntry {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        let entry = try store.addUserPhrase(
            text: text,
            pinyinKeys: pinyinKeys,
            domain: domain
        )
        refreshSnapshotAsync()
        return entry
    }

    /// Settings-page domain mapping editor (LP-007).
    @discardableResult
    func setDomainMapping(
        bundleIdentifier: String,
        domain: String
    ) throws -> Bool {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        let updated = try store.setDomainMapping(
            bundleIdentifier: bundleIdentifier,
            domain: domain
        )
        refreshSnapshotAsync()
        return updated
    }

    @discardableResult
    func removeDomainMapping(
        bundleIdentifier: String
    ) throws -> Bool {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        let removed = try store.removeDomainMapping(
            bundleIdentifier: bundleIdentifier
        )
        refreshSnapshotAsync()
        return removed
    }

    @discardableResult
    func renameDomain(from source: String, to target: String) throws -> Int {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        let moved = try store.renameDomain(from: source, to: target)
        // P2-16：域改名必须联动 L2/L3 产物，否则旧域名下的 user-lm
        // 计数与风格画像永远残留。
        try LanguageProfileArtifacts.renameDomain(
            from: source,
            to: target,
            in: languageProfileDirectory()
        )
        refreshSnapshotAsync()
        return moved
    }

    @discardableResult
    func deleteDomain(_ source: String) throws -> Int {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        let folded = try store.deleteDomain(source)
        try LanguageProfileArtifacts.deleteDomain(
            source,
            in: languageProfileDirectory()
        )
        refreshSnapshotAsync()
        return folded
    }

    private func languageProfileDirectory() -> URL {
        RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ).languageProfileDirectory
    }

    @discardableResult
    func delete(id: String) throws -> Bool {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        let deleted = try store.delete(id: id)
        refreshSnapshotAsync()
        return deleted
    }

    @discardableResult
    func clearAll() throws -> Int64 {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        let generation = try store.clearAll()
        refreshSnapshotAsync()
        return generation
    }

    /// Synchronously rebuilds the read snapshot on the caller's queue.
    /// Only background callers: the typing path uses `currentSnapshot()`.
    func refreshSnapshotNow() {
        guard let store = activeStore() else {
            return
        }
        let mappings = (try? store.domainMappings()) ?? []
        let entries = (try? store.snapshotEntries(
            limit: Self.snapshotEntryLimit
        )) ?? []
        let lexiconEntries = activeLexiconStore()
            .flatMap {
                try? $0.snapshotEntries(
                    limit: Self.snapshotLexiconEntryLimit
                )
            } ?? []
        lock.lock()
        snapshot = ReadSnapshot(
            domainMappings: Dictionary(
                mappings.map { ($0.bundleIdentifier, $0.domain) },
                uniquingKeysWith: { first, _ in first }
            ),
            entries: entries,
            lexiconEntries: lexiconEntries,
            loadedAt: ProcessInfo.processInfo.systemUptime
        )
        lock.unlock()
    }

    func refreshSnapshotAsync() {
        lock.lock()
        let alreadyRefreshing = isRefreshing
        isRefreshing = true
        lock.unlock()
        guard !alreadyRefreshing else {
            return
        }
        refreshQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.refreshSnapshotNow()
            self.lock.lock()
            self.isRefreshing = false
            self.lock.unlock()
        }
    }

    func currentSnapshot() -> ReadSnapshot {
        lock.lock()
        let snap = snapshot
        let refreshing = isRefreshing
        lock.unlock()
        if !refreshing,
           ProcessInfo.processInfo.systemUptime - snap.loadedAt
               > Self.snapshotStalenessSeconds
        {
            refreshSnapshotAsync()
        }
        return snap
    }

    func activeStore() -> PhraseBookStore? {
        lock.lock()
        defer { lock.unlock() }
        if let store {
            return store
        }
        let opened = try? PhraseBookStore(databaseURL: databaseURL)
        store = opened
        return opened
    }

    /// Same lazy-open pattern as `activeStore()`, for the asset-side
    /// lexicon store sharing the same database file.
    func activeLexiconStore() -> DomainLexiconStore? {
        lock.lock()
        defer { lock.unlock() }
        if let lexiconStore {
            return lexiconStore
        }
        let opened = try? DomainLexiconStore(databaseURL: databaseURL)
        lexiconStore = opened
        return opened
    }
}
