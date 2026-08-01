import Foundation
import Testing
@testable import RimeAIInputCore

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

        #expect(store.aiEnabled)
        #expect(store.offlineLockEnabled)
        #expect(store.contextPolicy == .standard)
        #expect(store.disabledAIApplications.isEmpty)
        #expect(store.disabledContextApplications.isEmpty)
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

        #expect(store.diagnosticCount(.requestStarted) == 2)
        #expect(store.diagnosticCount(.privacyBlocked) == 1)
        let persisted = defaults.dictionary(
            forKey: RimeAISettingsStore.Keys.diagnostics
        )
        #expect(persisted?.keys.sorted() == [
            "privacy_blocked",
            "request_started",
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

    @Test("reset removes product settings but preserves privacy defaults")
    func reset() {
        let (store, _) = makeStore()
        store.aiEnabled = false
        store.offlineLockEnabled = false
        store.contextPolicy = .smart
        store.disabledAIApplications = ["com.example.Secret"]
        store.record(.resultShown)

        store.resetAllProductData()

        #expect(store.aiEnabled)
        #expect(store.offlineLockEnabled)
        #expect(store.contextPolicy == .standard)
        #expect(store.disabledAIApplications.isEmpty)
        #expect(store.diagnosticSnapshot().isEmpty)
    }
}
