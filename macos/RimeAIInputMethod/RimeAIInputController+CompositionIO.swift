import AppKit
import InputMethodKit

/// 组合状态写入与文本提交：拼音输入、混输解析、历史英文 token
/// 预热、上屏（含前缀冲刷）与推断失效。
extension RimeAIInputController {
    func compositionInput(
        _ rawInput: String,
        client: any IMKTextInput
    ) {
        cancelVoiceDictation()
        continuationCoordinator.cancel(.compositionBegan)
        continuationAnchorRect = nil
        pipeline.invalidate()
        pipeline.beginInputCycle()
        let rimeInput = rawInput.lowercased()
        let candidates = RimeEngine.shared.candidates(
            for: rimeInput,
            limit: 50
        )
        let mixedSuggestion = resolveMixedComposition(
            rawInput: rawInput
        )
        // 中英混合输入：查询失败（Rime 无候选且无混输建议，典型如
        // 韵母首字母 i/u/v 开头的英文串）时原始按键必须保留在编码区，
        // 由 Space/Enter 原样上屏或等待后续混输解析，绝不丢弃。
        var resolvedCandidates = candidates
        var rawLeadPrefix: String?
        if candidates.isEmpty {
            if let split = MixedCompositionResolver.rawLeadSplit(
                of: rimeInput
            ) {
                let remainderCandidates = RimeEngine.shared.candidates(
                    for: split.remainder,
                    limit: 50
                )
                if !remainderCandidates.isEmpty {
                    // Rime 无法解析整串，但余串（如 nihao）有候选：前导
                    // 原样保留、候选逐个加前缀，与 nihaoi 等 Rime 可见
                    // 形式给出一致的候选列表。
                    resolvedCandidates = remainderCandidates.map {
                        split.lead + $0
                    }
                    rawLeadPrefix = split.lead
                }
            }
            if resolvedCandidates.isEmpty, let mixedSuggestion {
                // Rime 完全无法解析但混输解析有结果（如 iphonenihao）：
                // 结果作为普通首选展示，提交经主候选路径，不出现
                // 中英混输专属提示。
                resolvedCandidates = [mixedSuggestion.text]
            }
        }
        let token = composition.replaceInput(
            pinyin: rawInput,
            candidates: resolvedCandidates,
            rawLeadPrefix: rawLeadPrefix
        )
        configureVoiceHotKey()
        client.setMarkedText(
            composition.displayString,
            selectionRange: NSRange(
                location: composition.displayString.utf16.count,
                length: 0
            ),
            replacementRange: notFoundRange
        )
        if resolvedCandidates.isEmpty {
            pipeline.markUnavailable()
            renderCandidatePanel(client: client)
            return
        }
        if candidates.isEmpty {
            // Rime 查空的特殊输入：候选已合成完毕，直接进入展示，
            // 不参与语义推理；无候选前导时才登记混输建议。
            if rawLeadPrefix == nil, let mixedSuggestion {
                _ = pipeline.trackMixedSuggestionAsMainCandidate(
                    mixedSuggestion,
                    token: token
                )
            }
            renderCandidatePanel(client: client)
            return
        }
        if let mixedSuggestion,
           pipeline.presentMixedComposition(mixedSuggestion, token: token)
        {
            renderCandidatePanel(client: client)
            return
        }
        pipeline.scheduleInference(
            token: token,
            bundleIdentifier: currentBundleIdentifier,
            contextProvider: { [weak self] policy in
                self?.inferenceContext(policy: policy, client: client)
                    ?? ""
            }
        )
        renderCandidatePanel(client: client)
    }

    /// KBD-006：焦点段定稿/移动后重推后缀段定稿文本（daemon 本地
    /// 排序融合，批内防抖 + 串行）。仅在焦点不在末段时有实际工作。
    func scheduleSuffixRefinement(client: any IMKTextInput) {
        pipeline.scheduleSuffixRefinement(
            token: composition.token,
            bundleIdentifier: currentBundleIdentifier,
            contextProvider: { [weak self] policy in
                self?.inferenceContext(policy: policy, client: client)
                    ?? ""
            },
            applyRefinedText: { [weak self] suffixIndex, text, token in
                self?.applyRefinedSuffixText(
                    suffixIndex,
                    text,
                    token,
                    client: client
                ) ?? false
            }
        )
    }

    /// 应用单段重推文本并刷新 marked text；token 失效（用户编辑
    /// 抢先）时拒绝，批由管线侧作废。
    func applyRefinedSuffixText(
        _ suffixIndex: Int,
        _ text: String,
        _ token: CompositionToken,
        client: any IMKTextInput
    ) -> Bool {
        guard composition.updateSuffixCommittedText(
            atSuffixIndex: suffixIndex,
            committedText: text,
            token: token
        ) else {
            return false
        }
        client.setMarkedText(
            composition.displayString,
            selectionRange: NSRange(
                location: composition.displayString.utf16.count,
                length: 0
            ),
            replacementRange: notFoundRange
        )
        return true
    }

    /// KBD-007：云端整句按段应用（不提交）。仅当建议覆盖全部段、
    /// 段数 ≥ 2 且每段均可转换到用户字形时生效；返回 false 时调用
    /// 方回退既有整句提交路径。
    func applySegmentedSuggestionIfEligible(
        _ candidate: String,
        client: any IMKTextInput
    ) -> Bool {
        guard composition.semanticCandidateCoversPrefix,
              let segments = composition.semanticCandidateSegments,
              segments.count >= 2,
              let texts = CloudGeneratedSentencePolicy.segmentTexts(
                  text: candidate,
                  pinyinSegments: segments
              )
        else {
            return false
        }
        let sanitizedTexts = texts.map {
            SemanticCandidateScriptPolicy.sanitized(
                text: $0,
                characterSet: settings.characterSet
            )
        }
        guard sanitizedTexts.allSatisfy({ $0 != nil }) else {
            return false
        }
        let token = composition.token
        guard composition.applySegmentedSuggestion(
            sanitizedTexts.map { $0! },
            token: token
        ) else {
            return false
        }
        settings.record(.semanticAccepted)
        settings.record(.semanticSentenceAccepted)
        invalidateInference(clearPresentation: true)
        client.setMarkedText(
            composition.displayString,
            selectionRange: NSRange(
                location: composition.displayString.utf16.count,
                length: 0
            ),
            replacementRange: notFoundRange
        )
        candidatePanel.hide()
        configureVoiceHotKey()
        return true
    }

    func resolveMixedComposition(
        rawInput: String
    ) -> MixedCompositionSuggestion? {
        guard let currentBundleIdentifier,
              settings.isAIAllowed(for: currentBundleIdentifier)
        else {
            return nil
        }
        // 混输个人词表由 L1 短语库承担（LP-006）：取代原 settings +
        // history 的 256 词机制。
        var personalized = Set<String>()
        if settings.contextPolicy(for: currentBundleIdentifier) != .strict {
            // 预热完成前读进程内快照（冷启动时为空集），绝不在主线程
            // 触发 SQLite 查询。
            personalized = phrasebookEnglishTokensLoaded
                ? phrasebookEnglishTokens
                : RimeAIPhraseBookService.shared.allEnglishTokens()
        }
        return mixedCompositionResolver.resolve(
            rawInput: rawInput,
            personalizedEnglishTokens: personalized
        ) { pinyin, limit in
            RimeEngine.shared.candidates(for: pinyin, limit: limit)
        }
    }

    /// 预热 L1 短语库的混输个人词表，并一次性迁移既有个人英文词
    /// （导入幂等；迁移成功后清掉旧词表键，后续控制器实例不再重复
    /// 读取与导入）。
    func prewarmPhrasebookEnglishTokens(
        for bundleIdentifier: String
    ) {
        guard settings.contextPolicy(for: bundleIdentifier) != .strict,
              !phrasebookEnglishTokensLoaded,
              !phrasebookEnglishTokensLoading
        else {
            return
        }
        phrasebookEnglishTokensLoading = true
        let generation = phrasebookEnglishTokensGeneration
        let legacyTokens = legacyEnglishTokensMigrated
            ? nil
            : settings.personalEnglishTokens
        legacyEnglishTokensMigrated = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            if let legacyTokens, !legacyTokens.isEmpty {
                RimeAIPhraseBookService.shared.adoptPersonalEnglishTokens(
                    legacyTokens
                )
                UserDefaults.standard.removeObject(
                    forKey: RimeAISettingsStore.Keys.personalEnglishTokens
                )
            }
            // 同步刷新读快照后再取词：迁移刚写入的行必须进入本批
            // 预热结果，而不是等下一次后台刷新。
            RimeAIPhraseBookService.shared.refreshSnapshotNow()
            let tokens = RimeAIPhraseBookService.shared.allEnglishTokens()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.phrasebookEnglishTokensGeneration == generation
                else {
                    return
                }
                self.phrasebookEnglishTokens = tokens
                self.phrasebookEnglishTokensLoaded = true
                self.phrasebookEnglishTokensLoading = false
            }
        }
    }

    @discardableResult
    func commitText(
        _ text: String,
        source: HistoryCommitSource,
        client: any IMKTextInput,
        historyPinyin: String
    ) -> Bool {
        guard insertCommittedText(
            text,
            pinyin: historyPinyin,
            source: source,
            client: client
        ) else {
            return false
        }
        resetComposition(client: client, preserveContext: true)
        armContinuationAfterCommit(committedText: text, client: client)
        return true
    }

    func insertCommittedText(
        _ text: String,
        pinyin: String,
        source: HistoryCommitSource,
        client: any IMKTextInput
    ) -> Bool {
        guard !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            enterSecureInput(client: client)
            return false
        }
        let bundleIdentifier = currentBundleIdentifier
            ?? client.bundleIdentifier()
            ?? "unknown-client"
        let historyWasAllowedBeforeCommit = settings.shouldCaptureCloudHistory(
            isSecureInput: composition.isSecureInput
                || IsSecureEventInputEnabled()
        )
        client.insertText(text, replacementRange: notFoundRange)
        guard !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            enterSecureInput(client: client)
            return false
        }
        recordCommitSideEffects(
            text: text,
            pinyin: pinyin,
            source: source,
            historyBundleIdentifier: bundleIdentifier,
            contextBundleIdentifier: currentBundleIdentifier,
            historyWasAllowedBeforeCommit: historyWasAllowedBeforeCommit
        )
        return true
    }

    /// 提交文本后的上下文与历史记账：组合上屏（insertCommittedText）
    /// 与续写上屏（commitContinuation）共用。raw_pinyin 原样上屏不进
    /// 会话上下文（也不关停上下文存储）；组合路径的上下文门控要求
    /// 控制器已绑定 bundle（nil 按不允许处理），续写路径传入解析后的
    /// bundle。
    func recordCommitSideEffects(
        text: String,
        pinyin: String,
        source: HistoryCommitSource,
        historyBundleIdentifier: String,
        contextBundleIdentifier: String?,
        historyWasAllowedBeforeCommit: Bool
    ) {
        if let contextBundleIdentifier,
           settings.isAIAllowed(for: contextBundleIdentifier),
           settings.contextPolicy(for: contextBundleIdentifier) != .strict
        {
            if source != .rawPinyin {
                Self.contextStore.appendCommittedText(text)
            }
        } else {
            Self.contextStore.deactivate()
        }
        let shouldCaptureHistory = historyWasAllowedBeforeCommit
            && settings.shouldCaptureCloudHistory(
                isSecureInput: composition.isSecureInput
                    || IsSecureEventInputEnabled()
            )
        if shouldCaptureHistory {
            RimeAIHistoryService.shared.appendAsync(
                HistoryCommit(
                    bundleIdentifier: historyBundleIdentifier,
                    pinyin: pinyin,
                    committedText: text,
                    source: source
                )
            ) { [settings] result in
                switch result {
                case .success:
                    settings.record(.historyRecorded)
                case .failure:
                    settings.record(.historyWriteFailed)
                }
            }
        }
    }

    func resetComposition(
        client: any IMKTextInput,
        preserveContext: Bool = true
    ) {
        invalidateInference(clearPresentation: true)
        composition.reset()
        client.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: notFoundRange
        )
        candidatePanel.hide()
        if !preserveContext {
            Self.contextStore.deactivate()
        }
        configureVoiceHotKey()
    }

    func invalidateCurrentResult() {
        composition.beginSelection()
        invalidateInference(clearPresentation: true)
        if let client = activeClientObject as? any IMKTextInput,
           !composition.pinyin.isEmpty
        {
            renderCandidatePanel(client: client)
        }
    }

    func invalidateInference(clearPresentation: Bool = false) {
        pipeline.invalidate(clearPresentation: clearPresentation)
    }
}
