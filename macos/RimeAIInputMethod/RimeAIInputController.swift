import AppKit
import Carbon
import InputMethodKit

@objc(RimeAIInputController)
@MainActor
final class RimeAIInputController: IMKInputController, @unchecked Sendable {
    private let sessionNonce = UUID().uuidString
    private let candidatePanel: CandidatePanelController
    private var composition = CompositionState(appSessionID: "inactive")
    private var contextStore = SessionContextStore(maxCharacters: 100)
    private var debounceWorkItem: DispatchWorkItem?
    private var pendingRequestID: String?
    private var pendingRequestStartedAt: TimeInterval?
    private weak var activeClientObject: AnyObject?
    private var currentBundleIdentifier: String?
    private var settingsObservers: [NSObjectProtocol] = []
    private let settings = RimeAISettingsStore.shared

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
    }

    override nonisolated func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        MainActor.assumeIsolated {
            guard let client = sender as? any IMKTextInput else {
                return
            }
            activeClientObject = sender as AnyObject
            activateSession(for: client)
        }
    }

    override nonisolated func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated {
            invalidateInference()
            candidatePanel.hide()
            composition.reset()
            contextStore.deactivate()
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
        activeClientObject = sender as AnyObject
        activateSession(for: client)

        if IsSecureEventInputEnabled() {
            enterSecureInput(client: client)
            return false
        }
        if composition.isSecureInput {
            composition.switchApplicationSession(
                to: applicationSessionID(for: client)
            )
            contextStore.activate(
                sessionID: applicationSessionID(for: client)
            )
        }

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
            guard !composition.pinyin.isEmpty else {
                return false
            }
            resetComposition(client: client)
            return true
        case 36, 76:
            guard !composition.pinyin.isEmpty else {
                return false
            }
            commitText(composition.pinyin, client: client)
            return true
        case 48:
            guard let semanticCandidate = composition.semanticCandidate else {
                return false
            }
            selectSemanticCandidate(semanticCandidate, client: client)
            return true
        case 49:
            guard !composition.mainCandidates.isEmpty else {
                return false
            }
            selectMainCandidate(index: 0, client: client)
            return true
        case 123, 124, 125, 126, 116, 121:
            invalidateCurrentResult()
            return false
        default:
            break
        }

        let characters = event.charactersIgnoringModifiers ?? ""
        if let candidateIndex = numericCandidateIndex(from: characters),
           !composition.pinyin.isEmpty
        {
            guard candidateIndex < composition.mainCandidates.count else {
                return true
            }
            selectMainCandidate(index: candidateIndex, client: client)
            return true
        }

        if event.modifierFlags.contains(.shift),
           composition.pinyin.isEmpty
        {
            return false
        }
        if let character = acceptedPinyinCharacter(from: characters) {
            compositionInput(
                composition.pinyin + String(character),
                client: client
            )
            return true
        }

        if !composition.pinyin.isEmpty {
            selectMainCandidate(index: 0, client: client)
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
        if !composition.mainCandidates.isEmpty {
            selectMainCandidate(index: 0, client: client)
        } else if !composition.pinyin.isEmpty {
            commitText(composition.pinyin, client: client)
        }
    }

    override nonisolated func composedString(_ sender: Any!) -> Any! {
        MainActor.assumeIsolated {
            composition.pinyin
        }
    }

    override nonisolated func originalString(
        _ sender: Any!
    ) -> NSAttributedString! {
        let original = MainActor.assumeIsolated {
            composition.pinyin
        }
        return NSAttributedString(string: original)
    }

    override nonisolated func candidates(_ sender: Any!) -> [Any]! {
        MainActor.assumeIsolated {
            composition.mainCandidates
        }
    }

    override nonisolated func menu() -> NSMenu! {
        let menu = NSMenu(title: "RimeAI")
        let privacyItem = NSMenuItem(
            title: "RimeAI 隐私控制中心…",
            action: #selector(showPrivacyCenter(_:)),
            keyEquivalent: ","
        )
        privacyItem.target = self
        menu.addItem(privacyItem)
        return menu
    }

    @objc private func showPrivacyCenter(_ sender: Any?) {
        PrivacyCenterWindowController.shared.showWindow()
    }

    private func activateSession(for client: any IMKTextInput) {
        let bundleIdentifier = client.bundleIdentifier()
            ?? "unknown-client"
        currentBundleIdentifier = bundleIdentifier
        let sessionID = applicationSessionID(for: client)
        if composition.appSessionID != sessionID {
            invalidateInference()
            candidatePanel.hide()
            composition.switchApplicationSession(to: sessionID)
            contextStore.activate(sessionID: sessionID)
        }
    }

    private func applicationSessionID(
        for client: any IMKTextInput
    ) -> String {
        let bundleIdentifier = client.bundleIdentifier()
            ?? "unknown-client"
        return "\(bundleIdentifier)#\(sessionNonce)"
    }

    private func compositionInput(
        _ pinyin: String,
        client: any IMKTextInput
    ) {
        invalidateInference()
        let candidates = RimeEngine.shared.candidates(
            for: pinyin,
            limit: 10
        )
        guard !candidates.isEmpty else {
            if composition.pinyin.isEmpty {
                return
            }
            resetComposition(client: client)
            return
        }
        let token = composition.replaceInput(
            pinyin: pinyin,
            candidates: candidates
        )
        client.setMarkedText(
            pinyin,
            selectionRange: NSRange(location: pinyin.utf16.count, length: 0),
            replacementRange: notFoundRange
        )
        renderCandidatePanel(client: client)
        scheduleInference(token: token, client: client)
    }

    private func deleteBackward(client: any IMKTextInput) -> Bool {
        guard !composition.pinyin.isEmpty else {
            return false
        }
        var updated = composition.pinyin
        updated.removeLast()
        if updated.isEmpty {
            resetComposition(client: client)
        } else {
            compositionInput(updated, client: client)
        }
        return true
    }

    private func scheduleInference(
        token: CompositionToken,
        client: any IMKTextInput
    ) {
        guard let currentBundleIdentifier,
              settings.isAIAllowed(for: currentBundleIdentifier),
              !composition.isSecureInput
        else {
            settings.record(.privacyBlocked)
            return
        }
        let requestID = UUID().uuidString
        let contextPolicy = settings.contextPolicy(
            for: currentBundleIdentifier
        )
        let request = SemanticInferenceRequest(
            requestID: requestID,
            token: token,
            contextPolicy: contextPolicy,
            context: inferenceContext(
                policy: contextPolicy,
                token: token,
                client: client
            ),
            pinyin: composition.pinyin,
            candidates: composition.mainCandidates,
            deadlineMilliseconds: 400,
            allowSentence: composition.pinyin.count >= 8
        )
        settings.record(.requestStarted)
        pendingRequestID = requestID
        pendingRequestStartedAt = ProcessInfo.processInfo.systemUptime
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.composition.token == token,
                      !self.composition.isSelecting,
                      !self.composition.isSecureInput
                else {
                    return
                }
                self.sendInference(
                    request,
                    requestID: requestID,
                    token: token
                )
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(100),
            execute: workItem
        )
    }

    private func sendInference(
        _ request: SemanticInferenceRequest,
        requestID: String,
        token: CompositionToken
    ) {
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

    private func applyInferenceResult(
        _ result: SemanticInferenceResult?,
        requestID: String,
        token: CompositionToken
    ) {
        guard pendingRequestID == requestID else {
            settings.record(.resultRejected)
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
        guard let result else {
            settings.record(.daemonFailure)
            return
        }
        guard result.isDisplayable(
            for: token,
            candidates: composition.mainCandidates
        )
        else {
            if result.status == "timeout" {
                settings.record(.timeout)
            } else if result.status == "circuit_open" {
                settings.record(.circuitOpen)
            } else {
                settings.record(.resultRejected)
            }
            return
        }
        let candidate = result.displayCandidate
        guard !candidate.isEmpty,
              candidate.count <= 30,
              !candidate.contains("\n"),
              composition.applySemanticCandidate(candidate, token: token)
        else {
            settings.record(.resultRejected)
            return
        }
        settings.record(.resultShown)
        if let client = activeClientObject as? any IMKTextInput {
            renderCandidatePanel(client: client)
        }
    }

    private func renderCandidatePanel(client: any IMKTextInput) {
        candidatePanel.update(
            mainCandidates: composition.mainCandidates,
            semanticCandidate: composition.semanticCandidate,
            onMainSelection: { [weak self] index in
                guard let self,
                      let client = self.activeClientObject
                        as? any IMKTextInput
                else {
                    return
                }
                self.selectMainCandidate(index: index, client: client)
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
        var cursorRect = NSRect.zero
        _ = client.attributes(
            forCharacterIndex: 0,
            lineHeightRectangle: &cursorRect
        )
        if cursorRect.isEmpty {
            cursorRect = NSRect(
                origin: NSEvent.mouseLocation,
                size: NSSize(width: 1, height: 20)
            )
        }
        candidatePanel.show(anchorRect: cursorRect)
    }

    private func selectMainCandidate(
        index: Int,
        client: any IMKTextInput,
        acceptedViaSemanticCandidate: Bool = false
    ) {
        guard composition.mainCandidates.indices.contains(index) else {
            return
        }
        let pinyin = composition.pinyin
        let fallback = composition.mainCandidates[index]
        composition.beginSelection()
        invalidateInference()
        let committed = RimeEngine.shared.commitCandidate(
            pinyin: pinyin,
            index: index
        ) ?? fallback
        settings.record(
            acceptedViaSemanticCandidate
                ? .semanticAccepted
                : .mainAccepted
        )
        commitText(committed, client: client)
    }

    private func selectSemanticCandidate(
        _ candidate: String,
        client: any IMKTextInput
    ) {
        if let index = composition.mainCandidates.firstIndex(of: candidate) {
            selectMainCandidate(
                index: index,
                client: client,
                acceptedViaSemanticCandidate: true
            )
            return
        }
        composition.beginSelection()
        invalidateInference()
        settings.record(.semanticAccepted)
        commitText(candidate, client: client)
    }

    private func commitText(
        _ text: String,
        client: any IMKTextInput
    ) {
        client.insertText(text, replacementRange: notFoundRange)
        contextStore.appendCommittedText(text)
        resetComposition(client: client, preserveContext: true)
    }

    private func resetComposition(
        client: any IMKTextInput,
        preserveContext: Bool = true
    ) {
        invalidateInference()
        composition.reset()
        client.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: notFoundRange
        )
        candidatePanel.hide()
        if !preserveContext {
            contextStore.deactivate()
        }
    }

    private func enterSecureInput(client: any IMKTextInput) {
        invalidateInference()
        composition.enterSecureInput()
        contextStore.enterSecureInput()
        client.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: notFoundRange
        )
        candidatePanel.hide()
        settings.record(.privacyBlocked)
    }

    private func invalidateCurrentResult() {
        composition.beginSelection()
        invalidateInference()
        if let client = activeClientObject as? any IMKTextInput,
           !composition.pinyin.isEmpty
        {
            renderCandidatePanel(client: client)
        }
    }

    private func invalidateInference() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let pendingRequestID {
            DaemonClient.shared.cancel(requestID: pendingRequestID)
            settings.record(.requestCancelled)
            self.pendingRequestID = nil
        }
        pendingRequestStartedAt = nil
    }

    private func inferenceContext(
        policy: ContextPolicy,
        token: CompositionToken,
        client: any IMKTextInput
    ) -> String {
        switch policy {
        case .strict:
            return ""
        case .standard:
            return contextStore.context(for: token.appSessionID)
        case .smart:
            let cursorContext = cursorPrecedingContext(client: client)
            if !cursorContext.isEmpty {
                return cursorContext
            }
            return contextStore.context(for: token.appSessionID)
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
        settingsObservers = [settingsObserver, clearObserver]
    }

    private func applyChangedSettings() {
        guard let currentBundleIdentifier else {
            return
        }
        if !settings.isAIAllowed(for: currentBundleIdentifier) {
            invalidateCurrentResult()
            DaemonClient.shared.disconnect()
        }
    }

    private func clearEphemeralData() {
        invalidateCurrentResult()
        contextStore.deactivate()
        if !composition.appSessionID.isEmpty {
            contextStore.activate(sessionID: composition.appSessionID)
        }
    }

    private var notFoundRange: NSRange {
        NSRange(location: NSNotFound, length: NSNotFound)
    }

    private func acceptedPinyinCharacter(
        from characters: String
    ) -> Character? {
        guard characters.count == 1,
              let character = characters.lowercased().first,
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
