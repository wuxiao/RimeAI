import AppKit
import Foundation

extension Notification.Name {
    static let rimeAISettingsActionStatusDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.settings-action-status-did-change"
    )
}

struct SettingsActionStatus: Equatable {
    enum Kind: Equatable {
        case ready
        case working
        case success
        case failure
    }

    let kind: Kind
    let message: String

    static let ready = SettingsActionStatus(
        kind: .ready,
        message: "设置已载入；服务状态以各页实时显示为准"
    )
}

@MainActor
final class SettingsActionStatusCenter {
    static let shared = SettingsActionStatusCenter()

    private(set) var current = SettingsActionStatus.ready

    private init() {}

    func update(_ status: SettingsActionStatus) {
        guard status != current else {
            return
        }
        current = status
        NotificationCenter.default.post(
            name: .rimeAISettingsActionStatusDidChange,
            object: self
        )
    }
}

@MainActor
final class SettingsShortcutCaptureButton: NSButton {
    /// 固定宽度的键帽样式：显示快捷键、等待录制与出错提示时宽度都不变，
    /// 相邻控件不会跳动。
    static let keycapWidth: CGFloat = 184
    static let keycapHeight: CGFloat = 24
    static let capturingTitle = "请按下新组合…（Esc 取消）"
    static let invalidTitle = "组合不可用，请重试…（Esc 取消）"

    var onKeyEvent: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?
    var onCaptureStateChanged: ((Bool) -> Void)?

    private(set) var isCapturing = false
    private var currentDisplayName: String?
    private var emptyShortcutTitle = "添加备用快捷键…"
    private var eventMonitor: Any?
    private var showsValidationError = false
    private var errorResetWorkItem: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(
            frame: NSRect(x: 0, y: 0, width: Self.keycapWidth, height: Self.keycapHeight)
        )
        target = self
        action = #selector(toggleCapture(_:))
        isBordered = false
        wantsLayer = true
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 12.5, weight: .regular)
        widthAnchor.constraint(equalToConstant: Self.keycapWidth).isActive = true
        heightAnchor.constraint(equalToConstant: Self.keycapHeight).isActive = true
        setAccessibilityLabel("编辑语音快捷键")
        setAccessibilityHelp("点击后按下新的快捷键、Fn 或右侧 Command 键；按 Esc 取消。")
        refreshKeycapColors()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.keycapWidth, height: Self.keycapHeight)
    }

    isolated deinit {
        removeEventMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showShortcut(
        _ displayName: String?,
        emptyTitle: String = "添加备用快捷键…"
    ) {
        currentDisplayName = displayName
        emptyShortcutTitle = emptyTitle
        guard !isCapturing else {
            return
        }
        if let displayName, !displayName.isEmpty {
            title = "更改…（当前 \(displayName)）"
            setAccessibilityValue(displayName)
        } else {
            title = emptyTitle
            setAccessibilityValue("未设置")
        }
    }

    func beginCapture() {
        guard !isCapturing else {
            return
        }
        isCapturing = true
        showsValidationError = false
        title = Self.capturingTitle
        setAccessibilityValue("正在等待新快捷键")
        onCaptureStateChanged?(true)
        window?.makeFirstResponder(self)
        installEventMonitor()
        refreshKeycapColors()
    }

    /// 无效或冲突的组合：红色描边 + 抖动，录制继续等待下一次按键。
    func showValidationFailure() {
        guard isCapturing else {
            return
        }
        title = Self.invalidTitle
        setAccessibilityValue("快捷键组合不可用，正在等待重试")
        NSAccessibility.post(element: self, notification: .valueChanged)
        flashValidationError()
    }

    func finishCapture(displayName: String?) {
        removeEventMonitor()
        isCapturing = false
        clearValidationError()
        showShortcut(displayName, emptyTitle: emptyShortcutTitle)
        onCaptureStateChanged?(false)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    func cancelCapture() {
        guard isCapturing else {
            return
        }
        removeEventMonitor()
        isCapturing = false
        clearValidationError()
        showShortcut(currentDisplayName, emptyTitle: emptyShortcutTitle)
        onCaptureStateChanged?(false)
        onCancel?()
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    // MARK: - 键帽外观

    private func flashValidationError() {
        showsValidationError = true
        refreshKeycapColors()
        if let layer {
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [-5, 5, -4, 4, -2, 2, 0]
            shake.duration = 0.36
            shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.add(shake, forKey: "validationShake")
            CATransaction.commit()
        }
        errorResetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.clearValidationError()
            }
        }
        errorResetWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.2,
            execute: work
        )
    }

    private func clearValidationError() {
        errorResetWorkItem?.cancel()
        errorResetWorkItem = nil
        guard showsValidationError else {
            return
        }
        showsValidationError = false
        refreshKeycapColors()
    }

    private func refreshKeycapColors() {
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        if showsValidationError {
            layer?.borderColor = NSColor.systemRed.cgColor
            layer?.backgroundColor = NSColor.systemRed
                .withAlphaComponent(0.12).cgColor
            contentTintColor = .systemRed
        } else if isCapturing {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.08).cgColor
            contentTintColor = .controlAccentColor
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            contentTintColor = .labelColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshKeycapColors()
    }

    // MARK: - 录制

    private static func isCapturableModifierTap(_ event: NSEvent) -> Bool {
        var semantic = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        semantic.remove([.capsLock, .numericPad])
        return (event.keyCode == VoiceDictationShortcut.rightCommandKeyCode
            && semantic == [.command])
            || (event.keyCode == VoiceDictationShortcut.functionKeyCode
                && semantic == [.function])
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self, self.isCapturing else {
                return event
            }
            if event.type == .flagsChanged {
                if Self.isCapturableModifierTap(event) {
                    self.onKeyEvent?(event.keyCode, event.modifierFlags)
                    return nil
                }
                return event
            }
            if event.keyCode == 53 {
                self.cancelCapture()
                return nil
            }
            self.onKeyEvent?(event.keyCode, event.modifierFlags)
            return nil
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            cancelCapture()
            return
        }
        onKeyEvent?(event.keyCode, event.modifierFlags)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isCapturing else {
            super.flagsChanged(with: event)
            return
        }
        if Self.isCapturableModifierTap(event) {
            onKeyEvent?(event.keyCode, event.modifierFlags)
            return
        }
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            cancelCapture()
        }
        return resigned
    }

    @objc private func toggleCapture(_ sender: Any?) {
        if isCapturing {
            cancelCapture()
        } else {
            beginCapture()
        }
    }
}

@MainActor
final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

enum SettingsDocumentCodec {
    static let maximumDocumentBytes = RimeAISettingsStore
        .maxImportDocumentBytes

    static func validateFileSize(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize
        else {
            throw CocoaError(.fileReadUnknown)
        }
        try validateDocumentByteCount(fileSize)
    }

    static func validateDocumentByteCount(_ byteCount: Int) throws {
        guard byteCount <= maximumDocumentBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
    }

    static func encode(_ snapshot: RimeAISettingsExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        return try encoder.encode(snapshot)
    }

    static func decode(_ document: Data) throws -> RimeAISettingsExport {
        try validateDocumentByteCount(document.count)
        return try JSONDecoder().decode(
            RimeAISettingsExport.self,
            from: document
        )
    }
}

enum SettingsRuntimeOperation: Equatable, Sendable {
    case daemon(Bool)
    case cloudBroker(Bool)
    case voiceHelper(Bool)

    var displayName: String {
        switch self {
        case .daemon:
            return "daemon"
        case .cloudBroker:
            return "云端 broker"
        case .voiceHelper:
            return "语音 helper"
        }
    }
}

enum SettingsRuntimeStatusCopy {
    static func applied(_ operation: SettingsRuntimeOperation) -> String {
        let desired: String
        switch operation {
        case let .daemon(enabled),
             let .cloudBroker(enabled),
             let .voiceHelper(enabled):
            desired = enabled ? "启用" : "停用"
        }
        return "\(operation.displayName) \(desired)期望状态已应用；"
            + "连接状态继续刷新（以状态页为准）"
    }
}

typealias SettingsRuntimeCompletion = @MainActor @Sendable (
    Result<Void, Error>
) -> Void

enum SettingsDaemonActivationFailurePolicy {
    @MainActor
    static func apply(to settings: RimeAISettingsStore) {
        settings.aiEnabled = false
        settings.voiceEnabled = false
    }

    static func rollbackError(
        readinessError: Error,
        performRollback: () throws -> Void
    ) -> Error {
        do {
            try performRollback()
            return readinessError
        } catch let rollbackError {
            return NSError(
                domain: "fun.wwcn.inputmethod.RimeAI.daemon-activation",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Daemon 握手失败，且关闭回滚未完整完成："
                        + "\(readinessError.localizedDescription)；"
                        + rollbackError.localizedDescription,
                    NSUnderlyingErrorKey: rollbackError,
                ]
            )
        }
    }
}

enum SettingsDaemonDeactivationStep: String, Equatable, Sendable {
    case removeMarker = "删除启用 marker"
    case stopLaunchAgent = "停止 launchd job"
    case stopAdHocProcess = "停止 ad-hoc daemon"
}

struct SettingsDaemonDeactivationFailure: Equatable, Sendable {
    let step: SettingsDaemonDeactivationStep
    let description: String
}

struct SettingsDaemonDeactivationError: Error, Equatable, Sendable {
    let failures: [SettingsDaemonDeactivationFailure]
}

extension SettingsDaemonDeactivationError: LocalizedError {
    var errorDescription: String? {
        let details = failures.map {
            "\($0.step.rawValue)：\($0.description)"
        }.joined(separator: "；")
        return "Daemon 关闭未完整完成，运行态不确定：\(details)"
    }
}

struct SettingsDaemonLaunchAgentStopError: Error, Equatable, Sendable {
    let status: Int32
}

extension SettingsDaemonLaunchAgentStopError: LocalizedError {
    var errorDescription: String? {
        "launchctl kill returned \(status); daemon runtime state is uncertain"
    }
}

enum SettingsDaemonDeactivationPolicy {
    typealias Operation = (
        step: SettingsDaemonDeactivationStep,
        perform: () throws -> Void
    )

    static func requireSuccessfulLaunchctlKill(_ status: Int32) throws {
        guard status == 0 else {
            throw SettingsDaemonLaunchAgentStopError(status: status)
        }
    }

    static func run(_ operations: [Operation]) throws {
        var failures: [SettingsDaemonDeactivationFailure] = []
        for operation in operations {
            do {
                try operation.perform()
            } catch {
                failures.append(SettingsDaemonDeactivationFailure(
                    step: operation.step,
                    description: error.localizedDescription
                ))
            }
        }
        if !failures.isEmpty {
            throw SettingsDaemonDeactivationError(failures: failures)
        }
    }
}

/// Only a generation-bound, authenticated lifecycle probe may produce a
/// confirmed value. Process, pathname, socket-node, and UI status observations
/// remain unverified because they can be stale or predate the current request.
enum SettingsRuntimeAuthoritativeState: Equatable, Sendable {
    case confirmedEnabled
    case confirmedDisabled
    case unverified
}

struct SettingsRuntimeObservation: Equatable, Sendable {
    let daemon: SettingsRuntimeAuthoritativeState
    let cloudBroker: SettingsRuntimeAuthoritativeState
    let voiceHelper: SettingsRuntimeAuthoritativeState

    static let unverified = SettingsRuntimeObservation(
        daemon: .unverified,
        cloudBroker: .unverified,
        voiceHelper: .unverified
    )
}

enum SettingsLifecycleMarkerTransaction {
    static func run(
        createMarker: () throws -> Void,
        rollbackMarker: () throws -> Void,
        operation: () throws -> Void
    ) throws {
        try createMarker()
        do {
            try operation()
        } catch let operationError {
            do {
                try rollbackMarker()
            } catch let rollbackError {
                // A rollback failure is the actionable fail-closed error: the
                // caller must not leave an enable marker silently armed.
                throw rollbackError
            }
            throw operationError
        }
    }
}

enum SettingsRuntimeSocketNode {
    /// Confirms only the filesystem node type. It does not establish that a
    /// listener exists or that an authenticated protocol handshake can pass.
    static func exists(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeSocket
    }
}

struct SettingsRuntimeTransition: Equatable {
    let daemonEnabled: Bool?
    let cloudBrokerEnabled: Bool?
    let voiceHelperEnabled: Bool?

    static func plan(
        desired: RimeAISettingsExport,
        observation: SettingsRuntimeObservation = .unverified
    ) -> SettingsRuntimeTransition {
        let desiredVoiceEnabled = desired.aiEnabled && desired.voiceEnabled
        return SettingsRuntimeTransition(
            daemonEnabled: operation(
                desired: desired.aiEnabled,
                observed: observation.daemon
            ),
            cloudBrokerEnabled: operation(
                desired: desired.cloudConfigured,
                observed: observation.cloudBroker
            ),
            voiceHelperEnabled: operation(
                desired: desiredVoiceEnabled,
                observed: observation.voiceHelper
            )
        )
    }

    private static func operation(
        desired: Bool,
        observed: SettingsRuntimeAuthoritativeState
    ) -> Bool? {
        switch (desired, observed) {
        case (true, .confirmedEnabled), (false, .confirmedDisabled):
            return nil
        case (true, _):
            return true
        case (false, _):
            return false
        }
    }

    var orderedOperations: [SettingsRuntimeOperation] {
        var operations: [SettingsRuntimeOperation] = []
        if voiceHelperEnabled == false {
            operations.append(.voiceHelper(false))
        }
        if cloudBrokerEnabled == false {
            operations.append(.cloudBroker(false))
        }
        if daemonEnabled == false {
            operations.append(.daemon(false))
        }
        if daemonEnabled == true {
            operations.append(.daemon(true))
        }
        if cloudBrokerEnabled == true {
            operations.append(.cloudBroker(true))
        }
        if voiceHelperEnabled == true {
            operations.append(.voiceHelper(true))
        }
        return operations
    }
}
