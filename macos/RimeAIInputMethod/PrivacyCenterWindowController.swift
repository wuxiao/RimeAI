import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PrivacyCenterWindowController: NSObject, NSMenuItemValidation {
    static let shared = PrivacyCenterWindowController()

    /// 窗口位置与尺寸的记忆键；仅首次打开（无记忆）时居中。
    static let windowFrameAutosaveName = "fun.wwcn.inputmethod.RimeAI.settings"

    /// 标签页的稳定标识。标题可以改名（如“历史与统计”→“语音历史”），
    /// 跳转、菜单与测试一律按 identifier 匹配，不做脆弱的标题字符串比较。
    enum TabIdentifier {
        static let inputAndAI = "settings.tab.input-ai"
        static let voice = "settings.tab.voice"
        static let voiceHistory = "settings.tab.voice-history"
        static let cloudHistory = "settings.tab.cloud-history"
        static let languageProfile = "settings.tab.language-profile"
        static let statusAndData = "settings.tab.status-data"
    }

    let settings = RimeAISettingsStore.shared
    let credentialStore = FileCloudCredentialStore.shared
    let historyService = RimeAIHistoryService.shared
    let voiceHistoryService = VoiceHistoryService.shared
    let window: NSWindow
    let tabView = NSTabView()
    let rootStack = NSStackView()
    let characterSetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let characterWidthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let punctuationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let aiToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let offlineToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let contextPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let cloudModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let apiKeyField = NSSecureTextField()
    let cloudStatusLabel = NSTextField(labelWithString: "")
    let historyStatusLabel = NSTextField(labelWithString: "")
    let phrasebookStatusLabel = NSTextField(labelWithString: "")
    let profileSummaryLabel = NSTextField(labelWithString: "")
    let phrasebookEditor = PhrasebookEditorControls()
    let voiceToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    /// 语音总开关关闭时显示的醒目状态横幅。
    let voiceDisabledBannerLabel = NSTextField(labelWithString: "")
    let voiceRimeHotwordToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let voicePhraseBookHotwordToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let voiceAutoLearnCorrectionsToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let voiceCloudHotwordsToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let voiceAXFallbackReadToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let voiceClearLearnedCorrectionsButton = NSButton(title: "清空自动纠错映射", target: nil, action: nil)
    let voiceLearnedCorrectionsStatusLabel = NSTextField(labelWithString: "")
    let voiceCustomHotwordsScrollView = NSScrollView()
    let voiceCustomHotwordsTextView = NSTextView()
    let voiceCustomHotwordsStatusLabel = NSTextField(labelWithString: "")
    /// 编辑器内容与已保存值不一致时显示“有未保存的修改”。
    let voiceCustomHotwordsUnsavedLabel = NSTextField(labelWithString: "")
    var voiceCustomHotwordsHeightConstraint: NSLayoutConstraint?
    var voiceCustomHotwordsIsDirty = false
    let voiceInstructionLabel = NSTextField(labelWithString: "")
    let voiceShortcutCaptureButton = SettingsShortcutCaptureButton()
    let voiceShortcutCancelButton = NSButton(title: "取消编辑", target: nil, action: nil)
    let voiceShortcutStatusLabel = NSTextField(labelWithString: "")
    let voiceTranslateShortcutCaptureButton = SettingsShortcutCaptureButton()
    let voiceTranslateShortcutCancelButton = NSButton(title: "取消编辑", target: nil, action: nil)
    let voiceTranslateShortcutStatusLabel = NSTextField(labelWithString: "")
    let voiceTranslateLanguagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let voiceSmartPolishToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let voicePolishStylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let voiceAutoPasteToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let voiceHistoryToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let voiceSoundEffectsToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let voiceMuteSystemAudioToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    /// 服务状态：彩色圆点 + 文字，随生命周期通知实时刷新。
    let voiceServiceStatusDot = NSView()
    let voiceStatusLabel = NSTextField(labelWithString: "")
    /// helper 未安装时的可操作提示。
    let voiceInstallHintLabel = NSTextField(labelWithString: "")
    let voiceAccessibilityPermissionButton = NSButton(title: "打开辅助功能权限…", target: nil, action: nil)
    let voiceMicrophonePermissionButton = NSButton(title: "打开麦克风权限…", target: nil, action: nil)
    let voiceSpeechPermissionButton = NSButton(title: "打开语音识别权限…", target: nil, action: nil)
    let voiceStatCharsValueLabel = NSTextField(labelWithString: "0")
    let voiceStatSessionsValueLabel = NSTextField(labelWithString: "0")
    let voiceStatDurationValueLabel = NSTextField(labelWithString: "0 秒")
    let voiceStatSavedTimeValueLabel = NSTextField(labelWithString: "0 分钟")
    let voiceStatsDetailLabel = NSTextField(labelWithString: "")
    let voiceStatsTopAppsLabel = NSTextField(labelWithString: "")
    let voiceWeeklyChartView = VoiceUsageBarChartView()
    let voiceHistorySearchField = NSSearchField()
    let voiceHistoryFilterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let voiceHistoryScrollView = NSScrollView()
    let voiceHistoryTableView = NSTableView()
    let voiceHistoryStatusLabel = NSTextField(labelWithString: "")
    let voiceHistoryEmptyStateLabel = NSTextField(labelWithString: "")
    let voiceHistoryCopyFinalButton = NSButton(title: "复制成稿", target: nil, action: nil)
    let voiceHistoryCopyRawButton = NSButton(title: "复制原文", target: nil, action: nil)
    let voiceHistoryDeleteButton = NSButton(title: "删除选中", target: nil, action: nil)
    var voiceHistoryTableHeightConstraint: NSLayoutConstraint?
    var voiceHistoryPageClipView: NSClipView?
    var voiceHistoryRecords: [VoiceHistoryRecord] = []
    var voiceHistoryTableAdapter: VoiceHistoryTableAdapter?
    /// 后台查询代次：过期结果不得覆盖新结果。
    var voiceHistoryRefreshGeneration: UInt64 = 0
    var dataSizeRefreshGeneration: UInt64 = 0
    let disabledAIField = NSTextField()
    let disabledContextField = NSTextField()
    let daemonStatusLabel = NSTextField(labelWithString: "")
    let modelLabel = NSTextField(labelWithString: "")
    let artifactLabel = NSTextField(labelWithString: "")
    let diagnosticsLabel = NSTextField(labelWithString: "")
    let dataSizeLabel = NSTextField(labelWithString: "")
    /// 顶部状态条：仅在有操作提示时占位，空闲时隐藏。
    let settingsActionStatusLabel = NSTextField(labelWithString: "")
    var settingsActionStatusHideWorkItem: DispatchWorkItem?
    let importSettingsButton = NSButton(title: "导入设置…", target: nil, action: nil)
    let restoreDefaultSettingsButton = NSButton(title: "恢复默认设置…", target: nil, action: nil)
    var daemonObserver: NSObjectProtocol?
    var cloudObserver: NSObjectProtocol?
    var settingsObserver: NSObjectProtocol?
    var diagnosticsObserver: NSObjectProtocol?
    var settingsActionStatusObserver: NSObjectProtocol?
    var voiceShortcutStatusObserver: NSObjectProtocol?
    var voiceTranslateShortcutStatusObserver: NSObjectProtocol?
    var voiceHistoryObserver: NSObjectProtocol?
    var voiceServiceStateObserver: NSObjectProtocol?
    var voiceHistoryPageLayoutObserver: NSObjectProtocol?
    var voiceHotwordsEditorObserver: NSObjectProtocol?
    lazy var lifecycleCoordinator: ServiceLifecycleCoordinator =
        ServiceLifecycleCoordinator(
            eventHandler: { [weak self] event in
                self?.handleLifecycleEvent(event)
            },
            performOperation: { [weak self] operation, completion in
                guard let self else {
                    return
                }
                self.performLifecycleOperation(
                    operation,
                    completion: completion
                )
            }
        )

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.delegate = self
        reconcileCloudConfiguration()
        window.title = "RimeAI 设置"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 620)
        // 记住用户上次的窗口位置与大小；只有第一次打开才居中。
        let restoredFrame = window.setFrameUsingName(Self.windowFrameAutosaveName)
        if !restoredFrame {
            window.center()
        }
        window.setFrameAutosaveName(Self.windowFrameAutosaveName)
        configureInterface()
        observeState()
        refresh()
    }

    func showWindow(selectingTab tabIdentifier: String? = nil) {
        refresh()
        if let tabIdentifier,
           let item = tabView.tabViewItems.first(where: {
               ($0.identifier as? String) == tabIdentifier
           })
        {
            tabView.selectTabViewItem(item)
        }
        if settings.aiEnabled {
            DaemonClient.shared.connect()
        }
        if settings.cloudConfigured {
            CloudBrokerClient.shared.connect()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureInterface() {
        // The local daemon remains offline even when the separate cloud broker
        // is enabled with a user-provided credential.
        settings.offlineLockEnabled = true

        let contentView = NSView()
        window.contentView = contentView

        let title = label(
            "RimeAI 设置",
            font: .systemFont(ofSize: 22, weight: .semibold)
        )
        title.setAccessibilityLabel("RimeAI 设置")
        configureWrapping(settingsActionStatusLabel)
        settingsActionStatusLabel.font = .systemFont(ofSize: 12)
        settingsActionStatusLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.action-status"
        )
        settingsActionStatusLabel.setAccessibilityLabel("设置操作状态")
        // 空闲时不占高度：NSStackView 会把隐藏的排列子视图移出布局。
        settingsActionStatusLabel.isHidden = true

        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.setAccessibilityLabel("RimeAI 设置分类")
        tabView.setContentHuggingPriority(.defaultLow, for: .vertical)

        for view in [title, settingsActionStatusLabel, tabView] {
            rootStack.addArrangedSubview(view)
        }
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: 18
            ),
            rootStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -18
            ),
            rootStack.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: 16
            ),
            rootStack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -16
            ),
            tabView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            settingsActionStatusLabel.widthAnchor.constraint(
                equalTo: rootStack.widthAnchor
            ),
            tabView.heightAnchor.constraint(greaterThanOrEqualToConstant: 500),
        ])

        let inputStack = addSettingsTab(
            to: tabView,
            identifier: TabIdentifier.inputAndAI,
            title: "输入与 AI"
        )
        let voiceStack = addSettingsTab(
            to: tabView,
            identifier: TabIdentifier.voice,
            title: "语音"
        )
        let voiceHistoryStatsStack = addSettingsTab(
            to: tabView,
            identifier: TabIdentifier.voiceHistory,
            title: "语音历史"
        )
        let cloudStack = addSettingsTab(
            to: tabView,
            identifier: TabIdentifier.cloudHistory,
            title: "云端与历史"
        )
        let profileStack = addSettingsTab(
            to: tabView,
            identifier: TabIdentifier.languageProfile,
            title: "语言画像"
        )
        let statusStack = addSettingsTab(
            to: tabView,
            identifier: TabIdentifier.statusAndData,
            title: "状态与数据"
        )
        buildInputSettingsPage(inputStack)
        buildVoiceSettingsPage(voiceStack)
        buildVoiceHistoryStatsPage(voiceHistoryStatsStack)
        buildCloudHistoryPage(cloudStack)
        buildLanguageProfilePage(profileStack)
        buildStatusDataPage(statusStack)
    }
}

extension PrivacyCenterWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        voiceShortcutCaptureButton.cancelCapture()
        voiceShortcutCancelButton.isEnabled = false
        voiceTranslateShortcutCaptureButton.cancelCapture()
        voiceTranslateShortcutCancelButton.isEnabled = false
    }
}
