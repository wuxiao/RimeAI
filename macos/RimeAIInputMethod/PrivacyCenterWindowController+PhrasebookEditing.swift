import AppKit

/// Controls and cached data for the language-profile editing sections
/// (LP-002 enhancement): phrase curation, domain mapping, and the cloud
/// compression switch. Owned by `PrivacyCenterWindowController`; built
/// and driven entirely from this extension file.
@MainActor
final class PhrasebookEditorControls {
    let phraseTable = NSTableView()
    let phraseScroll = NSScrollView()
    var phraseEntries: [PhraseBookEntry] = []

    let mappingTable = NSTableView()
    let mappingScroll = NSScrollView()
    var mappings: [PhraseDomainMapping] = []

    let phraseTextField = NSTextField()
    let phrasePinyinField = NSTextField()
    let phraseDomainField = NSTextField()
    let mappingBundleField = NSTextField()
    let mappingDomainField = NSTextField()
    let domainSourceField = NSTextField()
    let domainTargetField = NSTextField()
    let consolidationToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    let editorStatusLabel = NSTextField(labelWithString: "")
    /// Domain-lexicon controls (schema v2) ride on the same controls
    /// container so the oversized controller class body stays untouched;
    /// see `PrivacyCenterWindowController+DomainLexicon.swift`.
    let lexicon = DomainLexiconEditorControls()

    func entry(at index: Int) -> PhraseBookEntry? {
        phraseEntries.indices.contains(index)
            ? phraseEntries[index]
            : nil
    }

    func mapping(at index: Int) -> PhraseDomainMapping? {
        mappings.indices.contains(index) ? mappings[index] : nil
    }
}

/// 语言画像编辑交互：单条短语添加/保护/删除、域映射编辑器、域改名/
/// 合并/删除与云压缩开关（LP-002/LP-007/LP-006 收口）。
extension PrivacyCenterWindowController {
    /// Appends the editing sections to the "语言画像" page. Called from
    /// `buildLanguageProfilePage` after the read-only status sections.
    func buildPhrasebookEditingSections(_ stack: NSStackView) {
        appendPhraseCurationSection(to: stack)
        appendDomainMappingSection(to: stack)
        appendDomainOperationSection(to: stack)
        appendConsolidationSection(to: stack)
        buildDomainLexiconSection(stack)
    }

    // MARK: - 短语管理

    private func appendPhraseCurationSection(to stack: NSStackView) {
        addSeparator(to: stack)
        stack.addArrangedSubview(sectionTitle("短语管理"))
        stack.addArrangedSubview(
            label(
                "学习到的短语按使用次数排列；受保护短语永不自动淘汰。",
                secondary: true
            )
        )
        configurePhraseTable()
        stack.addArrangedSubview(phrasebookEditor.phraseScroll)
        let phraseButtons = NSStackView()
        phraseButtons.orientation = .horizontal
        phraseButtons.spacing = 8
        phraseButtons.addArrangedSubview(
            NSButton(
                title: "添加短语",
                target: self,
                action: #selector(addUserPhrase(_:))
            )
        )
        phraseButtons.addArrangedSubview(
            NSButton(
                title: "切换保护",
                target: self,
                action: #selector(togglePhraseProtection(_:))
            )
        )
        phraseButtons.addArrangedSubview(
            NSButton(
                title: "删除短语",
                target: self,
                action: #selector(deleteUserPhrase(_:))
            )
        )
        stack.addArrangedSubview(phraseButtons)
        appendInputRow(
            to: stack,
            fields: [
                (phrasebookEditor.phraseTextField, "短语文本", "例如：wayne测试短语"),
                (phrasebookEditor.phrasePinyinField, "拼音串", "例如：wayneceshidayu"),
                (phrasebookEditor.phraseDomainField, "域（默认 global）", "global"),
            ]
        )
    }

    private func configurePhraseTable() {
        let table = phrasebookEditor.phraseTable
        table.addTableColumn(
            tableColumn("短语", identifier: "phrase.text", width: 220)
        )
        table.addTableColumn(
            tableColumn("域", identifier: "phrase.domain", width: 110)
        )
        table.addTableColumn(
            tableColumn("次数", identifier: "phrase.count", width: 48)
        )
        table.addTableColumn(
            tableColumn("保护", identifier: "phrase.protected", width: 48)
        )
        configureTable(table, scroll: phrasebookEditor.phraseScroll)
    }

    // MARK: - 域映射

    private func appendDomainMappingSection(to stack: NSStackView) {
        addSeparator(to: stack)
        stack.addArrangedSubview(sectionTitle("应用分域映射"))
        stack.addArrangedSubview(
            label(
                "未映射的应用计入 global 域；域内累计提交满 50 条后才建立"
                    + "独立画像。",
                secondary: true
            )
        )
        configureMappingTable()
        stack.addArrangedSubview(phrasebookEditor.mappingScroll)
        let mappingButtons = NSStackView()
        mappingButtons.orientation = .horizontal
        mappingButtons.spacing = 8
        mappingButtons.addArrangedSubview(
            NSButton(
                title: "添加映射",
                target: self,
                action: #selector(addDomainMapping(_:))
            )
        )
        mappingButtons.addArrangedSubview(
            NSButton(
                title: "删除映射",
                target: self,
                action: #selector(removeDomainMapping(_:))
            )
        )
        stack.addArrangedSubview(mappingButtons)
        appendInputRow(
            to: stack,
            fields: [
                (
                    phrasebookEditor.mappingBundleField,
                    "Bundle ID",
                    "例如：com.apple.Safari"
                ),
                (
                    phrasebookEditor.mappingDomainField,
                    "域",
                    "例如：browser"
                ),
            ]
        )
    }

    private func configureMappingTable() {
        let table = phrasebookEditor.mappingTable
        table.addTableColumn(
            tableColumn("Bundle ID", identifier: "mapping.bundle", width: 240)
        )
        table.addTableColumn(
            tableColumn("域", identifier: "mapping.domain", width: 140)
        )
        configureTable(table, scroll: phrasebookEditor.mappingScroll)
    }

    // MARK: - 域操作

    private func appendDomainOperationSection(to stack: NSStackView) {
        addSeparator(to: stack)
        stack.addArrangedSubview(sectionTitle("域操作"))
        stack.addArrangedSubview(
            label(
                "重命名/合并把源域短语与映射并入目标域；删除域把其内容"
                    + "并回 global。",
                secondary: true
            )
        )
        let domainButtons = NSStackView()
        domainButtons.orientation = .horizontal
        domainButtons.spacing = 8
        domainButtons.addArrangedSubview(
            NSButton(
                title: "重命名/合并域",
                target: self,
                action: #selector(renamePhraseDomain(_:))
            )
        )
        domainButtons.addArrangedSubview(
            NSButton(
                title: "删除域（并入 global）",
                target: self,
                action: #selector(deletePhraseDomain(_:))
            )
        )
        stack.addArrangedSubview(domainButtons)
        appendInputRow(
            to: stack,
            fields: [
                (phrasebookEditor.domainSourceField, "源域", "例如：work"),
                (phrasebookEditor.domainTargetField, "目标域", "例如：global"),
            ]
        )
    }

    // MARK: - 云压缩开关

    private func appendConsolidationSection(to stack: NSStackView) {
        addSeparator(to: stack)
        stack.addArrangedSubview(sectionTitle("云压缩"))
        let toggle = phrasebookEditor.consolidationToggle
        toggle.title = "空闲时使用云端压缩生成风格画像"
        toggle.target = self
        toggle.action = #selector(consolidationToggleChanged(_:))
        toggle.identifier = NSUserInterfaceItemIdentifier(
            "settings.cloud-consolidation"
        )
        toggle.setAccessibilityLabel("云压缩开关")
        stack.addArrangedSubview(toggle)
        stack.addArrangedSubview(
            label(
                "关闭后退化为纯本地统计学习（短语与接词习惯继续学习），"
                    + "风格画像不再更新；开关会改写云增强服务的启动参数"
                    + "并重启它。",
                secondary: true
            )
        )
        configureWrapping(phrasebookEditor.editorStatusLabel)
        phrasebookEditor.editorStatusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(phrasebookEditor.editorStatusLabel)
    }

    // MARK: - 动作

    @objc private func addUserPhrase(_ sender: Any?) {
        let controls = phrasebookEditor
        let domain = controls.phraseDomainField.stringValue.isEmpty
            ? PhraseBookDomain.global
            : controls.phraseDomainField.stringValue
        do {
            _ = try RimeAIPhraseBookService.shared.addUserPhrase(
                text: controls.phraseTextField.stringValue,
                pinyinKeys: controls.phrasePinyinField.stringValue,
                domain: domain
            )
            controls.phraseTextField.stringValue = ""
            controls.phrasePinyinField.stringValue = ""
            reloadPhrasebookEditors()
        } catch {
            presentError(
                error,
                message: "未能添加短语",
                information: "短语与拼音串不能为空，长度需在存储限制内。"
            )
        }
    }

    @objc private func togglePhraseProtection(_ sender: Any?) {
        guard
            let entry = phrasebookEditor.entry(
                at: phrasebookEditor.phraseTable.selectedRow
            )
        else {
            return
        }
        do {
            _ = try RimeAIPhraseBookService.shared.setProtected(
                id: entry.id,
                isProtected: !entry.isProtected
            )
            reloadPhrasebookEditors()
        } catch {
            presentError(
                error,
                message: "未能更新保护状态",
                information: "短语库文件可能正被其他进程占用。"
            )
        }
    }

    @objc private func deleteUserPhrase(_ sender: Any?) {
        guard
            let entry = phrasebookEditor.entry(
                at: phrasebookEditor.phraseTable.selectedRow
            )
        else {
            return
        }
        do {
            _ = try RimeAIPhraseBookService.shared.delete(id: entry.id)
            reloadPhrasebookEditors()
        } catch {
            presentError(
                error,
                message: "未能删除短语",
                information: "短语库文件可能正被其他进程占用。"
            )
        }
    }

    @objc private func addDomainMapping(_ sender: Any?) {
        let controls = phrasebookEditor
        do {
            _ = try RimeAIPhraseBookService.shared.setDomainMapping(
                bundleIdentifier: controls.mappingBundleField.stringValue,
                domain: controls.mappingDomainField.stringValue
            )
            controls.mappingBundleField.stringValue = ""
            controls.mappingDomainField.stringValue = ""
            reloadPhrasebookEditors()
        } catch {
            presentError(
                error,
                message: "未能添加域映射",
                information: "Bundle ID 不能为空；域名为小写字母、数字、"
                    + "连字符或下划线，不超过 64 字符。"
            )
        }
    }

    @objc private func removeDomainMapping(_ sender: Any?) {
        guard
            let mapping = phrasebookEditor.mapping(
                at: phrasebookEditor.mappingTable.selectedRow
            )
        else {
            return
        }
        do {
            _ = try RimeAIPhraseBookService.shared.removeDomainMapping(
                bundleIdentifier: mapping.bundleIdentifier
            )
            reloadPhrasebookEditors()
        } catch {
            presentError(
                error,
                message: "未能删除域映射",
                information: "短语库文件可能正被其他进程占用。"
            )
        }
    }

    @objc private func renamePhraseDomain(_ sender: Any?) {
        let controls = phrasebookEditor
        do {
            _ = try RimeAIPhraseBookService.shared.renameDomain(
                from: controls.domainSourceField.stringValue,
                to: controls.domainTargetField.stringValue
            )
            controls.domainSourceField.stringValue = ""
            controls.domainTargetField.stringValue = ""
            reloadPhrasebookEditors()
        } catch {
            presentError(
                error,
                message: "未能重命名/合并域",
                information: "源域与目标域均需为有效域名且互不相同。"
            )
        }
    }

    @objc private func deletePhraseDomain(_ sender: Any?) {
        let source = phrasebookEditor.domainSourceField.stringValue
        guard !source.isEmpty else {
            return
        }
        guard source.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() != PhraseBookDomain.global
        else {
            // store 侧 rename 到 global 等价于 no-op，必须在此拦下并
            // 明确告知，而不是清空输入框伪装成功。
            presentError(
                PhraseBookError.invalidDomain,
                message: "未能删除域",
                information: "global 域不可删除。"
            )
            return
        }
        do {
            _ = try RimeAIPhraseBookService.shared.deleteDomain(source)
            phrasebookEditor.domainSourceField.stringValue = ""
            reloadPhrasebookEditors()
        } catch {
            presentError(
                error,
                message: "未能删除域",
                information: "域必须存在；global 域不可删除。"
            )
        }
    }

    @objc private func consolidationToggleChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        RimeAISettingsStore.shared.cloudConsolidationEnabled = enabled
        applyCloudConsolidationPreference(enabled)
    }

    /// 把偏好写入已安装的 broker LaunchAgent plist；plist 变化且 broker
    /// 正在运行时重启它。launchctl 交互在后台队列执行，避免阻塞 UI。
    private func applyCloudConsolidationPreference(_ enabled: Bool) {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let plistURL = layout.cloudBrokerLaunchAgentPlist
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            phrasebookEditor.editorStatusLabel.stringValue =
                "云增强服务未安装；偏好已保存，安装后生效。"
            return
        }
        let wasRunning = FileManager.default.fileExists(
            atPath: layout.cloudBrokerEnabledMarker.path
        )
        phrasebookEditor.editorStatusLabel.stringValue =
            "正在应用云压缩偏好…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Self.applyConsolidationToInstalledBroker(
                layout: layout,
                plistURL: plistURL,
                enabled: enabled,
                wasRunning: wasRunning
            )
            DispatchQueue.main.async { [weak self] in
                switch outcome {
                case .success:
                    self?.phrasebookEditor.editorStatusLabel.stringValue =
                        enabled
                        ? "云压缩已开启。"
                        : "云压缩已关闭；仅保留本地统计学习。"
                case let .failure(message):
                    self?.phrasebookEditor.editorStatusLabel.stringValue =
                        "未能应用云压缩偏好：\(message)"
                }
            }
        }
    }

    private enum ConsolidationOutcome {
        case success
        case failure(String)
    }

    private nonisolated static func applyConsolidationToInstalledBroker(
        layout: RimeAIProductDataLayout,
        plistURL: URL,
        enabled: Bool,
        wasRunning: Bool
    ) -> ConsolidationOutcome {
        do {
            let changed = try CloudBrokerConsolidationPreference.apply(
                consolidationEnabled: enabled,
                to: plistURL
            )
            if wasRunning, changed {
                try ServiceLifecycleCoordinator.stopManagedCloudBroker(
                    layout: layout
                )
                try ServiceLifecycleCoordinator.startManagedCloudBroker(
                    layout: layout
                )
            }
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - 刷新

    func reloadPhrasebookEditors() {
        phrasebookEditor.consolidationToggle.state =
            RimeAISettingsStore.shared.cloudConsolidationEnabled ? .on : .off
        reloadDomainLexiconEditors()
        // 设置页不在击键路径上，但 SQLite 查询仍不下主线程：后台取
        // 数、主线程回填表格。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let service = RimeAIPhraseBookService.shared
            let entries = (try? service.entries(limit: 200)) ?? []
            let mappings = (try? service.domainMappings()) ?? []
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.phrasebookEditor.phraseEntries = entries
                    self.phrasebookEditor.phraseTable.reloadData()
                    self.phrasebookEditor.mappings = mappings
                    self.phrasebookEditor.mappingTable.reloadData()
                }
            }
        }
    }

    // MARK: - 控件辅助

    private func tableColumn(
        _ title: String,
        identifier: String,
        width: CGFloat
    ) -> NSTableColumn {
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier(identifier)
        )
        column.title = title
        column.width = width
        return column
    }

    private func configureTable(_ table: NSTableView, scroll: NSScrollView) {
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.identifier = NSUserInterfaceItemIdentifier(
            table === phrasebookEditor.phraseTable
                ? "settings.phrasebook-phrase-table"
                : "settings.phrasebook-mapping-table"
        )
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
    }

    private func appendInputRow(
        to stack: NSStackView,
        fields: [(field: NSTextField, label: String, placeholder: String)]
    ) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        for (field, title, placeholder) in fields {
            let column = NSStackView()
            column.orientation = .vertical
            column.spacing = 2
            column.addArrangedSubview(
                label(title, font: .systemFont(ofSize: 11), secondary: true)
            )
            field.placeholderString = placeholder
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(
                greaterThanOrEqualToConstant: 120
            ).isActive = true
            column.addArrangedSubview(field)
            row.addArrangedSubview(column)
        }
        stack.addArrangedSubview(row)
    }
}

// MARK: - NSTableView data source & delegate

extension PrivacyCenterWindowController:
    NSTableViewDataSource, NSTableViewDelegate
{
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === phrasebookEditor.phraseTable {
            return phrasebookEditor.phraseEntries.count
        }
        if tableView === lexiconEditor.lexiconTable {
            return lexiconEditor.lexicons.count
        }
        if tableView === lexiconEditor.entryTable {
            return lexiconEditor.entries.count
        }
        return phrasebookEditor.mappings.count
    }

    func tableView(
        _ tableView: NSTableView,
        objectValueFor tableColumn: NSTableColumn?,
        row: Int
    ) -> Any? {
        guard let identifier = tableColumn?.identifier.rawValue else {
            return nil
        }
        if tableView === lexiconEditor.lexiconTable {
            return lexiconObjectValue(identifier: identifier, row: row)
        }
        if tableView === lexiconEditor.entryTable {
            return lexiconEntryObjectValue(identifier: identifier, row: row)
        }
        if tableView === phrasebookEditor.phraseTable {
            return phraseObjectValue(identifier: identifier, row: row)
        }
        return mappingObjectValue(identifier: identifier, row: row)
    }

    private func lexiconObjectValue(
        identifier: String,
        row: Int
    ) -> Any? {
        guard let lexicon = lexiconEditor.lexicon(at: row) else {
            return nil
        }
        switch identifier {
        case "lexicon.name":
            return lexicon.name
        case "lexicon.domain":
            return lexicon.domain
        case "lexicon.version":
            return lexicon.version
        case "lexicon.count":
            return lexicon.entryCount
        case "lexicon.enabled":
            return lexicon.isEnabled ? "启用" : "停用"
        default:
            return nil
        }
    }

    private func lexiconEntryObjectValue(
        identifier: String,
        row: Int
    ) -> Any? {
        guard let entry = lexiconEditor.entry(at: row) else {
            return nil
        }
        switch identifier {
        case "lexicon-entry.text":
            return entry.text
        case "lexicon-entry.pinyin":
            return entry.pinyinKeys
        case "lexicon-entry.weight":
            return entry.weight
        case "lexicon-entry.blocked":
            return entry.isBlocked ? "✓" : ""
        default:
            return nil
        }
    }

    private func phraseObjectValue(
        identifier: String,
        row: Int
    ) -> Any? {
        guard let entry = phrasebookEditor.entry(at: row) else {
            return nil
        }
        switch identifier {
        case "phrase.text":
            return entry.text
        case "phrase.domain":
            return entry.domain
        case "phrase.count":
            return entry.count
        case "phrase.protected":
            return entry.isProtected ? "✓" : ""
        default:
            return nil
        }
    }

    private func mappingObjectValue(
        identifier: String,
        row: Int
    ) -> Any? {
        guard let mapping = phrasebookEditor.mapping(at: row) else {
            return nil
        }
        switch identifier {
        case "mapping.bundle":
            return mapping.bundleIdentifier
        case "mapping.domain":
            return mapping.domain
        default:
            return nil
        }
    }
}
