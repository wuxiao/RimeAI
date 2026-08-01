import AppKit

@MainActor
final class CandidatePanelController: NSObject {
    private let panel: NSPanel
    private let backgroundView: NSVisualEffectView
    private let mainCandidatesStack: NSStackView
    private let semanticButton: NSButton
    private var mainSelectionHandler: ((Int) -> Void)?
    private var semanticSelectionHandler: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        backgroundView = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 72)
        )
        mainCandidatesStack = NSStackView()
        semanticButton = NSButton()
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
        backgroundView.layer?.cornerRadius = 9
        backgroundView.layer?.masksToBounds = true
        backgroundView.autoresizingMask = [.width, .height]
        panel.contentView = backgroundView

        mainCandidatesStack.orientation = .horizontal
        mainCandidatesStack.alignment = .centerY
        mainCandidatesStack.spacing = 4
        mainCandidatesStack.distribution = .gravityAreas
        backgroundView.addSubview(mainCandidatesStack)

        semanticButton.isBordered = false
        semanticButton.alignment = .left
        semanticButton.font = .systemFont(ofSize: 13, weight: .medium)
        semanticButton.contentTintColor = .controlAccentColor
        semanticButton.target = self
        semanticButton.action = #selector(acceptSemanticCandidate(_:))
        semanticButton.toolTip = "Tab 接受本地语义候选"
        backgroundView.addSubview(semanticButton)
    }

    func update(
        mainCandidates: [String],
        semanticCandidate: String?,
        onMainSelection: @escaping (Int) -> Void,
        onSemanticSelection: @escaping () -> Void
    ) {
        mainSelectionHandler = onMainSelection
        semanticSelectionHandler = onSemanticSelection

        for view in mainCandidatesStack.arrangedSubviews {
            mainCandidatesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, candidate) in mainCandidates.enumerated() {
            let button = NSButton(
                title: "\(index + 1) \(candidate)",
                target: self,
                action: #selector(acceptMainCandidate(_:))
            )
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 14, weight: .regular)
            button.contentTintColor = .labelColor
            button.setButtonType(.momentaryChange)
            mainCandidatesStack.addArrangedSubview(button)
        }

        if let semanticCandidate, !semanticCandidate.isEmpty {
            semanticButton.title = "✦ \(semanticCandidate)"
            semanticButton.isEnabled = true
            semanticButton.alphaValue = 1
        } else {
            semanticButton.title = "✦ 本地语义候选"
            semanticButton.isEnabled = false
            semanticButton.alphaValue = 0.28
        }

        let contentWidth = min(
            960,
            max(
                260,
                mainCandidatesStack.fittingSize.width + 16,
                semanticButton.fittingSize.width + 24
            )
        )
        panel.setContentSize(NSSize(width: contentWidth, height: 72))
        layoutSubviews(width: contentWidth)
    }

    func show(anchorRect: NSRect) {
        guard !mainCandidatesStack.arrangedSubviews.isEmpty else {
            hide()
            return
        }
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

    func hide() {
        panel.orderOut(nil)
    }

    private func layoutSubviews(width: CGFloat) {
        backgroundView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width, height: 72)
        )
        mainCandidatesStack.frame = NSRect(
            x: 8,
            y: 37,
            width: width - 16,
            height: 30
        )
        semanticButton.frame = NSRect(
            x: 8,
            y: 5,
            width: width - 16,
            height: 28
        )
    }

    @objc
    private func acceptMainCandidate(_ sender: NSButton) {
        mainSelectionHandler?(sender.tag)
    }

    @objc
    private func acceptSemanticCandidate(_ sender: NSButton) {
        guard sender.isEnabled else {
            return
        }
        semanticSelectionHandler?()
    }
}
