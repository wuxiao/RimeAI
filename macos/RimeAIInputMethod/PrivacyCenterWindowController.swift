import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PrivacyCenterWindowController: NSObject {
    static let shared = PrivacyCenterWindowController()

    private let settings = RimeAISettingsStore.shared
    private let credentialStore = FileCloudCredentialStore.shared
    private let historyService = RimeAIHistoryService.shared
    private let window: NSWindow
    private let characterSetPopup = NSPopUpButton(
        frame: .zero,
        pullsDown: false
    )
    private let characterWidthPopup = NSPopUpButton(
        frame: .zero,
        pullsDown: false
    )
    private let punctuationPopup = NSPopUpButton(
        frame: .zero,
        pullsDown: false
    )
    private let aiToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let offlineToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    private let contextPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cloudModelPopup = NSPopUpButton(
        frame: .zero,
        pullsDown: false
    )
    private let apiKeyField = NSSecureTextField()
    private let cloudStatusLabel = NSTextField(labelWithString: "")
    private let historyStatusLabel = NSTextField(labelWithString: "")
    private let voiceToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    private let voiceRimeHotwordToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    private let voiceInstructionLabel = NSTextField(labelWithString: "")
    private let voiceShortcutCaptureButton = SettingsShortcutCaptureButton()
    private let voiceShortcutCancelButton = NSButton(
        title: "取消编辑",
        target: nil,
        action: nil
    )
    private let voiceShortcutStatusLabel = NSTextField(labelWithString: "")
    private let voiceStatusLabel = NSTextField(labelWithString: "")
    private let disabledAIField = NSTextField()
    private let disabledContextField = NSTextField()
    private let daemonStatusLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let artifactLabel = NSTextField(labelWithString: "")
    private let diagnosticsLabel = NSTextField(labelWithString: "")
    private let dataSizeLabel = NSTextField(labelWithString: "")
    private let settingsActionStatusLabel = NSTextField(labelWithString: "")
    private let importSettingsButton = NSButton(
        title: "导入设置…",
        target: nil,
        action: nil
    )
    private let restoreDefaultSettingsButton = NSButton(
        title: "恢复默认设置…",
        target: nil,
        action: nil
    )
    private var daemonObserver: NSObjectProtocol?
    private var cloudObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var diagnosticsObserver: NSObjectProtocol?
    private var settingsActionStatusObserver: NSObjectProtocol?
    private var voiceShortcutStatusObserver: NSObjectProtocol?
    private var runtimeSyncGeneration: UInt64 = 0
    private var isRuntimeSyncInProgress = false
    private var pendingRuntimeOperations: [SettingsRuntimeOperation] = []
    private var activeRuntimeOperations: [SettingsRuntimeOperation] = []
    private var failedRuntimeOperations: [(service: String, error: String)] = []
    private var runtimeSyncDescription = ""

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
        configureInterface()
        observeState()
        refresh()
    }

    func showWindow() {
        refresh()
        if settings.aiEnabled {
            DaemonClient.shared.connect()
        }
        if settings.cloudConfigured {
            CloudBrokerClient.shared.connect()
        }
        window.center()
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

        let tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.setAccessibilityLabel("RimeAI 设置分类")
        tabView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let rootStack = NSStackView(views: [
            title,
            settingsActionStatusLabel,
            tabView,
        ])
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
            title: "输入与 AI"
        )
        let voiceStack = addSettingsTab(
            to: tabView,
            title: "语音"
        )
        let cloudStack = addSettingsTab(
            to: tabView,
            title: "云端与历史"
        )
        let statusStack = addSettingsTab(
            to: tabView,
            title: "状态与数据"
        )

        inputStack.addArrangedSubview(sectionTitle("常规输入"))
        inputStack.addArrangedSubview(
            label(
                "默认使用简体中文、半角字符和中文标点。也可以从菜单栏的"
                    + "输入法菜单直接切换这些选项。",
                secondary: true
            )
        )

        let characterSetRow = NSStackView()
        characterSetRow.orientation = .horizontal
        characterSetRow.spacing = 10
        characterSetRow.addArrangedSubview(label("汉字输出"))
        characterSetPopup.addItems(withTitles: ["简体中文", "繁体中文"])
        characterSetPopup.target = self
        characterSetPopup.action = #selector(characterSetChanged(_:))
        characterSetPopup.identifier = NSUserInterfaceItemIdentifier(
            "settings.character-set"
        )
        characterSetPopup.setAccessibilityLabel("汉字输出")
        characterSetRow.addArrangedSubview(characterSetPopup)
        inputStack.addArrangedSubview(characterSetRow)

        let characterWidthRow = NSStackView()
        characterWidthRow.orientation = .horizontal
        characterWidthRow.spacing = 10
        characterWidthRow.addArrangedSubview(label("字符宽度"))
        characterWidthPopup.addItems(withTitles: ["半角", "全角"])
        characterWidthPopup.target = self
        characterWidthPopup.action = #selector(characterWidthChanged(_:))
        characterWidthPopup.identifier = NSUserInterfaceItemIdentifier(
            "settings.character-width"
        )
        characterWidthPopup.setAccessibilityLabel("字符宽度")
        characterWidthRow.addArrangedSubview(characterWidthPopup)
        inputStack.addArrangedSubview(characterWidthRow)

        let punctuationRow = NSStackView()
        punctuationRow.orientation = .horizontal
        punctuationRow.spacing = 10
        punctuationRow.addArrangedSubview(label("标点样式"))
        punctuationPopup.addItems(withTitles: ["中文（，。）", "西文（,.）"])
        punctuationPopup.target = self
        punctuationPopup.action = #selector(punctuationChanged(_:))
        punctuationPopup.identifier = NSUserInterfaceItemIdentifier(
            "settings.punctuation-style"
        )
        punctuationPopup.setAccessibilityLabel("标点样式")
        punctuationRow.addArrangedSubview(punctuationPopup)
        inputStack.addArrangedSubview(punctuationRow)

        addSeparator(to: inputStack)
        inputStack.addArrangedSubview(sectionTitle("AI 与隐私"))
        inputStack.addArrangedSubview(
            label(
                "Rime 同步生成候选；语义模型只通过当前用户私有的 Unix "
                    + "Domain Socket 运行。配置云端 API Key 后，另一个独立进程"
                    + "才可访问固定的云端端点。",
                secondary: true
            )
        )

        aiToggle.title = "启用本地语义候选"
        aiToggle.target = self
        aiToggle.action = #selector(toggleChanged(_:))
        aiToggle.identifier = NSUserInterfaceItemIdentifier(
            "settings.ai-enabled"
        )
        inputStack.addArrangedSubview(aiToggle)

        offlineToggle.title =
            "本地 daemon 网络隔离（始终开启：禁止 IPv4 / IPv6 socket）"
        offlineToggle.isEnabled = false
        offlineToggle.setAccessibilityHelp(
            "固定开启的安全策略，不能在设置中关闭。"
        )
        inputStack.addArrangedSubview(offlineToggle)

        let contextRow = NSStackView()
        contextRow.orientation = .horizontal
        contextRow.spacing = 10
        contextRow.addArrangedSubview(label("上下文模式"))
        contextPopup.addItems(
            withTitles: [
                "严格：仅拼音与候选",
                "标准：当前应用最近上屏 100 字",
                "智能：显式读取光标前最多 400 字",
            ]
        )
        contextPopup.target = self
        contextPopup.action = #selector(contextChanged(_:))
        contextPopup.identifier = NSUserInterfaceItemIdentifier(
            "settings.context-policy"
        )
        contextPopup.setAccessibilityLabel("上下文模式")
        contextRow.addArrangedSubview(contextPopup)
        inputStack.addArrangedSubview(contextRow)

        addSeparator(to: inputStack)
        inputStack.addArrangedSubview(sectionTitle("应用级策略"))
        inputStack.addArrangedSubview(
            label(
                "仅禁用本地 AI 的 Bundle ID（逗号分隔，精确匹配）",
                secondary: true
            )
        )
        disabledAIField.placeholderString =
            "例如：com.example.PasswordManager"
        disabledAIField.translatesAutoresizingMaskIntoConstraints = false
        disabledAIField.identifier = NSUserInterfaceItemIdentifier(
            "settings.disabled-ai-applications"
        )
        disabledAIField.setAccessibilityLabel("禁用本地 AI 的应用 Bundle ID")
        inputStack.addArrangedSubview(disabledAIField)
        disabledAIField.widthAnchor.constraint(
            equalTo: inputStack.widthAnchor
        ).isActive = true
        inputStack.addArrangedSubview(
            label(
                "仅禁用本地上下文的 Bundle ID（本地 AI 退化为严格模式）",
                secondary: true
            )
        )
        disabledContextField.placeholderString = "例如：com.example.Terminal"
        disabledContextField.translatesAutoresizingMaskIntoConstraints = false
        disabledContextField.identifier = NSUserInterfaceItemIdentifier(
            "settings.disabled-context-applications"
        )
        disabledContextField.setAccessibilityLabel(
            "禁用本地上下文的应用 Bundle ID"
        )
        inputStack.addArrangedSubview(disabledContextField)
        disabledContextField.widthAnchor.constraint(
            equalTo: inputStack.widthAnchor
        ).isActive = true
        let savePolicies = NSButton(
            title: "保存应用策略",
            target: self,
            action: #selector(saveApplicationPolicies(_:))
        )
        inputStack.addArrangedSubview(savePolicies)

        voiceStack.addArrangedSubview(
            sectionTitle("本地语音听写（实验）")
        )
        configureWrapping(voiceInstructionLabel)
        voiceInstructionLabel.textColor = .secondaryLabelColor
        voiceStack.addArrangedSubview(voiceInstructionLabel)

        let shortcutRow = NSStackView()
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .centerY
        shortcutRow.spacing = 8
        shortcutRow.addArrangedSubview(label("按住说话快捷键"))
        voiceShortcutCaptureButton.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-shortcut.capture"
        )
        voiceShortcutCaptureButton.onCaptureStateChanged = { [weak self]
            isCapturing in
            guard let self else {
                return
            }
            self.voiceShortcutCancelButton.isEnabled = isCapturing
            if isCapturing {
                self.voiceShortcutStatusLabel.stringValue =
                    "正在等待新组合；"
                    + VoiceDictationShortcut.validationFailureDescription
                self.voiceShortcutStatusLabel.textColor = .controlAccentColor
            }
        }
        voiceShortcutCaptureButton.onKeyEvent = { [weak self]
            keyCode,
            modifierFlags in
            self?.captureVoiceShortcut(
                keyCode: keyCode,
                modifierFlags: modifierFlags
            )
        }
        voiceShortcutCaptureButton.onCancel = { [weak self] in
            self?.refreshVoiceShortcutStatus()
        }
        shortcutRow.addArrangedSubview(voiceShortcutCaptureButton)
        voiceShortcutCancelButton.target = self
        voiceShortcutCancelButton.action = #selector(cancelVoiceShortcutEdit(_:))
        voiceShortcutCancelButton.isEnabled = false
        shortcutRow.addArrangedSubview(voiceShortcutCancelButton)
        let restoreVoiceShortcutButton = NSButton(
            title: "恢复默认",
            target: self,
            action: #selector(restoreDefaultVoiceShortcut(_:))
        )
        restoreVoiceShortcutButton.setAccessibilityHelp(
            "恢复默认按住说话快捷键 "
                + VoiceDictationShortcut.default.displayName + "。"
        )
        shortcutRow.addArrangedSubview(restoreVoiceShortcutButton)
        voiceStack.addArrangedSubview(shortcutRow)
        configureWrapping(voiceShortcutStatusLabel)
        voiceShortcutStatusLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-shortcut.status"
        )
        voiceShortcutStatusLabel.setAccessibilityLabel("语音快捷键状态")
        voiceStack.addArrangedSubview(voiceShortcutStatusLabel)

        voiceToggle.title = "启用按住说话"
        voiceToggle.target = self
        voiceToggle.action = #selector(toggleChanged(_:))
        voiceToggle.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-enabled"
        )
        voiceStack.addArrangedSubview(voiceToggle)
        voiceStack.addArrangedSubview(
            label(
                "可单独允许把当前焦点会话中成功确认的 Rime 词条作为"
                    + "易失本地热词。不会读取完整用户词典、长期历史或光标"
                    + "文本；切换焦点、进入安全输入或关闭语音时立即清空。",
                secondary: true
            )
        )
        voiceRimeHotwordToggle.title =
            "使用当前会话已确认的 Rime 词条辅助语音（实验）"
        voiceRimeHotwordToggle.target = self
        voiceRimeHotwordToggle.action = #selector(toggleChanged(_:))
        voiceRimeHotwordToggle.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-rime-hotwords"
        )
        voiceStack.addArrangedSubview(voiceRimeHotwordToggle)
        configureWrapping(voiceStatusLabel)
        voiceStatusLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-status"
        )
        voiceStatusLabel.setAccessibilityLabel("语音服务状态")
        voiceStack.addArrangedSubview(voiceStatusLabel)
        let voiceButtons = NSStackView()
        voiceButtons.orientation = .horizontal
        voiceButtons.spacing = 8
        voiceButtons.addArrangedSubview(
            NSButton(
                title: "重试语音服务",
                target: self,
                action: #selector(retryVoice(_:))
            )
        )
        voiceButtons.addArrangedSubview(
            NSButton(
                title: "打开麦克风权限…",
                target: self,
                action: #selector(openMicrophonePrivacy(_:))
            )
        )
        voiceButtons.addArrangedSubview(
            NSButton(
                title: "打开语音识别权限…",
                target: self,
                action: #selector(openSpeechRecognitionPrivacy(_:))
            )
        )
        voiceStack.addArrangedSubview(voiceButtons)

        cloudStack.addArrangedSubview(sectionTitle("云端模型增强"))
        cloudStack.addArrangedSubview(
            label(
                "保存 API Key 即启用：RimeAI 会跨应用、以明文长期保存每次"
                    + "上屏文本、拼音、应用标识和时间，并把最近文本、检索片段、"
                    + "当前拼音及候选发送到阿里云。只有 macOS Secure Event Input "
                    + "会自动阻止记录与上传；本地下方的应用策略不限制云端历史。",
                secondary: true
            )
        )
        configureWrapping(cloudStatusLabel)
        cloudStatusLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.cloud-status"
        )
        cloudStatusLabel.setAccessibilityLabel("云增强状态")
        cloudStack.addArrangedSubview(cloudStatusLabel)

        let modelRow = NSStackView()
        modelRow.orientation = .horizontal
        modelRow.spacing = 10
        modelRow.addArrangedSubview(label("排序模型"))
        cloudModelPopup.addItems(
            withTitles: RimeAICloudConfiguration.rankingModelIDs
        )
        cloudModelPopup.target = self
        cloudModelPopup.action = #selector(cloudModelChanged(_:))
        cloudModelPopup.identifier = NSUserInterfaceItemIdentifier(
            "settings.cloud-model"
        )
        cloudModelPopup.setAccessibilityLabel("云端排序模型")
        modelRow.addArrangedSubview(cloudModelPopup)
        cloudStack.addArrangedSubview(modelRow)

        apiKeyField.placeholderString = "GLM 云端 API Key（保存至 ~/.config/rimeai/cloud.env）"
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.identifier = NSUserInterfaceItemIdentifier(
            "settings.cloud-api-key"
        )
        apiKeyField.setAccessibilityLabel("云端 API Key")
        cloudStack.addArrangedSubview(apiKeyField)
        apiKeyField.widthAnchor.constraint(
            equalTo: cloudStack.widthAnchor
        ).isActive = true
        let cloudButtons = NSStackView()
        cloudButtons.orientation = .horizontal
        cloudButtons.spacing = 8
        cloudButtons.addArrangedSubview(
            NSButton(
                title: "保存 API Key 并启用",
                target: self,
                action: #selector(saveAPIKey(_:))
            )
        )
        cloudButtons.addArrangedSubview(
            NSButton(
                title: "移除 API Key（保留历史）",
                target: self,
                action: #selector(removeAPIKey(_:))
            )
        )
        cloudStack.addArrangedSubview(cloudButtons)

        addSeparator(to: cloudStack)
        cloudStack.addArrangedSubview(sectionTitle("长期明文历史"))
        configureWrapping(historyStatusLabel)
        historyStatusLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.history-status"
        )
        historyStatusLabel.setAccessibilityLabel("长期明文历史状态")
        cloudStack.addArrangedSubview(historyStatusLabel)
        let historyButtons = NSStackView()
        historyButtons.orientation = .horizontal
        historyButtons.spacing = 8
        historyButtons.addArrangedSubview(
            NSButton(
                title: "导出明文历史…",
                target: self,
                action: #selector(exportHistory(_:))
            )
        )
        historyButtons.addArrangedSubview(
            NSButton(
                title: "永久清除全部历史…",
                target: self,
                action: #selector(clearHistory(_:))
            )
        )
        cloudStack.addArrangedSubview(historyButtons)

        statusStack.addArrangedSubview(
            sectionTitle("本地模型与运行状态")
        )
        for statusLabel in [
            daemonStatusLabel,
            modelLabel,
            artifactLabel,
            dataSizeLabel,
        ] {
            configureWrapping(statusLabel)
            statusStack.addArrangedSubview(statusLabel)
        }

        addSeparator(to: statusStack)
        statusStack.addArrangedSubview(sectionTitle("设置管理"))
        statusStack.addArrangedSubview(
            label(
                "导入只接受经过 Store 严格校验的设置文档；API Key 不会导出或导入。"
                    + "导入与恢复默认后，daemon、云端 broker 和语音 helper 会按新设置收敛。",
                secondary: true
            )
        )
        let settingsButtons = NSStackView()
        settingsButtons.orientation = .horizontal
        settingsButtons.spacing = 8
        importSettingsButton.target = self
        importSettingsButton.action = #selector(importSettings(_:))
        settingsButtons.addArrangedSubview(importSettingsButton)
        settingsButtons.addArrangedSubview(
            NSButton(
                title: "导出设置…",
                target: self,
                action: #selector(exportSettings(_:))
            )
        )
        restoreDefaultSettingsButton.target = self
        restoreDefaultSettingsButton.action = #selector(
            restoreDefaultSettings(_:)
        )
        settingsButtons.addArrangedSubview(restoreDefaultSettingsButton)
        statusStack.addArrangedSubview(settingsButtons)

        addSeparator(to: statusStack)
        statusStack.addArrangedSubview(sectionTitle("无原文诊断"))
        configureWrapping(diagnosticsLabel)
        diagnosticsLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.diagnostics-status"
        )
        diagnosticsLabel.setAccessibilityLabel("无原文诊断计数")
        statusStack.addArrangedSubview(diagnosticsLabel)
        let dataButtons = NSStackView()
        dataButtons.orientation = .horizontal
        dataButtons.spacing = 8
        dataButtons.addArrangedSubview(
            NSButton(
                title: "清除短期上下文",
                target: self,
                action: #selector(clearEphemeralData(_:))
            )
        )
        dataButtons.addArrangedSubview(
            NSButton(
                title: "重置诊断计数",
                target: self,
                action: #selector(resetDiagnostics(_:))
            )
        )
        statusStack.addArrangedSubview(dataButtons)

        addSeparator(to: statusStack)
        statusStack.addArrangedSubview(sectionTitle("危险操作"))
        statusStack.addArrangedSubview(
            NSButton(
                title: "停用 AI 并清除本地制品…",
                target: self,
                action: #selector(clearAllProductData(_:))
            )
        )
        statusStack.addArrangedSubview(
            label(
                "清除操作会移除 API Key，并将历史、AI 模型、daemon 与 "
                    + "LaunchAgent 移到废纸篓，但不修改 Rime 用户词典。",
                secondary: true
            )
        )
    }

    private func observeState() {
        daemonObserver = NotificationCenter.default.addObserver(
            forName: .rimeAIDaemonStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.applyDaemonStatus(notification)
            }
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .rimeAISettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        cloudObserver = NotificationCenter.default.addObserver(
            forName: .rimeAICloudBrokerStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      self.settings.cloudConfigured,
                      let status = notification.userInfo?["status"] as? String
                else {
                    return
                }
                self.cloudStatusLabel.stringValue =
                    "云增强：\(status) · "
                    + RimeAICloudConfiguration.endpoint.absoluteString
            }
        }
        diagnosticsObserver = NotificationCenter.default.addObserver(
            forName: .rimeAIDiagnosticsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.diagnosticsLabel.stringValue =
                    self?.diagnosticsDescription() ?? ""
            }
        }
        settingsActionStatusObserver = NotificationCenter.default.addObserver(
            forName: .rimeAISettingsActionStatusDidChange,
            object: SettingsActionStatusCenter.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSettingsActionStatus()
            }
        }
        voiceShortcutStatusObserver = NotificationCenter.default.addObserver(
            forName: .rimeAIVoiceHotKeyRegistrationDidChange,
            object: VoiceHotKeyManager.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshVoiceShortcutStatus()
            }
        }
    }

    private func refresh() {
        characterSetPopup.selectItem(
            at: settings.characterSet == .simplified ? 0 : 1
        )
        characterWidthPopup.selectItem(
            at: settings.characterWidth == .half ? 0 : 1
        )
        punctuationPopup.selectItem(
            at: settings.punctuationStyle == .chinese ? 0 : 1
        )
        aiToggle.state = settings.aiEnabled ? .on : .off
        aiToggle.isEnabled = !isRuntimeSyncInProgress
        offlineToggle.state = settings.offlineLockEnabled ? .on : .off
        voiceToggle.state = settings.voiceEnabled ? .on : .off
        voiceToggle.isEnabled = settings.aiEnabled
            && !isRuntimeSyncInProgress
        let voiceShortcut = settings.voiceShortcut
        voiceInstructionLabel.stringValue =
            "按住 \(voiceShortcut.displayName) 录音，松开后等待最终文本；"
            + "Space 或回车确认上屏，Esc 取消。音频只在独立的本地 helper "
            + "内存中处理，不写入录音或听写历史。Apple Speech 属于系统管理"
            + "引擎；麦克风与语音识别权限都由 RimeAI Voice Helper 申请和"
            + "持有，而不是输入法进程。"
        voiceToggle.title =
            "启用按住说话（\(voiceShortcut.displayName)）"
        voiceShortcutCaptureButton.showShortcut(voiceShortcut.displayName)
        voiceShortcutCancelButton.isEnabled =
            voiceShortcutCaptureButton.isCapturing
        refreshVoiceShortcutStatus()
        voiceRimeHotwordToggle.state = settings.voiceRimeHotwordsEnabled
            ? .on
            : .off
        voiceRimeHotwordToggle.isEnabled = settings.aiEnabled
            && settings.voiceEnabled
            && settings.contextPolicy != .strict
        cloudModelPopup.selectItem(
            withTitle: settings.cloudModelID
        )
        contextPopup.selectItem(
            at: [
                ContextPolicy.strict: 0,
                ContextPolicy.standard: 1,
                ContextPolicy.smart: 2,
            ][settings.contextPolicy] ?? 1
        )
        disabledAIField.stringValue =
            settings.disabledAIApplications.joined(separator: ", ")
        disabledContextField.stringValue =
            settings.disabledContextApplications.joined(separator: ", ")
        diagnosticsLabel.stringValue = diagnosticsDescription()
        dataSizeLabel.stringValue = dataSizeDescription()
        let hasCredential = try? credentialStore.containsAPIKey()
        if settings.cloudConfigured, hasCredential == true {
            cloudStatusLabel.stringValue =
                "云增强：已启用 · \(RimeAICloudConfiguration.provider) · "
                + RimeAICloudConfiguration.endpoint.absoluteString
        } else if settings.cloudConfigured, hasCredential == nil {
            cloudStatusLabel.stringValue =
                "云增强：已启用 · 凭据文件暂时不可读，将在输入时重试"
        } else {
            cloudStatusLabel.stringValue =
                "云增强：未启用 · 未配置的输入不会保存到长期历史或上传"
        }
        refreshVoiceStatus()
        refreshSettingsActionStatus()
        if let statistics = try? historyService.statistics() {
            historyStatusLabel.stringValue =
                "明文历史：\(statistics.recordCount) 条 · 代次 "
                + "\(statistics.generation) · 待生成向量 "
                + "\(statistics.pendingEmbeddingJobs) 条"
        } else {
            historyStatusLabel.stringValue = "明文历史：存储不可用"
        }
        if !settings.aiEnabled {
            daemonStatusLabel.stringValue =
                "Daemon：已停用 · 重新开启 AI 后按需加载"
        }
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        if isRuntimeSyncInProgress,
           sender === aiToggle || sender === voiceToggle
        {
            refresh()
            updateSettingsActionStatus(
                .working,
                "另一个生命周期操作仍在进行，请稍后再更改开关"
            )
            return
        }
        if sender === aiToggle {
            let enabled = sender.state == .on
            settings.aiEnabled = enabled
            if !enabled {
                settings.clearEphemeralData()
                DaemonClient.shared.disconnect()
                settings.voiceEnabled = false
            }
            reconcileRuntime(
                SettingsRuntimeTransition(
                    daemonEnabled: enabled,
                    cloudBrokerEnabled: nil,
                    voiceHelperEnabled: enabled ? nil : false
                ),
                operation: enabled ? "本地 AI 已设为启用" : "本地 AI 已设为停用"
            )
        } else if sender === voiceToggle {
            guard settings.aiEnabled else {
                voiceToggle.state = .off
                return
            }
            let enabled = sender.state == .on
            if !enabled {
                settings.voiceEnabled = false
            }
            reconcileRuntime(
                SettingsRuntimeTransition(
                    daemonEnabled: nil,
                    cloudBrokerEnabled: nil,
                    voiceHelperEnabled: enabled
                ),
                operation: enabled ? "语音已设为启用" : "语音已设为停用"
            )
        } else if sender === voiceRimeHotwordToggle {
            guard settings.aiEnabled,
                  settings.voiceEnabled,
                  settings.contextPolicy != .strict
            else {
                voiceRimeHotwordToggle.state = settings
                    .voiceRimeHotwordsEnabled ? .on : .off
                return
            }
            settings.voiceRimeHotwordsEnabled = sender.state == .on
        }
    }

    @objc private func retryVoice(_ sender: Any?) {
        guard !rejectLifecycleActionDuringRuntimeSync("重试语音服务") else {
            return
        }
        guard settings.aiEnabled, settings.voiceEnabled else {
            refreshVoiceStatus()
            return
        }
        // 只在 lifecycle 期望状态操作成功后广播 retry；认证 XPC ready
        // 仍由语音 coordinator 独立确认，不能从进程或 socket 推断。
        reconcileRuntime(
            SettingsRuntimeTransition(
                daemonEnabled: nil,
                cloudBrokerEnabled: nil,
                voiceHelperEnabled: true
            ),
            operation: "语音服务重试已提交"
        )
    }

    private func captureVoiceShortcut(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard let shortcut = VoiceHotKeyManager.makeShortcut(
            keyCode: keyCode,
            modifierFlags: modifierFlags
        ) else {
            voiceShortcutCaptureButton.showValidationFailure()
            voiceShortcutStatusLabel.stringValue =
                "组合不可用；原快捷键 \(settings.voiceShortcut.displayName) 仍已保留"
            voiceShortcutStatusLabel.textColor = .systemRed
            updateSettingsActionStatus(
                .failure,
                "快捷键未更改："
                    + VoiceDictationShortcut.validationFailureDescription
            )
            return
        }
        settings.voiceShortcut = shortcut
        voiceShortcutCaptureButton.finishCapture(
            displayName: shortcut.displayName
        )
        voiceShortcutCancelButton.isEnabled = false
        updateSettingsActionStatus(
            .success,
            "语音快捷键已更改为 \(shortcut.displayName)"
        )
        refreshVoiceShortcutStatus()
    }

    @objc private func cancelVoiceShortcutEdit(_ sender: Any?) {
        voiceShortcutCaptureButton.cancelCapture()
        voiceShortcutCancelButton.isEnabled = false
        refreshVoiceShortcutStatus()
    }

    @objc private func restoreDefaultVoiceShortcut(_ sender: Any?) {
        let shortcut = VoiceDictationShortcut.default
        settings.voiceShortcut = shortcut
        voiceShortcutCaptureButton.finishCapture(
            displayName: shortcut.displayName
        )
        voiceShortcutCancelButton.isEnabled = false
        updateSettingsActionStatus(
            .success,
            "语音快捷键已恢复为 \(shortcut.displayName)"
        )
        refreshVoiceShortcutStatus()
    }

    @objc private func openMicrophonePrivacy(_ sender: Any?) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSpeechRecognitionPrivacy(_ sender: Any?) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func characterSetChanged(_ sender: NSPopUpButton) {
        settings.characterSet = sender.indexOfSelectedItem == 0
            ? .simplified
            : .traditional
        RimeEngine.shared.apply(settings.inputPreferences)
    }

    @objc private func characterWidthChanged(_ sender: NSPopUpButton) {
        settings.characterWidth = sender.indexOfSelectedItem == 0
            ? .half
            : .full
        RimeEngine.shared.apply(settings.inputPreferences)
    }

    @objc private func punctuationChanged(_ sender: NSPopUpButton) {
        settings.punctuationStyle = sender.indexOfSelectedItem == 0
            ? .chinese
            : .western
        RimeEngine.shared.apply(settings.inputPreferences)
    }

    @objc private func contextChanged(_ sender: NSPopUpButton) {
        settings.contextPolicy = [
            ContextPolicy.strict,
            ContextPolicy.standard,
            ContextPolicy.smart,
        ][max(0, min(sender.indexOfSelectedItem, 2))]
        settings.clearEphemeralData()
    }

    @objc private func cloudModelChanged(_ sender: NSPopUpButton) {
        guard let modelID = sender.selectedItem?.title else {
            return
        }
        settings.cloudModelID = modelID
    }

    @objc private func saveAPIKey(_ sender: Any?) {
        guard !rejectLifecycleActionDuringRuntimeSync("启用云增强") else {
            return
        }
        do {
            try credentialStore.saveAPIKey(apiKeyField.stringValue)
            settings.cloudModelID = cloudModelPopup.selectedItem?.title
                ?? RimeAICloudConfiguration.defaultRankingModelID
            settings.cloudConfigured = true
            apiKeyField.stringValue = ""
            reconcileRuntime(
                SettingsRuntimeTransition(
                    daemonEnabled: nil,
                    cloudBrokerEnabled: true,
                    voiceHelperEnabled: nil
                ),
                operation: "云增强已设为启用"
            )
            refresh()
        } catch {
            presentError(
                error,
                message: "未能保存 API Key",
                information: "API Key 必须非空、不超过 512 字节且不含换行，"
                    + "保存到 ~/.config/rimeai/cloud.env（权限 0600）。"
            )
        }
    }

    @objc private func removeAPIKey(_ sender: Any?) {
        guard !rejectLifecycleActionDuringRuntimeSync("移除 API Key") else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "移除 API Key 并停用云增强？"
        alert.informativeText =
            "长期明文历史会保留，且可继续导出或手动清除。"
        alert.addButton(withTitle: "移除并停用")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else {
                return
            }
            guard !self.rejectLifecycleActionDuringRuntimeSync("移除 API Key")
            else {
                return
            }
            // Disable first so no new cloud request or history write can race
            // with credential removal.
            self.settings.cloudConfigured = false
            CloudBrokerClient.shared.disconnect()
            var credentialFailure: (service: String, error: String)?
            do {
                try self.credentialStore.deleteAPIKey()
                self.apiKeyField.stringValue = ""
            } catch {
                credentialFailure = (
                    service: "API Key",
                    error: error.localizedDescription
                )
            }
            self.reconcileRuntime(
                SettingsRuntimeTransition(
                    daemonEnabled: nil,
                    cloudBrokerEnabled: false,
                    voiceHelperEnabled: nil
                ),
                operation: "云增强已设为停用",
                initialFailure: credentialFailure
            )
            self.refresh()
        }
    }

    @objc private func exportHistory(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RimeAI-history.jsonl"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "jsonl") ?? .json,
        ]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                return
            }
            do {
                try self.historyService.exportJSONL(to: url)
            } catch {
                self.presentError(
                    error,
                    message: "未能导出历史",
                    information: "目标文件没有被完整写入。"
                )
            }
        }
    }

    @objc private func clearHistory(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "永久清除全部明文历史？"
        alert.informativeText =
            "将删除所有跨应用上屏记录、待处理向量和本地检索索引。"
                + "此操作无法撤销，但不会移除 API Key。"
        alert.addButton(withTitle: "永久清除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .critical
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else {
                return
            }
            // Cancel local and cloud work before advancing the history
            // generation so a cleared snapshot cannot later be displayed.
            self.settings.clearEphemeralData()
            do {
                _ = try self.historyService.clearAll()
                self.refresh()
            } catch {
                self.presentError(
                    error,
                    message: "未能完整清除历史",
                    information: "请保留当前数据并重试。"
                )
            }
        }
    }

    @objc private func saveApplicationPolicies(_ sender: Any?) {
        settings.disabledAIApplications = splitApplications(
            disabledAIField.stringValue
        )
        settings.disabledContextApplications = splitApplications(
            disabledContextField.stringValue
        )
        settings.clearEphemeralData()
        refresh()
    }

    @objc private func clearEphemeralData(_ sender: Any?) {
        settings.clearEphemeralData()
    }

    @objc private func resetDiagnostics(_ sender: Any?) {
        settings.resetDiagnostics()
        updateSettingsActionStatus(.success, "诊断计数已重置")
    }

    @objc private func importSettings(_ sender: Any?) {
        guard !isRuntimeSyncInProgress else {
            updateSettingsActionStatus(
                .working,
                "上一次设置变更仍在同步运行状态，请稍后再导入"
            )
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK,
                  let url = panel.url,
                  let self
            else {
                return
            }
            guard !self.rejectLifecycleActionDuringRuntimeSync("导入设置")
            else {
                return
            }
            self.updateSettingsActionStatus(.working, "正在验证导入设置")
            do {
                // 先用 metadata 拒绝过大文档，避免在解码门禁前将整个
                // 非受信文件读入输入法进程；Store 仍保留第二道上限。
                try SettingsDocumentCodec.validateFileSize(at: url)
                let document = try Data(contentsOf: url, options: .mappedIfSafe)
                // 这里只取得严格凭据复验结果；设置文档从不承载、读取或写入
                // API Key 内容。凭据文件不可读时必须在应用任何设置前失败。
                let hasCloudCredential = try self.credentialStore
                    .containsAPIKey()
                try self.settings.applyImport(
                    document,
                    hasCloudCredential: hasCloudCredential
                )
                self.settings.clearEphemeralData()
                let after = self.settings.exportSnapshot()
                self.reconcileRuntime(
                    SettingsRuntimeTransition.plan(
                        desired: after,
                        // 现有进程、socket 节点与 UI 状态都不是当前
                        // generation 的认证存活证明，不能据此跳过幂等收敛。
                        observation: .unverified
                    ),
                    operation: "设置已从 \(url.lastPathComponent) 导入"
                )
            } catch {
                self.presentError(
                    error,
                    message: "未能导入设置",
                    information: "文件必须是受支持的 RimeAI 设置文档；"
                        + "API Key 不会从文件导入，现有设置未被部分修改。"
                )
            }
        }
    }

    @objc private func exportSettings(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RimeAI-settings.json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK,
                  let url = panel.url,
                  let self
            else {
                return
            }
            self.updateSettingsActionStatus(.working, "正在导出设置")
            do {
                let data = try SettingsDocumentCodec.encode(
                    self.settings.exportSnapshot()
                )
                try data.write(to: url, options: .atomic)
                self.updateSettingsActionStatus(
                    .success,
                    "设置已导出为 \(url.lastPathComponent)"
                )
            } catch {
                self.presentError(
                    error,
                    message: "未能导出设置",
                    information: "目标文件没有被完整写入；现有设置未被修改。"
                )
            }
        }
    }

    @objc private func restoreDefaultSettings(_ sender: Any?) {
        guard !isRuntimeSyncInProgress else {
            updateSettingsActionStatus(
                .working,
                "上一次设置变更仍在同步运行状态，请稍后再恢复默认"
            )
            return
        }
        let alert = NSAlert()
        alert.messageText = "恢复默认设置？"
        alert.informativeText =
            "输入偏好、AI 开关、云端状态、语音开关与快捷键、"
                + "上下文及应用策略将恢复默认。API Key、长期历史、"
                + "诊断计数、个人英文词与本地模型不会被删除。"
        alert.addButton(withTitle: "恢复默认")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self
            else {
                return
            }
            guard !self.rejectLifecycleActionDuringRuntimeSync("恢复默认设置")
            else {
                return
            }
            self.updateSettingsActionStatus(.working, "正在恢复默认设置")
            self.settings.restoreDefaults()
            self.settings.clearEphemeralData()
            let after = self.settings.exportSnapshot()
            self.reconcileRuntime(
                SettingsRuntimeTransition.plan(
                    desired: after,
                    observation: .unverified
                ),
                operation: "默认设置已恢复"
            )
        }
    }

    private func reconcileRuntime(
        _ transition: SettingsRuntimeTransition,
        operation: String,
        initialFailure: (service: String, error: String)? = nil
    ) {
        guard !isRuntimeSyncInProgress else {
            updateSettingsActionStatus(
                .working,
                "另一个生命周期操作仍在进行，请稍后重试"
            )
            return
        }
        runtimeSyncGeneration &+= 1
        if runtimeSyncGeneration == 0 {
            runtimeSyncGeneration = 1
        }
        pendingRuntimeOperations = transition.orderedOperations
        activeRuntimeOperations = pendingRuntimeOperations
        failedRuntimeOperations = initialFailure.map { [$0] } ?? []
        runtimeSyncDescription = operation
        guard !pendingRuntimeOperations.isEmpty else {
            activeRuntimeOperations = []
            setRuntimeSyncInProgress(false)
            updateSettingsActionStatus(
                .success,
                "\(operation)；认证运行态与期望状态一致"
            )
            return
        }
        setRuntimeSyncInProgress(true)
        let services = pendingRuntimeOperations.map(\.displayName)
        updateSettingsActionStatus(
            .working,
            "\(operation)；正在同步\(services.joined(separator: "、"))"
        )
        runNextRuntimeOperation(generation: runtimeSyncGeneration)
    }

    private func runNextRuntimeOperation(generation: UInt64) {
        guard generation == runtimeSyncGeneration else {
            return
        }
        guard !pendingRuntimeOperations.isEmpty else {
            setRuntimeSyncInProgress(false)
            if failedRuntimeOperations.isEmpty {
                let completionDescription: String
                if activeRuntimeOperations.count == 1,
                   let onlyOperation = activeRuntimeOperations.first
                {
                    completionDescription = SettingsRuntimeStatusCopy.applied(
                        onlyOperation
                    )
                } else {
                    completionDescription =
                        "生命周期操作已完成；服务状态继续刷新"
                        + "（以各服务状态为准）"
                }
                updateSettingsActionStatus(
                    .success,
                    "\(runtimeSyncDescription)；\(completionDescription)"
                )
            } else {
                let services = failedRuntimeOperations.map { $0.service }
                updateSettingsActionStatus(
                    .failure,
                    "\(runtimeSyncDescription)；"
                        + "\(services.joined(separator: "、"))"
                        + " 未能收敛，失败项目已保持或回退为关闭偏好"
                )
                presentRuntimeSyncFailure()
            }
            activeRuntimeOperations = []
            return
        }
        let next = pendingRuntimeOperations.removeFirst()
        performRuntimeOperation(next) { [weak self] result in
            guard let self,
                  generation == self.runtimeSyncGeneration
            else {
                return
            }
            if case let .failure(error) = result {
                self.failedRuntimeOperations.append((
                    service: next.displayName,
                    error: error.localizedDescription
                ))
            }
            self.runNextRuntimeOperation(generation: generation)
        }
    }

    private func performRuntimeOperation(
        _ operation: SettingsRuntimeOperation,
        completion: @escaping SettingsRuntimeCompletion
    ) {
        switch operation {
        case let .daemon(enabled):
            setManagedDaemonEnabled(enabled, completion: completion)
        case let .cloudBroker(enabled):
            setManagedCloudBrokerEnabled(enabled, completion: completion)
        case let .voiceHelper(enabled):
            guard !enabled || settings.aiEnabled else {
                settings.voiceEnabled = false
                let error = NSError(
                    domain: "fun.wwcn.inputmethod.RimeAI.settings-runtime",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "AI 总开关关闭时不能启用语音 helper。",
                    ]
                )
                setManagedVoiceEnabled(false) { _ in
                    completion(.failure(error))
                }
                return
            }
            setManagedVoiceEnabled(enabled, completion: completion)
        }
    }

    private func setRuntimeSyncInProgress(_ inProgress: Bool) {
        isRuntimeSyncInProgress = inProgress
        importSettingsButton.isEnabled = !inProgress
        restoreDefaultSettingsButton.isEnabled = !inProgress
        aiToggle.isEnabled = !inProgress
        voiceToggle.isEnabled = !inProgress && settings.aiEnabled
    }

    private func rejectLifecycleActionDuringRuntimeSync(
        _ action: String
    ) -> Bool {
        guard isRuntimeSyncInProgress else {
            return false
        }
        updateSettingsActionStatus(
            .working,
            "运行状态仍在同步，请稍后再\(action)"
        )
        return true
    }

    private func presentRuntimeSyncFailure() {
        let details = failedRuntimeOperations.map {
            "\($0.service)：\($0.error)"
        }.joined(separator: "\n")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "设置已更新，但操作未完全完成"
        alert.informativeText = details
            + "\n相关偏好已保持或回退为关闭；"
            + "其他服务的生命周期操作已完成，连接状态请见状态页。"
        alert.beginSheetModal(for: window)
    }

    @objc private func clearAllProductData(_ sender: Any?) {
        guard !rejectLifecycleActionDuringRuntimeSync("清除本地制品") else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "停用 AI 并清除本地制品？"
        alert.informativeText =
            "将停止 daemon，把模型、服务文件、运行文件和 LaunchAgent "
                + "移到废纸篓，并清除设置、诊断计数和短期上下文。"
                + "Rime 用户词典不会被修改；恢复 AI 需要重新安装。"
        alert.addButton(withTitle: "停用并移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self
            else {
                return
            }
            guard !self.rejectLifecycleActionDuringRuntimeSync("清除本地制品")
            else {
                return
            }
            self.disableAIAndTrashManagedData()
        }
    }

    private func disableAIAndTrashManagedData() {
        setRuntimeSyncInProgress(true)
        updateSettingsActionStatus(
            .working,
            "正在停用服务并清除本地制品"
        )
        DaemonClient.shared.disconnect()
        CloudBrokerClient.shared.disconnect()
        settings.cloudConfigured = false
        settings.voiceEnabled = false
        settings.aiEnabled = false
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else {
                return
            }
            let result = Result {
                try self.credentialStore.deleteAPIKey()
                _ = try self.historyService.clearAll()
                self.historyService.discardOpenStore()
                try VoiceHelperLifecycleCoordinator.shared
                    .suspendSynchronously(layout: layout)
                try Self.stopManagedCloudBroker(layout: layout)
                try Self.stopManagedDaemon(layout: layout)
                try Self.trashManagedData(layout: layout)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setRuntimeSyncInProgress(false)
                switch result {
                case .success:
                    self.settings.resetAllProductData()
                    self.settings.aiEnabled = false
                    self.daemonStatusLabel.stringValue =
                        "Daemon：停用期望状态已应用 · 连接状态继续刷新"
                    self.modelLabel.stringValue = "模型制品：已移到废纸篓"
                    self.artifactLabel.stringValue =
                        "重新安装开发者预览版后可恢复本地 AI。"
                    self.refresh()
                    self.updateSettingsActionStatus(
                        .success,
                        "停用生命周期与本地制品清理已完成；"
                            + "服务状态继续刷新（以状态页为准）"
                    )
                case let .failure(error):
                    self.presentError(
                        error,
                        message: "未能完整清除 RimeAI 本地制品",
                        information: "部分项目可能已经移到废纸篓；"
                            + "Rime 用户词典未被修改。"
                    )
                }
            }
        }
    }

    private func setManagedDaemonEnabled(
        _ enabled: Bool,
        completion: @escaping SettingsRuntimeCompletion
    ) {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        daemonStatusLabel.stringValue =
            enabled ? "Daemon：正在启动" : "Daemon：正在停止"
        if enabled {
            // Socket nodes and status notifications can outlive the client
            // generation that produced them. Invalidate that generation before
            // starting the lifecycle transaction so only the new hello can
            // prove readiness for this enable request.
            DaemonClient.shared.invalidateCurrentGeneration { [weak self] in
                guard let self else {
                    return
                }
                self.startManagedDaemonAndAwaitReadiness(
                    layout: layout,
                    completion: completion
                )
            }
            return
        }

        SettingsDaemonActivationFailurePolicy.apply(to: settings)
        DaemonClient.shared.disconnect()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try Self.suspendManagedDaemon(layout: layout)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                switch result {
                case .success:
                    self.daemonStatusLabel.stringValue =
                        "Daemon：停用期望状态已应用 · 连接状态继续刷新"
                    completion(.success(()))
                case let .failure(error):
                    // 执行态可能尚待人工重试，但持久化真值必须
                    // fail closed：下次启动不会再启用 daemon/voice。
                    SettingsDaemonActivationFailurePolicy.apply(
                        to: self.settings
                    )
                    DaemonClient.shared.disconnect()
                    self.daemonStatusLabel.stringValue =
                        "Daemon：关闭未完整完成 · 运行态不确定"
                    completion(.failure(error))
                }
            }
        }
    }

    private func startManagedDaemonAndAwaitReadiness(
        layout: RimeAIProductDataLayout,
        completion: @escaping SettingsRuntimeCompletion
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try Self.startManagedDaemon(layout: layout)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                switch result {
                case .success:
                    self.daemonStatusLabel.stringValue =
                        "Daemon：正在验证本代协议握手"
                    DaemonClient.shared.connectWhenReady { [weak self] result in
                        guard let self else {
                            return
                        }
                        switch result {
                        case .success:
                            self.daemonStatusLabel.stringValue =
                                "Daemon：本代协议握手就绪"
                            completion(.success(()))
                        case let .failure(error):
                            self.rollbackManagedDaemonActivation(
                                readinessError: error,
                                layout: layout,
                                completion: completion
                            )
                        }
                    }
                case let .failure(error):
                    SettingsDaemonActivationFailurePolicy.apply(
                        to: self.settings
                    )
                    DaemonClient.shared.disconnect()
                    self.daemonStatusLabel.stringValue =
                        error is SettingsDaemonDeactivationError
                            ? "Daemon：启动回滚未完整完成 · 运行态不确定"
                            : "Daemon：生命周期操作失败"
                    completion(.failure(error))
                }
            }
        }
    }

    private func rollbackManagedDaemonActivation(
        readinessError: Error,
        layout: RimeAIProductDataLayout,
        completion: @escaping SettingsRuntimeCompletion
    ) {
        SettingsDaemonActivationFailurePolicy.apply(to: settings)
        DaemonClient.shared.disconnect()
        daemonStatusLabel.stringValue = "Daemon：握手失败，正在回滚"
        DispatchQueue.global(qos: .userInitiated).async {
            let completionError =
                SettingsDaemonActivationFailurePolicy.rollbackError(
                    readinessError: readinessError,
                    performRollback: {
                        try Self.suspendManagedDaemon(layout: layout)
                    }
                )
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.daemonStatusLabel.stringValue =
                    "Daemon：握手失败，关闭偏好已回退"
                completion(.failure(completionError))
            }
        }
    }

    private func setManagedCloudBrokerEnabled(
        _ enabled: Bool,
        completion: @escaping SettingsRuntimeCompletion
    ) {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        if !enabled {
            settings.cloudConfigured = false
            CloudBrokerClient.shared.disconnect()
        }
        cloudStatusLabel.stringValue = enabled
            ? "云增强：正在启动"
            : "云增强：正在停止"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                if enabled {
                    try Self.startManagedCloudBroker(layout: layout)
                } else {
                    try Self.suspendManagedCloudBroker(layout: layout)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                switch result {
                case .success:
                    if enabled {
                        CloudBrokerClient.shared.connect()
                    } else {
                        self.refresh()
                    }
                    completion(.success(()))
                case let .failure(error):
                    if enabled {
                        self.settings.cloudConfigured = false
                        CloudBrokerClient.shared.disconnect()
                    } else {
                        // 无论 suspend 是否成功，都不允许失败把下次
                        // 启动的偏好重新拉回开启。
                        self.settings.cloudConfigured = false
                        CloudBrokerClient.shared.disconnect()
                    }
                    completion(.failure(error))
                }
            }
        }
    }

    private func setManagedVoiceEnabled(
        _ enabled: Bool,
        completion: @escaping SettingsRuntimeCompletion
    ) {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        voiceStatusLabel.stringValue = enabled
            ? "语音：正在启动本地 helper"
            : "语音：正在停止"
        VoiceHelperLifecycleCoordinator.shared.setDesired(
            enabled,
            layout: layout
        ) { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .success:
                self.settings.voiceEnabled = enabled
                if enabled {
                    NotificationCenter.default.post(
                        name: .rimeAIVoiceRetryRequested,
                        object: self.settings
                    )
                }
                self.refresh()
                completion(.success(()))
            case let .failure(error):
                self.settings.voiceEnabled = false
                self.voiceToggle.state = .off
                self.refreshVoiceStatus()
                completion(.failure(error))
            }
        }
    }

    private func refreshVoiceStatus() {
        guard settings.aiEnabled else {
            voiceStatusLabel.stringValue = "语音：已随 AI 总开关停用"
            return
        }
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        switch VoiceHelperLifecycle.installationStatus(layout: layout) {
        case .notInstalled:
            voiceStatusLabel.stringValue =
                "语音：helper 未安装 · 键盘输入不受影响"
        case .disabled:
            voiceStatusLabel.stringValue = settings.voiceEnabled
                ? "语音：等待启动"
                : "语音：已关闭"
        case .starting:
            voiceStatusLabel.stringValue = "语音：helper 正在启动"
        case .running:
            voiceStatusLabel.stringValue =
                "语音：helper 已运行 · 首次按住快捷键时完成认证与权限确认"
        }
    }

    private func applyDaemonStatus(_ notification: Notification) {
        guard settings.aiEnabled else {
            daemonStatusLabel.stringValue =
                "Daemon：已停用 · 模型资源已释放"
            return
        }
        let status = notification.userInfo?["status"] as? String ?? "未知"
        let artifactID =
            notification.userInfo?["model_artifact_id"] as? String
            ?? "尚未加载"
        let artifacts =
            notification.userInfo?["model_artifacts"]
                as? [DaemonModelArtifact]
            ?? []
        let enforced =
            notification.userInfo?["offline_lock"] as? Bool
            ?? false
        daemonStatusLabel.stringValue =
            "Daemon：\(status) · Internet socket 拦截："
            + (enforced ? "已生效" : "未确认")
        modelLabel.stringValue = "模型制品：\(artifactID)"
        artifactLabel.stringValue = artifacts.isEmpty
            ? "文件与校验值：等待 daemon 握手"
            : artifacts.map {
                "\($0.role)：\($0.path)\nSHA-256 \($0.sha256)"
            }.joined(separator: "\n")
    }

    private func diagnosticsDescription() -> String {
        let diagnostics = settings.diagnosticSnapshot()
        guard !diagnostics.isEmpty else {
            return "尚无诊断计数（不会保存原始输入文本）"
        }
        let names: [String: String] = [
            "request_started": "实际发出",
            "request_cancelled": "已取消",
            "result_shown": "候选已显示",
            "ranked_candidate_shown": "排序候选已显示",
            "sentence_suggestion_shown": "整句建议已显示",
            "same_top_candidate": "模型同意 Rime 首选",
            "insufficient_candidates": "完整候选不足，未执行重排",
            "sentence_script_mismatch": "整句字形与当前简繁设置不符",
            "below_confidence": "低置信度回退",
            "no_candidate": "无可用语义候选",
            "sentence_too_long": "整句超过 30 字",
            "sentence_incomplete": "整句候选未覆盖完整拼音",
            "semantic_accepted": "语义候选已采纳",
            "semantic_ranked_accepted": "排序候选已采纳",
            "semantic_sentence_accepted": "整句建议已采纳",
            "main_accepted": "Rime 主候选已采纳",
            "stale_result": "过期结果已丢弃",
            "invalid_result": "无效结果已拦截",
            "privacy_blocked": "隐私策略已拦截",
            "timeout": "推理超时",
            "circuit_open": "熔断回退",
            "daemon_failure": "daemon 失败",
            "history_recorded": "长期历史已记录",
            "history_write_failed": "长期历史写入失败",
            "cloud_request_started": "云请求已发出",
            "cloud_suggestion_shown": "云端建议已显示",
            "cloud_suggestion_accepted": "云端建议已采纳",
            "cloud_correction_shown": "云端纠错已显示",
            "cloud_correction_accepted": "云端纠错已采纳",
            "cloud_timeout": "云请求超时",
            "cloud_invalid_result": "云端无效结果已拦截",
            "cloud_transport_failure": "Qwen 连接失败",
            "voice_started": "语音录音已开始",
            "voice_stopped": "语音录音已结束",
            "voice_preview_shown": "语音临时文本已显示",
            "voice_final_shown": "语音最终文本已显示",
            "voice_accepted": "语音文本已确认",
            "voice_cancelled": "语音会话已取消",
            "voice_microphone_denied": "麦克风权限被拒绝",
            "voice_failure": "语音会话失败",
            "voice_disabled": "语音已熔断",
        ]
        return diagnostics.keys.sorted().map { key in
            let name = names[key] ?? key
            return "\(name)：\(diagnostics[key, default: 0])"
        }.joined(separator: " · ")
    }

    private func dataSizeDescription() -> String {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let managedBytes = layout.managedDataURLs.reduce(0) {
            $0 + dataSize(at: $1)
        }
        let rimeBytes = dataSize(at: layout.rimeUserDataDirectory)
        return "AI 服务与模型：\(formatted(bytes: managedBytes)) · "
            + "Rime 用户数据（清除时保留）：\(formatted(bytes: rimeBytes))"
    }

    private func dataSize(at root: URL) -> Int64 {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
        ]
        guard FileManager.default.fileExists(atPath: root.path) else {
            return 0
        }
        if let values = try? root.resourceValues(forKeys: resourceKeys),
           values.isRegularFile == true
        {
            return Int64(values.fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(
                    forKeys: resourceKeys
                ),
                values.isRegularFile == true
            else {
                continue
            }
            bytes += Int64(values.fileSize ?? 0)
        }
        return bytes
    }

    private func formatted(bytes: Int64) -> String {
        return ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }

    nonisolated private static func stopManagedDaemon(
        layout: RimeAIProductDataLayout
    ) throws {
        _ = try runProcess(
            executable: "/bin/launchctl",
            arguments: [
            "bootout",
            "gui/\(getuid())/fun.wwcn.rimeai.daemon",
            ]
        )
        try stopAdHocDaemon(layout: layout)
    }

    nonisolated private static func stopManagedCloudBroker(
        layout: RimeAIProductDataLayout
    ) throws {
        _ = try runProcess(
            executable: "/bin/launchctl",
            arguments: [
                "bootout",
                "gui/\(getuid())/fun.wwcn.rimeai.cloud-broker",
            ]
        )
        if FileManager.default.fileExists(
            atPath: layout.cloudBrokerEnabledMarker.path
        ) {
            try FileManager.default.removeItem(
                at: layout.cloudBrokerEnabledMarker
            )
        }
    }

    nonisolated private static func suspendManagedCloudBroker(
        layout: RimeAIProductDataLayout
    ) throws {
        if FileManager.default.fileExists(
            atPath: layout.cloudBrokerEnabledMarker.path
        ) {
            try FileManager.default.removeItem(
                at: layout.cloudBrokerEnabledMarker
            )
        }
        _ = try runProcess(
            executable: "/bin/launchctl",
            arguments: [
                "kill",
                "SIGTERM",
                "gui/\(getuid())/fun.wwcn.rimeai.cloud-broker",
            ]
        )
    }

    nonisolated private static func startManagedCloudBroker(
        layout: RimeAIProductDataLayout
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(
            atPath: layout.cloudBrokerLaunchAgentPlist.path
        ) else {
            throw lifecycleError(
                "cloud broker LaunchAgent is missing; reinstall RimeAI",
                code: 20
            )
        }
        try fileManager.createDirectory(
            at: layout.controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard fileManager.createFile(
            atPath: layout.cloudBrokerEnabledMarker.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw lifecycleError(
                "could not create the cloud broker enable marker",
                code: 21
            )
        }
        do {
            let domain = "gui/\(getuid())"
            let label = "fun.wwcn.rimeai.cloud-broker"
            let printStatus = try runProcess(
                executable: "/bin/launchctl",
                arguments: ["print", "\(domain)/\(label)"]
            )
            if printStatus != 0 {
                let bootstrapStatus = try runProcess(
                    executable: "/bin/launchctl",
                    arguments: [
                        "bootstrap",
                        domain,
                        layout.cloudBrokerLaunchAgentPlist.path,
                    ]
                )
                guard bootstrapStatus == 0 else {
                    throw lifecycleError(
                        "launchctl could not bootstrap the cloud broker",
                        code: Int(bootstrapStatus)
                    )
                }
            }
            let kickstartStatus = try runProcess(
                executable: "/bin/launchctl",
                arguments: ["kickstart", "\(domain)/\(label)"]
            )
            guard kickstartStatus == 0 else {
                throw lifecycleError(
                    "launchctl could not start the cloud broker",
                    code: Int(kickstartStatus)
                )
            }
            let socket = layout.runtimeDirectory
                .appendingPathComponent("rimeai-cloud.sock")
            for _ in 0..<40 {
                if SettingsRuntimeSocketNode.exists(
                    at: socket,
                    fileManager: fileManager
                ) {
                    // A socket node is only a launch milestone. Authenticated
                    // protocol readiness continues asynchronously in the client.
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw lifecycleError(
                "cloud broker did not create its private socket",
                code: 22
            )
        } catch {
            _ = try? runProcess(
                executable: "/bin/launchctl",
                arguments: [
                    "kill",
                    "SIGTERM",
                    "gui/\(getuid())/fun.wwcn.rimeai.cloud-broker",
                ]
            )
            if fileManager.fileExists(
                atPath: layout.cloudBrokerEnabledMarker.path
            ) {
                try? fileManager.removeItem(
                    at: layout.cloudBrokerEnabledMarker
                )
            }
            throw error
        }
    }

    nonisolated private static func suspendManagedDaemon(
        layout: RimeAIProductDataLayout
    ) throws {
        try SettingsDaemonDeactivationPolicy.run([
            (.removeMarker, {
                if FileManager.default.fileExists(
                    atPath: layout.daemonEnabledMarker.path
                ) {
                    try FileManager.default.removeItem(
                        at: layout.daemonEnabledMarker
                    )
                }
            }),
            (.stopLaunchAgent, {
                let status = try runProcess(
                    executable: "/bin/launchctl",
                    arguments: [
                        "kill",
                        "SIGTERM",
                        "gui/\(getuid())/fun.wwcn.rimeai.daemon",
                    ]
                )
                try SettingsDaemonDeactivationPolicy
                    .requireSuccessfulLaunchctlKill(status)
            }),
            (.stopAdHocProcess, {
                try stopAdHocDaemon(layout: layout)
            }),
        ])
    }

    nonisolated private static func startManagedDaemon(
        layout: RimeAIProductDataLayout
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(
            atPath: layout.launchAgentPlist.path
        ) else {
            throw NSError(
                domain: "fun.wwcn.inputmethod.RimeAI.daemon-lifecycle",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "LaunchAgent is missing; reinstall RimeAI",
                ]
            )
        }
        try fileManager.createDirectory(
            at: layout.controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try SettingsLifecycleMarkerTransaction.run(
            createMarker: {
                guard fileManager.createFile(
                    atPath: layout.daemonEnabledMarker.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw lifecycleError(
                        "could not create the local AI enable marker",
                        code: 4
                    )
                }
            },
            rollbackMarker: {
                try suspendManagedDaemon(layout: layout)
            },
            operation: {
                let domain = "gui/\(getuid())"
                let printStatus = try runProcess(
                    executable: "/bin/launchctl",
                    arguments: [
                        "print",
                        "\(domain)/fun.wwcn.rimeai.daemon",
                    ]
                )
                if printStatus != 0 {
                    let bootstrapStatus = try runProcess(
                        executable: "/bin/launchctl",
                        arguments: [
                            "bootstrap",
                            domain,
                            layout.launchAgentPlist.path,
                        ]
                    )
                    guard bootstrapStatus == 0 else {
                        throw lifecycleError(
                            "launchctl could not bootstrap the daemon",
                            code: Int(bootstrapStatus)
                        )
                    }
                }
                let kickstartStatus = try runProcess(
                    executable: "/bin/launchctl",
                    arguments: [
                        "kickstart",
                        "\(domain)/fun.wwcn.rimeai.daemon",
                    ]
                )
                guard kickstartStatus == 0 else {
                    throw lifecycleError(
                        "launchctl could not start the daemon",
                        code: Int(kickstartStatus)
                    )
                }
                let socket = layout.runtimeDirectory
                    .appendingPathComponent("rimeai.sock")
                for _ in 0..<80 {
                    if SettingsRuntimeSocketNode.exists(
                        at: socket,
                        fileManager: fileManager
                    ) {
                        // This deliberately does not claim daemon hello/ready;
                        // a typed generation-bound probe remains future work.
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                throw lifecycleError(
                    "daemon did not create its private socket",
                    code: 3
                )
            }
        )
    }

    nonisolated private static func stopAdHocDaemon(
        layout: RimeAIProductDataLayout
    ) throws {

        let pidPath = layout.runtimeDirectory
            .appendingPathComponent("rimeai-daemon.pid")
        guard
            let rawPID = try? String(contentsOf: pidPath, encoding: .utf8),
            let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 1,
            kill(pid, 0) == 0
        else {
            return
        }
        let ps = Process()
        let output = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", "\(pid)", "-o", "command="]
        ps.standardOutput = output
        ps.standardError = Pipe()
        try ps.run()
        ps.waitUntilExit()
        let command = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let socketPath = layout.runtimeDirectory
            .appendingPathComponent("rimeai.sock")
            .path
        guard command.contains("rimeai_daemon"),
              command.contains(socketPath)
        else {
            throw NSError(
                domain: "fun.wwcn.inputmethod.RimeAI.data-lifecycle",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "refused to stop an unrelated process",
                ]
            )
        }
        if kill(pid, SIGTERM) != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
    }

    nonisolated private static func runProcess(
        executable: String,
        arguments: [String]
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    nonisolated private static func lifecycleError(
        _ description: String,
        code: Int
    ) -> NSError {
        NSError(
            domain: "fun.wwcn.inputmethod.RimeAI.daemon-lifecycle",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    nonisolated private static func trashManagedData(
        layout: RimeAIProductDataLayout
    ) throws {
        let fileManager = FileManager.default
        for url in layout.managedDataURLs where
            fileManager.fileExists(atPath: url.path)
        {
            try fileManager.trashItem(
                at: url,
                resultingItemURL: nil
            )
        }
    }

    private func splitApplications(_ value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private func reconcileCloudConfiguration() {
        settings.reconcileCloudConfiguration(
            hasCredential: try? credentialStore.containsAPIKey()
        )
    }

    private func refreshVoiceShortcutStatus() {
        guard !voiceShortcutCaptureButton.isCapturing else {
            return
        }
        let configured = settings.voiceShortcut
        let message: String
        let color: NSColor
        switch VoiceHotKeyManager.shared.registrationStatus {
        case .inactive:
            if settings.aiEnabled, settings.voiceEnabled {
                message =
                    "已保存 \(configured.displayName)；"
                    + "仅在输入目标可用且未进入安全输入时注册"
            } else {
                message =
                    "已保存 \(configured.displayName)；语音启用后将自动注册"
            }
            color = .secondaryLabelColor
        case let .registered(shortcut):
            if shortcut == configured {
                message = "已注册 \(shortcut.displayName)"
                color = .systemGreen
            } else {
                message =
                    "正在从 \(shortcut.displayName) 切换到 "
                    + configured.displayName
                color = .systemOrange
            }
        case let .failed(shortcut, kind, code, registrationMessage):
            let failureKind = kind == .conflict ? "快捷键冲突" : "系统注册失败"
            message =
                "\(failureKind)：\(registrationMessage)"
                + "（\(shortcut.displayName)，OSStatus \(code)）"
            color = .systemRed
            if shortcut == configured {
                updateSettingsActionStatus(
                    .failure,
                    "\(configured.displayName) 已保存，但当前无法注册；请更换快捷键"
                )
            }
        }
        guard voiceShortcutStatusLabel.stringValue != message
                || voiceShortcutStatusLabel.textColor != color
        else {
            return
        }
        voiceShortcutStatusLabel.stringValue = message
        voiceShortcutStatusLabel.textColor = color
        voiceShortcutStatusLabel.setAccessibilityValue(message)
        NSAccessibility.post(
            element: voiceShortcutStatusLabel,
            notification: .valueChanged
        )
    }

    private func refreshSettingsActionStatus() {
        let status = SettingsActionStatusCenter.shared.current
        guard settingsActionStatusLabel.stringValue != status.message
                || settingsActionStatusLabel.textColor
                    != settingsActionStatusColor(for: status.kind)
        else {
            return
        }
        settingsActionStatusLabel.stringValue = status.message
        settingsActionStatusLabel.textColor = settingsActionStatusColor(
            for: status.kind
        )
        NSAccessibility.post(
            element: settingsActionStatusLabel,
            notification: .valueChanged
        )
    }

    private func settingsActionStatusColor(
        for kind: SettingsActionStatus.Kind
    ) -> NSColor {
        switch kind {
        case .ready:
            return .secondaryLabelColor
        case .working:
            return .controlAccentColor
        case .success:
            return .systemGreen
        case .failure:
            return .systemRed
        }
    }

    private func updateSettingsActionStatus(
        _ kind: SettingsActionStatus.Kind,
        _ message: String
    ) {
        SettingsActionStatusCenter.shared.update(SettingsActionStatus(
            kind: kind,
            message: message
        ))
    }

    private func presentError(
        _ error: Error,
        message: String,
        information: String
    ) {
        updateSettingsActionStatus(
            .failure,
            "\(message)：\(error.localizedDescription)"
        )
        let alert = NSAlert(error: error)
        alert.messageText = message
        alert.informativeText = information
        alert.beginSheetModal(for: window)
    }

    private func sectionTitle(_ value: String) -> NSTextField {
        label(value, font: .systemFont(ofSize: 15, weight: .semibold))
    }

    private func label(
        _ value: String,
        font: NSFont = .systemFont(ofSize: 13),
        secondary: Bool = false
    ) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = font
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        configureWrapping(field)
        return field
    }

    private func configureWrapping(_ field: NSTextField) {
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
    }

    private func addSettingsTab(
        to tabView: NSTabView,
        title: String
    ) -> NSStackView {
        let item = NSTabViewItem(identifier: title)
        item.label = title

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.setAccessibilityLabel("\(title)设置")

        let documentView = SettingsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        documentView.widthAnchor.constraint(
            equalTo: scrollView.contentView.widthAnchor
        ).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: documentView.leadingAnchor,
                constant: 20
            ),
            stack.trailingAnchor.constraint(
                equalTo: documentView.trailingAnchor,
                constant: -20
            ),
            stack.topAnchor.constraint(
                equalTo: documentView.topAnchor,
                constant: 20
            ),
            stack.bottomAnchor.constraint(
                equalTo: documentView.bottomAnchor,
                constant: -24
            ),
        ])

        item.view = scrollView
        tabView.addTabViewItem(item)
        return stack
    }

    private func addSeparator(to stack: NSStackView) {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

extension PrivacyCenterWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        voiceShortcutCaptureButton.cancelCapture()
        voiceShortcutCancelButton.isEnabled = false
    }
}
