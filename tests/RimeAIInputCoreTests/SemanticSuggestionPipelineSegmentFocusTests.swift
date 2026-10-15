import Foundation
import Testing
@testable import RimeAIInputCore

// MARK: - Segment focus pipeline tests (KBD-006/007)

/// Deterministic scheduling double: records scheduled blocks, runs
/// off-main work inline.
private final class SegmentFocusScheduling:
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

    private struct Entry {
        let delay: TimeInterval
        let action: @MainActor () -> Void
        let box: TaskBox
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func scheduleOnMain(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any SemanticSuggestionTask {
        let box = TaskBox()
        lock.withLock { entries.append(Entry(delay: delay, action: action, box: box)) }
        return box
    }

    func dispatchOffMain(_ action: @escaping @Sendable () -> Void) {
        action()
    }

    func dispatchOnMain(_ action: @escaping @MainActor () -> Void) {
        MainActor.assumeIsolated {
            action()
        }
    }

    /// Fires the earliest scheduled block; returns its delay or nil.
    @MainActor
    func fireNextScheduled() -> TimeInterval? {
        let entry = lock.withLock { () -> Entry? in
            guard !entries.isEmpty else {
                return nil
            }
            return entries.removeFirst()
        }
        guard let entry, !entry.box.isCancelled else {
            return nil
        }
        entry.action()
        return entry.delay
    }
}

/// 在途本地请求的完成闭包包裝（避免大元组）。
private struct PendingLocalCompletion: @unchecked Sendable {
    let complete: @Sendable (SemanticInferenceResult?) -> Void

    init(_ complete: @escaping @Sendable (SemanticInferenceResult?) -> Void) {
        self.complete = complete
    }
}

/// 已应用的后缀重推记录（避免大元组）。
private struct AppliedRefinedText {
    let index: Int
    let text: String
    let token: CompositionToken
}

/// Minimal harness for suffix refinement (KBD-006) and segmented
/// suggestion (KBD-007) tests. Deliberately not actor-isolated: the
/// dependency closures are nonisolated `@Sendable`; tests drive
/// everything from the main actor.
private final class SegmentFocusHarness: @unchecked Sendable {
    let scheduling = SegmentFocusScheduling()
    var flagsSecureInput = false
    var composition = CompositionState(appSessionID: "app-session")
    var rimeCandidateTable: [String: [String]] = [:]
    var allowRefinement = true
    private(set) var localRequests: [SemanticInferenceRequest] = []
    private(set) var pendingCompletions: [PendingLocalCompletion] = []
    private(set) var appliedRefined: [AppliedRefinedText] = []

    @MainActor
    lazy var pipeline = SemanticSuggestionPipeline(
        dependencies: SemanticSuggestionDependencies(
            now: { 1_000 },
            scheduling: scheduling,
            isSecureEventInputEnabled: { [self] in flagsSecureInput },
            isLocalInferenceAllowed: { bundleIdentifier in
                bundleIdentifier == "com.apple.notes"
            },
            isCloudConfigured: { false },
            contextPolicy: { _ in .standard },
            cloudModelID: { RimeAICloudConfiguration.defaultRankingModelID },
            characterSet: { .simplified },
            sendLocalInference: { [self] request, completion in
                localRequests.append(request)
                pendingCompletions.append(PendingLocalCompletion(completion))
            },
            cancelLocalInference: { _ in },
            rimeCandidates: { [self] pinyin in
                rimeCandidateTable[pinyin] ?? []
            },
            clientSessionID: "client-session",
            loadCloudAPIKey: { nil },
            cloudHistorySnapshot: { _ in nil },
            currentHistoryGeneration: { nil },
            sendCloudInference: { _, _, _ in },
            cancelCloudInference: { _ in },
            disconnectCloud: {},
            compositionSnapshot: { [self] in composition },
            applySemanticCandidate: { [self] text, token, decision, segments in
                composition.applySemanticCandidate(
                    text,
                    token: token,
                    decision: decision,
                    segments: segments
                )
            },
            onEvent: nil
        )
    )

    /// Builds `[nihao，][shijie。][zhenhao]` with focus on `nihao`:
    /// two suffix pinyin segments (shijie, zhenhao).
    func buildThreeSegmentComposition() {
        _ = composition.replaceInput(pinyin: "nihao", candidates: ["你好"])
        composition.appendLiteral("，")
        _ = composition.replaceInput(pinyin: "shijie", candidates: ["世界"])
        composition.appendLiteral("。")
        _ = composition.replaceInput(pinyin: "zhenhao", candidates: ["真好"])
        #expect(composition.moveFocusLeft(finalizedText: "真好") == true)
        #expect(composition.moveFocusLeft(finalizedText: "世界") == true)
        #expect(composition.pinyin == "nihao")
        #expect(composition.suffixSegments.count == 3)
    }

    @MainActor
    func scheduleSuffixRefinement() {
        pipeline.scheduleSuffixRefinement(
            token: composition.token,
            bundleIdentifier: "com.apple.notes",
            contextProvider: { _ in "上下文" },
            applyRefinedText: { [self] suffixIndex, text, token in
                appliedRefined.append(
                    AppliedRefinedText(
                        index: suffixIndex,
                        text: text,
                        token: token
                    )
                )
                guard allowRefinement else {
                    return false
                }
                return composition.updateSuffixCommittedText(
                    atSuffixIndex: suffixIndex,
                    committedText: text,
                    token: token
                )
            }
        )
    }

    @MainActor
    /// 完成路径经 `Task { @MainActor }` 跳线程；测试用例需在断言前
    /// `await pumpMainActor()` 让在途任务执行。
    func pumpMainActor() async {
        for _ in 0 ..< 10 {
            await Task.yield()
        }
    }

    func completeLastLocalRequest(
        rankedCandidate: String?,
        request: SemanticInferenceRequest,
        token: CompositionToken
    ) {
        guard let completion = pendingCompletions.popLast()?.complete else {
            Issue.record("no pending local completion")
            return
        }
        completion(
            SemanticInferenceResult(
                status: "ok",
                requestID: request.requestID,
                compositionID: token.compositionID.uuidString,
                revision: token.revision,
                appSessionID: token.appSessionID,
                rankedCandidate: rankedCandidate,
                sentenceSuggestion: nil,
                confidence: 0.9
            )
        )
    }
}

@Test @MainActor
func suffixRefinementUpdatesSuffixCommittedTextInOrder() async {
    let harness = SegmentFocusHarness()
    harness.buildThreeSegmentComposition()
    harness.rimeCandidateTable["shijie"] = ["世界", "时间"]
    harness.rimeCandidateTable["zhenhao"] = ["真好", "正好"]
    let token = harness.composition.token

    harness.scheduleSuffixRefinement()
    #expect(harness.scheduling.fireNextScheduled() != nil)

    // 第一段（shijie）请求先发：ranked-only、无段布局、上下文含
    // 应用内上下文与焦点段。
    guard harness.localRequests.count == 1 else {
        Issue.record("expected one refinement request")
        return
    }
    let first = harness.localRequests[0]
    #expect(first.pinyin == "shijie")
    #expect(first.allowSentence == false)
    #expect(first.segments == nil)
    #expect(first.context.hasPrefix("上下文"))
    #expect(first.candidates == ["世界", "时间"])

    harness.completeLastLocalRequest(
        rankedCandidate: "时间",
        request: first,
        token: token
    )
    await harness.pumpMainActor()

    // 应用后自动推进到第二段（zhenhao）。
    #expect(harness.appliedRefined.count == 1)
    #expect(harness.appliedRefined[0].text == "时间")
    #expect(harness.composition.suffixSegments[0].committedText == "时间")
    guard harness.localRequests.count == 2 else {
        Issue.record("expected second refinement request")
        return
    }
    #expect(harness.localRequests[1].pinyin == "zhenhao")

    harness.completeLastLocalRequest(
        rankedCandidate: "正好",
        request: harness.localRequests[1],
        token: harness.composition.token
    )
    await harness.pumpMainActor()

    #expect(harness.appliedRefined.count == 2)
    // zhenhao 段在数组下标 2（与前段之间隔着字面量段“。”）。
    #expect(harness.composition.suffixSegments[2].committedText == "正好")
    #expect(harness.composition.displayString == "nihao，时间。正好")
    #expect(harness.composition.rawCompositionString == "nihao，shijie。zhenhao")
}

@Test @MainActor
func suffixRefinementAbortsWhenUserEditsMidFlight() async {
    let harness = SegmentFocusHarness()
    harness.buildThreeSegmentComposition()
    harness.rimeCandidateTable["shijie"] = ["世界", "时间"]
    let token = harness.composition.token

    harness.scheduleSuffixRefinement()
    #expect(harness.scheduling.fireNextScheduled() != nil)
    guard harness.localRequests.count == 1 else {
        Issue.record("expected one refinement request")
        return
    }

    // 用户在响应前编辑焦点段：revision 前进使结果过期，整批作废，
    // 不再推进第二段。
    _ = harness.composition.replaceInput(
        pinyin: "nihaos",
        candidates: ["你好"]
    )
    harness.completeLastLocalRequest(
        rankedCandidate: "时间",
        request: harness.localRequests[0],
        token: token
    )
    await harness.pumpMainActor()

    // 应用被 token 守卫拒绝（harness 记录了尝试但组合状态未变），
    // 批作废：不推进第二段。
    #expect(harness.composition.suffixSegments[0].committedText == "世界")
    #expect(harness.composition.suffixSegments[2].committedText == "真好")
    #expect(harness.localRequests.count == 1)
}

@Test @MainActor
func suffixRefinementSkipsSegmentsWithoutRimeCandidates() {
    let harness = SegmentFocusHarness()
    harness.buildThreeSegmentComposition()
    // 只有第二段有候选：第一段直接跳过，不发生请求。
    harness.rimeCandidateTable["zhenhao"] = ["真好", "正好"]

    harness.scheduleSuffixRefinement()
    #expect(harness.scheduling.fireNextScheduled() != nil)

    guard harness.localRequests.count == 1 else {
        Issue.record("expected only the zhenhao request")
        return
    }
    #expect(harness.localRequests[0].pinyin == "zhenhao")
}

@Test @MainActor
func suffixRefinementIneligibleOnLastSegmentFocus() {
    let harness = SegmentFocusHarness()
    _ = harness.composition.replaceInput(pinyin: "nihao", candidates: ["你好"])

    harness.scheduleSuffixRefinement()
    // 后缀为空：调度不产生任何任务。
    #expect(harness.scheduling.fireNextScheduled() == nil)
    #expect(harness.localRequests.isEmpty)
}

// MARK: - Segmented suggestion (KBD-007)

@Test @MainActor
func segmentedSuggestionWritesAllSegmentsAndClearsActive() {
    let harness = SegmentFocusHarness()
    harness.buildThreeSegmentComposition()
    _ = harness.composition.replaceInput(pinyin: "nihao", candidates: ["你好"])
    // 重新聚焦 nihao 后活跃段有候选；模拟云端整句已通过
    // applySemanticCandidate 挂到建议槽。
    let segments = harness.composition.inferenceSegments
    #expect(segments == nil) // 焦点在中间段：无跨段布局
    // 按段应用走 CompositionState 合同，不依赖布局：
    let token = harness.composition.token
    let applied = harness.composition.applySegmentedSuggestion(
        ["你好", "时间", "真好"],
        token: token
    )
    #expect(applied)
    #expect(harness.composition.pinyin.isEmpty)
    // “，”在焦点字面量运行，“。”在后缀字面量段，不在拼音段定稿里。
    #expect(harness.composition.prefixSegments.map(\.committedText) == ["你好"])
    #expect(
        harness.composition.suffixSegments.map(\.committedText)
            == ["时间", "。", "真好"]
    )
    #expect(harness.composition.displayString == "你好，时间。真好")
    #expect(harness.composition.semanticCandidate == nil)
    #expect(harness.composition.hasComposition)
}

@Test @MainActor
func segmentedSuggestionRejectsCountMismatchAndStaleToken() {
    let harness = SegmentFocusHarness()
    harness.buildThreeSegmentComposition()
    let staleToken = harness.composition.token

    // 数量不匹配（缺焦点段）。
    let countMismatch = harness.composition.applySegmentedSuggestion(
        ["你好", "时间"],
        token: harness.composition.token
    )
    #expect(!countMismatch)
    #expect(harness.composition.pinyin == "nihao")

    // 用户编辑（replaceInput 前进 revision）后原 token 过期。
    _ = harness.composition.replaceInput(
        pinyin: "nihaos",
        candidates: ["你好"]
    )
    let staleApplication = harness.composition.applySegmentedSuggestion(
        ["你好", "时间", "真好"],
        token: staleToken
    )
    #expect(!staleApplication)
    #expect(harness.composition.pinyin == "nihaos")
}

// MARK: - Segment text splitting (KBD-007 basis)

@Test
func segmentTextsSplitsBySeparatorsInOrder() {
    let segments: [PinyinSegment] = [
        PinyinSegment(pinyin: "nihao", separator: "，", committedText: "你好"),
        PinyinSegment(pinyin: "shijie", separator: "", committedText: nil),
    ]
    #expect(
        CloudGeneratedSentencePolicy.segmentTexts(
            text: "你好，世界",
            pinyinSegments: segments
        ) == ["你好", "世界"]
    )
    // 分隔符缺失：nil。
    #expect(
        CloudGeneratedSentencePolicy.segmentTexts(
            text: "你好世界",
            pinyinSegments: segments
        ) == nil
    )
    // 切片为空：nil。
    #expect(
        CloudGeneratedSentencePolicy.segmentTexts(
            text: "，世界",
            pinyinSegments: segments
        ) == nil
    )
    // 单段布局：整句即切片。
    let single = [PinyinSegment(pinyin: "nihao", separator: "")]
    #expect(
        CloudGeneratedSentencePolicy.segmentTexts(
            text: "你好",
            pinyinSegments: single
        ) == ["你好"]
    )
}

