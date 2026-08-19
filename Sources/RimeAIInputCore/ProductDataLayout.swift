import Foundation

public struct RimeAIProductDataLayout: Equatable, Sendable {
    public let supportDirectory: URL
    public let daemonDirectory: URL
    public let modelDirectory: URL
    public let runtimeDirectory: URL
    public let historyDirectory: URL
    public let historyDatabase: URL
    public let historyVectorIndex: URL
    public let rimeUserDataDirectory: URL
    public let controlDirectory: URL
    public let daemonEnabledMarker: URL
    public let cloudBrokerEnabledMarker: URL
    public let launchAgentPlist: URL
    public let cloudBrokerLaunchAgentPlist: URL
    public let configDirectory: URL
    public let cloudCredentialFile: URL

    public init(homeDirectory: URL) {
        supportDirectory = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(
                "Application Support",
                isDirectory: true
            )
            .appendingPathComponent("RimeAI", isDirectory: true)
        daemonDirectory = supportDirectory
            .appendingPathComponent("daemon", isDirectory: true)
        modelDirectory = supportDirectory
            .appendingPathComponent("models", isDirectory: true)
        runtimeDirectory = supportDirectory
            .appendingPathComponent("runtime", isDirectory: true)
        historyDirectory = supportDirectory
            .appendingPathComponent("History", isDirectory: true)
        historyDatabase = historyDirectory
            .appendingPathComponent("history.sqlite3", isDirectory: false)
        historyVectorIndex = historyDirectory
            .appendingPathComponent("history-hnsw-v1.bin", isDirectory: false)
        rimeUserDataDirectory = supportDirectory
            .appendingPathComponent("Rime", isDirectory: true)
        controlDirectory = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("RimeAI", isDirectory: true)
        daemonEnabledMarker = controlDirectory
            .appendingPathComponent("daemon-enabled", isDirectory: false)
        cloudBrokerEnabledMarker = controlDirectory
            .appendingPathComponent(
                "cloud-broker-enabled",
                isDirectory: false
            )
        launchAgentPlist = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(
                "fun.wwcn.rimeai.daemon.plist",
                isDirectory: false
            )
        cloudBrokerLaunchAgentPlist = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(
                "fun.wwcn.rimeai.cloud-broker.plist",
                isDirectory: false
            )
        configDirectory = homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rimeai", isDirectory: true)
        cloudCredentialFile = configDirectory
            .appendingPathComponent("cloud.env", isDirectory: false)
    }

    public var managedDataURLs: [URL] {
        [
            daemonDirectory,
            modelDirectory,
            runtimeDirectory,
            historyDirectory,
            controlDirectory,
            launchAgentPlist,
            cloudBrokerLaunchAgentPlist,
        ]
    }
}
