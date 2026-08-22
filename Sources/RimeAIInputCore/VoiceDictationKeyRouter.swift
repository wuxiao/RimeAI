import Foundation

public struct VoiceDictationKeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let capsLock = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let control = Self(rawValue: 1 << 2)
    public static let option = Self(rawValue: 1 << 3)
    public static let command = Self(rawValue: 1 << 4)
    public static let numericPad = Self(rawValue: 1 << 5)
    public static let help = Self(rawValue: 1 << 6)
    public static let function = Self(rawValue: 1 << 7)
}

/// 把 AppKit 键盘事件归约为语音动作。Carbon 独占按住说话的 pressed /
/// released 配对；这里保持纯逻辑，确保语音确认键不会改变既有 Tab、数字
/// 与普通 Space 行为。
public enum VoiceDictationKeyDecision: Equatable, Sendable {
    case consumeShortcut
    case confirm
    case cancelAndConsume
    case cancelAndContinue
    case passThrough
}

public enum VoiceDictationKeyRouter {
    public static func isExactVoiceShortcut(
        modifiers: VoiceDictationKeyModifiers
    ) -> Bool {
        var semantic = modifiers
        semantic.remove(.capsLock)
        return semantic == [.control, .shift]
    }

    public static func isPlainConfirmation(
        modifiers: VoiceDictationKeyModifiers
    ) -> Bool {
        var semantic = modifiers
        semantic.remove([.capsLock, .numericPad])
        return semantic.isEmpty
    }

    public static func decision(
        keyCode: UInt16,
        isExactVoiceShortcut: Bool,
        shortcutRegistered: Bool,
        hasActiveSession: Bool,
        pendingConfirmation: Bool,
        isPlainConfirmationKey: Bool
    ) -> VoiceDictationKeyDecision {
        if isExactVoiceShortcut {
            // 录音只能由 Carbon pressed 回调启动，因为只有它能证明同一
            // registration 会收到 release。IMK 路径绝不自行 start；若
            // 热键刚在本次 keyDown 中注册，也只消费本次事件。
            return shortcutRegistered ? .consumeShortcut : .passThrough
        }

        guard hasActiveSession else {
            return .passThrough
        }
        if keyCode == 53 { // Escape
            return .cancelAndConsume
        }
        if pendingConfirmation,
           isPlainConfirmationKey,
           keyCode == 49 || keyCode == 36 || keyCode == 76
        {
            return .confirm
        }
        return .cancelAndContinue
    }
}
