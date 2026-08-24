import CryptoKit
import Foundation
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceTracerProcessDarwin
import Testing
@testable import RimeAIVoicePerformanceTracerBundleBuilder

@Suite("Voice performance tracer bundle builder", .serialized)
struct VoicePerformanceTracerBundleBuilderTests {
    @Test("vertical slice seals raw inputs and signs children before outer")
    func verticalSliceIsOrderedAndCanonical() throws {
        let fixture = BuilderFixture()

        let receipt = try fixture.builder.build(fixture.request)

        #expect(receipt.finalBundlePath == fixture.request.finalBundlePath)
        #expect(receipt.teamIdentifier == "ABCDEFGHIJ")
        let invocations = fixture.signer.invocations
        #expect(invocations.count == 4)
        #expect(invocations.map(\.signingIdentifier) == [
            "fun.wwcn.rimeai.voice-performance-collector",
            "fun.wwcn.rimeai.voice-performance-driver",
            "fun.wwcn.rimeai.voice-helper",
            "fun.wwcn.rimeai.voice-performance-tracer",
        ])
        for invocation in invocations.dropLast() {
            #expect(invocation.hardenedRuntime)
            #expect(invocation.arguments.contains("--options"))
            #expect(invocation.arguments.contains("runtime"))
            #expect(invocation.arguments.contains("--timestamp"))
            #expect(invocation.arguments.contains("--keychain"))
            #expect(!invocation.arguments.contains("--deep"))
            #expect(!invocation.arguments.contains("--entitlements"))
        }
        let outerInvocation = try #require(invocations.last)
        #expect(!outerInvocation.hardenedRuntime)
        #expect(!outerInvocation.arguments.contains("--options"))
        #expect(!outerInvocation.arguments.contains("runtime"))
        #expect(outerInvocation.arguments.contains("--timestamp"))
        #expect(outerInvocation.arguments.contains("--keychain"))
        #expect(!outerInvocation.arguments.contains("--deep"))
        #expect(!outerInvocation.arguments.contains("--entitlements"))

        let driverData = try #require(
            fixture.fileSystem.writtenFile(
                endingIn:
                    VoicePerformanceTracerBundleLayout
                        .driverPolicyResourceRelativePath
            )
        )
        #expect(
            driverData
                == (try SealedPerformanceControlDriverPolicy
                    .tracerCanonicalData())
        )
        let measurementData = try #require(
            fixture.fileSystem.writtenFile(
                endingIn:
                    VoicePerformanceTracerBundleLayout
                        .measurementPolicyResourceRelativePath
            )
        )
        let measurement = try VoicePerformanceMeasurementPolicy
            .decodeCanonical(measurementData)
        let final = fixture.request.finalBundlePath
        #expect(
            measurement.collector.expectedExecutablePath
                == final
                    + VoicePerformanceTracerBundleLayout
                        .collectorExecutableSuffix
        )
        #expect(
            measurement.driver.expectedExecutablePath
                == final
                    + VoicePerformanceTracerBundleLayout
                        .driverExecutableSuffix
        )
        #expect(
            measurement.helper.expectedExecutablePath
                == final
                    + VoicePerformanceTracerBundleLayout
                        .helperExecutableSuffix
        )
        #expect(!String(decoding: measurementData, as: UTF8.self)
            .contains(".staging-"))
        #expect(measurement.evaluationArtifact.maximumHotwords == 64)
        #expect(
            measurement.driver.policySHA256 == Self.sha256(driverData)
        )
        let rawReleasePolicy = try Data(
            contentsOf: URL(fileURLWithPath: fixture.request.repositoryRootPath)
                .appendingPathComponent(
                    "macos/VoiceHelper/VoiceReleasePolicy.plist"
                )
        )
        #expect(
            measurement.releasePolicySHA256
                == Self.sha256(rawReleasePolicy)
        )
        #expect(
            receipt.rawReleasePolicySHA256
                == Self.sha256(rawReleasePolicy)
        )
        #expect(
            receipt.measurementPolicyFileSHA256
                == Self.sha256(measurementData)
        )
        #expect(
            receipt.measurementPolicyCanonicalSHA256
                == measurement.canonicalSHA256
        )
        #expect(
            receipt.measurementPolicyFileSHA256
                != receipt.measurementPolicyCanonicalSHA256
        )
        let receiptObject = try #require(
            JSONSerialization.jsonObject(
                with: receipt.canonicalJSONData()
            ) as? [String: String]
        )
        #expect(
            Set(receiptObject.keys) == [
                "bundle_path",
                "measurement_policy_canonical_sha256",
                "measurement_policy_file_sha256",
                "raw_release_policy_sha256",
                "team_identifier",
            ]
        )
        #expect(
            receiptObject["measurement_policy_file_sha256"]
                == Self.sha256(measurementData)
        )
        #expect(
            receiptObject["measurement_policy_canonical_sha256"]
                == measurement.canonicalSHA256
        )

        let operations = fixture.recorder.operations
        let releaseRead = try Self.index(
            of: "read:VoiceReleasePolicy.plist",
            in: operations
        )
        let artifact = try Self.index(of: "artifact", in: operations)
        let collectorSign = try Self.index(of: "sign:collector", in: operations)
        let driverSign = try Self.index(of: "sign:driver", in: operations)
        let helperSign = try Self.index(of: "sign:helper", in: operations)
        let treeBefore = try Self.index(of: "tree:before", in: operations)
        let outerSign = try Self.index(of: "sign:outer", in: operations)
        let flush = try Self.index(of: "flush", in: operations)
        let install = try Self.index(of: "install", in: operations)
        #expect(releaseRead < artifact)
        #expect(collectorSign < driverSign)
        #expect(driverSign < helperSign)
        #expect(treeBefore < outerSign)
        #expect(outerSign < flush)
        #expect(flush < install)
    }

    @Test("an existing final output is never staged or overwritten")
    func outputExistsFailsBeforeStaging() {
        let fixture = BuilderFixture()
        fixture.fileSystem.outputExists = true

        #expect(
            throws: VoicePerformanceTracerBundleBuildError
                .outputAlreadyExists
        ) {
            try fixture.builder.build(fixture.request)
        }
        #expect(fixture.signer.invocations.isEmpty)
        #expect(!fixture.recorder.operations.contains("stage"))
        #expect(!fixture.recorder.operations.contains("install"))
    }

    @Test("entitlement evidence is rejected and staging is removed")
    func entitlementEvidenceFailsClosed() {
        let fixture = BuilderFixture()
        fixture.inspector.entitlementBlobAtInspection = 1

        #expect(
            throws: VoicePerformanceTracerBundleBuildError
                .invalidSigningEvidence
        ) {
            try fixture.builder.build(fixture.request)
        }
        #expect(fixture.recorder.operations.contains("cleanup-stage"))
        #expect(!fixture.recorder.operations.contains("install"))
    }

    @Test("resource-only outer does not claim executable hardened runtime")
    func resourceOnlyOuterNeedsNoHardenedRuntimeFlag() throws {
        let fixture = BuilderFixture()

        let receipt = try fixture.builder.build(fixture.request)

        #expect(receipt.finalBundlePath == fixture.request.finalBundlePath)
        #expect(fixture.recorder.operations.contains("install"))
    }

    @Test("resource-only outer rejects a claimed executable runtime flag")
    func resourceOnlyOuterRejectsClaimedHardenedRuntimeFlag() {
        let fixture = BuilderFixture()
        fixture.inspector.outerHasHardenedRuntimeFlag = true

        #expect(
            throws: VoicePerformanceTracerBundleBuildError
                .invalidSigningEvidence
        ) {
            try fixture.builder.build(fixture.request)
        }
        #expect(fixture.recorder.operations.contains("cleanup-stage"))
        #expect(!fixture.recorder.operations.contains("install"))
    }

    @Test("child evidence drift after outer signing blocks installation")
    func postOuterEvidenceDriftFailsClosed() {
        let fixture = BuilderFixture()
        fixture.inspector.driftAtInspection = 4

        #expect(
            throws: VoicePerformanceTracerBundleBuildError
                .signingEvidenceDrift
        ) {
            try fixture.builder.build(fixture.request)
        }
        #expect(fixture.recorder.operations.contains("cleanup-stage"))
        #expect(!fixture.recorder.operations.contains("install"))
    }

    @Test("final evidence drift rolls back only the installed generation")
    func finalEvidenceDriftRollsBack() {
        let fixture = BuilderFixture()
        fixture.inspector.driftAtInspection = 7

        #expect(
            throws: VoicePerformanceTracerBundleBuildError
                .finalVerificationFailed
        ) {
            try fixture.builder.build(fixture.request)
        }
        #expect(fixture.recorder.operations.contains("install"))
        #expect(fixture.recorder.operations.contains("rollback"))
        #expect(!fixture.recorder.operations.contains("cleanup-stage"))
    }

    @Test("uncertain rollback is surfaced as installation indeterminate")
    func rollbackFailureIsIndeterminate() {
        let fixture = BuilderFixture()
        fixture.inspector.driftAtInspection = 7
        fixture.fileSystem.rollbackFails = true

        #expect(
            throws: VoicePerformanceTracerBundleBuildError
                .installationIndeterminate
        ) {
            try fixture.builder.build(fixture.request)
        }
    }

    @Test("rename committed postcondition failure is rolled back")
    func renameCommittedFailureUsesToken() {
        let fixture = BuilderFixture()
        fixture.fileSystem.installFailure = .renameCommitted(
            .init(device: 7, inode: 11)
        )

        #expect(
            throws: VoicePerformanceTracerBundleBuildError
                .installationFailed
        ) {
            try fixture.builder.build(fixture.request)
        }
        #expect(fixture.recorder.operations.contains("install"))
        #expect(fixture.recorder.operations.contains("rollback"))
        #expect(!fixture.recorder.operations.contains("cleanup-stage"))
    }

    @Test("rename committed without provable rollback is indeterminate")
    func renameCommittedUncertainRollbackIsIndeterminate() {
        let fixture = BuilderFixture()
        fixture.fileSystem.installFailure = .renameCommitted(
            .init(device: 7, inode: 11)
        )
        fixture.fileSystem.rollbackFails = true

        #expect(
            throws: VoicePerformanceTracerBundleBuildError
                .installationIndeterminate
        ) {
            try fixture.builder.build(fixture.request)
        }
    }

    @Test("unknown exact-tree entry fails before outer signing")
    func exactTreeFailureStopsOuterSigning() {
        let fixture = BuilderFixture()
        fixture.fileSystem.failTreePhase = .beforeOuterSignature

        #expect(
            throws: VoicePerformanceTracerBundleBuildError.invalidBundleTree
        ) {
            try fixture.builder.build(fixture.request)
        }
        #expect(fixture.signer.invocations.count == 3)
        #expect(fixture.recorder.operations.contains("cleanup-stage"))
    }

    @Test("strict CLI accepts only non-derived ordered inputs")
    func cliParserOwnsDerivedAuthority() throws {
        let fixture = BuilderFixture()
        let arguments = fixture.cliArguments

        let parsed = try VoicePerformanceTracerBundleBuilderCLI.parse(
            arguments: arguments
        )

        #expect(parsed == fixture.request)
        #expect(
            throws: VoicePerformanceTracerBundleBuilderCLIError
                .invalidArguments
        ) {
            try VoicePerformanceTracerBundleBuilderCLI.parse(
                arguments: arguments + ["--maximum-hotwords", "64"]
            )
        }
        var reordered = arguments
        reordered.swapAt(1, 3)
        #expect(
            throws: VoicePerformanceTracerBundleBuilderCLIError
                .invalidArguments
        ) {
            try VoicePerformanceTracerBundleBuilderCLI.parse(
                arguments: reordered
            )
        }
        var leadingZero = arguments
        leadingZero[12] = "04"
        #expect(
            throws: VoicePerformanceTracerBundleBuilderCLIError
                .invalidArguments
        ) {
            try VoicePerformanceTracerBundleBuilderCLI.parse(
                arguments: leadingZero
            )
        }
        var unicodeVersion = arguments
        unicodeVersion[14] = "١.0"
        #expect(
            throws: VoicePerformanceTracerBundleBuilderCLIError
                .invalidArguments
        ) {
            try VoicePerformanceTracerBundleBuilderCLI.parse(
                arguments: unicodeVersion
            )
        }
        var nonNFCPath = arguments
        nonNFCPath[8] = "/private/tmp/rimeai-e\u{301}valuation-artifact"
        #expect(
            throws: VoicePerformanceTracerBundleBuilderCLIError
                .invalidArguments
        ) {
            try VoicePerformanceTracerBundleBuilderCLI.parse(
                arguments: nonNFCPath
            )
        }
    }

    @Test("CLI failure output is fixed and never leaks request paths")
    func cliFailureIsSafe() {
        let fixture = BuilderFixture()
        fixture.fileSystem.outputExists = true

        let result = VoicePerformanceTracerBundleBuilderCLI.execute(
            arguments: fixture.cliArguments,
            builder: fixture.builder
        )

        #expect(result.exitCode == 70)
        #expect(result.standardOutput.isEmpty)
        #expect(
            String(decoding: result.standardError, as: UTF8.self)
                == "error: bundle build failed\n"
        )
        #expect(
            !String(decoding: result.standardError, as: UTF8.self)
                .contains(fixture.request.finalBundlePath)
        )
    }

    @Test("final bundle cannot overlap a verified input or control authority")
    func finalPathOverlapIsRejected() {
        let fixture = BuilderFixture()
        let artifactOverlap = VoicePerformanceTracerBundleBuildRequest(
            finalBundlePath: fixture.request.verifiedArtifactDirectoryPath
                + "/" + VoicePerformanceTracerBundleLayout.outerBundleName,
            releaseBinDirectoryPath:
                fixture.request.releaseBinDirectoryPath,
            repositoryRootPath: fixture.request.repositoryRootPath,
            verifiedArtifactDirectoryPath:
                fixture.request.verifiedArtifactDirectoryPath,
            controlSocketPath: fixture.request.controlSocketPath,
            coldTrials: fixture.request.coldTrials,
            marketingVersion: fixture.request.marketingVersion,
            buildNumber: fixture.request.buildNumber,
            signingIdentity: fixture.request.signingIdentity,
            signingKeychainPath: fixture.request.signingKeychainPath
        )
        #expect(
            throws: VoicePerformanceTracerBundleBuildError.invalidRequest
        ) {
            try fixture.builder.build(artifactOverlap)
        }
        let socketParentOverlap = VoicePerformanceTracerBundleBuildRequest(
            finalBundlePath: fixture.request.finalBundlePath,
            releaseBinDirectoryPath:
                fixture.request.releaseBinDirectoryPath,
            repositoryRootPath: fixture.request.repositoryRootPath,
            verifiedArtifactDirectoryPath:
                fixture.request.verifiedArtifactDirectoryPath,
            controlSocketPath:
                fixture.request.finalBundlePath + "/control.sock",
            coldTrials: fixture.request.coldTrials,
            marketingVersion: fixture.request.marketingVersion,
            buildNumber: fixture.request.buildNumber,
            signingIdentity: fixture.request.signingIdentity,
            signingKeychainPath: fixture.request.signingKeychainPath
        )
        #expect(
            throws: VoicePerformanceTracerBundleBuildError.invalidRequest
        ) {
            try fixture.builder.build(socketParentOverlap)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }
            .joined()
    }

    private static func index(
        of prefix: String,
        in operations: [String]
    ) throws -> Int {
        try #require(operations.firstIndex { $0.hasPrefix(prefix) })
    }
}

private final class BuilderFixture: @unchecked Sendable {
    let recorder = OperationRecorder()
    let fileSystem: FakeBundleFileSystem
    let signer: FakeBundleSigner
    let inspector: FakeSigningInspector
    let request: VoicePerformanceTracerBundleBuildRequest
    let builder: VoicePerformanceTracerBundleBuilder

    init() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().path
        request = VoicePerformanceTracerBundleBuildRequest(
            finalBundlePath:
                "/private/tmp/rimeai-builder-output/"
                + VoicePerformanceTracerBundleLayout.outerBundleName,
            releaseBinDirectoryPath: "/private/tmp/rimeai-release-bin",
            repositoryRootPath: root,
            verifiedArtifactDirectoryPath:
                "/private/tmp/rimeai-verified-artifact",
            controlSocketPath:
                "/private/tmp/rimeai-control/control.sock",
            coldTrials: 4,
            marketingVersion: "1.2.3",
            buildNumber: "42",
            signingIdentity:
                "Developer ID Application: RimeAI Test (ABCDEFGHIJ)",
            signingKeychainPath: "/private/tmp/rimeai-signing.keychain-db"
        )
        fileSystem = FakeBundleFileSystem(recorder: recorder)
        signer = FakeBundleSigner(recorder: recorder)
        inspector = FakeSigningInspector(recorder: recorder)
        builder = VoicePerformanceTracerBundleBuilder(
            fileSystem: fileSystem,
            signer: signer,
            signingInspector: inspector,
            nonceGenerator: FixedNonceGenerator(),
            artifactVerifier: FakeArtifactVerifier(recorder: recorder)
        )
    }

    var cliArguments: [String] {
        [
            "/private/tmp/rimeai-voice-performance-tracer-bundle-builder",
            "--final-bundle", request.finalBundlePath,
            "--release-bin-dir", request.releaseBinDirectoryPath,
            "--repo-root", request.repositoryRootPath,
            "--verified-artifact-dir",
            request.verifiedArtifactDirectoryPath,
            "--control-socket", request.controlSocketPath,
            "--cold-trials", String(request.coldTrials),
            "--marketing-version", request.marketingVersion,
            "--build-number", request.buildNumber,
            "--signing-identity", request.signingIdentity,
            "--signing-keychain", request.signingKeychainPath!,
        ]
    }
}

private final class OperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var operations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ operation: String) {
        lock.lock()
        storage.append(operation)
        lock.unlock()
    }
}

private final class FakeBundleFileSystem:
    VoicePerformanceTracerBundleFileSystem,
    @unchecked Sendable
{
    let recorder: OperationRecorder
    var outputExists = false
    var rollbackFails = false
    var failTreePhase: VoicePerformanceTracerBundleTreePhase?
    var installFailure: VoicePerformanceTracerBundleFileSystemError?
    private let lock = NSLock()
    private var files: [String: Data] = [:]

    init(recorder: OperationRecorder) {
        self.recorder = recorder
    }

    func validateEnvironment(
        for request: VoicePerformanceTracerBundleBuildRequest
    ) throws {
        recorder.append("validate")
    }

    func pathExists(_ path: String) throws -> Bool {
        recorder.append("exists")
        return outputExists
    }

    func createPrivateStagingDirectory(_ path: String) throws {
        recorder.append("stage")
    }

    func createPrivateDirectory(_ path: String) throws {
        recorder.append("mkdir:" + path.components(separatedBy: "/").last!)
    }

    func readStableRegularFile(
        _ path: String,
        maximumBytes: Int
    ) throws -> Data {
        recorder.append("read:" + URL(fileURLWithPath: path).lastPathComponent)
        lock.lock()
        let stored = files[path]
        lock.unlock()
        if let stored { return stored }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func writeNewRegularFile(_ data: Data, to path: String) throws {
        recorder.append("write:" + URL(fileURLWithPath: path).lastPathComponent)
        lock.lock()
        files[path] = data
        lock.unlock()
    }

    func copyStableRegularFile(
        from sourcePath: String,
        to destinationPath: String,
        executable: Bool
    ) throws {
        recorder.append("copy:" + URL(fileURLWithPath: destinationPath).lastPathComponent)
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let data: Data
        if FileManager.default.fileExists(atPath: sourcePath) {
            data = try Data(contentsOf: sourceURL)
        } else {
            data = Data(("executable:" + sourceURL.lastPathComponent).utf8)
        }
        lock.lock()
        files[destinationPath] = data
        lock.unlock()
    }

    func normalizeAndVerifyExactTree(
        at bundlePath: String,
        phase: VoicePerformanceTracerBundleTreePhase
    ) throws {
        recorder.append(
            "tree:" + (phase == .beforeOuterSignature ? "before" : "after")
        )
        if failTreePhase == phase {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    func reverifyExactTreeWithoutMutation(
        at bundlePath: String,
        phase: VoicePerformanceTracerBundleTreePhase
    ) throws {
        recorder.append("tree:final-read-only")
        if failTreePhase == phase {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    func flushTreeBottomUpAndReverify(at bundlePath: String) throws {
        recorder.append("flush")
    }

    func installExclusive(
        stagingPath: String,
        finalPath: String
    ) throws -> VoicePerformanceTracerBundleInstallationToken {
        recorder.append("install")
        if let installFailure { throw installFailure }
        lock.lock()
        let staged = files.filter { $0.key.hasPrefix(stagingPath + "/") }
        for (path, data) in staged {
            files.removeValue(forKey: path)
            files[finalPath + path.dropFirst(stagingPath.count)] = data
        }
        lock.unlock()
        return .init(device: 7, inode: 11)
    }

    func syncParentDirectory(of path: String) throws {
        recorder.append("sync-parent")
    }

    func rollbackInstalledBundle(
        at finalPath: String,
        token: VoicePerformanceTracerBundleInstallationToken
    ) throws {
        recorder.append("rollback")
        if rollbackFails {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    func removeStagingTreeIfPresent(_ path: String) throws {
        recorder.append("cleanup-stage")
    }

    func writtenFile(endingIn suffix: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return files.first { $0.key.hasSuffix(suffix) }?.value
    }
}

private final class FakeBundleSigner:
    VoicePerformanceTracerBundleSigning,
    @unchecked Sendable
{
    private let recorder: OperationRecorder
    private let lock = NSLock()
    private var storage: [VoicePerformanceTracerCodesignInvocation] = []

    init(recorder: OperationRecorder) {
        self.recorder = recorder
    }

    var invocations: [VoicePerformanceTracerCodesignInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func sign(_ invocation: VoicePerformanceTracerCodesignInvocation) throws {
        let label: String
        switch invocation.signingIdentifier {
        case "fun.wwcn.rimeai.voice-performance-collector": label = "collector"
        case "fun.wwcn.rimeai.voice-performance-driver": label = "driver"
        case "fun.wwcn.rimeai.voice-helper": label = "helper"
        default: label = "outer"
        }
        recorder.append("sign:" + label)
        lock.lock()
        storage.append(invocation)
        lock.unlock()
    }
}

private final class FakeSigningInspector:
    VoicePerformanceTracerBundleSigningInspecting,
    @unchecked Sendable
{
    private let recorder: OperationRecorder
    private let lock = NSLock()
    private var childCount = 0
    var driftAtInspection: Int?
    var entitlementBlobAtInspection: Int?
    var outerHasHardenedRuntimeFlag = false

    init(recorder: OperationRecorder) {
        self.recorder = recorder
    }

    func inspectChildBundle(
        at appPath: String,
        executablePath: String,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String?
    ) throws -> VoicePerformanceTracerChildSigningEvidence {
        lock.lock()
        childCount += 1
        let count = childCount
        let drift = driftAtInspection == count
        let entitlement = entitlementBlobAtInspection == count
        lock.unlock()
        recorder.append("inspect-child:\(count)")
        let digit: Character = switch expectedSigningIdentifier {
        case "fun.wwcn.rimeai.voice-performance-collector": "1"
        case "fun.wwcn.rimeai.voice-performance-driver": "2"
        default: "3"
        }
        return .init(
            appPath: appPath,
            executablePath: executablePath,
            executableSHA256: String(repeating: digit, count: 64),
            signingIdentifier: expectedSigningIdentifier,
            teamIdentifier: "ABCDEFGHIJ",
            cdHash: String(repeating: drift ? "f" : digit, count: 40),
            developerIDValidated: true,
            strictValidation: true,
            allArchitecturesValidated: true,
            hardenedRuntime: true,
            trustedTimestamp: true,
            hasEntitlementBlob: entitlement,
            hasEntitlementDictionary: false
        )
    }

    func inspectOuterBundle(
        at bundlePath: String,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> VoicePerformanceTracerOuterSigningEvidence {
        recorder.append("inspect-outer")
        return .init(
            bundlePath: bundlePath,
            signingIdentifier: expectedSigningIdentifier,
            teamIdentifier: expectedTeamIdentifier,
            developerIDValidated: true,
            strictValidation: true,
            allArchitecturesValidated: true,
            nestedCodeValidated: true,
            hasHardenedRuntimeFlag: outerHasHardenedRuntimeFlag,
            trustedTimestamp: true,
            hasEntitlementBlob: false,
            hasEntitlementDictionary: false
        )
    }
}

private struct FixedNonceGenerator:
    VoicePerformanceTracerBundleNonceGenerating
{
    func randomBytes(count: Int) throws -> Data {
        Data(repeating: count == 32 ? 0xA1 : 0xB2, count: count)
    }
}

private struct FakeArtifactVerifier:
    VoicePerformanceTracerBundleArtifactVerifying
{
    let recorder: OperationRecorder

    func verifyArtifact(
        at path: String
    ) throws -> VoicePerformanceTracerVerifiedArtifact {
        recorder.append("artifact")
        return .init(
            directory: path,
            adapterID: "sherpa_onnx",
            artifactID: "zh_streaming_v1",
            contentSHA256: String(repeating: "a", count: 64),
            maximumHotwords: 64
        )
    }
}
