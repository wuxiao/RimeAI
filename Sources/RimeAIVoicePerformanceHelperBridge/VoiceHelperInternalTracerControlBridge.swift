import Darwin
import Foundation
import RimeAIInputCore
import RimeAIVoiceHelperEngine
import RimeAIVoicePerformanceControlCore
import Security

@_spi(VoicePerformanceTracer)
public enum VoiceHelperPerformanceTracerBridgeError:
    Error,
    Equatable,
    Sendable
{
    case rejected
}

@_spi(VoicePerformanceTracer)
public enum VoiceHelperPerformanceTracerBridgeFactory {
    public static func make(
        layout: RimeAIProductDataLayout,
        measurementPolicy: VoicePerformanceMeasurementPolicy
    ) throws -> VoiceHelperPerformanceTracerBridge {
        try make(
            bootstrap: VoiceHelperPerformanceTracerBootstrap(layout: layout),
            measurementPolicy: measurementPolicy,
            bundleURL: Bundle.main.bundleURL,
            peerNonceSource: securePeerNonce,
            processStartTokenSource: liveProcessStartToken
        )
    }

    static func make(
        bootstrap: VoiceHelperPerformanceTracerBootstrap,
        measurementPolicy: VoicePerformanceMeasurementPolicy,
        bundleURL: URL,
        peerNonceSource: @Sendable () throws -> PerformanceControlNonce,
        processStartTokenSource: @Sendable () throws -> UInt64
    ) throws -> VoiceHelperPerformanceTracerBridge {
        do {
            guard measurementPolicy.qualification == .tracer,
                  !measurementPolicy.authenticatedProductionDriver
            else {
                throw VoiceHelperPerformanceTracerBridgeError.rejected
            }
            let controlSessionNonce = try PerformanceControlNonce(
                measurementPolicy.controlSessionNonce
            )
            let measurementPolicySHA256 = try PerformanceControlSHA256(
                measurementPolicy.canonicalSHA256
            )
            let processStartToken = try processStartTokenSource()
            guard processStartToken > 0 else {
                throw VoiceHelperPerformanceTracerBridgeError.rejected
            }
            let prepared = try bootstrap.prepareEngine(
                measurementPolicy: measurementPolicy,
                bundleURL: bundleURL
            )
            let peerNonce = try peerNonceSource()
            return VoiceHelperPerformanceTracerBridge(
                controlBridge: VoiceHelperInternalTracerControlBridge(
                    preparedEngine: prepared.engine,
                    helperProcessStartToken: processStartToken,
                    controlSessionNonce: controlSessionNonce,
                    expectedEngine: measurementPolicy.expectedEngine
                ),
                controlSessionNonce: controlSessionNonce,
                peerNonce: peerNonce,
                measurementPolicySHA256: measurementPolicySHA256,
                releasePolicySHA256:
                    prepared.verifiedReleasePolicySHA256,
                coldTrials: measurementPolicy.coldTrials
            )
        } catch {
            throw VoiceHelperPerformanceTracerBridgeError.rejected
        }
    }

    private static func securePeerNonce()
        throws -> PerformanceControlNonce
    {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess
        else {
            throw VoiceHelperPerformanceTracerBridgeError.rejected
        }
        return try PerformanceControlNonce(bytes.map {
            String(format: "%02x", $0)
        }.joined())
    }

    private static func liveProcessStartToken() throws -> UInt64 {
        var usage = rusage_info_v6()
        var status: Int32 = -1
        repeat {
            status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(
                    to: rusage_info_t?.self,
                    capacity: 1
                ) {
                    proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
                }
            }
        } while status != 0 && errno == EINTR
        guard status == 0,
              usage.ri_proc_start_abstime > 0,
              usage.ri_proc_exit_abstime == 0
        else {
            throw VoiceHelperPerformanceTracerBridgeError.rejected
        }
        return usage.ri_proc_start_abstime
    }
}

/// SPI-only typed control surface for a single attested helper generation.
/// It owns the selected engine for the rest of the cold-load trial and never
/// upgrades tracer traffic to authenticated production authority.
@_spi(VoicePerformanceTracer)
public final class VoiceHelperPerformanceTracerBridge: @unchecked Sendable {
    private enum State {
        case awaitingChallenge
        case awaitingLoadEngine(trial: UInt64)
        case receivingLoadEngine(trial: UInt64)
        case awaitingAcknowledgement(trial: UInt64)
        case loading(trial: UInt64)
        case loaded
        case terminal
    }

    private let lock = NSLock()
    private let controlBridge: VoiceHelperInternalTracerControlBridge
    private let controlSessionNonce: PerformanceControlNonce
    private let peerNonce: PerformanceControlNonce
    private let measurementPolicySHA256: PerformanceControlSHA256
    private let releasePolicySHA256: PerformanceControlSHA256
    private let coldTrials: UInt64
    private var state = State.awaitingChallenge
    private var reservedNonces = Set<PerformanceControlNonce>()
    private var loadedEngine: (any VoiceDictationEngine)?

    public let authenticatedProductionDriver = false

    fileprivate init(
        controlBridge: VoiceHelperInternalTracerControlBridge,
        controlSessionNonce: PerformanceControlNonce,
        peerNonce: PerformanceControlNonce,
        measurementPolicySHA256: PerformanceControlSHA256,
        releasePolicySHA256: PerformanceControlSHA256,
        coldTrials: UInt64
    ) {
        self.controlBridge = controlBridge
        self.controlSessionNonce = controlSessionNonce
        self.peerNonce = peerNonce
        self.measurementPolicySHA256 = measurementPolicySHA256
        self.releasePolicySHA256 = releasePolicySHA256
        self.coldTrials = coldTrials
    }

    deinit {
        controlBridge.cancel()
    }

    public func receive(
        _ frame: PerformanceControlWireFrame
    ) throws -> PerformanceControlWireFrame {
        lock.lock()
        switch state {
        case .awaitingChallenge:
            return try receiveChallengeLocked(frame)
        case .awaitingLoadEngine(let trial):
            return try receiveLoadEngineLocked(frame, trial: trial)
        case .awaitingAcknowledgement(let trial):
            return try receiveAcknowledgementLocked(
                frame,
                trial: trial
            )
        case .receivingLoadEngine, .loading, .loaded, .terminal:
            throw rejectLocked()
        }
    }

    public func cancel() {
        terminate(controlBridge.cancel)
    }

    public func disconnect() {
        terminate(controlBridge.disconnect)
    }

    public func timeout() {
        terminate(controlBridge.timeout)
    }

    private func uniquelyMatchingTrial(
        sessionID: PerformanceControlNonce,
        planNonce: PerformanceControlNonce
    ) -> UInt64? {
        var match: UInt64?
        for trial in UInt64(1) ... coldTrials {
            guard let binding = try? PerformanceControlSessionBinding
                .derive(
                    controlSessionNonce: controlSessionNonce,
                    trial: trial
                ),
                  binding.sessionID == sessionID,
                  binding.planNonce == planNonce
            else {
                continue
            }
            guard match == nil else { return nil }
            match = trial
        }
        return match
    }

    /// Called only while `lock` is held.
    private func receiveChallengeLocked(
        _ frame: PerformanceControlWireFrame
    ) throws -> PerformanceControlWireFrame {
        guard case let .challenge(
            peerRole,
            sessionID,
            planNonce,
            collectorNonce
        ) = frame,
              peerRole == .helper,
              let trial = uniquelyMatchingTrial(
                  sessionID: sessionID,
                  planNonce: planNonce
              ),
              collectorNonce != sessionID,
              collectorNonce != planNonce,
              peerNonce != sessionID,
              peerNonce != planNonce,
              peerNonce != collectorNonce
        else {
            throw rejectLocked()
        }
        reservedNonces = [
            sessionID,
            planNonce,
            collectorNonce,
            peerNonce,
        ]
        state = .awaitingLoadEngine(trial: trial)
        lock.unlock()
        return .helperHello(
            sessionID: sessionID,
            planNonce: planNonce,
            collectorNonce: collectorNonce,
            peerNonce: peerNonce,
            measurementPolicySHA256: measurementPolicySHA256,
            releasePolicySHA256: releasePolicySHA256
        )
    }

    /// Called only while `lock` is held. Loader construction remains behind
    /// the later acknowledgement boundary.
    private func receiveLoadEngineLocked(
        _ frame: PerformanceControlWireFrame,
        trial: UInt64
    ) throws -> PerformanceControlWireFrame {
        guard case let .loadEngine(
            sequence,
            _,
            actualTrial,
            loadTicket
        ) = frame,
              sequence == 1,
              actualTrial == trial,
              reservedNonces.insert(loadTicket).inserted
        else {
            throw rejectLocked()
        }
        state = .receivingLoadEngine(trial: trial)
        lock.unlock()

        let response: PerformanceControlWireFrame
        do {
            response = try controlBridge.receiveLoadEngine(frame)
        } catch {
            throw failAfterUnlockedOperation()
        }

        lock.lock()
        guard case .receivingLoadEngine(let activeTrial) = state,
              activeTrial == trial
        else {
            throw rejectLocked()
        }
        state = .awaitingAcknowledgement(trial: trial)
        lock.unlock()
        return response
    }

    /// Called only while `lock` is held. The selected engine is retained by
    /// this façade only after the typed acknowledgement completes.
    private func receiveAcknowledgementLocked(
        _ frame: PerformanceControlWireFrame,
        trial: UInt64
    ) throws -> PerformanceControlWireFrame {
        guard case let .loadStartedAck(
            sequence,
            _,
            replyTo,
            actualTrial,
            _
        ) = frame,
              sequence == 2,
              replyTo == 1,
              actualTrial == trial
        else {
            throw rejectLocked()
        }
        state = .loading(trial: trial)
        lock.unlock()

        let result: VoiceHelperInternalTracerLoadResult
        do {
            result = try controlBridge
                .receiveLoadStartedAcknowledgement(frame)
        } catch {
            throw failAfterUnlockedOperation()
        }

        lock.lock()
        guard case .loading(let activeTrial) = state,
              activeTrial == trial
        else {
            throw rejectLocked()
        }
        loadedEngine = result.engine
        state = .loaded
        lock.unlock()
        return result.frame
    }

    private func terminate(_ action: () -> Void) {
        lock.lock()
        let releasedEngine = loadedEngine
        state = .terminal
        loadedEngine = nil
        lock.unlock()
        action()
        withExtendedLifetime(releasedEngine) {}
    }

    private func failAfterUnlockedOperation()
        -> VoiceHelperPerformanceTracerBridgeError
    {
        lock.lock()
        let releasedEngine = loadedEngine
        state = .terminal
        loadedEngine = nil
        lock.unlock()
        controlBridge.cancel()
        withExtendedLifetime(releasedEngine) {}
        return .rejected
    }

    private func rejectLocked()
        -> VoiceHelperPerformanceTracerBridgeError
    {
        let releasedEngine = loadedEngine
        state = .terminal
        loadedEngine = nil
        lock.unlock()
        controlBridge.cancel()
        withExtendedLifetime(releasedEngine) {}
        return .rejected
    }
}

enum VoiceHelperInternalTracerControlBridgeError:
    Error,
    Equatable,
    Sendable
{
    case invalidFrame
    case invalidState
    case bindingMismatch
    case engineLoadFailed
    case invalidProductDescriptor
}

struct VoiceHelperInternalTracerLoadResult: Sendable {
    let engine: any VoiceDictationEngine
    let frame: PerformanceControlWireFrame
    let authenticatedProductionDriver = false
}

/// Consumes only typed frames from an already-authenticated internal tracer
/// channel. It cannot confer production-driver authority or release evidence.
final class VoiceHelperInternalTracerControlBridge: @unchecked Sendable {
    private struct LoadBinding: Equatable, Sendable {
        let sessionID: PerformanceControlNonce
        let trial: UInt64
        let loadTicket: PerformanceControlNonce
    }

    private enum State {
        case awaitingLoadEngine
        case awaitingAcknowledgement(LoadBinding)
        case loading(LoadBinding)
        case loaded
        case terminal
    }

    private let lock = NSLock()
    private let preparedEngine: VoiceHelperInternalTracerPreparedEngine
    private let helperProcessStartToken: UInt64
    private let controlSessionNonce: PerformanceControlNonce
    private let expectedEngine: ExpectedPerformanceControlEngine
    private var state = State.awaitingLoadEngine

    let authenticatedProductionDriver = false

    init(
        preparedEngine: VoiceHelperInternalTracerPreparedEngine,
        helperProcessStartToken: UInt64,
        controlSessionNonce: PerformanceControlNonce,
        expectedEngine: ExpectedPerformanceControlEngine
    ) {
        self.preparedEngine = preparedEngine
        self.helperProcessStartToken = helperProcessStartToken
        self.controlSessionNonce = controlSessionNonce
        self.expectedEngine = expectedEngine
    }

    func receiveLoadEngine(
        _ frame: PerformanceControlWireFrame
    ) throws -> PerformanceControlWireFrame {
        lock.lock()
        guard case .awaitingLoadEngine = state else {
            throw rejectLocked(.invalidState)
        }
        guard case let .loadEngine(
            sequence,
            sessionID,
            trial,
            loadTicket
        ) = frame,
              sequence == 1,
              PerformanceControlSessionBinding.supportedTrials
                .contains(trial)
        else {
            throw rejectLocked(.invalidFrame)
        }
        guard let expectedBinding = try? PerformanceControlSessionBinding
            .derive(
                controlSessionNonce: controlSessionNonce,
                trial: trial
            ),
              sessionID == expectedBinding.sessionID
        else {
            throw rejectLocked(.bindingMismatch)
        }

        do {
            try preparedEngine.arm(
                sessionID: sessionID.rawValue,
                generation: helperProcessStartToken,
                ticket: loadTicket.rawValue
            )
        } catch {
            throw rejectLocked(.engineLoadFailed)
        }
        let binding = LoadBinding(
            sessionID: sessionID,
            trial: trial,
            loadTicket: loadTicket
        )
        state = .awaitingAcknowledgement(binding)
        lock.unlock()

        return .loadStarted(
            sequence: 1,
            sessionID: sessionID,
            replyTo: 1,
            trial: trial,
            loadTicket: loadTicket
        )
    }

    func receiveLoadStartedAcknowledgement(
        _ frame: PerformanceControlWireFrame
    ) throws -> VoiceHelperInternalTracerLoadResult {
        lock.lock()
        guard case let .awaitingAcknowledgement(expected) = state else {
            throw rejectLocked(.invalidState)
        }
        guard case let .loadStartedAck(
            sequence,
            sessionID,
            replyTo,
            trial,
            loadTicket
        ) = frame,
              sequence == 2,
              replyTo == 1,
              trial > 0
        else {
            throw rejectLocked(.invalidFrame)
        }
        let actual = LoadBinding(
            sessionID: sessionID,
            trial: trial,
            loadTicket: loadTicket
        )
        guard actual == expected else {
            throw rejectLocked(.bindingMismatch)
        }
        state = .loading(expected)
        lock.unlock()

        let engine: any VoiceDictationEngine
        do {
            engine = try preparedEngine
                .completeBeginBoundaryAcknowledgement(
                    sessionID: sessionID.rawValue,
                    generation: helperProcessStartToken,
                    ticket: loadTicket.rawValue
                )
        } catch {
            terminate()
            throw VoiceHelperInternalTracerControlBridgeError.engineLoadFailed
        }

        let summary: PerformanceControlEngineSummary
        do {
            summary = try Self.makeProductSummary(engine.descriptor)
            guard expectedEngine.matches(summary) else {
                throw VoiceHelperInternalTracerControlBridgeError
                    .invalidProductDescriptor
            }
        } catch {
            terminate()
            throw VoiceHelperInternalTracerControlBridgeError
                .invalidProductDescriptor
        }

        lock.lock()
        guard case let .loading(active) = state, active == expected else {
            throw rejectLocked(.invalidState)
        }
        state = .loaded
        lock.unlock()

        return VoiceHelperInternalTracerLoadResult(
            engine: engine,
            frame: .loadReady(
                sequence: 2,
                sessionID: sessionID,
                replyTo: 2,
                trial: trial,
                loadTicket: loadTicket,
                engine: summary
            )
        )
    }

    func cancel() {
        terminate()
    }

    func disconnect() {
        markTerminal()
        preparedEngine.disconnect()
    }

    func timeout() {
        markTerminal()
        preparedEngine.timeout()
    }

    private func terminate() {
        markTerminal()
        preparedEngine.cancel()
    }

    private func markTerminal() {
        lock.lock()
        state = .terminal
        lock.unlock()
    }

    /// Called only while `lock` is held. Returning the error keeps guard
    /// sites small while preserving unlock-before-loader-termination order.
    private func rejectLocked(
        _ error: VoiceHelperInternalTracerControlBridgeError
    ) -> VoiceHelperInternalTracerControlBridgeError {
        state = .terminal
        lock.unlock()
        preparedEngine.cancel()
        return error
    }

    private static func makeProductSummary(
        _ descriptor: VoiceEngineDescriptor
    ) throws -> PerformanceControlEngineSummary {
        let expectedCapabilities = [
            "hotword_snapshot", "local_asr", "streaming",
        ]
        guard descriptor.isStructurallyValid,
              descriptor.hasIntegrityVerifiedProductArtifact,
              descriptor.assetManagement == .productManaged,
              descriptor.qualification
                == .integrityVerifiedProductArtifact,
              descriptor.networkPolicy == .offline,
              descriptor.capabilities == [
                  .hotwordSnapshot, .localASR, .streaming,
              ],
              descriptor.advertisedProtocolCapabilities
                == expectedCapabilities,
              descriptor.maximumAlternatives == 1,
              let artifactID = descriptor.artifactID,
              let artifactSHA256 = descriptor.artifactSHA256,
              let artifactGeneration = descriptor.artifactGeneration,
              (1 ... 128).contains(
                  descriptor.advertisedMaximumHotwords
              )
        else {
            throw VoiceHelperInternalTracerControlBridgeError
                .invalidProductDescriptor
        }

        return try PerformanceControlEngineSummary(
            adapterID: ControlledPerformanceID(descriptor.adapterID),
            engineID: descriptor.protocolEngineID,
            artifactID: ControlledPerformanceID(artifactID.rawValue),
            artifactContentSHA256: PerformanceControlSHA256(
                artifactSHA256
            ),
            artifactGeneration: PerformanceControlArtifactGeneration(
                artifactGeneration.uuidString.lowercased()
            ),
            capabilities: try expectedCapabilities.map(
                ControlledPerformanceID.init
            ),
            networkPolicy: .offline,
            maximumHotwords: UInt64(
                descriptor.advertisedMaximumHotwords
            )
        )
    }
}
