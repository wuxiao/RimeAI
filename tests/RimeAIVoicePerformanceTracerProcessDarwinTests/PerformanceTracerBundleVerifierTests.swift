import Darwin
import Foundation
import RimeAIVoicePerformanceControlCore
import Testing
@testable import RimeAIVoicePerformanceTracerProcessDarwin

@Suite("Signed performance tracer bundle verifier")
struct PerformanceTracerBundleVerifierTests {
    @Test("live executable paths reject ACLs and renameable ancestors")
    func executablePathFilesystemAuthorityIsClosed() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "rimeai-tracer-path-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: root) }
        let secureChild = root.appendingPathComponent(
            "Secure",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: secureChild,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let executable = secureChild.appendingPathComponent("tracer-child")
        try Data("signed-placeholder".utf8).write(to: executable)
        try fileManager.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: executable.path
        )

        let system = MacOSPerformanceTracerBundleVerifierSystem()
        _ = try system.executableFileIdentity(
            at: executable.path,
            maximumBytes: 1_024
        )

        try fileManager.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: root.path
        )
        #expect(throws: Error.self) {
            try system.executableFileIdentity(
                at: executable.path,
                maximumBytes: 1_024
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = [
            "+a", "\(NSUserName()) allow read", executable.path,
        ]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        guard chmod.terminationStatus == 0 else { return }

        #expect(throws: Error.self) {
            try system.executableFileIdentity(
                at: executable.path,
                maximumBytes: 1_024
            )
        }
    }

    @Test("bundle paths require byte-exact NFC rather than Swift canonical equality")
    func bundlePathsRequireByteExactNFC() {
        let decomposed = "/Applications/Cafe\u{301}.bundle"

        #expect(
            !PerformanceTracerBundleVerifier.isCanonicalAbsolutePath(
                decomposed
            )
        )
    }

    @Test("collector accepts one sealed bundle and binds both canonical policies")
    func collectorAcceptsSealedBundleAndBothPolicies() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(role: .collector)

        let context = try PerformanceTracerBundleVerifier(
            system: fixture.system
        ).verify(
            role: .collector,
            declaredTracerBundlePath: fixture.bundlePath
        )

        #expect(context.outerPath == fixture.bundlePath)
        #expect(context.outerURL.path == context.outerPath)
        #expect(context.measurementPolicy == fixture.measurementPolicy)
        #expect(context.driverPolicy == fixture.driverPolicy)
        #expect(context.selfStartToken == fixture.startToken)
        #expect(!context.authenticatedProductionDriver)
        #expect(
            fixture.system.resourceRequests == [
                "Contents/Resources/VoicePerformanceMeasurementPolicy.json",
                "Contents/Resources/VoicePerformanceDriverPolicy.json",
            ]
        )
    }

    @Test("helper verifies measurement policy without reading driver policy")
    func helperDoesNotReadDriverPolicy() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(role: .helper)

        let context = try PerformanceTracerBundleVerifier(
            system: fixture.system
        ).verify(
            role: .helper,
            declaredTracerBundlePath: fixture.bundlePath
        )

        #expect(context.driverPolicy == nil)
        #expect(
            fixture.system.resourceRequests == [
                "Contents/Resources/VoicePerformanceMeasurementPolicy.json"
            ]
        )
    }

    @Test("driver accepts the same sealed measurement and driver policies")
    func driverAcceptsBothPolicies() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(role: .driver)

        let context = try PerformanceTracerBundleVerifier(
            system: fixture.system
        ).verify(
            role: .driver,
            declaredTracerBundlePath: fixture.bundlePath
        )

        #expect(context.driverPolicy == fixture.driverPolicy)
        #expect(context.selfStartToken == fixture.startToken)
    }

    @Test("resource seal cannot splice outer A with policy B")
    func resourceSealRejectsOuterPolicySplice() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.resourceSealToken = String(repeating: "e", count: 64)

        try expectRejected(fixture)
    }

    @Test("bundle cannot move away from policy-bound child paths")
    func movedBundleIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.executablePath =
            "/Applications/MovedPerformanceTracer.bundle"
            + VoicePerformanceTracerBundleLayout.collectorExecutableSuffix

        try expectRejected(
            fixture,
            declaredBundlePath:
                "/Applications/MovedPerformanceTracer.bundle"
        )
    }

    @Test("argv bundle path must equal the outer derived from live self")
    func declaredOuterMismatchIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )

        try expectRejected(
            fixture,
            declaredBundlePath: "/Applications/OtherTracer.bundle"
        )
    }

    @Test("each role has one fixed full child executable suffix")
    func wrongRoleExecutableSuffixIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.executablePath =
            fixture.bundlePath
            + VoicePerformanceTracerBundleLayout.driverExecutableSuffix

        try expectRejected(fixture)
    }

    @Test("policy binds every child path even when verifying collector")
    func wrongNonSelfChildPathIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        let text = String(
            decoding: fixture.measurementPolicyData,
            as: UTF8.self
        )
        fixture.system.measurementPolicyData = Data(
            text.replacingOccurrences(
                of: fixture.measurementPolicy
                    .helper.expectedExecutablePath,
                with: "/Applications/unbound-helper"
            ).utf8
        )

        try expectRejected(fixture)
    }

    @Test("outer signing identifier is exact")
    func wrongOuterIdentifierIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.outerSigningIdentifier =
            "fun.wwcn.rimeai.voice-performance-tracer.other"

        try expectRejected(fixture)
    }

    @Test("all policy identities are pinned to the outer Team ID")
    func wrongOuterTeamIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.outerTeamIdentifier = "ZYXWVUTSRQ"

        try expectRejected(fixture)
    }

    @Test("outer validation requires strict all-architecture nested seal")
    func incompleteOuterSealIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.outerNestedSealValidated = false

        try expectRejected(fixture)
    }

    @Test("outer seal is sandwiched around resource reads")
    func outerSwapDuringResourceReadsIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.secondOuterSealToken =
            String(repeating: "d", count: 64)

        try expectRejected(fixture)
    }

    @Test("self CDHash is exact")
    func wrongSelfCDHashIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.selfCDHash = String(repeating: "0", count: 40)

        try expectRejected(fixture)
    }

    @Test("self signing identifier is exact")
    func wrongSelfSigningIdentifierIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.selfSigningIdentifier =
            "fun.wwcn.rimeai.voice-performance-collector.other"

        try expectRejected(fixture)
    }

    @Test("self Team ID equals the verified outer Team ID")
    func wrongSelfTeamIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.selfTeamIdentifier = "ZYXWVUTSRQ"

        try expectRejected(fixture)
    }

    @Test("self executable SHA-256 is exact")
    func wrongSelfExecutableSHAIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.executableSHA256 =
            String(repeating: "0", count: 64)

        try expectRejected(fixture)
    }

    @Test("self static-code path must equal the live process path")
    func wrongSelfCodePathIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.selfExecutablePath = "/Applications/other"

        try expectRejected(fixture)
    }

    @Test("self code requires hardened runtime")
    func selfWithoutHardenedRuntimeIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.selfCodeDirectoryFlags = 0

        try expectRejected(fixture)
    }

    @Test("self code rejects debugger and relaxed runtime entitlements")
    func selfWithDisallowedEntitlementsIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.selfHasAnyEntitlements = true

        try expectRejected(fixture)
    }

    @Test("any entitlement payload is present even when empty or all false")
    func emptyAndFalseEntitlementPayloadsArePresent() {
        #expect(
            MacOSPerformanceTracerBundleVerifierSystem.hasAnyEntitlements(
                entitlementData: nil,
                entitlementDictionary: [String: Any]()
            )
        )
        #expect(
            MacOSPerformanceTracerBundleVerifierSystem.hasAnyEntitlements(
                entitlementData: nil,
                entitlementDictionary: ["com.example.flag": false]
            )
        )
        #expect(
            MacOSPerformanceTracerBundleVerifierSystem.hasAnyEntitlements(
                entitlementData: Data(),
                entitlementDictionary: nil
            )
        )
        #expect(
            !MacOSPerformanceTracerBundleVerifierSystem.hasAnyEntitlements(
                entitlementData: nil,
                entitlementDictionary: nil
            )
        )
    }

    @Test("a live process that was debugged cannot produce tracer evidence")
    func debuggedSelfIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.selfIsDebugged = true

        try expectRejected(fixture)
    }

    @Test("resource open must reject symlinks component by component")
    func symlinkedResourceIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.resourceOpenedWithoutSymlinks = false

        try expectRejected(fixture)
    }

    @Test("resource mode cannot be group or world writable")
    func unsafeResourceModeIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.resourceMode =
            mode_t(S_IFREG | S_IRUSR | S_IWGRP)

        try expectRejected(fixture)
    }

    @Test("resource bytes must match the bounded stable file size")
    func wrongResourceSizeIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.resourceReportedSize =
            UInt64(fixture.measurementPolicyData.count + 1)

        try expectRejected(fixture)
    }

    @Test("resource reader is bounded before policy decoding")
    func oversizedResourceIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        let size =
            VoicePerformanceMeasurementPolicy.maximumEncodedBytes + 1
        fixture.system.measurementPolicyData = Data(
            repeating: 0x20,
            count: size
        )
        fixture.system.resourceReportedSize = UInt64(size)

        try expectRejected(fixture)
    }

    @Test("resource device inode size and timestamps are sandwiched")
    func swappedResourceIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.resourceSwapped = true

        try expectRejected(fixture)
    }

    @Test("self PID generation is sandwiched around all verification")
    func changedSelfGenerationIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.finalStartToken = fixture.startToken + 1

        try expectRejected(fixture)
    }

    @Test("self snapshot must represent one live nonzero generation")
    func zeroSelfGenerationIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.startToken = 0

        try expectRejected(fixture)
    }

    @Test("driver policy protocol is pinned by measurement policy")
    func mismatchedDriverProtocolIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .driver
        )
        fixture.system.driverPolicyData = Self.driverPolicyData(
            protocolSHA256: String(repeating: "8", count: 64),
            qualification: "tracer",
            capabilities: [
                "authenticated_control",
                "lazy_load_ticket",
            ]
        )

        try expectRejected(fixture)
    }

    @Test("measurement policy pins canonical driver-policy SHA-256")
    func mismatchedDriverPolicyDigestIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        fixture.system.driverPolicyData = Self.driverPolicyData(
            protocolSHA256:
                fixture.measurementPolicy.controlProtocol.sha256,
            qualification: "production",
            capabilities: [
                "authenticated_control",
                "corpus_sessions",
                "helper_generation_rotation",
                "keyboard_phases",
                "late_challenges",
                "lazy_load_ticket",
            ]
        )

        try expectRejected(fixture)
    }

    @Test("runtime admission pins the code-owned control protocol contract")
    func nonCodeOwnedControlProtocolIsRejected() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector,
            protocolSHA256: String(repeating: "9", count: 64)
        )

        try expectRejected(fixture)
    }

    @Test("unexpected verifier system errors are not misclassified as rejection")
    func unexpectedSystemErrorPropagates() throws {
        let fixture = try PerformanceTracerBundleVerifierFixture(
            role: .collector
        )
        let unexpected = VerifierUnexpectedError(
            description: "verifier-secret-c152"
        )
        fixture.system.processSnapshotFailure = unexpected

        #expect(throws: unexpected) {
            try PerformanceTracerBundleVerifier(
                system: fixture.system
            ).verify(
                role: fixture.role,
                declaredTracerBundlePath: fixture.bundlePath
            )
        }
    }

    private func expectRejected(
        _ fixture: PerformanceTracerBundleVerifierFixture,
        declaredBundlePath: String? = nil
    ) throws {
        #expect(
            throws:
                VoicePerformanceTracerProcessError.invalidTracerBundle
        ) {
            try PerformanceTracerBundleVerifier(
                system: fixture.system
            ).verify(
                role: fixture.role,
                declaredTracerBundlePath:
                    declaredBundlePath ?? fixture.bundlePath
            )
        }
    }

    private static func driverPolicyData(
        protocolSHA256: String,
        qualification: String,
        capabilities: [String]
    ) -> Data {
        let capabilityJSON = capabilities.map { "\"\($0)\"" }
            .joined(separator: ",")
        return Data(
            ("{\"capabilities\":[\(capabilityJSON)],"
                + "\"control_protocol\":{\"id\":\"\(PerformanceControlProtocolIdentity.requiredID)\","
                + "\"sha256\":\"\(protocolSHA256)\"},"
                + "\"qualification\":\"\(qualification)\","
                + "\"schema_version\":1}").utf8
        )
    }
}

private final class PerformanceTracerBundleVerifierFixture {
    let role: VoicePerformanceTracerProcessRole
    let bundlePath = "/Applications/RimeAIVoicePerformanceTracer.bundle"
    let startToken: UInt64 = 4_242
    let driverPolicyData: Data
    let driverPolicy: SealedPerformanceControlDriverPolicy
    let measurementPolicyData: Data
    let measurementPolicy: VoicePerformanceMeasurementPolicy
    let system: FakePerformanceTracerBundleVerifierSystem

    init(
        role: VoicePerformanceTracerProcessRole,
        protocolSHA256: String =
            PerformanceControlProtocolContract.identity.sha256
    ) throws {
        self.role = role
        let protocolID = PerformanceControlProtocolIdentity.requiredID
        let protocolSHA = protocolSHA256
        driverPolicyData = Data(
            ("{\"capabilities\":[\"authenticated_control\",\"lazy_load_ticket\"],"
                + "\"control_protocol\":{\"id\":\"\(protocolID)\","
                + "\"sha256\":\"\(protocolSHA)\"},"
                + "\"qualification\":\"tracer\",\"schema_version\":1}").utf8
        )
        let protocolIdentity = try PerformanceControlProtocolIdentity(
            id: protocolID,
            sha256: protocolSHA
        )
        driverPolicy = try SealedPerformanceControlDriverPolicy.decodeCanonical(
            driverPolicyData,
            expectedControlProtocol: protocolIdentity
        )
        let collectorPath = bundlePath
            + VoicePerformanceTracerBundleLayout.collectorExecutableSuffix
        let driverPath = bundlePath
            + VoicePerformanceTracerBundleLayout.driverExecutableSuffix
        let helperPath = bundlePath
            + VoicePerformanceTracerBundleLayout.helperExecutableSuffix
        measurementPolicyData = Data(
            ("{\"cold_trials\":3,"
                + "\"collector\":{\"expected_cdhash\":\"\(String(repeating: "1", count: 40))\","
                + "\"expected_executable_path\":\"\(collectorPath)\","
                + "\"expected_executable_sha256\":\"\(String(repeating: "a", count: 64))\","
                + "\"expected_signing_identifier\":\"\(VoicePerformanceMeasurementPolicy.requiredCollectorSigningIdentifier)\","
                + "\"expected_team_identifier\":\"ABCDEFGHIJ\"},"
                + "\"control_protocol\":{\"id\":\"\(protocolID)\",\"sha256\":\"\(protocolSHA)\"},"
                + "\"control_session_nonce\":\"\(String(repeating: "7", count: 64))\","
                + "\"control_socket_path\":\"/tmp/rimeai-performance.sock\","
                + "\"driver\":{\"expected_cdhash\":\"\(String(repeating: "2", count: 40))\","
                + "\"expected_executable_path\":\"\(driverPath)\","
                + "\"expected_executable_sha256\":\"\(String(repeating: "b", count: 64))\","
                + "\"expected_signing_identifier\":\"\(VoicePerformanceMeasurementPolicy.requiredDriverSigningIdentifier)\","
                + "\"expected_team_identifier\":\"ABCDEFGHIJ\","
                + "\"policy_sha256\":\"\(driverPolicy.canonicalSHA256.rawValue)\"},"
                + "\"enabled\":true,"
                + "\"evaluation_artifact\":{\"adapter_id\":\"sherpa-onnx\","
                + "\"artifact_id\":\"fixture-artifact\","
                + "\"content_sha256\":\"\(String(repeating: "d", count: 64))\","
                + "\"directory\":\"/Library/Application Support/RimeAI/fixture\","
                + "\"maximum_hotwords\":64},"
                + "\"helper\":{\"expected_cdhash\":\"\(String(repeating: "3", count: 40))\","
                + "\"expected_executable_path\":\"\(helperPath)\","
                + "\"expected_executable_sha256\":\"\(String(repeating: "c", count: 64))\","
                + "\"expected_signing_identifier\":\"\(VoicePerformanceMeasurementPolicy.requiredHelperSigningIdentifier)\","
                + "\"expected_team_identifier\":\"ABCDEFGHIJ\"},"
                + "\"release_policy_sha256\":\"\(String(repeating: "e", count: 64))\","
                + "\"schema_version\":2}").utf8
        )
        measurementPolicy = try VoicePerformanceMeasurementPolicy.decodeCanonical(
            measurementPolicyData
        )
        let expected = Self.expectedIdentity(
            role: role,
            measurementPolicy: measurementPolicy
        )
        system = FakePerformanceTracerBundleVerifierSystem(
            executablePath: expected.path,
            startToken: startToken,
            measurementPolicyData: measurementPolicyData,
            driverPolicyData: driverPolicyData,
            expectedIdentity: expected
        )
    }

    private static func expectedIdentity(
        role: VoicePerformanceTracerProcessRole,
        measurementPolicy: VoicePerformanceMeasurementPolicy
    ) -> (path: String, sha256: String, signingID: String, cdHash: String) {
        switch role {
        case .collector:
            return (
                measurementPolicy.collector.expectedExecutablePath,
                measurementPolicy.collector.expectedExecutableSHA256,
                measurementPolicy.collector.expectedSigningIdentifier,
                measurementPolicy.collector.expectedCDHash
            )
        case .driver:
            return (
                measurementPolicy.driver.expectedExecutablePath,
                measurementPolicy.driver.expectedExecutableSHA256,
                measurementPolicy.driver.expectedSigningIdentifier,
                measurementPolicy.driver.expectedCDHash
            )
        case .helper:
            return (
                measurementPolicy.helper.expectedExecutablePath,
                measurementPolicy.helper.expectedExecutableSHA256,
                measurementPolicy.helper.expectedSigningIdentifier,
                measurementPolicy.helper.expectedCDHash
            )
        }
    }
}

private final class FakePerformanceTracerBundleVerifierSystem:
    PerformanceTracerBundleVerifyingSystem,
    @unchecked Sendable
{
    let effectiveUserID: uid_t = 501
    let currentProcessIdentifier: pid_t = 123
    var executablePath: String
    var startToken: UInt64
    var measurementPolicyData: Data
    var driverPolicyData: Data
    var expectedIdentity: (
        path: String,
        sha256: String,
        signingID: String,
        cdHash: String
    )
    var outerSigningIdentifier =
        PerformanceTracerBundleVerifier.requiredOuterSigningIdentifier
    var outerTeamIdentifier = "ABCDEFGHIJ"
    var outerCDHash = String(repeating: "f", count: 40)
    var outerSealToken = String(repeating: "f", count: 64)
    var secondOuterSealToken: String?
    var outerDeveloperIDValidated = true
    var outerStrictValidation = true
    var outerAllArchitecturesValidated = true
    var outerNestedSealValidated = true
    var resourceSourceBundlePath: String?
    var resourceSealToken: String?
    var resourceOpenedWithoutSymlinks = true
    var resourceMode = mode_t(S_IFREG | S_IRUSR)
    var resourceReportedSize: UInt64?
    var resourceSwapped = false
    var selfExecutablePath: String?
    var selfSigningIdentifier: String?
    var selfTeamIdentifier: String?
    var selfCDHash: String?
    var selfCodeDirectoryFlags =
        PerformanceTracerSelfCodeIdentity.hardenedRuntimeFlag
    var selfHasAnyEntitlements = false
    var selfIsDebugged = false
    var selfDeveloperIDValidated = true
    var selfStrictValidation = true
    var selfAllArchitecturesValidated = true
    var executableSHA256: String?
    var executableOwnerEUID: uid_t?
    var executableMode = mode_t(S_IFREG | S_IRUSR | S_IXUSR)
    var executableSize: UInt64 = 1_024
    var executableStable = true
    var executableOpenedWithoutSymlink = true
    var finalStartToken: UInt64?
    var finalExitToken: UInt64 = 0
    var finalUserCPUNanoseconds: UInt64 = 10
    var finalSystemCPUNanoseconds: UInt64 = 20
    var finalEnergyNanojoules: UInt64 = 30
    var processSnapshotFailure: Error?
    private(set) var resourceRequests: [String] = []
    private var processSnapshotCount = 0
    private var outerIdentityCount = 0

    init(
        executablePath: String,
        startToken: UInt64,
        measurementPolicyData: Data,
        driverPolicyData: Data,
        expectedIdentity: (
            path: String,
            sha256: String,
            signingID: String,
            cdHash: String
        )
    ) {
        self.executablePath = executablePath
        self.startToken = startToken
        self.measurementPolicyData = measurementPolicyData
        self.driverPolicyData = driverPolicyData
        self.expectedIdentity = expectedIdentity
    }

    func processSnapshot(pid: pid_t) throws -> PerformanceTracerProcessSnapshot {
        processSnapshotCount += 1
        if let processSnapshotFailure {
            throw processSnapshotFailure
        }
        let isFinal = processSnapshotCount > 1
        return PerformanceTracerProcessSnapshot(
            pid: pid,
            startToken:
                isFinal ? (finalStartToken ?? startToken) : startToken,
            exitToken: isFinal ? finalExitToken : 0,
            userCPUNanoseconds:
                isFinal ? finalUserCPUNanoseconds : 10,
            systemCPUNanoseconds:
                isFinal ? finalSystemCPUNanoseconds : 20,
            energyNanojoules: isFinal ? finalEnergyNanojoules : 30
        )
    }

    func currentExecutablePath(pid: pid_t) throws -> String {
        executablePath
    }

    func outerCodeIdentity(
        at bundlePath: String
    ) throws -> PerformanceTracerOuterCodeIdentity {
        outerIdentityCount += 1
        return PerformanceTracerOuterCodeIdentity(
            bundlePath: bundlePath,
            signingIdentifier: outerSigningIdentifier,
            teamIdentifier: outerTeamIdentifier,
            cdHash: outerCDHash,
            sealToken:
                outerIdentityCount > 1
                    ? (secondOuterSealToken ?? outerSealToken)
                    : outerSealToken,
            developerIDValidated: outerDeveloperIDValidated,
            strictValidation: outerStrictValidation,
            allArchitecturesValidated:
                outerAllArchitecturesValidated,
            nestedSealValidated: outerNestedSealValidated
        )
    }

    func readSealedResource(
        relativePath: String,
        from bundlePath: String,
        maximumBytes: Int,
        outerSealToken: String
    ) throws -> PerformanceTracerSealedResource {
        resourceRequests.append(relativePath)
        let data: Data
        switch relativePath {
        case "Contents/Resources/VoicePerformanceMeasurementPolicy.json":
            data = measurementPolicyData
        case "Contents/Resources/VoicePerformanceDriverPolicy.json":
            data = driverPolicyData
        default:
            throw VoicePerformanceTracerProcessError.invalidTracerBundle
        }
        let stat = PerformanceTracerStableFileIdentity(
            device: 1,
            inode: UInt64(resourceRequests.count),
            size: resourceReportedSize ?? UInt64(data.count),
            ownerEUID: effectiveUserID,
            mode: resourceMode,
            modificationSeconds: 1,
            modificationNanoseconds: 2,
            changeSeconds: 3,
            changeNanoseconds: 4
        )
        let after = resourceSwapped
            ? PerformanceTracerStableFileIdentity(
                device: stat.device,
                inode: stat.inode + 100,
                size: stat.size,
                ownerEUID: stat.ownerEUID,
                mode: stat.mode,
                modificationSeconds: stat.modificationSeconds,
                modificationNanoseconds: stat.modificationNanoseconds,
                changeSeconds: stat.changeSeconds,
                changeNanoseconds: stat.changeNanoseconds
            )
            : stat
        return PerformanceTracerSealedResource(
            data: data,
            relativePath: relativePath,
            sourceBundlePath: resourceSourceBundlePath ?? bundlePath,
            outerSealToken: resourceSealToken ?? outerSealToken,
            openedComponentWiseWithoutSymlinks:
                resourceOpenedWithoutSymlinks,
            before: stat,
            after: after
        )
    }

    func selfCodeIdentity(
        at executablePath: String,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> PerformanceTracerSelfCodeIdentity {
        PerformanceTracerSelfCodeIdentity(
            executablePath: selfExecutablePath ?? executablePath,
            signingIdentifier:
                selfSigningIdentifier ?? expectedIdentity.signingID,
            teamIdentifier:
                selfTeamIdentifier ?? expectedTeamIdentifier,
            cdHash: selfCDHash ?? expectedIdentity.cdHash,
            codeDirectoryFlags: selfCodeDirectoryFlags,
            hasAnyEntitlements:
                selfHasAnyEntitlements,
            isDebugged: selfIsDebugged,
            developerIDValidated: selfDeveloperIDValidated,
            strictValidation: selfStrictValidation,
            allArchitecturesValidated:
                selfAllArchitecturesValidated
        )
    }

    func executableFileIdentity(
        at executablePath: String,
        maximumBytes: UInt64
    ) throws -> PerformanceTracerExecutableFileIdentity {
        PerformanceTracerExecutableFileIdentity(
            sha256: executableSHA256 ?? expectedIdentity.sha256,
            ownerEUID: executableOwnerEUID ?? effectiveUserID,
            mode: executableMode,
            size: executableSize,
            stable: executableStable,
            openedWithoutSymlink: executableOpenedWithoutSymlink
        )
    }
}

private struct VerifierUnexpectedError:
    Error,
    Equatable,
    CustomStringConvertible
{
    let description: String
}
