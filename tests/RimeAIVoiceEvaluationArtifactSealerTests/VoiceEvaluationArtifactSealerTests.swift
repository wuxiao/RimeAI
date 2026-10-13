import Darwin
import Foundation
import Testing
@_spi(RimeAIInternal) import RimeAIVoiceArtifactCore
@testable import RimeAIVoiceEvaluationArtifactSealer

@Suite("Internal voice evaluation artifact sealer")
struct VoiceEvaluationArtifactSealerTests {
    @Test("a synthetic second cohort seals with paraformer manifest fields")
    func test_sealsSyntheticSecondCohort() throws {
        let fixture = try ParaformerEvaluationArtifactFixture()
        defer { fixture.remove() }
        let synthetic = VoiceEvaluationArtifactCohortDefinition(
            artifactID: "synthetic-paraformer-eval",
            modelID: "synthetic-paraformer",
            modelRevision: "synthetic-revision",
            hotwordProbePhrase: nil,
            sourceURL: "https://example.invalid/paraformer.tar.bz2",
            modelFileNames: ["decoder.onnx", "encoder.onnx", "tokens.txt"],
            payloadPaths: ParaformerEvaluationArtifactFixture.payloadPaths,
            frozenPayloads: [],
            runtimeKind: .sherpaOnnxOnlineParaformer
        )

        let receipt = try VoiceEvaluationArtifactSealer(
            cohort: synthetic,
            expectedPayloads: nil
        ).sealArtifact(at: fixture.root)
        let manifest = try VoiceASRArtifactManifest.decodeStrict(
            Data(contentsOf: fixture.root.appendingPathComponent("manifest.json"))
        )

        #expect(receipt.artifactID == "synthetic-paraformer-eval")
        #expect(receipt.verifiedFileCount == 5)
        #expect(receipt.verifiedPayloadBytes == fixture.payloadBytes)
        #expect(manifest.runtime.kind == .sherpaOnnxOnlineParaformer)
        #expect(manifest.runtime.modelType == .paraformer)
        #expect(manifest.runtime.modelingUnit == .cjkCharacter)
        #expect(manifest.runtime.decodingMethod == .greedySearch)
        #expect(manifest.runtime.joinerPath == nil)
        #expect(manifest.runtime.bpeVocabularyPath == nil)
        #expect(manifest.runtime.hotwordProbePhrase.isEmpty)
        #expect(manifest.capabilities.hotwordMode == .unsupported)
        #expect(manifest.capabilities.maximumHotwords == 0)
        #expect(manifest.license.sourceURL == "https://example.invalid/paraformer.tar.bz2")
    }

    @Test("a cohort never accepts another cohort's directory shape or bytes")
    func test_cohortDirShapeMismatchFails() throws {
        let zipformerShaped = try EvaluationArtifactFixture()
        defer { zipformerShaped.remove() }
        #expect(
            throws: VoiceEvaluationArtifactSealerError.invalidArtifactTree
        ) {
            _ = try VoiceEvaluationArtifactSealer(
                cohort: .paraformerBilingualZhEn
            ).sealArtifact(at: zipformerShaped.root)
        }
        #expect(!zipformerShaped.manifestExists)

        let paraformerShaped = try ParaformerEvaluationArtifactFixture()
        defer { paraformerShaped.remove() }
        #expect(
            throws: VoiceEvaluationArtifactSealerError
                .payloadDoesNotMatchFrozenCohort
        ) {
            _ = try VoiceEvaluationArtifactSealer(
                cohort: .paraformerBilingualZhEn
            ).sealArtifact(at: paraformerShaped.root)
        }
        #expect(!paraformerShaped.manifestExists)
    }

    @Test("prepared exact payload is sealed and fully verified")
    func preparedPayloadIsSealedAndVerified() throws {
        let fixture = try EvaluationArtifactFixture()
        defer { fixture.remove() }

        let receipt = try VoiceEvaluationArtifactSealer(
            expectedPayloads: nil
        ).sealArtifact(at: fixture.root)

        #expect(
            receipt.artifactID
                == VoiceEvaluationArtifactCohort.artifactID
        )
        #expect(receipt.verifiedFileCount == 7)
        #expect(receipt.verifiedPayloadBytes == fixture.payloadBytes)
        #expect(receipt.contentSHA256.utf8.count == 64)

        let manifestURL = fixture.root.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try VoiceASRArtifactManifest.decodeStrict(manifestData)
        #expect(manifest.artifactID.rawValue == receipt.artifactID)
        #expect(manifest.model.id == VoiceEvaluationArtifactCohort.modelID)
        #expect(
            manifest.model.revision
                == VoiceEvaluationArtifactCohort.modelRevision
        )
        #expect(manifest.model.quantization == .mixed)
        #expect(
            manifest.runtime.hotwordProbePhrase
                == VoiceEvaluationArtifactCohort.hotwordProbePhrase
        )
        #expect(manifest.contentSHA256 == receipt.contentSHA256)
        #expect(
            try VoiceASRArtifactVerifier()
                .verifyArtifact(at: fixture.root)
                == receipt.verifiedArtifact
        )

        var status = stat()
        #expect(lstat(manifestURL.path, &status) == 0)
        #expect(status.st_mode & mode_t(0o777) == mode_t(0o600))
    }

    @Test("frozen seven-file cohort and four-piece non-unknown probe are exact")
    func frozenCohortGoldenValuesAreExact() {
        #expect(VoiceEvaluationArtifactCohort.hotwordProbePhrase == "RIMEAI")
        #expect(
            VoiceEvaluationArtifactCohort.hotwordProbeTokenIDs
                == [379, 125, 31, 38]
        )
        #expect(
            !VoiceEvaluationArtifactCohort.hotwordProbeTokenIDs.contains(2)
        )
        #expect(VoiceEvaluationArtifactCohort.frozenPayloads == [
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
        ])
    }

    @Test("an intermediate symlink cannot redirect the artifact root")
    func intermediateSymlinkIsRejected() throws {
        let fixture = try EvaluationArtifactFixture()
        defer { fixture.remove() }
        let alias = URL(
            fileURLWithPath: "/private/tmp/rimeai-evaluation-alias-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: alias) }
        #expect(symlink("/private/tmp", alias.path) == 0)
        let redirected = alias.appendingPathComponent(
            fixture.root.lastPathComponent,
            isDirectory: true
        )

        #expect(throws: VoiceEvaluationArtifactSealerError.invalidArtifactTree) {
            _ = try VoiceEvaluationArtifactSealer(
                expectedPayloads: nil
            ).sealArtifact(at: redirected)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("manifest.json").path
            )
        )
    }

    @Test("identical payloads produce byte-identical manifests and receipts")
    func sealingIsDeterministic() throws {
        let first = try EvaluationArtifactFixture()
        let second = try EvaluationArtifactFixture()
        defer {
            first.remove()
            second.remove()
        }

        let sealer = VoiceEvaluationArtifactSealer(expectedPayloads: nil)
        let firstReceipt = try sealer.sealArtifact(at: first.root)
        let secondReceipt = try sealer.sealArtifact(at: second.root)
        let firstManifest = try Data(
            contentsOf: first.root.appendingPathComponent("manifest.json")
        )
        let secondManifest = try Data(
            contentsOf: second.root.appendingPathComponent("manifest.json")
        )

        #expect(firstManifest == secondManifest)
        #expect(
            firstReceipt.canonicalJSONData()
                == secondReceipt.canonicalJSONData()
        )
        let receiptObject = try #require(
            JSONSerialization.jsonObject(
                with: firstReceipt.canonicalJSONData()
            ) as? [String: Any]
        )
        #expect(receiptObject.keys.sorted() == [
            "artifact_id", "content_sha256", "verified_file_count",
            "verified_payload_bytes",
        ])
        #expect(!firstManifest.contains(0x0A))
    }

    @Test("production initializer rejects a payload outside the frozen cohort")
    func productionCohortIsFrozen() throws {
        let fixture = try EvaluationArtifactFixture()
        defer { fixture.remove() }

        #expect(
            throws: VoiceEvaluationArtifactSealerError
                .payloadDoesNotMatchFrozenCohort
        ) {
            _ = try VoiceEvaluationArtifactSealer().sealArtifact(
                at: fixture.root
            )
        }
        #expect(!fixture.manifestExists)
    }

    @Test("extra, symlink, hardlink, special, and insecure mode trees fail closed")
    func unsafeTreesAreRejected() throws {
        try expectTreeRejected { fixture in
            try Data("extra".utf8).write(
                to: fixture.root.appendingPathComponent("extra")
            )
            #expect(chmod(
                fixture.root.appendingPathComponent("extra").path,
                mode_t(0o600)
            ) == 0)
        }
        try expectTreeRejected { fixture in
            let tokens = fixture.root.appendingPathComponent("model/tokens.txt")
            try FileManager.default.removeItem(at: tokens)
            #expect(symlink("encoder.onnx", tokens.path) == 0)
        }
        try expectTreeRejected { fixture in
            let tokens = fixture.root.appendingPathComponent("model/tokens.txt")
            try FileManager.default.removeItem(at: tokens)
            #expect(link(
                fixture.root.appendingPathComponent("model/encoder.onnx").path,
                tokens.path
            ) == 0)
        }
        try expectTreeRejected { fixture in
            let tokens = fixture.root.appendingPathComponent("model/tokens.txt")
            try FileManager.default.removeItem(at: tokens)
            #expect(mkfifo(tokens.path, mode_t(0o600)) == 0)
        }
        try expectTreeRejected { fixture in
            #expect(chmod(
                fixture.root.appendingPathComponent("model/encoder.onnx").path,
                mode_t(0o640)
            ) == 0)
        }
        try expectTreeRejected { fixture in
            try Data().write(
                to: fixture.root.appendingPathComponent("model/._encoder.onnx")
            )
            #expect(chmod(
                fixture.root.appendingPathComponent("model/._encoder.onnx").path,
                mode_t(0o600)
            ) == 0)
        }
    }

    @Test("effective uid and ACL seams fail closed")
    func uidAndACLSeamsRejectTheTree() throws {
        let uidFixture = try EvaluationArtifactFixture()
        defer { uidFixture.remove() }
        var wrongUID = VoiceEvaluationArtifactSealerDependencies.live
        wrongUID.effectiveUserID = { geteuid() &+ 1 }
        #expect(throws: VoiceEvaluationArtifactSealerError.invalidArtifactTree) {
            _ = try VoiceEvaluationArtifactSealer(
                expectedPayloads: nil,
                dependencies: wrongUID
            ).sealArtifact(at: uidFixture.root)
        }
        #expect(!uidFixture.manifestExists)

        let aclFixture = try EvaluationArtifactFixture()
        defer { aclFixture.remove() }
        var extendedACL = VoiceEvaluationArtifactSealerDependencies.live
        extendedACL.hasNoExtendedACL = { _ in false }
        #expect(throws: VoiceEvaluationArtifactSealerError.invalidArtifactTree) {
            _ = try VoiceEvaluationArtifactSealer(
                expectedPayloads: nil,
                dependencies: extendedACL
            ).sealArtifact(at: aclFixture.root)
        }
        #expect(!aclFixture.manifestExists)
    }

    @Test("payload mutation after the initial hashes is detected before install")
    func mutationAfterHashingIsRejected() throws {
        let fixture = try EvaluationArtifactFixture()
        defer { fixture.remove() }
        var dependencies = VoiceEvaluationArtifactSealerDependencies.live
        dependencies.afterInitialPayloadsHashed = {
            let encoder = fixture.root.appendingPathComponent(
                "model/encoder.onnx"
            )
            try Data("mutated\n".utf8).write(to: encoder)
            #expect(chmod(encoder.path, mode_t(0o600)) == 0)
        }

        #expect(throws: VoiceEvaluationArtifactSealerError.payloadMutation) {
            _ = try VoiceEvaluationArtifactSealer(
                expectedPayloads: nil,
                dependencies: dependencies
            ).sealArtifact(at: fixture.root)
        }
        #expect(!fixture.manifestExists)
    }

    @Test("an existing manifest is never overwritten or removed")
    func existingManifestIsPreserved() throws {
        let fixture = try EvaluationArtifactFixture()
        defer { fixture.remove() }
        let manifest = fixture.root.appendingPathComponent("manifest.json")
        let original = Data("preexisting".utf8)
        try original.write(to: manifest)
        #expect(chmod(manifest.path, mode_t(0o600)) == 0)

        #expect(throws: VoiceEvaluationArtifactSealerError.existingManifest) {
            _ = try VoiceEvaluationArtifactSealer(
                expectedPayloads: nil
            ).sealArtifact(at: fixture.root)
        }
        #expect(try Data(contentsOf: manifest) == original)
    }

    @Test("write failure removes only the manifest inode created by this run")
    func writeFailureCleansUpOwnedManifest() throws {
        let fixture = try EvaluationArtifactFixture()
        defer { fixture.remove() }
        var dependencies = VoiceEvaluationArtifactSealerDependencies.live
        dependencies.writeManifest = { descriptor, data in
            try VoiceEvaluationArtifactSealerDependencies.live.writeManifest(
                descriptor,
                Data(data.prefix(17))
            )
            throw VoiceEvaluationArtifactSealerSystemFailure.write
        }

        #expect(throws: VoiceEvaluationArtifactSealerError.manifestWriteFailed) {
            _ = try VoiceEvaluationArtifactSealer(
                expectedPayloads: nil,
                dependencies: dependencies
            ).sealArtifact(at: fixture.root)
        }
        #expect(!fixture.manifestExists)
    }

    @Test("cleanup uncertainty does not delete an attacker replacement")
    func manifestReplacementIsPreservedAsIndeterminate() throws {
        let fixture = try EvaluationArtifactFixture()
        defer { fixture.remove() }
        let manifest = fixture.root.appendingPathComponent("manifest.json")
        let displaced = fixture.root.appendingPathComponent("owned-manifest")
        let replacement = Data("replacement".utf8)
        var dependencies = VoiceEvaluationArtifactSealerDependencies.live
        dependencies.writeManifest = { descriptor, data in
            try VoiceEvaluationArtifactSealerDependencies.live.writeManifest(
                descriptor,
                data
            )
            #expect(rename(manifest.path, displaced.path) == 0)
            try replacement.write(to: manifest)
            #expect(chmod(manifest.path, mode_t(0o600)) == 0)
            throw VoiceEvaluationArtifactSealerSystemFailure.write
        }

        #expect(
            throws: VoiceEvaluationArtifactSealerError
                .manifestCleanupIndeterminate
        ) {
            _ = try VoiceEvaluationArtifactSealer(
                expectedPayloads: nil,
                dependencies: dependencies
            ).sealArtifact(at: fixture.root)
        }
        #expect(try Data(contentsOf: manifest) == replacement)
    }

    @Test("unlink failure takes precedence over the original write failure")
    func unlinkFailureIsCleanupIndeterminate() throws {
        let fixture = try EvaluationArtifactFixture()
        defer { fixture.remove() }
        var dependencies = VoiceEvaluationArtifactSealerDependencies.live
        dependencies.writeManifest = { _, _ in
            throw VoiceEvaluationArtifactSealerSystemFailure.write
        }
        dependencies.unlinkManifest = { _ in -1 }

        #expect(
            throws: VoiceEvaluationArtifactSealerError
                .manifestCleanupIndeterminate
        ) {
            _ = try VoiceEvaluationArtifactSealer(
                expectedPayloads: nil,
                dependencies: dependencies
            ).sealArtifact(at: fixture.root)
        }
        #expect(fixture.manifestExists)
    }

    @Test("an unknown verifier error is preserved after owned cleanup")
    func unknownVerifierErrorIsNotReclassified() throws {
        let fixture = try EvaluationArtifactFixture()
        defer { fixture.remove() }
        var dependencies = VoiceEvaluationArtifactSealerDependencies.live
        dependencies.verifyArtifact = { _ in
            throw UnexpectedVerificationError.marker
        }

        #expect(throws: UnexpectedVerificationError.marker) {
            _ = try VoiceEvaluationArtifactSealer(
                expectedPayloads: nil,
                dependencies: dependencies
            ).sealArtifact(at: fixture.root)
        }
        #expect(!fixture.manifestExists)
    }

    @Test("root replacement during verification is detected and cleaned by inode")
    func rootReplacementDuringVerificationIsRejected() throws {
        let fixture = try EvaluationArtifactFixture()
        let displaced = URL(
            fileURLWithPath: fixture.root.path + "-displaced",
            isDirectory: true
        )
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: displaced)
        }
        var dependencies = VoiceEvaluationArtifactSealerDependencies.live
        dependencies.verifyArtifact = { directory in
            let verified = try VoiceASRArtifactVerifier().verifyArtifact(
                at: directory
            )
            #expect(rename(fixture.root.path, displaced.path) == 0)
            #expect(mkdir(fixture.root.path, mode_t(0o700)) == 0)
            #expect(chmod(fixture.root.path, mode_t(0o700)) == 0)
            return verified
        }

        #expect(throws: VoiceEvaluationArtifactSealerError.payloadMutation) {
            _ = try VoiceEvaluationArtifactSealer(
                expectedPayloads: nil,
                dependencies: dependencies
            ).sealArtifact(at: fixture.root)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: displaced.appendingPathComponent("manifest.json").path
            )
        )
    }

    private func expectTreeRejected(
        mutate: (EvaluationArtifactFixture) throws -> Void
    ) throws {
        let fixture = try EvaluationArtifactFixture()
        defer { fixture.remove() }
        try mutate(fixture)
        #expect(throws: VoiceEvaluationArtifactSealerError.invalidArtifactTree) {
            _ = try VoiceEvaluationArtifactSealer(
                expectedPayloads: nil
            ).sealArtifact(at: fixture.root)
        }
        #expect(!fixture.manifestExists)
    }
}

private final class ParaformerEvaluationArtifactFixture {
    static let payloadPaths = [
        "licenses/LICENSE.txt",
        "licenses/NOTICE.txt",
        "model/decoder.onnx",
        "model/encoder.onnx",
        "model/tokens.txt",
    ]

    static let payloads: [(String, Data)] = [
        ("licenses/LICENSE.txt", Data("license\n".utf8)),
        (
            "licenses/NOTICE.txt",
            Data(
                """
                RimeAI Voice Evaluation Artifact Notice

                Internal evaluation only.
                Redistribution is not approved.
                Production use or release is not approved.
                Upstream rights, immutable revision mapping, and NOTICE obligations remain unresolved.

                """.utf8
            )
        ),
        ("model/decoder.onnx", Data("decoder\n".utf8)),
        ("model/encoder.onnx", Data("encoder\n".utf8)),
        ("model/tokens.txt", Data("tokens\n".utf8)),
    ]

    let root: URL
    let payloadBytes: Int64

    var manifestExists: Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent("manifest.json").path
        )
    }

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
            "rimeai-evaluation-sealer-paraformer-\(UUID().uuidString)",
            isDirectory: true
        )
        payloadBytes = Self.payloads.reduce(0) {
            $0 + Int64($1.1.count)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for directory in ["licenses", "model"] {
            let url = root.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            #expect(chmod(url.path, mode_t(0o700)) == 0)
        }
        for (path, data) in Self.payloads {
            let url = root.appendingPathComponent(path)
            try data.write(to: url)
            #expect(chmod(url.path, mode_t(0o600)) == 0)
        }
        #expect(chmod(root.path, mode_t(0o700)) == 0)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum UnexpectedVerificationError: Error {
    case marker
}

private final class EvaluationArtifactFixture {
    static let payloads: [(String, Data)] = [
        ("licenses/LICENSE.txt", Data("license\n".utf8)),
        (
            "licenses/NOTICE.txt",
            Data(
                """
                RimeAI Voice Evaluation Artifact Notice

                Internal evaluation only.
                Redistribution is not approved.
                Production use or release is not approved.
                Upstream rights, immutable revision mapping, and NOTICE obligations remain unresolved.

                """.utf8
            )
        ),
        ("model/bpe.vocab", Data("bpe\n".utf8)),
        ("model/decoder.onnx", Data("decoder\n".utf8)),
        ("model/encoder.onnx", Data("encoder\n".utf8)),
        ("model/joiner.onnx", Data("joiner\n".utf8)),
        ("model/tokens.txt", Data("tokens\n".utf8)),
    ]

    let root: URL
    let payloadBytes: Int64

    var manifestExists: Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent("manifest.json").path
        )
    }

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
            "rimeai-evaluation-sealer-\(UUID().uuidString)",
            isDirectory: true
        )
        payloadBytes = Self.payloads.reduce(0) {
            $0 + Int64($1.1.count)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for directory in ["licenses", "model"] {
            let url = root.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            #expect(chmod(url.path, mode_t(0o700)) == 0)
        }
        for (path, data) in Self.payloads {
            let url = root.appendingPathComponent(path)
            try data.write(to: url)
            #expect(chmod(url.path, mode_t(0o600)) == 0)
        }
        #expect(chmod(root.path, mode_t(0o700)) == 0)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
