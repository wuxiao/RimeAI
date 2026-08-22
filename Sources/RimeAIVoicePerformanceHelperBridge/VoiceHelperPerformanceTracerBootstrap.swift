import CryptoKit
import Darwin
import Foundation
import RimeAIInputCore
import RimeAIVoiceHelperEngine
import RimeAIVoicePerformanceControlCore
import Security

enum VoiceHelperPerformanceTracerBootstrapError: Error, Equatable, Sendable {
    case releasePolicySHA256Mismatch
}

/// Tracer-only policy admission. Before the collector acknowledgement it may
/// validate the signed helper bundle and read the sealed release policy once,
/// but the deferred evaluation verifier/backend factory remains untouched.
struct VoiceHelperPerformanceTracerBootstrap {
    typealias EvaluationEngineFactory =
        (URL) throws -> any VoiceDictationEngine
    private typealias BundleValidator = (URL) throws -> Void

    private static let maximumPolicyBytes = 65_536
    private let trustedCatalog: VoiceASRTrustedArtifactCatalog
    private let bundleValidator: BundleValidator
    private let evaluationFactory: EvaluationEngineFactory

    init(layout: RimeAIProductDataLayout) {
        _ = layout
        self.init(
            trustedCatalog: .production,
            bundleValidator: Self.validateSignedBundle,
            evaluationFactory: {
                try SherpaOnnxEvaluationVoiceEngineFactory
                    .makeTracerEngine(at: $0)
            }
        )
    }

    init(
        trustedCatalog: VoiceASRTrustedArtifactCatalog,
        bundleValidator: @escaping (URL) throws -> Void,
        evaluationFactory: @escaping EvaluationEngineFactory
    ) {
        self.trustedCatalog = trustedCatalog
        self.bundleValidator = bundleValidator
        self.evaluationFactory = evaluationFactory
    }

    func prepareEngine(
        measurementPolicy: VoicePerformanceMeasurementPolicy,
        bundleURL: URL
    ) throws -> VoiceHelperInternalTracerPreparedBundle {
        let policyData = try validatedReleasePolicyData(
            bundleURL: bundleURL
        )
        let actualSHA256 = Self.sha256Hex(policyData)
        guard actualSHA256 == measurementPolicy.releasePolicySHA256 else {
            throw VoiceHelperPerformanceTracerBootstrapError
                .releasePolicySHA256Mismatch
        }
        _ = try VoiceReleasePolicy.decodeStrict(
            policyData,
            trustedCatalog: trustedCatalog
        )
        let artifactDirectory = URL(
            fileURLWithPath: measurementPolicy.evaluationArtifact.directory,
            isDirectory: true
        )
        let evaluationFactory = self.evaluationFactory
        return VoiceHelperInternalTracerPreparedBundle(
            engine: VoiceHelperInternalTracerPreparedEngine(
                loader: {
                    try evaluationFactory(artifactDirectory)
                }
            ),
            verifiedReleasePolicySHA256: try PerformanceControlSHA256(
                actualSHA256
            )
        )
    }

    private func validatedReleasePolicyData(
        bundleURL: URL
    ) throws -> Data {
        try bundleValidator(bundleURL)
        let policyURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(
                "VoiceReleasePolicy.plist",
                isDirectory: false
            )
        return try Self.readPolicyData(at: policyURL)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func validateSignedBundle(_ bundleURL: URL) throws {
        guard let teamIdentifier = VoiceDictationCodeSigningIdentity
            .currentTeamIdentifier()
        else {
            throw VoiceHelperReleaseBootstrapError.unsignedCurrentProcess
        }
        let peerPolicy = try VoiceDictationXPCPeerPolicy(
            expectedIdentifier:
                VoiceDictationXPCConstants.helperSigningIdentifier,
            expectedTeamIdentifier: teamIdentifier
        )
        var codeRequirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            peerPolicy.codeSigningRequirement as CFString,
            SecCSFlags(),
            &codeRequirement
        )
        guard requirementStatus == errSecSuccess,
              let codeRequirement
        else {
            throw VoiceHelperReleaseBootstrapError
                .codeRequirementCreationFailed(status: requirementStatus)
        }

        var staticCode: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard creationStatus == errSecSuccess,
              let staticCode
        else {
            throw VoiceHelperReleaseBootstrapError
                .bundleCodeCreationFailed(status: creationStatus)
        }

        let validationFlags = SecCSFlags(rawValue: UInt32(
            kSecCSStrictValidate
                | kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
        ))
        let validationStatus = SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            codeRequirement
        )
        guard validationStatus == errSecSuccess else {
            throw VoiceHelperReleaseBootstrapError
                .bundleSignatureInvalid(status: validationStatus)
        }
    }

    private static func readPolicyData(at url: URL) throws -> Data {
        let path = url.path
        let descriptor = open(
            path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw VoiceHelperReleaseBootstrapError.policyFileUnavailable(
                path: path,
                errno: errno
            )
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw VoiceHelperReleaseBootstrapError.policyFileReadFailed(
                path: path,
                errno: errno
            )
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw VoiceHelperReleaseBootstrapError
                .policyFileMustBeRegular(path: path)
        }
        guard status.st_size >= 0,
              status.st_size <= off_t(maximumPolicyBytes)
        else {
            throw VoiceHelperReleaseBootstrapError
                .policyFileTooLarge(path: path)
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 {
                return data
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw VoiceHelperReleaseBootstrapError
                    .policyFileReadFailed(path: path, errno: errno)
            }
            guard data.count + count <= maximumPolicyBytes else {
                throw VoiceHelperReleaseBootstrapError
                    .policyFileTooLarge(path: path)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
