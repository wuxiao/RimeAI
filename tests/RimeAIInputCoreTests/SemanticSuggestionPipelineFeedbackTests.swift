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
    func displayRankedResult(text: String = "你好") -> SemanticInferenceRequest? {
        _ = composition.replaceInput(
            pinyin: "nihao",
            candidates: [text]
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
                rankedCandidate: text,
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
func sameTextMainCandidateCommitsAsAdoptedViaMain() {
    // 首选一致合并场景（2026-10-24 神经臂假阴性裁决）：Space 上屏
    // 文本与展示建议逐字相同 → adopted_via_main（保留路径信息）；
    // 文本不同才是真 rejected。
    let harness = FeedbackHarness()
    guard let request = harness.displayRankedResult(text: "提高") else {
        Issue.record("ranked result must be displayed")
        return
    }
    harness.pipeline.markDisplayedSuggestionRejected(committedText: "提高")
    #expect(
        harness.sentenceFeedback == [
            FeedbackHarness.Record(
                requestID: request.requestID,
                outcome: "adopted_via_main"
            )
        ]
    )
    harness.pipeline.setDisplayedFeedback(
        requestID: "r2", cloud: false, text: "微调"
    )
    harness.pipeline.markDisplayedSuggestionRejected(committedText: "调整")
    #expect(
        harness.sentenceFeedback.count == 2
            && harness.sentenceFeedback.last?.outcome == "rejected"
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

@Test @MainActor
func localFrameReplacementSupersedesDisplayedLocalSuggestion() {
    // 孤儿化修复（LM-003 验证发现）：本地帧被更新的本地帧替换
    // （如 neural_late 帧链 / ranked→sentence 帧间替换）时，旧帧
    // 同样发 superseded——否则 daemon 侧旧行永远 pending。
    let harness = FeedbackHarness()
    guard let request = harness.displayRankedResult() else {
        Issue.record("ranked result must be displayed")
        return
    }
    harness.pipeline.setDisplayedFeedback(
        requestID: "local-frame-2", cloud: false, text: "你好世界"
    )
    #expect(
        harness.sentenceFeedback == [
            FeedbackHarness.Record(requestID: request.requestID, outcome: "superseded")
        ]
    )
    // 替换后的新帧仍走正常收尾：采纳只 resolve 最新帧。
    harness.pipeline.markDisplayedSuggestionAdopted()
    #expect(
        harness.sentenceFeedback.count == 2
            && harness.sentenceFeedback.last?.requestID == "local-frame-2"
            && harness.sentenceFeedback.last?.outcome == "adopted"
    )
    #expect(harness.cloudFeedback.isEmpty)
}

@Test @MainActor
func sameFrameReRegistrationDoesNotResendSuperseded() {
    // 同帧重复登记（同 requestID）不重复发 superseded；跨帧链
    // 重复替换只对各自旧帧发一次。
    let harness = FeedbackHarness()
    harness.pipeline.setDisplayedFeedback(
        requestID: "local-a", cloud: false, text: "甲"
    )
    harness.pipeline.setDisplayedFeedback(
        requestID: "local-a", cloud: false, text: "甲"
    )
    #expect(harness.sentenceFeedback.isEmpty)
    harness.pipeline.setDisplayedFeedback(
        requestID: "local-b", cloud: false, text: "乙"
    )
    harness.pipeline.setDisplayedFeedback(
        requestID: "local-b", cloud: false, text: "乙"
    )
    #expect(
        harness.sentenceFeedback == [
            FeedbackHarness.Record(requestID: "local-a", outcome: "superseded")
        ]
    )
}

@Test @MainActor
func cloudFrameReplacementKeepsCloudLifecycleUntouched() {
    // 云帧被替换不发 superseded：云反馈生命周期独立
    // （emitDisplayedFeedback 走 sendCloudFeedback 收尾）。
    let harness = FeedbackHarness()
    harness.pipeline.setDisplayedFeedback(
        requestID: "cloud-a", cloud: true, text: "云甲"
    )
    harness.pipeline.setDisplayedFeedback(
        requestID: "cloud-b", cloud: true, text: "云乙"
    )
    #expect(harness.sentenceFeedback.isEmpty)
    #expect(harness.cloudFeedback.isEmpty)
}

@Test @MainActor
func staleDroppedFrameEmitsSuperseded() {
    // 孤儿化第二层（LM-003 驱动实测）：迟到响应到达时已不在在途槽
    // （latest-request-wins 或周期重置）——该帧的 daemon 决策行以
    // superseded 收口，不再永远 pending。
    let harness = FeedbackHarness()
    harness.pipeline.applyInferenceResult(
        nil,
        requestID: "stale-frame-1",
        token: harness.composition.token
    )
    #expect(
        harness.sentenceFeedback == [
            FeedbackHarness.Record(
                requestID: "stale-frame-1",
                outcome: "superseded"
            )
        ]
    )
    // stale 帧不触碰展示槽：既有展示建议的收尾不受影响。
    guard let request = harness.displayRankedResult() else {
        Issue.record("ranked result must be displayed")
        return
    }
    harness.pipeline.applyInferenceResult(
        nil,
        requestID: "stale-frame-2",
        token: harness.composition.token
    )
    #expect(
        harness.sentenceFeedback.count == 2
            && harness.sentenceFeedback.last?.requestID == "stale-frame-2"
    )
    harness.pipeline.markDisplayedSuggestionAdopted()
    #expect(
        harness.sentenceFeedback.last?.requestID == request.requestID
            && harness.sentenceFeedback.last?.outcome == "adopted"
    )
}
