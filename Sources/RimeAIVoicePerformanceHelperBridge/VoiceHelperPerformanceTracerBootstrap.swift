import CryptoKit
import Darwin
import Foundation
import RimeAIInputCore
import RimeAIVoiceHelperEngine
import RimeAIVoicePerformanceControlCore
import Security

enum VoiceHelperPerformanceTracerBootstrapError: Error, Equatable, Sendable {
    case invalidVerifiedHelperExecutablePath
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
    private static let helperExecutableSuffix =
        "/Contents/MacOS/rimeai-voice-performance-helper"
    private let trustedCatalog: VoiceASRTrustedArtifactCatalog
    private let bundleValidator: BundleValidator
    private let evaluationFactory: EvaluationEngineFactory

    private struct OpenedBundleRoot {
        let descriptor: Int32
        let status: stat
    }

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
        measurementPolicy: VoicePerformanceMeasurementPolicy
    ) throws -> VoiceHelperInternalTracerPreparedBundle {
        let bundleURL = try Self.deriveVerifiedHelperBundleURL(
            executablePath:
                measurementPolicy.helper.expectedExecutablePath
        )
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

    static func deriveVerifiedHelperBundleURL(
        executablePath: String
    ) throws -> URL {
        guard Self.isCanonicalAbsolutePath(executablePath),
              executablePath.hasSuffix(helperExecutableSuffix)
        else {
            throw VoiceHelperPerformanceTracerBootstrapError
                .invalidVerifiedHelperExecutablePath
        }
        let bundlePath = String(
            executablePath.dropLast(helperExecutableSuffix.count)
        )
        guard Self.isCanonicalAbsolutePath(bundlePath),
              bundlePath.hasSuffix(".app"),
              bundlePath.utf8.count
                + helperExecutableSuffix.utf8.count < 4_096
        else {
            throw VoiceHelperPerformanceTracerBootstrapError
                .invalidVerifiedHelperExecutablePath
        }
        let bundleURL = URL(
            fileURLWithPath: bundlePath,
            isDirectory: true
        )
        guard bundleURL.path.utf8.elementsEqual(bundlePath.utf8) else {
            throw VoiceHelperPerformanceTracerBootstrapError
                .invalidVerifiedHelperExecutablePath
        }
        return bundleURL
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.utf8.count > 1,
              path.utf8.count < 4_096,
              path.first == "/",
              path.last != "/",
              path.utf8.elementsEqual(
                  path.precomposedStringWithCanonicalMapping.utf8
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

    private func validatedReleasePolicyData(
        bundleURL: URL
    ) throws -> Data {
        let bundlePath = bundleURL.path
        let openedBundle = try Self.openBundleRootByComponents(
            bundlePath
        )
        defer { close(openedBundle.descriptor) }
        try Self.requireExactRootBinding(
            openedBundle,
            path: bundlePath
        )
        try bundleValidator(bundleURL)
        try Self.requireExactRootBinding(
            openedBundle,
            path: bundlePath
        )
        let policyData = try Self.readPolicyData(
            bundleRootDescriptor: openedBundle.descriptor,
            bundlePath: bundlePath
        )
        try Self.requireExactRootBinding(
            openedBundle,
            path: bundlePath
        )
        return policyData
    }

    private static func openBundleRootByComponents(
        _ path: String
    ) throws -> OpenedBundleRoot {
        let components = path.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty else {
            throw VoiceHelperPerformanceTracerBootstrapError
                .invalidVerifiedHelperExecutablePath
        }
        var current = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            throw VoiceHelperPerformanceTracerBootstrapError
                .invalidVerifiedHelperExecutablePath
        }
        do {
            for (index, component) in components.enumerated() {
                var named = stat()
                let namedResult = component.withCString { pointer in
                    fstatat(
                        current,
                        pointer,
                        &named,
                        AT_SYMLINK_NOFOLLOW
                    )
                }
                guard namedResult == 0,
                      named.st_mode & mode_t(S_IFMT)
                        == mode_t(S_IFDIR)
                else {
                    throw VoiceHelperPerformanceTracerBootstrapError
                        .invalidVerifiedHelperExecutablePath
                }
                let next = component.withCString { pointer in
                    openat(
                        current,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else {
                    throw VoiceHelperPerformanceTracerBootstrapError
                        .invalidVerifiedHelperExecutablePath
                }
                var opened = stat()
                guard fstat(next, &opened) == 0,
                      opened.st_mode & mode_t(S_IFMT)
                        == mode_t(S_IFDIR),
                      opened.st_dev == named.st_dev,
                      opened.st_ino == named.st_ino
                else {
                    close(next)
                    throw VoiceHelperPerformanceTracerBootstrapError
                        .invalidVerifiedHelperExecutablePath
                }
                close(current)
                current = next
                if index == components.count - 1 {
                    return OpenedBundleRoot(
                        descriptor: current,
                        status: opened
                    )
                }
            }
        } catch {
            close(current)
            throw error
        }
        close(current)
        throw VoiceHelperPerformanceTracerBootstrapError
            .invalidVerifiedHelperExecutablePath
    }

    private static func requireExactRootBinding(
        _ heldRoot: OpenedBundleRoot,
        path: String
    ) throws {
        var heldStatus = stat()
        guard fstat(heldRoot.descriptor, &heldStatus) == 0,
              heldStatus.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFDIR),
              heldStatus.st_dev == heldRoot.status.st_dev,
              heldStatus.st_ino == heldRoot.status.st_ino
        else {
            throw VoiceHelperPerformanceTracerBootstrapError
                .invalidVerifiedHelperExecutablePath
        }
        let rebound = try openBundleRootByComponents(path)
        defer { close(rebound.descriptor) }
        guard rebound.status.st_dev == heldRoot.status.st_dev,
              rebound.status.st_ino == heldRoot.status.st_ino
        else {
            throw VoiceHelperPerformanceTracerBootstrapError
                .invalidVerifiedHelperExecutablePath
        }
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

    private static func readPolicyData(
        bundleRootDescriptor: Int32,
        bundlePath: String
    ) throws -> Data {
        let path = bundlePath
            + "/Contents/Resources/VoiceReleasePolicy.plist"
        var parentDescriptor = dup(bundleRootDescriptor)
        guard parentDescriptor >= 0 else {
            throw VoiceHelperReleaseBootstrapError.policyFileUnavailable(
                path: path,
                errno: errno
            )
        }
        for component in ["Contents", "Resources"] {
            var named = stat()
            let namedResult = component.withCString { pointer in
                fstatat(
                    parentDescriptor,
                    pointer,
                    &named,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard namedResult == 0,
                  named.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else {
                let savedErrno = namedResult == 0 ? ELOOP : errno
                close(parentDescriptor)
                throw VoiceHelperReleaseBootstrapError
                    .policyFileUnavailable(
                        path: path,
                        errno: savedErrno
                    )
            }
            let nextDescriptor = component.withCString { pointer in
                openat(
                    parentDescriptor,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                let savedErrno = errno
                close(parentDescriptor)
                throw VoiceHelperReleaseBootstrapError
                    .policyFileUnavailable(
                        path: path,
                        errno: savedErrno
                    )
            }
            var opened = stat()
            guard fstat(nextDescriptor, &opened) == 0,
                  opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  opened.st_dev == named.st_dev,
                  opened.st_ino == named.st_ino
            else {
                let savedErrno = errno == 0 ? EIO : errno
                close(nextDescriptor)
                close(parentDescriptor)
                throw VoiceHelperReleaseBootstrapError
                    .policyFileUnavailable(
                        path: path,
                        errno: savedErrno
                    )
            }
            close(parentDescriptor)
            parentDescriptor = nextDescriptor
        }

        let policyName = "VoiceReleasePolicy.plist"
        var namedPolicy = stat()
        let namedPolicyResult = policyName.withCString { pointer in
            fstatat(
                parentDescriptor,
                pointer,
                &namedPolicy,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard namedPolicyResult == 0 else {
            let savedErrno = errno
            close(parentDescriptor)
            throw VoiceHelperReleaseBootstrapError.policyFileUnavailable(
                path: path,
                errno: savedErrno
            )
        }
        guard namedPolicy.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFREG)
        else {
            close(parentDescriptor)
            throw VoiceHelperReleaseBootstrapError
                .policyFileMustBeRegular(path: path)
        }
        let descriptor = policyName.withCString { pointer in
            openat(
                parentDescriptor,
                pointer,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        let openErrno = errno
        close(parentDescriptor)
        guard descriptor >= 0 else {
            throw VoiceHelperReleaseBootstrapError.policyFileUnavailable(
                path: path,
                errno: openErrno
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
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_dev == namedPolicy.st_dev,
              status.st_ino == namedPolicy.st_ino
        else {
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
