import AppKit
import XCTest
@testable import RimeAIInputMethod

/// 设置窗口的展示逻辑：诚实的隐私文案、稳定的标签页标识、热词编辑计数、
/// 语音历史页的筛选/统计格式化/应用显示名/近 7 日柱状图，以及服务状态
/// 徽标与权限按钮徽标。
@MainActor
final class VoiceSettingsPresentationTests: XCTestCase {
    // MARK: - 隐私文案与标识

    func testPrivacyCopyIsHonestAndDoesNotClaimAnUnverifiedEngine() {
        let instruction = VoicePrivacyCopy.dictationInstruction(shortcutName: "右 ⌘", isModifierTap: true)
        XCTAssertFalse(instruction.contains("MLX"), "输入法侧无法确认引擎，不得宣称 MLX")
        XCTAssertTrue(instruction.contains("按一下 右 ⌘ 启动录音"))
        XCTAssertTrue(instruction.contains("本机"))
        let holdInstruction = VoicePrivacyCopy.dictationInstruction(
            shortcutName: "⌃⇧V", isModifierTap: false
        )
        XCTAssertFalse(holdInstruction.contains("MLX"))

        XCTAssertTrue(VoicePrivacyCopy.axFallbackReadNote.contains("默认关闭"))
        XCTAssertTrue(VoicePrivacyCopy.cloudHotwordsNote.contains("默认关闭"))
        XCTAssertTrue(VoicePrivacyCopy.historyCheckbox.contains("不上传"))
        XCTAssertFalse(VoicePrivacyCopy.phraseBookHotwordsCheckbox.contains("L1"))
    }

    func testSettingsTabsUseStableIdentifiers() {
        XCTAssertEqual(PrivacyCenterWindowController.TabIdentifier.voice, "settings.tab.voice")
        XCTAssertEqual(PrivacyCenterWindowController.TabIdentifier.voiceHistory, "settings.tab.voice-history")
        XCTAssertEqual(Set([
            PrivacyCenterWindowController.TabIdentifier.inputAndAI,
            PrivacyCenterWindowController.TabIdentifier.voice,
            PrivacyCenterWindowController.TabIdentifier.voiceHistory,
            PrivacyCenterWindowController.TabIdentifier.cloudHistory,
            PrivacyCenterWindowController.TabIdentifier.languageProfile,
            PrivacyCenterWindowController.TabIdentifier.statusAndData,
        ]).count, 6, "保持 6 个标签页且标识互不重复")
    }

    func testHotwordEditingCountsExactlyLikeSaving() {
        XCTAssertEqual(
            VoiceHotwordsEditing.parse("a, b，c\n\n d;e、f\r\n"),
            ["a", "b", "c", "d", "e", "f"]
        )
        XCTAssertEqual(VoiceHotwordsEditing.parse("  \n , "), [])
        let status = VoiceHotwordsEditing.status(savedCount: 3, liveCount: 5, phraseBookEnabled: false)
        XCTAssertTrue(status.contains("已保存 3/128 条"))
        XCTAssertTrue(status.contains("编辑中 5 条"))
        XCTAssertEqual(VoiceHotwordsEditing.unsavedIndicator, "● 有未保存的修改")
    }

    // MARK: - 语音历史

    func testVoiceHistoryFilterMapsPopupIndexToActionKind() {
        XCTAssertNil(VoiceHistoryFilter.action(forPopupIndex: 0))
        XCTAssertEqual(VoiceHistoryFilter.action(forPopupIndex: 1), .dictation)
        XCTAssertEqual(VoiceHistoryFilter.action(forPopupIndex: 2), .polish)
        XCTAssertEqual(VoiceHistoryFilter.action(forPopupIndex: 3), .translate)
        XCTAssertNil(VoiceHistoryFilter.action(forPopupIndex: 99))
    }

    func testStatsFormattingKeepsLongDurationsReadable() {
        XCTAssertEqual(VoiceStatsFormatting.formatDuration(milliseconds: 59_000), "59 秒")
        XCTAssertEqual(VoiceStatsFormatting.formatDuration(milliseconds: 61_000), "1 分 1 秒")
        XCTAssertEqual(VoiceStatsFormatting.formatDuration(milliseconds: 60_000), "1 分钟")
        XCTAssertEqual(VoiceStatsFormatting.formatDuration(milliseconds: 3_723_000), "1 小时 2 分")
        XCTAssertEqual(VoiceStatsFormatting.formatDuration(milliseconds: -1), "0 秒")
        XCTAssertEqual(VoiceStatsFormatting.formatSavedMinutes(0.5), "30 秒")
        XCTAssertEqual(VoiceStatsFormatting.formatSavedMinutes(45.26), "45.3 分钟")
        XCTAssertEqual(VoiceStatsFormatting.formatSavedMinutes(125), "2.1 小时")
        // 数值越长字号越小：长时长靠缩放完整显示而不是截断。
        XCTAssertGreaterThan(
            VoiceStatsFormatting.valueFontSize(textLength: 5),
            VoiceStatsFormatting.valueFontSize(textLength: 12)
        )
    }

    func testTopAppsLineNamesApplicationsInsteadOfBundleIdentifierSuffixes() {
        XCTAssertEqual(
            VoiceStatsFormatting.topAppsLine([]),
            VoiceStatsFormatting.emptyTopAppsText
        )
        let line = VoiceStatsFormatting.topAppsLine([
            VoiceAppUsageStat(
                bundleIdentifier: "com.apple.finder",
                sessionCount: 3,
                characterCount: 120,
                durationMilliseconds: 9_000
            ),
        ])
        XCTAssertTrue(line.contains("120 字 / 3 次"))
        XCTAssertFalse(line.contains("com.apple.finder"))
    }

    func testAppDisplayNameFallsBackToTheLastBundleComponent() {
        XCTAssertEqual(VoiceAppDisplayName.fallback("com.tesla.model3"), "model3")
        XCTAssertEqual(VoiceAppDisplayName.fallback("nodots"), "nodots")
        XCTAssertEqual(VoiceAppDisplayName.stripAppExtension("Safari.app"), "Safari")
        XCTAssertEqual(VoiceAppDisplayName.stripAppExtension("访达"), "访达")

        let unknown = "fun.wwcn.inputmethod.RimeAI.tests.unknown.\(UUID().uuidString)"
        XCTAssertEqual(VoiceAppDisplayName.resolve(unknown), VoiceAppDisplayName.fallback(unknown))

        // 已安装应用：解析为本地化显示名，而不是 bundle id 的最后一段。
        let finder = VoiceAppDisplayName.resolve("com.apple.finder")
        XCTAssertFalse(finder.isEmpty)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            XCTAssertEqual(
                finder,
                VoiceAppDisplayName.stripAppExtension(FileManager.default.displayName(atPath: url.path))
            )
        }
    }

    func testWeeklyChartFillsSevenDaysAndReportsEmptyState() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? calendar.timeZone
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let chart = VoiceUsageBarChartView()
        XCTAssertTrue(chart.isEmpty)

        let todayKey = VoiceHistoryStore.dayKey(for: now, calendar: calendar)
        chart.update(
            dailyTrend: [
                VoiceDailyUsageStat(
                    dayKey: todayKey,
                    sessionCount: 3,
                    characterCount: 30,
                    durationMilliseconds: 9_000,
                    polishedCount: 1,
                    translatedCount: 0,
                    autoPastedCount: 2
                ),
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(chart.entries.count, 7, "缺失的日期补零")
        XCTAssertEqual(chart.entries.last?.dayKey, todayKey)
        XCTAssertEqual(chart.entries.last?.isToday, true)
        XCTAssertEqual(chart.entries.last?.sessions, 3)
        XCTAssertEqual(chart.entries.first?.sessions, 0)
        XCTAssertFalse(chart.isEmpty)

        chart.update(dailyTrend: [], now: now, calendar: calendar)
        XCTAssertTrue(chart.isEmpty)
        XCTAssertEqual(chart.accessibilityValue() as? String, VoiceUsageBarChartView.emptyText)
    }

    // MARK: - 服务状态与权限徽标

    func testVoiceServiceStatusPresentationCoversEveryInstallationState() {
        typealias Status = VoiceHelperLifecycle.InstallationStatus
        func make(_ status: Status, voice: Bool = true) -> VoiceServiceStatusPresentation {
            VoiceServiceStatusPresentation.make(
                aiEnabled: true,
                voiceEnabled: voice,
                installationStatus: status
            )
        }

        XCTAssertEqual(
            VoiceServiceStatusPresentation.make(
                aiEnabled: false, voiceEnabled: true, installationStatus: .running
            ).tone,
            .off
        )
        XCTAssertEqual(make(.notInstalled).tone, .warning)
        XCTAssertEqual(
            make(.notInstalled).installHint,
            VoiceServiceStatusPresentation.notInstalledHint,
            "未安装时给出可操作的安装指引"
        )
        XCTAssertEqual(make(.disabled, voice: false).tone, .off)
        XCTAssertEqual(make(.disabled).tone, .pending)
        XCTAssertEqual(make(.starting).tone, .pending)
        XCTAssertEqual(make(.running).tone, .ok)
        XCTAssertNil(make(.running).installHint)
        for status: Status in [.notInstalled, .disabled, .starting, .running] {
            XCTAssertFalse(make(status).message.isEmpty)
        }
    }

    func testPermissionButtonsAppearOnlyWhenNeededAndCarryBadges() {
        XCTAssertFalse(VoicePermissionPresentation.showsAccessibilityButton(
            autoPasteEnabled: false, axFallbackReadEnabled: false
        ))
        XCTAssertTrue(VoicePermissionPresentation.showsAccessibilityButton(
            autoPasteEnabled: true, axFallbackReadEnabled: false
        ))
        XCTAssertTrue(VoicePermissionPresentation.showsAccessibilityButton(
            autoPasteEnabled: false, axFallbackReadEnabled: true
        ))
        XCTAssertEqual(
            VoicePermissionPresentation.badge("打开麦克风权限…", needsAttention: true),
            "⚠︎ 打开麦克风权限…"
        )
        XCTAssertEqual(
            VoicePermissionPresentation.badge("打开麦克风权限…", needsAttention: false),
            "打开麦克风权限…"
        )
    }
}
