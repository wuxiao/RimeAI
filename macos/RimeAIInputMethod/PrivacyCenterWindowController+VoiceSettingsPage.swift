import AppKit

/// 机械拆分自 PrivacyCenterWindowController.swift（纯代码搬移，行为不变）。
extension PrivacyCenterWindowController {
    func buildVoiceSettingsPage(_ voiceStack: NSStackView) {
        buildVoiceShortcutSection(voiceStack)
        buildVoiceControlSection(voiceStack)
    }

    private func buildVoiceShortcutSection(_ voiceStack: NSStackView) {
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
    }

    private func buildVoiceControlSection(_ voiceStack: NSStackView) {
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
    }
}
