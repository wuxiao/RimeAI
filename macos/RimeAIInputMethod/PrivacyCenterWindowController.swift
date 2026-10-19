import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PrivacyCenterWindowController: NSObject {
    static let shared = PrivacyCenterWindowController()

    let settings = RimeAISettingsStore.shared
    let credentialStore = FileCloudCredentialStore.shared
    let historyService = RimeAIHistoryService.shared
    let window: NSWindow
    let characterSetPopup = NSPopUpButton(
        frame: .zero,
        pullsDown: false
    )
    let characterWidthPopup = NSPopUpButton(
        frame: .zero,
        pullsDown: false
    )
    let punctuationPopup = NSPopUpButton(
        frame: .zero,
        pullsDown: false
    )
    let aiToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let offlineToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let contextPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let cloudModelPopup = NSPopUpButton(
        frame: .zero,
        pullsDown: false
    )
    let apiKeyField = NSSecureTextField()
    let cloudStatusLabel = NSTextField(labelWithString: "")
    let historyStatusLabel = NSTextField(labelWithString: "")
    let phrasebookStatusLabel = NSTextField(labelWithString: "")
    let profileSummaryLabel = NSTextField(labelWithString: "")
    let phrasebookEditor = PhrasebookEditorControls()
    let voiceToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let voiceRimeHotwordToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let voiceInstructionLabel = NSTextField(labelWithString: "")
    let voiceShortcutCaptureButton = SettingsShortcutCaptureButton()
    let voiceShortcutCancelButton = NSButton(
        title: "取消编辑",
        target: nil,
        action: nil
    )
    let voiceShortcutStatusLabel = NSTextField(labelWithString: "")
    let voiceStatusLabel = NSTextField(labelWithString: "")
    let disabledAIField = NSTextField()
    let disabledContextField = NSTextField()
    let daemonStatusLabel = NSTextField(labelWithString: "")
    let modelLabel = NSTextField(labelWithString: "")
    let artifactLabel = NSTextField(labelWithString: "")
    let diagnosticsLabel = NSTextField(labelWithString: "")
    let dataSizeLabel = NSTextField(labelWithString: "")
    let settingsActionStatusLabel = NSTextField(labelWithString: "")
    let importSettingsButton = NSButton(
        title: "导入设置…",
        target: nil,
        action: nil
    )
    let restoreDefaultSettingsButton = NSButton(
        title: "恢复默认设置…",
        target: nil,
        action: nil
    )
    var daemonObserver: NSObjectProtocol?
    var cloudObserver: NSObjectProtocol?
    var settingsObserver: NSObjectProtocol?
    var diagnosticsObserver: NSObjectProtocol?
    var settingsActionStatusObserver: NSObjectProtocol?
    var voiceShortcutStatusObserver: NSObjectProtocol?
    lazy var lifecycleCoordinator: ServiceLifecycleCoordinator =
        ServiceLifecycleCoordinator(
            eventHandler: { [weak self] event in
                self?.handleLifecycleEvent(event)
            },
            performOperation: { [weak self] operation, completion in
                guard let self else {
                    return
                }
                self.performLifecycleOperation(
                    operation,
                    completion: completion
                )
            }
        )

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.delegate = self
        reconcileCloudConfiguration()
        window.title = "RimeAI 设置"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 620)
        configureInterface()
        observeState()
        refresh()
    }

    func showWindow() {
        refresh()
        if settings.aiEnabled {
            DaemonClient.shared.connect()
        }
        if settings.cloudConfigured {
            CloudBrokerClient.shared.connect()
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureInterface() {
        // The local daemon remains offline even when the separate cloud broker
        // is enabled with a user-provided credential.
        settings.offlineLockEnabled = true

        let contentView = NSView()
        window.contentView = contentView

        let title = label(
            "RimeAI 设置",
            font: .systemFont(ofSize: 22, weight: .semibold)
        )
        title.setAccessibilityLabel("RimeAI 设置")
        configureWrapping(settingsActionStatusLabel)
        settingsActionStatusLabel.font = .systemFont(ofSize: 12)
        settingsActionStatusLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.action-status"
        )
        settingsActionStatusLabel.setAccessibilityLabel("设置操作状态")

        let tabView = NSTabView()
        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.setAccessibilityLabel("RimeAI 设置分类")
        tabView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let rootStack = NSStackView(views: [
            title,
            settingsActionStatusLabel,
            tabView,
        ])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: 18
            ),
            rootStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -18
            ),
            rootStack.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: 16
            ),
            rootStack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -16
            ),
            tabView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            settingsActionStatusLabel.widthAnchor.constraint(
                equalTo: rootStack.widthAnchor
            ),
            tabView.heightAnchor.constraint(greaterThanOrEqualToConstant: 500),
        ])

        let inputStack = addSettingsTab(
            to: tabView,
            title: "输入与 AI"
        )
        let voiceStack = addSettingsTab(
            to: tabView,
            title: "语音"
        )
        let cloudStack = addSettingsTab(
            to: tabView,
            title: "云端与历史"
        )
        let profileStack = addSettingsTab(
            to: tabView,
            title: "语言画像"
        )
        let statusStack = addSettingsTab(
            to: tabView,
            title: "状态与数据"
        )
        buildInputSettingsPage(inputStack)
        buildVoiceSettingsPage(voiceStack)
        buildCloudHistoryPage(cloudStack)
        buildLanguageProfilePage(profileStack)
        buildStatusDataPage(statusStack)
    }
}

extension PrivacyCenterWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        voiceShortcutCaptureButton.cancelCapture()
        voiceShortcutCancelButton.isEnabled = false
    }
}
