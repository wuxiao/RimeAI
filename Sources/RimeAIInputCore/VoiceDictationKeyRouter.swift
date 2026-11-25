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

    public static let rightCommandKeyCode: UInt16 = 54

    public let keyCode: UInt16
    public let modifiers: VoiceDictationKeyModifiers
    public static let validationFailureDescription =
        "语音快捷键仅支持 Control-Shift 或 Option-Shift 搭配字母、数字或标点键，"
        + "或单独点按右侧 Command（右 ⌘）；其他组合可能占用 VoiceOver、macOS 系统或编辑命令。"

    /// 是否为单修饰键点按切换模式（如右侧 Command：按一下开始、再按一下结束）。
    public var isModifierTap: Bool {
        keyCode == Self.rightCommandKeyCode && modifiers == [.command]
    }

    /// 快捷键修饰键接受精确的 Control-Shift / Option-Shift + 普通键，
    /// 或单独点按右侧 Command（keyCode 54，切换开始/结束）。
    /// 左侧 Command、VoiceOver Control-Option、单修饰键组合与三修饰键空间整体保留，
    /// 避免依赖会随系统版本扩张的 Apple 快捷键枚举。
    public init?(
        keyCode: UInt16,
        modifiers: VoiceDictationKeyModifiers
    ) {
        if keyCode == Self.rightCommandKeyCode && modifiers == [.command] {
            self.keyCode = keyCode
            self.modifiers = modifiers
            return
        }
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

    /// 一键语音翻译默认快捷键：Control-Shift-T（T = Translate）。
    public static let defaultTranslate = Self(
        keyCode: 17,
        modifiers: [.control, .shift]
    )!

    public static let rightCommand = Self(
        keyCode: rightCommandKeyCode,
        modifiers: [.command]
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
        if isModifierTap {
            return "右 ⌘"
        }
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
    /// 云端润色 / 翻译仍在进行时按下了确认键：放弃等待云端结果，
    /// 立即用本地已识别的原始文本上屏（调用方负责取消进行中的变换）。
    case commitRawDuringTransform
    case cancelAndConsume
    case cancelAndContinue
    case passThrough
}

public enum VoiceDictationKeyRouter {
    /// Space / Return / Keypad Enter：既有的三个确认键位。
    private static let confirmationKeyCodes: Set<UInt16> = [49, 36, 76]

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
        isTransforming: Bool = false,
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
        let isConfirmationKey = isPlainConfirmationKey
            && confirmationKeyCodes.contains(keyCode)
        if isTransforming, isConfirmationKey {
            // 变换（润色 / 翻译）尚未返回：确认键不再等待云端，
            // 直接提交本地原始识别文本。
            return .commitRawDuringTransform
        }
        if pendingConfirmation, isConfirmationKey {
            return .confirm
        }
        return .cancelAndContinue
    }
}

/// 纯逻辑状态机：识别“单独点按右侧 Command 键（按一下松开，期间未按其他键或修饰键）”。
/// 用于切换式语音听写（按一下启动，再按一下结束），不干扰 `右⌘+C/V` 等组合快捷键。
public struct VoiceModifierTapDetector: Equatable, Sendable {
    public static let maximumTapDurationSeconds: TimeInterval = 0.65

    private var armedTimestamp: TimeInterval?

    public init() {}

    public mutating func reset() {
        armedTimestamp = nil
    }

    /// 处理任意非修饰键按下（如 `右⌘+C`），立即取消待触发态。
    public mutating func handleOtherKeyDown() {
        armedTimestamp = nil
    }

    /// 处理 `flagsChanged` 事件；返回 `true` 表示完成一次干净的右 Command 点按。
    public mutating func handleFlagsChanged(
        keyCode: UInt16,
        modifiers: VoiceDictationKeyModifiers,
        timestamp: TimeInterval,
        shortcut: VoiceDictationShortcut
    ) -> Bool {
        guard shortcut.isModifierTap else {
            armedTimestamp = nil
            return false
        }
        var semantic = modifiers
        semantic.remove([.capsLock, .numericPad])

        guard keyCode == shortcut.keyCode else {
            // 其他修饰键按下或释放（如 Shift / Option / Control / Left Command）
            armedTimestamp = nil
            return false
        }

        if semantic == [.command] {
            // 右 Command 单独按下，进入待确认点按态
            armedTimestamp = timestamp
            return false
        }

        if semantic.isEmpty, let start = armedTimestamp {
            armedTimestamp = nil
            let elapsed = timestamp - start
            return elapsed >= 0 && elapsed <= Self.maximumTapDurationSeconds
        }

        // 组合了其他修饰键（如 右⌘+⇧）
        armedTimestamp = nil
        return false
    }
}
