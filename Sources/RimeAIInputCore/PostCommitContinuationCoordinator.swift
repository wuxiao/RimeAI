import Foundation

/// Events the post-commit continuation coordinator emits to its owner (the
/// IMK controller). The coordinator itself is Foundation-only; rendering the
/// chip is the controller's job.
public enum PostCommitContinuationEvent: Sendable, Equatable {
    case showSuggestion(String)
    case hideSuggestion
    case diagnostic(RimeAIDiagnosticEvent)
}

public enum PostCommitContinuationCancelReason: String, Sendable {
    case userTyped
    case compositionBegan
    case sessionSwitched
    case secureInput
    case deactivated
    case timedOut
}

/// Dependency seam for PostCommitContinuationCoordinator. Every closure is
/// injected by the IMK controller so the coordinator stays Foundation-only
/// and fully testable; `onEvent` is delivered on the main actor.
public struct PostCommitContinuationDependencies: Sendable {
    public var now: @Sendable () -> TimeInterval
    public var scheduling: any SemanticSuggestionScheduling
    public var isSecureEventInputEnabled: @Sendable () -> Bool
    /// settings.continuationSuggestionEnabled ∧ aiEnabled ∧ cloudConfigured,
    /// composed at the injection site.
    public var isContinuationEnabled: @Sendable () -> Bool
    public var isAIAllowed: @Sendable (String) -> Bool
    public var contextPolicy: @Sendable (String) -> ContextPolicy
    public var loadCloudAPIKey: @Sendable () -> String?
    public var cloudModelID: @Sendable () -> String
    public var clientSessionID: String
    public var cloudHistorySnapshot:
        @Sendable (String) -> HistoryContextSnapshot?
    public var sendContinuation:
        @Sendable (
            CloudContinuationRequest,
            String,
            @escaping @Sendable (CloudContinuationResponse?) -> Void
        ) -> Void
    public var cancelContinuation: @Sendable (String) -> Void
    public var compositionIsEmpty: @MainActor @Sendable () -> Bool
    public var compositionIsSelecting: @MainActor @Sendable () -> Bool
    public var onEvent:
        (@MainActor @Sendable (PostCommitContinuationEvent) -> Void)?

    public init(
        now: @escaping @Sendable () -> TimeInterval,
        scheduling: any SemanticSuggestionScheduling,
        isSecureEventInputEnabled: @escaping @Sendable () -> Bool,
        isContinuationEnabled: @escaping @Sendable () -> Bool,
        isAIAllowed: @escaping @Sendable (String) -> Bool,
        contextPolicy: @escaping @Sendable (String) -> ContextPolicy,
        loadCloudAPIKey: @escaping @Sendable () -> String?,
        cloudModelID: @escaping @Sendable () -> String,
        clientSessionID: String,
        cloudHistorySnapshot:
            @escaping @Sendable (String) -> HistoryContextSnapshot?,
        sendContinuation:
            @escaping @Sendable (
                CloudContinuationRequest,
                String,
                @escaping @Sendable (CloudContinuationResponse?) -> Void
            ) -> Void,
        cancelContinuation: @escaping @Sendable (String) -> Void,
        compositionIsEmpty: @escaping @MainActor @Sendable () -> Bool,
        compositionIsSelecting: @escaping @MainActor @Sendable () -> Bool,
        onEvent:
            (@MainActor @Sendable (PostCommitContinuationEvent) -> Void)? =
                nil
    ) {
        self.now = now
        self.scheduling = scheduling
        self.isSecureEventInputEnabled = isSecureEventInputEnabled
        self.isContinuationEnabled = isContinuationEnabled
        self.isAIAllowed = isAIAllowed
        self.contextPolicy = contextPolicy
        self.loadCloudAPIKey = loadCloudAPIKey
        self.cloudModelID = cloudModelID
        self.clientSessionID = clientSessionID
        self.cloudHistorySnapshot = cloudHistorySnapshot
        self.sendContinuation = sendContinuation
        self.cancelContinuation = cancelContinuation
        self.compositionIsEmpty = compositionIsEmpty
        self.compositionIsSelecting = compositionIsSelecting
        self.onEvent = onEvent
    }
}

/// Post-commit continuation state machine: after text is committed, arm a
/// debounced cloud request for the phrase that naturally follows; show it as
/// a single chip; withdraw it the instant the user types, switches session,
/// or the chip times out. Staleness is judged by an internal commit epoch —
/// never by history generation, whose asynchronous bump would race honest
/// in-flight responses (spec §5.3).
@MainActor
public final class PostCommitContinuationCoordinator {
    /// 请求 deadline：与 broker 的 30000ms 上限（本地开发调试放宽，
    /// 原为 3000ms）和客户端 deadline+50ms 迟到口径一致。
    public static let requestDeadlineMilliseconds = 30_000
    static let debounceSeconds: TimeInterval = 0.25
    static let autoHideSeconds: TimeInterval = 8
    static let cooldownSeconds: TimeInterval = 60
    static let cooldownThreshold = 3
    static let dedupCapacity = 64

    private var dependencies: PostCommitContinuationDependencies

    private struct InFlightSnapshot {
        let epoch: UInt64
        let bundleIdentifier: String
        let sentAt: TimeInterval
        let request: CloudContinuationRequest
    }

    private var commitEpoch: UInt64 = 0
    private var inFlight: InFlightSnapshot?
    private var debounceTask: (any SemanticSuggestionTask)?
    private var hideTask: (any SemanticSuggestionTask)?
    /// The suggestion currently on screen, plus the dedup key it was shown
    /// for; nil when nothing is displayed.
    private var showing: (key: String, text: String)?
    private var consecutiveAbstains = 0
    private var cooldownUntil: TimeInterval = 0
    /// Session-scoped LRU: context-tail key → suggestions already shown for
    /// it. Insertion order doubles as eviction order.
    private var dedupOrder: [String] = []
    private var dedupSets: [String: Set<String>] = [:]

    public init(dependencies: PostCommitContinuationDependencies) {
        self.dependencies = dependencies
    }

    /// The user committed text. Bumps the epoch, withdraws anything in
    /// flight or on screen, and rearms the 250 ms debounce (latest-wins).
    /// Session switches withdraw the suggestion through
    /// `cancel(.sessionSwitched)`, so no per-session state is kept here.
    public func commitDidHappen(
        bundleIdentifier: String,
        committedText: String,
        contextProvider: @escaping (ContextPolicy) -> String
    ) {
        commitEpoch &+= 1
        let epoch = commitEpoch
        cancelInFlight()
        hideSuggestionIfShowing(dismissDiagnostic: .continuationDismissed)
        debounceTask?.cancel()
        debounceTask = dependencies.scheduling.scheduleOnMain(
            after: Self.debounceSeconds
        ) { [weak self] in
            self?.arm(
                epoch: epoch,
                bundleIdentifier: bundleIdentifier,
                committedText: committedText,
                contextProvider: contextProvider
            )
        }
    }

    /// Any withdrawal condition: new keystroke, new composition, session or
    /// secure-input change, deactivation, or the auto-hide timer. The
    /// reason is recorded with the dismiss diagnostic so telemetry can
    /// tell them apart.
    public func cancel(_ reason: PostCommitContinuationCancelReason) {
        debounceTask?.cancel()
        debounceTask = nil
        cancelInFlight()
        hideSuggestionIfShowing(
            dismissDiagnostic: reason.dismissDiagnostic
        )
    }

    /// The user took the suggestion: clear the state, keep the dedup entry
    /// (acceptance must not re-show the same text), record the acceptance.
    public func acceptCandidate(_ text: String) {
        hideTask?.cancel()
        hideTask = nil
        showing = nil
        emit(.diagnostic(.continuationAccepted))
    }

    // MARK: - Arming

    private func arm(
        epoch: UInt64,
        bundleIdentifier: String,
        committedText: String,
        contextProvider: (ContextPolicy) -> String
    ) {
        debounceTask = nil
        guard epoch == commitEpoch,
              dependencies.isContinuationEnabled(),
              dependencies.isAIAllowed(bundleIdentifier)
        else {
            return
        }
        let policy = dependencies.contextPolicy(bundleIdentifier)
        guard policy != .strict,
              !dependencies.isSecureEventInputEnabled(),
              ContinuationTextPolicy.hanCount(committedText)
                  >= ContinuationTextPolicy.minimumContextHanCharacters,
              dependencies.now() >= cooldownUntil,
              let apiKey = dependencies.loadCloudAPIKey()
        else {
            return
        }
        let context = String(
            contextProvider(policy)
                .suffix(ContinuationTextPolicy.maximumContextCharacters)
        )
        let snapshot = dependencies.cloudHistorySnapshot(bundleIdentifier)
        let request = CloudContinuationRequest(
            requestID: UUID().uuidString,
            clientSessionID: dependencies.clientSessionID,
            bundleIdentifier: bundleIdentifier,
            modelID: dependencies.cloudModelID(),
            recentContext: context,
            historySnippets: snapshot?.relevantSnippets ?? [],
            historyGeneration: snapshot?.generation,
            deadlineMilliseconds: Self.requestDeadlineMilliseconds
        )
        guard ContinuationTextPolicy.isValid(request: request) else {
            return
        }
        inFlight = InFlightSnapshot(
            epoch: epoch,
            bundleIdentifier: bundleIdentifier,
            sentAt: dependencies.now(),
            request: request
        )
        emit(.diagnostic(.continuationRequested))
        let requestID = request.requestID
        let scheduling = dependencies.scheduling
        dependencies.sendContinuation(request, apiKey) {
            [weak self] response in
            scheduling.dispatchOnMain {
                self?.handleResponse(response, requestID: requestID)
            }
        }
    }

    // MARK: - Response guard ladder

    private func handleResponse(
        _ response: CloudContinuationResponse?,
        requestID: String
    ) {
        // A stale response (superseded commit, cancelled request) is dropped
        // without touching the current in-flight snapshot.
        guard let snapshot = inFlight,
              snapshot.request.requestID == requestID
        else {
            return
        }
        inFlight = nil
        let arrivalDeadline = snapshot.sentAt
            + Double(snapshot.request.deadlineMilliseconds) / 1000 + 0.05
        // The app session is guarded implicitly: a session switch cancels
        // the in-flight request via cancel(.sessionSwitched), so a live
        // snapshot always belongs to the current session.
        guard snapshot.epoch == commitEpoch,
              dependencies.compositionIsEmpty(),
              !dependencies.compositionIsSelecting(),
              !dependencies.isSecureEventInputEnabled()
        else {
            return
        }
        guard dependencies.now() <= arrivalDeadline else {
            registerFailure()
            return
        }
        guard let response,
              ContinuationTextPolicy.isValid(
                  response: response,
                  for: snapshot.request
              )
        else {
            registerFailure()
            return
        }
        guard response.decision == "generate",
              let text = response.generatedText
        else {
            registerFailure()
            return
        }
        consecutiveAbstains = 0
        let key = String(
            snapshot.request.recentContext
                .suffix(ContinuationTextPolicy.dedupTailLength)
        )
        if dedupSets[key]?.contains(text) == true {
            return
        }
        recordDedup(key: key, text: text)
        showing = (key: key, text: text)
        emit(.diagnostic(.continuationShown))
        emit(.showSuggestion(text))
        hideTask = dependencies.scheduling.scheduleOnMain(
            after: Self.autoHideSeconds
        ) { [weak self] in
            self?.cancel(.timedOut)
        }
    }

    private func registerFailure() {
        emit(.diagnostic(.continuationAbstained))
        consecutiveAbstains += 1
        if consecutiveAbstains >= Self.cooldownThreshold {
            consecutiveAbstains = 0
            cooldownUntil = dependencies.now() + Self.cooldownSeconds
            emit(.diagnostic(.continuationCooldown))
        }
    }

    // MARK: - State helpers

    private func cancelInFlight() {
        guard let snapshot = inFlight else {
            return
        }
        inFlight = nil
        dependencies.cancelContinuation(snapshot.request.requestID)
    }

    private func hideSuggestionIfShowing(
        dismissDiagnostic: RimeAIDiagnosticEvent
    ) {
        guard showing != nil else {
            return
        }
        showing = nil
        hideTask?.cancel()
        hideTask = nil
        emit(.hideSuggestion)
        emit(.diagnostic(dismissDiagnostic))
    }

    private func recordDedup(key: String, text: String) {
        if dedupSets[key] == nil {
            dedupOrder.append(key)
            dedupSets[key] = []
        } else if let index = dedupOrder.firstIndex(of: key) {
            // LRU: 再次命中的 key 移到队尾，淘汰按最近使用而非插入序。
            dedupOrder.remove(at: index)
            dedupOrder.append(key)
        }
        dedupSets[key]?.insert(text)
        while dedupOrder.count > Self.dedupCapacity {
            let evicted = dedupOrder.removeFirst()
            dedupSets.removeValue(forKey: evicted)
        }
    }

    private func emit(_ event: PostCommitContinuationEvent) {
        dependencies.onEvent?(event)
    }
}

private extension PostCommitContinuationCancelReason {
    /// Telemetry counterpart of the withdrawal condition: dismiss
    /// diagnostics record why the suggestion left the screen.
    var dismissDiagnostic: RimeAIDiagnosticEvent {
        switch self {
        case .userTyped:
            .continuationDismissedUserTyped
        case .compositionBegan:
            .continuationDismissedCompositionBegan
        case .sessionSwitched:
            .continuationDismissedSessionSwitched
        case .secureInput:
            .continuationDismissedSecureInput
        case .deactivated:
            .continuationDismissedDeactivated
        case .timedOut:
            .continuationDismissedTimedOut
        }
    }
}
