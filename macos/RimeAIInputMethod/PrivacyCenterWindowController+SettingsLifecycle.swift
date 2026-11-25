import AppKit

/// 机械拆分自 PrivacyCenterWindowController.swift（纯代码搬移，行为不变）。
extension PrivacyCenterWindowController {
    /// 提交一轮运行态收敛。状态机（generation、按序队列、失败收集）位于
    /// `ServiceLifecycleCoordinator`；这里只保留 UI 事件翻译与偏好回写。
    func reconcileRuntime(
        _ transition: SettingsRuntimeTransition,
        operation: String,
        initialFailure: (service: String, error: String)? = nil
    ) {
        lifecycleCoordinator.reconcile(
            transition.orderedOperations.map(Self.lifecycleOperation),
            description: operation,
            initialFailures: initialFailure.map {
                [ServiceLifecycleFailure(
                    service: $0.service,
                    error: $0.error
                )]
            } ?? []
        )
    }

    static func lifecycleOperation(
        _ operation: SettingsRuntimeOperation
    ) -> ServiceLifecycleOperation {
        switch operation {
        case let .daemon(enabled):
            return .daemon(enabled)
        case let .cloudBroker(enabled):
            return .cloudBroker(enabled)
        case let .voiceHelper(enabled):
            return .voiceHelper(enabled)
        }
    }

    static func settingsRuntimeOperation(
        _ operation: ServiceLifecycleOperation
    ) -> SettingsRuntimeOperation {
        switch operation {
        case let .daemon(enabled):
            return .daemon(enabled)
        case let .cloudBroker(enabled):
            return .cloudBroker(enabled)
        case let .voiceHelper(enabled):
            return .voiceHelper(enabled)
        }
    }

    func handleLifecycleEvent(_ event: ServiceLifecycleEvent) {
        switch event {
        case .busy:
            updateSettingsActionStatus(
                .working,
                "另一个生命周期操作仍在进行，请稍后重试"
            )
        case let .alreadyConsistent(description):
            setRuntimeSyncInProgress(false)
            updateSettingsActionStatus(
                .success,
                "\(description)；认证运行态与期望状态一致"
            )
        case let .started(description, services):
            setRuntimeSyncInProgress(true)
            updateSettingsActionStatus(
                .working,
                "\(description)；正在同步\(services.joined(separator: "、"))"
            )
        case let .succeeded(description, appliedOperations):
            setRuntimeSyncInProgress(false)
            let completionDescription: String
            if appliedOperations.count == 1,
               let onlyOperation = appliedOperations.first
            {
                completionDescription = SettingsRuntimeStatusCopy.applied(
                    Self.settingsRuntimeOperation(onlyOperation)
                )
            } else {
                completionDescription =
                    "生命周期操作已完成；服务状态继续刷新"
                    + "（以各服务状态为准）"
            }
            updateSettingsActionStatus(
                .success,
                "\(description)；\(completionDescription)"
            )
        case let .failed(description, failures):
            setRuntimeSyncInProgress(false)
            let services = failures.map(\.service)
            updateSettingsActionStatus(
                .failure,
                "\(description)；"
                    + "\(services.joined(separator: "、"))"
                    + " 未能收敛，失败项目已保持或回退为关闭偏好"
            )
            presentRuntimeSyncFailure(failures)
        }
    }

    func performLifecycleOperation(
        _ operation: ServiceLifecycleOperation,
        completion: @escaping ServiceLifecycleCompletion
    ) {
        switch operation {
        case let .daemon(enabled):
            setManagedDaemonEnabled(enabled, completion: completion)
        case let .cloudBroker(enabled):
            setManagedCloudBrokerEnabled(enabled, completion: completion)
        case let .voiceHelper(enabled):
            guard !enabled || settings.aiEnabled else {
                settings.voiceEnabled = false
                let error = NSError(
                    domain: "fun.wwcn.inputmethod.RimeAI.settings-runtime",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "AI 总开关关闭时不能启用语音 helper。",
                    ]
                )
                setManagedVoiceEnabled(false) { _ in
                    completion(.failure(error))
                }
                return
            }
            setManagedVoiceEnabled(enabled, completion: completion)
        }
    }

    func setRuntimeSyncInProgress(_ inProgress: Bool) {
        lifecycleCoordinator.setReconciling(inProgress)
        importSettingsButton.isEnabled = !inProgress
        restoreDefaultSettingsButton.isEnabled = !inProgress
        aiToggle.isEnabled = !inProgress
        voiceToggle.isEnabled = !inProgress && settings.aiEnabled
    }

    func rejectLifecycleActionDuringRuntimeSync(
        _ action: String
    ) -> Bool {
        guard lifecycleCoordinator.isReconciling else {
            return false
        }
        updateSettingsActionStatus(
            .working,
            "运行状态仍在同步，请稍后再\(action)"
        )
        return true
    }

    func presentRuntimeSyncFailure(
        _ failures: [ServiceLifecycleFailure]
    ) {
        let details = failures.map {
            "\($0.service)：\($0.error)"
        }.joined(separator: "\n")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "设置已更新，但操作未完全完成"
        alert.informativeText = details
            + "\n相关偏好已保持或回退为关闭；"
            + "其他服务的生命周期操作已完成，连接状态请见状态页。"
        alert.beginSheetModal(for: window)
    }


    @objc func clearAllProductData(_ sender: Any?) {
        guard !rejectLifecycleActionDuringRuntimeSync("清除本地制品") else {
            return
        }
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
            guard response == .alertFirstButtonReturn,
                  let self
            else {
                return
            }
            guard !self.rejectLifecycleActionDuringRuntimeSync("清除本地制品")
            else {
                return
            }
            self.disableAIAndTrashManagedData()
        }
    }

    func disableAIAndTrashManagedData() {
        setRuntimeSyncInProgress(true)
        updateSettingsActionStatus(
            .working,
            "正在停用服务并清除本地制品"
        )
        DaemonClient.shared.disconnect()
        CloudBrokerClient.shared.disconnect()
        settings.cloudConfigured = false
        settings.voiceEnabled = false
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
                // 语音历史同样先清空再关闭：之后的页面刷新不会悄悄重建一个空库。
                try self.voiceHistoryService.clearAll()
                try VoiceHelperLifecycleCoordinator.shared
                    .suspendSynchronously(layout: layout)
                try ServiceLifecycleCoordinator
                    .stopManagedCloudBroker(layout: layout)
                try ServiceLifecycleCoordinator
                    .stopManagedDaemon(layout: layout)
                try Self.trashManagedData(layout: layout)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setRuntimeSyncInProgress(false)
                switch result {
                case .success:
                    self.settings.resetAllProductData()
                    self.settings.aiEnabled = false
                    self.daemonStatusLabel.stringValue =
                        "Daemon：停用期望状态已应用 · 连接状态继续刷新"
                    self.modelLabel.stringValue = "模型制品：已移到废纸篓"
                    self.artifactLabel.stringValue =
                        "重新安装开发者预览版后可恢复本地 AI。"
                    self.refresh()
                    self.updateSettingsActionStatus(
                        .success,
                        "停用生命周期与本地制品清理已完成；"
                            + "服务状态继续刷新（以状态页为准）"
                    )
                case let .failure(error):
                    self.presentError(
                        error,
                        message: "未能完整清除 RimeAI 本地制品",
                        information: "部分项目可能已经移到废纸篓；"
                            + "Rime 用户词典未被修改。"
                    )
                }
            }
        }
    }


    func setManagedDaemonEnabled(
        _ enabled: Bool,
        completion: @escaping SettingsRuntimeCompletion
    ) {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        daemonStatusLabel.stringValue =
            enabled ? "Daemon：正在启动" : "Daemon：正在停止"
        if enabled {
            // Socket nodes and status notifications can outlive the client
            // generation that produced them. Invalidate that generation before
            // starting the lifecycle transaction so only the new hello can
            // prove readiness for this enable request.
            DaemonClient.shared.invalidateCurrentGeneration { [weak self] in
                guard let self else {
                    return
                }
                self.startManagedDaemonAndAwaitReadiness(
                    layout: layout,
                    completion: completion
                )
            }
            return
        }

        SettingsDaemonActivationFailurePolicy.apply(to: settings)
        DaemonClient.shared.disconnect()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try ServiceLifecycleCoordinator
                    .suspendManagedDaemon(layout: layout)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                switch result {
                case .success:
                    self.daemonStatusLabel.stringValue =
                        "Daemon：停用期望状态已应用 · 连接状态继续刷新"
                    completion(.success(()))
                case let .failure(error):
                    // 执行态可能尚待人工重试，但持久化真值必须
                    // fail closed：下次启动不会再启用 daemon/voice。
                    SettingsDaemonActivationFailurePolicy.apply(
                        to: self.settings
                    )
                    DaemonClient.shared.disconnect()
                    self.daemonStatusLabel.stringValue =
                        "Daemon：关闭未完整完成 · 运行态不确定"
                    completion(.failure(error))
                }
            }
        }
    }

    func startManagedDaemonAndAwaitReadiness(
        layout: RimeAIProductDataLayout,
        completion: @escaping SettingsRuntimeCompletion
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try ServiceLifecycleCoordinator
                    .startManagedDaemon(layout: layout)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                switch result {
                case .success:
                    self.daemonStatusLabel.stringValue =
                        "Daemon：正在验证本代协议握手"
                    DaemonClient.shared.connectWhenReady { [weak self] result in
                        guard let self else {
                            return
                        }
                        switch result {
                        case .success:
                            self.daemonStatusLabel.stringValue =
                                "Daemon：本代协议握手就绪"
                            completion(.success(()))
                        case let .failure(error):
                            self.rollbackManagedDaemonActivation(
                                readinessError: error,
                                layout: layout,
                                completion: completion
                            )
                        }
                    }
                case let .failure(error):
                    SettingsDaemonActivationFailurePolicy.apply(
                        to: self.settings
                    )
                    DaemonClient.shared.disconnect()
                    self.daemonStatusLabel.stringValue =
                        error is ServiceDaemonDeactivationError
                            ? "Daemon：启动回滚未完整完成 · 运行态不确定"
                            : "Daemon：生命周期操作失败"
                    completion(.failure(error))
                }
            }
        }
    }

    func rollbackManagedDaemonActivation(
        readinessError: Error,
        layout: RimeAIProductDataLayout,
        completion: @escaping SettingsRuntimeCompletion
    ) {
        SettingsDaemonActivationFailurePolicy.apply(to: settings)
        DaemonClient.shared.disconnect()
        daemonStatusLabel.stringValue = "Daemon：握手失败，正在回滚"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let completionError =
                SettingsDaemonActivationFailurePolicy.rollbackError(
                    readinessError: readinessError,
                    performRollback: {
                        try ServiceLifecycleCoordinator
                            .suspendManagedDaemon(layout: layout)
                    }
                )
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.daemonStatusLabel.stringValue =
                    "Daemon：握手失败，关闭偏好已回退"
                completion(.failure(completionError))
            }
        }
    }

    func setManagedCloudBrokerEnabled(
        _ enabled: Bool,
        completion: @escaping SettingsRuntimeCompletion
    ) {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        if !enabled {
            settings.cloudConfigured = false
            CloudBrokerClient.shared.disconnect()
        }
        cloudStatusLabel.stringValue = enabled
            ? "云增强：正在启动"
            : "云增强：正在停止"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                if enabled {
                    try ServiceLifecycleCoordinator
                        .startManagedCloudBroker(layout: layout)
                } else {
                    try ServiceLifecycleCoordinator
                        .suspendManagedCloudBroker(layout: layout)
                }
            }
            DispatchQueue.main.async { [weak self] in
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
                    completion(.success(()))
                case let .failure(error):
                    if enabled {
                        self.settings.cloudConfigured = false
                        CloudBrokerClient.shared.disconnect()
                    } else {
                        // 无论 suspend 是否成功，都不允许失败把下次
                        // 启动的偏好重新拉回开启。
                        self.settings.cloudConfigured = false
                        CloudBrokerClient.shared.disconnect()
                    }
                    completion(.failure(error))
                }
            }
        }
    }

    func setManagedVoiceEnabled(
        _ enabled: Bool,
        completion: @escaping SettingsRuntimeCompletion
    ) {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        voiceStatusLabel.stringValue = enabled
            ? "语音：正在启动本地 helper"
            : "语音：正在停止"
        VoiceHelperLifecycleCoordinator.shared.setDesired(
            enabled,
            layout: layout
        ) { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .success:
                self.settings.voiceEnabled = enabled
                if enabled {
                    NotificationCenter.default.post(
                        name: .rimeAIVoiceRetryRequested,
                        object: self.settings
                    )
                }
                self.refresh()
                completion(.success(()))
            case let .failure(error):
                self.settings.voiceEnabled = false
                self.voiceToggle.state = .off
                self.refreshVoiceStatus()
                completion(.failure(error))
            }
            // helper 启用/停用完成：服务状态徽标实时刷新。
            VoiceServiceStateNotifier.postServiceStateDidChange()
        }
    }

    /// 语音服务状态：彩色状态点 + 文字 +（语音组件未安装时的）安装指引，
    /// 以及按需出现、带徽标的权限按钮。
    func refreshVoiceStatus() {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let presentation = VoiceServiceStatusPresentation.make(
            aiEnabled: settings.aiEnabled,
            voiceEnabled: settings.voiceEnabled,
            installationStatus: VoiceHelperLifecycle.installationStatus(layout: layout)
        )
        applyVoiceServiceStatus(presentation)
        refreshVoicePermissionButtons()
    }

    func applyVoiceServiceStatus(_ presentation: VoiceServiceStatusPresentation) {
        voiceStatusLabel.stringValue = presentation.message
        voiceStatusLabel.setAccessibilityValue(presentation.message)
        voiceServiceStatusDot.layer?.backgroundColor = presentation.dotColor.cgColor
        voiceServiceStatusDot.setAccessibilityValue(presentation.message)
        voiceInstallHintLabel.stringValue = presentation.installHint ?? ""
        voiceInstallHintLabel.isHidden = presentation.installHint == nil
    }

    /// 麦克风/语音识别授权属于 Voice Helper 进程，输入法无法预读：仅在
    /// helper 明确拒绝后才加 ⚠︎ 徽标。辅助功能按钮只在有功能依赖它时出现。
    func refreshVoicePermissionButtons() {
        let permissionBlocked = VoiceDictationRuntime.shared.isPermissionBlocked
        voiceMicrophonePermissionButton.title = VoicePermissionPresentation.badge(
            "打开麦克风权限…",
            needsAttention: VoicePermissionPresentation.microphoneNeedsAttention(
                permissionBlocked: permissionBlocked
            )
        )
        voiceSpeechPermissionButton.title = VoicePermissionPresentation.badge(
            "打开语音识别权限…",
            needsAttention: VoicePermissionPresentation.microphoneNeedsAttention(
                permissionBlocked: permissionBlocked
            )
        )
        let showsAccessibility = VoicePermissionPresentation.showsAccessibilityButton(
            autoPasteEnabled: settings.voiceAutoPasteEnabled,
            axFallbackReadEnabled: settings.voiceAXFallbackReadEnabled
        )
        voiceAccessibilityPermissionButton.isHidden = !showsAccessibility
        voiceAccessibilityPermissionButton.title = VoicePermissionPresentation.badge(
            "打开辅助功能权限…",
            needsAttention: !VoiceAccessibilityAuthorization.isTrusted
        )
    }

    nonisolated static func trashManagedData(
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

    func splitApplications(_ value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    func reconcileCloudConfiguration() {
        settings.reconcileCloudConfiguration(
            hasCredential: try? credentialStore.containsAPIKey()
        )
    }
}
