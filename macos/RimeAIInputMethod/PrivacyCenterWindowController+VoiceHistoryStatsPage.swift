import AppKit
import UniformTypeIdentifiers

/// 语音历史与使用统计页：数据看板（2×2 自适应统计卡片 + 近 7 日柱状图）
/// 与历史记录表。全部数据保存在本机数据库，不上传；所有查询都在后台线程
/// 完成，并按代次回填。
extension PrivacyCenterWindowController {
    func buildVoiceHistoryStatsPage(_ stack: NSStackView) {
        buildVoiceUsageStatsSection(stack)
        addSeparator(to: stack)
        buildVoiceHistoryListSection(stack)
        observeVoiceHistoryPageLayout()
    }

    // MARK: - 使用统计

    private func buildVoiceUsageStatsSection(_ stack: NSStackView) {
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.addArrangedSubview(sectionTitle("语音使用情况统计"))
        // 历史与统计在数据变化时自动刷新，不再保留手工“刷新”按钮。
        headerRow.addArrangedSubview(
            NSButton(
                title: "重置统计…",
                target: self,
                action: #selector(resetVoiceUsageStats(_:))
            )
        )
        stack.addArrangedSubview(headerRow)

        // 2×2 栅格：每张卡片比一行四列宽一倍，长时长不会被截断。
        addStatCardRow(
            [
                StatCardSpec(title: "累计输出字数", valueLabel: voiceStatCharsValueLabel),
                StatCardSpec(title: "累计语音次数", valueLabel: voiceStatSessionsValueLabel),
            ],
            to: stack
        )
        addStatCardRow(
            [
                StatCardSpec(title: "累计说话时长", valueLabel: voiceStatDurationValueLabel),
                StatCardSpec(title: "估算节省时间", valueLabel: voiceStatSavedTimeValueLabel),
            ],
            to: stack
        )

        addFilling(voiceWeeklyChartView, to: stack)
        voiceWeeklyChartView.heightAnchor.constraint(
            equalToConstant: VoiceUsageBarChartView.preferredHeight
        ).isActive = true
        voiceWeeklyChartView.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-weekly-chart"
        )

        configureWrapping(voiceStatsDetailLabel)
        voiceStatsDetailLabel.font = .systemFont(ofSize: 12)
        voiceStatsDetailLabel.textColor = .secondaryLabelColor
        voiceStatsDetailLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-stats-detail"
        )
        addFilling(voiceStatsDetailLabel, to: stack)

        configureWrapping(voiceStatsTopAppsLabel)
        voiceStatsTopAppsLabel.font = .systemFont(ofSize: 12)
        voiceStatsTopAppsLabel.textColor = .secondaryLabelColor
        voiceStatsTopAppsLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-stats-top-apps"
        )
        addFilling(voiceStatsTopAppsLabel, to: stack)
    }

    private func addStatCardRow(
        _ cards: [StatCardSpec],
        to stack: NSStackView
    ) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        for card in cards {
            row.addArrangedSubview(
                makeStatCard(title: card.title, valueLabel: card.valueLabel)
            )
        }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private struct StatCardSpec {
        let title: String
        let valueLabel: NSTextField
    }

    private func makeStatCard(
        title: String,
        valueLabel: NSTextField
    ) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = NSSize(width: 10, height: 8)
        box.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 11, weight: .medium)
        titleField.textColor = .secondaryLabelColor

        // 数值允许换行而不是截断：配合按长度缩放的字号，长时长始终完整可见。
        configureWrapping(valueLabel)
        valueLabel.maximumNumberOfLines = 2
        valueLabel.textColor = .labelColor
        applyStatValueFont(valueLabel)

        let cardStack = NSStackView(views: [titleField, valueLabel])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 4
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(cardStack)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                cardStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                cardStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                cardStack.topAnchor.constraint(equalTo: content.topAnchor),
                cardStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        return box
    }

    /// 统计卡片数值字号随内容长度收缩，长时长绝不截断。
    func applyStatValueFont(_ label: NSTextField) {
        label.font = .monospacedDigitSystemFont(
            ofSize: VoiceStatsFormatting.valueFontSize(textLength: label.stringValue.count),
            weight: .semibold
        )
    }

    // MARK: - 历史记录

    private func buildVoiceHistoryListSection(_ stack: NSStackView) {
        stack.addArrangedSubview(sectionTitle("语音历史记录"))
        voiceStackStatusHint(stack)

        let filterRow = NSStackView()
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = 8
        filterRow.translatesAutoresizingMaskIntoConstraints = false

        voiceHistorySearchField.placeholderString = "搜索听写/润色/翻译记录或应用标识…"
        voiceHistorySearchField.target = self
        voiceHistorySearchField.action = #selector(voiceHistoryFilterChanged(_:))
        voiceHistorySearchField.sendsSearchStringImmediately = true
        voiceHistorySearchField.translatesAutoresizingMaskIntoConstraints = false
        voiceHistorySearchField.widthAnchor
            .constraint(greaterThanOrEqualToConstant: 280).isActive = true
        voiceHistorySearchField.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-history.search"
        )
        filterRow.addArrangedSubview(voiceHistorySearchField)

        voiceHistoryFilterPopup.removeAllItems()
        voiceHistoryFilterPopup.addItems(withTitles: [
            "全部类型",
            VoicePostProcessAction.dictation.displayName,
            VoicePostProcessAction.polish.displayName,
            VoicePostProcessAction.translate.displayName,
        ])
        voiceHistoryFilterPopup.target = self
        voiceHistoryFilterPopup.action = #selector(voiceHistoryFilterChanged(_:))
        voiceHistoryFilterPopup.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-history.filter"
        )
        filterRow.addArrangedSubview(voiceHistoryFilterPopup)
        stack.addArrangedSubview(filterRow)
        filterRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        configureVoiceHistoryTableView()
        voiceHistoryScrollView.documentView = voiceHistoryTableView
        voiceHistoryScrollView.hasVerticalScroller = true
        voiceHistoryScrollView.borderType = .bezelBorder
        voiceHistoryScrollView.translatesAutoresizingMaskIntoConstraints = false
        voiceHistoryScrollView.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-history.table"
        )
        addFilling(voiceHistoryScrollView, to: stack)
        // 表格高度随页面剩余空间伸缩（最小 240pt），不再固定为嵌套的小滚动区。
        let heightConstraint = voiceHistoryScrollView.heightAnchor.constraint(
            equalToConstant: SettingsLayout.historyTableMinimumHeight
        )
        heightConstraint.isActive = true
        voiceHistoryTableHeightConstraint = heightConstraint
        installVoiceHistoryEmptyState()

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        for button in [voiceHistoryCopyFinalButton, voiceHistoryCopyRawButton, voiceHistoryDeleteButton] {
            button.target = self
            actionRow.addArrangedSubview(button)
        }
        voiceHistoryCopyFinalButton.action = #selector(copySelectedVoiceHistoryFinal(_:))
        voiceHistoryCopyRawButton.action = #selector(copySelectedVoiceHistoryRaw(_:))
        voiceHistoryDeleteButton.action = #selector(deleteSelectedVoiceHistory(_:))
        let exportButton = NSButton(
            title: "导出历史…",
            target: self,
            action: #selector(exportVoiceHistory(_:))
        )
        let clearButton = NSButton(
            title: "清空历史…",
            target: self,
            action: #selector(clearVoiceHistory(_:))
        )
        actionRow.setCustomSpacing(16, after: voiceHistoryDeleteButton)
        actionRow.addArrangedSubview(exportButton)
        actionRow.addArrangedSubview(clearButton)
        stack.addArrangedSubview(actionRow)
        updateVoiceHistorySelectionDependentControls()
    }

    private func voiceStackStatusHint(_ stack: NSStackView) {
        configureWrapping(voiceHistoryStatusLabel)
        voiceHistoryStatusLabel.font = .systemFont(ofSize: 12)
        voiceHistoryStatusLabel.textColor = .secondaryLabelColor
        voiceHistoryStatusLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-history.status"
        )
        stack.addArrangedSubview(voiceHistoryStatusLabel)
    }

    /// 空状态：表格没有记录时给出引导，而不是一片空白。
    private func installVoiceHistoryEmptyState() {
        voiceHistoryEmptyStateLabel.stringValue =
            "暂无语音历史记录\n开始一次语音听写后，识别结果会出现在这里。"
        voiceHistoryEmptyStateLabel.alignment = .center
        voiceHistoryEmptyStateLabel.textColor = .secondaryLabelColor
        voiceHistoryEmptyStateLabel.font = .systemFont(ofSize: 13)
        voiceHistoryEmptyStateLabel.lineBreakMode = .byWordWrapping
        voiceHistoryEmptyStateLabel.maximumNumberOfLines = 0
        voiceHistoryEmptyStateLabel.isSelectable = false
        voiceHistoryEmptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        voiceHistoryEmptyStateLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.voice-history.empty-state"
        )
        voiceHistoryScrollView.addSubview(voiceHistoryEmptyStateLabel)
        let clipView = voiceHistoryScrollView.contentView
        NSLayoutConstraint.activate([
            voiceHistoryEmptyStateLabel.centerXAnchor.constraint(
                equalTo: clipView.centerXAnchor
            ),
            voiceHistoryEmptyStateLabel.centerYAnchor.constraint(
                equalTo: clipView.centerYAnchor
            ),
            voiceHistoryEmptyStateLabel.widthAnchor.constraint(
                lessThanOrEqualTo: clipView.widthAnchor,
                constant: -24
            ),
        ])
        voiceHistoryEmptyStateLabel.isHidden = true
    }

    /// 列宽：只有“内容”列可自动伸缩。窗口变宽时多余宽度全部给内容列，
    /// 其余列保持稳定；窄窗口下内容列最低 180pt。
    private func configureVoiceHistoryTableView() {
        for column in voiceHistoryTableView.tableColumns {
            voiceHistoryTableView.removeTableColumn(column)
        }
        voiceHistoryTableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        struct ColumnSpec {
            let id: String
            let title: String
            let width: CGFloat
            let minWidth: CGFloat
            let flexes: Bool
        }
        let columns = [
            ColumnSpec(id: "time", title: "时间", width: 104, minWidth: 90, flexes: false),
            ColumnSpec(id: "kind", title: "模式", width: 92, minWidth: 76, flexes: false),
            ColumnSpec(id: "content", title: "内容（双击复制成稿）", width: 330, minWidth: 180, flexes: true),
            ColumnSpec(id: "meta", title: "字数 / 时长 / 应用", width: 150, minWidth: 110, flexes: false),
        ]
        for spec in columns {
            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(spec.id)
            )
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            column.maxWidth = spec.flexes ? 10_000 : 400
            column.resizingMask = spec.flexes
                ? .autoresizingMask
                : .userResizingMask
            voiceHistoryTableView.addTableColumn(column)
        }
        voiceHistoryTableView.usesAlternatingRowBackgroundColors = true
        voiceHistoryTableView.rowHeight = 36
        voiceHistoryTableView.allowsMultipleSelection = false
        voiceHistoryTableView.menu = makeVoiceHistoryContextMenu()
        let adapter = VoiceHistoryTableAdapter(
            recordsProvider: { [weak self] in
                self?.voiceHistoryRecords ?? []
            },
            onSelectionChange: { [weak self] in
                self?.updateVoiceHistorySelectionDependentControls()
            }
        )
        voiceHistoryTableAdapter = adapter
        voiceHistoryTableView.dataSource = adapter
        voiceHistoryTableView.delegate = adapter
        voiceHistoryTableView.doubleAction = #selector(
            copySelectedVoiceHistoryFinal(_:)
        )
    }

    private func makeVoiceHistoryContextMenu() -> NSMenu {
        let menu = NSMenu(title: "语音历史")
        let items: [(title: String, action: Selector)] = [
            ("复制成稿", #selector(copySelectedVoiceHistoryFinal(_:))),
            ("复制原文", #selector(copySelectedVoiceHistoryRaw(_:))),
            ("删除", #selector(deleteSelectedVoiceHistory(_:))),
        ]
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: item.action, keyEquivalent: "")
            menuItem.target = self
            menu.addItem(menuItem)
        }
        return menu
    }

    /// 右键菜单与操作按钮共用：没有选中行时一律禁用。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copySelectedVoiceHistoryFinal(_:)),
             #selector(copySelectedVoiceHistoryRaw(_:)),
             #selector(deleteSelectedVoiceHistory(_:)):
            return selectedVoiceHistoryRecord() != nil
        default:
            return true
        }
    }

    func updateVoiceHistorySelectionDependentControls() {
        let hasSelection = selectedVoiceHistoryRecord() != nil
        for button in [voiceHistoryCopyFinalButton, voiceHistoryCopyRawButton, voiceHistoryDeleteButton] {
            button.isEnabled = hasSelection
        }
    }

    // MARK: - 页面高度

    /// 监听本页可视区域尺寸变化，让历史表格吃掉页面剩余高度。
    private func observeVoiceHistoryPageLayout() {
        voiceHistoryPageLayoutObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let clipView = notification.object as? NSClipView else {
                    return
                }
                self?.handleVoiceHistoryPageBoundsChange(clipView)
            }
        }
    }

    private func handleVoiceHistoryPageBoundsChange(_ clipView: NSClipView) {
        guard clipView === voiceHistoryPageClipView else {
            return
        }
        layoutVoiceHistoryPageForAvailableHeight()
    }

    /// 外层滚动视图足够高时表格直接填满，不再出现 240pt 的嵌套小滚动区；
    /// 空间不足时保底 240pt 并交由外层滚动。
    func layoutVoiceHistoryPageForAvailableHeight() {
        if voiceHistoryPageClipView == nil {
            let pageClipView = voiceHistoryScrollView.enclosingScrollView?.contentView
            pageClipView?.postsBoundsChangedNotifications = true
            voiceHistoryPageClipView = pageClipView
        }
        guard let clipView = voiceHistoryPageClipView,
              let heightConstraint = voiceHistoryTableHeightConstraint,
              clipView.bounds.height > 0
        else {
            return
        }
        let documentHeight = clipView.documentView?.frame.height ?? 0
        let otherContentHeight = documentHeight - heightConstraint.constant
        let desired = clipView.bounds.height - otherContentHeight
        let target = min(
            max(desired, SettingsLayout.historyTableMinimumHeight),
            SettingsLayout.historyTableMaximumHeight
        )
        if abs(target - heightConstraint.constant) > 0.5 {
            heightConstraint.constant = target
        }
    }

    // MARK: - 刷新（后台查询）

    func refreshVoiceHistoryAndStats() {
        let query = voiceHistorySearchField.stringValue
        let selectedAction = VoiceHistoryFilter.action(
            forPopupIndex: voiceHistoryFilterPopup.indexOfSelectedItem
        )
        let historyEnabled = settings.voiceHistoryEnabled
        voiceHistoryRefreshGeneration &+= 1
        let generation = voiceHistoryRefreshGeneration
        let service = voiceHistoryService
        // SQLite 查询移出主线程；结果按代次回填，过期结果直接丢弃。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let summary = try? service.usageSummary()
            let records = (try? service.listRecords(
                query: query,
                actionKind: selectedAction,
                limit: 300
            )) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.voiceHistoryRefreshGeneration == generation
                else {
                    return
                }
                self.applyVoiceHistoryAndStats(
                    summary: summary,
                    records: records,
                    historyEnabled: historyEnabled
                )
            }
        }
    }

    func applyVoiceHistoryAndStats(
        summary: VoiceUsageSummary?,
        records: [VoiceHistoryRecord],
        historyEnabled: Bool
    ) {
        applyVoiceUsageStats(summary)

        // 刷新后尽量保留原来选中的那条记录。
        let previousSelection = selectedVoiceHistoryRecord()?.id
        voiceHistoryRecords = records
        voiceHistoryTableView.reloadData()
        if let previousSelection,
           let index = records.firstIndex(where: { $0.id == previousSelection })
        {
            voiceHistoryTableView.selectRowIndexes(
                IndexSet(integer: index),
                byExtendingSelection: false
            )
        }
        voiceHistoryEmptyStateLabel.isHidden = !records.isEmpty
        updateVoiceHistorySelectionDependentControls()
        let retentionNote = historyEnabled
            ? "历史记录已开启"
            : "历史记录已关闭（仅统计次数与字数）"
        voiceHistoryStatusLabel.stringValue =
            "\(retentionNote) · 当前显示 \(records.count) 条记录"
        layoutVoiceHistoryPageForAvailableHeight()
    }

    private func applyVoiceUsageStats(_ summary: VoiceUsageSummary?) {
        guard let summary else {
            for label in [voiceStatCharsValueLabel, voiceStatSessionsValueLabel,
                          voiceStatDurationValueLabel, voiceStatSavedTimeValueLabel]
            {
                label.stringValue = "—"
                applyStatValueFont(label)
            }
            voiceStatsDetailLabel.stringValue = "统计存储暂不可用"
            voiceStatsTopAppsLabel.stringValue = ""
            voiceWeeklyChartView.update(dailyTrend: [])
            return
        }
        voiceStatCharsValueLabel.stringValue = "\(summary.totalCharacters) 字"
        voiceStatSessionsValueLabel.stringValue = "\(summary.totalSessions) 次"
        voiceStatDurationValueLabel.stringValue = VoiceStatsFormatting.formatDuration(
            milliseconds: summary.totalDurationMilliseconds
        )
        voiceStatSavedTimeValueLabel.stringValue = VoiceStatsFormatting.formatSavedMinutes(
            summary.estimatedMinutesSaved
        )
        for label in [voiceStatCharsValueLabel, voiceStatSessionsValueLabel,
                      voiceStatDurationValueLabel, voiceStatSavedTimeValueLabel]
        {
            applyStatValueFont(label)
        }
        voiceStatsDetailLabel.stringValue = VoiceStatsFormatting.detailLine(summary)
        voiceStatsTopAppsLabel.stringValue = VoiceStatsFormatting.topAppsLine(summary.topApps)
        voiceWeeklyChartView.update(dailyTrend: summary.dailyTrend)
    }

    // MARK: - 操作

    @objc func voiceHistoryFilterChanged(_ sender: Any?) {
        refreshVoiceHistoryAndStats()
    }

    @objc func copySelectedVoiceHistoryFinal(_ sender: Any?) {
        guard let record = selectedVoiceHistoryRecord() else {
            updateSettingsActionStatus(.failure, "请先选择一条语音历史记录")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.finalText, forType: .string)
        updateSettingsActionStatus(.success, "已复制成稿到剪贴板")
    }

    @objc func copySelectedVoiceHistoryRaw(_ sender: Any?) {
        guard let record = selectedVoiceHistoryRecord() else {
            updateSettingsActionStatus(.failure, "请先选择一条语音历史记录")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.rawText, forType: .string)
        updateSettingsActionStatus(.success, "已复制识别原文到剪贴板")
    }

    /// 删除不可撤销：先确认再执行。
    @objc func deleteSelectedVoiceHistory(_ sender: Any?) {
        guard let record = selectedVoiceHistoryRecord() else {
            updateSettingsActionStatus(.failure, "请先选择一条要删除的记录")
            return
        }
        let preview = record.finalText.count > 30
            ? String(record.finalText.prefix(30)) + "…"
            : record.finalText
        let alert = NSAlert()
        alert.messageText = "删除这条语音历史记录？"
        alert.informativeText = "将删除：“\(preview)”\n此操作无法撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else {
                return
            }
            do {
                try self.voiceHistoryService.deleteRecord(id: record.id)
                self.refreshVoiceHistoryAndStats()
                self.updateSettingsActionStatus(.success, "已删除选中的语音历史记录")
            } catch {
                self.presentError(
                    error,
                    message: "未能删除语音历史记录",
                    information: "请稍后重试。"
                )
            }
        }
    }

    @objc func exportVoiceHistory(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RimeAI-voice-history.jsonl"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "jsonl") ?? .json,
        ]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                return
            }
            // 导出可能包含数千条记录：写文件在后台完成。
            let service = self.voiceHistoryService
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try service.exportHistoryJSONL(to: url) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else {
                        return
                    }
                    switch result {
                    case .success:
                        self.updateSettingsActionStatus(
                            .success,
                            "语音历史已导出为 \(url.lastPathComponent)"
                        )
                    case let .failure(error):
                        self.presentError(
                            error,
                            message: "未能导出语音历史",
                            information: "目标文件没有被完整写入。"
                        )
                    }
                }
            }
        }
    }

    @objc func clearVoiceHistory(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "清空全部语音历史文本？"
        alert.informativeText =
            "将删除本机保存的所有语音听写、润色与翻译文本记录；累计使用统计会保留。"
        alert.addButton(withTitle: "清空历史")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else {
                return
            }
            do {
                try self.voiceHistoryService.clearHistory()
                self.refreshVoiceHistoryAndStats()
                self.updateSettingsActionStatus(.success, "语音历史记录已清空")
            } catch {
                self.presentError(
                    error,
                    message: "未能清空语音历史",
                    information: "请稍后重试。"
                )
            }
        }
    }

    @objc func resetVoiceUsageStats(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "重置语音使用情况统计？"
        alert.informativeText =
            "将清零累计字数、次数、时长、常用应用与连续天数统计；不会删除已有历史文本。"
        alert.addButton(withTitle: "重置统计")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else {
                return
            }
            do {
                try self.voiceHistoryService.resetUsageStatistics()
                self.refreshVoiceHistoryAndStats()
                self.updateSettingsActionStatus(.success, "语音使用统计已重置")
            } catch {
                self.presentError(
                    error,
                    message: "未能重置语音统计",
                    information: "请稍后重试。"
                )
            }
        }
    }

    func selectedVoiceHistoryRecord() -> VoiceHistoryRecord? {
        let row = voiceHistoryTableView.selectedRow
        guard voiceHistoryRecords.indices.contains(row) else {
            return nil
        }
        return voiceHistoryRecords[row]
    }
}

@MainActor
final class VoiceHistoryTableAdapter: NSObject, NSTableViewDataSource,
    NSTableViewDelegate
{
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private let recordsProvider: () -> [VoiceHistoryRecord]
    private let onSelectionChange: () -> Void

    init(
        recordsProvider: @escaping () -> [VoiceHistoryRecord],
        onSelectionChange: @escaping () -> Void = {}
    ) {
        self.recordsProvider = recordsProvider
        self.onSelectionChange = onSelectionChange
        super.init()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        recordsProvider().count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange()
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let records = recordsProvider()
        guard records.indices.contains(row),
              let columnID = tableColumn?.identifier.rawValue
        else {
            return nil
        }
        let record = records[row]
        let cellIdentifier = NSUserInterfaceItemIdentifier("voiceHistory.\(columnID)")
        let cell: NSTableCellView
        if let reused = tableView.makeView(
            withIdentifier: cellIdentifier,
            owner: self
        ) as? NSTableCellView {
            cell = reused
        } else {
            cell = Self.makeCell(identifier: cellIdentifier)
        }

        guard let textField = cell.textField else {
            return cell
        }
        Self.configure(
            textField,
            columnID: columnID,
            record: record
        )
        return cell
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 2
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(
                equalTo: cell.leadingAnchor,
                constant: 4
            ),
            textField.trailingAnchor.constraint(
                equalTo: cell.trailingAnchor,
                constant: -4
            ),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static func configure(
        _ textField: NSTextField,
        columnID: String,
        record: VoiceHistoryRecord
    ) {
        switch columnID {
        case "time":
            textField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            textField.textColor = .secondaryLabelColor
            textField.stringValue = timeFormatter.string(from: record.createdAt)
        case "kind":
            textField.font = .systemFont(ofSize: 11, weight: .medium)
            (textField.textColor, textField.stringValue) = kindCell(record)
        case "content":
            textField.font = .systemFont(ofSize: 12, weight: .regular)
            textField.textColor = .labelColor
            if record.rawText != record.finalText, !record.rawText.isEmpty {
                textField.stringValue =
                    "\(record.finalText)\n原文：\(record.rawText)"
                textField.toolTip =
                    "成稿：\(record.finalText)\n原文：\(record.rawText)"
            } else {
                textField.stringValue = record.finalText
                textField.toolTip = record.finalText
            }
        case "meta":
            textField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            textField.textColor = .secondaryLabelColor
            // 解析为用户看得懂的本地化应用名，而不是 bundle id 的最后一段。
            let appName = VoiceAppDisplayName.resolve(record.bundleIdentifier)
            let sec = max(1, (record.durationMilliseconds + 500) / 1_000)
            let pasteTag = record.autoPasted ? " · 自动贴" : ""
            textField.stringValue =
                "\(record.characterCount) 字 · \(sec)s\(pasteTag)\n\(appName)"
        default:
            textField.stringValue = ""
        }
    }

    private static func kindCell(_ record: VoiceHistoryRecord) -> (NSColor, String) {
        switch record.actionKind {
        case .dictation:
            return (.labelColor, "🎙 听写")
        case .polish:
            return (.systemBlue, "✨ \(record.polishStyle?.shortName ?? "润色")")
        case .translate:
            return (.systemGreen, "🌐 \(record.targetLanguage?.shortName ?? "翻译")")
        }
    }
}
