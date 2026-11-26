import AppKit
import ApplicationServices
import Foundation

// MARK: - 启动闸门

/// 无法启动语音听写的原因。每一条都有面向用户的说明，绝不静默无反应。
enum VoiceDictationStartBlocker: Equatable {
    case secureInput
    case voiceDisabled
    case aiDisabledForApplication
    case hostInactive
    case compositionActive
    case helperDisabled
    case microphoneDenied

    static let toastTitle = "无法开始语音听写"

    var message: String {
        switch self {
        case .secureInput:
            return "安全输入已开启（如密码框），语音听写暂不可用。"
        case .voiceDisabled:
            return "语音输入未启用，可在 RimeAI 设置中开启。"
        case .aiDisabledForApplication:
            return "当前应用已关闭 AI 功能，语音听写不可用。"
        case .hostInactive:
            return "输入目标尚未就绪，请稍后再试。"
        case .compositionActive:
            return "有未上屏的拼音内容，请先完成输入再开始语音。"
        case .helperDisabled:
            return "语音服务连续失败，已在本次输入法进程中停用。可在 RimeAI 设置中重试。"
        case .microphoneDenied:
            return "麦克风或语音识别权限已被拒绝，请在系统设置的“隐私与安全性”中授权。"
        }
    }

    var settingsPane: VoiceSystemSettingsPane? {
        self == .microphoneDenied ? .microphone : nil
    }
}

/// 纯逻辑启动闸门：与 `canStartVoiceDictation` 的判定一一对应，
/// 并把“为什么不行的原因”保留下来用于提示。
enum VoiceDictationStartGate {
    static func blocker(
        voiceEnabled: Bool,
        aiAllowed: Bool,
        isHostActive: Bool,
        hasActiveComposition: Bool,
        isSecureInput: Bool
    ) -> VoiceDictationStartBlocker? {
        if isSecureInput {
            return .secureInput
        }
        if !voiceEnabled {
            return .voiceDisabled
        }
        if !aiAllowed {
            return .aiDisabledForApplication
        }
        if !isHostActive {
            return .hostInactive
        }
        if hasActiveComposition {
            return .compositionActive
        }
        return nil
    }
}

// MARK: - 降级复制卡片

/// 无法自动上屏时，常驻复制浮窗必须说清楚真实原因。
enum VoicePersistentCopyReason: Equatable {
    /// 开始听写时就没有可用光标。
    case noCursor
    /// 录音期间焦点切换到了其他应用/输入框。
    case focusSwitched
    /// 已具备辅助功能权限但合成 ⌘V 失败：文本已在剪贴板。
    case commandVUnavailable
    /// 无辅助功能权限：文本已在剪贴板，需手动粘贴。
    case accessibilityNeeded
    /// 粘贴瞬间检测到安全输入：剪贴板未被改动。
    case secureInputBlocked
    /// 光标仍在原处，但宿主拒绝写入（且未尝试或无法 ⌘V）。
    case hostRefusedCommit

    var hint: String {
        switch self {
        case .noCursor:
            return "未检测到光标，内容已保留在浮窗"
        case .focusSwitched:
            return "焦点已切换，内容已保留在浮窗"
        case .hostRefusedCommit:
            return "当前应用无法直接写入，内容已保留在浮窗"
        case .commandVUnavailable:
            return "已复制到剪贴板，请按 ⌘V 粘贴"
        case .accessibilityNeeded:
            return "已复制到剪贴板，请按 ⌘V 粘贴（开启辅助功能权限可自动粘贴）"
        case .secureInputBlocked:
            return "安全输入已开启，内容已保留在浮窗"
        }
    }

    var offersAccessibilityAuthorization: Bool {
        self == .accessibilityNeeded
    }
}

enum VoiceClipboardFallbackPolicy {
    /// 上屏失败后的降级原因。`hadEditableTarget` 表示开始时曾有可用光标。
    static func reason(
        pasteOutcome: VoiceClipboardPaster.Outcome?,
        hadEditableTarget: Bool,
        focusSwitched: Bool,
        isAccessibilityTrusted: Bool
    ) -> VoicePersistentCopyReason {
        if let pasteOutcome {
            switch pasteOutcome {
            case .pastedViaCommandV:
                // 已成功粘贴，调用方不会走到降级；按焦点语义兜底。
                break
            case .blocked:
                return .secureInputBlocked
            case .copiedToClipboardOnly:
                return isAccessibilityTrusted
                    ? .commandVUnavailable
                    : .accessibilityNeeded
            }
        }
        guard hadEditableTarget else {
            return .noCursor
        }
        // 开始时有可用光标：之后焦点/选区离开 → 焦点已切换；
        // 光标仍在原处却写不进去 → 宿主拒绝写入（两种原因对用户含义不同）。
        return focusSwitched ? .focusSwitched : .hostRefusedCommit
    }
}

/// IMK `insertText` 在部分宿主（Electron/网页输入框）会“成功返回但什么
/// 也没插入”。上屏后回读同一区段：内容与插入前原封不动即为缺失，交由
/// ⌘V 回退；宿主做了改写（智能引号等）时无法断定，保守视为已插入，
/// 绝不因误判而重复上屏。
enum VoiceCommitReadback {
    enum Verdict: Equatable {
        case inserted
        case missing
        case unknown
    }

    /// 光标位置是第二重佐证：插入成功后光标必然前进一个文本长度。它只能
    /// 把“缺失”升级为“已插入”（某些宿主的回读恒定返回无关内容），绝不会
    /// 反向降级，因此不会增加重复上屏的风险。
    static func verify(
        committedText: String,
        baseline: String?,
        readback: String?,
        caretBefore: Int? = nil,
        caretAfter: Int? = nil
    ) -> Verdict {
        let verdict = verifyReadback(
            committedText: committedText,
            baseline: baseline,
            readback: readback
        )
        guard verdict == .missing,
              let caretBefore,
              let caretAfter,
              caretAfter == caretBefore + committedText.utf16.count
        else {
            return verdict
        }
        return .inserted
    }

    private static func verifyReadback(
        committedText: String,
        baseline: String?,
        readback: String?
    ) -> Verdict {
        guard let readback else {
            return .unknown
        }
        let expected = normalize(committedText)
        let actual = normalize(readback)
        if actual == expected {
            return .inserted
        }
        if actual == normalize(baseline ?? "") {
            return .missing
        }
        return .inserted
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 失败浮窗与系统设置

enum VoiceSystemSettingsPane: Equatable {
    case microphone
    case speechRecognition
    case accessibility

    var url: URL? {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .speechRecognition:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}

@MainActor
enum VoiceSystemSettingsOpener {
    static func open(_ pane: VoiceSystemSettingsPane) {
        guard let url = pane.url else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
enum VoiceAccessibilityAuthorization {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 触发系统“辅助功能”授权提示；系统已不再弹窗时改为直接打开隐私面板。
    static func requestPrompt() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            VoiceSystemSettingsOpener.open(.accessibility)
        }
    }
}

/// 失败浮窗的动作与去留：权限类失败常驻并给出系统设置入口；非权限的
/// 瞬时错误自动收起，但都保留“重试”。
struct VoiceFailurePresentation: Equatable {
    static let transientAutoDismissSeconds: TimeInterval = 6

    var settingsPane: VoiceSystemSettingsPane?
    var offersRetry = true
    var autoDismissSeconds: TimeInterval?

    static let microphonePermission = VoiceFailurePresentation(
        settingsPane: .microphone
    )
    static let serviceDisabled = VoiceFailurePresentation()
    static let incompatibleProtocol = VoiceFailurePresentation(
        offersRetry: false
    )
    static let transient = VoiceFailurePresentation(
        autoDismissSeconds: transientAutoDismissSeconds
    )

    static func presentation(
        for code: VoiceDictationErrorCode
    ) -> VoiceFailurePresentation {
        switch code {
        case .micDenied:
            return .microphonePermission
        case .micUnavailable, .asrEngineError, .asrTimeout, .asrOverload,
             .polishFailed, .internalError:
            return .transient
        case .invalidRequest:
            // 协议级问题，重试通常无效：常驻供用户查看。
            return VoiceFailurePresentation(offersRetry: false)
        case .incompatibleProtocol:
            return .incompatibleProtocol
        }
    }
}

// MARK: - 浮窗文案

enum VoicePanelFormatting {
    static let panelTitle = "语音听写"
    static let transformHint = "空格/回车直接上屏原文 · Esc 取消"
    static let pendingConfirmHint = "空格/回车上屏 · Esc 关闭"
    static let copiedFeedbackTitle = "已复制 ✓"
    static let errorBadge = "⚠︎ 语音不可用"

    /// 录音计时：`0:12`、`1:05`，超过一小时为 `1:02:03`。
    static func recordingTimer(seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    /// 录音已进行到第几秒（向下取整，保证首秒显示 0:00）。
    static func elapsedSeconds(since startedAt: Date, now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(startedAt).rounded(.down)))
    }
}

// MARK: - 备用听写与翻译热键注册计划

/// 纯逻辑：备用语音听写快捷键是否需要独立注册。未设置或与主听写快捷键相同时不单独注册。
enum VoiceSecondaryHotKeyPlan: Equatable {
    case activate(VoiceDictationShortcut)
    case deactivate

    static func plan(
        secondaryShortcut: VoiceDictationShortcut?,
        primaryShortcut: VoiceDictationShortcut
    ) -> VoiceSecondaryHotKeyPlan {
        guard let secondaryShortcut, secondaryShortcut != primaryShortcut else {
            return .deactivate
        }
        return .activate(secondaryShortcut)
    }
}

/// 纯逻辑：一键翻译快捷键是否需要独立注册。与任一听写快捷键相同（含同为
/// Fn / 右 ⌘ 点按）时不单独注册，由听写热键统一处理。
enum VoiceTranslationHotKeyPlan: Equatable {
    case activate
    case deactivate

    static func plan(
        translateShortcut: VoiceDictationShortcut,
        dictationShortcut: VoiceDictationShortcut,
        secondaryDictationShortcut: VoiceDictationShortcut? = nil
    ) -> VoiceTranslationHotKeyPlan {
        guard translateShortcut != dictationShortcut,
              translateShortcut != secondaryDictationShortcut
        else {
            return .deactivate
        }
        return .activate
    }
}

// MARK: - 服务状态通知

extension Notification.Name {
    /// 语音服务状态变化（helper 启用/停用完成、熔断或恢复、麦克风权限阻断）：
    /// 设置窗口据此实时刷新服务状态徽标，无需手动刷新。
    static let rimeAIVoiceServiceStateDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.voice-service-state-did-change"
    )
}

@MainActor
enum VoiceServiceStateNotifier {
    static func postServiceStateDidChange() {
        NotificationCenter.default.post(
            name: .rimeAIVoiceServiceStateDidChange,
            object: nil
        )
    }
}
