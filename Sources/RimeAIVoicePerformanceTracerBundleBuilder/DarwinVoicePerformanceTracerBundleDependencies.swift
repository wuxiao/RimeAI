import CryptoKit
import Darwin
import Foundation
import RimeAIVoiceArtifactCore
import Security

struct DarwinVoicePerformanceTracerBundleNonceGenerator:
    VoicePerformanceTracerBundleNonceGenerating
{
    func randomBytes(count: Int) throws -> Data {
        guard count > 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(
                kSecRandomDefault,
                count,
                bytes.baseAddress!
            )
        }
        guard status == errSecSuccess else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        return data
    }
}

struct DarwinVoicePerformanceTracerArtifactVerifier:
    VoicePerformanceTracerBundleArtifactVerifying
{
    private let verifier = VoiceASRArtifactVerifier()

    func verifyArtifact(
        at path: String
    ) throws -> VoicePerformanceTracerVerifiedArtifact {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard url.path == path else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        let verified = try verifier.verifyArtifact(at: url)
        guard verified.artifactDirectory.path == path,
              verified.manifest.capabilities.maximumHotwords >= 1,
              verified.manifest.capabilities.maximumHotwords <= 128
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        return VoicePerformanceTracerVerifiedArtifact(
            directory: path,
            adapterID: verified.manifest.adapter.id,
            artifactID: verified.manifest.artifactID.rawValue,
            contentSHA256: verified.contentSHA256,
            maximumHotwords: UInt64(
                verified.manifest.capabilities.maximumHotwords
            )
        )
    }
}

struct DarwinVoicePerformanceTracerBundleSigner:
    VoicePerformanceTracerBundleSigning
{
    func sign(_ invocation: VoicePerformanceTracerCodesignInvocation) throws {
        let arguments = invocation.arguments
        let expectedArgumentCount = 7
            + (invocation.hardenedRuntime ? 2 : 0)
            + (invocation.signingKeychainPath == nil ? 0 : 2)
        guard arguments.count == expectedArgumentCount,
              arguments.contains("--options")
                == invocation.hardenedRuntime,
              arguments.contains("runtime")
                == invocation.hardenedRuntime,
              !arguments.contains("--deep"),
              !arguments.contains("--entitlements"),
              arguments.last == invocation.path,
              invocation.path.first == "/",
              invocation.signingIdentifier.utf8.allSatisfy({ byte in
                  (byte >= 0x30 && byte <= 0x39)
                      || (byte >= 0x41 && byte <= 0x5A)
                      || (byte >= 0x61 && byte <= 0x7A)
                      || byte == 0x2D || byte == 0x2E
              })
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }
}

struct DarwinVoicePerformanceTracerBundleSigningInspector:
    VoicePerformanceTracerBundleSigningInspecting
{
    private static let hardenedRuntimeFlag: UInt32 = 0x0001_0000

    func inspectChildBundle(
        at appPath: String,
        executablePath: String,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String?
    ) throws -> VoicePerformanceTracerChildSigningEvidence {
        let code = try staticCode(at: appPath)
        let first = try signingInformation(code)
        guard first.signingIdentifier == expectedSigningIdentifier,
              expectedTeamIdentifier == nil
                || first.teamIdentifier == expectedTeamIdentifier,
              Self.isTeamIdentifier(first.teamIdentifier),
              first.executablePath == executablePath,
              first.cdHash.count == 40,
              first.codeDirectoryFlags & Self.hardenedRuntimeFlag != 0,
              first.hasTrustedTimestamp,
              !first.hasEntitlementBlob,
              !first.hasEntitlementDictionary
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        let requirement = try developerIDRequirement(
            signingIdentifier: expectedSigningIdentifier,
            teamIdentifier: first.teamIdentifier
        )
        let flags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
        )
        guard SecStaticCodeCheckValidity(code, flags, requirement)
                == errSecSuccess
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        let second = try signingInformation(code)
        guard second == first else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        return VoicePerformanceTracerChildSigningEvidence(
            appPath: appPath,
            executablePath: executablePath,
            executableSHA256: try stableSHA256(at: executablePath),
            signingIdentifier: second.signingIdentifier,
            teamIdentifier: second.teamIdentifier,
            cdHash: second.cdHash,
            developerIDValidated: true,
            strictValidation: true,
            allArchitecturesValidated: true,
            hardenedRuntime: true,
            trustedTimestamp: true,
            hasEntitlementBlob: false,
            hasEntitlementDictionary: false
        )
    }

    func inspectOuterBundle(
        at bundlePath: String,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> VoicePerformanceTracerOuterSigningEvidence {
        let code = try staticCode(at: bundlePath)
        let first = try signingInformation(code)
        guard first.signingIdentifier == expectedSigningIdentifier,
              first.teamIdentifier == expectedTeamIdentifier,
              first.hasTrustedTimestamp,
              !first.hasEntitlementBlob,
              !first.hasEntitlementDictionary
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        let requirement = try developerIDRequirement(
            signingIdentifier: expectedSigningIdentifier,
            teamIdentifier: expectedTeamIdentifier
        )
        let flags = SecCSFlags(
            rawValue: kSecCSStrictValidate
                | kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
        )
        guard SecStaticCodeCheckValidity(code, flags, requirement)
                == errSecSuccess,
              try signingInformation(code) == first
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        return VoicePerformanceTracerOuterSigningEvidence(
            bundlePath: bundlePath,
            signingIdentifier: first.signingIdentifier,
            teamIdentifier: first.teamIdentifier,
            developerIDValidated: true,
            strictValidation: true,
            allArchitecturesValidated: true,
            nestedCodeValidated: true,
            hasHardenedRuntimeFlag:
                first.codeDirectoryFlags & Self.hardenedRuntimeFlag != 0,
            trustedTimestamp: true,
            hasEntitlementBlob: false,
            hasEntitlementDictionary: false
        )
    }

    private struct SigningInformation: Equatable {
        let executablePath: String?
        let signingIdentifier: String
        let teamIdentifier: String
        let cdHash: String
        let codeDirectoryFlags: UInt32
        let hasTrustedTimestamp: Bool
        let hasEntitlementBlob: Bool
        let hasEntitlementDictionary: Bool
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
            throw VoicePerformanceTracerBundleFileSystemError.failed
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
              let unique = information[kSecCodeInfoUnique] as? Data,
              unique.count == 20,
              let flags = information[kSecCodeInfoFlags] as? NSNumber
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        return SigningInformation(
            executablePath: (
                information[kSecCodeInfoMainExecutable] as? URL
            )?.path,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            cdHash: unique.map { String(format: "%02x", $0) }.joined(),
            codeDirectoryFlags: flags.uint32Value,
            hasTrustedTimestamp:
                (information[kSecCodeInfoTimestamp] as? Date) != nil,
            hasEntitlementBlob:
                information.keys.contains(kSecCodeInfoEntitlements),
            hasEntitlementDictionary:
                information.keys.contains(kSecCodeInfoEntitlementsDict)
        )
    }

    private func developerIDRequirement(
        signingIdentifier: String,
        teamIdentifier: String
    ) throws -> SecRequirement {
        guard Self.isTeamIdentifier(teamIdentifier) else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
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
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        return requirement
    }

    private func stableSHA256(at path: String) throws -> String {
        let components = path.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard path.first == "/",
              components.count >= 2,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              })
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        let parentPath = "/" + components.dropLast().joined(separator: "/")
        let parent = try openAbsoluteDirectory(parentPath)
        defer { _ = close(parent) }
        let descriptor = openat(
            parent,
            String(components.last!),
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        defer { _ = close(descriptor) }
        let before = try Self.stableStat(descriptor)
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_nlink == 1,
              before.st_uid == geteuid(),
              before.st_mode & mode_t(0o777) == mode_t(0o700),
              Self.descriptorHasNoExtendedACL(descriptor),
              before.st_size >= 0
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        var hasher = SHA256()
        var remaining = before.st_size
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while remaining > 0 {
            let requested = min(Int64(buffer.count), remaining)
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, Int(requested))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            hasher.update(data: Data(buffer[..<count]))
            remaining -= Int64(count)
        }
        var extra: UInt8 = 0
        guard read(descriptor, &extra, 1) == 0,
              Self.sameStableFile(before, try Self.stableStat(descriptor))
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        return hasher.finalize().map { String(format: "%02x", $0) }
            .joined()
    }

    private static func stableStat(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        return status
    }

    private func openAbsoluteDirectory(_ path: String) throws -> Int32 {
        var current = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        if path == "/" { return current }
        do {
            for component in path.dropFirst().split(
                separator: "/",
                omittingEmptySubsequences: false
            ) {
                guard !component.isEmpty,
                      component != ".", component != ".."
                else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
                let next = openat(
                    current,
                    String(component),
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard next >= 0 else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
                _ = close(current)
                current = next
            }
            return current
        } catch {
            _ = close(current)
            throw error
        }
    }

    private static func descriptorHasNoExtendedACL(
        _ descriptor: Int32
    ) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT
        }
        acl_free(UnsafeMutableRawPointer(acl))
        return false
    }

    private static func sameStableFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func isTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A)
        }
    }
}

struct DarwinVoicePerformanceTracerBundleFileSystem:
    VoicePerformanceTracerBundleFileSystem
{
    private let beforeFinalUnlink: @Sendable (String) -> Void
    private let afterExclusiveRename: @Sendable (String) -> Void

    init(
        beforeFinalUnlink: @escaping @Sendable (String) -> Void = { _ in },
        afterExclusiveRename: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.beforeFinalUnlink = beforeFinalUnlink
        self.afterExclusiveRename = afterExclusiveRename
    }

    private static let executablePaths: Set<String> = [
        "Contents/Helpers/RimeAIVoicePerformanceCollector.app/Contents/MacOS/rimeai-voice-performance-tracer",
        "Contents/Helpers/RimeAIVoicePerformanceDriver.app/Contents/MacOS/rimeai-voice-performance-driver",
        "Contents/Helpers/RimeAIVoicePerformanceHelper.app/Contents/MacOS/rimeai-voice-performance-helper",
    ]
    private static let baseRegularPaths: Set<String> = [
        "Contents/Info.plist",
        "Contents/Helpers/RimeAIVoicePerformanceCollector.app/Contents/Info.plist",
        "Contents/Helpers/RimeAIVoicePerformanceDriver.app/Contents/Info.plist",
        "Contents/Helpers/RimeAIVoicePerformanceHelper.app/Contents/Info.plist",
        "Contents/Helpers/RimeAIVoicePerformanceHelper.app/Contents/Resources/VoiceReleasePolicy.plist",
        "Contents/Resources/VoicePerformanceDriverPolicy.json",
        "Contents/Resources/VoicePerformanceMeasurementPolicy.json",
        "Contents/Resources/THIRD_PARTY_NOTICES.md",
        "Contents/Resources/ThirdPartyLicenses/sherpa-onnx-Apache-2.0.txt",
        "Contents/Resources/ThirdPartyLicenses/onnxruntime-MIT.txt",
        "Contents/Resources/ThirdPartyLicenses/onnxruntime-ThirdPartyNotices-1.27.1.txt",
        "Contents/Helpers/RimeAIVoicePerformanceCollector.app/Contents/_CodeSignature/CodeResources",
        "Contents/Helpers/RimeAIVoicePerformanceDriver.app/Contents/_CodeSignature/CodeResources",
        "Contents/Helpers/RimeAIVoicePerformanceHelper.app/Contents/_CodeSignature/CodeResources",
    ]
    /// Resource-only bundles use detached signature sidecars in addition to
    /// CodeResources. These are exact codesign outputs, not optional payload.
    private static let outerSignaturePaths: Set<String> = [
        "Contents/_CodeSignature/CodeDirectory",
        "Contents/_CodeSignature/CodeRequirements",
        "Contents/_CodeSignature/CodeResources",
        "Contents/_CodeSignature/CodeSignature",
    ]
    private static let baseDirectories: Set<String> = [
        "Contents",
        "Contents/Helpers",
        "Contents/Helpers/RimeAIVoicePerformanceCollector.app",
        "Contents/Helpers/RimeAIVoicePerformanceCollector.app/Contents",
        "Contents/Helpers/RimeAIVoicePerformanceCollector.app/Contents/MacOS",
        "Contents/Helpers/RimeAIVoicePerformanceCollector.app/Contents/Resources",
        "Contents/Helpers/RimeAIVoicePerformanceCollector.app/Contents/_CodeSignature",
        "Contents/Helpers/RimeAIVoicePerformanceDriver.app",
        "Contents/Helpers/RimeAIVoicePerformanceDriver.app/Contents",
        "Contents/Helpers/RimeAIVoicePerformanceDriver.app/Contents/MacOS",
        "Contents/Helpers/RimeAIVoicePerformanceDriver.app/Contents/Resources",
        "Contents/Helpers/RimeAIVoicePerformanceDriver.app/Contents/_CodeSignature",
        "Contents/Helpers/RimeAIVoicePerformanceHelper.app",
        "Contents/Helpers/RimeAIVoicePerformanceHelper.app/Contents",
        "Contents/Helpers/RimeAIVoicePerformanceHelper.app/Contents/MacOS",
        "Contents/Helpers/RimeAIVoicePerformanceHelper.app/Contents/Resources",
        "Contents/Helpers/RimeAIVoicePerformanceHelper.app/Contents/_CodeSignature",
        "Contents/Resources",
        "Contents/Resources/ThirdPartyLicenses",
    ]
    private static let outerSignatureDirectory = "Contents/_CodeSignature"

    func validateEnvironment(
        for request: VoicePerformanceTracerBundleBuildRequest
    ) throws {
        for directory in [
            request.repositoryRootPath,
            request.releaseBinDirectoryPath,
            request.verifiedArtifactDirectoryPath,
        ] {
            let descriptor = try openAbsoluteDirectory(directory)
            defer { _ = close(descriptor) }
            let status = try stableStat(descriptor)
            guard status.st_uid == geteuid(),
                  status.st_mode & mode_t(0o022) == 0,
                  descriptorHasNoExtendedACL(descriptor)
            else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
        }
        let finalParent = parentPath(request.finalBundlePath)
        try validateSecureAncestors(finalParent)
        let outputParent = try openAbsoluteDirectory(finalParent)
        defer { _ = close(outputParent) }
        let outputStatus = try stableStat(outputParent)
        guard outputStatus.st_uid == geteuid(),
              outputStatus.st_mode & mode_t(0o022) == 0,
              descriptorHasNoExtendedACL(outputParent)
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }

        let socketParentPath = parentPath(request.controlSocketPath)
        let socketParent = try openAbsoluteDirectory(socketParentPath)
        defer { _ = close(socketParent) }
        let socketStatus = try stableStat(socketParent)
        guard socketStatus.st_uid == geteuid(),
              socketStatus.st_mode & mode_t(0o777) == mode_t(0o700),
              descriptorHasNoExtendedACL(socketParent)
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        if let keychain = request.signingKeychainPath {
            let opened = try openStableRegularFile(keychain)
            _ = close(opened.descriptor)
        }
    }

    func pathExists(_ path: String) throws -> Bool {
        let (parent, name) = try openAbsoluteParent(of: path)
        defer { _ = close(parent) }
        var status = stat()
        if fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            return true
        }
        guard errno == ENOENT else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        return false
    }

    func createPrivateStagingDirectory(_ path: String) throws {
        let (parent, name) = try openAbsoluteParent(of: path)
        defer { _ = close(parent) }
        guard mkdirat(parent, name, mode_t(0o700)) == 0 else {
            if errno == EEXIST {
                throw VoicePerformanceTracerBundleFileSystemError.outputExists
            }
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            _ = unlinkat(parent, name, AT_REMOVEDIR)
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        defer { _ = close(descriptor) }
        guard fchmod(descriptor, mode_t(0o700)) == 0,
              try validatePrivateDirectory(descriptor)
        else {
            _ = unlinkat(parent, name, AT_REMOVEDIR)
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    func createPrivateDirectory(_ path: String) throws {
        let (parent, name) = try openAbsoluteParent(of: path)
        defer { _ = close(parent) }
        guard mkdirat(parent, name, mode_t(0o700)) == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        defer { _ = close(descriptor) }
        guard fchmod(descriptor, mode_t(0o700)) == 0,
              try validatePrivateDirectory(descriptor)
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    func readStableRegularFile(
        _ path: String,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes > 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        let opened = try openStableRegularFile(path)
        defer { _ = close(opened.descriptor) }
        guard opened.status.st_size >= 0,
              opened.status.st_size <= Int64(maximumBytes)
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        var result = Data()
        result.reserveCapacity(Int(opened.status.st_size))
        var remaining = opened.status.st_size
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while remaining > 0 {
            let requested = min(Int64(buffer.count), remaining)
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(opened.descriptor, bytes.baseAddress, Int(requested))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            result.append(contentsOf: buffer[..<count])
            remaining -= Int64(count)
        }
        var extra: UInt8 = 0
        guard read(opened.descriptor, &extra, 1) == 0,
              Self.sameStableFile(
                  opened.status,
                  try stableStat(opened.descriptor)
              )
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        return result
    }

    func writeNewRegularFile(_ data: Data, to path: String) throws {
        let (parent, name) = try openAbsoluteParent(of: path)
        defer { _ = close(parent) }
        let destination = openat(
            parent,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard destination >= 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        defer { _ = close(destination) }
        try writeAll(data, to: destination)
        guard fchmod(destination, mode_t(0o600)) == 0,
              fsync(destination) == 0,
              try validatePrivateRegularFile(
                  destination,
                  executable: false
              )
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    func copyStableRegularFile(
        from sourcePath: String,
        to destinationPath: String,
        executable: Bool
    ) throws {
        let source = try openStableRegularFile(sourcePath)
        defer { _ = close(source.descriptor) }
        guard source.status.st_size >= 0,
              source.status.st_size <= 1_073_741_824
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        let (parent, name) = try openAbsoluteParent(of: destinationPath)
        defer { _ = close(parent) }
        let destination = openat(
            parent,
            name,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            executable ? mode_t(0o700) : mode_t(0o600)
        )
        guard destination >= 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        defer { _ = close(destination) }
        var remaining = source.status.st_size
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while remaining > 0 {
            let requested = min(Int64(buffer.count), remaining)
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(source.descriptor, bytes.baseAddress, Int(requested))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            try writeAll(buffer[0 ..< count], to: destination)
            remaining -= Int64(count)
        }
        var extra: UInt8 = 0
        guard read(source.descriptor, &extra, 1) == 0,
              Self.sameStableFile(
                  source.status,
                  try stableStat(source.descriptor)
              ),
              fchmod(
                  destination,
                  executable ? mode_t(0o700) : mode_t(0o600)
              ) == 0,
              fsync(destination) == 0,
              try validatePrivateRegularFile(
                  destination,
                  executable: executable
              )
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    func normalizeAndVerifyExactTree(
        at bundlePath: String,
        phase: VoicePerformanceTracerBundleTreePhase
    ) throws {
        let descriptor = try openAbsoluteDirectory(bundlePath)
        defer { _ = close(descriptor) }
        try normalizeDirectory(descriptor)
        let snapshot = try inspectTree(
            descriptor: descriptor,
            relativePath: "",
            normalizeModes: true
        )
        try requireExactTree(snapshot, phase: phase)
    }

    func reverifyExactTreeWithoutMutation(
        at bundlePath: String,
        phase: VoicePerformanceTracerBundleTreePhase
    ) throws {
        let descriptor = try openAbsoluteDirectory(bundlePath)
        defer { _ = close(descriptor) }
        let snapshot = try inspectTree(
            descriptor: descriptor,
            relativePath: "",
            normalizeModes: false
        )
        try requireExactTree(snapshot, phase: phase)
    }

    func flushTreeBottomUpAndReverify(at bundlePath: String) throws {
        let descriptor = try openAbsoluteDirectory(bundlePath)
        defer { _ = close(descriptor) }
        let before = try inspectTree(
            descriptor: descriptor,
            relativePath: "",
            normalizeModes: false
        )
        try requireExactTree(before, phase: .afterOuterSignature)
        try fsyncTreeBottomUp(descriptor: descriptor, relativePath: "")
        let after = try inspectTree(
            descriptor: descriptor,
            relativePath: "",
            normalizeModes: false
        )
        try requireExactTree(after, phase: .afterOuterSignature)
        guard before == after else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    func installExclusive(
        stagingPath: String,
        finalPath: String
    ) throws -> VoicePerformanceTracerBundleInstallationToken {
        let stagingParentPath = parentPath(stagingPath)
        guard stagingParentPath == parentPath(finalPath) else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        let parent = try openAbsoluteDirectory(stagingParentPath)
        defer { _ = close(parent) }
        let stagingName = lastComponent(stagingPath)
        let finalName = lastComponent(finalPath)
        let staging = openat(
            parent,
            stagingName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard staging >= 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        defer { _ = close(staging) }
        let before = try stableStat(staging)
        let token = VoicePerformanceTracerBundleInstallationToken(
            device: UInt64(before.st_dev),
            inode: UInt64(before.st_ino)
        )
        guard renameatx_np(
            parent,
            stagingName,
            parent,
            finalName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST {
                throw VoicePerformanceTracerBundleFileSystemError.outputExists
            }
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        afterExclusiveRename(finalPath)
        var installed = stat()
        guard fstatat(
            parent,
            finalName,
            &installed,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              installed.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              installed.st_dev == before.st_dev,
              installed.st_ino == before.st_ino
        else {
            throw VoicePerformanceTracerBundleFileSystemError
                .renameCommitted(token)
        }
        return token
    }

    func syncParentDirectory(of path: String) throws {
        let descriptor = try openAbsoluteDirectory(parentPath(path))
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    func rollbackInstalledBundle(
        at finalPath: String,
        token: VoicePerformanceTracerBundleInstallationToken
    ) throws {
        let (parent, name) = try openAbsoluteParent(of: finalPath)
        defer { _ = close(parent) }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        defer { _ = close(descriptor) }
        let status = try stableStat(descriptor)
        guard UInt64(status.st_dev) == token.device,
              UInt64(status.st_ino) == token.inode
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        try removeContents(of: descriptor)
        beforeFinalUnlink(finalPath)
        var finalStatus = stat()
        guard fstatat(
            parent,
            name,
            &finalStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              UInt64(finalStatus.st_dev) == token.device,
              UInt64(finalStatus.st_ino) == token.inode,
              finalStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    func removeStagingTreeIfPresent(_ path: String) throws {
        let (parent, name) = try openAbsoluteParent(of: path)
        defer { _ = close(parent) }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0 {
            guard errno == ENOENT else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            return
        }
        defer { _ = close(descriptor) }
        let status = try stableStat(descriptor)
        guard status.st_uid == geteuid(),
              status.st_mode & mode_t(0o777) == mode_t(0o700)
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        try removeContents(of: descriptor)
        beforeFinalUnlink(path)
        var finalStatus = stat()
        guard fstatat(
            parent,
            name,
            &finalStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              finalStatus.st_dev == status.st_dev,
              finalStatus.st_ino == status.st_ino,
              finalStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    private struct OpenedRegularFile {
        let descriptor: Int32
        let status: stat
    }

    private struct TreeSnapshot: Equatable {
        var directories: Set<String> = []
        var regularFiles: Set<String> = []
        var tokens: [String: FileToken] = [:]
    }

    private struct FileToken: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let mode: UInt16
    }

    private func requireExactTree(
        _ snapshot: TreeSnapshot,
        phase: VoicePerformanceTracerBundleTreePhase
    ) throws {
        var expectedDirectories = Self.baseDirectories
        var expectedRegularFiles = Self.baseRegularPaths
            .union(Self.executablePaths)
        if phase == .afterOuterSignature {
            expectedDirectories.insert(Self.outerSignatureDirectory)
            expectedRegularFiles.formUnion(Self.outerSignaturePaths)
        }
        guard snapshot.directories == expectedDirectories,
              snapshot.regularFiles == expectedRegularFiles
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    private func inspectTree(
        descriptor: Int32,
        relativePath: String,
        normalizeModes: Bool
    ) throws -> TreeSnapshot {
        var result = TreeSnapshot()
        let iteratorDescriptor = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard iteratorDescriptor >= 0,
              let directory = fdopendir(iteratorDescriptor)
        else {
            if iteratorDescriptor >= 0 { _ = close(iteratorDescriptor) }
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        defer { closedir(directory) }
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name, name != ".", name != "..",
                  !name.isEmpty,
                  name.utf8.count <= 255
            else {
                if name == "." || name == ".." { continue }
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            var status = stat()
            guard fstatat(
                descriptor,
                name,
                &status,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            let path = relativePath.isEmpty
                ? name : relativePath + "/" + name
            switch status.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
                defer { _ = close(child) }
                if normalizeModes { try normalizeDirectory(child) }
                guard try validatePrivateDirectory(child) else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
                result.directories.insert(path)
                let nested = try inspectTree(
                    descriptor: child,
                    relativePath: path,
                    normalizeModes: normalizeModes
                )
                result.directories.formUnion(nested.directories)
                result.regularFiles.formUnion(nested.regularFiles)
                guard Set(result.tokens.keys).isDisjoint(
                    with: nested.tokens.keys
                ) else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
                result.tokens.merge(nested.tokens) { existing, _ in existing }
            case mode_t(S_IFREG):
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
                defer { _ = close(child) }
                let executable = Self.executablePaths.contains(path)
                if normalizeModes {
                    guard fchmod(
                        child,
                        executable ? mode_t(0o700) : mode_t(0o600)
                    ) == 0 else {
                        throw VoicePerformanceTracerBundleFileSystemError.failed
                    }
                }
                guard try validatePrivateRegularFile(
                    child,
                    executable: executable
                ) else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
                let finalStatus = try stableStat(child)
                result.regularFiles.insert(path)
                result.tokens[path] = FileToken(
                    device: UInt64(finalStatus.st_dev),
                    inode: UInt64(finalStatus.st_ino),
                    size: UInt64(finalStatus.st_size),
                    mode: UInt16(finalStatus.st_mode & mode_t(0o777))
                )
            default:
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            errno = 0
        }
        guard errno == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        return result
    }

    private func fsyncTreeBottomUp(
        descriptor: Int32,
        relativePath: String
    ) throws {
        let iteratorDescriptor = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard iteratorDescriptor >= 0,
              let directory = fdopendir(iteratorDescriptor)
        else {
            if iteratorDescriptor >= 0 { _ = close(iteratorDescriptor) }
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        defer { closedir(directory) }
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            if name == "." || name == ".." { continue }
            var status = stat()
            guard fstatat(
                descriptor,
                name,
                &status,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            let flags: Int32
            if status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            } else if status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            } else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            let child = openat(descriptor, name, flags)
            guard child >= 0 else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            defer { _ = close(child) }
            if flags & O_DIRECTORY != 0 {
                try fsyncTreeBottomUp(
                    descriptor: child,
                    relativePath: relativePath.isEmpty
                        ? name : relativePath + "/" + name
                )
            }
            guard fsync(child) == 0 else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            errno = 0
        }
        guard errno == 0, fsync(descriptor) == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    private func removeContents(of descriptor: Int32) throws {
        let iteratorDescriptor = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard iteratorDescriptor >= 0,
              let directory = fdopendir(iteratorDescriptor)
        else {
            if iteratorDescriptor >= 0 { _ = close(iteratorDescriptor) }
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        defer { closedir(directory) }
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            if name == "." || name == ".." { continue }
            var status = stat()
            guard fstatat(
                descriptor,
                name,
                &status,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            if status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                let child = openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
                do {
                    try removeContents(of: child)
                    _ = close(child)
                } catch {
                    _ = close(child)
                    throw error
                }
                guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
            } else {
                guard unlinkat(descriptor, name, 0) == 0 else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
            }
            errno = 0
        }
        guard errno == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    private func openStableRegularFile(
        _ path: String
    ) throws -> OpenedRegularFile {
        let (parent, name) = try openAbsoluteParent(of: path)
        defer { _ = close(parent) }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        let status: stat
        do {
            status = try stableStat(descriptor)
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  status.st_nlink == 1,
                  status.st_uid == geteuid(),
                  status.st_mode & mode_t(0o022) == 0,
                  descriptorHasNoExtendedACL(descriptor)
            else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
        } catch {
            _ = close(descriptor)
            throw error
        }
        return OpenedRegularFile(descriptor: descriptor, status: status)
    }

    private func openAbsoluteParent(
        of path: String
    ) throws -> (Int32, String) {
        let parent = parentPath(path)
        return (try openAbsoluteDirectory(parent), lastComponent(path))
    }

    private func openAbsoluteDirectory(_ path: String) throws -> Int32 {
        guard path.first == "/", path.last != "/" || path == "/" else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        var current = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        if path == "/" { return current }
        do {
            for component in path.dropFirst().split(
                separator: "/",
                omittingEmptySubsequences: false
            ) {
                guard !component.isEmpty,
                      component != ".", component != ".."
                else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
                let next = openat(
                    current,
                    String(component),
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard next >= 0 else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
                _ = close(current)
                current = next
            }
            return current
        } catch {
            _ = close(current)
            throw error
        }
    }

    private func validateSecureAncestors(_ path: String) throws {
        var current = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        defer { _ = close(current) }
        let rootStatus = try stableStat(current)
        guard rootStatus.st_uid == 0,
              descriptorHasNoExtendedACL(current)
        else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        for component in path.dropFirst().split(separator: "/") {
            let next = openat(
                current,
                String(component),
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
            _ = close(current)
            current = next
            let status = try stableStat(current)
            let writable = status.st_mode & mode_t(0o022) != 0
            let rootSticky = status.st_uid == 0
                && status.st_mode & mode_t(S_ISVTX) != 0
            guard (status.st_uid == 0 || status.st_uid == geteuid()),
                  (!writable || rootSticky),
                  descriptorHasNoExtendedACL(current)
            else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
        }
    }

    private func validatePrivateDirectory(_ descriptor: Int32) throws -> Bool {
        let status = try stableStat(descriptor)
        return status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && status.st_uid == geteuid()
            && status.st_mode & mode_t(0o777) == mode_t(0o700)
            && descriptorHasNoExtendedACL(descriptor)
    }

    private func validatePrivateRegularFile(
        _ descriptor: Int32,
        executable: Bool
    ) throws -> Bool {
        let status = try stableStat(descriptor)
        let baseValid = status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && status.st_uid == geteuid()
            && status.st_nlink == 1
            && status.st_mode & mode_t(0o777)
                == (executable ? mode_t(0o700) : mode_t(0o600))
            && descriptorHasNoExtendedACL(descriptor)
        guard baseValid else { return false }
        if !executable { return true }
        return try isArm64MachOExecutable(descriptor, status)
    }

    private func isArm64MachOExecutable(
        _ descriptor: Int32,
        _ status: stat
    ) throws -> Bool {
        guard status.st_size >= Int64(MemoryLayout<mach_header_64>.size) else {
            return false
        }
        var header = mach_header_64()
        let count = withUnsafeMutableBytes(of: &header) { bytes in
            pread(
                descriptor,
                bytes.baseAddress,
                bytes.count,
                0
            )
        }
        guard count == MemoryLayout<mach_header_64>.size,
              header.magic == MH_MAGIC_64,
              header.cputype == CPU_TYPE_ARM64,
              header.filetype == MH_EXECUTE,
              UInt64(header.sizeofcmds)
                <= UInt64(status.st_size)
                    - UInt64(MemoryLayout<mach_header_64>.size)
        else {
            return false
        }
        return true
    }

    private func normalizeDirectory(_ descriptor: Int32) throws {
        guard fchmod(descriptor, mode_t(0o700)) == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    private func writeAll<Bytes: Collection>(
        _ bytes: Bytes,
        to descriptor: Int32
    ) throws where Bytes.Element == UInt8 {
        let data = Data(bytes)
        try writeAll(data, to: descriptor)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: written),
                    bytes.count - written
                )
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
                written += count
            }
        }
    }

    private func stableStat(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        return status
    }

    private static func sameStableFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func parentPath(_ path: String) -> String {
        let index = path.lastIndex(of: "/")!
        return index == path.startIndex ? "/" : String(path[..<index])
    }

    private func lastComponent(_ path: String) -> String {
        String(path[path.index(after: path.lastIndex(of: "/")!)...])
    }

    private func descriptorHasNoExtendedACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT
        }
        acl_free(UnsafeMutableRawPointer(acl))
        return false
    }
}
