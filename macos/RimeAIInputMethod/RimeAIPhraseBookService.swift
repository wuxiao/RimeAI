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
    private static let englishTokenLimit = 512

    private let lock = NSLock()
    private let refreshQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.phrasebook-snapshot",
        qos: .utility
    )
    private let databaseURL: URL
    private var store: PhraseBookStore?

    private struct ReadSnapshot: Sendable {
        let domainMappings: [String: String]
        let entries: [PhraseBookEntry]
        let loadedAt: TimeInterval

        static let cold = ReadSnapshot(
            domainMappings: [:],
            entries: [],
            loadedAt: -.infinity
        )
    }

    private var snapshot = ReadSnapshot.cold
    private var isRefreshing = false

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
        // 与 PhraseBookStore.phrases 的 SQL 排序一致：精确命中 > 本域 >
        // 使用次数 > 最近使用。
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
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.lastUsedAt > rhs.lastUsedAt
        }
        let matched = snap.entries.filter { entry in
            // 镜像 SQL 的 `pinyin_keys = ? OR pinyin_keys LIKE ?%'：这里
            // 的前缀匹配是大小写敏感的精确比较，而 SQL LIKE 对 ASCII 大
            // 小写不敏感——存储侧 pinyin_keys 一律为小写（[a-z']）时两者
            // 等价，仅手工导入的大写键才可能分叉。
            (entry.domain == domain || entry.domain == PhraseBookDomain.global)
                && (entry.pinyinKeys == trimmed
                    || entry.pinyinKeys.hasPrefix(trimmed))
        }
        return Array(matched.sorted(by: precedes).prefix(5))
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
        refreshSnapshotAsync()
        return folded
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

    func exportJSON(to destination: URL) throws {
        guard let store = activeStore() else {
            throw PhraseBookError.fileSystem(
                "phrasebook store unavailable"
            )
        }
        try store.exportJSON(to: destination)
    }

    /// One-shot adoption of the legacy personal English tokens.
    @discardableResult
    func adoptPersonalEnglishTokens(_ tokens: Set<String>) -> Int {
        guard let store = activeStore() else {
            return 0
        }
        return (try? store.adoptUserTokens(tokens)) ?? 0
    }

    /// Personalized ASCII tokens for the mixed-composition resolver
    /// (LP-006), across all domains, most frequent first. Memory-only:
    /// serves the process snapshot, ordered like the store's
    /// `englishTokens(limit:)`.
    func allEnglishTokens(
        limit: Int = RimeAIPhraseBookService.englishTokenLimit
    ) -> Set<String> {
        guard limit > 0 else {
            return []
        }
        var best: [String: (count: Int, lastUsedAt: Date)] = [:]
        for entry in currentSnapshot().entries
        where entry.text.isLowercaseASCIIToken {
            if let existing = best[entry.text] {
                if (entry.count, entry.lastUsedAt)
                    > (existing.count, existing.lastUsedAt)
                {
                    best[entry.text] = (entry.count, entry.lastUsedAt)
                }
            } else {
                best[entry.text] = (entry.count, entry.lastUsedAt)
            }
        }
        return Set(
            best
                .sorted { $0.value.count > $1.value.count
                    || $0.value.count == $1.value.count
                        && $0.value.lastUsedAt > $1.value.lastUsedAt
                }
                .prefix(limit)
                .map(\.key)
        )
    }

    /// Records ASCII tokens accepted through mixed composition as auto
    /// phrases so they are immediately available to the resolver.
    func recordMixedEnglishTokens(_ tokens: Set<String>) {
        guard let store = activeStore(), !tokens.isEmpty else {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            for token in tokens.sorted() {
                try? store.recordAutoPhrase(
                    text: token,
                    pinyinKeys: token,
                    domain: PhraseBookDomain.global
                )
            }
            self.refreshSnapshotAsync()
        }
    }

    /// Synchronously rebuilds the read snapshot on the caller's queue.
    /// Only background callers: the typing path uses `currentSnapshot()`.
    func refreshSnapshotNow() {
        guard let store = activeStore() else {
            return
        }
        let mappings = (try? store.domainMappings()) ?? []
        let entries = (try? store.entries(
            limit: Self.snapshotEntryLimit
        )) ?? []
        lock.lock()
        snapshot = ReadSnapshot(
            domainMappings: Dictionary(
                mappings.map { ($0.bundleIdentifier, $0.domain) },
                uniquingKeysWith: { first, _ in first }
            ),
            entries: entries,
            loadedAt: ProcessInfo.processInfo.systemUptime
        )
        lock.unlock()
    }

    private func refreshSnapshotAsync() {
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

    private func currentSnapshot() -> ReadSnapshot {
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

    private func activeStore() -> PhraseBookStore? {
        lock.lock()
        defer { lock.unlock() }
        if let store {
            return store
        }
        let opened = try? PhraseBookStore(databaseURL: databaseURL)
        store = opened
        return opened
    }
}

private extension String {
    /// `englishTokens(limit:)` 的内存等价：首字符为小写字母、其余为
    /// 小写字母或数字（SQL `GLOB '[a-z][a-z0-9]*'`）。
    var isLowercaseASCIIToken: Bool {
        guard let first = unicodeScalars.first,
              ("a" ... "z").contains(first)
        else {
            return false
        }
        return unicodeScalars.dropFirst().allSatisfy {
            ("a" ... "z").contains($0) || ("0" ... "9").contains($0)
        }
    }
}
