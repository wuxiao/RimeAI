import Darwin
import CryptoKit
import Foundation
import RimeAIInputCore
import SherpaOnnxC

enum SherpaOnnxProductBackendError: Error, Equatable, Sendable {
    case unsupportedArtifactContract
    case untrustedArtifact(VoiceASRArtifactID)
    case runtimeMetadataUnavailable
    case runtimeVersionMismatch(expected: String, actual: String)
    case runtimeRevisionMismatch(expected: String, actual: String)
    case onnxRuntimeVersionMismatch(expected: String, actual: String)
    case unsafeModelPath(String)
    case modelFileUnavailable(String)
    case recognizerInitializationFailed
    case streamInitializationFailed
    case resultUnavailable
    case invalidAudioFrame
    case decodeStepLimitExceeded
}

struct SherpaOnnxRuntimeIdentity: Equatable, Sendable {
    let sherpaVersion: String
    let sherpaGitRevision: String
    let onnxRuntimeVersion: String
}

struct SherpaOnnxRecognizerConfiguration: Equatable, Sendable {
    let encoderPath: String
    let decoderPath: String
    let joinerPath: String
    let tokensPath: String
    let bpeVocabularyPath: String
    let sampleRateHertz: Int
    let featureDimension: Int
    let numberOfThreads: Int
    let provider: String
    let modelType: String
    let modelingUnit: String
    let decodingMethod: String
    let maximumActivePaths: Int
    let endpointEnabled: Bool
    let rule1MinimumTrailingSilenceSeconds: Float
    let rule2MinimumTrailingSilenceSeconds: Float
    let rule3MinimumUtteranceSeconds: Float
    let hotwordsScore: Float
    let blankPenalty: Float
}

protocol SherpaOnnxRecognizerRunning: AnyObject, Sendable {
    func startSession(hotwords: [String]) throws
    func resetEndpoint() throws
    func accept(samples: [Float]) throws -> VoiceStreamingRecognitionUpdate
    func finish() throws -> VoiceStreamingRecognitionUpdate
    func cancel()
}

protocol SherpaOnnxRuntimeLoading: Sendable {
    func identity() throws -> SherpaOnnxRuntimeIdentity
    func makeRecognizer(
        configuration: SherpaOnnxRecognizerConfiguration
    ) throws -> any SherpaOnnxRecognizerRunning
}

/// Product backend for the pinned static sherpa-onnx runtime. The model is
/// still supplied by the verified artifact store; this type never downloads
/// or repairs runtime/model content.
final class SherpaOnnxProductBackendLoader:
    VoiceProductBackendLoading,
    @unchecked Sendable
{
    static let adapterID = "sherpa-onnx"
    static let adapterVersion = "1.13.6"
    static let adapterABIVersion = 1
    /// Revision embedded by the official v1.13.6 static XCFramework. This is
    /// intentionally distinct from the source tag commit; the binary archive
    /// checksum in Package.swift remains the primary artifact identity.
    static let embeddedSherpaGitRevision = "0fdffb3e"
    static let onnxRuntimeVersion = "1.27.1"
    static let supportedLocales: Set<String> = ["en-US", "zh-CN"]

    private let runtime: any SherpaOnnxRuntimeLoading

    convenience init() {
        self.init(runtime: SystemSherpaOnnxRuntime())
    }

    init(runtime: any SherpaOnnxRuntimeLoading) {
        self.runtime = runtime
    }

    func load(
        lease: VoiceASRVerifiedArtifactLease
    ) throws -> VoiceProductBackendLoad {
        let artifact = lease.artifact
        let manifest = artifact.manifest
        try Self.validateProductContract(manifest)
        try Self.validateRuntimeIdentity(runtime.identity())

        let configuration = try Self.makeConfiguration(for: artifact)
        let openFiles = try Self.openRuntimeFiles(
            for: artifact,
            configuration: configuration
        )
        let recognizer = try runtime.makeRecognizer(
            configuration: Self.configuration(
                configuration,
                boundTo: openFiles
            )
        )
        let driver = SherpaOnnxRecognizerDriver(
            artifactGeneration: lease.generation,
            recognizer: recognizer,
            openedRuntimeFiles: openFiles
        )

        // Exercise a model-approved non-empty hotword, end-of-input, result
        // extraction, and a fresh empty stream before this generation is
        // advertised to the server. The manifest phrase is integrity-bound
        // metadata, never user text.
        do {
            let probeHotwords = Array(
                repeating: manifest.runtime.hotwordProbePhrase,
                count: min(
                    manifest.capabilities.maximumHotwords,
                    VoiceDictationConstants.maximumHotwordCount
                )
            )
            try driver.startSession(
                hotwords: probeHotwords
            )
            let hotwordProbe = try driver.finish()
            guard hotwordProbe.text.isEmpty else {
                throw VoiceProductBackendLoadError.emptyStreamProbeFailed
            }
            driver.cancel()
            try driver.startSession(hotwords: [])
            let freshProbe = try driver.finish()
            guard freshProbe.text.isEmpty else {
                throw VoiceProductBackendLoadError.emptyStreamProbeFailed
            }
            driver.cancel()
        } catch let error as VoiceProductBackendLoadError {
            throw error
        } catch {
            driver.cancel()
            throw VoiceProductBackendLoadError.emptyStreamProbeFailed
        }

        let locales = Set(manifest.locales).intersection(
            Self.supportedLocales
        )
        let probe = VoiceProductEngineLoadProbe(
            artifactGeneration: lease.generation,
            adapterID: Self.adapterID,
            adapterVersion: Self.adapterVersion,
            adapterABIVersion: Self.adapterABIVersion,
            runtimeKind: .sherpaOnnxOnlineTransducer,
            supportedLocales: locales,
            supportsStreaming: true,
            supportsPartialResults: true,
            supportsEndpointDetection: true,
            maximumHotwords: min(
                manifest.capabilities.maximumHotwords,
                128
            ),
            maximumAlternatives: 1,
            sampleRateHertz: VoicePCMFrame.sampleRateHertz,
            channelCount: 1,
            bitsPerChannel: 32
        )
        return try VoiceProductBackendLoad(
            recognizerDriver: driver,
            loadProbe: probe
        )
    }

    private static func validateProductContract(
        _ manifest: VoiceASRArtifactManifest
    ) throws {
        guard manifest.adapter.id == adapterID,
              manifest.adapter.version == adapterVersion,
              manifest.adapter.abiVersion == adapterABIVersion,
              manifest.runtime.kind == .sherpaOnnxOnlineTransducer,
              manifest.networkPolicy == .offline,
              !Set(manifest.locales).intersection(supportedLocales).isEmpty,
              manifest.capabilities.maximumAlternatives == 1
        else {
            throw SherpaOnnxProductBackendError
                .unsupportedArtifactContract
        }
    }

    private static func validateRuntimeIdentity(
        _ identity: SherpaOnnxRuntimeIdentity
    ) throws {
        guard identity.sherpaVersion == adapterVersion else {
            throw SherpaOnnxProductBackendError.runtimeVersionMismatch(
                expected: adapterVersion,
                actual: identity.sherpaVersion
            )
        }
        let revision = identity.sherpaGitRevision.lowercased()
        guard revision == embeddedSherpaGitRevision
        else {
            throw SherpaOnnxProductBackendError.runtimeRevisionMismatch(
                expected: embeddedSherpaGitRevision,
                actual: identity.sherpaGitRevision
            )
        }
        guard identity.onnxRuntimeVersion == onnxRuntimeVersion else {
            throw SherpaOnnxProductBackendError
                .onnxRuntimeVersionMismatch(
                    expected: onnxRuntimeVersion,
                    actual: identity.onnxRuntimeVersion
                )
        }
    }

    private static func makeConfiguration(
        for artifact: VoiceASRVerifiedArtifact
    ) throws -> SherpaOnnxRecognizerConfiguration {
        let manifest = artifact.manifest
        let runtime = manifest.runtime
        let root = artifact.artifactDirectory.standardizedFileURL

        func absolutePath(_ relativePath: String) throws -> String {
            let url = root.appendingPathComponent(
                relativePath,
                isDirectory: false
            ).standardizedFileURL
            let prefix = root.path.hasSuffix("/")
                ? root.path
                : root.path + "/"
            guard url.path.hasPrefix(prefix),
                  url.deletingLastPathComponent().path.hasPrefix(
                      root.path
                  )
            else {
                throw SherpaOnnxProductBackendError
                    .unsafeModelPath(relativePath)
            }
            return url.path
        }

        return try SherpaOnnxRecognizerConfiguration(
            encoderPath: absolutePath(runtime.encoderPath),
            decoderPath: absolutePath(runtime.decoderPath),
            joinerPath: absolutePath(runtime.joinerPath),
            tokensPath: absolutePath(runtime.tokensPath),
            bpeVocabularyPath: absolutePath(
                runtime.bpeVocabularyPath
            ),
            sampleRateHertz: manifest.audio.sampleRateHertz,
            featureDimension: runtime.featureDimension,
            numberOfThreads: runtime.numberOfThreads,
            provider: runtime.provider.rawValue,
            modelType: runtime.modelType.rawValue,
            modelingUnit: runtime.modelingUnit.rawValue,
            decodingMethod: runtime.decodingMethod.rawValue,
            maximumActivePaths: runtime.maximumActivePaths,
            endpointEnabled: runtime.endpoint.enabled,
            rule1MinimumTrailingSilenceSeconds: Float(
                runtime.endpoint
                    .rule1MinimumTrailingSilenceMilliseconds
            ) / 1_000,
            rule2MinimumTrailingSilenceSeconds: Float(
                runtime.endpoint
                    .rule2MinimumTrailingSilenceMilliseconds
            ) / 1_000,
            rule3MinimumUtteranceSeconds: Float(
                runtime.endpoint.rule3MinimumUtteranceMilliseconds
            ) / 1_000,
            hotwordsScore: Float(runtime.hotwordsScoreMilli) / 1_000,
            blankPenalty: Float(runtime.blankPenaltyMilli) / 1_000
        )
    }

    private static func openRuntimeFiles(
        for artifact: VoiceASRVerifiedArtifact,
        configuration: SherpaOnnxRecognizerConfiguration
    ) throws -> SherpaOnnxOpenedRuntimeFiles {
        let runtime = artifact.manifest.runtime
        let paths = [
            (runtime.encoderPath, configuration.encoderPath),
            (runtime.decoderPath, configuration.decoderPath),
            (runtime.joinerPath, configuration.joinerPath),
            (runtime.tokensPath, configuration.tokensPath),
            (
                runtime.bpeVocabularyPath,
                configuration.bpeVocabularyPath
            ),
        ]
        let inventory = Dictionary(uniqueKeysWithValues:
            artifact.manifest.inventory.map { ($0.path, $0) }
        )
        var descriptors: [Int32] = []
        do {
            for (relativePath, path) in paths {
                guard let expected = inventory[relativePath] else {
                    throw SherpaOnnxProductBackendError
                        .unsupportedArtifactContract
                }
                let descriptor = open(
                    path,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    throw SherpaOnnxProductBackendError
                        .modelFileUnavailable(path)
                }
                var status = stat()
                guard fstat(descriptor, &status) == 0,
                      status.st_mode & S_IFMT == S_IFREG,
                      status.st_uid == geteuid(),
                      status.st_nlink == 1,
                      status.st_mode & mode_t(0o022) == 0,
                      status.st_size == expected.bytes
                else {
                    close(descriptor)
                    throw SherpaOnnxProductBackendError
                        .modelFileUnavailable(path)
                }
                let digest: String
                do {
                    digest = try descriptorSHA256(descriptor)
                } catch {
                    close(descriptor)
                    throw error
                }
                guard digest == expected.sha256,
                      lseek(descriptor, 0, SEEK_SET) == 0
                else {
                    close(descriptor)
                    throw SherpaOnnxProductBackendError
                        .modelFileUnavailable(path)
                }
                descriptors.append(descriptor)
            }
            return SherpaOnnxOpenedRuntimeFiles(
                descriptors: descriptors
            )
        } catch {
            for descriptor in descriptors {
                close(descriptor)
            }
            throw error
        }
    }

    private static func configuration(
        _ configuration: SherpaOnnxRecognizerConfiguration,
        boundTo files: SherpaOnnxOpenedRuntimeFiles
    ) -> SherpaOnnxRecognizerConfiguration {
        precondition(files.descriptorPaths.count == 5)
        return SherpaOnnxRecognizerConfiguration(
            encoderPath: files.descriptorPaths[0],
            decoderPath: files.descriptorPaths[1],
            joinerPath: files.descriptorPaths[2],
            tokensPath: files.descriptorPaths[3],
            bpeVocabularyPath: files.descriptorPaths[4],
            sampleRateHertz: configuration.sampleRateHertz,
            featureDimension: configuration.featureDimension,
            numberOfThreads: configuration.numberOfThreads,
            provider: configuration.provider,
            modelType: configuration.modelType,
            modelingUnit: configuration.modelingUnit,
            decodingMethod: configuration.decodingMethod,
            maximumActivePaths: configuration.maximumActivePaths,
            endpointEnabled: configuration.endpointEnabled,
            rule1MinimumTrailingSilenceSeconds:
                configuration.rule1MinimumTrailingSilenceSeconds,
            rule2MinimumTrailingSilenceSeconds:
                configuration.rule2MinimumTrailingSilenceSeconds,
            rule3MinimumUtteranceSeconds:
                configuration.rule3MinimumUtteranceSeconds,
            hotwordsScore: configuration.hotwordsScore,
            blankPenalty: configuration.blankPenalty
        )
    }

    private static func descriptorSHA256(_ descriptor: Int32) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { storage in
                read(descriptor, storage.baseAddress, storage.count)
            }
            if count > 0 {
                hasher.update(data: Data(buffer.prefix(count)))
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw SherpaOnnxProductBackendError
                .modelFileUnavailable("descriptor:\(descriptor)")
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

}

private final class SherpaOnnxOpenedRuntimeFiles: @unchecked Sendable {
    let descriptorPaths: [String]
    private let descriptors: [Int32]

    init(descriptors: [Int32]) {
        self.descriptors = descriptors
        descriptorPaths = descriptors.map { "/dev/fd/\($0)" }
    }

    deinit {
        for descriptor in descriptors {
            close(descriptor)
        }
    }
}

private final class SherpaOnnxRecognizerDriver:
    VoiceStreamingRecognizerDriver,
    @unchecked Sendable
{
    let artifactGeneration: UUID
    private let recognizer: any SherpaOnnxRecognizerRunning
    private let openedRuntimeFiles: SherpaOnnxOpenedRuntimeFiles

    init(
        artifactGeneration: UUID,
        recognizer: any SherpaOnnxRecognizerRunning,
        openedRuntimeFiles: SherpaOnnxOpenedRuntimeFiles
    ) {
        self.artifactGeneration = artifactGeneration
        self.recognizer = recognizer
        self.openedRuntimeFiles = openedRuntimeFiles
    }

    func startSession(hotwords: [String]) throws {
        try recognizer.startSession(hotwords: hotwords)
    }

    func resetEndpoint() throws {
        try recognizer.resetEndpoint()
    }

    func accept(samples: [Float]) throws -> VoiceStreamingRecognitionUpdate {
        try recognizer.accept(samples: samples)
    }

    func finish() throws -> VoiceStreamingRecognitionUpdate {
        try recognizer.finish()
    }

    func cancel() {
        recognizer.cancel()
    }
}

private struct SystemSherpaOnnxRuntime:
    SherpaOnnxRuntimeLoading,
    Sendable
{
    func identity() throws -> SherpaOnnxRuntimeIdentity {
        guard let sherpa = SherpaOnnxGetVersionStr(),
              let revision = SherpaOnnxGetGitSha1(),
              let onnx = SherpaOnnxGetOnnxruntimeVersionStr()
        else {
            throw SherpaOnnxProductBackendError.runtimeMetadataUnavailable
        }
        return SherpaOnnxRuntimeIdentity(
            sherpaVersion: String(cString: sherpa),
            sherpaGitRevision: String(cString: revision),
            onnxRuntimeVersion: String(cString: onnx)
        )
    }

    func makeRecognizer(
        configuration: SherpaOnnxRecognizerConfiguration
    ) throws -> any SherpaOnnxRecognizerRunning {
        let strings = SherpaOnnxCStringArena()
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = Int32(
            configuration.sampleRateHertz
        )
        config.feat_config.feature_dim = Int32(
            configuration.featureDimension
        )
        config.model_config.transducer.encoder = try strings.copy(
            configuration.encoderPath
        )
        config.model_config.transducer.decoder = try strings.copy(
            configuration.decoderPath
        )
        config.model_config.transducer.joiner = try strings.copy(
            configuration.joinerPath
        )
        config.model_config.tokens = try strings.copy(
            configuration.tokensPath
        )
        config.model_config.num_threads = Int32(
            configuration.numberOfThreads
        )
        config.model_config.provider = try strings.copy(
            configuration.provider
        )
        config.model_config.model_type = try strings.copy(
            configuration.modelType
        )
        config.model_config.modeling_unit = try strings.copy(
            configuration.modelingUnit
        )
        config.model_config.bpe_vocab = try strings.copy(
            configuration.bpeVocabularyPath
        )
        config.decoding_method = try strings.copy(
            configuration.decodingMethod
        )
        config.max_active_paths = Int32(
            configuration.maximumActivePaths
        )
        config.enable_endpoint = configuration.endpointEnabled ? 1 : 0
        config.rule1_min_trailing_silence =
            configuration.rule1MinimumTrailingSilenceSeconds
        config.rule2_min_trailing_silence =
            configuration.rule2MinimumTrailingSilenceSeconds
        config.rule3_min_utterance_length =
            configuration.rule3MinimumUtteranceSeconds
        config.hotwords_score = configuration.hotwordsScore
        config.blank_penalty = configuration.blankPenalty

        guard let recognizer = SherpaOnnxCreateOnlineRecognizer(&config)
        else {
            throw SherpaOnnxProductBackendError
                .recognizerInitializationFailed
        }
        guard let stream = SherpaOnnxCreateOnlineStream(recognizer) else {
            SherpaOnnxDestroyOnlineRecognizer(recognizer)
            throw SherpaOnnxProductBackendError.streamInitializationFailed
        }
        return SherpaOnnxCRecognizer(
            recognizer: recognizer,
            stream: stream
        )
    }
}

private final class SherpaOnnxCStringArena {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    func copy(_ value: String) throws -> UnsafePointer<CChar> {
        guard let pointer = strdup(value) else {
            throw SherpaOnnxProductBackendError
                .recognizerInitializationFailed
        }
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }

    deinit {
        for pointer in pointers {
            free(pointer)
        }
    }
}

private final class SherpaOnnxCRecognizer:
    SherpaOnnxRecognizerRunning,
    @unchecked Sendable
{
    private static let maximumIncrementalDecodeSteps = 256
    private static let maximumFinalDecodeSteps = 8_192

    private let recognizer: OpaquePointer
    private var stream: OpaquePointer?

    init(recognizer: OpaquePointer, stream: OpaquePointer) {
        self.recognizer = recognizer
        self.stream = stream
    }

    deinit {
        if let stream {
            SherpaOnnxDestroyOnlineStream(stream)
        }
        SherpaOnnxDestroyOnlineRecognizer(recognizer)
    }

    func startSession(hotwords: [String]) throws {
        let newStream: OpaquePointer?
        if hotwords.isEmpty {
            newStream = SherpaOnnxCreateOnlineStream(recognizer)
        } else {
            let text = hotwords.joined(separator: "\n")
            newStream = text.withCString {
                SherpaOnnxCreateOnlineStreamWithHotwords(
                    recognizer,
                    $0
                )
            }
        }
        guard let newStream else {
            throw SherpaOnnxProductBackendError.streamInitializationFailed
        }
        if let oldStream = stream {
            SherpaOnnxDestroyOnlineStream(oldStream)
        }
        stream = newStream
    }

    func resetEndpoint() throws {
        guard let stream else {
            throw SherpaOnnxProductBackendError.streamInitializationFailed
        }
        SherpaOnnxOnlineStreamReset(recognizer, stream)
    }

    func accept(samples: [Float]) throws -> VoiceStreamingRecognitionUpdate {
        guard samples.count == VoicePCMFrame.samplesPerFrame,
              samples.allSatisfy(\.isFinite),
              let stream
        else {
            throw SherpaOnnxProductBackendError.invalidAudioFrame
        }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxOnlineStreamAcceptWaveform(
                stream,
                Int32(VoicePCMFrame.sampleRateHertz),
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        try decodeReadyStream(
            stream,
            maximumSteps: Self.maximumIncrementalDecodeSteps
        )
        return try currentUpdate(stream)
    }

    func finish() throws -> VoiceStreamingRecognitionUpdate {
        guard let stream else {
            throw SherpaOnnxProductBackendError.resultUnavailable
        }
        SherpaOnnxOnlineStreamInputFinished(stream)
        try decodeReadyStream(
            stream,
            maximumSteps: Self.maximumFinalDecodeSteps
        )
        return try currentUpdate(stream)
    }

    func cancel() {
        guard let stream else { return }
        self.stream = nil
        SherpaOnnxDestroyOnlineStream(stream)
    }

    private func decodeReadyStream(
        _ stream: OpaquePointer,
        maximumSteps: Int
    ) throws {
        var steps = 0
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
            guard steps < maximumSteps else {
                throw SherpaOnnxProductBackendError
                    .decodeStepLimitExceeded
            }
            SherpaOnnxDecodeOnlineStream(recognizer, stream)
            steps += 1
        }
    }

    private func currentUpdate(
        _ stream: OpaquePointer
    ) throws -> VoiceStreamingRecognitionUpdate {
        guard let result = SherpaOnnxGetOnlineStreamResult(
            recognizer,
            stream
        ) else {
            throw SherpaOnnxProductBackendError.resultUnavailable
        }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        let text = result.pointee.text.map(String.init(cString:)) ?? ""
        return VoiceStreamingRecognitionUpdate(
            text: text,
            isEndpoint: SherpaOnnxOnlineStreamIsEndpoint(
                recognizer,
                stream
            ) != 0
        )
    }
}

/// Explicitly empty baseline provider used until a bounded Rime-derived
/// snapshot is supplied. It does not read dictionaries, documents, clipboard,
/// or history.
public struct EmptyVoiceHotwordProvider: VoiceHotwordProviding, Sendable {
    public init() {}

    public func snapshot(
        for request: VoiceDictationEngineRequest,
        maximumEntries: Int
    ) throws -> VoiceHotwordSnapshot {
        .empty
    }
}

/// Narrow assembly seam for an artifact lease admitted by another module.
/// This API cannot select a URL, invoke a verifier, read the product Store, or
/// consult the release catalog; callers must first construct the exact lease.
@_spi(VoiceArtifactAssembly)
public enum SherpaOnnxAdmittedArtifactVoiceEngineFactory {
    private struct PreparedBackend: Sendable {
        let descriptor: VoiceEngineDescriptor
        let recognizerDriver: any VoiceStreamingRecognizerDriver
    }

    @_spi(VoiceArtifactAssembly)
    public static func makeEngine(
        lease: VoiceASRVerifiedArtifactLease,
        sourceFactory: any VoicePCMSourceFactory,
        hotwordProvider: any VoiceHotwordProviding =
            RequestVoiceHotwordProvider()
    ) throws -> any VoiceDictationEngine {
        try makeEngine(
            lease: lease,
            backendLoader: SherpaOnnxProductBackendLoader(),
            sourceFactory: sourceFactory,
            hotwordProvider: hotwordProvider
        )
    }

    static func makeEngine(
        lease: VoiceASRVerifiedArtifactLease,
        backendLoader: any VoiceProductBackendLoading,
        sourceFactory: any VoicePCMSourceFactory,
        hotwordProvider: any VoiceHotwordProviding
    ) throws -> ProductStreamingVoiceEngine {
        let loaded = try backendLoader.load(lease: lease)
        guard loaded.recognizerDriver.artifactGeneration
                == lease.generation,
              loaded.loadProbe.artifactGeneration == lease.generation
        else {
            throw ProductManagedVoiceEngineBootstrapError
                .artifactGenerationMismatch
        }
        let prepared = PreparedBackend(
            descriptor: try VoiceEngineDescriptor.productManaged(
                lease: lease,
                loadProbe: loaded.loadProbe
            ),
            recognizerDriver: loaded.recognizerDriver
        )

        return try ProductStreamingVoiceEngine(
            descriptor: prepared.descriptor,
            sourceFactory: sourceFactory,
            recognizerDriver: prepared.recognizerDriver,
            hotwordProvider: hotwordProvider
        )
    }
}

/// The only production assembly entry point exported to the helper executable.
/// It fails closed when no verified current artifact exists or when the pinned
/// runtime/model contract cannot be loaded.
public enum SherpaOnnxProductVoiceEngineFactory {
    public static func makeEngine(
        layout: RimeAIProductDataLayout,
        hotwordProvider: any VoiceHotwordProviding =
            RequestVoiceHotwordProvider()
    ) throws -> any VoiceDictationEngine {
        try makeEngine(
            store: VoiceASRArtifactStore(layout: layout),
            backendLoader: SherpaOnnxProductBackendLoader(),
            sourceFactory: AVAudioEnginePCMSourceFactory(),
            hotwordProvider: hotwordProvider
        )
    }

    static func makeEngine(
        store: VoiceASRArtifactStore,
        backendLoader: any VoiceProductBackendLoading,
        sourceFactory: any VoicePCMSourceFactory,
        hotwordProvider: any VoiceHotwordProviding
    ) throws -> ProductStreamingVoiceEngine {
        try ProductManagedVoiceEngineBootstrap(
            store: store,
            backendLoader: ProductionApprovedSherpaOnnxBackendLoader(
                delegate: backendLoader
            )
        ).makeEngine(
            sourceFactory: sourceFactory,
            hotwordProvider: hotwordProvider
        )
    }
}

private struct ProductionApprovedSherpaOnnxBackendLoader:
    VoiceProductBackendLoading,
    Sendable
{
    private let delegate: any VoiceProductBackendLoading

    init(delegate: any VoiceProductBackendLoading) {
        self.delegate = delegate
    }

    func load(
        lease: VoiceASRVerifiedArtifactLease
    ) throws -> VoiceProductBackendLoad {
        guard VoiceASRTrustedArtifactCatalog.production.approves(
            lease.artifact
        ) else {
            throw SherpaOnnxProductBackendError.untrustedArtifact(
                lease.artifact.manifest.artifactID
            )
        }
        return try delegate.load(lease: lease)
    }
}
