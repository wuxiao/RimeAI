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

/// 已定稿、位于焦点段之外的 composition 切片。标点（与其他字面
/// 符号）自身永远不触发上屏，而是暂存在切片里，直到用户通过
/// Space、数字选词或 Enter 明确确认。
///
/// 拼音段在预编辑区显示定稿中文（`displayText`），Enter 原样上屏
/// 时按 `rawText` 回放原始字母。
public enum CompositionPrefixSegment: Equatable, Sendable {
    /// 一段拼音与它的定稿文本。`committedText` 是定稿时刻用户看
    /// 到的 Rime 首选（无候选时回退为原始字母）。
    case committedPinyin(pinyin: String, committedText: String)
    /// 标点或符号字面量，存储的是已按用户标点风格转换后的文本
    /// （全角中文标点或西文原样）。
    case literal(String)

    /// 预编辑区显示文本：拼音段显示定稿中文，字面量原样。
    var displayText: String {
        switch self {
        case let .committedPinyin(_, text):
            return text
        case let .literal(text):
            return text
        }
    }

    /// 原始击键回放文本（Enter 原样上屏路径）：拼音段回放字母。
    var rawText: String {
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

    var isPinyinSegment: Bool {
        if case .committedPinyin = self {
            return true
        }
        return false
    }
}

/// 跨标点推断布局构建的中间结构（避免大元组）。
private struct LayoutPart {
    let pinyin: String
    let committedText: String
    var separator: String
}

/// 段焦点模型下的 composition 布局：
///
/// `[前缀已定稿段][焦点段拼音][焦点字面量运行][后缀已定稿段]`
///
/// 焦点段携带活跃拼音并拥有候选；其余拼音段显示定稿中文。←/→
/// 在拼音段之间移动焦点，焦点移动会重建 compositionID，使飞行
/// 中的推断 token 全部失效。
public struct CompositionState: Sendable {
    /// 每页固定显示的候选数。分页是纯视图状态：翻页不改变
    /// compositionID/pinyin/mainCandidates，也不递增 revision，
    /// 因此不会使飞行中的语义推理 token 失效。
    public static let candidatesPerPage = 5

    public private(set) var compositionID = UUID()
    public private(set) var revision: UInt64 = 0
    public private(set) var appSessionID: String
    /// 焦点段的活跃拼音。
    public private(set) var pinyin = ""
    /// 焦点段之前的已定稿切片。
    public private(set) var prefixSegments: [CompositionPrefixSegment] = []
    /// 焦点段拼音与其后内容之间的字面量运行（保序）。仅当焦点
    /// 位于非末段时才可能非空；末段之后键入的字面量直接进入前缀。
    public private(set) var focusedSeparatorLiterals: [String] = []
    /// 焦点段之后的已定稿切片。
    public private(set) var suffixSegments: [CompositionPrefixSegment] = []
    public private(set) var mainCandidates: [String] = []
    /// 韵母首字母（i/u/v）开头的输入在 Rime 中无法解析：活跃段按
    /// “原始前导 + 余串候选”合成展示时，这里记录原始前导，供提交
    /// 路径把余串还原给 Rime 完成选词与学习。无前导时为 nil。
    public private(set) var rawLeadPrefix: String?
    public internal(set) var candidatePage = 0
    public private(set) var semanticCandidate: String?
    public private(set) var semanticCandidateDecision: SemanticInferenceDecision?
    /// 语义候选对应的跨标点段布局：由推断管线在应用候选时写入，
    /// 随 `semanticCandidate` 在所有清理点同步清空。
    public private(set) var semanticCandidateSegments: [PinyinSegment]?
    public private(set) var isSelecting = false
    public private(set) var isSecureInput = false

    public init(appSessionID: String) {
        self.appSessionID = appSessionID
    }

    /// 完整的 marked text：非焦点拼音段显示定稿中文，焦点段显示
    /// 活跃拼音，字面量原样。无前缀、无字面量运行且无后缀时与
    /// `pinyin` 逐字节一致，保持单段渲染行为不变。
    public var displayString: String {
        prefixSegments.map(\.displayText).joined()
            + pinyin
            + focusedSeparatorLiterals.joined()
            + suffixSegments.map(\.displayText).joined()
    }

    /// 是否存在任何正在编辑的内容（含焦点字面量运行与后缀）。
    /// 标点进入 composition 后，按键路径必须以此判断代替
    /// `pinyin.isEmpty`。
    public var hasComposition: Bool {
        !prefixSegments.isEmpty
            || !pinyin.isEmpty
            || !focusedSeparatorLiterals.isEmpty
            || !suffixSegments.isEmpty
    }

    /// 跨标点推断的段布局：焦点必须是最后一个拼音段（无后缀、无
    /// 焦点字面量运行）且前缀以 `.committedPinyin` 开头时构造——
    /// 每个拼音段的 separator 是紧随其后的连续字面量拼接，末段
    /// （焦点段）separator 为 ""、不携带定稿文本。焦点在中间时推
    /// 断退回单段协议（跨段一致性由云端整句建议与本地重推负责）。
    public var inferenceSegments: [PinyinSegment]? {
        guard !pinyin.isEmpty,
              focusedSeparatorLiterals.isEmpty,
              suffixSegments.isEmpty,
              case .committedPinyin? = prefixSegments.first
        else {
            return nil
        }
        var collected: [LayoutPart] = []
        for segment in prefixSegments {
            switch segment {
            case let .committedPinyin(segmentPinyin, committedText):
                collected.append(
                    LayoutPart(
                        pinyin: segmentPinyin,
                        committedText: committedText,
                        separator: ""
                    )
                )
            case let .literal(text):
                guard !collected.isEmpty else {
                    return nil
                }
                collected[collected.count - 1].separator += text
            }
        }
        var segments = collected.map {
            PinyinSegment(
                pinyin: $0.pinyin,
                separator: $0.separator,
                committedText: $0.committedText
            )
        }
        segments.append(
            PinyinSegment(pinyin: pinyin, separator: "", committedText: nil)
        )
        guard PinyinSegmentPolicy.isValid(segments, activePinyin: pinyin)
        else {
            return nil
        }
        return segments
    }

    /// 追加字面符号（标点等）。焦点段非空时先定稿为 committedPinyin
    /// 段——定稿文本由调用方传入（字形已按用户偏好转换、基准与
    /// 提交路径一致：当前页第一项候选；无候选（如混输态）回退原始
    /// 字母），未传时保持旧行为（全局首选/原始字母）。语义候选不
    /// 参与定稿，AI 候选仅可经 Tab 显式采用。
    ///
    /// 字面量落点：焦点之后仍有内容时插入焦点字面量运行最前（编
    /// 辑点紧跟拼音，先于既有的段间标点）；否则追加到前缀（既有
    /// 行为）。拼音清空同时重建 compositionID，使飞行中的推断
    /// token 立即失效。
    public mutating func appendLiteral(
        _ text: String,
        finalizedText: String? = nil
    ) {
        guard !text.isEmpty else {
            return
        }
        if !pinyin.isEmpty {
            prefixSegments.append(
                .committedPinyin(pinyin: pinyin, committedText: finalizedText ?? (mainCandidates.first ?? pinyin))
            )
            pinyin = ""
            rawLeadPrefix = nil
            compositionID = UUID()
        }
        if suffixSegments.contains(where: \.isPinyinSegment) {
            focusedSeparatorLiterals.insert(text, at: 0)
        } else {
            prefixSegments.append(.literal(text))
        }
        mainCandidates = []
        candidatePage = 0
        semanticCandidate = nil
        semanticCandidateDecision = nil
        semanticCandidateSegments = nil
        revision &+= 1
    }

    /// 弹出末尾的字面量段（退格在活跃段为空时使用）。优先弹出焦
    /// 点字面量运行中最新（紧贴拼音）的一个，其次弹出前缀末尾字
    /// 面量；两者皆无时返回 nil 且不改变状态。
    @discardableResult
    public mutating func popTrailingLiteral() -> String? {
        if !focusedSeparatorLiterals.isEmpty {
            let focused = focusedSeparatorLiterals.removeFirst()
            revision &+= 1
            return focused
        }
        guard case let .literal(text)? = prefixSegments.last else {
            return nil
        }
        prefixSegments.removeLast()
        revision &+= 1
        return text
    }

    /// ← ：焦点移到前一个拼音段。当前焦点段以 `finalizedText` 定稿
    /// （nil 时取当前首选/原始字母回退）并入后缀；前缀最后一个拼
    /// 音段复活为焦点段，它与既有内容之间的字面量成为焦点字面量
    /// 运行。前缀没有拼音段时返回 false 且不改变状态。焦点段拼音
    /// 为空（如刚退格删空）时不向后缀贡献内容。
    @discardableResult
    public mutating func moveFocusLeft(finalizedText: String? = nil) -> Bool {
        guard let index = prefixSegments.lastIndex(where: \.isPinyinSegment)
        else {
            return false
        }
        guard case let .committedPinyin(segmentPinyin, _) = prefixSegments[index]
        else {
            return false
        }
        var separatorRun: [String] = []
        var runEnd = index + 1
        while runEnd < prefixSegments.count,
              case let .literal(text) = prefixSegments[runEnd]
        {
            separatorRun.append(text)
            runEnd += 1
        }
        let rest = Array(prefixSegments[runEnd...])

        var newSuffix = rest
        if !pinyin.isEmpty {
            newSuffix.append(
                .committedPinyin(
                    pinyin: pinyin,
                    committedText: finalizedText ?? (mainCandidates.first ?? pinyin)
                )
            )
        }
        newSuffix.append(
            contentsOf: focusedSeparatorLiterals.map(CompositionPrefixSegment.literal)
        )
        newSuffix.append(contentsOf: suffixSegments)

        prefixSegments = Array(prefixSegments[..<index])
        suffixSegments = newSuffix
        pinyin = segmentPinyin
        focusedSeparatorLiterals = separatorRun
        afterFocusMoved()
        return true
    }

    /// → ：焦点移到下一个拼音段。当前焦点段以 `finalizedText` 定稿
    /// （nil 时取当前首选/原始字母回退）并入前缀（连同焦点字面量
    /// 运行）；后缀第一个拼音段复活为焦点段，其前的字面量成为焦点
    /// 字面量运行。后缀没有拼音段时返回 false 且不改变状态。
    @discardableResult
    public mutating func moveFocusRight(finalizedText: String? = nil) -> Bool {
        guard suffixSegments.contains(where: \.isPinyinSegment) else {
            return false
        }
        if !pinyin.isEmpty {
            prefixSegments.append(
                .committedPinyin(
                    pinyin: pinyin,
                    committedText: finalizedText ?? (mainCandidates.first ?? pinyin)
                )
            )
        }
        prefixSegments.append(
            contentsOf: focusedSeparatorLiterals.map(CompositionPrefixSegment.literal)
        )

        var leading: [String] = []
        while case let .literal(text)? = suffixSegments.first {
            leading.append(text)
            suffixSegments.removeFirst()
        }
        guard case let .committedPinyin(nextPinyin, _)? = suffixSegments.first
        else {
            return false
        }
        suffixSegments.removeFirst()

        pinyin = nextPinyin
        focusedSeparatorLiterals = leading
        afterFocusMoved()
        return true
    }

    /// 焦点移动后的公共收敛：编辑目标变更，候选、分页、语义候选与
    /// 飞行中 token 全部失效（compositionID 重建）。
    private mutating func afterFocusMoved() {
        mainCandidates = []
        rawLeadPrefix = nil
        candidatePage = 0
        semanticCandidate = nil
        semanticCandidateDecision = nil
        semanticCandidateSegments = nil
        compositionID = UUID()
        revision &+= 1
    }

    /// 提交含前缀的文本后清空焦点之外的全部切片（部分消费场景：
    /// 前缀与后缀已并入正式文本，保留会导致二次插入）。
    public mutating func flushPrefix() {
        guard !prefixSegments.isEmpty
            || !focusedSeparatorLiterals.isEmpty
            || !suffixSegments.isEmpty
        else {
            return
        }
        prefixSegments = []
        focusedSeparatorLiterals = []
        suffixSegments = []
        revision &+= 1
    }

    /// 清除焦点段但保留其余切片（退格把焦点段删空时使用；与
    /// `reset` 的区别是其余内容与显示继续存活）。
    public mutating func clearActivePinyin() {
        guard !pinyin.isEmpty else {
            return
        }
        pinyin = ""
        rawLeadPrefix = nil
        mainCandidates = []
        candidatePage = 0
        semanticCandidate = nil
        semanticCandidateDecision = nil
        semanticCandidateSegments = nil
        compositionID = UUID()
        revision &+= 1
    }


    /// 分段向后重推（KBD-006）：更新后缀拼音段的定稿文本。仅当
    /// token 仍匹配（期间无任何编辑）且目标段是拼音段时应用；
    /// revision 递增使批内后续步骤以最新 token 继续判定，用户编辑
    /// 则使剩余步骤全部失效。
    public mutating func updateSuffixCommittedText(
        atSuffixIndex index: Int,
        committedText: String,
        token: CompositionToken
    ) -> Bool {
        guard token == self.token,
              suffixSegments.indices.contains(index),
              case let .committedPinyin(pinyin, _) = suffixSegments[index],
              !committedText.isEmpty
        else {
            return false
        }
        suffixSegments[index] = .committedPinyin(
            pinyin: pinyin,
            committedText: committedText
        )
        revision &+= 1
        return true
    }

    /// 云端整句按段应用（KBD-007）：把已按段拆分的建议文本写入各
    /// 段定稿（前缀改写、焦点段定稿、后缀改写），不触发提交——
    /// 用户仍可 ←→ 逐段复核后经 Space 上屏。token 匹配、活跃段非
    /// 空、段数与文本一一对应且均非空时应用；焦点段定稿后活跃拼
    /// 音清空并重建 compositionID，焦点字面量运行原位保留。
    public mutating func applySegmentedSuggestion(
        _ texts: [String],
        token: CompositionToken
    ) -> Bool {
        guard token == self.token,
              !isSelecting,
              !isSecureInput,
              !pinyin.isEmpty
        else {
            return false
        }
        let prefixPinyinCount = prefixSegments.filter(\.isPinyinSegment).count
        let suffixPinyinCount = suffixSegments.filter(\.isPinyinSegment).count
        guard texts.count == prefixPinyinCount + 1 + suffixPinyinCount,
              texts.allSatisfy({ !$0.isEmpty })
        else {
            return false
        }
        var next = texts.makeIterator()
        for index in prefixSegments.indices {
            guard case let .committedPinyin(segmentPinyin, _) = prefixSegments[index]
            else {
                continue
            }
            let text = next.next() ?? ""
            prefixSegments[index] = .committedPinyin(
                pinyin: segmentPinyin,
                committedText: text
            )
        }
        // 焦点段定稿入前缀末尾（布局顺序不变），字面量运行原位保留
        let focusedText = next.next() ?? ""
        prefixSegments.append(
            .committedPinyin(pinyin: pinyin, committedText: focusedText)
        )
        pinyin = ""
        rawLeadPrefix = nil
        for index in suffixSegments.indices {
            guard case let .committedPinyin(segmentPinyin, _) = suffixSegments[index]
            else {
                continue
            }
            let text = next.next() ?? ""
            suffixSegments[index] = .committedPinyin(
                pinyin: segmentPinyin,
                committedText: text
            )
        }
        mainCandidates = []
        candidatePage = 0
        semanticCandidate = nil
        semanticCandidateDecision = nil
        semanticCandidateSegments = nil
        compositionID = UUID()
        revision &+= 1
        return true
    }

    @discardableResult
    public mutating func replaceInput(
        pinyin: String,
        candidates: [String],
        rawLeadPrefix: String? = nil
    ) -> CompositionToken {
        if self.pinyin.isEmpty {
            compositionID = UUID()
        }
        revision &+= 1
        self.pinyin = pinyin
        mainCandidates = candidates
        self.rawLeadPrefix = rawLeadPrefix
        candidatePage = 0
        semanticCandidate = nil
        semanticCandidateDecision = nil
        semanticCandidateSegments = nil
        isSelecting = false
        isSecureInput = false
        return token
    }


    @discardableResult
    public mutating func applySemanticCandidate(
        _ candidate: String,
        token: CompositionToken,
        decision: SemanticInferenceDecision = .rankedCandidate,
        segments: [PinyinSegment]? = nil
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
        semanticCandidateSegments = segments
        return true
    }

    public mutating func beginSelection() {
        revision &+= 1
        isSelecting = true
        semanticCandidate = nil
        semanticCandidateDecision = nil
        semanticCandidateSegments = nil
    }

    public mutating func reset() {
        revision &+= 1
        compositionID = UUID()
        pinyin = ""
        prefixSegments = []
        focusedSeparatorLiterals = []
        suffixSegments = []
        mainCandidates = []
        rawLeadPrefix = nil
        candidatePage = 0
        semanticCandidate = nil
        semanticCandidateDecision = nil
        semanticCandidateSegments = nil
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

    /// 当前 composition 的飞行中 token：推断结果应用时用于核对
    /// compositionID、revision 与会话。
    public var token: CompositionToken {
        CompositionToken(
            compositionID: compositionID,
            revision: revision,
            appSessionID: appSessionID
        )
    }
}
