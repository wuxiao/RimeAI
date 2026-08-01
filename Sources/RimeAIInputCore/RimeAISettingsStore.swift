import Foundation

public extension Notification.Name {
    static let rimeAISettingsDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.settings-did-change"
    )
    static let rimeAIClearEphemeralData = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.clear-ephemeral-data"
    )
}

public enum RimeAIDiagnosticEvent: String, CaseIterable, Codable, Sendable {
    case requestStarted = "request_started"
    case requestCancelled = "request_cancelled"
    case resultShown = "result_shown"
    case resultRejected = "result_rejected"
    case semanticAccepted = "semantic_accepted"
    case mainAccepted = "main_accepted"
    case privacyBlocked = "privacy_blocked"
    case timeout
    case circuitOpen = "circuit_open"
    case daemonFailure = "daemon_failure"
}

public struct RimeAISettingsExport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let aiEnabled: Bool
    public let offlineLockEnabled: Bool
    public let contextPolicy: ContextPolicy
    public let disabledAIApplications: [String]
    public let disabledContextApplications: [String]
    public let diagnostics: [String: Int]

    public init(
        schemaVersion: Int = 1,
        aiEnabled: Bool,
        offlineLockEnabled: Bool,
        contextPolicy: ContextPolicy,
        disabledAIApplications: [String],
        disabledContextApplications: [String],
        diagnostics: [String: Int]
    ) {
        self.schemaVersion = schemaVersion
        self.aiEnabled = aiEnabled
        self.offlineLockEnabled = offlineLockEnabled
        self.contextPolicy = contextPolicy
        self.disabledAIApplications = disabledAIApplications
        self.disabledContextApplications = disabledContextApplications
        self.diagnostics = diagnostics
    }
}

public final class RimeAISettingsStore: @unchecked Sendable {
    public enum Keys {
        public static let aiEnabled = "RimeAIEnabled"
        public static let offlineLockEnabled = "RimeAIOfflineLockEnabled"
        public static let contextPolicy = "RimeAIContextPolicy"
        public static let disabledAIApplications =
            "RimeAIDisabledAIApplications"
        public static let disabledContextApplications =
            "RimeAIDisabledContextApplications"
        public static let diagnostics = "RimeAIDiagnostics"
    }

    public static let shared = RimeAISettingsStore()

    private let defaults: UserDefaults
    private let diagnosticsLock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        get {
            guard
                defaults.object(forKey: Keys.offlineLockEnabled) != nil
            else {
                return true
            }
            return defaults.bool(forKey: Keys.offlineLockEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.offlineLockEnabled)
            notifySettingsChanged()
        }
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
        notifySettingsChanged()
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
        notifySettingsChanged()
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
            Keys.offlineLockEnabled,
            Keys.contextPolicy,
            Keys.disabledAIApplications,
            Keys.disabledContextApplications,
            Keys.diagnostics,
        ] {
            defaults.removeObject(forKey: key)
        }
        clearEphemeralData()
        notifySettingsChanged()
    }

    public func exportSnapshot() -> RimeAISettingsExport {
        RimeAISettingsExport(
            aiEnabled: aiEnabled,
            offlineLockEnabled: offlineLockEnabled,
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

    private func notifySettingsChanged() {
        NotificationCenter.default.post(
            name: .rimeAISettingsDidChange,
            object: self
        )
    }
}
