import AppKit
import ApplicationServices

/// 支持非激活悬浮但仍能响应 ⌘C / Esc / 空格 / 回车的听写浮窗。
private final class VoiceDictationFloatingPanel: NSPanel {
    var onCommandCopy: (() -> Bool)?
    var onConfirmKey: (() -> Bool)?
    var onEscapeClose: (() -> Bool)?

    override var canBecomeKey: Bool {
        true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        var modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        modifiers.remove([.capsLock, .numericPad])
        if event.keyCode == 8, modifiers == .command,
           onCommandCopy?() == true
        {
            return true
        }
        if event.keyCode == 53, modifiers.isEmpty,
           onEscapeClose?() == true
        {
            return true
        }
        // 面板成为 key window（用户点选了可复制文本）后，空格/回车必须仍
        // 等价于“上屏”：否则按键被浮窗自己吞掉，宿主永远收不到确认。
        if Self.isConfirmationKey(event.keyCode), modifiers.isEmpty,
           onConfirmKey?() == true
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func isConfirmationKey(_ keyCode: UInt16) -> Bool {
        keyCode == 49 || keyCode == 36 || keyCode == 76
    }
}

/// 深浅色切换时同步刷新图层描边等不会自动跟随外观的动态颜色。
private final class VoicePanelBackgroundView: NSVisualEffectView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// 顶对齐滚动容器，确保动态换行文本自上而下排布。
private final class VoiceTranscriptDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

/// 与拼音候选完全分离的极简听写浮窗。
/// - 录音期间展示状态指示（连接/识别/转换用旋转指示器，聆听用呼吸红点
///   与实时计时），文本实时自动换行。
/// - 宽度与高度随文本内容自适应，同一次会话内宽度只增不减；超长内容
///   平滑滚动，绝不横向溢出。
/// - 无光标焦点或无法自动上屏时进入常驻手动复制模式，说明真实原因，
///   不自动消失，支持按钮或 ⌘C 复制。
@MainActor
final class VoiceDictationPanelController: NSObject {
    private enum Layout {
        static let horizontalPadding: CGFloat = 16
        static let verticalPadding: CGFloat = 13
        static let dotSize: CGFloat = 8
        static let dotHaloSize: CGFloat = 16
        static let spinnerSize: CGFloat = 13
        static var indicatorSize: CGFloat { max(dotSize, spinnerSize) }
        static let dotTextSpacing: CGFloat = 8
        static let waveformWidth: CGFloat = 15
        static let waveformSpacing: CGFloat = 8
        static let statusHeight: CGFloat = 20
        static let statusBottomSpacing: CGFloat = 8
        static let timerPillHorizontalPadding: CGFloat = 7
        static let timerPillHeight: CGFloat = 20
        static let minPanelWidth: CGFloat = 124
        static let minActionPanelWidth: CGFloat = 256
        /// 待确认态需要同时容纳 [关闭] [复制] [上屏] 与左侧操作提示。
        static let minConfirmPanelWidth: CGFloat = 368
        static let maxPanelWidth: CGFloat = 380
        static let maxTextScrollHeight: CGFloat = 240
        static let minLineHeight: CGFloat = 21
        static let dividerHeight: CGFloat = 1
        static let actionBarTopSpacing: CGFloat = 10
        static let actionBarInnerTopSpacing: CGFloat = 9
        static let actionBarHeight: CGFloat = 26
        static let hintRowTopSpacing: CGFloat = 8
        static let hintRowInnerSpacing: CGFloat = 6
        static let hintRowHeight: CGFloat = 16
        static let minHintWidth: CGFloat = 72
        static let hintButtonSpacing: CGFloat = 8
        static let buttonSpacing: CGFloat = 6
        static let minButtonWidth: CGFloat = 56
        static let fontSize: CGFloat = 14
        static let lineSpacing: CGFloat = 5
        static let cornerRadius: CGFloat = 16
    }

    private enum DotStyle {
        case hidden
        case connecting
        case listening
        case finalizing
        case transforming
        case ready
        /// 与聆听的红色区分：错误用琥珀色并带警告图标。
        case error

        var color: NSColor {
            switch self {
            case .hidden:
                return .clear
            case .connecting:
                return .tertiaryLabelColor
            case .listening:
                return .systemRed
            case .finalizing:
                return .systemOrange
            case .transforming:
                return .controlAccentColor
            case .ready:
                return .systemGreen
            case .error:
                return .systemOrange
            }
        }

        /// 这些阶段用紧凑旋转指示器替代状态点。
        var usesSpinner: Bool {
            self == .connecting || self == .finalizing || self == .transforming
        }
    }

    /// 操作按钮的固定语义；数字即从左到右的视觉次序，主操作“上屏”最右。
    private enum Action: Int, CaseIterable {
        case cancel
        case copy
        case accessibility
        case settings
        case retry
        case confirm
    }

    private enum ScrollPosition {
        case top
        case bottom
        case preserve
    }

    private let panel: VoiceDictationFloatingPanel
    private let backgroundView: VoicePanelBackgroundView
    /// 柔和玻璃高光叠层：消除浅色模式下的灰暗毛玻璃感，在深浅色下都呈现通透层次。
    private let surfaceTintView = NSView()
    private let dotHaloView = NSView()
    private let statusDotView = NSView()
    private let waveformContainerView = NSView()
    private let waveformBars: [NSView] = [NSView(), NSView(), NSView()]
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let timerPillView = NSView()
    private let timerLabel = NSTextField(labelWithString: "")
    private let transcriptScrollView = NSScrollView()
    private let transcriptDocumentView = VoiceTranscriptDocumentView()
    private let transcriptLabel = NSTextField(wrappingLabelWithString: "")
    private let actionDivider = NSBox()
    private let actionHintLabel = NSTextField(labelWithString: "")
    private let confirmButton = NSButton(
        title: "上屏",
        target: nil,
        action: nil
    )
    private let copyButton = NSButton(
        title: "复制",
        target: nil,
        action: nil
    )
    private let cancelButton = NSButton(
        title: "关闭",
        target: nil,
        action: nil
    )
    private let retryButton = NSButton(
        title: "重试",
        target: nil,
        action: nil
    )
    private let settingsButton = NSButton(
        title: "打开系统设置",
        target: nil,
        action: nil
    )
    private let accessibilityButton = NSButton(
        title: "授权辅助功能",
        target: nil,
        action: nil
    )

    private var confirmHandler: (() -> Void)?
    private var copyHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?
    private var retryHandler: (() -> Void)?
    private var failureSettingsPane: VoiceSystemSettingsPane?
    private var toastDismissWorkItem: DispatchWorkItem?
    private var copyFeedbackWorkItem: DispatchWorkItem?
    private var failureDismissWorkItem: DispatchWorkItem?
    private var hintOverrideWorkItem: DispatchWorkItem?
    private var recordingTimer: DispatchSourceTimer?
    private var recordingStartedAt: Date?
    private var currentDotStyle: DotStyle = .hidden
    private var showsPlaceholderTranscript = false
    private var persistentCopyText: String?
    private var persistentCopyReason: VoicePersistentCopyReason = .noCursor
    private var currentHint: String?
    private var hintOverride: String?
    private var lastAnchorRect: NSRect = .zero
    private var preserveCurrentOriginOnNextLayout = false
    private var isPerformingProgrammaticLayout = false
    private var lastProgrammaticOrigin: NSPoint = .zero
    /// 用户在本次会话内拖动过浮窗：之后的预览刷新沿用该位置，不再弹回锚点。
    private var userMovedOrigin: NSPoint?
    /// 同一次会话内面板宽度的历史最大值。
    private var sessionMaximumWidth: CGFloat = 0
    private var moveObserver: NSObjectProtocol?
    private var lastAnnouncement: String?

    var isPersistentCopyVisible: Bool {
        persistentCopyText != nil && panel.isVisible
    }

    override init() {
        panel = VoiceDictationFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        backgroundView = VoicePanelBackgroundView(
            frame: NSRect(x: 0, y: 0, width: 220, height: 44)
        )
        super.init()

        panel.title = VoicePanelFormatting.panelTitle
        panel.isFloatingPanel = true
        // isFloatingPanel 会重置窗口层级：level 必须在其后设置才能保持置顶。
        panel.level = .popUpMenu
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.onCommandCopy = { [weak self] in
            self?.copyFromKeyEquivalent() ?? false
        }
        panel.onConfirmKey = { [weak self] in
            self?.confirmFromKeyEquivalent() ?? false
        }
        panel.onEscapeClose = { [weak self] in
            guard let self, let cancelHandler = self.cancelHandler else {
                return false
            }
            cancelHandler()
            return true
        }

        backgroundView.material = .menu
        backgroundView.state = .active
        backgroundView.blendingMode = .behindWindow
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = Layout.cornerRadius
        backgroundView.layer?.cornerCurve = .continuous
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.borderWidth = 0.5
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.onAppearanceChange = { [weak self] in
            self?.refreshDynamicColors()
        }
        panel.contentView = backgroundView

        surfaceTintView.wantsLayer = true
        surfaceTintView.autoresizingMask = [.width, .height]

        dotHaloView.wantsLayer = true
        dotHaloView.layer?.cornerRadius = Layout.dotHaloSize / 2
        dotHaloView.isHidden = true

        statusDotView.wantsLayer = true
        statusDotView.layer?.cornerRadius = Layout.dotSize / 2
        statusDotView.isHidden = true
        statusDotView.setAccessibilityLabel("语音状态指示")

        waveformContainerView.wantsLayer = true
        waveformContainerView.isHidden = true
        for bar in waveformBars {
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1.25
            bar.layer?.cornerCurve = .continuous
            waveformContainerView.addSubview(bar)
        }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.setAccessibilityLabel("处理中")

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true

        timerPillView.wantsLayer = true
        timerPillView.layer?.cornerRadius = Layout.timerPillHeight / 2
        timerPillView.layer?.cornerCurve = .continuous
        timerPillView.isHidden = true

        timerLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timerLabel.textColor = .secondaryLabelColor
        timerLabel.alignment = .center
        timerLabel.lineBreakMode = .byClipping
        timerLabel.isHidden = true
        timerLabel.setAccessibilityLabel("录音时长")
        timerPillView.addSubview(timerLabel)

        transcriptScrollView.drawsBackground = false
        transcriptScrollView.borderType = .noBorder
        transcriptScrollView.hasVerticalScroller = true
        transcriptScrollView.hasHorizontalScroller = false
        transcriptScrollView.autohidesScrollers = true
        transcriptScrollView.scrollerStyle = .overlay
        transcriptScrollView.documentView = transcriptDocumentView

        transcriptLabel.font = .systemFont(
            ofSize: Layout.fontSize,
            weight: .regular
        )
        transcriptLabel.textColor = .labelColor
        transcriptLabel.usesSingleLineMode = false
        transcriptLabel.maximumNumberOfLines = 0
        transcriptLabel.lineBreakMode = .byWordWrapping
        transcriptLabel.cell?.wraps = true
        transcriptLabel.cell?.isScrollable = false
        transcriptLabel.drawsBackground = false
        transcriptLabel.isBezeled = false
        transcriptLabel.isEditable = false
        transcriptLabel.isSelectable = false
        transcriptLabel.setAccessibilityLabel("听写文本")
        transcriptDocumentView.addSubview(transcriptLabel)

        // NSBox 分隔线会随深浅色外观自动取色；适度降透明度让视觉更轻盈。
        actionDivider.boxType = .separator
        actionDivider.alphaValue = 0.55
        actionDivider.isHidden = true

        actionHintLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        actionHintLabel.textColor = .secondaryLabelColor
        actionHintLabel.lineBreakMode = .byTruncatingTail
        actionHintLabel.isHidden = true

        configureButton(confirmButton, isPrimary: true, accessibility: "上屏听写文本")
        confirmButton.target = self
        confirmButton.action = #selector(confirm(_:))
        confirmButton.keyEquivalent = "\r"

        configureButton(copyButton, isPrimary: false, accessibility: "复制听写文本")
        copyButton.target = self
        copyButton.action = #selector(copyTranscript(_:))
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = [.command]

        configureButton(cancelButton, isPrimary: false, accessibility: "关闭听写浮窗")
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"

        configureButton(retryButton, isPrimary: false, accessibility: "重试语音服务")
        retryButton.target = self
        retryButton.action = #selector(retry(_:))

        configureButton(settingsButton, isPrimary: false, accessibility: "打开系统设置的隐私面板")
        settingsButton.target = self
        settingsButton.action = #selector(openSystemSettings(_:))

        configureButton(
            accessibilityButton,
            isPrimary: false,
            accessibility: "授权辅助功能权限以便自动粘贴"
        )
        accessibilityButton.target = self
        accessibilityButton.action = #selector(requestAccessibility(_:))

        for action in Action.allCases {
            button(for: action).isHidden = true
        }

        for view in [
            surfaceTintView,
            dotHaloView,
            statusDotView,
            waveformContainerView,
            spinner,
            statusLabel,
            timerPillView,
            transcriptScrollView,
            actionDivider,
            actionHintLabel,
            confirmButton,
            copyButton,
            cancelButton,
            retryButton,
            settingsButton,
            accessibilityButton,
        ] {
            backgroundView.addSubview(view)
        }

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePanelDidMove()
            }
        }
        refreshDynamicColors()
    }

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
    }

    private func configureButton(
        _ button: NSButton,
        isPrimary: Bool,
        accessibility: String
    ) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(
            ofSize: 12,
            weight: isPrimary ? .medium : .regular
        )
        // 只有主操作使用强调色。
        button.bezelColor = isPrimary ? .controlAccentColor : nil
        button.setAccessibilityLabel(accessibility)
    }

    private func button(for action: Action) -> NSButton {
        switch action {
        case .cancel: cancelButton
        case .copy: copyButton
        case .accessibility: accessibilityButton
        case .settings: settingsButton
        case .retry: retryButton
        case .confirm: confirmButton
        }
    }

    /// 从左到右的操作次序：次要/破坏性操作在左，主操作“上屏”在最右。
    private var orderedButtons: [NSButton] {
        Action.allCases.sorted { $0.rawValue < $1.rawValue }.map(button(for:))
    }

    // MARK: - Presentation States

    func showConnecting(
        intent: VoiceSessionIntent = .dictation,
        anchorRect: NSRect,
        onCancel: @escaping () -> Void
    ) {
        resetTransientState()
        beginNewSession()
        cancelHandler = onCancel
        currentDotStyle = .connecting
        setStatusBadge(nil)
        stopRecordingTimer()
        setPlaceholder(intent.isTranslation ? "准备翻译…" : "准备中…")
        configureActions(hint: nil, visible: [])
        announce("正在连接语音服务")
        present(anchorRect: anchorRect, scroll: .top)
    }

    func showListening(
        intent: VoiceSessionIntent = .dictation,
        anchorRect: NSRect,
        recordingStartedAt: Date? = nil,
        onCancel: @escaping () -> Void
    ) {
        resetTransientState()
        cancelHandler = onCancel
        currentDotStyle = .listening
        if case let .translate(language) = intent {
            setStatusBadge("翻译 · \(language.shortName)")
        } else {
            setStatusBadge(nil)
        }
        startRecordingTimer(startedAt: recordingStartedAt ?? Date())
        setPlaceholder("聆听中…")
        configureActions(hint: nil, visible: [])
        announce("开始聆听")
        present(anchorRect: anchorRect, scroll: .top)
    }

    func showFinalizing(
        intent: VoiceSessionIntent = .dictation,
        anchorRect: NSRect,
        onCancel: @escaping () -> Void
    ) {
        cancelTimers()
        persistentCopyText = nil
        confirmHandler = nil
        copyHandler = nil
        cancelHandler = onCancel
        currentDotStyle = .finalizing
        if case let .translate(language) = intent {
            setStatusBadge("识别中 · \(language.shortName)")
        } else {
            setStatusBadge(nil)
        }
        if showsPlaceholderTranscript {
            setPlaceholder("识别中…")
        }
        configureActions(hint: nil, visible: [])
        announce("识别中")
        present(anchorRect: anchorRect, scroll: .bottom)
    }

    func showTransforming(
        statusText: String,
        sourcePreview: String,
        anchorRect: NSRect,
        onCancel: @escaping () -> Void
    ) {
        resetTransientState()
        cancelHandler = onCancel
        currentDotStyle = .transforming
        setStatusBadge(statusText)
        stopRecordingTimer()
        setTranscript(
            attributed: makeTranscriptAttributedString(
                stable: sourcePreview,
                partial: ""
            ),
            plainText: sourcePreview,
            selectable: false
        )
        configureActions(hint: VoicePanelFormatting.transformHint, visible: [])
        announce(statusText)
        present(anchorRect: anchorRect, scroll: .bottom)
    }

    func updatePreview(
        stable: String,
        partial: String,
        pendingConfirm: Bool,
        polishApplied: Bool,
        intent: VoiceSessionIntent = .dictation,
        customStatus: String? = nil,
        anchorRect: NSRect,
        onConfirm: @escaping () -> Void,
        onCopy: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        resetTransientState()
        confirmHandler = pendingConfirm ? onConfirm : nil
        copyHandler = pendingConfirm ? onCopy : nil
        cancelHandler = onCancel
        let text = stable + partial

        if pendingConfirm {
            currentDotStyle = .ready
            stopRecordingTimer()
            if let customStatus, !customStatus.isEmpty {
                setStatusBadge(customStatus)
            } else if case let .translate(language) = intent {
                setStatusBadge("翻译 · \(language.shortName)")
            } else if polishApplied {
                setStatusBadge("已润色")
            } else {
                setStatusBadge(nil)
            }
            setTranscript(
                attributed: makeTranscriptAttributedString(
                    stable: text,
                    partial: ""
                ),
                plainText: text,
                selectable: true
            )
            confirmButton.title = "上屏"
            copyButton.title = "复制"
            cancelButton.title = "关闭"
            // macOS HIG：左到右 [关闭] [复制] [上屏]，仅“上屏”为强调色主按钮。
            configureActions(
                hint: VoicePanelFormatting.pendingConfirmHint,
                visible: onCopy == nil ? [.confirm, .cancel] : [.confirm, .copy, .cancel]
            )
            announce("识别完成，空格或回车上屏")
            present(anchorRect: anchorRect, scroll: .top)
        } else {
            currentDotStyle = .listening
            if case let .translate(language) = intent {
                setStatusBadge("翻译 · \(language.shortName)")
            } else {
                setStatusBadge(nil)
            }
            startRecordingTimer(startedAt: Date())
            if text.isEmpty {
                setPlaceholder("聆听中…")
            } else {
                setTranscript(
                    attributed: makeTranscriptAttributedString(
                        stable: stable,
                        partial: partial
                    ),
                    plainText: text,
                    selectable: false
                )
            }
            configureActions(hint: nil, visible: [])
            present(anchorRect: anchorRect, scroll: .bottom)
        }
    }

    /// 无光标焦点 / 无法自动上屏时进入常驻悬浮模式：说明真实原因，绝不
    /// 自动消失，直到用户复制或手动关闭。
    func showPersistentCopy(
        text: String,
        badge: String? = nil,
        reason: VoicePersistentCopyReason = .noCursor,
        anchorRect: NSRect,
        onCopied: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        cancelTimers()
        confirmHandler = nil
        persistentCopyText = text
        persistentCopyReason = reason
        copyHandler = { [weak self] in
            self?.performCopyAndDismiss(onCopied: onCopied)
        }
        cancelHandler = onClose
        currentDotStyle = .ready
        setStatusBadge(badge)
        stopRecordingTimer()
        setTranscript(
            attributed: makeTranscriptAttributedString(
                stable: text,
                partial: ""
            ),
            plainText: text,
            selectable: true
        )
        copyButton.title = "复制 ⌘C"
        cancelButton.title = "关闭"
        var visible: Set<Action> = [.copy, .cancel]
        if reason.offersAccessibilityAuthorization {
            visible.insert(.accessibility)
        }
        configureActions(hint: reason.hint, visible: visible)
        announce(reason.hint)
        present(anchorRect: anchorRect, scroll: .top)
    }

    /// 由快捷键（⌘C）触发复制常驻浮窗文本；返回 true 表示已复制并进入收起反馈。
    @discardableResult
    func triggerCopyFromShortcut() -> Bool {
        guard isPersistentCopyVisible, let copyHandler else {
            return false
        }
        copyHandler()
        return true
    }

    func showFailure(
        _ message: String,
        presentation: VoiceFailurePresentation = .transient,
        anchorRect: NSRect,
        onRetry: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        resetTransientState()
        cancelHandler = onCancel
        retryHandler = onRetry ?? {
            NotificationCenter.default.post(
                name: .rimeAIVoiceRetryRequested,
                object: nil
            )
        }
        failureSettingsPane = presentation.settingsPane
        currentDotStyle = .error
        setStatusBadge(VoicePanelFormatting.errorBadge, color: .systemOrange)
        stopRecordingTimer()
        setTranscript(
            attributed: makeTranscriptAttributedString(
                stable: message,
                partial: ""
            ),
            plainText: message,
            selectable: false
        )
        cancelButton.title = "关闭"
        var visible: Set<Action> = [.cancel]
        if presentation.offersRetry {
            visible.insert(.retry)
        }
        if presentation.settingsPane != nil {
            visible.insert(.settings)
        }
        configureActions(hint: nil, visible: visible)
        announce("语音不可用：\(message)")
        present(anchorRect: anchorRect, scroll: .top)

        if let autoDismiss = presentation.autoDismissSeconds {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.hide()
                }
            }
            failureDismissWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + autoDismiss,
                execute: work
            )
        }
    }

    /// 短暂提示浮层，到期自动收起。
    func showTransientToast(
        title: String,
        message: String,
        anchorRect: NSRect,
        durationSeconds: TimeInterval = 2.0
    ) {
        resetTransientState()
        cancelHandler = { [weak self] in self?.hide() }
        currentDotStyle = .ready
        setStatusBadge(title.isEmpty ? nil : title)
        stopRecordingTimer()
        setTranscript(
            attributed: makeTranscriptAttributedString(
                stable: message,
                partial: ""
            ),
            plainText: message,
            selectable: false
        )
        configureActions(hint: nil, visible: [])
        announce(message)
        present(anchorRect: anchorRect, scroll: .top)

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
        toastDismissWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + durationSeconds,
            execute: work
        )
    }

    func hide() {
        cancelTimers()
        stopRecordingTimer()
        persistentCopyText = nil
        persistentCopyReason = .noCursor
        preserveCurrentOriginOnNextLayout = false
        userMovedOrigin = nil
        sessionMaximumWidth = 0
        panel.orderOut(nil)
        dotHaloView.isHidden = true
        statusDotView.isHidden = true
        waveformContainerView.isHidden = true
        stopDotPulse()
        stopWaveformAnimation()
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        currentDotStyle = .hidden
        statusLabel.stringValue = ""
        statusLabel.isHidden = true
        statusLabel.textColor = .secondaryLabelColor
        timerLabel.stringValue = ""
        timerLabel.isHidden = true
        timerPillView.isHidden = true
        transcriptLabel.attributedStringValue = NSAttributedString(string: "")
        transcriptLabel.stringValue = ""
        transcriptLabel.isSelectable = false
        transcriptLabel.setAccessibilityLabel(nil)
        showsPlaceholderTranscript = false
        actionDivider.isHidden = true
        actionHintLabel.stringValue = ""
        actionHintLabel.isHidden = true
        currentHint = nil
        hintOverride = nil
        for button in orderedButtons {
            button.isHidden = true
        }
        confirmHandler = nil
        copyHandler = nil
        cancelHandler = nil
        retryHandler = nil
        failureSettingsPane = nil
        lastAnnouncement = nil
    }

    // MARK: - Copy

    private func copyFromKeyEquivalent() -> Bool {
        if let selected = selectedTranscriptText(), !selected.isEmpty {
            copyToPasteboard(selected)
            flashHintOverride("已复制所选内容")
            announce("已复制所选内容")
            return true
        }
        // 未选中任何范围：复制完整文本（常驻复制态会给出“已复制 ✓”反馈）。
        if let copyHandler {
            copyHandler()
            return true
        }
        return false
    }

    private func confirmFromKeyEquivalent() -> Bool {
        if let confirmHandler {
            confirmHandler()
            return true
        }
        // 浮窗为 key 时没有可确认内容：吞掉空格/回车，避免系统提示音。
        return persistentCopyText == nil && panel.isVisible
    }

    /// 可选中文本的当前选区；面板不是 key window 或未选中时返回 nil。
    private func selectedTranscriptText() -> String? {
        guard transcriptLabel.isSelectable,
              let editor = transcriptLabel.currentEditor() as? NSTextView
        else {
            return nil
        }
        let range = editor.selectedRange
        guard range.length > 0,
              let swiftRange = Range(range, in: editor.string)
        else {
            return nil
        }
        return String(editor.string[swiftRange])
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func performCopyAndDismiss(onCopied: @escaping () -> Void) {
        guard let text = persistentCopyText, !text.isEmpty else {
            hide()
            return
        }
        copyToPasteboard(text)
        onCopied()
        announce("已复制到剪贴板")

        copyButton.title = VoicePanelFormatting.copiedFeedbackTitle
        preserveCurrentOriginOnNextLayout = true
        layoutAndResize(anchorRect: lastAnchorRect, scroll: .preserve)
        preserveCurrentOriginOnNextLayout = false

        copyFeedbackWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
        copyFeedbackWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(450),
            execute: work
        )
    }

    private func flashHintOverride(_ text: String) {
        hintOverrideWorkItem?.cancel()
        hintOverride = text
        layoutAndResize(anchorRect: lastAnchorRect, scroll: .preserve)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.hintOverride = nil
                self.layoutAndResize(anchorRect: self.lastAnchorRect, scroll: .preserve)
            }
        }
        hintOverrideWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(1_200),
            execute: work
        )
    }

    // MARK: - State Helpers

    private func resetTransientState() {
        cancelTimers()
        persistentCopyText = nil
        persistentCopyReason = .noCursor
        confirmHandler = nil
        copyHandler = nil
        cancelHandler = nil
        retryHandler = nil
        failureSettingsPane = nil
    }

    private func beginNewSession() {
        sessionMaximumWidth = 0
        userMovedOrigin = nil
    }

    private func cancelTimers() {
        toastDismissWorkItem?.cancel()
        toastDismissWorkItem = nil
        copyFeedbackWorkItem?.cancel()
        copyFeedbackWorkItem = nil
        failureDismissWorkItem?.cancel()
        failureDismissWorkItem = nil
        hintOverrideWorkItem?.cancel()
        hintOverrideWorkItem = nil
        hintOverride = nil
    }

    private func startRecordingTimer(startedAt: Date) {
        if recordingStartedAt == nil {
            recordingStartedAt = startedAt
        }
        updateTimerLabel()
        guard recordingTimer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + 1,
            repeating: 1,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.updateTimerLabel()
            }
        }
        recordingTimer = timer
        timer.resume()
    }

    private func stopRecordingTimer() {
        recordingTimer?.cancel()
        recordingTimer = nil
        recordingStartedAt = nil
        timerLabel.stringValue = ""
        timerLabel.isHidden = true
        timerPillView.isHidden = true
    }

    private func updateTimerLabel() {
        guard let startedAt = recordingStartedAt else {
            timerLabel.isHidden = true
            timerPillView.isHidden = true
            return
        }
        timerLabel.stringValue = VoicePanelFormatting.recordingTimer(
            seconds: VoicePanelFormatting.elapsedSeconds(since: startedAt)
        )
        timerLabel.isHidden = false
        timerPillView.isHidden = false
        layoutAndResize(anchorRect: lastAnchorRect, scroll: .preserve)
    }

    private func setStatusBadge(_ text: String?, color: NSColor = .secondaryLabelColor) {
        if let text, !text.isEmpty {
            statusLabel.stringValue = text
            statusLabel.textColor = color
            statusLabel.isHidden = false
            statusLabel.setAccessibilityLabel(text)
        } else {
            statusLabel.stringValue = ""
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.isHidden = true
            statusLabel.setAccessibilityLabel(nil)
        }
    }

    private func setPlaceholder(_ text: String) {
        setTranscript(
            attributed: makePlaceholderAttributedString(text),
            plainText: text,
            selectable: false
        )
        showsPlaceholderTranscript = true
    }

    private func setTranscript(
        attributed: NSAttributedString,
        plainText: String,
        selectable: Bool
    ) {
        transcriptLabel.attributedStringValue = attributed
        transcriptLabel.isSelectable = selectable
        transcriptLabel.setAccessibilityLabel(
            plainText.isEmpty ? nil : plainText
        )
        showsPlaceholderTranscript = false
    }

    private func configureActions(hint: String?, visible: Set<Action>) {
        for action in Action.allCases {
            button(for: action).isHidden = !visible.contains(action)
        }
        currentHint = hint
        hintOverride = nil
        actionHintLabel.stringValue = hint ?? ""
        actionHintLabel.isHidden = (hint ?? "").isEmpty
        actionHintLabel.setAccessibilityLabel(hint)
    }

    private func announce(_ message: String) {
        guard message != lastAnnouncement else {
            return
        }
        lastAnnouncement = message
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    // MARK: - Typography & Dynamic Sizing

    private func makeParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = Layout.lineSpacing
        return style
    }

    private func makePlaceholderAttributedString(
        _ text: String
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: Layout.fontSize,
                    weight: .regular
                ),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: makeParagraphStyle(),
            ]
        )
    }

    private func makeTranscriptAttributedString(
        stable: String,
        partial: String
    ) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: Layout.fontSize, weight: .regular)
        let style = makeParagraphStyle()
        let result = NSMutableAttributedString()
        if !stable.isEmpty {
            result.append(NSAttributedString(
                string: stable,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: style,
                ]
            ))
        }
        if !partial.isEmpty {
            result.append(NSAttributedString(
                string: partial,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: style,
                ]
            ))
        }
        return result
    }

    private func present(anchorRect: NSRect, scroll: ScrollPosition) {
        lastAnchorRect = anchorRect
        layoutAndResize(anchorRect: anchorRect, scroll: scroll)
        panel.orderFrontRegardless()
    }

    private func refreshDynamicColors() {
        let appearance = backgroundView.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        appearance.performAsCurrentDrawingAppearance {
            surfaceTintView.layer?.backgroundColor = (
                isDark
                    ? NSColor.white.withAlphaComponent(0.03)
                    : NSColor.white.withAlphaComponent(0.36)
            ).cgColor
            backgroundView.layer?.borderColor = (
                isDark
                    ? NSColor.white.withAlphaComponent(0.15)
                    : NSColor.black.withAlphaComponent(0.09)
            ).cgColor
            statusDotView.layer?.backgroundColor = currentDotStyle.color.cgColor
            dotHaloView.layer?.backgroundColor = currentDotStyle.color
                .withAlphaComponent(currentDotStyle == .listening ? 0.24 : 0.14)
                .cgColor
            timerPillView.layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(isDark ? 0.10 : 0.055)
                .cgColor
            let barColor = NSColor.systemRed.withAlphaComponent(
                isDark ? 0.80 : 0.68
            ).cgColor
            for bar in waveformBars {
                bar.layer?.backgroundColor = barColor
            }
        }
    }

    private static func centeredScaleTransform(
        scaleX: CGFloat,
        scaleY: CGFloat,
        size: CGSize
    ) -> CATransform3D {
        let cx = size.width / 2
        let cy = size.height / 2
        var transform = CATransform3DMakeTranslation(cx, cy, 0)
        transform = CATransform3DScale(transform, scaleX, scaleY, 1)
        transform = CATransform3DTranslate(transform, -cx, -cy, 0)
        return transform
    }

    private func startDotPulse() {
        if let dotLayer = statusDotView.layer,
           dotLayer.animation(forKey: "listeningPulse") == nil
        {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.45
            pulse.duration = 0.85
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dotLayer.add(pulse, forKey: "listeningPulse")
        }
        if let haloLayer = dotHaloView.layer,
           haloLayer.animation(forKey: "listeningHalo") == nil
        {
            let haloSize = CGSize(
                width: Layout.dotHaloSize,
                height: Layout.dotHaloSize
            )
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = NSValue(
                caTransform3D: Self.centeredScaleTransform(
                    scaleX: 0.72,
                    scaleY: 0.72,
                    size: haloSize
                )
            )
            scale.toValue = NSValue(
                caTransform3D: Self.centeredScaleTransform(
                    scaleX: 1.55,
                    scaleY: 1.55,
                    size: haloSize
                )
            )
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.65
            opacity.toValue = 0.0
            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            group.duration = 1.45
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            haloLayer.add(group, forKey: "listeningHalo")
        }
    }

    private func stopDotPulse() {
        statusDotView.layer?.removeAnimation(forKey: "listeningPulse")
        dotHaloView.layer?.removeAnimation(forKey: "listeningHalo")
    }

    private func startWaveformAnimation() {
        let durations: [CFTimeInterval] = [0.58, 0.46, 0.64]
        let minScales: [CGFloat] = [0.35, 0.40, 0.30]
        let offsets: [CFTimeInterval] = [0.0, 0.14, 0.28]
        for (index, bar) in waveformBars.enumerated() {
            guard let layer = bar.layer,
                  layer.animation(forKey: "waveBar") == nil
            else {
                continue
            }
            let size = bar.bounds.size
            let anim = CABasicAnimation(keyPath: "transform")
            anim.fromValue = NSValue(
                caTransform3D: Self.centeredScaleTransform(
                    scaleX: 1.0,
                    scaleY: minScales[index],
                    size: size
                )
            )
            anim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            anim.duration = durations[index]
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timeOffset = offsets[index]
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(anim, forKey: "waveBar")
        }
    }

    private func stopWaveformAnimation() {
        for bar in waveformBars {
            bar.layer?.removeAnimation(forKey: "waveBar")
        }
    }

    /// 状态指示：连接/识别/转换阶段显示旋转指示器，其余显示状态点与柔光环；
    /// 聆听中在状态点右侧展示精致的三柱微动声波。
    private func placeIndicator(
        centerY: CGFloat,
        visible: Bool,
        showsWaveform: Bool
    ) {
        let usesSpinner = visible && currentDotStyle.usesSpinner
        spinner.isHidden = !usesSpinner
        if usesSpinner {
            spinner.frame = NSRect(
                x: Layout.horizontalPadding,
                y: round(centerY - Layout.spinnerSize / 2),
                width: Layout.spinnerSize,
                height: Layout.spinnerSize
            )
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        let showsDot = visible && !usesSpinner
        statusDotView.isHidden = !showsDot
        dotHaloView.isHidden = !showsDot
        let indicatorCenterX = Layout.horizontalPadding + Layout.indicatorSize / 2
        if showsDot {
            statusDotView.layer?.backgroundColor = currentDotStyle.color.cgColor
            dotHaloView.frame = NSRect(
                x: round(indicatorCenterX - Layout.dotHaloSize / 2),
                y: round(centerY - Layout.dotHaloSize / 2),
                width: Layout.dotHaloSize,
                height: Layout.dotHaloSize
            )
            statusDotView.frame = NSRect(
                x: round(indicatorCenterX - Layout.dotSize / 2),
                y: round(centerY - Layout.dotSize / 2),
                width: Layout.dotSize,
                height: Layout.dotSize
            )
            if currentDotStyle == .listening {
                startDotPulse()
            } else {
                stopDotPulse()
            }
        } else {
            stopDotPulse()
        }

        waveformContainerView.isHidden = !showsWaveform
        if showsWaveform {
            let waveX = Layout.horizontalPadding + Layout.indicatorSize + Layout.dotTextSpacing
            let waveHeight: CGFloat = 14
            waveformContainerView.frame = NSRect(
                x: waveX,
                y: round(centerY - waveHeight / 2),
                width: Layout.waveformWidth,
                height: waveHeight
            )
            let barHeights: [CGFloat] = [8, 13, 9]
            let barWidth: CGFloat = 2.5
            let barGap: CGFloat = 3.5
            for (index, bar) in waveformBars.enumerated() {
                let h = barHeights[index]
                let x = CGFloat(index) * (barWidth + barGap)
                bar.frame = NSRect(
                    x: x,
                    y: round((waveHeight - h) / 2),
                    width: barWidth,
                    height: h
                )
            }
            startWaveformAnimation()
        } else {
            stopWaveformAnimation()
        }
    }

    /// 一次布局的全部度量：先量后排，度量与落位互不耦合。
    private struct LayoutMetrics {
        let showsIndicator: Bool
        let showsWaveform: Bool
        let showsStatus: Bool
        let showsTimer: Bool
        let hasHeaderRow: Bool
        let visibleButtons: [NSButton]
        let hint: String
        let showsButtons: Bool
        /// 提示与按钮同排（居左）。
        let hintBesideButtons: Bool
        /// 提示独占一行：有按钮时在分隔线上方，没有按钮时是页脚行。
        let showsHintRow: Bool
        let hintRowHeight: CGFloat
        /// 顶部状态栏中 statusLabel 的起始 X。
        let headerContentLeftX: CGFloat
        /// 正文滚动区起始 X：有顶部栏时与左侧对齐（消除多余缩进空洞），
        /// 无顶部栏（单行紧凑状态）时紧随指示器右侧。
        let transcriptLeftX: CGFloat
        let panelWidth: CGFloat
        let textWidth: CGFloat
        let fullTextHeight: CGFloat
        let visibleTextHeight: CGFloat
        let totalHeight: CGFloat
        let timerTextWidth: CGFloat
        let timerPillWidth: CGFloat
    }

    private func layoutAndResize(anchorRect: NSRect, scroll: ScrollPosition) {
        let metrics = measureLayout()
        let targetSize = NSSize(
            width: metrics.panelWidth,
            height: metrics.totalHeight
        )
        let origin = resolvedOrigin(
            for: targetSize,
            anchorRect: anchorRect
        )
        let preservedScrollY = transcriptScrollView.contentView.bounds.origin.y
        isPerformingProgrammaticLayout = true
        panel.setFrame(NSRect(origin: origin, size: targetSize), display: true)
        isPerformingProgrammaticLayout = false
        lastProgrammaticOrigin = origin
        backgroundView.frame = NSRect(origin: .zero, size: targetSize)
        surfaceTintView.frame = backgroundView.bounds
        refreshDynamicColors()

        let statusBottom = layoutStatusBar(metrics)
        layoutTranscript(
            metrics,
            topCursor: statusBottom,
            scroll: scroll,
            preservedScrollY: preservedScrollY
        )
        layoutActionBar(
            metrics,
            transcriptTop: statusBottom - metrics.visibleTextHeight
        )
    }

    /// 正文与状态行的固有宽度（未约束）。
    private struct ContentMeasure {
        let unconstrainedTextWidth: CGFloat
        let statusWidth: CGFloat
        let timerTextWidth: CGFloat
        let timerPillWidth: CGFloat
    }

    private func measureLayout() -> LayoutMetrics {
        let showsIndicator = currentDotStyle != .hidden
        let showsStatus = !statusLabel.isHidden
        let showsTimer = !timerLabel.isHidden
        let hasHeaderRow = showsStatus || showsTimer
        let showsWaveform = showsIndicator && currentDotStyle == .listening && hasHeaderRow
        let visibleButtons = orderedButtons.filter { !$0.isHidden }
        let showsButtons = !visibleButtons.isEmpty
        let hint = hintOverride ?? currentHint ?? ""
        let showsHint = !hint.isEmpty
        let buttonsWidth = minimumButtonsWidth(visibleButtons)
        let hintWidth = showsHint ? ceil(actionHintLabel.fittingSize.width) : 0
        // 提示与按钮同排放不下（会被挤成省略号）时，提示独占一行并自动换行。
        let hintBesideButtons = showsHint
            && showsButtons
            && buttonsWidth + hintWidth + Layout.hintButtonSpacing
                <= Layout.maxPanelWidth
        let showsHintRow = showsHint && !hintBesideButtons

        let headerContentLeftX = Layout.horizontalPadding
            + (showsIndicator ? Layout.indicatorSize + Layout.dotTextSpacing : 0)
            + (showsWaveform ? Layout.waveformWidth + Layout.waveformSpacing : 0)
        let transcriptLeftX = hasHeaderRow
            ? Layout.horizontalPadding
            : headerContentLeftX
        let content = measureContentWidths(showsStatus: showsStatus, showsTimer: showsTimer)
        let panelWidth = resolvedPanelWidth(
            headerContentLeftX: headerContentLeftX,
            transcriptLeftX: transcriptLeftX,
            content: content,
            buttonsWidth: buttonsWidth,
            hintBesideButtons: hintBesideButtons,
            hintWidth: hintWidth,
            showsHintRow: showsHintRow,
            showsConfirm: visibleButtons.contains(confirmButton)
        )

        let textWidth = max(
            40,
            panelWidth - transcriptLeftX - Layout.horizontalPadding
        )
        let textHeights = measureTextHeights(
            attributed: transcriptLabel.attributedStringValue,
            textWidth: textWidth
        )
        let hintRowHeight = showsHintRow
            ? measuredHintRowHeight(
                hint,
                width: panelWidth - Layout.horizontalPadding * 2
            )
            : 0
        var totalHeight = Layout.verticalPadding * 2 + textHeights.visible
        if hasHeaderRow {
            totalHeight += Layout.statusHeight + Layout.statusBottomSpacing
        }
        if showsButtons {
            totalHeight += Layout.actionBarTopSpacing
                + Layout.dividerHeight
                + Layout.actionBarInnerTopSpacing
                + Layout.actionBarHeight
        }
        if showsHintRow {
            // 与按钮共存时复用按钮区的分隔线；仅有提示时页脚行自带分隔线。
            totalHeight += showsButtons
                ? Layout.hintRowTopSpacing + hintRowHeight + Layout.hintRowInnerSpacing
                : Layout.hintRowTopSpacing
                    + Layout.dividerHeight
                    + Layout.hintRowInnerSpacing
                    + hintRowHeight
        }

        return LayoutMetrics(
            showsIndicator: showsIndicator,
            showsWaveform: showsWaveform,
            showsStatus: showsStatus,
            showsTimer: showsTimer,
            hasHeaderRow: hasHeaderRow,
            visibleButtons: visibleButtons,
            hint: hint,
            showsButtons: showsButtons,
            hintBesideButtons: hintBesideButtons,
            showsHintRow: showsHintRow,
            hintRowHeight: hintRowHeight,
            headerContentLeftX: headerContentLeftX,
            transcriptLeftX: transcriptLeftX,
            panelWidth: panelWidth,
            textWidth: textWidth,
            fullTextHeight: textHeights.full,
            visibleTextHeight: textHeights.visible,
            totalHeight: totalHeight,
            timerTextWidth: content.timerTextWidth,
            timerPillWidth: content.timerPillWidth
        )
    }

    private func measureContentWidths(
        showsStatus: Bool,
        showsTimer: Bool
    ) -> ContentMeasure {
        let unconstrained = transcriptLabel.attributedStringValue.boundingRect(
            with: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let timerTextWidth = showsTimer ? ceil(timerLabel.fittingSize.width) + 2 : 0
        let timerPillWidth = showsTimer
            ? timerTextWidth + Layout.timerPillHorizontalPadding * 2
            : 0
        return ContentMeasure(
            unconstrainedTextWidth: ceil(unconstrained.size.width) + 6,
            statusWidth: showsStatus ? ceil(statusLabel.fittingSize.width) : 0,
            timerTextWidth: timerTextWidth,
            timerPillWidth: timerPillWidth
        )
    }

    /// 同一次听写会话内宽度只增不减：ASR 片段反复修订时浮窗不再左右“呼吸”。
    private func resolvedPanelWidth(
        headerContentLeftX: CGFloat,
        transcriptLeftX: CGFloat,
        content: ContentMeasure,
        buttonsWidth: CGFloat,
        hintBesideButtons: Bool,
        hintWidth: CGFloat,
        showsHintRow: Bool,
        showsConfirm: Bool
    ) -> CGFloat {
        let headerDesiredWidth = headerContentLeftX
            + content.statusWidth
            + (content.timerPillWidth > 0 ? content.timerPillWidth + 12 : 0)
            + Layout.horizontalPadding
        let bodyDesiredWidth = transcriptLeftX
            + content.unconstrainedTextWidth
            + Layout.horizontalPadding
        let hintBesideWidth = hintBesideButtons
            ? hintWidth + Layout.hintButtonSpacing
            : 0
        let hintRowWidth = showsHintRow
            ? hintWidth + Layout.horizontalPadding * 2
            : 0
        let panelWidth = min(
            Layout.maxPanelWidth,
            max(
                effectiveMinimumPanelWidth(
                    showsButtons: buttonsWidth > 0,
                    showsConfirm: showsConfirm
                ),
                buttonsWidth + hintBesideWidth,
                hintRowWidth,
                headerDesiredWidth,
                bodyDesiredWidth
            )
        )
        let sessionWidth = max(panelWidth, min(sessionMaximumWidth, Layout.maxPanelWidth))
        sessionMaximumWidth = sessionWidth
        return sessionWidth
    }

    private func measureTextHeights(
        attributed: NSAttributedString,
        textWidth: CGFloat
    ) -> (full: CGFloat, visible: CGFloat) {
        let wrappedRect = attributed.boundingRect(
            with: NSSize(
                width: textWidth,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let full = max(Layout.minLineHeight, ceil(wrappedRect.height) + 4)
        return (full, min(full, Layout.maxTextScrollHeight))
    }

    /// 换行后的提示行高度（按单词换行，绝不截断）。
    private func measuredHintRowHeight(_ hint: String, width: CGFloat) -> CGFloat {
        let attributed = NSAttributedString(
            string: hint,
            attributes: [.font: actionHintLabel.font ?? NSFont.systemFont(ofSize: 11.5)]
        )
        let rect = attributed.boundingRect(
            with: NSSize(width: max(40, width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(Layout.hintRowHeight, ceil(rect.height))
    }

    private func effectiveMinimumPanelWidth(
        showsButtons: Bool,
        showsConfirm: Bool
    ) -> CGFloat {
        if showsConfirm {
            return Layout.minConfirmPanelWidth
        }
        return showsButtons ? Layout.minActionPanelWidth : Layout.minPanelWidth
    }

    /// 状态行（指示器 / 微动声波 / 徽标 / 胶囊计时）。返回状态行下方的内容起点；
    /// AppKit 原点在左下角，自顶向下排布。
    private func layoutStatusBar(_ metrics: LayoutMetrics) -> CGFloat {
        let topCursor = metrics.totalHeight - Layout.verticalPadding
        guard metrics.hasHeaderRow else {
            timerPillView.isHidden = true
            // 只有指示器：对齐正文首行，不额外占用一行高度。
            placeIndicator(
                centerY: topCursor - Layout.minLineHeight / 2,
                visible: metrics.showsIndicator,
                showsWaveform: false
            )
            return topCursor
        }
        let statusY = topCursor - Layout.statusHeight
        let timerPillX = metrics.panelWidth - Layout.horizontalPadding - metrics.timerPillWidth
        let statusMaxRight = metrics.showsTimer
            ? timerPillX - 10
            : metrics.panelWidth - Layout.horizontalPadding
        statusLabel.frame = NSRect(
            x: metrics.headerContentLeftX,
            y: statusY + 2,
            width: metrics.showsStatus
                ? max(0, statusMaxRight - metrics.headerContentLeftX)
                : 0,
            height: 16
        )
        timerPillView.isHidden = !metrics.showsTimer
        if metrics.showsTimer {
            timerPillView.frame = NSRect(
                x: timerPillX,
                y: statusY,
                width: metrics.timerPillWidth,
                height: Layout.timerPillHeight
            )
            timerLabel.frame = NSRect(
                x: Layout.timerPillHorizontalPadding,
                y: 2,
                width: metrics.timerTextWidth,
                height: 15
            )
        }
        placeIndicator(
            centerY: statusY + Layout.statusHeight / 2,
            visible: metrics.showsIndicator,
            showsWaveform: metrics.showsWaveform
        )
        return statusY - Layout.statusBottomSpacing
    }

    private func layoutTranscript(
        _ metrics: LayoutMetrics,
        topCursor: CGFloat,
        scroll: ScrollPosition,
        preservedScrollY: CGFloat
    ) {
        let scrollY = topCursor - metrics.visibleTextHeight
        transcriptScrollView.frame = NSRect(
            x: metrics.transcriptLeftX,
            y: scrollY,
            width: metrics.textWidth,
            height: metrics.visibleTextHeight
        )
        transcriptDocumentView.frame = NSRect(
            x: 0,
            y: 0,
            width: metrics.textWidth,
            height: metrics.fullTextHeight
        )
        transcriptLabel.preferredMaxLayoutWidth = metrics.textWidth
        transcriptLabel.frame = NSRect(
            x: 0,
            y: 0,
            width: metrics.textWidth,
            height: metrics.fullTextHeight
        )
        let maximumScrollY = max(
            0,
            metrics.fullTextHeight - metrics.visibleTextHeight
        )
        let targetScrollY: CGFloat
        switch scroll {
        case .bottom:
            targetScrollY = maximumScrollY
        case .top:
            targetScrollY = 0
        case .preserve:
            targetScrollY = min(max(0, preservedScrollY), maximumScrollY)
        }
        transcriptScrollView.contentView.scroll(
            to: NSPoint(x: 0, y: targetScrollY)
        )
        transcriptScrollView.reflectScrolledClipView(
            transcriptScrollView.contentView
        )
    }

    /// 页脚：提示与按钮同排放得下时居左同排；放不下时提示独占一行、位于
    /// 分隔线上方并自动换行；没有按钮时整行只有提示。
    private func layoutActionBar(
        _ metrics: LayoutMetrics,
        transcriptTop: CGFloat
    ) {
        let showsActionBar = metrics.showsButtons || metrics.showsHintRow
        actionDivider.isHidden = !showsActionBar
        guard showsActionBar else {
            actionHintLabel.isHidden = true
            return
        }
        var hintBottom = transcriptTop
        if metrics.showsHintRow, metrics.showsButtons {
            hintBottom = transcriptTop
                - Layout.hintRowTopSpacing
                - metrics.hintRowHeight
            placeHintRow(metrics, bottomY: hintBottom)
        }
        let dividerTopSpacing = metrics.showsButtons
            ? Layout.hintRowInnerSpacing
                + Layout.actionBarTopSpacing
                + (metrics.showsHintRow ? 0 : -Layout.hintRowInnerSpacing)
            : Layout.hintRowTopSpacing
        let dividerY = hintBottom - dividerTopSpacing - Layout.dividerHeight
        actionDivider.frame = NSRect(
            x: Layout.horizontalPadding,
            y: dividerY,
            width: metrics.panelWidth - Layout.horizontalPadding * 2,
            height: Layout.dividerHeight
        )
        if metrics.showsButtons {
            layoutButtons(metrics)
        } else {
            placeHintRow(metrics, bottomY: Layout.verticalPadding - 3)
        }
    }

    private func placeHintRow(_ metrics: LayoutMetrics, bottomY: CGFloat) {
        actionHintLabel.lineBreakMode = .byWordWrapping
        actionHintLabel.maximumNumberOfLines = 0
        actionHintLabel.frame = NSRect(
            x: Layout.horizontalPadding,
            y: bottomY,
            width: metrics.panelWidth - Layout.horizontalPadding * 2,
            height: metrics.hintRowHeight
        )
        actionHintLabel.isHidden = false
    }

    /// 从右向左落位，最终视觉次序与 orderedButtons 一致（主操作最右）。
    private func layoutButtons(_ metrics: LayoutMetrics) {
        let buttonY = Layout.verticalPadding - 2
        var rightX = metrics.panelWidth - Layout.horizontalPadding
        for button in metrics.visibleButtons.reversed() {
            button.sizeToFit()
            let width = max(
                Layout.minButtonWidth,
                ceil(button.frame.width) + 6
            )
            rightX -= width
            button.frame = NSRect(
                x: rightX,
                y: buttonY,
                width: width,
                height: Layout.actionBarHeight
            )
            rightX -= Layout.buttonSpacing
        }
        guard metrics.hintBesideButtons else {
            // 提示已作为独立行排布（或根本没有提示），这里不再占用按钮左侧。
            if !metrics.showsHintRow {
                actionHintLabel.isHidden = true
            }
            return
        }
        actionHintLabel.lineBreakMode = .byTruncatingTail
        actionHintLabel.maximumNumberOfLines = 1
        let hintWidth = max(0, rightX - Layout.horizontalPadding - 4)
        actionHintLabel.frame = NSRect(
            x: Layout.horizontalPadding,
            y: buttonY + 5,
            width: hintWidth,
            height: 15
        )
        actionHintLabel.isHidden = hintWidth < Layout.minHintWidth
    }
    private func minimumButtonsWidth(_ buttons: [NSButton]) -> CGFloat {
        guard !buttons.isEmpty else {
            return 0
        }
        let total = buttons.reduce(CGFloat(0)) { partial, button in
            let fitting = button.intrinsicContentSize.width
            return partial + max(Layout.minButtonWidth, ceil(fitting) + 6)
        }
        return total
            + Layout.buttonSpacing * CGFloat(buttons.count - 1)
            + Layout.horizontalPadding * 2
    }

    private func resolvedOrigin(
        for size: NSSize,
        anchorRect: NSRect
    ) -> NSPoint {
        if preserveCurrentOriginOnNextLayout, panel.isVisible {
            return panel.frame.origin
        }
        let screen = NSScreen.screens.first {
            $0.frame.contains(
                NSPoint(x: anchorRect.midX, y: anchorRect.midY)
            )
        } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_920, height: 1_080)
        if let userMovedOrigin {
            // 记住用户拖动后的位置，仅夹取到当前屏幕可见范围内。
            return NSPoint(
                x: min(
                    max(userMovedOrigin.x, visibleFrame.minX + 8),
                    visibleFrame.maxX - size.width - 8
                ),
                y: min(
                    max(userMovedOrigin.y, visibleFrame.minY + 8),
                    visibleFrame.maxY - size.height - 8
                )
            )
        }
        var x = anchorRect.minX
        var y = anchorRect.minY - size.height - 6
        if y < visibleFrame.minY + 8 {
            y = anchorRect.maxY + 6
        }
        x = min(
            max(x, visibleFrame.minX + 8),
            visibleFrame.maxX - size.width - 8
        )
        y = min(
            max(y, visibleFrame.minY + 8),
            visibleFrame.maxY - size.height - 8
        )
        return NSPoint(x: x, y: y)
    }

    private func handlePanelDidMove() {
        guard !isPerformingProgrammaticLayout, panel.isVisible else {
            return
        }
        if panel.frame.origin != lastProgrammaticOrigin {
            userMovedOrigin = panel.frame.origin
        }
    }

#if DEBUG
    struct TestingSnapshot: Equatable {
        let status: String
        let transcript: String
        let accessibilityLabel: String?
        let confirmIsHidden: Bool
        let copyIsHidden: Bool
        let cancelIsHidden: Bool
        let hasConfirmHandler: Bool
        let hasCopyHandler: Bool
        let hasCancelHandler: Bool
        let panelSize: NSSize
        let isPersistentCopy: Bool
        let recordingTimer: String?
        let showsSpinner: Bool
        let dotIsVisible: Bool
        let hint: String
        let retryIsHidden: Bool
        let settingsIsHidden: Bool
        let accessibilityIsHidden: Bool
        /// 从左到右的可见按钮标题，用于断言 HIG 次序。
        let visibleButtonTitlesLeftToRight: [String]
        /// 可见按钮的 frame，用于断言实际落位次序。
        let buttonFrames: [String: NSRect]
        let confirmIsPrimary: Bool
        let persistentCopyReason: VoicePersistentCopyReason?
    }

    /// 测试专用：向面板发送一次按键等效事件（空格 49 / 回车 36 /
    /// ⌘C keyCode 8 + .command / Esc 53）。返回面板是否消费了该按键。
    func simulateKeyEquivalent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return false
        }
        return panel.performKeyEquivalent(with: event)
    }

    /// App target 测试专用：不展示窗口，只构造 hide 必须彻底擦除的状态。
    func populateForHideTesting() {
        statusLabel.stringValue = "测试状态"
        statusLabel.isHidden = false
        transcriptLabel.stringValue = "不得残留的听写正文"
        transcriptLabel.setAccessibilityLabel("不得残留的听写正文")
        persistentCopyText = "不得残留的听写正文"
        confirmButton.isHidden = false
        copyButton.isHidden = false
        cancelButton.isHidden = false
        retryButton.isHidden = false
        confirmHandler = {}
        copyHandler = {}
        cancelHandler = {}
    }

    var testingSnapshot: TestingSnapshot {
        TestingSnapshot(
            status: statusLabel.stringValue,
            transcript: transcriptLabel.stringValue,
            accessibilityLabel: transcriptLabel.accessibilityLabel(),
            confirmIsHidden: confirmButton.isHidden,
            copyIsHidden: copyButton.isHidden,
            cancelIsHidden: cancelButton.isHidden,
            hasConfirmHandler: confirmHandler != nil,
            hasCopyHandler: copyHandler != nil,
            hasCancelHandler: cancelHandler != nil,
            panelSize: panel.frame.size,
            isPersistentCopy: persistentCopyText != nil,
            recordingTimer: timerLabel.isHidden ? nil : timerLabel.stringValue,
            showsSpinner: !spinner.isHidden,
            dotIsVisible: !statusDotView.isHidden,
            hint: actionHintLabel.isHidden ? "" : actionHintLabel.stringValue,
            retryIsHidden: retryButton.isHidden,
            settingsIsHidden: settingsButton.isHidden,
            accessibilityIsHidden: accessibilityButton.isHidden,
            visibleButtonTitlesLeftToRight: orderedButtons
                .filter { !$0.isHidden }
                .map(\.title),
            buttonFrames: Dictionary(uniqueKeysWithValues: orderedButtons
                .filter { !$0.isHidden }
                .map { ($0.title, $0.frame) }),
            confirmIsPrimary: confirmButton.bezelColor == .controlAccentColor,
            persistentCopyReason: persistentCopyText == nil
                ? nil
                : persistentCopyReason
        )
    }
#endif

    @objc private func confirm(_ sender: NSButton) {
        confirmHandler?()
    }

    @objc private func copyTranscript(_ sender: NSButton) {
        copyHandler?()
    }

    @objc private func cancel(_ sender: NSButton) {
        cancelHandler?()
    }

    @objc private func retry(_ sender: NSButton) {
        retryHandler?()
    }

    @objc private func openSystemSettings(_ sender: NSButton) {
        guard let failureSettingsPane else {
            return
        }
        VoiceSystemSettingsOpener.open(failureSettingsPane)
    }

    @objc private func requestAccessibility(_ sender: NSButton) {
        VoiceAccessibilityAuthorization.requestPrompt()
    }
}
