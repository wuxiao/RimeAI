import AppKit

@MainActor
final class CandidatePanelController: NSObject {
    /// 一次面板刷新所需的完整内容模型。
    struct Content {
        let visibleCandidates: [String]
        let primaryCandidate: String?
        let pageLabel: String?
        let semanticPresentation: SemanticCandidatePresentation
        let suggestionSource: HistoryCommitSource
        let contextCharacterCount: Int
        let cloudInFlight: Bool
        /// 当前展示的整句建议来自神经臂迟到帧（LM-002 开发期来源
        /// 标注）；随 token 失效链自动消失。
        let neuralLateApplied: Bool
    }

    private let panel: NSPanel
    private let backgroundView: NSVisualEffectView
    private let mainCandidatesStack: NSStackView
    private let semanticButton: NSButton
    private let pageIndicator: NSTextField
    private var mainSelectionHandler: ((Int) -> Void)?
    private var semanticSelectionHandler: (() -> Void)?
    private var pageIndicatorVisible = false
    private var hasVisibleContent = false
    /// 续写形态不经过 `refreshCandidatePanelIfActive` 的 hasComposition
    /// 守卫；控制器据此避免把正常候选面板的隐藏误伤续写 chip（反之亦然）。
    private(set) var isShowingContinuation = false

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 66),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        backgroundView = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 66)
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

    /// 语义行标题组装：候选态按建议来源署名（☁︎ 云端系 / ✦ 本地
    /// 系）；LM-002 开发期神经臂迟到帧的建议与云端“☁︎ LLM 生成”
    /// 对称署名，避免本地/云端来源混淆；云端在途与上下文字数后置。
    private func resolvedSemanticTitle(
        presentation: SemanticCandidatePresentation,
        suggestionSource: HistoryCommitSource,
        primaryCandidate: String?,
        neuralLateApplied: Bool,
        cloudInFlight: Bool,
        contextCharacterCount: Int
    ) -> String {
        var semanticTitle: String
        if case let .candidate(text, _, _) = presentation {
            switch suggestionSource {
            case .cloudExact:
                semanticTitle = "☁︎ 云端建议：\(text)"
            case .cloudFuzzy:
                semanticTitle = "☁︎ 云端纠错：\(text)"
            case .cloudGenerated:
                semanticTitle = "☁︎ LLM 生成：\(text)"
            case .continuation:
                semanticTitle = "✦ 续写：\(text)"
            case .phraseBook:
                semanticTitle = "✦ 个人短语：\(text)"
            case .rimeMain, .localSemantic, .rawPinyin:
                semanticTitle = neuralLateApplied
                    ? "✦ 本地模型：\(text)"
                    : presentation.title
            }
        } else {
            semanticTitle = presentation.title(
                mainCandidate: primaryCandidate
            )
        }
        if cloudInFlight {
            // 云端请求在途：本地可选候选保留原文追加提示，负面诊断等
            // 不可选状态直接让位给云端分析中，AI 参与始终可见。
            if presentation.isSelectable {
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
        return semanticTitle
    }

    func update(
        content: Content,
        onMainSelection: @escaping (Int) -> Void,
        onSemanticSelection: @escaping () -> Void
    ) {
        let visibleCandidates = content.visibleCandidates
        let primaryCandidate = content.primaryCandidate
        let pageLabel = content.pageLabel
        let semanticPresentation = content.semanticPresentation
        let suggestionSource = content.suggestionSource
        let contextCharacterCount = content.contextCharacterCount
        let cloudInFlight = content.cloudInFlight
        let neuralLateApplied = content.neuralLateApplied
        mainSelectionHandler = onMainSelection
        semanticSelectionHandler = onSemanticSelection
        isShowingContinuation = semanticPresentation.isContinuation

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

        let semanticTitle = resolvedSemanticTitle(
            presentation: semanticPresentation,
            suggestionSource: suggestionSource,
            primaryCandidate: primaryCandidate,
            neuralLateApplied: neuralLateApplied,
            cloudInFlight: cloudInFlight,
            contextCharacterCount: contextCharacterCount
        )
        semanticButton.title = semanticTitle
        semanticButton.setAccessibilityLabel(semanticTitle)
        semanticButton.isEnabled = semanticPresentation.isSelectable
        semanticButton.alphaValue = semanticPresentation.isSelectable ? 1 : 0.68
        semanticButton.toolTip = semanticPresentation.isSelectable
            ? (semanticPresentation.isMixedCompositionCandidate
                ? "Tab 接受中英混输候选"
                : suggestionSource == .cloudFuzzy
                ? "Tab 接受云端纠错候选"
                : suggestionSource == .cloudGenerated
                    ? "Tab 接受 LLM 生成整句"
                    : suggestionSource == .cloudExact
                        ? "Tab 接受云端语义候选"
                        : suggestionSource == .phraseBook
                            ? "Tab 接受个人短语候选"
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
        // 面板高度只容纳实际内容：上 6 + 候选行 28 + 间距 4 +
        // 语义行 22 + 下 6，消除两行之间与底部的大面积留白。
        let contentHeight: CGFloat = showsMainCandidates ? 66 : 34
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
        var panelOriginX = anchorRect.minX
        var panelOriginY = anchorRect.minY - size.height - 4
        if panelOriginY < visibleFrame.minY {
            panelOriginY = anchorRect.maxY + 4
        }
        panelOriginX = min(
            max(panelOriginX, visibleFrame.minX),
            visibleFrame.maxX - size.width
        )
        panel.setFrameOrigin(
            NSPoint(x: panelOriginX, y: panelOriginY)
        )
        panel.orderFrontRegardless()
    }

    func hide() {
        isShowingContinuation = false
        panel.orderOut(nil)
    }

    /// 上屏后续写 chip：主候选为空、无分页、无云端在途标记，走既有
    /// update + show 渲染路径；不经过 refreshCandidatePanelIfActive。
    func showContinuation(
        _ text: String,
        anchor: NSRect,
        onSelection: @escaping () -> Void
    ) {
        update(
            content: Content(
                visibleCandidates: [],
                primaryCandidate: nil,
                pageLabel: nil,
                semanticPresentation: .continuation(candidate: text),
                suggestionSource: .continuation,
                contextCharacterCount: 0,
                cloudInFlight: false,
                neuralLateApplied: false
            ),
            onMainSelection: { _ in },
            onSemanticSelection: onSelection
        )
        show(anchorRect: anchor)
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
        let semanticHeight: CGFloat = 22
        let candidatesHeight: CGFloat = showsMainCandidates ? 28 : 0
        let candidatesY = height - 6 - candidatesHeight
        mainCandidatesStack.frame = NSRect(
            x: 8,
            y: showsMainCandidates ? candidatesY : 0,
            width: width - 16 - (pageIndicatorVisible ? 64 : 0),
            height: candidatesHeight
        )
        pageIndicator.frame = NSRect(
            x: width - 8 - 56,
            y: showsMainCandidates
                ? candidatesY + (candidatesHeight - 16) / 2
                : (height - 16) / 2,
            width: 56,
            height: 16
        )
        pageIndicator.isHidden = !pageIndicatorVisible
        semanticButton.frame = NSRect(
            x: 8,
            y: 6,
            width: width - 16,
            height: semanticHeight
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

    /// Tab 接受续写 chip：与点击 chip 同一回调路径；未在续写形态
    /// 时返回 false，调用方继续原有 Tab 分派。
    @discardableResult
    func acceptContinuationIfShowing() -> Bool {
        guard isShowingContinuation,
              let handler = semanticSelectionHandler
        else {
            return false
        }
        handler()
        return true
    }
}
