import Foundation
import Testing
@testable import RimeAIInputCore

// MARK: - 测试工具

/// 脚本化引擎：start 时同步回放已入队事件，也可在测试中途
/// 手动触发以模拟异步识别。
final class ScriptedVoiceEngine: VoiceDictationEngine, @unchecked Sendable {
    let engineID = "test-asr-engine"

    private let lock = NSLock()
    private var queuedEvents: [VoiceDictationEngineEvent] = []
    private var activeSink: (@Sendable (VoiceDictationEngineEvent) -> Void)?
    private(set) var cancelledRequestIDs: [String] = []
    private(set) var startedRequestIDs: [String] = []

    func enqueue(_ events: [VoiceDictationEngineEvent]) {
        lock.lock()
        queuedEvents.append(contentsOf: events)
        lock.unlock()
    }

    func trigger(_ event: VoiceDictationEngineEvent) {
        lock.lock()
        let sink = activeSink
        lock.unlock()
        sink?(event)
    }

    func start(
        requestID: String,
        mode: VoiceDictationMode,
        deadlineMilliseconds: Int,
        maximumDurationMilliseconds: Int,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {
        lock.lock()
        startedRequestIDs.append(requestID)
        activeSink = events
        let replay = queuedEvents
        queuedEvents.removeAll()
        lock.unlock()
        for event in replay {
            events(event)
        }
    }

    func cancel(requestID: String) {
        lock.lock()
        cancelledRequestIDs.append(requestID)
        lock.unlock()
    }

    var cancelledRequestIDsSnapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return cancelledRequestIDs
    }
}

/// 线程安全的输出收集器。
final class ReceivedOutputs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[VoiceDictationServerCore.Output]] = []

    var all: [[VoiceDictationServerCore.Output]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ outputs: [VoiceDictationServerCore.Output]) {
        lock.lock()
        storage.append(outputs)
        lock.unlock()
    }
}

private func makeContext(
    mode: VoiceDictationMode = .direct
) -> VoiceDictationSessionContext {
    VoiceDictationSessionContext(
        compositionID: UUID(),
        appSessionID: "com.apple.Safari#nonce",
        bundleID: "com.apple.Safari",
        mode: mode,
        deadlineMilliseconds: 1_500
    )
}

private func makeStart(
    requestID: String,
    mode: VoiceDictationMode = .direct
) -> VoiceDictationStart {
    VoiceDictationStart(
        requestID: requestID,
        compositionID: UUID(),
        appSessionID: "com.apple.Safari#nonce",
        bundleID: "com.apple.Safari",
        mode: mode,
        deadlineMilliseconds: 1_500
    )
}

private func localReady() -> VoiceReadyResponse {
    VoiceReadyResponse(
        capabilities: ["local_asr", "streaming"],
        networkPolicy: .offline,
        asrEngineID: "test-asr-engine"
    )
}

/// 驱动机器与服务端完成握手并返回客户端产出的 start 消息。
/// 引擎事件需在调用方 handle(start) 之前入队。
private func establishedStart(
    machine: inout VoiceDictationClientMachine,
    server: VoiceDictationServerCore,
    mode: VoiceDictationMode = .direct
) -> VoiceDictationStart {
    var hello: VoiceHelloRequest?
    for effect in machine.voiceShortcutPressed(makeContext(mode: mode)) {
        if case let .sendHello(message) = effect {
            hello = message
        }
    }
    var ready: VoiceReadyResponse?
    for output in server.handle(hello!) {
        if case let .ready(response) = output {
            ready = response
        }
    }
    var start: VoiceDictationStart?
    for effect in machine.ready(ready!) {
        if case let .sendStart(message) = effect {
            start = message
        }
    }
    return start!
}

private func firstEffect(
    _ effects: [VoiceDictationClientEffect],
    matching predicate: (VoiceDictationClientEffect) -> Bool
) -> VoiceDictationClientEffect? {
    effects.first(where: predicate)
}

// MARK: - 消息层

@Test
func voiceMessagesRoundTripThroughSnakeCaseJSON() throws {
    let start = makeStart(requestID: "req-1")
    let encoded = try JSONEncoder().encode(start)
    let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(object["protocol_version"] as? Int == 1)
    #expect(object["type"] as? String == "dictation_start")
    #expect(object["request_id"] as? String == "req-1")
    #expect(object["deadline_ms"] as? Int == 1_500)
    #expect(object["max_duration_ms"] as? Int == 60_000)
    let decoded = try JSONDecoder().decode(
        VoiceDictationStart.self,
        from: encoded
    )
    #expect(decoded == start)

    let final = VoiceDictationFinal(
        requestID: "req-1",
        finalText: "我们需要给数据库增加一个索引",
        confidence: 0.92,
        asrEngineID: "engine",
        polishApplied: false,
        elapsedMilliseconds: 120.5
    )
    let finalObject = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(final)
        ) as? [String: Any]
    )
    #expect(finalObject["final_text"] as? String != nil)
    #expect(finalObject["polish_applied"] as? Bool == false)
    #expect(finalObject["elapsed_ms"] as? Double == 120.5)
}

@Test
func deltaValidationRejectsNewlinesAndOversizeText() {
    #expect(VoiceDictationDelta(
        requestID: "req-1",
        sequence: 1,
        stableText: "我们需要",
        partialText: "给数据库",
        confidence: 0.8,
        elapsedMilliseconds: 100
    ).isValid)

    #expect(!VoiceDictationDelta(
        requestID: "req-1",
        sequence: 1,
        stableText: "包含\n换行",
        partialText: "",
        confidence: 0.8,
        elapsedMilliseconds: 0
    ).isValid)

    #expect(!VoiceDictationDelta(
        requestID: "req-1",
        sequence: 0,
        stableText: "有效",
        partialText: "",
        confidence: 0.8,
        elapsedMilliseconds: 0
    ).isValid)

    #expect(!VoiceDictationDelta(
        requestID: "req-1",
        sequence: 1,
        stableText: "",
        partialText: "",
        confidence: 0.8,
        elapsedMilliseconds: 0
    ).isValid)

    #expect(!VoiceDictationDelta(
        requestID: "req-1",
        sequence: 1,
        stableText: String(repeating: "字", count: 201),
        partialText: "",
        confidence: 0.8,
        elapsedMilliseconds: 0
    ).isValid)

    #expect(!VoiceDictationDelta(
        requestID: "req-1",
        sequence: 1,
        stableText: "有效",
        partialText: "",
        confidence: 1.5,
        elapsedMilliseconds: 0
    ).isValid)
}

@Test
func startValidationRejectsOutOfBoundsDeadlineAndDuration() {
    #expect(makeStart(requestID: "req-1").isValid)

    func startWith(
        deadline: Int = 1_500,
        duration: Int = 60_000
    ) -> VoiceDictationStart {
        VoiceDictationStart(
            requestID: "req-1",
            compositionID: UUID(),
            appSessionID: "com.apple.Safari#nonce",
            bundleID: "com.apple.Safari",
            mode: .direct,
            deadlineMilliseconds: deadline,
            maximumDurationMilliseconds: duration
        )
    }

    #expect(!startWith(deadline: 0).isValid)
    #expect(!startWith(deadline: 5_001).isValid)
    #expect(!startWith(duration: 60_001).isValid)
}

@Test
func acceptHashUsesFixedSixteenHexFormat() {
    #expect(VoiceDictationAccept.isAcceptHash(
        VoiceDictationAccept.acceptHash(for: "上屏文本")
    ))
    #expect(!VoiceDictationAccept.isAcceptHash("sha256-ABCDEF0123456789"))
    #expect(!VoiceDictationAccept.isAcceptHash("sha256-short"))
    #expect(!VoiceDictationAccept.isAcceptHash("deadbeefdeadbeef"))
    #expect(
        VoiceDictationAccept.acceptHash(for: "文本")
            != VoiceDictationAccept.acceptHash(for: "另一段文本")
    )
}

@Test
func readyResponseRequiresKnownCapabilitiesAndPolishGate() {
    #expect(localReady().isCompatible)
    #expect(localReady().supports(.direct))
    #expect(!localReady().supports(.polish))

    #expect(!VoiceReadyResponse(
        capabilities: ["telepathy"],
        networkPolicy: .offline,
        asrEngineID: "engine"
    ).isCompatible)

    #expect(!VoiceReadyResponse(
        capabilities: ["local_asr"],
        networkPolicy: .offline,
        asrEngineID: ""
    ).isCompatible)

    let polishReady = VoiceReadyResponse(
        capabilities: ["local_asr", "polish"],
        networkPolicy: .cloudASRAndPolish,
        asrEngineID: "engine"
    )
    #expect(polishReady.isCompatible)
    #expect(polishReady.supports(.polish))
}

// MARK: - 服务端核心

@Test
func serverHandshakeReturnsReadyForKnownClient() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)

    let outputs = server.handle(VoiceHelloRequest())
    guard case let .ready(response) = outputs[0] else {
        Issue.record("expected ready output")
        return
    }
    #expect(response.isCompatible)
    #expect(response.networkPolicy == .offline)
    #expect(response.asrEngineID == engine.engineID)

    let badClient = VoiceHelloRequest(
        clientID: "com.evil.client",
        capabilities: ["dictation"]
    )
    #expect(server.handle(badClient) == [.disconnect])
}

@Test
func serverRejectsStartBeforeHandshakeWithDisconnect() {
    let server = VoiceDictationServerCore(engine: ScriptedVoiceEngine())
    #expect(server.handle(makeStart(requestID: "req-early")) == [.disconnect])
}

@Test
func serverAssignsStrictlyIncreasingSequences() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    engine.enqueue([
        .partial(stableText: "我们", partialText: "需要", confidence: 0.7),
        .partial(stableText: "我们需要", partialText: "", confidence: 0.8),
    ])
    server.handle(VoiceHelloRequest())

    var sequences: [Int] = []
    for output in server.handle(makeStart(requestID: "req-1")) {
        if case let .delta(delta) = output {
            sequences.append(delta.sequence)
        }
    }
    #expect(sequences == [1, 2])
}

@Test
func serverLatestWinsCancelsPreviousSessionSilently() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    server.handle(VoiceHelloRequest())

    server.handle(makeStart(requestID: "req-1"))
    server.handle(makeStart(requestID: "req-2"))

    #expect(engine.cancelledRequestIDs == ["req-1"])
    #expect(engine.startedRequestIDs == ["req-1", "req-2"])

    // 当前会话（req-2）事件正常：异步触发在无 emit 时积压在 outbox。
    engine.trigger(.partial(
        stableText: "第二会话",
        partialText: "",
        confidence: 0.8
    ))
    // handle(cancel) 送出积压的 delta（恰好投递一次）；
    // cancel 本身不产生任何消息。
    let outputs = server.handle(
        VoiceDictationCancel(requestID: "req-2", reason: .userAbort)
    )
    #expect(outputs.count == 1)
    guard case let .delta(delta)? = outputs.first else {
        Issue.record("expected backlog delta")
        return
    }
    #expect(delta.requestID == "req-2")
    #expect(delta.stableText == "第二会话")
    #expect(engine.cancelledRequestIDs == ["req-1", "req-2"])
    // 会话已关闭：再次 cancel 无输出，迟到事件被丢弃。
    #expect(server.handle(
        VoiceDictationCancel(requestID: "req-2", reason: .userAbort)
    ).isEmpty)
    engine.trigger(.finished(
        text: "迟到结果",
        confidence: 0.9,
        polishApplied: false
    ))
}

@Test
func serverClosesSessionAfterFinalAndIgnoresLateEngineEvents() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    engine.enqueue([
        .finished(text: "最终文本", confidence: 0.9, polishApplied: false)
    ])
    server.handle(VoiceHelloRequest())
    let outputs = server.handle(makeStart(requestID: "req-1"))

    guard case let .final(final)? = outputs.first(where: {
        if case .final = $0 { return true }
        return false
    }) else {
        Issue.record("expected final output")
        return
    }
    #expect(final.finalText == "最终文本")
    #expect(final.asrEngineID == engine.engineID)

    // final 之后同会话的引擎事件必须被静默丢弃。
    engine.trigger(.partial(
        stableText: "迟到增量",
        partialText: "",
        confidence: 0.9
    ))
}

@Test
func serverDropsEngineEventsAfterClientCancel() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    server.handle(VoiceHelloRequest())
    server.handle(makeStart(requestID: "req-1"))
    server.handle(
        VoiceDictationCancel(requestID: "req-1", reason: .userAbort)
    )

    engine.trigger(.finished(
        text: "取消后的结果",
        confidence: 0.9,
        polishApplied: false
    ))
}

@Test
func serverRejectsPolishModeWithoutCapability() {
    let server = VoiceDictationServerCore(engine: ScriptedVoiceEngine())
    server.handle(VoiceHelloRequest())
    let outputs = server.handle(makeStart(
        requestID: "req-polish",
        mode: .polish
    ))
    guard case let .error(error)? = outputs.first else {
        Issue.record("expected invalid_request error")
        return
    }
    #expect(error.errorCode == .invalidRequest)
}

@Test
func serverTreatsStandalonePolishFailureAsProtocolViolation() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    engine.enqueue([
        .failed(.polishFailed, retryable: true)
    ])
    server.handle(VoiceHelloRequest())
    #expect(server.handle(makeStart(requestID: "req-1")).contains(.disconnect))
}

@Test
func serverSilentlyDropsAcceptWithMismatchedHash() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    engine.enqueue([
        .finished(text: "最终文本", confidence: 0.9, polishApplied: false)
    ])
    server.handle(VoiceHelloRequest())
    _ = server.handle(makeStart(requestID: "req-1"))

    let mismatched = VoiceDictationAccept(
        requestID: "req-1",
        acceptedTextSHA256: VoiceDictationAccept.acceptHash(for: "别的文本")
    )
    #expect(server.handle(mismatched).isEmpty)

    let matched = VoiceDictationAccept(
        requestID: "req-1",
        acceptedTextSHA256: VoiceDictationAccept.acceptHash(for: "最终文本")
    )
    #expect(server.handle(matched).isEmpty)
}

@Test
func serverEmitsAsyncOutputsExactlyOnceViaHandler() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    server.handle(VoiceHelloRequest())

    let received = ReceivedOutputs()
    server.setEmitHandler { outputs in
        received.append(outputs)
    }

    // emit 注入后：start 触发的输出走 emit，handle 返回空，不重复投递。
    let returned = server.handle(makeStart(requestID: "req-1"))
    #expect(returned.isEmpty)

    engine.trigger(.finished(
        text: "异步结果",
        confidence: 0.9,
        polishApplied: false
    ))
    let batches = received.all
    var finals = 0
    for batch in batches {
        for output in batch {
            if case .final = output {
                finals += 1
            }
        }
    }
    #expect(finals == 1)
}

// MARK: - 客户端状态机

@Test
func clientHappyPathCommitsOnlyAfterExplicitConfirmation() throws {
    var machine = VoiceDictationClientMachine()
    let server = VoiceDictationServerCore(engine: ScriptedVoiceEngine())
    let start = establishedStart(machine: &machine, server: server)
    #expect(start.isValid)
    #expect(machine.phase == .listening(requestID: start.requestID))

    // 乱序与重复 delta 被丢弃，不更新预览。
    _ = machine.delta(VoiceDictationDelta(
        requestID: start.requestID,
        sequence: 2,
        stableText: "我们需要",
        partialText: "增加",
        confidence: 0.7,
        elapsedMilliseconds: 100
    ))
    _ = machine.delta(VoiceDictationDelta(
        requestID: start.requestID,
        sequence: 1,
        stableText: "我们",
        partialText: "",
        confidence: 0.7,
        elapsedMilliseconds: 50
    ))
    #expect(machine.phase == .listening(requestID: start.requestID))

    let finalEffects = machine.finalResult(VoiceDictationFinal(
        requestID: start.requestID,
        finalText: "我们需要增加索引",
        confidence: 0.9,
        asrEngineID: "engine",
        polishApplied: false,
        elapsedMilliseconds: 900
    ))
    let preview = try #require(firstEffect(finalEffects) {
        if case .showPreview = $0 { return true }
        return false
    })
    guard case let .showPreview(_, _, pendingConfirm, _) = preview else {
        fatalError("unreachable")
    }
    #expect(pendingConfirm)
    #expect(machine.phase == .pendingConfirm(requestID: start.requestID))

    // 确认是上屏的唯一触发。
    let confirmEffects = machine.userConfirmed()
    var committed: String?
    var accept: VoiceDictationAccept?
    for effect in confirmEffects {
        switch effect {
        case let .commitText(text):
            committed = text
        case let .sendAccept(value):
            accept = value
        default:
            break
        }
    }
    #expect(committed == "我们需要增加索引")
    #expect(accept?.acceptedTextSHA256
        == VoiceDictationAccept.acceptHash(for: "我们需要增加索引"))
    #expect(machine.phase == .idle)
}

@Test
func clientEscDuringListeningSendsUserAbort() {
    var machine = VoiceDictationClientMachine()
    _ = machine.voiceShortcutPressed(makeContext())
    _ = machine.ready(localReady())

    let effects = machine.userCancelled()
    guard case let .sendCancel(cancel)? = effects.first else {
        Issue.record("expected cancel effect")
        return
    }
    #expect(cancel.reason == .userAbort)
    #expect(machine.phase == .idle)
}

@Test
func clientSecureInputCancelsAndBlocksNewSessions() {
    var machine = VoiceDictationClientMachine()
    _ = machine.voiceShortcutPressed(makeContext())
    _ = machine.ready(localReady())

    let effects = machine.secureInputChanged(active: true)
    guard case let .sendCancel(cancel)? = effects.first else {
        Issue.record("expected secure_input cancel")
        return
    }
    #expect(cancel.reason == .secureInput)
    #expect(machine.phase == .idle)

    #expect(machine.voiceShortcutPressed(makeContext()).isEmpty)
    #expect(machine.phase == .idle)

    _ = machine.secureInputChanged(active: false)
    #expect(!machine.voiceShortcutPressed(makeContext()).isEmpty)
}

@Test
func clientDeltaTimeoutFailsSilentlyWithoutCircuitCount() {
    var machine = VoiceDictationClientMachine()
    _ = machine.voiceShortcutPressed(makeContext())
    _ = machine.ready(localReady())

    let effects = machine.deltaTimedOut()
    guard case let .sendCancel(cancel)? = effects.first else {
        Issue.record("expected client_timeout cancel")
        return
    }
    #expect(cancel.reason == .clientTimeout)
    #expect(machine.phase == .idle)
    #expect(machine.consecutiveProtocolFailures == 0)
}

@Test
func clientMicDeniedIsStickyUntilExplicitRetry() {
    var machine = VoiceDictationClientMachine()
    _ = machine.voiceShortcutPressed(makeContext())
    _ = machine.ready(localReady())
    guard case let .listening(requestID) = machine.phase else {
        Issue.record("expected listening phase")
        return
    }

    let effects = machine.serverError(VoiceDictationError(
        requestID: requestID,
        errorCode: .micDenied,
        retryable: false
    ))
    #expect(effects.contains(.requestMicrophoneAuthorization))
    #expect(machine.phase == .idle)
    #expect(machine.voiceShortcutPressed(makeContext()).isEmpty)

    machine.userRetriedVoice()
    #expect(!machine.voiceShortcutPressed(makeContext()).isEmpty)
}

@Test
func clientCircuitBreaksAfterThreeConsecutiveProtocolFailures() {
    var machine = VoiceDictationClientMachine()

    for _ in 0 ..< 3 {
        _ = machine.voiceShortcutPressed(makeContext())
        // 未知能力按协议失败处理。
        _ = machine.ready(VoiceReadyResponse(
            capabilities: ["telepathy"],
            networkPolicy: .offline,
            asrEngineID: "engine"
        ))
    }
    #expect(machine.phase == .disabled)
    #expect(machine.voiceShortcutPressed(makeContext()).isEmpty)

    machine.userRetriedVoice()
    #expect(machine.phase == .idle)
}

@Test
func clientPropagatesPolishDegradationFlag() {
    var machine = VoiceDictationClientMachine()
    _ = machine.voiceShortcutPressed(makeContext(mode: .polish))
    _ = machine.ready(VoiceReadyResponse(
        capabilities: ["local_asr", "polish"],
        networkPolicy: .cloudASRAndPolish,
        asrEngineID: "engine"
    ))
    guard case let .listening(requestID) = machine.phase else {
        Issue.record("expected listening phase")
        return
    }

    // 润色失败降级：final 带 polish_applied=false，仍可确认上屏。
    let effects = machine.finalResult(VoiceDictationFinal(
        requestID: requestID,
        finalText: "未润色的原文",
        confidence: 0.9,
        asrEngineID: "engine",
        polishApplied: false,
        elapsedMilliseconds: 200
    ))
    guard case let .showPreview(_, _, pending, polishApplied)? =
        effects.first
    else {
        Issue.record("expected preview effect")
        return
    }
    #expect(pending)
    #expect(!polishApplied)
}

// MARK: - 回环：客户端 × 服务端

@Test
func loopbackHappyPathFromHotkeyToAccept() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    var machine = VoiceDictationClientMachine()

    let start = establishedStart(machine: &machine, server: server)

    engine.enqueue([
        .partial(stableText: "我们需要", partialText: "索引", confidence: 0.7),
        .finished(text: "我们需要索引", confidence: 0.9, polishApplied: false)
    ])
    var finalMessage: VoiceDictationFinal?
    for output in server.handle(start) {
        if case let .final(final) = output {
            finalMessage = final
        }
    }
    #expect(finalMessage != nil)

    _ = machine.finalResult(finalMessage!)
    var acceptMessage: VoiceDictationAccept?
    for effect in machine.userConfirmed() {
        if case let .sendAccept(accept) = effect {
            acceptMessage = accept
        }
    }
    #expect(acceptMessage != nil)
    #expect(server.handle(acceptMessage!).isEmpty)
}

@Test
func loopbackCancelStopsEngineAndDropsLateFinal() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    var machine = VoiceDictationClientMachine()

    let start = establishedStart(machine: &machine, server: server)
    _ = server.handle(start)

    var cancelMessage: VoiceDictationCancel?
    for effect in machine.userCancelled() {
        if case let .sendCancel(message) = effect {
            cancelMessage = message
        }
    }
    #expect(server.handle(cancelMessage!).isEmpty)
    #expect(engine.cancelledRequestIDs == [start.requestID])

    // 引擎迟到 final：会话已关闭，静默丢弃。
    engine.trigger(.finished(
        text: "迟到结果",
        confidence: 0.9,
        polishApplied: false
    ))
}

// MARK: - 线上编解码与真实 socket 传输

@Test
func wireCodingRoundTripsEveryMessageType() throws {
    let clientMessages: [VoiceClientMessage] = [
        .hello(VoiceHelloRequest()),
        .start(makeStart(requestID: "req-1")),
        .cancel(VoiceDictationCancel(
            requestID: "req-1",
            reason: .userAbort
        )),
        .accept(VoiceDictationAccept(
            requestID: "req-1",
            acceptedTextSHA256: VoiceDictationAccept.acceptHash(for: "文本")
        )),
    ]
    for message in clientMessages {
        let line = try VoiceDictationWire.encode(message)
        #expect(line.last == 0x0A)
        let payload = line.dropLast()
        #expect(try VoiceDictationWire.decodeClientLine(Data(payload)) == message)
    }

    let serverMessages: [VoiceServerMessage] = [
        .ready(localReady()),
        .delta(VoiceDictationDelta(
            requestID: "req-1",
            sequence: 1,
            stableText: "文本",
            partialText: "",
            confidence: 0.8,
            elapsedMilliseconds: 10
        )),
        .final(VoiceDictationFinal(
            requestID: "req-1",
            finalText: "最终文本",
            confidence: 0.9,
            asrEngineID: "engine",
            polishApplied: false,
            elapsedMilliseconds: 20
        )),
        .error(VoiceDictationError(
            requestID: "req-1",
            errorCode: .micDenied,
            retryable: false
        )),
    ]
    for message in serverMessages {
        let line = try VoiceDictationWire.encode(message)
        let payload = line.dropLast()
        #expect(try VoiceDictationWire.decodeServerLine(Data(payload)) == message)
    }
}

@Test
func wireDecodingRejectsUnknownTypeAndGarbage() {
    #expect(throws: VoiceDictationWireError.unknownType("telepathy")) {
        _ = try VoiceDictationWire.decodeClientLine(
            Data(#"{"type":"telepathy"}"#.utf8)
        )
    }
    #expect(throws: VoiceDictationWireError.malformedJSON) {
        _ = try VoiceDictationWire.decodeServerLine(Data("not json".utf8))
    }
    #expect(throws: VoiceDictationWireError.emptyLine) {
        _ = try VoiceDictationWire.decodeClientLine(Data())
    }
}

@Test
func lineExtractionSplitsFramesAndEnforcesLimit() throws {
    let first = Data(#"{"type":"a"}"#.utf8)
    let second = Data(#"{"type":"b"}"#.utf8)
    var buffer = first
    buffer.append(0x0A)
    buffer.append(second)
    buffer.append(0x0A)
    buffer.append(Data(#"{"type":"c""#.utf8))
    let result = try VoiceDictationWire.extractLines(from: buffer)
    #expect(result.lines == [first, second])
    #expect(result.remainder == Data(#"{"type":"c""#.utf8))

    let oversized = Data(repeating: 0x61, count: VoiceDictationWire
        .maximumLineBytes + 1)
    #expect(throws: VoiceDictationWireError.lineTooLong) {
        _ = try VoiceDictationWire.extractLines(from: oversized)
    }
}

/// 线程安全的服务端消息收集器，支持带超时的条件等待。
final class VoiceMessageCollector: @unchecked Sendable {
    private let condition = NSCondition()
    private var messages: [VoiceServerMessage] = []
    private var disconnected = false

    func append(_ message: VoiceServerMessage) {
        condition.lock()
        messages.append(message)
        condition.broadcast()
        condition.unlock()
    }

    func markDisconnected() {
        condition.lock()
        disconnected = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(
        for predicate: @escaping (VoiceServerMessage) -> Bool,
        timeout: TimeInterval
    ) throws -> VoiceServerMessage {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let found = messages.first(where: predicate) {
                return found
            }
            guard condition.wait(until: deadline) else {
                throw NSError(
                    domain: "voice-collector", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "timed out"]
                )
            }
        }
    }

    func waitForDisconnect(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !disconnected {
            guard condition.wait(until: deadline) else {
                throw NSError(
                    domain: "voice-collector", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "no disconnect"]
                )
            }
        }
    }
}

@Test
func transportLoopbackOverRealUDSSocket() async throws {
    let engine = ScriptedVoiceEngine()
    engine.enqueue([
        .partial(stableText: "传输层", partialText: "回环", confidence: 0.7),
        .finished(text: "传输层回环结果", confidence: 0.9, polishApplied: false)
    ])
    let core = VoiceDictationServerCore(engine: engine)
    let socketPath = NSTemporaryDirectory()
        + "rimeai-voice-\(UUID().uuidString).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }

    let server = VoiceDictationServerTransport(
        socketPath: socketPath,
        core: core
    )
    try server.start()
    defer { server.stop() }

    let client = VoiceDictationClientTransport(socketPath: socketPath)
    defer { client.close() }
    let collector = VoiceMessageCollector()
    client.setMessageHandler { message in
        collector.append(message)
    }
    client.setDisconnectHandler {
        collector.markDisconnected()
    }

    try await client.connect(timeout: 5)

    client.send(.hello(VoiceHelloRequest()))
    let ready = try collector.wait(
        for: { if case .ready = $0 { return true }; return false },
        timeout: 5
    )
    guard case let .ready(readyResponse) = ready else {
        fatalError("unreachable")
    }
    #expect(readyResponse.isCompatible)
    #expect(readyResponse.asrEngineID == engine.engineID)

    client.send(.start(makeStart(requestID: "wire-1")))
    let final = try collector.wait(
        for: { if case .final = $0 { return true }; return false },
        timeout: 5
    )
    guard case let .final(finalMessage) = final else {
        fatalError("unreachable")
    }
    #expect(finalMessage.requestID == "wire-1")
    #expect(finalMessage.finalText == "传输层回环结果")

    client.send(.accept(VoiceDictationAccept(
        requestID: "wire-1",
        acceptedTextSHA256: VoiceDictationAccept.acceptHash(
            for: "传输层回环结果"
        )
    )))
}

@Test
func transportDisconnectsOnMalformedLine() async throws {
    let core = VoiceDictationServerCore(engine: ScriptedVoiceEngine())
    let socketPath = NSTemporaryDirectory()
        + "rimeai-voice-\(UUID().uuidString).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }

    let server = VoiceDictationServerTransport(
        socketPath: socketPath,
        core: core
    )
    try server.start()
    defer { server.stop() }

    let client = VoiceDictationClientTransport(socketPath: socketPath)
    defer { client.close() }
    let collector = VoiceMessageCollector()
    client.setDisconnectHandler {
        collector.markDisconnected()
    }

    try await client.connect(timeout: 5)

    // 坏行按协议错误处理：服务端必须断开连接。
    client.sendRaw(Data("this is not json\n".utf8))
    try collector.waitForDisconnect(timeout: 5)
}

// MARK: - Coordinator 全栈（真实 socket）

/// 线程安全的 UI 回调收集器。
final class CoordinatorCallbackCollector: @unchecked Sendable {
    struct Snapshot: Sendable {
        let commits: [String]
        let pendingPreviews: Int
        let streamingPreviews: Int
    }

    private let condition = NSCondition()
    private var previews: [(stable: String, partial: String, pending: Bool, polish: Bool)] = []
    private var commits: [String] = []

    func appendPreview(
        stable: String, partial: String, pending: Bool, polish: Bool
    ) {
        condition.lock()
        previews.append((stable, partial, pending, polish))
        condition.broadcast()
        condition.unlock()
    }

    func appendCommit(_ text: String) {
        condition.lock()
        commits.append(text)
        condition.broadcast()
        condition.unlock()
    }

    private func snapshotLocked() -> Snapshot {
        Snapshot(
            commits: commits,
            pendingPreviews: previews.filter { $0.pending }.count,
            streamingPreviews: previews.filter { !$0.pending }.count
        )
    }

    /// predicate 收到锁内快照，不得再调用本类型的其他方法
    /// （NSCondition 不可重入）。
    func waitUntil(
        timeout: TimeInterval,
        _ predicate: @Sendable (Snapshot) -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        var snapshot = snapshotLocked()
        while !predicate(snapshot) {
            guard condition.wait(until: deadline) else {
                throw NSError(
                    domain: "coordinator-collector", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "timed out"]
                )
            }
            snapshot = snapshotLocked()
        }
    }

    var committedTexts: [String] {
        condition.lock()
        defer { condition.unlock() }
        return commits
    }
}

@Test
func coordinatorFullStackCommitsAfterConfirmation() throws {
    let engine = ScriptedVoiceEngine()
    engine.enqueue([
        .partial(stableText: "协同器", partialText: "测试", confidence: 0.7),
        .finished(text: "协同器全栈结果", confidence: 0.9, polishApplied: false)
    ])
    let core = VoiceDictationServerCore(engine: engine)
    let socketPath = NSTemporaryDirectory()
        + "rimeai-voice-\(UUID().uuidString).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let server = VoiceDictationServerTransport(socketPath: socketPath, core: core)
    try server.start()
    defer { server.stop() }

    let coordinator = VoiceDictationCoordinator(
        configuration: .init(
            socketPath: socketPath,
            uiQueue: DispatchQueue.global()
        )
    )
    let collector = CoordinatorCallbackCollector()
    coordinator.onPreview = { stable, partial, pending, polish in
        collector.appendPreview(
            stable: stable, partial: partial, pending: pending, polish: polish
        )
    }
    coordinator.onCommit = { text in
        collector.appendCommit(text)
    }

    coordinator.startDictation(makeContext())

    // 流式预览与待确认预览都出现。
    try collector.waitUntil(timeout: 5) {
        $0.pendingPreviews >= 1 && $0.streamingPreviews >= 1
    }

    // 确认前没有任何 commit：上屏唯一触发是显式确认。
    #expect(collector.committedTexts.isEmpty)

    coordinator.userConfirmed()
    try collector.waitUntil(timeout: 5) {
        $0.commits == ["协同器全栈结果"]
    }
    #expect(coordinator.phaseForTesting == .idle)
}

@Test
func coordinatorDeltaTimeoutCancelsSilently() throws {
    // 引擎不产出任何事件：delta 超时必须触发静默取消。
    let engine = ScriptedVoiceEngine()
    let core = VoiceDictationServerCore(engine: engine)
    let socketPath = NSTemporaryDirectory()
        + "rimeai-voice-\(UUID().uuidString).sock"
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let server = VoiceDictationServerTransport(socketPath: socketPath, core: core)
    try server.start()
    defer { server.stop() }

    let coordinator = VoiceDictationCoordinator(
        configuration: .init(
            socketPath: socketPath,
            deltaTimeout: 0.2,
            uiQueue: DispatchQueue.global()
        )
    )
    coordinator.startDictation(makeContext())

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if !engine.cancelledRequestIDsSnapshot.isEmpty {
            break
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    #expect(!engine.cancelledRequestIDsSnapshot.isEmpty)
    #expect(coordinator.phaseForTesting == .idle)
}
