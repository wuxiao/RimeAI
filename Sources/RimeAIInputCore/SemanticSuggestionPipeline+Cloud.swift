import Foundation

/// 云端推理通道：调度防抖、请求装配（off-main）、冻结守卫梯
/// （2026-08-16 仲裁决策）、生成式整句应用与失败兜底。守卫顺序与
/// 展示语义与拆分前逐字节一致。
extension SemanticSuggestionPipeline {
    func scheduleCloudInference(
        pinyin: String,
        bundleIdentifier: String,
        token: CompositionToken,
        localRequestWasScheduled: Bool
    ) {
        cloudDebounceTask?.cancel()
        cloudDebounceTask = dependencies.scheduling.scheduleOnMain(
            after: Self.cloudDebounceInterval
        ) { [weak self] in
            guard let self,
                  self.composition.token == token,
                  !self.composition.isSelecting,
                  !self.composition.isSecureInput,
                  !self.dependencies.isSecureEventInputEnabled()
            else {
                return
            }
            self.buildAndSendCloudInference(
                pinyin: pinyin,
                bundleIdentifier: bundleIdentifier,
                token: token,
                localRequestWasScheduled: localRequestWasScheduled
            )
        }
    }

    private func buildAndSendCloudInference(
        pinyin: String,
        bundleIdentifier: String,
        token: CompositionToken,
        localRequestWasScheduled: Bool
    ) {
        let dependencies = dependencies
        let requestID = UUID().uuidString
        let deadlineAt = dependencies.now() + Self.cloudWallClockDeadline
        // 构造请求前从组合状态再取一次段布局：调度与击键之间的
        // 竞态由这里的最新快照与主线程 guard 共同兜住。
        let seed = CloudRequestSeed(
            requestID: requestID,
            pinyin: pinyin,
            bundleIdentifier: bundleIdentifier,
            token: token,
            segments: composition.inferenceSegments
        )
        pendingCloudRequestID = requestID
        dependencies.scheduling.dispatchOffMain { [weak self] in
            guard let assembled = self?.assembleCloudRequest(
                seed: seed,
                deadlineAt: deadlineAt
            ) else {
                dependencies.scheduling.dispatchOnMain {
                    guard let self,
                          self.pendingCloudRequestID == requestID
                    else {
                        return
                    }
                    self.pendingCloudRequestID = nil
                    self.emit(.diagnostic(.cloudTransportFailure))
                    self.applyCloudFallback(
                        localRequestWasScheduled: localRequestWasScheduled,
                        decision: nil
                    )
                    dependencies.disconnectCloud()
                }
                return
            }
            dependencies.scheduling.dispatchOnMain { [weak self] in
                guard let self else {
                    return
                }
                self.dispatchValidatedCloudRequest(
                    assembled.request,
                    apiKey: assembled.apiKey,
                    token: token,
                    deadlineAt: deadlineAt,
                    localRequestWasScheduled: localRequestWasScheduled
                )
            }
        }
    }

    /// 云端请求身份字段（off-main 装配的入参包）。
    private struct CloudRequestSeed: Sendable {
        let requestID: String
        let pinyin: String
        let bundleIdentifier: String
        let token: CompositionToken
        let segments: [PinyinSegment]?
    }

    /// 云端请求装配（off-main）：读 Key、历史快照与剩余 deadline。
    /// Key 缺失或超长时返回 nil（调用方走 transport failure 兜底）。
    /// 只触碰 Sendable 的 dependencies，故 nonisolated。
    private nonisolated func assembleCloudRequest(
        seed: CloudRequestSeed,
        deadlineAt: TimeInterval
    ) -> (request: CloudInferenceRequest, apiKey: String)? {
        let apiKey = dependencies.loadCloudAPIKey()
        guard let apiKey,
              !apiKey.isEmpty,
              apiKey.utf8.count <= 512
        else {
            return nil
        }
        let historySnapshot = dependencies.cloudHistorySnapshot(seed.pinyin)
        // 网络层不再设软上限：拼音拼出有把握的中文通常几秒完成，
        // 长拼音/复杂整句建议需要更久。协议 clamp（30000ms，本地
        // 开发调试放宽）仍保留着作最后保险，墙钟 deadlineAt 与之
        // 对齐，只在 envelope 接近超时后才截断（broker/客户端共
        // 享同一 deadline）。
        let remainingMilliseconds = max(
            1,
            Int(
                (
                    deadlineAt
                        - dependencies.now()
                ) * 1_000
            )
        )
        let request = CloudInferenceRequest(
            requestID: seed.requestID,
            token: seed.token,
            bundleIdentifier: seed.bundleIdentifier,
            clientSessionID: dependencies.clientSessionID,
            modelID: dependencies.cloudModelID(),
            deadlineMilliseconds: remainingMilliseconds,
            pinyin: seed.pinyin,
            recentContext: historySnapshot?.recentText ?? "",
            historySnippets: historySnapshot?.relevantSnippets ?? [],
            historyGeneration: historySnapshot?.generation ?? 0,
            segments: seed.segments
        )
        return (request, apiKey)
    }

    /// 装配完成的请求在主线程上过有效性梯后发出；过期/无效的撤回
    /// 理由必须与真实原因一致（stale / timeout / invalid）。
    private func dispatchValidatedCloudRequest(
        _ request: CloudInferenceRequest,
        apiKey: String,
        token: CompositionToken,
        deadlineAt: TimeInterval,
        localRequestWasScheduled: Bool
    ) {
        let dependencies = dependencies
        guard pendingCloudRequestID == request.requestID else {
            return
        }
        let compositionStillCurrent = composition.token == token
            && !composition.isSelecting
            && !composition.isSecureInput
            && !dependencies.isSecureEventInputEnabled()
        guard compositionStillCurrent,
              dependencies.now() <= deadlineAt,
              request.isValid
        else {
            pendingCloudRequestID = nil
            // Withdrawal reason must match reality: a superseded
            // composition is stale, a missed deadline is a
            // timeout, a request that fails client-side
            // structural validation was never sendable.
            if !compositionStillCurrent {
                emit(.diagnostic(.staleResult))
            } else if dependencies.now() > deadlineAt {
                emit(.diagnostic(.cloudTimeout))
            } else {
                emit(.diagnostic(.cloudInvalidRequest))
            }
            if compositionStillCurrent {
                applyCloudFallback(
                    localRequestWasScheduled: localRequestWasScheduled,
                    decision: nil
                )
            }
            return
        }
        emit(.diagnostic(.cloudRequestStarted))
        cloudInFlight = true
        emit(.suggestionSlotChanged)
        dependencies.sendCloudInference(
            request,
            apiKey
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.applyCloudInferenceResult(
                    result,
                    request: request,
                    token: token,
                    deadlineAt: deadlineAt,
                    localRequestWasScheduled: localRequestWasScheduled
                )
            }
        }
    }

    /// Apply a cloud result. The guard ladder is frozen (arbitration
    /// decision 2026-08-16): request id → secure input → composition
    /// token/isSelecting/isSecureInput → history generation → deadline →
    /// structural validation.
    func applyCloudInferenceResult(
        _ result: CloudInferenceResponse?,
        request: CloudInferenceRequest,
        token: CompositionToken,
        deadlineAt: TimeInterval,
        localRequestWasScheduled: Bool
    ) {
        guard pendingCloudRequestID == request.requestID else {
            // 迟到/被替换的响应：计入 stale 而不是无声丢弃。
            emit(.diagnostic(.staleResult))
            return
        }
        pendingCloudRequestID = nil
        cloudInFlight = false
        emit(.suggestionSlotChanged)
        guard !dependencies.isSecureEventInputEnabled() else {
            emit(.secureInputDetected)
            return
        }
        guard composition.token == token,
              !composition.isSelecting,
              !composition.isSecureInput
        else {
            emit(.diagnostic(.staleResult))
            return
        }
        guard dependencies.currentHistoryGeneration()
            == request.historyGeneration
        else {
            emit(.diagnostic(.staleResult))
            return
        }
        guard dependencies.now() <= deadlineAt else {
            emit(.diagnostic(.cloudTimeout))
            applyCloudFallback(
                localRequestWasScheduled: localRequestWasScheduled,
                decision: nil
            )
            return
        }
        guard let result else {
            emit(.diagnostic(.cloudTransportFailure))
            applyCloudFallback(
                localRequestWasScheduled: localRequestWasScheduled,
                decision: nil
            )
            return
        }
        guard result.isValid(for: request) else {
            emit(.diagnostic(.cloudInvalidResult))
            applyCloudFallback(
                localRequestWasScheduled: localRequestWasScheduled,
                decision: nil
            )
            return
        }
        if result.decision == .generate {
            // 响应确实回来了：无论后续展示与否都留下痕迹，避免
            // 生成链路出现无法诊断的静默。
            emit(.diagnostic(.cloudGenerateReceived))
            applyCloudGeneratedResult(
                result,
                request: request,
                token: token,
                localRequestWasScheduled: localRequestWasScheduled
            )
            return
        }
        // 云端仅剩 abstain：无候选建议可上屏，交由兜底展示策略。
        applyCloudFallback(
            localRequestWasScheduled: localRequestWasScheduled,
            decision: result.decision
        )
    }

    /// 云端生成式整句：生成文本已通过客户端结构校验（拼音对齐校验已
    /// 按产品决策移除，文本可超出拼音覆盖并含标点），这里先转换字形
    /// 再处理与首选的重复——重复不再静默，而是明示云端表态，让 AI
    /// 参与始终可见。
    private func applyCloudGeneratedResult(
        _ result: CloudInferenceResponse,
        request: CloudInferenceRequest,
        token: CompositionToken,
        localRequestWasScheduled: Bool
    ) {
        guard let text = result.generatedText,
              let confidence = result.confidence
        else {
            applyCloudFallback(
                localRequestWasScheduled: localRequestWasScheduled,
                decision: .abstain
            )
            return
        }
        // 生成整句可能含繁体字：就地转换到用户字形后再比较与展示。
        guard let renderedText = SemanticCandidateScriptPolicy.sanitized(
            text: text,
            characterSet: dependencies.characterSet()
        ) else {
            emit(.diagnostic(.sentenceScriptMismatch))
            applyCloudFallback(
                localRequestWasScheduled: localRequestWasScheduled,
                decision: .abstain
            )
            return
        }
        // 与 Rime 首选相同：明示"云端与首选一致"而不是静默 keep，
        // 用户在本地无法重排的场景（如完整候选不足）也能看到 AI 表态。
        if renderedText == composition.mainCandidates.first {
            presentation = .cloudSameTopCandidate
            emit(.suggestionSlotChanged)
            return
        }
        // 本地已展示相同文本（典型为本地整句建议先到）：不覆盖。
        if cloudSuggestionApplied,
           case let .candidate(displayed, _, _) = presentation,
           displayed == renderedText
        {
            return
        }
        guard dependencies.applySemanticCandidate(
            renderedText,
            token,
            .sentenceSuggestion,
            request.segments
        ) else {
            emit(.diagnostic(.cloudInvalidResult))
            return
        }
        let candidate = CloudCandidate(
            text: renderedText,
            rimeIndex: nil,
            consumedLength: request.segments?.reduce(0) {
                    $0 + $1.pinyin.unicodeScalars.filter { $0.value != 39 }.count
                }
                // Letter count (apostrophes excluded) keeps the
                // segmented and unsegmented paths consistent.
                ?? request.pinyin.unicodeScalars.filter { $0.value != 39 }
                    .count,
            alignedPinyin: result.generatedPinyin ?? request.pinyin
        )
        historySource = .cloudGenerated
        cloudCandidate = candidate
        cloudSuggestionApplied = true
        presentation = .candidate(
            text: renderedText,
            decision: .sentenceSuggestion,
            confidence: confidence
        )
        contextCharacterCount = request.recentContext.count
            + request.historySnippets.reduce(0) { $0 + $1.text.count }
        emit(.diagnostic(.cloudSuggestionShown))
        emit(.diagnostic(.cloudGeneratedShown))
        emit(.suggestionSlotChanged)
    }

    /// Cloud failure/abstain resolution. A cloud failure must never
    /// overwrite a local success, and an applied cloud decision owns the
    /// slot outright.
    func applyCloudFallback(
        localRequestWasScheduled: Bool,
        decision: CloudInferenceDecision?
    ) {
        cloudCyclePending = false
        guard !cloudSuggestionApplied else {
            return
        }
        let resolved = CloudSemanticPresentationResolver.resolveFallback(
            current: presentation,
            localRequestWasScheduled: localRequestWasScheduled,
            cloudDecision: decision
        )
        if resolved != presentation {
            presentation = resolved
            emit(.suggestionSlotChanged)
        }
        // 本地与云都未给出建议：尝试用 L1 短语兜底填充建议位。
        tryPhraseBookFill()
    }

    // MARK: L1 phrasebook fallback (LP-006)

    /// 仅在本地与云都无建议（且云对本轮已无主张权）时，用拼音匹配的
    /// L1 短语填充独立建议位。只写语义建议槽，数字候选不可移动
    /// （REQ-KBD-02）。
    func tryPhraseBookFill() {
        guard let phraseContext,
              !cloudSuggestionApplied,
              !cloudCyclePending,
              pendingRequestID == nil,
              pendingCloudRequestID == nil,
              composition.token == phraseContext.token,
              !composition.isSelecting,
              !composition.isSecureInput,
              !dependencies.isSecureEventInputEnabled(),
              isPhraseBookEligiblePresentation
        else {
            return
        }
        guard let phrase = dependencies.phraseBookPhrases(
            phraseContext.pinyin,
            phraseContext.bundleIdentifier
        ).first,
              !phrase.text.isEmpty,
              !phrase.text.contains("\n"),
              dependencies.applySemanticCandidate(
                  phrase.text,
                  phraseContext.token,
                  .phraseBook,
                  nil
              )
        else {
            return
        }
        historySource = .phraseBook
        cloudCandidate = nil
        presentation = .candidate(
            text: phrase.text,
            decision: .phraseBook,
            confidence: min(0.95, 0.6 + Double(min(phrase.count, 7)) * 0.05)
        )
        contextCharacterCount = 0
        emit(.diagnostic(.resultShown))
        emit(.diagnostic(.phraseBookSuggestionShown))
        emit(.suggestionSlotChanged)
    }

    /// Slot states that carry no visible suggestion from either channel
    /// and may therefore be filled by a phrasebook hit. Agreement
    /// statements (sameTopCandidate/cloudSameTopCandidate) keep their
    /// explicit AI stance instead.
    private var isPhraseBookEligiblePresentation: Bool {
        switch presentation {
        case .noCandidate,
             .belowConfidence,
             .insufficientCandidates,
             .sentenceTooLong,
             .sentenceIncomplete,
             .scriptMismatch,
             .failure,
             .cloudFailure,
             .cloudBelowConfidence:
            return true
        case .idle,
             .analyzing,
             .candidate,
             .sameTopCandidate,
             .inputTooLong,
             .cloudAnalyzing,
             .cloudSameTopCandidate,
             .continuation,
             .unavailable:
            return false
        }
    }
}
