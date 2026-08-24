#if DEBUG
import CryptoKit
import Darwin
import Foundation
import RimeAIVoicePerformanceControlCore
import Testing
@_spi(RimeAIInternal) import RimeAIVoiceArtifactCore
@testable import RimeAIInputCore
@_spi(VoiceArtifactAssembly) @testable import RimeAIVoiceHelperEngine
@_spi(VoiceEvaluation) @testable import RimeAIVoicePerformanceHelperBridge
@_spi(VoicePerformanceTracer) import RimeAIVoicePerformanceHelperBridge

@Suite(.serialized)
struct SherpaOnnxEvaluationVoiceEngineFactoryTests {
    @Test
    func verifiedUncataloguedArtifactBuildsEngineWithoutTouchingRuntimeInputs()
        throws
    {
        let fixture = try EvaluationArtifactFixture()
        defer { fixture.remove() }
        let verifier = EvaluationArtifactVerifier(
            manifest: fixture.manifest
        )
        let backendLoader = EvaluationBackendLoader()
        let sourceFactory = EvaluationSourceFactory()
        let hotwordProvider = EvaluationHotwordProvider()

        let engine = try SherpaOnnxEvaluationVoiceEngineFactory.makeEngine(
            at: fixture.artifactDirectory,
            verifier: verifier,
            sourceFactory: sourceFactory,
            hotwordProvider: hotwordProvider,
            admittedEngineFactory: {
                lease, sourceFactory, hotwordProvider in
                try SherpaOnnxAdmittedArtifactVoiceEngineFactory.makeEngine(
                    lease: lease,
                    backendLoader: backendLoader,
                    sourceFactory: sourceFactory,
                    hotwordProvider: hotwordProvider
                )
            }
        )

        #expect(
            !VoiceASRTrustedArtifactCatalog.production.approves(
                verifier.artifact(at: fixture.artifactDirectory)
            )
        )
        #expect(verifier.verificationCount == 1)
        #expect(backendLoader.loadCount == 1)
        #expect(engine.descriptor.artifactID == fixture.manifest.artifactID)
        #expect(engine.descriptor.hasIntegrityVerifiedProductArtifact)
        #expect(sourceFactory.makeCount == 0)
        #expect(hotwordProvider.snapshotCount == 0)
    }

    @Test
    func verifierAndBackendRemainDeferredUntilTracerAcknowledgement()
        throws
    {
        let fixture = try EvaluationArtifactFixture()
        defer { fixture.remove() }
        let verifier = EvaluationArtifactVerifier(
            manifest: fixture.manifest
        )
        let backendLoader = EvaluationBackendLoader()
        let sourceFactory = EvaluationSourceFactory()
        let hotwordProvider = EvaluationHotwordProvider()
        let prepared = VoiceHelperInternalTracerPreparedEngine(loader: {
            try SherpaOnnxEvaluationVoiceEngineFactory.makeEngine(
                at: fixture.artifactDirectory,
                verifier: verifier,
                sourceFactory: sourceFactory,
                hotwordProvider: hotwordProvider,
                admittedEngineFactory: {
                    lease, sourceFactory, hotwordProvider in
                    try SherpaOnnxAdmittedArtifactVoiceEngineFactory
                        .makeEngine(
                            lease: lease,
                            backendLoader: backendLoader,
                            sourceFactory: sourceFactory,
                            hotwordProvider: hotwordProvider
                        )
                }
            )
        })

        #expect(
            !VoiceASRTrustedArtifactCatalog.production.approves(
                verifier.artifact(at: fixture.artifactDirectory)
            )
        )
        #expect(verifier.verificationCount == 0)
        #expect(backendLoader.loadCount == 0)
        try prepared.arm(
            sessionID: "session-1",
            generation: 7,
            ticket: "ticket-1"
        )
        #expect(verifier.verificationCount == 0)
        #expect(backendLoader.loadCount == 0)

        _ = try prepared.completeBeginBoundaryAcknowledgement(
            sessionID: "session-1",
            generation: 7,
            ticket: "ticket-1"
        )

        #expect(verifier.verificationCount == 1)
        #expect(backendLoader.loadCount == 1)
        #expect(sourceFactory.makeCount == 0)
        #expect(hotwordProvider.snapshotCount == 0)
    }

    @Test
    func appleProbeBundleDefersUncataloguedEvaluationUntilTracerAck()
        throws
    {
        let artifact = try EvaluationArtifactFixture()
        defer { artifact.remove() }
        let bundle = try EvaluationTracerBundleFixture()
        defer { bundle.remove() }
        let verifier = EvaluationArtifactVerifier(
            manifest: artifact.manifest
        )
        let backendLoader = EvaluationBackendLoader()
        let sourceFactory = EvaluationSourceFactory()
        let hotwordProvider = EvaluationHotwordProvider()
        let appleCalls = EvaluationInvocationCounter()
        let productCalls = EvaluationInvocationCounter()
        let policy = try VoicePerformanceMeasurementPolicy.decodeCanonical(
            evaluationTracerMeasurementPolicyData(
                artifactDirectory: artifact.artifactDirectory.path,
                artifactID: artifact.manifest.artifactID.rawValue,
                contentSHA256: artifact.manifest.contentSHA256,
                maximumHotwords: UInt64(
                    artifact.manifest.capabilities.maximumHotwords
                ),
                releasePolicySHA256: evaluationSHA256(
                    bundle.releasePolicyData
                ),
                helperExecutablePath: bundle.bundleURL.path
                    + "/Contents/MacOS/rimeai-voice-performance-helper"
            )
        )
        let bootstrap = VoiceHelperPerformanceTracerBootstrap(
            trustedCatalog: .production,
            bundleValidator: { _ in },
            evaluationFactory: { directory in
                try SherpaOnnxEvaluationVoiceEngineFactory.makeEngine(
                    at: directory,
                    verifier: verifier,
                    sourceFactory: sourceFactory,
                    hotwordProvider: hotwordProvider,
                    admittedEngineFactory: {
                        lease, sourceFactory, hotwordProvider in
                        try SherpaOnnxAdmittedArtifactVoiceEngineFactory
                            .makeEngine(
                                lease: lease,
                                backendLoader: backendLoader,
                                sourceFactory: sourceFactory,
                                hotwordProvider: hotwordProvider
                            )
                    }
                )
            }
        )
        let bridge = try VoiceHelperPerformanceTracerBridgeFactory.make(
            bootstrap: bootstrap,
            measurementPolicy: policy,
            peerNonceSource: {
                try PerformanceControlNonce(
                    String(repeating: "9", count: 64)
                )
            },
            processStartTokenSource: { 9_001 }
        )
        let binding = try PerformanceControlSessionBinding.derive(
            controlSessionNonce: PerformanceControlNonce(
                policy.controlSessionNonce
            ),
            trial: 1
        )
        _ = try bridge.receive(.challenge(
            peerRole: .helper,
            sessionID: binding.sessionID,
            planNonce: binding.planNonce,
            collectorNonce: try PerformanceControlNonce(
                String(repeating: "8", count: 64)
            )
        ))
        let ticket = try PerformanceControlNonce(
            String(repeating: "7", count: 64)
        )
        _ = try bridge.receive(.loadEngine(
            sequence: 1,
            sessionID: binding.sessionID,
            trial: 1,
            loadTicket: ticket
        ))

        #expect(verifier.verificationCount == 0)
        #expect(backendLoader.loadCount == 0)
        #expect(appleCalls.value == 0)
        #expect(productCalls.value == 0)

        let ready = try bridge.receive(.loadStartedAck(
            sequence: 2,
            sessionID: binding.sessionID,
            replyTo: 1,
            trial: 1,
            loadTicket: ticket
        ))

        guard case .loadReady(_, _, _, _, _, let summary) = ready else {
            Issue.record("expected load_ready")
            return
        }
        #expect(policy.expectedEngine.matches(summary))
        #expect(verifier.verificationCount == 1)
        #expect(backendLoader.loadCount == 1)
        #expect(appleCalls.value == 0)
        #expect(productCalls.value == 0)
        #expect(sourceFactory.makeCount == 0)
        #expect(hotwordProvider.snapshotCount == 0)
    }

    @Test
    func productionFactoryRejectsUncataloguedArtifactBeforeRuntimeInputs()
        throws
    {
        let artifactFixture = try EvaluationArtifactFixture()
        defer { artifactFixture.remove() }
        let fixture = try EvaluationProductStoreFixture(
            manifest: artifactFixture.manifest
        )
        defer { fixture.remove() }
        let backendLoader = EvaluationBackendLoader()
        let sourceFactory = EvaluationSourceFactory()
        let hotwordProvider = EvaluationHotwordProvider()

        #expect(
            throws: SherpaOnnxProductBackendError.untrustedArtifact(
                artifactFixture.manifest.artifactID
            )
        ) {
            _ = try SherpaOnnxProductVoiceEngineFactory.makeEngine(
                store: fixture.store,
                backendLoader: backendLoader,
                sourceFactory: sourceFactory,
                hotwordProvider: hotwordProvider
            )
        }

        #expect(backendLoader.loadCount == 0)
        #expect(sourceFactory.makeCount == 0)
        #expect(hotwordProvider.snapshotCount == 0)
    }
}

private final class EvaluationArtifactVerifier:
    VoiceASRArtifactVerifying,
    @unchecked Sendable
{
    let manifest: VoiceASRArtifactManifest
    private let lock = NSLock()
    private var verificationCountStorage = 0

    init(manifest: VoiceASRArtifactManifest) {
        self.manifest = manifest
    }

    func verifyArtifact(
        at artifactDirectory: URL
    ) throws -> VoiceASRVerifiedArtifact {
        lock.lock()
        verificationCountStorage += 1
        lock.unlock()
        return artifact(at: artifactDirectory)
    }

    func artifact(at artifactDirectory: URL) -> VoiceASRVerifiedArtifact {
        VoiceASRVerifiedArtifact(
            artifactDirectory: artifactDirectory,
            manifest: manifest,
            contentSHA256: manifest.contentSHA256,
            verifiedFileCount: manifest.inventory.count,
            verifiedPayloadBytes: manifest.inventory.reduce(0) {
                $0 + $1.bytes
            }
        )
    }

    var verificationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return verificationCountStorage
    }
}

private final class EvaluationBackendLoader:
    VoiceProductBackendLoading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var loadCountStorage = 0

    func load(
        lease: VoiceASRVerifiedArtifactLease
    ) throws -> VoiceProductBackendLoad {
        lock.lock()
        loadCountStorage += 1
        lock.unlock()
        let manifest = lease.artifact.manifest
        let driver = EvaluationRecognizerDriver(
            generation: lease.generation
        )
        return try VoiceProductBackendLoad(
            recognizerDriver: driver,
            loadProbe: VoiceProductEngineLoadProbe(
                artifactGeneration: lease.generation,
                adapterID: manifest.adapter.id,
                adapterVersion: manifest.adapter.version,
                adapterABIVersion: manifest.adapter.abiVersion,
                runtimeKind: manifest.runtime.kind,
                supportedLocales: Set(manifest.locales),
                supportsStreaming: true,
                supportsPartialResults: true,
                supportsEndpointDetection: true,
                maximumHotwords: manifest.capabilities.maximumHotwords,
                maximumAlternatives:
                    manifest.capabilities.maximumAlternatives,
                sampleRateHertz: manifest.audio.sampleRateHertz,
                channelCount: manifest.audio.channelCount,
                bitsPerChannel: 32
            )
        )
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadCountStorage
    }
}

private final class EvaluationRecognizerDriver:
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

private final class EvaluationSourceFactory:
    VoicePCMSourceFactory,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var makeCountStorage = 0

    func makeSource() throws -> any VoicePCMSource {
        lock.lock()
        makeCountStorage += 1
        lock.unlock()
        return EvaluationPCMSource()
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return makeCountStorage
    }
}

private final class EvaluationPCMSource:
    VoicePCMSource,
    @unchecked Sendable
{
    func start(
        onFrame: @escaping @Sendable (VoicePCMFrame) -> Void,
        onFailure: @escaping @Sendable (VoicePCMSourceFailure) -> Void
    ) throws {}

    func stop() {}
    func cancel() {}
}

private final class EvaluationHotwordProvider:
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

private final class EvaluationArtifactFixture {
    let artifactDirectory: URL
    let manifest: VoiceASRArtifactManifest

    init() throws {
        artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rimeai-evaluation-artifact-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        manifest = try VoiceASRArtifactManifest.decodeStrict(
            Data(evaluationManifestJSON.utf8),
            verifyContentDigest: false
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: artifactDirectory)
    }
}

private final class EvaluationProductStoreFixture {
    let homeDirectory: URL
    let store: VoiceASRArtifactStore

    init(manifest: VoiceASRArtifactManifest) throws {
        homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rimeai-evaluation-product-store-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: homeDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        #expect(chmod(homeDirectory.path, mode_t(0o700)) == 0)
        let layout = RimeAIProductDataLayout(
            homeDirectory: homeDirectory
        )
        store = VoiceASRArtifactStore(
            layout: layout,
            verifier: EvaluationArtifactVerifier(manifest: manifest)
        )
        _ = try store.selectorState()
        let release = layout.voiceASRReleaseDirectory(
            for: manifest.artifactID
        )
        try FileManager.default.createDirectory(
            at: release,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        #expect(chmod(release.path, mode_t(0o700)) == 0)
        _ = try store.activate(manifest.artifactID)
    }

    func remove() {
        try? FileManager.default.removeItem(at: homeDirectory)
    }
}

private final class EvaluationInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct EvaluationTracerBundleFixture {
    let root: URL
    let bundleURL: URL
    let releasePolicyData: Data

    init() throws {
        root = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ).appendingPathComponent(
            "rimeai-evaluation-tracer-bundle-\(UUID().uuidString)",
            isDirectory: true
        )
        bundleURL = root.appendingPathComponent(
            "RimeAIVoiceHelper.app",
            isDirectory: true
        )
        let resources = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        releasePolicyData = evaluationTracerReleasePolicyData()
        try releasePolicyData.write(
            to: resources.appendingPathComponent(
                "VoiceReleasePolicy.plist",
                isDirectory: false
            )
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func evaluationSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map {
        String(format: "%02x", $0)
    }.joined()
}

private func evaluationTracerReleasePolicyData() -> Data {
    Data(
        """
        <plist version="1.0">
        <dict>
          <key>SchemaVersion</key>
          <integer>2</integer>
          <key>RuntimeEngine</key>
          <string>apple-speech</string>
          <key>EngineIdentifier</key>
          <string>apple-speech-ondevice</string>
          <key>AssetManagement</key>
          <string>system_managed</string>
          <key>ReleaseEligible</key>
          <false/>
          <key>EligibilityReason</key>
          <string>macos14_15_system_managed_probe_only</string>
          <key>TrustedCatalogSHA256</key>
          <string>\(VoiceASRTrustedArtifactCatalog.production.canonicalSHA256)</string>
        </dict>
        </plist>
        """.utf8
    )
}

private func evaluationTracerMeasurementPolicyData(
    artifactDirectory: String,
    artifactID: String,
    contentSHA256: String,
    maximumHotwords: UInt64,
    releasePolicySHA256: String,
    helperExecutablePath: String
) -> Data {
    Data(
        (#"{"cold_trials":1,"collector":{"expected_cdhash":""#
            + String(repeating: "d", count: 40)
            + #"","expected_executable_path":"/usr/local/libexec/rimeai-voice-performance-collector","expected_executable_sha256":""#
            + String(repeating: "c", count: 64)
            + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-performance-collector","expected_team_identifier":"TEAMID1234"},"control_protocol":{"id":"rimeai-performance-control-v2","sha256":""#
            + String(repeating: "a", count: 64)
            + #""},"control_session_nonce":""#
            + String(repeating: "b", count: 64)
            + #"","control_socket_path":"/private/tmp/rimeai-performance.sock","driver":{"expected_cdhash":""#
            + String(repeating: "f", count: 40)
            + #"","expected_executable_path":"/usr/local/bin/rimeai-voice-performance-driver","expected_executable_sha256":""#
            + String(repeating: "e", count: 64)
            + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-performance-driver","expected_team_identifier":"TEAMID1234","policy_sha256":""#
            + String(repeating: "0", count: 64)
            + #""},"enabled":true,"evaluation_artifact":{"adapter_id":"sherpa-onnx","artifact_id":""#
            + artifactID
            + #"","content_sha256":""#
            + contentSHA256
            + #"","directory":""#
            + artifactDirectory
            + #"","maximum_hotwords":"#
            + String(maximumHotwords)
            + #"},"helper":{"expected_cdhash":""#
            + String(repeating: "3", count: 40)
            + #"","expected_executable_path":""#
            + helperExecutablePath
            + #"","expected_executable_sha256":""#
            + String(repeating: "1", count: 64)
            + #"","expected_signing_identifier":"fun.wwcn.rimeai.voice-helper","expected_team_identifier":"TEAMID1234"},"release_policy_sha256":""#
            + releasePolicySHA256
            + #"","schema_version":2}"#).utf8
    )
}

private let evaluationManifestJSON = """
{
  "schema_version": 2,
  "artifact_type": "rimeai.voice-asr-model",
  "asset_management": "product-managed",
  "artifact_id": "evaluation-sherpa-zipformer-zh-en-int8-v1",
  "adapter": {"id":"sherpa-onnx","version":"1.13.6","abi_version":1},
  "model": {"id":"icefall-zipformer-zh-en","revision":"evaluation-2026-08-21","format":"onnx","quantization":"int8"},
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
#endif
