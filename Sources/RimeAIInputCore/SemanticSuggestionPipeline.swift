import Foundation

// MARK: - Scheduling & cancellation seams

/// A cancellable main-queue task handed out by a scheduler when the
/// pipeline arms a debounce timer.
public protocol SemanticSuggestionTask: Sendable {
    func cancel()
}

/// Execution seam for the pipeline's timers and queue hops. Production
/// uses libdispatch; tests drive a manual queue. Debounce delays are
/// forwarded verbatim so the historic 100 ms local / 1000 ms cloud
/// timings survive the extraction byte for byte.
public protocol SemanticSuggestionScheduling: Sendable {
    /// Run `action` on the main thread after `delay` seconds and return a
    /// handle that can cancel it before it fires.
    func scheduleOnMain(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any SemanticSuggestionTask

    /// Run `action` off the main thread (credential load / history
    /// snapshot).
    func dispatchOffMain(_ action: @escaping @Sendable () -> Void)

    /// Hop back to the main actor from a background block.
    func dispatchOnMain(_ action: @escaping @MainActor () -> Void)
}

/// libdispatch-backed scheduler used by the input method process.
public struct DispatchQueueSemanticSuggestionScheduling:
    SemanticSuggestionScheduling
{
    public init() {}

    private final class DispatchWorkItemTask:
        SemanticSuggestionTask, @unchecked Sendable
    {
        private let lock = NSLock()
        private var workItem: DispatchWorkItem?

        init(_ workItem: DispatchWorkItem) {
            self.workItem = workItem
        }

        func cancel() {
            lock.withLock {
                workItem?.cancel()
            }
        }
    }

    public func scheduleOnMain(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any SemanticSuggestionTask {
        let workItem = DispatchWorkItem {
            MainActor.assumeIsolated {
                action()
            }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
        return DispatchWorkItemTask(workItem)
    }

    public func dispatchOffMain(_ action: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: action)
    }

    public func dispatchOnMain(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                action()
            }
        }
    }
}

// MARK: - Diagnostics event stream

/// Everything the pipeline needs to tell its host about, as a single
/// stream. The IMK controller forwards diagnostics to
/// `RimeAISettingsStore.record`, latency samples to `recordLatency`, and
/// reacts to the two UI-side effects itself.
public enum SemanticSuggestionPipelineEvent: Sendable {
    case diagnostic(RimeAIDiagnosticEvent)
    case latency(milliseconds: Double)
    /// Secure input became active while a result was in flight; the host
    /// must enter its secure-input mode.
    case secureInputDetected
    /// The visible suggestion slot changed (or cloud-in-flight state
    /// flipped); the host should refresh the candidate panel if visible.
    case suggestionSlotChanged
}

// MARK: - Injected dependencies

/// All side effects the pipeline needs from the IMK process. InputCore
/// itself must not import Carbon or reach singletons, so the controller
/// injects closures over `DaemonClient`, `CloudBrokerClient`,
/// `FileCloudCredentialStore`, `RimeAIHistoryService`,
/// `IsSecureEventInputEnabled`, and the live `CompositionState`.
public struct SemanticSuggestionDependencies: Sendable {
    /// Wall-clock uptime in seconds. Production uses
    /// `ProcessInfo.processInfo.systemUptime`.
    public var now: @Sendable () -> TimeInterval
    public var scheduling: any SemanticSuggestionScheduling
    /// Carbon `IsSecureEventInputEnabled()` bridged by the host process.
    public var isSecureEventInputEnabled: @Sendable () -> Bool

    // Settings reads (RimeAISettingsStore is thread-safe).
    public var isLocalInferenceAllowed:
        @Sendable (_ bundleIdentifier: String) -> Bool
    public var isCloudConfigured: @Sendable () -> Bool
    public var contextPolicy:
        @Sendable (_ bundleIdentifier: String) -> ContextPolicy
    public var cloudModelID: @Sendable () -> String
    public var characterSet: @Sendable () -> RimeAICharacterSetPreference

    // Local daemon transport.
    public var sendLocalInference: @Sendable (
        _ request: SemanticInferenceRequest,
        _ completion: @escaping @Sendable (SemanticInferenceResult?) -> Void
    ) -> Void
    public var cancelLocalInference: @Sendable (_ requestID: String) -> Void

    // Cloud transport and request assembly.
    public var clientSessionID: String
    public var loadCloudAPIKey: @Sendable () -> String?
    public var cloudHistorySnapshot:
        @Sendable (_ query: String) -> HistoryContextSnapshot?
    public var currentHistoryGeneration: @Sendable () -> Int64?

    // L1 phrasebook (LP-006): fills the suggestion slot only when both
    // the local and cloud channels yielded no suggestion for the cycle.
    public var phraseBookPhrases: @Sendable (
        _ pinyin: String,
        _ bundleIdentifier: String
    ) -> [PhraseBookEntry]
    public var sendCloudInference: @Sendable (
        _ request: CloudInferenceRequest,
        _ apiKey: String,
        _ completion: @escaping @Sendable (CloudInferenceResponse?) -> Void
    ) -> Void
    public var cancelCloudInference: @Sendable (_ requestID: String) -> Void
    public var disconnectCloud: @Sendable () -> Void

    // Live composition state (value snapshot per read) and the single
    // mutation the pipeline performs on it.
    public var compositionSnapshot: @MainActor @Sendable () -> CompositionState
    public var applySemanticCandidate: @MainActor @Sendable (
        _ candidate: String,
        _ token: CompositionToken,
        _ decision: SemanticInferenceDecision,
        _ segments: [PinyinSegment]?
    ) -> Bool

    public var onEvent: (@MainActor @Sendable (SemanticSuggestionPipelineEvent) -> Void)?

    public init(
        now: @escaping @Sendable () -> TimeInterval,
        scheduling: any SemanticSuggestionScheduling,
        isSecureEventInputEnabled: @escaping @Sendable () -> Bool,
        isLocalInferenceAllowed: @escaping @Sendable (String) -> Bool,
        isCloudConfigured: @escaping @Sendable () -> Bool,
        contextPolicy: @escaping @Sendable (String) -> ContextPolicy,
        cloudModelID: @escaping @Sendable () -> String,
        characterSet: @escaping @Sendable () -> RimeAICharacterSetPreference,
        sendLocalInference: @escaping @Sendable (
            SemanticInferenceRequest,
            @escaping @Sendable (SemanticInferenceResult?) -> Void
        ) -> Void,
        cancelLocalInference: @escaping @Sendable (String) -> Void,
        clientSessionID: String,
        loadCloudAPIKey: @escaping @Sendable () -> String?,
        cloudHistorySnapshot: @escaping @Sendable (String) -> HistoryContextSnapshot?,
        currentHistoryGeneration: @escaping @Sendable () -> Int64?,
        phraseBookPhrases: @escaping @Sendable (
            String,
            String
        ) -> [PhraseBookEntry] = { _, _ in [] },
        sendCloudInference: @escaping @Sendable (
            CloudInferenceRequest,
            String,
            @escaping @Sendable (CloudInferenceResponse?) -> Void
        ) -> Void,
        cancelCloudInference: @escaping @Sendable (String) -> Void,
        disconnectCloud: @escaping @Sendable () -> Void,
        compositionSnapshot: @escaping @MainActor @Sendable () -> CompositionState,
        applySemanticCandidate: @escaping @MainActor @Sendable (
            String,
            CompositionToken,
            SemanticInferenceDecision,
            [PinyinSegment]?
        ) -> Bool,
        onEvent: (@MainActor @Sendable (SemanticSuggestionPipelineEvent) -> Void)?
    ) {
        self.now = now
        self.scheduling = scheduling
        self.isSecureEventInputEnabled = isSecureEventInputEnabled
        self.isLocalInferenceAllowed = isLocalInferenceAllowed
        self.isCloudConfigured = isCloudConfigured
        self.contextPolicy = contextPolicy
        self.cloudModelID = cloudModelID
        self.characterSet = characterSet
        self.sendLocalInference = sendLocalInference
        self.cancelLocalInference = cancelLocalInference
        self.clientSessionID = clientSessionID
        self.loadCloudAPIKey = loadCloudAPIKey
        self.cloudHistorySnapshot = cloudHistorySnapshot
        self.currentHistoryGeneration = currentHistoryGeneration
        self.phraseBookPhrases = phraseBookPhrases
        self.sendCloudInference = sendCloudInference
        self.cancelCloudInference = cancelCloudInference
        self.disconnectCloud = disconnectCloud
        self.compositionSnapshot = compositionSnapshot
        self.applySemanticCandidate = applySemanticCandidate
        self.onEvent = onEvent
    }
}

// MARK: - Pipeline

/// Deep module owning the semantic suggestion lifecycle: dual debounce
/// (100 ms local / 1000 ms cloud), request gating, latest-request-wins
/// stale rejection, the frozen cloud guard ladder (secure input →
/// composition token/isSelecting → history generation → deadline →
/// structural validation), and cloud-over-local arbitration where a
/// valid cloud decision owns the single suggestion slot and a cloud
/// failure never overwrites a local success (arbitration decision
/// 2026-08-16). The IMK controller is a thin adapter supplying closures.
@MainActor
public final class SemanticSuggestionPipeline: @unchecked Sendable {
    public static let localDebounceInterval: TimeInterval = 0.1
    public static let cloudDebounceInterval: TimeInterval = 1.0
    public static let localDeadlineMilliseconds = 400
    public static let cloudWallClockDeadline: TimeInterval = 30.0

    private let dependencies: SemanticSuggestionDependencies

    // Orchestration state (was: RimeAIInputController fields).
    private var localDebounceTask: (any SemanticSuggestionTask)?
    private var cloudDebounceTask: (any SemanticSuggestionTask)?
    private var pendingRequestID: String?
    private var pendingRequestStartedAt: TimeInterval?
    // Segment layout of the in-flight local request, consumed by
    // `applyLocalResult` for cross-punctuation sentence validation.
    private var pendingRequestSegments: [PinyinSegment]?
    private var pendingCloudRequestID: String?

    // L1 phrasebook fallback (LP-006): the composition context the fill
    // is anchored to, plus whether the cloud channel for this cycle may
    // still claim the slot.
    private struct PhraseBookSlotContext {
        let pinyin: String
        let bundleIdentifier: String
        let token: CompositionToken
    }

    private var phraseContext: PhraseBookSlotContext?
    private var cloudCyclePending = false

    // The visible suggestion slot, read by the controller for rendering
    // and commit attribution.
    public private(set) var presentation: SemanticCandidatePresentation =
        .idle
    public private(set) var historySource: HistoryCommitSource =
        .localSemantic
    public private(set) var cloudCandidate: CloudCandidate?
    public private(set) var mixedCompositionSuggestion:
        MixedCompositionSuggestion?
    public private(set) var cloudSuggestionApplied = false
    public private(set) var contextCharacterCount = 0
    public private(set) var cloudInFlight = false

    public var hasPendingCloudRequest: Bool {
        pendingCloudRequestID != nil
    }

    public init(dependencies: SemanticSuggestionDependencies) {
        self.dependencies = dependencies
    }

    private var composition: CompositionState {
        dependencies.compositionSnapshot()
    }

    private func emit(_ event: SemanticSuggestionPipelineEvent) {
        dependencies.onEvent?(event)
    }

    // MARK: Slot lifecycle (driven by composition edits)

    /// A fresh input cycle starts: reset commit attribution to local and
    /// drop any cloud/mixed suggestion carried over from the previous
    /// keystroke.
    public func beginInputCycle() {
        mixedCompositionSuggestion = nil
        historySource = .localSemantic
        cloudCandidate = nil
        cloudSuggestionApplied = false
        phraseContext = nil
        cloudCyclePending = false
    }

    /// No candidates and no mixed suggestion: collapse the slot to the
    /// explicit "unavailable" presentation.
    public func markUnavailable() {
        presentation = .unavailable
        contextCharacterCount = 0
    }

    /// Rime 无候选时解析出的混输结果：由控制器作为普通主候选展示，
    /// 这里仅登记建议与决策供提交路径复用，不占用语义建议槽、不显示
    /// 中英混输专属提示。返回 false（槽位未动）时语义与
    /// `presentMixedComposition` 的失败分支一致。
    @discardableResult
    public func trackMixedSuggestionAsMainCandidate(
        _ suggestion: MixedCompositionSuggestion,
        token: CompositionToken
    ) -> Bool {
        guard dependencies.applySemanticCandidate(
            suggestion.text,
            token,
            .mixedComposition,
            nil
        ) else {
            return false
        }
        mixedCompositionSuggestion = suggestion
        presentation = .idle
        contextCharacterCount = 0
        emit(.diagnostic(.mixedCompositionShown))
        return true
    }

    /// Show the mixed-composition suggestion as the slot's candidate.
    /// Returns false (untouched slot) when the composition refuses the
    /// candidate, matching the controller's original fall-through into
    /// the analyzing path.
    @discardableResult
    public func presentMixedComposition(
        _ suggestion: MixedCompositionSuggestion,
        token: CompositionToken
    ) -> Bool {
        guard dependencies.applySemanticCandidate(
            suggestion.text,
            token,
            .mixedComposition,
            nil
        ) else {
            return false
        }
        mixedCompositionSuggestion = suggestion
        presentation = .candidate(
            text: suggestion.text,
            decision: .mixedComposition,
            confidence: suggestion.confidence
        )
        contextCharacterCount = 0
        emit(.diagnostic(.resultShown))
        emit(.diagnostic(.mixedCompositionShown))
        return true
    }

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
                segments: segments
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

    /// 击键停顿 1000 ms 后才发云端请求：latest-request-wins 下连续击键
    /// 期间发出的云端请求必然被下一次击键取消，只会白白消耗一次 LLM
    /// 往返；等停顿再发，大模型结果才有机会真正到达候选面板。
    private func scheduleCloudInference(
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

    private func sendInference(
        _ request: SemanticInferenceRequest,
        token: CompositionToken
    ) {
        let requestID = request.requestID
        pendingRequestID = requestID
        pendingRequestSegments = request.segments
        pendingRequestStartedAt = dependencies.now()
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

    private func buildAndSendCloudInference(
        pinyin: String,
        bundleIdentifier: String,
        token: CompositionToken,
        localRequestWasScheduled: Bool
    ) {
        let dependencies = dependencies
        let requestID = UUID().uuidString
        let startedAt = dependencies.now()
        let deadlineAt = startedAt + Self.cloudWallClockDeadline
        let modelID = dependencies.cloudModelID()
        let clientSessionID = dependencies.clientSessionID
        // 构造请求前从组合状态再取一次段布局：调度与击键之间的
        // 竞态由这里的最新快照与主线程 guard 共同兜住。
        let segments = composition.inferenceSegments
        pendingCloudRequestID = requestID
        dependencies.scheduling.dispatchOffMain { [weak self] in
            let apiKey = dependencies.loadCloudAPIKey()
            guard let apiKey,
                  !apiKey.isEmpty,
                  apiKey.utf8.count <= 512
            else {
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
            let historySnapshot = dependencies.cloudHistorySnapshot(pinyin)
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
                requestID: requestID,
                token: token,
                bundleIdentifier: bundleIdentifier,
                clientSessionID: clientSessionID,
                modelID: modelID,
                deadlineMilliseconds: remainingMilliseconds,
                pinyin: pinyin,
                recentContext: historySnapshot?.recentText ?? "",
                historySnippets: historySnapshot?.relevantSnippets ?? [],
                historyGeneration: historySnapshot?.generation ?? 0,
                segments: segments
            )
            dependencies.scheduling.dispatchOnMain {
                guard let self,
                      self.pendingCloudRequestID == requestID
                else {
                    return
                }
                let compositionStillCurrent = self.composition.token == token
                    && !self.composition.isSelecting
                    && !self.composition.isSecureInput
                    && !dependencies.isSecureEventInputEnabled()
                guard compositionStillCurrent,
                      dependencies.now() <= deadlineAt,
                      request.isValid
                else {
                    self.pendingCloudRequestID = nil
                    // Withdrawal reason must match reality: a superseded
                    // composition is stale, a missed deadline is a
                    // timeout, a request that fails client-side
                    // structural validation was never sendable.
                    if !compositionStillCurrent {
                        self.emit(.diagnostic(.staleResult))
                    } else if dependencies.now() > deadlineAt {
                        self.emit(.diagnostic(.cloudTimeout))
                    } else {
                        self.emit(.diagnostic(.cloudInvalidRequest))
                    }
                    if compositionStillCurrent {
                        self.applyCloudFallback(
                            localRequestWasScheduled:
                                localRequestWasScheduled,
                            decision: nil
                        )
                    }
                    return
                }
                self.emit(.diagnostic(.cloudRequestStarted))
                self.cloudInFlight = true
                self.emit(.suggestionSlotChanged)
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
                            localRequestWasScheduled:
                                localRequestWasScheduled
                        )
                    }
                }
            }
        }
    }

    // MARK: Result application

    /// Apply a local daemon result. Guard ladder: pending request id →
    /// secure input → cloud ownership → status/token/structure. After the
    /// ladder resolves, an empty slot may still be filled by the L1
    /// phrasebook fallback.
    public func applyInferenceResult(
        _ result: SemanticInferenceResult?,
        requestID: String,
        token: CompositionToken
    ) {
        applyLocalResult(result, requestID: requestID, token: token)
        tryPhraseBookFill()
    }

    private func applyLocalResult(
        _ result: SemanticInferenceResult?,
        requestID: String,
        token: CompositionToken
    ) {
        guard pendingRequestID == requestID else {
            emit(.diagnostic(.staleResult))
            return
        }
        pendingRequestID = nil
        let requestSegments = pendingRequestSegments
        pendingRequestSegments = nil
        if let pendingRequestStartedAt {
            emit(.latency(milliseconds: max(
                0,
                (
                    dependencies.now()
                        - pendingRequestStartedAt
                ) * 1_000
            )))
        }
        pendingRequestStartedAt = nil
        guard !dependencies.isSecureEventInputEnabled() else {
            emit(.secureInputDetected)
            return
        }
        if cloudSuggestionApplied {
            // A valid cloud decision owns the single explicit suggestion
            // slot.
            return
        }
        guard let result else {
            emit(.diagnostic(.daemonFailure))
            presentation = .failure
            emit(.suggestionSlotChanged)
            return
        }
        guard result.status == "ok" else {
            if result.status == "timeout" {
                emit(.diagnostic(.timeout))
            } else if result.status == "circuit_open" {
                emit(.diagnostic(.circuitOpen))
            } else {
                emit(.diagnostic(.daemonFailure))
            }
            presentation = .failure
            emit(.suggestionSlotChanged)
            return
        }
        guard result.matches(token) else {
            emit(.diagnostic(.staleResult))
            presentation = .idle
            emit(.suggestionSlotChanged)
            return
        }
        guard result.isValid(
            for: token,
            candidates: composition.mainCandidates,
            segments: requestSegments
        ) else {
            emit(.diagnostic(.invalidResult))
            presentation = .failure
            emit(.suggestionSlotChanged)
            return
        }
        let candidatePresentation = result.candidatePresentation(
            characterSet: dependencies.characterSet()
        )
        presentation = candidatePresentation
        switch candidatePresentation {
        case .sameTopCandidate:
            emit(.diagnostic(.sameTopCandidate))
            emit(.suggestionSlotChanged)
            return
        case .insufficientCandidates:
            emit(.diagnostic(.insufficientCandidates))
            emit(.suggestionSlotChanged)
            return
        case .belowConfidence:
            emit(.diagnostic(.belowConfidence))
            emit(.suggestionSlotChanged)
            return
        case .noCandidate:
            emit(.diagnostic(.noCandidate))
            emit(.suggestionSlotChanged)
            return
        case .sentenceTooLong:
            emit(.diagnostic(.sentenceTooLong))
            emit(.suggestionSlotChanged)
            return
        case .sentenceIncomplete:
            emit(.diagnostic(.sentenceIncomplete))
            emit(.suggestionSlotChanged)
            return
        case .scriptMismatch:
            // 字形不符不再静默丢弃：就地转换为用户设置的字形后照常
            // 展示（繁体整句转简体），仅无法转换时才拒绝。
            if let decision = result.resolvedDecision,
               let sanitized = SemanticCandidateScriptPolicy.sanitized(
                   text: result.displayCandidate,
                   characterSet: dependencies.characterSet()
               ),
               dependencies.applySemanticCandidate(
                   sanitized,
                   token,
                   decision,
                   requestSegments
               )
            {
                presentation = .candidate(
                    text: sanitized,
                    decision: decision,
                    confidence: result.confidence ?? 0
                )
                historySource = .localSemantic
                cloudCandidate = nil
                emit(.diagnostic(.resultShown))
                emit(.suggestionSlotChanged)
                return
            }
            emit(.diagnostic(.sentenceScriptMismatch))
            emit(.suggestionSlotChanged)
            return
        case .idle,
             .analyzing,
             .cloudAnalyzing,
             .cloudSameTopCandidate,
             .cloudBelowConfidence,
             .cloudFailure,
             .continuation,
             .unavailable,
             .failure:
            emit(.diagnostic(.invalidResult))
            presentation = .failure
            emit(.suggestionSlotChanged)
            return
        case .candidate:
            break
        case .inputTooLong:
            emit(.diagnostic(.inputTooLong))
            emit(.suggestionSlotChanged)
            return
        }
        let candidate = result.displayCandidate
        guard let decision = result.resolvedDecision else {
            emit(.diagnostic(.invalidResult))
            presentation = .failure
            emit(.suggestionSlotChanged)
            return
        }
        guard !candidate.isEmpty,
              !candidate.contains("\n"),
              dependencies.applySemanticCandidate(
                  candidate,
                  token,
                  decision,
                  requestSegments
              )
        else {
            emit(.diagnostic(.invalidResult))
            presentation = .failure
            emit(.suggestionSlotChanged)
            return
        }
        historySource = .localSemantic
        cloudCandidate = nil
        emit(.diagnostic(.resultShown))
        if decision == .sentenceSuggestion {
            emit(.diagnostic(.sentenceSuggestionShown))
        } else {
            emit(.diagnostic(.rankedCandidateShown))
        }
        emit(.suggestionSlotChanged)
    }

    /// Apply a cloud result. The guard ladder is frozen (arbitration
    /// decision 2026-08-16): request id → secure input → composition
    /// token/isSelecting/isSecureInput → history generation → deadline →
    /// structural validation.
    public func applyCloudInferenceResult(
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
    private func applyCloudFallback(
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
    private func tryPhraseBookFill() {
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

    // MARK: Invalidation

    /// Cancel everything in flight: both debounces, the pending local
    /// request, and the pending cloud request.
    /// `clearPresentation == true` additionally resets the slot to idle
    /// (used on reset / secure input / session switch).
    public func invalidate(clearPresentation: Bool = false) {
        localDebounceTask?.cancel()
        localDebounceTask = nil
        cloudDebounceTask?.cancel()
        cloudDebounceTask = nil
        cloudInFlight = false
        if let pendingRequestID {
            dependencies.cancelLocalInference(pendingRequestID)
            emit(.diagnostic(.requestCancelled))
            self.pendingRequestID = nil
        }
        if let pendingCloudRequestID {
            dependencies.cancelCloudInference(pendingCloudRequestID)
            self.pendingCloudRequestID = nil
        }
        pendingRequestStartedAt = nil
        pendingRequestSegments = nil
        if clearPresentation {
            presentation = .idle
            contextCharacterCount = 0
            historySource = .localSemantic
            cloudCandidate = nil
            cloudSuggestionApplied = false
            mixedCompositionSuggestion = nil
            phraseContext = nil
            cloudCyclePending = false
        }
    }
}
