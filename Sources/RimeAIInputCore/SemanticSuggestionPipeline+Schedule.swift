import Foundation

/// 推断调度入口：composition 编辑产生新候选后的本地+云双通道调度，
/// 与本地请求发送。守卫语义与拆分前一致。
extension SemanticSuggestionPipeline {
    // MARK: Scheduling

    /// Entry point after a composition edit produced fresh candidates.
    /// `contextProvider` supplies the inference context for the given
    /// policy (the controller reads its session store / cursor text).
    public func scheduleInference(
        token: CompositionToken,
        bundleIdentifier: String?,
        contextProvider: (ContextPolicy) -> String
    ) {
        presentation = .analyzing
        guard let bundleIdentifier,
              !composition.isSecureInput,
              !dependencies.isSecureEventInputEnabled()
        else {
            presentation = .unavailable
            emit(.diagnostic(.privacyBlocked))
            return
        }
        guard composition.pinyin.count <= 256 else {
            presentation = .inputTooLong
            contextCharacterCount = 0
            return
        }
        let localAllowed = dependencies.isLocalInferenceAllowed(
            bundleIdentifier
        )
        let cloudAllowed = dependencies.isCloudConfigured()
        guard localAllowed || cloudAllowed else {
            presentation = .unavailable
            return
        }
        if !localAllowed, cloudAllowed {
            presentation = .cloudAnalyzing
        }
        let pinyin = composition.pinyin.lowercased()
        // 跨标点段布局随本地请求发送；allowSentence 以各段字母总数
        // 判定，使跨标点整句建议不因活跃段偏短而被闸掉。
        let segments = composition.inferenceSegments
        let sentenceScopePinyin = segments.map { $0.map(\.pinyin).joined() }
            ?? pinyin
        phraseContext = PhraseBookSlotContext(
            pinyin: pinyin,
            bundleIdentifier: bundleIdentifier,
            token: token
        )
        cloudCyclePending = cloudAllowed
        let localRequest: SemanticInferenceRequest?
        if localAllowed {
            let requestID = UUID().uuidString
            let contextPolicy = dependencies.contextPolicy(
                bundleIdentifier
            )
            let context = contextProvider(contextPolicy)
            contextCharacterCount = context.count
            localRequest = SemanticInferenceRequest(
                requestID: requestID,
                token: token,
                contextPolicy: contextPolicy,
                context: context,
                pinyin: pinyin,
                candidates: composition.mainCandidates,
                deadlineMilliseconds: Self.localDeadlineMilliseconds,
                allowSentence: LocalSentenceSuggestionPolicy.allows(
                    pinyin: sentenceScopePinyin,
                    characterSet: dependencies.characterSet()
                ),
                segments: segments,
                domain: dependencies.domainForBundle(bundleIdentifier),
                characterSet: dependencies.characterSet() == .simplified
                    ? "simplified" : nil
            )
        } else {
            localRequest = nil
            contextCharacterCount = 0
        }
        // Local debounce replaces without cancelling: superseded timers
        // self-reject on the live token guard inside, exactly like the
        // controller's DispatchWorkItem did.
        localDebounceTask = dependencies.scheduling.scheduleOnMain(
            after: Self.localDebounceInterval
        ) { [weak self] in
            guard let self,
                  self.composition.token == token,
                  !self.composition.isSelecting,
                  !self.composition.isSecureInput,
                  !self.dependencies.isSecureEventInputEnabled()
            else {
                return
            }
            if let localRequest {
                self.sendInference(localRequest, token: token)
            }
        }
        if cloudAllowed {
            scheduleCloudInference(
                pinyin: pinyin,
                bundleIdentifier: bundleIdentifier,
                token: token,
                localRequestWasScheduled: localRequest != nil
            )
        }
    }

    /// 发送本地推断请求并登记在途槽（latest-request-wins）；同步句
    /// 建议允许时同时登记神经臂迟到帧期望槽。
    private func sendInference(
        _ request: SemanticInferenceRequest,
        token: CompositionToken
    ) {
        let requestID = request.requestID
        pendingRequestID = requestID
        pendingRequestSegments = request.segments
        pendingRequestStartedAt = dependencies.now()
        if request.allowSentence {
            neuralLateRequestID = requestID
            neuralLateToken = token
            neuralLateSegments = request.segments
        } else {
            neuralLateRequestID = nil
            neuralLateToken = nil
            neuralLateSegments = nil
        }
        emit(.diagnostic(.requestStarted))
        dependencies.sendLocalInference(request) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.applyInferenceResult(
                    result,
                    requestID: requestID,
                    token: token
                )
            }
        }
    }
}
