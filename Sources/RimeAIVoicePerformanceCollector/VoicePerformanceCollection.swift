import Foundation

public final class VoicePerformanceCollection: @unchecked Sendable {
    private struct ProcessIdentity: Equatable {
        let processIdentifier: pid_t
        let startAbsoluteTime: UInt64
    }

    private struct ProcessAccumulator {
        let plan: VoicePerformanceProcessPlan
        let start: VoicePerformanceProcessSnapshot
        var last: VoicePerformanceProcessSnapshot
        var peakResidentBytes: UInt64
        var peakPhysicalFootprintBytes: UInt64
        var sampleCount: Int
        var lastSampleNanoseconds: UInt64
        var maximumSampleGapNanoseconds: UInt64

        init(
            plan: VoicePerformanceProcessPlan,
            snapshot: VoicePerformanceProcessSnapshot,
            nowNanoseconds: UInt64
        ) {
            self.plan = plan
            start = snapshot
            last = snapshot
            peakResidentBytes = snapshot.residentBytes
            peakPhysicalFootprintBytes = snapshot.physicalFootprintBytes
            sampleCount = 1
            lastSampleNanoseconds = nowNanoseconds
            maximumSampleGapNanoseconds = 0
        }

        mutating func append(
            _ snapshot: VoicePerformanceProcessSnapshot,
            at nowNanoseconds: UInt64
        ) throws {
            guard nowNanoseconds >= lastSampleNanoseconds,
                  snapshot.userCPUNanoseconds >= last.userCPUNanoseconds,
                  snapshot.systemCPUNanoseconds >= last.systemCPUNanoseconds,
                  snapshot.energyNanojoules >= last.energyNanojoules
            else {
                throw VoicePerformanceCollectorError.samplingFailed
            }
            maximumSampleGapNanoseconds = max(
                maximumSampleGapNanoseconds,
                nowNanoseconds - lastSampleNanoseconds
            )
            peakResidentBytes = max(peakResidentBytes, snapshot.residentBytes)
            peakPhysicalFootprintBytes = max(
                peakPhysicalFootprintBytes,
                snapshot.physicalFootprintBytes
            )
            sampleCount += 1
            lastSampleNanoseconds = nowNanoseconds
            last = snapshot
        }

        func result() -> VoicePerformanceProcessResult {
            VoicePerformanceProcessResult(
                role: plan.role,
                instanceID: Self.instanceID(plan: plan, snapshot: start),
                startUserCPUNanoseconds: start.userCPUNanoseconds,
                endUserCPUNanoseconds: last.userCPUNanoseconds,
                startSystemCPUNanoseconds: start.systemCPUNanoseconds,
                endSystemCPUNanoseconds: last.systemCPUNanoseconds,
                startEnergyNanojoules: start.energyNanojoules,
                endEnergyNanojoules: last.energyNanojoules,
                baselineResidentBytes: start.residentBytes,
                peakResidentBytes: peakResidentBytes,
                baselinePhysicalFootprintBytes: start.physicalFootprintBytes,
                peakPhysicalFootprintBytes: peakPhysicalFootprintBytes,
                sampleCount: sampleCount,
                maximumSampleGapMilliseconds:
                    maximumSampleGapNanoseconds / 1_000_000
            )
        }

        private static func instanceID(
            plan: VoicePerformanceProcessPlan,
            snapshot: VoicePerformanceProcessSnapshot
        ) -> String {
            "\(plan.role.rawValue)-\(snapshot.processIdentifier)-"
                + "\(snapshot.processStartAbsoluteTime)-"
                + String(plan.expectedCDHash.prefix(12))
        }
    }

    private struct ActiveSession {
        let sampleID: String
        let startNanoseconds: UInt64
        var accumulators: [ProcessAccumulator]
    }

    private struct ActiveColdArtifactLoad {
        let sequence: Int
        let startNanoseconds: UInt64
    }

    private struct KeyboardKey: Hashable {
        let sequence: Int
        let phase: VoicePerformanceKeyboardPhase
    }

    private struct ActiveKeyboardTrial {
        let key: KeyboardKey
        let startNanoseconds: UInt64
    }

    private let lock = NSLock()
    private let plan: VoicePerformanceCollectionPlan
    private let platform: any VoicePerformancePlatform
    private let artifactVerifier: any VoicePerformanceArtifactVerifying
    private let initialEnvironment: VoicePerformanceEnvironmentSnapshot
    private let processIdentities: [VoicePerformanceProcessRole: ProcessIdentity]

    private var verifiedArtifact: VoicePerformanceArtifactEvidence?
    private var activeColdArtifactLoad: ActiveColdArtifactLoad?
    private var usedColdArtifactSequences: Set<Int> = []
    private var coldArtifactLoadMilliseconds: [UInt64] = []
    private var activeSession: ActiveSession?
    private var seenSampleIDs: Set<String> = []
    private var sessions: [VoicePerformanceSessionResult] = []
    private var activeKeyboardTrial: ActiveKeyboardTrial?
    private var seenKeyboardKeys: Set<KeyboardKey> = []
    private var keyboardTrials: [VoicePerformanceKeyboardTrialResult] = []
    private var lateVoiceCommitCount = 0
    private var lateChallengeCounts: [
        VoicePerformanceLateChallengeScenario: Int
    ] = [:]
    private var finishMarkerReceived = false
    private var failed = false

    private static func isValidHardwareModel(_ value: String) -> Bool {
        let bytes = value.utf8
        guard let first = bytes.first,
              bytes.count <= 128,
              isASCIIAlphanumeric(first)
        else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            isASCIIAlphanumeric(byte)
                || byte == 0x2C // , in raw hw.model values such as Mac15,7
                || byte == 0x2D // -
                || byte == 0x2E // .
                || byte == 0x5F // _
        }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
    }

    public init(
        plan: VoicePerformanceCollectionPlan,
        platform: any VoicePerformancePlatform,
        artifactVerifier: any VoicePerformanceArtifactVerifying =
            VoicePerformanceASRArtifactVerifier()
    ) throws {
        self.plan = plan
        self.platform = platform
        self.artifactVerifier = artifactVerifier
        do {
            try platform.verifyCollectorIdentity(
                expectedSHA256: plan.nativeCollectorSHA256,
                expectedTeamIdentifier: plan.expectedTeamIdentifier
            )
            let environment = try platform.environmentSnapshot()
            guard !environment.lowPowerMode,
                  Self.isValidHardwareModel(environment.hardwareModel),
                  environment.physicalMemoryBytes > 0,
                  environment.logicalCPUCount > 0
            else {
                throw VoicePerformanceCollectorError.invalidEnvironment
            }
            initialEnvironment = environment

            var identities: [
                VoicePerformanceProcessRole: ProcessIdentity
            ] = [:]
            for process in plan.processes {
                let snapshot = try platform.attestedSnapshot(
                    for: process,
                    expectedTeamIdentifier: plan.expectedTeamIdentifier
                )
                guard snapshot.processIdentifier == process.processIdentifier,
                      snapshot.processStartAbsoluteTime > 0,
                      snapshot.residentBytes > 0,
                      snapshot.physicalFootprintBytes > 0
                else {
                    throw VoicePerformanceCollectorError.invalidProcessIdentity
                }
                identities[process.role] = ProcessIdentity(
                    processIdentifier: snapshot.processIdentifier,
                    startAbsoluteTime: snapshot.processStartAbsoluteTime
                )
            }
            guard identities.count == VoicePerformanceProcessRole.allCases.count
            else {
                throw VoicePerformanceCollectorError.invalidProcessIdentity
            }
            processIdentities = identities
        } catch let error as VoicePerformanceCollectorError {
            throw error
        } catch {
            throw VoicePerformanceCollectorError.samplingFailed
        }
    }

    public func consume(_ event: VoicePerformanceLiveEvent) throws {
        lock.lock()
        defer { lock.unlock() }
        try performFailClosed {
            guard !finishMarkerReceived else {
                throw VoicePerformanceCollectorError.invalidStateTransition
            }
            switch event {
            case let .coldArtifactLoadBegin(sequence):
                guard activeColdArtifactLoad == nil,
                      activeSession == nil,
                      activeKeyboardTrial == nil,
                      !usedColdArtifactSequences.contains(sequence)
                else {
                    throw VoicePerformanceCollectorError.invalidStateTransition
                }
                let now = try beginBoundaryNanoseconds()
                activeColdArtifactLoad = ActiveColdArtifactLoad(
                    sequence: sequence,
                    startNanoseconds: now
                )
            case let .coldArtifactLoadEnd(sequence):
                guard let active = activeColdArtifactLoad,
                      active.sequence == sequence
                else {
                    throw VoicePerformanceCollectorError.invalidStateTransition
                }
                let now = try endBoundaryNanoseconds()
                guard now >= active.startNanoseconds,
                      now - active.startNanoseconds >= 1_000_000
                else {
                    throw VoicePerformanceCollectorError.samplingFailed
                }
                coldArtifactLoadMilliseconds.append(
                    (now - active.startNanoseconds) / 1_000_000
                )
                usedColdArtifactSequences.insert(sequence)
                activeColdArtifactLoad = nil
            case let .sessionBegin(sampleID):
                try beginSession(sampleID: sampleID)
            case let .sessionEnd(sampleID):
                try endSession(sampleID: sampleID)
            case let .keyboardBegin(sequence, phase):
                let key = KeyboardKey(sequence: sequence, phase: phase)
                guard activeKeyboardTrial == nil,
                      activeColdArtifactLoad == nil,
                      activeSession == nil,
                      !seenKeyboardKeys.contains(key)
                else {
                    throw VoicePerformanceCollectorError.invalidStateTransition
                }
                activeKeyboardTrial = ActiveKeyboardTrial(
                    key: key,
                    startNanoseconds: try beginBoundaryNanoseconds()
                )
            case let .keyboardCandidateReady(sequence, phase):
                let key = KeyboardKey(sequence: sequence, phase: phase)
                guard let active = activeKeyboardTrial,
                      active.key == key
                else {
                    throw VoicePerformanceCollectorError.invalidStateTransition
                }
                let now = try endBoundaryNanoseconds()
                guard now >= active.startNanoseconds,
                      now - active.startNanoseconds >= 1_000_000
                else {
                    throw VoicePerformanceCollectorError.samplingFailed
                }
                keyboardTrials.append(VoicePerformanceKeyboardTrialResult(
                    sequence: sequence,
                    phase: phase,
                    rimeCandidateLatencyMilliseconds:
                        (now - active.startNanoseconds) / 1_000_000
                ))
                seenKeyboardKeys.insert(key)
                activeKeyboardTrial = nil
            case .lateVoiceCommit:
                _ = try endBoundaryNanoseconds()
                guard lateVoiceCommitCount < Int.max else {
                    throw VoicePerformanceCollectorError.samplingFailed
                }
                lateVoiceCommitCount += 1
            case let .challenge(scenario):
                guard activeColdArtifactLoad == nil,
                      activeSession == nil,
                      activeKeyboardTrial == nil,
                      lateChallengeCounts[scenario, default: 0] < Int.max
                else {
                    throw VoicePerformanceCollectorError.invalidStateTransition
                }
                _ = try endBoundaryNanoseconds()
                lateChallengeCounts[scenario, default: 0] += 1
            case .finish:
                try receiveFinishMarker()
            }
        }
    }

    public func sample() throws {
        lock.lock()
        defer { lock.unlock() }
        try performFailClosed {
            guard !finishMarkerReceived else {
                throw VoicePerformanceCollectorError.invalidStateTransition
            }
            try validateEnvironment()
            let now = try platform.continuousTimeNanoseconds()
            let snapshots = try captureAllSnapshots()
            guard var session = activeSession else { return }
            try append(
                snapshots: snapshots,
                at: now,
                to: &session.accumulators
            )
            activeSession = session
        }
    }

    public func finish() throws -> VoicePerformanceUnboundResult {
        lock.lock()
        defer { lock.unlock() }
        return try performFailClosed {
            guard finishMarkerReceived else {
                throw VoicePerformanceCollectorError.incompleteCollection
            }
            let verifiedArtifact = try verifyArtifactForResult()
            return VoicePerformanceUnboundResult(
                collectionProtocol: plan.collectionProtocol,
                artifact: verifiedArtifact,
                collector: VoicePerformanceCollectorMetadata(
                    sampleIntervalMilliseconds:
                        plan.sampleIntervalMilliseconds,
                    executableSHA256: plan.nativeCollectorSHA256,
                    teamIdentifier: plan.expectedTeamIdentifier
                ),
                environment: VoicePerformanceEnvironmentResult(
                    hardwareModel: initialEnvironment.hardwareModel,
                    physicalMemoryBytes:
                        initialEnvironment.physicalMemoryBytes,
                    logicalCPUCount: initialEnvironment.logicalCPUCount,
                    powerSource: initialEnvironment.powerSource,
                    lowPowerMode: initialEnvironment.lowPowerMode,
                    thermalStateStart: initialEnvironment.thermalState,
                    thermalStateEnd: initialEnvironment.thermalState
                ),
                coldArtifactLoadMilliseconds: coldArtifactLoadMilliseconds,
                sessions: sessions,
                keyboardTrials: keyboardTrials,
                lateVoiceCommitCount: lateVoiceCommitCount,
                lateChallengeCounts: VoicePerformanceLateChallengeCounts(
                    counts: lateChallengeCounts
                )
            )
        }
    }

    private func performFailClosed<T>(_ body: () throws -> T) throws -> T {
        guard !failed else {
            throw VoicePerformanceCollectorError.samplingFailed
        }
        do {
            return try body()
        } catch {
            failed = true
            if let collectorError = error as? VoicePerformanceCollectorError {
                throw collectorError
            }
            throw VoicePerformanceCollectorError.samplingFailed
        }
    }

    private func verifyArtifactForResult() throws
        -> VoicePerformanceArtifactEvidence?
    {
        if let verifiedArtifact {
            return verifiedArtifact
        }
        guard let artifactDirectory = plan.artifactDirectory,
              let expectedArtifact = plan.artifact
        else {
            return nil
        }
        let artifact = try artifactVerifier.verifyArtifact(
            at: artifactDirectory
        )
        guard artifact.artifactID == expectedArtifact.artifactID,
              artifact.artifactContentSHA256
                == expectedArtifact.artifactContentSHA256,
              artifact.adapterID == expectedArtifact.adapterID,
              artifact.engineID == expectedArtifact.engineID,
              artifact.modelID == expectedArtifact.modelID,
              artifact.modelRevision == expectedArtifact.modelRevision,
              artifact.verifiedPayloadBytes > 0,
              artifact.verifiedFileCount > 0
        else {
            throw VoicePerformanceCollectorError.invalidArtifact
        }
        verifiedArtifact = artifact
        return artifact
    }

    private func beginBoundaryNanoseconds() throws -> UInt64 {
        try validateEnvironment()
        _ = try captureAllSnapshots()
        return try platform.continuousTimeNanoseconds()
    }

    private func endBoundaryNanoseconds() throws -> UInt64 {
        try validateEnvironment()
        let now = try platform.continuousTimeNanoseconds()
        _ = try captureAllSnapshots()
        return now
    }

    private func validateEnvironment() throws {
        let current = try platform.environmentSnapshot()
        guard current == initialEnvironment else {
            throw VoicePerformanceCollectorError.invalidEnvironment
        }
    }

    private func captureAllSnapshots() throws
        -> [VoicePerformanceProcessSnapshot]
    {
        var snapshots: [VoicePerformanceProcessSnapshot] = []
        snapshots.reserveCapacity(plan.processes.count)
        for process in plan.processes {
            let snapshot = try platform.attestedSnapshot(
                for: process,
                expectedTeamIdentifier: plan.expectedTeamIdentifier
            )
            let expectedIdentity = processIdentities[process.role]
            guard snapshot.processIdentifier == process.processIdentifier,
                  snapshot.processStartAbsoluteTime > 0,
                  expectedIdentity == ProcessIdentity(
                      processIdentifier: snapshot.processIdentifier,
                      startAbsoluteTime: snapshot.processStartAbsoluteTime
                  )
            else {
                throw VoicePerformanceCollectorError.invalidProcessIdentity
            }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    private func beginSession(sampleID: String) throws {
        guard activeSession == nil,
              activeColdArtifactLoad == nil,
              activeKeyboardTrial == nil,
              !seenSampleIDs.contains(sampleID)
        else {
            throw VoicePerformanceCollectorError.invalidStateTransition
        }
        try validateEnvironment()
        let snapshots = try captureAllSnapshots()
        guard snapshots.allSatisfy({
            $0.residentBytes > 0 && $0.physicalFootprintBytes > 0
        }) else {
            throw VoicePerformanceCollectorError.samplingFailed
        }
        let now = try platform.continuousTimeNanoseconds()
        let accumulators = zip(plan.processes, snapshots).map {
            ProcessAccumulator(
                plan: $0.0,
                snapshot: $0.1,
                nowNanoseconds: now
            )
        }
        activeSession = ActiveSession(
            sampleID: sampleID,
            startNanoseconds: now,
            accumulators: accumulators
        )
    }

    private func endSession(sampleID: String) throws {
        guard var session = activeSession,
              session.sampleID == sampleID
        else {
            throw VoicePerformanceCollectorError.invalidStateTransition
        }
        try validateEnvironment()
        let now = try platform.continuousTimeNanoseconds()
        let snapshots = try captureAllSnapshots()
        guard now >= session.startNanoseconds,
              now - session.startNanoseconds >= 1_000_000
        else {
            throw VoicePerformanceCollectorError.samplingFailed
        }
        try append(
            snapshots: snapshots,
            at: now,
            to: &session.accumulators
        )
        let maximumAllowedGap = UInt64(plan.sampleIntervalMilliseconds)
            * 2_000_000
        guard session.accumulators.allSatisfy({
            $0.sampleCount >= 2
                && $0.maximumSampleGapNanoseconds <= maximumAllowedGap
        }) else {
            throw VoicePerformanceCollectorError.samplingFailed
        }
        let processResults = session.accumulators.map { $0.result() }
        guard let voiceHelper = processResults.first(where: {
            $0.role == .voiceHelper
        })
        else {
            throw VoicePerformanceCollectorError.samplingFailed
        }
        let userDelta = voiceHelper.endUserCPUNanoseconds
            - voiceHelper.startUserCPUNanoseconds
        let systemDelta = voiceHelper.endSystemCPUNanoseconds
            - voiceHelper.startSystemCPUNanoseconds
        let (totalCPUDelta, cpuOverflow) = userDelta.addingReportingOverflow(
            systemDelta
        )
        guard !cpuOverflow, totalCPUDelta > 0 else {
            throw VoicePerformanceCollectorError.samplingFailed
        }
        sessions.append(VoicePerformanceSessionResult(
            sampleID: sampleID,
            processingDurationMilliseconds:
                (now - session.startNanoseconds) / 1_000_000,
            processes: processResults
        ))
        seenSampleIDs.insert(sampleID)
        activeSession = nil
    }

    private func append(
        snapshots: [VoicePerformanceProcessSnapshot],
        at nowNanoseconds: UInt64,
        to accumulators: inout [ProcessAccumulator]
    ) throws {
        guard snapshots.count == accumulators.count else {
            throw VoicePerformanceCollectorError.samplingFailed
        }
        for index in accumulators.indices {
            try accumulators[index].append(
                snapshots[index],
                at: nowNanoseconds
            )
        }
    }

    private func receiveFinishMarker() throws {
        guard activeColdArtifactLoad == nil,
              activeSession == nil,
              activeKeyboardTrial == nil,
              !coldArtifactLoadMilliseconds.isEmpty,
              !sessions.isEmpty,
              !keyboardTrials.isEmpty
        else {
            throw VoicePerformanceCollectorError.incompleteCollection
        }
        for sequence in Set(keyboardTrials.map(\.sequence)) {
            let phases = Set(
                keyboardTrials.lazy
                    .filter { $0.sequence == sequence }
                    .map(\.phase)
            )
            guard phases == Set(VoicePerformanceKeyboardPhase.allCases) else {
                throw VoicePerformanceCollectorError.incompleteCollection
            }
        }
        let hasPositiveEnergyDelta = sessions.lazy
            .flatMap(\.processes)
            .contains(where: {
                $0.endEnergyNanojoules > $0.startEnergyNanojoules
            })
        guard hasPositiveEnergyDelta else {
            throw VoicePerformanceCollectorError.incompleteCollection
        }
        _ = try endBoundaryNanoseconds()
        finishMarkerReceived = true
    }
}
