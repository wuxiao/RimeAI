import CryptoKit
import Darwin
import Foundation
import RimeAIVoicePerformanceControlCore
import Security

@_silgen_name("csops")
private func rimeaiPerformanceTracerCSOps(
    _ pid: pid_t,
    _ operation: UInt32,
    _ address: UnsafeMutableRawPointer?,
    _ size: Int
) -> Int32

/// The one process identity a signed tracer child is allowed to verify.
public enum VoicePerformanceTracerProcessRole: String, Equatable, Sendable {
    case collector
    case driver
    case helper

    fileprivate var executableSuffix: String {
        switch self {
        case .collector:
            VoicePerformanceTracerBundleLayout.collectorExecutableSuffix
        case .driver:
            VoicePerformanceTracerBundleLayout.driverExecutableSuffix
        case .helper:
            VoicePerformanceTracerBundleLayout.helperExecutableSuffix
        }
    }
}

/// Immutable inputs recovered from the signed outer tracer bundle.
///
/// This context is tracer-only evidence. Verifying it can never establish a
/// production driver authority.
public struct VerifiedPerformanceTracerBundleContext: Sendable {
    /// Exact lexical path used for identity comparisons. Callers must not
    /// derive authority from URL normalization.
    public let outerPath: String
    public let outerURL: URL
    public let measurementPolicy: VoicePerformanceMeasurementPolicy
    public let driverPolicy: SealedPerformanceControlDriverPolicy?
    public let selfStartToken: UInt64
    /// The outer signature proves integrity for one Developer-ID cohort; its
    /// Team ID is not a code-pinned, approved RimeAI production authority.
    public let authenticatedProductionDriver = false
}

/// Verifies the signed outer bundle, its sealed policies, and the live child
/// process as one generation-sandwiched identity.
///
/// The nested code seal is the resource-integrity gate. Every opened path edge
/// also rejects rename authority from another UID, and executable/resources
/// reject extended ACLs. A process already compromised under the same
/// effective UID remains outside this tracer's authorization threat model.
public struct PerformanceTracerBundleVerifier: Sendable {
    public static let requiredOuterSigningIdentifier =
        "fun.wwcn.rimeai.voice-performance-tracer"

    static let measurementPolicyRelativePath =
        "Contents/Resources/VoicePerformanceMeasurementPolicy.json"
    static let driverPolicyRelativePath =
        "Contents/Resources/VoicePerformanceDriverPolicy.json"

    private let system: any PerformanceTracerBundleVerifyingSystem

    public init() {
        system = MacOSPerformanceTracerBundleVerifierSystem()
    }

    init(system: any PerformanceTracerBundleVerifyingSystem) {
        self.system = system
    }

    public func verify(
        role: VoicePerformanceTracerProcessRole,
        declaredTracerBundlePath: String
    ) throws -> VerifiedPerformanceTracerBundleContext {
        do {
            return try verifyCodeOwned(
                role: role,
                declaredTracerBundlePath: declaredTracerBundlePath
            )
        } catch {
            // Never echo a caller-controlled path, identity, or policy field.
            throw VoicePerformanceTracerProcessError.invalidTracerBundle
        }
    }

    private func verifyCodeOwned(
        role: VoicePerformanceTracerProcessRole,
        declaredTracerBundlePath: String
    ) throws -> VerifiedPerformanceTracerBundleContext {
        let pid = system.currentProcessIdentifier
        guard pid > 0 else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        let firstProcess = try system.processSnapshot(pid: pid)
        guard Self.isLive(firstProcess), firstProcess.pid == pid else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }

        let executablePath = try system.currentExecutablePath(pid: pid)
        guard Self.isCanonicalAbsolutePath(executablePath),
              executablePath.hasSuffix(role.executableSuffix)
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        let derivedBundlePath = String(
            executablePath.dropLast(role.executableSuffix.count)
        )
        guard Self.isCanonicalBundlePath(derivedBundlePath),
              Self.isCanonicalBundlePath(declaredTracerBundlePath),
              Self.byteExactlyEqual(
                  declaredTracerBundlePath,
                  derivedBundlePath
              )
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }

        // The outer supplies one exact Developer-ID Team for this cohort.
        // No Team value learned here is upgraded to production authority.
        let firstOuter = try system.outerCodeIdentity(at: derivedBundlePath)
        try Self.validateOuterIdentity(
            firstOuter,
            expectedPath: derivedBundlePath
        )

        let measurementResource = try system.readSealedResource(
            relativePath: Self.measurementPolicyRelativePath,
            from: derivedBundlePath,
            maximumBytes:
                VoicePerformanceMeasurementPolicy.maximumEncodedBytes,
            outerSealToken: firstOuter.sealToken
        )
        try Self.validateResource(
            measurementResource,
            expectedRelativePath: Self.measurementPolicyRelativePath,
            expectedBundlePath: derivedBundlePath,
            expectedSealToken: firstOuter.sealToken,
            maximumBytes:
                VoicePerformanceMeasurementPolicy.maximumEncodedBytes,
            effectiveUserID: system.effectiveUserID
        )
        let measurementPolicy =
            try VoicePerformanceMeasurementPolicy.decodeCanonical(
                measurementResource.data
            )
        guard !measurementPolicy.authenticatedProductionDriver,
              measurementPolicy.collector.expectedTeamIdentifier
                == firstOuter.teamIdentifier,
              measurementPolicy.driver.expectedTeamIdentifier
                == firstOuter.teamIdentifier,
              measurementPolicy.helper.expectedTeamIdentifier
                == firstOuter.teamIdentifier
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        guard Self.byteExactlyEqual(
                  measurementPolicy.collector.expectedExecutablePath,
                  derivedBundlePath
                    + VoicePerformanceTracerBundleLayout
                        .collectorExecutableSuffix
              ),
              Self.byteExactlyEqual(
                  measurementPolicy.driver.expectedExecutablePath,
                  derivedBundlePath
                    + VoicePerformanceTracerBundleLayout
                        .driverExecutableSuffix
              ),
              Self.byteExactlyEqual(
                  measurementPolicy.helper.expectedExecutablePath,
                  derivedBundlePath
                    + VoicePerformanceTracerBundleLayout
                        .helperExecutableSuffix
              )
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }

        let expectedSelf = Self.expectedSelfIdentity(
            role: role,
            policy: measurementPolicy
        )
        guard Self.byteExactlyEqual(
                  expectedSelf.executablePath,
                  derivedBundlePath + role.executableSuffix
              ),
              Self.byteExactlyEqual(
                  expectedSelf.executablePath,
                  executablePath
              )
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }

        let driverPolicy: SealedPerformanceControlDriverPolicy?
        switch role {
        case .collector, .driver:
            let driverResource = try system.readSealedResource(
                relativePath: Self.driverPolicyRelativePath,
                from: derivedBundlePath,
                maximumBytes:
                    SealedPerformanceControlDriverPolicy.maximumEncodedBytes,
                outerSealToken: firstOuter.sealToken
            )
            try Self.validateResource(
                driverResource,
                expectedRelativePath: Self.driverPolicyRelativePath,
                expectedBundlePath: derivedBundlePath,
                expectedSealToken: firstOuter.sealToken,
                maximumBytes:
                    SealedPerformanceControlDriverPolicy.maximumEncodedBytes,
                effectiveUserID: system.effectiveUserID
            )
            let decoded =
                try SealedPerformanceControlDriverPolicy.decodeCanonical(
                    driverResource.data,
                    expectedControlProtocol:
                        measurementPolicy.controlProtocol
                )
            guard decoded.qualification == .tracer,
                  decoded.capabilities
                    == SealedPerformanceControlDriverPolicy
                        .tracerCapabilities,
                  !decoded.authenticatedProductionDriver,
                  decoded.canonicalSHA256.rawValue
                    == measurementPolicy.driver.policySHA256
            else {
                throw PerformanceTracerBundleVerifierSystemError.failed
            }
            driverPolicy = decoded
        case .helper:
            // The helper does not need, and must not read, driver authority.
            driverPolicy = nil
        }

        let secondOuter = try system.outerCodeIdentity(at: derivedBundlePath)
        try Self.validateOuterIdentity(
            secondOuter,
            expectedPath: derivedBundlePath
        )
        guard secondOuter == firstOuter else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }

        let selfCode = try system.selfCodeIdentity(
            at: executablePath,
            expectedSigningIdentifier: expectedSelf.signingIdentifier,
            expectedTeamIdentifier: firstOuter.teamIdentifier
        )
        guard Self.byteExactlyEqual(
                  selfCode.executablePath,
                  executablePath
              ),
              selfCode.signingIdentifier == expectedSelf.signingIdentifier,
              selfCode.teamIdentifier == firstOuter.teamIdentifier,
              selfCode.cdHash == expectedSelf.cdHash,
              Self.isLowercaseHex(selfCode.cdHash, byteCount: 20),
              selfCode.codeDirectoryFlags
                & PerformanceTracerSelfCodeIdentity.hardenedRuntimeFlag != 0,
              !selfCode.hasDisallowedEntitlements,
              !selfCode.isDebugged,
              selfCode.developerIDValidated,
              selfCode.strictValidation,
              selfCode.allArchitecturesValidated
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }

        let executableFile = try system.executableFileIdentity(
            at: executablePath,
            maximumBytes:
                MacOSPerformanceTracerBundleVerifierSystem
                    .maximumExecutableBytes
        )
        guard executableFile.sha256 == expectedSelf.executableSHA256,
              Self.isLowercaseHex(
                  executableFile.sha256,
                  byteCount: 32
              ),
              executableFile.ownerEUID == 0
                || executableFile.ownerEUID == system.effectiveUserID,
              executableFile.mode & S_IFMT == S_IFREG,
              executableFile.mode & (S_ISUID | S_ISGID) == 0,
              executableFile.mode & (S_IWGRP | S_IWOTH) == 0,
              executableFile.size > 0,
              executableFile.size
                <= MacOSPerformanceTracerBundleVerifierSystem
                    .maximumExecutableBytes,
              executableFile.stable,
              executableFile.openedWithoutSymlink
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }

        let secondProcess = try system.processSnapshot(pid: pid)
        guard Self.isLive(secondProcess),
              secondProcess.pid == firstProcess.pid,
              secondProcess.startToken == firstProcess.startToken,
              secondProcess.userCPUNanoseconds
                >= firstProcess.userCPUNanoseconds,
              secondProcess.systemCPUNanoseconds
                >= firstProcess.systemCPUNanoseconds,
              secondProcess.energyNanojoules
                >= firstProcess.energyNanojoules
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }

        let outerURL = URL(
            fileURLWithPath: derivedBundlePath,
            isDirectory: true
        )
        guard Self.byteExactlyEqual(outerURL.path, derivedBundlePath) else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return VerifiedPerformanceTracerBundleContext(
            outerPath: derivedBundlePath,
            outerURL: outerURL,
            measurementPolicy: measurementPolicy,
            driverPolicy: driverPolicy,
            selfStartToken: secondProcess.startToken
        )
    }

    private struct ExpectedSelfIdentity {
        let executablePath: String
        let executableSHA256: String
        let signingIdentifier: String
        let cdHash: String
    }

    private static func expectedSelfIdentity(
        role: VoicePerformanceTracerProcessRole,
        policy: VoicePerformanceMeasurementPolicy
    ) -> ExpectedSelfIdentity {
        switch role {
        case .collector:
            ExpectedSelfIdentity(
                executablePath:
                    policy.collector.expectedExecutablePath,
                executableSHA256:
                    policy.collector.expectedExecutableSHA256,
                signingIdentifier:
                    policy.collector.expectedSigningIdentifier,
                cdHash: policy.collector.expectedCDHash
            )
        case .driver:
            ExpectedSelfIdentity(
                executablePath: policy.driver.expectedExecutablePath,
                executableSHA256:
                    policy.driver.expectedExecutableSHA256,
                signingIdentifier:
                    policy.driver.expectedSigningIdentifier,
                cdHash: policy.driver.expectedCDHash
            )
        case .helper:
            ExpectedSelfIdentity(
                executablePath: policy.helper.expectedExecutablePath,
                executableSHA256:
                    policy.helper.expectedExecutableSHA256,
                signingIdentifier:
                    policy.helper.expectedSigningIdentifier,
                cdHash: policy.helper.expectedCDHash
            )
        }
    }

    private static func validateOuterIdentity(
        _ identity: PerformanceTracerOuterCodeIdentity,
        expectedPath: String
    ) throws {
        guard byteExactlyEqual(identity.bundlePath, expectedPath),
              identity.signingIdentifier
                == requiredOuterSigningIdentifier,
              isTeamIdentifier(identity.teamIdentifier),
              isLowercaseHex(identity.cdHash, byteCount: 20),
              isLowercaseHex(identity.sealToken, byteCount: 32),
              identity.developerIDValidated,
              identity.strictValidation,
              identity.allArchitecturesValidated,
              identity.nestedSealValidated
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
    }

    private static func validateResource(
        _ resource: PerformanceTracerSealedResource,
        expectedRelativePath: String,
        expectedBundlePath: String,
        expectedSealToken: String,
        maximumBytes: Int,
        effectiveUserID: uid_t
    ) throws {
        guard byteExactlyEqual(
                  resource.relativePath,
                  expectedRelativePath
              ),
              byteExactlyEqual(
                  resource.sourceBundlePath,
                  expectedBundlePath
              ),
              resource.outerSealToken == expectedSealToken,
              resource.openedComponentWiseWithoutSymlinks,
              resource.before == resource.after,
              resource.before.size > 0,
              resource.before.size <= UInt64(maximumBytes),
              resource.before.size == UInt64(resource.data.count),
              resource.before.ownerEUID == 0
                || resource.before.ownerEUID == effectiveUserID,
              resource.before.mode & S_IFMT == S_IFREG,
              resource.before.mode & (S_ISUID | S_ISGID) == 0,
              resource.before.mode & (S_IWGRP | S_IWOTH) == 0,
              resource.before.mode & (S_IXUSR | S_IXGRP | S_IXOTH) == 0
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
    }

    private static func isLive(
        _ snapshot: PerformanceTracerProcessSnapshot
    ) -> Bool {
        snapshot.pid > 0
            && snapshot.startToken > 0
            && snapshot.exitToken == 0
    }

    private static func isCanonicalBundlePath(_ path: String) -> Bool {
        isCanonicalAbsolutePath(path) && path.hasSuffix(".bundle")
    }

    static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.utf8.count > 1,
              path.utf8.count < Int(MAXPATHLEN),
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
        let components = path.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return !components.isEmpty
            && components.allSatisfy {
                !$0.isEmpty
                    && $0 != "."
                    && $0 != ".."
                    && $0.utf8.count <= Int(NAME_MAX)
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
            (0x30 ... 0x39).contains(byte)
                || (0x61 ... 0x66).contains(byte)
        }
    }

    static func byteExactlyEqual(_ left: String, _ right: String) -> Bool {
        left.utf8.elementsEqual(right.utf8)
    }
}

struct PerformanceTracerProcessSnapshot: Equatable, Sendable {
    let pid: pid_t
    let startToken: UInt64
    let exitToken: UInt64
    let userCPUNanoseconds: UInt64
    let systemCPUNanoseconds: UInt64
    let energyNanojoules: UInt64
}

struct PerformanceTracerOuterCodeIdentity: Equatable, Sendable {
    let bundlePath: String
    let signingIdentifier: String
    let teamIdentifier: String
    let cdHash: String
    let sealToken: String
    let developerIDValidated: Bool
    let strictValidation: Bool
    let allArchitecturesValidated: Bool
    let nestedSealValidated: Bool
}

struct PerformanceTracerStableFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let ownerEUID: uid_t
    let mode: mode_t
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
}

struct PerformanceTracerSealedResource: Equatable, Sendable {
    let data: Data
    let relativePath: String
    let sourceBundlePath: String
    let outerSealToken: String
    let openedComponentWiseWithoutSymlinks: Bool
    let before: PerformanceTracerStableFileIdentity
    let after: PerformanceTracerStableFileIdentity
}

struct PerformanceTracerSelfCodeIdentity: Equatable, Sendable {
    // Stable Darwin code-signing ABI value from kern/cs_blobs.h.
    static let hardenedRuntimeFlag: UInt32 = 0x0001_0000
    static let debuggedFlag: UInt32 = 0x1000_0000

    let executablePath: String
    let signingIdentifier: String
    let teamIdentifier: String
    let cdHash: String
    let codeDirectoryFlags: UInt32
    let hasDisallowedEntitlements: Bool
    let isDebugged: Bool
    let developerIDValidated: Bool
    let strictValidation: Bool
    let allArchitecturesValidated: Bool
}

struct PerformanceTracerExecutableFileIdentity: Equatable, Sendable {
    let sha256: String
    let ownerEUID: uid_t
    let mode: mode_t
    let size: UInt64
    let stable: Bool
    let openedWithoutSymlink: Bool
}

protocol PerformanceTracerBundleVerifyingSystem: Sendable {
    var effectiveUserID: uid_t { get }
    var currentProcessIdentifier: pid_t { get }

    func processSnapshot(pid: pid_t) throws
        -> PerformanceTracerProcessSnapshot
    func currentExecutablePath(pid: pid_t) throws -> String
    func outerCodeIdentity(at bundlePath: String) throws
        -> PerformanceTracerOuterCodeIdentity
    func readSealedResource(
        relativePath: String,
        from bundlePath: String,
        maximumBytes: Int,
        outerSealToken: String
    ) throws -> PerformanceTracerSealedResource
    func selfCodeIdentity(
        at executablePath: String,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> PerformanceTracerSelfCodeIdentity
    func executableFileIdentity(
        at executablePath: String,
        maximumBytes: UInt64
    ) throws -> PerformanceTracerExecutableFileIdentity
}

enum PerformanceTracerBundleVerifierSystemError: Error {
    case failed
}

struct MacOSPerformanceTracerBundleVerifierSystem:
    PerformanceTracerBundleVerifyingSystem
{
    static let maximumExecutableBytes: UInt64 = 512 * 1_024 * 1_024

    var effectiveUserID: uid_t { geteuid() }
    var currentProcessIdentifier: pid_t { getpid() }

    func processSnapshot(pid: pid_t) throws
        -> PerformanceTracerProcessSnapshot
    {
        guard pid > 0 else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        var usage = rusage_info_v6()
        var status: Int32 = -1
        repeat {
            status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(
                    to: rusage_info_t?.self,
                    capacity: 1
                ) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
        } while status != 0 && errno == EINTR
        guard status == 0 else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return PerformanceTracerProcessSnapshot(
            pid: pid,
            startToken: usage.ri_proc_start_abstime,
            exitToken: usage.ri_proc_exit_abstime,
            userCPUNanoseconds: usage.ri_user_time,
            systemCPUNanoseconds: usage.ri_system_time,
            energyNanojoules: usage.ri_energy_nj
        )
    }

    func currentExecutablePath(pid: pid_t) throws -> String {
        guard pid == currentProcessIdentifier else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var count: Int32 = -1
        repeat {
            count = proc_pidpath(
                pid,
                &bytes,
                UInt32(bytes.count)
            )
        } while count < 0 && errno == EINTR
        guard count > 1,
              Int(count) < bytes.count,
              bytes[Int(count)] == 0,
              !bytes[..<Int(count)].contains(0),
              let path = String(
                  bytes: bytes[..<Int(count)].map(
                      UInt8.init(bitPattern:)
                  ),
                  encoding: .utf8
              )
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return path
    }

    func outerCodeIdentity(
        at bundlePath: String
    ) throws -> PerformanceTracerOuterCodeIdentity {
        let code = try staticCode(at: bundlePath)
        let first = try signingInformation(code)
        guard first.signingIdentifier
                == PerformanceTracerBundleVerifier
                    .requiredOuterSigningIdentifier,
              Self.isTeamIdentifier(first.teamIdentifier),
              first.cdHash.count == 40
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        let requirement = try developerIDRequirement(
            signingIdentifier: first.signingIdentifier,
            teamIdentifier: first.teamIdentifier
        )
        let flags = SecCSFlags(
            rawValue: kSecCSStrictValidate
                | kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
        )
        guard SecStaticCodeCheckValidity(
            code,
            flags,
            requirement
        ) == errSecSuccess else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        let second = try signingInformation(code)
        guard second == first else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return PerformanceTracerOuterCodeIdentity(
            bundlePath: bundlePath,
            signingIdentifier: second.signingIdentifier,
            teamIdentifier: second.teamIdentifier,
            cdHash: second.cdHash,
            sealToken: Self.sealToken(
                signingIdentifier: second.signingIdentifier,
                teamIdentifier: second.teamIdentifier,
                cdHash: second.cdHash
            ),
            developerIDValidated: true,
            strictValidation: true,
            allArchitecturesValidated: true,
            nestedSealValidated: true
        )
    }

    func readSealedResource(
        relativePath: String,
        from bundlePath: String,
        maximumBytes: Int,
        outerSealToken: String
    ) throws -> PerformanceTracerSealedResource {
        guard maximumBytes > 0,
              relativePath
                == PerformanceTracerBundleVerifier
                    .measurementPolicyRelativePath
                || relativePath
                    == PerformanceTracerBundleVerifier
                        .driverPolicyRelativePath
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }

        var directory = try openAbsoluteDirectoryComponentWise(
            bundlePath,
            validateFinalDirectory: true
        )
        defer {
            if directory >= 0 {
                _ = Darwin.close(directory)
            }
        }
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count == 3,
              components[0] == "Contents",
              components[1] == "Resources"
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        for component in components.dropLast() {
            let next = try openDirectory(
                named: component,
                relativeTo: directory,
                validateSafety: true
            )
            _ = Darwin.close(directory)
            directory = next
        }
        let descriptor = try openRegularFile(
            named: components[2],
            relativeTo: directory
        )
        defer { _ = Darwin.close(descriptor) }
        try validateNoExtendedACL(descriptor)
        let beforeStat = try stableStat(descriptor)
        try validateRegularFile(
            beforeStat,
            maximumBytes: UInt64(maximumBytes),
            allowExecutableMode: false
        )
        let data = try readToEnd(
            descriptor,
            expectedSize: UInt64(beforeStat.st_size),
            maximumBytes: UInt64(maximumBytes)
        )
        // Revalidate the nested resource seal while the exact resource fd is
        // still open. The fixed path must still name that same inode.
        let sealedOuter = try outerCodeIdentity(at: bundlePath)
        guard sealedOuter.sealToken == outerSealToken else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        let pathStat = try stableStat(
            named: components[2],
            relativeTo: directory
        )
        let afterStat = try stableStat(descriptor)
        try validateNoExtendedACL(descriptor)
        let before = Self.fileIdentity(beforeStat)
        let after = Self.fileIdentity(afterStat)
        guard before == after,
              before == Self.fileIdentity(pathStat),
              before.size == UInt64(data.count)
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return PerformanceTracerSealedResource(
            data: data,
            relativePath: relativePath,
            sourceBundlePath: bundlePath,
            outerSealToken: outerSealToken,
            openedComponentWiseWithoutSymlinks: true,
            before: before,
            after: after
        )
    }

    func selfCodeIdentity(
        at executablePath: String,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> PerformanceTracerSelfCodeIdentity {
        let requirement = try developerIDRequirement(
            signingIdentifier: expectedSigningIdentifier,
            teamIdentifier: expectedTeamIdentifier
        )
        var liveCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &liveCode) == errSecSuccess,
              let liveCode,
              SecCodeCheckValidity(
                  liveCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate),
                  requirement
              ) == errSecSuccess
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        let dynamicStatus = try dynamicCodeStatus()
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            liveCode,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        let staticFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
        )
        guard SecStaticCodeCheckValidity(
            staticCode,
            staticFlags,
            requirement
        ) == errSecSuccess
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        // SecCodeCopyStaticCode preserves the binding to the already-validated
        // live SecCode without relying on nominal CF-type reinterpretation.
        let staticInformation = try signingInformation(staticCode)
        guard PerformanceTracerBundleVerifier.byteExactlyEqual(
                  staticInformation.executablePath ?? "",
                  executablePath
              ),
              staticInformation.signingIdentifier
                == expectedSigningIdentifier,
              staticInformation.teamIdentifier == expectedTeamIdentifier
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return PerformanceTracerSelfCodeIdentity(
            executablePath: executablePath,
            signingIdentifier: staticInformation.signingIdentifier,
            teamIdentifier: staticInformation.teamIdentifier,
            cdHash: staticInformation.cdHash,
            codeDirectoryFlags: staticInformation.codeDirectoryFlags,
            hasDisallowedEntitlements:
                staticInformation.hasDisallowedEntitlements,
            isDebugged:
                dynamicStatus & PerformanceTracerSelfCodeIdentity.debuggedFlag
                    != 0,
            developerIDValidated: true,
            strictValidation: true,
            allArchitecturesValidated: true
        )
    }

    func executableFileIdentity(
        at executablePath: String,
        maximumBytes: UInt64
    ) throws -> PerformanceTracerExecutableFileIdentity {
        let components = executablePath.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.count >= 2,
              components.allSatisfy({ !$0.isEmpty })
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        let parentPath = "/" + components.dropLast().joined(separator: "/")
        let parent = try openAbsoluteDirectoryComponentWise(
            parentPath,
            validateFinalDirectory: true
        )
        defer { _ = Darwin.close(parent) }
        let descriptor = try openRegularFile(
            named: components.last!,
            relativeTo: parent
        )
        defer { _ = Darwin.close(descriptor) }
        try validateNoExtendedACL(descriptor)
        let before = try stableStat(descriptor)
        try validateRegularFile(
            before,
            maximumBytes: maximumBytes,
            allowExecutableMode: true
        )
        let digest = try sha256ToEnd(
            descriptor,
            expectedSize: UInt64(before.st_size),
            maximumBytes: maximumBytes
        )
        let after = try stableStat(descriptor)
        try validateNoExtendedACL(descriptor)
        guard Self.fileIdentity(before) == Self.fileIdentity(after),
              UInt64(after.st_size) == UInt64(before.st_size)
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return PerformanceTracerExecutableFileIdentity(
            sha256: digest,
            ownerEUID: after.st_uid,
            mode: after.st_mode,
            size: UInt64(after.st_size),
            stable: true,
            openedWithoutSymlink: true
        )
    }

    private struct SigningInformation: Equatable {
        let executablePath: String?
        let signingIdentifier: String
        let teamIdentifier: String
        let cdHash: String
        let codeDirectoryFlags: UInt32
        let hasDisallowedEntitlements: Bool
    }

    private func dynamicCodeStatus() throws -> UInt32 {
        var status: UInt32 = 0
        let result = withUnsafeMutablePointer(to: &status) { pointer in
            rimeaiPerformanceTracerCSOps(
                Darwin.getpid(),
                0, // CS_OPS_STATUS from XNU bsd/sys/codesign.h.
                UnsafeMutableRawPointer(pointer),
                MemoryLayout<UInt32>.size
            )
        }
        guard result == 0 else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return status
    }

    private func staticCode(at path: String) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: path) as CFURL,
            SecCSFlags(),
            &code
        ) == errSecSuccess,
              let code
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return code
    }

    private func signingInformation(
        _ code: SecStaticCode
    ) throws -> SigningInformation {
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &dictionary
        ) == errSecSuccess,
              let information = dictionary as? [CFString: Any],
              let signingIdentifier =
                information[kSecCodeInfoIdentifier] as? String,
              let teamIdentifier =
                information[kSecCodeInfoTeamIdentifier] as? String,
              let cdHashData = information[kSecCodeInfoUnique] as? Data,
              cdHashData.count == 20,
              let flags = information[kSecCodeInfoFlags] as? NSNumber
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        let executablePath = (
            information[kSecCodeInfoMainExecutable] as? URL
        )?.path
        let entitlementData =
            information[kSecCodeInfoEntitlements] as? Data
        let entitlementDictionary =
            information[kSecCodeInfoEntitlementsDict]
                as? [String: Any]
        let hasMalformedEntitlements = entitlementData != nil
            && entitlementDictionary == nil
        let hasEffectiveEntitlements = entitlementDictionary?.contains {
            _, value in
            if let boolean = value as? Bool { return boolean }
            if let number = value as? NSNumber {
                return number.boolValue
            }
            return true
        } ?? false
        return SigningInformation(
            executablePath: executablePath,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            cdHash: cdHashData.map {
                String(format: "%02x", $0)
            }.joined(),
            codeDirectoryFlags: flags.uint32Value,
            hasDisallowedEntitlements:
                hasMalformedEntitlements || hasEffectiveEntitlements
        )
    }

    private func developerIDRequirement(
        signingIdentifier: String,
        teamIdentifier: String
    ) throws -> SecRequirement {
        guard Self.isSigningIdentifier(signingIdentifier),
              Self.isTeamIdentifier(teamIdentifier)
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
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
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return requirement
    }

    private func openAbsoluteDirectoryComponentWise(
        _ path: String,
        validateFinalDirectory: Bool
    ) throws -> Int32 {
        let components = path.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard path.first == "/",
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty })
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        var directory = Darwin.open(
            "/",
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard directory >= 0 else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        do {
            for (index, component) in components.enumerated() {
                let next = try openDirectory(
                    named: component,
                    relativeTo: directory,
                    validateSafety: false
                )
                if validateFinalDirectory {
                    let parent = try stableStat(directory)
                    let child = try stableStat(next)
                    try validateDirectory(
                        parent,
                        nextEntryOwner: child.st_uid
                    )
                    try validateNoExtendedACL(directory)
                    if index == components.count - 1 {
                        try validateDirectory(
                            child,
                            nextEntryOwner: nil
                        )
                        try validateNoExtendedACL(next)
                    }
                }
                _ = Darwin.close(directory)
                directory = next
            }
            return directory
        } catch {
            _ = Darwin.close(directory)
            throw error
        }
    }

    private func openDirectory(
        named component: String,
        relativeTo directory: Int32,
        validateSafety: Bool
    ) throws -> Int32 {
        guard Self.isPathComponent(component) else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        var descriptor: Int32 = -1
        repeat {
            descriptor = Darwin.openat(
                directory,
                component,
                O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
            )
        } while descriptor < 0 && errno == EINTR
        guard descriptor >= 0 else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        if validateSafety {
            do {
                let value = try stableStat(descriptor)
                try validateDirectory(value, nextEntryOwner: nil)
                try validateNoExtendedACL(descriptor)
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        return descriptor
    }

    private func openRegularFile(
        named component: String,
        relativeTo directory: Int32
    ) throws -> Int32 {
        guard Self.isPathComponent(component) else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        var descriptor: Int32 = -1
        repeat {
            descriptor = Darwin.openat(
                directory,
                component,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        } while descriptor < 0 && errno == EINTR
        guard descriptor >= 0 else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return descriptor
    }

    private func validateDirectory(
        _ value: stat,
        nextEntryOwner: uid_t?
    ) throws {
        guard value.st_mode & S_IFMT == S_IFDIR,
              value.st_uid == 0 || value.st_uid == effectiveUserID,
              value.st_mode & (S_ISUID | S_ISGID) == 0
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        guard value.st_mode & (S_IWGRP | S_IWOTH) != 0 else {
            return
        }
        // A root-owned sticky directory such as /private/tmp cannot rename a
        // child owned by root or this effective UID. No other writable edge is
        // an acceptable authority boundary for an executable evidence path.
        guard value.st_uid == 0,
              value.st_mode & S_ISVTX != 0,
              let nextEntryOwner,
              nextEntryOwner == 0 || nextEntryOwner == effectiveUserID
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
    }

    private func validateNoExtendedACL(_ descriptor: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else {
                throw PerformanceTracerBundleVerifierSystemError.failed
            }
            return
        }
        acl_free(UnsafeMutableRawPointer(acl))
        throw PerformanceTracerBundleVerifierSystemError.failed
    }

    private func validateRegularFile(
        _ value: stat,
        maximumBytes: UInt64,
        allowExecutableMode: Bool
    ) throws {
        guard value.st_mode & S_IFMT == S_IFREG,
              value.st_size > 0,
              UInt64(value.st_size) <= maximumBytes,
              value.st_uid == 0 || value.st_uid == effectiveUserID,
              value.st_mode & (S_ISUID | S_ISGID) == 0,
              value.st_mode & (S_IWGRP | S_IWOTH) == 0,
              allowExecutableMode
                || value.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) == 0
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
    }

    private func readToEnd(
        _ descriptor: Int32,
        expectedSize: UInt64,
        maximumBytes: UInt64
    ) throws -> Data {
        guard expectedSize > 0,
              expectedSize <= maximumBytes,
              expectedSize <= UInt64(Int.max)
        else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        var result = Data()
        result.reserveCapacity(Int(expectedSize))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            var copied: Int = -1
            repeat {
                copied = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(
                        descriptor,
                        bytes.baseAddress,
                        bytes.count
                    )
                }
            } while copied < 0 && errno == EINTR
            guard copied >= 0 else {
                throw PerformanceTracerBundleVerifierSystemError.failed
            }
            if copied == 0 { break }
            guard UInt64(result.count) + UInt64(copied)
                    <= expectedSize,
                  UInt64(result.count) + UInt64(copied)
                    <= maximumBytes
            else {
                throw PerformanceTracerBundleVerifierSystemError.failed
            }
            result.append(contentsOf: buffer[..<copied])
        }
        guard UInt64(result.count) == expectedSize else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return result
    }

    private func sha256ToEnd(
        _ descriptor: Int32,
        expectedSize: UInt64,
        maximumBytes: UInt64
    ) throws -> String {
        guard expectedSize > 0, expectedSize <= maximumBytes else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        var hasher = SHA256()
        var totalBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            var copied: Int = -1
            repeat {
                copied = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(
                        descriptor,
                        bytes.baseAddress,
                        bytes.count
                    )
                }
            } while copied < 0 && errno == EINTR
            guard copied >= 0 else {
                throw PerformanceTracerBundleVerifierSystemError.failed
            }
            if copied == 0 { break }
            let copiedBytes = UInt64(copied)
            guard copiedBytes <= expectedSize,
                  copiedBytes <= maximumBytes,
                  totalBytes <= expectedSize - copiedBytes,
                  totalBytes <= maximumBytes - copiedBytes
            else {
                throw PerformanceTracerBundleVerifierSystemError.failed
            }
            totalBytes += copiedBytes
            hasher.update(data: Data(buffer[..<copied]))
        }
        guard totalBytes == expectedSize else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func stableStat(_ descriptor: Int32) throws -> stat {
        var value = stat()
        var status: Int32 = -1
        repeat {
            status = fstat(descriptor, &value)
        } while status != 0 && errno == EINTR
        guard status == 0 else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return value
    }

    private func stableStat(
        named component: String,
        relativeTo directory: Int32
    ) throws -> stat {
        guard Self.isPathComponent(component) else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        var value = stat()
        var status: Int32 = -1
        repeat {
            status = fstatat(
                directory,
                component,
                &value,
                AT_SYMLINK_NOFOLLOW
            )
        } while status != 0 && errno == EINTR
        guard status == 0 else {
            throw PerformanceTracerBundleVerifierSystemError.failed
        }
        return value
    }

    private static func fileIdentity(
        _ value: stat
    ) -> PerformanceTracerStableFileIdentity {
        PerformanceTracerStableFileIdentity(
            device: UInt64(bitPattern: Int64(value.st_dev)),
            inode: UInt64(value.st_ino),
            size: UInt64(value.st_size),
            ownerEUID: value.st_uid,
            mode: value.st_mode,
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }

    private static func sealToken(
        signingIdentifier: String,
        teamIdentifier: String,
        cdHash: String
    ) -> String {
        var hasher = SHA256()
        hasher.update(
            data: Data(
                "rimeai.voice-performance-tracer.outer-seal.v1\u{0}".utf8
            )
        )
        hasher.update(data: Data(signingIdentifier.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(teamIdentifier.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(cdHash.utf8))
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func isPathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.utf8.contains(0)
            && !value.contains("/")
            && value.utf8.count <= Int(NAME_MAX)
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

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x5A).contains(byte)
            || (0x61 ... 0x7A).contains(byte)
    }
}
