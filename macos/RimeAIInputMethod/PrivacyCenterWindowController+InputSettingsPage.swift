import AppKit

/// 机械拆分自 PrivacyCenterWindowController.swift（纯代码搬移，行为不变）。
extension PrivacyCenterWindowController {
    func buildInputSettingsPage(_ inputStack: NSStackView) {
        buildGeneralInputSection(inputStack)
        buildAIPrivacySection(inputStack)
        buildAppPolicySection(inputStack)
    }

    private func buildGeneralInputSection(_ inputStack: NSStackView) {
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
    }

    private func buildAIPrivacySection(_ inputStack: NSStackView) {
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
    }

    private func buildAppPolicySection(_ inputStack: NSStackView) {
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
    }
}
