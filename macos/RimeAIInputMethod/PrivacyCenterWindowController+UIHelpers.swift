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

    func addSettingsTab(
        to tabView: NSTabView,
        title: String
    ) -> NSStackView {
        let item = NSTabViewItem(identifier: title)
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
}
