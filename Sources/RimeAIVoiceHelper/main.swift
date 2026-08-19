import Foundation
import RimeAIInputCore

/// rimeai-voice-helper 的协议服务端。引擎由 --engine 选择：
/// - unavailable（默认）：诚实骨架，任何听写请求显式返回
///   mic_unavailable，不假装能识别。
/// - apple-speech：Apple Speech on-device（SFSpeechRecognizer +
///   AVAudioEngine）。识别路径需要语音与麦克风 TCC 授权，授权/设备
///   不可用经协议显式报错；识别质量门尚未真机验证，见
///   docs/VOICE_INPUT_DESIGN.md 第 8 节。
struct UnavailableVoiceEngine: VoiceDictationEngine {
    let engineID = "unavailable-stub"

    func start(
        requestID: String,
        mode: VoiceDictationMode,
        deadlineMilliseconds: Int,
        maximumDurationMilliseconds: Int,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {
        events(.failed(.micUnavailable, retryable: false))
    }

    func cancel(requestID: String) {}
}

let arguments = CommandLine.arguments
guard let socketFlagIndex = arguments.firstIndex(of: "--socket"),
      arguments.indices.contains(socketFlagIndex + 1)
else {
    FileHandle.standardError.write(
        Data(
            (
                "用法: rimeai-voice-helper --socket <path> "
                    + "[--engine unavailable|apple-speech]\n"
            ).utf8
        )
    )
    exit(64)
}

let socketPath = arguments[socketFlagIndex + 1]
let engineName = value(of: "--engine", in: arguments) ?? "unavailable"
let engine: any VoiceDictationEngine
switch engineName {
case "apple-speech":
    engine = AppleSpeechEngine()
case "unavailable":
    engine = UnavailableVoiceEngine()
default:
    FileHandle.standardError.write(
        Data("未知引擎: \(engineName)\n".utf8)
    )
    exit(64)
}

func value(of flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag),
          arguments.indices.contains(index + 1)
    else {
        return nil
    }
    return arguments[index + 1]
}

let core = VoiceDictationServerCore(engine: engine)
let server = VoiceDictationServerTransport(socketPath: socketPath, core: core)

do {
    try server.start()
} catch {
    FileHandle.standardError.write(
        Data("启动失败: \(error)\n".utf8)
    )
    exit(1)
}

FileHandle.standardError.write(
    Data(
        (
            "rimeai-voice-helper 已监听 \(socketPath)（引擎 \(engineName)，"
                + "network_policy=offline）\n"
        ).utf8
    )
)

let signalSource = DispatchSource.makeSignalSource(
    signal: SIGTERM,
    queue: DispatchQueue.main
)
signal(SIGTERM, SIG_IGN)
signalSource.setEventHandler {
    server.stop()
    exit(0)
}
signalSource.resume()

dispatchMain()
