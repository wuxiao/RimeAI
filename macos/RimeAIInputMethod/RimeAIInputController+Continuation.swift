import AppKit
import InputMethodKit

/// 上屏后续写联想的进程侧接线：协调器装配、事件到 UI 的转发，
/// 以及续写 chip 的提交路径（不经 commitText，无组合可重置）。
extension RimeAIInputController {
    func makeContinuationCoordinator() -> PostCommitContinuationCoordinator {
        PostCommitContinuationCoordinator(
            dependencies: PostCommitContinuationDependencies(
                now: { ProcessInfo.processInfo.systemUptime },
                scheduling: DispatchQueueSemanticSuggestionScheduling(),
                isSecureEventInputEnabled: { IsSecureEventInputEnabled() },
                isContinuationEnabled: { [settings] in
                    settings.continuationSuggestionEnabled
                        && settings.aiEnabled
                        && settings.cloudConfigured
                },
                isAIAllowed: { [settings] bundleIdentifier in
                    settings.isAIAllowed(for: bundleIdentifier)
                },
                contextPolicy: { [settings] bundleIdentifier in
                    settings.contextPolicy(for: bundleIdentifier)
                },
                loadCloudAPIKey: {
                    try? FileCloudCredentialStore.shared.loadAPIKey()
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
                clientSessionID: sessionNonce,
                // 续写的相关历史片段留空（query 为空时 snapshot 只回
                // recentText 与 generation）；prompt 侧由 broker 按
                // recent_context 组织。
                cloudHistorySnapshot: { _ in
                    try? RimeAIHistoryService.shared.contextSnapshot(
                        query: "",
                        maxRecentCharacters: 600,
                        maximumSnippetCount: 0
                    )
                },
                sendContinuation: { request, apiKey, completion in
                    CloudBrokerClient.shared.continuation(
                        request,
                        apiKey: apiKey,
                        completion: completion
                    )
                },
                cancelContinuation: { requestID in
                    CloudBrokerClient.shared.cancelContinuation(
                        requestID: requestID
                    )
                },
                compositionIsEmpty: { [weak self] in
                    self?.composition.hasComposition == false
                },
                compositionIsSelecting: { [weak self] in
                    self?.composition.isSelecting ?? false
                },
                onEvent: { [weak self] event in
                    self?.handleContinuationEvent(event)
                }
            )
        )
    }

    func handleContinuationEvent(_ event: PostCommitContinuationEvent) {
        switch event {
        case let .showSuggestion(text):
            guard let anchor = continuationAnchorRect else {
                return
            }
            candidatePanel.showContinuation(text, anchor: anchor) {
                [weak self] in
                self?.acceptContinuationSuggestion(text)
            }
        case .hideSuggestion:
            if candidatePanel.isShowingContinuation {
                candidatePanel.hide()
            }
            continuationAnchorRect = nil
        case let .diagnostic(metric):
            settings.record(metric)
        }
    }

    /// commitText 成功路径末尾调用：快照光标锚点并 arm 协调器。
    func armContinuationAfterCommit(
        committedText: String,
        client: any IMKTextInput
    ) {
        continuationAnchorRect = cursorAnchorRect(
            client: client,
            characterIndex: 0
        )
        continuationCoordinator.commitDidHappen(
            bundleIdentifier: currentBundleIdentifier
                ?? client.bundleIdentifier()
                ?? "unknown-client",
            committedText: committedText,
            contextProvider: { [weak self] policy in
                self?.inferenceContext(policy: policy, client: client) ?? ""
            }
        )
    }

    /// 点击续写 chip：协调器记接受（含诊断），面板收起，文本上屏并
    /// 链式 arm 下一轮。
    func acceptContinuationSuggestion(_ text: String) {
        continuationCoordinator.acceptCandidate(text)
        if candidatePanel.isShowingContinuation {
            candidatePanel.hide()
        }
        continuationAnchorRect = nil
        guard let client = activeClientObject as? any IMKTextInput else {
            return
        }
        commitContinuation(text, client: client)
    }

    /// 续写提交：直接 insertText（无组合状态），上下文与历史经
    /// recordCommitSideEffects 记账（source 为 .continuation，非
    /// rawPinyin，故总是进上下文）；结束后显式 arm 下一轮链式联想
    /// （同一上下文同一建议由协调器去重拦住）。
    func commitContinuation(_ text: String, client: any IMKTextInput) {
        guard !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            enterSecureInput(client: client)
            return
        }
        let bundleIdentifier = currentBundleIdentifier
            ?? client.bundleIdentifier()
            ?? "unknown-client"
        client.insertText(text, replacementRange: notFoundRange)
        recordCommitSideEffects(
            text: text,
            pinyin: "",
            source: .continuation,
            historyBundleIdentifier: bundleIdentifier,
            contextBundleIdentifier: bundleIdentifier,
            historyWasAllowedBeforeCommit: true
        )
        armContinuationAfterCommit(committedText: text, client: client)
    }
}
