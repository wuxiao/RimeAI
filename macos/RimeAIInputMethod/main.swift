import AppKit
import Darwin
import InputMethodKit

enum RimeAIInputMethodServerConfiguration {
    static func connectionName(for bundleIdentifier: String) -> String {
        "\(bundleIdentifier).Connection"
    }
}

enum RimeAIProcessEnvironment {
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment[
            "XCTestConfigurationFilePath"
        ] != nil || NSClassFromString("XCTestCase") != nil
    }
}

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
    // InputMethodKit requires exactly one server that remains alive for the
    // application's full run-loop lifetime.
    private let inputMethodServer: IMKServer?
    private var voiceRuntime: VoiceDictationRuntime?

    override init() {
        if !RimeAIProcessEnvironment.isRunningUnitTests,
           let bundleIdentifier = Bundle.main.bundleIdentifier {
            inputMethodServer = IMKServer(
                name: RimeAIInputMethodServerConfiguration.connectionName(
                    for: bundleIdentifier
                ),
                bundleIdentifier: bundleIdentifier
            )
        } else {
            inputMethodServer = nil
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !RimeAIProcessEnvironment.isRunningUnitTests else {
            return
        }
        voiceRuntime = MainActor.assumeIsolated {
            VoiceDictationRuntime.shared
        }
        reconcileVoiceHelperDesiredState()
        RimeEngine.shared.warm()
        if CommandLine.arguments.contains("--settings") {
            PrivacyCenterWindowController.shared.showWindow()
        }
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
        if shouldEnable {
            MainActor.assumeIsolated {
                SettingsActionStatusCenter.shared.update(
                    SettingsActionStatus(
                        kind: .working,
                        message: "正在恢复语音服务运行状态"
                    )
                )
            }
        }
        VoiceHelperLifecycleCoordinator.shared.setDesired(
            shouldEnable,
            layout: layout
        ) { result in
            // Coordinator 的 completion 合同是 @MainActor；显式保持与
            // AppKit delegate 其余跨隔离入口一致，避免未来实现换队列后
            // 在非主线程更新设置窗口状态。
            MainActor.assumeIsolated {
                guard shouldEnable else {
                    return
                }
                switch result {
                case .success:
                    SettingsActionStatusCenter.shared.update(
                        SettingsActionStatus(
                            kind: .success,
                            message: "语音服务已按保存的设置恢复"
                        )
                    )
                    NotificationCenter.default.post(
                        name: .rimeAIVoiceRetryRequested,
                        object: settings
                    )
                case let .failure(error):
                    // 安装缺失或恢复失败时 fail closed；设置中可再次启用。
                    settings.voiceEnabled = false
                    SettingsActionStatusCenter.shared.update(
                        SettingsActionStatus(
                            kind: .failure,
                            message: "语音服务恢复失败：\(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }
}

// Constructing the delegate also constructs IMKServer before the process first
// accesses NSApplication.shared. InputMethodKit relies on that ordering when it
// publishes the server's XPC endpoint during application bootstrap.
private let applicationDelegate = RimeAIApplicationDelegate()
private let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = applicationDelegate
withExtendedLifetime(applicationDelegate) {
    application.run()
}
