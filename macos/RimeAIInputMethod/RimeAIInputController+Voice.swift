import AppKit
import Carbon
import InputMethodKit

/// 语音听写：快捷键路由修饰键映射、会话启动/结束/取消、热键注册、
/// 热词准入与 VoiceDictationRuntimeOwner 协议实现。
extension RimeAIInputController {
    func isVoiceShortcut(_ event: NSEvent) -> Bool {
        let modifiers = voiceKeyModifiers(event.modifierFlags)
        if settings.voiceShortcuts.contains(where: {
            VoiceDictationKeyRouter.isExactVoiceShortcut(
                keyCode: event.keyCode,
                modifiers: modifiers,
                shortcut: $0
            )
        }) {
            return true
        }
        if voiceTranslateHotKeyIsRegistered,
           VoiceDictationKeyRouter.isExactVoiceShortcut(
               keyCode: event.keyCode,
               modifiers: modifiers,
               shortcut: settings.voiceTranslateShortcut
           )
        {
            return true
        }
        return false
    }

    func isRegisteredVoiceShortcut(_ event: NSEvent) -> Bool {
        let modifiers = voiceKeyModifiers(event.modifierFlags)
        if voiceHotKeyIsRegistered,
           VoiceDictationKeyRouter.isExactVoiceShortcut(
               keyCode: event.keyCode,
               modifiers: modifiers,
               shortcut: settings.voiceShortcut
           )
        {
            return true
        }
        if voiceSecondaryHotKeyIsRegistered,
           let secondary = settings.voiceSecondaryShortcut,
           VoiceDictationKeyRouter.isExactVoiceShortcut(
               keyCode: event.keyCode,
               modifiers: modifiers,
               shortcut: secondary
           )
        {
            return true
        }
        if voiceTranslateHotKeyIsRegistered,
           VoiceDictationKeyRouter.isExactVoiceShortcut(
               keyCode: event.keyCode,
               modifiers: modifiers,
               shortcut: settings.voiceTranslateShortcut
           )
        {
            return true
        }
        return false
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

    /// 当前无法启动语音听写的原因；nil 表示可以启动。
    func voiceStartBlocker(client: any IMKTextInput) -> VoiceDictationStartBlocker? {
        if let runtimeBlocker = VoiceDictationRuntime.shared.startBlocker {
            return runtimeBlocker
        }
        let bundleIdentifier = client.bundleIdentifier() ?? "unknown-client"
        return VoiceDictationStartGate.blocker(
            voiceEnabled: settings.voiceEnabled,
            aiAllowed: settings.isAIAllowed(for: bundleIdentifier),
            isHostActive: isHostActive,
            hasActiveComposition: composition.hasComposition
                || VoiceClientMarkedRangePolicy.hasMarkedText(client.markedRange()),
            isSecureInput: composition.isSecureInput || IsSecureEventInputEnabled()
        )
    }

    func canStartVoiceDictation(
        client: any IMKTextInput
    ) -> Bool {
        voiceStartBlocker(client: client) == nil
    }

    func startVoiceDictation(
        client: any IMKTextInput,
        intent: VoiceSessionIntent = .dictation
    ) -> Bool {
        let bundleIdentifier = client.bundleIdentifier()
            ?? "unknown-client"
        let runtime = VoiceDictationRuntime.shared
        // 被阻断（安全输入 / 应用已关闭 AI / 有未上屏拼音 / 服务停用 / 麦克风
        // 权限被拒）时给出明确原因，而不是静默无反应。
        if let blocker = voiceStartBlocker(client: client) {
            if blocker == .secureInput {
                settings.record(.privacyBlocked)
            }
            runtime.presentStartBlockedToast(
                blocker,
                anchorRect: fallbackVoiceAnchorRect()
            )
            configureVoiceHotKey()
            return false
        }
        guard let clientObject = activeClientObject else {
            configureVoiceHotKey()
            return false
        }
        VoicePostCommitEditTracker.shared.settleNowIfMatching(
            client: clientObject,
            reason: .nextDictation,
            bundleIdentifier: bundleIdentifier
        )
        let selection = client.selectedRange()
        let hasEditableSelection = selection.location != NSNotFound
        let caretAnchor = hasEditableSelection
            ? voiceCaretRect(
                client: client,
                characterIndex: selection.location
            )
            : nil
        let hasEditableTarget = hasEditableSelection && caretAnchor != nil
        let anchor = caretAnchor ?? fallbackVoiceAnchorRect()
        let isSecure = composition.isSecureInput || IsSecureEventInputEnabled()
        let domain = RimeAIPhraseBookService.shared.domain(
            forBundleIdentifier: bundleIdentifier
        )
        let recentContext = (!isSecure
            && settings.isAIAllowed(for: bundleIdentifier)
            && settings.contextPolicy(for: bundleIdentifier) != .strict)
            ? Self.contextStore.retainedContext(for: bundleIdentifier)
            : ""
        candidatePanel.hide()
        let started = runtime.start(
            owner: self,
            client: clientObject,
            context: VoiceDictationSessionContext(
                compositionID: UUID(),
                appSessionID: applicationSessionID(for: client),
                bundleID: bundleIdentifier,
                // 最终识别上限收紧为 10s（原沿用协议上限 30s）。
                deadlineMilliseconds: VoiceSessionTiming
                    .finalizationDeadlineMilliseconds,
                maximumDurationMilliseconds: VoiceDictationConstants
                    .unlimitedDurationMilliseconds,
                hotwordSnapshot: voiceHotwordSnapshot(for: client)
            ),
            selection: selection,
            anchorRect: anchor,
            hasEditableTarget: hasEditableTarget,
            intent: intent,
            domain: domain,
            recentContext: recentContext
        )
        return started
    }

    func fallbackVoiceAnchorRect() -> NSRect {
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y, width: 1, height: 20)
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
        let isSecure = composition.isSecureInput || IsSecureEventInputEnabled()
        guard settings.voiceEnabled,
              settings.isAIAllowed(for: bundleIdentifier),
              !isSecure
        else {
            return .empty
        }
        let session = voiceHotwordSession(for: client)
        voiceHotwordAdmission.activate(
            session: session,
            policy: voiceHotwordPolicy(for: bundleIdentifier)
        )
        let sessionPhrases = voiceHotwordAdmission.snapshot(
            session: session
        ).phrases
        // strict 应用只使用用户亲手维护的热词：自动学习收录的词条是跨应用学到的
        // 个人数据，与 L1 短语一样不进入。
        let isStrict = settings.contextPolicy(for: bundleIdentifier) == .strict
        let phraseBookPhrases: [String]
        if settings.voicePhraseBookHotwordsEnabled, !isStrict {
            phraseBookPhrases = RimeAIPhraseBookService.shared
                .voiceHotwordCandidates(
                    forBundleIdentifier: bundleIdentifier,
                    limit: 96
                )
        } else {
            phraseBookPhrases = []
        }
        return VoiceHotwordMerger.merge(
            customPhrases: isStrict
                ? settings.voiceUserCuratedHotwords
                : settings.voiceCustomHotwords,
            phraseBookPhrases: phraseBookPhrases,
            sessionRimePhrases: sessionPhrases
        )
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

    /// 右 ⌘ 点按切换录音没有 Carbon release 边沿：控制器失活（切换输入法、
    /// 输入会话结束）时补一次“松开”，否则录音在控制器失活后无人能停。
    func releaseModifierTapDictationIfRecording() {
        let runtime = VoiceDictationRuntime.shared
        guard VoiceModifierTapPolicy.shouldReleaseOnDeactivate(
            isModifierTap: settings.voiceShortcuts.contains(where: \.isModifierTap),
            phase: runtime.phase
        ) else {
            return
        }
        runtime.stop(owner: self)
    }

    /// 任意非修饰键按下或状态重置时，同时撤销点按检测与指针防护。
    func resetVoiceModifierTapDetectors() {
        voiceModifierTapDetector.reset()
        voiceTranslateModifierTapDetector.reset()
        voiceModifierTapPointerGuard.reset()
        voiceTranslateModifierTapPointerGuard.reset()
        VoiceGlobalHotKeyService.shared.resetModifierTapDetectors()
    }

    func handleVoiceModifierFlagsChanged(
        _ event: NSEvent,
        client: any IMKTextInput
    ) -> Bool {
        // 语音未启用时右 ⌘ 点按不构成任何语音意图：保持静默，也不弹出提示。
        guard settings.voiceEnabled else {
            resetVoiceModifierTapDetectors()
            return false
        }
        VoiceGlobalHotKeyService.shared.handleFlagsChanged(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            controller: self,
            client: client
        )
        return false
    }

    func finishVoiceDictation() {
        VoiceDictationRuntime.shared.stop(owner: self)
    }

    func cancelVoiceDictation() {
        VoiceDictationRuntime.shared.cancel(owner: self)
    }

    func configureVoiceHotKey() {
        if IsSecureEventInputEnabled() {
            // 覆盖 Carbon 轮询 tick 之间刚进入 Secure Input 的窗口，并
            // 记录本 controller 的安全态，以便后续真实键事件恢复注册。
            enterSecureInputIfPossible()
            return
        }
        VoiceGlobalHotKeyService.shared.reconcileHotKeys()
        if case .registered = VoiceHotKeyManager.shared.registrationStatus {
            voiceHotKeyIsRegistered = true
            voiceHotKeyRegistrationFailed = false
        } else {
            voiceHotKeyIsRegistered = false
        }
        if case .registered = VoiceHotKeyManager.shared.secondaryRegistrationStatus {
            voiceSecondaryHotKeyIsRegistered = true
        } else {
            voiceSecondaryHotKeyIsRegistered = false
        }
        if case .registered = VoiceHotKeyManager.shared.translateRegistrationStatus {
            voiceTranslateHotKeyIsRegistered = true
        } else {
            voiceTranslateHotKeyIsRegistered = false
        }
    }

    func clearVoiceTranslationHotKeyRegistration() {
        VoiceGlobalHotKeyService.shared.reconcileHotKeys()
        voiceTranslateHotKeyIsRegistered = false
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
              !VoiceClientMarkedRangePolicy.hasMarkedText(inputClient.markedRange()),
              !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            return false
        }
        let currentSelection = inputClient.selectedRange()
        guard currentSelection.location != NSNotFound else {
            return false
        }
        // 不再把选区偏移与光标坐标锁死在启动时的 8pt 容差内：Electron/网页输入框在
        // 流式输出、滚动或用户点击重定位光标时，同会话内光标仍在可编辑区域，应允许上屏。
        return voiceCaretRect(
            client: inputClient,
            characterIndex: currentSelection.location
        ) != nil
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
        !text.contains("\r"),
        !text.unicodeScalars.contains(where: {
            ($0.value < 0x20 && $0.value != 0x0A) || $0.value == 0x7F
        })
        else {
            return false
        }

        // 上屏前记下插入区段的原有内容：部分宿主（Electron/网页输入框）的
        // insertText 会“成功返回”却什么也没写入。按提交瞬间的实时光标位置回读，
        // 避免同会话内光标微调后回读范围错位。
        let caretBefore = inputClient.selectedRange()
        let readbackLocation = caretBefore.location == NSNotFound
            ? selection.location
            : caretBefore.location
        let insertedRange = NSRange(location: readbackLocation, length: text.utf16.count)
        let readback: (NSRange) -> String? = { range in
            inputClient.attributedSubstring(from: range)?.string
        }
        let baseline = readback(insertedRange)
        inputClient.insertText(text, replacementRange: notFoundRange)
        if VoiceCommitReadback.verify(
            committedText: text,
            baseline: baseline,
            readback: readback(insertedRange),
            caretBefore: caretBefore.location == NSNotFound ? nil : caretBefore.location,
            caretAfter: inputClient.selectedRange().location
        ) == .missing {
            // 文本并未真正写入：返回 false 以触发 ⌘V 回退。
            return false
        }
        if let currentBundleIdentifier,
           settings.isAIAllowed(for: currentBundleIdentifier),
           settings.contextPolicy(for: currentBundleIdentifier) != .strict
        {
            Self.contextStore.appendCommittedText(text)
            armContinuationAfterCommit(committedText: text, client: inputClient)
        } else {
            Self.contextStore.deactivate()
        }
        return true
    }

    /// 开始听写时那个输入框的文本证据：光标前最多 16 个字（光标在文首时改取
    /// 光标后的文字）的绝对位置与内容。
    func voiceRuntimeTargetFingerprint(
        client: AnyObject,
        selection: NSRange
    ) -> VoiceTargetFingerprint? {
        guard let inputClient = client as? any IMKTextInput,
              selection.location != NSNotFound
        else {
            return nil
        }
        return VoiceTargetFingerprint.capture(
            caretLocation: selection.location,
            selectionLength: selection.length,
            read: { inputClient.attributedSubstring(from: $0)?.string }
        )
    }

    /// 提交前按证据复核「还是开始听写的那个输入框」：有文字证据时原样回读比对，
    /// 滚动、重排、在同一输入框内移动光标都不影响；没有文字证据（空输入框，或
    /// 宿主不支持回读）时退回光标矩形比对。
    func voiceRuntimeTargetMatchesFingerprint(
        client: AnyObject,
        fingerprint: VoiceTargetFingerprint?,
        anchorRect: NSRect
    ) -> Bool {
        guard let fingerprint else {
            return true
        }
        guard let inputClient = client as? any IMKTextInput else {
            return false
        }
        if fingerprint.hasTextEvidence {
            return fingerprint.matches { inputClient.attributedSubstring(from: $0)?.string }
        }
        let selection = inputClient.selectedRange()
        guard selection.location != NSNotFound,
              let currentAnchor = voiceCaretRect(
                  client: inputClient,
                  characterIndex: selection.location
              )
        else {
            return false
        }
        return VoiceCaretRectMatch.isSameCaretRect(anchorRect, currentAnchor)
    }

    func voiceRuntimeDidBecomeUnavailable() {
        VoiceHotKeyManager.shared.deactivate(owner: self)
        voiceHotKeyIsRegistered = false
        voiceSecondaryHotKeyIsRegistered = false
        voiceTranslateHotKeyIsRegistered = false
    }

    func voiceRuntimeDidBecomeAvailable() {
        voiceHotKeyRegistrationFailed = false
        configureVoiceHotKey()
    }

    func voiceRuntimeSecureInputDetected() {
        enterSecureInputIfPossible()
    }
}
