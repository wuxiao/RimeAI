import AppKit
import Carbon

/// 语义建议流水线的进程侧接线：把 Carbon/单例/历史服务作为
/// 闭包依赖注入 InputCore，并转发流水线事件到设置存储与 UI。
extension RimeAIInputController {
    /// All IMK-process side effects the pipeline needs, injected as
    /// closures so InputCore stays free of Carbon and singletons.
    func makeSuggestionPipeline() -> SemanticSuggestionPipeline {
        let pipeline = SemanticSuggestionPipeline(
            dependencies: SemanticSuggestionDependencies(
                now: { ProcessInfo.processInfo.systemUptime },
                scheduling: DispatchQueueSemanticSuggestionScheduling(),
                isSecureEventInputEnabled: { IsSecureEventInputEnabled() },
                isLocalInferenceAllowed: { [settings] bundleIdentifier in
                    settings.isAIAllowed(for: bundleIdentifier)
                },
                isCloudConfigured: { [settings] in
                    settings.cloudConfigured
                },
                contextPolicy: { [settings] bundleIdentifier in
                    settings.contextPolicy(for: bundleIdentifier)
                },
                cloudModelID: { [settings] in
                    let preferred = settings.cloudModelID
                    let resolved = CloudBrokerClient.shared
                        .resolvedModelID(for: preferred)
                    if resolved != preferred {
                        settings.record(.modelDowngraded)
                    }
                    return resolved
                },
                characterSet: { [settings] in
                    settings.characterSet
                },
                domainForBundle: { bundleIdentifier in
                    RimeAIPhraseBookService.shared.domain(
                        forBundleIdentifier: bundleIdentifier
                    )
                },
                sendLocalInference: Self.makeDaemonSendClosure(
                    controller: self
                ),
                cancelLocalInference: { requestID in
                    DaemonClient.shared.cancel(requestID: requestID)
                },
                rimeCandidates: { pinyin in
                    RimeEngine.shared.candidates(for: pinyin, limit: 10)
                },
                clientSessionID: sessionNonce,
                loadCloudAPIKey: {
                    try? FileCloudCredentialStore.shared.loadAPIKey()
                },
                cloudHistorySnapshot: { pinyin in
                    try? RimeAIHistoryService.shared.contextSnapshot(
                        query: pinyin,
                        maxRecentCharacters: 600,
                        maximumSnippetCount: 8
                    )
                },
                currentHistoryGeneration: {
                    try? RimeAIHistoryService.shared.statistics().generation
                },
                phraseBookPhrases: { pinyin, bundleIdentifier in
                    RimeAIPhraseBookService.shared.phrases(
                        matchingPinyin: pinyin,
                        bundleIdentifier: bundleIdentifier
                    )
                },
                sendCloudInference: { request, apiKey, completion in
                    CloudBrokerClient.shared.infer(
                        request,
                        apiKey: apiKey,
                        completion: completion
                    )
                },
                cancelCloudInference: { requestID in
                    CloudBrokerClient.shared.cancel(requestID: requestID)
                },
                disconnectCloud: {
                    CloudBrokerClient.shared.disconnect()
                },
                sendSentenceFeedback: { requestID, outcome in
                    DaemonClient.shared.sendSentenceFeedback(
                        requestID: requestID,
                        outcome: outcome
                    )
                },
                sendCloudFeedback: { requestID, outcome in
                    CloudBrokerClient.shared.sendSentenceFeedback(
                        requestID: requestID,
                        outcome: outcome
                    )
                },
                compositionSnapshot: { [weak self] in
                    self?.composition
                        ?? CompositionState(appSessionID: "inactive")
                },
                applySemanticCandidate: { [weak self] text, token, decision, segments in
                    self?.composition.applySemanticCandidate(
                        text,
                        token: token,
                        decision: decision,
                        segments: segments
                    ) ?? false
                },
                onEvent: { [weak self] event in
                    self?.handlePipelineEvent(event)
                }
            )
        )
        return pipeline
    }

    /// 本地推断发送闭包：随发送登记迟到帧路由（reveal A-F1：按
    /// requestID 路由到发起请求的 pipeline，帧到时一次性取回，
    /// 不再依赖被最新 controller init 覆盖的单例单槽）。控制器在
    /// init 尾部才把 pipeline 存入属性，故经 self 间接取用。
    private static func makeDaemonSendClosure(
        controller: RimeAIInputController
    ) -> (
        SemanticInferenceRequest,
        @escaping @Sendable (SemanticInferenceResult?) -> Void
    ) -> Void {
        { [weak controller] request, completion in
            if request.allowSentence,
               let pipeline = controller?.pipeline {
                DaemonClient.shared.registerSentenceLateRoute(
                    requestID: request.requestID
                ) { frame in
                    pipeline.applyNeuralSentenceLate(frame)
                }
            }
            DaemonClient.shared.infer(
                request,
                completion: completion
            )
        }
    }

    /// Forward the pipeline's diagnostic stream to the settings store and
    /// run its two UI-side effects on the controller side.
    func handlePipelineEvent(
        _ event: SemanticSuggestionPipelineEvent
    ) {
        switch event {
        case let .diagnostic(metric):
            settings.record(metric)
        case let .latency(milliseconds):
            settings.recordLatency(milliseconds: milliseconds)
        case .secureInputDetected:
            enterSecureInputIfPossible()
        case .suggestionSlotChanged:
            refreshCandidatePanelIfActive()
        }
    }
}
