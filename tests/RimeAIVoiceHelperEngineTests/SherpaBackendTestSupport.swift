// SherpaOnnxProductBackendTests 与 SherpaOnnxBufferTransportTests 的
// 共享测试基建：store fixture、mock runtime/recognizer、清单常量。
import Darwin
import Foundation
import RimeAISherpaOnnxSafeC
import SherpaOnnxC
import Testing
@_spi(RimeAIInternal) import RimeAIVoiceArtifactCore
@testable import RimeAIInputCore
@testable import RimeAIVoiceHelperEngine

enum SherpaBackendTestError: Error {
    case probeFailed
    case modelReadFailed
}

final class SherpaBackendLockedCallCounter: @unchecked Sendable {
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

final class SherpaBackendFakeRuntime:
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
            sherpaGitRevision: "1cb484af-rimeai-buffer",
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
        .filter { !$0.isEmpty }
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

final class SherpaBackendFakeRecognizer:
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

struct SherpaBackendVerifier: VoiceASRArtifactVerifying {
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

final class SherpaBackendStoreFixture {
    enum Cohort {
        case zipformer
        case paraformer
    }

    private static let zipformerModelFiles: [(String, String)] = [
        ("model/encoder.onnx", "encoder\n"),
        ("model/decoder.onnx", "decoder\n"),
        ("model/joiner.onnx", "joiner\n"),
        ("model/tokens.txt", "tokens\n"),
        ("model/bpe.vocab", "bpe\n"),
    ]

    private static let paraformerModelFiles: [(String, String)] = [
        ("model/encoder.onnx", "encoder\n"),
        ("model/decoder.onnx", "decoder\n"),
        ("model/tokens.txt", "tokens\n"),
    ]

    let home: URL
    let artifactDirectory: URL
    let store: VoiceASRArtifactStore
    private let cohortModelFiles: [(String, String)]

    init(
        homeParent: URL = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ),
        cohort: Cohort = .zipformer
    ) throws {
        let manifestJSON = cohort == .zipformer
            ? sherpaBackendManifestJSON
            : sherpaBackendParaformerManifestJSON
        cohortModelFiles = cohort == .zipformer
            ? Self.zipformerModelFiles
            : Self.paraformerModelFiles
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
            Data(manifestJSON.utf8),
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
        for (relativePath, contents) in cohortModelFiles {
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
        cohortModelFiles.map { path($0.0) }
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

let sherpaBackendManifestJSON = """
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

let sherpaBackendParaformerManifestJSON = """
{
  "schema_version": 2,
  "artifact_type": "rimeai.voice-asr-model",
  "asset_management": "product-managed",
  "artifact_id": "sherpa-paraformer-zh-en-v1",
  "adapter": {"id":"sherpa-onnx","version":"1.13.6","abi_version":1},
  "model": {"id":"funasr-streaming-paraformer-zh-en","revision":"2026-10-13","format":"onnx","quantization":"fp32"},
  "target": {"os":"macos","architecture":"arm64","minimum_os_version":"14.0"},
  "audio": {"sample_rate_hz":16000,"channel_count":1,"sample_format":"float32le","frame_duration_ms":20},
  "runtime": {
    "kind":"sherpa-onnx-online-paraformer",
    "encoder_path":"model/encoder.onnx",
    "decoder_path":"model/decoder.onnx",
    "tokens_path":"model/tokens.txt",
    "modeling_unit":"cjkchar",
    "model_type":"paraformer",
    "feature_dimension":80,
    "provider":"cpu",
    "num_threads":2,
    "decoding_method":"greedy_search",
    "max_active_paths":4,
    "endpoint":{"enabled":true,"rule1_min_trailing_silence_ms":2400,"rule2_min_trailing_silence_ms":1200,"rule3_min_utterance_ms":30000},
    "hotword_probe_phrase":"",
    "hotwords_score_milli":0,
    "blank_penalty_milli":0
  },
  "network_policy":"offline",
  "locales":["en-US","zh-CN"],
  "capabilities":{"streaming":true,"partial_results":true,"endpoint_detection":true,"hotword_mode":"unsupported","maximum_hotwords":0,"maximum_alternatives":1},
  "license":{"spdx_id":"Apache-2.0","license_path":"licenses/LICENSE.txt","notice_path":"licenses/NOTICE.txt","source_url":"https://example.invalid/model-card"},
  "inventory":[
    {"path":"licenses/LICENSE.txt","bytes":8,"sha256":"c0c56958ef8be5c1979366896b7e0c7206949a5aa2b23f51429c7f56b10990d3"},
    {"path":"licenses/NOTICE.txt","bytes":7,"sha256":"5de37b4c620461f2b695f1cf6b8ee36e7d025da8334a3693c4ed9aa48a5c7d6a"},
    {"path":"model/decoder.onnx","bytes":8,"sha256":"eacbeef293be61f2a85d929cadb4cbb5248c8b8a1478b3d4b3180ea365d5e687"},
    {"path":"model/encoder.onnx","bytes":8,"sha256":"b1c4c05f286afb2531d4c847c4ca1e56260fc61281b7a04d50e09d09ab7a682b"},
    {"path":"model/tokens.txt","bytes":7,"sha256":"2de8bce5133f08dc3ebb75abcb1ef6c0951800ee3ae8ca06fcf58395d1244218"}
  ],
  "content_sha256":"0000000000000000000000000000000000000000000000000000000000000000"
}
"""

func addExtendedACL(to path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["+a", "\(NSUserName()) allow read", path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SherpaBackendTestError.modelReadFailed
    }
}

func removeExtendedACL(from path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["-N", path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SherpaBackendTestError.modelReadFailed
    }
}

func addDenyOnlyACL(to path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["+a", "everyone deny delete", path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SherpaBackendTestError.modelReadFailed
    }
}

func addAuthorityGrantingACL(to path: String) throws {
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
