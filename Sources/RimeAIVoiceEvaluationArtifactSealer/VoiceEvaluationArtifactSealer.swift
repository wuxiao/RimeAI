import CryptoKit
import Darwin
import Foundation
@_spi(RimeAIInternal) import RimeAIVoiceArtifactCore

public enum VoiceEvaluationArtifactCohort {
    public static let artifactID =
        "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20-eval-27ffbd9e"
    public static let modelID =
        "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"
    public static let modelRevision =
        "archive-sha256-27ffbd9ee24ad186d99acc2f6354d7992b27bcab490812510665fa8f9389c5f8"
    public static let hotwordProbePhrase = "RIMEAI"
    static let hotwordProbeTokenIDs = [379, 125, 31, 38]
    public static let sourceURL =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
        + "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2"

    static let payloadPaths = [
        "licenses/LICENSE.txt",
        "licenses/NOTICE.txt",
        "model/bpe.vocab",
        "model/decoder.onnx",
        "model/encoder.onnx",
        "model/joiner.onnx",
        "model/tokens.txt",
    ]

    /// Frozen from the independently verified archive intake and deterministic
    /// BPE exporter. The production initializer never accepts another cohort.
    static let frozenPayloads: [VoiceEvaluationArtifactFrozenPayload] = [
        .init(
            path: "licenses/LICENSE.txt",
            bytes: 11_358,
            sha256: "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
        ),
        .init(
            path: "licenses/NOTICE.txt",
            bytes: 229,
            sha256: "94e2ce6616b74174dab7abb50c8f2f92b193e24d18518f9eb64db4d2e12bbb6a"
        ),
        .init(
            path: "model/bpe.vocab",
            bytes: 12_564,
            sha256: "d0b642f3a2eacd5fadefdeff9e0e1358cab729647cbb7fe58cf738e1f7407029"
        ),
        .init(
            path: "model/decoder.onnx",
            bytes: 13_876_452,
            sha256: "2e3b5ec371f8899ee6acd829fd753ba45772df57a91bdf37cde3136354e7db7d"
        ),
        .init(
            path: "model/encoder.onnx",
            bytes: 181_895_032,
            sha256: "8fa764187a261844f859d7143ebaa563af5d10adfece4c18a8f414c88cba2a9b"
        ),
        .init(
            path: "model/joiner.onnx",
            bytes: 3_228_404,
            sha256: "1ed689c5ed19dbaa725d9d191bb4822b5f4855a39e1ffd28cbc1f340d25b2ee0"
        ),
        .init(
            path: "model/tokens.txt",
            bytes: 56_317,
            sha256: "a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3"
        ),
    ]

    public static func evaluationNoticeData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "NOTICE",
            withExtension: "txt"
        ) else {
            throw VoiceEvaluationArtifactSealerError.internalResourceFailure
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw VoiceEvaluationArtifactSealerError.internalResourceFailure
        }
    }
}

struct VoiceEvaluationArtifactFrozenPayload: Equatable, Sendable {
    let path: String
    let bytes: Int64
    let sha256: String
}

/// One pinned evaluation cohort: identity, directory shape, frozen payload
/// digests and the manifest runtime kind the sealer emits for it.
public struct VoiceEvaluationArtifactCohortDefinition: Equatable, Sendable {
    public enum RuntimeKind: String, Sendable {
        case sherpaOnnxOnlineTransducer = "sherpa-onnx-online-transducer"
        case sherpaOnnxOnlineParaformer = "sherpa-onnx-online-paraformer"
    }

    let artifactID: String
    let modelID: String
    let modelRevision: String
    let hotwordProbePhrase: String?
    let sourceURL: String
    let modelFileNames: [String]
    let payloadPaths: [String]
    let frozenPayloads: [VoiceEvaluationArtifactFrozenPayload]
    let runtimeKind: RuntimeKind
}

extension VoiceEvaluationArtifactCohortDefinition {
    public static let zipformerBilingualZhEn2023 =
        VoiceEvaluationArtifactCohortDefinition(
            artifactID: VoiceEvaluationArtifactCohort.artifactID,
            modelID: VoiceEvaluationArtifactCohort.modelID,
            modelRevision: VoiceEvaluationArtifactCohort.modelRevision,
            hotwordProbePhrase: VoiceEvaluationArtifactCohort
                .hotwordProbePhrase,
            sourceURL: VoiceEvaluationArtifactCohort.sourceURL,
            modelFileNames: [
                "bpe.vocab", "decoder.onnx", "encoder.onnx", "joiner.onnx",
                "tokens.txt",
            ],
            payloadPaths: VoiceEvaluationArtifactCohort.payloadPaths,
            frozenPayloads: VoiceEvaluationArtifactCohort.frozenPayloads,
            runtimeKind: .sherpaOnnxOnlineTransducer
        )

    /// Frozen from the verified archive intake on 2026-10-13. The staged
    /// int8 encoder/decoder combination follows the upstream real-time
    /// example; hotwords are unsupported by streaming paraformer.
    public static let paraformerBilingualZhEn =
        VoiceEvaluationArtifactCohortDefinition(
            artifactID: "sherpa-onnx-streaming-paraformer-bilingual-zh-en-eval-5462a1fc",
            modelID: "sherpa-onnx-streaming-paraformer-bilingual-zh-en",
            modelRevision:
                "archive-sha256-5462a1fce42693deae572af1e8c4687124b12aa85fe61ff4d3168bb5280e205f",
            hotwordProbePhrase: nil,
            sourceURL:
                "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
                + "sherpa-onnx-streaming-paraformer-bilingual-zh-en.tar.bz2",
            modelFileNames: ["decoder.onnx", "encoder.onnx", "tokens.txt"],
            payloadPaths: [
                "licenses/LICENSE.txt",
                "licenses/NOTICE.txt",
                "model/decoder.onnx",
                "model/encoder.onnx",
                "model/tokens.txt",
            ],
            frozenPayloads: [
                .init(
                    path: "licenses/LICENSE.txt",
                    bytes: 11_358,
                    sha256: "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
                ),
                .init(
                    path: "licenses/NOTICE.txt",
                    bytes: 229,
                    sha256: "94e2ce6616b74174dab7abb50c8f2f92b193e24d18518f9eb64db4d2e12bbb6a"
                ),
                .init(
                    path: "model/decoder.onnx",
                    bytes: 71_664_561,
                    sha256: "f3cca9f77bb9d93c8fcbfb63ae617b6b1ee96818df3aa3b151c40658fe38594f"
                ),
                .init(
                    path: "model/encoder.onnx",
                    bytes: 165_462_184,
                    sha256: "81a70226a8934e6ed92aa1d4fc486b428b5398e2f2619ed4897b7294cab90e9a"
                ),
                .init(
                    path: "model/tokens.txt",
                    bytes: 75_756,
                    sha256: "59aba8873a2ed1e122c25fee421e25f283b63290efbde85c1f01a853d83cb6e6"
                ),
            ],
            runtimeKind: .sherpaOnnxOnlineParaformer
        )
}

public enum VoiceEvaluationArtifactSealerError: Error, Equatable, Sendable {
    case invalidArtifactPath
    case invalidArtifactTree
    case existingManifest
    case payloadDoesNotMatchFrozenCohort
    case payloadMutation
    case payloadDurabilityFailed
    case manifestEncodingFailed
    case manifestWriteFailed
    case manifestDurabilityFailed
    case postSealVerificationFailed
    case manifestCleanupIndeterminate
    case internalResourceFailure
}

public struct VoiceEvaluationArtifactSealReceipt: Equatable, Sendable {
    public let verifiedArtifact: VoiceASRVerifiedArtifact

    public var artifactID: String {
        verifiedArtifact.manifest.artifactID.rawValue
    }

    public var contentSHA256: String { verifiedArtifact.contentSHA256 }
    public var verifiedFileCount: Int { verifiedArtifact.verifiedFileCount }
    public var verifiedPayloadBytes: Int64 {
        verifiedArtifact.verifiedPayloadBytes
    }

    public func canonicalJSONData() -> Data {
        Data(
            ("{\"artifact_id\":\"" + artifactID
                + "\",\"content_sha256\":\"" + contentSHA256
                + "\",\"verified_file_count\":"
                + String(verifiedFileCount)
                + ",\"verified_payload_bytes\":"
                + String(verifiedPayloadBytes) + "}").utf8
        )
    }
}

public protocol VoiceEvaluationArtifactSealing: Sendable {
    func sealArtifact(
        at artifactDirectory: URL
    ) throws -> VoiceEvaluationArtifactSealReceipt
}

public struct VoiceEvaluationArtifactSealer:
    VoiceEvaluationArtifactSealing,
    Sendable
{
    private let cohort: VoiceEvaluationArtifactCohortDefinition
    private let expectedPayloads: [VoiceEvaluationArtifactFrozenPayload]?
    private let dependencies: VoiceEvaluationArtifactSealerDependencies

    public init(
        cohort: VoiceEvaluationArtifactCohortDefinition =
            .zipformerBilingualZhEn2023
    ) {
        self.cohort = cohort
        expectedPayloads = cohort.frozenPayloads
        dependencies = .live
    }

    init(
        cohort: VoiceEvaluationArtifactCohortDefinition,
        expectedPayloads: [VoiceEvaluationArtifactFrozenPayload]?,
        dependencies: VoiceEvaluationArtifactSealerDependencies = .live
    ) {
        self.cohort = cohort
        self.expectedPayloads = expectedPayloads
        self.dependencies = dependencies
    }

    init(
        expectedPayloads: [VoiceEvaluationArtifactFrozenPayload]?,
        dependencies: VoiceEvaluationArtifactSealerDependencies = .live
    ) {
        self.init(
            cohort: .zipformerBilingualZhEn2023,
            expectedPayloads: expectedPayloads,
            dependencies: dependencies
        )
    }

    public func sealArtifact(
        at artifactDirectory: URL
    ) throws -> VoiceEvaluationArtifactSealReceipt {
        let path = artifactDirectory.path
        guard Self.isCanonicalAbsolutePath(path), artifactDirectory.isFileURL
        else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactPath
        }

        let openedRoot = try Self.openArtifactRootByComponents(path)
        let rootDescriptor = openedRoot.descriptor
        defer { close(rootDescriptor) }
        try Self.validateDirectory(
            descriptor: rootDescriptor,
            namedStatus: openedRoot.namedStatus,
            effectiveUserID: dependencies.effectiveUserID(),
            hasNoExtendedACL: dependencies.hasNoExtendedACL
        )
        guard try Self.names(in: rootDescriptor) == ["licenses", "model"] else {
            if Self.entryExists(
                named: VoiceASRArtifactManifest.manifestFileName,
                in: rootDescriptor
            ) {
                throw VoiceEvaluationArtifactSealerError.existingManifest
            }
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }

        let licenseDescriptor = try Self.openDirectory(
            named: "licenses",
            in: rootDescriptor,
            dependencies: dependencies
        )
        defer { close(licenseDescriptor) }
        let modelDescriptor = try Self.openDirectory(
            named: "model",
            in: rootDescriptor,
            dependencies: dependencies
        )
        defer { close(modelDescriptor) }
        guard try Self.names(in: licenseDescriptor) == [
            "LICENSE.txt", "NOTICE.txt",
        ], try Self.names(in: modelDescriptor) == cohort.modelFileNames else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }

        let parents = [
            "licenses": licenseDescriptor,
            "model": modelDescriptor,
        ]
        var inventory: [VoiceEvaluationArtifactFrozenPayload] = []
        inventory.reserveCapacity(cohort.payloadPaths.count)
        for relativePath in cohort.payloadPaths {
            let components = relativePath.split(separator: "/").map(String.init)
            guard components.count == 2,
                  let parent = parents[components[0]]
            else {
                throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
            }
            let digest = try Self.stableDigest(
                named: components[1],
                relativePath: relativePath,
                in: parent,
                dependencies: dependencies
            )
            inventory.append(.init(
                path: relativePath,
                bytes: digest.bytes,
                sha256: digest.sha256
            ))
        }
        guard inventory.map(\.path) == cohort.payloadPaths
        else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }
        if let expectedPayloads, inventory != expectedPayloads {
            throw VoiceEvaluationArtifactSealerError
                .payloadDoesNotMatchFrozenCohort
        }
        try dependencies.afterInitialPayloadsHashed()
        try Self.revalidatePayloads(
            inventory,
            parents: parents,
            dependencies: dependencies
        )
        let noticeData = try Self.readSecureFile(
            named: "NOTICE.txt",
            relativePath: "licenses/NOTICE.txt",
            in: licenseDescriptor,
            maximumBytes: 16_384,
            dependencies: dependencies
        )
        guard noticeData == (try VoiceEvaluationArtifactCohort.evaluationNoticeData())
        else {
            throw VoiceEvaluationArtifactSealerError
                .payloadDoesNotMatchFrozenCohort
        }

        let manifestData = try Self.makeManifestData(
            inventory: inventory,
            cohort: cohort
        )
        var manifestMayExist = false
        var installedManifestIdentity: FileIdentity?
        do {
            try Self.validateNamedRootBinding(
                path,
                expected: openedRoot.namedStatus,
                dependencies: dependencies
            )
            try Self.installManifest(
                manifestData,
                rootDescriptor: rootDescriptor,
                childDirectoryDescriptors: [
                    licenseDescriptor, modelDescriptor,
                ],
                dependencies: dependencies,
                manifestMayExist: &manifestMayExist,
                installedIdentity: &installedManifestIdentity
            )
            guard try Self.names(in: rootDescriptor) == [
                "licenses", VoiceASRArtifactManifest.manifestFileName, "model",
            ], try Self.names(in: licenseDescriptor) == [
                "LICENSE.txt", "NOTICE.txt",
            ], try Self.names(in: modelDescriptor) == cohort.modelFileNames else {
                throw VoiceEvaluationArtifactSealerError.payloadMutation
            }
            try Self.revalidatePayloads(
                inventory,
                parents: parents,
                dependencies: dependencies
            )
            try Self.validateNamedRootBinding(
                path,
                expected: openedRoot.namedStatus,
                dependencies: dependencies
            )

            let verified: VoiceASRVerifiedArtifact
            let verifierDirectory = artifactDirectory
            try Self.validateVerifierRootBinding(
                verifierDirectory,
                expected: openedRoot.namedStatus
            )
            do {
                verified = try dependencies.verifyArtifact(verifierDirectory)
            } catch let error as VoiceASRArtifactError {
                _ = error
                throw VoiceEvaluationArtifactSealerError
                    .postSealVerificationFailed
            }
            try Self.validateNamedRootBinding(
                path,
                expected: openedRoot.namedStatus,
                dependencies: dependencies
            )
            guard verified.manifest.artifactID.rawValue
                    == cohort.artifactID,
                  verified.verifiedFileCount == inventory.count,
                  verified.verifiedPayloadBytes
                    == inventory.reduce(Int64(0), { $0 + $1.bytes })
            else {
                throw VoiceEvaluationArtifactSealerError
                    .postSealVerificationFailed
            }
            return VoiceEvaluationArtifactSealReceipt(
                verifiedArtifact: verified
            )
        } catch {
            if manifestMayExist {
                do {
                    guard let installedManifestIdentity else {
                        throw VoiceEvaluationArtifactSealerError
                            .manifestCleanupIndeterminate
                    }
                    try Self.cleanupInstalledManifest(
                        rootDescriptor: rootDescriptor,
                        installedIdentity: installedManifestIdentity,
                        dependencies: dependencies
                    )
                } catch {
                    throw VoiceEvaluationArtifactSealerError
                        .manifestCleanupIndeterminate
                }
            }
            throw error
        }
    }

    private struct Digest {
        let bytes: Int64
        let sha256: String
    }

    private struct OpenedRoot {
        let descriptor: Int32
        let namedStatus: stat
    }

    private struct FileIdentity {
        let device: dev_t
        let inode: ino_t
    }

    static func isCanonicalAbsolutePath(_ path: String) -> Bool {
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
        ).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
                && component.utf8.count <= 255
        }
    }

    private static func openArtifactRootByComponents(
        _ path: String
    ) throws -> OpenedRoot {
        let components = path.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactPath
        }
        var current = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }
        for (index, component) in components.enumerated() {
            var named = stat()
            guard fstatat(
                current,
                component,
                &named,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                named.st_mode & S_IFMT == S_IFDIR
            else {
                close(current)
                throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
            }
            let next = openat(
                current,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                close(current)
                throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
            }
            var opened = stat()
            guard fstat(next, &opened) == 0,
                  opened.st_mode & S_IFMT == S_IFDIR,
                  opened.st_dev == named.st_dev,
                  opened.st_ino == named.st_ino
            else {
                close(next)
                close(current)
                throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
            }
            close(current)
            current = next
            if index == components.count - 1 {
                return OpenedRoot(
                    descriptor: current,
                    namedStatus: named
                )
            }
        }
        close(current)
        throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
    }

    private static func validateNamedRootBinding(
        _ path: String,
        expected: stat,
        dependencies: VoiceEvaluationArtifactSealerDependencies
    ) throws {
        let reopened = try openArtifactRootByComponents(path)
        defer { close(reopened.descriptor) }
        guard reopened.namedStatus.st_dev == expected.st_dev,
              reopened.namedStatus.st_ino == expected.st_ino
        else {
            throw VoiceEvaluationArtifactSealerError.payloadMutation
        }
        do {
            try validateDirectory(
                descriptor: reopened.descriptor,
                namedStatus: reopened.namedStatus,
                effectiveUserID: dependencies.effectiveUserID(),
                hasNoExtendedACL: dependencies.hasNoExtendedACL
            )
        } catch let error as VoiceEvaluationArtifactSealerError {
            if error == .invalidArtifactTree {
                throw VoiceEvaluationArtifactSealerError.payloadMutation
            }
            throw error
        }
    }

    private static func validateVerifierRootBinding(
        _ directory: URL,
        expected: stat
    ) throws {
        guard directory.isFileURL,
              isCanonicalAbsolutePath(directory.path)
        else {
            throw VoiceEvaluationArtifactSealerError.payloadMutation
        }
        let reopened: OpenedRoot
        do {
            reopened = try openArtifactRootByComponents(directory.path)
        } catch {
            throw VoiceEvaluationArtifactSealerError.payloadMutation
        }
        defer { close(reopened.descriptor) }
        var opened = stat()
        guard fstat(reopened.descriptor, &opened) == 0,
              opened.st_dev == expected.st_dev,
              opened.st_ino == expected.st_ino,
              opened.st_dev == reopened.namedStatus.st_dev,
              opened.st_ino == reopened.namedStatus.st_ino
        else {
            throw VoiceEvaluationArtifactSealerError.payloadMutation
        }
    }

    private static func validateDirectory(
        descriptor: Int32,
        namedStatus: stat? = nil,
        effectiveUserID: uid_t,
        hasNoExtendedACL: (Int32) -> Bool
    ) throws {
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFDIR,
              opened.st_mode & mode_t(0o7777) == mode_t(0o700),
              opened.st_uid == effectiveUserID,
              hasNoExtendedACL(descriptor),
              namedStatus.map({
                  $0.st_dev == opened.st_dev && $0.st_ino == opened.st_ino
              }) ?? true
        else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }
    }

    private static func openDirectory(
        named name: String,
        in parent: Int32,
        dependencies: VoiceEvaluationArtifactSealerDependencies
    ) throws -> Int32 {
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFDIR
        else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }
        do {
            try validateDirectory(
                descriptor: descriptor,
                namedStatus: named,
                effectiveUserID: dependencies.effectiveUserID(),
                hasNoExtendedACL: dependencies.hasNoExtendedACL
            )
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func names(in descriptor: Int32) throws -> [String] {
        let iteratorDescriptor = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard iteratorDescriptor >= 0,
              let directory = fdopendir(iteratorDescriptor)
        else {
            if iteratorDescriptor >= 0 { close(iteratorDescriptor) }
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }
        defer { closedir(directory) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(
                    to: CChar.self
                ))
            }
            if name != ".", name != ".." {
                guard !name.hasPrefix("._") else {
                    return []
                }
                result.append(name)
            }
        }
        guard errno == 0 else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }
        return result.sorted()
    }

    private static func entryExists(named name: String, in parent: Int32) -> Bool {
        var status = stat()
        return fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0
    }

    private static func stableDigest(
        named name: String,
        relativePath: String,
        in parent: Int32,
        dependencies: VoiceEvaluationArtifactSealerDependencies
    ) throws -> Digest {
        let descriptor = try openSecureFile(
            named: name,
            relativePath: relativePath,
            in: parent,
            dependencies: dependencies
        )
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                if errno == EINTR { continue }
                throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
            }
            if count == 0 { break }
            let (next, overflow) = total.addingReportingOverflow(Int64(count))
            guard !overflow,
                  next <= VoiceASRArtifactVerificationLimits.production
                    .maximumTotalBytes
            else {
                throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
            }
            total = next
            hasher.update(data: Data(buffer[0 ..< count]))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameStableIdentity(before, after),
              total == after.st_size
        else {
            throw VoiceEvaluationArtifactSealerError.payloadMutation
        }
        do {
            try dependencies.synchronize(descriptor)
        } catch VoiceEvaluationArtifactSealerSystemFailure.synchronize {
            throw VoiceEvaluationArtifactSealerError.payloadDurabilityFailed
        }
        var afterSync = stat()
        guard fstat(descriptor, &afterSync) == 0,
              sameStableIdentity(after, afterSync)
        else {
            throw VoiceEvaluationArtifactSealerError.payloadMutation
        }
        return Digest(
            bytes: total,
            sha256: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private static func revalidatePayloads(
        _ expected: [VoiceEvaluationArtifactFrozenPayload],
        parents: [String: Int32],
        dependencies: VoiceEvaluationArtifactSealerDependencies
    ) throws {
        for entry in expected {
            let components = entry.path.split(separator: "/").map(String.init)
            guard components.count == 2,
                  let parent = parents[components[0]]
            else {
                throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
            }
            let digest = try stableDigest(
                named: components[1],
                relativePath: entry.path,
                in: parent,
                dependencies: dependencies
            )
            guard digest.bytes == entry.bytes,
                  digest.sha256 == entry.sha256
            else {
                throw VoiceEvaluationArtifactSealerError.payloadMutation
            }
        }
    }

    private static func readSecureFile(
        named name: String,
        relativePath: String,
        in parent: Int32,
        maximumBytes: Int,
        dependencies: VoiceEvaluationArtifactSealerDependencies
    ) throws -> Data {
        let descriptor = try openSecureFile(
            named: name,
            relativePath: relativePath,
            in: parent,
            dependencies: dependencies
        )
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_size >= 0,
              before.st_size <= maximumBytes
        else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }
        var result = Data(count: Int(before.st_size))
        var offset = 0
        try result.withUnsafeMutableBytes { bytes in
            while offset < bytes.count {
                let count = pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset,
                    off_t(offset)
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw VoiceEvaluationArtifactSealerError
                        .invalidArtifactTree
                }
                offset += count
            }
        }
        var afterRead = stat()
        guard fstat(descriptor, &afterRead) == 0,
              sameStableIdentity(before, afterRead),
              offset == result.count
        else {
            throw VoiceEvaluationArtifactSealerError.payloadMutation
        }
        do {
            try dependencies.synchronize(descriptor)
        } catch VoiceEvaluationArtifactSealerSystemFailure.synchronize {
            throw VoiceEvaluationArtifactSealerError.payloadDurabilityFailed
        }
        var afterSync = stat()
        guard fstat(descriptor, &afterSync) == 0,
              sameStableIdentity(afterRead, afterSync)
        else {
            throw VoiceEvaluationArtifactSealerError.payloadMutation
        }
        return result
    }

    private static func openSecureFile(
        named name: String,
        relativePath: String,
        in parent: Int32,
        dependencies: VoiceEvaluationArtifactSealerDependencies
    ) throws -> Int32 {
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFREG
        else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_mode & mode_t(0o7777) == mode_t(0o600),
              opened.st_uid == dependencies.effectiveUserID(),
              opened.st_nlink == 1,
              dependencies.hasNoExtendedACL(descriptor),
              named.st_dev == opened.st_dev,
              named.st_ino == opened.st_ino
        else {
            close(descriptor)
            throw VoiceEvaluationArtifactSealerError.invalidArtifactTree
        }
        _ = relativePath
        return descriptor
    }

    private static func sameStableIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid
            && lhs.st_nlink == rhs.st_nlink && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func makeManifestData(
        inventory: [VoiceEvaluationArtifactFrozenPayload],
        cohort: VoiceEvaluationArtifactCohortDefinition
    ) throws -> Data {
        let provisional = try canonicalManifestData(
            inventory: inventory,
            contentSHA256: String(repeating: "0", count: 64),
            cohort: cohort
        )
        let provisionalManifest: VoiceASRArtifactManifest
        do {
            provisionalManifest = try VoiceASRArtifactManifest.decodeStrict(
                provisional,
                verifyContentDigest: false
            )
        } catch let error as VoiceASRArtifactError {
            _ = error
            throw VoiceEvaluationArtifactSealerError.manifestEncodingFailed
        }
        let final = try canonicalManifestData(
            inventory: inventory,
            contentSHA256: provisionalManifest.calculatedContentSHA256,
            cohort: cohort
        )
        do {
            let decoded = try VoiceASRArtifactManifest.decodeStrict(final)
            guard decoded.calculatedContentSHA256 == decoded.contentSHA256 else {
                throw VoiceEvaluationArtifactSealerError.manifestEncodingFailed
            }
        } catch let error as VoiceASRArtifactError {
            _ = error
            throw VoiceEvaluationArtifactSealerError.manifestEncodingFailed
        }
        return final
    }

    private static func canonicalManifestData(
        inventory: [VoiceEvaluationArtifactFrozenPayload],
        contentSHA256: String,
        cohort: VoiceEvaluationArtifactCohortDefinition
    ) throws -> Data {
        let runtime: [String: Any]
        let capabilities: [String: Any]
        switch cohort.runtimeKind {
        case .sherpaOnnxOnlineTransducer:
            runtime = [
                "kind": "sherpa-onnx-online-transducer",
                "encoder_path": "model/encoder.onnx",
                "decoder_path": "model/decoder.onnx",
                "joiner_path": "model/joiner.onnx",
                "tokens_path": "model/tokens.txt",
                "bpe_vocab_path": "model/bpe.vocab",
                "modeling_unit": "cjkchar+bpe", "model_type": "zipformer",
                "feature_dimension": 80, "provider": "cpu", "num_threads": 2,
                "decoding_method": "modified_beam_search",
                "max_active_paths": 4,
                "endpoint": [
                    "enabled": true,
                    "rule1_min_trailing_silence_ms": 2_400,
                    "rule2_min_trailing_silence_ms": 1_200,
                    "rule3_min_utterance_ms": 30_000,
                ],
                "hotword_probe_phrase": cohort.hotwordProbePhrase ?? "",
                "hotwords_score_milli": 1_500,
                "blank_penalty_milli": 0,
            ]
            capabilities = [
                "streaming": true, "partial_results": true,
                "endpoint_detection": true,
                "hotword_mode": "bounded-phrase-list",
                "maximum_hotwords": 32, "maximum_alternatives": 1,
            ]
        case .sherpaOnnxOnlineParaformer:
            runtime = [
                "kind": "sherpa-onnx-online-paraformer",
                "encoder_path": "model/encoder.onnx",
                "decoder_path": "model/decoder.onnx",
                "tokens_path": "model/tokens.txt",
                "modeling_unit": "cjkchar", "model_type": "paraformer",
                "feature_dimension": 80, "provider": "cpu", "num_threads": 2,
                "decoding_method": "greedy_search",
                "max_active_paths": 4,
                "endpoint": [
                    "enabled": true,
                    "rule1_min_trailing_silence_ms": 2_400,
                    "rule2_min_trailing_silence_ms": 1_200,
                    "rule3_min_utterance_ms": 20_000,
                ],
                "hotword_probe_phrase": "",
                "hotwords_score_milli": 0,
                "blank_penalty_milli": 0,
            ]
            capabilities = [
                "streaming": true, "partial_results": true,
                "endpoint_detection": true,
                "hotword_mode": "unsupported",
                "maximum_hotwords": 0, "maximum_alternatives": 1,
            ]
        }
        let object: [String: Any] = [
            "schema_version": 2,
            "artifact_type": VoiceASRArtifactManifest.supportedArtifactType,
            "asset_management": "product-managed",
            "artifact_id": cohort.artifactID,
            "adapter": [
                "id": "sherpa-onnx", "version": "1.13.6", "abi_version": 1,
            ],
            "model": [
                "id": cohort.modelID,
                "revision": cohort.modelRevision,
                "format": "onnx", "quantization": "mixed",
            ],
            "target": [
                "os": "macos", "architecture": "arm64",
                "minimum_os_version": "14.0",
            ],
            "audio": [
                "sample_rate_hz": 16_000, "channel_count": 1,
                "sample_format": "float32le", "frame_duration_ms": 20,
            ],
            "runtime": runtime,
            "network_policy": "offline",
            "locales": ["en-US", "zh-CN"],
            "capabilities": capabilities,
            "license": [
                "spdx_id": "Apache-2.0",
                "license_path": "licenses/LICENSE.txt",
                "notice_path": "licenses/NOTICE.txt",
                "source_url": cohort.sourceURL,
            ],
            "inventory": inventory.map { entry in
                [
                    "path": entry.path,
                    "bytes": entry.bytes,
                    "sha256": entry.sha256,
                ] as [String: Any]
            },
            "content_sha256": contentSHA256,
        ]
        do {
            return try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw VoiceEvaluationArtifactSealerError.manifestEncodingFailed
        }
    }

    private static func installManifest(
        _ data: Data,
        rootDescriptor: Int32,
        childDirectoryDescriptors: [Int32],
        dependencies: VoiceEvaluationArtifactSealerDependencies,
        manifestMayExist: inout Bool,
        installedIdentity: inout FileIdentity?
    ) throws {
        let descriptor = openat(
            rootDescriptor,
            VoiceASRArtifactManifest.manifestFileName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw VoiceEvaluationArtifactSealerError.existingManifest
            }
            throw VoiceEvaluationArtifactSealerError.manifestWriteFailed
        }
        manifestMayExist = true
        defer { close(descriptor) }
        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0 else {
            throw VoiceEvaluationArtifactSealerError.manifestWriteFailed
        }
        installedIdentity = FileIdentity(
            device: initialStatus.st_dev,
            inode: initialStatus.st_ino
        )
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw VoiceEvaluationArtifactSealerError.manifestWriteFailed
        }
        var securedStatus = stat()
        guard fstat(descriptor, &securedStatus) == 0,
              securedStatus.st_mode & S_IFMT == S_IFREG,
              securedStatus.st_mode & mode_t(0o7777) == mode_t(0o600),
              securedStatus.st_uid == dependencies.effectiveUserID(),
              securedStatus.st_nlink == 1,
              dependencies.hasNoExtendedACL(descriptor),
              securedStatus.st_dev == initialStatus.st_dev,
              securedStatus.st_ino == initialStatus.st_ino
        else {
            throw VoiceEvaluationArtifactSealerError.manifestWriteFailed
        }
        do {
            try dependencies.writeManifest(descriptor, data)
        } catch VoiceEvaluationArtifactSealerSystemFailure.write {
            throw VoiceEvaluationArtifactSealerError.manifestWriteFailed
        }
        var writtenStatus = stat()
        guard fstat(descriptor, &writtenStatus) == 0,
              writtenStatus.st_dev == securedStatus.st_dev,
              writtenStatus.st_ino == securedStatus.st_ino,
              writtenStatus.st_size == data.count,
              writtenStatus.st_mode & mode_t(0o7777) == mode_t(0o600),
              writtenStatus.st_uid == dependencies.effectiveUserID(),
              writtenStatus.st_nlink == 1,
              dependencies.hasNoExtendedACL(descriptor)
        else {
            throw VoiceEvaluationArtifactSealerError.manifestWriteFailed
        }
        do {
            try dependencies.synchronize(descriptor)
        } catch VoiceEvaluationArtifactSealerSystemFailure.synchronize {
            throw VoiceEvaluationArtifactSealerError.manifestDurabilityFailed
        }
        for child in childDirectoryDescriptors {
            do {
                try dependencies.synchronize(child)
            } catch VoiceEvaluationArtifactSealerSystemFailure.synchronize {
                throw VoiceEvaluationArtifactSealerError
                    .manifestDurabilityFailed
            }
        }
        do {
            try dependencies.synchronize(rootDescriptor)
        } catch VoiceEvaluationArtifactSealerSystemFailure.synchronize {
            throw VoiceEvaluationArtifactSealerError.manifestDurabilityFailed
        }
        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
              finalStatus.st_dev == writtenStatus.st_dev,
              finalStatus.st_ino == writtenStatus.st_ino,
              finalStatus.st_size == writtenStatus.st_size,
              finalStatus.st_mode == writtenStatus.st_mode,
              finalStatus.st_uid == writtenStatus.st_uid,
              finalStatus.st_nlink == writtenStatus.st_nlink
        else {
            throw VoiceEvaluationArtifactSealerError.payloadMutation
        }
    }

    private static func cleanupInstalledManifest(
        rootDescriptor: Int32,
        installedIdentity: FileIdentity,
        dependencies: VoiceEvaluationArtifactSealerDependencies
    ) throws {
        var named = stat()
        guard fstatat(
            rootDescriptor,
            VoiceASRArtifactManifest.manifestFileName,
            &named,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            named.st_mode & S_IFMT == S_IFREG,
            named.st_dev == installedIdentity.device,
            named.st_ino == installedIdentity.inode,
            dependencies.unlinkManifest(rootDescriptor) == 0
        else {
            throw VoiceEvaluationArtifactSealerError
                .manifestCleanupIndeterminate
        }
        var absent = stat()
        errno = 0
        guard fstatat(
            rootDescriptor,
            VoiceASRArtifactManifest.manifestFileName,
            &absent,
            AT_SYMLINK_NOFOLLOW
        ) == -1,
            errno == ENOENT
        else {
            throw VoiceEvaluationArtifactSealerError
                .manifestCleanupIndeterminate
        }
        do {
            try dependencies.synchronize(rootDescriptor)
        } catch {
            throw VoiceEvaluationArtifactSealerError
                .manifestCleanupIndeterminate
        }
    }
}
