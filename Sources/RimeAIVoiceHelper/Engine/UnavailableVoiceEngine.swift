import RimeAIInputCore

/// 默认引擎是诚实的不可用骨架：不访问麦克风、不触发 TCC，也不伪造
/// 识别能力。每次请求都明确返回 `mic_unavailable`。
public struct UnavailableVoiceEngine: VoiceDictationEngine {
    public static let adapterDescriptor = VoiceEngineDescriptor.unavailable(
        adapterID: "unavailable-stub",
        adapterVersion: "1.0.0"
    )

    public var descriptor: VoiceEngineDescriptor {
        Self.adapterDescriptor
    }

    public init() {}

    public func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {
        events(.failed(.micUnavailable, retryable: false))
    }

    public func stop(requestID: String) {}

    public func cancel(requestID: String) {}
}
