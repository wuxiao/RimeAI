import Foundation
import Testing
@testable import RimeAIInputCore

// MARK: - DaemonSentenceLateFrame 协议层

@Test
func sentenceLateFrameDecodesSnakeCaseJSON() throws {
    let cid = UUID().uuidString
    let json = """
    {"schema_version":1,"type":"sentence_late","status":"ok",
     "request_id":"req-1","composition_id":"\(cid)",
     "revision":3,"app_session_id":"app-1",
     "sentence_suggestion":"请执行命令","confidence":0.5,
     "model_artifact_id":"stub:v3","elapsed_ms":123.5}
    """
    let data = Data(json.utf8)
    let frame = try JSONDecoder().decode(
        DaemonSentenceLateFrame.self, from: data
    )
    #expect(frame.type == "sentence_late")
    #expect(frame.requestID == "req-1")
    #expect(frame.revision == 3)
    #expect(frame.sentenceSuggestion == "请执行命令")
    #expect(frame.isValid)

    let token = CompositionToken(
        compositionID: UUID(uuidString: cid)!,
        revision: 3,
        appSessionID: "app-1"
    )
    #expect(frame.matches(token))

    let result = frame.asInferenceResult()
    #expect(result.decision == .sentenceSuggestion)
    #expect(result.displayCandidate == "请执行命令")
    #expect(result.rankedCandidate == nil)
}

@Test
func sentenceLateFrameRejectsStructurallyInvalidPayloads() {
    func frame(
        _ suggestion: String, confidence: Double?
    ) -> DaemonSentenceLateFrame {
        DaemonSentenceLateFrame(
            status: "ok",
            requestID: "r",
            compositionID: nil,
            revision: nil,
            appSessionID: nil,
            sentenceSuggestion: suggestion,
            confidence: confidence
        )
    }
    #expect(!frame("", confidence: 0.5).isValid)
    #expect(!frame("a\nb", confidence: 0.5).isValid)
    #expect(!frame(String(repeating: "字", count: 31), confidence: 0.5).isValid)
    #expect(!frame("命令", confidence: 1.5).isValid)
    #expect(!frame("命令", confidence: nil).isValid)
    #expect(frame(String(repeating: "字", count: 30), confidence: 0).isValid)
    #expect(!frame("命令", confidence: 0.5).matches(
        CompositionToken(
            compositionID: UUID(), revision: 9, appSessionID: "other"
        )
    ))
}

// MARK: - 测试替身

private final class NeuralLateScheduling:
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
        lock.withLock { entries.append(Entry(action: action, box: box)) }
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
        return 0.1
    }
}

private final class NeuralLateHarness: @unchecked Sendable {
    let scheduling = NeuralLateScheduling()
    var flagsSecureInput = false
    var allowApply = true
    var composition = CompositionState(appSessionID: "app-session")
    private(set) var localRequests: [SemanticInferenceRequest] = []
    private(set) var appliedCandidates:
        [(text: String, decision: SemanticInferenceDecision)] = []
    private(set) var diagnostics: [RimeAIDiagnosticEvent] = []
    private(set) var secureInputEvents = 0

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
            sendLocalInference: { [self] request, _ in
                localRequests.append(request)
            },
            cancelLocalInference: { _ in },
            rimeCandidates: { _ in [] },
            clientSessionID: "client-session",
            loadCloudAPIKey: { nil },
            cloudHistorySnapshot: { _ in nil },
            currentHistoryGeneration: { nil },
            sendCloudInference: { _, _, _ in },
            cancelCloudInference: { _ in },
            disconnectCloud: {},
            compositionSnapshot: { [self] in composition },
            applySemanticCandidate: { [self] text, _, decision, _ in
                guard allowApply else {
                    return false
                }
                appliedCandidates.append((text, decision))
                return true
            },
            onEvent: { [self] event in
                switch event {
                case let .diagnostic(metric):
                    diagnostics.append(metric)
                case .latency:
                    break
                case .secureInputDetected:
                    secureInputEvents += 1
                case .suggestionSlotChanged:
                    break
                }
            }
        )
    )

    func typePinyin(_ pinyin: String, candidates: [String]) {
        _ = composition.replaceInput(pinyin: pinyin, candidates: candidates)
    }

    @discardableResult
    @MainActor
    func runLocalSendCycle() -> SemanticInferenceRequest? {
        pipeline.scheduleInference(
            token: composition.token,
            bundleIdentifier: "com.apple.notes",
            contextProvider: { _ in "上下文" }
        )
        guard scheduling.fireNextScheduled() != nil else {
            return nil
        }
        return localRequests.last
    }
}

// MARK: - 流水线迟到帧应用（双延迟档神经臂）

private func makeFrame(
    requestID: String,
    token: CompositionToken,
    suggestion: String = "请执行命令",
    confidence: Double = 0.5
) -> DaemonSentenceLateFrame {
    DaemonSentenceLateFrame(
        status: "ok",
        requestID: requestID,
        compositionID: token.compositionID.uuidString,
        revision: token.revision,
        appSessionID: token.appSessionID,
        sentenceSuggestion: suggestion,
        confidence: confidence,
        modelArtifactID: "stub:mlx-8bit:v3",
        elapsedMilliseconds: 140
    )
}

@Test @MainActor
func neuralLateFrameAppliesToSuggestionSlotAfterSyncResult() {
    let harness = NeuralLateHarness()
    harness.typePinyin("qingzhixing", candidates: ["请执行"])
    let token = harness.composition.token
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    // 同步档先出（重排候选）。
    harness.pipeline.applyInferenceResult(
        SemanticInferenceResult(
            status: "ok",
            requestID: request.requestID,
            compositionID: token.compositionID.uuidString,
            revision: token.revision,
            appSessionID: token.appSessionID,
            rankedCandidate: "请执行",
            sentenceSuggestion: nil,
            confidence: 0.8,
            decision: .rankedCandidate
        ),
        requestID: request.requestID,
        token: token
    )
    guard case let .candidate(syncText, syncDecision, _) =
        harness.pipeline.presentation
    else {
        Issue.record("sync result must present a candidate")
        return
    }
    #expect(syncText == "请执行")
    #expect(syncDecision == .rankedCandidate)

    // 神经臂迟到帧随后接管同一建议位。
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(requestID: request.requestID, token: token)
    )
    guard case let .candidate(text, decision, confidence) =
        harness.pipeline.presentation
    else {
        Issue.record("late frame must present a candidate")
        return
    }
    #expect(text == "请执行命令")
    #expect(decision == .sentenceSuggestion)
    #expect(confidence == 0.5)
    #expect(harness.appliedCandidates.last?.text == "请执行命令")
    #expect(
        harness.appliedCandidates.last?.decision == .sentenceSuggestion
    )
    #expect(harness.diagnostics.contains(.resultShown))
    #expect(harness.diagnostics.contains(.sentenceSuggestionShown))
}

@Test @MainActor
func neuralLateFrameRejectsAdvancedRevisionAndUnknownRequest() {
    let harness = NeuralLateHarness()
    harness.typePinyin("qingzhixing", candidates: ["请执行"])
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    let staleToken = harness.composition.token

    // 击键推进 revision：旧帧变 stale，建议位保持原状。
    harness.typePinyin("qingzhixingm", candidates: ["请执行命"])
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(requestID: request.requestID, token: staleToken)
    )
    #expect(harness.diagnostics.suffix(1) == [.staleResult])
    #expect(harness.appliedCandidates.isEmpty)

    // 从未登记过的 requestID 直接丢弃。
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(
            requestID: "never-registered",
            token: harness.composition.token
        )
    )
    #expect(harness.diagnostics.suffix(1) == [.staleResult])
    #expect(harness.appliedCandidates.isEmpty)
}

@Test @MainActor
func neuralLateExpectationNotRegisteredWithoutAllowSentence() {
    let harness = NeuralLateHarness()
    // 单键组合不送整句请求 → 不登记神经臂期望。
    harness.typePinyin("q", candidates: ["请"])
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    #expect(!request.allowSentence)
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(
            requestID: request.requestID,
            token: harness.composition.token
        )
    )
    #expect(harness.diagnostics.suffix(1) == [.staleResult])
    #expect(harness.appliedCandidates.isEmpty)
}

@Test @MainActor
func neuralLateFrameFailsClosedOnSecureInput() {
    let harness = NeuralLateHarness()
    harness.typePinyin("qingzhixing", candidates: ["请执行"])
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    let token = harness.composition.token
    harness.flagsSecureInput = true
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(requestID: request.requestID, token: token)
    )
    #expect(harness.secureInputEvents == 1)
    #expect(harness.appliedCandidates.isEmpty)
}

@Test @MainActor
func neuralLateFrameDropsWhenCloudOwnsTheSlot() {
    let harness = NeuralLateHarness()
    harness.typePinyin("qingzhixing", candidates: ["请执行"])
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    let token = harness.composition.token
    let diagnosticsBefore = harness.diagnostics.count
    harness.pipeline.cloudSuggestionApplied = true
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(requestID: request.requestID, token: token)
    )
    #expect(harness.appliedCandidates.isEmpty)
    #expect(harness.diagnostics.count == diagnosticsBefore)
}

@Test @MainActor
func neuralLateFrameDropsStructurallyInvalidPayloads() {
    let harness = NeuralLateHarness()
    harness.typePinyin("qingzhixing", candidates: ["请执行"])
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    let token = harness.composition.token
    for suggestion in ["", "a\nb", String(repeating: "字", count: 31)] {
        harness.pipeline.applyNeuralSentenceLate(
            makeFrame(
                requestID: request.requestID,
                token: token,
                suggestion: suggestion
            )
        )
    }
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(requestID: request.requestID, token: token, confidence: 2)
    )
    #expect(harness.appliedCandidates.isEmpty)
    #expect(harness.pipeline.presentation == .analyzing)
}

@Test @MainActor
func neuralLateFrameIsConsumedOnce() {
    let harness = NeuralLateHarness()
    harness.typePinyin("qingzhixing", candidates: ["请执行"])
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    let token = harness.composition.token
    let frame = makeFrame(requestID: request.requestID, token: token)
    harness.pipeline.applyNeuralSentenceLate(frame)
    #expect(harness.appliedCandidates.count == 1)
    harness.pipeline.applyNeuralSentenceLate(frame)
    #expect(harness.appliedCandidates.count == 1)
    #expect(harness.diagnostics.suffix(1) == [.staleResult])
}

@Test @MainActor
func neuralLateFrameSupersededByNewRequestRegistration() {
    let harness = NeuralLateHarness()
    harness.typePinyin("qingzhixing", candidates: ["请执行"])
    guard let first = harness.runLocalSendCycle() else {
        Issue.record("first request must be sent")
        return
    }
    harness.typePinyin("qingzhixingm", candidates: ["请执行命"])
    guard let second = harness.runLocalSendCycle() else {
        Issue.record("second request must be sent")
        return
    }
    // 最新登记胜出：第一请求的迟到帧按 stale 处理。
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(
            requestID: first.requestID,
            token: CompositionToken(
                compositionID: UUID(uuidString: first.compositionID)!,
                revision: first.revision,
                appSessionID: first.appSessionID
            )
        )
    )
    #expect(harness.diagnostics.suffix(1) == [.staleResult])
    // 第二请求（当前 token）的帧正常应用。
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(
            requestID: second.requestID,
            token: harness.composition.token
        )
    )
    #expect(harness.appliedCandidates.count == 1)
}

// MARK: - reveal 修复轮（A-F2/C-F1、B-F1、A-F6）

@Test @MainActor
func syncResultArrivingAfterNeuralLateDoesNotOverwriteIt() {
    // §4.3.1 冻结仲裁的反向序兜底：daemon 两臂无写序保证，同步帧
    // 可能晚于神经迟到帧到达。神经已接管的建议位不得被同步 ok 帧
    // 覆写（reveal A-F2/C-F1）。
    let harness = NeuralLateHarness()
    harness.typePinyin("qingzhixing", candidates: ["请执行"])
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    let token = harness.composition.token
    // 神经帧先到并接管建议位。
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(requestID: request.requestID, token: token)
    )
    guard case let .candidate(neuralText, neuralDecision, _) =
        harness.pipeline.presentation
    else {
        Issue.record("neural frame must present a candidate first")
        return
    }
    #expect(neuralText == "请执行命令")
    #expect(neuralDecision == .sentenceSuggestion)
    let appliedByNeural = harness.appliedCandidates.count

    // 同步 ok 帧后到：只消费在途槽，不得覆写展示。
    harness.pipeline.applyInferenceResult(
        SemanticInferenceResult(
            status: "ok",
            requestID: request.requestID,
            compositionID: token.compositionID.uuidString,
            revision: token.revision,
            appSessionID: token.appSessionID,
            rankedCandidate: "请执行",
            sentenceSuggestion: nil,
            confidence: 0.8,
            decision: .rankedCandidate
        ),
        requestID: request.requestID,
        token: token
    )
    guard case let .candidate(text, decision, _) =
        harness.pipeline.presentation
    else {
        Issue.record(
            "late sync ok frame must not collapse the neural candidate"
        )
        return
    }
    #expect(text == "请执行命令")
    #expect(decision == .sentenceSuggestion)
    #expect(harness.appliedCandidates.count == appliedByNeural)
    #expect(harness.diagnostics.contains(.supersededByNeuralLate))
    // 在途槽已被消费：后续同请求帧按 stale 处理。
    harness.pipeline.applyInferenceResult(
        SemanticInferenceResult(
            status: "ok",
            requestID: request.requestID,
            compositionID: token.compositionID.uuidString,
            revision: token.revision,
            appSessionID: token.appSessionID,
            rankedCandidate: "请执行",
            sentenceSuggestion: nil,
            confidence: 0.8,
            decision: .rankedCandidate
        ),
        requestID: request.requestID,
        token: token
    )
    #expect(harness.diagnostics.suffix(2).contains(.staleResult))
}

@Test @MainActor
func syncTimeoutAfterNeuralLateDoesNotClearPresentation() {
    // 反向序的 timeout 形态：同步超时终态不得把已上屏的神经整句
    // 塌成 .failure（reveal A-F2/C-F1 的第二种复现形态）。
    let harness = NeuralLateHarness()
    harness.typePinyin("qingzhixing", candidates: ["请执行"])
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    let token = harness.composition.token
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(requestID: request.requestID, token: token)
    )
    harness.pipeline.applyInferenceResult(
        SemanticInferenceResult(
            status: "timeout",
            requestID: request.requestID,
            compositionID: token.compositionID.uuidString,
            revision: token.revision,
            appSessionID: token.appSessionID,
            rankedCandidate: nil,
            sentenceSuggestion: nil,
            confidence: nil
        ),
        requestID: request.requestID,
        token: token
    )
    guard case let .candidate(text, decision, _) =
        harness.pipeline.presentation
    else {
        Issue.record(
            "late sync timeout must not collapse the neural candidate"
        )
        return
    }
    #expect(text == "请执行命令")
    #expect(decision == .sentenceSuggestion)
    #expect(harness.diagnostics.contains(.supersededByNeuralLate))
    #expect(harness.diagnostics.contains(.timeout) == false)
}

@Test @MainActor
func neuralLateFrameWithWrongScriptFallsBackToSanitizedText() {
    // reveal B-F1：神经臂可产出传统字形（基线 flips 有实例）；迟到帧
    // 的 script-mismatch 与同步路径同款字形转写，而不是静默丢弃。
    let harness = NeuralLateHarness()
    harness.typePinyin("qingzhixing", candidates: ["请执行"])
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    let token = harness.composition.token
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(
            requestID: request.requestID,
            token: token,
            suggestion: "請執行命令"
        )
    )
    guard case let .candidate(text, decision, _) =
        harness.pipeline.presentation
    else {
        Issue.record("script-mismatch late frame must fall back to text")
        return
    }
    #expect(text == "请执行命令")
    #expect(decision == .sentenceSuggestion)
    #expect(harness.appliedCandidates.last?.text == "请执行命令")
    #expect(harness.diagnostics.contains(.resultShown))
}

@Test @MainActor
func invalidateClearsNeuralLateExpectationSlot() {
    // reveal A-F6：invalidate 与同步在途槽同位置清理神经臂期望槽，
    // 不再依赖「每个调用点都恰好推进 revision」的隐式不变量。
    let harness = NeuralLateHarness()
    harness.typePinyin("qingzhixing", candidates: ["请执行"])
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    let token = harness.composition.token
    harness.pipeline.invalidate()
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(requestID: request.requestID, token: token)
    )
    #expect(harness.appliedCandidates.isEmpty)
    #expect(harness.pipeline.presentation == .analyzing)
}


// MARK: - LM-002 对比行快照（本地/云端分两行展示）

@Test @MainActor
func neuralLateFrameSnapshotsLocalComparisonAndExpiresWithToken() {
    let harness = NeuralLateHarness()
    harness.typePinyin("qingzhixing", candidates: ["请执行"])
    let token = harness.composition.token
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(requestID: request.requestID, token: token)
    )
    // 迟到帧应用后：主槽为神经建议，本地快照可供对比行展示。
    #expect(harness.pipeline.neuralLateApplied)
    #expect(harness.pipeline.localComparisonSuggestion == "请执行命令")

    // 击键推进 token：快照随失效链清空。
    harness.typePinyin("q", candidates: ["请"])
    #expect(harness.pipeline.localComparisonSuggestion == nil)
    #expect(!harness.pipeline.neuralLateApplied)
}

@Test @MainActor
func cloudTakeoverClearsNeuralLabelButLateFrameStillSnapshots() {
    let harness = NeuralLateHarness()
    harness.typePinyin("qingzhixing", candidates: ["请执行"])
    let token = harness.composition.token
    guard let request = harness.runLocalSendCycle() else {
        Issue.record("local request must be sent")
        return
    }
    // 云端先接管主槽（模拟 applyCloudGeneratedResult 的状态效果）。
    harness.pipeline.cloudSuggestionApplied = true
    harness.pipeline.presentation = .candidate(
        text: "请执行命令",
        decision: .sentenceSuggestion,
        confidence: 0.9
    )
    harness.pipeline.neuralLateAppliedToken = nil

    // 神经迟到帧晚到：主槽不动（云端所有权），但本地快照仍记录，
    // 供对比行分两行展示。
    harness.pipeline.applyNeuralSentenceLate(
        makeFrame(requestID: request.requestID, token: token)
    )
    #expect(!harness.pipeline.neuralLateApplied)
    guard case let .candidate(text, _, _) = harness.pipeline.presentation
    else {
        Issue.record("cloud suggestion must own the slot")
        return
    }
    #expect(text == "请执行命令")
    #expect(harness.pipeline.localComparisonSuggestion == "请执行命令")
}
