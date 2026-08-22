import Darwin
import Foundation
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

        #expect(descriptorPaths.allSatisfy { $0.hasPrefix("/dev/fd/") })
        #expect(Set(descriptorPaths).count == descriptorPaths.count)
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

    init(
        identity: SherpaOnnxRuntimeIdentity = SherpaOnnxRuntimeIdentity(
            sherpaVersion: "1.13.6",
            sherpaGitRevision: "0fdffb3e",
            onnxRuntimeVersion: "1.27.1"
        ),
        recognizer: SherpaBackendFakeRecognizer =
            SherpaBackendFakeRecognizer()
    ) {
        runtimeIdentity = identity
        self.recognizer = recognizer
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
        let contents = try paths.map {
            try Data(contentsOf: URL(fileURLWithPath: $0))
        }
        lock.lock()
        makeRecognizerCountStorage += 1
        capturedConfigurationStorage = configuration
        capturedModelContentsStorage = contents
        lock.unlock()
        return recognizer
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

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
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
