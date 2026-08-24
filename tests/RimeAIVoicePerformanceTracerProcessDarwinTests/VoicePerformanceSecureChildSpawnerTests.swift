import Darwin
import Foundation
import Testing
@testable import RimeAIVoicePerformanceTracerProcessDarwin

enum SuspendedAttestationMismatch: CaseIterable, Sendable {
    case firstGeneration
    case firstPath
    case liveCodePath
    case signingIdentity
    case teamIdentity
    case cdHash
    case developerID
    case strictValidation
    case hardenedRuntime
    case entitlements
    case debugged
    case fileSHA256
    case fileOwner
    case fileMode
    case fileSize
    case unstableFile
    case replacedNamedPath
    case symlink
    case extendedACL
    case secondPath
    case secondGeneration
}

enum CanonicallyEquivalentPathObservation: CaseIterable, Sendable {
    case firstLiveExecutablePath
    case liveCodeExecutablePath
    case secondLiveExecutablePath
}

@Suite("Secure atomic tracer child spawning")
struct VoicePerformanceSecureChildSpawnerTests {
    @Test("driver spawn uses frozen argv, fixed environment, and a new pgrp")
    func driverSpawnIsExactAndAtomicallyGrouped() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let generation = VoicePerformanceSupervisedProcessGeneration(
            pid: 3_001,
            startToken: 30_001,
            processGroupID: 3_001
        )
        let spawnSystem = RecordingSecureSpawnSystem(next: generation)
        let processSystem = SecureSpawnSupervisorSystem(
            currentPID: 3_000,
            generations: [3_001: generation]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(
            system: processSystem
        )
        let expectedChildIdentity = try VoicePerformanceExpectedChildIdentity(
            executablePath: bundle
                + VoicePerformanceTracerBundleLayout.driverExecutableSuffix,
            executableSHA256: String(repeating: "a", count: 64),
            signingIdentifier:
                "fun.wwcn.rimeai.voice-performance-driver",
            teamIdentifier: "A1B2C3D4E5",
            cdHash: String(repeating: "b", count: 40)
        )
        let request = try VoicePerformanceDriverSpawnRequest(
            tracerBundlePath: bundle,
            expectedChildIdentity: expectedChildIdentity,
            deadline: .init(nanoseconds: 44_000)
        )

        let spawned = try VoicePerformanceSecureChildSpawner(
            system: spawnSystem
        ).spawnDriver(request: request, supervisedBy: supervisor)

        #expect(spawned == generation)
        #expect(spawnSystem.specifications.count == 1)
        #expect(
            spawnSystem.specifications[0].executablePath
                == bundle
                    + VoicePerformanceTracerBundleLayout.driverExecutableSuffix
        )
        #expect(
            spawnSystem.specifications[0].arguments == [
                bundle
                    + VoicePerformanceTracerBundleLayout.driverExecutableSuffix,
                "--tracer-bundle", bundle,
                "--deadline-continuous-ns", "44000",
            ]
        )
        #expect(spawnSystem.specifications[0].processGroup == .new)
        #expect(
            spawnSystem.specifications[0].expectedChildIdentity
                == expectedChildIdentity
        )
        #expect(
            spawnSystem.specifications[0].environment
                == ["LANG=C", "LC_ALL=C", "PATH=/usr/bin:/bin"]
        )
        #expect(supervisor.driverGeneration == generation)
        #expect(processSystem.groupChanges.isEmpty)
        #expect(
            spawnSystem.events
                == ["spawn-suspended", "attest", "resume"]
        )
    }

    @Test("helper spawn joins only the bound driver pgrp with frozen argv")
    func helperSpawnIsExactAndAtomicallyGrouped() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let driver = generation(pid: 3_101, start: 31_001, group: 3_101)
        let helper = generation(pid: 3_102, start: 31_002, group: 3_101)
        let spawnSystem = RecordingSecureSpawnSystem(next: helper)
        let processSystem = SecureSpawnSupervisorSystem(
            currentPID: 3_101,
            generations: [3_101: driver, 3_102: helper]
        )
        let supervisor = VoicePerformanceDriverHelperSupervisor(
            system: processSystem
        )
        try supervisor.bindCurrentDriver(expected: driver)
        let request = try VoicePerformanceHelperSpawnRequest(
            tracerBundlePath: bundle,
            trial: 2,
            policyColdTrials: 3,
            expectedChildIdentity: try expectedHelperIdentity(bundle),
            deadline: .init(nanoseconds: 55_000)
        )

        let spawned = try VoicePerformanceSecureChildSpawner(
            system: spawnSystem
        ).spawnHelper(request: request, supervisedBy: supervisor)

        #expect(spawned == helper)
        #expect(spawnSystem.specifications[0].processGroup == .existing(3_101))
        #expect(
            spawnSystem.specifications[0].arguments == [
                bundle
                    + VoicePerformanceTracerBundleLayout.helperExecutableSuffix,
                "--tracer-bundle", bundle, "--trial", "2",
                "--deadline-continuous-ns", "55000",
            ]
        )
        #expect(supervisor.activeHelperGeneration == helper)
        #expect(processSystem.groupChanges.isEmpty)
    }

    @Test("attestation failure never resumes and aborts the suspended child")
    func attestationFailureNeverResumesAndCleansUp() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let generation = generation(pid: 3_151, start: 31_051, group: 3_151)
        let spawnSystem = RecordingSecureSpawnSystem(next: generation)
        spawnSystem.attestationError = VoicePerformanceTracerProcessError
            .processGenerationMismatch
        let processSystem = SecureSpawnSupervisorSystem(
            currentPID: 3_150,
            generations: [generation.pid: generation]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(
            system: processSystem
        )
        let request = try VoicePerformanceDriverSpawnRequest(
            tracerBundlePath: bundle,
            expectedChildIdentity: try expectedDriverIdentity(bundle),
            deadline: .init(nanoseconds: 55_100)
        )

        #expect(
            throws:
                VoicePerformanceTracerProcessError.processGenerationMismatch
        ) {
            try VoicePerformanceSecureChildSpawner(system: spawnSystem)
                .spawnDriver(request: request, supervisedBy: supervisor)
        }

        #expect(spawnSystem.events == ["spawn-suspended", "attest"])
        #expect(spawnSystem.aborted == [generation])
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("resume failure aborts the adopted suspended child")
    func resumeFailureCleansUp() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let generation = generation(pid: 3_152, start: 31_052, group: 3_152)
        let spawnSystem = RecordingSecureSpawnSystem(next: generation)
        spawnSystem.resumeError = VoicePerformanceTracerProcessError
            .processSpawnFailed
        let processSystem = SecureSpawnSupervisorSystem(
            currentPID: 3_150,
            generations: [generation.pid: generation]
        )
        processSystem.waitOutcomes = [.exited(code: 0)]
        let supervisor = VoicePerformanceCollectorDriverSupervisor(
            system: processSystem
        )
        let request = try VoicePerformanceDriverSpawnRequest(
            tracerBundlePath: bundle,
            expectedChildIdentity: try expectedDriverIdentity(bundle),
            deadline: .init(nanoseconds: 55_200)
        )

        #expect(throws: VoicePerformanceTracerProcessError.processSpawnFailed) {
            try VoicePerformanceSecureChildSpawner(system: spawnSystem)
                .spawnDriver(request: request, supervisedBy: supervisor)
        }

        #expect(
            spawnSystem.events
                == ["spawn-suspended", "attest", "resume"]
        )
        #expect(spawnSystem.aborted.isEmpty)
        #expect(processSystem.waitOutcomes.isEmpty)
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("opaque attestation failure survives successful raw child cleanup")
    func opaqueAttestationFailureIsPreservedAfterCleanup() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let generation = generation(pid: 3_157, start: 31_057, group: 3_157)
        let unexpected = SecureSpawnUnexpectedError(
            description: "spawn-attestation-secret-110f"
        )
        let spawnSystem = RecordingSecureSpawnSystem(next: generation)
        spawnSystem.attestationError = unexpected
        let supervisor = VoicePerformanceCollectorDriverSupervisor(
            system: SecureSpawnSupervisorSystem(
                currentPID: 3_150,
                generations: [generation.pid: generation]
            )
        )
        let request = try VoicePerformanceDriverSpawnRequest(
            tracerBundlePath: bundle,
            expectedChildIdentity: try expectedDriverIdentity(bundle),
            deadline: .init(nanoseconds: 55_300)
        )

        #expect(throws: unexpected) {
            try VoicePerformanceSecureChildSpawner(system: spawnSystem)
                .spawnDriver(request: request, supervisedBy: supervisor)
        }
        #expect(spawnSystem.aborted == [generation])
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("opaque resume failure survives successful supervisor cleanup")
    func opaqueResumeFailureIsPreservedAfterCleanup() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let generation = generation(pid: 3_158, start: 31_058, group: 3_158)
        let unexpected = SecureSpawnUnexpectedError(
            description: "spawn-resume-secret-4a2d"
        )
        let spawnSystem = RecordingSecureSpawnSystem(next: generation)
        spawnSystem.resumeError = unexpected
        let processSystem = SecureSpawnSupervisorSystem(
            currentPID: 3_150,
            generations: [generation.pid: generation]
        )
        processSystem.waitOutcomes = [.exited(code: 0)]
        let supervisor = VoicePerformanceCollectorDriverSupervisor(
            system: processSystem
        )
        let request = try VoicePerformanceDriverSpawnRequest(
            tracerBundlePath: bundle,
            expectedChildIdentity: try expectedDriverIdentity(bundle),
            deadline: .init(nanoseconds: 55_400)
        )

        #expect(throws: unexpected) {
            try VoicePerformanceSecureChildSpawner(system: spawnSystem)
                .spawnDriver(request: request, supervisedBy: supervisor)
        }
        #expect(spawnSystem.aborted.isEmpty)
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("cleanup failure overrides an opaque primary spawn failure")
    func cleanupFailureOverridesOpaquePrimary() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let generation = generation(pid: 3_159, start: 31_059, group: 3_159)
        let spawnSystem = RecordingSecureSpawnSystem(next: generation)
        spawnSystem.attestationError = SecureSpawnUnexpectedError(
            description: "spawn-primary-secret-c48a"
        )
        spawnSystem.abortError = VoicePerformanceTracerProcessError
            .processWaitFailed
        let supervisor = VoicePerformanceCollectorDriverSupervisor(
            system: SecureSpawnSupervisorSystem(
                currentPID: 3_150,
                generations: [generation.pid: generation]
            )
        )
        let request = try VoicePerformanceDriverSpawnRequest(
            tracerBundlePath: bundle,
            expectedChildIdentity: try expectedDriverIdentity(bundle),
            deadline: .init(nanoseconds: 55_500)
        )

        #expect(throws: VoicePerformanceTracerProcessError.processCleanupFailed) {
            try VoicePerformanceSecureChildSpawner(system: spawnSystem)
                .spawnDriver(request: request, supervisedBy: supervisor)
        }
        #expect(spawnSystem.aborted == [generation])
    }

    @Test("production spawn flags always start the child suspended")
    func productionFlagsIncludeStartSuspended() {
        #expect(
            DarwinVoicePerformanceSecureChildSpawningSystem.spawnFlags
                & Int16(POSIX_SPAWN_START_SUSPENDED) != 0
        )
    }

    @Test("expected child identity preserves a physical private-tmp path")
    func expectedChildIdentityAcceptsPhysicalPrivateTemporaryPath() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ).appendingPathComponent(
            "rimeai-spawn-path-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("driver")
        #expect(
            FileManager.default.createFile(
                atPath: executable.path,
                contents: Data()
            )
        )
        #expect(executable.standardizedFileURL.path != executable.path)

        let identity = try VoicePerformanceExpectedChildIdentity(
            executablePath: executable.path,
            executableSHA256: String(repeating: "a", count: 64),
            signingIdentifier:
                "fun.wwcn.rimeai.voice-performance-driver",
            teamIdentifier: "A1B2C3D4E5",
            cdHash: String(repeating: "b", count: 40)
        )

        #expect(
            identity.executablePath.utf8.elementsEqual(executable.path.utf8)
        )
    }

    @Test("production attestation sandwiches every child identity check")
    func productionAttestationUsesExactIdentitySandwich() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let identity = try expectedDriverIdentity(bundle)
        let generation = generation(pid: 3_153, start: 31_053, group: 3_153)
        let attestation = ScriptedSuspendedChildAttestationSystem(
            effectiveUserID: 501,
            generations: [generation, generation],
            executablePaths: [identity.executablePath, identity.executablePath],
            codeIdentity: .init(
                executablePath: identity.executablePath,
                signingIdentifier: identity.signingIdentifier,
                teamIdentifier: identity.teamIdentifier,
                cdHash: identity.cdHash,
                codeDirectoryFlags: 0x0001_0000,
                hasDisallowedEntitlements: false,
                isDebugged: false,
                developerIDValidated: true,
                strictValidation: true
            ),
            fileIdentity: .init(
                sha256: identity.executableSHA256,
                ownerEUID: 501,
                mode: S_IFREG | S_IRUSR | S_IXUSR,
                size: 4_096,
                stable: true,
                namedPathStable: true,
                openedWithoutSymlink: true,
                hasExtendedACL: false
            )
        )
        let specification = VoicePerformanceSecureSpawnSpecification(
            executablePath: identity.executablePath,
            arguments: [identity.executablePath],
            processGroup: .new,
            expectedChildIdentity: identity
        )

        try DarwinVoicePerformanceSecureChildSpawningSystem(
            attestationSystem: attestation
        ).attestSuspendedChild(generation, specification: specification)

        #expect(attestation.events == [
            "generation",
            "path",
            "live-code",
            "file",
            "path",
            "generation",
        ])
    }

    @Test(
        "canonically equivalent live paths with different UTF-8 bytes are rejected",
        arguments: CanonicallyEquivalentPathObservation.allCases
    )
    func productionAttestationRequiresByteExactAuthorityPaths(
        _ observation: CanonicallyEquivalentPathObservation
    ) throws {
        let bundle = "/Applications/Rim\u{00E9}AI Voice Performance.bundle"
        let identity = try expectedDriverIdentity(bundle)
        let decomposedPath =
            identity.executablePath.decomposedStringWithCanonicalMapping
        #expect(decomposedPath == identity.executablePath)
        #expect(
            !decomposedPath.utf8.elementsEqual(identity.executablePath.utf8)
        )

        let generation = generation(pid: 3_155, start: 31_055, group: 3_155)
        var executablePaths = [
            identity.executablePath,
            identity.executablePath,
        ]
        var codeIdentity = validCodeIdentity(identity)
        switch observation {
        case .firstLiveExecutablePath:
            executablePaths[0] = decomposedPath
        case .liveCodeExecutablePath:
            codeIdentity = .init(
                executablePath: decomposedPath,
                signingIdentifier: codeIdentity.signingIdentifier,
                teamIdentifier: codeIdentity.teamIdentifier,
                cdHash: codeIdentity.cdHash,
                codeDirectoryFlags: codeIdentity.codeDirectoryFlags,
                hasDisallowedEntitlements:
                    codeIdentity.hasDisallowedEntitlements,
                isDebugged: codeIdentity.isDebugged,
                developerIDValidated: codeIdentity.developerIDValidated,
                strictValidation: codeIdentity.strictValidation
            )
        case .secondLiveExecutablePath:
            executablePaths[1] = decomposedPath
        }
        let attestation = ScriptedSuspendedChildAttestationSystem(
            effectiveUserID: 501,
            generations: [generation, generation],
            executablePaths: executablePaths,
            codeIdentity: codeIdentity,
            fileIdentity: validFileIdentity(identity)
        )
        let specification = VoicePerformanceSecureSpawnSpecification(
            executablePath: identity.executablePath,
            arguments: [identity.executablePath],
            processGroup: .new,
            expectedChildIdentity: identity
        )

        #expect(
            throws:
                VoicePerformanceTracerProcessError.processGenerationMismatch
        ) {
            try DarwinVoicePerformanceSecureChildSpawningSystem(
                attestationSystem: attestation
            ).attestSuspendedChild(
                generation,
                specification: specification
            )
        }
        #expect(attestation.resumedPIDs.isEmpty)
    }

    @Test(
        "every failed suspended-child identity check rejects the generation",
        arguments: SuspendedAttestationMismatch.allCases
    )
    func productionAttestationRejectsEveryMismatch(
        _ mismatch: SuspendedAttestationMismatch
    ) throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let identity = try expectedDriverIdentity(bundle)
        let generation = generation(pid: 3_154, start: 31_054, group: 3_154)
        let wrongGeneration = self.generation(
            pid: generation.pid,
            start: generation.startToken + 1,
            group: generation.processGroupID
        )
        var generations = [generation, generation]
        var paths = [identity.executablePath, identity.executablePath]
        var codePath = identity.executablePath
        var signingIdentifier = identity.signingIdentifier
        var teamIdentifier = identity.teamIdentifier
        var cdHash = identity.cdHash
        var developerIDValidated = true
        var strictValidation = true
        var codeDirectoryFlags: UInt32 = 0x0001_0000
        var hasDisallowedEntitlements = false
        var isDebugged = false
        var sha256 = identity.executableSHA256
        var ownerEUID: uid_t = 501
        var mode = mode_t(S_IFREG | S_IRUSR | S_IXUSR)
        var size: UInt64 = 4_096
        var stable = true
        var namedPathStable = true
        var openedWithoutSymlink = true
        var hasExtendedACL = false
        switch mismatch {
        case .firstGeneration:
            generations[0] = wrongGeneration
        case .firstPath:
            paths[0] += ".lookalike"
        case .liveCodePath:
            codePath += ".lookalike"
        case .signingIdentity:
            signingIdentifier += ".lookalike"
        case .teamIdentity:
            teamIdentifier = "Z9Y8X7W6V5"
        case .cdHash:
            cdHash = String(repeating: "e", count: 40)
        case .developerID:
            developerIDValidated = false
        case .strictValidation:
            strictValidation = false
        case .hardenedRuntime:
            codeDirectoryFlags = 0
        case .entitlements:
            hasDisallowedEntitlements = true
        case .debugged:
            isDebugged = true
        case .fileSHA256:
            sha256 = String(repeating: "e", count: 64)
        case .fileOwner:
            ownerEUID = 502
        case .fileMode:
            mode |= S_IWOTH
        case .fileSize:
            size = 0
        case .unstableFile:
            stable = false
        case .replacedNamedPath:
            namedPathStable = false
        case .symlink:
            openedWithoutSymlink = false
        case .extendedACL:
            hasExtendedACL = true
        case .secondPath:
            paths[1] += ".lookalike"
        case .secondGeneration:
            generations[1] = wrongGeneration
        }
        let attestation = ScriptedSuspendedChildAttestationSystem(
            effectiveUserID: 501,
            generations: generations,
            executablePaths: paths,
            codeIdentity: .init(
                executablePath: codePath,
                signingIdentifier: signingIdentifier,
                teamIdentifier: teamIdentifier,
                cdHash: cdHash,
                codeDirectoryFlags: codeDirectoryFlags,
                hasDisallowedEntitlements: hasDisallowedEntitlements,
                isDebugged: isDebugged,
                developerIDValidated: developerIDValidated,
                strictValidation: strictValidation
            ),
            fileIdentity: .init(
                sha256: sha256,
                ownerEUID: ownerEUID,
                mode: mode,
                size: size,
                stable: stable,
                namedPathStable: namedPathStable,
                openedWithoutSymlink: openedWithoutSymlink,
                hasExtendedACL: hasExtendedACL
            )
        )
        let specification = VoicePerformanceSecureSpawnSpecification(
            executablePath: identity.executablePath,
            arguments: [identity.executablePath],
            processGroup: .new,
            expectedChildIdentity: identity
        )

        #expect(
            throws:
                VoicePerformanceTracerProcessError.processGenerationMismatch
        ) {
            try DarwinVoicePerformanceSecureChildSpawningSystem(
                attestationSystem: attestation
            ).attestSuspendedChild(
                generation,
                specification: specification
            )
        }
        #expect(attestation.resumedPIDs.isEmpty)
    }

    @Test("production resume rechecks the exact generation before SIGCONT")
    func productionResumeRequiresExactGeneration() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let identity = try expectedDriverIdentity(bundle)
        let generation = generation(pid: 3_155, start: 31_055, group: 3_155)
        let wrongGeneration = self.generation(
            pid: generation.pid,
            start: generation.startToken + 1,
            group: generation.processGroupID
        )
        let attestation = ScriptedSuspendedChildAttestationSystem(
            effectiveUserID: 501,
            generations: [wrongGeneration],
            executablePaths: [],
            codeIdentity: validCodeIdentity(identity),
            fileIdentity: validFileIdentity(identity)
        )

        #expect(
            throws:
                VoicePerformanceTracerProcessError.processGenerationMismatch
        ) {
            try DarwinVoicePerformanceSecureChildSpawningSystem(
                attestationSystem: attestation
            ).resumeSuspendedChild(generation)
        }

        #expect(attestation.events == ["generation"])
        #expect(attestation.resumedPIDs.isEmpty)
    }

    @Test("production resume sends SIGCONT after the exact generation recheck")
    func productionResumeSignalsOnlyExactGeneration() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let identity = try expectedDriverIdentity(bundle)
        let generation = generation(pid: 3_156, start: 31_056, group: 3_156)
        let attestation = ScriptedSuspendedChildAttestationSystem(
            effectiveUserID: 501,
            generations: [generation],
            executablePaths: [],
            codeIdentity: validCodeIdentity(identity),
            fileIdentity: validFileIdentity(identity)
        )

        try DarwinVoicePerformanceSecureChildSpawningSystem(
            attestationSystem: attestation
        ).resumeSuspendedChild(generation)

        #expect(attestation.events == ["generation", "resume"])
        #expect(attestation.resumedPIDs == [generation.pid])
    }

    @Test("concrete suspended attestation preserves opaque system failures")
    func productionAttestationPreservesOpaqueSystemFailure() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let identity = try expectedDriverIdentity(bundle)
        let generation = generation(pid: 3_160, start: 31_060, group: 3_160)
        let unexpected = SecureSpawnUnexpectedError(
            description: "concrete-attestation-secret-df02"
        )
        let attestation = ScriptedSuspendedChildAttestationSystem(
            effectiveUserID: 501,
            generations: [generation, generation],
            executablePaths: [identity.executablePath, identity.executablePath],
            codeIdentity: validCodeIdentity(identity),
            fileIdentity: validFileIdentity(identity),
            unexpectedErrorAtEvent: "generation",
            unexpectedError: unexpected
        )
        let specification = VoicePerformanceSecureSpawnSpecification(
            executablePath: identity.executablePath,
            arguments: [identity.executablePath],
            processGroup: .new,
            expectedChildIdentity: identity
        )

        #expect(throws: unexpected) {
            try DarwinVoicePerformanceSecureChildSpawningSystem(
                attestationSystem: attestation
            ).attestSuspendedChild(generation, specification: specification)
        }
        #expect(attestation.resumedPIDs.isEmpty)
    }

    @Test("concrete resume preserves opaque generation probe failures")
    func productionResumePreservesOpaqueSystemFailure() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let identity = try expectedDriverIdentity(bundle)
        let generation = generation(pid: 3_161, start: 31_061, group: 3_161)
        let unexpected = SecureSpawnUnexpectedError(
            description: "concrete-resume-secret-7d26"
        )
        let attestation = ScriptedSuspendedChildAttestationSystem(
            effectiveUserID: 501,
            generations: [generation],
            executablePaths: [],
            codeIdentity: validCodeIdentity(identity),
            fileIdentity: validFileIdentity(identity),
            unexpectedErrorAtEvent: "generation",
            unexpectedError: unexpected
        )

        #expect(throws: unexpected) {
            try DarwinVoicePerformanceSecureChildSpawningSystem(
                attestationSystem: attestation
            ).resumeSuspendedChild(generation)
        }
        #expect(attestation.resumedPIDs.isEmpty)
    }

    @Test("wrong atomic pgrp is aborted before supervisor adoption")
    func wrongSpawnGroupIsAborted() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let wrong = generation(pid: 3_201, start: 32_001, group: 3_200)
        let spawnSystem = RecordingSecureSpawnSystem(next: wrong)
        let processSystem = SecureSpawnSupervisorSystem(
            currentPID: 3_200,
            generations: [3_201: wrong]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(
            system: processSystem
        )
        let request = try VoicePerformanceDriverSpawnRequest(
            tracerBundlePath: bundle,
            expectedChildIdentity: try expectedDriverIdentity(bundle),
            deadline: .init(nanoseconds: 66_000)
        )

        #expect(
            throws:
                VoicePerformanceTracerProcessError.processGenerationMismatch
        ) {
            try VoicePerformanceSecureChildSpawner(system: spawnSystem)
                .spawnDriver(request: request, supervisedBy: supervisor)
        }

        #expect(spawnSystem.aborted == [wrong])
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("post-spawn cleanup failure is never reported as an identity mismatch")
    func cleanupFailureHasDedicatedProvenance() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let wrong = generation(pid: 3_211, start: 32_101, group: 3_210)
        let spawnSystem = RecordingSecureSpawnSystem(next: wrong)
        spawnSystem.abortError = VoicePerformanceTracerProcessError
            .processWaitFailed
        let processSystem = SecureSpawnSupervisorSystem(
            currentPID: 3_210,
            generations: [3_211: wrong]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(
            system: processSystem
        )
        let request = try VoicePerformanceDriverSpawnRequest(
            tracerBundlePath: bundle,
            expectedChildIdentity: try expectedDriverIdentity(bundle),
            deadline: .init(nanoseconds: 66_100)
        )

        #expect(
            throws: VoicePerformanceTracerProcessError.processCleanupFailed
        ) {
            try VoicePerformanceSecureChildSpawner(system: spawnSystem)
                .spawnDriver(request: request, supervisedBy: supervisor)
        }

        #expect(spawnSystem.aborted == [wrong])
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("early driver exit before group adoption falls back to raw cleanup")
    func earlyDriverExitUsesRawGroupCleanup() throws {
        let bundle = "/Applications/RimeAI Voice Performance.bundle"
        let driver = generation(pid: 3_212, start: 32_102, group: 3_212)
        let spawnSystem = RecordingSecureSpawnSystem(next: driver)
        let processSystem = SecureSpawnSupervisorSystem(
            currentPID: 3_210,
            generations: [3_212: driver]
        )
        processSystem.peekOutcomes = [.exited(code: 0)]
        let supervisor = VoicePerformanceCollectorDriverSupervisor(
            system: processSystem
        )
        let request = try VoicePerformanceDriverSpawnRequest(
            tracerBundlePath: bundle,
            expectedChildIdentity: try expectedDriverIdentity(bundle),
            deadline: .init(nanoseconds: 66_200)
        )

        #expect(
            throws:
                VoicePerformanceTracerProcessError.processGenerationMismatch
        ) {
            try VoicePerformanceSecureChildSpawner(system: spawnSystem)
                .spawnDriver(request: request, supervisedBy: supervisor)
        }

        #expect(spawnSystem.aborted == [driver])
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("an exited direct child is reaped when getpgid reports ESRCH")
    func zombieLeaderIsExplicitlyReaped() throws {
        var pid: Int32 = 0
        var command = Array("/usr/bin/true".utf8CString)
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let spawnStatus = command.withUnsafeMutableBufferPointer { executable in
            var arguments: [UnsafeMutablePointer<CChar>?] = [
                executable.baseAddress,
                nil,
            ]
            return arguments.withUnsafeMutableBufferPointer { argv in
                environment.withUnsafeMutableBufferPointer { envp in
                    posix_spawn(
                        &pid,
                        executable.baseAddress,
                        nil,
                        nil,
                        argv.baseAddress,
                        envp.baseAddress
                    )
                }
            }
        }
        #expect(spawnStatus == 0)
        #expect(pid > 1)
        guard spawnStatus == 0, pid > 1 else { return }

        var cleanupComplete = false
        defer {
            if !cleanupComplete {
                var status: Int32 = 0
                _ = Darwin.waitpid(pid, &status, 0)
            }
        }

        var observedExitedChild = false
        for _ in 0 ..< 1_000 {
            var information = siginfo_t()
            if Darwin.waitid(
                P_PID,
                id_t(pid),
                &information,
                WEXITED | WNOHANG | WNOWAIT
            ) == 0,
               information.si_pid == pid
            {
                observedExitedChild = true
                break
            }
            Darwin.usleep(1_000)
        }
        #expect(observedExitedChild)
        guard observedExitedChild else { return }

        errno = 0
        let observedMissingGroup = Darwin.getpgid(pid) < 0 && errno == ESRCH
        #expect(observedMissingGroup)
        guard observedMissingGroup else { return }

        try DarwinVoicePerformanceSecureChildSpawningSystem()
            .abortUnadoptedChild(
                .init(
                    pid: pid,
                    startToken: 1,
                    processGroupID: pid
                ),
                processGroup: .new
            )

        var status: Int32 = 0
        errno = 0
        #expect(Darwin.waitpid(pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
        cleanupComplete = true
    }

    @Test("an initially zombie leader still anchors cleanup of its live group")
    func initialZombieLeaderStillCleansLiveGroup() throws {
        let pid: Int32 = 3_221
        let termination = ScriptedSecureChildTerminationSystem(
            processGroupID: nil,
            generations: [],
            groupLiveness: [true, true, false],
            peeks: [.exited(code: 0), .exited(code: 0), .exited(code: 0)],
            waits: [.exited(code: 0)],
            times: [0, 2_000_000_000, 2_000_000_000]
        )

        try DarwinVoicePerformanceSecureChildSpawningSystem(
            terminationSystem: termination
        ).abortUnadoptedChild(
            .init(pid: pid, startToken: 33_221, processGroupID: pid),
            processGroup: .new
        )

        #expect(termination.signals == [
            .init(signal: .terminate, pid: pid, processGroup: .new),
            .init(signal: .kill, pid: pid, processGroup: .new),
        ])
        #expect(termination.waits.isEmpty)
    }

    @Test("a leader becoming zombie after TERM still permits group KILL")
    func leaderBecomingZombieStillCleansLiveGroup() throws {
        let pid: Int32 = 3_222
        let expected = generation(pid: pid, start: 33_222, group: pid)
        let termination = ScriptedSecureChildTerminationSystem(
            processGroupID: pid,
            generations: [expected],
            groupLiveness: [true, true, false],
            peeks: [.running, .running, .exited(code: 0)],
            waits: [.exited(code: 0)],
            times: [0, 2_000_000_000, 2_000_000_000]
        )

        try DarwinVoicePerformanceSecureChildSpawningSystem(
            terminationSystem: termination
        ).abortUnadoptedChild(
            expected,
            processGroup: .new
        )

        #expect(termination.signals == [
            .init(signal: .terminate, pid: pid, processGroup: .new),
            .init(signal: .kill, pid: pid, processGroup: .new),
        ])
        #expect(termination.waits.isEmpty)
    }

    @Test("getpgid exit race rechecks the unreaped child anchor")
    func processGroupLookupExitRaceStillCleansLiveGroup() throws {
        let pid: Int32 = 3_223
        let termination = ScriptedSecureChildTerminationSystem(
            processGroupID: nil,
            generations: [],
            groupLiveness: [true, true, false],
            peeks: [
                .running,
                .exited(code: 0),
                .exited(code: 0),
                .exited(code: 0),
            ],
            waits: [.exited(code: 0)],
            times: [0, 2_000_000_000, 2_000_000_000]
        )

        try DarwinVoicePerformanceSecureChildSpawningSystem(
            terminationSystem: termination
        ).abortUnadoptedChild(
            .init(pid: pid, startToken: 33_223, processGroupID: pid),
            processGroup: .new
        )

        #expect(termination.signals == [
            .init(signal: .terminate, pid: pid, processGroup: .new),
            .init(signal: .kill, pid: pid, processGroup: .new),
        ])
        #expect(termination.waits.isEmpty)
    }

    @Test("spawn requests reject free or lookalike bundle paths")
    func spawnRequestPathIsFrozen() {
        #expect(throws: VoicePerformanceTracerProcessError.invalidTracerBundle) {
            try VoicePerformanceDriverSpawnRequest(
                tracerBundlePath: "/Applications/Lookalike.app",
                expectedChildIdentity: try expectedDriverIdentity(
                    "/Applications/Lookalike.app"
                ),
                deadline: .init(nanoseconds: 1)
            )
        }
        #expect(throws: VoicePerformanceTracerProcessError.invalidTrial) {
            try VoicePerformanceHelperSpawnRequest(
                tracerBundlePath: "/Applications/Tracer.bundle",
                trial: 4,
                policyColdTrials: 3,
                expectedChildIdentity: try expectedHelperIdentity(
                    "/Applications/Tracer.bundle"
                ),
                deadline: .init(nanoseconds: 1)
            )
        }
    }

    private func expectedDriverIdentity(_ bundle: String) throws
        -> VoicePerformanceExpectedChildIdentity
    {
        try VoicePerformanceExpectedChildIdentity(
            executablePath: bundle
                + VoicePerformanceTracerBundleLayout.driverExecutableSuffix,
            executableSHA256: String(repeating: "a", count: 64),
            signingIdentifier:
                "fun.wwcn.rimeai.voice-performance-driver",
            teamIdentifier: "A1B2C3D4E5",
            cdHash: String(repeating: "b", count: 40)
        )
    }

    private func expectedHelperIdentity(_ bundle: String) throws
        -> VoicePerformanceExpectedChildIdentity
    {
        try VoicePerformanceExpectedChildIdentity(
            executablePath: bundle
                + VoicePerformanceTracerBundleLayout.helperExecutableSuffix,
            executableSHA256: String(repeating: "c", count: 64),
            signingIdentifier: "fun.wwcn.rimeai.voice-helper",
            teamIdentifier: "A1B2C3D4E5",
            cdHash: String(repeating: "d", count: 40)
        )
    }

    private func validCodeIdentity(
        _ identity: VoicePerformanceExpectedChildIdentity
    ) -> VoicePerformanceSuspendedChildCodeIdentity {
        .init(
            executablePath: identity.executablePath,
            signingIdentifier: identity.signingIdentifier,
            teamIdentifier: identity.teamIdentifier,
            cdHash: identity.cdHash,
            codeDirectoryFlags: 0x0001_0000,
            hasDisallowedEntitlements: false,
            isDebugged: false,
            developerIDValidated: true,
            strictValidation: true
        )
    }

    private func validFileIdentity(
        _ identity: VoicePerformanceExpectedChildIdentity
    ) -> VoicePerformanceSuspendedExecutableFileIdentity {
        .init(
            sha256: identity.executableSHA256,
            ownerEUID: 501,
            mode: S_IFREG | S_IRUSR | S_IXUSR,
            size: 4_096,
            stable: true,
            namedPathStable: true,
            openedWithoutSymlink: true,
            hasExtendedACL: false
        )
    }

    private func generation(pid: Int32, start: UInt64, group: Int32)
        -> VoicePerformanceSupervisedProcessGeneration
    {
        .init(pid: pid, startToken: start, processGroupID: group)
    }
}

private final class RecordingSecureSpawnSystem:
    VoicePerformanceSecureChildSpawningSystem, @unchecked Sendable
{
    let next: VoicePerformanceSupervisedProcessGeneration
    var specifications: [VoicePerformanceSecureSpawnSpecification] = []
    var aborted: [VoicePerformanceSupervisedProcessGeneration] = []
    var abortError: Error?
    var attestationError: Error?
    var resumeError: Error?
    var events: [String] = []

    init(next: VoicePerformanceSupervisedProcessGeneration) {
        self.next = next
    }

    func spawnSuspended(
        specification: VoicePerformanceSecureSpawnSpecification
    ) throws -> VoicePerformanceSupervisedProcessGeneration {
        events.append("spawn-suspended")
        specifications.append(specification)
        return next
    }

    func attestSuspendedChild(
        _ generation: VoicePerformanceSupervisedProcessGeneration,
        specification: VoicePerformanceSecureSpawnSpecification
    ) throws {
        events.append("attest")
        if let attestationError { throw attestationError }
    }

    func resumeSuspendedChild(
        _ generation: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        events.append("resume")
        if let resumeError { throw resumeError }
    }

    func abortUnadoptedChild(
        _ generation: VoicePerformanceSupervisedProcessGeneration,
        processGroup: VoicePerformanceSpawnProcessGroup
    ) throws {
        aborted.append(generation)
        if let abortError { throw abortError }
    }
}

private final class SecureSpawnSupervisorSystem:
    VoicePerformanceProcessGroupSystem, @unchecked Sendable
{
    let currentProcessID: Int32
    var generations: [Int32: VoicePerformanceSupervisedProcessGeneration]
    var groupChanges: [(pid: Int32, group: Int32)] = []
    var peekOutcomes: [VoicePerformanceWaitOutcome] = []
    var waitOutcomes: [VoicePerformanceWaitOutcome] = []

    init(
        currentPID: Int32,
        generations: [Int32: VoicePerformanceSupervisedProcessGeneration]
    ) {
        currentProcessID = currentPID
        self.generations = generations
    }

    func setProcessGroup(pid: Int32, processGroupID: Int32) throws {
        groupChanges.append((pid, processGroupID))
    }

    func generation(pid: Int32) throws
        -> VoicePerformanceSupervisedProcessGeneration?
    {
        generations[pid]
    }

    func signalProcessGroup(
        _ signal: VoicePerformanceTerminationSignal,
        processGroupID: Int32
    ) throws {}

    func signalProcess(
        _ signal: VoicePerformanceTerminationSignal,
        pid: Int32
    ) throws {}

    func processGroupHasLiveProcesses(processGroupID: Int32) throws -> Bool {
        false
    }

    func processGroupLiveProcessesExactlyMatch(
        processGroupID: Int32,
        expectedProcessIDs: Set<Int32>
    ) throws -> Bool {
        true
    }

    func peekNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        peekOutcomes.isEmpty ? .running : peekOutcomes.removeFirst()
    }

    func waitNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        waitOutcomes.isEmpty ? .running : waitOutcomes.removeFirst()
    }

    func currentContinuousNanoseconds() throws -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) throws {}
}

private final class ScriptedSecureChildTerminationSystem:
    VoicePerformanceSecureChildTerminationSystem, @unchecked Sendable
{
    struct RecordedSignal: Equatable {
        let signal: VoicePerformanceTerminationSignal
        let pid: Int32
        let processGroup: VoicePerformanceSpawnProcessGroup
    }

    let processGroupID: Int32?
    var generations: [VoicePerformanceSupervisedProcessGeneration]
    var groupLiveness: [Bool]
    var peeks: [VoicePerformanceWaitOutcome]
    var waits: [VoicePerformanceWaitOutcome]
    var times: [UInt64]
    var signals: [RecordedSignal] = []

    init(
        processGroupID: Int32?,
        generations: [VoicePerformanceSupervisedProcessGeneration],
        groupLiveness: [Bool],
        peeks: [VoicePerformanceWaitOutcome],
        waits: [VoicePerformanceWaitOutcome],
        times: [UInt64]
    ) {
        self.processGroupID = processGroupID
        self.generations = generations
        self.groupLiveness = groupLiveness
        self.peeks = peeks
        self.waits = waits
        self.times = times
    }

    func processGroupID(pid: Int32) throws -> Int32? {
        processGroupID
    }

    func generation(pid: Int32) throws
        -> VoicePerformanceSupervisedProcessGeneration?
    {
        generations.isEmpty ? nil : generations.removeFirst()
    }

    func processGroupHasLiveProcesses(processGroupID: Int32) throws -> Bool {
        groupLiveness.removeFirst()
    }

    func peekNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        peeks.removeFirst()
    }

    func waitNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        waits.removeFirst()
    }

    func signal(
        _ signal: VoicePerformanceTerminationSignal,
        pid: Int32,
        processGroup: VoicePerformanceSpawnProcessGroup
    ) throws {
        signals.append(
            .init(signal: signal, pid: pid, processGroup: processGroup)
        )
    }

    func currentContinuousNanoseconds() throws -> UInt64 {
        times.removeFirst()
    }

    func sleep(nanoseconds: UInt64) throws {}
}

private final class ScriptedSuspendedChildAttestationSystem:
    VoicePerformanceSuspendedChildAttestingSystem, @unchecked Sendable
{
    let effectiveUserID: uid_t
    var generations: [VoicePerformanceSupervisedProcessGeneration]
    var executablePaths: [String]
    let codeIdentity: VoicePerformanceSuspendedChildCodeIdentity
    let fileIdentity: VoicePerformanceSuspendedExecutableFileIdentity
    let unexpectedErrorAtEvent: String?
    let unexpectedError: SecureSpawnUnexpectedError?
    var events: [String] = []
    var resumedPIDs: [Int32] = []

    init(
        effectiveUserID: uid_t,
        generations: [VoicePerformanceSupervisedProcessGeneration],
        executablePaths: [String],
        codeIdentity: VoicePerformanceSuspendedChildCodeIdentity,
        fileIdentity: VoicePerformanceSuspendedExecutableFileIdentity,
        unexpectedErrorAtEvent: String? = nil,
        unexpectedError: SecureSpawnUnexpectedError? = nil
    ) {
        self.effectiveUserID = effectiveUserID
        self.generations = generations
        self.executablePaths = executablePaths
        self.codeIdentity = codeIdentity
        self.fileIdentity = fileIdentity
        self.unexpectedErrorAtEvent = unexpectedErrorAtEvent
        self.unexpectedError = unexpectedError
    }

    func generation(pid: Int32) throws
        -> VoicePerformanceSupervisedProcessGeneration?
    {
        events.append("generation")
        if unexpectedErrorAtEvent == "generation", let unexpectedError {
            throw unexpectedError
        }
        return generations.isEmpty ? nil : generations.removeFirst()
    }

    func executablePath(pid: Int32) throws -> String {
        events.append("path")
        guard !executablePaths.isEmpty else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        return executablePaths.removeFirst()
    }

    func liveCodeIdentity(
        pid: Int32,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> VoicePerformanceSuspendedChildCodeIdentity {
        events.append("live-code")
        return codeIdentity
    }

    func executableFileIdentity(
        at executablePath: String,
        maximumBytes: UInt64
    ) throws -> VoicePerformanceSuspendedExecutableFileIdentity {
        events.append("file")
        return fileIdentity
    }

    func resume(pid: Int32) throws {
        events.append("resume")
        resumedPIDs.append(pid)
    }
}

private struct SecureSpawnUnexpectedError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    let description: String
}
