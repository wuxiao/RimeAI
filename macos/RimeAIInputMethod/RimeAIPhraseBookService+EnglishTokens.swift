import Foundation

extension RimeAIPhraseBookService {
    // MARK: - English tokens (mixed composition, LP-006)

    /// One-shot adoption of the legacy personal English tokens.
    @discardableResult
    func adoptPersonalEnglishTokens(_ tokens: Set<String>) -> Int {
        guard let store = activeStore() else {
            return 0
        }
        return (try? store.adoptUserTokens(tokens)) ?? 0
    }

    /// Personalized ASCII tokens for the mixed-composition resolver
    /// (LP-006), across all domains and mounted lexicons, most frequent/pinned
    /// first. Memory-only: serves the precomputed process snapshot.
    func allEnglishTokens(
        limit: Int = RimeAIPhraseBookService.englishTokenLimit
    ) -> Set<String> {
        guard limit > 0 else {
            return []
        }
        let snap = currentSnapshot()
        if limit >= snap.orderedEnglishTokens.count {
            return snap.englishTokens
        }
        return Set(snap.orderedEnglishTokens.prefix(limit))
    }

    /// Preferred original-case renderings keyed by lowercase token (e.g.
    /// `"rimeai" -> "RimeAI"`, `"fastapi" -> "FastAPI"`), derived from the
    /// unified L1 snapshot (learned phrases, custom hotwords, and domain lexicons).
    func casedEnglishTokens(
        limit: Int = RimeAIPhraseBookService.englishTokenLimit
    ) -> [String: String] {
        guard limit > 0 else {
            return [:]
        }
        let snap = currentSnapshot()
        if limit >= snap.orderedEnglishTokens.count {
            return snap.casedEnglishTokens
        }
        let allowed = Set(snap.orderedEnglishTokens.prefix(limit))
        return snap.casedEnglishTokens.filter { allowed.contains($0.key) }
    }

    /// Records ASCII tokens accepted through mixed composition as auto
    /// phrases while preserving case so both keyboard mixing and voice
    /// hotwords retain exact technical spellings.
    func recordMixedEnglishTokens(_ tokens: Set<String>) {
        guard let store = activeStore(), !tokens.isEmpty else {
            return
        }
        let cleaned = tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        guard !cleaned.isEmpty else {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            for token in cleaned {
                try? store.recordAutoPhrase(
                    text: token,
                    pinyinKeys: token.lowercased(),
                    domain: PhraseBookDomain.global
                )
            }
            self.refreshSnapshotAsync()
        }
    }

    struct EnglishVocabularySnapshot {
        let orderedTokens: [String]
        let casedTokens: [String: String]
    }

    /// Builds the lowercase lookup set + preferred mixed-case map from
    /// learned L1 phrasebook entries, user-curated voice hotwords and enabled
    /// domain lexicon entries.
    static func buildEnglishVocabulary(
        entries: [PhraseBookEntry],
        hotwordEntries: [PhraseBookEntry] = [],
        lexiconEntries: [PhraseBookEntry],
        limit: Int
    ) -> EnglishVocabularySnapshot {
        guard limit > 0 else {
            return EnglishVocabularySnapshot(orderedTokens: [], casedTokens: [:])
        }

        struct Candidate {
            let lower: String
            let cased: String
            let isPinned: Bool
            let hasUppercase: Bool
            let isWholeEntry: Bool
            let count: Int
            let lastUsedAt: Date
        }

        func betterCandidate(_ lhs: Candidate, over rhs: Candidate) -> Bool {
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }
            if lhs.hasUppercase != rhs.hasUppercase {
                return lhs.hasUppercase
            }
            if lhs.isWholeEntry != rhs.isWholeEntry {
                return lhs.isWholeEntry
            }
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            return lhs.lastUsedAt > rhs.lastUsedAt
        }

        func rankBetter(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }
            if lhs.count != rhs.count {
                return lhs.count > rhs.count
            }
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
            return lhs.lower < rhs.lower
        }

        var bestByLower: [String: Candidate] = [:]

        func consider(entry: PhraseBookEntry) {
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return
            }
            let isPinned = entry.isProtected || entry.source == .user
            let extractedTokens: [String]
            if trimmed.isEnglishMixableToken {
                extractedTokens = [trimmed]
            } else {
                extractedTokens = extractEmbeddedEnglishTokens(from: trimmed)
            }

            for token in extractedTokens {
                let lower = token.lowercased()
                let candidate = Candidate(
                    lower: lower,
                    cased: token,
                    isPinned: isPinned,
                    hasUppercase: token != lower,
                    isWholeEntry: token == trimmed,
                    count: entry.count,
                    lastUsedAt: entry.lastUsedAt
                )
                if let existing = bestByLower[lower] {
                    if betterCandidate(candidate, over: existing) {
                        bestByLower[lower] = candidate
                    }
                } else {
                    bestByLower[lower] = candidate
                }
            }
        }

        for entry in entries {
            consider(entry: entry)
        }
        for entry in hotwordEntries {
            consider(entry: entry)
        }
        for entry in lexiconEntries {
            consider(entry: entry)
        }

        let ordered = bestByLower.values
            .sorted(by: rankBetter)
            .prefix(limit)

        var orderedTokens: [String] = []
        orderedTokens.reserveCapacity(ordered.count)
        var casedTokens: [String: String] = [:]
        for item in ordered {
            orderedTokens.append(item.lower)
            if item.hasUppercase {
                casedTokens[item.lower] = item.cased
            }
        }
        return EnglishVocabularySnapshot(
            orderedTokens: orderedTokens,
            casedTokens: casedTokens
        )
    }

    private static func extractEmbeddedEnglishTokens(from text: String) -> [String] {
        var result: [String] = []
        var current = ""

        func flush() {
            if current.isEnglishMixableToken && current.count >= 3 {
                result.append(current)
            }
            current.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            let isLetter = (0x41 ... 0x5A).contains(scalar.value)
                || (0x61 ... 0x7A).contains(scalar.value)
            let isDigit = (0x30 ... 0x39).contains(scalar.value)
            if isLetter || (!current.isEmpty && isDigit) {
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return result
    }
}

extension String {
    /// Lowercase ASCII identifier (first scalar `a-z`, rest `a-z0-9`).
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

    /// ASCII identifier supporting mixed casing (e.g. `RimeAI`, `FastAPI`, `swift`).
    var isEnglishMixableToken: Bool {
        guard let first = unicodeScalars.first,
              ("a" ... "z").contains(first) || ("A" ... "Z").contains(first),
              count <= 32
        else {
            return false
        }
        return unicodeScalars.dropFirst().allSatisfy {
            ("a" ... "z").contains($0)
                || ("A" ... "Z").contains($0)
                || ("0" ... "9").contains($0)
        }
    }
}
