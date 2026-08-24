import CryptoKit
import Foundation
import RimeAIInputCore
import RimeAIVoiceArtifactCore
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceTracerProcessDarwin

public struct VoicePerformanceTracerBundleBuildRequest:
    Equatable,
    Sendable
{
    public let finalBundlePath: String
    public let releaseBinDirectoryPath: String
    public let repositoryRootPath: String
    public let verifiedArtifactDirectoryPath: String
    public let controlSocketPath: String
    public let coldTrials: UInt64
    public let marketingVersion: String
    public let buildNumber: String
    public let signingIdentity: String
    public let signingKeychainPath: String?

    public init(
        finalBundlePath: String,
        releaseBinDirectoryPath: String,
        repositoryRootPath: String,
        verifiedArtifactDirectoryPath: String,
        controlSocketPath: String,
        coldTrials: UInt64,
        marketingVersion: String,
        buildNumber: String,
        signingIdentity: String,
        signingKeychainPath: String? = nil
    ) {
        self.finalBundlePath = finalBundlePath
        self.releaseBinDirectoryPath = releaseBinDirectoryPath
        self.repositoryRootPath = repositoryRootPath
        self.verifiedArtifactDirectoryPath =
            verifiedArtifactDirectoryPath
        self.controlSocketPath = controlSocketPath
        self.coldTrials = coldTrials
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.signingIdentity = signingIdentity
        self.signingKeychainPath = signingKeychainPath
    }
}

public struct VoicePerformanceTracerBundleBuildReceipt:
    Equatable,
    Sendable
{
    public let finalBundlePath: String
    public let measurementPolicyFileSHA256: String
    public let measurementPolicyCanonicalSHA256: String
    public let rawReleasePolicySHA256: String
    public let teamIdentifier: String

    public init(
        finalBundlePath: String,
        measurementPolicyFileSHA256: String,
        measurementPolicyCanonicalSHA256: String,
        rawReleasePolicySHA256: String,
        teamIdentifier: String
    ) {
        self.finalBundlePath = finalBundlePath
        self.measurementPolicyFileSHA256 = measurementPolicyFileSHA256
        self.measurementPolicyCanonicalSHA256 =
            measurementPolicyCanonicalSHA256
        self.rawReleasePolicySHA256 = rawReleasePolicySHA256
        self.teamIdentifier = teamIdentifier
    }

    public func canonicalJSONData() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "bundle_path": finalBundlePath,
                "measurement_policy_canonical_sha256":
                    measurementPolicyCanonicalSHA256,
                "measurement_policy_file_sha256":
                    measurementPolicyFileSHA256,
                "raw_release_policy_sha256": rawReleasePolicySHA256,
                "team_identifier": teamIdentifier,
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

public enum VoicePerformanceTracerBundleBuildError:
    Error,
    Equatable,
    Sendable
{
    case invalidRequest
    case insecureSource
    case outputAlreadyExists
    case stagingCreationFailed
    case stagingCleanupFailed
    case invalidReleasePolicy
    case invalidArtifact
    case signingFailed
    case invalidSigningEvidence
    case signingEvidenceDrift
    case invalidBundleTree
    case policyConstructionFailed
    case installationFailed
    case finalVerificationFailed
    case installationIndeterminate
}

public struct VoicePerformanceTracerBundleBuilder: Sendable {
    private let fileSystem: any VoicePerformanceTracerBundleFileSystem
    private let signer: any VoicePerformanceTracerBundleSigning
    private let signingInspector:
        any VoicePerformanceTracerBundleSigningInspecting
    private let nonceGenerator:
        any VoicePerformanceTracerBundleNonceGenerating
    private let artifactVerifier:
        any VoicePerformanceTracerBundleArtifactVerifying

    public init() {
        fileSystem = DarwinVoicePerformanceTracerBundleFileSystem()
        signer = DarwinVoicePerformanceTracerBundleSigner()
        signingInspector = DarwinVoicePerformanceTracerBundleSigningInspector()
        nonceGenerator = DarwinVoicePerformanceTracerBundleNonceGenerator()
        artifactVerifier = DarwinVoicePerformanceTracerArtifactVerifier()
    }

    init(
        fileSystem: any VoicePerformanceTracerBundleFileSystem,
        signer: any VoicePerformanceTracerBundleSigning,
        signingInspector:
            any VoicePerformanceTracerBundleSigningInspecting,
        nonceGenerator:
            any VoicePerformanceTracerBundleNonceGenerating,
        artifactVerifier:
            any VoicePerformanceTracerBundleArtifactVerifying
    ) {
        self.fileSystem = fileSystem
        self.signer = signer
        self.signingInspector = signingInspector
        self.nonceGenerator = nonceGenerator
        self.artifactVerifier = artifactVerifier
    }

    public func build(
        _ request: VoicePerformanceTracerBundleBuildRequest
    ) throws -> VoicePerformanceTracerBundleBuildReceipt {
        guard Self.isValid(request) else {
            throw VoicePerformanceTracerBundleBuildError.invalidRequest
        }
        do {
            try fileSystem.validateEnvironment(for: request)
        } catch {
            throw VoicePerformanceTracerBundleBuildError.insecureSource
        }
        do {
            guard try !fileSystem.pathExists(request.finalBundlePath) else {
                throw VoicePerformanceTracerBundleBuildError
                    .outputAlreadyExists
            }
        } catch let error as VoicePerformanceTracerBundleBuildError {
            throw error
        } catch {
            throw VoicePerformanceTracerBundleBuildError.installationFailed
        }

        let sessionNonce: String
        let stagingNonce: String
        do {
            sessionNonce = try Self.hex(
                nonceGenerator.randomBytes(count: 32),
                expectedCount: 32
            )
            stagingNonce = try Self.hex(
                nonceGenerator.randomBytes(count: 16),
                expectedCount: 16
            )
        } catch {
            throw VoicePerformanceTracerBundleBuildError.invalidRequest
        }
        let finalParent = Self.parentPath(of: request.finalBundlePath)
        let stagingPath = finalParent
            + "/.RimeAIVoicePerformanceTracer.bundle.staging-"
            + stagingNonce

        var stagingCreated = false
        do {
            do {
                try fileSystem.createPrivateStagingDirectory(stagingPath)
                stagingCreated = true
            } catch {
                throw VoicePerformanceTracerBundleBuildError
                    .stagingCreationFailed
            }

            let paths = BundlePaths(root: stagingPath)
            try createInitialBundleTree(
                paths: paths,
                request: request
            )

            let rawReleasePolicy: Data
            do {
                rawReleasePolicy = try fileSystem.readStableRegularFile(
                    paths.helperReleasePolicy,
                    maximumBytes: 65_536
                )
                _ = try VoiceReleasePolicy.decodeStrict(rawReleasePolicy)
            } catch {
                throw VoicePerformanceTracerBundleBuildError
                    .invalidReleasePolicy
            }
            let rawReleasePolicySHA256 = Self.sha256(rawReleasePolicy)

            let artifact: VoicePerformanceTracerVerifiedArtifact
            do {
                artifact = try artifactVerifier.verifyArtifact(
                    at: request.verifiedArtifactDirectoryPath
                )
            } catch {
                throw VoicePerformanceTracerBundleBuildError.invalidArtifact
            }
            guard Self.byteExactlyEqual(
                      artifact.directory,
                      request.verifiedArtifactDirectoryPath
                  ),
                  (1 ... 128).contains(artifact.maximumHotwords)
            else {
                throw VoicePerformanceTracerBundleBuildError.invalidArtifact
            }

            let initialEvidence = try signAndInspectChildren(
                paths: paths,
                request: request
            )
            let teamIdentifier = initialEvidence.collector.teamIdentifier

            let driverPolicyData: Data
            let measurementPolicyData: Data
            let measurementPolicyCanonicalSHA256: String
            do {
                driverPolicyData = try SealedPerformanceControlDriverPolicy
                    .tracerCanonicalData()
                measurementPolicyData = try VoicePerformanceMeasurementPolicy
                    .tracerCanonicalData(
                        for: .init(
                            coldTrials: request.coldTrials,
                            controlSocketPath: request.controlSocketPath,
                            controlSessionNonce: sessionNonce,
                            teamIdentifier: teamIdentifier,
                            collector: .init(
                                executablePath:
                                    request.finalBundlePath
                                    + VoicePerformanceTracerBundleLayout
                                        .collectorExecutableSuffix,
                                executableSHA256:
                                    initialEvidence.collector
                                        .executableSHA256,
                                cdHash: initialEvidence.collector.cdHash
                            ),
                            driver: .init(
                                executablePath:
                                    request.finalBundlePath
                                    + VoicePerformanceTracerBundleLayout
                                        .driverExecutableSuffix,
                                executableSHA256:
                                    initialEvidence.driver.executableSHA256,
                                cdHash: initialEvidence.driver.cdHash
                            ),
                            helper: .init(
                                executablePath:
                                    request.finalBundlePath
                                    + VoicePerformanceTracerBundleLayout
                                        .helperExecutableSuffix,
                                executableSHA256:
                                    initialEvidence.helper.executableSHA256,
                                cdHash: initialEvidence.helper.cdHash
                            ),
                            evaluationArtifact: .init(
                                directory: artifact.directory,
                                adapterID: artifact.adapterID,
                                artifactID: artifact.artifactID,
                                contentSHA256: artifact.contentSHA256,
                                maximumHotwords: artifact.maximumHotwords
                            ),
                            rawReleasePolicySHA256:
                                rawReleasePolicySHA256
                        )
                    )
                measurementPolicyCanonicalSHA256 =
                    try VoicePerformanceMeasurementPolicy
                        .decodeCanonical(measurementPolicyData)
                        .canonicalSHA256
            } catch {
                throw VoicePerformanceTracerBundleBuildError
                    .policyConstructionFailed
            }

            do {
                try fileSystem.writeNewRegularFile(
                    driverPolicyData,
                    to: paths.driverPolicy
                )
                try fileSystem.writeNewRegularFile(
                    measurementPolicyData,
                    to: paths.measurementPolicy
                )
                try copyLegalResources(paths: paths, request: request)
                try fileSystem.normalizeAndVerifyExactTree(
                    at: stagingPath,
                    phase: .beforeOuterSignature
                )
            } catch let error as VoicePerformanceTracerBundleBuildError {
                throw error
            } catch {
                throw VoicePerformanceTracerBundleBuildError.invalidBundleTree
            }

            try sign(
                path: stagingPath,
                identifier: BundleConstants.outerSigningIdentifier,
                hardenedRuntime: false,
                request: request
            )
            do {
                try fileSystem.normalizeAndVerifyExactTree(
                    at: stagingPath,
                    phase: .afterOuterSignature
                )
            } catch {
                throw VoicePerformanceTracerBundleBuildError.invalidBundleTree
            }
            do {
                let outer = try signingInspector.inspectOuterBundle(
                    at: stagingPath,
                    expectedSigningIdentifier:
                        BundleConstants.outerSigningIdentifier,
                    expectedTeamIdentifier: teamIdentifier
                )
                guard Self.isValid(
                    outer,
                    bundlePath: stagingPath,
                    teamIdentifier: teamIdentifier
                ) else {
                    throw VoicePerformanceTracerBundleBuildError
                        .invalidSigningEvidence
                }
                let rechecked = try inspectChildren(
                    paths: paths,
                    expectedTeamIdentifier: teamIdentifier
                )
                guard rechecked == initialEvidence else {
                    throw VoicePerformanceTracerBundleBuildError
                        .signingEvidenceDrift
                }
            } catch let error as VoicePerformanceTracerBundleBuildError {
                throw error
            } catch {
                throw VoicePerformanceTracerBundleBuildError
                    .invalidSigningEvidence
            }
            do {
                try fileSystem.flushTreeBottomUpAndReverify(
                    at: stagingPath
                )
            } catch {
                throw VoicePerformanceTracerBundleBuildError.invalidBundleTree
            }

            let installationToken: VoicePerformanceTracerBundleInstallationToken
            do {
                installationToken = try fileSystem.installExclusive(
                    stagingPath: stagingPath,
                    finalPath: request.finalBundlePath
                )
                stagingCreated = false
            } catch VoicePerformanceTracerBundleFileSystemError.outputExists {
                throw VoicePerformanceTracerBundleBuildError
                    .outputAlreadyExists
            } catch let VoicePerformanceTracerBundleFileSystemError
                .renameCommitted(token)
            {
                stagingCreated = false
                do {
                    try fileSystem.rollbackInstalledBundle(
                        at: request.finalBundlePath,
                        token: token
                    )
                    try fileSystem.syncParentDirectory(
                        of: request.finalBundlePath
                    )
                } catch {
                    throw VoicePerformanceTracerBundleBuildError
                        .installationIndeterminate
                }
                throw VoicePerformanceTracerBundleBuildError
                    .installationFailed
            } catch {
                throw VoicePerformanceTracerBundleBuildError.installationFailed
            }

            do {
                try fileSystem.syncParentDirectory(of: request.finalBundlePath)
                try finalReverify(
                    request: request,
                    expectedEvidence: initialEvidence,
                    teamIdentifier: teamIdentifier
                )
            } catch {
                do {
                    try fileSystem.rollbackInstalledBundle(
                        at: request.finalBundlePath,
                        token: installationToken
                    )
                    try fileSystem.syncParentDirectory(
                        of: request.finalBundlePath
                    )
                } catch {
                    throw VoicePerformanceTracerBundleBuildError
                        .installationIndeterminate
                }
                throw VoicePerformanceTracerBundleBuildError
                    .finalVerificationFailed
            }

            return VoicePerformanceTracerBundleBuildReceipt(
                finalBundlePath: request.finalBundlePath,
                measurementPolicyFileSHA256:
                    Self.sha256(measurementPolicyData),
                measurementPolicyCanonicalSHA256:
                    measurementPolicyCanonicalSHA256,
                rawReleasePolicySHA256: rawReleasePolicySHA256,
                teamIdentifier: teamIdentifier
            )
        } catch {
            let original = error
            if stagingCreated {
                do {
                    try fileSystem.removeStagingTreeIfPresent(stagingPath)
                    try fileSystem.syncParentDirectory(of: stagingPath)
                } catch {
                    throw VoicePerformanceTracerBundleBuildError
                        .stagingCleanupFailed
                }
            }
            if let known = original
                as? VoicePerformanceTracerBundleBuildError
            {
                throw known
            }
            throw VoicePerformanceTracerBundleBuildError.installationFailed
        }
    }

    private func createInitialBundleTree(
        paths: BundlePaths,
        request: VoicePerformanceTracerBundleBuildRequest
    ) throws {
        do {
            for directory in paths.initialDirectories {
                try fileSystem.createPrivateDirectory(directory)
            }
            for spec in BundleInfoPlistSpec.all {
                let template = try fileSystem.readStableRegularFile(
                    request.repositoryRootPath
                        + "/macos/VoicePerformanceTracer/"
                        + spec.templateName,
                    maximumBytes: 65_536
                )
                let rendered = try Self.renderInfoPlist(
                    template,
                    spec: spec,
                    marketingVersion: request.marketingVersion,
                    buildNumber: request.buildNumber
                )
                try fileSystem.writeNewRegularFile(
                    rendered,
                    to: paths.infoPlist(for: spec)
                )
            }
            for executable in BundleExecutableSpec.all {
                try fileSystem.copyStableRegularFile(
                    from: request.releaseBinDirectoryPath
                        + "/" + executable.sourceName,
                    to: paths.executable(for: executable),
                    executable: true
                )
            }
            try fileSystem.copyStableRegularFile(
                from: request.repositoryRootPath
                    + "/macos/VoiceHelper/VoiceReleasePolicy.plist",
                to: paths.helperReleasePolicy,
                executable: false
            )
        } catch let error as VoicePerformanceTracerBundleBuildError {
            throw error
        } catch {
            throw VoicePerformanceTracerBundleBuildError.insecureSource
        }
    }

    private func copyLegalResources(
        paths: BundlePaths,
        request: VoicePerformanceTracerBundleBuildRequest
    ) throws {
        for resource in BundleLegalResource.all {
            try fileSystem.copyStableRegularFile(
                from: request.repositoryRootPath + "/" + resource.source,
                to: paths.root + "/" + resource.destination,
                executable: false
            )
        }
    }

    private func signAndInspectChildren(
        paths: BundlePaths,
        request: VoicePerformanceTracerBundleBuildRequest
    ) throws -> ChildEvidenceSet {
        var evidence: [VoicePerformanceTracerChildSigningEvidence] = []
        for child in BundleExecutableSpec.all {
            try sign(
                path: paths.app(for: child),
                identifier: child.signingIdentifier,
                hardenedRuntime: true,
                request: request
            )
            do {
                let inspected = try signingInspector.inspectChildBundle(
                    at: paths.app(for: child),
                    executablePath: paths.executable(for: child),
                    expectedSigningIdentifier: child.signingIdentifier,
                    expectedTeamIdentifier:
                        evidence.first?.teamIdentifier
                )
                guard Self.isValid(
                    inspected,
                    appPath: paths.app(for: child),
                    executablePath: paths.executable(for: child),
                    signingIdentifier: child.signingIdentifier,
                    teamIdentifier: evidence.first?.teamIdentifier
                ) else {
                    throw VoicePerformanceTracerBundleBuildError
                        .invalidSigningEvidence
                }
                evidence.append(inspected)
            } catch let error as VoicePerformanceTracerBundleBuildError {
                throw error
            } catch {
                throw VoicePerformanceTracerBundleBuildError
                    .invalidSigningEvidence
            }
        }
        guard evidence.count == 3 else {
            throw VoicePerformanceTracerBundleBuildError
                .invalidSigningEvidence
        }
        return ChildEvidenceSet(
            collector: evidence[0],
            driver: evidence[1],
            helper: evidence[2]
        )
    }

    private func inspectChildren(
        paths: BundlePaths,
        expectedTeamIdentifier: String
    ) throws -> ChildEvidenceSet {
        var result: [VoicePerformanceTracerChildSigningEvidence] = []
        for child in BundleExecutableSpec.all {
            let evidence = try signingInspector.inspectChildBundle(
                at: paths.app(for: child),
                executablePath: paths.executable(for: child),
                expectedSigningIdentifier: child.signingIdentifier,
                expectedTeamIdentifier: expectedTeamIdentifier
            )
            guard Self.isValid(
                evidence,
                appPath: paths.app(for: child),
                executablePath: paths.executable(for: child),
                signingIdentifier: child.signingIdentifier,
                teamIdentifier: expectedTeamIdentifier
            ) else {
                throw VoicePerformanceTracerBundleBuildError
                    .invalidSigningEvidence
            }
            result.append(evidence)
        }
        return ChildEvidenceSet(
            collector: result[0],
            driver: result[1],
            helper: result[2]
        )
    }

    private func sign(
        path: String,
        identifier: String,
        hardenedRuntime: Bool,
        request: VoicePerformanceTracerBundleBuildRequest
    ) throws {
        do {
            try signer.sign(.init(
                path: path,
                signingIdentifier: identifier,
                signingIdentity: request.signingIdentity,
                hardenedRuntime: hardenedRuntime,
                signingKeychainPath: request.signingKeychainPath
            ))
        } catch {
            throw VoicePerformanceTracerBundleBuildError.signingFailed
        }
    }

    private func finalReverify(
        request: VoicePerformanceTracerBundleBuildRequest,
        expectedEvidence: ChildEvidenceSet,
        teamIdentifier: String
    ) throws {
        try fileSystem.reverifyExactTreeWithoutMutation(
            at: request.finalBundlePath,
            phase: .afterOuterSignature
        )
        let outer = try signingInspector.inspectOuterBundle(
            at: request.finalBundlePath,
            expectedSigningIdentifier:
                BundleConstants.outerSigningIdentifier,
            expectedTeamIdentifier: teamIdentifier
        )
        guard Self.isValid(
            outer,
            bundlePath: request.finalBundlePath,
            teamIdentifier: teamIdentifier
        ) else {
            throw VoicePerformanceTracerBundleBuildError
                .invalidSigningEvidence
        }
        let finalPaths = BundlePaths(root: request.finalBundlePath)
        let finalEvidence = try inspectChildren(
            paths: finalPaths,
            expectedTeamIdentifier: teamIdentifier
        )
        guard finalEvidence.rebased(
            from: request.finalBundlePath,
            to: expectedEvidence.collector.appPath
                .components(separatedBy: "/Contents/Helpers/")[0]
        ) == expectedEvidence else {
            throw VoicePerformanceTracerBundleBuildError.signingEvidenceDrift
        }
    }

    private static func isValid(
        _ evidence: VoicePerformanceTracerChildSigningEvidence,
        appPath: String,
        executablePath: String,
        signingIdentifier: String,
        teamIdentifier: String?
    ) -> Bool {
        byteExactlyEqual(evidence.appPath, appPath)
            && byteExactlyEqual(evidence.executablePath, executablePath)
            && evidence.signingIdentifier == signingIdentifier
            && (teamIdentifier == nil
                || evidence.teamIdentifier == teamIdentifier)
            && isTeamIdentifier(evidence.teamIdentifier)
            && isLowercaseHex(evidence.executableSHA256, count: 64)
            && isLowercaseHex(evidence.cdHash, count: 40)
            && evidence.developerIDValidated
            && evidence.strictValidation
            && evidence.allArchitecturesValidated
            && evidence.hardenedRuntime
            && evidence.trustedTimestamp
            && !evidence.hasEntitlementBlob
            && !evidence.hasEntitlementDictionary
    }

    private static func isValid(
        _ evidence: VoicePerformanceTracerOuterSigningEvidence,
        bundlePath: String,
        teamIdentifier: String
    ) -> Bool {
        byteExactlyEqual(evidence.bundlePath, bundlePath)
            && evidence.signingIdentifier
                == BundleConstants.outerSigningIdentifier
            && evidence.teamIdentifier == teamIdentifier
            && evidence.developerIDValidated
            && evidence.strictValidation
            && evidence.allArchitecturesValidated
            && evidence.nestedCodeValidated
            && !evidence.hasHardenedRuntimeFlag
            && evidence.trustedTimestamp
            && !evidence.hasEntitlementBlob
            && !evidence.hasEntitlementDictionary
    }

    static func isValid(
        _ request: VoicePerformanceTracerBundleBuildRequest
    ) -> Bool {
        let paths = [
            request.finalBundlePath,
            request.releaseBinDirectoryPath,
            request.repositoryRootPath,
            request.verifiedArtifactDirectoryPath,
            request.controlSocketPath,
        ] + (request.signingKeychainPath.map { [$0] } ?? [])
        guard paths.allSatisfy(isCanonicalAbsolutePath),
              request.finalBundlePath.hasSuffix(
                  "/" + VoicePerformanceTracerBundleLayout.outerBundleName
              ),
              request.controlSocketPath.utf8.count <= 103,
              PerformanceControlSessionBinding.supportedTrials.contains(
                  request.coldTrials
              ),
              isVersion(request.marketingVersion),
              isBuildNumber(request.buildNumber),
              isControlledIdentity(request.signingIdentity)
        else {
            return false
        }
        let final = request.finalBundlePath
        let sourceRoots = [
            request.repositoryRootPath,
            request.releaseBinDirectoryPath,
            request.verifiedArtifactDirectoryPath,
        ]
        guard sourceRoots.allSatisfy({
            !pathsOverlapByComponent(final, $0)
        }) else {
            return false
        }
        let socketParent = parentPath(of: request.controlSocketPath)
        guard !pathsOverlapByComponent(final, request.controlSocketPath),
              !pathsOverlapByComponent(final, socketParent),
              request.signingKeychainPath.map({
                  !pathsOverlapByComponent(final, $0)
              }) ?? true
        else {
            return false
        }
        return true
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.utf8.count > 1,
              path.utf8.count < 4_096,
              path.first == "/",
              path.last != "/",
              byteExactlyEqual(
                  path,
                  path.precomposedStringWithCanonicalMapping
              ),
              !path.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7F
              })
        else {
            return false
        }
        return path.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        ).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
                && $0.utf8.count <= 255
        }
    }

    private static func isVersion(_ value: String) -> Bool {
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return !components.isEmpty && components.count <= 4
            && value.utf8.count <= 32
            && components.allSatisfy { component in
                !component.isEmpty
                    && component.utf8.allSatisfy {
                        $0 >= 0x30 && $0 <= 0x39
                    }
                    && (component == "0" || component.first != "0")
            }
    }

    private static func isBuildNumber(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 18
            && value.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
            && value.first != "0"
    }

    private static func isControlledIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512
            && byteExactlyEqual(
                value,
                value.precomposedStringWithCanonicalMapping
            )
            && !value.unicodeScalars.contains(where: {
                $0.value < 0x20 || $0.value == 0x7F
            })
    }

    private static func renderInfoPlist(
        _ template: Data,
        spec: BundleInfoPlistSpec,
        marketingVersion: String,
        buildNumber: String
    ) throws -> Data {
        guard var string = String(data: template, encoding: .utf8),
              string.components(
                  separatedBy: "__RIMEAI_MARKETING_VERSION__"
              ).count == 2,
              string.components(
                  separatedBy: "__RIMEAI_BUILD_NUMBER__"
              ).count == 2
        else {
            throw VoicePerformanceTracerBundleBuildError.insecureSource
        }
        string = string.replacingOccurrences(
            of: "__RIMEAI_MARKETING_VERSION__",
            with: marketingVersion
        ).replacingOccurrences(
            of: "__RIMEAI_BUILD_NUMBER__",
            with: buildNumber
        )
        let data = Data(string.utf8)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
              Set(plist.keys) == spec.expectedKeys,
              plist["CFBundleIdentifier"] as? String
                == spec.signingIdentifier,
              plist["CFBundlePackageType"] as? String
                == spec.packageType,
              plist["CFBundleShortVersionString"] as? String
                == marketingVersion,
              plist["CFBundleVersion"] as? String == buildNumber,
              plist["LSMinimumSystemVersion"] as? String == "14.0",
              plist["CFBundleExecutable"] as? String == spec.executableName,
              plist["LSUIElement"] as? Bool == spec.uiElement
        else {
            throw VoicePerformanceTracerBundleBuildError.insecureSource
        }
        return data
    }

    private static func parentPath(of path: String) -> String {
        let index = path.lastIndex(of: "/")!
        return index == path.startIndex ? "/" : String(path[..<index])
    }

    private static func pathsOverlapByComponent(
        _ left: String,
        _ right: String
    ) -> Bool {
        let lhs = left.split(separator: "/", omittingEmptySubsequences: true)
        let rhs = right.split(separator: "/", omittingEmptySubsequences: true)
        let shared = min(lhs.count, rhs.count)
        return lhs.prefix(shared).elementsEqual(rhs.prefix(shared))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }
            .joined()
    }

    private static func hex(
        _ data: Data,
        expectedCount: Int
    ) throws -> String {
        guard data.count == expectedCount else {
            throw VoicePerformanceTracerBundleBuildError.invalidRequest
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseHex(
        _ value: String,
        count: Int
    ) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    private static func isTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A)
        }
    }

    private static func byteExactlyEqual(
        _ left: String,
        _ right: String
    ) -> Bool {
        left.utf8.elementsEqual(right.utf8)
    }
}

struct VoicePerformanceTracerVerifiedArtifact: Equatable, Sendable {
    let directory: String
    let adapterID: String
    let artifactID: String
    let contentSHA256: String
    let maximumHotwords: UInt64
}

protocol VoicePerformanceTracerBundleArtifactVerifying: Sendable {
    func verifyArtifact(at path: String) throws
        -> VoicePerformanceTracerVerifiedArtifact
}

protocol VoicePerformanceTracerBundleNonceGenerating: Sendable {
    func randomBytes(count: Int) throws -> Data
}

struct VoicePerformanceTracerCodesignInvocation: Equatable, Sendable {
    let path: String
    let signingIdentifier: String
    let signingIdentity: String
    let hardenedRuntime: Bool
    let signingKeychainPath: String?

    var arguments: [String] {
        var result = [
            "--force",
            "--sign", signingIdentity,
            "--identifier", signingIdentifier,
        ]
        if hardenedRuntime {
            result += ["--options", "runtime"]
        }
        result.append("--timestamp")
        if let signingKeychainPath {
            result += ["--keychain", signingKeychainPath]
        }
        result.append(path)
        return result
    }
}

protocol VoicePerformanceTracerBundleSigning: Sendable {
    func sign(_ invocation: VoicePerformanceTracerCodesignInvocation) throws
}

struct VoicePerformanceTracerChildSigningEvidence: Equatable, Sendable {
    let appPath: String
    let executablePath: String
    let executableSHA256: String
    let signingIdentifier: String
    let teamIdentifier: String
    let cdHash: String
    let developerIDValidated: Bool
    let strictValidation: Bool
    let allArchitecturesValidated: Bool
    let hardenedRuntime: Bool
    let trustedTimestamp: Bool
    let hasEntitlementBlob: Bool
    let hasEntitlementDictionary: Bool
}

struct VoicePerformanceTracerOuterSigningEvidence: Equatable, Sendable {
    let bundlePath: String
    let signingIdentifier: String
    let teamIdentifier: String
    let developerIDValidated: Bool
    let strictValidation: Bool
    let allArchitecturesValidated: Bool
    let nestedCodeValidated: Bool
    /// Resource-only bundles have no executable CodeDirectory on which the
    /// hardened-runtime flag can be asserted. Keep the observed bit explicit
    /// so callers cannot accidentally report executable protection here.
    let hasHardenedRuntimeFlag: Bool
    let trustedTimestamp: Bool
    let hasEntitlementBlob: Bool
    let hasEntitlementDictionary: Bool
}

protocol VoicePerformanceTracerBundleSigningInspecting: Sendable {
    func inspectChildBundle(
        at appPath: String,
        executablePath: String,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String?
    ) throws -> VoicePerformanceTracerChildSigningEvidence

    func inspectOuterBundle(
        at bundlePath: String,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> VoicePerformanceTracerOuterSigningEvidence
}

enum VoicePerformanceTracerBundleTreePhase: Equatable, Sendable {
    case beforeOuterSignature
    case afterOuterSignature
}

struct VoicePerformanceTracerBundleInstallationToken: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

enum VoicePerformanceTracerBundleFileSystemError: Error, Equatable {
    case outputExists
    case renameCommitted(VoicePerformanceTracerBundleInstallationToken)
    case failed
}

protocol VoicePerformanceTracerBundleFileSystem: Sendable {
    func validateEnvironment(
        for request: VoicePerformanceTracerBundleBuildRequest
    ) throws
    func pathExists(_ path: String) throws -> Bool
    func createPrivateStagingDirectory(_ path: String) throws
    func createPrivateDirectory(_ path: String) throws
    func readStableRegularFile(
        _ path: String,
        maximumBytes: Int
    ) throws -> Data
    func writeNewRegularFile(_ data: Data, to path: String) throws
    func copyStableRegularFile(
        from sourcePath: String,
        to destinationPath: String,
        executable: Bool
    ) throws
    func normalizeAndVerifyExactTree(
        at bundlePath: String,
        phase: VoicePerformanceTracerBundleTreePhase
    ) throws
    func reverifyExactTreeWithoutMutation(
        at bundlePath: String,
        phase: VoicePerformanceTracerBundleTreePhase
    ) throws
    func flushTreeBottomUpAndReverify(at bundlePath: String) throws
    func installExclusive(
        stagingPath: String,
        finalPath: String
    ) throws -> VoicePerformanceTracerBundleInstallationToken
    func syncParentDirectory(of path: String) throws
    func rollbackInstalledBundle(
        at finalPath: String,
        token: VoicePerformanceTracerBundleInstallationToken
    ) throws
    func removeStagingTreeIfPresent(_ path: String) throws
}

private struct ChildEvidenceSet: Equatable {
    let collector: VoicePerformanceTracerChildSigningEvidence
    let driver: VoicePerformanceTracerChildSigningEvidence
    let helper: VoicePerformanceTracerChildSigningEvidence

    func rebased(from oldRoot: String, to newRoot: String) -> Self {
        Self(
            collector: collector.rebased(from: oldRoot, to: newRoot),
            driver: driver.rebased(from: oldRoot, to: newRoot),
            helper: helper.rebased(from: oldRoot, to: newRoot)
        )
    }
}

private extension VoicePerformanceTracerChildSigningEvidence {
    func rebased(from oldRoot: String, to newRoot: String) -> Self {
        Self(
            appPath: newRoot + appPath.dropFirst(oldRoot.count),
            executablePath:
                newRoot + executablePath.dropFirst(oldRoot.count),
            executableSHA256: executableSHA256,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            cdHash: cdHash,
            developerIDValidated: developerIDValidated,
            strictValidation: strictValidation,
            allArchitecturesValidated: allArchitecturesValidated,
            hardenedRuntime: hardenedRuntime,
            trustedTimestamp: trustedTimestamp,
            hasEntitlementBlob: hasEntitlementBlob,
            hasEntitlementDictionary: hasEntitlementDictionary
        )
    }
}

private enum BundleConstants {
    static let outerSigningIdentifier =
        "fun.wwcn.rimeai.voice-performance-tracer"
}

private struct BundleExecutableSpec: Equatable {
    let sourceName: String
    let appName: String
    let signingIdentifier: String

    static let collector = Self(
        sourceName: "rimeai-voice-performance-tracer",
        appName: VoicePerformanceTracerBundleLayout.collectorAppName,
        signingIdentifier:
            VoicePerformanceMeasurementPolicy
                .requiredCollectorSigningIdentifier
    )
    static let driver = Self(
        sourceName: "rimeai-voice-performance-driver",
        appName: VoicePerformanceTracerBundleLayout.driverAppName,
        signingIdentifier:
            VoicePerformanceMeasurementPolicy.requiredDriverSigningIdentifier
    )
    static let helper = Self(
        sourceName: "rimeai-voice-performance-helper",
        appName: VoicePerformanceTracerBundleLayout.helperAppName,
        signingIdentifier:
            VoicePerformanceMeasurementPolicy.requiredHelperSigningIdentifier
    )
    static let all = [collector, driver, helper]
}

private struct BundleInfoPlistSpec: Equatable {
    let templateName: String
    let signingIdentifier: String
    let packageType: String
    let executableName: String?
    let uiElement: Bool?

    var expectedKeys: Set<String> {
        var result: Set<String> = [
            "CFBundleDevelopmentRegion",
            "CFBundleIdentifier",
            "CFBundleInfoDictionaryVersion",
            "CFBundleName",
            "CFBundlePackageType",
            "CFBundleShortVersionString",
            "CFBundleVersion",
            "LSMinimumSystemVersion",
        ]
        if executableName != nil { result.insert("CFBundleExecutable") }
        if uiElement != nil { result.insert("LSUIElement") }
        return result
    }

    static let outer = Self(
        templateName: "Outer-Info.plist",
        signingIdentifier: BundleConstants.outerSigningIdentifier,
        packageType: "BNDL",
        executableName: nil,
        uiElement: nil
    )
    static let collector = Self(
        templateName: "Collector-Info.plist",
        signingIdentifier: BundleExecutableSpec.collector.signingIdentifier,
        packageType: "APPL",
        executableName: BundleExecutableSpec.collector.sourceName,
        uiElement: true
    )
    static let driver = Self(
        templateName: "Driver-Info.plist",
        signingIdentifier: BundleExecutableSpec.driver.signingIdentifier,
        packageType: "APPL",
        executableName: BundleExecutableSpec.driver.sourceName,
        uiElement: true
    )
    static let helper = Self(
        templateName: "Helper-Info.plist",
        signingIdentifier: BundleExecutableSpec.helper.signingIdentifier,
        packageType: "APPL",
        executableName: BundleExecutableSpec.helper.sourceName,
        uiElement: true
    )
    static let all = [outer, collector, driver, helper]
}

private struct BundleLegalResource {
    let source: String
    let destination: String

    static let all = [
        Self(
            source: "THIRD_PARTY_NOTICES.md",
            destination: "Contents/Resources/THIRD_PARTY_NOTICES.md"
        ),
        Self(
            source:
                "ios/ThirdPartyLicenses/sherpa-onnx-Apache-2.0.txt",
            destination:
                "Contents/Resources/ThirdPartyLicenses/sherpa-onnx-Apache-2.0.txt"
        ),
        Self(
            source: "ios/ThirdPartyLicenses/onnxruntime-MIT.txt",
            destination:
                "Contents/Resources/ThirdPartyLicenses/onnxruntime-MIT.txt"
        ),
        Self(
            source:
                "ios/ThirdPartyLicenses/onnxruntime-ThirdPartyNotices-1.27.1.txt",
            destination:
                "Contents/Resources/ThirdPartyLicenses/onnxruntime-ThirdPartyNotices-1.27.1.txt"
        ),
    ]
}

private struct BundlePaths {
    let root: String

    var contents: String { root + "/Contents" }
    var helpers: String { contents + "/Helpers" }
    var resources: String { contents + "/Resources" }
    var licenseDirectory: String { resources + "/ThirdPartyLicenses" }

    var initialDirectories: [String] {
        var result = [contents, helpers]
        for child in BundleExecutableSpec.all {
            let app = app(for: child)
            // Current macOS codesign materializes an empty Resources
            // directory for executable app bundles. Precreate it for every
            // child so the before/after signature trees are identical.
            result += [
                app,
                app + "/Contents",
                app + "/Contents/MacOS",
                app + "/Contents/Resources",
            ]
        }
        result += [resources, licenseDirectory]
        return result
    }

    var driverPolicy: String {
        root + "/"
            + VoicePerformanceTracerBundleLayout
                .driverPolicyResourceRelativePath
    }
    var measurementPolicy: String {
        root + "/"
            + VoicePerformanceTracerBundleLayout
                .measurementPolicyResourceRelativePath
    }
    var helperReleasePolicy: String {
        root + "/"
            + VoicePerformanceTracerBundleLayout
                .helperReleasePolicyResourceRelativePath
    }

    func app(for spec: BundleExecutableSpec) -> String {
        helpers + "/" + spec.appName
    }

    func executable(for spec: BundleExecutableSpec) -> String {
        app(for: spec) + "/Contents/MacOS/" + spec.sourceName
    }

    func infoPlist(for spec: BundleInfoPlistSpec) -> String {
        switch spec {
        case .outer: root + "/Contents/Info.plist"
        case .collector:
            app(for: .collector) + "/Contents/Info.plist"
        case .driver:
            app(for: .driver) + "/Contents/Info.plist"
        case .helper:
            app(for: .helper) + "/Contents/Info.plist"
        default:
            preconditionFailure("unknown fixed plist specification")
        }
    }
}
