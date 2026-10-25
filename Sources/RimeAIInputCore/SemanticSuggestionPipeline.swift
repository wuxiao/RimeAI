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
    /// bundle→domain mapping from the phrasebook snapshot (P2-4); the
    /// default keeps requests protocol-compatible with pre-domain daemons.
    public var domainForBundle: @Sendable (_ bundleIdentifier: String) -> String? = { _ in nil }

    // Local daemon transport.
    public var sendLocalInference: @Sendable (
        _ request: SemanticInferenceRequest,
        _ completion: @escaping @Sendable (SemanticInferenceResult?) -> Void
    ) -> Void
    public var cancelLocalInference: @Sendable (_ requestID: String) -> Void
    /// Rime 候选查询（分段向后重推 KBD-006）：控制器桥接进程内
    /// RimeEngine；默认空实现（单测与不启用时零开销）。
    public var rimeCandidates: @Sendable (_ pinyin: String) -> [String] =
        { _ in [] }

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
    /// LM-003 传感层：把用户对已展示建议的裁决发往 daemon 决策日志
    /// （controller 提供；传输层按 daemon capability 门控，默认空实现
    /// ——单测与旧宿主零开销）。
    public var sendSentenceFeedback: @Sendable (
        _ requestID: String,
        _ outcome: String
    ) -> Void = { _, _ in }
    /// LM-003 传感层：云端建议的裁决发往 broker 决策日志
    /// （`cloud-decisions.db` 写穿侧的对应帧）。
    public var sendCloudFeedback: @Sendable (
        _ requestID: String,
        _ outcome: String
    ) -> Void = { _, _ in }

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
        domainForBundle: @escaping @Sendable (String) -> String? = { _ in nil },
        sendLocalInference: @escaping @Sendable (
            SemanticInferenceRequest,
            @escaping @Sendable (SemanticInferenceResult?) -> Void
        ) -> Void,
        cancelLocalInference: @escaping @Sendable (String) -> Void,
        rimeCandidates: @escaping @Sendable (String) -> [String] = { _ in [] },
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
        sendSentenceFeedback: @escaping @Sendable (String, String) -> Void = { _, _ in },
        sendCloudFeedback: @escaping @Sendable (String, String) -> Void = { _, _ in },
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
        self.domainForBundle = domainForBundle
        self.sendLocalInference = sendLocalInference
        self.cancelLocalInference = cancelLocalInference
        self.rimeCandidates = rimeCandidates
        self.clientSessionID = clientSessionID
        self.loadCloudAPIKey = loadCloudAPIKey
        self.cloudHistorySnapshot = cloudHistorySnapshot
        self.currentHistoryGeneration = currentHistoryGeneration
        self.phraseBookPhrases = phraseBookPhrases
        self.sendCloudInference = sendCloudInference
        self.cancelCloudInference = cancelCloudInference
        self.disconnectCloud = disconnectCloud
        self.sendSentenceFeedback = sendSentenceFeedback
        self.sendCloudFeedback = sendCloudFeedback
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

    let dependencies: SemanticSuggestionDependencies

    // Orchestration state (was: RimeAIInputController fields).
    var localDebounceTask: (any SemanticSuggestionTask)?
    var cloudDebounceTask: (any SemanticSuggestionTask)?
    var pendingRequestID: String?
    var pendingRequestStartedAt: TimeInterval?
    // Segment layout of the in-flight local request, consumed by
    // `applyLocalResult` for cross-punctuation sentence validation.
    var pendingRequestSegments: [PinyinSegment]?
    // 异步神经整句迟到帧（LM-001）：发送时登记的期望槽
    // （latest-request-wins，迟到帧只消费登记过的 requestID），
    // 以及神经帧已成功应用的组合令牌（§4.3.1 冻结仲裁：后到的同步
    // 帧在同令牌上不得覆写或清空已上屏的神经整句）。
    var neuralLateRequestID: String?
    var neuralLateToken: CompositionToken?
    var neuralLateSegments: [PinyinSegment]?
    var neuralLateAppliedToken: CompositionToken?
    /// LM-002 开发期对比行：本地/云端整句建议快照（绑定 token，
    /// 独立于仲裁槽存活，供面板分两行展示；不改变提交/反馈语义）。
    var localSentenceText: String?
    var localSentenceToken: CompositionToken?
    var cloudSentenceText: String?
    var cloudSentenceToken: CompositionToken?

    /// 当前组合令牌下的本地整句建议快照（神经迟到帧 / 同步 beam）。
    public var localComparisonSuggestion: String? {
        guard let localSentenceText, let localSentenceToken,
              localSentenceToken == composition.token
        else {
            return nil
        }
        return localSentenceText
    }

    /// 当前组合令牌下的云端整句建议快照。
    public var cloudComparisonSuggestion: String? {
        guard let cloudSentenceText, let cloudSentenceToken,
              cloudSentenceToken == composition.token
        else {
            return nil
        }
        return cloudSentenceText
    }

    /// 当前展示槽的整句建议是否来自神经臂迟到帧（LM-002 开发期
    /// 来源标注）。token 仍匹配当前组合才为真（失效链自动消除）；
    /// 云端接管槽位时显式清除。
    public var neuralLateApplied: Bool {
        guard let neuralLateAppliedToken else {
            return false
        }
        return neuralLateAppliedToken == composition.token
    }
    /// 当前展示槽中可反馈建议的来源标识（LM-003）：requestID + 是否
    /// 云端（云端走 broker 反馈帧，本地/神经迟到帧走 daemon）+ 展示
    /// 文本（用于「内容一致即采纳」比对：首选一致合并场景下 Space
    /// 上屏与建议同文，语义上是采纳而非拒绝）。
    var displayedFeedback: (requestID: String, cloud: Bool, text: String?)?
    var pendingCloudRequestID: String?
    /// 分段向后重推（KBD-006）：防抖任务与在途请求 ID 集合。
    var suffixRefinementTask: (any SemanticSuggestionTask)?
    var pendingSuffixRefinementRequestIDs: Set<String> = []

    // L1 phrasebook fallback (LP-006): the composition context the fill
    // is anchored to, plus whether the cloud channel for this cycle may
    // still claim the slot.
    struct PhraseBookSlotContext {
        let pinyin: String
        let bundleIdentifier: String
        let token: CompositionToken
    }

    var phraseContext: PhraseBookSlotContext?
    var cloudCyclePending = false

    // The visible suggestion slot, read by the controller for rendering
    // and commit attribution.
    public internal(set) var presentation: SemanticCandidatePresentation =
        .idle
    public internal(set) var historySource: HistoryCommitSource =
        .localSemantic
    public internal(set) var cloudCandidate: CloudCandidate?
    public internal(set) var mixedCompositionSuggestion:
        MixedCompositionSuggestion?
    public internal(set) var cloudSuggestionApplied = false
    public internal(set) var contextCharacterCount = 0
    public internal(set) var cloudInFlight = false

    public var hasPendingCloudRequest: Bool {
        pendingCloudRequestID != nil
    }

    public init(dependencies: SemanticSuggestionDependencies) {
        self.dependencies = dependencies
    }

    var composition: CompositionState {
        dependencies.compositionSnapshot()
    }

    func emit(_ event: SemanticSuggestionPipelineEvent) {
        dependencies.onEvent?(event)
    }

    // MARK: Slot lifecycle (driven by composition edits)

    /// A fresh input cycle starts: reset commit attribution to local and
    /// drop any cloud/mixed suggestion carried over from the previous
    /// keystroke.
    public func beginInputCycle() {
        expireDisplayedSuggestion()
        mixedCompositionSuggestion = nil
        historySource = .localSemantic
        cloudCandidate = nil
        cloudSuggestionApplied = false
        phraseContext = nil
        cloudCyclePending = false
        localSentenceText = nil
        localSentenceToken = nil
        cloudSentenceText = nil
        cloudSentenceToken = nil
        neuralLateRequestID = nil
        neuralLateToken = nil
        neuralLateSegments = nil
        neuralLateAppliedToken = nil
    }

    // MARK: - 决策反馈（LM-003 传感层）

    /// 展示槽里是否有可反馈的建议（采纳/拒绝发射点用）。
    public var hasDisplayedSuggestionForFeedback: Bool {
        displayedFeedback != nil
    }

    /// 用户 Tab 采纳了展示槽中的建议。
    public func markDisplayedSuggestionAdopted() {
        emitDisplayedFeedback("adopted")
    }

    /// 用户选了其他候选（数字/Space 提交 Rime 候选）。首选一致合并
    /// 场景下，上屏文本与展示建议完全一致时语义上是采纳（用户看到
    /// 并上屏了这个建议的内容），记 adopted_via_main 保留路径信息；
    /// 只有提交文本与建议不同才是真拒绝（2026-10-24 神经臂假阴性
    /// 裁决：实测 15 个 rejected 里 ~10 个提交文本逐字相同）。
    public func markDisplayedSuggestionRejected(
        committedText: String? = nil
    ) {
        if let text = displayedFeedback?.text,
           let committed = committedText,
           !text.isEmpty,
           text == committed {
            emitDisplayedFeedback("adopted_via_main")
        } else {
            emitDisplayedFeedback("rejected")
        }
    }

    /// 输入周期结束（新周期/重置）时建议未被处理。
    func expireDisplayedSuggestion() {
        emitDisplayedFeedback("expired")
    }

    private func emitDisplayedFeedback(_ outcome: String) {
        guard let feedback = displayedFeedback else { return }
        displayedFeedback = nil
        if feedback.cloud {
            dependencies.sendCloudFeedback(feedback.requestID, outcome)
        } else {
            dependencies.sendSentenceFeedback(
                feedback.requestID,
                outcome
            )
        }
    }

    /// 登记展示槽建议的来源；云端接管本地建议时先发 superseded。
    func setDisplayedFeedback(
        requestID: String, cloud: Bool, text: String? = nil
    ) {
        if let existing = displayedFeedback,
           !existing.cloud,
           cloud,
           existing.requestID != requestID {
            dependencies.sendSentenceFeedback(
                existing.requestID,
                "superseded"
            )
        }
        displayedFeedback = (requestID, cloud, text)
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


    // MARK: Invalidation

    /// Cancel everything in flight: both debounces, the pending local
    /// request, the pending cloud request, and the suffix refinement
    /// batch.
    /// `clearPresentation == true` additionally resets the slot to idle
    /// (used on reset / secure input / session switch).
    public func invalidate(clearPresentation: Bool = false) {
        localDebounceTask?.cancel()
        localDebounceTask = nil
        cloudDebounceTask?.cancel()
        cloudDebounceTask = nil
        suffixRefinementTask?.cancel()
        suffixRefinementTask = nil
        for requestID in pendingSuffixRefinementRequestIDs {
            dependencies.cancelLocalInference(requestID)
        }
        pendingSuffixRefinementRequestIDs.removeAll()
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
        neuralLateRequestID = nil
        neuralLateToken = nil
        neuralLateSegments = nil
        neuralLateAppliedToken = nil
        if clearPresentation {
            presentation = .idle
            contextCharacterCount = 0
            historySource = .localSemantic
            cloudCandidate = nil
            cloudSuggestionApplied = false
            mixedCompositionSuggestion = nil
            phraseContext = nil
            cloudCyclePending = false
            localSentenceText = nil
            localSentenceToken = nil
            cloudSentenceText = nil
            cloudSentenceToken = nil
        }
    }
}