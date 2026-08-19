import Foundation
import Testing
@testable import RimeAIInputCore

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    var currentValue: Int {
        lock.withLock { value }
    }
}

@Suite("Privacy settings")
struct RimeAISettingsStoreTests {
    private func makeStore() -> (RimeAISettingsStore, UserDefaults) {
        let suiteName = "RimeAISettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (RimeAISettingsStore(defaults: defaults), defaults)
    }

    @Test("privacy-preserving defaults are explicit")
    func privacyDefaults() {
        let (store, _) = makeStore()

        #expect(store.characterSet == .simplified)
        #expect(store.characterWidth == .half)
        #expect(store.punctuationStyle == .chinese)
        #expect(store.aiEnabled)
        #expect(store.offlineLockEnabled)
        #expect(!store.cloudConfigured)
        #expect(
            store.cloudModelID
                == RimeAICloudConfiguration.defaultRankingModelID
        )
        #expect(store.contextPolicy == .standard)
        #expect(store.disabledAIApplications.isEmpty)
        #expect(store.disabledContextApplications.isEmpty)
    }

    @Test("cloud history ignores local application and context policies")
    func cloudHistoryHasAnIndependentBoundary() {
        let (store, _) = makeStore()
        store.aiEnabled = false
        store.characterSet = .traditional
        store.characterWidth = .full
        store.punctuationStyle = .western
        store.contextPolicy = .strict
        store.disabledAIApplications = ["com.example.Secret"]
        store.disabledContextApplications = ["com.example.Secret"]
        store.cloudConfigured = true

        #expect(
            !store.isAIAllowed(for: "com.example.Secret")
        )
        #expect(
            store.contextPolicy(for: "com.example.Secret") == .strict
        )
        #expect(store.shouldCaptureCloudHistory(isSecureInput: false))
        #expect(!store.shouldCaptureCloudHistory(isSecureInput: true))
    }

    @Test("indeterminate credential state never disables cloud")
    func indeterminateCredentialStatePreservesCloudPreference() {
        let (store, _) = makeStore()
        store.cloudConfigured = true

        store.reconcileCloudConfiguration(hasCredential: nil)
        #expect(store.cloudConfigured)

        store.reconcileCloudConfiguration(hasCredential: true)
        #expect(store.cloudConfigured)

        store.reconcileCloudConfiguration(hasCredential: false)
        #expect(!store.cloudConfigured)
    }

    @Test("offline lock is a local daemon invariant")
    func offlineLockCannotBeDisabled() {
        let (store, defaults) = makeStore()

        store.offlineLockEnabled = false

        #expect(store.offlineLockEnabled)
        #expect(
            defaults.bool(
                forKey: RimeAISettingsStore.Keys.offlineLockEnabled
            )
        )
    }

    @Test("application policies use normalized exact bundle identifiers")
    func exactApplicationPolicies() {
        let (store, _) = makeStore()
        store.disabledAIApplications = [
            " com.example.Secret ",
            "com.example.Secret",
            "",
        ]
        store.disabledContextApplications = ["com.example.NoContext"]

        #expect(!store.isAIAllowed(for: "com.example.Secret"))
        #expect(store.isAIAllowed(for: "com.example.Secret.Helper"))
        #expect(store.contextPolicy(for: "com.example.NoContext") == .strict)
        #expect(store.contextPolicy(for: "com.example.Other") == .standard)
        #expect(store.disabledAIApplications == ["com.example.Secret"])
    }

    @Test("diagnostics persist counters only and can be reset")
    func diagnosticCounters() {
        let (store, defaults) = makeStore()

        store.record(.requestStarted)
        store.record(.requestStarted)
        store.record(.privacyBlocked)
        store.record(.sameTopCandidate)
        store.record(.belowConfidence)

        #expect(store.diagnosticCount(.requestStarted) == 2)
        #expect(store.diagnosticCount(.privacyBlocked) == 1)
        #expect(store.diagnosticCount(.sameTopCandidate) == 1)
        #expect(store.diagnosticCount(.belowConfidence) == 1)
        let persisted = defaults.dictionary(
            forKey: RimeAISettingsStore.Keys.diagnostics
        )
        #expect(persisted?.keys.sorted() == [
            "below_confidence",
            "privacy_blocked",
            "request_started",
            "same_top_candidate",
        ])

        store.resetDiagnostics()
        #expect(store.diagnosticSnapshot().isEmpty)
    }

    @Test("latency diagnostics use aggregate buckets without raw values")
    func latencyBuckets() {
        let (store, _) = makeStore()

        store.recordLatency(milliseconds: 42)
        store.recordLatency(milliseconds: 180)
        store.recordLatency(milliseconds: 399)
        store.recordLatency(milliseconds: 500)

        #expect(store.diagnosticSnapshot() == [
            "latency_lt_50_ms": 1,
            "latency_lt_250_ms": 1,
            "latency_lt_400_ms": 1,
            "latency_gte_400_ms": 1,
        ])
    }

    @Test("personal English learning stores normalized bounded tokens only")
    func personalEnglishTokens() {
        let (store, _) = makeStore()

        store.learnPersonalEnglishTokens([
            "API", "timeout", "x", "包含中文", String(repeating: "a", count: 33),
        ])

        #expect(store.personalEnglishTokens == ["api", "timeout"])
        store.resetAllProductData()
        #expect(store.personalEnglishTokens.isEmpty)
    }

    @Test("personal English learning evicts the oldest token at capacity")
    func personalEnglishTokenEviction() {
        let (store, _) = makeStore()
        for index in 0 ..< 256 {
            store.learnPersonalEnglishTokens([
                "term\(Self.letters(for: index))"
            ])
        }
        let oldest = "termaaa"
        store.learnPersonalEnglishTokens(["zzzznew"])

        #expect(store.personalEnglishTokens.count == 256)
        #expect(!store.personalEnglishTokens.contains(oldest))
        #expect(store.personalEnglishTokens.contains("zzzznew"))
    }

    private static func letters(for value: Int) -> String {
        let scalars = [
            UnicodeScalar(97 + (value / 676) % 26)!,
            UnicodeScalar(97 + (value / 26) % 26)!,
            UnicodeScalar(97 + value % 26)!,
        ]
        return String(String.UnicodeScalarView(scalars))
    }

    @Test("diagnostic counters do not masquerade as policy changes")
    func diagnosticNotificationsAreSeparate() {
        let (store, _) = makeStore()
        let settingsChanges = NotificationCounter()
        let diagnosticChanges = NotificationCounter()
        let settingsObserver = NotificationCenter.default.addObserver(
            forName: .rimeAISettingsDidChange,
            object: store,
            queue: nil
        ) { _ in
            settingsChanges.increment()
        }
        let diagnosticObserver = NotificationCenter.default.addObserver(
            forName: .rimeAIDiagnosticsDidChange,
            object: store,
            queue: nil
        ) { _ in
            diagnosticChanges.increment()
        }
        defer {
            NotificationCenter.default.removeObserver(settingsObserver)
            NotificationCenter.default.removeObserver(diagnosticObserver)
        }

        store.record(.cloudRequestStarted)

        #expect(settingsChanges.currentValue == 0)
        #expect(diagnosticChanges.currentValue == 1)
    }

    @Test("reset removes product settings but preserves privacy defaults")
    func reset() {
        let (store, _) = makeStore()
        store.aiEnabled = false
        store.offlineLockEnabled = false
        store.cloudConfigured = true
        store.cloudModelID = "glm-5.3"
        store.contextPolicy = .smart
        store.disabledAIApplications = ["com.example.Secret"]
        store.record(.resultShown)

        store.resetAllProductData()

        #expect(store.aiEnabled)
        #expect(store.characterSet == .simplified)
        #expect(store.characterWidth == .half)
        #expect(store.punctuationStyle == .chinese)
        #expect(store.offlineLockEnabled)
        #expect(!store.cloudConfigured)
        #expect(
            store.cloudModelID
                == RimeAICloudConfiguration.defaultRankingModelID
        )
        #expect(store.contextPolicy == .standard)
        #expect(store.disabledAIApplications.isEmpty)
        #expect(store.diagnosticSnapshot().isEmpty)
    }
}
