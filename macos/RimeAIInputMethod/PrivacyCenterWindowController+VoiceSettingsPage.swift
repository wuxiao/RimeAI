import AppKit

/// 语音设置页：按“听写与快捷键 / 润色上屏与音频 / 热词与自动纠错 / 服务状态”
/// 四张卡片分组。所有“标签 | 控件”行共用固定宽度标签列，弹窗宽度统一，
/// 相邻控件不再参差或跳动。
extension PrivacyCenterWindowController {
    func buildVoiceSettingsPage(_ voiceStack: NSStackView) {
        buildVoiceDictationCard(voiceStack)
        buildVoiceOutputAndAudioCard(voiceStack)
        buildVoiceHotwordAndCorrectionCard(voiceStack)
        buildVoiceServiceStatusCard(voiceStack)
    }

    /// 统一配置可换行的语音复选框，并让它横向填满卡片。
    private func addVoiceCheckbox(
        _ button: NSButton,
        title: String,
        identifier: String,
        to content: NSStackView
    ) {
        button.title = title
        button.target = self
        button.action = #selector(toggleChanged(_:))
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.lineBreakMode = .byWordWrapping
        button.usesSingleLineMode = false
        (button.cell as? NSButtonCell)?.wraps = true
        button.setAccessibilityLabel(title)
        addFilling(button, to: content)
    }

    private func addNote(_ text: String, to content: NSStackView) {
        let note = label(text, secondary: true)
        note.font = .systemFont(ofSize: 12)
        addFilling(note, to: content)
    }

    // MARK: 听写与快捷键

    private func buildVoiceDictationCard(_ voiceStack: NSStackView) {
        let card = settingsCard("语音听写与快捷键")
        addCard(card, to: voiceStack)
        let content = card.content

        configureWrapping(voiceDisabledBannerLabel)
        voiceDisabledBannerLabel.stringValue = VoicePrivacyCopy.voiceDisabledBanner
        voiceDisabledBannerLabel.textColor = .systemOrange
        voiceDisabledBannerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        voiceDisabledBannerLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-disabled-banner"
        )
        voiceDisabledBannerLabel.setAccessibilityLabel(VoicePrivacyCopy.voiceDisabledBanner)
        voiceDisabledBannerLabel.isHidden = true
        addFilling(voiceDisabledBannerLabel, to: content)

        addVoiceCheckbox(
            voiceToggle,
            title: "启用语音输入",
            identifier: "settings.voice-enabled",
            to: content
        )

        configureWrapping(voiceInstructionLabel)
        voiceInstructionLabel.textColor = .secondaryLabelColor
        addFilling(voiceInstructionLabel, to: content)

        buildVoiceShortcutRow(into: content)
        buildVoiceSecondaryShortcutRow(into: content)
        buildVoiceTranslationRows(into: content)
    }

    private func buildVoiceShortcutRow(into content: NSStackView) {
        voiceShortcutCaptureButton.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-shortcut.capture"
        )
        voiceShortcutCaptureButton.onCaptureStateChanged = { [weak self]
            isCapturing in
            guard let self else {
                return
            }
            if isCapturing {
                self.voiceSecondaryShortcutCaptureButton.cancelCapture()
                self.voiceTranslateShortcutCaptureButton.cancelCapture()
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
        voiceShortcutCancelButton.target = self
        voiceShortcutCancelButton.action = #selector(cancelVoiceShortcutEdit(_:))
        voiceShortcutCancelButton.isEnabled = false
        let useRightCommandButton = NSButton(
            title: "设为右 ⌘",
            target: self,
            action: #selector(useRightCommandVoiceShortcut(_:))
        )
        useRightCommandButton.setAccessibilityHelp(
            "设为右侧 Command 键：按一下开始录音，再按一下结束。"
        )
        let restoreVoiceShortcutButton = NSButton(
            title: "恢复默认",
            target: self,
            action: #selector(restoreDefaultVoiceShortcut(_:))
        )
        restoreVoiceShortcutButton.setAccessibilityHelp(
            "恢复默认语音快捷键 "
                + VoiceDictationShortcut.default.displayName + "。"
        )
        content.addArrangedSubview(labeledRow("语音听写快捷键", [
            voiceShortcutCaptureButton,
            voiceShortcutCancelButton,
            useRightCommandButton,
            restoreVoiceShortcutButton,
        ]))
        configureWrapping(voiceShortcutStatusLabel)
        voiceShortcutStatusLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-shortcut.status"
        )
        voiceShortcutStatusLabel.setAccessibilityLabel("语音快捷键状态")
        addFilling(voiceShortcutStatusLabel, to: content)
    }

    private func buildVoiceSecondaryShortcutRow(into content: NSStackView) {
        voiceSecondaryShortcutCaptureButton.identifier =
            NSUserInterfaceItemIdentifier(
                "settings.voice-secondary-shortcut.capture"
            )
        voiceSecondaryShortcutCaptureButton.setAccessibilityLabel(
            "编辑备用语音听写快捷键"
        )
        voiceSecondaryShortcutCaptureButton.onCaptureStateChanged = { [weak self]
            isCapturing in
            guard let self else {
                return
            }
            if isCapturing {
                self.voiceShortcutCaptureButton.cancelCapture()
                self.voiceTranslateShortcutCaptureButton.cancelCapture()
            }
            self.voiceSecondaryShortcutCancelButton.isEnabled = isCapturing
            if isCapturing {
                self.voiceSecondaryShortcutStatusLabel.stringValue =
                    "正在等待备用快捷键组合；"
                    + VoiceDictationShortcut.validationFailureDescription
                self.voiceSecondaryShortcutStatusLabel.textColor =
                    .controlAccentColor
            }
        }
        voiceSecondaryShortcutCaptureButton.onKeyEvent = { [weak self]
            keyCode,
            modifierFlags in
            self?.captureVoiceSecondaryShortcut(
                keyCode: keyCode,
                modifierFlags: modifierFlags
            )
        }
        voiceSecondaryShortcutCaptureButton.onCancel = { [weak self] in
            self?.refreshVoiceSecondaryShortcutStatus()
        }
        voiceSecondaryShortcutCancelButton.target = self
        voiceSecondaryShortcutCancelButton.action = #selector(
            cancelVoiceSecondaryShortcutEdit(_:)
        )
        voiceSecondaryShortcutCancelButton.isEnabled = false

        voiceSecondaryShortcutPresetButton.target = self
        voiceSecondaryShortcutPresetButton.action = #selector(
            usePresetSecondaryVoiceShortcut(_:)
        )
        voiceSecondaryShortcutPresetButton.identifier =
            NSUserInterfaceItemIdentifier(
                "settings.voice-secondary-shortcut.preset"
            )
        voiceSecondaryShortcutPresetButton.setAccessibilityHelp(
            "一键将另一常用修饰键设为备用听写快捷键（例如外接键盘用右 ⌘、内置键盘用 Fn）。"
        )

        voiceSecondaryShortcutClearButton.target = self
        voiceSecondaryShortcutClearButton.action = #selector(
            clearSecondaryVoiceShortcut(_:)
        )
        voiceSecondaryShortcutClearButton.identifier =
            NSUserInterfaceItemIdentifier(
                "settings.voice-secondary-shortcut.clear"
            )
        voiceSecondaryShortcutClearButton.setAccessibilityHelp(
            "清除备用语音听写快捷键，仅保留主快捷键。"
        )

        content.addArrangedSubview(labeledRow("备用听写快捷键", [
            voiceSecondaryShortcutCaptureButton,
            voiceSecondaryShortcutCancelButton,
            voiceSecondaryShortcutPresetButton,
            voiceSecondaryShortcutClearButton,
        ]))
        configureWrapping(voiceSecondaryShortcutStatusLabel)
        voiceSecondaryShortcutStatusLabel.identifier =
            NSUserInterfaceItemIdentifier(
                "settings.voice-secondary-shortcut.status"
            )
        voiceSecondaryShortcutStatusLabel.setAccessibilityLabel(
            "备用语音快捷键状态"
        )
        addFilling(voiceSecondaryShortcutStatusLabel, to: content)
    }

    private func buildVoiceTranslationRows(into content: NSStackView) {
        addNote(
            "按下翻译快捷键直接启动语音翻译：松开后自动识别并翻译为目标语言，"
                + "配合自动粘贴实现跨应用开口即译（需要启用云增强 API Key）。",
            to: content
        )
        voiceTranslateShortcutCaptureButton.identifier =
            NSUserInterfaceItemIdentifier(
                "settings.voice-translate-shortcut.capture"
            )
        voiceTranslateShortcutCaptureButton.setAccessibilityLabel(
            "编辑语音翻译快捷键"
        )
        voiceTranslateShortcutCaptureButton.onCaptureStateChanged = { [weak self]
            isCapturing in
            guard let self else {
                return
            }
            if isCapturing {
                self.voiceShortcutCaptureButton.cancelCapture()
                self.voiceSecondaryShortcutCaptureButton.cancelCapture()
            }
            self.voiceTranslateShortcutCancelButton.isEnabled = isCapturing
            if isCapturing {
                self.voiceTranslateShortcutStatusLabel.stringValue =
                    "正在等待翻译快捷键组合；"
                    + VoiceDictationShortcut.validationFailureDescription
                self.voiceTranslateShortcutStatusLabel.textColor =
                    .controlAccentColor
            }
        }
        voiceTranslateShortcutCaptureButton.onKeyEvent = { [weak self]
            keyCode,
            modifierFlags in
            self?.captureVoiceTranslateShortcut(
                keyCode: keyCode,
                modifierFlags: modifierFlags
            )
        }
        voiceTranslateShortcutCaptureButton.onCancel = { [weak self] in
            self?.refreshVoiceTranslateShortcutStatus()
        }
        voiceTranslateShortcutCancelButton.target = self
        voiceTranslateShortcutCancelButton.action = #selector(
            cancelVoiceTranslateShortcutEdit(_:)
        )
        voiceTranslateShortcutCancelButton.isEnabled = false
        let restoreTranslateButton = NSButton(
            title: "恢复默认",
            target: self,
            action: #selector(restoreDefaultVoiceTranslateShortcut(_:))
        )
        restoreTranslateButton.setAccessibilityHelp(
            "恢复默认语音翻译快捷键 "
                + VoiceDictationShortcut.defaultTranslate.displayName + "。"
        )
        content.addArrangedSubview(labeledRow("一键翻译快捷键", [
            voiceTranslateShortcutCaptureButton,
            voiceTranslateShortcutCancelButton,
            restoreTranslateButton,
        ]))
        configureWrapping(voiceTranslateShortcutStatusLabel)
        voiceTranslateShortcutStatusLabel.identifier =
            NSUserInterfaceItemIdentifier(
                "settings.voice-translate-shortcut.status"
            )
        voiceTranslateShortcutStatusLabel.setAccessibilityLabel(
            "语音翻译快捷键状态"
        )
        addFilling(voiceTranslateShortcutStatusLabel, to: content)

        voiceTranslateLanguagePopup.removeAllItems()
        voiceTranslateLanguagePopup.addItems(
            withTitles: VoiceTranslationLanguage.allCases.map(\.displayName)
        )
        voiceTranslateLanguagePopup.target = self
        voiceTranslateLanguagePopup.action = #selector(
            voiceTranslateLanguageChanged(_:)
        )
        voiceTranslateLanguagePopup.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-translate-language"
        )
        voiceTranslateLanguagePopup.setAccessibilityLabel("语音翻译目标语言")
        fixedWidthPopup(voiceTranslateLanguagePopup, width: SettingsLayout.popupWidth)
        content.addArrangedSubview(labeledRow("翻译目标语言", [
            voiceTranslateLanguagePopup,
        ]))
    }

    // MARK: 润色、上屏与音频

    private func buildVoiceOutputAndAudioCard(_ voiceStack: NSStackView) {
        let card = settingsCard(
            "润色、上屏与音频",
            subtitle: VoicePrivacyCopy.cloudPolishNote
        )
        addCard(card, to: voiceStack)
        let content = card.content

        addVoiceCheckbox(
            voiceSmartPolishToggle,
            title: "启用智能润色（自动去除“嗯、啊、那个”等口头语、消除重复并整理标点）",
            identifier: "settings.voice-smart-polish",
            to: content
        )

        voicePolishStylePopup.removeAllItems()
        voicePolishStylePopup.addItems(
            withTitles: VoicePolishStyle.allCases.map(\.displayName)
        )
        voicePolishStylePopup.target = self
        voicePolishStylePopup.action = #selector(voicePolishStyleChanged(_:))
        voicePolishStylePopup.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-polish-style"
        )
        voicePolishStylePopup.setAccessibilityLabel("语音润色风格")
        fixedWidthPopup(voicePolishStylePopup, width: SettingsLayout.popupWidth)
        content.addArrangedSubview(labeledRow("润色风格", [voicePolishStylePopup]))

        addVoiceCheckbox(
            voiceAutoPasteToggle,
            title: "听写/翻译完成后自动粘贴上屏（无需再按 Space / 回车确认）",
            identifier: "settings.voice-auto-paste",
            to: content
        )
        addVoiceCheckbox(
            voiceCloudHotwordsToggle,
            title: VoicePrivacyCopy.cloudHotwordsCheckbox,
            identifier: "settings.voice-cloud-hotwords",
            to: content
        )
        addNote(VoicePrivacyCopy.cloudHotwordsNote, to: content)
        addVoiceCheckbox(
            voiceHistoryToggle,
            title: VoicePrivacyCopy.historyCheckbox,
            identifier: "settings.voice-history-enabled",
            to: content
        )
        addVoiceCheckbox(
            voiceSoundEffectsToggle,
            title: "启用交互提示音（开始录音、停止、完成上屏、取消）",
            identifier: "settings.voice-sound-effects",
            to: content
        )
        addVoiceCheckbox(
            voiceMuteSystemAudioToggle,
            title: "语音输入时自动静音系统媒体音频（结束后自动恢复原静音与音量状态）",
            identifier: "settings.voice-mute-system-audio",
            to: content
        )
    }

    // MARK: 热词与自动纠错

    private func buildVoiceHotwordAndCorrectionCard(_ voiceStack: NSStackView) {
        let card = settingsCard(
            "热词与自动纠错",
            subtitle: "热词在本机用于引导识别与校正同音词；只有显式开启“发送到云端”后才会离开本机。"
        )
        addCard(card, to: voiceStack)
        let content = card.content

        addVoiceCheckbox(
            voiceRimeHotwordToggle,
            title: "使用当前会话已确认的 Rime 词条辅助语音（实验）",
            identifier: "settings.voice-rime-hotwords",
            to: content
        )
        addNote(
            "只使用当前焦点会话中你已通过 Rime 确认的词条；切换焦点、进入安全输入或关闭语音时立即清空。",
            to: content
        )
        addVoiceCheckbox(
            voicePhraseBookHotwordToggle,
            title: VoicePrivacyCopy.phraseBookHotwordsCheckbox,
            identifier: "settings.voice-phrasebook-hotwords",
            to: content
        )
        addVoiceCheckbox(
            voiceAutoLearnCorrectionsToggle,
            title: "上屏后手动修改错字时自动修正并收录进热词与词典（仅匹配同音/近音或英文拼写纠错）",
            identifier: "settings.voice-auto-learn-corrections",
            to: content
        )

        // “清空自动纠错映射”紧邻自动纠错开关，并需要确认，避免误点。
        voiceClearLearnedCorrectionsButton.target = self
        voiceClearLearnedCorrectionsButton.action = #selector(
            clearVoiceLearnedCorrections(_:)
        )
        voiceClearLearnedCorrectionsButton.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-learned-corrections.clear"
        )
        configureWrapping(voiceLearnedCorrectionsStatusLabel)
        voiceLearnedCorrectionsStatusLabel.textColor = .secondaryLabelColor
        voiceLearnedCorrectionsStatusLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-learned-corrections.status"
        )
        content.addArrangedSubview(labeledRow("自动纠错映射", [
            voiceClearLearnedCorrectionsButton,
            voiceLearnedCorrectionsStatusLabel,
        ]))

        addVoiceCheckbox(
            voiceAXFallbackReadToggle,
            title: VoicePrivacyCopy.axFallbackReadCheckbox,
            identifier: "settings.voice-ax-fallback-read",
            to: content
        )
        addNote(VoicePrivacyCopy.axFallbackReadNote, to: content)

        addNote(
            "每行一个常用语、专有名词或中英混合术语（也可用逗号分隔，最多 128 条）。"
                + "将在本地语音转文字时用于上下文偏置与同音词自动校正。",
            to: content
        )
        buildVoiceHotwordsEditor(into: content)
    }

    private func buildVoiceHotwordsEditor(into content: NSStackView) {
        voiceCustomHotwordsTextView.isEditable = true
        voiceCustomHotwordsTextView.isSelectable = true
        voiceCustomHotwordsTextView.isRichText = false
        voiceCustomHotwordsTextView.font = .monospacedSystemFont(
            ofSize: 12,
            weight: .regular
        )
        voiceCustomHotwordsTextView.isAutomaticQuoteSubstitutionEnabled = false
        voiceCustomHotwordsTextView.isAutomaticDashSubstitutionEnabled = false
        voiceCustomHotwordsTextView.isAutomaticSpellingCorrectionEnabled = false
        voiceCustomHotwordsTextView.textContainerInset = NSSize(
            width: 6,
            height: 6
        )
        // 任何编辑都会经 NSText.didChangeNotification 进入“未保存”状态：
        // 后台刷新绝不覆盖正在修改的内容（见 observeState）。
        voiceCustomHotwordsScrollView.documentView = voiceCustomHotwordsTextView
        voiceCustomHotwordsScrollView.hasVerticalScroller = true
        voiceCustomHotwordsScrollView.borderType = .bezelBorder
        voiceCustomHotwordsScrollView.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-custom-hotwords"
        )
        addFilling(voiceCustomHotwordsScrollView, to: content)
        let height = voiceCustomHotwordsScrollView.heightAnchor.constraint(
            equalToConstant: SettingsLayout.hotwordEditorHeight
        )
        height.isActive = true
        voiceCustomHotwordsHeightConstraint = height

        let hotwordActionRow = NSStackView()
        hotwordActionRow.orientation = .horizontal
        hotwordActionRow.alignment = .centerY
        hotwordActionRow.spacing = 8
        let saveHotwordsButton = NSButton(
            title: "保存常用语热词",
            target: self,
            action: #selector(saveVoiceCustomHotwords(_:))
        )
        saveHotwordsButton.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-custom-hotwords.save"
        )
        hotwordActionRow.addArrangedSubview(saveHotwordsButton)
        configureWrapping(voiceCustomHotwordsStatusLabel)
        voiceCustomHotwordsStatusLabel.textColor = .secondaryLabelColor
        voiceCustomHotwordsStatusLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-custom-hotwords.count"
        )
        hotwordActionRow.addArrangedSubview(voiceCustomHotwordsStatusLabel)
        voiceCustomHotwordsUnsavedLabel.stringValue = ""
        voiceCustomHotwordsUnsavedLabel.textColor = .systemOrange
        voiceCustomHotwordsUnsavedLabel.font = .systemFont(ofSize: 12, weight: .medium)
        voiceCustomHotwordsUnsavedLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-custom-hotwords.unsaved"
        )
        hotwordActionRow.addArrangedSubview(voiceCustomHotwordsUnsavedLabel)
        hotwordActionRow.setCustomSpacing(
            16,
            after: voiceCustomHotwordsStatusLabel
        )
        content.addArrangedSubview(hotwordActionRow)
    }

    // MARK: 服务状态

    private func buildVoiceServiceStatusCard(_ voiceStack: NSStackView) {
        let card = settingsCard("服务状态")
        addCard(card, to: voiceStack)
        let content = card.content

        voiceServiceStatusDot.wantsLayer = true
        voiceServiceStatusDot.layer?.cornerRadius = 4
        voiceServiceStatusDot.translatesAutoresizingMaskIntoConstraints = false
        voiceServiceStatusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        voiceServiceStatusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        voiceServiceStatusDot.setAccessibilityLabel("语音服务状态")

        configureWrapping(voiceStatusLabel)
        voiceStatusLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-status"
        )
        voiceStatusLabel.setAccessibilityLabel("语音服务状态")
        let statusRow = NSStackView(views: [voiceServiceStatusDot, voiceStatusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 8
        addFilling(statusRow, to: content)

        configureWrapping(voiceInstallHintLabel)
        voiceInstallHintLabel.font = .systemFont(ofSize: 12)
        voiceInstallHintLabel.textColor = .systemOrange
        voiceInstallHintLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-install-hint"
        )
        voiceInstallHintLabel.isHidden = true
        addFilling(voiceInstallHintLabel, to: content)

        let voiceButtons = NSStackView()
        voiceButtons.orientation = .horizontal
        voiceButtons.spacing = 8
        let retryButton = NSButton(
            title: "重试语音服务",
            target: self,
            action: #selector(retryVoice(_:))
        )
        retryButton.identifier = NSUserInterfaceItemIdentifier("settings.voice-retry")
        voiceButtons.addArrangedSubview(retryButton)
        voiceMicrophonePermissionButton.target = self
        voiceMicrophonePermissionButton.action = #selector(openMicrophonePrivacy(_:))
        voiceMicrophonePermissionButton.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-microphone-permission"
        )
        voiceButtons.addArrangedSubview(voiceMicrophonePermissionButton)
        voiceSpeechPermissionButton.target = self
        voiceSpeechPermissionButton.action = #selector(
            openSpeechRecognitionPrivacy(_:)
        )
        voiceSpeechPermissionButton.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-speech-permission"
        )
        voiceButtons.addArrangedSubview(voiceSpeechPermissionButton)
        voiceAccessibilityPermissionButton.target = self
        voiceAccessibilityPermissionButton.action = #selector(
            openAccessibilityPrivacy(_:)
        )
        voiceAccessibilityPermissionButton.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-accessibility-permission"
        )
        voiceButtons.addArrangedSubview(voiceAccessibilityPermissionButton)
        content.addArrangedSubview(voiceButtons)
    }
}
