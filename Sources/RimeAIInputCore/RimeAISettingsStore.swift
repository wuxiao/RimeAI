import Foundation

public extension Notification.Name {
    static let rimeAISettingsDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.settings-did-change"
    )
    static let rimeAIClearEphemeralData = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.clear-ephemeral-data"
    )
    static let rimeAIDiagnosticsDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.diagnostics-did-change"
    )
}

public enum RimeAIDiagnosticEvent: String, CaseIterable, Codable, Sendable {
    case requestStarted = "request_started"
    case requestCancelled = "request_cancelled"
    case resultShown = "result_shown"
    case resultRejected = "result_rejected"
    case staleResult = "stale_result"
    case invalidResult = "invalid_result"
    case sameTopCandidate = "same_top_candidate"
    case insufficientCandidates = "insufficient_candidates"
    case belowConfidence = "below_confidence"
    case noCandidate = "no_candidate"
    case rankedCandidateShown = "ranked_candidate_shown"
    case sentenceSuggestionShown = "sentence_suggestion_shown"
    case mixedCompositionShown = "mixed_composition_shown"
    case sentenceTooLong = "sentence_too_long"
    case sentenceIncomplete = "sentence_incomplete"
    case sentenceScriptMismatch = "sentence_script_mismatch"
    case semanticAccepted = "semantic_accepted"
    case semanticRankedAccepted = "semantic_ranked_accepted"
    case semanticSentenceAccepted = "semantic_sentence_accepted"
    case mixedCompositionAccepted = "mixed_composition_accepted"
    case mainAccepted = "main_accepted"
    case privacyBlocked = "privacy_blocked"
    case timeout
    case circuitOpen = "circuit_open"
    case daemonFailure = "daemon_failure"
    case historyRecorded = "history_recorded"
    case historyWriteFailed = "history_write_failed"
    case cloudRequestStarted = "cloud_request_started"
    case cloudSuggestionShown = "cloud_suggestion_shown"
    case cloudSuggestionAccepted = "cloud_suggestion_accepted"
    case cloudCorrectionShown = "cloud_correction_shown"
    case cloudCorrectionAccepted = "cloud_correction_accepted"
    case cloudTimeout = "cloud_timeout"
    case cloudInvalidResult = "cloud_invalid_result"
    case cloudTransportFailure = "cloud_transport_failure"
}

public struct RimeAISettingsExport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let inputPreferences: RimeAIInputPreferences
    public let aiEnabled: Bool
    public let offlineLockEnabled: Bool
    public let cloudConfigured: Bool
    public let cloudProvider: String
    public let cloudEndpoint: String
    public let cloudModelID: String
    public let contextPolicy: ContextPolicy
    public let disabledAIApplications: [String]
    public let disabledContextApplications: [String]
    public let diagnostics: [String: Int]

    public init(
        schemaVersion: Int = 3,
        inputPreferences: RimeAIInputPreferences = RimeAIInputPreferences(),
        aiEnabled: Bool,
        offlineLockEnabled: Bool,
        cloudConfigured: Bool = false,
        cloudProvider: String = RimeAICloudConfiguration.provider,
        cloudEndpoint: String = RimeAICloudConfiguration.endpoint.absoluteString,
        cloudModelID: String = RimeAICloudConfiguration.defaultRankingModelID,
        contextPolicy: ContextPolicy,
        disabledAIApplications: [String],
        disabledContextApplications: [String],
        diagnostics: [String: Int]
    ) {
        self.schemaVersion = schemaVersion
        self.inputPreferences = inputPreferences
        self.aiEnabled = aiEnabled
        self.offlineLockEnabled = offlineLockEnabled
        self.cloudConfigured = cloudConfigured
        self.cloudProvider = cloudProvider
        self.cloudEndpoint = cloudEndpoint
        self.cloudModelID = cloudModelID
        self.contextPolicy = contextPolicy
        self.disabledAIApplications = disabledAIApplications
        self.disabledContextApplications = disabledContextApplications
        self.diagnostics = diagnostics
    }
}

public final class RimeAISettingsStore: @unchecked Sendable {
    public enum Keys {
        public static let aiEnabled = "RimeAIEnabled"
        public static let characterSet = "RimeAICharacterSet"
        public static let characterWidth = "RimeAICharacterWidth"
        public static let punctuationStyle = "RimeAIPunctuationStyle"
        public static let offlineLockEnabled = "RimeAIOfflineLockEnabled"
        public static let cloudConfigured = "RimeAICloudConfigured"
        public static let cloudModelID = "RimeAICloudModelID"
        public static let contextPolicy = "RimeAIContextPolicy"
        public static let disabledAIApplications =
            "RimeAIDisabledAIApplications"
        public static let disabledContextApplications =
            "RimeAIDisabledContextApplications"
        public static let diagnostics = "RimeAIDiagnostics"
        public static let personalEnglishTokens = "RimeAIPersonalEnglishTokens"
    }

    public static let shared = RimeAISettingsStore()

    private let defaults: UserDefaults
    private let diagnosticsLock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var characterSet: RimeAICharacterSetPreference {
        get {
            guard let value = defaults.string(forKey: Keys.characterSet) else {
                return .simplified
            }
            return RimeAICharacterSetPreference(rawValue: value) ?? .simplified
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.characterSet)
            notifySettingsChanged()
        }
    }

    public var characterWidth: RimeAICharacterWidth {
        get {
            guard let value = defaults.string(forKey: Keys.characterWidth) else {
                return .half
            }
            return RimeAICharacterWidth(rawValue: value) ?? .half
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.characterWidth)
            notifySettingsChanged()
        }
    }

    public var punctuationStyle: RimeAIPunctuationStyle {
        get {
            guard let value = defaults.string(forKey: Keys.punctuationStyle)
            else {
                return .chinese
            }
            return RimeAIPunctuationStyle(rawValue: value) ?? .chinese
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.punctuationStyle)
            notifySettingsChanged()
        }
    }

    public var inputPreferences: RimeAIInputPreferences {
        RimeAIInputPreferences(
            characterSet: characterSet,
            characterWidth: characterWidth,
            punctuationStyle: punctuationStyle
        )
    }

    public var personalEnglishTokens: Set<String> {
        Set(
            (defaults.stringArray(forKey: Keys.personalEnglishTokens) ?? [])
                .compactMap(Self.normalizedPersonalEnglishToken)
        )
    }

    public func learnPersonalEnglishTokens(_ tokens: Set<String>) {
        var learned = (defaults.stringArray(forKey: Keys.personalEnglishTokens)
            ?? []).compactMap(Self.normalizedPersonalEnglishToken)
        for token in tokens.compactMap(Self.normalizedPersonalEnglishToken)
            .sorted()
        {
            learned.removeAll { $0 == token }
            learned.append(token)
        }
        defaults.set(
            Array(learned.suffix(256)),
            forKey: Keys.personalEnglishTokens
        )
    }

    public var aiEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.aiEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.aiEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.aiEnabled)
            notifySettingsChanged()
        }
    }

    public var offlineLockEnabled: Bool {
        get { true }
        set {
            // The local daemon's process-wide INET guard is an invariant, not
            // a user-facing switch. Keep the legacy key pinned to true so an
            // older build cannot accidentally present a disabled lock.
            defaults.set(true, forKey: Keys.offlineLockEnabled)
            notifySettingsChanged()
        }
    }

    public var cloudConfigured: Bool {
        get {
            defaults.bool(forKey: Keys.cloudConfigured)
        }
        set {
            defaults.set(newValue, forKey: Keys.cloudConfigured)
            notifySettingsChanged()
        }
    }

    public func reconcileCloudConfiguration(
        hasCredential: Bool?
    ) {
        guard cloudConfigured, hasCredential == false else {
            return
        }
        cloudConfigured = false
    }

    public var cloudModelID: String {
        get {
            guard
                let stored = defaults.string(forKey: Keys.cloudModelID),
                RimeAICloudConfiguration.rankingModelIDs.contains(stored)
            else {
                return RimeAICloudConfiguration.defaultRankingModelID
            }
            return stored
        }
        set {
            let validated = RimeAICloudConfiguration.rankingModelIDs
                .contains(newValue)
                ? newValue
                : RimeAICloudConfiguration.defaultRankingModelID
            defaults.set(validated, forKey: Keys.cloudModelID)
            notifySettingsChanged()
        }
    }

    public func shouldCaptureCloudHistory(
        isSecureInput: Bool
    ) -> Bool {
        cloudConfigured && !isSecureInput
    }

    public var contextPolicy: ContextPolicy {
        get {
            guard
                let rawValue = defaults.string(forKey: Keys.contextPolicy)
            else {
                return .standard
            }
            return ContextPolicy(rawValue: rawValue) ?? .standard
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.contextPolicy)
            notifySettingsChanged()
        }
    }

    public var disabledAIApplications: [String] {
        get {
            normalizedApplications(
                defaults.stringArray(forKey: Keys.disabledAIApplications) ?? []
            )
        }
        set {
            defaults.set(
                normalizedApplications(newValue),
                forKey: Keys.disabledAIApplications
            )
            notifySettingsChanged()
        }
    }

    public var disabledContextApplications: [String] {
        get {
            normalizedApplications(
                defaults.stringArray(
                    forKey: Keys.disabledContextApplications
                ) ?? []
            )
        }
        set {
            defaults.set(
                normalizedApplications(newValue),
                forKey: Keys.disabledContextApplications
            )
            notifySettingsChanged()
        }
    }

    public func isAIAllowed(for bundleIdentifier: String) -> Bool {
        aiEnabled
            && !disabledAIApplications.contains(
                normalizedApplication(bundleIdentifier)
            )
    }

    public func contextPolicy(
        for bundleIdentifier: String
    ) -> ContextPolicy {
        if disabledContextApplications.contains(
            normalizedApplication(bundleIdentifier)
        ) {
            return .strict
        }
        return contextPolicy
    }

    public func record(_ event: RimeAIDiagnosticEvent) {
        incrementDiagnostic(key: event.rawValue)
    }

    public func recordLatency(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else {
            return
        }
        let bucket: String
        switch milliseconds {
        case ..<50:
            bucket = "latency_lt_50_ms"
        case ..<100:
            bucket = "latency_lt_100_ms"
        case ..<250:
            bucket = "latency_lt_250_ms"
        case ..<400:
            bucket = "latency_lt_400_ms"
        default:
            bucket = "latency_gte_400_ms"
        }
        incrementDiagnostic(key: bucket)
    }

    private func incrementDiagnostic(key: String) {
        diagnosticsLock.withLock {
            var diagnostics = loadDiagnostics()
            diagnostics[key, default: 0] += 1
            defaults.set(diagnostics, forKey: Keys.diagnostics)
        }
        notifyDiagnosticsChanged()
    }

    public func diagnosticCount(
        _ event: RimeAIDiagnosticEvent
    ) -> Int {
        diagnosticsLock.withLock {
            loadDiagnostics()[event.rawValue, default: 0]
        }
    }

    public func diagnosticSnapshot() -> [String: Int] {
        diagnosticsLock.withLock {
            loadDiagnostics()
        }
    }

    public func resetDiagnostics() {
        diagnosticsLock.withLock {
            defaults.removeObject(forKey: Keys.diagnostics)
        }
        notifyDiagnosticsChanged()
    }

    public func clearEphemeralData() {
        NotificationCenter.default.post(
            name: .rimeAIClearEphemeralData,
            object: self
        )
    }

    public func resetAllProductData() {
        for key in [
            Keys.aiEnabled,
            Keys.characterSet,
            Keys.characterWidth,
            Keys.punctuationStyle,
            Keys.offlineLockEnabled,
            Keys.cloudConfigured,
            Keys.cloudModelID,
            Keys.contextPolicy,
            Keys.disabledAIApplications,
            Keys.disabledContextApplications,
            Keys.diagnostics,
            Keys.personalEnglishTokens,
        ] {
            defaults.removeObject(forKey: key)
        }
        clearEphemeralData()
        notifySettingsChanged()
    }

    public func exportSnapshot() -> RimeAISettingsExport {
        RimeAISettingsExport(
            inputPreferences: inputPreferences,
            aiEnabled: aiEnabled,
            offlineLockEnabled: offlineLockEnabled,
            cloudConfigured: cloudConfigured,
            cloudModelID: cloudModelID,
            contextPolicy: contextPolicy,
            disabledAIApplications: disabledAIApplications,
            disabledContextApplications: disabledContextApplications,
            diagnostics: diagnosticSnapshot()
        )
    }

    private func loadDiagnostics() -> [String: Int] {
        let raw = defaults.dictionary(forKey: Keys.diagnostics) ?? [:]
        return raw.reduce(into: [:]) { result, entry in
            if let value = entry.value as? NSNumber {
                result[entry.key] = value.intValue
            }
        }
    }

    private func normalizedApplications(
        _ applications: [String]
    ) -> [String] {
        Array(
            Set(
                applications
                    .map(normalizedApplication)
                    .filter { !$0.isEmpty }
            )
        ).sorted()
    }

    private func normalizedApplication(
        _ application: String
    ) -> String {
        application.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedPersonalEnglishToken(
        _ token: String
    ) -> String? {
        let normalized = token.lowercased()
        guard (3 ... 32).contains(normalized.count),
              normalized.unicodeScalars.allSatisfy({ scalar in
                  (65 ... 90).contains(scalar.value)
                      || (97 ... 122).contains(scalar.value)
              })
        else {
            return nil
        }
        return normalized
    }

    private func notifySettingsChanged() {
        NotificationCenter.default.post(
            name: .rimeAISettingsDidChange,
            object: self
        )
    }

    private func notifyDiagnosticsChanged() {
        NotificationCenter.default.post(
            name: .rimeAIDiagnosticsDidChange,
            object: self
        )
    }
}
