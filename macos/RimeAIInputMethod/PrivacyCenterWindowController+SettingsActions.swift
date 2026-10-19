import AppKit
import UniformTypeIdentifiers

/// 机械拆分自 PrivacyCenterWindowController.swift（纯代码搬移，行为不变）。
extension PrivacyCenterWindowController {
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

    @objc func cancelVoiceShortcutEdit(_ sender: Any?) {
        voiceShortcutCaptureButton.cancelCapture()
        voiceShortcutCancelButton.isEnabled = false
        refreshVoiceShortcutStatus()
    }

    @objc func restoreDefaultVoiceShortcut(_ sender: Any?) {
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

    @objc func openMicrophonePrivacy(_ sender: Any?) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
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
