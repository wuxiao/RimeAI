import AppKit
import InputMethodKit

/// 输入法菜单、偏好切换动作与设置变更观察。
extension RimeAIInputController {
    nonisolated func makeInputMethodMenu() -> NSMenu {
        let preferences = RimeAISettingsStore.shared.inputPreferences
        let menu = NSMenu(title: "RimeAI")
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
        let voiceItem = NSMenuItem(
            title: RimeAISettingsStore.shared.voiceEnabled
                ? "语音听写已开启（按住 \(VoiceHotKeyManager.displayShortcut)）"
                : "设置语音听写…",
            action: #selector(showPrivacyCenter(_:)),
            keyEquivalent: ""
        )
        voiceItem.target = self
        menu.addItem(voiceItem)
        let settingsItem = NSMenuItem(
            title: "RimeAI 设置…",
            action: #selector(showPrivacyCenter(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        return menu
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
