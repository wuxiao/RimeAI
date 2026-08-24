import Foundation

public struct VoiceDictationKeyModifiers: OptionSet, Codable, Sendable {
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

public struct VoiceDictationShortcut: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
    }

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z",
        7: "X", 8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
    ]
    private static let allowedModifierShapes: [VoiceDictationKeyModifiers] = [
        [.control, .shift],
        [.option, .shift],
    ]
    private static let unsafeKeyCodes: Set<UInt16> = [
        36, // Return
        48, // Tab
        49, // Space
        51, // Delete
        53, // Escape
        54, 55, // Command
        56, 60, // Shift
        57, // Caps Lock
        58, 61, // Option
        59, 62, // Control
        63, // Function
        76, // Keypad Enter
        114, // Help
        115, 116, 117, 119, 121, // navigation / forward delete
        123, 124, 125, 126, // arrows
    ]

    public let keyCode: UInt16
    public let modifiers: VoiceDictationKeyModifiers
    public static let validationFailureDescription =
        "语音快捷键仅支持 Control-Shift 或 Option-Shift 搭配字母、数字或标点键；"
        + "其他组合可能占用 VoiceOver、macOS 系统或编辑命令。"

    /// 快捷键修饰键只接受精确的 Control-Shift 或 Option-Shift。
    /// Command、VoiceOver Control-Option、单修饰键与三修饰键空间整体保留，
    /// 避免依赖会随系统版本扩张的 Apple 快捷键枚举。
    public init?(
        keyCode: UInt16,
        modifiers: VoiceDictationKeyModifiers
    ) {
        guard Self.allowedModifierShapes.contains(modifiers),
              !Self.unsafeKeyCodes.contains(keyCode),
              Self.keyNames[keyCode] != nil
        else {
            return nil
        }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let `default` = Self(
        keyCode: 9,
        modifiers: [.control, .shift]
    )!

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let modifierBits = try container.decode(UInt8.self, forKey: .modifiers)
        guard let validated = Self(
            keyCode: keyCode,
            modifiers: VoiceDictationKeyModifiers(rawValue: modifierBits)
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .keyCode,
                in: container,
                debugDescription: Self.validationFailureDescription
            )
        }
        self = validated
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers.rawValue, forKey: .modifiers)
    }

    public var displayName: String {
        var result = ""
        if modifiers.contains(.control) {
            result += "⌃"
        }
        if modifiers.contains(.option) {
            result += "⌥"
        }
        if modifiers.contains(.shift) {
            result += "⇧"
        }
        if modifiers.contains(.command) {
            result += "⌘"
        }
        result += Self.keyNames[keyCode]!
        return result
    }

    public func matches(
        keyCode: UInt16,
        modifiers eventModifiers: VoiceDictationKeyModifiers
    ) -> Bool {
        guard keyCode == self.keyCode else {
            return false
        }
        var semantic = eventModifiers
        semantic.remove([.capsLock, .numericPad])
        return semantic == modifiers
    }
}

struct VoiceHotKeyRegistrationState: Equatable, Sendable {
    enum Activation: Equatable, Sendable {
        case unchanged(registrationID: UInt32)
        case register(
            registrationID: UInt32,
            endedPressedRegistrationID: UInt32?
        )
    }

    private(set) var registrationID: UInt32 = 0
    private(set) var registeredShortcut: VoiceDictationShortcut?
    private(set) var pressedRegistrationID: UInt32?

    mutating func activate(
        shortcut: VoiceDictationShortcut
    ) -> Activation {
        if registeredShortcut == shortcut {
            return .unchanged(registrationID: registrationID)
        }
        let endedPress = pressedRegistrationID
        advanceGeneration()
        registeredShortcut = shortcut
        pressedRegistrationID = nil
        return .register(
            registrationID: registrationID,
            endedPressedRegistrationID: endedPress
        )
    }

    mutating func press(registrationID: UInt32) -> Bool {
        guard registeredShortcut != nil,
              registrationID == self.registrationID,
              pressedRegistrationID == nil
        else {
            return false
        }
        pressedRegistrationID = registrationID
        return true
    }

    mutating func release(registrationID: UInt32) -> Bool {
        guard registrationID == self.registrationID,
              pressedRegistrationID == registrationID
        else {
            return false
        }
        pressedRegistrationID = nil
        return true
    }

    @discardableResult
    mutating func deactivate() -> UInt32? {
        let endedPress = pressedRegistrationID
        guard registeredShortcut != nil || endedPress != nil else {
            return nil
        }
        advanceGeneration()
        registeredShortcut = nil
        pressedRegistrationID = nil
        return endedPress
    }

    mutating func registrationFailed(registrationID: UInt32) {
        guard registrationID == self.registrationID else {
            return
        }
        advanceGeneration()
        registeredShortcut = nil
        pressedRegistrationID = nil
    }

    private mutating func advanceGeneration() {
        registrationID &+= 1
        if registrationID == 0 {
            registrationID = 1
        }
    }
}

enum VoiceHotKeyRegistrationEvaluation: Equatable, Sendable {
    case registered
    case conflict
    case systemFailure(status: Int32)
    case invalidRegistration
}

struct VoiceHotKeyRegistrationPolicy {
    /// Carbon 会允许 non-exclusive 注册在已有 exclusive holder 时返回
    /// `noErr`，但随后不会派发事件。只有明确请求 exclusive、状态成功且
    /// 返回有效 reference 时，注册层才能对 UI 声称快捷键可用。
    static func evaluate(
        requestedExclusive: Bool,
        status: Int32,
        referenceWasCreated: Bool,
        conflictStatus: Int32
    ) -> VoiceHotKeyRegistrationEvaluation {
        guard requestedExclusive else {
            return .invalidRegistration
        }
        if status == conflictStatus {
            return .conflict
        }
        if status != 0 {
            return .systemFailure(status: status)
        }
        return referenceWasCreated ? .registered : .invalidRegistration
    }
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
        keyCode: UInt16,
        modifiers: VoiceDictationKeyModifiers,
        shortcut: VoiceDictationShortcut
    ) -> Bool {
        shortcut.matches(keyCode: keyCode, modifiers: modifiers)
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
