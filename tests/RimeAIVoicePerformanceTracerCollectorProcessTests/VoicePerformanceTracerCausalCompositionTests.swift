import Foundation
import RimeAIVoicePerformanceControlCore
import Testing

@testable import RimeAIVoicePerformanceCollector
@testable import RimeAIVoicePerformanceTracerCollectorProcess
@testable import RimeAIVoicePerformanceTracerProcessDarwin

@Suite("Voice performance tracer causal composition")
struct VoicePerformanceTracerCausalCompositionTests {
    @Test(
        "one shared clock orders suspended children, cold load, exits, and evidence publication"
    )
    func sharedClockOwnsThePublishedColdLoadEvidence() throws {
        let fixture = try CausalThreeProcessFixture()

        let result = try fixture.run()

        #expect(result.trials.count == 1)
        #expect(
            result.trials[0].coldLoadDurationNanoseconds
                == fixture.measuredColdLoadDuration
        )
        #expect(fixture.hasRequiredCausalOrder)
        #expect(fixture.publishedResult == result)
    }

    @Test("a replayed ready boundary cannot finish or publish evidence")
    func replayedReadyBoundaryIsRejected() throws {
        let fixture = try CausalThreeProcessFixture(replayReady: true)

        #expect(
            throws: VoicePerformanceTracerCollectorProcessError
                .collectionFailed
        ) {
            try fixture.runCommand()
        }

        #expect(fixture.publishedResult == nil)
        #expect(fixture.clock.contains(.helperColdLoadEnd))
        #expect(!fixture.clock.contains(.collectorColdLoadEnd))
        #expect(!fixture.clock.contains(.evidencePublished))
    }
}

private final class CausalThreeProcessFixture {
    let clock = CausalVirtualClock()
    let policy: CausalPolicyFixture
    let runtime: CausalCollectorProcessRuntime

    init(replayReady: Bool = false) throws {
        policy = try CausalPolicyFixture()
        let processes = CausalProcessTable(clock: clock)
        let spawnSystem = CausalSuspendedSpawnSystem(
            clock: clock,
            processes: processes
        )
        let collectorSupervisor = VoicePerformanceCollectorDriverSupervisor(
            system: CausalProcessGroupSystem(
                currentProcessID: 700,
                processes: processes
            )
        )
        let helperSupervisor = VoicePerformanceDriverHelperSupervisor(
            system: CausalProcessGroupSystem(
                currentProcessID: 701,
                processes: processes
            )
        )
        let spawner = VoicePerformanceSecureChildSpawner(system: spawnSystem)
        let transport = try CausalTracerTransport(
            policy: policy,
            clock: clock,
            processes: processes,
            spawner: spawner,
            helperSupervisor: helperSupervisor,
            replayReady: replayReady
        )
        runtime = CausalCollectorProcessRuntime(
            policy: policy,
            clock: clock,
            processes: processes,
            spawner: spawner,
            collectorSupervisor: collectorSupervisor,
            helperSupervisor: helperSupervisor,
            transport: transport
        )
    }

    var publishedResult: VoicePerformanceTracerResult? {
        guard let data = runtime.publishedData else { return nil }
        return try? VoicePerformanceTracerResult.decodeCanonical(data)
    }

    var measuredColdLoadDuration: UInt64 {
        guard
            let begin = clock.timestamp(of: .collectorColdLoadBegin),
            let end = clock.timestamp(of: .collectorColdLoadEnd),
            end > begin
        else { return 0 }
        return end - begin
    }

    var hasRequiredCausalOrder: Bool {
        clock.containsInOrder([
            .driverSpawnSuspended,
            .driverAttested,
            .driverResumed,
            .driverAccepted,
            .helperSpawnSuspended,
            .helperAttested,
            .helperResumed,
            .helperAccepted,
            .driverChallenge,
            .helperChallenge,
            .driverHello,
            .helperHello,
            .driverArmed,
            .loadEngine,
            .loadStarted,
            .collectorColdLoadBegin,
            .helperColdLoadBegin,
            .helperColdLoadEnd,
            .collectorColdLoadEnd,
            .helperFinished,
            .helperReaped,
            .driverFinished,
            .transportClosed,
            .driverReaped,
            .evidencePublished,
        ])
    }

    func runCommand() throws {
        try VoicePerformanceTracerCollectorProcess(runtime: runtime).run(
            argv: policy.collectorArguments,
            currentExecutablePath: policy.collectorExecutablePath
        )
    }

    func run() throws -> VoicePerformanceTracerResult {
        try runCommand()
        guard let publishedResult else {
            throw CausalFixtureError.missingEvidence
        }
        return publishedResult
    }
}

private enum CausalFixtureError: Error {
    case invalidState
    case missingEvidence
}

private enum CausalEvent: Equatable, Sendable {
    case transportStarted
    case driverSpawnSuspended
    case driverAttested
    case driverResumed
    case driverBound
    case driverAccepted
    case helperSpawnSuspended
    case helperAttested
    case helperResumed
    case helperAccepted
    case driverChallenge
    case helperChallenge
    case driverHello
    case helperHello
    case driverArmed
    case loadEngine
    case loadStarted
    case collectorColdLoadBegin
    case helperColdLoadBegin
    case helperColdLoadEnd
    case collectorColdLoadEnd
    case helperFinished
    case helperReaped
    case driverFinished
    case transportClosed
    case driverReaped
    case evidencePublished
}

private struct CausalTimedEvent: Equatable, Sendable {
    let event: CausalEvent
    let nanoseconds: UInt64
}

private final class CausalVirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock().now
    private var nanoseconds: UInt64 = 1_000
    private var events: [CausalTimedEvent] = []
    private var measurementSamples = 0

    var nowNanoseconds: UInt64 {
        lock.withLock { nanoseconds }
    }

    var now: ContinuousClock.Instant {
        instant(at: nowNanoseconds)
    }

    func instant(at value: UInt64) -> ContinuousClock.Instant {
        base.advanced(by: .nanoseconds(Int64(value)))
    }

    @discardableResult
    func record(
        _ event: CausalEvent,
        advancingBy delta: UInt64 = 1
    ) -> UInt64 {
        lock.withLock {
            nanoseconds += delta
            events.append(.init(event: event, nanoseconds: nanoseconds))
            return nanoseconds
        }
    }

    func sampleColdLoadBoundary() -> UInt64 {
        lock.withLock {
            measurementSamples += 1
            nanoseconds += 1
            let event: CausalEvent = measurementSamples == 1
                ? .collectorColdLoadBegin
                : .collectorColdLoadEnd
            events.append(.init(event: event, nanoseconds: nanoseconds))
            return nanoseconds
        }
    }

    func advanceSilently(by delta: UInt64) {
        lock.withLock { nanoseconds += delta }
    }

    func timestamp(of event: CausalEvent) -> UInt64? {
        lock.withLock {
            events.first(where: { $0.event == event })?.nanoseconds
        }
    }

    func contains(_ event: CausalEvent) -> Bool {
        timestamp(of: event) != nil
    }

    func containsInOrder(_ expected: [CausalEvent]) -> Bool {
        lock.withLock {
            var nextIndex = events.startIndex
            for event in expected {
                guard let index = events[nextIndex...].firstIndex(
                    where: { $0.event == event }
                ) else {
                    return false
                }
                nextIndex = events.index(after: index)
            }
            return true
        }
    }
}

private struct CausalCollectorMonotonicClock:
    VoicePerformanceTracerMonotonicClock
{
    let clock: CausalVirtualClock

    func nowNanoseconds() -> UInt64 {
        clock.sampleColdLoadBoundary()
    }
}

private struct CausalCollectorContinuousClock:
    VoicePerformanceTracerContinuousClock
{
    let clock: CausalVirtualClock
    var now: ContinuousClock.Instant { clock.now }
}

private struct CausalNonceSource: VoicePerformanceTracerNonceSource {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var values: [PerformanceControlNonce]

        init(_ values: [PerformanceControlNonce]) {
            self.values = values
        }
    }

    private let storage: Storage

    init(_ values: [PerformanceControlNonce]) {
        storage = Storage(values)
    }

    func nextNonce() throws -> PerformanceControlNonce {
        try storage.lock.withLock {
            guard !storage.values.isEmpty else {
                throw VoicePerformanceTracerCollectorError.entropyFailure
            }
            return storage.values.removeFirst()
        }
    }
}

private struct CausalPolicyFixture {
    static let deadlineNanoseconds: UInt64 = 100_000_000_000

    let outerPath = "/private/tmp/RimeAIVoicePerformanceTracer.bundle"
    let resultPath = "/private/tmp/rimeai-results/causal-result.json"
    let measurementPolicy: VoicePerformanceMeasurementPolicy
    let driverPolicy: SealedPerformanceControlDriverPolicy

    var collectorExecutablePath: String {
        outerPath + VoicePerformanceTracerBundleLayout.collectorExecutableSuffix
    }

    var collectorArguments: [String] {
        [
            collectorExecutablePath,
            "--tracer-bundle", outerPath,
            "--result", resultPath,
        ]
    }

    init() throws {
        let driverData = try SealedPerformanceControlDriverPolicy
            .tracerCanonicalData()
        driverPolicy = try SealedPerformanceControlDriverPolicy.decodeCanonical(
            driverData,
            expectedControlProtocol: PerformanceControlProtocolContract.identity
        )
        let input = VoicePerformanceMeasurementPolicy.TracerBuildInput(
            coldTrials: 1,
            controlSocketPath: "/private/tmp/rimeai-causal-performance.sock",
            controlSessionNonce: String(repeating: "b", count: 64),
            teamIdentifier: "TEAMID1234",
            collector: .init(
                executablePath: outerPath
                    + VoicePerformanceTracerBundleLayout.collectorExecutableSuffix,
                executableSHA256: String(repeating: "c", count: 64),
                cdHash: String(repeating: "c", count: 40)
            ),
            driver: .init(
                executablePath: outerPath
                    + VoicePerformanceTracerBundleLayout.driverExecutableSuffix,
                executableSHA256: String(repeating: "d", count: 64),
                cdHash: String(repeating: "d", count: 40)
            ),
            helper: .init(
                executablePath: outerPath
                    + VoicePerformanceTracerBundleLayout.helperExecutableSuffix,
                executableSHA256: String(repeating: "f", count: 64),
                cdHash: String(repeating: "f", count: 40)
            ),
            evaluationArtifact: .init(
                directory: "/private/tmp/rimeai-causal-evaluation-artifact",
                adapterID: "sherpa-onnx",
                artifactID: "voice-model",
                contentSHA256: String(repeating: "e", count: 64),
                maximumHotwords: 64
            ),
            rawReleasePolicySHA256: String(repeating: "1", count: 64)
        )
        measurementPolicy = try VoicePerformanceMeasurementPolicy
            .decodeCanonical(
                VoicePerformanceMeasurementPolicy.tracerCanonicalData(
                    for: input
                )
            )
    }
}

private enum CausalProcessLife: Equatable {
    case suspended
    case resumed
    case exited(Int32)
    case signaled(Int32)
    case reaped
}

private final class CausalProcessTable: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: CausalVirtualClock
    private var generations:
        [Int32: VoicePerformanceSupervisedProcessGeneration] = [:]
    private var lives: [Int32: CausalProcessLife] = [:]

    init(clock: CausalVirtualClock) {
        self.clock = clock
    }

    func addSuspended(
        _ generation: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        try lock.withLock {
            guard generations[generation.pid] == nil else {
                throw CausalFixtureError.invalidState
            }
            generations[generation.pid] = generation
            lives[generation.pid] = .suspended
        }
    }

    func requireSuspended(pid: Int32) throws {
        try lock.withLock {
            guard lives[pid] == .suspended else {
                throw CausalFixtureError.invalidState
            }
        }
    }

    func resume(pid: Int32) throws {
        try lock.withLock {
            guard lives[pid] == .suspended else {
                throw CausalFixtureError.invalidState
            }
            lives[pid] = .resumed
        }
    }

    func isResumed(pid: Int32) -> Bool {
        lock.withLock { lives[pid] == .resumed }
    }

    @discardableResult
    func exit(pid: Int32, code: Int32 = 0) -> Bool {
        lock.withLock {
            guard lives[pid] == .resumed || lives[pid] == .suspended else {
                return false
            }
            lives[pid] = .exited(code)
            return true
        }
    }

    func generation(pid: Int32)
        -> VoicePerformanceSupervisedProcessGeneration?
    {
        lock.withLock {
            guard lives[pid] != .reaped else { return nil }
            return generations[pid]
        }
    }

    func setProcessGroup(pid: Int32, group: Int32) throws {
        try lock.withLock {
            guard let current = generations[pid] else {
                throw CausalFixtureError.invalidState
            }
            generations[pid] = .init(
                pid: current.pid,
                startToken: current.startToken,
                processGroupID: group
            )
        }
    }

    func liveProcessIDs(group: Int32) -> Set<Int32> {
        lock.withLock {
            Set(generations.compactMap { pid, generation in
                guard generation.processGroupID == group,
                      lives[pid] == .suspended || lives[pid] == .resumed
                else { return nil }
                return pid
            })
        }
    }

    func peek(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        try lock.withLock {
            switch lives[pid] {
            case .suspended, .resumed:
                return .running
            case .exited(let code):
                return .exited(code: code)
            case .signaled(let signal):
                return .signaled(signal: signal)
            case .reaped, nil:
                throw CausalFixtureError.invalidState
            }
        }
    }

    func wait(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        try lock.withLock {
            switch lives[pid] {
            case .suspended, .resumed:
                return .running
            case .exited(let code):
                lives[pid] = .reaped
                return .exited(code: code)
            case .signaled(let signal):
                lives[pid] = .reaped
                return .signaled(signal: signal)
            case .reaped, nil:
                throw CausalFixtureError.invalidState
            }
        }
    }

    func signal(pid: Int32, signal: Int32) throws {
        try lock.withLock {
            guard lives[pid] == .suspended || lives[pid] == .resumed else {
                throw CausalFixtureError.invalidState
            }
            lives[pid] = .signaled(signal)
        }
    }

    func signalGroup(_ group: Int32, signal: Int32) throws {
        let pids = liveProcessIDs(group: group)
        for pid in pids { try self.signal(pid: pid, signal: signal) }
    }

    func sleep(nanoseconds: UInt64) {
        clock.advanceSilently(by: nanoseconds)
    }
}

private struct CausalProcessGroupSystem: VoicePerformanceProcessGroupSystem {
    let currentProcessID: Int32
    let processes: CausalProcessTable

    func setProcessGroup(pid: Int32, processGroupID: Int32) throws {
        try processes.setProcessGroup(pid: pid, group: processGroupID)
    }

    func generation(pid: Int32) throws
        -> VoicePerformanceSupervisedProcessGeneration?
    {
        processes.generation(pid: pid)
    }

    func signalProcessGroup(
        _ signal: VoicePerformanceTerminationSignal,
        processGroupID: Int32
    ) throws {
        try processes.signalGroup(
            processGroupID,
            signal: signal == .terminate ? 15 : 9
        )
    }

    func signalProcess(
        _ signal: VoicePerformanceTerminationSignal,
        pid: Int32
    ) throws {
        try processes.signal(pid: pid, signal: signal == .terminate ? 15 : 9)
    }

    func processGroupHasLiveProcesses(processGroupID: Int32) throws -> Bool {
        !processes.liveProcessIDs(group: processGroupID).isEmpty
    }

    func processGroupLiveProcessesExactlyMatch(
        processGroupID: Int32,
        expectedProcessIDs: Set<Int32>
    ) throws -> Bool {
        processes.liveProcessIDs(group: processGroupID)
            == expectedProcessIDs
    }

    func peekNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        try processes.peek(pid: pid)
    }

    func waitNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        try processes.wait(pid: pid)
    }

    func currentContinuousNanoseconds() throws -> UInt64 {
        processes.clockNowNanoseconds
    }

    func sleep(nanoseconds: UInt64) throws {
        processes.sleep(nanoseconds: nanoseconds)
    }
}

private extension CausalProcessTable {
    var clockNowNanoseconds: UInt64 {
        clock.nowNanoseconds
    }
}

private final class CausalSuspendedSpawnSystem:
    VoicePerformanceSecureChildSpawningSystem,
    @unchecked Sendable
{
    let clock: CausalVirtualClock
    let processes: CausalProcessTable

    init(clock: CausalVirtualClock, processes: CausalProcessTable) {
        self.clock = clock
        self.processes = processes
    }

    func spawnSuspended(
        specification: VoicePerformanceSecureSpawnSpecification
    ) throws -> VoicePerformanceSupervisedProcessGeneration {
        let generation: VoicePerformanceSupervisedProcessGeneration
        let event: CausalEvent
        switch specification.processGroup {
        case .new:
            generation = .init(pid: 701, startToken: 7_001, processGroupID: 701)
            event = .driverSpawnSuspended
        case .existing(let group):
            generation = .init(pid: 702, startToken: 7_002, processGroupID: group)
            event = .helperSpawnSuspended
        }
        try processes.addSuspended(generation)
        clock.record(event)
        return generation
    }

    func attestSuspendedChild(
        _ generation: VoicePerformanceSupervisedProcessGeneration,
        specification: VoicePerformanceSecureSpawnSpecification
    ) throws {
        try processes.requireSuspended(pid: generation.pid)
        guard specification.expectedChildIdentity.executablePath
                == specification.executablePath
        else { throw CausalFixtureError.invalidState }
        clock.record(
            generation.pid == 701 ? .driverAttested : .helperAttested
        )
    }

    func resumeSuspendedChild(
        _ generation: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        try processes.resume(pid: generation.pid)
        clock.record(
            generation.pid == 701 ? .driverResumed : .helperResumed
        )
    }

    func abortUnadoptedChild(
        _ generation: VoicePerformanceSupervisedProcessGeneration,
        processGroup _: VoicePerformanceSpawnProcessGroup
    ) throws {
        _ = processes.exit(pid: generation.pid)
    }
}

private final class CausalCollectorProcessRuntime:
    VoicePerformanceTracerCollectorProcessRuntime
{
    let policy: CausalPolicyFixture
    let clock: CausalVirtualClock
    let processes: CausalProcessTable
    let spawner: VoicePerformanceSecureChildSpawner
    let collectorSupervisor: VoicePerformanceCollectorDriverSupervisor
    let helperSupervisor: VoicePerformanceDriverHelperSupervisor
    let transport: CausalTracerTransport
    var launchedDriver: VoicePerformanceSupervisedProcessGeneration?
    var publishedData: Data?

    init(
        policy: CausalPolicyFixture,
        clock: CausalVirtualClock,
        processes: CausalProcessTable,
        spawner: VoicePerformanceSecureChildSpawner,
        collectorSupervisor: VoicePerformanceCollectorDriverSupervisor,
        helperSupervisor: VoicePerformanceDriverHelperSupervisor,
        transport: CausalTracerTransport
    ) {
        self.policy = policy
        self.clock = clock
        self.processes = processes
        self.spawner = spawner
        self.collectorSupervisor = collectorSupervisor
        self.helperSupervisor = helperSupervisor
        self.transport = transport
    }

    func parseArguments(
        _ argv: [String],
        currentExecutablePath: String
    ) throws -> VoicePerformanceCollectorProcessArguments {
        try VoicePerformanceCollectorProcessArguments.parse(
            argv,
            currentExecutablePath: currentExecutablePath
        )
    }

    func verifyCollectorBundle(
        declaredPath: String
    ) throws -> VoicePerformanceTracerCollectorVerifiedContext {
        guard declaredPath == policy.outerPath else {
            throw VoicePerformanceTracerProcessError.invalidTracerBundle
        }
        return .init(
            outerPath: declaredPath,
            measurementPolicy: policy.measurementPolicy,
            driverPolicy: policy.driverPolicy,
            selfStartToken: 6_001
        )
    }

    func makeGlobalDeadline()
        throws -> VoicePerformanceTracerCollectorGlobalDeadline
    {
        .init(
            processDeadline: .init(
                nanoseconds: CausalPolicyFixture.deadlineNanoseconds
            ),
            collectorDeadline: clock.instant(
                at: CausalPolicyFixture.deadlineNanoseconds
            )
        )
    }

    func hasTimeRemaining(
        before deadline: VoicePerformanceTracerCollectorGlobalDeadline
    ) throws -> Bool {
        clock.nowNanoseconds < deadline.processDeadline.nanoseconds
    }

    func startTransport(socketPath: String) throws {
        try transport.start(socketPath: socketPath)
    }

    func launchPreparedDriver(
        executablePath: String,
        argv: [String]
    ) throws -> VoicePerformanceSupervisedProcessGeneration {
        guard executablePath
                == policy.measurementPolicy.driver.expectedExecutablePath,
              argv == [
                  executablePath,
                  "--tracer-bundle", policy.outerPath,
                  "--deadline-continuous-ns",
                  String(CausalPolicyFixture.deadlineNanoseconds),
              ]
        else { throw CausalFixtureError.invalidState }
        let identity = try VoicePerformanceExpectedChildIdentity(
            executablePath: executablePath,
            executableSHA256:
                policy.measurementPolicy.driver.expectedExecutableSHA256,
            signingIdentifier:
                policy.measurementPolicy.driver.expectedSigningIdentifier,
            teamIdentifier:
                policy.measurementPolicy.driver.expectedTeamIdentifier,
            cdHash: policy.measurementPolicy.driver.expectedCDHash
        )
        let generation = try spawner.spawnDriver(
            request: VoicePerformanceDriverSpawnRequest(
                tracerBundlePath: policy.outerPath,
                expectedChildIdentity: identity,
                deadline: .init(
                    nanoseconds: CausalPolicyFixture.deadlineNanoseconds
                )
            ),
            supervisedBy: collectorSupervisor
        )
        try helperSupervisor.bindCurrentDriver(expected: generation)
        launchedDriver = generation
        return generation
    }

    func bindLaunchedDriver(
        _ identity: VoicePerformanceTracerLaunchedDriverIdentity
    ) throws {
        try transport.bindLaunchedDriver(identity)
    }

    func collect(
        _ request: VoicePerformanceTracerCollectionRequest,
        deadline: ContinuousClock.Instant
    ) throws -> VoicePerformanceTracerResult {
        let nonces = try ["2", "3", "6"].map(causalNonce)
        return try VoicePerformanceTracerCollector(
            transport: transport,
            nonceSource: CausalNonceSource(nonces),
            monotonicClock: CausalCollectorMonotonicClock(clock: clock),
            continuousClock: CausalCollectorContinuousClock(clock: clock)
        ).collect(request, deadline: deadline)
    }

    func waitForSucceededDriver(
        before _: VoicePerformanceTracerCollectorGlobalDeadline
    ) throws {
        guard let launchedDriver else {
            throw CausalFixtureError.invalidState
        }
        guard collectorSupervisor.driverGeneration == launchedDriver else {
            throw CausalFixtureError.invalidState
        }
        _ = try collectorSupervisor.reapSucceededDriver()
        clock.record(.driverReaped)
    }

    func closeTransport() {
        _ = transport.close()
    }

    func terminateDriverGroupAndReap() throws {
        try collectorSupervisor.terminateDriverGroupAndReap()
        if !clock.contains(.driverReaped) {
            clock.record(.driverReaped)
        }
    }

    func writeResult(
        _ data: Data,
        to resultPath: String,
        before deadline: VoicePerformanceContinuousDeadline
    ) throws {
        guard resultPath == policy.resultPath,
              clock.nowNanoseconds < deadline.nanoseconds
        else { throw CausalFixtureError.invalidState }
        publishedData = data
        clock.record(.evidencePublished)
    }
}

private final class CausalTracerTransport:
    VoicePerformanceTracerTransport,
    @unchecked Sendable
{
    let policy: CausalPolicyFixture
    let clock: CausalVirtualClock
    let processes: CausalProcessTable
    let spawner: VoicePerformanceSecureChildSpawner
    let helperSupervisor: VoicePerformanceDriverHelperSupervisor
    let replayReady: Bool
    let controlSocketPath: String
    var started = false
    var boundDriver: VoicePerformanceTracerLaunchedDriverIdentity?
    var driverConnection: CausalDriverConnection?
    var helperConnection: CausalHelperConnection?
    var closed = false

    init(
        policy: CausalPolicyFixture,
        clock: CausalVirtualClock,
        processes: CausalProcessTable,
        spawner: VoicePerformanceSecureChildSpawner,
        helperSupervisor: VoicePerformanceDriverHelperSupervisor,
        replayReady: Bool
    ) throws {
        self.policy = policy
        self.clock = clock
        self.processes = processes
        self.spawner = spawner
        self.helperSupervisor = helperSupervisor
        self.replayReady = replayReady
        controlSocketPath = policy.measurementPolicy.controlSocketPath
    }

    func start(socketPath: String) throws {
        guard !started, socketPath == controlSocketPath else {
            throw CausalFixtureError.invalidState
        }
        started = true
        clock.record(.transportStarted)
    }

    func bindLaunchedDriver(
        _ identity: VoicePerformanceTracerLaunchedDriverIdentity
    ) throws {
        guard started,
              boundDriver == nil,
              identity.role == .driver,
              identity.pid == 701,
              identity.processStartToken == 7_001,
              identity.processGroupID == 701,
              processes.isResumed(pid: identity.pid)
        else { throw VoicePerformanceTracerTransportError.failed }
        boundDriver = identity
        clock.record(.driverBound)
    }

    func acceptAuthenticatedConnection(
        _ request: VoicePerformanceTracerPeerRequest,
        deadline _: ContinuousClock.Instant
    ) throws -> any VoicePerformanceTracerConnection {
        switch request.role {
        case .driver:
            guard let boundDriver,
                  driverConnection == nil,
                  processes.isResumed(pid: boundDriver.pid)
            else { throw VoicePerformanceTracerTransportError.failed }
            let connection = try CausalDriverConnection(
                policy: policy,
                clock: clock,
                processes: processes
            )
            driverConnection = connection
            clock.record(.driverAccepted)
            return connection
        case .helper:
            guard request.trial == 1,
                  driverConnection != nil,
                  helperConnection == nil
            else { throw VoicePerformanceTracerTransportError.failed }
            let helper = policy.measurementPolicy.helper
            let identity = try VoicePerformanceExpectedChildIdentity(
                executablePath: helper.expectedExecutablePath,
                executableSHA256: helper.expectedExecutableSHA256,
                signingIdentifier: helper.expectedSigningIdentifier,
                teamIdentifier: helper.expectedTeamIdentifier,
                cdHash: helper.expectedCDHash
            )
            let generation = try spawner.spawnHelper(
                request: VoicePerformanceHelperSpawnRequest(
                    tracerBundlePath: policy.outerPath,
                    trial: 1,
                    policyColdTrials: 1,
                    expectedChildIdentity: identity,
                    deadline: .init(
                        nanoseconds: CausalPolicyFixture.deadlineNanoseconds
                    )
                ),
                supervisedBy: helperSupervisor
            )
            let connection = try CausalHelperConnection(
                policy: policy,
                clock: clock,
                processes: processes,
                generation: generation,
                supervisor: helperSupervisor,
                replayReady: replayReady
            )
            helperConnection = connection
            clock.record(.helperAccepted)
            return connection
        }
    }

    @discardableResult
    func close() -> Bool {
        guard !closed else { return true }
        closed = true
        driverConnection?.close()
        helperConnection?.close()
        clock.record(.transportClosed)
        return true
    }
}

private final class CausalDriverConnection:
    VoicePerformanceTracerConnection,
    @unchecked Sendable
{
    let policy: CausalPolicyFixture
    let clock: CausalVirtualClock
    let processes: CausalProcessTable
    let attestedPeer: VoicePerformanceTracerAttestedPeer
    var challenge: PerformanceControlWireFrame?
    var receiveCount = 0
    var closed = false

    init(
        policy: CausalPolicyFixture,
        clock: CausalVirtualClock,
        processes: CausalProcessTable
    ) throws {
        self.policy = policy
        self.clock = clock
        self.processes = processes
        attestedPeer = try .init(
            pid: 701,
            effectiveUserID: 501,
            processStartToken: 7_001,
            pidVersion: 1,
            instanceID: String(repeating: "d", count: 64)
        )
    }

    func send(
        _ frame: PerformanceControlWireFrame,
        deadline _: ContinuousClock.Instant
    ) throws {
        guard case .challenge(.driver, _, _, _) = frame,
              processes.isResumed(pid: 701)
        else { throw VoicePerformanceTracerTransportError.failed }
        challenge = frame
        clock.record(.driverChallenge)
    }

    func receive(
        deadline _: ContinuousClock.Instant
    ) throws -> PerformanceControlWireFrame {
        guard case let .challenge(
            .driver,
            sessionID,
            planNonce,
            collectorNonce
        ) = challenge else {
            throw VoicePerformanceTracerTransportError.failed
        }
        defer { receiveCount += 1 }
        if receiveCount == 0 {
            clock.record(.driverHello)
            return .driverHello(
                sessionID: sessionID,
                planNonce: planNonce,
                collectorNonce: collectorNonce,
                peerNonce: try causalNonce("4"),
                collectionProtocol: policy.measurementPolicy.controlProtocol,
                driverPolicySHA256: policy.driverPolicy.canonicalSHA256,
                measurementPolicySHA256: try .init(
                    policy.measurementPolicy.canonicalSHA256
                )
            )
        }
        guard receiveCount == 1 else {
            throw VoicePerformanceTracerTransportError.failed
        }
        clock.record(.driverArmed)
        return .armColdLoad(
            sequence: 1,
            sessionID: sessionID,
            trial: 1
        )
    }

    func close() {
        guard !closed else { return }
        closed = true
        if processes.exit(pid: 701) {
            clock.record(.driverFinished)
        }
    }

    func closeAndConfirmPeerExit(
        deadline _: ContinuousClock.Instant
    ) throws {
        close()
    }
}

private final class CausalHelperConnection:
    VoicePerformanceTracerConnection,
    @unchecked Sendable
{
    let policy: CausalPolicyFixture
    let clock: CausalVirtualClock
    let processes: CausalProcessTable
    let generation: VoicePerformanceSupervisedProcessGeneration
    let supervisor: VoicePerformanceDriverHelperSupervisor
    let replayReady: Bool
    let attestedPeer: VoicePerformanceTracerAttestedPeer
    var sent: [PerformanceControlWireFrame] = []
    var receiveCount = 0
    var closed = false
    var exitConfirmed = false

    init(
        policy: CausalPolicyFixture,
        clock: CausalVirtualClock,
        processes: CausalProcessTable,
        generation: VoicePerformanceSupervisedProcessGeneration,
        supervisor: VoicePerformanceDriverHelperSupervisor,
        replayReady: Bool
    ) throws {
        self.policy = policy
        self.clock = clock
        self.processes = processes
        self.generation = generation
        self.supervisor = supervisor
        self.replayReady = replayReady
        attestedPeer = try .init(
            pid: generation.pid,
            effectiveUserID: 501,
            processStartToken: generation.startToken,
            pidVersion: 2,
            instanceID: String(repeating: "e", count: 64)
        )
    }

    func send(
        _ frame: PerformanceControlWireFrame,
        deadline _: ContinuousClock.Instant
    ) throws {
        switch frame {
        case .challenge(.helper, _, _, _):
            clock.record(.helperChallenge)
        case .loadEngine:
            clock.record(.loadEngine)
        case .loadStartedAck:
            clock.record(.helperColdLoadBegin)
        default:
            throw VoicePerformanceTracerTransportError.failed
        }
        sent.append(frame)
    }

    func receive(
        deadline _: ContinuousClock.Instant
    ) throws -> PerformanceControlWireFrame {
        defer { receiveCount += 1 }
        switch receiveCount {
        case 0:
            guard case let .challenge(
                .helper,
                sessionID,
                planNonce,
                collectorNonce
            ) = sent.last else {
                throw VoicePerformanceTracerTransportError.failed
            }
            clock.record(.helperHello)
            return .helperHello(
                sessionID: sessionID,
                planNonce: planNonce,
                collectorNonce: collectorNonce,
                peerNonce: try causalNonce("5"),
                measurementPolicySHA256: try .init(
                    policy.measurementPolicy.canonicalSHA256
                ),
                releasePolicySHA256: try .init(
                    policy.measurementPolicy.releasePolicySHA256
                )
            )
        case 1:
            guard case let .loadEngine(
                sequence,
                sessionID,
                trial,
                ticket
            ) = sent.last else {
                throw VoicePerformanceTracerTransportError.failed
            }
            clock.record(.loadStarted)
            return .loadStarted(
                sequence: 1,
                sessionID: sessionID,
                replyTo: sequence,
                trial: trial,
                loadTicket: ticket
            )
        case 2:
            guard case let .loadStartedAck(
                sequence,
                sessionID,
                _,
                trial,
                ticket
            ) = sent.last else {
                throw VoicePerformanceTracerTransportError.failed
            }
            clock.record(.helperColdLoadEnd, advancingBy: 250)
            let expected = policy.measurementPolicy.expectedEngine
            let engine = try PerformanceControlEngineSummary(
                adapterID: expected.adapterID,
                engineID: expected.engineID,
                artifactID: expected.artifactID,
                artifactContentSHA256: expected.artifactContentSHA256,
                artifactGeneration: .init(
                    "00000000-0000-4000-8000-000000000001"
                ),
                capabilities: expected.capabilities,
                networkPolicy: expected.networkPolicy,
                maximumHotwords: expected.maximumHotwords
            )
            return .loadReady(
                sequence: 2,
                sessionID: sessionID,
                replyTo: sequence,
                trial: trial,
                loadTicket: replayReady ? try causalNonce("9") : ticket,
                engine: engine
            )
        default:
            throw VoicePerformanceTracerTransportError.failed
        }
    }

    func close() {
        closed = true
    }

    func closeAndConfirmPeerExit(
        deadline _: ContinuousClock.Instant
    ) throws {
        guard !exitConfirmed else { return }
        exitConfirmed = true
        closed = true
        guard processes.exit(pid: generation.pid) else {
            throw VoicePerformanceTracerTransportError.failed
        }
        clock.record(.helperFinished)
        _ = try supervisor.reapSucceededHelper(
            exactGeneration: generation
        )
        clock.record(.helperReaped)
    }
}

private func causalNonce(_ character: String)
    throws -> PerformanceControlNonce
{
    try PerformanceControlNonce(
        String(repeating: character, count: 64)
    )
}
