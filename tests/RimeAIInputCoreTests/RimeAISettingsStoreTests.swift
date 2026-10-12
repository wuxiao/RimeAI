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
        #expect(!store.voiceEnabled)
        #expect(!store.voiceRimeHotwordsEnabled)
        #expect(
            store.cloudModelID
                == RimeAICloudConfiguration.defaultRankingModelID
        )
        #expect(store.contextPolicy == .standard)
        #expect(store.disabledAIApplications.isEmpty)
        #expect(store.disabledContextApplications.isEmpty)
        #expect(store.voiceShortcut == .default)
    }

    @Test("voice shortcut persists as a validated value")
    func voiceShortcutPersistence() throws {
        let (store, defaults) = makeStore()
        let custom = try #require(
            VoiceDictationShortcut(keyCode: 0, modifiers: [.option, .shift])
        )

        store.voiceShortcut = custom

        #expect(RimeAISettingsStore(defaults: defaults).voiceShortcut == custom)
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

    @Test("personal English tokens normalize to bounded lowercase tokens only")
    func personalEnglishTokens() {
        let (store, defaults) = makeStore()

        // Learning moved to the L1 phrasebook (adoptUserTokens); the
        // legacy defaults key only needs to read back normalized.
        defaults.set(
            ["api", "timeout", "x", "包含中文", String(repeating: "a", count: 33)],
            forKey: RimeAISettingsStore.Keys.personalEnglishTokens
        )

        #expect(store.personalEnglishTokens == ["api", "timeout"])
        store.resetAllProductData()
        #expect(store.personalEnglishTokens.isEmpty)
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
    func reset() throws {
        let (store, _) = makeStore()
        store.aiEnabled = false
        store.offlineLockEnabled = false
        store.cloudConfigured = true
        store.voiceEnabled = true
        store.voiceShortcut = try #require(
            VoiceDictationShortcut(keyCode: 12, modifiers: [.option, .shift])
        )
        store.voiceRimeHotwordsEnabled = true
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
        #expect(!store.voiceEnabled)
        #expect(store.voiceShortcut == .default)
        #expect(!store.voiceRimeHotwordsEnabled)
        #expect(
            store.cloudModelID
                == RimeAICloudConfiguration.defaultRankingModelID
        )
        #expect(store.contextPolicy == .standard)
        #expect(store.disabledAIApplications.isEmpty)
        #expect(store.diagnosticSnapshot().isEmpty)
    }

    @Test("voice hotword consent is explicit and exported")
    func voiceHotwordConsentIsExplicitAndExported() throws {
        let (store, _) = makeStore()
        let shortcut = try #require(
            VoiceDictationShortcut(keyCode: 12, modifiers: [.option, .shift])
        )

        #expect(!store.voiceRimeHotwordsEnabled)
        store.voiceRimeHotwordsEnabled = true
        store.voiceShortcut = shortcut

        let snapshot = store.exportSnapshot()
        #expect(snapshot.schemaVersion == 8)
        #expect(snapshot.voiceEnabled == false)
        #expect(snapshot.voiceRimeHotwordsEnabled)
        #expect(snapshot.voiceShortcut == shortcut)
    }

    @Test("schema 5 exports migrate a missing voice shortcut to the default")
    func schemaFiveVoiceShortcutMigration() throws {
        let legacy = RimeAISettingsExport(
            schemaVersion: 5,
            aiEnabled: true,
            offlineLockEnabled: true,
            contextPolicy: .standard,
            disabledAIApplications: [],
            disabledContextApplications: [],
            diagnostics: [:]
        )
        let encoded = try JSONEncoder().encode(legacy)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "voiceShortcut")

        let decoded = try JSONDecoder().decode(
            RimeAISettingsExport.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.schemaVersion == 5)
        #expect(decoded.voiceShortcut == .default)
    }

    @Test("validated import applies settings once without importing diagnostics")
    func validatedImportIsBatched() throws {
        let (store, _) = makeStore()
        store.record(.resultShown)
        let shortcut = try #require(
            VoiceDictationShortcut(keyCode: 12, modifiers: [.control, .shift])
        )
        let changes = NotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .rimeAISettingsDidChange,
            object: store,
            queue: nil
        ) { _ in
            changes.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let snapshot = RimeAISettingsExport(
            inputPreferences: RimeAIInputPreferences(
                characterSet: .traditional,
                characterWidth: .full,
                punctuationStyle: .western
            ),
            aiEnabled: true,
            offlineLockEnabled: true,
            cloudConfigured: true,
            voiceEnabled: true,
            voiceShortcut: shortcut,
            voiceRimeHotwordsEnabled: true,
            contextPolicy: .smart,
            disabledAIApplications: ["com.example.NoAI"],
            disabledContextApplications: ["com.example.NoContext"],
            diagnostics: ["forged_policy": 999]
        )

        try store.applyImport(snapshot, hasCloudCredential: true)

        #expect(changes.currentValue == 1)
        #expect(store.inputPreferences == snapshot.inputPreferences)
        #expect(store.cloudConfigured)
        #expect(store.voiceEnabled)
        #expect(store.voiceShortcut == shortcut)
        #expect(store.voiceRimeHotwordsEnabled)
        #expect(store.contextPolicy == .smart)
        #expect(store.disabledAIApplications == ["com.example.NoAI"])
        #expect(store.disabledContextApplications == ["com.example.NoContext"])
        #expect(store.diagnosticCount(.resultShown) == 1)
        #expect(store.diagnosticSnapshot()["forged_policy"] == nil)
    }

    @Test("authority-invalid imports are rejected atomically")
    func invalidImportAuthorityIsAtomic() {
        let validArguments = (
            aiEnabled: true,
            offlineLockEnabled: true,
            contextPolicy: ContextPolicy.standard,
            disabledAIApplications: [String](),
            disabledContextApplications: [String](),
            diagnostics: [String: Int]()
        )
        let invalidImports: [(RimeAISettingsExport, RimeAISettingsImportError)] = [
            (
                RimeAISettingsExport(
                    schemaVersion: 4,
                    aiEnabled: validArguments.aiEnabled,
                    offlineLockEnabled: validArguments.offlineLockEnabled,
                    contextPolicy: validArguments.contextPolicy,
                    disabledAIApplications: validArguments.disabledAIApplications,
                    disabledContextApplications:
                        validArguments.disabledContextApplications,
                    diagnostics: validArguments.diagnostics
                ),
                .unsupportedSchemaVersion(4)
            ),
            (
                RimeAISettingsExport(
                    aiEnabled: validArguments.aiEnabled,
                    offlineLockEnabled: false,
                    contextPolicy: validArguments.contextPolicy,
                    disabledAIApplications: validArguments.disabledAIApplications,
                    disabledContextApplications:
                        validArguments.disabledContextApplications,
                    diagnostics: validArguments.diagnostics
                ),
                .offlineLockRequired
            ),
            (
                RimeAISettingsExport(
                    aiEnabled: validArguments.aiEnabled,
                    offlineLockEnabled: validArguments.offlineLockEnabled,
                    cloudProvider: "untrusted-provider",
                    contextPolicy: validArguments.contextPolicy,
                    disabledAIApplications: validArguments.disabledAIApplications,
                    disabledContextApplications:
                        validArguments.disabledContextApplications,
                    diagnostics: validArguments.diagnostics
                ),
                .unsupportedCloudProvider
            ),
            (
                RimeAISettingsExport(
                    aiEnabled: validArguments.aiEnabled,
                    offlineLockEnabled: validArguments.offlineLockEnabled,
                    cloudEndpoint: "https://example.invalid/",
                    contextPolicy: validArguments.contextPolicy,
                    disabledAIApplications: validArguments.disabledAIApplications,
                    disabledContextApplications:
                        validArguments.disabledContextApplications,
                    diagnostics: validArguments.diagnostics
                ),
                .unsupportedCloudEndpoint
            ),
            (
                RimeAISettingsExport(
                    aiEnabled: validArguments.aiEnabled,
                    offlineLockEnabled: validArguments.offlineLockEnabled,
                    cloudModelID: "untrusted-model",
                    contextPolicy: validArguments.contextPolicy,
                    disabledAIApplications: validArguments.disabledAIApplications,
                    disabledContextApplications:
                        validArguments.disabledContextApplications,
                    diagnostics: validArguments.diagnostics
                ),
                .unsupportedCloudModelID
            ),
            (
                RimeAISettingsExport(
                    aiEnabled: validArguments.aiEnabled,
                    offlineLockEnabled: validArguments.offlineLockEnabled,
                    cloudConfigured: true,
                    contextPolicy: validArguments.contextPolicy,
                    disabledAIApplications: validArguments.disabledAIApplications,
                    disabledContextApplications:
                        validArguments.disabledContextApplications,
                    diagnostics: validArguments.diagnostics
                ),
                .cloudCredentialRequired
            ),
        ]

        for (snapshot, expectedError) in invalidImports {
            let (store, _) = makeStore()
            store.aiEnabled = false
            let before = store.exportSnapshot()
            let changes = NotificationCounter()
            let observer = NotificationCenter.default.addObserver(
                forName: .rimeAISettingsDidChange,
                object: store,
                queue: nil
            ) { _ in
                changes.increment()
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            #expect(throws: expectedError) {
                try store.applyImport(snapshot, hasCloudCredential: false)
            }
            #expect(store.exportSnapshot() == before)
            #expect(changes.currentValue == 0)
        }
    }

    @Test("imports reject unreachable voice state and oversized app policies")
    func invalidImportedPolicyIsAtomic() {
        let tooManyApplications = (0 ... 256).map { "com.example.app\($0)" }
        let invalidImports: [(RimeAISettingsExport, RimeAISettingsImportError)] = [
            (
                RimeAISettingsExport(
                    aiEnabled: false,
                    offlineLockEnabled: true,
                    voiceEnabled: true,
                    contextPolicy: .standard,
                    disabledAIApplications: [],
                    disabledContextApplications: [],
                    diagnostics: [:]
                ),
                .voiceRequiresAI
            ),
            (
                RimeAISettingsExport(
                    aiEnabled: true,
                    offlineLockEnabled: true,
                    contextPolicy: .standard,
                    disabledAIApplications: tooManyApplications,
                    disabledContextApplications: [],
                    diagnostics: [:]
                ),
                .applicationPolicyLimitExceeded
            ),
            (
                RimeAISettingsExport(
                    aiEnabled: true,
                    offlineLockEnabled: true,
                    contextPolicy: .standard,
                    disabledAIApplications: [String(repeating: "a", count: 256)],
                    disabledContextApplications: [],
                    diagnostics: [:]
                ),
                .applicationPolicyLimitExceeded
            ),
            (
                RimeAISettingsExport(
                    aiEnabled: true,
                    offlineLockEnabled: true,
                    contextPolicy: .standard,
                    disabledAIApplications: ["com.example.good\ncom.evil"],
                    disabledContextApplications: [],
                    diagnostics: [:]
                ),
                .applicationPolicyLimitExceeded
            ),
        ]

        for (snapshot, expectedError) in invalidImports {
            let (store, _) = makeStore()
            store.contextPolicy = .smart
            let before = store.exportSnapshot()
            let changes = NotificationCounter()
            let observer = NotificationCenter.default.addObserver(
                forName: .rimeAISettingsDidChange,
                object: store,
                queue: nil
            ) { _ in
                changes.increment()
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            #expect(throws: expectedError) {
                try store.applyImport(snapshot, hasCloudCredential: false)
            }
            #expect(store.exportSnapshot() == before)
            #expect(changes.currentValue == 0)
        }
    }

    @Test("every legal export can be imported with retained hotword consent")
    func exportedSettingsRoundTrip() throws {
        let (source, _) = makeStore()
        source.voiceRimeHotwordsEnabled = true
        let exported = source.exportSnapshot()
        #expect(!exported.voiceEnabled)
        #expect(exported.voiceRimeHotwordsEnabled)

        let (destination, _) = makeStore()
        try destination.applyImport(
            exported,
            hasCloudCredential: false
        )

        #expect(destination.exportSnapshot() == exported)
    }

    @Test("malformed or oversized import documents cannot mutate settings")
    func invalidImportDocumentIsAtomic() throws {
        let (store, _) = makeStore()
        store.contextPolicy = .smart
        let before = store.exportSnapshot()
        let changes = NotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .rimeAISettingsDidChange,
            object: store,
            queue: nil
        ) { _ in
            changes.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(before)
            ) as? [String: Any]
        )
        object["voiceShortcut"] = ["keyCode": 49, "modifiers": 6]
        let unsafeShortcut = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: RimeAISettingsImportError.invalidDocument) {
            try store.applyImport(
                unsafeShortcut,
                hasCloudCredential: false
            )
        }
        #expect(throws: RimeAISettingsImportError.documentTooLarge) {
            try store.applyImport(
                Data(
                    repeating: 0,
                    count: RimeAISettingsStore.maxImportDocumentBytes + 1
                ),
                hasCloudCredential: false
            )
        }
        #expect(store.exportSnapshot() == before)
        #expect(changes.currentValue == 0)
    }

    @Test("restore defaults is one settings change and preserves learned data")
    func restoreDefaultsPreservesNonSettingsData() throws {
        let (store, defaults) = makeStore()
        store.aiEnabled = false
        store.cloudConfigured = true
        store.voiceEnabled = true
        store.voiceRimeHotwordsEnabled = true
        store.voiceShortcut = try #require(
            VoiceDictationShortcut(keyCode: 12, modifiers: [.option, .shift])
        )
        store.contextPolicy = .smart
        store.disabledAIApplications = ["com.example.NoAI"]
        store.record(.resultShown)
        defaults.set(
            ["retained"],
            forKey: RimeAISettingsStore.Keys.personalEnglishTokens
        )
        let changes = NotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .rimeAISettingsDidChange,
            object: store,
            queue: nil
        ) { _ in
            changes.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.restoreDefaults()

        #expect(changes.currentValue == 1)
        #expect(store.aiEnabled)
        #expect(!store.cloudConfigured)
        #expect(!store.voiceEnabled)
        #expect(!store.voiceRimeHotwordsEnabled)
        #expect(store.voiceShortcut == .default)
        #expect(store.contextPolicy == .standard)
        #expect(store.disabledAIApplications.isEmpty)
        #expect(store.diagnosticCount(.resultShown) == 1)
        #expect(store.personalEnglishTokens == ["retained"])
    }

    @Test("settings import errors provide actionable localized messages")
    func importErrorsAreLocalized() {
        let errors: [RimeAISettingsImportError] = [
            .invalidDocument,
            .documentTooLarge,
            .unsupportedSchemaVersion(8),
            .offlineLockRequired,
            .unsupportedCloudProvider,
            .unsupportedCloudEndpoint,
            .unsupportedCloudModelID,
            .cloudCredentialRequired,
            .voiceRequiresAI,
            .continuationRequiresAI,
            .applicationPolicyLimitExceeded,
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test("continuation suggestion is an explicit opt-in, off by default")
    func continuationSuggestionDefaultsFalse() {
        let (store, _) = makeStore()

        #expect(!store.continuationSuggestionEnabled)
        store.continuationSuggestionEnabled = true
        #expect(store.continuationSuggestionEnabled)
        store.resetAllProductData()
        #expect(!store.continuationSuggestionEnabled)
    }

    @Test("schema 7 exports carry the continuation opt-in; 5/6 imports migrate")
    func continuationExportRoundTripBumpsSchemaVersion() throws {
        let (store, _) = makeStore()
        store.continuationSuggestionEnabled = true
        let exported = store.exportSnapshot()
        #expect(exported.schemaVersion == 8)
        #expect(exported.continuationSuggestionEnabled)

        let (destination, _) = makeStore()
        try destination.applyImport(exported, hasCloudCredential: false)
        #expect(destination.continuationSuggestionEnabled)
        #expect(destination.exportSnapshot() == exported)

        // schema 6 documents predate the key: migrate to the default
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(exported)
            ) as? [String: Any]
        )
        object["schemaVersion"] = 6
        object.removeValue(forKey: "continuationSuggestionEnabled")
        let legacySix = try JSONSerialization.data(withJSONObject: object)
        let (sixStore, _) = makeStore()
        try sixStore.applyImport(legacySix, hasCloudCredential: false)
        #expect(!sixStore.continuationSuggestionEnabled)
        #expect(sixStore.exportSnapshot().schemaVersion == 8)

        // schema 5 documents keep the voice shortcut migration
        let legacyFive = RimeAISettingsExport(
            schemaVersion: 5,
            aiEnabled: true,
            offlineLockEnabled: true,
            contextPolicy: .standard,
            disabledAIApplications: [],
            disabledContextApplications: [],
            diagnostics: [:]
        )
        var fiveObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(legacyFive)
            ) as? [String: Any]
        )
        fiveObject.removeValue(forKey: "voiceShortcut")
        fiveObject.removeValue(forKey: "continuationSuggestionEnabled")
        let (fiveStore, _) = makeStore()
        try fiveStore.applyImport(
            JSONSerialization.data(withJSONObject: fiveObject),
            hasCloudCredential: false
        )
        #expect(fiveStore.voiceShortcut == .default)
        #expect(!fiveStore.continuationSuggestionEnabled)
    }

    @Test("continuation opt-in requires AI on import and stays atomic")
    func continuationImportRequiresAI() throws {
        let (store, _) = makeStore()
        store.contextPolicy = .smart
        let before = store.exportSnapshot()
        let snapshot = RimeAISettingsExport(
            aiEnabled: false,
            offlineLockEnabled: true,
            continuationSuggestionEnabled: true,
            contextPolicy: .standard,
            disabledAIApplications: [],
            disabledContextApplications: [],
            diagnostics: [:]
        )

        #expect(throws: RimeAISettingsImportError.continuationRequiresAI) {
            try store.applyImport(snapshot, hasCloudCredential: false)
        }
        #expect(store.exportSnapshot() == before)
    }

    @Test("schema 8 exports carrying the removed pinyinAlignment import cleanly")
    func legacyPinyinAlignmentExportImports() throws {
        let (store, _) = makeStore()
        let exported = store.exportSnapshot()
        #expect(exported.schemaVersion == 8)

        // The alignment tier was removed without a schema bump: older
        // schema-8 documents still carry `pinyinAlignment`, which the
        // decoder must ignore (unknown keys never fail Codable).
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(exported)
            ) as? [String: Any]
        )
        object["pinyinAlignment"] = "loose"
        try store.applyImport(
            JSONSerialization.data(withJSONObject: object),
            hasCloudCredential: false
        )
        #expect(store.exportSnapshot() == exported)

        // Round-tripping never re-introduces the field.
        let roundTripped = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(store.exportSnapshot())
            ) as? [String: Any]
        )
        #expect(roundTripped["pinyinAlignment"] == nil)
    }

    @Test("history commit source continuation raw value round trips")
    func historyCommitSourceContinuationRawValue() throws {
        #expect(HistoryCommitSource.continuation.rawValue == "continuation")
        let decoded = try JSONDecoder().decode(
            HistoryCommitSource.self,
            from: Data("\"continuation\"".utf8)
        )
        #expect(decoded == .continuation)
    }
}
