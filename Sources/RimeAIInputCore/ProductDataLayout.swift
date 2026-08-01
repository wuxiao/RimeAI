import Foundation

public struct RimeAIProductDataLayout: Equatable, Sendable {
    public let supportDirectory: URL
    public let daemonDirectory: URL
    public let modelDirectory: URL
    public let runtimeDirectory: URL
    public let rimeUserDataDirectory: URL
    public let controlDirectory: URL
    public let daemonEnabledMarker: URL
    public let launchAgentPlist: URL

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
        rimeUserDataDirectory = supportDirectory
            .appendingPathComponent("Rime", isDirectory: true)
        controlDirectory = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("RimeAI", isDirectory: true)
        daemonEnabledMarker = controlDirectory
            .appendingPathComponent("daemon-enabled", isDirectory: false)
        launchAgentPlist = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(
                "fun.wwcn.rimeai.daemon.plist",
                isDirectory: false
            )
    }

    public var managedDataURLs: [URL] {
        [
            daemonDirectory,
            modelDirectory,
            runtimeDirectory,
            controlDirectory,
            launchAgentPlist,
        ]
    }
}
