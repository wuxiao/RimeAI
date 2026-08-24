import CryptoKit
import Darwin
import Foundation
import Security

@_silgen_name("csops")
private func rimeaiSuspendedChildCSOps(
    _ pid: pid_t,
    _ operation: UInt32,
    _ address: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int32

private func rimeaiIsCanonicalAbsoluteExecutablePath(
    _ value: String
) -> Bool {
    guard value.utf8.count > 1,
          value.utf8.count < Int(MAXPATHLEN),
          value.first == "/",
          value.last != "/",
          value.utf8.elementsEqual(
              value.precomposedStringWithCanonicalMapping.utf8
          ),
          !value.unicodeScalars.contains(where: {
              $0.value < 0x20 || $0.value == 0x7F
          })
    else {
        return false
    }
    return value.dropFirst().split(
        separator: "/",
        omittingEmptySubsequences: false
    ).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
            && $0.utf8.count <= 255
    }
}

public struct VoicePerformanceExpectedChildIdentity: Equatable, Sendable {
    public let executablePath: String
    public let executableSHA256: String
    public let signingIdentifier: String
    public let teamIdentifier: String
    public let cdHash: String

    public init(
        executablePath: String,
        executableSHA256: String,
        signingIdentifier: String,
        teamIdentifier: String,
        cdHash: String
    ) throws {
        guard Self.isCanonicalAbsolutePath(executablePath),
              Self.isLowercaseHex(executableSHA256, byteCount: 32),
              Self.isSigningIdentifier(signingIdentifier),
              Self.isTeamIdentifier(teamIdentifier),
              Self.isLowercaseHex(cdHash, byteCount: 20)
        else {
            throw VoicePerformanceTracerProcessError.invalidTracerBundle
        }
        self.executablePath = executablePath
        self.executableSHA256 = executableSHA256
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.cdHash = cdHash
    }

    private static func isCanonicalAbsolutePath(_ value: String) -> Bool {
        rimeaiIsCanonicalAbsoluteExecutablePath(value)
    }

    private static func isSigningIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 255,
              let first = value.utf8.first,
              isASCIIAlphaNumeric(first)
        else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { byte in
            isASCIIAlphaNumeric(byte) || byte == 0x2D || byte == 0x2E
        }
    }

    private static func isTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte)
                || (0x41 ... 0x5A).contains(byte)
        }
    }

    private static func isLowercaseHex(
        _ value: String,
        byteCount: Int
    ) -> Bool {
        value.utf8.count == byteCount * 2 && value.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x5A).contains(byte)
            || (0x61 ... 0x7A).contains(byte)
    }
}

public struct VoicePerformanceDriverSpawnRequest: Equatable, Sendable {
    private static let requiredSigningIdentifier =
        "fun.wwcn.rimeai.voice-performance-driver"

    public let tracerBundlePath: String
    public let expectedChildIdentity: VoicePerformanceExpectedChildIdentity
    public let deadline: VoicePerformanceContinuousDeadline

    public init(
        tracerBundlePath: String,
        expectedChildIdentity: VoicePerformanceExpectedChildIdentity,
        deadline: VoicePerformanceContinuousDeadline
    ) throws {
        let executablePath =
            tracerBundlePath
            + VoicePerformanceTracerBundleLayout.driverExecutableSuffix
        _ = try VoicePerformanceDriverProcessArguments.parse(
            [
                executablePath,
                "--tracer-bundle", tracerBundlePath,
                "--deadline-continuous-ns", deadline.encoded,
            ],
            currentExecutablePath: executablePath
        )
        guard expectedChildIdentity.executablePath.utf8.elementsEqual(
                  executablePath.utf8
              ),
              expectedChildIdentity.signingIdentifier
                == Self.requiredSigningIdentifier
        else {
            throw VoicePerformanceTracerProcessError.invalidTracerBundle
        }
        self.tracerBundlePath = tracerBundlePath
        self.expectedChildIdentity = expectedChildIdentity
        self.deadline = deadline
    }

    fileprivate var specification: VoicePerformanceSecureSpawnSpecification {
        let executablePath =
            tracerBundlePath
            + VoicePerformanceTracerBundleLayout.driverExecutableSuffix
        return .init(
            executablePath: executablePath,
            arguments: [
                executablePath,
                "--tracer-bundle", tracerBundlePath,
                "--deadline-continuous-ns", deadline.encoded,
            ],
            processGroup: .new,
            expectedChildIdentity: expectedChildIdentity
        )
    }
}

public struct VoicePerformanceHelperSpawnRequest: Equatable, Sendable {
    private static let requiredSigningIdentifier =
        "fun.wwcn.rimeai.voice-helper"

    public let tracerBundlePath: String
    public let trial: UInt64
    public let expectedChildIdentity: VoicePerformanceExpectedChildIdentity
    public let deadline: VoicePerformanceContinuousDeadline

    public init(
        tracerBundlePath: String,
        trial: UInt64,
        policyColdTrials: UInt64,
        expectedChildIdentity: VoicePerformanceExpectedChildIdentity,
        deadline: VoicePerformanceContinuousDeadline
    ) throws {
        let executablePath =
            tracerBundlePath
            + VoicePerformanceTracerBundleLayout.helperExecutableSuffix
        _ = try VoicePerformanceHelperProcessArguments.parse(
            [
                executablePath,
                "--tracer-bundle", tracerBundlePath,
                "--trial", String(trial),
                "--deadline-continuous-ns", deadline.encoded,
            ],
            currentExecutablePath: executablePath,
            policyColdTrials: policyColdTrials
        )
        guard expectedChildIdentity.executablePath.utf8.elementsEqual(
                  executablePath.utf8
              ),
              expectedChildIdentity.signingIdentifier
                == Self.requiredSigningIdentifier
        else {
            throw VoicePerformanceTracerProcessError.invalidTracerBundle
        }
        self.tracerBundlePath = tracerBundlePath
        self.trial = trial
        self.expectedChildIdentity = expectedChildIdentity
        self.deadline = deadline
    }

    fileprivate func specification(
        joining processGroupID: Int32
    ) -> VoicePerformanceSecureSpawnSpecification {
        let executablePath =
            tracerBundlePath
            + VoicePerformanceTracerBundleLayout.helperExecutableSuffix
        return .init(
            executablePath: executablePath,
            arguments: [
                executablePath,
                "--tracer-bundle", tracerBundlePath,
                "--trial", String(trial),
                "--deadline-continuous-ns", deadline.encoded,
            ],
            processGroup: .existing(processGroupID),
            expectedChildIdentity: expectedChildIdentity
        )
    }
}

enum VoicePerformanceSpawnProcessGroup: Equatable, Sendable {
    case new
    case existing(Int32)
}

struct VoicePerformanceSecureSpawnSpecification: Equatable, Sendable {
    static let fixedEnvironment = [
        "LANG=C",
        "LC_ALL=C",
        "PATH=/usr/bin:/bin",
    ]

    let executablePath: String
    let arguments: [String]
    let processGroup: VoicePerformanceSpawnProcessGroup
    let expectedChildIdentity: VoicePerformanceExpectedChildIdentity
    let environment = fixedEnvironment
}

protocol VoicePerformanceSecureChildSpawningSystem: Sendable {
    func spawnSuspended(
        specification: VoicePerformanceSecureSpawnSpecification
    ) throws -> VoicePerformanceSupervisedProcessGeneration
    func attestSuspendedChild(
        _ generation: VoicePerformanceSupervisedProcessGeneration,
        specification: VoicePerformanceSecureSpawnSpecification
    ) throws
    func resumeSuspendedChild(
        _ generation: VoicePerformanceSupervisedProcessGeneration
    ) throws
    func abortUnadoptedChild(
        _ generation: VoicePerformanceSupervisedProcessGeneration,
        processGroup: VoicePerformanceSpawnProcessGroup
    ) throws
}

protocol VoicePerformanceSecureChildTerminationSystem: Sendable {
    func processGroupID(pid: Int32) throws -> Int32?
    func generation(pid: Int32) throws
        -> VoicePerformanceSupervisedProcessGeneration?
    func processGroupHasLiveProcesses(processGroupID: Int32) throws -> Bool
    func peekNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome
    func waitNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome
    func signal(
        _ signal: VoicePerformanceTerminationSignal,
        pid: Int32,
        processGroup: VoicePerformanceSpawnProcessGroup
    ) throws
    func currentContinuousNanoseconds() throws -> UInt64
    func sleep(nanoseconds: UInt64) throws
}

struct VoicePerformanceSuspendedChildCodeIdentity: Equatable, Sendable {
    let executablePath: String
    let signingIdentifier: String
    let teamIdentifier: String
    let cdHash: String
    let codeDirectoryFlags: UInt32
    let hasDisallowedEntitlements: Bool
    let isDebugged: Bool
    let developerIDValidated: Bool
    let strictValidation: Bool
}

struct VoicePerformanceSuspendedExecutableFileIdentity: Equatable, Sendable {
    let sha256: String
    let ownerEUID: uid_t
    let mode: mode_t
    let size: UInt64
    let stable: Bool
    let namedPathStable: Bool
    let openedWithoutSymlink: Bool
    let hasExtendedACL: Bool
}

protocol VoicePerformanceSuspendedChildAttestingSystem: Sendable {
    var effectiveUserID: uid_t { get }
    func generation(pid: Int32) throws
        -> VoicePerformanceSupervisedProcessGeneration?
    func executablePath(pid: Int32) throws -> String
    func liveCodeIdentity(
        pid: Int32,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> VoicePerformanceSuspendedChildCodeIdentity
    func executableFileIdentity(
        at executablePath: String,
        maximumBytes: UInt64
    ) throws -> VoicePerformanceSuspendedExecutableFileIdentity
    func resume(pid: Int32) throws
}

public struct VoicePerformanceSecureChildSpawner: Sendable {
    private let system: any VoicePerformanceSecureChildSpawningSystem

    public init() {
        system = DarwinVoicePerformanceSecureChildSpawningSystem()
    }

    init(system: any VoicePerformanceSecureChildSpawningSystem) {
        self.system = system
    }

    @discardableResult
    public func spawnDriver(
        request: VoicePerformanceDriverSpawnRequest,
        supervisedBy supervisor: VoicePerformanceCollectorDriverSupervisor
    ) throws -> VoicePerformanceSupervisedProcessGeneration {
        guard supervisor.driverGeneration == nil else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        let specification = request.specification
        let generation = try system.spawnSuspended(
            specification: specification
        )

        do {
            guard generation.pid > 1,
                generation.startToken > 0,
                generation.processGroupID == generation.pid
            else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
            try system.attestSuspendedChild(
                generation,
                specification: specification
            )
            try supervisor.adoptSpawnedDriverForCleanup(expected: generation)
            try supervisor.prepareDriver(expected: generation)
            try system.resumeSuspendedChild(generation)
            return generation
        } catch {
            let original = normalizedProcessError(error)
            if supervisor.driverGeneration == generation {
                do {
                    try supervisor.abortSpawnedDriver(
                        exactGeneration: generation
                    )
                } catch {
                    try abortUnadoptedChildOrReportCleanupFailure(
                        generation,
                        processGroup: specification.processGroup
                    )
                }
            } else {
                try abortUnadoptedChildOrReportCleanupFailure(
                    generation,
                    processGroup: specification.processGroup
                )
            }
            throw original
        }
    }

    @discardableResult
    public func spawnHelper(
        request: VoicePerformanceHelperSpawnRequest,
        supervisedBy supervisor: VoicePerformanceDriverHelperSupervisor
    ) throws -> VoicePerformanceSupervisedProcessGeneration {
        guard let driver = supervisor.currentDriverGeneration,
            supervisor.activeHelperGeneration == nil,
            driver.pid > 1,
            driver.processGroupID == driver.pid
        else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        let specification = request.specification(
            joining: driver.processGroupID
        )
        let generation = try system.spawnSuspended(
            specification: specification
        )

        do {
            guard generation.pid > 1,
                generation.pid != driver.pid,
                generation.startToken > 0,
                generation.processGroupID == driver.processGroupID
            else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
            try system.attestSuspendedChild(
                generation,
                specification: specification
            )
            try supervisor.adoptSpawnedHelperForCleanup(expected: generation)
            try supervisor.prepareHelper(expected: generation)
            try system.resumeSuspendedChild(generation)
            return generation
        } catch {
            let original = normalizedProcessError(error)
            if supervisor.activeHelperGeneration == generation {
                do {
                    try supervisor.abortSpawnedHelper(
                        exactGeneration: generation
                    )
                } catch {
                    try abortUnadoptedChildOrReportCleanupFailure(
                        generation,
                        processGroup: specification.processGroup
                    )
                }
            } else {
                try abortUnadoptedChildOrReportCleanupFailure(
                    generation,
                    processGroup: specification.processGroup
                )
            }
            throw original
        }
    }

    private func abortUnadoptedChildOrReportCleanupFailure(
        _ generation: VoicePerformanceSupervisedProcessGeneration,
        processGroup: VoicePerformanceSpawnProcessGroup
    ) throws {
        do {
            try system.abortUnadoptedChild(
                generation,
                processGroup: processGroup
            )
        } catch {
            throw VoicePerformanceTracerProcessError.processCleanupFailed
        }
    }
}

struct DarwinVoicePerformanceSecureChildSpawningSystem:
    VoicePerformanceSecureChildSpawningSystem, Sendable
{
    static let spawnFlags = Int16(
        POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_START_SUSPENDED
    )
    private static let pollNanoseconds: UInt64 = 10_000_000
    private static let terminateGraceNanoseconds: UInt64 = 2_000_000_000
    private static let killGraceNanoseconds: UInt64 = 3_000_000_000
    private static let maximumExecutableBytes: UInt64 = 512 * 1_024 * 1_024
    private static let hardenedRuntimeFlag: UInt32 = 0x0001_0000
    private let terminationSystem:
        any VoicePerformanceSecureChildTerminationSystem
    private let attestationSystem:
        any VoicePerformanceSuspendedChildAttestingSystem

    init() {
        terminationSystem = DarwinVoicePerformanceSecureChildTerminationSystem()
        attestationSystem =
            DarwinVoicePerformanceSuspendedChildAttestationSystem()
    }

    init(
        terminationSystem:
            any VoicePerformanceSecureChildTerminationSystem
    ) {
        self.terminationSystem = terminationSystem
        attestationSystem =
            DarwinVoicePerformanceSuspendedChildAttestationSystem()
    }

    init(
        attestationSystem:
            any VoicePerformanceSuspendedChildAttestingSystem
    ) {
        terminationSystem = DarwinVoicePerformanceSecureChildTerminationSystem()
        self.attestationSystem = attestationSystem
    }

    func spawnSuspended(
        specification: VoicePerformanceSecureSpawnSpecification
    ) throws -> VoicePerformanceSupervisedProcessGeneration {
        let pid = try spawnRaw(specification: specification)
        var observedStartToken: UInt64?
        do {
            guard let generation = try attestationSystem.generation(pid: pid),
                generation.pid == pid,
                generation.startToken > 0
            else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
            observedStartToken = generation.startToken
            let expectedProcessGroupID: Int32
            switch specification.processGroup {
            case .new:
                expectedProcessGroupID = pid
            case .existing(let processGroupID):
                expectedProcessGroupID = processGroupID
            }
            guard generation.processGroupID == expectedProcessGroupID else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
            return generation
        } catch {
            let original = normalizedProcessError(error)
            do {
                try abortDirectChild(
                    pid: pid,
                    expectedStartToken: observedStartToken,
                    processGroup: specification.processGroup
                )
            } catch {
                throw VoicePerformanceTracerProcessError.processCleanupFailed
            }
            throw original
        }
    }

    func attestSuspendedChild(
        _ generation: VoicePerformanceSupervisedProcessGeneration,
        specification: VoicePerformanceSecureSpawnSpecification
    ) throws {
        do {
            let expected = specification.expectedChildIdentity
            let expectedProcessGroupID: Int32
            switch specification.processGroup {
            case .new:
                expectedProcessGroupID = generation.pid
            case .existing(let processGroupID):
                expectedProcessGroupID = processGroupID
            }
            guard generation.pid > 1,
                  generation.startToken > 0,
                  generation.processGroupID == expectedProcessGroupID,
                  specification.executablePath.utf8.elementsEqual(
                    expected.executablePath.utf8
                  ),
                  try attestationSystem.generation(pid: generation.pid)
                    == generation,
                  try attestationSystem.executablePath(pid: generation.pid)
                    .utf8.elementsEqual(expected.executablePath.utf8)
            else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }

            let code = try attestationSystem.liveCodeIdentity(
                pid: generation.pid,
                expectedSigningIdentifier: expected.signingIdentifier,
                expectedTeamIdentifier: expected.teamIdentifier
            )
            guard code.executablePath.utf8.elementsEqual(
                      expected.executablePath.utf8
                  ),
                  code.signingIdentifier == expected.signingIdentifier,
                  code.teamIdentifier == expected.teamIdentifier,
                  code.cdHash == expected.cdHash,
                  code.codeDirectoryFlags & Self.hardenedRuntimeFlag != 0,
                  !code.hasDisallowedEntitlements,
                  !code.isDebugged,
                  code.developerIDValidated,
                  code.strictValidation
            else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }

            let file = try attestationSystem.executableFileIdentity(
                at: expected.executablePath,
                maximumBytes: Self.maximumExecutableBytes
            )
            guard file.sha256 == expected.executableSHA256,
                  file.ownerEUID == 0
                    || file.ownerEUID == attestationSystem.effectiveUserID,
                  file.mode & S_IFMT == S_IFREG,
                  file.mode & (S_ISUID | S_ISGID) == 0,
                  file.mode & (S_IWGRP | S_IWOTH) == 0,
                  file.mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0,
                  file.size > 0,
                  file.size <= Self.maximumExecutableBytes,
                  file.stable,
                  file.namedPathStable,
                  file.openedWithoutSymlink,
                  !file.hasExtendedACL,
                  try attestationSystem.executablePath(pid: generation.pid)
                    .utf8.elementsEqual(expected.executablePath.utf8),
                  try attestationSystem.generation(pid: generation.pid)
                    == generation
            else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
        } catch is VoicePerformanceTracerProcessError {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        } catch is VoicePerformancePOSIXError {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
    }

    func resumeSuspendedChild(
        _ generation: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        do {
            guard try attestationSystem.generation(pid: generation.pid)
                == generation
            else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
        } catch is VoicePerformanceTracerProcessError {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        } catch is VoicePerformancePOSIXError {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }
        do {
            try attestationSystem.resume(pid: generation.pid)
        } catch is VoicePerformanceTracerProcessError {
            throw VoicePerformanceTracerProcessError.processSpawnFailed
        } catch is VoicePerformancePOSIXError {
            throw VoicePerformanceTracerProcessError.processSpawnFailed
        }
    }

    func abortUnadoptedChild(
        _ generation: VoicePerformanceSupervisedProcessGeneration,
        processGroup: VoicePerformanceSpawnProcessGroup
    ) throws {
        try abortDirectChild(
            pid: generation.pid,
            expectedStartToken: generation.startToken,
            processGroup: processGroup
        )
    }

    private func spawnRaw(
        specification: VoicePerformanceSecureSpawnSpecification
    ) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw VoicePerformanceTracerProcessError.processSpawnFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw VoicePerformanceTracerProcessError.processSpawnFailed
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let openCodes = "/dev/null".withCString { path in
            [
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    path,
                    O_RDONLY,
                    0
                ),
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDOUT_FILENO,
                    path,
                    O_WRONLY,
                    0
                ),
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDERR_FILENO,
                    path,
                    O_WRONLY,
                    0
                ),
            ]
        }
        guard openCodes.allSatisfy({ $0 == 0 }) else {
            throw VoicePerformanceTracerProcessError.processSpawnFailed
        }

        var signalMask = sigset_t()
        var signalDefaults = sigset_t()
        guard sigemptyset(&signalMask) == 0,
            sigfillset(&signalDefaults) == 0,
            sigdelset(&signalDefaults, SIGKILL) == 0,
            sigdelset(&signalDefaults, SIGSTOP) == 0,
            posix_spawnattr_setsigmask(&attributes, &signalMask) == 0,
            posix_spawnattr_setsigdefault(&attributes, &signalDefaults) == 0
        else {
            throw VoicePerformanceTracerProcessError.processSpawnFailed
        }

        let processGroupID: Int32
        switch specification.processGroup {
        case .new:
            processGroupID = 0
        case .existing(let value):
            guard value > 1 else {
                throw VoicePerformanceTracerProcessError.processSpawnFailed
            }
            processGroupID = value
        }
        guard posix_spawnattr_setpgroup(&attributes, processGroupID) == 0 else {
            throw VoicePerformanceTracerProcessError.processSpawnFailed
        }
        guard posix_spawnattr_setflags(&attributes, Self.spawnFlags) == 0 else {
            throw VoicePerformanceTracerProcessError.processSpawnFailed
        }

        var pid: Int32 = 0
        let result = try withCStringVector(specification.arguments) { argv in
            try withCStringVector(specification.environment) { environment in
                specification.executablePath.withCString { executablePath in
                    posix_spawn(
                        &pid,
                        executablePath,
                        &fileActions,
                        &attributes,
                        argv,
                        environment
                    )
                }
            }
        }
        guard result == 0, pid > 1 else {
            throw VoicePerformanceTracerProcessError.processSpawnFailed
        }
        return pid
    }

    private func abortDirectChild(
        pid: Int32,
        expectedStartToken: UInt64?,
        processGroup: VoicePerformanceSpawnProcessGroup
    ) throws {
        guard pid > 1 else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        let initialAnchor = try directChildAnchor(pid: pid)
        var effectiveProcessGroup = processGroup
        if processGroup == .new {
            let actualProcessGroupID = try terminationSystem
                .processGroupID(pid: pid)
            if actualProcessGroupID == nil {
                let anchoredAfterLookup = initialAnchor.isTerminated
                    ? initialAnchor
                    : try directChildAnchor(pid: pid)
                guard anchoredAfterLookup.isTerminated else {
                    throw VoicePerformanceTracerProcessError
                        .processGroupFailure
                }
            } else if let actualProcessGroupID,
                actualProcessGroupID != pid
            {
                effectiveProcessGroup = .existing(actualProcessGroupID)
            }
        }
        switch effectiveProcessGroup {
        case .new:
            if try !terminationSystem
                .processGroupHasLiveProcesses(processGroupID: pid)
            {
                guard try childHasExited(pid: pid) else {
                    throw VoicePerformanceTracerProcessError
                        .processGroupFailure
                }
                return
            }
        case .existing:
            if initialAnchor.isTerminated {
                guard try childHasExited(pid: pid) else {
                    throw VoicePerformanceTracerProcessError
                        .processGroupFailure
                }
                return
            }
        }
        try verifyCleanupAnchor(
            pid: pid,
            expectedStartToken: expectedStartToken,
            processGroup: effectiveProcessGroup
        )

        try signal(
            .terminate,
            pid: pid,
            processGroup: effectiveProcessGroup
        )
        if try waitForExit(
            pid: pid,
            processGroup: effectiveProcessGroup,
            duration: Self.terminateGraceNanoseconds
        ) {
            return
        }

        try verifyCleanupAnchor(
            pid: pid,
            expectedStartToken: expectedStartToken,
            processGroup: effectiveProcessGroup
        )
        try signal(.kill, pid: pid, processGroup: effectiveProcessGroup)
        guard try waitForExit(
            pid: pid,
            processGroup: effectiveProcessGroup,
            duration: Self.killGraceNanoseconds
        ) else {
            throw VoicePerformanceTracerProcessError.processTerminationTimedOut
        }
    }

    private func directChildAnchor(pid: Int32) throws
        -> VoicePerformanceWaitOutcome
    {
        while true {
            do {
                return try terminationSystem.peekNonBlocking(pid: pid)
            } catch let error as VoicePerformancePOSIXError
                where error.code == EINTR
            {
                continue
            } catch is VoicePerformancePOSIXError {
                throw VoicePerformanceTracerProcessError.processWaitFailed
            }
        }
    }

    private func verifyCleanupAnchor(
        pid: Int32,
        expectedStartToken: UInt64?,
        processGroup: VoicePerformanceSpawnProcessGroup
    ) throws {
        let anchor = try directChildAnchor(pid: pid)
        if anchor.isTerminated { return }

        let expectedProcessGroupID: Int32
        switch processGroup {
        case .new:
            expectedProcessGroupID = pid
        case .existing(let value):
            expectedProcessGroupID = value
        }
        guard let expectedStartToken else {
            guard try terminationSystem.processGroupID(pid: pid)
                == expectedProcessGroupID
            else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
            return
        }
        if let generation = try terminationSystem.generation(pid: pid) {
            guard generation.pid == pid,
                generation.startToken == expectedStartToken,
                generation.processGroupID == expectedProcessGroupID
            else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
            return
        }

        // The leader can transition to a zombie between the WNOWAIT peek and
        // the rusage/pgrp generation sandwich. A second WNOWAIT observation
        // keeps its PID unreaped, which safely anchors the owned process group.
        guard try directChildAnchor(pid: pid).isTerminated else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }
    }

    private func signal(
        _ signal: VoicePerformanceTerminationSignal,
        pid: Int32,
        processGroup: VoicePerformanceSpawnProcessGroup
    ) throws {
        do {
            try terminationSystem.signal(
                signal,
                pid: pid,
                processGroup: processGroup
            )
        } catch is VoicePerformanceTracerProcessError {
            throw VoicePerformanceTracerProcessError.processGroupFailure
        } catch is VoicePerformancePOSIXError {
            throw VoicePerformanceTracerProcessError.processGroupFailure
        }
    }

    private func waitForExit(
        pid: Int32,
        processGroup: VoicePerformanceSpawnProcessGroup,
        duration: UInt64
    ) throws -> Bool {
        let start = try terminationSystem.currentContinuousNanoseconds()
        let (deadline, overflow) = start.addingReportingOverflow(duration)
        guard !overflow else {
            throw VoicePerformanceTracerProcessError.processWaitFailed
        }
        while true {
            switch processGroup {
            case .new:
                if try !terminationSystem
                    .processGroupHasLiveProcesses(processGroupID: pid)
                {
                    return try childHasExited(pid: pid)
                }
            case .existing:
                if try childHasExited(pid: pid) { return true }
            }
            let now = try terminationSystem.currentContinuousNanoseconds()
            guard now < deadline else { return false }
            try terminationSystem.sleep(
                nanoseconds: min(Self.pollNanoseconds, deadline - now)
            )
        }
    }

    private func childHasExited(pid: Int32) throws -> Bool {
        while true {
            do {
                return try terminationSystem.waitNonBlocking(pid: pid)
                    .isTerminated
            } catch let error as VoicePerformancePOSIXError
                where error.code == EINTR
            {
                continue
            } catch let error as VoicePerformancePOSIXError
                where error.code == ECHILD
            {
                return true
            } catch is VoicePerformancePOSIXError {
                throw VoicePerformanceTracerProcessError.processWaitFailed
            }
        }
    }
}

private extension VoicePerformanceWaitOutcome {
    var isTerminated: Bool {
        switch self {
        case .running:
            false
        case .exited, .signaled:
            true
        }
    }
}

private struct DarwinVoicePerformanceSuspendedChildAttestationSystem:
    VoicePerformanceSuspendedChildAttestingSystem, Sendable
{
    private struct StableFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let ownerEUID: uid_t
        let ownerGroupID: gid_t
        let mode: mode_t
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    private static let debuggedFlag: UInt32 = 0x1000_0000
    private let processSystem = DarwinVoicePerformanceProcessGroupSystem()

    var effectiveUserID: uid_t { Darwin.geteuid() }

    func generation(pid: Int32) throws
        -> VoicePerformanceSupervisedProcessGeneration?
    {
        try processSystem.generation(pid: pid)
    }

    func executablePath(pid: Int32) throws -> String {
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var count: Int32 = -1
        repeat {
            count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
        } while count < 0 && errno == EINTR
        guard count > 1,
              Int(count) < bytes.count,
              bytes[Int(count)] == 0,
              !bytes[..<Int(count)].contains(0),
              let path = String(
                  bytes: bytes[..<Int(count)].map(UInt8.init(bitPattern:)),
                  encoding: .utf8
              ),
              rimeaiIsCanonicalAbsoluteExecutablePath(path)
        else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }
        return path
    }

    func liveCodeIdentity(
        pid: Int32,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> VoicePerformanceSuspendedChildCodeIdentity {
        guard pid > 1 else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }
        let attributes = NSDictionary(
            object: NSNumber(value: pid),
            forKey: NSString(string: kSecGuestAttributePid as String)
        )
        var liveCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &liveCode
        ) == errSecSuccess,
              let liveCode
        else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }

        let requirement = try developerIDRequirement(
            signingIdentifier: expectedSigningIdentifier,
            teamIdentifier: expectedTeamIdentifier
        )
        guard SecCodeCheckValidity(
            liveCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement
        ) == errSecSuccess
        else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            liveCode,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(
                      rawValue:
                          kSecCSStrictValidate | kSecCSCheckAllArchitectures
                  ),
                  requirement
              ) == errSecSuccess
        else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }

        // Security accepts a dynamic SecCode for signing information, while
        // Swift imports the parameter using the nominal SecStaticCode type.
        let signingInformationCode = unsafeBitCast(
            liveCode,
            to: SecStaticCode.self
        )
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(
            signingInformationCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &dictionary
        ) == errSecSuccess,
              let information = dictionary as? [CFString: Any],
              let executableURL =
                information[kSecCodeInfoMainExecutable] as? URL,
              let signingIdentifier =
                information[kSecCodeInfoIdentifier] as? String,
              let teamIdentifier =
                information[kSecCodeInfoTeamIdentifier] as? String,
              let unique = information[kSecCodeInfoUnique] as? Data,
              unique.count == 20,
              let flags = information[kSecCodeInfoFlags] as? NSNumber
        else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }

        let entitlementData =
            information[kSecCodeInfoEntitlements] as? Data
        let entitlementDictionary =
            information[kSecCodeInfoEntitlementsDict] as? [String: Any]
        let hasMalformedEntitlements = entitlementData != nil
            && entitlementDictionary == nil
        let hasEffectiveEntitlements = entitlementDictionary?.contains {
            _, value in
            if let boolean = value as? Bool { return boolean }
            if let number = value as? NSNumber { return number.boolValue }
            return true
        } ?? false

        var dynamicStatus: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &dynamicStatus) { pointer in
            rimeaiSuspendedChildCSOps(
                pid,
                0, // CS_OPS_STATUS from XNU bsd/sys/codesign.h.
                UnsafeMutableRawPointer(pointer),
                MemoryLayout<UInt32>.size
            )
        }
        guard status == 0 else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }

        return VoicePerformanceSuspendedChildCodeIdentity(
            executablePath: executableURL.path,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            cdHash: unique.map { String(format: "%02x", $0) }.joined(),
            codeDirectoryFlags: flags.uint32Value,
            hasDisallowedEntitlements:
                hasMalformedEntitlements || hasEffectiveEntitlements,
            isDebugged: dynamicStatus & Self.debuggedFlag != 0,
            developerIDValidated: true,
            strictValidation: true
        )
    }

    func executableFileIdentity(
        at executablePath: String,
        maximumBytes: UInt64
    ) throws -> VoicePerformanceSuspendedExecutableFileIdentity {
        var descriptor: Int32 = -1
        repeat {
            descriptor = Darwin.open(
                executablePath,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        } while descriptor < 0 && errno == EINTR
        guard descriptor >= 0 else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }
        defer { _ = Darwin.close(descriptor) }

        let before = try stableStat(descriptor)
        let namedBefore = try stableStat(path: executablePath)
        guard before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0,
              UInt64(before.st_size) <= maximumBytes,
              fileIdentity(before) == fileIdentity(namedBefore)
        else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }
        let hasExtendedACL = try extendedACLIsPresent(descriptor)
        let sha256 = try sha256ToEnd(
            descriptor,
            expectedSize: UInt64(before.st_size),
            maximumBytes: maximumBytes
        )
        let after = try stableStat(descriptor)
        let namedAfter = try stableStat(path: executablePath)
        let beforeIdentity = fileIdentity(before)
        let afterIdentity = fileIdentity(after)
        let namedBeforeIdentity = fileIdentity(namedBefore)
        let namedAfterIdentity = fileIdentity(namedAfter)
        return VoicePerformanceSuspendedExecutableFileIdentity(
            sha256: sha256,
            ownerEUID: after.st_uid,
            mode: after.st_mode,
            size: UInt64(after.st_size),
            stable: beforeIdentity == afterIdentity,
            namedPathStable:
                beforeIdentity == namedBeforeIdentity
                    && beforeIdentity == namedAfterIdentity,
            openedWithoutSymlink: true,
            hasExtendedACL: hasExtendedACL
        )
    }

    func resume(pid: Int32) throws {
        guard pid > 1 else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        while Darwin.kill(pid, SIGCONT) != 0 {
            if errno == EINTR { continue }
            throw VoicePerformancePOSIXError(code: errno)
        }
    }

    private func developerIDRequirement(
        signingIdentifier: String,
        teamIdentifier: String
    ) throws -> SecRequirement {
        let text = "anchor apple generic"
            + " and identifier \"\(signingIdentifier)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            text as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
              let requirement
        else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }
        return requirement
    }

    private func stableStat(_ descriptor: Int32) throws -> stat {
        var value = stat()
        var status: Int32 = -1
        repeat {
            status = Darwin.fstat(descriptor, &value)
        } while status != 0 && errno == EINTR
        guard status == 0 else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }
        return value
    }

    private func stableStat(path: String) throws -> stat {
        var value = stat()
        var status: Int32 = -1
        repeat {
            status = Darwin.lstat(path, &value)
        } while status != 0 && errno == EINTR
        guard status == 0 else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }
        return value
    }

    private func extendedACLIsPresent(_ descriptor: Int32) throws -> Bool {
        errno = 0
        if let acl = Darwin.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
            Darwin.acl_free(UnsafeMutableRawPointer(acl))
            return true
        }
        guard errno == ENOENT else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }
        return false
    }

    private func sha256ToEnd(
        _ descriptor: Int32,
        expectedSize: UInt64,
        maximumBytes: UInt64
    ) throws -> String {
        guard #available(macOS 10.15, *) else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }
        guard expectedSize > 0,
              expectedSize <= maximumBytes
        else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }
        var hasher = SHA256()
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            var copied: Int = -1
            repeat {
                copied = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
            } while copied < 0 && errno == EINTR
            guard copied >= 0 else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
            if copied == 0 { break }
            let byteCount = UInt64(copied)
            guard byteCount <= expectedSize,
                  byteCount <= maximumBytes,
                  total <= expectedSize - byteCount,
                  total <= maximumBytes - byteCount
            else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
            total += byteCount
            hasher.update(data: Data(buffer[..<copied]))
        }
        guard total == expectedSize else {
            throw VoicePerformanceTracerProcessError
                .processGenerationMismatch
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func fileIdentity(_ value: stat) -> StableFileIdentity {
        StableFileIdentity(
            device: UInt64(bitPattern: Int64(value.st_dev)),
            inode: UInt64(value.st_ino),
            size: UInt64(value.st_size),
            ownerEUID: value.st_uid,
            ownerGroupID: value.st_gid,
            mode: value.st_mode,
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }
}

private struct DarwinVoicePerformanceSecureChildTerminationSystem:
    VoicePerformanceSecureChildTerminationSystem, Sendable
{
    private let processSystem = DarwinVoicePerformanceProcessGroupSystem()

    func processGroupID(pid: Int32) throws -> Int32? {
        while true {
            errno = 0
            let value = Darwin.getpgid(pid)
            if value >= 0 { return value }
            if errno == EINTR { continue }
            if errno == ESRCH { return nil }
            throw VoicePerformancePOSIXError(code: errno)
        }
    }

    func generation(pid: Int32) throws
        -> VoicePerformanceSupervisedProcessGeneration?
    {
        try processSystem.generation(pid: pid)
    }

    func processGroupHasLiveProcesses(processGroupID: Int32) throws -> Bool {
        try processSystem.processGroupHasLiveProcesses(
            processGroupID: processGroupID
        )
    }

    func peekNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        try processSystem.peekNonBlocking(pid: pid)
    }

    func waitNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        try processSystem.waitNonBlocking(pid: pid)
    }

    func signal(
        _ signal: VoicePerformanceTerminationSignal,
        pid: Int32,
        processGroup: VoicePerformanceSpawnProcessGroup
    ) throws {
        let rawSignal = signal == .terminate ? SIGTERM : SIGKILL
        let target: Int32
        switch processGroup {
        case .new:
            target = -pid
        case .existing:
            target = pid
        }
        while Darwin.kill(target, rawSignal) != 0 {
            if errno == EINTR { continue }
            if errno == ESRCH { return }
            throw VoicePerformancePOSIXError(code: errno)
        }
    }

    func currentContinuousNanoseconds() throws -> UInt64 {
        try VoicePerformanceContinuousDeadline.currentNanoseconds()
    }

    func sleep(nanoseconds: UInt64) throws {
        try processSystem.sleep(nanoseconds: nanoseconds)
    }
}

private func withCStringVector<Result>(
    _ strings: [String],
    _ body: (
        UnsafePointer<UnsafeMutablePointer<CChar>?>
    ) throws -> Result
) throws -> Result {
    var allocated: [UnsafeMutablePointer<CChar>] = []
    defer { allocated.forEach { Darwin.free($0) } }
    for string in strings {
        guard let pointer = Darwin.strdup(string) else {
            throw VoicePerformanceTracerProcessError.processSpawnFailed
        }
        allocated.append(pointer)
    }
    var pointers: [UnsafeMutablePointer<CChar>?] = allocated.map(Optional.some)
    pointers.append(nil)
    return try pointers.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            throw VoicePerformanceTracerProcessError.processSpawnFailed
        }
        return try body(baseAddress)
    }
}

private func normalizedProcessError(_ error: Error) -> Error {
    if let processError = error as? VoicePerformanceTracerProcessError {
        return processError
    }
    if error is VoicePerformancePOSIXError {
        return VoicePerformanceTracerProcessError.processSpawnFailed
    }
    return error
}
