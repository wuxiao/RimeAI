import AppKit
import InputMethodKit

/// 候选选择与提交过渡：主候选/语义候选两条选词路径、Rime 提交
/// 过渡应用（含前缀冲刷与部分选词保留）与语义接纳诊断。
extension RimeAIInputController {
    func selectMainCandidate(
        index: Int,
        client: any IMKTextInput,
        acceptedViaSemanticCandidate: Bool = false
    ) {
        guard !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            enterSecureInput(client: client)
            return
        }
        guard composition.mainCandidates.indices.contains(index) else {
            return
        }
        let originalInput = composition.pinyin
        let pinyin = originalInput.lowercased()
        let fallback = composition.mainCandidates[index]
        if composition.semanticCandidateDecision == .mixedComposition,
           pipeline.mixedCompositionSuggestion?.text == fallback
        {
            // 以普通主候选形式展示的混输结果（Rime 无法解析的输入）：
            // Rime 提交必然失败，直接复用混输提交路径。
            selectSemanticCandidate(fallback, client: client)
            return
        }
        let semanticDecision = acceptedViaSemanticCandidate
            ? composition.semanticCandidateDecision
            : nil
        // 合成候选（韵母首字母前导 + 余串候选）：把余串还原给 Rime
        // 完成选词与学习，提交文本再加回前导。
        let rawLeadPrefix = composition.rawLeadPrefix
        let rimePinyin: String
        let rimeExpectedText: String
        if let rawLeadPrefix, !rawLeadPrefix.isEmpty {
            rimePinyin = String(pinyin.dropFirst(rawLeadPrefix.count))
            rimeExpectedText = String(fallback.dropFirst(rawLeadPrefix.count))
        } else {
            rimePinyin = pinyin
            rimeExpectedText = fallback
        }
        composition.beginSelection()
        invalidateInference()
        guard let transition = RimeEngine.shared.selectCandidate(
            pinyin: rimePinyin,
            index: index,
            expectedText: rimeExpectedText
        ) else {
            settings.record(.invalidResult)
            compositionInput(originalInput, client: client)
            return
        }
        guard let appliedTransition = appliedSelectionTransition(
            transition,
            originalInput: originalInput,
            rawLeadPrefix: rawLeadPrefix,
            client: client
        ) else {
            return
        }
        // KBD-006：焦点在中间段时，数字选词只确认焦点段（Rime 学习
        // 照常），焦点自动右移到下一拼音段；后缀保持可编辑，历史留
        // 待最终整句提交时一次落库。
        if composition.canMoveFocusRight {
            composition.moveFocusRight(
                finalizedText: appliedTransition.committedText
            )
            invalidateInference(clearPresentation: true)
            compositionInput(composition.pinyin, client: client)
            scheduleSuffixRefinement(client: client)
            if acceptedViaSemanticCandidate {
                recordSemanticAcceptance(decision: semanticDecision)
                pipeline.markDisplayedSuggestionAdopted()
            } else {
                settings.record(.mainAccepted)
                pipeline.markDisplayedSuggestionRejected(
                    committedText: appliedTransition.committedText
                )
            }
            return
        }
        // KBD-008：焦点在末段时的部分选词——确认前缀不上屏，保留
        // 预编辑区可 ← 回修；校验失败回退下方既有提交路径。
        if retainPartialSelectionInComposition(
            appliedTransition,
            acceptedViaSemanticCandidate: acceptedViaSemanticCandidate,
            semanticDecision: semanticDecision,
            client: client
        ) {
            return
        }
        let historySource = acceptedViaSemanticCandidate
            ? pipeline.historySource
            : .rimeMain
        // 整段提交（无剩余拼音）时，上屏文本 = 全部定稿外层（前缀 +
        // 焦点字面量 + 后缀）+ 本次提交；在 apply 清空前快照，供续写
        // 协调器的汉字数门槛使用。
        let fullCommittedText = composition.committedOuterText
            + appliedTransition.committedText
        let isFullCommit = appliedTransition.remainingInput == nil
        guard applyCandidateSelection(
            appliedTransition,
            expectedText: fallback,
            source: historySource,
            client: client
        ) else {
            return
        }
        if isFullCommit {
            armContinuationAfterCommit(
                committedText: fullCommittedText,
                client: client
            )
        }
        if acceptedViaSemanticCandidate {
            recordSemanticAcceptance(decision: semanticDecision)
            pipeline.markDisplayedSuggestionAdopted()
        } else {
            settings.record(.mainAccepted)
            pipeline.markDisplayedSuggestionRejected(
                committedText: appliedTransition.committedText
            )
        }
    }

    /// 合成候选（韵母首字母前导 + 余串候选）：Rime 只见去掉前导的
    /// 余串（选词与学习以余串为准），选后把前导加回定稿文本；非合
    /// 成候选（无前导）原样返回。transition 校验失败（剩余拼音与原
    /// 始输入不一致）时复位组合状态并返回 nil，调用方终止本次选词。
    private func appliedSelectionTransition(
        _ transition: CandidateSelectionTransition,
        originalInput: String,
        rawLeadPrefix: String?,
        client: any IMKTextInput
    ) -> CandidateSelectionTransition? {
        guard let rawLeadPrefix, !rawLeadPrefix.isEmpty else {
            return transition
        }
        guard let adjusted = CandidateSelectionTransition(
            originalInput: originalInput,
            committedText: rawLeadPrefix + transition.committedText,
            remainingInput: transition.remainingInput ?? ""
        ) else {
            settings.record(.invalidResult)
            compositionInput(originalInput, client: client)
            return nil
        }
        return adjusted
    }

    /// KBD-008：焦点在末段时的部分选词（有未消费剩余拼音）——
    /// 确认前缀不上屏，以定稿文本保留在预编辑区（可 ← 回修，修正
    /// 定稿后由 KBD-006 重推其余段），剩余拼音成为新活跃段；历史
    /// 与热词留待最终整句提交一次落库（D2/D3）。段写入校验失败时
    /// 返回 false，调用方回退既有提交路径（fail-safe，与旧行为一
    /// 致）。
    private func retainPartialSelectionInComposition(
        _ transition: CandidateSelectionTransition,
        acceptedViaSemanticCandidate: Bool,
        semanticDecision: SemanticInferenceDecision?,
        client: any IMKTextInput
    ) -> Bool {
        guard let remainingInput = transition.remainingInput,
              composition.retainFocusedSegmentAsPrefix(
                  finalizedText: transition.committedText,
                  remainingPinyin: remainingInput
              )
        else {
            return false
        }
        invalidateInference(clearPresentation: true)
        compositionInput(composition.pinyin, client: client)
        if acceptedViaSemanticCandidate {
            recordSemanticAcceptance(decision: semanticDecision)
        } else {
            settings.record(.mainAccepted)
        }
        return true
    }

    func selectSemanticCandidate(
        _ candidate: String,
        client: any IMKTextInput
    ) {
        guard !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            enterSecureInput(client: client)
            return
        }
        // 最后一道字形关口：能转换就转换（与展示一致），仅无法转换
        // 时拒绝上屏。
        guard let committedDisplay = SemanticCandidateScriptPolicy.sanitized(
            text: candidate,
            characterSet: settings.characterSet
        ) else {
            settings.record(.sentenceScriptMismatch)
            return
        }
        let candidate = committedDisplay
        let decision = composition.semanticCandidateDecision
        if decision != .mixedComposition,
           let index = composition.mainCandidates.firstIndex(of: candidate)
        {
            selectMainCandidate(
                index: index,
                client: client,
                acceptedViaSemanticCandidate: true
            )
            return
        }
        let originalInput = composition.pinyin
        let cloudCandidate = pipeline.cloudCandidate?.text == candidate
            ? pipeline.cloudCandidate
            : nil
        let acceptedMixedSuggestion = decision == .mixedComposition
            ? pipeline.mixedCompositionSuggestion
            : nil
        // 整句覆盖判定须在 beginSelection() 清空段布局之前完成；
        // 可达的提交路径里 committedCandidate 与 candidate 相同
        // （Rime 分支守护 transition.committedText == candidate）。
        let semanticCommitText = composition.semanticCandidateCommitText(
            for: candidate
        )
        composition.beginSelection()
        invalidateInference()
        var learnedEnglishTokens = Set<String>()
        if let acceptedMixedSuggestion {
            learnedEnglishTokens = Set(
                acceptedMixedSuggestion.segments
                    .filter { $0.kind == .ascii }
                    .map { $0.rawText.lowercased() }
            )
        }
        let rimeCommitResult: String?
        if let cloudCandidate,
           let rimeIndex = cloudCandidate.rimeIndex
        {
            guard let transition = RimeEngine.shared.selectCandidate(
                pinyin: cloudCandidate.alignedPinyin,
                index: rimeIndex,
                expectedText: candidate
            ), transition.remainingInput == nil,
              transition.committedText == candidate
            else {
                settings.record(.invalidResult)
                compositionInput(originalInput, client: client)
                return
            }
            rimeCommitResult = transition.committedText
        } else {
            rimeCommitResult = nil
        }
        guard commitText(
            semanticCommitText,
            source: pipeline.historySource,
            client: client,
            historyPinyin: composition.historyPinyin
        ) else {
            return
        }
        recordVoiceHotwordFromRimeCommit(
            rimeCommitResult,
            matching: candidate,
            client: client
        )
        recordSemanticAcceptance(decision: decision)
        pipeline.markDisplayedSuggestionAdopted()
        if !learnedEnglishTokens.isEmpty {
            // 混输个人词表学习进 L1 短语库（LP-006），取代 settings 的
            // 256 词上限；持久历史仍由固化循环统计。
            RimeAIPhraseBookService.shared.recordMixedEnglishTokens(
                learnedEnglishTokens
            )
        }
    }

    func recordSemanticAcceptance(
        decision: SemanticInferenceDecision?
    ) {
        settings.record(.semanticAccepted)
        if pipeline.historySource == .cloudExact
            || pipeline.historySource == .cloudFuzzy
            || pipeline.historySource == .cloudGenerated
        {
            settings.record(.cloudSuggestionAccepted)
        }
        if pipeline.historySource == .cloudFuzzy {
            settings.record(.cloudCorrectionAccepted)
        }
        if pipeline.historySource == .cloudGenerated {
            settings.record(.cloudGeneratedAccepted)
        }
        if decision == .sentenceSuggestion {
            settings.record(.semanticSentenceAccepted)
        } else if decision == .mixedComposition {
            settings.record(.mixedCompositionAccepted)
        } else if decision == .phraseBook {
            settings.record(.phraseBookSuggestionAccepted)
        } else {
            settings.record(.semanticRankedAccepted)
        }
    }

    @discardableResult
    func applyCandidateSelection(
        _ transition: CandidateSelectionTransition,
        expectedText: String,
        source: HistoryCommitSource,
        client: any IMKTextInput
    ) -> Bool {
        CandidateSelectionApplicationTransition.apply(
            transition,
            secureInputIsActive: { [self] in
                composition.isSecureInput || IsSecureEventInputEnabled()
            },
            cancelForSecureInput: { [self] in
                enterSecureInput(client: client)
            },
            insertConfirmedPrefix: { [self] text, pinyin in
                let fullText = composition.committedOuterText + text
                let fullPinyin = composition.prefixHistoryPinyin + pinyin
                    + composition.suffixHistoryPinyin
                let inserted = insertCommittedText(
                    fullText,
                    pinyin: fullPinyin,
                    source: source,
                    client: client
                )
                if inserted {
                    // 前缀已并入正式文本：立即冲刷，防止后续提交把
                    // 同一段内容二次插入。
                    composition.flushPrefix()
                }
                return inserted
            },
            retainMarkedComposition: { [self] remainingInput in
                compositionInput(remainingInput, client: client)
            },
            resetComposition: { [self] in
                resetComposition(client: client, preserveContext: true)
            },
            recordConfirmedHotword: { [self] text in
                recordVoiceHotwordFromRimeCommit(
                    text,
                    matching: expectedText,
                    client: client
                )
            }
        )
    }
}
