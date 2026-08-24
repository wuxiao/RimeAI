import CryptoKit
import Darwin
import Foundation
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceTracerProcessDarwin
import Testing
@testable import RimeAIVoicePerformanceTracerBundleBuilder

@Suite("Darwin voice tracer bundle builder boundaries", .serialized)
struct DarwinVoicePerformanceTracerBundleDependenciesTests {
    @Test("only a thin arm64 Mach-O executable is copied as executable")
    func executableCopyRejectsScriptFatAndX86() throws {
        let fixture = try SecureBuilderFixture()
        defer { fixture.remove() }
        let fileSystem = DarwinVoicePerformanceTracerBundleFileSystem()
        let source = try fixture.directory("sources")
        let destination = try fixture.directory("destinations")

        let accepted = source + "/arm64"
        try fixture.file(accepted, data: Self.machO(cpuType: CPU_TYPE_ARM64))
        try fileSystem.copyStableRegularFile(
            from: accepted,
            to: destination + "/arm64",
            executable: true
        )
        #expect(
            try Data(contentsOf: URL(fileURLWithPath: destination + "/arm64"))
                == Self.machO(cpuType: CPU_TYPE_ARM64)
        )

        let rejected: [(String, Data)] = [
            (
                "script",
                Data("#!/bin/sh\nexit 0\n".utf8)
                    + Data(repeating: 0, count: 64)
            ),
            ("fat", Self.fatMachO()),
            ("x86", Self.machO(cpuType: CPU_TYPE_X86_64)),
        ]
        for (name, data) in rejected {
            let sourcePath = source + "/" + name
            try fixture.file(sourcePath, data: data)
            #expect(throws: VoicePerformanceTracerBundleFileSystemError.failed) {
                try fileSystem.copyStableRegularFile(
                    from: sourcePath,
                    to: destination + "/" + name,
                    executable: true
                )
            }
        }
    }

    @Test("source output socket and keychain authorities reject writable modes")
    func authorityPathsRejectWritableModes() throws {
        let fixture = try SecureBuilderFixture()
        defer { fixture.remove() }
        let repository = try fixture.directory("repository")
        let release = try fixture.directory("release")
        let artifact = try fixture.directory("artifact")
        let output = try fixture.directory("output")
        let control = try fixture.directory("control")
        let keychain = fixture.root + "/signing.keychain-db"
        try fixture.file(keychain, data: Data("keychain".utf8))
        let request = Self.request(
            repository: repository,
            release: release,
            artifact: artifact,
            output: output,
            control: control,
            keychain: keychain
        )
        let fileSystem = DarwinVoicePerformanceTracerBundleFileSystem()

        try fileSystem.validateEnvironment(for: request)

        for path in [repository, release, artifact, output] {
            #expect(chmod(path, mode_t(0o720)) == 0)
            #expect(throws: VoicePerformanceTracerBundleFileSystemError.failed) {
                try fileSystem.validateEnvironment(for: request)
            }
            #expect(chmod(path, mode_t(0o700)) == 0)
        }
        #expect(chmod(control, mode_t(0o750)) == 0)
        #expect(throws: VoicePerformanceTracerBundleFileSystemError.failed) {
            try fileSystem.validateEnvironment(for: request)
        }
        #expect(chmod(control, mode_t(0o700)) == 0)
        #expect(chmod(keychain, mode_t(0o620)) == 0)
        #expect(throws: VoicePerformanceTracerBundleFileSystemError.failed) {
            try fileSystem.validateEnvironment(for: request)
        }
    }

    @Test("exclusive rename reports a committed token after postcheck drift")
    func renamePostcheckUsesCommittedError() throws {
        let fixture = try SecureBuilderFixture()
        defer { fixture.remove() }
        let parent = try fixture.directory("install")
        let staging = parent + "/.staging"
        let final = parent + "/RimeAIVoicePerformanceTracer.bundle"
        let moved = parent + "/committed-generation"
        let marker = final + "/replacement-marker"
        let setup = DarwinVoicePerformanceTracerBundleFileSystem()
        try setup.createPrivateStagingDirectory(staging)
        var status = stat()
        #expect(lstat(staging, &status) == 0)
        let expected = VoicePerformanceTracerBundleInstallationToken(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
        let swapping = DarwinVoicePerformanceTracerBundleFileSystem(
            afterExclusiveRename: { path in
                guard path == final else { return }
                _ = rename(path, moved)
                _ = mkdir(path, mode_t(0o700))
                FileManager.default.createFile(
                    atPath: marker,
                    contents: Data("replacement".utf8)
                )
            }
        )

        #expect(
            throws: VoicePerformanceTracerBundleFileSystemError
                .renameCommitted(expected)
        ) {
            try swapping.installExclusive(
                stagingPath: staging,
                finalPath: final
            )
        }
        #expect(FileManager.default.fileExists(atPath: moved))
        #expect(FileManager.default.fileExists(atPath: marker))
    }

    @Test("rollback refuses a same-UID path replacement before unlink")
    func rollbackRechecksPathIdentity() throws {
        let fixture = try SecureBuilderFixture()
        defer { fixture.remove() }
        let parent = try fixture.directory("rollback-parent")
        let final = parent + "/RimeAIVoicePerformanceTracer.bundle"
        let moved = parent + "/original-generation"
        let marker = final + "/replacement-marker"
        let setup = DarwinVoicePerformanceTracerBundleFileSystem()
        try setup.createPrivateStagingDirectory(final)
        try setup.writeNewRegularFile(
            Data("owned".utf8),
            to: final + "/owned"
        )
        var status = stat()
        #expect(lstat(final, &status) == 0)
        let token = VoicePerformanceTracerBundleInstallationToken(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
        let swapping = DarwinVoicePerformanceTracerBundleFileSystem(
            beforeFinalUnlink: { path in
                guard path == final else { return }
                _ = rename(path, moved)
                _ = mkdir(path, mode_t(0o700))
                FileManager.default.createFile(
                    atPath: marker,
                    contents: Data("replacement".utf8)
                )
            }
        )

        #expect(throws: VoicePerformanceTracerBundleFileSystemError.failed) {
            try swapping.rollbackInstalledBundle(at: final, token: token)
        }
        #expect(FileManager.default.fileExists(atPath: marker))
        #expect(FileManager.default.fileExists(atPath: moved))
    }

    @Test("staging cleanup refuses a same-UID path replacement before unlink")
    func stagingCleanupRechecksPathIdentity() throws {
        let fixture = try SecureBuilderFixture()
        defer { fixture.remove() }
        let parent = try fixture.directory("cleanup-parent")
        let staging = parent + "/.staging"
        let moved = parent + "/original-staging"
        let marker = staging + "/replacement-marker"
        let setup = DarwinVoicePerformanceTracerBundleFileSystem()
        try setup.createPrivateStagingDirectory(staging)
        try setup.writeNewRegularFile(
            Data("owned".utf8),
            to: staging + "/owned"
        )
        let swapping = DarwinVoicePerformanceTracerBundleFileSystem(
            beforeFinalUnlink: { path in
                guard path == staging else { return }
                _ = rename(path, moved)
                _ = mkdir(path, mode_t(0o700))
                FileManager.default.createFile(
                    atPath: marker,
                    contents: Data("replacement".utf8)
                )
            }
        )

        #expect(throws: VoicePerformanceTracerBundleFileSystemError.failed) {
            try swapping.removeStagingTreeIfPresent(staging)
        }
        #expect(FileManager.default.fileExists(atPath: marker))
        #expect(FileManager.default.fileExists(atPath: moved))
    }

    @Test("real filesystem vertical slice installs the exact private tree")
    func realFilesWithFakeSignerBuildExactTree() throws {
        let fixture = try SecureBuilderFixture()
        defer { fixture.remove() }
        let release = try fixture.directory("release-bin")
        let artifact = try fixture.directory("verified-artifact")
        let output = try fixture.directory("output")
        let control = try fixture.directory("control")
        for executable in [
            "rimeai-voice-performance-tracer",
            "rimeai-voice-performance-driver",
            "rimeai-voice-performance-helper",
        ] {
            try fixture.file(
                release + "/" + executable,
                data: Self.machO(cpuType: CPU_TYPE_ARM64)
            )
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().path
        let request = Self.request(
            repository: repository,
            release: release,
            artifact: artifact,
            output: output,
            control: control,
            keychain: nil
        )
        let signer = RealTreeFakeSigner()
        let builder = VoicePerformanceTracerBundleBuilder(
            fileSystem: DarwinVoicePerformanceTracerBundleFileSystem(),
            signer: signer,
            signingInspector: RealFileSigningInspector(),
            nonceGenerator: DarwinTestNonceGenerator(),
            artifactVerifier: DarwinTestArtifactVerifier()
        )

        let receipt = try builder.build(request)

        #expect(receipt.finalBundlePath == request.finalBundlePath)
        #expect(signer.invocations.count == 4)
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: output
        )
        #expect(entries == [VoicePerformanceTracerBundleLayout.outerBundleName])
        try Self.expectPrivateExactModes(at: request.finalBundlePath)
        let measurementPath = request.finalBundlePath + "/"
            + VoicePerformanceTracerBundleLayout
                .measurementPolicyResourceRelativePath
        let measurementData = try Data(
            contentsOf: URL(fileURLWithPath: measurementPath)
        )
        let measurement = try VoicePerformanceMeasurementPolicy
            .decodeCanonical(measurementData)
        #expect(
            measurement.collector.expectedExecutablePath
                == request.finalBundlePath
                    + VoicePerformanceTracerBundleLayout
                        .collectorExecutableSuffix
        )
        #expect(!String(decoding: measurementData, as: UTF8.self)
            .contains(".staging-"))
    }

    private static func request(
        repository: String,
        release: String,
        artifact: String,
        output: String,
        control: String,
        keychain: String?
    ) -> VoicePerformanceTracerBundleBuildRequest {
        .init(
            finalBundlePath: output + "/"
                + VoicePerformanceTracerBundleLayout.outerBundleName,
            releaseBinDirectoryPath: release,
            repositoryRootPath: repository,
            verifiedArtifactDirectoryPath: artifact,
            controlSocketPath: control + "/control.sock",
            coldTrials: 4,
            marketingVersion: "1.0.0",
            buildNumber: "1",
            signingIdentity:
                "Developer ID Application: Fake Test (ABCDEFGHIJ)",
            signingKeychainPath: keychain
        )
    }

    private static func machO(cpuType: cpu_type_t) -> Data {
        var header = mach_header_64(
            magic: MH_MAGIC_64,
            cputype: cpuType,
            cpusubtype: CPU_SUBTYPE_ARM64_ALL,
            filetype: UInt32(MH_EXECUTE),
            ncmds: 0,
            sizeofcmds: 0,
            flags: 0,
            reserved: 0
        )
        return Data(bytes: &header, count: MemoryLayout.size(ofValue: header))
    }

    private static func fatMachO() -> Data {
        var result = Data([0xCA, 0xFE, 0xBA, 0xBE])
        result.append(Data(repeating: 0, count: 60))
        return result
    }

    private static func expectPrivateExactModes(at root: String) throws {
        var rootStatus = stat()
        #expect(lstat(root, &rootStatus) == 0)
        #expect(rootStatus.st_mode & mode_t(0o777) == mode_t(0o700))
        let executableSuffixes = [
            VoicePerformanceTracerBundleLayout.collectorExecutableSuffix,
            VoicePerformanceTracerBundleLayout.driverExecutableSuffix,
            VoicePerformanceTracerBundleLayout.helperExecutableSuffix,
        ]
        let enumerator = try #require(
            FileManager.default.enumerator(atPath: root)
        )
        var count = 0
        while let relativePath = enumerator.nextObject() as? String {
            count += 1
            let path = root + "/" + relativePath
            var status = stat()
            #expect(lstat(path, &status) == 0)
            let kind = status.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFDIR) {
                #expect(status.st_mode & mode_t(0o777) == mode_t(0o700))
            } else {
                #expect(kind == mode_t(S_IFREG))
                #expect(status.st_nlink == 1)
                let isExecutable = executableSuffixes.contains {
                    path.hasSuffix($0)
                }
                #expect(
                    status.st_mode & mode_t(0o777)
                        == (isExecutable ? mode_t(0o700) : mode_t(0o600))
                )
            }
        }
        #expect(count == 41)
    }
}

private final class SecureBuilderFixture {
    let root: String
    private var removed = false

    init() throws {
        var template = Array(
            "/private/tmp/rimeai-bundle-builder-tests.XXXXXX".utf8CString
        )
        let created = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!)
        }
        guard let created else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        root = String(cString: created)
        guard chmod(root, mode_t(0o700)) == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    deinit {
        if !removed { try? FileManager.default.removeItem(atPath: root) }
    }

    func directory(_ relativePath: String) throws -> String {
        let path = root + "/" + relativePath
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: false
        )
        guard chmod(path, mode_t(0o700)) == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        return path
    }

    func file(_ path: String, data: Data) throws {
        try data.write(
            to: URL(fileURLWithPath: path),
            options: .withoutOverwriting
        )
        guard chmod(path, mode_t(0o600)) == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
    }

    func remove() {
        guard !removed else { return }
        try? FileManager.default.removeItem(atPath: root)
        removed = true
    }
}

private final class RealTreeFakeSigner:
    VoicePerformanceTracerBundleSigning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [VoicePerformanceTracerCodesignInvocation] = []

    var invocations: [VoicePerformanceTracerCodesignInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func sign(_ invocation: VoicePerformanceTracerCodesignInvocation) throws {
        lock.lock()
        storage.append(invocation)
        lock.unlock()
        let resourcesDirectory = invocation.path + "/Contents/Resources"
        if !FileManager.default.fileExists(atPath: resourcesDirectory) {
            try FileManager.default.createDirectory(
                atPath: resourcesDirectory,
                withIntermediateDirectories: false
            )
            guard chmod(resourcesDirectory, mode_t(0o700)) == 0 else {
                throw VoicePerformanceTracerBundleFileSystemError.failed
            }
        }
        let signatureDirectory = invocation.path + "/Contents/_CodeSignature"
        try FileManager.default.createDirectory(
            atPath: signatureDirectory,
            withIntermediateDirectories: false
        )
        guard chmod(signatureDirectory, mode_t(0o700)) == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        let codeResources = signatureDirectory + "/CodeResources"
        try Data(invocation.signingIdentifier.utf8).write(
            to: URL(fileURLWithPath: codeResources),
            options: .withoutOverwriting
        )
        guard chmod(codeResources, mode_t(0o600)) == 0 else {
            throw VoicePerformanceTracerBundleFileSystemError.failed
        }
        if invocation.signingIdentifier
            == "fun.wwcn.rimeai.voice-performance-tracer"
        {
            // A resource-only Developer ID bundle uses the detached-signature
            // sidecars in addition to CodeResources on current macOS.
            for name in [
                "CodeDirectory", "CodeSignature", "CodeRequirements",
            ] {
                let path = signatureDirectory + "/" + name
                try Data(name.utf8).write(
                    to: URL(fileURLWithPath: path),
                    options: .withoutOverwriting
                )
                guard chmod(path, mode_t(0o600)) == 0 else {
                    throw VoicePerformanceTracerBundleFileSystemError.failed
                }
            }
        }
    }
}

private struct RealFileSigningInspector:
    VoicePerformanceTracerBundleSigningInspecting
{
    func inspectChildBundle(
        at appPath: String,
        executablePath: String,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String?
    ) throws -> VoicePerformanceTracerChildSigningEvidence {
        let data = try Data(contentsOf: URL(fileURLWithPath: executablePath))
        let sha = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        let digit: Character = switch expectedSigningIdentifier {
        case "fun.wwcn.rimeai.voice-performance-collector": "1"
        case "fun.wwcn.rimeai.voice-performance-driver": "2"
        default: "3"
        }
        return .init(
            appPath: appPath,
            executablePath: executablePath,
            executableSHA256: sha,
            signingIdentifier: expectedSigningIdentifier,
            teamIdentifier: "ABCDEFGHIJ",
            cdHash: String(repeating: digit, count: 40),
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
        .init(
            bundlePath: bundlePath,
            signingIdentifier: expectedSigningIdentifier,
            teamIdentifier: expectedTeamIdentifier,
            developerIDValidated: true,
            strictValidation: true,
            allArchitecturesValidated: true,
            nestedCodeValidated: true,
            hasHardenedRuntimeFlag: false,
            trustedTimestamp: true,
            hasEntitlementBlob: false,
            hasEntitlementDictionary: false
        )
    }
}

private struct DarwinTestNonceGenerator:
    VoicePerformanceTracerBundleNonceGenerating
{
    func randomBytes(count: Int) throws -> Data {
        Data(repeating: count == 32 ? 0xC1 : 0xD2, count: count)
    }
}

private struct DarwinTestArtifactVerifier:
    VoicePerformanceTracerBundleArtifactVerifying
{
    func verifyArtifact(
        at path: String
    ) throws -> VoicePerformanceTracerVerifiedArtifact {
        .init(
            directory: path,
            adapterID: "sherpa_onnx",
            artifactID: "zh_streaming_v1",
            contentSHA256: String(repeating: "a", count: 64),
            maximumHotwords: 64
        )
    }
}
