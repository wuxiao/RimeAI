import Foundation

public struct CompositionToken: Equatable, Sendable {
    public let compositionID: UUID
    public let revision: UInt64
    public let appSessionID: String

    public init(
        compositionID: UUID,
        revision: UInt64,
        appSessionID: String
    ) {
        self.compositionID = compositionID
        self.revision = revision
        self.appSessionID = appSessionID
    }
}

/// 已定稿、位于活跃拼音段之前的 composition 切片。标点（与其他
/// 字面符号）自身永远不触发上屏，而是暂存在这里，直到用户通过
/// Space、数字选词或 Enter 明确确认。
public enum CompositionPrefixSegment: Equatable, Sendable {
    /// 一段拼音与紧随其后的字面符号。`committedText` 是定稿时刻
    /// 用户看到的 Rime 首选（无候选时回退为原始字母）。
    case committedPinyin(pinyin: String, committedText: String)
    /// 标点或符号字面量，存储的是已按用户标点风格转换后的文本
    /// （全角中文标点或西文原样）。
    case literal(String)

    var displayText: String {
        switch self {
        case let .committedPinyin(pinyin, _):
            return pinyin
        case let .literal(text):
            return text
        }
    }

    var committedText: String {
        switch self {
        case let .committedPinyin(_, text):
            return text
        case let .literal(text):
            return text
        }
    }
}

public struct CompositionState: Sendable {
    /// 每页固定显示的候选数。分页是纯视图状态：翻页不改变
    /// compositionID/pinyin/mainCandidates，也不递增 revision，
    /// 因此不会使飞行中的语义推理 token 失效。
    public static let candidatesPerPage = 5

    public private(set) var compositionID = UUID()
    public private(set) var revision: UInt64 = 0
    public private(set) var appSessionID: String
    public private(set) var pinyin = ""
    public private(set) var prefixSegments: [CompositionPrefixSegment] = []
    public private(set) var mainCandidates: [String] = []
    public private(set) var candidatePage = 0
    public private(set) var semanticCandidate: String?
    public private(set) var semanticCandidateDecision: SemanticInferenceDecision?
    public private(set) var isSelecting = false
    public private(set) var isSecureInput = false

    public init(appSessionID: String) {
        self.appSessionID = appSessionID
    }

    /// 完整的 marked text：定稿前缀按原样渲染（拼音段保持字母），
    /// 加上活跃拼音段。无前缀时与 `pinyin` 逐字节一致，保持分段
    /// 改造之前的渲染行为。
    public var displayString: String {
        prefixSegments.map(\.displayText).joined() + pinyin
    }

    /// 是否存在任何正在编辑的内容（含定稿前缀）。标点进入
    /// composition 后，按键路径必须以此判断代替 `pinyin.isEmpty`。
    public var hasComposition: Bool {
        !prefixSegments.isEmpty || !pinyin.isEmpty
    }

    /// 前缀在上屏时贡献的文本：各拼音段的定稿文本与字面量原样拼接。
    public var committedPrefixText: String {
        prefixSegments.map(\.committedText).joined()
    }

    /// 前缀按原始击键回放（字母 + 字面量），供 Enter 原样上屏使用。
    public var rawPrefixString: String {
        prefixSegments.map(\.displayText).joined()
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

    /// 历史库的 pinyin 字段：全部字母段拼接、不含标点，保持该列
    /// 可作为 Rime 输入重现的契约。HistoryStore 拒绝超过 256 字节
    /// 的条目，超限时保留尾部（最近的输入段）。
    public var historyPinyin: String {
        let joined = prefixHistoryPinyin + pinyin
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

    /// 追加字面符号（标点等）。活跃段非空时先定稿为 committedPinyin
    /// 段——定稿文本取当前 Rime 首选，无候选（如混输态）回退原始
    /// 字母；语义候选不参与定稿，AI 候选仅可经 Tab 显式采用。
    /// 拼音清空同时重建 compositionID，使飞行中的推断 token 立即失效。
    public mutating func appendLiteral(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        if !pinyin.isEmpty {
            let finalized = mainCandidates.first ?? pinyin
            prefixSegments.append(
                .committedPinyin(pinyin: pinyin, committedText: finalized)
            )
            pinyin = ""
            compositionID = UUID()
        }
        prefixSegments.append(.literal(text))
        mainCandidates = []
        candidatePage = 0
        semanticCandidate = nil
        semanticCandidateDecision = nil
        revision &+= 1
    }

    /// 弹出末尾的字面量段（退格在活跃段为空、末段为标点时使用）。
    /// 末段不是字面量时返回 nil 且不改变状态。
    @discardableResult
    public mutating func popTrailingLiteral() -> String? {
        guard case let .literal(text)? = prefixSegments.last else {
            return nil
        }
        prefixSegments.removeLast()
        revision &+= 1
        return text
    }

    /// 提交含前缀的文本后清空前缀（部分消费场景：前缀已并入正式
    /// 文本，保留会导致二次插入）。
    public mutating func flushPrefix() {
        guard !prefixSegments.isEmpty else {
            return
        }
        prefixSegments = []
        revision &+= 1
    }

    /// 清除活跃段但保留定稿前缀（退格把活跃段删空、或活跃段查询
    /// 失败时使用；与 `reset` 的区别是前缀与显示继续存活）。
    public mutating func clearActivePinyin() {
        guard !pinyin.isEmpty else {
            return
        }
        pinyin = ""
        mainCandidates = []
        candidatePage = 0
        semanticCandidate = nil
        semanticCandidateDecision = nil
        compositionID = UUID()
        revision &+= 1
    }


    @discardableResult
    public mutating func replaceInput(
        pinyin: String,
        candidates: [String]
    ) -> CompositionToken {
        if self.pinyin.isEmpty {
            compositionID = UUID()
        }
        revision &+= 1
        self.pinyin = pinyin
        mainCandidates = candidates
        candidatePage = 0
        semanticCandidate = nil
        semanticCandidateDecision = nil
        isSelecting = false
        isSecureInput = false
        return token
    }

    /// 弹出最后一个前缀段并把它作为活跃拼音段复活（退格路径）。
    /// 与 `popSegment` 的区别：拼音段复活后前缀仍保留其前序段，
    /// 状态回到该段定稿前的编辑形态。
    @discardableResult
    public mutating func reviveLastPinyinSegment() -> String? {
        guard case let .committedPinyin(pinyin, _)? = prefixSegments.last
        else {
            return nil
        }
        prefixSegments.removeLast()
        self.pinyin = pinyin
        mainCandidates = []
        candidatePage = 0
        semanticCandidate = nil
        semanticCandidateDecision = nil
        compositionID = UUID()
        revision &+= 1
        return pinyin
    }


    @discardableResult
    public mutating func applySemanticCandidate(
        _ candidate: String,
        token: CompositionToken,
        decision: SemanticInferenceDecision = .rankedCandidate
    ) -> Bool {
        guard !candidate.isEmpty,
              !isSelecting,
              !isSecureInput,
              token == self.token
        else {
            return false
        }
        semanticCandidate = candidate
        semanticCandidateDecision = decision
        return true
    }

    public mutating func beginSelection() {
        revision &+= 1
        isSelecting = true
        semanticCandidate = nil
        semanticCandidateDecision = nil
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

    public mutating func reset() {
        revision &+= 1
        compositionID = UUID()
        pinyin = ""
        prefixSegments = []
        mainCandidates = []
        candidatePage = 0
        semanticCandidate = nil
        semanticCandidateDecision = nil
        isSelecting = false
    }

    public mutating func enterSecureInput() {
        reset()
        isSecureInput = true
    }

    public mutating func switchApplicationSession(to identifier: String) {
        reset()
        appSessionID = identifier
        isSecureInput = false
    }

    public var token: CompositionToken {
        CompositionToken(
            compositionID: compositionID,
            revision: revision,
            appSessionID: appSessionID
        )
    }
}
