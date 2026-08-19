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
                "RimeAI",
                "fun.wwcn.rimeai.daemon.plist",
                "fun.wwcn.rimeai.cloud-broker.plist",
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
            layout.cloudBrokerLaunchAgentPlist.lastPathComponent
                == "fun.wwcn.rimeai.cloud-broker.plist"
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
