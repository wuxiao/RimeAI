import Foundation

public enum VoicePerformancePowerSource: String, Codable, Sendable {
    case ac
    case battery
}

public enum VoicePerformanceThermalState: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public struct VoicePerformanceEnvironmentSnapshot: Equatable, Sendable {
    public let hardwareModel: String
    public let physicalMemoryBytes: UInt64
    public let logicalCPUCount: Int
    public let powerSource: VoicePerformancePowerSource
    public let lowPowerMode: Bool
    public let thermalState: VoicePerformanceThermalState

    public init(
        hardwareModel: String,
        physicalMemoryBytes: UInt64,
        logicalCPUCount: Int,
        powerSource: VoicePerformancePowerSource,
        lowPowerMode: Bool,
        thermalState: VoicePerformanceThermalState
    ) {
        self.hardwareModel = hardwareModel
        self.physicalMemoryBytes = physicalMemoryBytes
        self.logicalCPUCount = logicalCPUCount
        self.powerSource = powerSource
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
    }
}

public struct VoicePerformanceProcessSnapshot: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let processStartAbsoluteTime: UInt64
    public let userCPUNanoseconds: UInt64
    public let systemCPUNanoseconds: UInt64
    public let energyNanojoules: UInt64
    public let residentBytes: UInt64
    public let physicalFootprintBytes: UInt64

    public init(
        processIdentifier: pid_t,
        processStartAbsoluteTime: UInt64,
        userCPUNanoseconds: UInt64,
        systemCPUNanoseconds: UInt64,
        energyNanojoules: UInt64,
        residentBytes: UInt64,
        physicalFootprintBytes: UInt64
    ) {
        self.processIdentifier = processIdentifier
        self.processStartAbsoluteTime = processStartAbsoluteTime
        self.userCPUNanoseconds = userCPUNanoseconds
        self.systemCPUNanoseconds = systemCPUNanoseconds
        self.energyNanojoules = energyNanojoules
        self.residentBytes = residentBytes
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

public protocol VoicePerformancePlatform: Sendable {
    /// Re-attest the already-running collector. Production implementations
    /// must bind both the on-disk executable hash and the collector's Team ID.
    func verifyCollectorIdentity(
        expectedSHA256: String,
        expectedTeamIdentifier: String
    ) throws

    func environmentSnapshot() throws -> VoicePerformanceEnvironmentSnapshot

    /// Nanoseconds derived from mach_continuous_time, including time asleep.
    func continuousTimeNanoseconds() throws -> UInt64

    /// One live, identity-sandwiched RUSAGE_INFO_V6 snapshot.
    func attestedSnapshot(
        for process: VoicePerformanceProcessPlan,
        expectedTeamIdentifier: String
    ) throws -> VoicePerformanceProcessSnapshot
}

public struct VoicePerformanceArtifactEvidence: Codable, Equatable, Sendable {
    public let artifactID: String
    public let artifactContentSHA256: String
    public let adapterID: String
    public let engineID: String
    public let modelID: String
    public let modelRevision: String
    public let verifiedPayloadBytes: Int64
    public let verifiedFileCount: Int

    public init(
        artifactID: String,
        artifactContentSHA256: String,
        adapterID: String,
        engineID: String,
        modelID: String,
        modelRevision: String,
        verifiedPayloadBytes: Int64,
        verifiedFileCount: Int
    ) {
        self.artifactID = artifactID
        self.artifactContentSHA256 = artifactContentSHA256
        self.adapterID = adapterID
        self.engineID = engineID
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.verifiedPayloadBytes = verifiedPayloadBytes
        self.verifiedFileCount = verifiedFileCount
    }

    enum CodingKeys: String, CodingKey {
        case artifactID = "artifact_id"
        case artifactContentSHA256 = "artifact_content_sha256"
        case adapterID = "adapter_id"
        case engineID = "engine_id"
        case modelID = "model_id"
        case modelRevision = "model_revision"
        case verifiedPayloadBytes = "verified_payload_bytes"
        case verifiedFileCount = "verified_file_count"
    }
}

public protocol VoicePerformanceArtifactVerifying: Sendable {
    func verifyArtifact(at artifactDirectory: URL) throws
        -> VoicePerformanceArtifactEvidence
}

public struct VoicePerformanceCollectorMetadata: Codable, Equatable, Sendable {
    public let collectorID: String
    public let clockDomain: String
    public let sampleIntervalMilliseconds: Int
    public let memorySource: String
    public let energySource: String
    public let executableSHA256: String
    public let teamIdentifier: String
    public let signingIdentifier: String

    init(
        sampleIntervalMilliseconds: Int,
        executableSHA256: String,
        teamIdentifier: String
    ) {
        collectorID = "rimeai-voice-performance-v1"
        clockDomain = "mach_continuous_time"
        self.sampleIntervalMilliseconds = sampleIntervalMilliseconds
        memorySource = "proc_pid_rusage_v6"
        energySource = "proc_pid_rusage_v6_energy_nj"
        self.executableSHA256 = executableSHA256
        self.teamIdentifier = teamIdentifier
        signingIdentifier =
            DarwinVoicePerformancePlatform.collectorSigningIdentifier
    }

    enum CodingKeys: String, CodingKey {
        case collectorID = "collector_id"
        case clockDomain = "clock_domain"
        case sampleIntervalMilliseconds = "sample_interval_ms"
        case memorySource = "memory_source"
        case energySource = "energy_source"
        case executableSHA256 = "executable_sha256"
        case teamIdentifier = "team_identifier"
        case signingIdentifier = "signing_identifier"
    }
}

public struct VoicePerformanceEnvironmentResult: Codable, Equatable, Sendable {
    public let hardwareModel: String
    public let physicalMemoryBytes: UInt64
    public let logicalCPUCount: Int
    public let powerSource: VoicePerformancePowerSource
    public let lowPowerMode: Bool
    public let thermalStateStart: VoicePerformanceThermalState
    public let thermalStateEnd: VoicePerformanceThermalState

    enum CodingKeys: String, CodingKey {
        case hardwareModel = "hardware_model"
        case physicalMemoryBytes = "physical_memory_bytes"
        case logicalCPUCount = "logical_cpu_count"
        case powerSource = "power_source"
        case lowPowerMode = "low_power_mode"
        case thermalStateStart = "thermal_state_start"
        case thermalStateEnd = "thermal_state_end"
    }
}

public struct VoicePerformanceProcessResult: Codable, Equatable, Sendable {
    public let role: VoicePerformanceProcessRole
    public let instanceID: String
    public let startUserCPUNanoseconds: UInt64
    public let endUserCPUNanoseconds: UInt64
    public let startSystemCPUNanoseconds: UInt64
    public let endSystemCPUNanoseconds: UInt64
    public let startEnergyNanojoules: UInt64
    public let endEnergyNanojoules: UInt64
    public let baselineResidentBytes: UInt64
    public let peakResidentBytes: UInt64
    public let baselinePhysicalFootprintBytes: UInt64
    public let peakPhysicalFootprintBytes: UInt64
    public let sampleCount: Int
    public let maximumSampleGapMilliseconds: UInt64

    enum CodingKeys: String, CodingKey {
        case role
        case instanceID = "instance_id"
        case startUserCPUNanoseconds = "start_user_cpu_ns"
        case endUserCPUNanoseconds = "end_user_cpu_ns"
        case startSystemCPUNanoseconds = "start_system_cpu_ns"
        case endSystemCPUNanoseconds = "end_system_cpu_ns"
        case startEnergyNanojoules = "start_energy_nj"
        case endEnergyNanojoules = "end_energy_nj"
        case baselineResidentBytes = "baseline_resident_bytes"
        case peakResidentBytes = "peak_resident_bytes"
        case baselinePhysicalFootprintBytes = "baseline_phys_footprint_bytes"
        case peakPhysicalFootprintBytes = "peak_phys_footprint_bytes"
        case sampleCount = "sample_count"
        case maximumSampleGapMilliseconds = "maximum_sample_gap_ms"
    }
}

public struct VoicePerformanceSessionResult: Codable, Equatable, Sendable {
    public let sampleID: String
    public let processingDurationMilliseconds: UInt64
    public let processes: [VoicePerformanceProcessResult]

    enum CodingKeys: String, CodingKey {
        case sampleID = "sample_id"
        case processingDurationMilliseconds = "processing_duration_ms"
        case processes
    }
}

public struct VoicePerformanceKeyboardTrialResult:
    Codable,
    Equatable,
    Sendable
{
    public let sequence: Int
    public let phase: VoicePerformanceKeyboardPhase
    public let rimeCandidateLatencyMilliseconds: UInt64

    enum CodingKeys: String, CodingKey {
        case sequence
        case phase
        case rimeCandidateLatencyMilliseconds = "rime_candidate_latency_ms"
    }
}

public struct VoicePerformanceLateChallengeCounts:
    Codable,
    Equatable,
    Sendable
{
    public let cancel: Int
    public let applicationSwitch: Int
    public let secureInput: Int
    public let targetInvalidation: Int
    public let keyboardInput: Int

    init(counts: [VoicePerformanceLateChallengeScenario: Int]) {
        cancel = counts[.cancel, default: 0]
        applicationSwitch = counts[.applicationSwitch, default: 0]
        secureInput = counts[.secureInput, default: 0]
        targetInvalidation = counts[.targetInvalidation, default: 0]
        keyboardInput = counts[.keyboardInput, default: 0]
    }

    enum CodingKeys: String, CodingKey {
        case cancel
        case applicationSwitch = "application_switch"
        case secureInput = "secure_input"
        case targetInvalidation = "target_invalidation"
        case keyboardInput = "keyboard_input"
    }
}

public struct VoicePerformanceUnboundResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int = 1
    public let collectionProtocol: VoicePerformanceCollectionProtocol
    public let artifact: VoicePerformanceArtifactEvidence?
    public let collector: VoicePerformanceCollectorMetadata
    public let environment: VoicePerformanceEnvironmentResult
    public let coldArtifactLoadMilliseconds: [UInt64]
    public let sessions: [VoicePerformanceSessionResult]
    public let keyboardTrials: [VoicePerformanceKeyboardTrialResult]
    public let lateVoiceCommitCount: Int
    public let lateChallengeCounts: VoicePerformanceLateChallengeCounts

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case collectionProtocol = "collection_protocol"
        case artifact
        case collector
        case environment
        case coldArtifactLoadMilliseconds = "cold_artifact_load_ms"
        case sessions
        case keyboardTrials = "keyboard_trials"
        case lateVoiceCommitCount = "late_voice_commit_count"
        case lateChallengeCounts = "late_challenge_counts"
    }
}
