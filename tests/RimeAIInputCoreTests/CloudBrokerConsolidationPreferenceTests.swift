import Foundation
import Testing
@testable import RimeAIInputCore

// MARK: - Broker plist consolidation flag (LP-006 cloud-compression switch)

private func temporaryPlistURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "cloud-broker-consolidation-\(UUID().uuidString).plist"
        )
    try PropertyListSerialization.data(
        fromPropertyList: [
            "Label": "fun.wwcn.rimeai.cloud-broker",
            "ProgramArguments": [
                "/usr/bin/python3",
                "-m",
                "rimeai_cloud_broker",
                "--socket",
                "/tmp/rimeai-cloud.sock",
            ],
        ] as [String: Any],
        format: .xml,
        options: 0
    ).write(to: url)
    return url
}

@Test
func disablingConsolidationAppendsTheFlagOnce() {
    let base = ["/usr/bin/python3", "-m", "rimeai_cloud_broker"]
    let disabled = CloudBrokerConsolidationPreference.programArguments(
        base,
        consolidationEnabled: false
    )
    #expect(disabled == base + ["--no-consolidation"])

    // Toggling again stays idempotent.
    let twice = CloudBrokerConsolidationPreference.programArguments(
        disabled,
        consolidationEnabled: false
    )
    #expect(twice == disabled)
}

@Test
func enablingConsolidationStripsTheFlag() {
    let disabled = [
        "/usr/bin/python3",
        "-m",
        "rimeai_cloud_broker",
        "--no-consolidation",
        "--socket",
        "/tmp/rimeai-cloud.sock",
    ]
    let enabled = CloudBrokerConsolidationPreference.programArguments(
        disabled,
        consolidationEnabled: true
    )
    #expect(
        enabled == [
            "/usr/bin/python3",
            "-m",
            "rimeai_cloud_broker",
            "--socket",
            "/tmp/rimeai-cloud.sock",
        ]
    )
}

@Test
func applyRewritesInstalledPlistOnlyWhenChanged() throws {
    let url = try temporaryPlistURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let changed = try CloudBrokerConsolidationPreference.apply(
        consolidationEnabled: false,
        to: url
    )
    #expect(changed)
    let contents = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: url),
        options: [],
        format: nil
    ) as? [String: Any]
    let arguments = contents?["ProgramArguments"] as? [String]
    #expect(arguments?.last == "--no-consolidation")

    // Second apply is a no-op.
    let unchanged = try CloudBrokerConsolidationPreference.apply(
        consolidationEnabled: false,
        to: url
    )
    #expect(!unchanged)
}

@Test
func consolidationPreferenceDefaultsToEnabled() {
    let suite = UserDefaults(suiteName: "cloud-consolidation-test")
    defer { suite?.removePersistentDomain(forName: "cloud-consolidation-test") }
    let store = RimeAISettingsStore(defaults: suite ?? .standard)

    #expect(store.cloudConsolidationEnabled)
    store.cloudConsolidationEnabled = false
    #expect(!store.cloudConsolidationEnabled)
    store.cloudConsolidationEnabled = true
    #expect(store.cloudConsolidationEnabled)
}
