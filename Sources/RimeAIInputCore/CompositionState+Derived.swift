import Foundation

/// `CompositionState` 的派生只读视图：显示/回放文本、历史拼音、
/// 分页视图与语义候选提交文本。只读访问器集中在此文件，主文件
/// 保留状态机与变更路径。
extension CompositionState {
    /// ← 是否有可聚焦的前缀拼音段。
    public var canMoveFocusLeft: Bool {
        prefixSegments.contains(where: \.isPinyinSegment)
    }

    /// → 是否有可聚焦的后缀拼音段。
    public var canMoveFocusRight: Bool {
        suffixSegments.contains(where: \.isPinyinSegment)
    }

    /// 前缀在上屏时贡献的文本：各拼音段的定稿文本与字面量原样拼接。
    public var committedPrefixText: String {
        prefixSegments.map(\.committedText).joined()
    }

    /// 后缀在上屏时贡献的文本：各拼音段的定稿文本与字面量原样拼接。
    public var committedSuffixText: String {
        suffixSegments.map(\.committedText).joined()
    }

    /// 焦点段之外的全部定稿文本（前缀 + 焦点字面量运行 + 后缀），
    /// 按显示顺序拼接。
    public var committedOuterText: String {
        committedPrefixText
            + focusedSeparatorLiterals.joined()
            + committedSuffixText
    }

    /// 前缀按原始击键回放（字母 + 字面量），供 Enter 原样上屏使用。
    public var rawPrefixString: String {
        prefixSegments.map(\.rawText).joined()
    }

    /// 后缀按原始击键回放（字母 + 字面量），供 Enter 原样上屏使用。
    public var rawSuffixString: String {
        suffixSegments.map(\.rawText).joined()
    }

    /// 全部内容按原始击键回放（前缀 + 活跃拼音 + 字面量运行 + 后缀）。
    public var rawCompositionString: String {
        rawPrefixString
            + pinyin
            + focusedSeparatorLiterals.joined()
            + rawSuffixString
    }

    /// 仅前缀中的字母段拼接（不含标点），供部分消费提交路径与
    /// 活跃段拼音另行拼接。
    public var prefixHistoryPinyin: String {
        prefixSegments.compactMap { segment in
            if case let .committedPinyin(pinyin, _) = segment {
                return pinyin
            }
            return nil
        }.joined()
    }

    /// 仅后缀中的字母段拼接（不含标点）。
    public var suffixHistoryPinyin: String {
        suffixSegments.compactMap { segment in
            if case let .committedPinyin(pinyin, _) = segment {
                return pinyin
            }
            return nil
        }.joined()
    }

    /// 历史库的 pinyin 字段：全部字母段拼接（前缀 + 焦点段 + 后缀）、
    /// 不含标点，保持该列可作为 Rime 输入重现的契约。HistoryStore
    /// 拒绝超过 256 字节的条目，超限时保留尾部（最近的输入段）。
    public var historyPinyin: String {
        let joined = prefixHistoryPinyin + pinyin + suffixHistoryPinyin
        return Self.truncatedToUTF8Limit(joined, limit: 256)
    }

    private static func truncatedToUTF8Limit(
        _ string: String,
        limit: Int
    ) -> String {
        guard string.utf8.count > limit else {
            return string
        }
        var kept: [UnicodeScalar] = []
        var used = 0
        for scalar in string.unicodeScalars.reversed() {
            let width = UTF8.width(scalar)
            if used + width > limit {
                continue
            }
            kept.append(scalar)
            used += width
        }
        return String(String.UnicodeScalarView(kept.reversed()))
    }

    /// 语义候选是否已整句覆盖定稿前缀：候选携带跨标点段布局，且
    /// 布局与候选文本的结构校验（分隔符按序出现、各段非空、整体
    /// 不超上限）通过即视为覆盖。校验与准入用同一个
    /// `CloudGeneratedSentencePolicy`（confidence 传 1，只关心结
    /// 构），提交判定因此与准入判定同口径。
    var semanticCandidateCoversPrefix: Bool {
        guard let text = semanticCandidate,
              let segments = semanticCandidateSegments
        else {
            return false
        }
        return CloudGeneratedSentencePolicy.allows(
            text: text,
            pinyinSegments: segments,
            confidence: 1
        )
    }

    /// 语义候选提交时上屏的完整文本：候选携带跨标点段布局且布局
    /// 与候选文本匹配（`semanticCandidateCoversPrefix`）时，整句已
    /// 覆盖焦点之外的全部内容，直接返回候选本身，前置定稿文本会
    /// 造成重复上屏；无布局或布局不匹配时前置全部定稿文本（前缀 +
    /// 字面量运行 + 后缀）。段布局随 `beginSelection()` 清空，须在
    /// 此之前调用。
    public func semanticCandidateCommitText(for candidate: String) -> String {
        if candidate == semanticCandidate, semanticCandidateCoversPrefix {
            return candidate
        }
        return committedOuterText + candidate
    }

    /// 候选总页数；无候选时为 0，其余向上取整。
    public var candidatePageCount: Int {
        guard !mainCandidates.isEmpty else {
            return 0
        }
        return (mainCandidates.count + Self.candidatesPerPage - 1)
            / Self.candidatesPerPage
    }

    /// 当前页可见的候选切片。
    public var visibleMainCandidates: [String] {
        let start = candidatePage * Self.candidatesPerPage
        guard start < mainCandidates.count else {
            return []
        }
        let end = min(start + Self.candidatesPerPage, mainCandidates.count)
        return Array(mainCandidates[start ..< end])
    }

    /// 数字键的页内槽位（1-based）映射到全局候选索引；越界返回 nil。
    public func globalCandidateIndex(forPageSlot slot: Int) -> Int? {
        guard (1 ... Self.candidatesPerPage).contains(slot) else {
            return nil
        }
        let index = candidatePage * Self.candidatesPerPage + slot - 1
        return index < mainCandidates.count ? index : nil
    }

    /// 候选向后翻一页；已在最后一页时返回 false 且不改变状态。
    @discardableResult
    public mutating func advanceCandidatePage() -> Bool {
        guard candidatePage + 1 < candidatePageCount else {
            return false
        }
        candidatePage += 1
        return true
    }

    /// 候选向前翻一页；已在第一页时返回 false 且不改变状态。
    @discardableResult
    public mutating func retreatCandidatePage() -> Bool {
        guard candidatePage > 0 else {
            return false
        }
        candidatePage -= 1
        return true
    }
}
