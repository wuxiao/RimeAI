import Darwin
import Foundation
import RimeAIInputCore
import Security

public struct VoiceHelperDebugArguments: Equatable, Sendable {
    public let socketPath: String
    public let engineName: String

    fileprivate init(
        socketPath: String,
        engineName: String
    ) {
        self.socketPath = socketPath
        self.engineName = engineName
    }
}

public enum VoiceHelperReleaseBootstrapError: Error, Equatable, Sendable {
    case invalidDebugArguments
    case invalidReleaseArguments
    case unsignedCurrentProcess
    case codeRequirementCreationFailed(status: OSStatus)
    case bundleCodeCreationFailed(status: OSStatus)
    case bundleSignatureInvalid(status: OSStatus)
    case policyFileUnavailable(path: String, errno: Int32)
    case policyFileMustBeRegular(path: String)
    case policyFileTooLarge(path: String)
    case policyFileReadFailed(path: String, errno: Int32)
}

/// Release-only engine assembly driven by the policy embedded in the signed
/// helper bundle. Strict policy/catalog validation always happens before an
/// engine factory is invoked, so a mismatch cannot touch TCC, the product
/// Store, or the native recognizer and cannot fall back to another engine.
public struct VoiceHelperReleaseBootstrap {
    private typealias EngineFactory = () throws -> any VoiceDictationEngine
    private typealias BundleValidator = (URL) throws -> Void

    private static let maximumPolicyBytes = 65_536
    private let trustedCatalog: VoiceASRTrustedArtifactCatalog
    private let bundleValidator: BundleValidator
    private let appleFactory: EngineFactory
    private let productFactory: EngineFactory

    public init(layout: RimeAIProductDataLayout) {
        self.init(
            trustedCatalog: .production,
            bundleValidator: Self.validateSignedBundle,
            appleFactory: { AppleSpeechEngine() },
            productFactory: {
                try SherpaOnnxProductVoiceEngineFactory.makeEngine(
                    layout: layout
                )
            }
        )
    }

    /// Debug also has an exact grammar so malformed or duplicated flags are
    /// rejected before any engine, Store, native runtime, TCC, or UDS server
    /// is constructed.
    public static func parseDebugArguments(
        _ arguments: [String]
    ) throws -> VoiceHelperDebugArguments {
        let values = Array(arguments.dropFirst())
        guard [2, 4].contains(values.count),
              values[0] == "--socket",
              !values[1].isEmpty
        else {
            throw VoiceHelperReleaseBootstrapError.invalidDebugArguments
        }

        let engineName: String
        switch values.count {
        case 2:
            engineName = "unavailable"
        case 4:
            guard values[2] == "--engine",
                  [
                      "unavailable",
                      "apple-speech",
                      "product-managed",
                  ].contains(values[3])
            else {
                throw VoiceHelperReleaseBootstrapError.invalidDebugArguments
            }
            engineName = values[3]
        default:
            throw VoiceHelperReleaseBootstrapError.invalidDebugArguments
        }
        return VoiceHelperDebugArguments(
            socketPath: values[1],
            engineName: engineName
        )
    }

    /// Release accepts one immutable launchd endpoint and no engine selector
    /// or other argv-provided policy surface.
    public static func validateReleaseArguments(
        _ arguments: [String]
    ) throws {
        let expected = [
            "--mach-service",
            VoiceDictationXPCConstants.machServiceName,
        ]
        guard Array(arguments.dropFirst()) == expected else {
            throw VoiceHelperReleaseBootstrapError.invalidReleaseArguments
        }
    }

    /// Internal factory seam used to prove fail-closed ordering without
    /// constructing Store/native/TCC dependencies in tests.
    init(
        trustedCatalog: VoiceASRTrustedArtifactCatalog,
        bundleValidator: @escaping (URL) throws -> Void,
        appleFactory: @escaping () throws -> any VoiceDictationEngine,
        productFactory: @escaping () throws -> any VoiceDictationEngine
    ) {
        self.trustedCatalog = trustedCatalog
        self.bundleValidator = bundleValidator
        self.appleFactory = appleFactory
        self.productFactory = productFactory
    }

    /// Reads only `Contents/Resources/VoiceReleasePolicy.plist` beneath the
    /// supplied helper bundle. The final path component must be a regular,
    /// non-symlink file.
    public func makeEngine(
        bundleURL: URL
    ) throws -> any VoiceDictationEngine {
        try makeEngine(
            policyData: validatedReleasePolicyData(bundleURL: bundleURL)
        )
    }

    func makeEngine(
        policyData: Data
    ) throws -> any VoiceDictationEngine {
        let policy = try VoiceReleasePolicy.decodeStrict(
            policyData,
            trustedCatalog: trustedCatalog
        )
        switch policy.runtimeEngine {
        case .appleSpeech:
            return try appleFactory()
        case .productManaged:
            return try productFactory()
        }
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
                throw VoiceHelperReleaseBootstrapError.policyFileReadFailed(
                    path: path,
                    errno: errno
                )
            }
            guard data.count + count <= maximumPolicyBytes else {
                throw VoiceHelperReleaseBootstrapError
                    .policyFileTooLarge(path: path)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
