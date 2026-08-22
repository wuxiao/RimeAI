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
    private var voiceRuntime: VoiceDictationRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningUnitTests else {
            return
        }
        voiceRuntime = MainActor.assumeIsolated {
            VoiceDictationRuntime.shared
        }
        reconcileVoiceHelperDesiredState()
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

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment[
            "XCTestConfigurationFilePath"
        ] != nil || NSClassFromString("XCTestCase") != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            voiceRuntime?.shutdown()
            voiceRuntime = nil
        }
    }

    private func reconcileVoiceHelperDesiredState() {
        let settings = RimeAISettingsStore.shared
        if !settings.aiEnabled, settings.voiceEnabled {
            settings.voiceEnabled = false
        }
        let shouldEnable = settings.aiEnabled && settings.voiceEnabled
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        VoiceHelperLifecycleCoordinator.shared.setDesired(
            shouldEnable,
            layout: layout
        ) { result in
            guard shouldEnable else {
                return
            }
            switch result {
            case .success:
                NotificationCenter.default.post(
                    name: .rimeAIVoiceRetryRequested,
                    object: settings
                )
            case .failure:
                // 安装缺失或恢复失败时 fail closed；设置中可再次启用。
                settings.voiceEnabled = false
            }
        }
    }
}

private let applicationDelegate = RimeAIApplicationDelegate()
private let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = applicationDelegate
application.run()
