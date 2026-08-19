import AppKit
import Carbon
import InputMethodKit

@objc(RimeAIInputController)
@MainActor
final class RimeAIInputController: IMKInputController, @unchecked Sendable {
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
    private var pendingRequestID: String?
    private var pendingRequestStartedAt: TimeInterval?
    private var pendingCloudRequestID: String?
    private var pendingCloudBuildCancellation: CloudCandidateBuildCancellation?
    private var cloudDeadlineAt: TimeInterval?
    private var semanticPresentation: SemanticCandidatePresentation = .idle
    private var semanticHistorySource: HistoryCommitSource = .localSemantic
    private var semanticCloudCandidate: CloudCandidate?
    private var cloudSuggestionApplied = false
    private var semanticContextCharacterCount = 0
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
            if IsSecureEventInputEnabled() {
                enterSecureInput(client: client)
            }
        }
    }

    override nonisolated func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated {
            invalidateInference(clearPresentation: true)
            candidatePanel.hide()
            composition.reset()
            Self.contextStore.suspend(ownerID: sessionNonce)
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
            Self.contextStore.activate(
                sessionID: client.bundleIdentifier() ?? "unknown-client",
                ownerID: sessionNonce
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
            commitText(
                composition.pinyin,
                source: .rawPinyin,
                client: client
            )
            return true
        case 48:
            guard let semanticCandidate = composition.semanticCandidate else {
                return false
            }
            selectSemanticCandidate(semanticCandidate, client: client)
            return true
        case 49:
            if !composition.mainCandidates.isEmpty {
                selectMainCandidate(index: 0, client: client)
                return true
            }
            if let semanticCandidate = composition.semanticCandidate {
                selectSemanticCandidate(semanticCandidate, client: client)
                return true
            }
            guard composition.pinyin.isEmpty else {
                commitText(
                    composition.pinyin,
                    source: .rawPinyin,
                    client: client
                )
                return true
            }
            if let literal = transformedLiteral(" ") {
                client.insertText(literal, replacementRange: notFoundRange)
                return true
            }
            return false
        case 123, 124, 125, 126, 116, 121:
            invalidateCurrentResult()
            clearContextForCurrentApplication()
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
        if let character = acceptedCompositionCharacter(
            from: event.characters ?? characters
        ) {
            compositionInput(
                composition.pinyin + String(character),
                client: client
            )
            return true
        }

        let literal = transformedLiteral(event.characters ?? characters)
        if !composition.pinyin.isEmpty {
            selectMainCandidate(index: 0, client: client)
            if let literal {
                client.insertText(literal, replacementRange: notFoundRange)
                return true
            }
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
        if !composition.mainCandidates.isEmpty {
            selectMainCandidate(index: 0, client: client)
        } else if !composition.pinyin.isEmpty {
            commitText(
                composition.pinyin,
                source: .rawPinyin,
                client: client
            )
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
        Self.contextStore.activate(
            sessionID: bundleIdentifier,
            ownerID: sessionNonce
        )
        if composition.appSessionID != sessionID {
            invalidateInference(clearPresentation: true)
            candidatePanel.hide()
            composition.switchApplicationSession(to: sessionID)
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
        _ rawInput: String,
        client: any IMKTextInput
    ) {
        invalidateInference()
        mixedCompositionSuggestion = nil
        let rimeInput = rawInput.lowercased()
        let candidates = RimeEngine.shared.candidates(
            for: rimeInput,
            limit: 10
        )
        let mixedSuggestion = resolveMixedComposition(
            rawInput: rawInput
        )
        guard !candidates.isEmpty || mixedSuggestion != nil else {
            if composition.pinyin.isEmpty {
                return
            }
            resetComposition(client: client)
            return
        }
        let token = composition.replaceInput(
            pinyin: rawInput,
            candidates: candidates
        )
        semanticHistorySource = .localSemantic
        semanticCloudCandidate = nil
        cloudSuggestionApplied = false
        client.setMarkedText(
            rawInput,
            selectionRange: NSRange(
                location: rawInput.utf16.count,
                length: 0
            ),
            replacementRange: notFoundRange
        )
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
                if cloudAllowed {
                    self.buildAndSendCloudInference(
                        pinyin: pinyin,
                        bundleIdentifier: currentBundleIdentifier,
                        token: token,
                        localRequestWasScheduled: localRequest != nil
                    )
                }
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
        cloudDeadlineAt = deadlineAt
        settings.record(.cloudRequestStarted)
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
                    self.cloudDeadlineAt = nil
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
                cancellation: buildCancellation
            )
            let historyService = RimeAIHistoryService.shared
            let historySnapshot = try? historyService.contextSnapshot(
                    query: pinyin,
                    maxRecentCharacters: 600,
                    maximumSnippetCount: 8
                )
            let remainingMilliseconds = max(
                1,
                min(
                    800,
                    Int(
                        (
                            deadlineAt
                                - ProcessInfo.processInfo.systemUptime
                        ) * 1_000
                    )
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
                        self.cloudDeadlineAt = nil
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
            return
        }
        pendingCloudRequestID = nil
        cloudDeadlineAt = nil
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
        guard let candidate = result.selectedCandidate(for: request),
              let confidence = result.confidence
        else {
            applyCloudFallback(
                localRequestWasScheduled: localRequestWasScheduled,
                decision: result.decision
            )
            return
        }
        guard composition.applySemanticCandidate(
            candidate.text,
            token: token,
            decision: .rankedCandidate
        ) else {
            settings.record(.cloudInvalidResult)
            return
        }
        semanticHistorySource = candidate.source == .rimeFuzzy
            ? .cloudFuzzy
            : .cloudExact
        semanticCloudCandidate = candidate
        cloudSuggestionApplied = true
        semanticPresentation = .candidate(
            text: candidate.text,
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
        candidatePanel.update(
            mainCandidates: composition.mainCandidates,
            semanticPresentation: semanticPresentation,
            suggestionSource: semanticHistorySource,
            contextCharacterCount: semanticContextCharacterCount,
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
        guard !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            enterSecureInput(client: client)
            return
        }
        guard composition.mainCandidates.indices.contains(index) else {
            return
        }
        let pinyin = composition.pinyin.lowercased()
        let fallback = composition.mainCandidates[index]
        let semanticDecision = acceptedViaSemanticCandidate
            ? composition.semanticCandidateDecision
            : nil
        composition.beginSelection()
        invalidateInference()
        let committed = RimeEngine.shared.commitCandidate(
            pinyin: pinyin,
            index: index
        ) ?? fallback
        if acceptedViaSemanticCandidate {
            recordSemanticAcceptance(decision: semanticDecision)
        } else {
            settings.record(.mainAccepted)
        }
        let historySource = acceptedViaSemanticCandidate
            ? semanticHistorySource
            : .rimeMain
        commitText(
            committed,
            source: historySource,
            client: client
        )
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
        let cloudCandidate = semanticCloudCandidate?.text == candidate
            ? semanticCloudCandidate
            : nil
        let acceptedMixedSuggestion = decision == .mixedComposition
            ? mixedCompositionSuggestion
            : nil
        composition.beginSelection()
        invalidateInference()
        recordSemanticAcceptance(decision: decision)
        if let acceptedMixedSuggestion {
            let tokens = Set(
                acceptedMixedSuggestion.segments
                    .filter { $0.kind == .ascii }
                    .map { $0.rawText.lowercased() }
            )
            settings.learnPersonalEnglishTokens(tokens)
        }
        let committedCandidate: String
        if let cloudCandidate,
           let rimeIndex = cloudCandidate.rimeIndex
        {
            let committed = RimeEngine.shared.commitCandidate(
                pinyin: cloudCandidate.alignedPinyin,
                index: rimeIndex
            )
            committedCandidate = committed == candidate
                ? committed ?? candidate
                : candidate
        } else {
            committedCandidate = candidate
        }
        commitText(
            committedCandidate,
            source: semanticHistorySource,
            client: client
        )
    }

    private func recordSemanticAcceptance(
        decision: SemanticInferenceDecision?
    ) {
        settings.record(.semanticAccepted)
        if semanticHistorySource == .cloudExact
            || semanticHistorySource == .cloudFuzzy
        {
            settings.record(.cloudSuggestionAccepted)
        }
        if semanticHistorySource == .cloudFuzzy {
            settings.record(.cloudCorrectionAccepted)
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

    private func commitText(
        _ text: String,
        source: HistoryCommitSource,
        client: any IMKTextInput
    ) {
        guard !composition.isSecureInput,
              !IsSecureEventInputEnabled()
        else {
            enterSecureInput(client: client)
            return
        }
        let pinyin = composition.pinyin
        let bundleIdentifier = currentBundleIdentifier
            ?? client.bundleIdentifier()
            ?? "unknown-client"
        let historyWasAllowedBeforeCommit = settings.shouldCaptureCloudHistory(
            isSecureInput: composition.isSecureInput
                || IsSecureEventInputEnabled()
        )
        client.insertText(text, replacementRange: notFoundRange)
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
        resetComposition(client: client, preserveContext: true)
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
    }

    private func enterSecureInput(client: any IMKTextInput) {
        invalidateInference(clearPresentation: true)
        composition.enterSecureInput()
        Self.contextStore.enterSecureInput()
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
            invalidateInference(clearPresentation: true)
            composition.enterSecureInput()
            Self.contextStore.enterSecureInput()
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
        cloudDeadlineAt = nil
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
        settingsObservers = [settingsObserver, clearObserver]
    }

    private func applyChangedSettings() {
        RimeEngine.shared.apply(settings.inputPreferences)
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
        if !settings.isAIAllowed(for: currentBundleIdentifier) {
            DaemonClient.shared.disconnect()
        }
        if !settings.cloudConfigured {
            if pendingCloudRequestID != nil {
                invalidateCurrentResult()
            }
            CloudBrokerClient.shared.disconnect()
        }
    }

    private func transformedLiteral(_ literal: String) -> String? {
        RimeAIInputTextTransformer.transformedLiteral(
            literal,
            preferences: settings.inputPreferences
        )
    }

    private func clearEphemeralData() {
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
