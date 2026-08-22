import Darwin
import Foundation
import Testing
@_spi(RimeAIInternal) import RimeAIVoiceArtifactCore
@testable import RimeAIInputCore
@testable import RimeAIVoiceHelperEngine

@Suite(.serialized)
struct ProductManagedVoiceEngineBootstrapTests {
    @Test
    func bootstrapBindsLeaseDriverProbeAndDescriptorGeneration() throws {
        let fixture = try BootstrapStoreFixture(activateCurrent: true)
        defer { fixture.remove() }
        let loader = BootstrapBackendLoader()
        let sourceFactory = BootstrapSourceFactory()
        let hotwords = BootstrapHotwordProvider()

        let engine = try ProductManagedVoiceEngineBootstrap(
            store: fixture.store,
            backendLoader: loader
        ).makeEngine(
            sourceFactory: sourceFactory,
            hotwordProvider: hotwords
        )

        let generation = try #require(loader.receivedGeneration)
        #expect(loader.driver?.artifactGeneration == generation)
        #expect(engine.descriptor.artifactGeneration == generation)
        #expect(engine.descriptor.artifactID == fixture.artifactID)
        #expect(engine.descriptor.hasIntegrityVerifiedProductArtifact)
        #expect(sourceFactory.makeCount == 0)
        #expect(hotwords.snapshotCount == 0)
    }

    @Test
    func mixedDriverAndProbeGenerationsAreRejectedImmediately() {
        let driver = BootstrapRecognizerDriver(generation: UUID())
        #expect(
            throws: VoiceProductBackendLoadError
                .artifactGenerationMismatch
        ) {
            _ = try VoiceProductBackendLoad(
                recognizerDriver: driver,
                loadProbe: makeBootstrapProbe(generation: UUID())
            )
        }
    }

    @Test
    func backendGenerationMustMatchTheStoreLease() throws {
        let fixture = try BootstrapStoreFixture(activateCurrent: true)
        defer { fixture.remove() }
        let loader = BootstrapBackendLoader(
            forcedGeneration: UUID()
        )

        #expect(
            throws: ProductManagedVoiceEngineBootstrapError
                .artifactGenerationMismatch
        ) {
            _ = try ProductManagedVoiceEngineBootstrap(
                store: fixture.store,
                backendLoader: loader
            ).makeEngine(
                sourceFactory: BootstrapSourceFactory(),
                hotwordProvider: BootstrapHotwordProvider()
            )
        }
    }

    @Test
    func descriptorMismatchRemainsAClassifiedBootstrapFailure() throws {
        let fixture = try BootstrapStoreFixture(activateCurrent: true)
        defer { fixture.remove() }
        let loader = BootstrapBackendLoader(adapterID: "wrong-adapter")

        #expect(throws: VoiceProductEngineDescriptorError.adapterMismatch) {
            _ = try ProductManagedVoiceEngineBootstrap(
                store: fixture.store,
                backendLoader: loader
            ).makeEngine(
                sourceFactory: BootstrapSourceFactory(),
                hotwordProvider: BootstrapHotwordProvider()
            )
        }
    }

    @Test
    func backendFailureDoesNotTouchAudioOrHotwords() throws {
        let fixture = try BootstrapStoreFixture(activateCurrent: true)
        defer { fixture.remove() }
        let loader = BootstrapBackendLoader(
            error: VoiceProductBackendLoadError.emptyStreamProbeFailed
        )
        let sourceFactory = BootstrapSourceFactory()
        let hotwords = BootstrapHotwordProvider()

        #expect(
            throws: VoiceProductBackendLoadError.emptyStreamProbeFailed
        ) {
            _ = try ProductManagedVoiceEngineBootstrap(
                store: fixture.store,
                backendLoader: loader
            ).makeEngine(
                sourceFactory: sourceFactory,
                hotwordProvider: hotwords
            )
        }
        #expect(sourceFactory.makeCount == 0)
        #expect(hotwords.snapshotCount == 0)
    }

    @Test
    func missingCurrentSelectorFailsBeforeBackendLoad() throws {
        let fixture = try BootstrapStoreFixture(activateCurrent: false)
        defer { fixture.remove() }
        let loader = BootstrapBackendLoader()

        #expect(throws: VoiceASRArtifactStoreError.noCurrentArtifact) {
            _ = try ProductManagedVoiceEngineBootstrap(
                store: fixture.store,
                backendLoader: loader
            ).makeEngine(
                sourceFactory: BootstrapSourceFactory(),
                hotwordProvider: BootstrapHotwordProvider()
            )
        }
        #expect(loader.loadCount == 0)
    }
}

private final class BootstrapBackendLoader:
    VoiceProductBackendLoading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let forcedGeneration: UUID?
    private let adapterID: String
    private let error: (any Error)?
    private var receivedGenerationStorage: UUID?
    private var driverStorage: BootstrapRecognizerDriver?
    private var loadCountStorage = 0

    init(
        forcedGeneration: UUID? = nil,
        adapterID: String = "sherpa-onnx",
        error: (any Error)? = nil
    ) {
        self.forcedGeneration = forcedGeneration
        self.adapterID = adapterID
        self.error = error
    }

    func load(
        lease: VoiceASRVerifiedArtifactLease
    ) throws -> VoiceProductBackendLoad {
        lock.lock()
        loadCountStorage += 1
        receivedGenerationStorage = lease.generation
        let generation = forcedGeneration ?? lease.generation
        let driver = BootstrapRecognizerDriver(generation: generation)
        driverStorage = driver
        let error = self.error
        lock.unlock()
        if let error {
            throw error
        }
        return try VoiceProductBackendLoad(
            recognizerDriver: driver,
            loadProbe: makeBootstrapProbe(
                generation: generation,
                adapterID: adapterID
            )
        )
    }

    var receivedGeneration: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return receivedGenerationStorage
    }

    var driver: BootstrapRecognizerDriver? {
        lock.lock()
        defer { lock.unlock() }
        return driverStorage
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadCountStorage
    }
}

private final class BootstrapRecognizerDriver:
    VoiceStreamingRecognizerDriver,
    @unchecked Sendable
{
    let artifactGeneration: UUID

    init(generation: UUID) {
        artifactGeneration = generation
    }

    func startSession(hotwords: [String]) throws {}
    func resetEndpoint() throws {}

    func accept(samples: [Float]) throws -> VoiceStreamingRecognitionUpdate {
        VoiceStreamingRecognitionUpdate(text: "", isEndpoint: false)
    }

    func finish() throws -> VoiceStreamingRecognitionUpdate {
        VoiceStreamingRecognitionUpdate(text: "", isEndpoint: false)
    }

    func cancel() {}
}

private final class BootstrapSourceFactory:
    VoicePCMSourceFactory,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var makeCountStorage = 0

    func makeSource() throws -> any VoicePCMSource {
        lock.lock()
        makeCountStorage += 1
        lock.unlock()
        return BootstrapPCMSource()
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return makeCountStorage
    }
}

private final class BootstrapPCMSource: VoicePCMSource, @unchecked Sendable {
    func start(
        onFrame: @escaping @Sendable (VoicePCMFrame) -> Void,
        onFailure: @escaping @Sendable (VoicePCMSourceFailure) -> Void
    ) throws {}

    func stop() {}
    func cancel() {}
}

private final class BootstrapHotwordProvider:
    VoiceHotwordProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var snapshotCountStorage = 0

    func snapshot(
        for request: VoiceDictationEngineRequest,
        maximumEntries: Int
    ) throws -> VoiceHotwordSnapshot {
        lock.lock()
        snapshotCountStorage += 1
        lock.unlock()
        return .empty
    }

    var snapshotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshotCountStorage
    }
}

private func makeBootstrapProbe(
    generation: UUID,
    adapterID: String = "sherpa-onnx"
) -> VoiceProductEngineLoadProbe {
    VoiceProductEngineLoadProbe(
        artifactGeneration: generation,
        adapterID: adapterID,
        adapterVersion: "1.13.6",
        adapterABIVersion: 1,
        runtimeKind: .sherpaOnnxOnlineTransducer,
        supportedLocales: ["zh-CN"],
        supportsStreaming: true,
        supportsPartialResults: true,
        supportsEndpointDetection: true,
        maximumHotwords: 32,
        maximumAlternatives: 1,
        sampleRateHertz: 16_000,
        channelCount: 1,
        bitsPerChannel: 32
    )
}

private struct BootstrapVerifier: VoiceASRArtifactVerifying {
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

private final class BootstrapStoreFixture {
    let home: URL
    let artifactID: VoiceASRArtifactID
    let store: VoiceASRArtifactStore

    init(activateCurrent: Bool) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimeai-product-bootstrap-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        artifactID = VoiceASRArtifactID(
            rawValue: "sherpa-zipformer-zh-en-int8-v1"
        )!
        let manifest = try VoiceASRArtifactManifest.decodeStrict(
            Data(bootstrapManifestJSON.utf8),
            verifyContentDigest: false
        )
        let layout = RimeAIProductDataLayout(homeDirectory: home)
        store = VoiceASRArtifactStore(
            layout: layout,
            verifier: BootstrapVerifier(manifest: manifest)
        )
        _ = try store.selectorState()
        let release = layout.voiceASRReleaseDirectory(for: artifactID)
        try FileManager.default.createDirectory(
            at: release,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        #expect(chmod(release.path, mode_t(0o700)) == 0)
        if activateCurrent {
            _ = try store.activate(artifactID)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}

private let bootstrapManifestJSON = """
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
