import Foundation
import RimeAIVoicePerformanceCollector
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceTracerDarwin
import RimeAIVoicePerformanceTracerProcessDarwin

enum VoicePerformanceTracerCollectorDeadlineBudget {
    private static let nanosecondsPerSecond: UInt64 = 1_000_000_000
    private static let fixedSeconds: UInt64 = 45
    private static let secondsPerTrial: UInt64 = 145

    /// Covers the sequential worst case of every phase-capped operation:
    /// helper accept/exit, collector sends, cumulative peer-response windows,
    /// and the 65-second acknowledged load-plus-ready window for each signed
    /// cold trial. The fixed budget covers driver accept/exit plus listener,
    /// spawn, and publication work.
    static func nanoseconds(coldTrials: UInt64) throws -> UInt64 {
        guard PerformanceControlSessionBinding.supportedTrials
            .contains(coldTrials)
        else {
            throw VoicePerformanceTracerCollectorProcessError
                .deadlineFailure
        }
        return try checkedNanoseconds(
            coldTrials: coldTrials,
            fixedSeconds: fixedSeconds,
            secondsPerTrial: secondsPerTrial
        )
    }

    static func checkedNanoseconds(
        coldTrials: UInt64,
        fixedSeconds: UInt64,
        secondsPerTrial: UInt64
    ) throws -> UInt64 {
        let (trialSeconds, multiplyOverflow) = secondsPerTrial
            .multipliedReportingOverflow(by: coldTrials)
        let (totalSeconds, addOverflow) = fixedSeconds
            .addingReportingOverflow(trialSeconds)
        let (nanoseconds, nanosecondOverflow) = totalSeconds
            .multipliedReportingOverflow(by: nanosecondsPerSecond)
        guard !multiplyOverflow, !addOverflow, !nanosecondOverflow else {
            throw VoicePerformanceTracerCollectorProcessError
                .deadlineFailure
        }
        return nanoseconds
    }
}

enum VoicePerformanceTracerCollectorDeadlineAlignment {
    static func collectorDeadline(
        processDeadline: VoicePerformanceContinuousDeadline,
        collectorNow: () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        remainingNanoseconds: (
            VoicePerformanceContinuousDeadline
        ) throws -> UInt64 = { deadline in
            try deadline.remainingNanoseconds()
        }
    ) throws -> ContinuousClock.Instant {
        // Sample the collector clock first. Advancing this earlier base by a
        // remainder sampled afterward can only make the collector deadline
        // conservative relative to the process's absolute deadline.
        let collectorBase = collectorNow()
        let remaining = try remainingNanoseconds(processDeadline)
        guard remaining > 0, remaining <= UInt64(Int64.max) else {
            throw VoicePerformanceTracerCollectorProcessError
                .deadlineFailure
        }
        return collectorBase.advanced(
            by: .nanoseconds(Int64(remaining))
        )
    }
}

final class DarwinVoicePerformanceTracerCollectorProcessRuntime:
    VoicePerformanceTracerCollectorProcessRuntime
{
    private let verifier = PerformanceTracerBundleVerifier()
    private let spawner = VoicePerformanceSecureChildSpawner()
    private let supervisor = VoicePerformanceCollectorDriverSupervisor()
    private let writer = VoicePerformanceAtomicResultWriter()

    private var verifiedContext:
        VoicePerformanceTracerCollectorVerifiedContext?
    private var globalDeadline:
        VoicePerformanceTracerCollectorGlobalDeadline?
    private var transport: DarwinVoicePerformanceTracerTransport?
    private var launchedDriver:
        VoicePerformanceSupervisedProcessGeneration?
    private var collectionStarted = false

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
        guard verifiedContext == nil else {
            throw VoicePerformanceTracerProcessError.invalidTracerBundle
        }
        let verified = try verifier.verify(
            role: .collector,
            declaredTracerBundlePath: declaredPath
        )
        guard let driverPolicy = verified.driverPolicy,
              verified.outerPath == declaredPath,
              !verified.authenticatedProductionDriver,
              !verified.measurementPolicy.authenticatedProductionDriver,
              !driverPolicy.authenticatedProductionDriver,
              verified.selfStartToken > 0
        else {
            throw VoicePerformanceTracerProcessError.invalidTracerBundle
        }
        let context = VoicePerformanceTracerCollectorVerifiedContext(
            outerPath: verified.outerPath,
            measurementPolicy: verified.measurementPolicy,
            driverPolicy: driverPolicy,
            selfStartToken: verified.selfStartToken
        )
        verifiedContext = context
        return context
    }

    func makeGlobalDeadline()
        throws -> VoicePerformanceTracerCollectorGlobalDeadline
    {
        guard let context = verifiedContext,
              globalDeadline == nil
        else {
            throw VoicePerformanceTracerCollectorProcessError
                .deadlineFailure
        }
        let duration = try VoicePerformanceTracerCollectorDeadlineBudget
            .nanoseconds(
                coldTrials: context.measurementPolicy.coldTrials
            )
        let processDeadline = try VoicePerformanceContinuousDeadline.after(
            nanoseconds: duration
        )
        let collectorDeadline = try
            VoicePerformanceTracerCollectorDeadlineAlignment
                .collectorDeadline(processDeadline: processDeadline)
        let deadline = VoicePerformanceTracerCollectorGlobalDeadline(
            processDeadline: processDeadline,
            collectorDeadline: collectorDeadline
        )
        globalDeadline = deadline
        return deadline
    }

    func hasTimeRemaining(
        before deadline: VoicePerformanceTracerCollectorGlobalDeadline
    ) throws -> Bool {
        guard matchesStoredDeadline(deadline) else {
            throw VoicePerformanceTracerCollectorProcessError
                .deadlineFailure
        }
        return try !deadline.processDeadline.isExpired()
            && ContinuousClock().now < deadline.collectorDeadline
    }

    func startTransport(socketPath: String) throws {
        guard transport == nil,
              let context = verifiedContext,
              context.measurementPolicy.controlSocketPath == socketPath
        else {
            throw VoicePerformanceTracerTransportError.failed
        }
        transport = try DarwinVoicePerformanceTracerTransport(
            socketPath: socketPath
        )
    }

    func launchPreparedDriver(
        executablePath: String,
        argv: [String]
    ) throws -> VoicePerformanceSupervisedProcessGeneration {
        guard launchedDriver == nil,
              transport != nil,
              let context = verifiedContext,
              let deadline = globalDeadline,
              executablePath
                == context.measurementPolicy.driver
                    .expectedExecutablePath,
              argv == [
                  executablePath,
                  "--tracer-bundle", context.outerPath,
                  "--deadline-continuous-ns",
                  deadline.processDeadline.encoded,
              ]
        else {
            throw VoicePerformanceTracerProcessError.processSpawnFailed
        }
        let driver = context.measurementPolicy.driver
        let expectedChildIdentity = try
            VoicePerformanceExpectedChildIdentity(
                executablePath: driver.expectedExecutablePath,
                executableSHA256: driver.expectedExecutableSHA256,
                signingIdentifier: driver.expectedSigningIdentifier,
                teamIdentifier: driver.expectedTeamIdentifier,
                cdHash: driver.expectedCDHash
            )
        let request = try VoicePerformanceDriverSpawnRequest(
            tracerBundlePath: context.outerPath,
            expectedChildIdentity: expectedChildIdentity,
            deadline: deadline.processDeadline
        )
        let generation = try spawner.spawnDriver(
            request: request,
            supervisedBy: supervisor
        )
        launchedDriver = generation
        return generation
    }

    func bindLaunchedDriver(
        _ identity: VoicePerformanceTracerLaunchedDriverIdentity
    ) throws {
        guard let transport,
              let generation = launchedDriver,
              identity.role == .driver,
              identity.pid == generation.pid,
              identity.processStartToken == generation.startToken,
              identity.processGroupID == generation.processGroupID
        else {
            throw VoicePerformanceTracerTransportError
                .authenticationFailed
        }
        try transport.bindLaunchedDriver(identity)
    }

    func collect(
        _ request: VoicePerformanceTracerCollectionRequest,
        deadline: ContinuousClock.Instant
    ) throws -> VoicePerformanceTracerResult {
        guard !collectionStarted,
              let context = verifiedContext,
              let transport,
              let globalDeadline,
              request.measurementPolicy == context.measurementPolicy,
              request.driverPolicy == context.driverPolicy,
              deadline == globalDeadline.collectorDeadline,
              !request.authenticatedProductionDriver
        else {
            throw VoicePerformanceTracerCollectorError.invalidRequest
        }
        collectionStarted = true
        return try VoicePerformanceTracerCollector(
            transport: transport
        ).collect(request, deadline: deadline)
    }

    func waitForSucceededDriver(
        before deadline: VoicePerformanceTracerCollectorGlobalDeadline
    ) throws {
        guard matchesStoredDeadline(deadline),
              let generation = launchedDriver
        else {
            throw VoicePerformanceTracerProcessError.processWaitFailed
        }
        _ = try supervisor.waitForSucceededDriver(
            exactGeneration: generation,
            until: deadline.processDeadline
        )
        launchedDriver = nil
    }

    func closeTransport() {
        transport?.close()
        transport = nil
    }

    func terminateDriverGroupAndReap() throws {
        try supervisor.terminateDriverGroupAndReap()
        launchedDriver = nil
    }

    func writeResult(
        _ data: Data,
        to resultPath: String,
        before deadline: VoicePerformanceContinuousDeadline
    ) throws {
        guard let context = verifiedContext else {
            throw VoicePerformanceTracerProcessError.invalidResultPath
        }
        guard let globalDeadline,
              deadline == globalDeadline.processDeadline
        else {
            throw VoicePerformanceTracerProcessError.invalidDeadline
        }
        try writer.write(
            canonicalResult: data,
            to: resultPath,
            protectingDirectories: [
                context.outerPath,
                context.measurementPolicy.evaluationArtifact.directory,
            ],
            before: deadline
        )
    }

    private func matchesStoredDeadline(
        _ deadline: VoicePerformanceTracerCollectorGlobalDeadline
    ) -> Bool {
        guard let globalDeadline else { return false }
        return deadline.processDeadline == globalDeadline.processDeadline
            && deadline.collectorDeadline
                == globalDeadline.collectorDeadline
    }
}
