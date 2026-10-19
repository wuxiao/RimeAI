import AppKit

/// 机械拆分自 PrivacyCenterWindowController.swift（纯代码搬移，行为不变）。
extension PrivacyCenterWindowController {
    func observeState() {
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

    func refresh() {
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
        aiToggle.isEnabled = !lifecycleCoordinator.isReconciling
        offlineToggle.state = settings.offlineLockEnabled ? .on : .off
        voiceToggle.state = settings.voiceEnabled ? .on : .off
        voiceToggle.isEnabled = settings.aiEnabled
            && !lifecycleCoordinator.isReconciling
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
        do {
            let hasCredential = try credentialStore.containsAPIKey()
            if settings.cloudConfigured, hasCredential {
                cloudStatusLabel.stringValue =
                    "云增强：已启用 · \(RimeAICloudConfiguration.provider) · "
                    + RimeAICloudConfiguration.endpoint.absoluteString
            } else if settings.cloudConfigured {
                cloudStatusLabel.stringValue =
                    "云增强：已启用 · 凭据文件不存在或为空"
            } else {
                cloudStatusLabel.stringValue =
                    "云增强：未启用 · 未配置的输入不会保存到长期历史或上传"
            }
        } catch CloudCredentialError.malformedFile {
            // 凭据文件存在但格式损坏：与暂时 I/O 失败区分，提示用户修复
            // 而不是静默重试（R3-F8 P2-10）。
            cloudStatusLabel.stringValue =
                "云增强：凭据无效 · cloud.env 格式错误（每行应为 "
                + "KEY=VALUE），修复前云端请求都会被跳过"
        } catch {
            cloudStatusLabel.stringValue =
                "云增强：已启用 · 凭据文件暂时不可读，将在输入时重试"
        }
        refreshVoiceStatus()
        refreshSettingsActionStatus()
        refreshLanguageProfileStatus()
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


    func applyDaemonStatus(_ notification: Notification) {
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

    func diagnosticsDescription() -> String {
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
            "cloud_transport_failure": "云连接失败",
            "continuation_requested": "续写建议已请求",
            "continuation_shown": "续写建议已显示",
            "continuation_accepted": "续写建议已采纳",
            "continuation_dismissed": "续写建议已撤销",
            "continuation_abstained": "续写建议已弃权",
            "continuation_cooldown": "续写建议进入冷却",
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

    func dataSizeDescription() -> String {
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

    func dataSize(at root: URL) -> Int64 {
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

    func formatted(bytes: Int64) -> String {
        return ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }


    func refreshVoiceShortcutStatus() {
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

    func refreshSettingsActionStatus() {
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

    func settingsActionStatusColor(
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

    func updateSettingsActionStatus(
        _ kind: SettingsActionStatus.Kind,
        _ message: String
    ) {
        SettingsActionStatusCenter.shared.update(SettingsActionStatus(
            kind: kind,
            message: message
        ))
    }
}
