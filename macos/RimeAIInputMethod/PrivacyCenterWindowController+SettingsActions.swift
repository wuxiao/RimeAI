import AppKit
import UniformTypeIdentifiers

/// 机械拆分自 PrivacyCenterWindowController.swift（纯代码搬移，行为不变）。
extension PrivacyCenterWindowController {
    /// 开关分发表：每个开关对应一个独立处理函数，新增开关不再让单个方法
    /// 随分支数量膨胀。
    private var toggleHandlers: [ObjectIdentifier: (NSButton) -> Void] {
        [
            ObjectIdentifier(aiToggle): { [weak self] in
                self?.applyAIToggle($0)
            },
            ObjectIdentifier(voiceToggle): { [weak self] in
                self?.applyVoiceToggle($0)
            },
            ObjectIdentifier(voiceRimeHotwordToggle): { [weak self] in
                self?.applyVoiceRimeHotwordToggle($0)
            },
            ObjectIdentifier(voicePhraseBookHotwordToggle): { [weak self] in
                self?.applyVoicePhraseBookHotwordToggle($0)
            },
            ObjectIdentifier(voiceAutoLearnCorrectionsToggle): { [weak self] in
                self?.applyVoiceAutoLearnCorrectionsToggle($0)
            },
            ObjectIdentifier(voiceCloudHotwordsToggle): { [weak self] in
                self?.applyVoiceCloudHotwordsToggle($0)
            },
            ObjectIdentifier(voiceAXFallbackReadToggle): { [weak self] in
                self?.applyVoiceAXFallbackReadToggle($0)
            },
            ObjectIdentifier(voiceSmartPolishToggle): { [weak self] in
                self?.applyVoiceSmartPolishToggle($0)
            },
            ObjectIdentifier(voiceAutoPasteToggle): { [weak self] in
                self?.applyVoiceAutoPasteToggle($0)
            },
            ObjectIdentifier(voiceHistoryToggle): { [weak self] in
                self?.applyVoiceHistoryToggle($0)
            },
            ObjectIdentifier(voiceSharedHistoryToggle): { [weak self] in
                self?.applyVoiceSharedHistoryToggle($0)
            },
            ObjectIdentifier(voiceSoundEffectsToggle): { [weak self] in
                self?.applyVoiceSoundEffectsToggle($0)
            },
            ObjectIdentifier(voiceMuteSystemAudioToggle): { [weak self] in
                self?.applyVoiceMuteSystemAudioToggle($0)
            },
        ]
    }

    @objc func toggleChanged(_ sender: NSButton) {
        if lifecycleCoordinator.isReconciling,
           sender === aiToggle || sender === voiceToggle
        {
            refresh()
            updateSettingsActionStatus(
                .working,
                "另一个生命周期操作仍在进行，请稍后再更改开关"
            )
            return
        }
        toggleHandlers[ObjectIdentifier(sender)]?(sender)
    }

    private func applyAIToggle(_ sender: NSButton) {
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
    }

    private func applyVoiceToggle(_ sender: NSButton) {
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
    }

    /// 热词与自动纠错类开关的共同前置：AI 与语音均开启且非 strict 策略。
    private func voiceContextFeatureAllowed() -> Bool {
        settings.aiEnabled
            && settings.voiceEnabled
            && settings.contextPolicy != .strict
    }

    /// 不满足前置条件时把控件恢复为已保存的取值。
    private func restoreToggle(_ button: NSButton, isOn: Bool) {
        button.state = isOn ? .on : .off
    }

    private func applyVoiceRimeHotwordToggle(_ sender: NSButton) {
        guard voiceContextFeatureAllowed() else {
            restoreToggle(voiceRimeHotwordToggle, isOn: settings.voiceRimeHotwordsEnabled)
            return
        }
        settings.voiceRimeHotwordsEnabled = sender.state == .on
    }

    private func applyVoicePhraseBookHotwordToggle(_ sender: NSButton) {
        guard voiceContextFeatureAllowed() else {
            restoreToggle(
                voicePhraseBookHotwordToggle,
                isOn: settings.voicePhraseBookHotwordsEnabled
            )
            return
        }
        settings.voicePhraseBookHotwordsEnabled = sender.state == .on
    }

    private func applyVoiceAutoLearnCorrectionsToggle(_ sender: NSButton) {
        guard voiceContextFeatureAllowed() else {
            restoreToggle(
                voiceAutoLearnCorrectionsToggle,
                isOn: settings.voiceAutoLearnCorrectionsEnabled
            )
            return
        }
        settings.voiceAutoLearnCorrectionsEnabled = sender.state == .on
        if sender.state != .on {
            VoicePostCommitEditTracker.shared.clearEphemeralData()
        }
    }

    private func applyVoiceCloudHotwordsToggle(_ sender: NSButton) {
        guard settings.aiEnabled, settings.voiceEnabled else {
            restoreToggle(voiceCloudHotwordsToggle, isOn: settings.voiceCloudHotwordsEnabled)
            return
        }
        // 默认关闭的显式 opt-in：只有开启后热词上下文才会离开本机。
        settings.setVoiceCloudHotwordsEnabled(sender.state == .on)
    }

    private func applyVoiceAXFallbackReadToggle(_ sender: NSButton) {
        guard voiceContextFeatureAllowed() else {
            restoreToggle(voiceAXFallbackReadToggle, isOn: settings.voiceAXFallbackReadEnabled)
            return
        }
        // 默认关闭的显式 opt-in：读取光标周边文本属于额外的隐私边界。
        let enabled = sender.state == .on
        settings.setVoiceAXFallbackReadEnabled(enabled)
        if !enabled {
            VoicePostCommitEditTracker.shared.clearEphemeralData()
        }
    }

    private func applyVoiceSmartPolishToggle(_ sender: NSButton) {
        settings.voiceSmartPolishEnabled = sender.state == .on
    }

    private func applyVoiceAutoPasteToggle(_ sender: NSButton) {
        settings.voiceAutoPasteEnabled = sender.state == .on
    }

    private func applyVoiceHistoryToggle(_ sender: NSButton) {
        settings.voiceHistoryEnabled = sender.state == .on
    }

    private func applyVoiceSharedHistoryToggle(_ sender: NSButton) {
        settings.voiceSharedHistoryEnabled = sender.state == .on
    }

    private func applyVoiceSoundEffectsToggle(_ sender: NSButton) {
        settings.voiceSoundEffectsEnabled = sender.state == .on
        if sender.state == .on {
            VoiceSoundEffectsPlayer.shared.play(.start, enabled: true)
        }
    }

    private func applyVoiceMuteSystemAudioToggle(_ sender: NSButton) {
        settings.voiceMuteSystemAudioEnabled = sender.state == .on
    }

    @objc func voicePolishStyleChanged(_ sender: NSPopUpButton) {
        let styles = VoicePolishStyle.allCases
        let index = max(0, min(sender.indexOfSelectedItem, styles.count - 1))
        settings.voicePolishStyle = styles[index]
    }

    @objc func voiceTranslateLanguageChanged(_ sender: NSPopUpButton) {
        let languages = VoiceTranslationLanguage.allCases
        let index = max(0, min(sender.indexOfSelectedItem, languages.count - 1))
        settings.voiceTranslateTargetLanguage = languages[index]
    }

    func captureVoiceTranslateShortcut(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard let shortcut = VoiceHotKeyManager.makeShortcut(
            keyCode: keyCode,
            modifierFlags: modifierFlags
        ) else {
            voiceTranslateShortcutCaptureButton.showValidationFailure()
            voiceTranslateShortcutStatusLabel.stringValue =
                "组合不可用；原翻译快捷键 \(settings.voiceTranslateShortcut.displayName) 仍已保留"
            voiceTranslateShortcutStatusLabel.textColor = .systemRed
            updateSettingsActionStatus(
                .failure,
                "翻译快捷键未更改："
                    + VoiceDictationShortcut.validationFailureDescription
            )
            return
        }
        guard !settings.voiceShortcuts.contains(shortcut) else {
            voiceTranslateShortcutCaptureButton.showValidationFailure()
            voiceTranslateShortcutStatusLabel.stringValue =
                "不能与语音听写快捷键（\(shortcut.displayName)）相同"
            voiceTranslateShortcutStatusLabel.textColor = .systemRed
            updateSettingsActionStatus(
                .failure,
                "翻译快捷键不能与语音听写快捷键重复"
            )
            return
        }
        settings.voiceTranslateShortcut = shortcut
        VoiceGlobalHotKeyService.shared.resetModifierTapDetectors()
        voiceTranslateShortcutCaptureButton.finishCapture(
            displayName: shortcut.displayName
        )
        voiceTranslateShortcutCancelButton.isEnabled = false
        updateSettingsActionStatus(
            .success,
            "一键翻译快捷键已更改为 \(shortcut.displayName)"
        )
        refreshVoiceTranslateShortcutStatus()
    }

    @objc func cancelVoiceTranslateShortcutEdit(_ sender: Any?) {
        voiceTranslateShortcutCaptureButton.cancelCapture()
        voiceTranslateShortcutCancelButton.isEnabled = false
        refreshVoiceTranslateShortcutStatus()
    }

    @objc func restoreDefaultVoiceTranslateShortcut(_ sender: Any?) {
        let shortcut = VoiceDictationShortcut.defaultTranslate
        settings.voiceTranslateShortcut = shortcut
        VoiceGlobalHotKeyService.shared.resetModifierTapDetectors()
        voiceTranslateShortcutCaptureButton.finishCapture(
            displayName: shortcut.displayName
        )
        voiceTranslateShortcutCancelButton.isEnabled = false
        updateSettingsActionStatus(
            .success,
            "一键翻译快捷键已恢复为 \(shortcut.displayName)"
        )
        refreshVoiceTranslateShortcutStatus()
    }

    @objc func saveVoiceCustomHotwords(_ sender: Any?) {
        // 与编辑器实时计数共用同一解析规则，保证“编辑中 N 条”与保存结果一致。
        let parts = VoiceHotwordsEditing.parse(voiceCustomHotwordsTextView.string)
        let normalized = RimeAISettingsStore.normalizedVoiceCustomHotwords(parts)
        settings.voiceCustomHotwords = normalized
        RimeAIPhraseBookService.shared.reloadVoiceHotwordsAsync()
        voiceCustomHotwordsTextView.string = normalized.joined(separator: "\n")
        voiceCustomHotwordsIsDirty = false
        let skipped = max(0, parts.count - normalized.count)
        let suffix = skipped > 0 ? "（已跳过 \(skipped) 条重复或非法词条）" : ""
        updateSettingsActionStatus(
            .success,
            "已保存 \(normalized.count) 条语音常用语热词\(suffix)"
        )
    }

    @objc func clearVoiceLearnedCorrections(_ sender: Any?) {
        let count = settings.voiceLearnedCorrections.count
        guard count > 0 else {
            updateSettingsActionStatus(.success, "当前没有自动纠错映射")
            return
        }
        // 不可撤销的删除必须先确认，避免误点。
        let alert = NSAlert()
        alert.messageText = "清空自动纠错映射？"
        alert.informativeText =
            "将删除 \(count) 条从你上屏后手动修改中学到的纠错映射（错词 → 正词）。"
            + "自定义热词与个人短语库不受影响。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else {
                return
            }
            self.settings.voiceLearnedCorrections = [:]
            VoicePostCommitEditTracker.shared.clearEphemeralData()
            self.updateSettingsActionStatus(
                .success,
                "已清空 \(count) 条自动纠错映射（手动/已收录热词保留在上方列表）"
            )
        }
    }

    @objc func retryVoice(_ sender: Any?) {
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

    func captureVoiceShortcut(
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
        VoiceGlobalHotKeyService.shared.resetModifierTapDetectors()
        voiceShortcutCaptureButton.finishCapture(
            displayName: shortcut.displayName
        )
        voiceShortcutCancelButton.isEnabled = false
        updateSettingsActionStatus(
            .success,
            "语音快捷键已更改为 \(shortcut.displayName)"
                + (shortcut.isModifierTap ? "（按一下开始，再按一下结束）" : "")
        )
        refreshVoiceShortcutStatus()
    }

    @objc func cancelVoiceShortcutEdit(_ sender: Any?) {
        voiceShortcutCaptureButton.cancelCapture()
        voiceShortcutCancelButton.isEnabled = false
        refreshVoiceShortcutStatus()
    }

    @objc func useRightCommandVoiceShortcut(_ sender: Any?) {
        let shortcut = VoiceDictationShortcut.rightCommand
        settings.voiceShortcut = shortcut
        VoiceGlobalHotKeyService.shared.resetModifierTapDetectors()
        voiceShortcutCaptureButton.finishCapture(
            displayName: shortcut.displayName
        )
        voiceShortcutCancelButton.isEnabled = false
        updateSettingsActionStatus(
            .success,
            "语音快捷键已设为 \(shortcut.displayName)（按一下开始，再按一下结束）"
        )
        refreshVoiceShortcutStatus()
    }

    @objc func restoreDefaultVoiceShortcut(_ sender: Any?) {
        let shortcut = VoiceDictationShortcut.default
        settings.voiceShortcut = shortcut
        VoiceGlobalHotKeyService.shared.resetModifierTapDetectors()
        voiceShortcutCaptureButton.finishCapture(
            displayName: shortcut.displayName
        )
        voiceShortcutCancelButton.isEnabled = false
        updateSettingsActionStatus(
            .success,
            "语音快捷键已恢复为 \(shortcut.displayName)"
                + (shortcut.isModifierTap ? "（按一下开始，再按一下结束）" : "")
        )
        refreshVoiceShortcutStatus()
    }

    func captureVoiceSecondaryShortcut(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard let shortcut = VoiceHotKeyManager.makeShortcut(
            keyCode: keyCode,
            modifierFlags: modifierFlags
        ) else {
            voiceSecondaryShortcutCaptureButton.showValidationFailure()
            let previousName = settings.voiceSecondaryShortcut?.displayName ?? "未设置"
            voiceSecondaryShortcutStatusLabel.stringValue =
                "组合不可用；原备用快捷键（\(previousName)）仍已保留"
            voiceSecondaryShortcutStatusLabel.textColor = .systemRed
            updateSettingsActionStatus(
                .failure,
                "备用快捷键未更改："
                    + VoiceDictationShortcut.validationFailureDescription
            )
            return
        }
        guard shortcut != settings.voiceShortcut else {
            voiceSecondaryShortcutCaptureButton.showValidationFailure()
            voiceSecondaryShortcutStatusLabel.stringValue =
                "不能与主语音听写快捷键（\(settings.voiceShortcut.displayName)）相同"
            voiceSecondaryShortcutStatusLabel.textColor = .systemRed
            updateSettingsActionStatus(
                .failure,
                "备用快捷键不能与主语音听写快捷键重复"
            )
            return
        }
        settings.voiceSecondaryShortcut = shortcut
        VoiceGlobalHotKeyService.shared.resetModifierTapDetectors()
        voiceSecondaryShortcutCaptureButton.finishCapture(
            displayName: shortcut.displayName
        )
        voiceSecondaryShortcutCancelButton.isEnabled = false
        updateSettingsActionStatus(
            .success,
            "备用语音快捷键已更改为 \(shortcut.displayName)"
                + (shortcut.isModifierTap ? "（按一下开始，再按一下结束）" : "")
        )
        refreshVoiceSecondaryShortcutStatus()
    }

    @objc func cancelVoiceSecondaryShortcutEdit(_ sender: Any?) {
        voiceSecondaryShortcutCaptureButton.cancelCapture()
        voiceSecondaryShortcutCancelButton.isEnabled = false
        refreshVoiceSecondaryShortcutStatus()
    }

    @objc func usePresetSecondaryVoiceShortcut(_ sender: Any?) {
        let preset: VoiceDictationShortcut =
            settings.voiceShortcut == .rightCommand
            ? .function
            : .rightCommand
        settings.voiceSecondaryShortcut = preset
        VoiceGlobalHotKeyService.shared.resetModifierTapDetectors()
        voiceSecondaryShortcutCaptureButton.finishCapture(
            displayName: preset.displayName
        )
        voiceSecondaryShortcutCancelButton.isEnabled = false
        updateSettingsActionStatus(
            .success,
            "备用语音快捷键已设为 \(preset.displayName)（按一下开始，再按一下结束）"
        )
        refreshVoiceSecondaryShortcutStatus()
    }

    @objc func clearSecondaryVoiceShortcut(_ sender: Any?) {
        settings.voiceSecondaryShortcut = nil
        VoiceGlobalHotKeyService.shared.resetModifierTapDetectors()
        voiceSecondaryShortcutCaptureButton.finishCapture(displayName: nil)
        voiceSecondaryShortcutCancelButton.isEnabled = false
        updateSettingsActionStatus(
            .success,
            "已清除备用语音快捷键"
        )
        refreshVoiceSecondaryShortcutStatus()
    }

    @objc func openMicrophonePrivacy(_ sender: Any?) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc func openAccessibilityPrivacy(_ sender: Any?) {
        VoiceSystemSettingsOpener.open(.accessibility)
    }

    @objc func openSpeechRecognitionPrivacy(_ sender: Any?) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc func characterSetChanged(_ sender: NSPopUpButton) {
        settings.characterSet = sender.indexOfSelectedItem == 0
            ? .simplified
            : .traditional
        RimeEngine.shared.apply(settings.inputPreferences)
    }

    @objc func characterWidthChanged(_ sender: NSPopUpButton) {
        settings.characterWidth = sender.indexOfSelectedItem == 0
            ? .half
            : .full
        RimeEngine.shared.apply(settings.inputPreferences)
    }

    @objc func punctuationChanged(_ sender: NSPopUpButton) {
        settings.punctuationStyle = sender.indexOfSelectedItem == 0
            ? .chinese
            : .western
        RimeEngine.shared.apply(settings.inputPreferences)
    }

    @objc func contextChanged(_ sender: NSPopUpButton) {
        settings.contextPolicy = [
            ContextPolicy.strict,
            ContextPolicy.standard,
            ContextPolicy.smart,
        ][max(0, min(sender.indexOfSelectedItem, 2))]
        settings.clearEphemeralData()
    }

    @objc func cloudModelChanged(_ sender: NSPopUpButton) {
        guard let modelID = sender.selectedItem?.title else {
            return
        }
        settings.cloudModelID = modelID
    }


    @objc func saveAPIKey(_ sender: Any?) {
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

    @objc func removeAPIKey(_ sender: Any?) {
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

    @objc func exportHistory(_ sender: Any?) {
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

    @objc func clearHistory(_ sender: Any?) {
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

    @objc func saveApplicationPolicies(_ sender: Any?) {
        settings.disabledAIApplications = splitApplications(
            disabledAIField.stringValue
        )
        settings.disabledContextApplications = splitApplications(
            disabledContextField.stringValue
        )
        settings.clearEphemeralData()
        refresh()
    }


    @objc func clearEphemeralData(_ sender: Any?) {
        settings.clearEphemeralData()
    }

    @objc func resetDiagnostics(_ sender: Any?) {
        settings.resetDiagnostics()
        updateSettingsActionStatus(.success, "诊断计数已重置")
    }

    @objc func importSettings(_ sender: Any?) {
        guard !lifecycleCoordinator.isReconciling else {
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
                RimeAIPhraseBookService.shared.reloadVoiceHotwordsAsync()
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

    @objc func exportSettings(_ sender: Any?) {
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

    @objc func restoreDefaultSettings(_ sender: Any?) {
        guard !lifecycleCoordinator.isReconciling else {
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
}
