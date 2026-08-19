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
    private let disabledAIField = NSTextField()
    private let disabledContextField = NSTextField()
    private let daemonStatusLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let artifactLabel = NSTextField(labelWithString: "")
    private let diagnosticsLabel = NSTextField(labelWithString: "")
    private let dataSizeLabel = NSTextField(labelWithString: "")
    private var daemonObserver: NSObjectProtocol?
    private var cloudObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var diagnosticsObserver: NSObjectProtocol?

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
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

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let documentView = NSView()
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
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                equalTo: documentView.trailingAnchor,
                constant: -24
            ),
            stack.topAnchor.constraint(
                equalTo: documentView.topAnchor,
                constant: 22
            ),
            stack.bottomAnchor.constraint(
                equalTo: documentView.bottomAnchor,
                constant: -22
            ),
        ])

        let title = label(
            "RimeAI 设置",
            font: .systemFont(ofSize: 22, weight: .semibold)
        )
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(sectionTitle("常规输入"))
        stack.addArrangedSubview(
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
        characterSetRow.addArrangedSubview(characterSetPopup)
        stack.addArrangedSubview(characterSetRow)

        let characterWidthRow = NSStackView()
        characterWidthRow.orientation = .horizontal
        characterWidthRow.spacing = 10
        characterWidthRow.addArrangedSubview(label("字符宽度"))
        characterWidthPopup.addItems(withTitles: ["半角", "全角"])
        characterWidthPopup.target = self
        characterWidthPopup.action = #selector(characterWidthChanged(_:))
        characterWidthRow.addArrangedSubview(characterWidthPopup)
        stack.addArrangedSubview(characterWidthRow)

        let punctuationRow = NSStackView()
        punctuationRow.orientation = .horizontal
        punctuationRow.spacing = 10
        punctuationRow.addArrangedSubview(label("标点样式"))
        punctuationPopup.addItems(withTitles: ["中文（，。）", "西文（,.）"])
        punctuationPopup.target = self
        punctuationPopup.action = #selector(punctuationChanged(_:))
        punctuationRow.addArrangedSubview(punctuationPopup)
        stack.addArrangedSubview(punctuationRow)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("AI 与隐私"))
        stack.addArrangedSubview(
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
        stack.addArrangedSubview(aiToggle)

        offlineToggle.title =
            "本地 daemon 网络隔离（始终开启：禁止 IPv4 / IPv6 socket）"
        offlineToggle.isEnabled = false
        stack.addArrangedSubview(offlineToggle)

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
        contextRow.addArrangedSubview(contextPopup)
        stack.addArrangedSubview(contextRow)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("云端模型增强与长期记忆"))
        stack.addArrangedSubview(
            label(
                "保存 API Key 即启用：RimeAI 会跨应用、以明文长期保存每次"
                    + "上屏文本、拼音、应用标识和时间，并把最近文本、检索片段、"
                    + "当前拼音及候选发送到阿里云。只有 macOS Secure Event Input "
                    + "会自动阻止记录与上传；本地下方的应用策略不限制云端历史。",
                secondary: true
            )
        )
        configureWrapping(cloudStatusLabel)
        stack.addArrangedSubview(cloudStatusLabel)

        let modelRow = NSStackView()
        modelRow.orientation = .horizontal
        modelRow.spacing = 10
        modelRow.addArrangedSubview(label("排序模型"))
        cloudModelPopup.addItems(
            withTitles: RimeAICloudConfiguration.rankingModelIDs
        )
        cloudModelPopup.target = self
        cloudModelPopup.action = #selector(cloudModelChanged(_:))
        modelRow.addArrangedSubview(cloudModelPopup)
        stack.addArrangedSubview(modelRow)

        apiKeyField.placeholderString = "GLM 云端 API Key（保存至 ~/.config/rimeai/cloud.env）"
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(apiKeyField)
        apiKeyField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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
        stack.addArrangedSubview(cloudButtons)

        configureWrapping(historyStatusLabel)
        stack.addArrangedSubview(historyStatusLabel)
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
        stack.addArrangedSubview(historyButtons)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("应用级策略"))
        stack.addArrangedSubview(
            label(
                "仅禁用本地 AI 的 Bundle ID（逗号分隔，精确匹配）",
                secondary: true
            )
        )
        disabledAIField.placeholderString =
            "例如：com.example.PasswordManager"
        disabledAIField.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(disabledAIField)
        disabledAIField.widthAnchor.constraint(
            equalTo: stack.widthAnchor
        ).isActive = true
        stack.addArrangedSubview(
            label(
                "仅禁用本地上下文的 Bundle ID（本地 AI 退化为严格模式）",
                secondary: true
            )
        )
        disabledContextField.placeholderString = "例如：com.example.Terminal"
        disabledContextField.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(disabledContextField)
        disabledContextField.widthAnchor.constraint(
            equalTo: stack.widthAnchor
        ).isActive = true
        let savePolicies = NSButton(
            title: "保存应用策略",
            target: self,
            action: #selector(saveApplicationPolicies(_:))
        )
        stack.addArrangedSubview(savePolicies)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("本地模型与运行状态"))
        for statusLabel in [
            daemonStatusLabel,
            modelLabel,
            artifactLabel,
            dataSizeLabel,
        ] {
            configureWrapping(statusLabel)
            stack.addArrangedSubview(statusLabel)
        }

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("无原文诊断"))
        configureWrapping(diagnosticsLabel)
        stack.addArrangedSubview(diagnosticsLabel)
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
        dataButtons.addArrangedSubview(
            NSButton(
                title: "导出设置…",
                target: self,
                action: #selector(exportSettings(_:))
            )
        )
        dataButtons.addArrangedSubview(
            NSButton(
                title: "停用 AI 并清除本地制品…",
                target: self,
                action: #selector(clearAllProductData(_:))
            )
        )
        stack.addArrangedSubview(dataButtons)
        stack.addArrangedSubview(
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
        offlineToggle.state = settings.offlineLockEnabled ? .on : .off
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
        if sender === aiToggle {
            settings.aiEnabled = sender.state == .on
            if sender.state == .off {
                settings.clearEphemeralData()
                DaemonClient.shared.disconnect()
            }
            setManagedDaemonEnabled(sender.state == .on)
        }
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
        do {
            try credentialStore.saveAPIKey(apiKeyField.stringValue)
            settings.cloudModelID = cloudModelPopup.selectedItem?.title
                ?? RimeAICloudConfiguration.defaultRankingModelID
            settings.cloudConfigured = true
            apiKeyField.stringValue = ""
            setManagedCloudBrokerEnabled(true)
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
            // Disable first so no new cloud request or history write can race
            // with credential removal.
            self.settings.cloudConfigured = false
            CloudBrokerClient.shared.disconnect()
            self.setManagedCloudBrokerEnabled(false)
            do {
                try self.credentialStore.deleteAPIKey()
                self.apiKeyField.stringValue = ""
                self.refresh()
            } catch {
                self.presentError(
                    error,
                    message: "未能移除 API Key",
                    information: "云增强已停用，但凭据文件可能仍然存在。"
                )
            }
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
    }

    @objc private func exportSettings(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RimeAI-settings.json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [settings] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys,
                .withoutEscapingSlashes,
            ]
            guard let data = try? encoder.encode(settings.exportSnapshot())
            else {
                return
            }
            try? data.write(to: url, options: .atomic)
        }
    }

    @objc private func clearAllProductData(_ sender: Any?) {
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
            guard response == .alertFirstButtonReturn else {
                return
            }
            self?.disableAIAndTrashManagedData()
        }
    }

    private func disableAIAndTrashManagedData() {
        DaemonClient.shared.disconnect()
        CloudBrokerClient.shared.disconnect()
        settings.cloudConfigured = false
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
                try Self.stopManagedDaemon(layout: layout)
                try Self.stopManagedCloudBroker(layout: layout)
                try Self.trashManagedData(layout: layout)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.settings.resetAllProductData()
                    self.settings.aiEnabled = false
                    self.daemonStatusLabel.stringValue =
                        "Daemon：已停用 · Internet socket：不存在"
                    self.modelLabel.stringValue = "模型制品：已移到废纸篓"
                    self.artifactLabel.stringValue =
                        "重新安装开发者预览版后可恢复本地 AI。"
                    self.refresh()
                case let .failure(error):
                    let failure = NSAlert(error: error)
                    failure.messageText = "未能完整清除 RimeAI 本地制品"
                    failure.informativeText =
                        "部分项目可能已经移到废纸篓；Rime 用户词典未被修改。"
                    failure.beginSheetModal(for: self.window)
                }
            }
        }
    }

    private func setManagedDaemonEnabled(_ enabled: Bool) {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        daemonStatusLabel.stringValue =
            enabled ? "Daemon：正在启动" : "Daemon：正在停止"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                if enabled {
                    try Self.startManagedDaemon(layout: layout)
                } else {
                    try Self.suspendManagedDaemon(layout: layout)
                }
            }
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                switch result {
                case .success:
                    if enabled {
                        DaemonClient.shared.connect()
                    } else {
                        self.daemonStatusLabel.stringValue =
                            "Daemon：已停用 · 模型资源已释放"
                    }
                case let .failure(error):
                    if enabled {
                        self.settings.aiEnabled = false
                    }
                    self.daemonStatusLabel.stringValue =
                        "Daemon：生命周期操作失败"
                    let failure = NSAlert(error: error)
                    failure.messageText = enabled
                        ? "未能启动 RimeAI daemon"
                        : "未能完整停止 RimeAI daemon"
                    failure.beginSheetModal(for: self.window)
                }
            }
        }
    }

    private func setManagedCloudBrokerEnabled(_ enabled: Bool) {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        cloudStatusLabel.stringValue = enabled
            ? "云增强：正在启动"
            : "云增强：正在停止"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                if enabled {
                    try Self.startManagedCloudBroker(layout: layout)
                } else {
                    try Self.suspendManagedCloudBroker(layout: layout)
                }
            }
            DispatchQueue.main.async {
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
                case let .failure(error):
                    self.presentError(
                        error,
                        message: enabled
                            ? "未能启动云端 broker"
                            : "未能完整停止云端 broker",
                        information: enabled
                            ? "API Key 与长期历史仍已保存；请重新安装服务组件后重试。"
                            : "云增强已在设置中停用，重新登录后 broker 不会再次启动。"
                    )
                }
            }
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
                let attributes = try? fileManager.attributesOfItem(
                    atPath: socket.path
                )
                if attributes?[.type] as? FileAttributeType == .typeSocket {
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
        if FileManager.default.fileExists(
            atPath: layout.daemonEnabledMarker.path
        ) {
            try FileManager.default.removeItem(
                at: layout.daemonEnabledMarker
            )
        }
        _ = try runProcess(
            executable: "/bin/launchctl",
            arguments: [
                "kill",
                "SIGTERM",
                "gui/\(getuid())/fun.wwcn.rimeai.daemon",
            ]
        )
        try stopAdHocDaemon(layout: layout)
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
            if fileManager.fileExists(atPath: socket.path) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw lifecycleError(
            "daemon did not create its private socket",
            code: 3
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

    private func presentError(
        _ error: Error,
        message: String,
        information: String
    ) {
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

    private func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 600).isActive = true
        return separator
    }
}
