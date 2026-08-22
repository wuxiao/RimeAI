import Foundation
import RimeAIInputCore

/// Product ASR 的固定 decoder 输入。采集层必须先完成重采样、混声道和
/// Float32 归一化，再把拥有自身存储的 20 ms frame 交给识别队列。
public struct VoicePCMFrame: Equatable, Sendable {
    public static let sampleRateHertz = 16_000
    public static let samplesPerFrame = 320

    public let samples: [Float]

    public init(samples: [Float]) {
        self.samples = samples
    }

    public var isValid: Bool {
        samples.count == Self.samplesPerFrame
            && samples.allSatisfy(\.isFinite)
    }
}

public struct VoicePCMSourceFailure: Equatable, Sendable {
    public let code: VoiceDictationErrorCode
    public let retryable: Bool

    public init(code: VoiceDictationErrorCode, retryable: Bool) {
        self.code = code
        self.retryable = retryable
    }
}

/// 一次听写会话独占一个 source。正常 `stop()` 会排空已接收输入并可
/// 零填最后不足 20 ms 的尾帧；`cancel()` 必须丢弃尾帧。二者返回后都
/// 不得再投递 frame。
public protocol VoicePCMSource: AnyObject, Sendable {
    func start(
        onFrame: @escaping @Sendable (VoicePCMFrame) -> Void,
        onFailure: @escaping @Sendable (VoicePCMSourceFailure) -> Void
    ) throws

    func stop()
    func cancel()
}

public protocol VoicePCMSourceFactory: Sendable {
    func makeSource() throws -> any VoicePCMSource
}

/// recognizer 当前私有 stream 的可见结果。`isEndpoint` 只结束当前
/// 分段；用户松开前不得把它直接变成 wire final。
struct VoiceStreamingRecognitionUpdate: Equatable, Sendable {
    let text: String
    let isEndpoint: Bool

    init(text: String, isEndpoint: Bool) {
        self.text = text
        self.isEndpoint = isEndpoint
    }
}

/// 一个已加载 artifact generation 独占的同步 decoder seam。所有方法
/// 只能由产品引擎的同一串行 decoder queue 调用。
protocol VoiceStreamingRecognizerDriver: AnyObject, Sendable {
    /// Store lease generation whose immutable model files were synchronously
    /// opened when this recognizer was constructed.
    var artifactGeneration: UUID { get }

    /// Starts a new protocol request with a fresh native stream. No decoder or
    /// buffered-audio state may cross this boundary.
    func startSession(hotwords: [String]) throws

    /// Advances the current request across an endpoint while preserving any
    /// native audio that has not yet been consumed by the decoder.
    func resetEndpoint() throws
    func accept(samples: [Float]) throws -> VoiceStreamingRecognitionUpdate
    func finish() throws -> VoiceStreamingRecognitionUpdate
    func cancel()
}

enum VoiceProductBackendLoadError: Error, Equatable, Sendable {
    case unsupportedArtifactContract
    case recognizerInitializationFailed
    case emptyStreamProbeFailed
    case artifactGenerationMismatch
    case unexpectedRuntimeFailure
}

/// A recognizer and its independently observed runtime facts. The initializer
/// rejects a mixed-generation pair before it can reach descriptor creation.
struct VoiceProductBackendLoad: Sendable {
    let recognizerDriver: any VoiceStreamingRecognizerDriver
    let loadProbe: VoiceProductEngineLoadProbe

    init(
        recognizerDriver: any VoiceStreamingRecognizerDriver,
        loadProbe: VoiceProductEngineLoadProbe
    ) throws {
        guard recognizerDriver.artifactGeneration
            == loadProbe.artifactGeneration
        else {
            throw VoiceProductBackendLoadError.artifactGenerationMismatch
        }
        self.recognizerDriver = recognizerDriver
        self.loadProbe = loadProbe
    }
}

/// Synchronously opens every model file, constructs the recognizer, and runs
/// its non-empty hotword-capacity and fresh empty-stream load probes while the
/// Store lease remains locked. A loader must not retain the lease for deferred
/// path access, call Store APIs, request TCC permission, or start microphone
/// capture.
protocol VoiceProductBackendLoading: Sendable {
    func load(
        lease: VoiceASRVerifiedArtifactLease
    ) throws -> VoiceProductBackendLoad
}

public protocol VoiceHotwordProviding: Sendable {
    func snapshot(
        for request: VoiceDictationEngineRequest,
        maximumEntries: Int
    ) throws -> VoiceHotwordSnapshot
}

/// Production provider: consumes only the immutable snapshot already admitted
/// by the V2 request. It performs no filesystem, history, clipboard, or Rime
/// database IO on the microphone-start path.
public struct RequestVoiceHotwordProvider: VoiceHotwordProviding, Sendable {
    public init() {}

    public func snapshot(
        for request: VoiceDictationEngineRequest,
        maximumEntries: Int
    ) throws -> VoiceHotwordSnapshot {
        try request.hotwordSnapshot.limited(to: maximumEntries)
    }
}
