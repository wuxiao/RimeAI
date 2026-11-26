import AppKit

/// 机械拆分自 PrivacyCenterWindowController.swift（纯代码搬移，行为不变）。
extension PrivacyCenterWindowController {
    func presentError(
        _ error: Error,
        message: String,
        information: String
    ) {
        updateSettingsActionStatus(
            .failure,
            "\(message)：\(error.localizedDescription)"
        )
        let alert = NSAlert(error: error)
        alert.messageText = message
        alert.informativeText = information
        alert.beginSheetModal(for: window)
    }

    func sectionTitle(_ value: String) -> NSTextField {
        label(value, font: .systemFont(ofSize: 15, weight: .semibold))
    }

    func label(
        _ value: String,
        font: NSFont = .systemFont(ofSize: 13),
        secondary: Bool = false
    ) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = font
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        configureWrapping(field)
        return field
    }

    func configureWrapping(_ field: NSTextField) {
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
    }

    /// 标签页使用稳定 identifier：标题可随文案调整而改名，跳转与断言不受影响。
    func addSettingsTab(
        to tabView: NSTabView,
        identifier: String,
        title: String
    ) -> NSStackView {
        let item = NSTabViewItem(identifier: identifier)
        item.label = title

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.setAccessibilityLabel("\(title)设置")

        let documentView = SettingsDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        documentView.widthAnchor.constraint(
            equalTo: scrollView.contentView.widthAnchor
        ).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: documentView.leadingAnchor,
                constant: 20
            ),
            stack.trailingAnchor.constraint(
                equalTo: documentView.trailingAnchor,
                constant: -20
            ),
            stack.topAnchor.constraint(
                equalTo: documentView.topAnchor,
                constant: 20
            ),
            stack.bottomAnchor.constraint(
                equalTo: documentView.bottomAnchor,
                constant: -24
            ),
        ])

        item.view = scrollView
        tabView.addTabViewItem(item)
        return stack
    }

    func addSeparator(to stack: NSStackView) {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    // MARK: - 分组卡片与对齐行

    /// 设置页分组卡片（NSBox 容器 + 垂直内容栈）。同一张卡片内的行共用
    /// `SettingsLayout.labelColumnWidth`，弹窗与按钮不再参差不齐。
    func settingsCard(_ title: String, subtitle: String? = nil) -> SettingsCard {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = NSSize(width: 14, height: 12)
        box.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(sectionTitle(title))
        if let subtitle {
            content.addArrangedSubview(label(subtitle, secondary: true))
        }
        box.contentView?.addSubview(content)
        if let boxContent = box.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(
                    equalTo: boxContent.leadingAnchor
                ),
                content.trailingAnchor.constraint(
                    equalTo: boxContent.trailingAnchor
                ),
                content.topAnchor.constraint(equalTo: boxContent.topAnchor),
                content.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor),
            ])
        }
        return SettingsCard(box: box, content: content)
    }

    /// 把卡片加入页面栈并让卡片横向填满。
    func addCard(_ card: SettingsCard, to stack: NSStackView) {
        stack.addArrangedSubview(card.box)
        card.box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// “标签 | 控件…”行：标签列固定宽度，保证上下各行控件左对齐。
    func labeledRow(
        _ title: String,
        labelWidth: CGFloat = SettingsLayout.labelColumnWidth,
        _ controls: [NSView]
    ) -> NSStackView {
        let row = NSStackView(views: [label(title)] + controls)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.arrangedSubviews.first?.widthAnchor.constraint(
            equalToConstant: labelWidth
        ).isActive = true
        return row
    }

    /// 宽度固定的弹窗：与相邻行的控件列对齐。
    func fixedWidthPopup(_ popup: NSPopUpButton, width: CGFloat) {
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    /// 把可换行的控件加入垂直栈并绑定到栈宽度，否则会按单行固有宽度排布。
    func addFilling(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// 状态圆点（图层着色，外观切换时重新解析动态颜色）。
    func makeStatusDot(identifier: String) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        dot.identifier = NSUserInterfaceItemIdentifier(identifier)
        dot.setAccessibilityLabel("语音服务状态")
        return dot
    }

    func setStatusDot(_ dot: NSView, color: NSColor, label: String) {
        dot.layer?.backgroundColor = color.cgColor
        dot.setAccessibilityValue(label)
    }
}

/// 设置页排版常量。
enum SettingsLayout {
    /// 所有“标签 | 控件”行的标签列宽度。
    static let labelColumnWidth: CGFloat = 136
    /// 弹窗类控件的统一宽度。
    static let popupWidth: CGFloat = 224
    /// 热词编辑器高度：可同时看到约 7 行。
    static let hotwordEditorHeight: CGFloat = 152
    /// 语音历史表格的高度区间：空间充足时填满页面，不足时保底并由外层滚动。
    static let historyTableMinimumHeight: CGFloat = 240
    static let historyTableMaximumHeight: CGFloat = 1_200
    /// 顶部状态条自动收起时限：成功提示短、失败提示略长。
    static let actionBannerSuccessDismissSeconds: TimeInterval = 6
    static let actionBannerFailureDismissSeconds: TimeInterval = 10
}

struct SettingsCard {
    let box: NSBox
    let content: NSStackView
}

/// 语音相关的用户可见文案（集中管理，便于核对隐私表述与单测）。
enum VoicePrivacyCopy {
    /// 听写说明：只陈述可验证的事实，不宣称输入法侧无法确认的推理引擎。
    static func dictationInstruction(shortcutName: String, isModifierTap: Bool) -> String {
        let trigger = isModifierTap
            ? "按一下 \(shortcutName) 启动录音，再按一下结束并等待最终文本；"
            : "按住 \(shortcutName) 录音，松开后等待最终文本；"
        return trigger
            + "Space 或回车确认上屏，Esc 取消。音频只在独立的本地 helper "
            + "进程内存中离线识别，不写入录音；识别文本默认保存在本机语音历史"
            + "（可关闭或清空），麦克风权限由 RimeAI Voice Helper 持有。"
    }

    /// 支持同时绑定主/备用两个语音快捷键时的说明文案。
    static func dictationInstruction(
        shortcuts: [VoiceDictationShortcut]
    ) -> String {
        guard !shortcuts.isEmpty else {
            return dictationInstruction(
                shortcutName: VoiceDictationShortcut.default.displayName,
                isModifierTap: VoiceDictationShortcut.default.isModifierTap
            )
        }
        if shortcuts.count == 1, let only = shortcuts.first {
            return dictationInstruction(
                shortcutName: only.displayName,
                isModifierTap: only.isModifierTap
            )
        }
        let tapShortcuts = shortcuts.filter(\.isModifierTap)
        let holdShortcuts = shortcuts.filter { !$0.isModifierTap }
        let trigger: String
        if holdShortcuts.isEmpty {
            let names = tapShortcuts.map(\.displayName).joined(separator: " 或 ")
            trigger = "按一下 \(names) 启动录音，再按一下结束并等待最终文本；"
        } else if tapShortcuts.isEmpty {
            let names = holdShortcuts.map(\.displayName).joined(separator: " 或 ")
            trigger = "按住 \(names) 录音，松开后等待最终文本；"
        } else {
            let tapNames = tapShortcuts.map(\.displayName).joined(separator: " / ")
            let holdNames = holdShortcuts.map(\.displayName).joined(separator: " / ")
            trigger = "按一下 \(tapNames) 启动/结束录音，或按住 \(holdNames) 录音松开后等待最终文本；"
        }
        return trigger
            + "Space 或回车确认上屏，Esc 取消。音频只在独立的本地 helper "
            + "进程内存中离线识别，不写入录音；识别文本默认保存在本机语音历史"
            + "（可关闭或清空），麦克风权限由 RimeAI Voice Helper 持有。"
    }

    static func voiceToggleTitle(
        shortcuts: [VoiceDictationShortcut]
    ) -> String {
        let effective = shortcuts.isEmpty ? [VoiceDictationShortcut.default] : shortcuts
        let summary = VoiceDictationShortcut.displaySummary(effective)
        if effective.allSatisfy(\.isModifierTap) {
            return "启用语音输入（按一下 \(summary) 启动/结束）"
        }
        if effective.allSatisfy({ !$0.isModifierTap }) {
            return "启用按住说话（\(summary)）"
        }
        return "启用语音输入（\(summary)）"
    }

    static let voiceDisabledBanner = "语音输入未启用：启用后以下选项才会生效。"
    static let historyCheckbox =
        "在本机保存语音听写与翻译历史（本地数据库，默认开启，不上传；可在「语音历史」页检索、复制或清空）"
    static let cloudPolishNote =
        "已配置云增强时，听写文本会发送到你配置的云端模型进行润色或翻译；"
        + "未配置、离线或超时时自动使用本地瞬时润色，绝不丢字。"
    static let cloudHotwordsCheckbox = "允许向云端润色/翻译发送热词上下文"
    static let cloudHotwordsNote =
        "默认关闭。热词（自定义常用语、当前会话确认的词条与个人短语库常用语）"
        + "默认只在本机用于识别偏置；开启后才会随润色/翻译请求发送到云端模型。"
    static let axFallbackReadCheckbox =
        "允许通过辅助功能读取光标周边文本以增强自动纠错"
    static let axFallbackReadNote =
        "默认关闭。仅在宿主应用不支持输入法回读时，通过辅助功能读取光标前后"
        + "少量文本用于学习纠错；需要先在系统设置中授予“辅助功能”权限，"
        + "安全输入与密码框下永不读取。"
    static let phraseBookHotwordsCheckbox =
        "自动融合个人短语库与领域词库中的常用语作为热词"
}
