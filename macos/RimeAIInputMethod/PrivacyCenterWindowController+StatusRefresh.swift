import AppKit

/// 设置窗口的状态刷新：设置存储 / 运行态 → 各页面控件的单向同步。
/// 所有数据库与磁盘查询都移出主线程，结果按代次回填，过期结果直接丢弃。
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
        voiceSecondaryShortcutStatusObserver = NotificationCenter.default
            .addObserver(
                forName: .rimeAIVoiceSecondaryHotKeyRegistrationDidChange,
                object: VoiceHotKeyManager.shared,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshVoiceSecondaryShortcutStatus()
                }
            }
        voiceTranslateShortcutStatusObserver = NotificationCenter.default
            .addObserver(
                forName: .rimeAIVoiceTranslateHotKeyRegistrationDidChange,
                object: VoiceHotKeyManager.shared,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshVoiceTranslateShortcutStatus()
                }
            }
        voiceHistoryObserver = NotificationCenter.default.addObserver(
            forName: .rimeAIVoiceHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshVoiceHistoryAndStats()
            }
        }
        // 语音 helper 启用/停用完成、熔断恢复或权限阻断时，服务状态徽标实时刷新。
        voiceServiceStateObserver = NotificationCenter.default.addObserver(
            forName: .rimeAIVoiceServiceStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshVoiceStatus()
            }
        }
        // 热词编辑器的任何输入都进入“未保存”状态；用通知而非代理，避免
        // 后台刷新与用户输入互相覆盖。
        voiceHotwordsEditorObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification,
            object: voiceCustomHotwordsTextView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteVoiceCustomHotwordsEdited()
            }
        }
    }

    func refresh() {
        refreshInputPreferences()
        refreshVoiceSettingsPage()
        refreshApplicationPolicies()
        refreshCloudStatus()
        refreshVoiceStatus()
        refreshVoiceHistoryAndStats()
        refreshSettingsActionStatus()
        refreshLanguageProfileStatus()
        refreshStorageUsageAsync()
    }

    // MARK: - 输入与 AI

    private func refreshInputPreferences() {
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
        if !settings.aiEnabled {
            daemonStatusLabel.stringValue =
                "Daemon：已停用 · 重新开启 AI 后按需加载"
        }
    }

    private func refreshApplicationPolicies() {
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
    }

    // MARK: - 语音页

    /// 语音页全部控件的刷新。语音未启用时相关控件整体禁用并显示横幅；
    /// 热词编辑器在获得焦点或有未保存修改时绝不覆盖。
    func refreshVoiceSettingsPage() {
        refreshVoicePrimaryControls()
        refreshVoiceShortcutControls()
        refreshVoiceTranslationControls()
        refreshVoiceOutputAndAudioControls()
        refreshVoiceHotwordAndCorrectionControls()
        refreshVoiceControlAvailability()
    }

    private func refreshVoicePrimaryControls() {
        voiceToggle.state = settings.voiceEnabled ? .on : .off
        voiceToggle.isEnabled = settings.aiEnabled
            && !lifecycleCoordinator.isReconciling
        let voiceShortcuts = settings.voiceShortcuts
        // 只陈述可验证的事实：输入法侧无法确认 helper 当前使用的识别引擎，
        // 不再宣称 “Qwen3-ASR MLX 实时流式”。
        voiceInstructionLabel.stringValue = VoicePrivacyCopy.dictationInstruction(
            shortcuts: voiceShortcuts
        )
        voiceToggle.title = VoicePrivacyCopy.voiceToggleTitle(
            shortcuts: voiceShortcuts
        )
        voiceDisabledBannerLabel.isHidden = settings.voiceEnabled
    }

    private func refreshVoiceShortcutControls() {
        let voiceShortcut = settings.voiceShortcut
        voiceShortcutCaptureButton.showShortcut(voiceShortcut.displayName)
        voiceShortcutCancelButton.isEnabled =
            voiceShortcutCaptureButton.isCapturing
        refreshVoiceShortcutStatus()

        let secondaryShortcut = settings.voiceSecondaryShortcut
        voiceSecondaryShortcutCaptureButton.showShortcut(
            secondaryShortcut?.displayName
        )
        voiceSecondaryShortcutCancelButton.isEnabled =
            voiceSecondaryShortcutCaptureButton.isCapturing
        voiceSecondaryShortcutPresetButton.title =
            voiceShortcut == .rightCommand ? "设为 Fn" : "设为右 ⌘"
        refreshVoiceSecondaryShortcutStatus()
    }

    private func refreshVoiceTranslationControls() {
        let translateShortcut = settings.voiceTranslateShortcut
        voiceTranslateShortcutCaptureButton.showShortcut(
            translateShortcut.displayName
        )
        voiceTranslateShortcutCancelButton.isEnabled =
            voiceTranslateShortcutCaptureButton.isCapturing
        refreshVoiceTranslateShortcutStatus()
        if let langIndex = VoiceTranslationLanguage.allCases.firstIndex(
            of: settings.voiceTranslateTargetLanguage
        ) {
            voiceTranslateLanguagePopup.selectItem(at: langIndex)
        }
    }

    private func refreshVoiceOutputAndAudioControls() {
        voiceSmartPolishToggle.state = settings.voiceSmartPolishEnabled
            ? .on
            : .off
        if let styleIndex = VoicePolishStyle.allCases.firstIndex(
            of: settings.voicePolishStyle
        ) {
            voicePolishStylePopup.selectItem(at: styleIndex)
        }
        voiceAutoPasteToggle.state = settings.voiceAutoPasteEnabled
            ? .on
            : .off
        voiceCloudHotwordsToggle.state = settings.voiceCloudHotwordsEnabled
            ? .on
            : .off
        voiceHistoryToggle.state = settings.voiceHistoryEnabled
            ? .on
            : .off
        voiceSharedHistoryToggle.state = settings.voiceSharedHistoryEnabled
            ? .on
            : .off
        voiceSoundEffectsToggle.state = settings.voiceSoundEffectsEnabled
            ? .on
            : .off
        voiceMuteSystemAudioToggle.state = settings.voiceMuteSystemAudioEnabled
            ? .on
            : .off
    }

    private func refreshVoiceHotwordAndCorrectionControls() {
        voiceRimeHotwordToggle.state = settings.voiceRimeHotwordsEnabled
            ? .on
            : .off
        voicePhraseBookHotwordToggle.state = settings
            .voicePhraseBookHotwordsEnabled ? .on : .off
        voiceAutoLearnCorrectionsToggle.state = settings
            .voiceAutoLearnCorrectionsEnabled ? .on : .off
        voiceAXFallbackReadToggle.state = settings.voiceAXFallbackReadEnabled
            ? .on
            : .off
        refreshVoiceLearnedCorrectionsStatus()

        // 热词编辑器：正在输入或有未保存修改时，刷新绝不覆盖用户内容。
        if !voiceCustomHotwordsIsDirty,
           window.firstResponder !== voiceCustomHotwordsTextView
        {
            let formatted = settings.voiceCustomHotwords.joined(separator: "\n")
            if voiceCustomHotwordsTextView.string != formatted {
                voiceCustomHotwordsTextView.string = formatted
            }
        }
        refreshVoiceCustomHotwordsStatus()
    }

    private func refreshVoiceLearnedCorrectionsStatus() {
        let learnedCorrections = settings.voiceLearnedCorrections
        voiceClearLearnedCorrectionsButton.isEnabled = !learnedCorrections.isEmpty
        if learnedCorrections.isEmpty {
            voiceLearnedCorrectionsStatusLabel.stringValue =
                "自动纠错映射：暂无（语音上屏后直接修改错字即可自动收录）"
        } else {
            let preview = learnedCorrections
                .sorted { $0.key < $1.key }
                .prefix(4)
                .map { "\($0.key)→\($0.value)" }
                .joined(separator: "、")
            let suffix = learnedCorrections.count > 4 ? " 等" : ""
            voiceLearnedCorrectionsStatusLabel.stringValue =
                "自动纠错映射 \(learnedCorrections.count)/128 条：\(preview)\(suffix)"
        }
    }

    /// 语音未启用时干净地禁用所有依赖控件；总开关本身保持可用。
    func refreshVoiceControlAvailability() {
        let voiceOn = settings.aiEnabled && settings.voiceEnabled
        let notStrict = settings.contextPolicy != .strict
        voiceShortcutCaptureButton.isEnabled = voiceOn
        voiceSecondaryShortcutCaptureButton.isEnabled = voiceOn
        voiceSecondaryShortcutPresetButton.isEnabled = voiceOn
        voiceSecondaryShortcutClearButton.isEnabled = voiceOn
            && settings.voiceSecondaryShortcut != nil
        voiceTranslateShortcutCaptureButton.isEnabled = voiceOn
        voiceTranslateLanguagePopup.isEnabled = voiceOn
        voiceSmartPolishToggle.isEnabled = voiceOn
        voicePolishStylePopup.isEnabled = voiceOn
            && settings.voiceSmartPolishEnabled
        voiceAutoPasteToggle.isEnabled = voiceOn
        voiceCloudHotwordsToggle.isEnabled = voiceOn
        voiceSharedHistoryToggle.isEnabled = voiceOn && settings.voiceHistoryEnabled
        voiceSoundEffectsToggle.isEnabled = voiceOn
        voiceMuteSystemAudioToggle.isEnabled = voiceOn
        voiceRimeHotwordToggle.isEnabled = voiceOn && notStrict
        voicePhraseBookHotwordToggle.isEnabled = voiceOn && notStrict
        voiceAutoLearnCorrectionsToggle.isEnabled = voiceOn && notStrict
        voiceAXFallbackReadToggle.isEnabled = voiceOn && notStrict
    }

    // MARK: - 热词编辑器（未保存保护）

    func noteVoiceCustomHotwordsEdited() {
        voiceCustomHotwordsIsDirty = true
        refreshVoiceCustomHotwordsStatus()
    }

    /// 实时条数徽标与“未保存”指示：计数规则与保存时完全一致。
    func refreshVoiceCustomHotwordsStatus() {
        let liveCount = VoiceHotwordsEditing.parse(
            voiceCustomHotwordsTextView.string
        ).count
        voiceCustomHotwordsStatusLabel.stringValue = VoiceHotwordsEditing.status(
            savedCount: settings.voiceCustomHotwords.count,
            liveCount: liveCount,
            phraseBookEnabled: settings.voicePhraseBookHotwordsEnabled
        )
        voiceCustomHotwordsUnsavedLabel.stringValue = voiceCustomHotwordsIsDirty
            ? VoiceHotwordsEditing.unsavedIndicator
            : ""
        voiceCustomHotwordsUnsavedLabel.setAccessibilityValue(
            voiceCustomHotwordsIsDirty ? "有未保存的修改" : nil
        )
    }

    // MARK: - 云端状态

    private func refreshCloudStatus() {
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
    }

    // MARK: - 数据体积与明文历史（后台）

    /// 数据体积需要遍历目录、明文历史需要查询 SQLite：都移出主线程。
    func refreshStorageUsageAsync() {
        dataSizeRefreshGeneration &+= 1
        let generation = dataSizeRefreshGeneration
        let historyService = historyService
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sizeDescription = Self.managedDataSizeDescription()
            let statistics = try? historyService.statistics()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.dataSizeRefreshGeneration == generation
                else {
                    return
                }
                self.dataSizeLabel.stringValue = sizeDescription
                if let statistics {
                    self.historyStatusLabel.stringValue =
                        "明文历史：\(statistics.recordCount) 条 · 代次 "
                        + "\(statistics.generation) · 待生成向量 "
                        + "\(statistics.pendingEmbeddingJobs) 条"
                } else {
                    self.historyStatusLabel.stringValue = "明文历史：存储不可用"
                }
            }
        }
    }

    nonisolated static func managedDataSizeDescription() -> String {
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

    nonisolated static func dataSize(at root: URL) -> Int64 {
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

    nonisolated static func formatted(bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }

    // MARK: - 运行态

    func applyDaemonStatus(_ notification: Notification) {
        guard settings.aiEnabled else {
            daemonStatusLabel.stringValue =
                "Daemon：已停用 · 模型资源已释放"
            return
        }
        let status = notification.userInfo?["status"] as? String ?? "未知"
        // artifactID 可能为空（握手尚未完成）：显式给出占位文案，避免
        // 字符串插值输出 "Optional(...)"。
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
                "\($0.role)：\($0.path)\nSHA-256 \($0.sha256 ?? "daemon 未提供")"
            }.joined(separator: "\n")
    }

    // MARK: - 诊断

    func diagnosticsDescription() -> String {
        let diagnostics = settings.diagnosticSnapshot()
        guard !diagnostics.isEmpty else {
            return "尚无诊断计数（不会保存原始输入文本）"
        }
        let names = Self.diagnosticMetricNames
        return diagnostics.keys.sorted().map { key in
            let name = names[key] ?? key
            return "\(name)：\(diagnostics[key, default: 0])"
        }.joined(separator: " · ")
    }

    private static let diagnosticMetricNames: [String: String] = [
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
        "voice_polished": "语音智能润色",
        "voice_translated": "语音一键翻译",
        "voice_auto_pasted": "语音自动粘贴",
        "voice_correction_learned": "语音上屏改错自动收录",
    ]

    // MARK: - 快捷键状态

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
                    + "将在非安全输入状态下全局注册（任意应用与输入法可用）"
            } else {
                message =
                    "已保存 \(configured.displayName)；语音启用后将全局注册"
            }
            color = .secondaryLabelColor
        case let .registered(shortcut):
            if shortcut == configured {
                let globeHint = shortcut == .function
                    ? "；如系统触发输入法切换或表情，请在系统设置 → 键盘将「按下 🌐 键以」设为无操作"
                    : ""
                message = "已全局注册 \(shortcut.displayName)（任意应用与输入法均可触发\(globeHint)）"
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

    func refreshVoiceSecondaryShortcutStatus() {
        guard !voiceSecondaryShortcutCaptureButton.isCapturing else {
            return
        }
        let message: String
        let color: NSColor
        guard let configured = settings.voiceSecondaryShortcut else {
            message =
                "未绑定备用快捷键；可再绑定一个键（例如内置键盘用 Fn、外接键盘用 右 ⌘），两者均可随时触发听写"
            color = .secondaryLabelColor
            if voiceSecondaryShortcutStatusLabel.stringValue != message
                || voiceSecondaryShortcutStatusLabel.textColor != color
            {
                voiceSecondaryShortcutStatusLabel.stringValue = message
                voiceSecondaryShortcutStatusLabel.textColor = color
                voiceSecondaryShortcutStatusLabel.setAccessibilityValue(message)
                NSAccessibility.post(
                    element: voiceSecondaryShortcutStatusLabel,
                    notification: .valueChanged
                )
            }
            return
        }
        switch VoiceHotKeyManager.shared.secondaryRegistrationStatus {
        case .inactive:
            if settings.aiEnabled, settings.voiceEnabled {
                message =
                    "已保存 \(configured.displayName)；"
                    + "将在非安全输入状态下全局注册（任意应用与输入法可用）"
            } else {
                message =
                    "已保存 \(configured.displayName)；语音启用后将全局注册"
            }
            color = .secondaryLabelColor
        case let .registered(shortcut):
            if shortcut == configured {
                let globeHint = shortcut == .function
                    ? "；如系统触发输入法切换或表情，请在系统设置 → 键盘将「按下 🌐 键以」设为无操作"
                    : ""
                message = "已全局注册 \(shortcut.displayName)（任意应用与输入法均可触发\(globeHint)）"
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
                    "备用快捷键 \(configured.displayName) 已保存，但当前无法注册；请更换快捷键"
                )
            }
        }
        guard voiceSecondaryShortcutStatusLabel.stringValue != message
                || voiceSecondaryShortcutStatusLabel.textColor != color
        else {
            return
        }
        voiceSecondaryShortcutStatusLabel.stringValue = message
        voiceSecondaryShortcutStatusLabel.textColor = color
        voiceSecondaryShortcutStatusLabel.setAccessibilityValue(message)
        NSAccessibility.post(
            element: voiceSecondaryShortcutStatusLabel,
            notification: .valueChanged
        )
    }

    func refreshVoiceTranslateShortcutStatus() {
        guard !voiceTranslateShortcutCaptureButton.isCapturing else {
            return
        }
        let configured = settings.voiceTranslateShortcut
        let message: String
        let color: NSColor
        if settings.voiceShortcuts.contains(configured) {
            message = "与语音听写快捷键相同，请更换为不同组合以启用一键翻译"
            color = .systemOrange
        } else {
            switch VoiceHotKeyManager.shared.translateRegistrationStatus {
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
                    message =
                        "已注册 \(shortcut.displayName)（目标语言：\(settings.voiceTranslateTargetLanguage.shortName)）"
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
            }
        }
        guard voiceTranslateShortcutStatusLabel.stringValue != message
                || voiceTranslateShortcutStatusLabel.textColor != color
        else {
            return
        }
        voiceTranslateShortcutStatusLabel.stringValue = message
        voiceTranslateShortcutStatusLabel.textColor = color
        voiceTranslateShortcutStatusLabel.setAccessibilityValue(message)
        NSAccessibility.post(
            element: voiceTranslateShortcutStatusLabel,
            notification: .valueChanged
        )
    }

    // MARK: - 顶部状态条

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
        updateSettingsActionBanner(for: status)
    }

    /// 顶部状态条按“操作提示”工作：进行中常驻，成功/失败到时自动收起，
    /// 空闲时完全不占高度，标签页始终拿到全部空间。
    func updateSettingsActionBanner(for status: SettingsActionStatus) {
        settingsActionStatusHideWorkItem?.cancel()
        settingsActionStatusHideWorkItem = nil
        switch status.kind {
        case .ready:
            setSettingsActionBannerVisible(false)
        case .working:
            setSettingsActionBannerVisible(true)
        case .success, .failure:
            setSettingsActionBannerVisible(true)
            let delay = status.kind == .failure
                ? SettingsLayout.actionBannerFailureDismissSeconds
                : SettingsLayout.actionBannerSuccessDismissSeconds
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.setSettingsActionBannerVisible(false)
                }
            }
            settingsActionStatusHideWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay,
                execute: work
            )
        }
    }

    func setSettingsActionBannerVisible(_ visible: Bool) {
        let wasHidden = settingsActionStatusLabel.isHidden
        settingsActionStatusLabel.isHidden = !visible
        guard visible, wasHidden, window.isVisible else {
            return
        }
        // 首次出现时增高窗口，避免挤压缩小标签页；之后隐藏时空间让给标签页。
        let bannerHeight = max(
            ceil(settingsActionStatusLabel.fittingSize.height),
            16
        ) + rootStack.spacing
        var frame = window.frame
        frame.size.height += bannerHeight
        frame.origin.y -= bannerHeight
        if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.y = max(frame.origin.y, visibleFrame.minY)
        }
        window.setFrame(frame, display: true)
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
