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
}

extension String {
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
