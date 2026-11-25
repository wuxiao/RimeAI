import AppKit
import ApplicationServices
import Carbon
import Foundation

// MARK: - 超时口径

/// 语音会话各阶段的超时口径（毫秒）。集中定义，避免散落的魔法数字漂移。
enum VoiceSessionTiming {
    /// 松开快捷键后等待最终文本的上限。原值沿用协议上限 30s，过长会让
    /// 用户误以为卡死；收紧到 10s，超时后走既有失败浮窗并可直接重试。
    static let finalizationDeadlineMilliseconds = 10_000

    /// 云端润色只是整理口语，应远快于翻译。
    static let cloudPolishDeadlineMilliseconds = 6_000
    /// 云端翻译涉及跨语言重写，给到与最终识别相同的上限。
    static let cloudTranslateDeadlineMilliseconds = 10_000

    static func cloudTransformDeadline(
        for task: CloudVoiceTransformTask
    ) -> Int {
        switch task {
        case .polish:
            return cloudPolishDeadlineMilliseconds
        case .translate:
            return cloudTranslateDeadlineMilliseconds
        }
    }
}

// MARK: - 云端润色截断守卫

/// 大模型偶发只返回半句（被输出上限截断）。输入足够长（≥ 80 字）而
/// 输出不足原文 60% 时判为截断：宁可用本地润色的完整原文，也不上屏残句。
enum VoiceCloudPolishTruncationGuard {
    static let minimumInputCharacters = 80
    static let minimumOutputRatio = 0.6
    static let fallbackStatus = "云端润色结果不完整，已改用本地润色"

    static func looksTruncated(input: String, output: String) -> Bool {
        let inputCount = input.count
        guard inputCount >= minimumInputCharacters else {
            return false
        }
        return Double(output.count) < Double(inputCount) * minimumOutputRatio
    }
}

// MARK: - 云端热词 opt-in

/// 热词上下文可能包含个人常用语与专有名词：仅在用户显式开启
/// “允许向云端润色/翻译发送热词上下文”时才随请求发送。
enum VoiceCloudHotwordPolicy {
    static func cloudHotwords(
        isEnabled: Bool,
        activeHotwords: [String]
    ) -> [String] {
        isEnabled ? activeHotwords : []
    }
}

// MARK: - 润色/翻译中直接上屏原文

/// 润色或翻译进行中按下空格/回车：放弃在途转换，把已识别的原文作为
/// 最终文本走正常上屏流程（历史、自动粘贴与回退策略全部沿用）。
enum VoiceTransformRawCommit {
    struct Plan: Equatable {
        let actionKind: VoicePostProcessAction
        let polishStyle: VoicePolishStyle?
        let targetLanguage: VoiceTranslationLanguage?
        let polishApplied: Bool
        let status: String
    }

    static func plan(for intent: VoiceSessionIntent) -> Plan {
        switch intent {
        case .dictation:
            return Plan(
                actionKind: .dictation,
                polishStyle: nil,
                targetLanguage: nil,
                polishApplied: false,
                status: "已跳过润色"
            )
        case .translate:
            // 原文未经翻译，不得记作一次“翻译”。
            return Plan(
                actionKind: .dictation,
                polishStyle: nil,
                targetLanguage: nil,
                polishApplied: false,
                status: "已跳过翻译"
            )
        }
    }
}

// MARK: - 宿主 markedRange 判定

/// 部分宿主（Electron / Chromium / 断联 XPC proxy）在没有未上屏组合文本时
/// 会返回 `{location: 0, length: 0}` 而不是 `{NSNotFound, 0}`。
/// 只有 `location != NSNotFound && length > 0` 才表示存在真正的未上屏拼音组合。
enum VoiceClientMarkedRangePolicy {
    static func hasMarkedText(_ range: NSRange) -> Bool {
        range.location != NSNotFound && range.length > 0
    }
}

// MARK: - 润色/收尾中再次触发语音快捷键（策略 A：保底上屏 + 无缝续录）

/// 用户在语音会话的不同阶段再次触发听写/翻译快捷键（如右 ⌘ 点按）时的处理决策。
enum VoiceRepeatTriggerDecision: Equatable {
    /// 空闲态：直接启动新一轮录音。
    case startNewSession
    /// 连接/录音中：停止当前录音进入识别收尾。
    case stopRecording
    /// 润色/翻译进行中：中止慢云端请求，用本地 0ms 润色保底上屏上一句，并立即开启新一轮录音。
    case flushTransformAndRestart
    /// 手动待确认态：提交上一句已就绪结果，并立即开启新一轮录音。
    case commitPendingAndRestart
    /// ASR 正在最终收尾：记下续录意图，收尾返回后立即本地润色上屏并自动开启新一轮录音。
    case queueRestartAfterFinalizing
    /// 服务已熔断：忽略（由调用方给出停用提示）。
    case ignoreDisabled

    static func decide(
        phase: VoiceDictationClientPhase,
        isTransforming: Bool
    ) -> VoiceRepeatTriggerDecision {
        if isTransforming {
            return .flushTransformAndRestart
        }
        switch phase {
        case .idle:
            return .startNewSession
        case .connecting, .listening:
            return .stopRecording
        case .finalizing:
            return .queueRestartAfterFinalizing
        case .pendingConfirm:
            return .commitPendingAndRestart
        case .disabled:
            return .ignoreDisabled
        }
    }
}

// MARK: - 跨路径修饰键事件去重

/// 全局监控器（`NSEvent.addGlobalMonitorForEvents`）与活跃的 `IMKInputController`
/// 在 RimeAI 处于激活状态时会收到同一物理按键的两次 `flagsChanged`。
/// 按 `(keyCode, modifiers, timestamp)` 做 O(1) 去重，确保同一物理边沿只处理一次。
struct VoiceModifierEventDeduplicator: Equatable {
    static let duplicateWindowSeconds: TimeInterval = 0.008

    private var lastKeyCode: UInt16?
    private var lastModifiers: VoiceDictationKeyModifiers?
    private var lastTimestamp: TimeInterval?

    mutating func shouldProcess(
        keyCode: UInt16,
        modifiers: VoiceDictationKeyModifiers,
        timestamp: TimeInterval
    ) -> Bool {
        if let prevKey = lastKeyCode,
           let prevMods = lastModifiers,
           let prevTime = lastTimestamp,
           prevKey == keyCode,
           prevMods == modifiers,
           abs(timestamp - prevTime) <= Self.duplicateWindowSeconds
        {
            return false
        }
        lastKeyCode = keyCode
        lastModifiers = modifiers
        lastTimestamp = timestamp
        return true
    }

    mutating func reset() {
        lastKeyCode = nil
        lastModifiers = nil
        lastTimestamp = nil
    }
}

// MARK: - 右 ⌘ 点按切换

/// 右 ⌘ 点按切换录音没有 Carbon release 边沿：控制器失活（切换输入法、
/// 输入会话结束）时必须补一次“松开”，否则录音在控制器失活后无人能停。
enum VoiceModifierTapPolicy {
    /// 仅当快捷键确为点按模式且仍处于录音阶段才补发 release；
    /// 收尾/待确认/转换阶段不得再调用 stop。
    static func shouldReleaseOnDeactivate(
        isModifierTap: Bool,
        phase: VoiceDictationClientPhase
    ) -> Bool {
        guard isModifierTap else {
            return false
        }
        switch phase {
        case .connecting, .listening:
            return true
        case .idle, .finalizing, .pendingConfirm, .disabled:
            return false
        }
    }
}

/// 右 ⌘ 误触发防护：`⌘+点击`、`⌘+滚轮` 以及 `⌘+普通按键`（如 `右⌘+C/V/Tab`）
/// 同样产生“右 ⌘ 按下 → 松开”的修饰键序列。按下时记下最近一次指针/按键活动的
/// 系统时间；松开时若活动发生了更新，则判为组合操作并撤销本次点按触发。
/// 通过 CoreGraphics HID 空闲时间查询实现，即使未授予“输入监控”权限也可靠拦截
/// `右⌘+C/V`，且绝不读取或记录任何具体按键内容。
struct VoiceModifierTapPointerGuard: Equatable {
    private var armedPointerActivityAt: TimeInterval?
    private var armedKeyDownActivityAt: TimeInterval?

    /// 右 ⌘ 单独按下时调用。
    mutating func armed(
        lastPointerActivityAt: TimeInterval?,
        lastKeyDownActivityAt: TimeInterval? = nil
    ) {
        armedPointerActivityAt = lastPointerActivityAt
        armedKeyDownActivityAt = lastKeyDownActivityAt
    }

    mutating func reset() {
        armedPointerActivityAt = nil
        armedKeyDownActivityAt = nil
    }

    /// 返回 true 表示按下期间发生过指针点击/滚动或非修饰键按下，应撤销触发。
    mutating func pointerActivityIntervened(
        lastPointerActivityAt: TimeInterval?,
        lastKeyDownActivityAt: TimeInterval? = nil
    ) -> Bool {
        defer { reset() }
        if Self.activityAdvanced(
            armed: armedPointerActivityAt,
            current: lastPointerActivityAt
        ) {
            return true
        }
        if Self.activityAdvanced(
            armed: armedKeyDownActivityAt,
            current: lastKeyDownActivityAt
        ) {
            return true
        }
        return false
    }

    private static func activityAdvanced(
        armed: TimeInterval?,
        current: TimeInterval?
    ) -> Bool {
        guard let armed else {
            return current != nil
        }
        guard let current else {
            return false
        }
        return current > armed + 0.001
    }
}

enum VoicePointerActivity {
    static let trackedEventTypes: [CGEventType] = [
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .scrollWheel
    ]

    /// 最近一次鼠标按下/滚轮事件的时间戳。与 `NSEvent.timestamp` 不同，
    /// 这里只需要在“按下”与“松开”两个时刻用同一时间基做相对比较。
    static func lastPointerEventTimestamp(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        var intervals: [TimeInterval] = []
        for eventType in trackedEventTypes {
            let interval = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: eventType
            )
            // 从未发生过的类型会返回极大值或负值。
            guard interval.isFinite, interval >= 0, interval < 1e9 else {
                continue
            }
            intervals.append(interval)
        }
        guard let mostRecent = intervals.min() else {
            return nil
        }
        return now - mostRecent
    }

    /// 最近一次非修饰键 `keyDown` 的系统时间戳（仅统计时间，不读取键位与字符）。
    /// 用于跨输入法全局监听右 `⌘` 时，即便无输入监控权限也能精准拦截 `右⌘+C/V` 等组合。
    static func lastKeyDownEventTimestamp(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        let interval = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .keyDown
        )
        guard interval.isFinite, interval >= 0, interval < 1e9 else {
            return nil
        }
        return now - interval
    }
}
