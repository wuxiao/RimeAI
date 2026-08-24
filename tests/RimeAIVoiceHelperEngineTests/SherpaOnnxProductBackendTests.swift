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
        #expect(String(cString: revision) == "0fdffb3e")
        #expect(String(cString: onnxRuntime) == "1.27.1")
        #expect(SherpaOnnxProductBackendLoader.adapterVersion == "1.13.6")
        #expect(
            SherpaOnnxProductBackendLoader.embeddedSherpaGitRevision
                == "0fdffb3e"
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
                sherpaGitRevision: "0fdffb3e",
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
                expected: "0fdffb3e",
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
                sherpaGitRevision: "0fdffb3e",
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

private enum SherpaBackendTestError: Error {
    case probeFailed
    case modelReadFailed
}

private final class SherpaBackendLockedCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class SherpaBackendFakeRuntime:
    SherpaOnnxRuntimeLoading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let runtimeIdentity: SherpaOnnxRuntimeIdentity
    private let recognizer: SherpaBackendFakeRecognizer
    private var identityCountStorage = 0
    private var makeRecognizerCountStorage = 0
    private var capturedConfigurationStorage:
        SherpaOnnxRecognizerConfiguration?
    private var capturedModelContentsStorage: [Data] = []
    private var reopenedModelContentsStorage: [Data] = []
    private let afterModelReads:
        (@Sendable (SherpaOnnxRecognizerConfiguration) throws -> Void)?

    init(
        identity: SherpaOnnxRuntimeIdentity = SherpaOnnxRuntimeIdentity(
            sherpaVersion: "1.13.6",
            sherpaGitRevision: "0fdffb3e",
            onnxRuntimeVersion: "1.27.1"
        ),
        recognizer: SherpaBackendFakeRecognizer =
            SherpaBackendFakeRecognizer(),
        afterModelReads:
            (@Sendable (SherpaOnnxRecognizerConfiguration) throws -> Void)? =
                nil
    ) {
        runtimeIdentity = identity
        self.recognizer = recognizer
        self.afterModelReads = afterModelReads
    }

    func identity() throws -> SherpaOnnxRuntimeIdentity {
        lock.lock()
        identityCountStorage += 1
        lock.unlock()
        return runtimeIdentity
    }

    func makeRecognizer(
        configuration: SherpaOnnxRecognizerConfiguration
    ) throws -> any SherpaOnnxRecognizerRunning {
        let paths = [
            configuration.encoderPath,
            configuration.decoderPath,
            configuration.joinerPath,
            configuration.tokensPath,
            configuration.bpeVocabularyPath,
        ]
        let contents = try paths.map(Self.readAll)
        let reopenedContents = try paths.map(Self.readAll)
        try afterModelReads?(configuration)
        lock.lock()
        makeRecognizerCountStorage += 1
        capturedConfigurationStorage = configuration
        capturedModelContentsStorage = contents
        reopenedModelContentsStorage = reopenedContents
        lock.unlock()
        return recognizer
    }

    private static func readAll(path: String) throws -> Data {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SherpaBackendTestError.modelReadFailed
        }
        defer { Darwin.close(descriptor) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                result.append(buffer, count: count)
            } else if count == 0 {
                return result
            } else if errno != EINTR {
                throw SherpaBackendTestError.modelReadFailed
            }
        }
    }

    var identityCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return identityCountStorage
    }

    var makeRecognizerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return makeRecognizerCountStorage
    }

    var capturedConfiguration: SherpaOnnxRecognizerConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return capturedConfigurationStorage
    }

    var capturedModelContents: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return capturedModelContentsStorage
    }

    var reopenedModelContents: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return reopenedModelContentsStorage
    }
}

private final class SherpaBackendFakeRecognizer:
    SherpaOnnxRecognizerRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let finishError: (any Error)?
    private var startedHotwordsStorage: [[String]] = []
    private var endpointResetCountStorage = 0
    private var finishCountStorage = 0
    private var cancelCountStorage = 0

    init(finishError: (any Error)? = nil) {
        self.finishError = finishError
    }

    func startSession(hotwords: [String]) throws {
        lock.lock()
        startedHotwordsStorage.append(hotwords)
        lock.unlock()
    }

    func resetEndpoint() throws {
        lock.lock()
        endpointResetCountStorage += 1
        lock.unlock()
    }

    func accept(samples: [Float]) throws -> VoiceStreamingRecognitionUpdate {
        VoiceStreamingRecognitionUpdate(text: "", isEndpoint: false)
    }

    func finish() throws -> VoiceStreamingRecognitionUpdate {
        lock.lock()
        finishCountStorage += 1
        let error = finishError
        lock.unlock()
        if let error {
            throw error
        }
        return VoiceStreamingRecognitionUpdate(text: "", isEndpoint: false)
    }

    func cancel() {
        lock.lock()
        cancelCountStorage += 1
        lock.unlock()
    }

    var startedHotwords: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return startedHotwordsStorage
    }

    var endpointResetCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return endpointResetCountStorage
    }

    var finishCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return finishCountStorage
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelCountStorage
    }
}

private struct SherpaBackendVerifier: VoiceASRArtifactVerifying {
    let manifest: VoiceASRArtifactManifest

    func verifyArtifact(
        at artifactDirectory: URL
    ) throws -> VoiceASRVerifiedArtifact {
        VoiceASRVerifiedArtifact(
            artifactDirectory: artifactDirectory,
            manifest: manifest,
            contentSHA256: manifest.contentSHA256,
            verifiedFileCount: manifest.inventory.count,
            verifiedPayloadBytes: 49
        )
    }
}

private final class SherpaBackendStoreFixture {
    private static let modelFiles: [(String, String)] = [
        ("model/encoder.onnx", "encoder\n"),
        ("model/decoder.onnx", "decoder\n"),
        ("model/joiner.onnx", "joiner\n"),
        ("model/tokens.txt", "tokens\n"),
        ("model/bpe.vocab", "bpe\n"),
    ]

    let home: URL
    let artifactDirectory: URL
    let store: VoiceASRArtifactStore

    init(
        homeParent: URL = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        )
    ) throws {
        home = homeParent.appendingPathComponent(
            "rimeai-sherpa-backend-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        #expect(chmod(home.path, mode_t(0o700)) == 0)

        let manifest = try VoiceASRArtifactManifest.decodeStrict(
            Data(sherpaBackendManifestJSON.utf8),
            verifyContentDigest: false
        )
        let layout = RimeAIProductDataLayout(homeDirectory: home)
        store = VoiceASRArtifactStore(
            layout: layout,
            verifier: SherpaBackendVerifier(manifest: manifest)
        )
        _ = try store.selectorState()
        artifactDirectory = layout.voiceASRReleaseDirectory(
            for: manifest.artifactID
        )
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        #expect(chmod(artifactDirectory.path, mode_t(0o700)) == 0)
        try FileManager.default.createDirectory(
            at: path("model"),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for (relativePath, contents) in Self.modelFiles {
            let file = path(relativePath)
            try Data(contents.utf8).write(to: file, options: .atomic)
            #expect(chmod(file.path, mode_t(0o600)) == 0)
        }
        _ = try store.activate(manifest.artifactID)
    }

    func path(_ relativePath: String) -> URL {
        artifactDirectory.appendingPathComponent(relativePath)
    }

    var runtimeModelFiles: [URL] {
        Self.modelFiles.map { path($0.0) }
    }

    func load(
        using loader: SherpaOnnxProductBackendLoader
    ) throws -> (VoiceProductBackendLoad, UUID) {
        try store.withVerifiedCurrentArtifact { lease in
            let loaded = try loader.load(lease: lease)
            return (loaded, lease.generation)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}

private let sherpaBackendManifestJSON = """
{
  "schema_version": 2,
  "artifact_type": "rimeai.voice-asr-model",
  "asset_management": "product-managed",
  "artifact_id": "sherpa-zipformer-zh-en-int8-v1",
  "adapter": {"id":"sherpa-onnx","version":"1.13.6","abi_version":1},
  "model": {"id":"icefall-zipformer-zh-en","revision":"2026-08-20","format":"onnx","quantization":"int8"},
  "target": {"os":"macos","architecture":"arm64","minimum_os_version":"14.0"},
  "audio": {"sample_rate_hz":16000,"channel_count":1,"sample_format":"float32le","frame_duration_ms":20},
  "runtime": {
    "kind":"sherpa-onnx-online-transducer",
    "encoder_path":"model/encoder.onnx",
    "decoder_path":"model/decoder.onnx",
    "joiner_path":"model/joiner.onnx",
    "tokens_path":"model/tokens.txt",
    "bpe_vocab_path":"model/bpe.vocab",
    "modeling_unit":"cjkchar+bpe",
    "model_type":"zipformer",
    "feature_dimension":80,
    "provider":"cpu",
    "num_threads":2,
    "decoding_method":"modified_beam_search",
    "max_active_paths":4,
    "endpoint":{"enabled":true,"rule1_min_trailing_silence_ms":2400,"rule2_min_trailing_silence_ms":1200,"rule3_min_utterance_ms":30000},
    "hotword_probe_phrase":"RimeAI",
    "hotwords_score_milli":1500,
    "blank_penalty_milli":0
  },
  "network_policy":"offline",
  "locales":["en-US","zh-CN"],
  "capabilities":{"streaming":true,"partial_results":true,"endpoint_detection":true,"hotword_mode":"bounded-phrase-list","maximum_hotwords":32,"maximum_alternatives":1},
  "license":{"spdx_id":"Apache-2.0","license_path":"licenses/LICENSE.txt","notice_path":"licenses/NOTICE.txt","source_url":"https://example.invalid/model-card"},
  "inventory":[
    {"path":"licenses/LICENSE.txt","bytes":8,"sha256":"c0c56958ef8be5c1979366896b7e0c7206949a5aa2b23f51429c7f56b10990d3"},
    {"path":"licenses/NOTICE.txt","bytes":7,"sha256":"5de37b4c620461f2b695f1cf6b8ee36e7d025da8334a3693c4ed9aa48a5c7d6a"},
    {"path":"model/bpe.vocab","bytes":4,"sha256":"9b40808e3407521a22ecb18c10da26933cbcd86dfd2ad844ce69fe961025e4f3"},
    {"path":"model/decoder.onnx","bytes":8,"sha256":"eacbeef293be61f2a85d929cadb4cbb5248c8b8a1478b3d4b3180ea365d5e687"},
    {"path":"model/encoder.onnx","bytes":8,"sha256":"b1c4c05f286afb2531d4c847c4ca1e56260fc61281b7a04d50e09d09ab7a682b"},
    {"path":"model/joiner.onnx","bytes":7,"sha256":"8e7fda7c0958b448ed92d9b9bbf8f04f6423097f39eb007ca5c56f4a9657c340"},
    {"path":"model/tokens.txt","bytes":7,"sha256":"2de8bce5133f08dc3ebb75abcb1ef6c0951800ee3ae8ca06fcf58395d1244218"}
  ],
  "content_sha256":"4fa8f1ad946857620cf81ab549cf10e4135962e81eb45758d522e5df62a04504"
}
"""

private func addExtendedACL(to path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["+a", "\(NSUserName()) allow read", path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SherpaBackendTestError.modelReadFailed
    }
}

private func removeExtendedACL(from path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["-N", path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SherpaBackendTestError.modelReadFailed
    }
}

private func addDenyOnlyACL(to path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["+a", "everyone deny delete", path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SherpaBackendTestError.modelReadFailed
    }
}

private func addAuthorityGrantingACL(to path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = [
        "+a",
        "everyone allow add_file,delete_child,file_inherit,directory_inherit",
        path,
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SherpaBackendTestError.modelReadFailed
    }
}
