import AppKit
import Carbon
import InputMethodKit

/// 语音听写：快捷键路由修饰键映射、会话启动/结束/取消、热键注册、
/// 热词准入与 VoiceDictationRuntimeOwner 协议实现。
extension RimeAIInputController {
    func isVoiceShortcut(_ event: NSEvent) -> Bool {
        return VoiceDictationKeyRouter.isExactVoiceShortcut(
            keyCode: event.keyCode,
            modifiers: voiceKeyModifiers(event.modifierFlags),
            shortcut: settings.voiceShortcut
        )
    }

    func voiceKeyModifiers(
        _ modifiers: NSEvent.ModifierFlags
    ) -> VoiceDictationKeyModifiers {
        let semantic = modifiers.intersection(.deviceIndependentFlagsMask)
        var result: VoiceDictationKeyModifiers = []
        let mapping: [(NSEvent.ModifierFlags, VoiceDictationKeyModifiers)] = [
            (.capsLock, .capsLock),
            (.shift, .shift),
            (.control, .control),
            (.option, .option),
            (.command, .command),
            (.numericPad, .numericPad),
            (.help, .help),
            (.function, .function),
        ]
        for (appKitFlag, voiceFlag) in mapping
        where semantic.contains(appKitFlag) {
            result.insert(voiceFlag)
        }
        return result
    }

    func startVoiceDictation(
        client: any IMKTextInput
    ) -> Bool {
        let bundleIdentifier = client.bundleIdentifier()
            ?? "unknown-client"
        guard canStartVoiceDictation(client: client),
              let clientObject = activeClientObject
        else {
            configureVoiceHotKey()
            return false
        }
        let selection = client.selectedRange()
        guard selection.location != NSNotFound else {
            settings.record(.voiceFailure)
            return false
        }
        guard let anchor = voiceCaretRect(
            client: client,
            characterIndex: selection.location
        ) else {
            // 语音最终会直接上屏；拿不到由宿主返回的真实 caret 时必须
            // fail closed，不能沿用候选窗的鼠标位置回退。
            settings.record(.voiceFailure)
            return false
        }
        candidatePanel.hide()
        let started = VoiceDictationRuntime.shared.start(
            owner: self,
            client: clientObject,
            context: VoiceDictationSessionContext(
                compositionID: UUID(),
                appSessionID: applicationSessionID(for: client),
                bundleID: bundleIdentifier,
                hotwordSnapshot: voiceHotwordSnapshot(for: client)
            ),
            selection: selection,
            anchorRect: anchor
        )
        return started
    }

    func voiceHotwordSession(
        for client: any IMKTextInput
    ) -> VoiceHotwordAdmissionSession {
        VoiceHotwordAdmissionSession(
            applicationIdentifier: client.bundleIdentifier()
                ?? "unknown-client",
            controllerSessionIdentifier: sessionNonce,
            focusEpoch: hostFocusEpoch
        )
    }

    func voiceHotwordPolicy(
        for bundleIdentifier: String
    ) -> VoiceHotwordAdmissionPolicy {
        VoiceHotwordAdmissionPolicy(
            isVoiceEnabled: settings.voiceEnabled,
            isAIAllowed: settings.isAIAllowed(for: bundleIdentifier),
            isHotwordAssistEnabled: settings.voiceRimeHotwordsEnabled,
            contextPolicy: settings.contextPolicy(for: bundleIdentifier),
            isSecureInput: composition.isSecureInput
                || IsSecureEventInputEnabled()
        )
    }

    func voiceHotwordSnapshot(
        for client: any IMKTextInput
    ) -> VoiceHotwordSnapshot {
        let bundleIdentifier = client.bundleIdentifier() ?? "unknown-client"
        let session = voiceHotwordSession(for: client)
        voiceHotwordAdmission.activate(
            session: session,
            policy: voiceHotwordPolicy(for: bundleIdentifier)
        )
        return voiceHotwordAdmission.snapshot(session: session)
    }

    func recordVoiceHotwordFromRimeCommit(
        _ committedText: String?,
        matching expectedText: String? = nil,
        client: any IMKTextInput
    ) {
        guard !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            enterSecureInput(client: client)
            return
        }
        let bundleIdentifier = client.bundleIdentifier() ?? "unknown-client"
        let session = voiceHotwordSession(for: client)
        voiceHotwordAdmission.activate(
            session: session,
            policy: voiceHotwordPolicy(for: bundleIdentifier)
        )
        voiceHotwordAdmission.recordRimeCommitResult(
            committedText,
            matching: expectedText,
            session: session
        )
    }

    func canStartVoiceDictation(
        client: any IMKTextInput
    ) -> Bool {
        let bundleIdentifier = client.bundleIdentifier()
            ?? "unknown-client"
        return settings.voiceEnabled
            && isHostActive
            && settings.isAIAllowed(for: bundleIdentifier)
            && !composition.hasComposition
            && client.markedRange().location == NSNotFound
            && !composition.isSecureInput
            && !IsSecureEventInputEnabled()
    }

    func finishVoiceDictation() {
        VoiceDictationRuntime.shared.stop(owner: self)
    }

    func cancelVoiceDictation() {
        VoiceDictationRuntime.shared.cancel(owner: self)
    }

    func configureVoiceHotKey() {
        let runtime = VoiceDictationRuntime.shared
        if IsSecureEventInputEnabled() {
            // 覆盖 Carbon 轮询 tick 之间刚进入 Secure Input 的窗口，并
            // 记录本 controller 的安全态，以便后续真实键事件恢复注册。
            enterSecureInputIfPossible()
            return
        }
        let activeInputClient = activeClientObject as? any IMKTextInput
        let bundleIdentifier = currentBundleIdentifier
            ?? activeInputClient?.bundleIdentifier()
            ?? "unknown-client"
        let canRegister = isHostActive
            && activeInputClient != nil
            && settings.voiceEnabled
            && settings.isAIAllowed(for: bundleIdentifier)
            && composition.pinyin.isEmpty
            && activeInputClient?.markedRange().location == NSNotFound
            && !composition.isSecureInput
            && runtime.canRegisterHotKey
        guard canRegister else {
            VoiceHotKeyManager.shared.deactivate(owner: self)
            voiceHotKeyIsRegistered = false
            return
        }
        do {
            try VoiceHotKeyManager.shared.activate(
                owner: self,
                shortcut: settings.voiceShortcut,
                onPressed: { [weak self] in
                    guard let self,
                          let client = self.activeClientObject
                            as? any IMKTextInput
                    else {
                        return
                    }
                    if !VoiceDictationRuntime.shared.isActive(owner: self) {
                        _ = self.startVoiceDictation(client: client)
                    }
                },
                onReleased: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.finishVoiceDictation()
                },
                onSecureInputDetected: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.voiceHotKeyIsRegistered = false
                    self.enterSecureInputIfPossible()
                }
            )
            voiceHotKeyIsRegistered = true
            voiceHotKeyRegistrationFailed = false
        } catch {
            voiceHotKeyIsRegistered = false
            if !voiceHotKeyRegistrationFailed {
                settings.record(.voiceFailure)
            }
            voiceHotKeyRegistrationFailed = true
        }
    }
}

// MARK: - VoiceDictationRuntimeOwner

extension RimeAIInputController {
    func voiceRuntimeTargetIsValid(
        client: AnyObject,
        appSessionID: String,
        selection: NSRange,
        anchorRect: NSRect
    ) -> Bool {
        guard activeClientObject === client,
              let inputClient = client as? any IMKTextInput,
              applicationSessionID(for: inputClient) == appSessionID,
              currentBundleIdentifier
                == (inputClient.bundleIdentifier() ?? "unknown-client"),
              !composition.hasComposition,
              inputClient.markedRange().location == NSNotFound,
              !composition.isSecureInput,
              !IsSecureEventInputEnabled(),
              inputClient.selectedRange() == selection
        else {
            return false
        }
        guard let currentAnchor = voiceCaretRect(
            client: inputClient,
            characterIndex: selection.location
        ) else {
            return false
        }
        return voiceRectsMatch(anchorRect, currentAnchor)
    }

    func voiceRuntimeCommit(
        _ text: String,
        client: AnyObject,
        appSessionID: String,
        selection: NSRange,
        anchorRect: NSRect
    ) -> Bool {
        guard voiceRuntimeTargetIsValid(
            client: client,
            appSessionID: appSessionID,
            selection: selection,
            anchorRect: anchorRect
        ),
        let inputClient = client as? any IMKTextInput,
        !text.isEmpty,
        text.count <= VoiceDictationConstants.maximumTextCharacters,
        !text.contains("\n"),
        !text.contains("\r")
        else {
            return false
        }

        inputClient.insertText(text, replacementRange: notFoundRange)
        if let currentBundleIdentifier,
           settings.isAIAllowed(for: currentBundleIdentifier),
           settings.contextPolicy(for: currentBundleIdentifier) != .strict
        {
            // 只进入易失的当前应用上下文；语音文本不写入长期历史。
            Self.contextStore.appendCommittedText(text)
        } else {
            Self.contextStore.deactivate()
        }
        return true
    }

    func voiceRuntimeDidBecomeUnavailable() {
        VoiceHotKeyManager.shared.deactivate(owner: self)
        voiceHotKeyIsRegistered = false
    }

    func voiceRuntimeDidBecomeAvailable() {
        voiceHotKeyRegistrationFailed = false
        configureVoiceHotKey()
    }

    func voiceRuntimeSecureInputDetected() {
        enterSecureInputIfPossible()
    }

    func voiceRectsMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        let tolerance: CGFloat = 1
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
