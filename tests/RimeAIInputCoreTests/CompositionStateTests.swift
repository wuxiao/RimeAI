import Foundation
import Testing
@testable import RimeAIInputCore

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
