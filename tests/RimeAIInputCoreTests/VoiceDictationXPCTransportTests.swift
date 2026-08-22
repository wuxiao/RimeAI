import Darwin
import Foundation
import Testing
@testable import RimeAIInputCore

@Suite(.serialized)
struct VoiceDictationXPCTransportTests {
    @Test
    func signingRequirementPinsAnchorTeamAndExactIdentifier() throws {
        let policy = try VoiceDictationXPCPeerPolicy(
            expectedIdentifier: "fun.wwcn.rimeai.voice-helper",
            expectedTeamIdentifier: "A1B2C3D4E5",
            expectedEffectiveUserIdentifier: 501
        )
        #expect(policy.codeSigningRequirement == (
            "anchor apple generic"
                + " and identifier \"fun.wwcn.rimeai.voice-helper\""
                + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
                + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                + " and certificate leaf[subject.OU] = \"A1B2C3D4E5\""
        ))
        #expect(policy.expectedEffectiveUserIdentifier == 501)
    }

    @Test
    func signingRequirementRejectsUntrustedSyntax() {
        #expect(throws: VoiceDictationTransportError.invalidPeerIdentity) {
            _ = try VoiceDictationXPCPeerPolicy(
                expectedIdentifier: "helper\" or true",
                expectedTeamIdentifier: "A1B2C3D4E5"
            )
        }
        #expect(throws: VoiceDictationTransportError.invalidPeerIdentity) {
            _ = try VoiceDictationXPCPeerPolicy(
                expectedIdentifier: "fun.wwcn.rimeai.voice-helper",
                expectedTeamIdentifier: "short"
            )
        }
    }

    @Test
    func xpcPayloadUsesOneBoundedJSONRecordWithoutDelimiter() throws {
        let message = VoiceClientMessage.hello(VoiceHelloRequest())
        let payload = try VoiceDictationWire.encodeXPCPayload(message)
        #expect(payload.count <= VoiceDictationWire.maximumLineBytes)
        #expect(payload.last != 0x0A)
        #expect(try VoiceDictationWire.decodeXPCClientPayload(payload) == message)

        var secondLine = payload
        secondLine.append(0x0A)
        secondLine.append(contentsOf: payload)
        #expect(throws: VoiceDictationWireError.malformedJSON) {
            _ = try VoiceDictationWire.decodeXPCClientPayload(secondLine)
        }
        #expect(throws: VoiceDictationWireError.lineTooLong) {
            _ = try VoiceDictationWire.decodeXPCClientPayload(
                Data(repeating: 0x41, count:
                    VoiceDictationWire.maximumLineBytes + 1)
            )
        }
    }

    @Test
    func anonymousXPCCompletesHelloStartStopFinalAndAccept() async throws {
        let engine = ScriptedVoiceEngine()
        engine.enqueue([
            .partial(
                stableText: "认证",
                partialText: "回环",
                confidence: 0.8
            ),
        ])
        engine.enqueueOnStop([
            .finished(
                text: "认证回环完成",
                confidence: 0.95,
                polishApplied: false
            ),
        ])
        let listener = NSXPCListener.anonymous()
        let server = VoiceDictationXPCServerTransport(
            anonymousListener: listener,
            core: VoiceDictationServerCore(engine: engine)
        )
        try server.start()
        defer { server.stop() }

        let client = VoiceDictationXPCClientTransport(
            listenerEndpoint: listener.endpoint
        )
        defer { client.close() }
        let collector = VoiceMessageCollector()
        client.setGenerationMessageHandler { message, _ in
            collector.append(message)
        }
        client.setGenerationDisconnectHandler { _ in
            collector.markDisconnected()
        }
        try await client.connect(timeout: 3)

        client.send(.hello(VoiceHelloRequest()))
        _ = try collector.wait(
            for: { if case .ready = $0 { true } else { false } },
            timeout: 3
        )

        let hotwordSnapshot = try VoiceHotwordSnapshot(
            phrases: ["RimeAI", "认证回环"]
        )
        let start = VoiceDictationStart(
            requestID: "xpc-loop-1",
            compositionID: UUID(),
            appSessionID: "xpc-session",
            bundleID: "com.example.host",
            mode: .direct,
            deadlineMilliseconds: 3_000,
            hotwordSnapshot: hotwordSnapshot
        )
        client.send(.start(start))
        _ = try collector.wait(
            for: { if case .delta = $0 { true } else { false } },
            timeout: 3
        )
        #expect(engine.startedRequests.first?.hotwordSnapshot == hotwordSnapshot)
        client.send(.stop(VoiceDictationStop(requestID: "xpc-loop-1")))
        let final = try collector.wait(
            for: { if case .final = $0 { true } else { false } },
            timeout: 3
        )
        guard case .final(let finalMessage) = final else {
            Issue.record("expected final")
            return
        }
        #expect(finalMessage.finalText == "认证回环完成")
        client.send(.accept(VoiceDictationAccept(
            requestID: "xpc-loop-1",
            acceptedTextSHA256: VoiceDictationAccept.acceptHash(
                for: finalMessage.finalText
            )
        )))
    }

    @Test
    func invalidCandidateBeforeHelloDoesNotResetActiveConnection() async throws {
        let engine = ScriptedVoiceEngine()
        engine.enqueue([
            .partial(
                stableText: "旧连接",
                partialText: "仍有效",
                confidence: 0.9
            ),
        ])
        let listener = NSXPCListener.anonymous()
        let server = VoiceDictationXPCServerTransport(
            anonymousListener: listener,
            core: VoiceDictationServerCore(engine: engine)
        )
        try server.start()
        defer { server.stop() }

        let active = VoiceDictationXPCClientTransport(
            listenerEndpoint: listener.endpoint
        )
        let candidate = VoiceDictationXPCClientTransport(
            listenerEndpoint: listener.endpoint
        )
        defer {
            active.close()
            candidate.close()
        }
        let activeCollector = VoiceMessageCollector()
        active.setGenerationMessageHandler { message, _ in
            activeCollector.append(message)
        }
        try await active.connect(timeout: 3)
        active.send(.hello(VoiceHelloRequest()))
        _ = try activeCollector.wait(
            for: { if case .ready = $0 { true } else { false } },
            timeout: 3
        )

        try await candidate.connect(timeout: 3)
        candidate.send(.start(VoiceDictationStart(
            requestID: "invalid-before-hello",
            compositionID: UUID(),
            appSessionID: "candidate",
            bundleID: "com.example.candidate",
            mode: .direct,
            deadlineMilliseconds: 3_000
        )))

        active.send(.start(VoiceDictationStart(
            requestID: "active-after-invalid-candidate",
            compositionID: UUID(),
            appSessionID: "active",
            bundleID: "com.example.active",
            mode: .direct,
            deadlineMilliseconds: 3_000
        )))
        let delta = try activeCollector.wait(
            for: { if case .delta = $0 { true } else { false } },
            timeout: 3
        )
        guard case .delta(let message) = delta else {
            Issue.record("expected active delta")
            return
        }
        #expect(message.requestID == "active-after-invalid-candidate")
    }

    @Test
    func coreAsyncOutputKeepsTheEpochItWasProducedUnder() throws {
        let engine = ScriptedVoiceEngine()
        let core = VoiceDictationServerCore(engine: engine)
        let firstEpoch = core.resetConnection()
        _ = core.handle(VoiceHelloRequest())
        _ = core.handle(VoiceDictationStart(
            requestID: "old-epoch",
            compositionID: UUID(),
            appSessionID: "epoch-session",
            bundleID: "com.example.epoch",
            mode: .direct,
            deadlineMilliseconds: 3_000
        ))

        let capture = BlockingCoreEpochCapture()
        core.setConnectionScopedEmitHandler {
            outputs, connectionEpoch, outputEpoch in
            capture.capture(
                outputs: outputs,
                connectionEpoch: connectionEpoch,
                outputEpoch: outputEpoch
            )
        }
        DispatchQueue.global().async {
            engine.trigger(.failed(.polishFailed, retryable: false))
        }
        #expect(capture.waitUntilEntered())

        let secondEpoch = core.resetConnection()
        #expect(secondEpoch != firstEpoch)
        capture.release()
        #expect(capture.waitUntilFinished())
        #expect(capture.epoch == firstEpoch)
        #expect(capture.outputs == [.disconnect])
    }

    @Test
    func oldDisconnectScopeExpiresWhenANewSessionStarts() throws {
        let engine = RetainingVoiceEngine()
        let core = VoiceDictationServerCore(engine: engine)
        _ = core.resetConnection()
        _ = core.handle(VoiceHelloRequest())
        _ = core.handle(makeStart(requestID: "old-disconnect"))

        let capture = BlockingCoreEpochCapture()
        core.setConnectionScopedEmitHandler {
            outputs, connectionEpoch, outputEpoch in
            capture.capture(
                outputs: outputs,
                connectionEpoch: connectionEpoch,
                outputEpoch: outputEpoch
            )
        }
        DispatchQueue.global().async {
            engine.trigger(
                sinkIndex: 0,
                event: .failed(.polishFailed, retryable: false)
            )
        }
        #expect(capture.waitUntilEntered())
        defer { capture.release() }

        let staleConnectionEpoch = try #require(capture.epoch)
        let staleOutputEpoch = try #require(capture.outputEpoch)
        #expect(core.isCurrentOutputScope(
            connectionEpoch: staleConnectionEpoch,
            outputEpoch: staleOutputEpoch
        ))

        _ = core.handle(makeStart(requestID: "replacement-session"))
        #expect(engine.startedRequestIDs.count == 2)
        #expect(!core.isCurrentOutputScope(
            connectionEpoch: staleConnectionEpoch,
            outputEpoch: staleOutputEpoch
        ))
        capture.release()
        #expect(capture.waitUntilFinished())
    }

    @Test
    func frameQueueIsSingleFlightAndPreservesFIFO() {
        let sender = ControlledXPCFrameSender()
        let queue = VoiceDictationXPCFrameQueue(
            sender: sender.send,
            onFailure: sender.fail
        )
        let first = Data([1])
        let second = Data([2])
        let third = Data([3])

        #expect(queue.enqueue(first))
        #expect(queue.enqueue(second))
        #expect(queue.enqueue(third))
        #expect(sender.sentFrames == [first])

        sender.completeNext(accepted: true)
        queue.waitForPendingStateTransitionsForTesting()
        #expect(sender.sentFrames == [first, second])
        sender.completeNext(accepted: true)
        queue.waitForPendingStateTransitionsForTesting()
        #expect(sender.sentFrames == [first, second, third])
        sender.completeNext(accepted: true)
        queue.waitForPendingStateTransitionsForTesting()
        #expect(sender.failureCount == 0)
    }

    @Test
    func frameQueueOverflowAndNegativeAckFailClosedOnce() {
        let overflowSender = ControlledXPCFrameSender()
        let overflowQueue = VoiceDictationXPCFrameQueue(
            maximumFrameCount: 2,
            maximumQueuedBytes: 2,
            sender: overflowSender.send,
            onFailure: overflowSender.fail
        )
        #expect(overflowQueue.enqueue(Data([1])))
        #expect(overflowQueue.enqueue(Data([2])))
        #expect(!overflowQueue.enqueue(Data([3])))
        #expect(!overflowQueue.enqueue(Data([4])))
        overflowQueue.waitForPendingStateTransitionsForTesting()
        #expect(overflowSender.failureCount == 1)
        overflowSender.completeNext(accepted: true)
        overflowQueue.waitForPendingStateTransitionsForTesting()
        #expect(overflowSender.sentFrames == [Data([1])])
        #expect(overflowSender.failureCount == 1)

        let rejectedSender = ControlledXPCFrameSender()
        let rejectedQueue = VoiceDictationXPCFrameQueue(
            sender: rejectedSender.send,
            onFailure: rejectedSender.fail
        )
        #expect(rejectedQueue.enqueue(Data([9])))
        #expect(rejectedQueue.enqueue(Data([10])))
        rejectedSender.completeNext(accepted: false)
        rejectedQueue.waitForPendingStateTransitionsForTesting()
        #expect(rejectedSender.failureCount == 1)
        #expect(rejectedSender.sentFrames == [Data([9])])
        #expect(!rejectedQueue.enqueue(Data([11])))
        rejectedQueue.waitForPendingStateTransitionsForTesting()
        #expect(rejectedSender.failureCount == 1)
    }

    @Test
    func frameQueueOverflowFailureDoesNotSynchronouslyReenterCallerLock() {
        let callerLock = NSLock()
        let failureEntered = DispatchSemaphore(value: 0)
        let failureFinished = DispatchSemaphore(value: 0)
        let enqueueReturned = DispatchSemaphore(value: 0)
        let sender = ControlledXPCFrameSender()
        let queue = VoiceDictationXPCFrameQueue(
            maximumFrameCount: 1,
            maximumQueuedBytes: 1,
            sender: sender.send,
            onFailure: {
                failureEntered.signal()
                callerLock.lock()
                callerLock.unlock()
                failureFinished.signal()
            }
        )

        #expect(queue.enqueue(Data([1])))
        callerLock.lock()
        DispatchQueue.global().async {
            #expect(!queue.enqueue(Data([2])))
            enqueueReturned.signal()
        }

        // 模拟 enqueue 调用方仍持有 Coordinator 锁：异步失败回调可以开始，
        // 但它等待该锁时不能阻止 enqueue 本身返回。
        #expect(failureEntered.wait(timeout: .now() + 3) == .success)
        #expect(enqueueReturned.wait(timeout: .now() + 3) == .success)
        callerLock.unlock()

        #expect(failureFinished.wait(timeout: .now() + 3) == .success)
        #expect(sender.sentFrames == [Data([1])])
    }

    @Test
    func frameQueueInvalidateAndDuplicateReplyCannotReleaseAStaleNextFrame() {
        let invalidatedSender = ControlledXPCFrameSender()
        let invalidatedQueue = VoiceDictationXPCFrameQueue(
            sender: invalidatedSender.send,
            onFailure: invalidatedSender.fail
        )
        #expect(invalidatedQueue.enqueue(Data([1])))
        #expect(invalidatedQueue.enqueue(Data([2])))
        invalidatedQueue.invalidate()
        invalidatedSender.completeNext(accepted: true)
        invalidatedQueue.waitForPendingStateTransitionsForTesting()
        #expect(invalidatedSender.sentFrames == [Data([1])])

        let duplicateSender = ControlledXPCFrameSender()
        let duplicateQueue = VoiceDictationXPCFrameQueue(
            sender: duplicateSender.send,
            onFailure: duplicateSender.fail
        )
        #expect(duplicateQueue.enqueue(Data([3])))
        #expect(duplicateQueue.enqueue(Data([4])))
        duplicateSender.completeNext(accepted: true)
        duplicateQueue.waitForPendingStateTransitionsForTesting()
        #expect(duplicateSender.sentFrames == [Data([3]), Data([4])])
        duplicateSender.replayLastCompletion(accepted: false)
        duplicateQueue.waitForPendingStateTransitionsForTesting()
        #expect(duplicateSender.failureCount == 0)
        duplicateSender.completeNext(accepted: true)
        duplicateQueue.waitForPendingStateTransitionsForTesting()
        #expect(duplicateSender.failureCount == 0)
    }

    @Test
    func callbackBeforePingAuthenticationIsRejected() async throws {
        let listener = NSXPCListener.anonymous()
        let fakeServer = PreAuthenticationCallbackServer()
        listener.delegate = fakeServer
        listener.activate()
        defer { listener.invalidate() }

        let client = VoiceDictationXPCClientTransport(
            listenerEndpoint: listener.endpoint
        )
        defer { client.close() }
        let recorder = LockedVoiceMessageRecorder()
        client.setGenerationMessageHandler { message, _ in
            recorder.append(message)
        }
        try await client.connect(timeout: 3)

        #expect(fakeServer.preAuthenticationCallbackWasAccepted == false)
        #expect(recorder.messages.isEmpty)
    }

    @Test
    func pingTimeoutAndWrongPeerUserFailClosed() async throws {
        let silentListener = NSXPCListener.anonymous()
        let silentServer = SilentPingServer()
        silentListener.delegate = silentServer
        silentListener.activate()
        defer { silentListener.invalidate() }
        let timedClient = VoiceDictationXPCClientTransport(
            listenerEndpoint: silentListener.endpoint
        )
        defer { timedClient.close() }
        do {
            try await timedClient.connect(timeout: 0.05)
            Issue.record("silent XPC ping unexpectedly connected")
        } catch let error as VoiceDictationTransportError {
            #expect(error == .connectTimeout)
        } catch {
            Issue.record("unexpected ping timeout error: \(error)")
        }

        let uidListener = NSXPCListener.anonymous()
        let uidServer = SilentPingServer(shouldReply: true)
        uidListener.delegate = uidServer
        uidListener.activate()
        defer { uidListener.invalidate() }
        let wrongUID = geteuid() == uid_t.max ? geteuid() - 1 : geteuid() + 1
        let wrongUIDClient = VoiceDictationXPCClientTransport(
            listenerEndpoint: uidListener.endpoint,
            expectedEffectiveUserIdentifier: wrongUID
        )
        defer { wrongUIDClient.close() }
        do {
            try await wrongUIDClient.connect(timeout: 3)
            Issue.record("wrong-EUID XPC peer unexpectedly connected")
        } catch let error as VoiceDictationTransportError {
            #expect(error == .peerUserMismatch)
        } catch {
            Issue.record("unexpected EUID error: \(error)")
        }
    }

    @Test
    func reusedRequestIDCannotAdmitAnOldEngineCallback() {
        let engine = RetainingVoiceEngine()
        let core = VoiceDictationServerCore(engine: engine)
        let recorder = CoreOutputRecorder()
        core.setConnectionScopedEmitHandler { outputs, epoch, _ in
            recorder.append(outputs: outputs, epoch: epoch)
        }
        let reusedRequestID = "reused-request"

        _ = core.resetConnection()
        _ = core.handle(VoiceHelloRequest())
        _ = core.handle(makeStart(requestID: reusedRequestID))
        #expect(engine.sinkCount == 1)

        _ = core.resetConnection()
        _ = core.handle(VoiceHelloRequest())
        _ = core.handle(makeStart(requestID: reusedRequestID))
        #expect(engine.sinkCount == 2)
        #expect(engine.startedRequestIDs.count == 2)
        #expect(engine.startedRequestIDs[0] != engine.startedRequestIDs[1])
        #expect(engine.cancelledRequestIDs == [engine.startedRequestIDs[0]])
        recorder.removeAll()

        engine.trigger(
            sinkIndex: 0,
            event: .partial(
                stableText: "旧",
                partialText: "结果",
                confidence: 0.5
            )
        )
        engine.trigger(
            sinkIndex: 1,
            event: .partial(
                stableText: "新",
                partialText: "结果",
                confidence: 0.9
            )
        )

        let deltas = recorder.outputs.compactMap { output -> VoiceDictationDelta? in
            guard case .delta(let delta) = output else {
                return nil
            }
            return delta
        }
        #expect(deltas.count == 1)
        #expect(deltas.first?.stableText == "新")
    }

    @Test
    func closedOldEngineIsCancelledBeforeAReplacementStarts() {
        let engine = BlockingFirstCancelVoiceEngine()
        let core = VoiceDictationServerCore(engine: engine)
        _ = core.handle(VoiceHelloRequest())
        _ = core.handle(makeStart(requestID: "old-wire-id"))
        defer { engine.releaseFirstCancel() }

        DispatchQueue.global().async {
            engine.triggerOversizePartial()
        }
        #expect(engine.waitUntilFirstCancelBegins())

        let replacementFinished = DispatchSemaphore(value: 0)
        let replacement = makeStart(requestID: "new-wire-id")
        DispatchQueue.global().async {
            _ = core.handle(replacement)
            replacementFinished.signal()
        }
        #expect(engine.waitUntilSecondCancelCompletes())
        #expect(replacementFinished.wait(timeout: .now() + 1) == .success)
        #expect(engine.startedRequestIDs.count == 2)
        #expect(engine.startedRequestIDs[0] != engine.startedRequestIDs[1])
        #expect(engine.overloadCount == 0)
    }

    @Test
    func concurrentEngineEventsDrainInSequenceOrder() {
        let engine = RetainingVoiceEngine()
        let core = VoiceDictationServerCore(engine: engine)
        _ = core.resetConnection()
        _ = core.handle(VoiceHelloRequest())
        _ = core.handle(makeStart(requestID: "ordered-events"))

        let capture = BlockingOrderedCoreOutputCapture()
        core.setConnectionScopedEmitHandler { outputs, _, _ in
            capture.capture(outputs)
        }
        DispatchQueue.global().async {
            engine.trigger(
                sinkIndex: 0,
                event: .partial(
                    stableText: "一",
                    partialText: "",
                    confidence: 0.9
                )
            )
        }
        #expect(capture.waitUntilFirstHandlerEntered())

        let secondReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            engine.trigger(
                sinkIndex: 0,
                event: .partial(
                    stableText: "二",
                    partialText: "",
                    confidence: 0.9
                )
            )
            secondReturned.signal()
        }
        #expect(secondReturned.wait(timeout: .now() + 3) == .success)
        capture.releaseFirstHandler()
        #expect(capture.waitForTwoBatches())

        #expect(capture.deltaSequences == [1, 2])
    }

    private func makeStart(requestID: String) -> VoiceDictationStart {
        VoiceDictationStart(
            requestID: requestID,
            compositionID: UUID(),
            appSessionID: "reused-session",
            bundleID: "com.example.reused",
            mode: .direct,
            deadlineMilliseconds: 3_000
        )
    }
}

private final class BlockingCoreEpochCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let allowedToFinish = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var capturedEpoch: UInt64?
    private var capturedOutputEpoch: UInt64?
    private var capturedOutputs: [VoiceDictationServerCore.Output] = []

    var epoch: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return capturedEpoch
    }

    var outputs: [VoiceDictationServerCore.Output] {
        lock.lock()
        defer { lock.unlock() }
        return capturedOutputs
    }

    var outputEpoch: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return capturedOutputEpoch
    }

    func capture(
        outputs: [VoiceDictationServerCore.Output],
        connectionEpoch: UInt64,
        outputEpoch: UInt64
    ) {
        lock.lock()
        capturedEpoch = connectionEpoch
        capturedOutputEpoch = outputEpoch
        capturedOutputs = outputs
        lock.unlock()
        entered.signal()
        _ = allowedToFinish.wait(timeout: .now() + 3)
        finished.signal()
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 3) == .success
    }

    func release() {
        allowedToFinish.signal()
    }

    func waitUntilFinished() -> Bool {
        finished.wait(timeout: .now() + 3) == .success
    }
}

private final class ControlledXPCFrameSender: @unchecked Sendable {
    private let condition = NSCondition()
    private var frames: [Data] = []
    private var completions: [(Bool) -> Void] = []
    private var mostRecentlyCompleted: ((Bool) -> Void)?
    private var failures = 0

    var sentFrames: [Data] {
        condition.lock()
        defer { condition.unlock() }
        return frames
    }

    var failureCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return failures
    }

    func send(_ frame: Data, completion: @escaping (Bool) -> Void) {
        condition.lock()
        frames.append(frame)
        completions.append(completion)
        condition.broadcast()
        condition.unlock()
    }

    func completeNext(accepted: Bool) {
        condition.lock()
        guard !completions.isEmpty else {
            condition.unlock()
            Issue.record("expected an in-flight XPC frame")
            return
        }
        let completion = completions.removeFirst()
        mostRecentlyCompleted = completion
        condition.unlock()
        completion(accepted)
    }

    func replayLastCompletion(accepted: Bool) {
        condition.lock()
        let completion = mostRecentlyCompleted
        condition.unlock()
        guard let completion else {
            Issue.record("expected a completed XPC frame")
            return
        }
        completion(accepted)
    }

    func fail() {
        condition.lock()
        failures += 1
        condition.broadcast()
        condition.unlock()
    }

}

private final class LockedVoiceMessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [VoiceServerMessage] = []

    var messages: [VoiceServerMessage] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ message: VoiceServerMessage) {
        lock.lock()
        recorded.append(message)
        lock.unlock()
    }
}

private final class PreAuthenticationCallbackServer:
    NSObject,
    NSXPCListenerDelegate,
    VoiceDictationXPCServiceProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var accepted: Bool?

    var preAuthenticationCallbackWasAccepted: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(
            with: VoiceDictationXPCServiceProtocol.self
        )
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(
            with: VoiceDictationXPCClientProtocol.self
        )
        connection.activate()
        return true
    }

    func ping(withReply reply: @escaping () -> Void) {
        guard let connection = NSXPCConnection.current(),
              let payload = try? VoiceDictationWire.encodeXPCPayload(
                  VoiceServerMessage.ready(VoiceReadyResponse(
                      capabilities: ["local_asr", "streaming"],
                      networkPolicy: .offline,
                      asrEngineID: "pre-auth-fake"
                  ))
              ),
              let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                  reply()
              }) as? VoiceDictationXPCClientProtocol
        else {
            reply()
            return
        }
        proxy.receiveFrame(payload) { [weak self] accepted in
            self?.lock.lock()
            self?.accepted = accepted
            self?.lock.unlock()
            reply()
        }
    }

    func sendFrame(
        _ frame: Data,
        withReply reply: @escaping (Bool) -> Void
    ) {
        reply(false)
    }
}

private final class SilentPingServer:
    NSObject,
    NSXPCListenerDelegate,
    VoiceDictationXPCServiceProtocol,
    @unchecked Sendable
{
    private let shouldReply: Bool

    init(shouldReply: Bool = false) {
        self.shouldReply = shouldReply
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(
            with: VoiceDictationXPCServiceProtocol.self
        )
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(
            with: VoiceDictationXPCClientProtocol.self
        )
        connection.activate()
        return true
    }

    func ping(withReply reply: @escaping () -> Void) {
        if shouldReply {
            reply()
        }
    }

    func sendFrame(
        _ frame: Data,
        withReply reply: @escaping (Bool) -> Void
    ) {
        reply(false)
    }
}

private final class RetainingVoiceEngine:
    VoiceDictationEngine,
    @unchecked Sendable
{
    let descriptor = verifiedTestVoiceEngineDescriptor(
        adapterID: "retaining-test-engine"
    )
    private let lock = NSLock()
    private var sinks: [@Sendable (VoiceDictationEngineEvent) -> Void] = []
    private var starts: [String] = []
    private var cancellations: [String] = []

    var sinkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sinks.count
    }

    var startedRequestIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var cancelledRequestIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {
        lock.lock()
        starts.append(request.requestID)
        sinks.append(events)
        lock.unlock()
    }

    func stop(requestID: String) {}
    func cancel(requestID: String) {
        lock.lock()
        cancellations.append(requestID)
        lock.unlock()
    }

    func trigger(sinkIndex: Int, event: VoiceDictationEngineEvent) {
        lock.lock()
        let sink = sinks.indices.contains(sinkIndex) ? sinks[sinkIndex] : nil
        lock.unlock()
        sink?(event)
    }
}

private final class BlockingFirstCancelVoiceEngine:
    VoiceDictationEngine,
    @unchecked Sendable
{
    let descriptor = verifiedTestVoiceEngineDescriptor(
        adapterID: "blocking-cancel-test-engine"
    )
    private let lock = NSLock()
    private let firstCancelBegan = DispatchSemaphore(value: 0)
    private let allowFirstCancelToFinish = DispatchSemaphore(value: 0)
    private let secondCancelFinished = DispatchSemaphore(value: 0)
    private var activeRequestID: String?
    private var sink: (@Sendable (VoiceDictationEngineEvent) -> Void)?
    private var starts: [String] = []
    private var cancelCount = 0
    private var overloads = 0

    var startedRequestIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var overloadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return overloads
    }

    func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {
        lock.lock()
        starts.append(request.requestID)
        if activeRequestID != nil {
            overloads += 1
        } else {
            activeRequestID = request.requestID
            sink = events
        }
        lock.unlock()
    }

    func stop(requestID: String) {}

    func cancel(requestID: String) {
        lock.lock()
        cancelCount += 1
        let invocation = cancelCount
        if invocation > 1, activeRequestID == requestID {
            activeRequestID = nil
            sink = nil
        }
        lock.unlock()

        if invocation == 1 {
            firstCancelBegan.signal()
            _ = allowFirstCancelToFinish.wait(timeout: .now() + 2)
            lock.lock()
            if activeRequestID == requestID {
                activeRequestID = nil
                sink = nil
            }
            lock.unlock()
        } else {
            secondCancelFinished.signal()
        }
    }

    func triggerOversizePartial() {
        lock.lock()
        let sink = self.sink
        lock.unlock()
        sink?(.partial(
            stableText: String(repeating: "字", count: 201),
            partialText: "",
            confidence: 0.8
        ))
    }

    func waitUntilFirstCancelBegins() -> Bool {
        firstCancelBegan.wait(timeout: .now() + 1) == .success
    }

    func waitUntilSecondCancelCompletes() -> Bool {
        secondCancelFinished.wait(timeout: .now() + 1) == .success
    }

    func releaseFirstCancel() {
        allowFirstCancelToFinish.signal()
    }
}

private final class CoreOutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [VoiceDictationServerCore.Output] = []

    var outputs: [VoiceDictationServerCore.Output] {
        lock.lock()
        defer { lock.unlock() }
        return batches
    }

    func append(
        outputs: [VoiceDictationServerCore.Output],
        epoch: UInt64
    ) {
        lock.lock()
        batches.append(contentsOf: outputs)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        batches.removeAll()
        lock.unlock()
    }
}

private final class BlockingOrderedCoreOutputCapture: @unchecked Sendable {
    private let condition = NSCondition()
    private let firstEntered = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private var batches: [[VoiceDictationServerCore.Output]] = []

    var deltaSequences: [Int] {
        condition.lock()
        defer { condition.unlock() }
        return batches.flatMap { outputs in
            outputs.compactMap { output -> Int? in
                guard case .delta(let delta) = output else {
                    return nil
                }
                return delta.sequence
            }
        }
    }

    func capture(_ outputs: [VoiceDictationServerCore.Output]) {
        condition.lock()
        let isFirst = batches.isEmpty
        if isFirst {
            condition.unlock()
            firstEntered.signal()
            _ = releaseFirst.wait(timeout: .now() + 3)
            condition.lock()
        }
        batches.append(outputs)
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilFirstHandlerEntered() -> Bool {
        firstEntered.wait(timeout: .now() + 3) == .success
    }

    func releaseFirstHandler() {
        releaseFirst.signal()
    }

    func waitForTwoBatches() -> Bool {
        let deadline = Date().addingTimeInterval(3)
        condition.lock()
        defer { condition.unlock() }
        while batches.count < 2 {
            guard condition.wait(until: deadline) else {
                return false
            }
        }
        return true
    }
}
