import Darwin
import Foundation
import Testing
@_spi(RimeAIInternal) import RimeAIVoiceArtifactCore
@testable import RimeAIInputCore

@Suite("Voice ASR offline artifact publisher", .serialized)
struct VoiceASRArtifactPublisherTests {
    @Test("production trust catalog is empty and fails closed")
    func productionCatalogRejectsUnapprovedArtifact() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let source = try fixture.makeArtifactSource()
        let publisher = VoiceASRArtifactPublisher(layout: fixture.layout)

        #expect(
            throws: VoiceASRArtifactPublisherError.untrustedArtifact(
                fixture.artifactID
            )
        ) {
            try publisher.publishLocalArtifact(from: source)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.layout.voiceASRReleaseDirectory(
                    for: fixture.artifactID
                ).path
            )
        )
    }

    @Test("a trusted local directory is copied into an immutable release")
    func trustedArtifactPublishesOffline() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let source = try fixture.makeArtifactSource()
        let publisher = try fixture.trustedPublisher(for: source)

        let result = try publisher.publishLocalArtifact(from: source)

        #expect(result.disposition == .published)
        #expect(result.selectorState == nil)
        let release = fixture.layout.voiceASRReleaseDirectory(
            for: fixture.artifactID
        )
        #expect(result.artifact.artifactDirectory == release)
        #expect(
            try VoiceASRArtifactVerifier().verifyArtifact(at: release)
                .contentSHA256 == result.artifact.contentSHA256
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.layout.voiceASRCurrentSelector.path
            )
        )
        #expect(try fixture.stagingImportEntries().isEmpty)
        try fixture.expectPrivateTree(at: release)
    }

    @Test("a symlinked source ancestor is rejected during publisher copy")
    func symlinkedSourceAncestorIsRejected() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let source = try fixture.makeArtifactSource()
        let aliasPath = source.path.replacingOccurrences(
            of: "/private/tmp/",
            with: "/tmp/"
        )
        #expect(aliasPath != source.path)
        let alias = URL(fileURLWithPath: aliasPath, isDirectory: true)
        let verified = try VoiceASRArtifactVerifier().verifyArtifact(at: source)
        let publisher = fixture.publisher(
            approval: fixture.approval(for: verified),
            verifier: SymlinkAliasAcceptingVerifier(
                alias: alias,
                physicalSource: source
            )
        )

        #expect(
            throws: VoiceASRArtifactError.insecureFilesystemEntry(".")
        ) {
            try publisher.publishLocalArtifact(from: alias)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.layout.voiceASRReleaseDirectory(
                    for: fixture.artifactID
                ).path
            )
        )
    }

    @Test("a decomposed source path is rejected before verification")
    func decomposedSourcePathIsRejectedBeforeVerification() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let source = try fixture.makeArtifactSource()
        let verified = try VoiceASRArtifactVerifier().verifyArtifact(at: source)
        let decomposedPath = source.path + "/e\u{301}"
        let decomposed = URL(
            fileURLWithPath: decomposedPath,
            isDirectory: true
        )
        #expect(decomposed.path.utf8.elementsEqual(decomposedPath.utf8))
        #expect(
            !decomposedPath.utf8.elementsEqual(
                decomposedPath.precomposedStringWithCanonicalMapping.utf8
            )
        )
        let publisher = fixture.publisher(
            approval: fixture.approval(for: verified),
            verifier: UnexpectedSourceVerifier()
        )

        #expect(
            throws: VoiceASRArtifactPublisherError.sourceMustBeLocalDirectory
        ) {
            try publisher.publishLocalArtifact(from: decomposed)
        }
    }

    @Test("trust approval binds digest, adapter, model, license, and source")
    func trustApprovalBindsReleaseMetadata() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let source = try fixture.makeArtifactSource()
        let verified = try VoiceASRArtifactVerifier().verifyArtifact(at: source)
        let approvals = [
            fixture.approval(
                for: verified,
                contentSHA256: String(repeating: "f", count: 64)
            ),
            fixture.approval(
                for: verified,
                adapterVersion: verified.manifest.adapter.version + "-other"
            ),
            fixture.approval(
                for: verified,
                modelRevision: verified.manifest.model.revision + "-other"
            ),
            fixture.approval(for: verified, licenseSPDXID: "MIT"),
            fixture.approval(
                for: verified,
                sourceURL: "https://example.invalid/different-source"
            ),
        ]

        for approval in approvals {
            let publisher = fixture.publisher(approval: approval)
            #expect(
                throws: VoiceASRArtifactPublisherError.untrustedArtifact(
                    fixture.artifactID
                )
            ) {
                try publisher.publishLocalArtifact(from: source)
            }
        }
    }

    @Test("invalid release evidence cannot authorize publication")
    func invalidReleaseEvidenceFailsClosed() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let source = try fixture.makeArtifactSource()
        let verified = try VoiceASRArtifactVerifier().verifyArtifact(at: source)
        let approval = fixture.approval(
            for: verified,
            releaseEvidence: VoiceASRReleaseEvidence(
                sourceReviewID: "source-review-2026-08-21",
                modelRightsReviewID: "model-rights-review-2026-08-21",
                redistributionReviewID:
                    "redistribution-review-2026-08-21",
                qualityReportSHA256: "not-a-sha256"
            )
        )

        #expect(
            throws: VoiceASRArtifactPublisherError.untrustedArtifact(
                fixture.artifactID
            )
        ) {
            try fixture.publisher(approval: approval)
                .publishLocalArtifact(from: source)
        }
    }

    @Test("network URLs are rejected before verification")
    func rejectsNetworkURL() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let publisher = VoiceASRArtifactPublisher(layout: fixture.layout)

        #expect(
            throws: VoiceASRArtifactPublisherError.sourceMustBeLocalDirectory
        ) {
            try publisher.publishLocalArtifact(
                from: URL(string: "https://example.invalid/model")!
            )
        }
    }

    @Test("publishing identical approved content is idempotent")
    func identicalContentIsIdempotent() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let source = try fixture.makeArtifactSource()
        let publisher = try fixture.trustedPublisher(for: source)
        let first = try publisher.publishLocalArtifact(from: source)

        let second = try publisher.publishLocalArtifact(from: source)

        #expect(first.disposition == .published)
        #expect(second.disposition == .alreadyPublished)
        #expect(first.artifact.contentSHA256 == second.artifact.contentSHA256)
        #expect(try fixture.stagingImportEntries().isEmpty)
        let releases = try FileManager.default.contentsOfDirectory(
            atPath: fixture.layout.voiceASRReleasesDirectory.path
        )
        #expect(releases == [fixture.artifactID.rawValue])
    }

    @Test("an existing artifact ID can never be overwritten with new content")
    func immutableReleaseConflictIsRejected() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let firstSource = try fixture.makeArtifactSource()
        let secondSource = try fixture.makeArtifactSource(
            modelRevision: "2026-08-21"
        )
        _ = try fixture.trustedPublisher(for: firstSource)
            .publishLocalArtifact(from: firstSource)
        let secondPublisher = try fixture.trustedPublisher(for: secondSource)

        #expect(
            throws: VoiceASRArtifactPublisherError.immutableReleaseConflict(
                fixture.artifactID
            )
        ) {
            try secondPublisher.publishLocalArtifact(from: secondSource)
        }
        let release = fixture.layout.voiceASRReleaseDirectory(
            for: fixture.artifactID
        )
        let remaining = try VoiceASRArtifactVerifier().verifyArtifact(
            at: release
        )
        #expect(remaining.manifest.model.revision == "2026-08-20")
        #expect(try fixture.stagingImportEntries().isEmpty)
    }

    @Test("activation is optional and occurs only after publication")
    func optionallyActivatesPublishedRelease() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let source = try fixture.makeArtifactSource()
        let publisher = try fixture.trustedPublisher(for: source)

        let result = try publisher.publishLocalArtifact(
            from: source,
            activate: true
        )

        #expect(result.disposition == .published)
        #expect(result.selectorState?.current == fixture.artifactID)
        #expect(result.selectorState?.previous == nil)
        #expect(
            try String(
                contentsOf: fixture.layout.voiceASRCurrentSelector,
                encoding: .utf8
            ) == fixture.artifactID.rawValue + "\n"
        )
    }

    @Test("strict source verification rejects AppleDouble before staging")
    func invalidSourceNeverReachesStaging() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let source = try fixture.makeArtifactSource()
        let appleDouble = source.appendingPathComponent("._metadata")
        try Data("fork".utf8).write(to: appleDouble)
        #expect(chmod(appleDouble.path, mode_t(0o600)) == 0)
        let publisher = VoiceASRArtifactPublisher(layout: fixture.layout)

        #expect(
            throws: VoiceASRArtifactError.insecureFilesystemEntry(
                "._metadata"
            )
        ) {
            try publisher.publishLocalArtifact(from: source)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.layout.voiceASRDirectory.path
            )
        )
    }

    @Test("a failed final verification removes the unique staging tree")
    func failedPublishCleansStaging() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let source = try fixture.makeArtifactSource()
        let verified = try VoiceASRArtifactVerifier().verifyArtifact(at: source)
        let verifier = RejectStagedArtifactVerifier(source: source)
        let publisher = fixture.publisher(
            approval: fixture.approval(for: verified),
            verifier: verifier
        )

        #expect(throws: PublisherVerifierFailure.rejectedStaging) {
            try publisher.publishLocalArtifact(from: source)
        }
        #expect(try fixture.stagingImportEntries().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.layout.voiceASRReleaseDirectory(
                    for: fixture.artifactID
                ).path
            )
        )
    }

    @Test("publisher instances serialize concurrent publication")
    func concurrentPublicationIsSerialized() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let source = try fixture.makeArtifactSource()
        let first = try fixture.trustedPublisher(for: source)
        let second = try fixture.trustedPublisher(for: source)
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let outcomes = PublishOutcomeBox()

        for publisher in [first, second] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                _ = start.wait(timeout: .now() + 2)
                do {
                    outcomes.record(
                        try publisher.publishLocalArtifact(from: source)
                            .disposition
                    )
                } catch {
                    outcomes.record(error: error)
                }
            }
        }
        start.signal()
        start.signal()
        #expect(group.wait(timeout: .now() + 5) == .success)

        let snapshot = outcomes.snapshot()
        #expect(snapshot.errors.isEmpty)
        #expect(
            snapshot.dispositions.sorted(by: { $0.rawValue < $1.rawValue })
                == [.alreadyPublished, .published]
        )
        #expect(try fixture.stagingImportEntries().isEmpty)
        try fixture.expectPrivatePublisherLock()
    }

    @Test("the on-disk lock blocks a second publisher until released")
    func fileLockSerializesPublishers() throws {
        let fixture = try PublisherFixture()
        defer { fixture.remove() }
        let source = try fixture.makeArtifactSource()
        let publisher = try fixture.trustedPublisher(for: source)
        _ = try publisher.publishLocalArtifact(from: source)
        let lockURL = fixture.layout.voiceASRDirectory
            .appendingPathComponent(".publisher.lock")
        let lockDescriptor = open(
            lockURL.path,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        #expect(lockDescriptor >= 0)
        defer { close(lockDescriptor) }
        #expect(flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0)

        let finished = DispatchSemaphore(value: 0)
        let outcomes = PublishOutcomeBox()
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                outcomes.record(
                    try publisher.publishLocalArtifact(from: source)
                        .disposition
                )
            } catch {
                outcomes.record(error: error)
            }
        }
        #expect(finished.wait(timeout: .now() + 0.1) == .timedOut)
        #expect(flock(lockDescriptor, LOCK_UN) == 0)
        #expect(finished.wait(timeout: .now() + 5) == .success)

        let snapshot = outcomes.snapshot()
        #expect(snapshot.errors.isEmpty)
        #expect(snapshot.dispositions == [.alreadyPublished])
    }
}

private final class PublishOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var dispositions: [VoiceASRArtifactPublishDisposition] = []
    private var errors: [String] = []

    func record(_ disposition: VoiceASRArtifactPublishDisposition) {
        lock.lock()
        dispositions.append(disposition)
        lock.unlock()
    }

    func record(error: Error) {
        lock.lock()
        errors.append(String(describing: error))
        lock.unlock()
    }

    func snapshot() -> (
        dispositions: [VoiceASRArtifactPublishDisposition],
        errors: [String]
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (dispositions, errors)
    }
}

private enum PublisherVerifierFailure: Error, Equatable {
    case rejectedStaging
    case unexpectedSourceVerification
}

private struct UnexpectedSourceVerifier: VoiceASRArtifactVerifying {
    func verifyArtifact(
        at artifactDirectory: URL
    ) throws -> VoiceASRVerifiedArtifact {
        throw PublisherVerifierFailure.unexpectedSourceVerification
    }
}

private struct RejectStagedArtifactVerifier: VoiceASRArtifactVerifying {
    let source: URL

    func verifyArtifact(
        at artifactDirectory: URL
    ) throws -> VoiceASRVerifiedArtifact {
        let verified = try VoiceASRArtifactVerifier().verifyArtifact(
            at: artifactDirectory
        )
        guard artifactDirectory == source else {
            throw PublisherVerifierFailure.rejectedStaging
        }
        return verified
    }
}

private struct SymlinkAliasAcceptingVerifier: VoiceASRArtifactVerifying {
    let alias: URL
    let physicalSource: URL

    func verifyArtifact(
        at artifactDirectory: URL
    ) throws -> VoiceASRVerifiedArtifact {
        guard artifactDirectory == alias else {
            return try VoiceASRArtifactVerifier().verifyArtifact(
                at: artifactDirectory
            )
        }
        let verified = try VoiceASRArtifactVerifier().verifyArtifact(
            at: physicalSource
        )
        return VoiceASRVerifiedArtifact(
            artifactDirectory: artifactDirectory,
            manifest: verified.manifest,
            contentSHA256: verified.contentSHA256,
            verifiedFileCount: verified.verifiedFileCount,
            verifiedPayloadBytes: verified.verifiedPayloadBytes
        )
    }
}

private struct PublisherFixture {
    let home: URL
    let layout: RimeAIProductDataLayout
    let artifactID = VoiceASRArtifactID(
        rawValue: "sherpa-zipformer-zh-en-int8-v1"
    )!

    init() throws {
        home = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "rimeai-voice-publisher-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        layout = RimeAIProductDataLayout(homeDirectory: home)
    }

    func makeArtifactSource(
        modelRevision: String = "2026-08-20"
    ) throws -> URL {
        let root = home.appendingPathComponent(
            "import-source-\(UUID().uuidString)",
            isDirectory: true
        )
        let licenses = root.appendingPathComponent(
            "licenses",
            isDirectory: true
        )
        let model = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: licenses,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: model,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let files: [(URL, Data)] = [
            (
                licenses.appendingPathComponent("LICENSE.txt"),
                Data("license\n".utf8)
            ),
            (
                licenses.appendingPathComponent("NOTICE.txt"),
                Data("notice\n".utf8)
            ),
            (
                model.appendingPathComponent("encoder.onnx"),
                Data("encoder\n".utf8)
            ),
            (
                model.appendingPathComponent("decoder.onnx"),
                Data("decoder\n".utf8)
            ),
            (
                model.appendingPathComponent("joiner.onnx"),
                Data("joiner\n".utf8)
            ),
            (
                model.appendingPathComponent("tokens.txt"),
                Data("tokens\n".utf8)
            ),
            (
                model.appendingPathComponent("bpe.vocab"),
                Data("bpe\n".utf8)
            ),
            (
                root.appendingPathComponent("manifest.json"),
                try Self.validManifestData(modelRevision: modelRevision)
            ),
        ]
        for (url, data) in files {
            try data.write(to: url)
            guard chmod(url.path, mode_t(0o600)) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        guard chmod(root.path, mode_t(0o700)) == 0,
              chmod(licenses.path, mode_t(0o700)) == 0,
              chmod(model.path, mode_t(0o700)) == 0
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        return root
    }

    func trustedPublisher(
        for source: URL
    ) throws -> VoiceASRArtifactPublisher {
        let verified = try VoiceASRArtifactVerifier().verifyArtifact(at: source)
        return publisher(approval: approval(for: verified))
    }

    func publisher(
        approval: VoiceASRTrustedArtifactApproval,
        verifier: any VoiceASRArtifactVerifying = VoiceASRArtifactVerifier()
    ) -> VoiceASRArtifactPublisher {
        VoiceASRArtifactPublisher(
            layout: layout,
            trustedCatalog: VoiceASRTrustedArtifactCatalog(
                approvals: [approval]
            ),
            verifier: verifier
        )
    }

    func approval(
        for verified: VoiceASRVerifiedArtifact,
        contentSHA256: String? = nil,
        adapterVersion: String? = nil,
        modelRevision: String? = nil,
        licenseSPDXID: String? = nil,
        sourceURL: String? = nil,
        releaseEvidence: VoiceASRReleaseEvidence? = nil
    ) -> VoiceASRTrustedArtifactApproval {
        let manifest = verified.manifest
        return VoiceASRTrustedArtifactApproval(
            artifactID: manifest.artifactID,
            contentSHA256: contentSHA256 ?? manifest.contentSHA256,
            adapterID: manifest.adapter.id,
            adapterVersion: adapterVersion ?? manifest.adapter.version,
            adapterABIVersion: manifest.adapter.abiVersion,
            modelID: manifest.model.id,
            modelRevision: modelRevision ?? manifest.model.revision,
            modelFormat: manifest.model.format,
            modelQuantization: manifest.model.quantization,
            licenseSPDXID: licenseSPDXID ?? manifest.license.spdxID,
            licensePath: manifest.license.licensePath,
            noticePath: manifest.license.noticePath,
            sourceURL: sourceURL ?? manifest.license.sourceURL,
            redistributionApproved: true,
            releaseEvidence: releaseEvidence ?? VoiceASRReleaseEvidence(
                sourceReviewID: "source-review-2026-08-21",
                modelRightsReviewID: "model-rights-review-2026-08-21",
                redistributionReviewID:
                    "redistribution-review-2026-08-21",
                qualityReportSHA256: String(repeating: "d", count: 64)
            )
        )
    }

    func stagingImportEntries() throws -> [String] {
        guard FileManager.default.fileExists(
            atPath: layout.voiceASRStagingDirectory.path
        ) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            atPath: layout.voiceASRStagingDirectory.path
        ).filter { $0.hasPrefix(".import-") }
    }

    func expectPrivateTree(at root: URL) throws {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        )
        var paths = [root]
        while let entry = enumerator?.nextObject() as? URL {
            paths.append(entry)
        }
        for path in paths {
            var status = stat()
            #expect(lstat(path.path, &status) == 0)
            #expect(status.st_uid == geteuid())
            if status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                #expect(status.st_mode & mode_t(0o777) == mode_t(0o700))
            } else {
                #expect(status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
                #expect(status.st_mode & mode_t(0o777) == mode_t(0o600))
                #expect(status.st_nlink == 1)
            }
        }
    }

    func expectPrivatePublisherLock() throws {
        let url = layout.voiceASRDirectory.appendingPathComponent(
            ".publisher.lock"
        )
        var status = stat()
        #expect(lstat(url.path, &status) == 0)
        #expect(status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        #expect(status.st_uid == geteuid())
        #expect(status.st_mode & mode_t(0o777) == mode_t(0o600))
        #expect(status.st_nlink == 1)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }

    private static func validManifestData(
        modelRevision: String
    ) throws -> Data {
        let placeholder = manifestJSON(
            contentSHA256: String(repeating: "0", count: 64),
            modelRevision: modelRevision
        )
        let manifest = try VoiceASRArtifactManifest.decodeStrict(
            Data(placeholder.utf8),
            verifyContentDigest: false
        )
        return Data(
            manifestJSON(
                contentSHA256: manifest.calculatedContentSHA256,
                modelRevision: modelRevision
            ).utf8
        )
    }

    private static func manifestJSON(
        contentSHA256: String,
        modelRevision: String
    ) -> String {
        """
        {
          "schema_version": 2,
          "artifact_type": "rimeai.voice-asr-model",
          "asset_management": "product-managed",
          "artifact_id": "sherpa-zipformer-zh-en-int8-v1",
          "adapter": {
            "id": "sherpa-onnx",
            "version": "1.13.6",
            "abi_version": 1
          },
          "model": {
            "id": "icefall-zipformer-zh-en",
            "revision": "\(modelRevision)",
            "format": "onnx",
            "quantization": "int8"
          },
          "target": {
            "os": "macos",
            "architecture": "arm64",
            "minimum_os_version": "14.0"
          },
          "audio": {
            "sample_rate_hz": 16000,
            "channel_count": 1,
            "sample_format": "float32le",
            "frame_duration_ms": 20
          },
          "runtime": {
            "kind": "sherpa-onnx-online-transducer",
            "encoder_path": "model/encoder.onnx",
            "decoder_path": "model/decoder.onnx",
            "joiner_path": "model/joiner.onnx",
            "tokens_path": "model/tokens.txt",
            "bpe_vocab_path": "model/bpe.vocab",
            "modeling_unit": "cjkchar+bpe",
            "model_type": "zipformer",
            "feature_dimension": 80,
            "provider": "cpu",
            "num_threads": 2,
            "decoding_method": "modified_beam_search",
            "max_active_paths": 4,
            "endpoint": {
              "enabled": true,
              "rule1_min_trailing_silence_ms": 2400,
              "rule2_min_trailing_silence_ms": 1200,
              "rule3_min_utterance_ms": 30000
            },
            "hotword_probe_phrase": "RimeAI",
            "hotwords_score_milli": 1500,
            "blank_penalty_milli": 0
          },
          "network_policy": "offline",
          "locales": ["en-US", "zh-CN"],
          "capabilities": {
            "streaming": true,
            "partial_results": true,
            "endpoint_detection": true,
            "hotword_mode": "bounded-phrase-list",
            "maximum_hotwords": 32,
            "maximum_alternatives": 1
          },
          "license": {
            "spdx_id": "Apache-2.0",
            "license_path": "licenses/LICENSE.txt",
            "notice_path": "licenses/NOTICE.txt",
            "source_url": "https://example.invalid/model-card"
          },
          "inventory": [
            {
              "path": "licenses/LICENSE.txt",
              "bytes": 8,
              "sha256": "c0c56958ef8be5c1979366896b7e0c7206949a5aa2b23f51429c7f56b10990d3"
            },
            {
              "path": "licenses/NOTICE.txt",
              "bytes": 7,
              "sha256": "5de37b4c620461f2b695f1cf6b8ee36e7d025da8334a3693c4ed9aa48a5c7d6a"
            },
            {
              "path": "model/bpe.vocab",
              "bytes": 4,
              "sha256": "9b40808e3407521a22ecb18c10da26933cbcd86dfd2ad844ce69fe961025e4f3"
            },
            {
              "path": "model/decoder.onnx",
              "bytes": 8,
              "sha256": "eacbeef293be61f2a85d929cadb4cbb5248c8b8a1478b3d4b3180ea365d5e687"
            },
            {
              "path": "model/encoder.onnx",
              "bytes": 8,
              "sha256": "b1c4c05f286afb2531d4c847c4ca1e56260fc61281b7a04d50e09d09ab7a682b"
            },
            {
              "path": "model/joiner.onnx",
              "bytes": 7,
              "sha256": "8e7fda7c0958b448ed92d9b9bbf8f04f6423097f39eb007ca5c56f4a9657c340"
            },
            {
              "path": "model/tokens.txt",
              "bytes": 7,
              "sha256": "2de8bce5133f08dc3ebb75abcb1ef6c0951800ee3ae8ca06fcf58395d1244218"
            }
          ],
          "content_sha256": "\(contentSHA256)"
        }
        """
    }
}
