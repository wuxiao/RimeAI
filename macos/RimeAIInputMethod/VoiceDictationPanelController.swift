import AppKit

/// 与拼音候选完全分离的听写面板。它不持有会话状态，只渲染控制器传入的
/// 快照并把显式确认/取消动作回调给 `VoiceDictationCoordinator`。
@MainActor
final class VoiceDictationPanelController: NSObject {
    private let panel: NSPanel
    private let backgroundView: NSVisualEffectView
    private let statusLabel = NSTextField(labelWithString: "")
    private let transcriptLabel = NSTextField(wrappingLabelWithString: "")
    private let confirmButton = NSButton(
        title: "确认（Space / ↩）",
        target: nil,
        action: nil
    )
    private let cancelButton = NSButton(
        title: "取消（Esc）",
        target: nil,
        action: nil
    )
    private var confirmHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 116),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        backgroundView = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: 520, height: 116)
        )
        super.init()

        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false

        backgroundView.material = .popover
        backgroundView.state = .active
        backgroundView.blendingMode = .behindWindow
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 10
        backgroundView.layer?.masksToBounds = true
        backgroundView.autoresizingMask = [.width, .height]
        panel.contentView = backgroundView

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        transcriptLabel.font = .systemFont(ofSize: 15, weight: .regular)
        transcriptLabel.textColor = .labelColor
        transcriptLabel.maximumNumberOfLines = 3
        transcriptLabel.lineBreakMode = .byTruncatingTail

        confirmButton.target = self
        confirmButton.action = #selector(confirm(_:))
        confirmButton.keyEquivalent = ""
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))

        for view in [
            statusLabel,
            transcriptLabel,
            confirmButton,
            cancelButton,
        ] {
            backgroundView.addSubview(view)
        }
        layoutSubviews()
    }

    func showListening(
        anchorRect: NSRect,
        onCancel: @escaping () -> Void
    ) {
        confirmHandler = nil
        cancelHandler = onCancel
        statusLabel.stringValue =
            "🎙 正在听写 · 松开 \(VoiceHotKeyManager.displayShortcut) 完成"
        transcriptLabel.stringValue = "请开始说话…"
        confirmButton.isHidden = true
        cancelButton.isHidden = false
        show(anchorRect: anchorRect)
    }

    func showConnecting(
        anchorRect: NSRect,
        onCancel: @escaping () -> Void
    ) {
        confirmHandler = nil
        cancelHandler = onCancel
        statusLabel.stringValue = "正在准备语音听写…"
        transcriptLabel.stringValue =
            "请按住 \(VoiceHotKeyManager.displayShortcut)，松开即可结束"
        confirmButton.isHidden = true
        cancelButton.isHidden = false
        show(anchorRect: anchorRect)
    }

    func showFinalizing(
        anchorRect: NSRect,
        onCancel: @escaping () -> Void
    ) {
        confirmHandler = nil
        cancelHandler = onCancel
        statusLabel.stringValue = "正在生成最终听写结果…"
        if transcriptLabel.stringValue == "请开始说话…" {
            transcriptLabel.stringValue = ""
        }
        confirmButton.isHidden = true
        cancelButton.isHidden = false
        show(anchorRect: anchorRect)
    }

    func updatePreview(
        stable: String,
        partial: String,
        pendingConfirm: Bool,
        polishApplied: Bool,
        anchorRect: NSRect,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        confirmHandler = pendingConfirm ? onConfirm : nil
        cancelHandler = onCancel
        let text = stable + partial
        transcriptLabel.stringValue = text.isEmpty ? "正在聆听…" : text
        if pendingConfirm {
            statusLabel.stringValue = polishApplied
                ? "听写完成 · 已应用有限润色，请确认后上屏"
                : "听写完成 · 请确认后上屏"
        } else {
            statusLabel.stringValue =
                "🎙 正在听写 · 松开 \(VoiceHotKeyManager.displayShortcut) 完成"
        }
        confirmButton.isHidden = !pendingConfirm
        cancelButton.isHidden = false
        transcriptLabel.setAccessibilityLabel(
            text.isEmpty ? "暂无听写文本" : text
        )
        show(anchorRect: anchorRect)
    }

    func showFailure(
        _ message: String,
        anchorRect: NSRect,
        onCancel: @escaping () -> Void
    ) {
        confirmHandler = nil
        cancelHandler = onCancel
        statusLabel.stringValue = "语音听写不可用"
        transcriptLabel.stringValue = message
        confirmButton.isHidden = true
        cancelButton.isHidden = false
        show(anchorRect: anchorRect)
    }

    func hide() {
        panel.orderOut(nil)
        statusLabel.stringValue = ""
        transcriptLabel.stringValue = ""
        transcriptLabel.setAccessibilityLabel(nil)
        confirmButton.isHidden = true
        cancelButton.isHidden = true
        confirmHandler = nil
        cancelHandler = nil
    }

#if DEBUG
    struct TestingSnapshot: Equatable {
        let status: String
        let transcript: String
        let accessibilityLabel: String?
        let confirmIsHidden: Bool
        let cancelIsHidden: Bool
        let hasConfirmHandler: Bool
        let hasCancelHandler: Bool
    }

    /// App target 测试专用：不展示窗口，只构造 hide 必须彻底擦除的状态。
    func populateForHideTesting() {
        statusLabel.stringValue = "测试状态"
        transcriptLabel.stringValue = "不得残留的听写正文"
        transcriptLabel.setAccessibilityLabel("不得残留的听写正文")
        confirmButton.isHidden = false
        cancelButton.isHidden = false
        confirmHandler = {}
        cancelHandler = {}
    }

    var testingSnapshot: TestingSnapshot {
        TestingSnapshot(
            status: statusLabel.stringValue,
            transcript: transcriptLabel.stringValue,
            accessibilityLabel: transcriptLabel.accessibilityLabel(),
            confirmIsHidden: confirmButton.isHidden,
            cancelIsHidden: cancelButton.isHidden,
            hasConfirmHandler: confirmHandler != nil,
            hasCancelHandler: cancelHandler != nil
        )
    }
#endif

    private func show(anchorRect: NSRect) {
        let size = panel.frame.size
        let screen = NSScreen.screens.first {
            $0.frame.contains(
                NSPoint(x: anchorRect.midX, y: anchorRect.midY)
            )
        } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        var x = anchorRect.minX
        var y = anchorRect.minY - size.height - 4
        if y < visibleFrame.minY {
            y = anchorRect.maxY + 4
        }
        x = min(max(x, visibleFrame.minX), visibleFrame.maxX - size.width)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    private func layoutSubviews() {
        backgroundView.frame = NSRect(
            origin: .zero,
            size: panel.frame.size
        )
        statusLabel.frame = NSRect(x: 14, y: 88, width: 492, height: 18)
        transcriptLabel.frame = NSRect(x: 14, y: 38, width: 492, height: 45)
        cancelButton.frame = NSRect(x: 390, y: 7, width: 116, height: 28)
        confirmButton.frame = NSRect(x: 238, y: 7, width: 146, height: 28)
    }

    @objc private func confirm(_ sender: NSButton) {
        confirmHandler?()
    }

    @objc private func cancel(_ sender: NSButton) {
        cancelHandler?()
    }
}
