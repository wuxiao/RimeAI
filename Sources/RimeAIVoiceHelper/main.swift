import Darwin
import Foundation
import RimeAIInputCore
import RimeAIVoiceHelperEngine

/// rimeai-voice-helper 的协议服务端。开发 Debug 可由 --engine 选择引擎
/// 并显式使用私有 UDS；Release 引擎只由签名 bundle 内的严格 policy
/// 选择，且只接受固定 launchd Mach service 并进行双向签名与当前用户
/// 校验，认证或 policy 校验失败时绝不降级：
/// - unavailable：诚实骨架，任何听写请求显式返回
///   mic_unavailable，不假装能识别。
/// - apple-speech：Apple Speech on-device（SFSpeechRecognizer +
///   AVAudioEngine）。识别路径需要语音与麦克风 TCC 授权，授权/设备
///   不可用经协议显式报错；识别质量门尚未真机验证，见
///   docs/VOICE_INPUT_DESIGN.md 第 8 节。
/// - product-managed：只从产品托管 Store 的 current selector 装载经
///   严格校验的 sherpa-onnx 模型；无 selector、模型或运行时不匹配时
///   在申请 TCC/打开麦克风前退出，绝不回退到系统或云识别。
let arguments = CommandLine.arguments
// helper 只产生当前用户私有的运行态制品。尤其保证 NWListener 创建的
// socket 从出生起即不会因继承常见 022 umask 而短暂暴露宽权限。
_ = umask(mode_t(0o177))

#if DEBUG
let debugArguments: VoiceHelperDebugArguments
do {
    debugArguments = try VoiceHelperReleaseBootstrap.parseDebugArguments(
        arguments
    )
} catch {
    FileHandle.standardError.write(Data(
        (
            "Debug 用法: rimeai-voice-helper --socket <path> "
                + "[--engine unavailable|apple-speech|product-managed]\n"
        ).utf8
    ))
    exit(64)
}
let socketPath = debugArguments.socketPath
let engineName = debugArguments.engineName
let engine: any VoiceDictationEngine
switch engineName {
case "apple-speech":
    engine = AppleSpeechEngine()
case "product-managed":
    do {
        engine = try SherpaOnnxProductVoiceEngineFactory.makeEngine(
            layout: RimeAIProductDataLayout(
                homeDirectory: FileManager.default
                    .homeDirectoryForCurrentUser
            )
        )
    } catch {
        FileHandle.standardError.write(Data(
            "产品托管语音引擎初始化失败: \(error)\n".utf8
        ))
        exit(78)
    }
case "unavailable":
    engine = UnavailableVoiceEngine()
default:
    FileHandle.standardError.write(
        Data("未知引擎: \(engineName)\n".utf8)
    )
    exit(64)
}
#else
do {
    try VoiceHelperReleaseBootstrap.validateReleaseArguments(arguments)
} catch {
    FileHandle.standardError.write(Data(
        "Release 用法: rimeai-voice-helper --mach-service \(VoiceDictationXPCConstants.machServiceName)\n".utf8
    ))
    exit(64)
}

let engine: any VoiceDictationEngine
do {
    engine = try VoiceHelperReleaseBootstrap(
        layout: RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    ).makeEngine(bundleURL: Bundle.main.bundleURL)
} catch {
    FileHandle.standardError.write(Data(
        "Release 语音 policy 装配失败: \(error)\n".utf8
    ))
    exit(78)
}
let engineName = engine.descriptor.adapterID
#endif

let core = VoiceDictationServerCore(engine: engine)
private protocol VoiceHelperServer: AnyObject, Sendable {
    func start() throws
    func stop()
}

extension VoiceDictationServerTransport: VoiceHelperServer {}
extension VoiceDictationXPCServerTransport: VoiceHelperServer {}

private let server: any VoiceHelperServer
let transportDescription: String
#if DEBUG
server = VoiceDictationServerTransport(socketPath: socketPath, core: core)
transportDescription = "私有开发 socket \(socketPath)"
#else
let machServiceName = VoiceDictationXPCConstants.machServiceName
do {
    server = try VoiceDictationXPCServerTransport(
        machServiceName: machServiceName,
        core: core
    )
} catch {
    FileHandle.standardError.write(Data(
        "认证 XPC 初始化失败: \(error)\n".utf8
    ))
    exit(1)
}
transportDescription = "认证 Mach service \(machServiceName)"
#endif

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
            "rimeai-voice-helper 已启动 \(transportDescription)（引擎 \(engineName)，"
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
