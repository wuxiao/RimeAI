import RimeAIInputCore

/// 默认引擎是诚实的不可用骨架：不访问麦克风、不触发 TCC，也不伪造
/// 识别能力。引擎被直接启动时明确失败 `mic_unavailable`；经协议
/// 服务端时其 ready 能力为空，start 会在能力门被 invalid_request
/// 拒绝，到不了引擎。
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
