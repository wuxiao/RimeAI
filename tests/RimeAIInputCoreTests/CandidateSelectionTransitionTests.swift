import Testing
@testable import RimeAIInputCore

@Suite("Candidate selection transition")
struct CandidateSelectionTransitionTests {
    @Test("whole-composition selection records the whole input")
    func completeSelection() throws {
        let transition = try #require(CandidateSelectionTransition(
            originalInput: "nihao",
            committedText: "你好",
            remainingInput: ""
        ))

        #expect(transition.committedText == "你好")
        #expect(transition.historyInput == "nihao")
        #expect(transition.remainingInput == nil)
    }

    @Test("partial selection commits only the chosen prefix and retains tail")
    func partialSelection() throws {
        let transition = try #require(CandidateSelectionTransition(
            originalInput: "mingtiantianqi",
            committedText: "明天",
            remainingInput: "tianqi"
        ))

        #expect(transition.committedText == "明天")
        #expect(transition.historyInput == "mingtian")
        #expect(transition.remainingInput == "tianqi")
    }

    @Test("apostrophe separator belongs to the consumed prefix")
    func apostropheBoundary() throws {
        let transition = try #require(CandidateSelectionTransition(
            originalInput: "xi'anrenmin",
            committedText: "西安",
            remainingInput: "renmin"
        ))

        #expect(transition.historyInput == "xi'an")
        #expect(transition.remainingInput == "renmin")
    }

    @Test("unauthoritative native tails fail closed")
    func invalidTail() {
        #expect(CandidateSelectionTransition(
            originalInput: "mingtiantianqi",
            committedText: "明天",
            remainingInput: "qianqi"
        ) == nil)
        #expect(CandidateSelectionTransition(
            originalInput: "mingtiantianqi",
            committedText: "明天",
            remainingInput: "mingtiantianqi"
        ) == nil)
        #expect(CandidateSelectionTransition(
            originalInput: "mingtiantianqi",
            committedText: "明天\n天气",
            remainingInput: "tianqi"
        ) == nil)
    }

    // KBD-008：部分选词段保留——确认前缀不上屏，以定稿中文保留
    // 预编辑区并可 ← 回修；剩余拼音成为新活跃段。

    @Test("partial selection retention keeps confirmed prefix in composition")
    func retainFocusedSegmentAsPrefixKeepsConfirmedPrefix() {
        var state = CompositionState(appSessionID: "app-1")
        _ = state.replaceInput(
            pinyin: "ceshishurufanihao",
            candidates: ["测试输入法你好", "测试输入法"]
        )
        #expect(
            state.retainFocusedSegmentAsPrefix(
                finalizedText: "测试输入法",
                remainingPinyin: "nihao"
            ) == true
        )
        #expect(state.pinyin == "nihao")
        #expect(state.prefixSegments == [
            .committedPinyin(pinyin: "ceshishurufa", committedText: "测试输入法")
        ])
        #expect(state.displayString == "测试输入法nihao")
        // 段拼音只记被消费前缀，历史拼接不与活跃段重复。
        #expect(state.prefixHistoryPinyin == "ceshishurufa")
        // 候选/语义候选失效（等待 compositionInput 重建）。
        #expect(state.mainCandidates.isEmpty)
        #expect(state.semanticCandidate == nil)
        // ← 可回修前缀段：定稿文本随段保留。
        #expect(state.moveFocusLeft(finalizedText: "你好") == true)
        #expect(state.pinyin == "ceshishurufa")
        guard case let .committedPinyin(_, suffixText)? = state.suffixSegments.first
        else {
            Issue.record("后缀应包含剩余段定稿")
            return
        }
        #expect(suffixText == "你好")
        // 前缀唯一段已复活为焦点：焦点段显示拼音原样，后缀显定稿。
        #expect(state.displayString == "ceshishurufa你好")
    }

    @Test("invalid remaining pinyin is rejected without state change")
    func retainFocusedSegmentAsPrefixRejectsInvalidRemainingPinyin() {
        var state = CompositionState(appSessionID: "app-1")
        _ = state.replaceInput(
            pinyin: "ceshishurufa",
            candidates: ["测试输入法"]
        )
        // 空剩余、非焦点段后缀、含非法字节（空格/大写）、不短于焦
        // 点段、空定稿文本：全部拒绝且状态不变（调用方回退既有上
        // 屏路径）。
        #expect(state.retainFocusedSegmentAsPrefix(
            finalizedText: "测试", remainingPinyin: ""
        ) == false)
        #expect(state.retainFocusedSegmentAsPrefix(
            finalizedText: "测试", remainingPinyin: "xxx"
        ) == false)
        #expect(state.retainFocusedSegmentAsPrefix(
            finalizedText: "测试", remainingPinyin: "ni hao"
        ) == false)
        #expect(state.retainFocusedSegmentAsPrefix(
            finalizedText: "测试", remainingPinyin: "niHao"
        ) == false)
        #expect(state.retainFocusedSegmentAsPrefix(
            finalizedText: "测试", remainingPinyin: "ceshishurufa"
        ) == false)
        #expect(state.retainFocusedSegmentAsPrefix(
            finalizedText: "", remainingPinyin: "shurufa"
        ) == false)
        #expect(state.pinyin == "ceshishurufa")
        #expect(state.prefixSegments.isEmpty)
        #expect(state.mainCandidates == ["测试输入法"])
    }

    @Test("focused separator run merges into prefix with suffix intact")
    func retainFocusedSegmentAsPrefixMergesFocusedSeparatorRun() {
        var state = CompositionState(appSessionID: "app-1")
        _ = state.replaceInput(pinyin: "ceshi", candidates: ["测试"])
        state.appendLiteral("，")
        _ = state.replaceInput(pinyin: "shijie", candidates: ["世界"])
        #expect(state.moveFocusLeft(finalizedText: "世界") == true)
        // 焦点 ceshi + 焦点字面量运行 [，] + 后缀 [shijie/世界]。UI
        // 层此状态选词走 KBD-006 分支；本用例验证 CompositionState
        // 层通用行为：焦点段部分消费时字面量运行随段并入前缀、后
        // 缀不动。
        #expect(
            state.retainFocusedSegmentAsPrefix(
                finalizedText: "测试",
                remainingPinyin: "shi"
            ) == true
        )
        #expect(state.pinyin == "shi")
        #expect(state.focusedSeparatorLiterals.isEmpty)
        #expect(state.prefixSegments == [
            .committedPinyin(pinyin: "ce", committedText: "测试"),
            .literal("，")
        ])
        #expect(state.displayString == "测试，shi世界")
        #expect(state.prefixHistoryPinyin == "ce")
    }
}
