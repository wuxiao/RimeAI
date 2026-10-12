import AppKit
import Carbon

/// 语义建议流水线的进程侧接线：把 Carbon/单例/历史服务作为
/// 闭包依赖注入 InputCore，并转发流水线事件到设置存储与 UI。
extension RimeAIInputController {
    /// All IMK-process side effects the pipeline needs, injected as
    /// closures so InputCore stays free of Carbon and singletons.
    func makeSuggestionPipeline() -> SemanticSuggestionPipeline {
        SemanticSuggestionPipeline(
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
                sendLocalInference: { request, completion in
                    DaemonClient.shared.infer(
                        request,
                        completion: completion
                    )
                },
                cancelLocalInference: { requestID in
                    DaemonClient.shared.cancel(requestID: requestID)
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
