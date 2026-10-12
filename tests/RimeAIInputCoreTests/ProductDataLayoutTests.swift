import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("Product data lifecycle")
struct ProductDataLayoutTests {
    @Test("managed AI data never includes the Rime user directory")
    func managedDataExcludesRime() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let layout = RimeAIProductDataLayout(homeDirectory: home)

        #expect(layout.rimeUserDataDirectory.lastPathComponent == "Rime")
        #expect(
            layout.managedDataURLs.map(\.lastPathComponent) == [
                "daemon",
                "models",
                "runtime",
                "History",
                "language_profile",
                "voice",
                "RimeAI",
                "fun.wwcn.rimeai.daemon.plist",
                "fun.wwcn.rimeai.cloud-broker.plist",
                "fun.wwcn.rimeai.voice-helper.plist",
            ]
        )
        #expect(layout.historyDatabase.lastPathComponent == "history.sqlite3")
        #expect(
            layout.historyVectorIndex.lastPathComponent
                == "history-hnsw-v1.bin"
        )
        #expect(
            layout.daemonEnabledMarker.deletingLastPathComponent()
                == layout.controlDirectory
        )
        #expect(
            layout.cloudBrokerEnabledMarker.deletingLastPathComponent()
                == layout.controlDirectory
        )
        #expect(
            layout.voiceEnabledMarker.deletingLastPathComponent()
                == layout.controlDirectory
        )
        #expect(
            layout.voiceHelperApplication.lastPathComponent
                == "RimeAIVoiceHelper.app"
        )
        #expect(layout.voiceSocket.lastPathComponent == "rimeai-voice.sock")
        #expect(
            layout.voiceASRDirectory.path
                == "/Users/example/Library/Application Support/RimeAI/models/voice"
        )
        #expect(
            layout.voiceASRReleasesDirectory.deletingLastPathComponent()
                == layout.voiceASRDirectory
        )
        #expect(
            layout.voiceASRStagingDirectory.deletingLastPathComponent()
                == layout.voiceASRDirectory
        )
        #expect(layout.voiceASRCurrentSelector.lastPathComponent == "current")
        #expect(
            layout.voiceASRPreviousSelector.lastPathComponent == "previous"
        )
        let artifactID = VoiceASRArtifactID(rawValue: "sherpa-onnx.zh_v1")!
        #expect(
            layout.voiceASRReleaseDirectory(for: artifactID).path
                == "/Users/example/Library/Application Support/RimeAI/models/voice/releases/sherpa-onnx.zh_v1"
        )
        #expect(
            layout.voiceASRStagedArtifactDirectory(for: artifactID).path
                == "/Users/example/Library/Application Support/RimeAI/models/voice/staging/sherpa-onnx.zh_v1"
        )
        #expect(
            layout.cloudBrokerLaunchAgentPlist.lastPathComponent
                == "fun.wwcn.rimeai.cloud-broker.plist"
        )
        #expect(
            layout.voiceLaunchAgentPlist.lastPathComponent
                == "fun.wwcn.rimeai.voice-helper.plist"
        )
        #expect(
            !layout.managedDataURLs.contains(layout.rimeUserDataDirectory)
        )
        #expect(
            layout.managedDataURLs.allSatisfy {
                !$0.path.hasPrefix(
                    layout.rimeUserDataDirectory.path + "/"
                )
            }
        )
    }
}
