import AppKit

/// 机械拆分自 PrivacyCenterWindowController.swift（纯代码搬移，行为不变）。
extension PrivacyCenterWindowController {
    func buildStatusDataPage(_ statusStack: NSStackView) {

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
}
