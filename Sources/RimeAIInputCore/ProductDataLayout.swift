import Foundation
#if canImport(RimeAIVoiceArtifactCore)
import RimeAIVoiceArtifactCore
#endif

public struct RimeAIProductDataLayout: Equatable, Sendable {
    public let supportDirectory: URL
    public let daemonDirectory: URL
    public let modelDirectory: URL
    public let voiceASRDirectory: URL
    public let voiceASRReleasesDirectory: URL
    public let voiceASRStagingDirectory: URL
    public let voiceASRCurrentSelector: URL
    public let voiceASRPreviousSelector: URL
    public let runtimeDirectory: URL
    public let historyDirectory: URL
    public let historyDatabase: URL
    public let historyVectorIndex: URL
    public let languageProfileDirectory: URL
    public let phraseBookDatabase: URL
    public let voiceDirectory: URL
    public let voiceHelperApplication: URL
    public let voiceSocket: URL
    public let rimeUserDataDirectory: URL
    public let controlDirectory: URL
    public let daemonEnabledMarker: URL
    public let cloudBrokerEnabledMarker: URL
    public let voiceEnabledMarker: URL
    public let launchAgentPlist: URL
    public let cloudBrokerLaunchAgentPlist: URL
    public let voiceLaunchAgentPlist: URL
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
        voiceASRDirectory = modelDirectory
            .appendingPathComponent("voice", isDirectory: true)
        voiceASRReleasesDirectory = voiceASRDirectory
            .appendingPathComponent("releases", isDirectory: true)
        voiceASRStagingDirectory = voiceASRDirectory
            .appendingPathComponent("staging", isDirectory: true)
        voiceASRCurrentSelector = voiceASRDirectory
            .appendingPathComponent("current", isDirectory: false)
        voiceASRPreviousSelector = voiceASRDirectory
            .appendingPathComponent("previous", isDirectory: false)
        runtimeDirectory = supportDirectory
            .appendingPathComponent("runtime", isDirectory: true)
        historyDirectory = supportDirectory
            .appendingPathComponent("History", isDirectory: true)
        historyDatabase = historyDirectory
            .appendingPathComponent("history.sqlite3", isDirectory: false)
        historyVectorIndex = historyDirectory
            .appendingPathComponent("history-hnsw-v1.bin", isDirectory: false)
        languageProfileDirectory = supportDirectory
            .appendingPathComponent(
                "language_profile",
                isDirectory: true
            )
        phraseBookDatabase = languageProfileDirectory
            .appendingPathComponent(
                "phrasebook.sqlite3",
                isDirectory: false
            )
        voiceDirectory = supportDirectory
            .appendingPathComponent("voice", isDirectory: true)
        voiceHelperApplication = voiceDirectory
            .appendingPathComponent("RimeAIVoiceHelper.app", isDirectory: true)
        voiceSocket = runtimeDirectory
            .appendingPathComponent("rimeai-voice.sock", isDirectory: false)
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
        voiceEnabledMarker = controlDirectory
            .appendingPathComponent("voice-enabled", isDirectory: false)
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
        voiceLaunchAgentPlist = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(
                "fun.wwcn.rimeai.voice-helper.plist",
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
            languageProfileDirectory,
            voiceDirectory,
            controlDirectory,
            launchAgentPlist,
            cloudBrokerLaunchAgentPlist,
            voiceLaunchAgentPlist,
        ]
    }

    public func voiceASRReleaseDirectory(
        for artifactID: VoiceASRArtifactID
    ) -> URL {
        voiceASRReleasesDirectory.appendingPathComponent(
            artifactID.rawValue,
            isDirectory: true
        )
    }

    public func voiceASRStagedArtifactDirectory(
        for artifactID: VoiceASRArtifactID
    ) -> URL {
        voiceASRStagingDirectory.appendingPathComponent(
            artifactID.rawValue,
            isDirectory: true
        )
    }
}
