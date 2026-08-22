import Foundation
import Testing
@testable import RimeAIVoicePerformanceCollector

@Test("schema-1 collection plan preserves the fixed process role order")
func collectionPlanDecodes() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )

    #expect(plan.sampleIntervalMilliseconds == 100)
    #expect(plan.collectionProtocol == VoicePerformanceCollectionProtocol(
        id: "rimeai-release-collection-v1",
        sha256: String(repeating: "7", count: 64)
    ))
    #expect(plan.nativeCollectorSHA256 == String(repeating: "a", count: 64))
    #expect(plan.processes.map(\.role) == [
        .inputMethod,
        .candidateService,
        .voiceHelper,
    ])
}

@Test("collection plan rejects duplicate JSON keys")
func collectionPlanRejectsDuplicateKeys() throws {
    let duplicate = TestFixture.validPlanJSON.replacingOccurrences(
        of: "\"schema_version\": 1,",
        with: "\"schema_version\": 1, \"schema_version\": 1,"
    )

    #expect(throws: VoicePerformanceCollectorError.invalidPlan) {
        _ = try VoicePerformanceCollectionPlan.decodeStrict(
            Data(duplicate.utf8)
        )
    }
}

@Test("collection plan rejects non-integer JSON number types")
func collectionPlanRejectsNonIntegerJSONNumberTypes() throws {
    let replacements: [(String, String)] = [
        ("\"schema_version\": 1", "\"schema_version\": 1.0"),
        ("\"schema_version\": 1", "\"schema_version\": true"),
        ("\"sample_interval_ms\": 100", "\"sample_interval_ms\": 100.0"),
        ("\"sample_interval_ms\": 100", "\"sample_interval_ms\": true"),
        ("\"pid\": 101", "\"pid\": 101.0"),
        ("\"pid\": 101", "\"pid\": true"),
    ]

    for (original, invalid) in replacements {
        let json = TestFixture.validPlanJSON.replacingOccurrences(
            of: original,
            with: invalid
        )
        #expect(throws: VoicePerformanceCollectorError.invalidPlan) {
            _ = try VoicePerformanceCollectionPlan.decodeStrict(Data(json.utf8))
        }
    }
}

@Test("collection plan rejects one PID assigned to two roles")
func collectionPlanRejectsDuplicateProcessInstances() throws {
    let duplicatePID = TestFixture.validPlanJSON.replacingOccurrences(
        of: "\"pid\": 102",
        with: "\"pid\": 101"
    )

    #expect(throws: VoicePerformanceCollectorError.invalidPlan) {
        _ = try VoicePerformanceCollectionPlan.decodeStrict(
            Data(duplicatePID.utf8)
        )
    }
}

@Test("collection plan rejects malformed process and collector identities")
func collectionPlanRejectsMalformedIdentityClaims() throws {
    let replacements: [(String, String)] = [
        ("TEAMID1234", "teamid1234"),
        ("rimeai-release-collection-v1", "private protocol"),
        (
            "7777777777777777777777777777777777777777777777777777777777777777",
            "777777777777777777777777777777777777777777777777777777777777777A"
        ),
        (
            "fun.wwcn.inputmethod.RimeAI",
            "fun.wwcn.inputmethod/RimeAI"
        ),
        ("rimeai-daemon", "same-team-unrelated-tool"),
        (
            "1111111111111111111111111111111111111111",
            "111111111111111111111111111111111111111A"
        ),
        (
            "/Applications/RimeAIInputMethod.app/Contents/MacOS/RimeAIInputMethod",
            "Applications/RimeAIInputMethod"
        ),
        (
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        ),
        ("\"sample_interval_ms\": 100", "\"sample_interval_ms\": 101"),
    ]

    for (original, invalid) in replacements {
        let json = TestFixture.validPlanJSON.replacingOccurrences(
            of: original,
            with: invalid
        )
        #expect(throws: VoicePerformanceCollectorError.invalidPlan) {
            _ = try VoicePerformanceCollectionPlan.decodeStrict(Data(json.utf8))
        }
    }
}

@Test("product artifact identity is semantic and runtime-derived")
func collectionPlanRejectsInvalidArtifactIdentity() throws {
    let productPlan = TestFixture.validPlanJSON
        .replacingOccurrences(
            of: "\"artifact_directory\": null",
            with: "\"artifact_directory\": \"/Library/Application Support/RimeAI/artifacts/model-v1\""
        )
        .replacingOccurrences(
            of: "\"artifact\": null",
            with: """
            "artifact": {
                "artifact_id": "model-v1",
                "artifact_content_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                "adapter_id": "sherpa-onnx",
                "engine_id": "sherpa-onnx@bbbbbbbbbbbbbbbb",
                "model_id": "zh-small",
                "model_revision": "2026.08"
              }
            """
        )
    _ = try VoicePerformanceCollectionPlan.decodeStrict(Data(productPlan.utf8))

    for (original, invalid) in [
        ("model-v1", "../model-v1"),
        (
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbB"
        ),
        ("sherpa-onnx@bbbbbbbbbbbbbbbb", "friendly-name"),
    ] {
        let json = productPlan.replacingOccurrences(of: original, with: invalid)
        #expect(throws: VoicePerformanceCollectorError.invalidPlan) {
            _ = try VoicePerformanceCollectionPlan.decodeStrict(Data(json.utf8))
        }
    }
}

@Test("product artifact verification starts only after measured collection")
func productArtifactVerificationIsDeferredUntilFinish() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validProductPlanJSON.utf8)
    )
    let platform = FakePerformancePlatform()
    let verifier = RecordingArtifactVerifier()
    let collection = try VoicePerformanceCollection(
        plan: plan,
        platform: platform,
        artifactVerifier: verifier
    )

    #expect(verifier.callCount == 0)
    platform.timeNanoseconds = 0
    try collection.consume(.coldArtifactLoadBegin(sequence: 1))
    platform.timeNanoseconds = 10_000_000
    try collection.consume(.coldArtifactLoadEnd(sequence: 1))
    #expect(verifier.callCount == 0)

    try completeMeasuredCollectionAfterColdLoad(
        collection,
        platform: platform
    )
    #expect(verifier.callCount == 0)

    let result = try collection.finish()
    let repeatedResult = try collection.finish()

    #expect(verifier.callCount == 1)
    #expect(result.artifact == verifier.evidence)
    #expect(repeatedResult == result)
}

@Test("collector rejects a hardware model containing control characters")
func collectorRejectsControlCharactersInHardwareModel() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let platform = FakePerformancePlatform()
    platform.hardwareModel = "Mac15,7\nprivate"

    #expect(throws: VoicePerformanceCollectorError.invalidEnvironment) {
        _ = try VoicePerformanceCollection(plan: plan, platform: platform)
    }
}

@Test("collector rejects a hardware model over 128 bytes")
func collectorRejectsOverlongHardwareModel() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let platform = FakePerformancePlatform()
    platform.hardwareModel = String(repeating: "M", count: 129)

    #expect(throws: VoicePerformanceCollectorError.invalidEnvironment) {
        _ = try VoicePerformanceCollection(plan: plan, platform: platform)
    }
}

@Test("collector preserves the raw macOS hardware model identity")
func collectorPreservesRawHardwareModelIdentity() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let platform = FakePerformancePlatform()
    platform.hardwareModel = "Mac15,7"
    let collection = try VoicePerformanceCollection(
        plan: plan,
        platform: platform
    )
    platform.timeNanoseconds = 0
    try collection.consume(.coldArtifactLoadBegin(sequence: 1))
    platform.timeNanoseconds = 10_000_000
    try collection.consume(.coldArtifactLoadEnd(sequence: 1))
    try completeMeasuredCollectionAfterColdLoad(
        collection,
        platform: platform
    )

    let result = try collection.finish()

    #expect(result.environment.hardwareModel == "Mac15,7")
}

@Test("live event accepts a marker without caller-supplied measurements")
func liveEventDecodesSessionMarker() throws {
    let event = try VoicePerformanceLiveEvent.decodeStrictNDJSONLine(Data(
        """
        {"schema_version":1,"event":"session_begin","sample_id":"voice-000001"}
        """.utf8
    ))

    #expect(event == .sessionBegin(sampleID: "voice-000001"))
}

@Test("late challenge marker carries only one fixed scenario")
func liveEventDecodesChallengeMarker() throws {
    let event = try VoicePerformanceLiveEvent.decodeStrictNDJSONLine(Data(
        """
        {"schema_version":1,"event":"challenge","scenario":"secure_input"}
        """.utf8
    ))

    #expect(event == .challenge(scenario: .secureInput))
    #expect(throws: VoicePerformanceCollectorError.invalidEvent) {
        _ = try VoicePerformanceLiveEvent.decodeStrictNDJSONLine(Data(
            """
            {"schema_version":1,"event":"challenge","scenario":"invented"}
            """.utf8
        ))
    }
    #expect(throws: VoicePerformanceCollectorError.invalidEvent) {
        _ = try VoicePerformanceLiveEvent.decodeStrictNDJSONLine(Data(
            """
            {"schema_version":1,"event":"challenge","scenario":"cancel","elapsed_ms":1}
            """.utf8
        ))
    }
}

@Test("live events reject duplicate keys measurements and private payloads")
func liveEventsRejectCallerMeasurementsAndPrivatePayloads() throws {
    let invalidLines = [
        "{\"schema_version\":1,\"event\":\"finish\",\"event\":\"finish\"}",
        "{\"schema_version\":1,\"event\":\"finish\",\"processing_duration_ms\":1}",
        "{\"schema_version\":1,\"event\":\"finish\",\"text\":\"private\"}",
        "{\"schema_version\":true,\"event\":\"finish\"}",
        "{\"schema_version\":1,\"event\":\"cold_artifact_load_begin\",\"sequence\":1.0}",
    ]

    for line in invalidLines {
        #expect(throws: VoicePerformanceCollectorError.invalidEvent) {
            _ = try VoicePerformanceLiveEvent.decodeStrictNDJSONLine(
                Data(line.utf8)
            )
        }
    }
}

@Test("live markers produce one unbound process and keyboard result")
func liveMarkersProduceUnboundResult() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let platform = FakePerformancePlatform()
    let verifier = RecordingArtifactVerifier()
    let collection = try VoicePerformanceCollection(
        plan: plan,
        platform: platform,
        artifactVerifier: verifier
    )

    platform.timeNanoseconds = 0
    try collection.consume(.coldArtifactLoadBegin(sequence: 1))
    platform.timeNanoseconds = 100_000_000
    try collection.consume(.coldArtifactLoadEnd(sequence: 1))

    platform.timeNanoseconds = 200_000_000
    platform.residentBytes = 10_000
    try collection.consume(.sessionBegin(sampleID: "voice-000001"))
    platform.timeNanoseconds = 250_000_000
    platform.residentBytes = 20_000
    try collection.sample()
    platform.timeNanoseconds = 300_000_000
    platform.residentBytes = 15_000
    try collection.consume(.sessionEnd(sampleID: "voice-000001"))

    for (index, phase) in VoicePerformanceKeyboardPhase.allCases.enumerated() {
        let sequence = 1
        platform.timeNanoseconds = UInt64(400 + index * 100) * 1_000_000
        try collection.consume(.keyboardBegin(sequence: sequence, phase: phase))
        platform.timeNanoseconds += UInt64(10 + index) * 1_000_000
        try collection.consume(
            .keyboardCandidateReady(sequence: sequence, phase: phase)
        )
    }
    for scenario in VoicePerformanceLateChallengeScenario.allCases {
        try collection.consume(.challenge(scenario: scenario))
    }
    try collection.consume(.finish)

    let result = try collection.finish()
    let session = try #require(result.sessions.first)
    let process = try #require(session.processes.first)
    #expect(result.coldArtifactLoadMilliseconds == [100])
    #expect(session.sampleID == "voice-000001")
    #expect(session.processingDurationMilliseconds == 100)
    #expect(process.startUserCPUNanoseconds == 200_001_000)
    #expect(process.endUserCPUNanoseconds == 300_001_000)
    #expect(process.baselineResidentBytes == 10_000)
    #expect(process.peakResidentBytes == 20_000)
    #expect(process.sampleCount == 3)
    #expect(process.maximumSampleGapMilliseconds == 50)
    #expect(result.keyboardTrials.map(\.rimeCandidateLatencyMilliseconds)
        == [10, 11, 12])
    #expect(result.lateVoiceCommitCount == 0)
    #expect(result.lateChallengeCounts.cancel == 1)
    #expect(result.lateChallengeCounts.applicationSwitch == 1)
    #expect(result.collectionProtocol == plan.collectionProtocol)
    #expect(result.collector.executableSHA256 == plan.nativeCollectorSHA256)
    #expect(result.collector.teamIdentifier == plan.expectedTeamIdentifier)
    #expect(result.artifact == nil)
    #expect(verifier.callCount == 0)
    #expect(
        result.collector.signingIdentifier
            == "fun.wwcn.rimeai.voice-performance-collector"
    )
}

@Test("begin markers exclude collector attestation latency from durations")
func beginMarkersExcludeAttestationLatency() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let platform = FakePerformancePlatform()
    let collection = try VoicePerformanceCollection(
        plan: plan,
        platform: platform
    )
    platform.snapshotAdvanceNanoseconds = 10_000_000

    platform.timeNanoseconds = 100_000_000
    try collection.consume(.coldArtifactLoadBegin(sequence: 1))
    platform.timeNanoseconds = 200_000_000
    try collection.consume(.coldArtifactLoadEnd(sequence: 1))

    platform.timeNanoseconds = 300_000_000
    try collection.consume(.sessionBegin(sampleID: "voice-000001"))
    platform.timeNanoseconds = 400_000_000
    try collection.consume(.sessionEnd(sampleID: "voice-000001"))

    for (index, phase) in VoicePerformanceKeyboardPhase.allCases.enumerated() {
        let beginNanoseconds = UInt64(500 + index * 200) * 1_000_000
        platform.timeNanoseconds = beginNanoseconds
        try collection.consume(.keyboardBegin(sequence: 1, phase: phase))
        platform.timeNanoseconds = beginNanoseconds + 100_000_000
        try collection.consume(
            .keyboardCandidateReady(sequence: 1, phase: phase)
        )
    }
    try collection.consume(.finish)
    let result = try collection.finish()

    #expect(result.coldArtifactLoadMilliseconds == [70])
    #expect(result.sessions.map(\.processingDurationMilliseconds) == [70])
    #expect(
        result.keyboardTrials.map(\.rimeCandidateLatencyMilliseconds)
            == [70, 70, 70]
    )
}

@Test("measurement intervals cannot overlap across scenarios")
func measurementIntervalsCannotOverlap() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let collection = try VoicePerformanceCollection(
        plan: plan,
        platform: FakePerformancePlatform()
    )
    try collection.consume(.coldArtifactLoadBegin(sequence: 1))

    #expect(throws: VoicePerformanceCollectorError.invalidStateTransition) {
        try collection.consume(.sessionBegin(sampleID: "voice-000001"))
    }
}

@Test("zero-duration cold measurements are rejected")
func zeroDurationColdMeasurementIsRejected() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let collection = try VoicePerformanceCollection(
        plan: plan,
        platform: FakePerformancePlatform()
    )
    try collection.consume(.coldArtifactLoadBegin(sequence: 1))

    #expect(throws: VoicePerformanceCollectorError.samplingFailed) {
        try collection.consume(.coldArtifactLoadEnd(sequence: 1))
    }
}

@Test("near-UInt64-limit boundary rejects a sub-millisecond interval without trapping")
func boundaryArithmeticDoesNotOverflow() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let platform = FakePerformancePlatform()
    let collection = try VoicePerformanceCollection(
        plan: plan,
        platform: platform
    )
    platform.userCPUNanosecondsOverride = 0
    platform.systemCPUNanosecondsOverride = 0
    platform.energyNanojoulesOverride = 0
    platform.timeNanoseconds = UInt64.max - 500_000
    try collection.consume(.coldArtifactLoadBegin(sequence: 1))
    platform.timeNanoseconds = UInt64.max

    #expect(throws: VoicePerformanceCollectorError.samplingFailed) {
        try collection.consume(.coldArtifactLoadEnd(sequence: 1))
    }
}

@Test("all-zero native energy evidence is rejected at finish")
func zeroEnergyEvidenceIsRejected() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let platform = FakePerformancePlatform()
    let collection = try VoicePerformanceCollection(
        plan: plan,
        platform: platform
    )
    platform.timeNanoseconds = 0
    try collection.consume(.coldArtifactLoadBegin(sequence: 1))
    platform.timeNanoseconds = 10_000_000
    try collection.consume(.coldArtifactLoadEnd(sequence: 1))
    platform.energyNanojoulesOverride = 0
    platform.timeNanoseconds = 20_000_000
    try collection.consume(.sessionBegin(sampleID: "voice-000001"))
    platform.timeNanoseconds = 30_000_000
    try collection.consume(.sessionEnd(sampleID: "voice-000001"))
    for (index, phase) in VoicePerformanceKeyboardPhase.allCases.enumerated() {
        platform.timeNanoseconds = UInt64(40 + index * 20) * 1_000_000
        try collection.consume(.keyboardBegin(sequence: 1, phase: phase))
        platform.timeNanoseconds += 1_000_000
        try collection.consume(
            .keyboardCandidateReady(sequence: 1, phase: phase)
        )
    }

    #expect(throws: VoicePerformanceCollectorError.incompleteCollection) {
        try collection.consume(.finish)
    }
}

@Test("voice helper CPU counter addition overflow is rejected without trapping")
func voiceHelperCPUOverflowIsRejected() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let platform = FakePerformancePlatform()
    let collection = try VoicePerformanceCollection(
        plan: plan,
        platform: platform
    )

    platform.userCPUNanosecondsOverride = 0
    platform.systemCPUNanosecondsOverride = 0
    platform.timeNanoseconds = 100_000_000
    try collection.consume(.sessionBegin(sampleID: "voice-000001"))
    platform.userCPUNanosecondsOverride = UInt64.max
    platform.systemCPUNanosecondsOverride = UInt64.max
    platform.timeNanoseconds = 200_000_000

    #expect(throws: VoicePerformanceCollectorError.samplingFailed) {
        try collection.consume(.sessionEnd(sampleID: "voice-000001"))
    }
}

@Test("Darwin snapshot sandwiches exact live process identity between V6 reads")
func darwinSnapshotSandwichesIdentity() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let process = try #require(plan.processes.first)
    let system = FakeDarwinPerformanceSystem()
    let platform = DarwinVoicePerformancePlatform(system: system)

    let snapshot = try platform.attestedSnapshot(
        for: process,
        expectedTeamIdentifier: plan.expectedTeamIdentifier
    )

    #expect(system.calls == ["rusage", "identity", "rusage"])
    #expect(snapshot.processIdentifier == process.processIdentifier)
    #expect(snapshot.processStartAbsoluteTime == 4_242)
    #expect(snapshot.userCPUNanoseconds == 20)
    #expect(snapshot.systemCPUNanoseconds == 30)
    #expect(snapshot.energyNanojoules == 40)
    #expect(snapshot.residentBytes == 50)
    #expect(snapshot.physicalFootprintBytes == 60)
}

@Test("collector self attestation requires its exact signing identifier")
func collectorSelfAttestationRequiresExactIdentifier() throws {
    let system = FakeDarwinPerformanceSystem()
    system.collectorSigningIdentifierValue = "same-team-unrelated-tool"
    let platform = DarwinVoicePerformancePlatform(system: system)

    #expect(throws: VoicePerformanceCollectorError.invalidCollectorIdentity) {
        try platform.verifyCollectorIdentity(
            expectedSHA256: String(repeating: "a", count: 64),
            expectedTeamIdentifier: "TEAMID1234"
        )
    }
}

@Test("collector self attestation rejects a non-Developer-ID signature")
func collectorSelfAttestationRequiresDeveloperID() throws {
    let system = FakeDarwinPerformanceSystem()
    system.acceptsCollectorDeveloperID = false

    #expect(throws: VoicePerformanceCollectorError.invalidCollectorIdentity) {
        try DarwinVoicePerformancePlatform(system: system)
            .verifyCollectorIdentity(
                expectedSHA256: String(repeating: "a", count: 64),
                expectedTeamIdentifier: "TEAMID1234"
            )
    }
}

@Test("Darwin snapshot rejects a process that exits or reuses its PID")
func darwinSnapshotRejectsExitAndPIDReuse() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let process = try #require(plan.processes.first)

    let exited = FakeDarwinPerformanceSystem()
    exited.secondProcessExitAbsoluteTime = 4_300
    #expect(throws: VoicePerformanceCollectorError.invalidProcessIdentity) {
        _ = try DarwinVoicePerformancePlatform(system: exited)
            .attestedSnapshot(
                for: process,
                expectedTeamIdentifier: plan.expectedTeamIdentifier
            )
    }

    let reused = FakeDarwinPerformanceSystem()
    reused.secondProcessStartAbsoluteTime = 4_243
    #expect(throws: VoicePerformanceCollectorError.invalidProcessIdentity) {
        _ = try DarwinVoicePerformancePlatform(system: reused)
            .attestedSnapshot(
                for: process,
                expectedTeamIdentifier: plan.expectedTeamIdentifier
            )
    }
}

@Test("Darwin snapshot requires exact UID path identifier Team and CDHash")
func darwinSnapshotRequiresExactRuntimeIdentity() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let process = try #require(plan.processes.first)
    let mutations: [(FakeDarwinPerformanceSystem) -> Void] = [
        { $0.processEffectiveUserID = 502 },
        { $0.processExecutablePath = "/tmp/lookalike" },
        { $0.processSigningIdentifier = "same-team-unrelated-tool" },
        { $0.processTeamIdentifier = "OTHERID123" },
        { $0.processCDHash = String(repeating: "f", count: 40) },
    ]

    for mutate in mutations {
        let system = FakeDarwinPerformanceSystem()
        mutate(system)
        #expect(throws: VoicePerformanceCollectorError.invalidProcessIdentity) {
            _ = try DarwinVoicePerformancePlatform(system: system)
                .attestedSnapshot(
                    for: process,
                    expectedTeamIdentifier: plan.expectedTeamIdentifier
                )
        }
    }
}

@Test("Darwin snapshot rejects a peer without a Developer ID signature")
func darwinSnapshotRequiresDeveloperID() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let process = try #require(plan.processes.first)
    let system = FakeDarwinPerformanceSystem()
    system.acceptsProcessDeveloperID = false

    #expect(throws: VoicePerformanceCollectorError.invalidProcessIdentity) {
        _ = try DarwinVoicePerformancePlatform(system: system)
            .attestedSnapshot(
                for: process,
                expectedTeamIdentifier: plan.expectedTeamIdentifier
            )
    }
}

@Test("macOS system captures a live process with one RUSAGE_INFO_V6 read")
func macOSSystemCapturesLiveRUsageV6() throws {
    let system = MacOSVoicePerformanceSystem()

    let usage = try system.rusageV6(processIdentifier: getpid())

    #expect(usage.processStartAbsoluteTime > 0)
    #expect(usage.processExitAbsoluteTime == 0)
    #expect(usage.residentBytes > 0)
    #expect(usage.physicalFootprintBytes > 0)
}

@Test("macOS collector clock is mach_continuous_time converted to nanoseconds")
func macOSSystemProvidesMonotonicContinuousNanoseconds() throws {
    let system = MacOSVoicePerformanceSystem()

    let first = try system.continuousTimeNanoseconds()
    let second = try system.continuousTimeNanoseconds()

    #expect(first > 0)
    #expect(second >= first)
}

@Test("macOS environment snapshot is complete and release-comparable")
func macOSSystemCapturesEnvironment() throws {
    let environment = try MacOSVoicePerformanceSystem().environmentSnapshot()

    #expect(!environment.hardwareModel.isEmpty)
    #expect(environment.physicalMemoryBytes > 0)
    #expect(environment.logicalCPUCount > 0)
}

@Test("stdin NDJSON reader rejects an over-limit line before newline arrives")
func boundedNDJSONReaderRejectsUnboundedLine() throws {
    var reader = VoicePerformanceBoundedNDJSONReader(maximumLineBytes: 16)

    #expect(throws: VoicePerformanceCollectorError.invalidEvent) {
        _ = try reader.append(Data(repeating: 0x61, count: 17))
    }
}

@Test("stdin NDJSON reader rejects carriage-return replay framing")
func boundedNDJSONReaderRejectsCarriageReturn() throws {
    var reader = VoicePerformanceBoundedNDJSONReader(maximumLineBytes: 64)

    #expect(throws: VoicePerformanceCollectorError.invalidEvent) {
        _ = try reader.append(Data("{}\r\n".utf8))
    }
}

@Test("stdin NDJSON reader rejects an unterminated final record")
func boundedNDJSONReaderRejectsUnterminatedRecord() throws {
    var reader = VoicePerformanceBoundedNDJSONReader(maximumLineBytes: 64)
    _ = try reader.append(Data("{}".utf8))

    #expect(throws: VoicePerformanceCollectorError.invalidEvent) {
        try reader.finish()
    }
}

@Test("serial collector gates timer samples after finish is linearized")
func serialCollectorDoesNotSampleAfterFinish() throws {
    let plan = try VoicePerformanceCollectionPlan.decodeStrict(
        Data(TestFixture.validPlanJSON.utf8)
    )
    let platform = FakePerformancePlatform()
    let collection = try VoicePerformanceCollection(
        plan: plan,
        platform: platform
    )
    let serial = VoicePerformanceSerialCollector(
        collection: collection,
        sampleIntervalMilliseconds: 100,
        startsTimer: false
    )

    platform.timeNanoseconds = 0
    _ = try serial.consume(.coldArtifactLoadBegin(sequence: 1))
    platform.timeNanoseconds = 10_000_000
    _ = try serial.consume(.coldArtifactLoadEnd(sequence: 1))
    platform.timeNanoseconds = 20_000_000
    _ = try serial.consume(.sessionBegin(sampleID: "voice-000001"))
    platform.timeNanoseconds = 30_000_000
    _ = try serial.consume(.sessionEnd(sampleID: "voice-000001"))
    for (index, phase) in VoicePerformanceKeyboardPhase.allCases.enumerated() {
        platform.timeNanoseconds = UInt64(40 + index * 20) * 1_000_000
        _ = try serial.consume(.keyboardBegin(sequence: 1, phase: phase))
        platform.timeNanoseconds += 1_000_000
        _ = try serial.consume(
            .keyboardCandidateReady(sequence: 1, phase: phase)
        )
    }
    let maybeResult = try serial.consume(.finish)
    let result = try #require(maybeResult)

    #expect(result.sessions.count == 1)
    #expect(try serial.sampleIfRunning() == false)
}

@Test("command emits only one final JSON result after a complete live stream")
func collectorCommandEmitsFinalJSONOnly() throws {
    let planURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "rimeai-performance-plan-\(UUID().uuidString).json"
    )
    try Data(TestFixture.validPlanJSON.utf8).write(to: planURL)
    #expect(chmod(planURL.path, S_IRUSR | S_IWUSR) == 0)
    defer { try? FileManager.default.removeItem(at: planURL) }

    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    let events = """
    {"schema_version":1,"event":"cold_artifact_load_begin","sequence":1}
    {"schema_version":1,"event":"cold_artifact_load_end","sequence":1}
    {"schema_version":1,"event":"session_begin","sample_id":"voice-000001"}
    {"schema_version":1,"event":"session_end","sample_id":"voice-000001"}
    {"schema_version":1,"event":"keyboard_begin","sequence":1,"phase":"baseline"}
    {"schema_version":1,"event":"keyboard_candidate_ready","sequence":1,"phase":"baseline"}
    {"schema_version":1,"event":"keyboard_begin","sequence":1,"phase":"helper_loaded_idle"}
    {"schema_version":1,"event":"keyboard_candidate_ready","sequence":1,"phase":"helper_loaded_idle"}
    {"schema_version":1,"event":"keyboard_begin","sequence":1,"phase":"listening_cancel_to_rime"}
    {"schema_version":1,"event":"keyboard_candidate_ready","sequence":1,"phase":"listening_cancel_to_rime"}
    {"schema_version":1,"event":"finish"}

    """
    try input.fileHandleForWriting.write(contentsOf: Data(events.utf8))
    try input.fileHandleForWriting.close()

    let platform = FakePerformancePlatform()
    platform.continuousTimeAdvanceNanoseconds = 1_000_000

    let exitCode = VoicePerformanceCollectorCommand.runForTesting(
        arguments: ["collector", "--plan", planURL.path],
        input: input.fileHandleForReading,
        output: output.fileHandleForWriting,
        errorOutput: errors.fileHandleForWriting,
        platform: platform
    )
    try output.fileHandleForWriting.close()
    try errors.fileHandleForWriting.close()
    let maybeStdout = try output.fileHandleForReading.readToEnd()
    let maybeStderr = try errors.fileHandleForReading.readToEnd()
    let stdout = try #require(maybeStdout)
    let stderr = maybeStderr ?? Data()
    let result = try JSONSerialization.jsonObject(with: stdout)
        as? [String: Any]

    #expect(exitCode == 0)
    #expect(result?["schema_version"] as? Int == 1)
    #expect(result?["collection_protocol"] is [String: Any])
    #expect(result?["cold_artifact_load_ms"] is [Any])
    #expect(result?["late_challenge_counts"] is [String: Any])
    #expect(result?["sessions"] is [Any])
    #expect(stderr.isEmpty)
}

@Test("artifact verification failure at finish emits no stdout result")
func artifactVerificationFailureEmitsNoResult() throws {
    let planURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "rimeai-performance-product-plan-\(UUID().uuidString).json"
    )
    try Data(TestFixture.validProductPlanJSON.utf8).write(to: planURL)
    #expect(chmod(planURL.path, S_IRUSR | S_IWUSR) == 0)
    defer { try? FileManager.default.removeItem(at: planURL) }

    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    let events = """
    {"schema_version":1,"event":"cold_artifact_load_begin","sequence":1}
    {"schema_version":1,"event":"cold_artifact_load_end","sequence":1}
    {"schema_version":1,"event":"session_begin","sample_id":"voice-000001"}
    {"schema_version":1,"event":"session_end","sample_id":"voice-000001"}
    {"schema_version":1,"event":"keyboard_begin","sequence":1,"phase":"baseline"}
    {"schema_version":1,"event":"keyboard_candidate_ready","sequence":1,"phase":"baseline"}
    {"schema_version":1,"event":"keyboard_begin","sequence":1,"phase":"helper_loaded_idle"}
    {"schema_version":1,"event":"keyboard_candidate_ready","sequence":1,"phase":"helper_loaded_idle"}
    {"schema_version":1,"event":"keyboard_begin","sequence":1,"phase":"listening_cancel_to_rime"}
    {"schema_version":1,"event":"keyboard_candidate_ready","sequence":1,"phase":"listening_cancel_to_rime"}
    {"schema_version":1,"event":"finish"}

    """
    try input.fileHandleForWriting.write(contentsOf: Data(events.utf8))
    try input.fileHandleForWriting.close()

    let platform = FakePerformancePlatform()
    platform.continuousTimeAdvanceNanoseconds = 1_000_000
    let verifier = FailingArtifactVerifier()
    let exitCode = VoicePerformanceCollectorCommand.runForTesting(
        arguments: ["collector", "--plan", planURL.path],
        input: input.fileHandleForReading,
        output: output.fileHandleForWriting,
        errorOutput: errors.fileHandleForWriting,
        platform: platform,
        artifactVerifier: verifier
    )
    try output.fileHandleForWriting.close()
    try errors.fileHandleForWriting.close()
    let stdout = try output.fileHandleForReading.readToEnd() ?? Data()
    let stderr = try errors.fileHandleForReading.readToEnd() ?? Data()

    #expect(verifier.callCount == 1)
    #expect(exitCode == 65)
    #expect(stdout.isEmpty)
    #expect(
        String(decoding: stderr, as: UTF8.self)
            == "rimeai-voice-performance-collector:E_COLLECTION_REJECTED\n"
    )
}

@Test("command rejects regular-file event replay without stdout evidence")
func collectorCommandRejectsRegularFileReplay() throws {
    let suffix = UUID().uuidString
    let directory = FileManager.default.temporaryDirectory
    let planURL = directory.appendingPathComponent(
        "rimeai-performance-plan-\(suffix).json"
    )
    let replayURL = directory.appendingPathComponent(
        "rimeai-performance-events-\(suffix).ndjson"
    )
    try Data(TestFixture.validPlanJSON.utf8).write(to: planURL)
    try Data("{\"schema_version\":1,\"event\":\"finish\"}\n".utf8)
        .write(to: replayURL)
    #expect(chmod(planURL.path, S_IRUSR | S_IWUSR) == 0)
    defer {
        try? FileManager.default.removeItem(at: planURL)
        try? FileManager.default.removeItem(at: replayURL)
    }

    let input = try FileHandle(forReadingFrom: replayURL)
    let output = Pipe()
    let errors = Pipe()
    let exitCode = VoicePerformanceCollectorCommand.runForTesting(
        arguments: ["collector", "--plan", planURL.path],
        input: input,
        output: output.fileHandleForWriting,
        errorOutput: errors.fileHandleForWriting,
        platform: FakePerformancePlatform()
    )
    try input.close()
    try output.fileHandleForWriting.close()
    try errors.fileHandleForWriting.close()
    let stdout = try output.fileHandleForReading.readToEnd() ?? Data()
    let stderr = try errors.fileHandleForReading.readToEnd() ?? Data()

    #expect(exitCode == 65)
    #expect(stdout.isEmpty)
    #expect(
        String(decoding: stderr, as: UTF8.self)
            == "rimeai-voice-performance-collector:E_COLLECTION_REJECTED\n"
    )
}

private enum TestFixture {
    static let validPlanJSON = """
    {
      "schema_version": 1,
      "collection_protocol": {
        "id": "rimeai-release-collection-v1",
        "sha256": "7777777777777777777777777777777777777777777777777777777777777777"
      },
      "sample_interval_ms": 100,
      "native_collector_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "expected_team_identifier": "TEAMID1234",
      "processes": [
        {
          "role": "input_method",
          "pid": 101,
          "expected_executable_path": "/Applications/RimeAIInputMethod.app/Contents/MacOS/RimeAIInputMethod",
          "expected_signing_identifier": "fun.wwcn.inputmethod.RimeAI",
          "expected_cdhash": "1111111111111111111111111111111111111111"
        },
        {
          "role": "candidate_service",
          "pid": 102,
          "expected_executable_path": "/Library/Application Support/RimeAI/current/runtime/rimeai-daemon/rimeai-daemon",
          "expected_signing_identifier": "rimeai-daemon",
          "expected_cdhash": "2222222222222222222222222222222222222222"
        },
        {
          "role": "voice_helper",
          "pid": 103,
          "expected_executable_path": "/Applications/RimeAIInputMethod.app/Contents/Helpers/RimeAIVoiceHelper.app/Contents/MacOS/rimeai-voice-helper",
          "expected_signing_identifier": "fun.wwcn.rimeai.voice-helper",
          "expected_cdhash": "3333333333333333333333333333333333333333"
        }
      ],
      "artifact_directory": null,
      "artifact": null
    }
    """

    static let validProductPlanJSON = validPlanJSON
        .replacingOccurrences(
            of: "\"artifact_directory\": null",
            with: "\"artifact_directory\": \"/Library/Application Support/RimeAI/artifacts/model-v1\""
        )
        .replacingOccurrences(
            of: "\"artifact\": null",
            with: """
            "artifact": {
                "artifact_id": "model-v1",
                "artifact_content_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                "adapter_id": "sherpa-onnx",
                "engine_id": "sherpa-onnx@bbbbbbbbbbbbbbbb",
                "model_id": "zh-small",
                "model_revision": "2026.08"
              }
            """
        )
}

private func completeMeasuredCollectionAfterColdLoad(
    _ collection: VoicePerformanceCollection,
    platform: FakePerformancePlatform
) throws {
    platform.timeNanoseconds = 20_000_000
    try collection.consume(.sessionBegin(sampleID: "voice-000001"))
    platform.timeNanoseconds = 30_000_000
    try collection.consume(.sessionEnd(sampleID: "voice-000001"))
    for (index, phase) in VoicePerformanceKeyboardPhase.allCases.enumerated() {
        platform.timeNanoseconds = UInt64(40 + index * 20) * 1_000_000
        try collection.consume(.keyboardBegin(sequence: 1, phase: phase))
        platform.timeNanoseconds += 1_000_000
        try collection.consume(
            .keyboardCandidateReady(sequence: 1, phase: phase)
        )
    }
    try collection.consume(.finish)
}

private final class RecordingArtifactVerifier:
    VoicePerformanceArtifactVerifying,
    @unchecked Sendable
{
    private(set) var callCount = 0
    let evidence = VoicePerformanceArtifactEvidence(
        artifactID: "model-v1",
        artifactContentSHA256: String(repeating: "b", count: 64),
        adapterID: "sherpa-onnx",
        engineID: "sherpa-onnx@bbbbbbbbbbbbbbbb",
        modelID: "zh-small",
        modelRevision: "2026.08",
        verifiedPayloadBytes: 1_024,
        verifiedFileCount: 1
    )

    func verifyArtifact(
        at artifactDirectory: URL
    ) throws -> VoicePerformanceArtifactEvidence {
        callCount += 1
        return evidence
    }
}

private final class FailingArtifactVerifier:
    VoicePerformanceArtifactVerifying,
    @unchecked Sendable
{
    private(set) var callCount = 0

    func verifyArtifact(
        at artifactDirectory: URL
    ) throws -> VoicePerformanceArtifactEvidence {
        callCount += 1
        throw VoicePerformanceCollectorError.invalidArtifact
    }
}

private final class FakePerformancePlatform:
    VoicePerformancePlatform,
    @unchecked Sendable
{
    var timeNanoseconds: UInt64 = 0
    var residentBytes: UInt64 = 10_000
    var snapshotAdvanceNanoseconds: UInt64 = 0
    var continuousTimeAdvanceNanoseconds: UInt64 = 0
    var userCPUNanosecondsOverride: UInt64?
    var systemCPUNanosecondsOverride: UInt64?
    var energyNanojoulesOverride: UInt64?
    var hardwareModel = "Mac15,7"

    func verifyCollectorIdentity(
        expectedSHA256: String,
        expectedTeamIdentifier: String
    ) throws {}

    func environmentSnapshot() throws -> VoicePerformanceEnvironmentSnapshot {
        VoicePerformanceEnvironmentSnapshot(
            hardwareModel: hardwareModel,
            physicalMemoryBytes: 8_589_934_592,
            logicalCPUCount: 8,
            powerSource: .ac,
            lowPowerMode: false,
            thermalState: .nominal
        )
    }

    func continuousTimeNanoseconds() throws -> UInt64 {
        timeNanoseconds += continuousTimeAdvanceNanoseconds
        return timeNanoseconds
    }

    func attestedSnapshot(
        for process: VoicePerformanceProcessPlan,
        expectedTeamIdentifier: String
    ) throws -> VoicePerformanceProcessSnapshot {
        timeNanoseconds += snapshotAdvanceNanoseconds
        let roleOffset = UInt64(
            VoicePerformanceProcessRole.allCases.firstIndex(of: process.role)!
                + 1
        ) * 1_000
        return VoicePerformanceProcessSnapshot(
            processIdentifier: process.processIdentifier,
            processStartAbsoluteTime: roleOffset,
            userCPUNanoseconds: userCPUNanosecondsOverride
                ?? timeNanoseconds + roleOffset,
            systemCPUNanoseconds: systemCPUNanosecondsOverride
                ?? timeNanoseconds / 2 + roleOffset,
            energyNanojoules: energyNanojoulesOverride
                ?? timeNanoseconds * 2 + roleOffset,
            residentBytes: residentBytes,
            physicalFootprintBytes: residentBytes + 500
        )
    }
}

private final class FakeDarwinPerformanceSystem:
    DarwinVoicePerformanceSystem,
    @unchecked Sendable
{
    var calls: [String] = []
    private var readCount = 0
    var collectorSigningIdentifierValue =
        "fun.wwcn.rimeai.voice-performance-collector"
    var secondProcessStartAbsoluteTime: UInt64 = 4_242
    var secondProcessExitAbsoluteTime: UInt64 = 0
    var processEffectiveUserID: uid_t = 501
    var processExecutablePath =
        "/Applications/RimeAIInputMethod.app/Contents/MacOS/RimeAIInputMethod"
    var processSigningIdentifier = "fun.wwcn.inputmethod.RimeAI"
    var processTeamIdentifier = "TEAMID1234"
    var processCDHash = String(repeating: "1", count: 40)
    var acceptsCollectorDeveloperID = true
    var acceptsProcessDeveloperID = true

    var effectiveUserID: uid_t { 501 }

    func collectorExecutableSHA256() throws -> String {
        String(repeating: "a", count: 64)
    }

    func collectorTeamIdentifier() throws -> String { "TEAMID1234" }

    func collectorSigningIdentifier() throws -> String {
        collectorSigningIdentifierValue
    }

    func validateCollectorDeveloperID(
        signingIdentifier: String,
        teamIdentifier: String
    ) throws {
        if !acceptsCollectorDeveloperID {
            throw VoicePerformanceCollectorError.invalidCollectorIdentity
        }
    }

    func validateDeveloperID(
        processIdentifier: pid_t,
        signingIdentifier: String,
        teamIdentifier: String
    ) throws {
        if !acceptsProcessDeveloperID {
            throw VoicePerformanceCollectorError.invalidProcessIdentity
        }
    }

    func environmentSnapshot() throws -> VoicePerformanceEnvironmentSnapshot {
        VoicePerformanceEnvironmentSnapshot(
            hardwareModel: "Mac15,7",
            physicalMemoryBytes: 8_589_934_592,
            logicalCPUCount: 8,
            powerSource: .ac,
            lowPowerMode: false,
            thermalState: .nominal
        )
    }

    func continuousTimeNanoseconds() throws -> UInt64 { 123 }

    func rusageV6(processIdentifier: pid_t) throws
        -> DarwinVoicePerformanceRUsageV6
    {
        calls.append("rusage")
        readCount += 1
        return DarwinVoicePerformanceRUsageV6(
            processStartAbsoluteTime: readCount == 1
                ? 4_242
                : secondProcessStartAbsoluteTime,
            processExitAbsoluteTime: readCount == 1
                ? 0
                : secondProcessExitAbsoluteTime,
            userCPUNanoseconds: UInt64(readCount * 10),
            systemCPUNanoseconds: UInt64(readCount * 10 + 10),
            energyNanojoules: UInt64(readCount * 10 + 20),
            residentBytes: UInt64(readCount * 10 + 30),
            physicalFootprintBytes: UInt64(readCount * 10 + 40)
        )
    }

    func processIdentity(processIdentifier: pid_t) throws
        -> DarwinVoicePerformanceProcessIdentity
    {
        calls.append("identity")
        return DarwinVoicePerformanceProcessIdentity(
            effectiveUserID: processEffectiveUserID,
            executablePath: processExecutablePath,
            signingIdentifier: processSigningIdentifier,
            teamIdentifier: processTeamIdentifier,
            cdHash: processCDHash
        )
    }
}
