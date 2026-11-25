import AppKit

// MARK: - 服务状态

/// 语音服务状态徽标的展示模型（纯逻辑，便于单测）。
struct VoiceServiceStatusPresentation: Equatable {
    enum Tone: Equatable {
        case off
        case ok
        case pending
        case warning
    }

    let tone: Tone
    let message: String
    /// 仅在语音组件未安装时给出可操作的安装指引。
    let installHint: String?

    static let notInstalledHint =
        "未检测到语音组件：请重新安装完整版 RimeAI 输入法（安装包内含 Voice Helper），"
        + "再回到这里启用语音。"

    static func make(
        aiEnabled: Bool,
        voiceEnabled: Bool,
        installationStatus: VoiceHelperLifecycle.InstallationStatus
    ) -> VoiceServiceStatusPresentation {
        guard aiEnabled else {
            return VoiceServiceStatusPresentation(
                tone: .off,
                message: "语音：已随 AI 总开关停用",
                installHint: nil
            )
        }
        switch installationStatus {
        case .notInstalled:
            return VoiceServiceStatusPresentation(
                tone: .warning,
                message: "语音：语音组件未安装 · 键盘输入不受影响",
                installHint: notInstalledHint
            )
        case .disabled:
            return voiceEnabled
                ? VoiceServiceStatusPresentation(
                    tone: .pending,
                    message: "语音：等待启动",
                    installHint: nil
                )
                : VoiceServiceStatusPresentation(
                    tone: .off,
                    message: "语音：已关闭",
                    installHint: nil
                )
        case .starting:
            return VoiceServiceStatusPresentation(
                tone: .pending,
                message: "语音：语音组件正在启动",
                installHint: nil
            )
        case .running:
            return VoiceServiceStatusPresentation(
                tone: .ok,
                message: "语音：语音组件已运行 · 首次使用快捷键时完成认证与权限确认",
                installHint: nil
            )
        }
    }

    var dotColor: NSColor {
        switch tone {
        case .off:
            return .secondaryLabelColor
        case .ok:
            return .systemGreen
        case .pending:
            return .systemOrange
        case .warning:
            return .systemRed
        }
    }
}

// MARK: - 权限按钮

enum VoicePermissionPresentation {
    /// 麦克风/语音识别授权属于 Voice Helper 进程，输入法无法预读：仅在
    /// helper 明确拒绝后才加 ⚠︎ 徽标，平时保持普通外观。
    static func microphoneNeedsAttention(permissionBlocked: Bool) -> Bool {
        permissionBlocked
    }

    /// 只有确实有功能依赖辅助功能（自动 ⌘V 粘贴 / AX 回读）时才展示授权按钮。
    static func showsAccessibilityButton(
        autoPasteEnabled: Bool,
        axFallbackReadEnabled: Bool
    ) -> Bool {
        autoPasteEnabled || axFallbackReadEnabled
    }

    static func badge(_ title: String, needsAttention: Bool) -> String {
        needsAttention ? "⚠︎ " + title : title
    }
}

// MARK: - 热词编辑

/// 自定义热词文本的解析：保存与实时计数共用同一规则，保证两者始终一致。
enum VoiceHotwordsEditing {
    static let separators = CharacterSet(charactersIn: "\n\r,，、;；")

    static func parse(_ rawText: String) -> [String] {
        rawText
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static let unsavedIndicator = "● 有未保存的修改"

    static func status(savedCount: Int, liveCount: Int, phraseBookEnabled: Bool) -> String {
        let phraseBookHint = phraseBookEnabled
            ? "已启用常用语库自动融合"
            : "仅使用自定义热词"
        return "已保存 \(savedCount)/128 条 · 编辑中 \(liveCount) 条 · \(phraseBookHint)"
    }
}

// MARK: - 历史筛选

enum VoiceHistoryFilter {
    /// 筛选弹窗索引 → 类型过滤；0 为“全部类型”。
    static func action(forPopupIndex index: Int) -> VoicePostProcessAction? {
        switch index {
        case 1:
            return .dictation
        case 2:
            return .polish
        case 3:
            return .translate
        default:
            return nil
        }
    }
}

// MARK: - 统计格式化

/// 统计文案格式化。应用显示名解析依赖主 actor，本枚举只在主线程使用。
@MainActor
enum VoiceStatsFormatting {
    static let emptyTopAppsText = "常用应用：暂无语音输入记录"

    /// 统计卡片数值字号：内容越长字号越小，长时长绝不截断。
    static func valueFontSize(textLength: Int, base: CGFloat = 18) -> CGFloat {
        switch textLength {
        case 0 ... 7:
            return base
        case 8 ... 11:
            return base - 3
        default:
            return base - 5
        }
    }

    static func formatDuration(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        if totalSeconds < 60 {
            return "\(totalSeconds) 秒"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 {
            return seconds > 0 ? "\(minutes) 分 \(seconds) 秒" : "\(minutes) 分钟"
        }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return "\(hours) 小时 \(remMinutes) 分"
    }

    static func formatSavedMinutes(_ minutes: Double) -> String {
        if minutes < 1.0 {
            let seconds = Int((minutes * 60.0).rounded())
            return "\(max(0, seconds)) 秒"
        }
        if minutes < 60.0 {
            return String(format: "%.1f 分钟", minutes)
        }
        return String(format: "%.1f 小时", minutes / 60.0)
    }

    static func detailLine(_ summary: VoiceUsageSummary) -> String {
        let cpm = Int(summary.averageCharsPerMinute.rounded())
        return "今日：\(summary.todaySessions) 次 / \(summary.todayCharacters) 字 · "
            + "近 7 日：\(summary.last7DaysSessions) 次 / \(summary.last7DaysCharacters) 字 · "
            + "平均语速：\(cpm) 字/分 · 连续使用：\(summary.activeDayStreak) 天\n"
            + "模式分布：听写 \(summary.dictationSessions) 次 · "
            + "智能润色 \(summary.polishedSessions) 次 · "
            + "语音翻译 \(summary.translatedSessions) 次 · "
            + "自动粘贴 \(summary.autoPastedSessions) 次"
    }

    static func topAppsLine(_ topApps: [VoiceAppUsageStat]) -> String {
        guard !topApps.isEmpty else {
            return emptyTopAppsText
        }
        return "常用应用 Top 5：" + topApps
            .map { VoiceAppDisplayName.describe($0) }
            .joined(separator: " · ")
    }
}

// MARK: - 应用显示名

@MainActor
enum VoiceAppDisplayName {
    private static var cache: [String: String] = [:]

    /// 把 bundle id 解析为用户看得懂的本地化应用名；未安装或解析失败时
    /// 回退到 bundle id 的最后一段。
    static func resolve(_ bundleIdentifier: String) -> String {
        if let cached = cache[bundleIdentifier] {
            return cached
        }
        var resolved: String?
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) {
            resolved = stripAppExtension(
                FileManager.default.displayName(atPath: url.path)
            )
        }
        let name = (resolved?.isEmpty == false)
            ? resolved!
            : fallback(bundleIdentifier)
        cache[bundleIdentifier] = name
        return name
    }

    static func stripAppExtension(_ name: String) -> String {
        var result = name
        for suffix in [".app", ".APP"] where result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
        }
        return result
    }

    /// 兜底：`com.apple.Safari` → `Safari`；没有分隔符时原样返回。
    static func fallback(_ bundleIdentifier: String) -> String {
        bundleIdentifier.split(separator: ".").last.map(String.init)
            ?? bundleIdentifier
    }

    static func describe(_ app: VoiceAppUsageStat) -> String {
        "\(resolve(app.bundleIdentifier))（\(app.characterCount) 字 / \(app.sessionCount) 次）"
    }
}
