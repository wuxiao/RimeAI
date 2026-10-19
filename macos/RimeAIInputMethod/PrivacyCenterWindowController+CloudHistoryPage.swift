import AppKit

/// 机械拆分自 PrivacyCenterWindowController.swift（纯代码搬移，行为不变）。
extension PrivacyCenterWindowController {
    func buildCloudHistoryPage(_ cloudStack: NSStackView) {
        buildCloudModelSection(cloudStack)
        buildPlainHistorySection(cloudStack)
    }

    private func buildCloudModelSection(_ cloudStack: NSStackView) {
        cloudStack.addArrangedSubview(sectionTitle("云端模型增强"))
        cloudStack.addArrangedSubview(
            label(
                "保存 API Key 即启用：RimeAI 会跨应用、以明文在本机长期保存"
                    + "每次上屏文本、拼音、应用标识和时间；输入时把当前拼音"
                    + "和光标前最近文本（最多 120 字）发送到云端模型生成整句"
                    + "候选，不发送本地候选列表（服务商与端点见下方状态）。"
                    + "空闲固化时，还会把滚动窗口（7 天）外的上屏原文按域分批"
                    + "（每域每轮最多约 24KB）发送到云端生成风格画像；"
                    + "「语言画像」页可关闭云压缩，关闭后只做本地统计。"
                    + "只有 macOS Secure Event Input 会自动阻止记录与上传；"
                    + "「输入与 AI」中的应用策略仅限制本地功能，不限制云端"
                    + "记录与上传。",
                secondary: true
            )
        )
        cloudStack.addArrangedSubview(
            label(
                "开启「上屏后续写联想」后，每次上屏还会把最近上下文"
                    + "（含光标前的既有文本）发送到云端以生成续写建议；"
                    + "该功能默认关闭。",
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
        cloudStack.addArrangedSubview(
            label(
                "API Key 以明文保存在 ~/.config/rimeai/cloud.env（目录 0700、"
                    + "文件 0600），不是 Keychain；同账户的其他进程、备份或"
                    + "同步工具可能读取。",
                secondary: true
            )
        )
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
    }

    private func buildPlainHistorySection(_ cloudStack: NSStackView) {
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

    }
}
