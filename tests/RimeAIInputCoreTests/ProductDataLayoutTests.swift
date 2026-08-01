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
                "RimeAI",
                "fun.wwcn.rimeai.daemon.plist",
            ]
        )
        #expect(
            layout.daemonEnabledMarker.deletingLastPathComponent()
                == layout.controlDirectory
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
