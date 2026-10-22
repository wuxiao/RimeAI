import Foundation
import Testing
@testable import RimeAIInputCore

// LM-003 传感层：展示建议的采纳/拒绝/过期/取代反馈发射。
// 独立 mini-harness（管线主测试文件的 PipelineHarness/ManualScheduling
// 均为私有，且该文件已达行数上限——这里只装配反馈路径所需最小件）。

/// 最小手动调度桩：只驱动本地 100ms 去抖的同步发射。
private final class FeedbackScheduling:
    SemanticSuggestionScheduling, @unchecked Sendable
{
    final class TaskBox: SemanticSuggestionTask, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.withLock { cancelled = true }
        }

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }
    }

    private let lock = NSLock()
    private var blocks: [(action: @MainActor () -> Void, box: TaskBox)] = []

    func scheduleOnMain(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any SemanticSuggestionTask {
        let box = TaskBox()
        lock.withLock { blocks.append((action, box)) }
        return box
    }

    func dispatchOffMain(_ action: @escaping @Sendable () -> Void) {
        action()
    }

    func dispatchOnMain(_ action: @escaping @MainActor () -> Void) {
        MainActor.assumeIsolated { action() }
    }

    @MainActor
    @discardableResult
    func fireNextScheduled() -> Bool {
        lock.lock()
        guard !blocks.isEmpty else {
            lock.unlock()
            return false
        }
        let next = blocks.removeFirst()
        lock.unlock()
        guard !next.box.isCancelled else { return fireNextScheduled() }
        next.action()
        return true
    }
}

private final class FeedbackHarness: @unchecked Sendable {
    let scheduling = FeedbackScheduling()
    var composition = CompositionState(appSessionID: "app-session")
    var clock: TimeInterval = 1_000

    struct Record: Equatable {
        let requestID: String
        let outcome: String
    }

    private(set) var localRequests: [SemanticInferenceRequest] = []
    private(set) var sentenceFeedback: [Record] = []
    private(set) var cloudFeedback: [Record] = []

    @MainActor
    lazy var pipeline: SemanticSuggestionPipeline =
        SemanticSuggestionPipeline(
            dependencies: SemanticSuggestionDependencies(
                now: { [self] in clock },
                scheduling: scheduling,
                isSecureEventInputEnabled: { false },
                isLocalInferenceAllowed: { _ in true },
                isCloudConfigured: { false },
                contextPolicy: { _ in .standard },
                cloudModelID: {
                    RimeAICloudConfiguration.defaultRankingModelID
                },
                characterSet: { .simplified },
                sendLocalInference: { [self] request, _ in
                    localRequests.append(request)
                },
                cancelLocalInference: { _ in },
                clientSessionID: "client-session",
                loadCloudAPIKey: { nil },
                cloudHistorySnapshot: { _ in
                    HistoryContextSnapshot(
                        recentText: "",
                        relevantSnippets: [],
                        generation: 0
                    )
                },
                currentHistoryGeneration: { 0 },
                sendCloudInference: { _, _, _ in },
                cancelCloudInference: { _ in },
                disconnectCloud: {},
                sendSentenceFeedback: { [self] requestID, outcome in
                    sentenceFeedback.append(
                        FeedbackHarness.Record(requestID: requestID, outcome: outcome)
                    )
                },
                sendCloudFeedback: { [self] requestID, outcome in
                    cloudFeedback.append(
                        FeedbackHarness.Record(requestID: requestID, outcome: outcome)
                    )
                },
                compositionSnapshot: { [self] in composition },
                applySemanticCandidate: { [self] text, token, _, _ in
                    composition.applySemanticCandidate(text, token: token)
                },
                onEvent: nil
            )
        )

    @MainActor
    @discardableResult
    func displayRankedResult() -> SemanticInferenceRequest? {
        _ = composition.replaceInput(
            pinyin: "nihao",
            candidates: ["拟好", "你好"]
        )
        let token = composition.token
        pipeline.scheduleInference(
            token: token,
            bundleIdentifier: "com.apple.notes",
            contextProvider: { _ in "上下文" }
        )
        guard scheduling.fireNextScheduled() else { return nil }
        guard let request = localRequests.last else { return nil }
        pipeline.applyInferenceResult(
            SemanticInferenceResult(
                status: "ok",
                requestID: request.requestID,
                compositionID: request.compositionID,
                revision: request.revision,
                appSessionID: request.appSessionID,
                rankedCandidate: "你好",
                sentenceSuggestion: nil,
                confidence: 0.9,
                decision: .rankedCandidate
            ),
            requestID: request.requestID,
            token: token
        )
        return request
    }
}

@Test @MainActor
func displayedRankResultEmitsAdoptedOnce() {
    let harness = FeedbackHarness()
    guard let request = harness.displayRankedResult() else {
        Issue.record("ranked result must be displayed")
        return
    }
    #expect(harness.pipeline.hasDisplayedSuggestionForFeedback)

    harness.pipeline.markDisplayedSuggestionAdopted()
    #expect(
        harness.sentenceFeedback == [
            FeedbackHarness.Record(requestID: request.requestID, outcome: "adopted")
        ]
    )
    #expect(!harness.pipeline.hasDisplayedSuggestionForFeedback)
    // 一次性消费：重复标记不再发射。
    harness.pipeline.markDisplayedSuggestionAdopted()
    #expect(harness.sentenceFeedback.count == 1)
}

@Test @MainActor
func beginInputCycleExpiresDisplayedSuggestion() {
    let harness = FeedbackHarness()
    guard let request = harness.displayRankedResult() else {
        Issue.record("ranked result must be displayed")
        return
    }
    harness.pipeline.beginInputCycle()
    #expect(
        harness.sentenceFeedback == [
            FeedbackHarness.Record(requestID: request.requestID, outcome: "expired")
        ]
    )
}

@Test @MainActor
func selectionOverrideEmitsRejected() {
    let harness = FeedbackHarness()
    guard let request = harness.displayRankedResult() else {
        Issue.record("ranked result must be displayed")
        return
    }
    harness.pipeline.markDisplayedSuggestionRejected()
    #expect(
        harness.sentenceFeedback == [
            FeedbackHarness.Record(requestID: request.requestID, outcome: "rejected")
        ]
    )
}

@Test @MainActor
func cloudTakeoverSupersedesDisplayedLocalSuggestion() {
    let harness = FeedbackHarness()
    guard let request = harness.displayRankedResult() else {
        Issue.record("ranked result must be displayed")
        return
    }
    // 云端建议接管展示槽：本地建议被取代（客户端钉住的发射语义；
    // daemon 侧行按 latest-request-wins 自行消解）。
    harness.pipeline.setDisplayedFeedback(
        requestID: "cloud-request-1",
        cloud: true
    )
    #expect(
        harness.sentenceFeedback == [
            FeedbackHarness.Record(requestID: request.requestID, outcome: "superseded")
        ]
    )
    harness.pipeline.markDisplayedSuggestionAdopted()
    #expect(
        harness.cloudFeedback == [
            FeedbackHarness.Record(requestID: "cloud-request-1", outcome: "adopted")
        ]
    )
}

@Test @MainActor
func feedbackWithoutDisplayedSuggestionIsSilent() {
    let harness = FeedbackHarness()
    harness.pipeline.markDisplayedSuggestionAdopted()
    harness.pipeline.markDisplayedSuggestionRejected()
    harness.pipeline.beginInputCycle()
    #expect(harness.sentenceFeedback.isEmpty)
    #expect(harness.cloudFeedback.isEmpty)
}
