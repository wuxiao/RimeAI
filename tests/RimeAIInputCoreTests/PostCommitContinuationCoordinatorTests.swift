import Foundation
import Testing
@testable import RimeAIInputCore

// MARK: - Manual doubles

/// Records every block the coordinator hands to its scheduling seam so
/// tests fire debounces, auto-hide timers and queue hops deterministically.
/// Mirrors the private harness in SemanticSuggestionPipelineTests (those
/// fakes are file-private by design; this copy stays independent).
private final class ManualScheduling:
    SemanticSuggestionScheduling, @unchecked Sendable
{
    final class TaskBox: SemanticSuggestionTask, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        func cancel() {
            lock.withLock { cancelled = true }
        }
    }

    struct ScheduledBlock {
        let delay: TimeInterval
        let action: @MainActor () -> Void
        let box: TaskBox
    }

    private let lock = NSLock()
    private var scheduledBlocks: [ScheduledBlock] = []
    private var onMainBlocks: [@MainActor () -> Void] = []

    var scheduledDelays: [TimeInterval] {
        lock.withLock { scheduledBlocks.map(\.delay) }
    }

    var pendingScheduledCount: Int {
        lock.withLock { scheduledBlocks.count }
    }

    func scheduleOnMain(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any SemanticSuggestionTask {
        let box = TaskBox()
        lock.withLock {
            scheduledBlocks.append(
                ScheduledBlock(delay: delay, action: action, box: box)
            )
        }
        return box
    }

    func dispatchOffMain(_ action: @escaping @Sendable () -> Void) {
        action()
    }

    func dispatchOnMain(_ action: @escaping @MainActor () -> Void) {
        lock.withLock { onMainBlocks.append(action) }
    }

    /// Fire the next live timer (skipping cancelled boxes) and return its
    /// delay.
    @discardableResult
    @MainActor
    func fireNextScheduled() -> TimeInterval? {
        while true {
            let block = lock.withLock { () -> ScheduledBlock? in
                guard let first = scheduledBlocks.first else {
                    return nil
                }
                scheduledBlocks.removeFirst()
                return first
            }
            guard let block else {
                return nil
            }
            if !block.box.isCancelled {
                block.action()
                return block.delay
            }
        }
    }

    @MainActor
    func runNextOnMain() {
        let block = lock.withLock { () -> (@MainActor () -> Void)? in
            guard !onMainBlocks.isEmpty else {
                return nil
            }
            return onMainBlocks.removeFirst()
        }
        block?()
    }
}

/// Mutable knobs the tests flip mid-flight. All access happens on the test
/// thread; `@unchecked Sendable` only satisfies the dependency closures.
private final class ContinuationFlags: @unchecked Sendable {
    var enabled = true
    var aiAllowed = true
    var policy: ContextPolicy = .standard
    var secure = false
    var compositionEmpty = true
    var selecting = false
    var apiKey: String? = "test-api-key"
    var historySnapshot = HistoryContextSnapshot(
        recentText: "",
        relevantSnippets: [],
        generation: 3
    )
}

private final class ContinuationHarness: @unchecked Sendable {
    let scheduling = ManualScheduling()
    let flags = ContinuationFlags()
    var clock: TimeInterval = 1_000

    private(set) var events: [PostCommitContinuationEvent] = []
    private(set) var requests: [CloudContinuationRequest] = []
    private(set) var cancelledRequestIDs: [String] = []
    private var completions: [String: (CloudContinuationResponse?) -> Void] =
        [:]

    @MainActor
    lazy var coordinator: PostCommitContinuationCoordinator =
        PostCommitContinuationCoordinator(
            dependencies: PostCommitContinuationDependencies(
                now: { [self] in clock },
                scheduling: scheduling,
                isSecureEventInputEnabled: { [flags] in flags.secure },
                isContinuationEnabled: { [flags] in flags.enabled },
                isAIAllowed: { [flags] _ in flags.aiAllowed },
                contextPolicy: { [flags] _ in flags.policy },
                loadCloudAPIKey: { [flags] in flags.apiKey },
                cloudModelID: { "glm-5.3-flash" },
                clientSessionID: "client-session",
                cloudHistorySnapshot: { [flags] _ in flags.historySnapshot },
                sendContinuation: { [self] request, _, completion in
                    requests.append(request)
                    completions[request.requestID] = completion
                },
                cancelContinuation: { [self] requestID in
                    cancelledRequestIDs.append(requestID)
                },
                compositionIsEmpty: { [flags] in flags.compositionEmpty },
                compositionIsSelecting: { [flags] in flags.selecting },
                onEvent: { [self] event in
                    events.append(event)
                }
            )
        )

    @MainActor
    func commit(
        _ text: String = "床前明月光",
        context: String = "床前明月光",
        bundle: String = "com.example.Editor"
    ) {
        coordinator.commitDidHappen(
            bundleIdentifier: bundle,
            committedText: text,
            contextProvider: { _ in context }
        )
    }

    /// Fire the debounce; returns the request it sent, if any.
    @MainActor
    @discardableResult
    func fireDebounce() -> CloudContinuationRequest? {
        let before = requests.count
        let delay = scheduling.fireNextScheduled()
        #expect(delay == 0.25)
        return requests.count > before ? requests.last : nil
    }

    /// Fire every armed timer for a commit that must not reach the network.
    @MainActor
    func fireDebounceExpectingSilence(name: String) {
        while scheduling.fireNextScheduled() != nil {}
    }

    /// Deliver a broker response as if it arrived off-main.
    @MainActor
    func deliver(
        _ response: CloudContinuationResponse?,
        for request: CloudContinuationRequest
    ) {
        completions[request.requestID]?(response)
        scheduling.runNextOnMain()
    }

    func makeResponse(
        for request: CloudContinuationRequest,
        decision: String = "generate",
        text: String? = "疑是地上霜",
        confidence: Double? = 0.9
    ) -> CloudContinuationResponse {
        CloudContinuationResponse(
            status: "ok",
            requestID: request.requestID,
            decision: decision,
            generatedText: text,
            confidence: confidence,
            reason: decision == "generate" ? "context_match" : "uncertain",
            modelID: request.modelID,
            elapsedMilliseconds: 12
        )
    }

    var shownTexts: [String] {
        events.compactMap { event in
            if case let .showSuggestion(text) = event { text } else { nil }
        }
    }

    var hideCount: Int {
        events.reduce(0) { $0 + ($1 == .hideSuggestion ? 1 : 0) }
    }

    var diagnostics: [RimeAIDiagnosticEvent] {
        events.compactMap { event in
            if case let .diagnostic(metric) = event { metric } else { nil }
        }
    }
}

// MARK: - Debounce

@Test @MainActor
func commitDebounceLatestWins() {
    let harness = ContinuationHarness()
    _ = harness.coordinator

    harness.commit("床前明月光", context: "床前明月光")
    harness.commit("低头思故乡", context: "床前明月光，低头思故乡")

    let request = harness.fireDebounce()
    #expect(harness.requests.count == 1)
    #expect(request?.recentContext == "床前明月光，低头思故乡")
    // 250 ms debounce, latest-wins: only one timer ever fired.
    #expect(harness.scheduling.pendingScheduledCount == 0)
    #expect(
        harness.diagnostics.filter { $0 == .continuationRequested }.count == 1
    )
}

// MARK: - Gate matrix

@Test @MainActor
func gateMatrixBlocksRequestAndEvents() {
    let cases: [(String, (ContinuationFlags) -> Void, String)] = [
        ("switch off", { $0.enabled = false }, "床前明月光"),
        ("AI disabled for app", { $0.aiAllowed = false }, "床前明月光"),
        ("strict policy", { $0.policy = .strict }, "床前明月光"),
        ("secure input", { $0.secure = true }, "床前明月光"),
        ("short commit", { _ in }, "床前明"),
        ("missing credential", { $0.apiKey = nil }, "床前明月光"),
    ]
    for (name, configure, text) in cases {
        let harness = ContinuationHarness()
        _ = harness.coordinator
        configure(harness.flags)

        harness.commit(text)
        harness.fireDebounceExpectingSilence(name: name)

        #expect(harness.requests.isEmpty, Comment(rawValue: name))
        #expect(harness.events.isEmpty, Comment(rawValue: name))
    }
}

// MARK: - Guard ladder

@Test @MainActor
func guardLadderDropsLateResults() throws {
    // userTyped before the result arrives
    do {
        let harness = ContinuationHarness()
        _ = harness.coordinator
        harness.commit()
        let request = try #require(harness.fireDebounce())
        harness.coordinator.cancel(.userTyped)
        #expect(harness.cancelledRequestIDs == [request.requestID])
        harness.deliver(harness.makeResponse(for: request), for: request)
        #expect(harness.shownTexts.isEmpty)
    }
    // epoch change: a newer commit supersedes the in-flight request
    do {
        let harness = ContinuationHarness()
        _ = harness.coordinator
        harness.commit(context: "床前明月光")
        let first = try #require(harness.fireDebounce())
        harness.commit(context: "低头思故乡")
        let second = try #require(harness.fireDebounce())
        #expect(harness.cancelledRequestIDs == [first.requestID])
        harness.deliver(harness.makeResponse(for: first), for: first)
        #expect(harness.shownTexts.isEmpty)
        harness.deliver(harness.makeResponse(for: second), for: second)
        #expect(harness.shownTexts == ["疑是地上霜"])
    }
    // composition no longer empty at arrival
    do {
        let harness = ContinuationHarness()
        _ = harness.coordinator
        harness.commit()
        let request = try #require(harness.fireDebounce())
        harness.flags.compositionEmpty = false
        harness.deliver(harness.makeResponse(for: request), for: request)
        #expect(harness.shownTexts.isEmpty)
    }
    // selection in progress at arrival
    do {
        let harness = ContinuationHarness()
        _ = harness.coordinator
        harness.commit()
        let request = try #require(harness.fireDebounce())
        harness.flags.selecting = true
        harness.deliver(harness.makeResponse(for: request), for: request)
        #expect(harness.shownTexts.isEmpty)
    }
    // session switched at arrival
    do {
        let harness = ContinuationHarness()
        _ = harness.coordinator
        harness.commit()
        let request = try #require(harness.fireDebounce())
        harness.coordinator.cancel(.sessionSwitched)
        harness.deliver(harness.makeResponse(for: request), for: request)
        #expect(harness.shownTexts.isEmpty)
    }
    // secure input turned on at arrival
    do {
        let harness = ContinuationHarness()
        _ = harness.coordinator
        harness.commit()
        let request = try #require(harness.fireDebounce())
        harness.flags.secure = true
        harness.deliver(harness.makeResponse(for: request), for: request)
        #expect(harness.shownTexts.isEmpty)
    }
    // arrival after deadline + 50 ms
    do {
        let harness = ContinuationHarness()
        _ = harness.coordinator
        harness.commit()
        let request = try #require(harness.fireDebounce())
        harness.clock += Double(
            PostCommitContinuationCoordinator.requestDeadlineMilliseconds
        ) / 1000 + 0.051
        harness.deliver(harness.makeResponse(for: request), for: request)
        #expect(harness.shownTexts.isEmpty)
        #expect(harness.diagnostics.contains(.continuationAbstained))
    }
    // structurally invalid response (punctuation in the text)
    do {
        let harness = ContinuationHarness()
        _ = harness.coordinator
        harness.commit()
        let request = try #require(harness.fireDebounce())
        harness.deliver(
            harness.makeResponse(for: request, text: "疑是地上霜。"),
            for: request
        )
        #expect(harness.shownTexts.isEmpty)
        #expect(harness.diagnostics.contains(.continuationAbstained))
    }
}

@Test @MainActor
func brokerSilenceLeavesPendingUntilNextCommit() throws {
    let harness = ContinuationHarness()
    _ = harness.coordinator

    harness.commit()
    let first = try #require(harness.fireDebounce())
    // Old broker: never answers. No suggestion, no error event.
    #expect(harness.shownTexts.isEmpty)
    #expect(harness.diagnostics == [.continuationRequested])

    harness.commit(context: "疑是地上霜")
    let second = try #require(harness.fireDebounce())
    #expect(harness.cancelledRequestIDs == [first.requestID])
    #expect(second.requestID != first.requestID)
}

// MARK: - Cooldown

@Test @MainActor
func abstainCooldownBlocksArmingForSixtySeconds() throws {
    let harness = ContinuationHarness()
    _ = harness.coordinator

    for _ in 0 ..< 3 {
        harness.commit()
        let request = try #require(harness.fireDebounce())
        harness.deliver(
            harness.makeResponse(for: request, decision: "abstain", text: nil, confidence: nil),
            for: request
        )
    }
    #expect(
        harness.diagnostics.filter { $0 == .continuationAbstained }.count == 3
    )

    harness.commit()
    #expect(harness.scheduling.pendingScheduledCount == 1)
    harness.fireDebounceExpectingSilence(name: "cooldown")
    #expect(harness.requests.count == 3)
    #expect(harness.diagnostics.contains(.continuationCooldown))

    // 冷却 60s 后恢复
    harness.clock += 61
    harness.commit()
    #expect(harness.fireDebounce() != nil)
    #expect(harness.requests.count == 4)
}

@Test @MainActor
func cooldownResetsOnGenerate() throws {
    let harness = ContinuationHarness()
    _ = harness.coordinator

    for _ in 0 ..< 2 {
        harness.commit()
        let request = try #require(harness.fireDebounce())
        harness.deliver(
            harness.makeResponse(for: request, decision: "abstain", text: nil, confidence: nil),
            for: request
        )
    }
    harness.commit(context: "春眠不觉晓")
    let request = try #require(harness.fireDebounce())
    harness.deliver(
        harness.makeResponse(for: request, text: "处处闻啼鸟"),
        for: request
    )
    #expect(harness.shownTexts == ["处处闻啼鸟"])

    // 一次成功后计数清零：再来两次 abstain 不触发冷却
    for _ in 0 ..< 2 {
        harness.commit(context: "白日依山尽")
        let next = try #require(harness.fireDebounce())
        harness.deliver(
            harness.makeResponse(for: next, decision: "abstain", text: nil, confidence: nil),
            for: next
        )
    }
    harness.commit(context: "欲穷千里目")
    #expect(harness.fireDebounce() != nil)
    #expect(!harness.diagnostics.contains(.continuationCooldown))
}

// MARK: - Dedup

@Test @MainActor
func dedupSameContextTailSuppressesRepeatSuggestion() throws {
    let harness = ContinuationHarness()
    _ = harness.coordinator

    harness.commit()
    let first = try #require(harness.fireDebounce())
    harness.deliver(harness.makeResponse(for: first), for: first)
    #expect(harness.shownTexts == ["疑是地上霜"])
    harness.coordinator.cancel(.userTyped)

    // 同一 context 尾部、同一文本：不再展示
    harness.commit()
    let second = try #require(harness.fireDebounce())
    harness.deliver(harness.makeResponse(for: second), for: second)
    #expect(harness.shownTexts == ["疑是地上霜"])

    // 同一 context 尾部、不同文本：仍然展示
    harness.commit()
    let third = try #require(harness.fireDebounce())
    harness.deliver(
        harness.makeResponse(for: third, text: "低头思故乡"),
        for: third
    )
    #expect(harness.shownTexts == ["疑是地上霜", "低头思故乡"])
}

@Test @MainActor
func dedupLRUBoundedAt64() throws {
    let harness = ContinuationHarness()
    _ = harness.coordinator

    func context(_ index: Int) -> String {
        "第\(index)号床前明月光"
    }
    for index in 0 ..< 65 {
        harness.commit(context: context(index))
        let request = try #require(harness.fireDebounce())
        harness.deliver(harness.makeResponse(for: request), for: request)
    }
    #expect(harness.shownTexts.count == 65)

    // 容量 64：最早的 context 条目已淘汰，同一建议可以再次展示
    harness.commit(context: context(0))
    let request = try #require(harness.fireDebounce())
    harness.deliver(harness.makeResponse(for: request), for: request)
    #expect(harness.shownTexts.count == 66)
}

// MARK: - Lifecycle

@Test @MainActor
func autoHideAfter8Seconds() throws {
    let harness = ContinuationHarness()
    _ = harness.coordinator

    harness.commit()
    let request = try #require(harness.fireDebounce())
    harness.deliver(harness.makeResponse(for: request), for: request)
    #expect(harness.shownTexts == ["疑是地上霜"])
    #expect(harness.diagnostics.contains(.continuationShown))

    let delay = harness.scheduling.fireNextScheduled()
    #expect(delay == 8)
    #expect(harness.hideCount == 1)
    // Auto-hide withdraws with the timed-out reason recorded.
    #expect(harness.diagnostics.contains(.continuationDismissedTimedOut))
    #expect(!harness.diagnostics.contains(.continuationDismissed))
}

@Test @MainActor
func cancelReasonsAreRecordedInDismissDiagnostics() throws {
    let harness = ContinuationHarness()
    _ = harness.coordinator

    // 用户开始击键：以 userTyped 原因撤下建议。
    harness.commit()
    let request = try #require(harness.fireDebounce())
    harness.deliver(harness.makeResponse(for: request), for: request)
    #expect(harness.shownTexts == ["疑是地上霜"])

    harness.coordinator.cancel(.userTyped)
    #expect(harness.hideCount == 1)
    #expect(harness.diagnostics.contains(.continuationDismissedUserTyped))
    #expect(!harness.diagnostics.contains(.continuationDismissed))

    // 无建议在屏时取消：不产生撤下诊断。
    harness.coordinator.cancel(.sessionSwitched)
    #expect(harness.hideCount == 1)
    #expect(!harness.diagnostics.contains(.continuationDismissedSessionSwitched))
}

@Test @MainActor
func acceptRecordsDiagnosticAndAllowsRearm() throws {
    let harness = ContinuationHarness()
    _ = harness.coordinator

    harness.commit()
    let request = try #require(harness.fireDebounce())
    harness.deliver(harness.makeResponse(for: request), for: request)
    #expect(harness.shownTexts == ["疑是地上霜"])

    harness.coordinator.acceptCandidate("疑是地上霜")
    #expect(harness.diagnostics.contains(.continuationAccepted))
    // 接受后状态清空：随后的取消不再隐藏面板，自动隐藏计时已取消
    harness.coordinator.cancel(.userTyped)
    #expect(harness.hideCount == 0)

    // 链式联想：下一轮 commit 正常 arm（同 context 同文本由去重拦截展示，
    // 但请求照常发出）
    harness.commit()
    #expect(harness.fireDebounce() != nil)
    #expect(harness.requests.count == 2)
}
