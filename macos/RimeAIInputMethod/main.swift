import AppKit
import Darwin
import InputMethodKit

if CommandLine.arguments.contains("--verify-cloud-credential") {
    let isAvailable: Bool
    do {
        isAvailable = try FileCloudCredentialStore.shared.loadAPIKey()?.isEmpty == false
    } catch {
        isAvailable = false
    }
    let result = isAvailable ? "available\n" : "unavailable\n"
    FileHandle.standardOutput.write(Data(result.utf8))
    Darwin.exit(isAvailable ? EXIT_SUCCESS : EXIT_FAILURE)
}

private final class RimeAIApplicationDelegate: NSObject, NSApplicationDelegate {
    private var inputMethodServer: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard
            let connectionName = Bundle.main.object(
                forInfoDictionaryKey: "InputMethodConnectionName"
            ) as? String,
            let bundleIdentifier = Bundle.main.bundleIdentifier
        else {
            NSApplication.shared.terminate(nil)
            return
        }
        inputMethodServer = IMKServer(
            name: connectionName,
            bundleIdentifier: bundleIdentifier
        )
        RimeEngine.shared.warm()
        if CommandLine.arguments.contains("--settings") {
            PrivacyCenterWindowController.shared.showWindow()
        }
    }
}

private let applicationDelegate = RimeAIApplicationDelegate()
private let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = applicationDelegate
application.run()
