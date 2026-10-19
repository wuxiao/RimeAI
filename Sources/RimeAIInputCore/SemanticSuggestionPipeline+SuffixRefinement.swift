import Foundation

/// 分段重推应用闭包：写入后缀段定稿文本；token 失效或段不存在时
/// 返回 false（整批作废）。
public typealias SuffixRefinementApplier = @MainActor @Sendable (
    _ suffixIndex: Int, _ text: String, _ token: CompositionToken
) -> Bool

/// 分段向后重推（KBD-006）：焦点段定稿/移动后，按批（串行、每段
/// 一次本地 infer、ranked-only）用最新上下文重推后缀段定稿文本。
/// 批锚是 compositionID 与焦点段拼音——焦点移动、整句按段应用或
/// 用户编辑焦点段都会使剩余步骤作废；批内自身应用只递增 revision、
/// 不换 compositionID，因此批可以继续推进。云整句建议通道不受影
/// 响（KBD-007 仍覆盖全部段）。
extension SemanticSuggestionPipeline {
    /// 重推批的防抖间隔：吸收连续焦点移动/定稿事件，只在动作稳定
    /// 后发一轮。
    public static let suffixRefinementDebounceInterval: TimeInterval = 0.15

    /// 一次重推批的不可变锚与闭包集合。闭包均为主线程侧使用，
    /// Sendable 由管线类的 @unchecked 约束一并承担。
    struct SuffixRefinementBatch: @unchecked Sendable {
        let anchorCompositionID: UUID
        let anchorFocusedPinyin: String
        let suffixPinyins: [String]
        let bundleIdentifier: String
        let contextProvider: (ContextPolicy) -> String
        let applyRefinedText: SuffixRefinementApplier
    }

    /// 单步在途请求的完成现场。
    private struct SuffixRefinementStep {
        let requestID: String
        let candidates: [String]
        let suffixIndex: Int
        let requestToken: CompositionToken
        let nextOffset: Int
    }

    /// 调度一轮后缀重推。调用时机：焦点段定稿/移动、字面量定稿、
    /// 中段选词确认。后缀为空（焦点在末段/纯单段）时零开销返回。
    public func scheduleSuffixRefinement(
        token: CompositionToken,
        bundleIdentifier: String?,
        contextProvider: @escaping (ContextPolicy) -> String,
        applyRefinedText: @escaping SuffixRefinementApplier
    ) {
        cancelSuffixRefinement()
        guard let bundleIdentifier,
              !composition.isSecureInput,
              !composition.isSelecting,
              !dependencies.isSecureEventInputEnabled(),
              dependencies.isLocalInferenceAllowed(bundleIdentifier)
        else {
            return
        }
        let suffixPinyins = composition.suffixSegments.compactMap {
            segment -> String? in
            if case let .committedPinyin(pinyin, _) = segment {
                return pinyin.lowercased()
            }
            return nil
        }
        guard !suffixPinyins.isEmpty else {
            return
        }
        let batch = SuffixRefinementBatch(
            anchorCompositionID: token.compositionID,
            anchorFocusedPinyin: composition.pinyin,
            suffixPinyins: suffixPinyins,
            bundleIdentifier: bundleIdentifier,
            contextProvider: contextProvider,
            applyRefinedText: applyRefinedText
        )
        suffixRefinementTask = dependencies.scheduling.scheduleOnMain(
            after: Self.suffixRefinementDebounceInterval
        ) { [weak self] in
            self?.runSuffixRefinementStep(batch: batch, offset: 0)
        }
    }

    /// 取消在途重推批与请求（invalidate / 新一轮调度前调用）。
    func cancelSuffixRefinement() {
        suffixRefinementTask?.cancel()
        suffixRefinementTask = nil
        for requestID in pendingSuffixRefinementRequestIDs {
            dependencies.cancelLocalInference(requestID)
        }
        pendingSuffixRefinementRequestIDs.removeAll()
    }

    /// 定位该段在后缀数组中的索引：批内后缀结构不变（结构变更必
    /// 换 compositionID，已被批锚挡住），仅定稿文本可被批推进。
    private func suffixRefinementTargetIndex(
        _ composition: CompositionState,
        suffixIndexInBatch offset: Int
    ) -> Int? {
        var seen = 0
        for (index, segment) in composition.suffixSegments.enumerated() {
            guard segment.isPinyinSegment else {
                continue
            }
            if seen == offset {
                return index
            }
            seen += 1
        }
        return nil
    }

    private func runSuffixRefinementStep(
        batch: SuffixRefinementBatch,
        offset: Int
    ) {
        guard offset < batch.suffixPinyins.count else {
            return
        }
        let current = composition
        guard current.compositionID == batch.anchorCompositionID,
              current.pinyin == batch.anchorFocusedPinyin,
              !current.isSelecting,
              !current.isSecureInput,
              !dependencies.isSecureEventInputEnabled()
        else {
            return
        }
        guard let suffixIndex = suffixRefinementTargetIndex(
            current,
            suffixIndexInBatch: offset
        ) else {
            return
        }
        sendSuffixRefinementRequest(
            batch: batch,
            offset: offset,
            suffixIndex: suffixIndex,
            composition: current
        )
    }

    /// 组装并发送单段重推请求：前文 = 应用内上下文 + 组合区已定稿
    /// 文本（前缀 + 焦点段首选猜测 + 字面量 + 之前后缀段定稿）；
    /// ranked-only、不带段布局。该段无 Rime 候选时直接跳过。
    private func sendSuffixRefinementRequest(
        batch: SuffixRefinementBatch,
        offset: Int,
        suffixIndex: Int,
        composition current: CompositionState
    ) {
        let segmentPinyin = batch.suffixPinyins[offset]
        let candidates = dependencies.rimeCandidates(segmentPinyin)
        guard !candidates.isEmpty else {
            runSuffixRefinementStep(batch: batch, offset: offset + 1)
            return
        }
        let policy = dependencies.contextPolicy(batch.bundleIdentifier)
        let focusedGuess = current.mainCandidates.first ?? current.pinyin
        var preceding = current.committedPrefixText + focusedGuess
            + current.focusedSeparatorLiterals.joined()
        for segment in current.suffixSegments.prefix(suffixIndex) {
            preceding += segment.committedText
        }
        let request = SemanticInferenceRequest(
            requestID: UUID().uuidString,
            token: current.token,
            contextPolicy: policy,
            context: batch.contextProvider(policy) + preceding,
            pinyin: segmentPinyin,
            candidates: candidates,
            deadlineMilliseconds: Self.localDeadlineMilliseconds,
            allowSentence: false,
            segments: nil,
            domain: dependencies.domainForBundle(batch.bundleIdentifier)
        )
        let step = SuffixRefinementStep(
            requestID: request.requestID,
            candidates: candidates,
            suffixIndex: suffixIndex,
            requestToken: current.token,
            nextOffset: offset + 1
        )
        pendingSuffixRefinementRequestIDs.insert(request.requestID)
        dependencies.sendLocalInference(request) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finishSuffixRefinementStep(
                    result,
                    step: step,
                    batch: batch
                )
            }
        }
    }

    private func finishSuffixRefinementStep(
        _ result: SemanticInferenceResult?,
        step: SuffixRefinementStep,
        batch: SuffixRefinementBatch
    ) {
        pendingSuffixRefinementRequestIDs.remove(step.requestID)
        guard let result,
              result.status == "ok",
              result.matches(step.requestToken)
        else {
            // daemon 失败/过期：整批作废（下一次定稿事件重新调度），
            // 避免对不可用链路继续打满整批请求。
            return
        }
        guard let ranked = result.rankedCandidate,
              step.candidates.contains(ranked),
              let sanitized = SemanticCandidateScriptPolicy.sanitized(
                  text: ranked,
                  characterSet: dependencies.characterSet()
              )
        else {
            // 无有效重排：跳过该段继续推进剩余段。
            runSuffixRefinementStep(batch: batch, offset: step.nextOffset)
            return
        }
        let current = composition
        guard current.suffixSegments.indices.contains(step.suffixIndex),
              case let .committedPinyin(_, existing) =
              current.suffixSegments[step.suffixIndex]
        else {
            return
        }
        if sanitized != existing {
            guard batch.applyRefinedText(
                step.suffixIndex,
                sanitized,
                step.requestToken
            ) else {
                // 用户编辑抢先使 token 失效：整批作废。
                return
            }
        }
        runSuffixRefinementStep(batch: batch, offset: step.nextOffset)
    }
}
