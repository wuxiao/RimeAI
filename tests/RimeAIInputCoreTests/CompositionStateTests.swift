import Foundation
import Testing
@testable import RimeAIInputCore

@Test
func rawLeadPrefixFollowsActivePinyinLifecycle() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(
        pinyin: "inihao",
        candidates: ["i你好", "i妳好"],
        rawLeadPrefix: "i"
    )
    #expect(state.rawLeadPrefix == "i")

    // 常规输入重写后不再携带前导。
    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    #expect(state.rawLeadPrefix == nil)

    // 退格清空活跃段与整体重置同样清除前导。
    _ = state.replaceInput(
        pinyin: "inihao",
        candidates: ["i你好"],
        rawLeadPrefix: "i"
    )
    state.clearActivePinyin()
    #expect(state.rawLeadPrefix == nil)

    _ = state.replaceInput(
        pinyin: "inihao",
        candidates: ["i你好"],
        rawLeadPrefix: "i"
    )
    state.reset()
    #expect(state.rawLeadPrefix == nil)
}

@Test
func mainCandidatesNeverMoveWhenSemanticResultArrives() {
    var state = CompositionState(appSessionID: "app-1")
    let token = state.replaceInput(
        pinyin: "shijian",
        candidates: ["时间", "事件", "实践"]
    )

    let accepted = state.applySemanticCandidate(
        "事件",
        token: token,
        decision: .sentenceSuggestion
    )

    #expect(accepted)
    #expect(state.mainCandidates == ["时间", "事件", "实践"])
    #expect(state.semanticCandidate == "事件")
    #expect(state.semanticCandidateDecision == .sentenceSuggestion)
}

@Test
func staleSemanticResultCannotRefreshANewerComposition() {
    var state = CompositionState(appSessionID: "app-1")
    let oldToken = state.replaceInput(
        pinyin: "shi",
        candidates: ["是", "时"]
    )
    _ = state.replaceInput(
        pinyin: "shijian",
        candidates: ["时间", "事件"]
    )

    let accepted = state.applySemanticCandidate(
        "是",
        token: oldToken
    )

    #expect(!accepted)
    #expect(state.semanticCandidate == nil)
}

@Test
func selectionAndSecureInputInvalidatePendingResults() {
    var state = CompositionState(appSessionID: "app-1")
    let selectingToken = state.replaceInput(
        pinyin: "shijian",
        candidates: ["时间", "事件"]
    )
    state.beginSelection()
    let acceptedWhileSelecting = state.applySemanticCandidate(
        "事件",
        token: selectingToken
    )
    #expect(!acceptedWhileSelecting)

    let secureToken = state.replaceInput(
        pinyin: "mima",
        candidates: ["密码"]
    )
    state.enterSecureInput()
    let acceptedInSecureInput = state.applySemanticCandidate(
        "密码",
        token: secureToken
    )
    #expect(!acceptedInSecureInput)
    #expect(state.pinyin.isEmpty)
    #expect(state.mainCandidates.isEmpty)
}

@Test
func resultsAreIsolatedByApplicationSession() {
    var state = CompositionState(appSessionID: "app-1")
    let token = state.replaceInput(
        pinyin: "shijian",
        candidates: ["时间", "事件"]
    )
    state.switchApplicationSession(to: "app-2")

    let acceptedAcrossApplications = state.applySemanticCandidate(
        "事件",
        token: token
    )
    #expect(!acceptedAcrossApplications)
    #expect(state.appSessionID == "app-2")
    #expect(state.pinyin.isEmpty)
}

@Test
func candidatePagingAdvancesAndRetreatsWithinBounds() {
    var state = CompositionState(appSessionID: "app-1")
    let candidates = (1 ... 12).map { "候选\($0)" }
    _ = state.replaceInput(pinyin: "ceshi", candidates: candidates)
    #expect(state.candidatePageCount == 3)

    let firstAdvance = state.advanceCandidatePage()
    #expect(firstAdvance)
    #expect(state.visibleMainCandidates.count == 5)
    let secondAdvance = state.advanceCandidatePage()
    #expect(secondAdvance)
    #expect(state.visibleMainCandidates == ["候选11", "候选12"])
    let advancePastLastPage = state.advanceCandidatePage()
    #expect(!advancePastLastPage)
    #expect(state.candidatePage == 2)

    let firstRetreat = state.retreatCandidatePage()
    #expect(firstRetreat)
    #expect(state.candidatePage == 1)
    let secondRetreat = state.retreatCandidatePage()
    #expect(secondRetreat)
    #expect(state.candidatePage == 0)
    let retreatBeforeFirstPage = state.retreatCandidatePage()
    #expect(!retreatBeforeFirstPage)
    #expect(state.visibleMainCandidates.count == 5)

    var singlePageState = CompositionState(appSessionID: "app-1")
    _ = singlePageState.replaceInput(
        pinyin: "shi",
        candidates: ["是", "时", "十"]
    )
    #expect(singlePageState.candidatePageCount == 1)
    let singlePageAdvance = singlePageState.advanceCandidatePage()
    let singlePageRetreat = singlePageState.retreatCandidatePage()
    #expect(!singlePageAdvance)
    #expect(!singlePageRetreat)
}

@Test
func replaceInputResetsCandidatePage() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(
        pinyin: "ceshi",
        candidates: (1 ... 12).map { "候选\($0)" }
    )
    let advanced = state.advanceCandidatePage()
    #expect(advanced)
    #expect(state.candidatePage == 1)

    _ = state.replaceInput(pinyin: "cesh", candidates: ["测"])
    #expect(state.candidatePage == 0)
}

@Test
func resetClearsCandidatePage() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(
        pinyin: "ceshi",
        candidates: (1 ... 12).map { "候选\($0)" }
    )
    let advanced = state.advanceCandidatePage()
    #expect(advanced)

    state.reset()
    #expect(state.candidatePage == 0)
    #expect(state.candidatePageCount == 0)
    #expect(state.visibleMainCandidates.isEmpty)
}

@Test
func pageFlipDoesNotInvalidateInFlightSemanticToken() {
    var state = CompositionState(appSessionID: "app-1")
    let token = state.replaceInput(
        pinyin: "shijian",
        candidates: (1 ... 12).map { "候选\($0)" }
    )
    let revisionBeforePaging = state.revision

    let advanced = state.advanceCandidatePage()
    #expect(advanced)

    #expect(state.revision == revisionBeforePaging)
    let accepted = state.applySemanticCandidate(
        "候选2",
        token: token,
        decision: .rankedCandidate
    )
    #expect(accepted)
    #expect(state.semanticCandidate == "候选2")
}

@Test
func pageSlotMapsToGlobalIndexAcrossPages() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(
        pinyin: "ceshi",
        candidates: (1 ... 12).map { "候选\($0)" }
    )

    #expect(state.globalCandidateIndex(forPageSlot: 1) == 0)
    #expect(state.globalCandidateIndex(forPageSlot: 5) == 4)
    #expect(state.globalCandidateIndex(forPageSlot: 6) == nil)
    #expect(state.globalCandidateIndex(forPageSlot: 10) == nil)

    let firstAdvance = state.advanceCandidatePage()
    #expect(firstAdvance)
    #expect(state.globalCandidateIndex(forPageSlot: 1) == 5)
    #expect(state.globalCandidateIndex(forPageSlot: 2) == 6)
    #expect(state.globalCandidateIndex(forPageSlot: 5) == 9)
    #expect(state.globalCandidateIndex(forPageSlot: 6) == nil)

    let secondAdvance = state.advanceCandidatePage()
    #expect(secondAdvance)
    #expect(state.globalCandidateIndex(forPageSlot: 2) == 11)
    #expect(state.globalCandidateIndex(forPageSlot: 3) == nil)
}

@Test
func emptyCompositionHasNoVisiblePage() {
    let state = CompositionState(appSessionID: "app-1")
    #expect(state.candidatePageCount == 0)
    #expect(state.visibleMainCandidates.isEmpty)
    #expect(state.globalCandidateIndex(forPageSlot: 1) == nil)
}

// MARK: - Prefix segments (punctuation never commits)

@Test
func appendLiteralFinalizesActiveSegmentWithTopCandidate() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(
        pinyin: "nihao",
        candidates: ["你好", "泥豪"]
    )

    state.appendLiteral("，")

    #expect(state.pinyin.isEmpty)
    #expect(state.prefixSegments == [
        .committedPinyin(pinyin: "nihao", committedText: "你好"),
        .literal("，"),
    ])
    #expect(state.mainCandidates.isEmpty)
    #expect(state.displayString == "nihao，")
    #expect(state.committedPrefixText == "你好，")
    #expect(state.rawPrefixString == "nihao，")
    #expect(state.hasComposition)
}

@Test
func appendLiteralFallsBackToRawLettersWithoutCandidates() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "fjfww", candidates: [])

    state.appendLiteral("，")

    #expect(state.prefixSegments == [
        .committedPinyin(pinyin: "fjfww", committedText: "fjfww"),
        .literal("，"),
    ])
    #expect(state.committedPrefixText == "fjfww，")
}

@Test
func appendLiteralInvalidatesInFlightInferenceToken() {
    var state = CompositionState(appSessionID: "app-1")
    let token = state.replaceInput(
        pinyin: "shijie",
        candidates: ["世界"]
    )

    state.appendLiteral("，")

    let accepted = state.applySemanticCandidate(
        "世界",
        token: token,
        decision: .rankedCandidate
    )
    #expect(!accepted)
    #expect(state.semanticCandidate == nil)
}

@Test
func appendLiteralOnPrefixOnlyAppendsConsecutivePunctuation() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "hao", candidates: ["好"])
    state.appendLiteral("，")

    state.appendLiteral("。")

    #expect(state.prefixSegments == [
        .committedPinyin(pinyin: "hao", committedText: "好"),
        .literal("，"),
        .literal("。"),
    ])
    #expect(state.displayString == "hao，。")
}

@Test
func lettersAfterPunctuationStartNewActiveSegment() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    state.appendLiteral("，")

    _ = state.replaceInput(pinyin: "shijie", candidates: ["世界"])

    #expect(state.displayString == "nihao，shijie")
    #expect(state.committedPrefixText == "你好，")
    #expect(state.historyPinyin == "nihaoshijie")
    #expect(state.mainCandidates == ["世界"])
}

@Test
func popTrailingLiteralOnlyRemovesLiterals() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "hao", candidates: ["好"])
    state.appendLiteral("，")

    let popped = state.popTrailingLiteral()

    #expect(popped == "，")
    #expect(state.prefixSegments == [
        .committedPinyin(pinyin: "hao", committedText: "好")
    ])

    let notPopped = state.popTrailingLiteral()
    #expect(notPopped == nil)
    #expect(state.prefixSegments == [
        .committedPinyin(pinyin: "hao", committedText: "好")
    ])
}

@Test
func reviveLastPinyinSegmentRestoresEditableActiveSegment() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    state.appendLiteral("，")
    _ = state.replaceInput(pinyin: "shijie", candidates: ["世界"])
    state.appendLiteral("。")

    // 末段是标点时退格先弹出标点，拼音段不可复活
    #expect(state.reviveLastPinyinSegment() == nil)

    let popped = state.popTrailingLiteral()
    #expect(popped == "。")
    let revived = state.reviveLastPinyinSegment()

    #expect(revived == "shijie")
    #expect(state.pinyin == "shijie")
    #expect(state.prefixSegments == [
        .committedPinyin(pinyin: "nihao", committedText: "你好"),
        .literal("，"),
    ])
    #expect(state.displayString == "nihao，shijie")
    // 复活后的旧 token 不得复活语义结果
    let staleAccepted = state.applySemanticCandidate(
        "世界",
        token: CompositionToken(
            compositionID: UUID(),
            revision: 0,
            appSessionID: "app-1"
        )
    )
    #expect(!staleAccepted)
}

@Test
func clearActivePinyinKeepsPrefixAlive() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    state.appendLiteral("，")
    _ = state.replaceInput(pinyin: "shi", candidates: ["是"])

    state.clearActivePinyin()

    #expect(state.pinyin.isEmpty)
    #expect(state.prefixSegments == [
        .committedPinyin(pinyin: "nihao", committedText: "你好"),
        .literal("，"),
    ])
    #expect(state.displayString == "nihao，")
    #expect(state.hasComposition)
}

@Test
func flushPrefixClearsSegmentsForPartialCommit() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    state.appendLiteral("，")
    _ = state.replaceInput(pinyin: "shijie", candidates: ["世界"])

    state.flushPrefix()

    #expect(state.prefixSegments.isEmpty)
    #expect(state.pinyin == "shijie")
    #expect(state.displayString == "shijie")
    #expect(state.committedPrefixText.isEmpty)
    #expect(state.prefixHistoryPinyin.isEmpty)
}

@Test
func resetAndSecureInputClearPrefixSegments() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    state.appendLiteral("，")
    state.reset()

    #expect(state.prefixSegments.isEmpty)
    #expect(!state.hasComposition)

    _ = state.replaceInput(pinyin: "mima", candidates: ["密码"])
    state.appendLiteral("。")
    state.enterSecureInput()

    #expect(state.prefixSegments.isEmpty)
    #expect(state.isSecureInput)
}

@Test
func emptyPrefixPreservesLegacyRenderingByteForByte() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "ceshi", candidates: ["测试"])

    #expect(state.displayString == "ceshi")
    #expect(state.hasComposition)
    #expect(state.committedPrefixText.isEmpty)
    #expect(state.rawPrefixString.isEmpty)
    #expect(state.historyPinyin == "ceshi")

    state.reset()
    #expect(!state.hasComposition)
    #expect(state.displayString.isEmpty)
}

@Test
func historyPinyinExcludesPunctuationAndTruncatesToTail() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "aaaaaaaaaa", candidates: ["甲"])
    state.appendLiteral("，")
    _ = state.replaceInput(pinyin: "bbbbbbbbbb", candidates: ["乙"])
    state.appendLiteral("。")
    _ = state.replaceInput(pinyin: "cccccccccc", candidates: ["丙"])

    #expect(state.historyPinyin == "aaaaaaaaaabbbbbbbbbbcccccccccc")

    var long = CompositionState(appSessionID: "app-1")
    _ = long.replaceInput(
        pinyin: String(repeating: "a", count: 200),
        candidates: ["甲"]
    )
    long.appendLiteral("，")
    _ = long.replaceInput(
        pinyin: String(repeating: "b", count: 200),
        candidates: ["乙"]
    )

    // 超 256 字节时保留尾部（最近段）：56 个 a + 200 个 b
    let truncated = long.historyPinyin
    #expect(truncated.utf8.count == 256)
    #expect(truncated.hasSuffix(String(repeating: "b", count: 200)))
    #expect(truncated.hasPrefix(String(repeating: "a", count: 56)))
}

// MARK: - Cross-punctuation inference segments

@Test
func test_inferenceSegmentsBuiltFromCommittedPrefix() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    state.appendLiteral("，")
    // 连续字面量拼接为同一段的 separator。
    state.appendLiteral("。")
    _ = state.replaceInput(pinyin: "shijie", candidates: ["世界"])
    state.appendLiteral("！")
    _ = state.replaceInput(pinyin: "zhenhao", candidates: ["真好"])

    #expect(state.inferenceSegments == [
        PinyinSegment(
            pinyin: "nihao",
            separator: "，。",
            committedText: "你好"
        ),
        PinyinSegment(
            pinyin: "shijie",
            separator: "！",
            committedText: "世界"
        ),
        PinyinSegment(pinyin: "zhenhao", separator: "", committedText: nil),
    ])

    // 前导字面量（未拼过拼音就敲标点）：不构造段布局。
    var leadingLiteral = CompositionState(appSessionID: "app-1")
    leadingLiteral.appendLiteral("，")
    _ = leadingLiteral.replaceInput(pinyin: "nihao", candidates: ["你好"])
    #expect(leadingLiteral.inferenceSegments == nil)

    // 无前缀段：旧行为。
    var noPrefix = CompositionState(appSessionID: "app-1")
    _ = noPrefix.replaceInput(pinyin: "nihao", candidates: ["你好"])
    #expect(noPrefix.inferenceSegments == nil)

    // 活跃段为空：不构造段布局。
    var emptyActive = CompositionState(appSessionID: "app-1")
    _ = emptyActive.replaceInput(pinyin: "nihao", candidates: ["你好"])
    emptyActive.appendLiteral("，")
    #expect(emptyActive.inferenceSegments == nil)
}

@Test
func test_inferenceSegmentsDegradeToNilBeyondPolicyBounds() {
    var state = CompositionState(appSessionID: "app-1")
    for index in 0 ..< 8 {
        _ = state.replaceInput(
            pinyin: "ha\(index)",
            candidates: ["好\(index)"]
        )
        state.appendLiteral("，")
    }
    _ = state.replaceInput(pinyin: "zuihou", candidates: ["最后"])

    // 9 段超过 PinyinSegmentPolicy.maximumSegments：退回 nil（单段协议）。
    #expect(state.inferenceSegments == nil)
}

@Test
func test_reviveLastPinyinSegmentClearsSemanticCandidateSegments() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    state.appendLiteral("，")
    _ = state.replaceInput(pinyin: "shijie", candidates: ["世界"])
    state.appendLiteral("。")
    _ = state.replaceInput(pinyin: "zhenhao", candidates: ["真好"])
    let segments = state.inferenceSegments

    let accepted = state.applySemanticCandidate(
        "你好，世界！真好",
        token: state.token,
        decision: .sentenceSuggestion,
        segments: segments
    )
    #expect(accepted)
    #expect(state.semanticCandidateSegments == segments)

    _ = state.popTrailingLiteral()
    _ = state.reviveLastPinyinSegment()

    #expect(state.semanticCandidate == nil)
    #expect(state.semanticCandidateSegments == nil)
}

@Test
func test_applySemanticCandidateStoresSegments() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    state.appendLiteral("，")
    _ = state.replaceInput(pinyin: "shijie", candidates: ["世界"])
    let token = state.token
    let segments = state.inferenceSegments

    // 显式携带 segments 时记录。
    let accepted = state.applySemanticCandidate(
        "你好，世界",
        token: token,
        decision: .sentenceSuggestion,
        segments: segments
    )
    #expect(accepted)
    #expect(state.semanticCandidateSegments == segments)

    // 默认参数：不传 segments 时改写为 nil。
    let acceptedWithoutSegments = state.applySemanticCandidate(
        "世界",
        token: token
    )
    #expect(acceptedWithoutSegments)
    #expect(state.semanticCandidateSegments == nil)

    // 过期 token：既不落候选也不落 segments。
    let acceptedWithStaleToken = state.applySemanticCandidate(
        "你好，世界",
        token: CompositionToken(
            compositionID: UUID(),
            revision: 0,
            appSessionID: "app-1"
        ),
        segments: segments
    )
    #expect(!acceptedWithStaleToken)
    #expect(state.semanticCandidateSegments == nil)

    // 所有清理点与 semanticCandidate 同步清空 segments。
    let acceptedBeforeLiteral = state.applySemanticCandidate(
        "你好，世界",
        token: token,
        segments: segments
    )
    #expect(acceptedBeforeLiteral)
    state.appendLiteral("，")
    #expect(state.semanticCandidateSegments == nil)

    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    let acceptedBeforeClearingActive = state.applySemanticCandidate(
        "你好，世界",
        token: state.token,
        segments: segments
    )
    #expect(acceptedBeforeClearingActive)
    state.clearActivePinyin()
    #expect(state.semanticCandidateSegments == nil)

    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    let acceptedBeforeSelection = state.applySemanticCandidate(
        "你好，世界",
        token: state.token,
        segments: segments
    )
    #expect(acceptedBeforeSelection)
    state.beginSelection()
    #expect(state.semanticCandidateSegments == nil)

    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    let acceptedBeforeReset = state.applySemanticCandidate(
        "你好，世界",
        token: state.token,
        segments: segments
    )
    #expect(acceptedBeforeReset)
    state.reset()
    #expect(state.semanticCandidateSegments == nil)
}

@Test
func test_wholeCompositionSentenceCommitDoesNotPrependPrefix() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    state.appendLiteral("，")
    _ = state.replaceInput(pinyin: "shijie", candidates: ["世界"])
    let accepted = state.applySemanticCandidate(
        "你好，世界",
        token: state.token,
        decision: .sentenceSuggestion,
        segments: state.inferenceSegments
    )
    #expect(accepted)

    // 布局匹配的整句候选已覆盖定稿前缀的全部内容：
    // 提交文本不得再前置 committedPrefixText（“你好，”）。
    #expect(state.committedPrefixText == "你好，")
    #expect(state.semanticCandidateCommitText(for: "你好，世界") == "你好，世界")
}

@Test
func test_plainSentenceCommitStillPrependsPrefix() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    state.appendLiteral("，")
    _ = state.replaceInput(pinyin: "shijie", candidates: ["世界"])
    let accepted = state.applySemanticCandidate(
        "世界",
        token: state.token,
        decision: .rankedCandidate
    )
    #expect(accepted)

    // 无段布局（单段协议/旧路径）：提交仍前置定稿前缀。
    #expect(state.semanticCandidateSegments == nil)
    #expect(state.semanticCandidateCommitText(for: "世界") == "你好，世界")
}

@Test
func test_mismatchedSentenceLayoutCommitStillPrependsPrefix() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    state.appendLiteral("，")
    _ = state.replaceInput(pinyin: "shijie", candidates: ["世界"])
    let accepted = state.applySemanticCandidate(
        "你好，世界",
        token: state.token,
        decision: .sentenceSuggestion,
        segments: state.inferenceSegments
    )
    #expect(accepted)

    // 布局与候选文本不匹配（缺少分隔标点）：保持旧行为，前置前缀。
    #expect(state.semanticCandidateCommitText(for: "你好世界") == "你好，你好世界")
}

@Test
func test_mixedScriptSentenceCommitDoesNotPrependPrefix() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(pinyin: "nihao", candidates: ["你好"])
    state.appendLiteral("，")
    _ = state.replaceInput(pinyin: "shijie", candidates: ["世界"])
    // 中英混输整句：准入与提交用同一个结构校验，段布局匹配即视
    // 为已覆盖定稿前缀，不得再前置前缀造成重复上屏。
    let accepted = state.applySemanticCandidate(
        "你好，seeyou世界",
        token: state.token,
        decision: .sentenceSuggestion,
        segments: state.inferenceSegments
    )
    #expect(accepted)

    #expect(state.committedPrefixText == "你好，")
    #expect(
        state.semanticCandidateCommitText(for: "你好，seeyou世界")
            == "你好，seeyou世界"
    )
}

@Test
func appendLiteralFinalizedTextFollowsCommitBaselineAndOverride() {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(
        pinyin: "ceshi",
        candidates: (1 ... 12).map { "候选\($0)" }
    )
    // 未传定稿时保持旧行为：全局首选。
    state.appendLiteral("，")
    #expect(state.prefixSegments.last == .literal("，"))
    #expect(
        state.prefixSegments.first
            == .committedPinyin(pinyin: "ceshi", committedText: "候选1")
    )

    // 当前页第一项基准由 controller 层计算后传入（与提交路径同一
    // 基准，含字形转换）：翻到第 2 页后定稿文本应是第 2 页首选。
    var paged = CompositionState(appSessionID: "app-1")
    _ = paged.replaceInput(
        pinyin: "ceshi",
        candidates: (1 ... 12).map { "候选\($0)" }
    )
    _ = paged.advanceCandidatePage()
    let pageCommitted = paged.mainCandidates[
        paged.globalCandidateIndex(forPageSlot: 1) ?? 0
    ]
    paged.appendLiteral("，", finalizedText: pageCommitted)
    #expect(
        paged.prefixSegments.first
            == .committedPinyin(pinyin: "ceshi", committedText: "候选6")
    )

    // 调用方传入字形转换后的候选时原样使用（繁体候选不入定稿）。
    var overridden = CompositionState(appSessionID: "app-1")
    _ = overridden.replaceInput(
        pinyin: "ceshi",
        candidates: ["測試"]
    )
    overridden.appendLiteral(",", finalizedText: "测试")
    #expect(
        overridden.prefixSegments.first
            == .committedPinyin(pinyin: "ceshi", committedText: "测试")
    )

    // 无候选（混输态）且未传定稿时回退原始字母。
    var fallback = CompositionState(appSessionID: "app-1")
    _ = fallback.replaceInput(pinyin: "api", candidates: [])
    fallback.appendLiteral("，")
    #expect(
        fallback.prefixSegments.first
            == .committedPinyin(pinyin: "api", committedText: "api")
    )
}
