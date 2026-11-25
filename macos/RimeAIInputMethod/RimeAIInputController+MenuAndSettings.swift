import AppKit
import InputMethodKit

/// 输入法菜单、偏好切换动作与设置变更观察。
extension RimeAIInputController {
    nonisolated func makeInputMethodMenu() -> NSMenu {
        let menu = NSMenu(title: "RimeAI")
        appendInputPreferenceItems(to: menu)
        menu.addItem(.separator())
        appendVoiceMenuItems(to: menu)
        // 不得给 IMK 菜单项设置 keyEquivalent：输入法菜单的按键等效项
        // 是系统级匹配，会抢占宿主应用自身的 ⌘，(Settings) 等快捷键。
        let settingsItem = NSMenuItem(
            title: "RimeAI 设置…",
            action: #selector(showPrivacyCenter(_:)),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        return menu
    }

    /// 字形、字符宽度、标点与续写联想：带勾选状态的偏好开关。
    private nonisolated func appendInputPreferenceItems(to menu: NSMenu) {
        let preferences = RimeAISettingsStore.shared.inputPreferences
        menu.addItem(preferenceMenuItem(
            title: "简体中文",
            action: #selector(useSimplifiedChinese(_:)),
            selected: preferences.characterSet == .simplified
        ))
        menu.addItem(preferenceMenuItem(
            title: "繁体中文",
            action: #selector(useTraditionalChinese(_:)),
            selected: preferences.characterSet == .traditional
        ))
        menu.addItem(.separator())
        menu.addItem(preferenceMenuItem(
            title: "半角字符",
            action: #selector(useHalfWidth(_:)),
            selected: preferences.characterWidth == .half
        ))
        menu.addItem(preferenceMenuItem(
            title: "全角字符",
            action: #selector(useFullWidth(_:)),
            selected: preferences.characterWidth == .full
        ))
        menu.addItem(.separator())
        menu.addItem(preferenceMenuItem(
            title: "中文标点（，。）",
            action: #selector(useChinesePunctuation(_:)),
            selected: preferences.punctuationStyle == .chinese
        ))
        menu.addItem(preferenceMenuItem(
            title: "西文标点（,.）",
            action: #selector(useWesternPunctuation(_:)),
            selected: preferences.punctuationStyle == .western
        ))
        menu.addItem(.separator())
        menu.addItem(preferenceMenuItem(
            title: "上屏后续写联想",
            action: #selector(toggleContinuationSuggestion(_:)),
            selected: RimeAISettingsStore.shared.continuationSuggestionEnabled
        ))
    }

    /// 语音：顶层只保留一个简洁的“语音听写设置…”入口，快捷开关收进子菜单，
    /// 不再在顶层堆一行超长的状态文案。
    private nonisolated func appendVoiceMenuItems(to menu: NSMenu) {
        let voiceSettings = RimeAISettingsStore.shared
        let voiceItem = NSMenuItem(
            title: "语音听写设置…",
            action: #selector(showVoiceSettings(_:)),
            keyEquivalent: ""
        )
        voiceItem.target = self
        voiceItem.setAccessibilityLabel(
            voiceSettings.voiceEnabled
                ? "语音听写设置，当前快捷键 \(VoiceHotKeyManager.displayShortcut)"
                : "语音听写设置，语音听写未开启"
        )
        if voiceSettings.voiceEnabled {
            let voiceSubmenu = NSMenu(title: "语音快捷开关")
            voiceSubmenu.addItem(preferenceMenuItem(
                title: "语音智能润色（\(voiceSettings.voicePolishStyle.shortName)）",
                action: #selector(toggleVoiceSmartPolish(_:)),
                selected: voiceSettings.voiceSmartPolishEnabled
            ))
            voiceSubmenu.addItem(preferenceMenuItem(
                title: "语音完成后自动粘贴",
                action: #selector(toggleVoiceAutoPaste(_:)),
                selected: voiceSettings.voiceAutoPasteEnabled
            ))
            voiceSubmenu.addItem(preferenceMenuItem(
                title: "语音输入时自动静音",
                action: #selector(toggleVoiceMuteSystemAudio(_:)),
                selected: voiceSettings.voiceMuteSystemAudioEnabled
            ))
            voiceItem.submenu = voiceSubmenu
        }
        menu.addItem(voiceItem)

        let voiceHistoryItem = NSMenuItem(
            title: "语音历史…",
            action: #selector(showVoiceHistoryAndStats(_:)),
            keyEquivalent: ""
        )
        voiceHistoryItem.target = self
        menu.addItem(voiceHistoryItem)
    }

    private nonisolated func preferenceMenuItem(
        title: String,
        action: Selector,
        selected: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        item.state = selected ? .on : .off
        return item
    }

    @objc private func useSimplifiedChinese(_ sender: Any?) {
        MainActor.assumeIsolated {
            settings.characterSet = .simplified
        }
    }

    @objc private func useTraditionalChinese(_ sender: Any?) {
        MainActor.assumeIsolated {
            settings.characterSet = .traditional
        }
    }

    @objc private func useHalfWidth(_ sender: Any?) {
        MainActor.assumeIsolated {
            settings.characterWidth = .half
        }
    }

    @objc private func useFullWidth(_ sender: Any?) {
        MainActor.assumeIsolated {
            settings.characterWidth = .full
        }
    }

    @objc private func useChinesePunctuation(_ sender: Any?) {
        MainActor.assumeIsolated {
            settings.punctuationStyle = .chinese
        }
    }

    @objc private func useWesternPunctuation(_ sender: Any?) {
        MainActor.assumeIsolated {
            settings.punctuationStyle = .western
        }
    }

    @objc private func showPrivacyCenter(_ sender: Any?) {
        MainActor.assumeIsolated {
            PrivacyCenterWindowController.shared.showWindow()
        }
    }

    @objc private func showVoiceSettings(_ sender: Any?) {
        MainActor.assumeIsolated {
            PrivacyCenterWindowController.shared.showWindow(
                selectingTab: PrivacyCenterWindowController.TabIdentifier.voice
            )
        }
    }

    @objc private func showVoiceHistoryAndStats(_ sender: Any?) {
        MainActor.assumeIsolated {
            PrivacyCenterWindowController.shared.showWindow(
                selectingTab: PrivacyCenterWindowController.TabIdentifier.voiceHistory
            )
        }
    }

    @objc private func toggleVoiceSmartPolish(_ sender: Any?) {
        MainActor.assumeIsolated {
            settings.voiceSmartPolishEnabled = !settings.voiceSmartPolishEnabled
        }
    }

    @objc private func toggleVoiceAutoPaste(_ sender: Any?) {
        MainActor.assumeIsolated {
            settings.voiceAutoPasteEnabled = !settings.voiceAutoPasteEnabled
        }
    }

    @objc private func toggleVoiceMuteSystemAudio(_ sender: Any?) {
        MainActor.assumeIsolated {
            settings.voiceMuteSystemAudioEnabled =
                !settings.voiceMuteSystemAudioEnabled
        }
    }

    @objc private func toggleContinuationSuggestion(_ sender: Any?) {
        MainActor.assumeIsolated {
            settings.continuationSuggestionEnabled =
                !settings.continuationSuggestionEnabled
        }
    }

    func observeSettings() {
        let settingsObserver = NotificationCenter.default.addObserver(
            forName: .rimeAISettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyChangedSettings()
            }
        }
        let clearObserver = NotificationCenter.default.addObserver(
            forName: .rimeAIClearEphemeralData,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearEphemeralData()
            }
        }
        settingsObservers = [
            settingsObserver,
            clearObserver,
        ]
    }

    func applyChangedSettings() {
        RimeEngine.shared.apply(settings.inputPreferences)
        if !settings.voiceEnabled {
            cancelVoiceDictation()
        }
        if !settings.continuationSuggestionEnabled {
            continuationCoordinator.cancel(.deactivated)
            continuationAnchorRect = nil
        }
        if let currentBundleIdentifier {
            voiceHotwordAdmission.updatePolicy(
                voiceHotwordPolicy(for: currentBundleIdentifier)
            )
        } else {
            voiceHotwordAdmission.deactivate()
        }
        configureVoiceHotKey()
        if let client = activeClientObject as? any IMKTextInput,
           !composition.pinyin.isEmpty
        {
            compositionInput(composition.pinyin, client: client)
        }
        guard let currentBundleIdentifier else {
            return
        }
        if !settings.isAIAllowed(for: currentBundleIdentifier)
            || settings.contextPolicy(for: currentBundleIdentifier) == .strict
        {
            invalidateCurrentResult()
            Self.contextStore.deactivate()
        }
        if settings.contextPolicy(for: currentBundleIdentifier) == .strict {
            cancelVoiceDictation()
        }
        if !settings.isAIAllowed(for: currentBundleIdentifier) {
            cancelVoiceDictation()
            configureVoiceHotKey()
            DaemonClient.shared.disconnect()
        }
        if !settings.cloudConfigured {
            if pipeline.hasPendingCloudRequest {
                invalidateCurrentResult()
            }
            CloudBrokerClient.shared.disconnect()
        }
    }

    func clearEphemeralData() {
        cancelVoiceDictation()
        voiceHotwordAdmission.clear()
        phrasebookEnglishTokensGeneration &+= 1
        phrasebookEnglishTokens = []
        phrasebookEnglishTokensLoaded = false
        phrasebookEnglishTokensLoading = false
        invalidateCurrentResult()
        clearContextForCurrentApplication()
    }

    func clearContextForCurrentApplication() {
        Self.contextStore.deactivate()
        if activeClientObject != nil, let currentBundleIdentifier {
            Self.contextStore.activate(
                sessionID: currentBundleIdentifier,
                ownerID: sessionNonce
            )
        }
    }
}
