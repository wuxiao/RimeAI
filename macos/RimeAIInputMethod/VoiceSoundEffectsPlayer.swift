import AppKit
import Foundation

/// 语音交互提示音播放器（类似网易叭哥说 / macOS 听写反馈音）。
/// 使用 macOS 内置轻量系统音效，零外部资源依赖且不阻塞主线程。
@MainActor
final class VoiceSoundEffectsPlayer {
    static let shared = VoiceSoundEffectsPlayer()

    /// 声音来源出口：生产环境加载系统音效，测试注入静音样本以验证分发。
    typealias SoundProvider = (VoiceSoundEffectKind) -> NSSound?

    private let soundProvider: SoundProvider
    private var cachedTemplates: [VoiceSoundEffectKind: NSSound] = [:]
    /// 实际送入播放的音效种类（按顺序），供测试断言分发结果。
    private(set) var playedKinds: [VoiceSoundEffectKind] = []

    private init() {
        soundProvider = VoiceSoundEffectsPlayer.loadSystemSound
    }

    init(soundProvider: @escaping SoundProvider) {
        self.soundProvider = soundProvider
    }

    func play(
        _ kind: VoiceSoundEffectKind,
        enabled: Bool = RimeAISettingsStore.shared.voiceSoundEffectsEnabled
    ) {
        // 关闭提示音时绝不触碰声音加载，更不能出声。
        guard enabled else {
            return
        }
        guard let template = providerTemplate(for: kind),
              let instance = template.copy() as? NSSound
        else {
            return
        }
        // 每次播放使用独立实例，连续触发时不会把上一声截断。
        instance.volume = Self.volume(for: kind)
        playedKinds.append(kind)
        instance.play()
    }

    /// 开始录音前播放启动音并给出足够让提示音播出的短暂延迟（毫秒），
    /// 避免“语音输入时自动静音”把启动音自己切掉。
    static let startSoundLeadInMilliseconds = 140

    private func providerTemplate(for kind: VoiceSoundEffectKind) -> NSSound? {
        if let existing = cachedTemplates[kind] {
            return existing
        }
        guard let loaded = soundProvider(kind) else {
            return nil
        }
        cachedTemplates[kind] = loaded
        return loaded
    }

    static func loadSystemSound(for kind: VoiceSoundEffectKind) -> NSSound? {
        for name in systemSoundNames(for: kind) {
            if let sound = NSSound(named: NSSound.Name(name)) {
                return sound
            }
            let path = "/System/Library/Sounds/\(name).aiff"
            if FileManager.default.fileExists(atPath: path),
               let sound = NSSound(contentsOfFile: path, byReference: true)
            {
                return sound
            }
        }
        return nil
    }

    private static func systemSoundNames(for kind: VoiceSoundEffectKind) -> [String] {
        switch kind {
        case .start:
            return ["Tink", "Pop", "Purr"]
        case .stop:
            return ["Morse", "Pop", "Tink"]
        case .success:
            return ["Glass", "Hero", "Tink"]
        case .cancel:
            return ["Funk", "Submarine", "Basso"]
        case .error:
            return ["Basso", "Sosumi", "Funk"]
        }
    }

    static func volume(for kind: VoiceSoundEffectKind) -> Float {
        switch kind {
        case .start:
            return 0.45
        case .stop:
            return 0.35
        case .success:
            return 0.40
        case .cancel:
            return 0.32
        case .error:
            return 0.38
        }
    }
}
