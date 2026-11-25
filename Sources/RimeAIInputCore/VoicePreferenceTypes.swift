import Foundation

// MARK: - Polish Style & Translation Language
//
// 轻量的纯偏好类型：只依赖 Foundation，供 iOS 便携核心（RimeAISettingsStore）
// 与 macOS 语音功能共用。不要在此文件引入语音运行时依赖。

public enum VoicePolishStyle: String, CaseIterable, Codable, Sendable {
    case concise = "concise"
    case formal = "formal"
    case casual = "casual"
    case structured = "structured"

    public var displayName: String {
        switch self {
        case .concise:
            return "精简书面（去口头语、补标点）"
        case .formal:
            return "正式专业（邮件 / 文档 / 汇报）"
        case .casual:
            return "自然流畅（即时聊天 / 社交）"
        case .structured:
            return "条理整理（理顺长段逻辑）"
        }
    }

    public var shortName: String {
        switch self {
        case .concise:
            return "精简书面"
        case .formal:
            return "正式专业"
        case .casual:
            return "自然流畅"
        case .structured:
            return "条理整理"
        }
    }
}

public enum VoiceTranslationLanguage: String, CaseIterable, Codable, Sendable {
    case autoEnZh = "auto_en_zh"
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"

    public var displayName: String {
        switch self {
        case .autoEnZh:
            return "中英互译（自动识别）"
        case .english:
            return "英语 (English)"
        case .simplifiedChinese:
            return "简体中文"
        case .japanese:
            return "日语 (日本語)"
        case .korean:
            return "韩语 (한국어)"
        case .french:
            return "法语 (Français)"
        case .german:
            return "德语 (Deutsch)"
        case .spanish:
            return "西班牙语 (Español)"
        }
    }

    public var shortName: String {
        switch self {
        case .autoEnZh:
            return "中英互译"
        case .english:
            return "英语"
        case .simplifiedChinese:
            return "中文"
        case .japanese:
            return "日语"
        case .korean:
            return "韩语"
        case .french:
            return "法语"
        case .german:
            return "德语"
        case .spanish:
            return "西班牙语"
        }
    }
}
