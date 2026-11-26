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
    /// `corrector` 是会话开始时编译好的热词集（含 L1 / 词库来源）；不传时按
    /// 调用方给的列表即时编译，且全部视为用户手工维护的热词。
    static func cloudHotwords(
        isEnabled: Bool,
        activeHotwords: [String],
        transcript: String = "",
        corrector: VoiceHotwordCorrector? = nil
    ) -> [String] {
        guard isEnabled else {
            return []
        }
        return (corrector ?? VoiceHotwordCorrector(hotwords: activeHotwords))
            .prioritizedForCloud(transcript: transcript, limit: 32)
    }
}

/// 语音成稿进入键盘长期历史的闸门：默认开启、可单独关闭；关闭「本机语音历史」
/// 同样不写入——用户不想留存语音文本时，不应换个库继续存。
enum VoiceSharedHistoryPolicy {
    static func shouldRecord(
        isVoiceHistoryEnabled: Bool,
        isSharedHistoryEnabled: Bool,
        isAIAllowed: Bool,
        isCloudHistoryAllowed: Bool
    ) -> Bool {
        isVoiceHistoryEnabled
            && isSharedHistoryEnabled
            && isAIAllowed
            && isCloudHistoryAllowed
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

// MARK: - IMK 光标矩形可用性

/// `IMKTextInput.attributes(forCharacterIndex:lineHeightRectangle:)` 的原始返回值
/// 能否作为语音听写的光标锚点。
/// 部分 Electron/Chromium/微信输入框在空内容或刚聚焦时，把插入点报告为
/// `{x, y, width: 0, height: lineHeight}`：`NSRect.isEmpty` 为 true，但零宽且有行高
/// 的矩形就是真实插入点，不能据此判定“未检测到光标”。
enum VoiceCaretRectPolicy {
    /// 归一化为可用锚点；不可用时返回 nil。
    /// 零宽插入点补成 1pt 宽——下游用 `isEmpty` 判断锚点是否有效，原始零宽矩形会被
    /// 误当成无锚点而退回鼠标位置。
    static func normalizedAnchor(_ rect: NSRect) -> NSRect? {
        // `NSRect.width/height` 取的是绝对值，负尺寸必须用 size 原值判断。
        let rawWidth = rect.size.width
        let rawHeight = rect.size.height
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rawWidth.isFinite,
              rawHeight.isFinite,
              rawHeight > 0,
              rawWidth >= 0
        else {
            return nil
        }
        // 屏幕原点处的零宽矩形是宿主的占位值（尚未排版出真实光标），不是光标位置。
        guard rawWidth > 0 || rect.origin != .zero else {
            return nil
        }
        guard rawWidth > 0 else {
            return NSRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: 1,
                height: rawHeight
            )
        }
        return rect
    }
}

// MARK: - 采样式目标校验去抖

/// 录音/润色期间的目标有效性来自两类高频采样：150ms 定时器与每次 ASR 预览回调。
/// 宿主（尤其 Electron/Chromium）重排或滚动时，单次 XPC 查询可能拿到瞬时抖动的
/// 选区/光标矩形；若据此立即把 `hasEditableTarget` 永久置为 false，本次听写就只能
/// 手动复制（提示“焦点已切换”），哪怕下一个采样光标仍在原处。
///
/// 这里要求“连续无效”持续满 `lockoutInterval` 才判定目标失效，任何一次有效采样都会
/// 重新计时。真正的焦点切换是持续状态，必然在窗口内被确认；上屏瞬间仍会同步复核
/// 目标有效性，去抖不会把文本写进已失焦的输入框。
struct VoiceTargetValidityDebouncer: Equatable {
    /// 连续无效需持续的秒数：远大于单次 XPC 抖动与一帧重排，又短于用户可感知的延迟。
    static let lockoutInterval: TimeInterval = 0.6

    /// 连续无效段的首个采样时刻；nil 表示最近一次采样有效。
    private(set) var firstInvalidSampleAt: TimeInterval?

    /// 记录一次采样；返回 true 表示应判定目标失效。
    /// `timestamp` 须来自单调时钟（如 `ProcessInfo.systemUptime`）。
    mutating func noteSample(
        isValid: Bool,
        at timestamp: TimeInterval
    ) -> Bool {
        guard !isValid else {
            firstInvalidSampleAt = nil
            return false
        }
        guard let first = firstInvalidSampleAt else {
            firstInvalidSampleAt = timestamp
            return false
        }
        return timestamp - first >= Self.lockoutInterval
    }

    mutating func reset() {
        firstInvalidSampleAt = nil
    }
}

// MARK: - 录音/处理期焦点暂离与回切恢复

/// 语音会话在不同阶段遇到临时失焦（如 `UserNotificationCenter` 系统弹窗、
/// `⌘Tab` 临时切去浏览器/系统设置查阅资料再切回原应用、或 Electron 内部重激活
/// IMK 控制器）时，决定是否保留原目标身份以便焦点回到原应用后照常自动上屏。
///
/// 安全边界保持不变：所有上屏入口在提交瞬间仍同步复核 `targetIsValid`
/// （同前台 PID / 同 IMK 会话且非安全输入）；若最终仍停留在其他应用，
/// fail-closed 降级为常驻手动复制浮窗，绝不跨应用误上屏。
enum VoiceSessionTargetRecoveryPolicy {
    /// 会话仍在录音、收尾或云端润色/翻译进行中，尚未进入手动待确认态。
    static func isInProgress(
        phase: VoiceDictationClientPhase,
        isTransforming: Bool
    ) -> Bool {
        if isTransforming {
            return true
        }
        switch phase {
        case .connecting, .listening, .finalizing:
            return true
        case .pendingConfirm, .idle, .disabled:
            return false
        }
    }

    /// 采样式校验在持续无效满去抖窗口时，是否应永久锁死本次自动上屏。
    /// - 录音/收尾/润色期间不锁死：焦点短暂离开（如系统通知或切窗查资料）后
    ///   只要在提交前回到原应用，同步复核通过即照常自动上屏。
    /// - 手动待确认态（`.pendingConfirm` 且非转换中）持续失焦时转为常驻复制浮窗。
    static func shouldLockOutAutoPasteOnSustainedInvalidity(
        phase: VoiceDictationClientPhase,
        isTransforming: Bool
    ) -> Bool {
        !isInProgress(phase: phase, isTransforming: isTransforming)
    }

    /// IMK 控制器失活或会话切换时，是否应平滑移交给绑定原 `targetFrontmostPID`
    /// 的全局会话宿主，而不是永久拆离目标。
    static func shouldHandOffControllerToGlobal(
        phase: VoiceDictationClientPhase,
        isTransforming: Bool,
        isSameApp: Bool,
        targetWasEditableAtStart: Bool,
        hasTargetPID: Bool,
        isGlobalMonitorActive: Bool
    ) -> Bool {
        guard isGlobalMonitorActive, hasTargetPID, targetWasEditableAtStart else {
            return false
        }
        if isInProgress(phase: phase, isTransforming: isTransforming) {
            return true
        }
        if case .pendingConfirm = phase {
            return isSameApp
        }
        return false
    }

    /// 其他 IMK 控制器通过 `claim(owner:)` 激活时，是否应拆离当前活跃的全局语音会话。
    /// - 当前前台仍是原目标应用时始终保留。
    /// - 录音/收尾/润色期间即使暂时切到其他应用并触发了对方应用的 `activateServer`，
    ///   也保留对原目标 PID 的绑定，以便切回原应用后照常自动上屏。
    static func shouldDetachGlobalSessionOnClaim(
        phase: VoiceDictationClientPhase,
        isTransforming: Bool,
        targetCurrentlyValid: Bool
    ) -> Bool {
        if targetCurrentlyValid {
            return false
        }
        return !isInProgress(phase: phase, isTransforming: isTransforming)
    }
}

// MARK: - 同一输入框证据

/// 「还是开始听写的那个输入框」的文本证据：记下光标前（光标在文首时改取光标后）
/// 一小段文字的绝对位置与内容，提交前原样回读比对。
///
/// 只凭 IMK 会话与光标存在与否，无法区分同一客户端里的另一个输入框（Electron 同一
/// 网页的多个输入框共用一个 client）；把光标坐标锁死又会被滚动与重排误伤。文字证据
/// 两头兼顾：滚动、重排、在同一输入框内移动光标，都不改变被记录位置上的文字。
struct VoiceTargetFingerprint: Equatable {
    struct Probe: Equatable {
        let offset: Int
        let length: Int
        let text: String
    }

    /// 光标前最多取这么多 UTF-16 单元。
    static let probeLength = 16
    /// 光标在文首时改取光标后的文字；范围越界时宿主可能返回 nil，逐级缩短。
    static let suffixProbeLengths = [16, 8, 4, 2, 1]

    let probes: [Probe]

    /// 没有任何文字证据时（空输入框，或宿主不支持回读），调用方须改用光标矩形判定。
    var hasTextEvidence: Bool {
        probes.contains { !$0.text.isEmpty }
    }

    static func capture(
        caretLocation: Int,
        selectionLength: Int,
        read: (NSRange) -> String?
    ) -> VoiceTargetFingerprint {
        var probes: [Probe] = []
        if caretLocation > 0 {
            let length = min(probeLength, caretLocation)
            let range = NSRange(location: caretLocation - length, length: length)
            if let text = read(range), !text.isEmpty {
                probes.append(Probe(offset: range.location, length: length, text: text))
            }
        }
        if probes.isEmpty {
            let offset = caretLocation + max(0, selectionLength)
            for length in suffixProbeLengths {
                if let text = read(NSRange(location: offset, length: length)), !text.isEmpty {
                    probes.append(Probe(offset: offset, length: length, text: text))
                    break
                }
            }
        }
        return VoiceTargetFingerprint(probes: probes)
    }

    /// 记录位置上的文字必须逐条原样读回；读不到视为不匹配。
    func matches(_ read: (NSRange) -> String?) -> Bool {
        hasTextEvidence
            && probes.allSatisfy { probe in
                read(NSRange(location: probe.offset, length: probe.length)) == probe.text
            }
    }
}

/// 没有文字证据时的兜底：上屏前复核光标还在原处（各边与尺寸都在容差内）。
/// 滚动与重排会让它误判，所以只用于空输入框、或宿主不支持文字回读的情形。
enum VoiceCaretRectMatch {
    static func isSameCaretRect(
        _ lhs: NSRect,
        _ rhs: NSRect,
        tolerance: CGFloat = 8
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.size.width - rhs.size.width) <= tolerance
            && abs(lhs.size.height - rhs.size.height) <= tolerance
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
