import Foundation
import Network
import Testing
@testable import RimeAIInputCore

// MARK: - 测试工具

func verifiedTestVoiceEngineDescriptor(
    adapterID: String = "test-asr-engine",
    capabilities: Set<VoiceEngineCapability> = [
        .localASR, .streaming, .hotwordSnapshot,
    ],
    networkPolicy: VoiceNetworkPolicy = .offline
) -> VoiceEngineDescriptor {
    VoiceEngineDescriptor(
        adapterID: adapterID,
        adapterVersion: "1.0.0-test",
        assetManagement: .productManaged,
        qualification: .integrityVerifiedProductArtifact,
        artifactID: VoiceASRArtifactID(rawValue: "voice-test-artifact-v1")!,
        artifactSHA256: String(repeating: "a", count: 64),
        artifactGeneration: UUID(),
        supportedLocales: ["zh-CN"],
        capabilities: capabilities,
        networkPolicy: networkPolicy,
        audioFormat: .fixedLinearPCM(
            sampleRateHertz: 16_000,
            channelCount: 1,
            bitsPerChannel: 32
        ),
        hotwordMode: capabilities.contains(.hotwordSnapshot)
            ? .boundedPhraseList(maximumEntries: 32)
            : .unsupported,
        maximumAlternatives: 1
    )
}

/// 脚本化引擎：start 时同步回放已入队事件，也可在测试中途
/// 手动触发以模拟异步识别。
final class ScriptedVoiceEngine: VoiceDictationEngine, @unchecked Sendable {
    let descriptor: VoiceEngineDescriptor

    private let lock = NSLock()
    private var queuedEvents: [VoiceDictationEngineEvent] = []
    private var queuedStopEvents: [VoiceDictationEngineEvent] = []
    private var activeSink: (@Sendable (VoiceDictationEngineEvent) -> Void)?
    private(set) var cancelledRequestIDs: [String] = []
    private(set) var startedRequests: [VoiceDictationEngineRequest] = []
    private(set) var startedRequestIDs: [String] = []
    private(set) var stoppedRequestIDs: [String] = []

    init(
        capabilities: Set<VoiceEngineCapability> = [
            .localASR, .streaming, .hotwordSnapshot,
        ],
        networkPolicy: VoiceNetworkPolicy = .offline
    ) {
        descriptor = verifiedTestVoiceEngineDescriptor(
            capabilities: capabilities,
            networkPolicy: networkPolicy
        )
    }

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

    func enqueueOnStop(_ events: [VoiceDictationEngineEvent]) {
        lock.lock()
        queuedStopEvents.append(contentsOf: events)
        lock.unlock()
    }

    func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {
        lock.lock()
        startedRequests.append(request)
        startedRequestIDs.append(request.requestID)
        activeSink = events
        let replay = queuedEvents
        queuedEvents.removeAll()
        lock.unlock()
        for event in replay {
            events(event)
        }
    }

    func stop(requestID: String) {
        lock.lock()
        stoppedRequestIDs.append(requestID)
        let sink = activeSink
        let replay = queuedStopEvents
        queuedStopEvents.removeAll()
        lock.unlock()
        for event in replay {
            sink?(event)
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

    var stoppedRequestIDsSnapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stoppedRequestIDs
    }
}

/// 可注入服务端的线程安全单调时钟。
final class TestVoiceMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: Double

    init(milliseconds: Double) {
        self.milliseconds = milliseconds
    }

    func now() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return milliseconds
    }

    func advance(by delta: Double) {
        lock.lock()
        milliseconds += delta
        lock.unlock()
    }

    func set(milliseconds: Double) {
        lock.lock()
        self.milliseconds = milliseconds
        lock.unlock()
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
    mode: VoiceDictationMode = .direct,
    hotwordSnapshot: VoiceHotwordSnapshot = .empty
) -> VoiceDictationSessionContext {
    VoiceDictationSessionContext(
        compositionID: UUID(),
        appSessionID: "com.apple.Safari#nonce",
        bundleID: "com.apple.Safari",
        mode: mode,
        deadlineMilliseconds: 1_500,
        hotwordSnapshot: hotwordSnapshot
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
        capabilities: ["hotword_snapshot", "local_asr", "streaming"],
        networkPolicy: .offline,
        asrEngineID: "test-asr-engine",
        maximumHotwords: 32
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
    #expect(
        object["protocol_version"] as? Int
            == VoiceDictationConstants.protocolVersion
    )
    #expect(object["type"] as? String == "dictation_start")
    #expect(object["request_id"] as? String == "req-1")
    #expect(object["deadline_ms"] as? Int == 1_500)
    #expect(object["max_duration_ms"] as? Int == 60_000)
    let hotwords = try #require(
        object["hotword_snapshot"] as? [String: Any]
    )
    #expect(hotwords["normalization_version"] as? Int == 1)
    #expect((hotwords["phrases"] as? [String])?.isEmpty == true)
    #expect((hotwords["hotword_set_sha256"] as? String)?.count == 64)
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
func hotwordSnapshotCanonicalizesBindsOrderAndRejectsControlSyntax() throws {
    let normalized = try VoiceHotwordSnapshot(phrases: [
        "  ＡＰＩ  ", "接口",
    ])
    #expect(normalized.phrases == ["API", "接口"])
    #expect(normalized.isValid)
    #expect(normalized.hotwordSetSHA256.count == 64)
    #expect(
        normalized.hotwordSetSHA256
            != (try VoiceHotwordSnapshot(phrases: ["接口", "API"]))
                .hotwordSetSHA256
    )
    #expect(throws: VoiceHotwordSnapshot.ValidationError.self) {
        try VoiceHotwordSnapshot(phrases: ["API", "ＡＰＩ"])
    }
    for unsafe in ["单", "多\n行", "含\0零", "斜/杠", ":9999", "#控制", "@控制"] {
        #expect(throws: VoiceHotwordSnapshot.ValidationError.self) {
            try VoiceHotwordSnapshot(phrases: [unsafe])
        }
    }
    let maximumPhrases = (0 ..< VoiceDictationConstants.maximumHotwordCount)
        .map { "术语\($0)" }
    let maximumSnapshot = try VoiceHotwordSnapshot(
        phrases: maximumPhrases
    )
    let maximumPayload = try VoiceDictationWire.encodeXPCPayload(.start(
        VoiceDictationStart(
            requestID: "maximum-hotwords",
            compositionID: UUID(),
            appSessionID: "maximum-hotwords-session",
            bundleID: "com.example.maximum-hotwords",
            mode: .direct,
            deadlineMilliseconds: 1_500,
            hotwordSnapshot: maximumSnapshot
        )
    ))
    #expect(maximumPayload.count <= VoiceDictationWire.maximumLineBytes)
    #expect(throws: VoiceHotwordSnapshot.ValidationError.self) {
        try VoiceHotwordSnapshot(phrases: maximumPhrases + ["额外术语"])
    }
}

@Test
func decodedHotwordSnapshotRejectsTamperedDigest() throws {
    let valid = try VoiceHotwordSnapshot(phrases: ["API", "接口"])
    var object = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(valid)
        ) as? [String: Any]
    )
    object["hotword_set_sha256"] = String(repeating: "0", count: 64)
    let tampered = try JSONDecoder().decode(
        VoiceHotwordSnapshot.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(!tampered.isValid)
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
func helloRequiresKnownCapabilitiesIncludingDictation() {
    #expect(VoiceHelloRequest().isValid)
    #expect(VoiceHelloRequest(capabilities: ["dictation"]).isValid)
    #expect(!VoiceHelloRequest(capabilities: ["cancel"]).isValid)
    #expect(!VoiceHelloRequest(
        capabilities: ["dictation", "telepathy"]
    ).isValid)
    #expect(!VoiceHelloRequest(
        protocolVersion: VoiceDictationConstants.protocolVersion + 1,
        capabilities: ["dictation"]
    ).isValid)
}

@Test
func stopMessageRequiresCurrentProtocolAndBoundedRequestID() {
    #expect(VoiceDictationStop(requestID: "req-1").isValid)
    #expect(!VoiceDictationStop(
        protocolVersion: VoiceDictationConstants.protocolVersion + 1,
        requestID: "req-1"
    ).isValid)
    #expect(!VoiceDictationStop(requestID: "").isValid)
    #expect(!VoiceDictationStop(
        requestID: String(repeating: "a", count: 129)
    ).isValid)
}

@Test
func readyResponseRequiresKnownCapabilitiesAndPolishGate() {
    #expect(localReady().isCompatible)
    #expect(localReady().supports(.direct))
    #expect(!localReady().supports(.polish))
    #expect(localReady().maximumHotwords == 32)

    #expect(!VoiceReadyResponse(
        capabilities: ["hotword_snapshot", "local_asr"],
        networkPolicy: .offline,
        asrEngineID: "engine",
        maximumHotwords: 0
    ).isCompatible)

    #expect(!VoiceReadyResponse(
        capabilities: ["local_asr"],
        networkPolicy: .offline,
        asrEngineID: "engine",
        maximumHotwords: 1
    ).isCompatible)

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

    #expect(!VoiceReadyResponse(
        capabilities: ["streaming"],
        networkPolicy: .offline,
        asrEngineID: "engine"
    ).isCompatible)

    #expect(!VoiceReadyResponse(
        capabilities: ["local_asr", "local_asr"],
        networkPolicy: .offline,
        asrEngineID: "engine"
    ).isCompatible)

    #expect(!VoiceReadyResponse(
        capabilities: ["cloud_asr"],
        networkPolicy: .offline,
        asrEngineID: "engine"
    ).isCompatible)

    #expect(!VoiceReadyResponse(
        capabilities: ["local_asr"],
        networkPolicy: .cloudASROnly,
        asrEngineID: "engine"
    ).isCompatible)

    let polishReady = VoiceReadyResponse(
        capabilities: ["local_asr", "polish"],
        networkPolicy: .cloudASRAndPolish,
        asrEngineID: "engine"
    )
    #expect(polishReady.isCompatible)
    #expect(polishReady.supports(.polish))
}

@Test
func clientNegotiatesAndRehashesBoundedHotwordSnapshot() throws {
    let snapshot = try VoiceHotwordSnapshot(phrases: [
        "API", "接口", "模型",
    ])
    var machine = VoiceDictationClientMachine()
    _ = machine.voiceShortcutPressed(VoiceDictationSessionContext(
        compositionID: UUID(),
        appSessionID: "editor#focus",
        bundleID: "com.example.Editor",
        hotwordSnapshot: snapshot
    ))
    let effects = machine.ready(VoiceReadyResponse(
        capabilities: ["hotword_snapshot", "local_asr", "streaming"],
        networkPolicy: .offline,
        asrEngineID: "product",
        maximumHotwords: 2
    ))
    guard case let .sendStart(start)? = effects.first else {
        Issue.record("expected negotiated start")
        return
    }
    #expect(start.hotwordSnapshot?.phrases == ["API", "接口"])
    #expect(start.hotwordSnapshot?.isValid == true)
    #expect(
        start.hotwordSnapshot?.hotwordSetSHA256
            != snapshot.hotwordSetSHA256
    )
}

@Test
func clientOmitsHotwordsForEngineWithoutNegotiatedCapability() throws {
    var machine = VoiceDictationClientMachine()
    _ = machine.voiceShortcutPressed(VoiceDictationSessionContext(
        compositionID: UUID(),
        appSessionID: "editor#focus",
        bundleID: "com.example.Editor",
        hotwordSnapshot: try VoiceHotwordSnapshot(phrases: ["API"])
    ))
    let effects = machine.ready(VoiceReadyResponse(
        capabilities: ["local_asr", "streaming"],
        networkPolicy: .offline,
        asrEngineID: "system-probe"
    ))
    guard case let .sendStart(start)? = effects.first else {
        Issue.record("expected start without hotwords")
        return
    }
    #expect(start.hotwordSnapshot == nil)
}

@Test
func descriptorSeparatesRuntimeCapabilitiesFromReleaseEligibility() {
    let unverifiedProductAdapter = VoiceEngineDescriptor(
        adapterID: "probe-local-asr",
        adapterVersion: "1.0.0",
        assetManagement: .productManaged,
        qualification: .probeOnly,
        supportedLocales: ["zh-CN"],
        capabilities: [.localASR, .streaming],
        networkPolicy: .offline,
        audioFormat: .fixedLinearPCM(
            sampleRateHertz: 16_000,
            channelCount: 1,
            bitsPerChannel: 16
        ),
        hotwordMode: .unsupported,
        maximumAlternatives: 1
    )
    #expect(unverifiedProductAdapter.isStructurallyValid)
    #expect(!unverifiedProductAdapter.hasIntegrityVerifiedProductArtifact)
    #expect(unverifiedProductAdapter.advertisedProtocolCapabilities.isEmpty)

    let systemProbe = VoiceEngineDescriptor(
        adapterID: "system-probe-local-asr",
        adapterVersion: "1.0.0",
        assetManagement: .systemManaged,
        qualification: .probeOnly,
        supportedLocales: ["zh-CN"],
        capabilities: [.localASR, .streaming],
        networkPolicy: .offline,
        audioFormat: .systemNativePCM,
        hotwordMode: .unsupported,
        maximumAlternatives: 1
    )
    #expect(systemProbe.isStructurallyValid)
    #expect(!systemProbe.hasIntegrityVerifiedProductArtifact)
    #expect(systemProbe.advertisedProtocolCapabilities == [
        "local_asr", "streaming",
    ])

    let verified = verifiedTestVoiceEngineDescriptor()
    #expect(verified.isStructurallyValid)
    #expect(verified.hasIntegrityVerifiedProductArtifact)
    #expect(verified.advertisedProtocolCapabilities == [
        "hotword_snapshot", "local_asr", "streaming",
    ])
    #expect(verified.advertisedMaximumHotwords == 32)
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

    let unknownCapability = VoiceHelloRequest(
        capabilities: ["dictation", "telepathy"]
    )
    #expect(server.handle(unknownCapability) == [.disconnect])

    let missingDictation = VoiceHelloRequest(capabilities: ["cancel"])
    #expect(server.handle(missingDictation) == [.disconnect])
}

@Test
func serverRejectsStartBeforeHandshakeWithDisconnect() {
    let server = VoiceDictationServerCore(engine: ScriptedVoiceEngine())
    #expect(server.handle(makeStart(requestID: "req-early")) == [.disconnect])
}

@Test
func serverPassesCompleteTypedRequestToEngineWithPrivateControlID() throws {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    let compositionID = try #require(
        UUID(uuidString: "D763BBA1-7B16-49DF-A3B8-A3D5AE0DC2A7")
    )
    let hotwords = try VoiceHotwordSnapshot(phrases: ["API", "接口"])
    let start = VoiceDictationStart(
        requestID: "wire-request-17",
        compositionID: compositionID,
        appSessionID: "com.example.Editor#session-42",
        bundleID: "com.example.Editor",
        mode: .direct,
        deadlineMilliseconds: 2_345,
        maximumDurationMilliseconds: 54_321,
        hotwordSnapshot: hotwords
    )

    server.handle(VoiceHelloRequest())
    #expect(server.handle(start).isEmpty)

    let request = try #require(engine.startedRequests.first)
    #expect(request.requestID != start.requestID)
    #expect(UUID(uuidString: request.requestID) != nil)
    #expect(request.wireRequestID == start.requestID)
    #expect(request.compositionID == start.compositionID)
    #expect(request.applicationSessionID == start.appSessionID)
    #expect(request.bundleID == start.bundleID)
    #expect(request.mode == start.mode)
    #expect(request.deadlineMilliseconds == start.deadlineMilliseconds)
    #expect(
        request.maximumDurationMilliseconds
            == start.maximumDurationMilliseconds
    )
    #expect(request.hotwordSnapshot == hotwords)
}

@Test
func serverEnforcesNegotiatedHotwordContractBeforeStartingEngine() {
    let unsupportedEngine = ScriptedVoiceEngine(
        capabilities: [.localASR, .streaming]
    )
    let unsupportedServer = VoiceDictationServerCore(
        engine: unsupportedEngine
    )
    _ = unsupportedServer.handle(VoiceHelloRequest())
    let unexpectedSnapshot = unsupportedServer.handle(
        makeStart(requestID: "unexpected-hotwords")
    )
    #expect(unsupportedEngine.startedRequests.isEmpty)
    guard case let .error(error)? = unexpectedSnapshot.first else {
        Issue.record("expected invalid_request for unsupported snapshot")
        return
    }
    #expect(error.errorCode == .invalidRequest)

    let supportedEngine = ScriptedVoiceEngine()
    let supportedServer = VoiceDictationServerCore(engine: supportedEngine)
    _ = supportedServer.handle(VoiceHelloRequest())
    let missingSnapshot = VoiceDictationStart(
        requestID: "missing-hotwords",
        compositionID: UUID(),
        appSessionID: "editor#focus",
        bundleID: "com.example.Editor",
        mode: .direct,
        deadlineMilliseconds: 1_500,
        hotwordSnapshot: nil
    )
    let missingOutputs = supportedServer.handle(missingSnapshot)
    #expect(supportedEngine.startedRequests.isEmpty)
    guard case let .error(missingError)? = missingOutputs.first else {
        Issue.record("expected invalid_request for missing snapshot")
        return
    }
    #expect(missingError.errorCode == .invalidRequest)
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
func serverStopFinishesMatchingSessionExactlyOnce() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    server.handle(VoiceHelloRequest())
    #expect(server.handle(makeStart(requestID: "req-1")).isEmpty)
    let engineRequestID = engine.startedRequestIDs[0]

    engine.enqueueOnStop([
        .finished(text: "松开后的最终文本", confidence: 0.9, polishApplied: false)
    ])
    let outputs = server.handle(VoiceDictationStop(requestID: "req-1"))
    #expect(engine.stoppedRequestIDs == [engineRequestID])
    guard case let .final(final)? = outputs.first else {
        Issue.record("expected final after stop")
        return
    }
    #expect(final.finalText == "松开后的最终文本")

    // stop 幂等；final 已关闭的会话不得再次触发引擎。
    #expect(server.handle(VoiceDictationStop(requestID: "req-1")).isEmpty)
    #expect(engine.stoppedRequestIDs == [engineRequestID])
}

@Test
func staleStopAndCancelCannotAffectLatestSession() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    server.handle(VoiceHelloRequest())
    server.handle(makeStart(requestID: "old"))
    server.handle(makeStart(requestID: "current"))
    let engineRequestIDs = engine.startedRequestIDs

    #expect(server.handle(VoiceDictationStop(requestID: "old")).isEmpty)
    #expect(server.handle(
        VoiceDictationCancel(requestID: "old", reason: .userAbort)
    ).isEmpty)
    #expect(engine.stoppedRequestIDs.isEmpty)
    #expect(engine.cancelledRequestIDs == [engineRequestIDs[0]])

    engine.enqueueOnStop([
        .finished(text: "当前会话", confidence: 0.9, polishApplied: false)
    ])
    let outputs = server.handle(VoiceDictationStop(requestID: "current"))
    #expect(outputs.contains(where: {
        if case .final = $0 { return true }
        return false
    }))
}

@Test
func serverUsesInjectedMonotonicClockForElapsedMilliseconds() throws {
    let clock = TestVoiceMonotonicClock(milliseconds: 1_000)
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(
        engine: engine,
        monotonicNowMilliseconds: { clock.now() }
    )
    let received = ReceivedOutputs()
    server.setEmitHandler { received.append($0) }
    server.handle(VoiceHelloRequest())
    server.handle(makeStart(requestID: "timed"))

    clock.advance(by: 125.5)
    engine.trigger(.partial(
        stableText: "计时",
        partialText: "增量",
        confidence: 0.8
    ))
    clock.advance(by: -200)
    engine.trigger(.partial(
        stableText: "计时回退",
        partialText: "仍单调",
        confidence: 0.8
    ))
    clock.advance(by: 274.5)
    engine.trigger(.finished(
        text: "计时最终结果",
        confidence: 0.9,
        polishApplied: false
    ))

    let outputs = received.all.flatMap { $0 }
    let deltas = outputs.compactMap { output in
        if case let .delta(value) = output { return value }
        return nil
    }
    #expect(deltas.map(\.elapsedMilliseconds) == [125.5, 125.5])
    let final = try #require(outputs.compactMap { output in
        if case let .final(value) = output { return value }
        return nil
    }.first)
    #expect(final.elapsedMilliseconds == 200)
}

@Test
func serverKeepsElapsedFiniteWhenInjectedClockIsNonFinite() throws {
    let clock = TestVoiceMonotonicClock(milliseconds: 5_000)
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(
        engine: engine,
        monotonicNowMilliseconds: { clock.now() }
    )
    let received = ReceivedOutputs()
    server.setEmitHandler { received.append($0) }
    server.handle(VoiceHelloRequest())
    server.handle(makeStart(requestID: "non-finite-clock"))

    clock.set(milliseconds: .nan)
    engine.trigger(.partial(
        stableText: "异常时钟",
        partialText: "仍有效",
        confidence: 0.8
    ))

    let delta = try #require(received.all.flatMap { $0 }.compactMap { output in
        if case let .delta(value) = output { return value }
        return nil
    }.first)
    #expect(delta.elapsedMilliseconds == 0)
    #expect(delta.isValid)
}

@Test
func serverTruncatesOversizeDeltaAndFinalizesInsteadOfFailing() throws {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    let text = String(repeating: "字", count: 201)
    engine.enqueue([
        .partial(stableText: text, partialText: "尾", confidence: 0.8)
    ])
    server.handle(VoiceHelloRequest())
    let outputs = server.handle(makeStart(requestID: "long-delta"))

    let final = try #require(outputs.compactMap { output in
        if case let .final(value) = output { return value }
        return nil
    }.first)
    #expect(final.finalText.count == 200)
    #expect(final.finalText == String(text.prefix(200)))
    #expect(final.isValid)
    #expect(!outputs.contains(where: {
        if case .error = $0 { return true }
        return false
    }))
    #expect(engine.cancelledRequestIDs == engine.startedRequestIDs)
}

@Test
func serverFinalizesOversizeDeltaAcrossGraphemeJoinBoundary() throws {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    // 两字段各自合计 201 Characters；拼接后重音符与末尾 a 合并为
    // 一个 Character，cumulativeText.count 仅 200。仍须按字段协议上限
    // 走安全 final，不能落入 delta.isValid 后变成 asr_engine_error。
    let stable = String(repeating: "a", count: 200)
    let partial = "\u{301}"
    engine.enqueue([
        .partial(stableText: stable, partialText: partial, confidence: 0.8)
    ])
    server.handle(VoiceHelloRequest())
    let outputs = server.handle(makeStart(requestID: "joined-grapheme"))

    let final = try #require(outputs.compactMap { output in
        if case let .final(value) = output { return value }
        return nil
    }.first)
    #expect(final.finalText == stable + partial)
    #expect(final.finalText.count == 200)
    #expect(!outputs.contains(where: {
        if case .error = $0 { return true }
        return false
    }))
    #expect(engine.cancelledRequestIDs == engine.startedRequestIDs)
}

@Test
func serverSafelyTruncatesOversizeEngineFinal() throws {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    let text = String(repeating: "👩🏽‍💻", count: 201)
    engine.enqueue([
        .finished(text: text, confidence: 0.9, polishApplied: true)
    ])
    server.handle(VoiceHelloRequest())
    let outputs = server.handle(makeStart(requestID: "long-final"))

    let final = try #require(outputs.compactMap { output in
        if case let .final(value) = output { return value }
        return nil
    }.first)
    #expect(final.finalText.count == 200)
    #expect(final.finalText == String(text.prefix(200)))
    #expect(final.polishApplied)
    #expect(final.isValid)
    #expect(!outputs.contains(where: {
        if case .error = $0 { return true }
        return false
    }))
}

@Test
func serverLatestWinsCancelsPreviousSessionSilently() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    server.handle(VoiceHelloRequest())

    server.handle(makeStart(requestID: "req-1"))
    server.handle(makeStart(requestID: "req-2"))

    #expect(engine.startedRequestIDs.count == 2)
    #expect(engine.startedRequestIDs[0] != engine.startedRequestIDs[1])
    #expect(engine.cancelledRequestIDs == [engine.startedRequestIDs[0]])

    // 当前会话（req-2）的异步增量即使已积压，取消也必须丢弃，不能在
    // Esc 之后继续发给客户端。
    engine.trigger(.partial(
        stableText: "第二会话",
        partialText: "",
        confidence: 0.8
    ))
    let outputs = server.handle(
        VoiceDictationCancel(requestID: "req-2", reason: .userAbort)
    )
    #expect(outputs.isEmpty)
    #expect(engine.cancelledRequestIDs == engine.startedRequestIDs)
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
func serverCancelClearsPendingFinalBeforeAccept() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    engine.enqueue([
        .finished(text: "不要上屏", confidence: 0.9, polishApplied: false)
    ])
    server.handle(VoiceHelloRequest())
    _ = server.handle(makeStart(requestID: "pending-cancel"))
    #expect(server.hasPendingFinalAcknowledgement)

    #expect(server.handle(VoiceDictationCancel(
        requestID: "pending-cancel",
        reason: .userAbort
    )).isEmpty)
    #expect(!server.hasPendingFinalAcknowledgement)
    #expect(engine.cancelledRequestIDs.isEmpty)

    let staleAccept = VoiceDictationAccept(
        requestID: "pending-cancel",
        acceptedTextSHA256: VoiceDictationAccept.acceptHash(
            for: "不要上屏"
        )
    )
    #expect(server.handle(staleAccept).isEmpty)
    #expect(!server.hasPendingFinalAcknowledgement)
}

@Test
func serverRejectsReusedWireRequestIDWithinAConnection() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    server.handle(VoiceHelloRequest())
    _ = server.handle(makeStart(requestID: "must-be-unique"))

    let outputs = server.handle(makeStart(requestID: "must-be-unique"))
    #expect(engine.startedRequestIDs.count == 1)
    #expect(outputs == [.disconnect])
    #expect(engine.cancelledRequestIDs == engine.startedRequestIDs)
}

@Test
func malformedCurrentControlMessageCancelsAndDisconnects() {
    let engine = ScriptedVoiceEngine()
    let server = VoiceDictationServerCore(engine: engine)
    server.handle(VoiceHelloRequest())
    _ = server.handle(makeStart(requestID: "active-control"))

    let outputs = server.handle(VoiceDictationStop(
        protocolVersion: VoiceDictationConstants.protocolVersion + 1,
        requestID: "active-control"
    ))
    #expect(outputs == [.disconnect])
    #expect(engine.cancelledRequestIDs == engine.startedRequestIDs)
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
    #expect(server.hasPendingFinalAcknowledgement)

    let matched = VoiceDictationAccept(
        requestID: "req-1",
        acceptedTextSHA256: VoiceDictationAccept.acceptHash(for: "最终文本")
    )
    #expect(server.handle(matched).isEmpty)
    #expect(!server.hasPendingFinalAcknowledgement)
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
        case let .commitText(text, embeddedAccept):
            committed = text
            accept = embeddedAccept
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
func clientConnectingCanBeAbortedBeforeLateReady() {
    var secureMachine = VoiceDictationClientMachine()
    _ = secureMachine.voiceShortcutPressed(makeContext())
    #expect(secureMachine.phase == .connecting)
    #expect(secureMachine.secureInputChanged(active: true).isEmpty)
    #expect(secureMachine.phase == .idle)
    #expect(secureMachine.ready(localReady()).isEmpty)
    #expect(secureMachine.phase == .idle)

    var escapeMachine = VoiceDictationClientMachine()
    _ = escapeMachine.voiceShortcutPressed(makeContext())
    #expect(escapeMachine.userCancelled().isEmpty)
    #expect(escapeMachine.phase == .idle)
    #expect(escapeMachine.ready(localReady()).isEmpty)

    var switchedMachine = VoiceDictationClientMachine()
    _ = switchedMachine.voiceShortcutPressed(makeContext())
    #expect(switchedMachine.sessionSwitched().isEmpty)
    #expect(switchedMachine.phase == .idle)
    #expect(switchedMachine.ready(localReady()).isEmpty)

    var releasedMachine = VoiceDictationClientMachine()
    _ = releasedMachine.voiceShortcutPressed(makeContext())
    #expect(releasedMachine.userStoppedRecording().isEmpty)
    #expect(releasedMachine.phase == .idle)
    #expect(releasedMachine.ready(localReady()).isEmpty)
}

@Test
func clientReleaseEntersFinalizingAndCanStillCancelOrTimeout() {
    var machine = VoiceDictationClientMachine()
    _ = machine.voiceShortcutPressed(makeContext())
    _ = machine.ready(localReady())
    guard case let .listening(requestID) = machine.phase else {
        Issue.record("expected listening phase")
        return
    }

    let stopEffects = machine.userStoppedRecording()
    #expect(stopEffects == [
        .sendStop(VoiceDictationStop(requestID: requestID))
    ])
    #expect(machine.phase == .finalizing(requestID: requestID))
    #expect(machine.userStoppedRecording().isEmpty)

    let timeoutEffects = machine.finalTimedOut()
    guard case let .sendCancel(timeoutCancel)? = timeoutEffects.first else {
        Issue.record("expected final timeout cancel")
        return
    }
    #expect(timeoutCancel.reason == .clientTimeout)
    #expect(machine.phase == .idle)

    _ = machine.voiceShortcutPressed(makeContext())
    _ = machine.ready(localReady())
    _ = machine.userStoppedRecording()
    let cancelEffects = machine.userCancelled()
    guard case let .sendCancel(cancel)? = cancelEffects.first else {
        Issue.record("expected user abort while finalizing")
        return
    }
    #expect(cancel.reason == .userAbort)
    #expect(machine.phase == .idle)
}

@Test
func clientAcceptsFinalAfterReleaseAndSessionSwitchCancelsFinalizing() {
    var machine = VoiceDictationClientMachine()
    _ = machine.voiceShortcutPressed(makeContext())
    _ = machine.ready(localReady())
    guard case let .listening(requestID) = machine.phase else {
        Issue.record("expected listening phase")
        return
    }
    _ = machine.userStoppedRecording()
    let finalEffects = machine.finalResult(VoiceDictationFinal(
        requestID: requestID,
        finalText: "松开完成",
        confidence: 0.9,
        asrEngineID: "engine",
        polishApplied: false,
        elapsedMilliseconds: 50
    ))
    #expect(finalEffects.contains(where: {
        if case .showPreview(_, _, true, _) = $0 { return true }
        return false
    }))
    #expect(machine.phase == .pendingConfirm(requestID: requestID))

    _ = machine.userCancelled()
    _ = machine.voiceShortcutPressed(makeContext())
    _ = machine.ready(localReady())
    guard case let .listening(secondRequestID) = machine.phase else {
        Issue.record("expected second listening phase")
        return
    }
    _ = machine.userStoppedRecording()
    let switched = machine.sessionSwitched()
    #expect(switched == [.sendCancel(VoiceDictationCancel(
        requestID: secondRequestID,
        reason: .sessionSwitch
    ))])
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
func clientHelloResponseTimeoutAnnouncesAndUsesExistingCircuitBreaker() {
    var machine = VoiceDictationClientMachine()

    for failure in 1 ... VoiceDictationConstants.circuitBreakerLimit {
        _ = machine.voiceShortcutPressed(makeContext())
        let effects = machine.helloResponseTimedOut()
        #expect(effects.contains(.announceFailure(.internalError)))
        #expect(machine.consecutiveProtocolFailures == failure)
        if failure < VoiceDictationConstants.circuitBreakerLimit {
            #expect(machine.phase == .idle)
            #expect(!effects.contains(.voiceDisabled))
        } else {
            #expect(machine.phase == .disabled)
            #expect(effects.contains(.voiceDisabled))
        }
    }

    // 迟到的同一超时不能在 disabled/idle 上重复计数。
    #expect(machine.helloResponseTimedOut().isEmpty)
    #expect(machine.consecutiveProtocolFailures
        == VoiceDictationConstants.circuitBreakerLimit)
}

@Test
func clientSuccessfulFinalBreaksProtocolFailureStreak() {
    var machine = VoiceDictationClientMachine()

    _ = machine.voiceShortcutPressed(makeContext())
    _ = machine.ready(VoiceReadyResponse(
        capabilities: ["telepathy"],
        networkPolicy: .offline,
        asrEngineID: "engine"
    ))
    #expect(machine.consecutiveProtocolFailures == 1)

    _ = machine.voiceShortcutPressed(makeContext())
    _ = machine.ready(localReady())
    guard case let .listening(requestID) = machine.phase else {
        Issue.record("expected recovered listening phase")
        return
    }
    _ = machine.finalResult(VoiceDictationFinal(
        requestID: requestID,
        finalText: "恢复成功",
        confidence: 0.9,
        asrEngineID: "engine",
        polishApplied: false,
        elapsedMilliseconds: 100
    ))
    #expect(machine.consecutiveProtocolFailures == 0)
    _ = machine.userCancelled()

    for expectedCount in 1 ... 2 {
        _ = machine.voiceShortcutPressed(makeContext())
        _ = machine.ready(VoiceReadyResponse(
            capabilities: ["telepathy"],
            networkPolicy: .offline,
            asrEngineID: "engine"
        ))
        #expect(machine.consecutiveProtocolFailures == expectedCount)
        #expect(machine.phase == .idle)
    }

    _ = machine.voiceShortcutPressed(makeContext())
    _ = machine.ready(VoiceReadyResponse(
        capabilities: ["telepathy"],
        networkPolicy: .offline,
        asrEngineID: "engine"
    ))
    #expect(machine.phase == .disabled)
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
        .partial(stableText: "我们需要", partialText: "索引", confidence: 0.7)
    ])
    for output in server.handle(start) {
        if case let .delta(delta) = output {
            _ = machine.delta(delta)
        }
    }
    engine.enqueueOnStop([
        .finished(text: "我们需要索引", confidence: 0.9, polishApplied: false)
    ])
    var finalMessage: VoiceDictationFinal?
    var stopMessage: VoiceDictationStop?
    for effect in machine.userStoppedRecording() {
        if case let .sendStop(message) = effect {
            stopMessage = message
        }
    }
    for output in server.handle(stopMessage!) {
        if case let .final(final) = output {
            finalMessage = final
        }
    }
    #expect(engine.stoppedRequestIDs == engine.startedRequestIDs)
    #expect(finalMessage != nil)

    _ = machine.finalResult(finalMessage!)
    var acceptMessage: VoiceDictationAccept?
    for effect in machine.userConfirmed() {
        if case let .commitText(_, accept) = effect {
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
    #expect(engine.cancelledRequestIDs == engine.startedRequestIDs)

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
        .stop(VoiceDictationStop(requestID: "req-1")),
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
    private var disconnects = 0

    func append(_ message: VoiceServerMessage) {
        condition.lock()
        messages.append(message)
        condition.broadcast()
        condition.unlock()
    }

    func markDisconnected() {
        condition.lock()
        disconnected = true
        disconnects += 1
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

    func waitForCount(
        _ count: Int,
        matching predicate: @escaping (VoiceServerMessage) -> Bool,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while messages.filter(predicate).count < count {
            guard condition.wait(until: deadline) else {
                throw NSError(
                    domain: "voice-collector", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "timed out"]
                )
            }
        }
    }

    var disconnectCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return disconnects
    }
}

/// hello 超时使用的手动调度器：测试显式 fire，不依赖墙钟或 sleep。
final class ManualVoiceTimeoutScheduler: @unchecked Sendable {
    private final class Scheduled: @unchecked Sendable {
        private let lock = NSLock()
        private var operation: (@Sendable () -> Void)?

        init(operation: @escaping @Sendable () -> Void) {
            self.operation = operation
        }

        func cancel() {
            lock.lock()
            operation = nil
            lock.unlock()
        }

        func fire() {
            lock.lock()
            let operation = operation
            self.operation = nil
            lock.unlock()
            operation?()
        }
    }

    private let condition = NSCondition()
    private var scheduled: [Scheduled] = []

    func schedule(
        after _: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) -> VoiceDictationTimeoutCancellation {
        let task = Scheduled(operation: operation)
        condition.lock()
        scheduled.append(task)
        condition.broadcast()
        condition.unlock()
        return { task.cancel() }
    }

    func waitForScheduledCount(
        _ count: Int,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while scheduled.count < count {
            guard condition.wait(until: deadline) else {
                throw NSError(
                    domain: "voice-timeout-scheduler",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "timed out"]
                )
            }
        }
    }

    func fire(_ index: Int) {
        condition.lock()
        let task = scheduled.indices.contains(index)
            ? scheduled[index]
            : nil
        condition.unlock()
        task?.fire()
    }

    var scheduledCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return scheduled.count
    }
}

/// 接受并读取客户端消息，但不会自动回答 hello；测试可精确决定何时
/// 回送 ready，从而把握手计时与真实 UDS 连接建立分开控制。
final class ControllableVoiceHelloServer: @unchecked Sendable {
    private let condition = NSCondition()
    private let socketPath: String
    private let queue = DispatchQueue(label: "voice-silent-hello-server")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var helloCount = 0

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketPath)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else {
                return
            }
            self?.condition.lock()
            self?.condition.broadcast()
            self?.condition.unlock()
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        condition.lock()
        self.listener = listener
        condition.unlock()
        listener.start(queue: queue)
    }

    func stop() {
        condition.lock()
        let listener = self.listener
        let connections = self.connections
        self.listener = nil
        self.connections.removeAll()
        condition.unlock()
        listener?.cancel()
        for connection in connections {
            connection.cancel()
        }
    }

    func waitForHelloCount(
        _ count: Int,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while helloCount < count {
            guard condition.wait(until: deadline) else {
                throw NSError(
                    domain: "voice-controllable-server",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "hello timed out"]
                )
            }
        }
    }

    func waitForConnectionCount(
        _ count: Int,
        timeout: TimeInterval
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while connections.count < count {
            guard condition.wait(until: deadline) else {
                throw NSError(
                    domain: "voice-controllable-server",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "connect timed out"]
                )
            }
        }
    }

    func send(_ message: VoiceServerMessage) throws {
        let data = try VoiceDictationWire.encode(message)
        condition.lock()
        let connection = connections.last
        condition.unlock()
        guard let connection else {
            throw NSError(
                domain: "voice-controllable-server",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "no connection"]
            )
        }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func accept(_ connection: NWConnection) {
        condition.lock()
        connections.append(connection)
        condition.broadcast()
        condition.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let connection else {
                return
            }
            self?.receive(connection, buffer: Data())
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: VoiceDictationWire.maximumLineBytes
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            if let extracted = try? VoiceDictationWire.extractLines(
                from: nextBuffer
            ) {
                nextBuffer = extracted.remainder
                let receivedHellos = extracted.lines.reduce(into: 0) {
                    count, line in
                    guard case .hello = try? VoiceDictationWire
                        .decodeClientLine(line)
                    else {
                        return
                    }
                    count += 1
                }
                if receivedHellos > 0 {
                    condition.lock()
                    helloCount += receivedHellos
                    condition.broadcast()
                    condition.unlock()
                }
            }
            if error == nil, !isComplete {
                self.receive(connection, buffer: nextBuffer)
            }
        }
    }
}

/// Keep UDS fixtures well below Darwin's `sockaddr_un.sun_path` limit.
/// `NSTemporaryDirectory()` is long enough that appending a UUID can make
/// Network.framework trap during `NWConnection` construction.
func makeVoiceTestSocketPath() -> String {
    let root = "/tmp/rav-\(getuid())-\(getpid())"
    let fileManager = FileManager.default
    try? fileManager.createDirectory(
        atPath: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try? fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: root
    )
    return "\(root)/\(UUID().uuidString).sock"
}

/// Network.framework's UDS listener/connection setup uses shared process state
/// and can trap when many independent socket fixtures are created at once.
/// Keep only the real-transport integration tests serialized; protocol and
/// state-machine tests above remain parallel.
@Suite(.serialized)
struct VoiceDictationSocketTests {
@Test
func serverTransportRejectsNonPrivateSocketDirectory() throws {
    let root = "/tmp/rav-public-\(UUID().uuidString.prefix(8))"
    let socketPath = "\(root)/voice.sock"
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        atPath: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o755]
    )
    try fileManager.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: root
    )
    defer { try? fileManager.removeItem(atPath: root) }

    let server = VoiceDictationServerTransport(
        socketPath: socketPath,
        core: VoiceDictationServerCore(engine: ScriptedVoiceEngine())
    )
    #expect(
        throws: VoiceDictationTransportError.insecureSocketDirectory
    ) {
        try server.start()
    }
}

@Test
func serverTransportRejectsExtendedACLOnSocketDirectory() throws {
    let root = "/tmp/rav-acl-\(UUID().uuidString.prefix(8))"
    let socketPath = "\(root)/voice.sock"
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        atPath: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: root
    )
    defer { try? fileManager.removeItem(atPath: root) }

    let chmod = Process()
    chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
    chmod.arguments = ["+a", "everyone allow list,search", root]
    chmod.standardOutput = FileHandle.nullDevice
    chmod.standardError = FileHandle.nullDevice
    try chmod.run()
    chmod.waitUntilExit()
    #expect(chmod.terminationStatus == 0)

    let server = VoiceDictationServerTransport(
        socketPath: socketPath,
        core: VoiceDictationServerCore(engine: ScriptedVoiceEngine())
    )
    #expect(
        throws: VoiceDictationTransportError.insecureSocketDirectory
    ) {
        try server.start()
    }
}

@Test
func serverTransportPublishesCurrentUser0600Socket() throws {
    let root = "/tmp/rav-private-\(UUID().uuidString.prefix(8))"
    let socketPath = "\(root)/voice.sock"
    let fileManager = FileManager.default
    defer { try? fileManager.removeItem(atPath: root) }

    let server = VoiceDictationServerTransport(
        socketPath: socketPath,
        core: VoiceDictationServerCore(engine: ScriptedVoiceEngine())
    )
    try server.start()
    defer { server.stop() }

    let directoryAttributes = try fileManager.attributesOfItem(atPath: root)
    let socketAttributes = try fileManager.attributesOfItem(atPath: socketPath)
    #expect(
        (directoryAttributes[.ownerAccountID] as? NSNumber)?.uint32Value
            == geteuid()
    )
    #expect(
        (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
            == 0o700
    )
    #expect(
        (socketAttributes[.ownerAccountID] as? NSNumber)?.uint32Value
            == geteuid()
    )
    #expect(
        (socketAttributes[.posixPermissions] as? NSNumber)?.intValue
            == 0o600
    )
}

@Test
func transportLoopbackOverRealUDSSocket() async throws {
    let engine = ScriptedVoiceEngine()
    engine.enqueue([
        .partial(stableText: "传输层", partialText: "回环", confidence: 0.7)
    ])
    engine.enqueueOnStop([
        .finished(text: "传输层回环结果", confidence: 0.9, polishApplied: false)
    ])
    let core = VoiceDictationServerCore(engine: engine)
    let socketPath = makeVoiceTestSocketPath()
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
    _ = try collector.wait(
        for: { if case .delta = $0 { return true }; return false },
        timeout: 5
    )
    client.send(.stop(VoiceDictationStop(requestID: "wire-1")))
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
    let socketPath = makeVoiceTestSocketPath()
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

@Test
func replacementTransportConnectionMustHandshakeAgain() async throws {
    let core = VoiceDictationServerCore(engine: ScriptedVoiceEngine())
    let socketPath = makeVoiceTestSocketPath()
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let server = VoiceDictationServerTransport(socketPath: socketPath, core: core)
    try server.start()
    defer { server.stop() }

    let firstClient = VoiceDictationClientTransport(socketPath: socketPath)
    let firstCollector = VoiceMessageCollector()
    firstClient.setMessageHandler { firstCollector.append($0) }
    try await firstClient.connect(timeout: 5)
    firstClient.send(.hello(VoiceHelloRequest()))
    _ = try firstCollector.wait(
        for: { if case .ready = $0 { return true }; return false },
        timeout: 5
    )
    firstClient.close()

    let replacement = VoiceDictationClientTransport(socketPath: socketPath)
    defer { replacement.close() }
    let replacementCollector = VoiceMessageCollector()
    replacement.setDisconnectHandler {
        replacementCollector.markDisconnected()
    }
    try await replacement.connect(timeout: 5)
    // 新连接不能继承上一连接的握手状态。
    replacement.send(.start(makeStart(requestID: "without-new-hello")))
    try replacementCollector.waitForDisconnect(timeout: 5)
}

@Test
func clientTransportIgnoresDisconnectFromReplacedConnection() async throws {
    let core = VoiceDictationServerCore(engine: ScriptedVoiceEngine())
    let socketPath = makeVoiceTestSocketPath()
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let server = VoiceDictationServerTransport(socketPath: socketPath, core: core)
    try server.start()
    defer { server.stop() }

    let client = VoiceDictationClientTransport(socketPath: socketPath)
    defer { client.close() }
    let collector = VoiceMessageCollector()
    client.setMessageHandler { collector.append($0) }
    client.setDisconnectHandler { collector.markDisconnected() }

    try await client.connect(timeout: 5)
    client.send(.hello(VoiceHelloRequest()))
    try collector.waitForCount(
        1,
        matching: { if case .ready = $0 { return true }; return false },
        timeout: 5
    )

    // 同一 transport 安装新 NWConnection 会取消旧连接；旧连接的迟到
    // disconnect 不得击穿新连接或触发 Coordinator 失败路径。
    try await client.connect(timeout: 5)
    client.send(.hello(VoiceHelloRequest()))
    try collector.waitForCount(
        2,
        matching: { if case .ready = $0 { return true }; return false },
        timeout: 5
    )
    try await Task.sleep(for: .milliseconds(100))
    #expect(collector.disconnectCount == 0)
}

@Test
func transportHandlesSynchronousEngineDisconnectWithoutRouteDeadlock() async throws {
    let engine = ScriptedVoiceEngine(
        capabilities: [
            .localASR, .streaming, .polish, .hotwordSnapshot,
        ]
    )
    engine.enqueue([.failed(.polishFailed, retryable: true)])
    let core = VoiceDictationServerCore(engine: engine)
    let socketPath = makeVoiceTestSocketPath()
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let server = VoiceDictationServerTransport(socketPath: socketPath, core: core)
    try server.start()
    defer { server.stop() }

    let client = VoiceDictationClientTransport(socketPath: socketPath)
    defer { client.close() }
    let collector = VoiceMessageCollector()
    client.setMessageHandler { collector.append($0) }
    client.setDisconnectHandler { collector.markDisconnected() }
    try await client.connect(timeout: 5)
    client.send(.hello(VoiceHelloRequest()))
    _ = try collector.wait(
        for: { if case .ready = $0 { return true }; return false },
        timeout: 5
    )

    client.send(.start(makeStart(requestID: "sync-disconnect", mode: .polish)))
    try collector.waitForDisconnect(timeout: 5)
}

// MARK: - Coordinator 全栈（真实 socket）

/// 线程安全的 UI 回调收集器。
final class CoordinatorCallbackCollector: @unchecked Sendable {
    struct Snapshot: Sendable {
        let commits: [String]
        let pendingPreviews: Int
        let streamingPreviews: Int
        let phases: [VoiceDictationClientPhase]
        let announcements: [VoiceDictationErrorCode]
        let disabledCount: Int
    }

    private let condition = NSCondition()
    private var previews: [(stable: String, partial: String, pending: Bool, polish: Bool)] = []
    private var commits: [String] = []
    private var phases: [VoiceDictationClientPhase] = []
    private var announcements: [VoiceDictationErrorCode] = []
    private var disabledCount = 0

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

    func appendPhase(_ phase: VoiceDictationClientPhase) {
        condition.lock()
        phases.append(phase)
        condition.broadcast()
        condition.unlock()
    }

    func appendAnnouncement(_ code: VoiceDictationErrorCode) {
        condition.lock()
        announcements.append(code)
        condition.broadcast()
        condition.unlock()
    }

    func appendDisabled() {
        condition.lock()
        disabledCount += 1
        condition.broadcast()
        condition.unlock()
    }

    private func snapshotLocked() -> Snapshot {
        Snapshot(
            commits: commits,
            pendingPreviews: previews.filter { $0.pending }.count,
            streamingPreviews: previews.filter { !$0.pending }.count,
            phases: phases,
            announcements: announcements,
            disabledCount: disabledCount
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

    var snapshot: Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return snapshotLocked()
    }
}

final class CommitAttemptRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var attempts = 0

    func record() {
        condition.lock()
        attempts += 1
        condition.broadcast()
        condition.unlock()
    }

    func waitForAttempt(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while attempts == 0 {
            guard condition.wait(until: deadline) else {
                throw NSError(
                    domain: "commit-attempt-recorder", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "timed out"]
                )
            }
        }
    }


    var attemptCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return attempts
    }
}

@Test
func coordinatorFullStackCommitsAfterConfirmation() throws {
    let hotwordSnapshot = try VoiceHotwordSnapshot(
        phrases: ["RimeAI", "语音输入"]
    )
    let engine = ScriptedVoiceEngine()
    engine.enqueue([
        .partial(stableText: "协同器", partialText: "测试", confidence: 0.7)
    ])
    engine.enqueueOnStop([
        .finished(text: "协同器全栈结果", confidence: 0.9, polishApplied: false)
    ])
    let core = VoiceDictationServerCore(engine: engine)
    let socketPath = makeVoiceTestSocketPath()
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let server = VoiceDictationServerTransport(socketPath: socketPath, core: core)
    try server.start()
    defer { server.stop() }

    let coordinator = VoiceDictationCoordinator(
        configuration: .init(
            socketPath: socketPath,
            uiQueue: DispatchQueue(label: "voice-full-stack-ui")
        )
    )
    defer { coordinator.shutdown() }
    let collector = CoordinatorCallbackCollector()
    coordinator.onPreview = { stable, partial, pending, polish in
        collector.appendPreview(
            stable: stable, partial: partial, pending: pending, polish: polish
        )
    }
    coordinator.onCommit = { text in
        collector.appendCommit(text)
        return true
    }
    coordinator.onPhaseChanged = { phase in
        collector.appendPhase(phase)
    }

    coordinator.startDictation(makeContext(
        hotwordSnapshot: hotwordSnapshot
    ))

    // 按下后只产生流式预览；松开才请求 final。
    try collector.waitUntil(timeout: 5) {
        $0.streamingPreviews >= 1
    }
    #expect(engine.startedRequests.first?.hotwordSnapshot == hotwordSnapshot)
    coordinator.stopDictation()
    try collector.waitUntil(timeout: 5) {
        $0.pendingPreviews >= 1
            && $0.phases.contains(where: {
                if case .finalizing = $0 { return true }
                return false
            })
            && $0.phases.contains(where: {
                if case .pendingConfirm = $0 { return true }
                return false
            })
    }
    #expect(engine.stoppedRequestIDsSnapshot.count == 1)

    // 确认前没有任何 commit：上屏唯一触发是显式确认。
    #expect(collector.committedTexts.isEmpty)

    coordinator.userConfirmed()
    try collector.waitUntil(timeout: 5) {
        $0.commits == ["协同器全栈结果"]
    }
    let acknowledgeDeadline = Date().addingTimeInterval(5)
    while core.hasPendingFinalAcknowledgement,
          Date() < acknowledgeDeadline
    {
        Thread.sleep(forTimeInterval: 0.01)
    }
    #expect(!core.hasPendingFinalAcknowledgement)
    #expect(coordinator.phaseForTesting == .idle)
}

@Test
func coordinatorDoesNotAcknowledgeWhenHostCommitFails() throws {
    let engine = ScriptedVoiceEngine()
    engine.enqueue([
        .partial(stableText: "不会", partialText: "上屏", confidence: 0.7)
    ])
    engine.enqueueOnStop([
        .finished(text: "不会上屏", confidence: 0.9, polishApplied: false)
    ])
    let core = VoiceDictationServerCore(engine: engine)
    let socketPath = makeVoiceTestSocketPath()
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let server = VoiceDictationServerTransport(socketPath: socketPath, core: core)
    try server.start()
    defer { server.stop() }

    let coordinator = VoiceDictationCoordinator(
        configuration: .init(
            socketPath: socketPath,
            uiQueue: DispatchQueue(label: "voice-commit-failure-ui")
        )
    )
    defer { coordinator.shutdown() }
    let collector = CoordinatorCallbackCollector()
    let attempts = CommitAttemptRecorder()
    coordinator.onPreview = { stable, partial, pending, polish in
        collector.appendPreview(
            stable: stable, partial: partial, pending: pending, polish: polish
        )
    }
    coordinator.onCommit = { _ in
        attempts.record()
        return false
    }

    coordinator.startDictation(makeContext())
    try collector.waitUntil(timeout: 5) { $0.streamingPreviews >= 1 }
    coordinator.stopDictation()
    try collector.waitUntil(timeout: 5) { $0.pendingPreviews >= 1 }
    #expect(core.hasPendingFinalAcknowledgement)

    coordinator.userConfirmed()
    try attempts.waitForAttempt(timeout: 5)
    // 给错误实现中可能独立发送的 accept 留出传输窗口。
    Thread.sleep(forTimeInterval: 0.1)
    #expect(core.hasPendingFinalAcknowledgement)
    #expect(coordinator.phaseForTesting == .idle)
}

@Test
func coordinatorDropsQueuedCommitAfterSessionSwitch() throws {
    let engine = ScriptedVoiceEngine()
    engine.enqueue([
        .partial(stableText: "旧目标", partialText: "预览", confidence: 0.7)
    ])
    engine.enqueueOnStop([
        .finished(text: "旧目标文本", confidence: 0.9, polishApplied: false)
    ])
    let core = VoiceDictationServerCore(engine: engine)
    let socketPath = makeVoiceTestSocketPath()
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let server = VoiceDictationServerTransport(socketPath: socketPath, core: core)
    try server.start()
    defer { server.stop() }

    let uiQueue = DispatchQueue(label: "voice-stale-commit-ui")
    let coordinator = VoiceDictationCoordinator(
        configuration: .init(socketPath: socketPath, uiQueue: uiQueue)
    )
    defer { coordinator.shutdown() }
    let collector = CoordinatorCallbackCollector()
    let attempts = CommitAttemptRecorder()
    coordinator.onPreview = { stable, partial, pending, polish in
        collector.appendPreview(
            stable: stable, partial: partial, pending: pending, polish: polish
        )
    }
    coordinator.onCommit = { _ in
        attempts.record()
        return true
    }

    coordinator.startDictation(makeContext())
    try collector.waitUntil(timeout: 5) { $0.streamingPreviews >= 1 }
    coordinator.stopDictation()
    try collector.waitUntil(timeout: 5) { $0.pendingPreviews >= 1 }

    let blockerEntered = DispatchSemaphore(value: 0)
    let releaseBlocker = DispatchSemaphore(value: 0)
    uiQueue.async {
        blockerEntered.signal()
        releaseBlocker.wait()
    }
    #expect(blockerEntered.wait(timeout: .now() + 5) == .success)

    coordinator.userConfirmed()
    coordinator.sessionSwitched()
    releaseBlocker.signal()
    Thread.sleep(forTimeInterval: 0.1)

    #expect(attempts.attemptCount == 0)
    #expect(core.hasPendingFinalAcknowledgement)
    #expect(coordinator.phaseForTesting == .idle)
}

@Test
func coordinatorFinalTimeoutCancelsAfterReleaseAndPublishesIdle() throws {
    let engine = ScriptedVoiceEngine()
    engine.enqueue([
        .partial(stableText: "等待", partialText: "最终结果", confidence: 0.7)
    ])
    let core = VoiceDictationServerCore(engine: engine)
    let socketPath = makeVoiceTestSocketPath()
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let server = VoiceDictationServerTransport(socketPath: socketPath, core: core)
    try server.start()
    defer { server.stop() }

    let coordinator = VoiceDictationCoordinator(
        configuration: .init(
            socketPath: socketPath,
            deltaTimeout: 2,
            finalTimeout: 0.2,
            uiQueue: DispatchQueue(label: "voice-final-timeout-ui")
        )
    )
    defer { coordinator.shutdown() }
    let collector = CoordinatorCallbackCollector()
    coordinator.onPreview = { stable, partial, pending, polish in
        collector.appendPreview(
            stable: stable, partial: partial, pending: pending, polish: polish
        )
    }
    coordinator.onPhaseChanged = { collector.appendPhase($0) }

    coordinator.startDictation(makeContext())
    try collector.waitUntil(timeout: 5) { $0.streamingPreviews >= 1 }
    coordinator.stopDictation()
    try collector.waitUntil(timeout: 5) {
        $0.phases.last == .idle
    }

    let cancelDeadline = Date().addingTimeInterval(5)
    while engine.cancelledRequestIDsSnapshot.isEmpty,
          Date() < cancelDeadline
    {
        Thread.sleep(forTimeInterval: 0.01)
    }

    #expect(engine.stoppedRequestIDsSnapshot.count == 1)
    #expect(engine.cancelledRequestIDsSnapshot.count == 1)
    #expect(coordinator.phaseForTesting == .idle)
}

@Test
func coordinatorReleaseWhileConnectingPublishesIdleAndIgnoresLateFailure() throws {
    let socketPath = makeVoiceTestSocketPath()
    let coordinator = VoiceDictationCoordinator(
        configuration: .init(
            socketPath: socketPath,
            connectTimeout: 0.2,
            uiQueue: DispatchQueue(label: "voice-connecting-release-ui")
        )
    )
    defer { coordinator.shutdown() }
    let collector = CoordinatorCallbackCollector()
    coordinator.onPhaseChanged = { collector.appendPhase($0) }

    coordinator.startDictation(makeContext())
    coordinator.stopDictation()
    try collector.waitUntil(timeout: 5) {
        $0.phases.contains(.connecting) && $0.phases.last == .idle
    }
    Thread.sleep(forTimeInterval: 0.3)
    #expect(coordinator.phaseForTesting == .idle)
}

@Test
func coordinatorHelloResponseTimeoutClosesGenerationAnnouncesAndCanRetry() throws {
    let socketPath = makeVoiceTestSocketPath()
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let server = ControllableVoiceHelloServer(socketPath: socketPath)
    try server.start()
    defer { server.stop() }
    let scheduler = ManualVoiceTimeoutScheduler()
    let coordinator = VoiceDictationCoordinator(
        configuration: .init(
            socketPath: socketPath,
            helloResponseTimeout: 60,
            deltaTimeout: 60,
            finalTimeout: 60,
            uiQueue: DispatchQueue(label: "voice-hello-timeout-ui")
        ),
        scheduleHelloResponseTimeout: { delay, operation in
            scheduler.schedule(after: delay, operation: operation)
        }
    )
    defer { coordinator.shutdown() }
    let collector = CoordinatorCallbackCollector()
    coordinator.onPhaseChanged = { collector.appendPhase($0) }
    coordinator.onAnnounce = { collector.appendAnnouncement($0) }
    coordinator.onDisabled = { collector.appendDisabled() }

    coordinator.startDictation(makeContext())
    try server.waitForHelloCount(1, timeout: 5)
    try scheduler.waitForScheduledCount(1, timeout: 5)
    #expect(coordinator.phaseForTesting == .connecting)

    // Secure Input 解除是 no-op，不得让在途握手 timer 的 epoch 失效。
    coordinator.secureInputChanged(active: false)
    scheduler.fire(0)
    try collector.waitUntil(timeout: 5) {
        $0.phases.last == .idle
            && $0.announcements == [.internalError]
    }
    #expect(coordinator.phaseForTesting == .idle)
    #expect(collector.snapshot.disabledCount == 0)

    // 超时必须关闭并失效旧 transport；重试建立第二条连接并发送新 hello。
    coordinator.startDictation(makeContext())
    try server.waitForConnectionCount(2, timeout: 5)
    try server.waitForHelloCount(2, timeout: 5)
    try scheduler.waitForScheduledCount(2, timeout: 5)
    #expect(coordinator.phaseForTesting == .connecting)

    // connecting 阶段松开会取消第二个 hello timer；迟到 fire 不得再报错。
    coordinator.stopDictation()
    try collector.waitUntil(timeout: 5) { $0.phases.last == .idle }
    scheduler.fire(1)
    #expect(coordinator.phaseForTesting == .idle)
    #expect(collector.snapshot.announcements == [.internalError])
}

@Test
func coordinatorReadyCancelsHelloTimerWithoutAffectingFinalTimeout() throws {
    let socketPath = makeVoiceTestSocketPath()
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let server = ControllableVoiceHelloServer(socketPath: socketPath)
    try server.start()
    defer { server.stop() }
    let scheduler = ManualVoiceTimeoutScheduler()
    let coordinator = VoiceDictationCoordinator(
        configuration: .init(
            socketPath: socketPath,
            helloResponseTimeout: 60,
            deltaTimeout: 60,
            finalTimeout: 60,
            uiQueue: DispatchQueue(label: "voice-ready-cancels-timeout-ui")
        ),
        scheduleHelloResponseTimeout: { delay, operation in
            scheduler.schedule(after: delay, operation: operation)
        }
    )
    defer { coordinator.shutdown() }
    let collector = CoordinatorCallbackCollector()
    coordinator.onPhaseChanged = { collector.appendPhase($0) }
    coordinator.onAnnounce = { collector.appendAnnouncement($0) }

    coordinator.startDictation(makeContext())
    try server.waitForHelloCount(1, timeout: 5)
    try scheduler.waitForScheduledCount(1, timeout: 5)
    try server.send(.ready(localReady()))
    try collector.waitUntil(timeout: 5) {
        $0.phases.contains(where: {
            if case .listening = $0 { return true }
            return false
        })
    }

    coordinator.stopDictation()
    guard case .finalizing = coordinator.phaseForTesting else {
        Issue.record("expected independent finalizing timeout phase")
        return
    }
    scheduler.fire(0)
    guard case .finalizing = coordinator.phaseForTesting else {
        Issue.record("cancelled hello timer changed finalizing phase")
        return
    }
    #expect(collector.snapshot.announcements.isEmpty)
}

@Test
func coordinatorCanRestartBeforeAbandonedConnectReturns() throws {
    let socketPath = makeVoiceTestSocketPath()
    let coordinator = VoiceDictationCoordinator(
        configuration: .init(
            socketPath: socketPath,
            connectTimeout: 0.2,
            uiQueue: DispatchQueue(label: "voice-immediate-restart-ui")
        )
    )
    defer { coordinator.shutdown() }
    let collector = CoordinatorCallbackCollector()
    coordinator.onPhaseChanged = { collector.appendPhase($0) }

    coordinator.startDictation(makeContext())
    coordinator.stopDictation()
    coordinator.startDictation(makeContext())

    try collector.waitUntil(timeout: 5) {
        $0.phases.filter { $0 == .connecting }.count >= 2
            && $0.phases.last == .idle
    }
    #expect(coordinator.phaseForTesting == .idle)
}

@Test
func coordinatorRetriesAfterCurrentConnectFailureWithoutExplicitReset() throws {
    let socketPath = makeVoiceTestSocketPath()
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let scheduler = ManualVoiceTimeoutScheduler()
    let coordinator = VoiceDictationCoordinator(
        configuration: .init(
            socketPath: socketPath,
            connectTimeout: 0.2,
            uiQueue: DispatchQueue(label: "voice-connect-retry-ui")
        ),
        scheduleHelloResponseTimeout: { delay, operation in
            scheduler.schedule(after: delay, operation: operation)
        }
    )
    defer { coordinator.shutdown() }
    let collector = CoordinatorCallbackCollector()
    coordinator.onPhaseChanged = { collector.appendPhase($0) }
    coordinator.onPreview = { stable, partial, pending, polish in
        collector.appendPreview(
            stable: stable,
            partial: partial,
            pending: pending,
            polish: polish
        )
    }

    // 第一次连接在当前 epoch 内真实失败，必须清掉 isConnecting。
    coordinator.startDictation(makeContext())
    try collector.waitUntil(timeout: 5) {
        $0.phases.contains(.connecting) && $0.phases.last == .idle
    }
    #expect(scheduler.scheduledCount == 0)

    let engine = ScriptedVoiceEngine()
    engine.enqueue([
        .partial(stableText: "重试", partialText: "成功", confidence: 0.8)
    ])
    let core = VoiceDictationServerCore(engine: engine)
    let server = VoiceDictationServerTransport(socketPath: socketPath, core: core)
    try server.start()
    defer { server.stop() }

    coordinator.startDictation(makeContext())
    try collector.waitUntil(timeout: 5) { $0.streamingPreviews >= 1 }
    #expect(engine.startedRequestIDs.count == 1)
    guard case .listening = coordinator.phaseForTesting else {
        Issue.record("expected retry to reach listening")
        return
    }
}

@Test
func coordinatorResetReconnectsWithFreshHandshakeAndShutdownClosesSession() throws {
    let engine = ScriptedVoiceEngine()
    engine.enqueue([
        .partial(stableText: "第一次", partialText: "连接", confidence: 0.7)
    ])
    let core = VoiceDictationServerCore(engine: engine)
    let socketPath = makeVoiceTestSocketPath()
    defer { try? FileManager.default.removeItem(atPath: socketPath) }
    let server = VoiceDictationServerTransport(socketPath: socketPath, core: core)
    try server.start()
    defer { server.stop() }

    let coordinator = VoiceDictationCoordinator(
        configuration: .init(
            socketPath: socketPath,
            uiQueue: DispatchQueue(label: "voice-reset-ui")
        )
    )
    defer { coordinator.shutdown() }
    let collector = CoordinatorCallbackCollector()
    coordinator.onPreview = { stable, partial, pending, polish in
        collector.appendPreview(
            stable: stable, partial: partial, pending: pending, polish: polish
        )
    }

    coordinator.startDictation(makeContext())
    try collector.waitUntil(timeout: 5) { $0.streamingPreviews >= 1 }
    coordinator.resetConnection()
    #expect(coordinator.phaseForTesting == .idle)

    engine.enqueue([
        .partial(stableText: "第二次", partialText: "连接", confidence: 0.8)
    ])
    coordinator.startDictation(makeContext())
    try collector.waitUntil(timeout: 5) { $0.streamingPreviews >= 2 }
    #expect(engine.startedRequestIDs.count == 2)

    coordinator.shutdown()
    #expect(coordinator.phaseForTesting == .idle)
    let cancelDeadline = Date().addingTimeInterval(5)
    while engine.cancelledRequestIDsSnapshot.count < 2,
          Date() < cancelDeadline
    {
        Thread.sleep(forTimeInterval: 0.01)
    }
    #expect(engine.cancelledRequestIDsSnapshot.count == 2)
}

@Test
func coordinatorDeltaTimeoutCancelsSilently() throws {
    // 引擎不产出任何事件：delta 超时必须触发静默取消。
    let engine = ScriptedVoiceEngine()
    let core = VoiceDictationServerCore(engine: engine)
    let socketPath = makeVoiceTestSocketPath()
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
    defer { coordinator.shutdown() }
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
}
