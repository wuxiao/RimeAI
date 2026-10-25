import Darwin
import Foundation
import RimeAISherpaOnnxSafeC
import SherpaOnnxC
import Testing
@_spi(RimeAIInternal) import RimeAIVoiceArtifactCore
@testable import RimeAIInputCore
@testable import RimeAIVoiceHelperEngine

@Suite(.serialized)
struct SherpaOnnxProductBackendTests {
    @Test
    func linkedRuntimeIdentityMatchesThePinnedBinaryContract() throws {
        let version = try #require(SherpaOnnxGetVersionStr())
        let revision = try #require(SherpaOnnxGetGitSha1())
        let onnxRuntime = try #require(
            SherpaOnnxGetOnnxruntimeVersionStr()
        )

        #expect(String(cString: version) == "1.13.6")
        #expect(String(cString: revision) == "1cb484af-rimeai-buffer")
        #expect(String(cString: onnxRuntime) == "1.27.1")
        #expect(SherpaOnnxProductBackendLoader.adapterVersion == "1.13.6")
        #expect(
            SherpaOnnxProductBackendLoader.embeddedSherpaGitRevision
                == "1cb484af-rimeai-buffer"
        )
        #expect(
            SherpaOnnxProductBackendLoader.onnxRuntimeVersion == "1.27.1"
        )
    }

    @Test("native model exceptions become typed Swift failures")
    func invalidNativeModelDoesNotEscapeTheCXXBoundary() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }

        #expect(
            throws: SherpaOnnxProductBackendError
                .recognizerInitializationFailed
        ) {
            _ = try fixture.load(using: SherpaOnnxProductBackendLoader())
        }
    }

    @Test("native boundary rejects invalid arguments and clears outputs")
    func nativeBoundaryClearsFailedOutputs() {
        var recognizer = OpaquePointer(bitPattern: 1)
        #expect(
            RimeAISherpaOnnxCreateOnlineRecognizer(
                nil,
                &recognizer
            ) == RimeAISherpaOnnxStatusInvalidArgument
        )
        #expect(recognizer == nil)

        var stream = OpaquePointer(bitPattern: 1)
        #expect(
            RimeAISherpaOnnxCreateOnlineStream(nil, &stream)
                == RimeAISherpaOnnxStatusInvalidArgument
        )
        #expect(stream == nil)

        var result = UnsafePointer<SherpaOnnxOnlineRecognizerResult>(
            bitPattern: 1
        )
        #expect(
            RimeAISherpaOnnxGetOnlineStreamResult(
                nil,
                nil,
                &result
            ) == RimeAISherpaOnnxStatusInvalidArgument
        )
        #expect(result == nil)

        var ready: Int32 = 7
        #expect(
            RimeAISherpaOnnxIsOnlineStreamReady(nil, nil, &ready)
                == RimeAISherpaOnnxStatusInvalidArgument
        )
        #expect(ready == 0)
    }

    @Test
    func loadMapsTheManifestAndBindsTheProbeToTheLeaseGeneration() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let recognizer = SherpaBackendFakeRecognizer()
        let runtime = SherpaBackendFakeRuntime(recognizer: recognizer)
        let loader = SherpaOnnxProductBackendLoader(runtime: runtime)

        let (loaded, generation) = try fixture.load(using: loader)
        let configuration = try #require(runtime.capturedConfiguration)
        let descriptorPaths = [
            configuration.encoderPath,
            configuration.decoderPath,
            configuration.joinerPath,
            configuration.tokensPath,
            configuration.bpeVocabularyPath,
        ]

        let snapshotPrefix = fixture.artifactDirectory
            .deletingLastPathComponent().path
            + "/.rimeai-sherpa-runtime-"
        #expect(
            descriptorPaths.allSatisfy {
                $0.hasPrefix(snapshotPrefix) && !$0.hasPrefix("/dev/fd/")
            }
        )
        #expect(Set(descriptorPaths).count == descriptorPaths.count)
        #expect(descriptorPaths.allSatisfy { path in
            errno = 0
            return Darwin.access(path, F_OK) == -1 && errno == ENOENT
        })
        #expect(
            configuration
                == SherpaOnnxRecognizerConfiguration(
                    encoderPath: descriptorPaths[0],
                    decoderPath: descriptorPaths[1],
                    joinerPath: descriptorPaths[2],
                    tokensPath: descriptorPaths[3],
                    bpeVocabularyPath: descriptorPaths[4],
                    sampleRateHertz: 16_000,
                    featureDimension: 80,
                    numberOfThreads: 2,
                    provider: "cpu",
                    modelType: "zipformer",
                    modelingUnit: "cjkchar+bpe",
                    decodingMethod: "modified_beam_search",
                    maximumActivePaths: 4,
                    endpointEnabled: true,
                    rule1MinimumTrailingSilenceSeconds: 2.4,
                    rule2MinimumTrailingSilenceSeconds: 1.2,
                    rule3MinimumUtteranceSeconds: 30,
                    hotwordsScore: 1.5,
                    blankPenalty: 0
                )
        )
        #expect(runtime.capturedModelContents == [
            Data("encoder\n".utf8),
            Data("decoder\n".utf8),
            Data("joiner\n".utf8),
            Data("tokens\n".utf8),
            Data("bpe\n".utf8),
        ])
        #expect(runtime.reopenedModelContents == runtime.capturedModelContents)
        for file in fixture.runtimeModelFiles {
            var status = stat()
            #expect(lstat(file.path, &status) == 0)
            #expect(status.st_nlink == 1)
        }
        #expect(runtime.identityCount == 1)
        #expect(runtime.makeRecognizerCount == 1)
        #expect(recognizer.startedHotwords.count == 2)
        #expect(recognizer.startedHotwords[0].count == 32)
        #expect(recognizer.startedHotwords[0].allSatisfy { $0 == "RimeAI" })
        #expect(recognizer.startedHotwords[1].isEmpty)
        #expect(recognizer.endpointResetCount == 0)
        #expect(recognizer.finishCount == 2)
        #expect(recognizer.cancelCount == 2)

        #expect(loaded.recognizerDriver.artifactGeneration == generation)
        #expect(loaded.loadProbe.artifactGeneration == generation)
        #expect(loaded.loadProbe.adapterID == "sherpa-onnx")
        #expect(loaded.loadProbe.adapterVersion == "1.13.6")
        #expect(loaded.loadProbe.adapterABIVersion == 1)
        #expect(
            loaded.loadProbe.runtimeKind
                == .sherpaOnnxOnlineTransducer
        )
        #expect(loaded.loadProbe.supportedLocales == ["en-US", "zh-CN"])
        #expect(loaded.loadProbe.supportsStreaming)
        #expect(loaded.loadProbe.supportsPartialResults)
        #expect(loaded.loadProbe.supportsEndpointDetection)
        #expect(loaded.loadProbe.maximumHotwords == 32)
        #expect(loaded.loadProbe.maximumAlternatives == 1)
        #expect(loaded.loadProbe.sampleRateHertz == 16_000)
        #expect(loaded.loadProbe.channelCount == 1)
        #expect(loaded.loadProbe.bitsPerChannel == 32)
    }

    @Test("paraformer configuration maps encoder, decoder and tokens only")
    func test_paraformerConfigBuilds() throws {
        let fixture = try SherpaBackendStoreFixture(cohort: .paraformer)
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(runtime: runtime)

        let (loaded, _) = try fixture.load(using: loader)
        let configuration = try #require(runtime.capturedConfiguration)
        let snapshotPrefix = fixture.artifactDirectory
            .deletingLastPathComponent().path
            + "/.rimeai-sherpa-runtime-"

        #expect(configuration.modelType == "paraformer")
        #expect(configuration.modelingUnit == "cjkchar")
        #expect(configuration.decodingMethod == "greedy_search")
        #expect(configuration.hotwordsScore == 0)
        #expect(configuration.joinerPath.isEmpty)
        #expect(configuration.bpeVocabularyPath.isEmpty)
        let descriptorPaths = [
            configuration.encoderPath,
            configuration.decoderPath,
            configuration.tokensPath,
        ]
        #expect(
            descriptorPaths.allSatisfy {
                $0.hasPrefix(snapshotPrefix) && !$0.hasPrefix("/dev/fd/")
            }
        )
        #expect(Set(descriptorPaths).count == descriptorPaths.count)
        #expect(loaded.loadProbe.runtimeKind == .sherpaOnnxOnlineParaformer)
        #expect(loaded.loadProbe.maximumHotwords == 0)
    }

    @Test("paraformer snapshot binds exactly three model files")
    func test_paraformerSnapshotUsesThreeFiles() throws {
        let fixture = try SherpaBackendStoreFixture(cohort: .paraformer)
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(runtime: runtime)

        _ = try fixture.load(using: loader)

        #expect(runtime.capturedModelContents == [
            Data("encoder\n".utf8),
            Data("decoder\n".utf8),
            Data("tokens\n".utf8),
        ])
        #expect(runtime.reopenedModelContents == runtime.capturedModelContents)
        for file in fixture.runtimeModelFiles {
            var status = stat()
            #expect(lstat(file.path, &status) == 0)
            #expect(status.st_nlink == 1)
        }
    }

    @Test("paraformer load probe skips the non-empty hotword probe")
    func test_paraformerLoadProbeSkipsHotwordProbe() throws {
        let fixture = try SherpaBackendStoreFixture(cohort: .paraformer)
        defer { fixture.remove() }
        let recognizer = SherpaBackendFakeRecognizer()
        let runtime = SherpaBackendFakeRuntime(recognizer: recognizer)
        let loader = SherpaOnnxProductBackendLoader(runtime: runtime)

        _ = try fixture.load(using: loader)

        #expect(recognizer.startedHotwords.count == 1)
        #expect(recognizer.startedHotwords[0].isEmpty)
        #expect(recognizer.finishCount == 1)
        #expect(recognizer.cancelCount == 1)
    }

    @Test("paraformer engine rejects a non-empty hotword snapshot")
    func test_paraformerRejectsHotwordSnapshot() throws {
        let fixture = try SherpaBackendStoreFixture(cohort: .paraformer)
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(runtime: runtime)

        let (loaded, _) = try fixture.load(using: loader)

        #expect(
            throws: SherpaOnnxProductBackendError.hotwordsUnsupported
        ) {
            try loaded.recognizerDriver.startSession(hotwords: ["RIMEAI"])
        }
    }

    @Test("clone failure uses the descriptor-copy fallback")
    func cloneFailureUsesDescriptorCopyFallback() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let expectedContents = try fixture.runtimeModelFiles.map {
            try Data(contentsOf: $0)
        }
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(
            runtime: runtime,
            snapshotOperations: SherpaOnnxRuntimeSnapshotOperations(
                cloneFile: { _, _, _ in
                    errno = ENOTSUP
                    return -1
                }
            )
        )

        _ = try fixture.load(using: loader)

        #expect(runtime.capturedModelContents == expectedContents)
        #expect(runtime.reopenedModelContents == expectedContents)
        let parent = fixture.artifactDirectory.deletingLastPathComponent()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .allSatisfy { !$0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test("pread failure fails closed without snapshot residue")
    func preadFailureFailsClosedWithoutSnapshotResidue() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(
            runtime: runtime,
            snapshotOperations: SherpaOnnxRuntimeSnapshotOperations(
                cloneFile: { _, _, _ in
                    errno = ENOTSUP
                    return -1
                },
                readFile: { _, _, _, _ in
                    errno = EIO
                    return -1
                }
            )
        )

        #expect(
            throws: SherpaOnnxProductBackendError.unsafeModelPath(
                fixture.artifactDirectory.path
            )
        ) {
            _ = try fixture.load(using: loader)
        }
        #expect(runtime.makeRecognizerCount == 0)
        let parent = fixture.artifactDirectory.deletingLastPathComponent()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .allSatisfy { !$0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test("premature pread EOF fails closed without snapshot residue")
    func prematurePreadEOFFailsClosedWithoutSnapshotResidue() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let readCalls = SherpaBackendLockedCallCounter()
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(
            runtime: runtime,
            snapshotOperations: SherpaOnnxRuntimeSnapshotOperations(
                cloneFile: { _, _, _ in
                    errno = ENOTSUP
                    return -1
                },
                readFile: { descriptor, buffer, count, offset in
                    guard readCalls.next() == 0 else { return 0 }
                    return Darwin.pread(
                        descriptor,
                        buffer,
                        min(count, 1),
                        offset
                    )
                }
            )
        )

        #expect(
            throws: SherpaOnnxProductBackendError.unsafeModelPath(
                fixture.artifactDirectory.path
            )
        ) {
            _ = try fixture.load(using: loader)
        }
        #expect(readCalls.count == 2)
        #expect(runtime.makeRecognizerCount == 0)
        let parent = fixture.artifactDirectory.deletingLastPathComponent()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .allSatisfy { !$0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test("partial write then failure leaves no snapshot residue")
    func partialWriteThenFailureLeavesNoSnapshotResidue() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let writeCalls = SherpaBackendLockedCallCounter()
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(
            runtime: runtime,
            snapshotOperations: SherpaOnnxRuntimeSnapshotOperations(
                cloneFile: { _, _, _ in
                    errno = ENOTSUP
                    return -1
                },
                writeFile: { descriptor, buffer, count in
                    guard writeCalls.next() == 0 else {
                        errno = EIO
                        return -1
                    }
                    return Darwin.write(
                        descriptor,
                        buffer,
                        min(count, 1)
                    )
                }
            )
        )

        #expect(
            throws: SherpaOnnxProductBackendError.unsafeModelPath(
                fixture.artifactDirectory.path
            )
        ) {
            _ = try fixture.load(using: loader)
        }
        #expect(writeCalls.count == 2)
        #expect(runtime.makeRecognizerCount == 0)
        let parent = fixture.artifactDirectory.deletingLastPathComponent()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .allSatisfy { !$0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test("fsync failure leaves no snapshot residue")
    func fsyncFailureLeavesNoSnapshotResidue() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(
            runtime: runtime,
            snapshotOperations: SherpaOnnxRuntimeSnapshotOperations(
                cloneFile: { _, _, _ in
                    errno = ENOTSUP
                    return -1
                },
                syncFile: { _ in
                    errno = EIO
                    return -1
                }
            )
        )

        #expect(
            throws: SherpaOnnxProductBackendError.unsafeModelPath(
                fixture.artifactDirectory.path
            )
        ) {
            _ = try fixture.load(using: loader)
        }
        #expect(runtime.makeRecognizerCount == 0)
        let parent = fixture.artifactDirectory.deletingLastPathComponent()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .allSatisfy { !$0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test("fchmod failure leaves no snapshot residue")
    func fchmodFailureLeavesNoSnapshotResidue() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(
            runtime: runtime,
            snapshotOperations: SherpaOnnxRuntimeSnapshotOperations(
                cloneFile: { _, _, _ in
                    errno = ENOTSUP
                    return -1
                },
                chmodFile: { _, _ in
                    errno = EIO
                    return -1
                }
            )
        )

        #expect(
            throws: SherpaOnnxProductBackendError.unsafeModelPath(
                fixture.artifactDirectory.path
            )
        ) {
            _ = try fixture.load(using: loader)
        }
        #expect(runtime.makeRecognizerCount == 0)
        let parent = fixture.artifactDirectory.deletingLastPathComponent()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .allSatisfy { !$0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test("post-load snapshot rebind is rejected without deleting replacement")
    func snapshotNamespaceDriftFailsClosedAndCleansOnlyOwnedInodes() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let expectedContents = try fixture.runtimeModelFiles.map {
            try Data(contentsOf: $0)
        }
        let runtime = SherpaBackendFakeRuntime(
            afterModelReads: { configuration in
                let manager = FileManager.default
                let snapshot = URL(
                    fileURLWithPath: configuration.encoderPath
                ).deletingLastPathComponent()
                let moved = snapshot.appendingPathExtension("moved")
                try manager.moveItem(at: snapshot, to: moved)
                try manager.createDirectory(
                    at: snapshot,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o500]
                )
                #expect(chmod(snapshot.path, mode_t(0o500)) == 0)
            }
        )
        var rejectedPath: String?

        do {
            _ = try fixture.load(
                using: SherpaOnnxProductBackendLoader(runtime: runtime)
            )
            Issue.record("expected snapshot namespace rebind rejection")
        } catch SherpaOnnxProductBackendError.unsafeModelPath(let path) {
            rejectedPath = path
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let path = try #require(rejectedPath)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(
            FileManager.default.fileExists(atPath: path + ".moved")
        )
        #expect(runtime.capturedModelContents == expectedContents)
        #expect(runtime.reopenedModelContents == expectedContents)
    }

    @Test
    func sherpaVersionMismatchFailsBeforeRecognizerConstruction() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime(
            identity: SherpaOnnxRuntimeIdentity(
                sherpaVersion: "1.13.5",
                sherpaGitRevision: "1cb484af-rimeai-buffer",
                onnxRuntimeVersion: "1.27.1"
            )
        )

        #expect(
            throws: SherpaOnnxProductBackendError.runtimeVersionMismatch(
                expected: "1.13.6",
                actual: "1.13.5"
            )
        ) {
            _ = try fixture.load(
                using: SherpaOnnxProductBackendLoader(runtime: runtime)
            )
        }
        #expect(runtime.makeRecognizerCount == 0)
    }

    @Test
    func sherpaRevisionMismatchFailsBeforeRecognizerConstruction() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime(
            identity: SherpaOnnxRuntimeIdentity(
                sherpaVersion: "1.13.6",
                sherpaGitRevision: "wrong-revision",
                onnxRuntimeVersion: "1.27.1"
            )
        )

        #expect(
            throws: SherpaOnnxProductBackendError.runtimeRevisionMismatch(
                expected: "1cb484af-rimeai-buffer",
                actual: "wrong-revision"
            )
        ) {
            _ = try fixture.load(
                using: SherpaOnnxProductBackendLoader(runtime: runtime)
            )
        }
        #expect(runtime.makeRecognizerCount == 0)
    }

    @Test
    func onnxRuntimeVersionMismatchFailsBeforeRecognizerConstruction() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime(
            identity: SherpaOnnxRuntimeIdentity(
                sherpaVersion: "1.13.6",
                sherpaGitRevision: "1cb484af-rimeai-buffer",
                onnxRuntimeVersion: "1.27.0"
            )
        )

        #expect(
            throws: SherpaOnnxProductBackendError.onnxRuntimeVersionMismatch(
                expected: "1.27.1",
                actual: "1.27.0"
            )
        ) {
            _ = try fixture.load(
                using: SherpaOnnxProductBackendLoader(runtime: runtime)
            )
        }
        #expect(runtime.makeRecognizerCount == 0)
    }

    @Test
    func missingModelFileFailsClosedBeforeRecognizerConstruction() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let missing = fixture.path("model/encoder.onnx")
        #expect(missing.path.hasPrefix("/private/tmp/"))
        try FileManager.default.removeItem(at: missing)
        let runtime = SherpaBackendFakeRuntime()

        #expect(
            throws: SherpaOnnxProductBackendError.modelFileUnavailable(
                missing.path
            )
        ) {
            _ = try fixture.load(
                using: SherpaOnnxProductBackendLoader(runtime: runtime)
            )
        }
        #expect(runtime.makeRecognizerCount == 0)
    }

    @Test("artifact paths reject authority-granting ancestor ACLs")
    func artifactAncestorExtendedACLFailsClosed() throws {
        let outer = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ).appendingPathComponent(
            "rimeai-sherpa-ancestor-acl-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outer,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? removeExtendedACL(from: outer.path)
            try? FileManager.default.removeItem(at: outer)
        }
        let fixture = try SherpaBackendStoreFixture(homeParent: outer)
        defer { fixture.remove() }
        try addAuthorityGrantingACL(to: outer.path)
        let runtime = SherpaBackendFakeRuntime()

        #expect(
            throws: SherpaOnnxProductBackendError.unsafeModelPath(
                fixture.artifactDirectory.path
            )
        ) {
            _ = try fixture.load(
                using: SherpaOnnxProductBackendLoader(runtime: runtime)
            )
        }
        #expect(runtime.makeRecognizerCount == 0)
    }

    @Test("deny-only ancestor ACLs preserve standard macOS home paths")
    func denyOnlyArtifactAncestorACLIsAccepted() throws {
        let outer = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ).appendingPathComponent(
            "rimeai-sherpa-ancestor-deny-acl-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outer,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? removeExtendedACL(from: outer.path)
            try? FileManager.default.removeItem(at: outer)
        }
        try addDenyOnlyACL(to: outer.path)
        let fixture = try SherpaBackendStoreFixture(homeParent: outer)
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime()

        _ = try fixture.load(
            using: SherpaOnnxProductBackendLoader(runtime: runtime)
        )
        #expect(runtime.makeRecognizerCount == 1)
    }

    @Test("artifact paths reject non-sticky renameable ancestors")
    func artifactRenameableAncestorFailsClosed() throws {
        let outer = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ).appendingPathComponent(
            "rimeai-sherpa-ancestor-mode-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outer,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: outer) }
        let fixture = try SherpaBackendStoreFixture(homeParent: outer)
        defer { fixture.remove() }
        #expect(chmod(outer.path, mode_t(0o777)) == 0)
        let runtime = SherpaBackendFakeRuntime()

        #expect(
            throws: SherpaOnnxProductBackendError.unsafeModelPath(
                fixture.artifactDirectory.path
            )
        ) {
            _ = try fixture.load(
                using: SherpaOnnxProductBackendLoader(runtime: runtime)
            )
        }
        #expect(runtime.makeRecognizerCount == 0)
    }

    @Test("snapshot parents reject ACLs added after store verification")
    func snapshotParentExtendedACLFailsClosedWithoutResidue() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let parent = fixture.artifactDirectory.deletingLastPathComponent()
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(runtime: runtime)

        try fixture.store.withVerifiedCurrentArtifact { lease in
            try addAuthorityGrantingACL(to: parent.path)
            defer { try? removeExtendedACL(from: parent.path) }
            #expect(
                throws: SherpaOnnxProductBackendError.unsafeModelPath(
                    fixture.artifactDirectory.path
                )
            ) {
                _ = try loader.load(lease: lease)
            }
        }
        #expect(runtime.makeRecognizerCount == 0)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .allSatisfy { !$0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test("runtime snapshot files reject post-materialization ACLs")
    func runtimeSnapshotExtendedACLFailsClosed() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime(
            afterModelReads: { configuration in
                try addExtendedACL(to: configuration.encoderPath)
            }
        )

        do {
            _ = try fixture.load(
                using: SherpaOnnxProductBackendLoader(runtime: runtime)
            )
            Issue.record("expected runtime snapshot ACL rejection")
        } catch SherpaOnnxProductBackendError.unsafeModelPath(let path) {
            #expect(path.contains("/.rimeai-sherpa-runtime-"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        let parent = fixture.artifactDirectory.deletingLastPathComponent()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .allSatisfy { !$0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test("runtime snapshot directories reject post-materialization ACLs")
    func runtimeSnapshotDirectoryExtendedACLFailsClosed() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime(
            afterModelReads: { configuration in
                let snapshotDirectory = URL(
                    fileURLWithPath: configuration.encoderPath
                ).deletingLastPathComponent()
                try addExtendedACL(to: snapshotDirectory.path)
            }
        )

        do {
            _ = try fixture.load(
                using: SherpaOnnxProductBackendLoader(runtime: runtime)
            )
            Issue.record("expected runtime snapshot directory ACL rejection")
        } catch SherpaOnnxProductBackendError.unsafeModelPath(let path) {
            #expect(path.contains("/.rimeai-sherpa-runtime-"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        let parent = fixture.artifactDirectory.deletingLastPathComponent()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .allSatisfy { !$0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test("materialized snapshot reopen failure removes the created entry")
    func materializedSnapshotReopenFailureLeavesNoResidue() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let originalContents = try fixture.runtimeModelFiles.map {
            try Data(contentsOf: $0)
        }
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(
            runtime: runtime,
            snapshotOperations: SherpaOnnxRuntimeSnapshotOperations(
                openMaterializedFile: { _, _ in
                    errno = EMFILE
                    return -1
                }
            )
        )

        #expect(
            throws: SherpaOnnxProductBackendError.unsafeModelPath(
                fixture.artifactDirectory.path
            )
        ) {
            _ = try fixture.load(using: loader)
        }
        #expect(runtime.makeRecognizerCount == 0)
        let parent = fixture.artifactDirectory.deletingLastPathComponent()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .allSatisfy { !$0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
        #expect(
            try fixture.runtimeModelFiles.map { try Data(contentsOf: $0) }
                == originalContents
        )
        for file in fixture.runtimeModelFiles {
            var status = stat()
            #expect(lstat(file.path, &status) == 0)
            #expect(status.st_nlink == 1)
        }
    }

    @Test("materialized snapshot directory open failure leaves no residue")
    func materializedSnapshotDirectoryOpenFailureLeavesNoResidue() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(
            runtime: runtime,
            snapshotOperations: SherpaOnnxRuntimeSnapshotOperations(
                openMaterializedDirectory: { _, _ in
                    errno = EMFILE
                    return -1
                }
            )
        )

        #expect(
            throws: SherpaOnnxProductBackendError.unsafeModelPath(
                fixture.artifactDirectory.path
            )
        ) {
            _ = try fixture.load(using: loader)
        }
        #expect(runtime.makeRecognizerCount == 0)
        let parent = fixture.artifactDirectory.deletingLastPathComponent()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .allSatisfy { !$0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test("directory binding failure before inode token leaves no residue")
    func directoryBindingBeforeInodeTokenFailureLeavesNoResidue() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(
            runtime: runtime,
            snapshotOperations: SherpaOnnxRuntimeSnapshotOperations(
                statCreatedDirectory: { _, _, _ in
                    errno = EIO
                    return -1
                }
            )
        )

        #expect(
            throws: SherpaOnnxProductBackendError.unsafeModelPath(
                fixture.artifactDirectory.path
            )
        ) {
            _ = try fixture.load(using: loader)
        }
        #expect(runtime.makeRecognizerCount == 0)
        let parent = fixture.artifactDirectory.deletingLastPathComponent()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .allSatisfy { !$0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test("file binding failure before inode token leaves no residue")
    func fileBindingBeforeInodeTokenFailureLeavesNoResidue() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime()
        let loader = SherpaOnnxProductBackendLoader(
            runtime: runtime,
            snapshotOperations: SherpaOnnxRuntimeSnapshotOperations(
                cloneFile: { _, _, _ in
                    errno = ENOTSUP
                    return -1
                },
                statCreatedFile: { _, _ in
                    errno = EIO
                    return -1
                }
            )
        )

        #expect(
            throws: SherpaOnnxProductBackendError.unsafeModelPath(
                fixture.artifactDirectory.path
            )
        ) {
            _ = try fixture.load(using: loader)
        }
        #expect(runtime.makeRecognizerCount == 0)
        let parent = fixture.artifactDirectory.deletingLastPathComponent()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .allSatisfy { !$0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test
    func symlinkedAncestorAliasCannotBecomeArtifactPathAuthority() throws {
        let fixture = try SherpaBackendStoreFixture(
            homeParent: URL(
                fileURLWithPath: "/tmp",
                isDirectory: true
            )
        )
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime()

        #expect(fixture.artifactDirectory.path.hasPrefix("/tmp/"))
        #expect(
            throws: SherpaOnnxProductBackendError.unsafeModelPath(
                fixture.artifactDirectory.path
            )
        ) {
            _ = try fixture.load(
                using: SherpaOnnxProductBackendLoader(runtime: runtime)
            )
        }
        #expect(runtime.makeRecognizerCount == 0)
    }

    @Test
    func writableModelFileFailsClosedBeforeRecognizerConstruction() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let insecure = fixture.path("model/decoder.onnx")
        #expect(chmod(insecure.path, mode_t(0o622)) == 0)
        let runtime = SherpaBackendFakeRuntime()

        #expect(
            throws: SherpaOnnxProductBackendError.modelFileUnavailable(
                insecure.path
            )
        ) {
            _ = try fixture.load(
                using: SherpaOnnxProductBackendLoader(runtime: runtime)
            )
        }
        #expect(runtime.makeRecognizerCount == 0)
    }

    @Test
    func changedModelBytesFailClosedBeforeRecognizerConstruction() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let changed = fixture.path("model/encoder.onnx")
        try Data("mutated\n".utf8).write(to: changed, options: .atomic)
        #expect(chmod(changed.path, mode_t(0o600)) == 0)
        let runtime = SherpaBackendFakeRuntime()

        #expect(
            throws: SherpaOnnxProductBackendError.modelFileUnavailable(
                changed.path
            )
        ) {
            _ = try fixture.load(
                using: SherpaOnnxProductBackendLoader(runtime: runtime)
            )
        }
        #expect(runtime.makeRecognizerCount == 0)
    }

    @Test
    func recognizerProbeFailureIsClassifiedAndCancelsTheDriver() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let recognizer = SherpaBackendFakeRecognizer(
            finishError: SherpaBackendTestError.probeFailed
        )
        let runtime = SherpaBackendFakeRuntime(recognizer: recognizer)

        #expect(throws: VoiceProductBackendLoadError.emptyStreamProbeFailed) {
            _ = try fixture.load(
                using: SherpaOnnxProductBackendLoader(runtime: runtime)
            )
        }
        #expect(runtime.makeRecognizerCount == 1)
        #expect(recognizer.startedHotwords.count == 1)
        #expect(recognizer.startedHotwords[0].count == 32)
        #expect(recognizer.startedHotwords[0].allSatisfy { $0 == "RimeAI" })
        #expect(recognizer.finishCount == 1)
        #expect(recognizer.cancelCount == 1)
    }
}
