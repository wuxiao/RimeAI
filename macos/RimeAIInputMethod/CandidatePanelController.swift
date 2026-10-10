import AppKit

@MainActor
final class CandidatePanelController: NSObject {
    private let panel: NSPanel
    private let backgroundView: NSVisualEffectView
    private let mainCandidatesStack: NSStackView
    private let semanticButton: NSButton
    private let pageIndicator: NSTextField
    private var mainSelectionHandler: ((Int) -> Void)?
    private var semanticSelectionHandler: (() -> Void)?
    private var pageIndicatorVisible = false
    private var hasVisibleContent = false

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
        pageIndicator = NSTextField(labelWithString: "")
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

        pageIndicator.isBezeled = false
        pageIndicator.isEditable = false
        pageIndicator.drawsBackground = false
        pageIndicator.alignment = .right
        pageIndicator.font = .monospacedDigitSystemFont(
            ofSize: 11,
            weight: .regular
        )
        pageIndicator.textColor = .secondaryLabelColor
        pageIndicator.isHidden = true
        backgroundView.addSubview(pageIndicator)
    }

    func update(
        visibleCandidates: [String],
        primaryCandidate: String?,
        pageLabel: String?,
        semanticPresentation: SemanticCandidatePresentation,
        suggestionSource: HistoryCommitSource,
        contextCharacterCount: Int,
        cloudInFlight: Bool,
        onMainSelection: @escaping (Int) -> Void,
        onSemanticSelection: @escaping () -> Void
    ) {
        mainSelectionHandler = onMainSelection
        semanticSelectionHandler = onSemanticSelection

        for view in mainCandidatesStack.arrangedSubviews {
            mainCandidatesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, candidate) in visibleCandidates.enumerated() {
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

        pageIndicator.stringValue = pageLabel ?? ""
        pageIndicatorVisible = pageLabel != nil

        var semanticTitle: String
        if case let .candidate(text, _, _) = semanticPresentation {
            switch suggestionSource {
            case .cloudExact:
                semanticTitle = "☁︎ Qwen 建议：\(text)"
            case .cloudFuzzy:
                semanticTitle = "☁︎ Qwen 纠错：\(text)"
            case .cloudGenerated:
                semanticTitle = "☁︎ LLM 生成：\(text)"
            case .rimeMain, .localSemantic, .rawPinyin:
                semanticTitle = semanticPresentation.title
            }
        } else {
            semanticTitle = semanticPresentation.title(
                mainCandidate: primaryCandidate
            )
        }
        if cloudInFlight {
            // 云端请求在途：本地可选候选保留原文追加提示，负面诊断等
            // 不可选状态直接让位给云端分析中，AI 参与始终可见。
            if semanticPresentation.isSelectable {
                semanticTitle += " · ☁︎ 云端分析中…"
            } else {
                semanticTitle = SemanticCandidatePresentation
                    .cloudAnalyzing
                    .title
            }
        }
        if contextCharacterCount > 0 {
            semanticTitle += " · 上下文 \(contextCharacterCount) 字"
        }
        semanticButton.title = semanticTitle
        semanticButton.setAccessibilityLabel(semanticTitle)
        semanticButton.isEnabled = semanticPresentation.isSelectable
        semanticButton.alphaValue = semanticPresentation.isSelectable ? 1 : 0.68
        semanticButton.toolTip = semanticPresentation.isSelectable
            ? (semanticPresentation.isMixedCompositionCandidate
                ? "Tab 接受中英混输候选"
                : suggestionSource == .cloudFuzzy
                ? "Tab 接受 Qwen 纠错候选"
                : suggestionSource == .cloudGenerated
                    ? "Tab 接受 LLM 生成整句"
                    : suggestionSource == .cloudExact
                        ? "Tab 接受 Qwen 语义候选"
                        : "Tab 接受本地语义候选")
            : semanticTitle

        let showsMainCandidates = !visibleCandidates.isEmpty
        let contentWidth = min(
            960,
            max(
                260,
                // 分页指示器占据的 64pt 必须计入面板宽度，否则 stack
                // 比 fittingSize 窄 64pt，候选按钮被压缩成省略号。
                mainCandidatesStack.fittingSize.width + 16
                    + (pageIndicatorVisible ? 64 : 0),
                semanticButton.fittingSize.width + 24
            )
        )
        // 候选按钮与语义按钮分层不重叠；面板高度按"候选 + 语义"两段
        // 容纳，长 LLM 文本会被自然换行而非被压住。
        let contentHeight: CGFloat = showsMainCandidates ? 96 : 56
        hasVisibleContent = showsMainCandidates
            || semanticPresentation.isSelectable
        panel.setContentSize(
            NSSize(width: contentWidth, height: contentHeight)
        )
        layoutSubviews(
            width: contentWidth,
            height: contentHeight,
            showsMainCandidates: showsMainCandidates
        )
    }

    func show(anchorRect: NSRect) {
        guard hasVisibleContent else {
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

    private func layoutSubviews(
        width: CGFloat,
        height: CGFloat,
        showsMainCandidates: Bool
    ) {
        backgroundView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width, height: height)
        )
        pageIndicator.frame = NSRect(
            x: width - 8 - 56,
            y: showsMainCandidates ? 44 : 0,
            width: 56,
            height: 16
        )
        pageIndicator.isHidden = !pageIndicatorVisible
        mainCandidatesStack.frame = NSRect(
            x: 8,
            y: showsMainCandidates ? 64 : 0,
            width: width - 16 - (pageIndicatorVisible ? 64 : 0),
            height: showsMainCandidates ? 28 : 0
        )
        semanticButton.frame = NSRect(
            x: 8,
            y: 5,
            width: width - 16,
            height: showsMainCandidates ? 56 : 46
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
