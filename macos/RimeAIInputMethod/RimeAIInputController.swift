import AppKit
import Carbon
import InputMethodKit

@objc(RimeAIInputController)
@MainActor
final class RimeAIInputController: IMKInputController,
    VoiceDictationRuntimeOwner, @unchecked Sendable
{
    private static var contextStore = SessionContextStore(maxCharacters: 100)

    private let sessionNonce = UUID().uuidString
    private let candidatePanel: CandidatePanelController
    private let mixedCompositionResolver = MixedCompositionResolver()
    private var composition = CompositionState(appSessionID: "inactive")
    private var mixedCompositionSuggestion: MixedCompositionSuggestion?
    private var historyEnglishTokens = Set<String>()
    private var historyEnglishTokensLoaded = false
    private var historyEnglishTokensLoading = false
    private var historyEnglishTokensGeneration: UInt64 = 0
    private var debounceWorkItem: DispatchWorkItem?
    private var cloudDebounceWorkItem: DispatchWorkItem?
    private var pendingRequestID: String?
    private var pendingRequestStartedAt: TimeInterval?
    private var pendingCloudRequestID: String?
    private var pendingCloudBuildCancellation: CloudCandidateBuildCancellation?
    private var cloudInFlight = false
    private var semanticPresentation: SemanticCandidatePresentation = .idle
    private var semanticHistorySource: HistoryCommitSource = .localSemantic
    private var semanticCloudCandidate: CloudCandidate?
    private var cloudSuggestionApplied = false
    private var semanticContextCharacterCount = 0
    private weak var activeClientObject: AnyObject?
    private var currentBundleIdentifier: String?
    private var hostFocusEpoch: UInt64 = 0
    private var settingsObservers: [NSObjectProtocol] = []
    private let settings = RimeAISettingsStore.shared
    private var voiceHotKeyRegistrationFailed = false
    private var voiceHotKeyIsRegistered = false
    private var isHostActive = false
    private var voiceHotwordAdmission = VoiceHotwordAdmissionState()

    override init!(
        server: IMKServer!,
        delegate: Any!,
        client inputClient: Any!
    ) {
        candidatePanel = MainActor.assumeIsolated {
            CandidatePanelController()
        }
        super.init(
            server: server,
            delegate: delegate,
            client: inputClient
        )
        MainActor.assumeIsolated {
            activeClientObject = inputClient as AnyObject
            observeSettings()
        }
    }

    deinit {
        for observer in settingsObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        // IMK controllers normally die on main. Do not call assumeIsolated
        // off-main; runtime/HotKeyManager hold owners weakly and their timers
        // invalidate an owner that has disappeared.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                VoiceDictationRuntime.shared.deactivate(owner: self)
            }
        }
    }

    override nonisolated func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        MainActor.assumeIsolated {
            guard let client = sender as? any IMKTextInput else {
                return
            }
            beginHostActivation(sender as AnyObject)
            activateSession(for: client)
            if IsSecureEventInputEnabled() {
                enterSecureInput(client: client)
            } else {
                VoiceDictationRuntime.shared.secureInputChanged(
                    active: false,
                    owner: self
                )
                configureVoiceHotKey()
            }
        }
    }

    override nonisolated func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated {
            VoiceDictationRuntime.shared.deactivate(owner: self)
            voiceHotKeyIsRegistered = false
            isHostActive = false
            invalidateInference(clearPresentation: true)
            candidatePanel.hide()
            composition.reset()
            Self.contextStore.suspend(ownerID: sessionNonce)
            voiceHotwordAdmission.deactivate()
            activeClientObject = nil
        }
        super.deactivateServer(sender)
    }

    override nonisolated func handle(
        _ event: NSEvent!,
        client sender: Any!
    ) -> Bool {
        MainActor.assumeIsolated {
            handleOnMain(event, client: sender)
        }
    }

    private func handleOnMain(
        _ event: NSEvent!,
        client sender: Any!
    ) -> Bool {
        guard event?.type == .keyDown,
              let client = sender as? any IMKTextInput
        else {
            return false
        }
        if isHostActive {
            adoptActiveClient(sender as AnyObject)
        } else {
            beginHostActivation(sender as AnyObject)
        }
        activateSession(for: client)

        if IsSecureEventInputEnabled() {
            enterSecureInput(client: client)
            return false
        }
        if composition.isSecureInput {
            composition.switchApplicationSession(
                to: applicationSessionID(for: client)
            )
            Self.contextStore.activate(
                sessionID: client.bundleIdentifier() ?? "unknown-client",
                ownerID: sessionNonce
            )
            VoiceDictationRuntime.shared.secureInputChanged(
                active: false,
                owner: self
            )
            configureVoiceHotKey()
        }

        let voiceRuntime = VoiceDictationRuntime.shared
        let voiceDecision = VoiceDictationKeyRouter.decision(
            keyCode: event.keyCode,
            isExactVoiceShortcut: isVoiceShortcut(event),
            shortcutRegistered: voiceHotKeyIsRegistered,
            hasActiveSession: voiceRuntime.isActive(owner: self),
            pendingConfirmation: voiceRuntime.isPendingConfirmation(owner: self),
            isPlainConfirmationKey: VoiceDictationKeyRouter
                .isPlainConfirmation(
                    modifiers: voiceKeyModifiers(event.modifierFlags)
                )
        )
        switch voiceDecision {
        case .consumeShortcut:
            return true
        case .confirm:
            voiceRuntime.confirm(owner: self)
            return true
        case .cancelAndConsume:
            cancelVoiceDictation()
            return true
        case .cancelAndContinue:
            // 先使语音目标永久失效，再继续原有键盘路径。
            cancelVoiceDictation()
        case .passThrough:
            break
        }
        voiceRuntime.dismissTransientPanel(owner: self)

        let modifiers = event.modifierFlags.intersection(
            [.command, .control, .option]
        )
        if !modifiers.isEmpty {
            invalidateCurrentResult()
            return false
        }

        switch event.keyCode {
        case 51:
            return deleteBackward(client: client)
        case 53:
            guard composition.hasComposition else {
                return false
            }
            resetComposition(client: client)
            return true
        case 36, 76:
            guard composition.hasComposition else {
                return false
            }
            commitText(
                composition.rawPrefixString + composition.pinyin,
                source: .rawPinyin,
                client: client,
                historyPinyin: composition.historyPinyin
            )
            return true
        case 48:
            guard let semanticCandidate = composition.semanticCandidate else {
                // 有 composition（含仅前缀）时 Tab 不能直通，否则宿主
                // 对 marked range 的原生处理会吞掉编码区。
                return composition.hasComposition
            }
            selectSemanticCandidate(semanticCandidate, client: client)
            return true
        case 49:
            if !composition.mainCandidates.isEmpty {
                selectMainCandidate(
                    index: currentCommitCandidateIndex,
                    client: client
                )
                return true
            }
            if let semanticCandidate = composition.semanticCandidate {
                selectSemanticCandidate(semanticCandidate, client: client)
                return true
            }
            guard composition.pinyin.isEmpty else {
                commitText(
                    composition.rawPrefixString + composition.pinyin,
                    source: .rawPinyin,
                    client: client,
                    historyPinyin: composition.historyPinyin
                )
                return true
            }
            if composition.hasComposition {
                // 仅前缀状态：Space 提交前缀定稿，空格字面随后按
                // 现有宽度偏好处理。
                flushCompositionAsFinal(client: client)
            }
            if let literal = transformedLiteral(" ") {
                client.insertText(literal, replacementRange: notFoundRange)
                return true
            }
            return false
        case 27, 24:
            guard composition.hasComposition else {
                break
            }
            let moved = event.keyCode == 24
                ? composition.advanceCandidatePage()
                : composition.retreatCandidatePage()
            if moved {
                refreshCandidatePanelIfActive()
            }
            return true
        case 123, 124, 125, 126, 116, 121:
            if composition.pinyin.isEmpty,
               !composition.prefixSegments.isEmpty
            {
                // 仅前缀状态同样存在 marked text，方向键直通会使
                // marked range 与状态失联，先吞掉。
                invalidateCurrentResult()
                return true
            }
            invalidateCurrentResult()
            clearContextForCurrentApplication()
            return false
        default:
            break
        }

        let characters = event.charactersIgnoringModifiers ?? ""
        if let candidateIndex = numericCandidateIndex(from: characters),
           composition.hasComposition
        {
            if !composition.pinyin.isEmpty {
                if let globalIndex = composition.globalCandidateIndex(
                    forPageSlot: candidateIndex + 1
                ) {
                    selectMainCandidate(index: globalIndex, client: client)
                }
                return true
            }
            // 仅前缀状态无候选可选：先提交前缀，数字键作为普通
            // 字符放行。
            flushCompositionAsFinal(client: client)
            return false
        }

        if event.modifierFlags.contains(.shift),
           !composition.hasComposition
        {
            return false
        }
        if let character = acceptedCompositionCharacter(
            from: event.characters ?? characters
        ) {
            compositionInput(
                composition.pinyin + String(character),
                client: client
            )
            configureVoiceHotKey()
            return true
        }

        let keyCharacters = event.characters ?? characters
        if let scalar = keyCharacters.unicodeScalars.first,
           keyCharacters.unicodeScalars.count == 1,
           let literalText = RimeAIInputTextTransformer
               .compositionLiteralText(
                   scalar,
                   preferences: settings.inputPreferences
               )
        {
            // 标点/符号进入 composition，绝不触发上屏。
            appendCompositionLiteral(literalText, client: client)
            configureVoiceHotKey()
            return true
        }

        let literal = transformedLiteral(keyCharacters)
        if composition.hasComposition {
            // 未映射符号：先整段提交（前缀定稿 + 当前内容）再放行
            // 该符号，保持"符号出现在文本流"的既有语义。
            flushCompositionAsFinal(client: client)
            return false
        } else if let literal {
            client.insertText(literal, replacementRange: notFoundRange)
            return true
        }
        return false
    }

    override nonisolated func commitComposition(_ sender: Any!) {
        MainActor.assumeIsolated {
            commitCompositionOnMain(sender)
        }
    }

    private func commitCompositionOnMain(_ sender: Any!) {
        guard let client = sender as? any IMKTextInput else {
            return
        }
        cancelVoiceDictation()
        adoptActiveClient(sender as AnyObject)
        if !composition.mainCandidates.isEmpty {
            selectMainCandidate(
                index: currentCommitCandidateIndex,
                client: client
            )
        } else if !composition.pinyin.isEmpty {
            commitText(
                composition.rawPrefixString + composition.pinyin,
                source: .rawPinyin,
                client: client,
                historyPinyin: composition.historyPinyin
            )
        } else if composition.hasComposition {
            // 仅前缀状态（如刚输入标点后焦点切换）：提交定稿文本，
            // 不残留 marked text。
            commitText(
                composition.committedPrefixText,
                source: .rimeMain,
                client: client,
                historyPinyin: composition.prefixHistoryPinyin
            )
        }
    }

    override nonisolated func composedString(_ sender: Any!) -> Any! {
        MainActor.assumeIsolated {
            composition.displayString
        }
    }

    override nonisolated func originalString(
        _ sender: Any!
    ) -> NSAttributedString! {
        let original = MainActor.assumeIsolated {
            composition.displayString
        }
        return NSAttributedString(string: original)
    }

    override nonisolated func candidates(_ sender: Any!) -> [Any]! {
        MainActor.assumeIsolated {
            // IMK 协议兜底回调，无实际显示路径；候选分页仅存在于
            // 自绘 CandidatePanelController，此处维持全量返回。
            composition.mainCandidates
        }
    }

    override nonisolated func menu() -> NSMenu! {
        makeInputMethodMenu()
    }

    private nonisolated func makeInputMethodMenu() -> NSMenu {
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
        settings.characterSet = .simplified
    }

    @objc private func useTraditionalChinese(_ sender: Any?) {
        settings.characterSet = .traditional
    }

    @objc private func useHalfWidth(_ sender: Any?) {
        settings.characterWidth = .half
    }

    @objc private func useFullWidth(_ sender: Any?) {
        settings.characterWidth = .full
    }

    @objc private func useChinesePunctuation(_ sender: Any?) {
        settings.punctuationStyle = .chinese
    }

    @objc private func useWesternPunctuation(_ sender: Any?) {
        settings.punctuationStyle = .western
    }

    @objc private func showPrivacyCenter(_ sender: Any?) {
        PrivacyCenterWindowController.shared.showWindow()
    }

    private func activateSession(for client: any IMKTextInput) {
        let bundleIdentifier = client.bundleIdentifier()
            ?? "unknown-client"
        currentBundleIdentifier = bundleIdentifier
        prewarmHistoryEnglishTokens(for: bundleIdentifier)
        let sessionID = applicationSessionID(for: client)
        voiceHotwordAdmission.activate(
            session: voiceHotwordSession(for: client),
            policy: voiceHotwordPolicy(for: bundleIdentifier)
        )
        Self.contextStore.activate(
            sessionID: bundleIdentifier,
            ownerID: sessionNonce
        )
        if composition.appSessionID != sessionID {
            VoiceDictationRuntime.shared.sessionSwitched(owner: self)
            invalidateInference(clearPresentation: true)
            candidatePanel.hide()
            composition.switchApplicationSession(to: sessionID)
        }
        configureVoiceHotKey()
    }

    private func applicationSessionID(
        for client: any IMKTextInput
    ) -> String {
        let bundleIdentifier = client.bundleIdentifier()
            ?? "unknown-client"
        return "\(bundleIdentifier)#\(sessionNonce)#\(hostFocusEpoch)"
    }

    private func voiceHotwordSession(
        for client: any IMKTextInput
    ) -> VoiceHotwordAdmissionSession {
        VoiceHotwordAdmissionSession(
            applicationIdentifier: client.bundleIdentifier()
                ?? "unknown-client",
            controllerSessionIdentifier: sessionNonce,
            focusEpoch: hostFocusEpoch
        )
    }

    private func voiceHotwordPolicy(
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

    private func adoptActiveClient(_ clientObject: AnyObject) {
        if let activeClientObject, activeClientObject !== clientObject {
            VoiceHotKeyManager.shared.deactivate(owner: self)
            voiceHotKeyIsRegistered = false
            VoiceDictationRuntime.shared.sessionSwitched(owner: self)
            hostFocusEpoch &+= 1
        }
        activeClientObject = clientObject
    }

    private func beginHostActivation(_ clientObject: AnyObject) {
        isHostActive = true
        VoiceHotKeyManager.shared.deactivate(owner: self)
        voiceHotKeyIsRegistered = false
        VoiceDictationRuntime.shared.claim(owner: self)
        VoiceDictationRuntime.shared.sessionSwitched(owner: self)
        hostFocusEpoch &+= 1
        activeClientObject = clientObject
    }

    private func isVoiceShortcut(_ event: NSEvent) -> Bool {
        return VoiceDictationKeyRouter.isExactVoiceShortcut(
            keyCode: event.keyCode,
            modifiers: voiceKeyModifiers(event.modifierFlags),
            shortcut: settings.voiceShortcut
        )
    }

    private func voiceKeyModifiers(
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

    private func startVoiceDictation(
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

    private func voiceHotwordSnapshot(
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

    private func recordVoiceHotwordFromRimeCommit(
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

    private func canStartVoiceDictation(
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

    private func finishVoiceDictation() {
        VoiceDictationRuntime.shared.stop(owner: self)
    }

    private func cancelVoiceDictation() {
        VoiceDictationRuntime.shared.cancel(owner: self)
    }

    private func configureVoiceHotKey() {
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

    private func compositionInput(
        _ rawInput: String,
        client: any IMKTextInput,
        preserveInputOnLookupFailure: Bool = false
    ) {
        cancelVoiceDictation()
        invalidateInference()
        mixedCompositionSuggestion = nil
        let rimeInput = rawInput.lowercased()
        let candidates = RimeEngine.shared.candidates(
            for: rimeInput,
            limit: 50
        )
        let mixedSuggestion = resolveMixedComposition(
            rawInput: rawInput
        )
        guard !candidates.isEmpty || mixedSuggestion != nil
                || preserveInputOnLookupFailure
        else {
            if composition.pinyin.isEmpty {
                return
            }
            if composition.prefixSegments.isEmpty {
                resetComposition(client: client)
            } else {
                // 前缀仍在编辑中：只清活跃段，保留定稿前缀与显示。
                composition.clearActivePinyin()
                invalidateInference(clearPresentation: true)
                mixedCompositionSuggestion = nil
                client.setMarkedText(
                    composition.displayString,
                    selectionRange: NSRange(
                        location: composition.displayString.utf16.count,
                        length: 0
                    ),
                    replacementRange: notFoundRange
                )
                candidatePanel.hide()
            }
            return
        }
        let token = composition.replaceInput(
            pinyin: rawInput,
            candidates: candidates
        )
        configureVoiceHotKey()
        semanticHistorySource = .localSemantic
        semanticCloudCandidate = nil
        cloudSuggestionApplied = false
        client.setMarkedText(
            composition.displayString,
            selectionRange: NSRange(
                location: composition.displayString.utf16.count,
                length: 0
            ),
            replacementRange: notFoundRange
        )
        if candidates.isEmpty, mixedSuggestion == nil {
            semanticPresentation = .unavailable
            semanticContextCharacterCount = 0
            renderCandidatePanel(client: client)
            return
        }
        if let mixedSuggestion,
           composition.applySemanticCandidate(
               mixedSuggestion.text,
               token: token,
               decision: .mixedComposition
           )
        {
            mixedCompositionSuggestion = mixedSuggestion
            semanticPresentation = .candidate(
                text: mixedSuggestion.text,
                decision: .mixedComposition,
                confidence: mixedSuggestion.confidence
            )
            semanticContextCharacterCount = 0
            settings.record(.resultShown)
            settings.record(.mixedCompositionShown)
            renderCandidatePanel(client: client)
            return
        }
        semanticPresentation = .analyzing
        scheduleInference(token: token, client: client)
        renderCandidatePanel(client: client)
    }

    private func resolveMixedComposition(
        rawInput: String
    ) -> MixedCompositionSuggestion? {
        guard let currentBundleIdentifier,
              settings.isAIAllowed(for: currentBundleIdentifier)
        else {
            return nil
        }
        var personalized = Set<String>()
        if settings.contextPolicy(for: currentBundleIdentifier) != .strict {
            personalized = settings.personalEnglishTokens
            if historyEnglishTokensLoaded {
                personalized.formUnion(historyEnglishTokens)
            }
        }
        return mixedCompositionResolver.resolve(
            rawInput: rawInput,
            personalizedEnglishTokens: personalized
        ) { pinyin, limit in
            RimeEngine.shared.candidates(for: pinyin, limit: limit)
        }
    }

    private func prewarmHistoryEnglishTokens(
        for bundleIdentifier: String
    ) {
        guard settings.contextPolicy(for: bundleIdentifier) != .strict,
              !historyEnglishTokensLoaded,
              !historyEnglishTokensLoading
        else {
            return
        }
        historyEnglishTokensLoading = true
        let generation = historyEnglishTokensGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let recentText = try? RimeAIHistoryService.shared.recentText(
                maxCharacters: 4_000
            )
            let tokens = recentText.map {
                MixedCompositionResolver.personalizedEnglishTokens(from: $0)
            } ?? []
            let boundedTokens = Set(tokens.sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                return $0 < $1
            }.prefix(256))
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.historyEnglishTokensGeneration == generation
                else {
                    return
                }
                self.historyEnglishTokens = boundedTokens
                self.historyEnglishTokensLoaded = true
                self.historyEnglishTokensLoading = false
            }
        }
    }

    /// 提交基准索引：翻页后为当前页第一个候选，未翻页时即全局首选；
    /// 页状态异常时回落 0。Space、IMK 强制提交与 flush-then-dispatch
    /// 共用，保证"当前高亮项上屏"的体验一致。
    private var currentCommitCandidateIndex: Int {
        composition.globalCandidateIndex(forPageSlot: 1) ?? 0
    }

    /// 标点/符号进入 composition：定稿活跃段并追加字面量段，绝不
    /// 触发上屏。面板与推断随之收敛到"仅前缀"状态。
    private func appendCompositionLiteral(
        _ text: String,
        client: any IMKTextInput
    ) {
        cancelVoiceDictation()
        invalidateInference(clearPresentation: true)
        mixedCompositionSuggestion = nil
        semanticCloudCandidate = nil
        cloudSuggestionApplied = false
        semanticPresentation = .unavailable
        semanticContextCharacterCount = 0
        composition.appendLiteral(text)
        client.setMarkedText(
            composition.displayString,
            selectionRange: NSRange(
                location: composition.displayString.utf16.count,
                length: 0
            ),
            replacementRange: notFoundRange
        )
        candidatePanel.hide()
        configureVoiceHotKey()
    }

    /// flush-then-dispatch：把整段 composition（定稿前缀 + 活跃内容）
    /// 作为最终文本提交。活跃段有候选时取 Rime 首选，无候选（混输
    /// 态等）回落原始字母，与 `appendLiteral` 的定稿语义一致；语义
    /// 候选不参与，AI 候选仅可经 Tab 显式采用。
    @discardableResult
    private func flushCompositionAsFinal(client: any IMKTextInput) -> Bool {
        guard composition.hasComposition else {
            return false
        }
        if !composition.pinyin.isEmpty {
            if !composition.mainCandidates.isEmpty {
                selectMainCandidate(
                    index: currentCommitCandidateIndex,
                    client: client
                )
            } else {
                commitText(
                    composition.rawPrefixString + composition.pinyin,
                    source: .rawPinyin,
                    client: client,
                    historyPinyin: composition.historyPinyin
                )
            }
            return true
        }
        return commitText(
            composition.committedPrefixText,
            source: .rimeMain,
            client: client,
            historyPinyin: composition.prefixHistoryPinyin
        )
    }

    private func deleteBackward(client: any IMKTextInput) -> Bool {
        if !composition.pinyin.isEmpty {
            var updated = composition.pinyin
            updated.removeLast()
            if updated.isEmpty {
                if composition.prefixSegments.isEmpty {
                    resetComposition(client: client)
                } else {
                    // 活跃段删空但前缀仍在编辑：保留前缀与显示。
                    composition.clearActivePinyin()
                    invalidateInference(clearPresentation: true)
                    mixedCompositionSuggestion = nil
                    client.setMarkedText(
                        composition.displayString,
                        selectionRange: NSRange(
                            location: composition.displayString.utf16.count,
                            length: 0
                        ),
                        replacementRange: notFoundRange
                    )
                    candidatePanel.hide()
                }
            } else {
                compositionInput(updated, client: client)
            }
            return true
        }
        if composition.popTrailingLiteral() != nil {
            // 删除末尾标点，前缀其余部分保持。
            invalidateInference(clearPresentation: true)
            client.setMarkedText(
                composition.displayString,
                selectionRange: NSRange(
                    location: composition.displayString.utf16.count,
                    length: 0
                ),
                replacementRange: notFoundRange
            )
            return true
        }
        if let revived = composition.reviveLastPinyinSegment() {
            // 拼音段复活为活跃段继续编辑；preserve 防止查询失败时
            // 丢失整个 buffer。
            compositionInput(
                revived,
                client: client,
                preserveInputOnLookupFailure: true
            )
            return true
        }
        return false
    }

    private func scheduleInference(
        token: CompositionToken,
        client: any IMKTextInput
    ) {
        guard let currentBundleIdentifier,
              !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            semanticPresentation = .unavailable
            settings.record(.privacyBlocked)
            return
        }
        guard composition.pinyin.count <= 256 else {
            semanticPresentation = .inputTooLong
            semanticContextCharacterCount = 0
            return
        }
        let localAllowed = settings.isAIAllowed(
            for: currentBundleIdentifier
        )
        let cloudAllowed = settings.cloudConfigured
        guard localAllowed || cloudAllowed else {
            semanticPresentation = .unavailable
            return
        }
        if !localAllowed, cloudAllowed {
            semanticPresentation = .cloudAnalyzing
        }
        let pinyin = composition.pinyin.lowercased()
        let localRequest: SemanticInferenceRequest?
        if localAllowed {
            let requestID = UUID().uuidString
            let contextPolicy = settings.contextPolicy(
                for: currentBundleIdentifier
            )
            let context = inferenceContext(
                policy: contextPolicy,
                client: client
            )
            semanticContextCharacterCount = context.count
            localRequest = SemanticInferenceRequest(
                requestID: requestID,
                token: token,
                contextPolicy: contextPolicy,
                context: context,
                pinyin: pinyin,
                candidates: composition.mainCandidates,
                deadlineMilliseconds: 400,
                allowSentence: LocalSentenceSuggestionPolicy.allows(
                    pinyin: pinyin,
                    characterSet: settings.characterSet
                )
            )
        } else {
            localRequest = nil
            semanticContextCharacterCount = 0
        }
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.composition.token == token,
                      !self.composition.isSelecting,
                      !self.composition.isSecureInput,
                      !IsSecureEventInputEnabled()
                else {
                    return
                }
                if let localRequest {
                    self.sendInference(
                        localRequest,
                        requestID: localRequest.requestID,
                        token: token
                    )
                }
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(100),
            execute: workItem
        )
        if cloudAllowed {
            scheduleCloudInference(
                pinyin: pinyin,
                bundleIdentifier: currentBundleIdentifier,
                token: token,
                localRequestWasScheduled: localRequest != nil
            )
        }
    }

    /// 击键停顿 1000 ms 后才发云端请求：latest-request-wins 下连续击键
    /// 期间发出的云端请求必然被下一次击键取消，只会白白消耗一次 LLM
    /// 往返；等停顿再发，大模型结果才有机会真正到达候选面板。
    private func scheduleCloudInference(
        pinyin: String,
        bundleIdentifier: String,
        token: CompositionToken,
        localRequestWasScheduled: Bool
    ) {
        cloudDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.composition.token == token,
                      !self.composition.isSelecting,
                      !self.composition.isSecureInput,
                      !IsSecureEventInputEnabled()
                else {
                    return
                }
                self.buildAndSendCloudInference(
                    pinyin: pinyin,
                    bundleIdentifier: bundleIdentifier,
                    token: token,
                    localRequestWasScheduled: localRequestWasScheduled
                )
            }
        }
        cloudDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(1_000),
            execute: workItem
        )
    }

    private func sendInference(
        _ request: SemanticInferenceRequest,
        requestID: String,
        token: CompositionToken
    ) {
        pendingRequestID = requestID
        pendingRequestStartedAt = ProcessInfo.processInfo.systemUptime
        settings.record(.requestStarted)
        DaemonClient.shared.infer(request) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.applyInferenceResult(
                    result,
                    requestID: requestID,
                    token: token
                )
            }
        }
    }

    private func buildAndSendCloudInference(
        pinyin: String,
        bundleIdentifier: String,
        token: CompositionToken,
        localRequestWasScheduled: Bool
    ) {
        let requestID = UUID().uuidString
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadlineAt = startedAt + 4.0
        let modelID = settings.cloudModelID
        let clientSessionID = sessionNonce
        let buildCancellation = CloudCandidateBuildCancellation()
        pendingCloudBuildCancellation?.cancel()
        pendingCloudBuildCancellation = buildCancellation
        pendingCloudRequestID = requestID
        DispatchQueue.global(qos: .userInitiated).async {
            let apiKey = try? FileCloudCredentialStore.shared.loadAPIKey()
            guard let apiKey,
                  !apiKey.isEmpty,
                  apiKey.utf8.count <= 512
            else {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.pendingCloudRequestID == requestID
                    else {
                        return
                    }
                    self.pendingCloudRequestID = nil
                    self.pendingCloudBuildCancellation = nil
                    self.settings.record(.cloudTransportFailure)
                    self.applyCloudFallback(
                        localRequestWasScheduled: localRequestWasScheduled,
                        decision: nil
                    )
                    CloudBrokerClient.shared.disconnect()
                }
                return
            }
            let pool = RimeCloudCandidatePoolBuilder.build(
                for: pinyin,
                cancellation: buildCancellation,
                characterSet: self.settings.characterSet
            )
            let historyService = RimeAIHistoryService.shared
            let historySnapshot = try? historyService.contextSnapshot(
                    query: pinyin,
                    maxRecentCharacters: 600,
                    maximumSnippetCount: 8
                )
            // 网络层不再设软上限：拼音拼出有把握的中文通常几秒完成，
            // 长拼音/复杂整句建议需要更久。协议 clamp（4000ms）仍保
            // 留着作最后保险，墙钟 deadlineAt 仍是 4s 但只在 envelope
            // 接近超时后才截断（broker/客户端共享同一 deadline）。
            let remainingMilliseconds = max(
                1,
                Int(
                    (
                        deadlineAt
                            - ProcessInfo.processInfo.systemUptime
                    ) * 1_000
                )
            )
            let request = CloudInferenceRequest(
                requestID: requestID,
                token: token,
                bundleIdentifier: bundleIdentifier,
                clientSessionID: clientSessionID,
                modelID: modelID,
                deadlineMilliseconds: remainingMilliseconds,
                pinyin: pinyin,
                candidates: pool.candidates,
                candidatePoolHash: pool.hash,
                recentContext: historySnapshot?.recentText ?? "",
                historySnippets: historySnapshot?.relevantSnippets ?? [],
                historyGeneration: historySnapshot?.generation ?? 0
            )
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.pendingCloudRequestID == requestID,
                      self.pendingCloudBuildCancellation === buildCancellation,
                      self.composition.token == token,
                      !self.composition.isSelecting,
                      !self.composition.isSecureInput,
                      !IsSecureEventInputEnabled(),
                      ProcessInfo.processInfo.systemUptime <= deadlineAt,
                      request.isValid
                else {
                    if let self,
                       self.pendingCloudRequestID == requestID
                    {
                        self.pendingCloudRequestID = nil
                        if self.pendingCloudBuildCancellation
                            === buildCancellation
                        {
                            self.pendingCloudBuildCancellation = nil
                        }
                        self.settings.record(.cloudTimeout)
                        if self.composition.token == token,
                           !self.composition.isSelecting,
                           !self.composition.isSecureInput,
                           !IsSecureEventInputEnabled()
                        {
                            self.applyCloudFallback(
                                localRequestWasScheduled:
                                    localRequestWasScheduled,
                                decision: nil
                            )
                        }
                    }
                    return
                }
                self.pendingCloudBuildCancellation = nil
                self.settings.record(.cloudRequestStarted)
                self.cloudInFlight = true
                self.refreshCandidatePanelIfActive()
                CloudBrokerClient.shared.infer(
                    request,
                    apiKey: apiKey
                ) { [weak self] result in
                    Task { @MainActor [weak self] in
                        self?.applyCloudInferenceResult(
                            result,
                            request: request,
                            token: token,
                            deadlineAt: deadlineAt,
                            localRequestWasScheduled: localRequestWasScheduled
                        )
                    }
                }
            }
        }
    }

    private func applyCloudInferenceResult(
        _ result: CloudInferenceResponse?,
        request: CloudInferenceRequest,
        token: CompositionToken,
        deadlineAt: TimeInterval,
        localRequestWasScheduled: Bool
    ) {
        guard pendingCloudRequestID == request.requestID else {
            // 迟到/被替换的响应：计入 stale 而不是无声丢弃。
            settings.record(.staleResult)
            return
        }
        pendingCloudRequestID = nil
        cloudInFlight = false
        refreshCandidatePanelIfActive()
        guard !IsSecureEventInputEnabled() else {
            enterSecureInputIfPossible()
            return
        }
        guard composition.token == token,
              !composition.isSelecting,
              !composition.isSecureInput
        else {
            settings.record(.staleResult)
            return
        }
        guard (try? RimeAIHistoryService.shared.statistics().generation)
            == request.historyGeneration
        else {
            settings.record(.staleResult)
            return
        }
        guard ProcessInfo.processInfo.systemUptime <= deadlineAt else {
            settings.record(.cloudTimeout)
            applyCloudFallback(
                localRequestWasScheduled: localRequestWasScheduled,
                decision: nil
            )
            return
        }
        guard let result else {
            settings.record(.cloudTransportFailure)
            applyCloudFallback(
                localRequestWasScheduled: localRequestWasScheduled,
                decision: nil
            )
            return
        }
        guard result.isValid(for: request) else {
            settings.record(.cloudInvalidResult)
            applyCloudFallback(
                localRequestWasScheduled: localRequestWasScheduled,
                decision: nil
            )
            return
        }
        if result.decision == .generate {
            // 响应确实回来了：无论后续展示与否都留下痕迹，避免
            // 生成链路出现无法诊断的静默。
            settings.record(.cloudGenerateReceived)
            applyCloudGeneratedResult(
                result,
                request: request,
                token: token,
                localRequestWasScheduled: localRequestWasScheduled
            )
            return
        }
        guard let candidate = result.selectedCandidate(for: request),
              let confidence = result.confidence
        else {
            applyCloudFallback(
                localRequestWasScheduled: localRequestWasScheduled,
                decision: result.decision
            )
            return
        }
        // 池内候选可能因 Rime 选项竞态混入繁体：就地转换为用户字形
        // 后展示，而不是静默丢弃。
        guard let renderedCandidate = SemanticCandidateScriptPolicy.sanitized(
            text: candidate.text,
            characterSet: settings.characterSet
        ) else {
            settings.record(.sentenceScriptMismatch)
            applyCloudFallback(
                localRequestWasScheduled: localRequestWasScheduled,
                decision: .abstain
            )
            return
        }
        let displayText = renderedCandidate == candidate.text
            ? candidate.text
            : renderedCandidate
        guard composition.applySemanticCandidate(
            displayText,
            token: token,
            decision: .rankedCandidate
        ) else {
            settings.record(.cloudInvalidResult)
            return
        }
        semanticHistorySource = candidate.source == .rimeFuzzy
            ? .cloudFuzzy
            : .cloudExact
        // 候选被字形修正过时本地保存渲染后的文本，Tab 上屏与展示一致。
        let storedCandidate = renderedCandidate == candidate.text
            ? candidate
            : CloudCandidate(
                id: candidate.id,
                text: renderedCandidate,
                source: candidate.source,
                rimeIndex: candidate.rimeIndex,
                consumedLength: candidate.consumedLength,
                alignedPinyin: candidate.alignedPinyin,
                editCost: candidate.editCost
            )
        semanticCloudCandidate = storedCandidate
        cloudSuggestionApplied = true
        semanticPresentation = .candidate(
            text: displayText,
            decision: .rankedCandidate,
            confidence: confidence
        )
        semanticContextCharacterCount = request.recentContext.count
            + request.historySnippets.reduce(0) { $0 + $1.text.count }
        settings.record(.cloudSuggestionShown)
        if candidate.source == .rimeFuzzy {
            settings.record(.cloudCorrectionShown)
        }
        refreshCandidatePanelIfActive()
    }

    /// 云端生成式整句：生成文本已通过 broker 字典对齐校验与客户端
    /// 结构校验，这里先转换字形再处理与首选的重复——重复不再静默，
    /// 而是明示云端表态，让 AI 参与始终可见。
    private func applyCloudGeneratedResult(
        _ result: CloudInferenceResponse,
        request: CloudInferenceRequest,
        token: CompositionToken,
        localRequestWasScheduled: Bool
    ) {
        guard let text = result.generatedText,
              let confidence = result.confidence
        else {
            applyCloudFallback(
                localRequestWasScheduled: localRequestWasScheduled,
                decision: .abstain
            )
            return
        }
        // 生成整句可能含繁体字：就地转换到用户字形后再比较与展示。
        guard let renderedText = SemanticCandidateScriptPolicy.sanitized(
            text: text,
            characterSet: settings.characterSet
        ) else {
            settings.record(.sentenceScriptMismatch)
            applyCloudFallback(
                localRequestWasScheduled: localRequestWasScheduled,
                decision: .abstain
            )
            return
        }
        // 与 Rime 首选相同：明示"云端与首选一致"而不是静默 keep，
        // 用户在本地无法重排的场景（如完整候选不足）也能看到 AI 表态。
        if renderedText == composition.mainCandidates.first {
            semanticPresentation = .cloudSameTopCandidate
            refreshCandidatePanelIfActive()
            return
        }
        // 本地已展示相同文本（典型为本地整句建议先到）：不覆盖。
        if cloudSuggestionApplied,
           case let .candidate(displayed, _, _) = semanticPresentation,
           displayed == renderedText
        {
            return
        }
        guard composition.applySemanticCandidate(
            renderedText,
            token: token,
            decision: .sentenceSuggestion
        ) else {
            settings.record(.cloudInvalidResult)
            return
        }
        let candidate = CloudCandidate(
            text: renderedText,
            source: .cloudGenerated,
            rimeIndex: nil,
            consumedLength: request.pinyin.count,
            alignedPinyin: result.generatedPinyin ?? request.pinyin,
            editCost: 0
        )
        semanticHistorySource = .cloudGenerated
        semanticCloudCandidate = candidate
        cloudSuggestionApplied = true
        semanticPresentation = .candidate(
            text: renderedText,
            decision: .sentenceSuggestion,
            confidence: confidence
        )
        semanticContextCharacterCount = request.recentContext.count
            + request.historySnippets.reduce(0) { $0 + $1.text.count }
        settings.record(.cloudSuggestionShown)
        settings.record(.cloudGeneratedShown)
        refreshCandidatePanelIfActive()
    }

    private func applyCloudFallback(
        localRequestWasScheduled: Bool,
        decision: CloudInferenceDecision?
    ) {
        guard !cloudSuggestionApplied else {
            return
        }
        let resolved = CloudSemanticPresentationResolver.resolveFallback(
            current: semanticPresentation,
            localRequestWasScheduled: localRequestWasScheduled,
            cloudDecision: decision
        )
        guard resolved != semanticPresentation else {
            return
        }
        semanticPresentation = resolved
        refreshCandidatePanelIfActive()
    }

    private func applyInferenceResult(
        _ result: SemanticInferenceResult?,
        requestID: String,
        token: CompositionToken
    ) {
        guard pendingRequestID == requestID else {
            settings.record(.staleResult)
            return
        }
        pendingRequestID = nil
        if let pendingRequestStartedAt {
            settings.recordLatency(
                milliseconds: max(
                    0,
                    (
                        ProcessInfo.processInfo.systemUptime
                            - pendingRequestStartedAt
                    ) * 1_000
                )
            )
        }
        pendingRequestStartedAt = nil
        guard !IsSecureEventInputEnabled() else {
            enterSecureInputIfPossible()
            return
        }
        if cloudSuggestionApplied {
            // A valid cloud decision owns the single explicit suggestion slot.
            return
        }
        guard let result else {
            settings.record(.daemonFailure)
            semanticPresentation = .failure
            refreshCandidatePanelIfActive()
            return
        }
        guard result.status == "ok" else {
            if result.status == "timeout" {
                settings.record(.timeout)
            } else if result.status == "circuit_open" {
                settings.record(.circuitOpen)
            } else {
                settings.record(.daemonFailure)
            }
            semanticPresentation = .failure
            refreshCandidatePanelIfActive()
            return
        }
        guard result.matches(token) else {
            settings.record(.staleResult)
            semanticPresentation = .idle
            refreshCandidatePanelIfActive()
            return
        }
        guard result.isValid(
            for: token,
            candidates: composition.mainCandidates
        ) else {
            settings.record(.invalidResult)
            semanticPresentation = .failure
            refreshCandidatePanelIfActive()
            return
        }
        let candidatePresentation = result.candidatePresentation(
            characterSet: settings.characterSet
        )
        semanticPresentation = candidatePresentation
        switch candidatePresentation {
        case .sameTopCandidate:
            settings.record(.sameTopCandidate)
            refreshCandidatePanelIfActive()
            return
        case .insufficientCandidates:
            settings.record(.insufficientCandidates)
            refreshCandidatePanelIfActive()
            return
        case .belowConfidence:
            settings.record(.belowConfidence)
            refreshCandidatePanelIfActive()
            return
        case .noCandidate:
            settings.record(.noCandidate)
            refreshCandidatePanelIfActive()
            return
        case .sentenceTooLong:
            settings.record(.sentenceTooLong)
            refreshCandidatePanelIfActive()
            return
        case .sentenceIncomplete:
            settings.record(.sentenceIncomplete)
            refreshCandidatePanelIfActive()
            return
        case .scriptMismatch:
            // 字形不符不再静默丢弃：就地转换为用户设置的字形后照常
            // 展示（繁体整句转简体），仅无法转换时才拒绝。
            if let decision = result.resolvedDecision,
               let sanitized = SemanticCandidateScriptPolicy.sanitized(
                   text: result.displayCandidate,
                   characterSet: settings.characterSet
               ),
               composition.applySemanticCandidate(
                   sanitized,
                   token: token,
                   decision: decision
               )
            {
                semanticPresentation = .candidate(
                    text: sanitized,
                    decision: decision,
                    confidence: result.confidence ?? 0
                )
                semanticHistorySource = .localSemantic
                semanticCloudCandidate = nil
                settings.record(.resultShown)
                refreshCandidatePanelIfActive()
                return
            }
            settings.record(.sentenceScriptMismatch)
            refreshCandidatePanelIfActive()
            return
        case .idle,
             .analyzing,
             .cloudAnalyzing,
             .cloudSameTopCandidate,
             .cloudBelowConfidence,
             .cloudFailure,
             .unavailable,
             .failure:
            settings.record(.invalidResult)
            semanticPresentation = .failure
            refreshCandidatePanelIfActive()
            return
        case .candidate:
            break
        case .inputTooLong:
            settings.record(.invalidResult)
            semanticPresentation = .failure
            refreshCandidatePanelIfActive()
            return
        }
        let candidate = result.displayCandidate
        guard let decision = result.resolvedDecision else {
            settings.record(.invalidResult)
            semanticPresentation = .failure
            refreshCandidatePanelIfActive()
            return
        }
        guard !candidate.isEmpty,
              !candidate.contains("\n"),
              composition.applySemanticCandidate(
                  candidate,
                  token: token,
                  decision: decision
              )
        else {
            settings.record(.invalidResult)
            semanticPresentation = .failure
            refreshCandidatePanelIfActive()
            return
        }
        semanticHistorySource = .localSemantic
        semanticCloudCandidate = nil
        settings.record(.resultShown)
        if decision == .sentenceSuggestion {
            settings.record(.sentenceSuggestionShown)
        } else {
            settings.record(.rankedCandidateShown)
        }
        refreshCandidatePanelIfActive()
    }

    private func renderCandidatePanel(client: any IMKTextInput) {
        let pageOffset = composition.candidatePage
            * CompositionState.candidatesPerPage
        candidatePanel.update(
            visibleCandidates: composition.visibleMainCandidates,
            primaryCandidate: composition.mainCandidates.first,
            pageLabel: composition.candidatePageCount > 1
                ? "\(composition.candidatePage + 1)/\(composition.candidatePageCount)"
                : nil,
            semanticPresentation: semanticPresentation,
            suggestionSource: semanticHistorySource,
            contextCharacterCount: semanticContextCharacterCount,
            cloudInFlight: cloudInFlight,
            onMainSelection: { [weak self] localIndex in
                guard let self,
                      let client = self.activeClientObject
                        as? any IMKTextInput
                else {
                    return
                }
                self.selectMainCandidate(
                    index: pageOffset + localIndex,
                    client: client
                )
            },
            onSemanticSelection: { [weak self] in
                guard let self,
                      let candidate = self.composition.semanticCandidate,
                      let client = self.activeClientObject
                        as? any IMKTextInput
                else {
                    return
                }
                self.selectSemanticCandidate(candidate, client: client)
            }
        )
        candidatePanel.show(anchorRect: cursorAnchorRect(
            client: client,
            characterIndex: 0
        ))
    }

    private func cursorAnchorRect(
        client: any IMKTextInput,
        characterIndex: Int
    ) -> NSRect {
        var cursorRect = NSRect.zero
        _ = client.attributes(
            forCharacterIndex: max(0, characterIndex),
            lineHeightRectangle: &cursorRect
        )
        if cursorRect.isEmpty {
            cursorRect = NSRect(
                origin: NSEvent.mouseLocation,
                size: NSSize(width: 1, height: 20)
            )
        }
        return cursorRect
    }

    private func voiceCaretRect(
        client: any IMKTextInput,
        characterIndex: Int
    ) -> NSRect? {
        var caretRect = NSRect.zero
        _ = client.attributes(
            forCharacterIndex: max(0, characterIndex),
            lineHeightRectangle: &caretRect
        )
        guard !caretRect.isEmpty,
              caretRect.origin.x.isFinite,
              caretRect.origin.y.isFinite,
              caretRect.size.width.isFinite,
              caretRect.size.height.isFinite
        else {
            return nil
        }
        return caretRect
    }

    private func selectMainCandidate(
        index: Int,
        client: any IMKTextInput,
        acceptedViaSemanticCandidate: Bool = false
    ) {
        guard !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            enterSecureInput(client: client)
            return
        }
        guard composition.mainCandidates.indices.contains(index) else {
            return
        }
        let originalInput = composition.pinyin
        let pinyin = originalInput.lowercased()
        let fallback = composition.mainCandidates[index]
        let semanticDecision = acceptedViaSemanticCandidate
            ? composition.semanticCandidateDecision
            : nil
        composition.beginSelection()
        invalidateInference()
        guard let transition = RimeEngine.shared.selectCandidate(
            pinyin: pinyin,
            index: index,
            expectedText: fallback
        ) else {
            settings.record(.invalidResult)
            compositionInput(originalInput, client: client)
            return
        }
        let historySource = acceptedViaSemanticCandidate
            ? semanticHistorySource
            : .rimeMain
        guard applyCandidateSelection(
            transition,
            expectedText: fallback,
            source: historySource,
            client: client
        ) else {
            return
        }
        if acceptedViaSemanticCandidate {
            recordSemanticAcceptance(decision: semanticDecision)
        } else {
            settings.record(.mainAccepted)
        }
    }

    private func selectSemanticCandidate(
        _ candidate: String,
        client: any IMKTextInput
    ) {
        guard !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            enterSecureInput(client: client)
            return
        }
        // 最后一道字形关口：能转换就转换（与展示一致），仅无法转换
        // 时拒绝上屏。
        guard let committedDisplay = SemanticCandidateScriptPolicy.sanitized(
            text: candidate,
            characterSet: settings.characterSet
        ) else {
            settings.record(.sentenceScriptMismatch)
            return
        }
        let candidate = committedDisplay
        let decision = composition.semanticCandidateDecision
        if decision != .mixedComposition,
           let index = composition.mainCandidates.firstIndex(of: candidate)
        {
            selectMainCandidate(
                index: index,
                client: client,
                acceptedViaSemanticCandidate: true
            )
            return
        }
        let originalInput = composition.pinyin
        let cloudCandidate = semanticCloudCandidate?.text == candidate
            ? semanticCloudCandidate
            : nil
        let acceptedMixedSuggestion = decision == .mixedComposition
            ? mixedCompositionSuggestion
            : nil
        composition.beginSelection()
        invalidateInference()
        var learnedEnglishTokens = Set<String>()
        if let acceptedMixedSuggestion {
            learnedEnglishTokens = Set(
                acceptedMixedSuggestion.segments
                    .filter { $0.kind == .ascii }
                    .map { $0.rawText.lowercased() }
            )
        }
        let committedCandidate: String
        let rimeCommitResult: String?
        if let cloudCandidate,
           let rimeIndex = cloudCandidate.rimeIndex
        {
            guard let transition = RimeEngine.shared.selectCandidate(
                pinyin: cloudCandidate.alignedPinyin,
                index: rimeIndex,
                expectedText: candidate
            ), transition.remainingInput == nil,
              transition.committedText == candidate
            else {
                settings.record(.invalidResult)
                compositionInput(originalInput, client: client)
                return
            }
            rimeCommitResult = transition.committedText
            committedCandidate = transition.committedText
        } else {
            rimeCommitResult = nil
            committedCandidate = candidate
        }
        guard commitText(
            composition.committedPrefixText + committedCandidate,
            source: semanticHistorySource,
            client: client,
            historyPinyin: composition.prefixHistoryPinyin + originalInput
        ) else {
            return
        }
        recordVoiceHotwordFromRimeCommit(
            rimeCommitResult,
            matching: candidate,
            client: client
        )
        recordSemanticAcceptance(decision: decision)
        if !learnedEnglishTokens.isEmpty {
            settings.learnPersonalEnglishTokens(learnedEnglishTokens)
        }
    }

    private func recordSemanticAcceptance(
        decision: SemanticInferenceDecision?
    ) {
        settings.record(.semanticAccepted)
        if semanticHistorySource == .cloudExact
            || semanticHistorySource == .cloudFuzzy
            || semanticHistorySource == .cloudGenerated
        {
            settings.record(.cloudSuggestionAccepted)
        }
        if semanticHistorySource == .cloudFuzzy {
            settings.record(.cloudCorrectionAccepted)
        }
        if semanticHistorySource == .cloudGenerated {
            settings.record(.cloudGeneratedAccepted)
        }
        if decision == .sentenceSuggestion {
            settings.record(.semanticSentenceAccepted)
        } else if decision == .mixedComposition {
            settings.record(.mixedCompositionAccepted)
        } else {
            settings.record(.semanticRankedAccepted)
        }
    }

    private func refreshCandidatePanelIfActive() {
        guard let client = activeClientObject as? any IMKTextInput,
              !composition.pinyin.isEmpty
        else {
            return
        }
        renderCandidatePanel(client: client)
    }

    @discardableResult
    private func applyCandidateSelection(
        _ transition: CandidateSelectionTransition,
        expectedText: String,
        source: HistoryCommitSource,
        client: any IMKTextInput
    ) -> Bool {
        CandidateSelectionApplicationTransition.apply(
            transition,
            secureInputIsActive: { [self] in
                composition.isSecureInput || IsSecureEventInputEnabled()
            },
            cancelForSecureInput: { [self] in
                enterSecureInput(client: client)
            },
            insertConfirmedPrefix: { [self] text, pinyin in
                let fullText = composition.committedPrefixText + text
                let fullPinyin = composition.prefixHistoryPinyin + pinyin
                let inserted = insertCommittedText(
                    fullText,
                    pinyin: fullPinyin,
                    source: source,
                    client: client
                )
                if inserted {
                    // 前缀已并入正式文本：立即冲刷，防止后续提交把
                    // 同一段内容二次插入。
                    composition.flushPrefix()
                }
                return inserted
            },
            retainMarkedComposition: { [self] remainingInput in
                compositionInput(
                    remainingInput,
                    client: client,
                    preserveInputOnLookupFailure: true
                )
            },
            resetComposition: { [self] in
                resetComposition(client: client, preserveContext: true)
            },
            recordConfirmedHotword: { [self] text in
                recordVoiceHotwordFromRimeCommit(
                    text,
                    matching: expectedText,
                    client: client
                )
            }
        )
    }

    @discardableResult
    private func commitText(
        _ text: String,
        source: HistoryCommitSource,
        client: any IMKTextInput,
        historyPinyin: String
    ) -> Bool {
        guard insertCommittedText(
            text,
            pinyin: historyPinyin,
            source: source,
            client: client
        ) else {
            return false
        }
        resetComposition(client: client, preserveContext: true)
        return true
    }

    private func insertCommittedText(
        _ text: String,
        pinyin: String,
        source: HistoryCommitSource,
        client: any IMKTextInput
    ) -> Bool {
        guard !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            enterSecureInput(client: client)
            return false
        }
        let bundleIdentifier = currentBundleIdentifier
            ?? client.bundleIdentifier()
            ?? "unknown-client"
        let historyWasAllowedBeforeCommit = settings.shouldCaptureCloudHistory(
            isSecureInput: composition.isSecureInput
                || IsSecureEventInputEnabled()
        )
        guard !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            enterSecureInput(client: client)
            return false
        }
        client.insertText(text, replacementRange: notFoundRange)
        guard !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            enterSecureInput(client: client)
            return false
        }
        if let currentBundleIdentifier,
           settings.isAIAllowed(for: currentBundleIdentifier),
           settings.contextPolicy(for: currentBundleIdentifier) != .strict
        {
            Self.contextStore.appendCommittedText(text)
        } else {
            Self.contextStore.deactivate()
        }
        let shouldCaptureHistory = historyWasAllowedBeforeCommit
            && settings.shouldCaptureCloudHistory(
                isSecureInput: composition.isSecureInput
                    || IsSecureEventInputEnabled()
            )
        if shouldCaptureHistory {
            RimeAIHistoryService.shared.appendAsync(
                HistoryCommit(
                    bundleIdentifier: bundleIdentifier,
                    pinyin: pinyin,
                    committedText: text,
                    source: source
                )
            ) { [settings] result in
                switch result {
                case .success:
                    settings.record(.historyRecorded)
                case .failure:
                    settings.record(.historyWriteFailed)
                }
            }
        }
        return true
    }

    private func resetComposition(
        client: any IMKTextInput,
        preserveContext: Bool = true
    ) {
        invalidateInference(clearPresentation: true)
        composition.reset()
        mixedCompositionSuggestion = nil
        client.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: notFoundRange
        )
        candidatePanel.hide()
        if !preserveContext {
            Self.contextStore.deactivate()
        }
        configureVoiceHotKey()
    }

    private func enterSecureInput(client: any IMKTextInput) {
        VoiceDictationRuntime.shared.secureInputChanged(
            active: true,
            owner: self
        )
        VoiceHotKeyManager.shared.deactivate(owner: self)
        voiceHotKeyIsRegistered = false
        invalidateInference(clearPresentation: true)
        composition.enterSecureInput()
        Self.contextStore.enterSecureInput()
        voiceHotwordAdmission.enterSecureInput()
        client.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: notFoundRange
        )
        candidatePanel.hide()
        settings.record(.privacyBlocked)
    }

    private func enterSecureInputIfPossible() {
        guard let client = activeClientObject as? any IMKTextInput else {
            VoiceDictationRuntime.shared.secureInputChanged(
                active: true,
                owner: self
            )
            VoiceHotKeyManager.shared.deactivate(owner: self)
            voiceHotKeyIsRegistered = false
            invalidateInference(clearPresentation: true)
            composition.enterSecureInput()
            Self.contextStore.enterSecureInput()
            voiceHotwordAdmission.enterSecureInput()
            return
        }
        enterSecureInput(client: client)
    }

    private func invalidateCurrentResult() {
        composition.beginSelection()
        invalidateInference(clearPresentation: true)
        if let client = activeClientObject as? any IMKTextInput,
           !composition.pinyin.isEmpty
        {
            renderCandidatePanel(client: client)
        }
    }

    private func invalidateInference(clearPresentation: Bool = false) {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        cloudDebounceWorkItem?.cancel()
        cloudDebounceWorkItem = nil
        cloudInFlight = false
        if let pendingRequestID {
            DaemonClient.shared.cancel(requestID: pendingRequestID)
            settings.record(.requestCancelled)
            self.pendingRequestID = nil
        }
        if let pendingCloudRequestID {
            CloudBrokerClient.shared.cancel(requestID: pendingCloudRequestID)
            self.pendingCloudRequestID = nil
        }
        pendingCloudBuildCancellation?.cancel()
        pendingCloudBuildCancellation = nil
        pendingRequestStartedAt = nil
        if clearPresentation {
            semanticPresentation = .idle
            semanticContextCharacterCount = 0
            semanticHistorySource = .localSemantic
            semanticCloudCandidate = nil
            cloudSuggestionApplied = false
            mixedCompositionSuggestion = nil
        }
    }

    private func inferenceContext(
        policy: ContextPolicy,
        client: any IMKTextInput
    ) -> String {
        switch policy {
        case .strict:
            return ""
        case .standard:
            return Self.contextStore.context(
                for: currentBundleIdentifier ?? "unknown-client"
            )
        case .smart:
            let cursorContext = cursorPrecedingContext(client: client)
            if !cursorContext.isEmpty {
                return cursorContext
            }
            return Self.contextStore.context(
                for: currentBundleIdentifier ?? "unknown-client"
            )
        }
    }

    private func cursorPrecedingContext(
        client: any IMKTextInput
    ) -> String {
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.location > 0 else {
            return ""
        }
        let length = min(selection.location, 400)
        let range = NSRange(
            location: selection.location - length,
            length: length
        )
        guard let substring = client.attributedSubstring(from: range) else {
            return ""
        }
        return String(substring.string.suffix(400))
    }

    private func observeSettings() {
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

    private func applyChangedSettings() {
        RimeEngine.shared.apply(settings.inputPreferences)
        if !settings.voiceEnabled {
            cancelVoiceDictation()
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
            if pendingCloudRequestID != nil {
                invalidateCurrentResult()
            }
            CloudBrokerClient.shared.disconnect()
        }
    }

    // MARK: - VoiceDictationRuntimeOwner

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

    private func voiceRectsMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        let tolerance: CGFloat = 1
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func transformedLiteral(_ literal: String) -> String? {
        RimeAIInputTextTransformer.transformedLiteral(
            literal,
            preferences: settings.inputPreferences
        )
    }

    private func clearEphemeralData() {
        cancelVoiceDictation()
        voiceHotwordAdmission.clear()
        historyEnglishTokensGeneration &+= 1
        historyEnglishTokens = []
        historyEnglishTokensLoaded = false
        historyEnglishTokensLoading = false
        invalidateCurrentResult()
        clearContextForCurrentApplication()
    }

    private func clearContextForCurrentApplication() {
        Self.contextStore.deactivate()
        if activeClientObject != nil, let currentBundleIdentifier {
            Self.contextStore.activate(
                sessionID: currentBundleIdentifier,
                ownerID: sessionNonce
            )
        }
    }

    private var notFoundRange: NSRange {
        NSRange(location: NSNotFound, length: NSNotFound)
    }

    private func acceptedCompositionCharacter(
        from characters: String
    ) -> Character? {
        guard characters.count == 1,
              let character = characters.first,
              character == "'" || character.isASCII && character.isLetter
        else {
            return nil
        }
        return character
    }

    private func numericCandidateIndex(
        from characters: String
    ) -> Int? {
        guard characters.count == 1,
              let character = characters.first,
              character.isNumber
        else {
            return nil
        }
        if character == "0" {
            return 9
        }
        guard let value = character.wholeNumberValue else {
            return nil
        }
        return value - 1
    }
}
