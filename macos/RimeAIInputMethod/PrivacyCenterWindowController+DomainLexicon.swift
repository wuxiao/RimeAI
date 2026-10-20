import AppKit
import UniformTypeIdentifiers

/// Controls and cached data for the domain-lexicon section: the
/// installed-lexicon table, the selected lexicon's entry table, the
/// mount-domain input, and the section status label. Owned by
/// `PrivacyCenterWindowController`; built and driven entirely from this
/// extension file (mirrors `PhrasebookEditorControls`).
@MainActor
final class DomainLexiconEditorControls {
    let lexiconTable = NSTableView()
    let lexiconScroll = NSScrollView()
    var lexicons: [DomainLexicon] = []
    var selectedLexiconId: String?

    let entryTable = NSTableView()
    let entryScroll = NSScrollView()
    var entries: [DomainLexiconEntry] = []

    let domainField = NSTextField()
    let statusLabel = NSTextField(labelWithString: "")

    func lexicon(at index: Int) -> DomainLexicon? {
        lexicons.indices.contains(index) ? lexicons[index] : nil
    }

    func entry(at index: Int) -> DomainLexiconEntry? {
        entries.indices.contains(index) ? entries[index] : nil
    }
}

/// 领域词库管理（schema v2 资产侧）：安装/替换 Rime `.dict.yaml` 词库、
/// 启停、卸载、词条浏览与跨读音屏蔽。词库短语只进独立建议位（与学习
/// 短语同一落点），不移动数字候选、不触碰 Rime 用户词典。
extension PrivacyCenterWindowController {
    /// Controls live on `phrasebookEditor.lexicon`（控制器类体保持不
    /// 变，见 `PhrasebookEditorControls.lexicon` 注释）。internal：
    /// `+PhrasebookEditing.swift` 的表格数据源分支同样引用。
    var lexiconEditor: DomainLexiconEditorControls {
        phrasebookEditor.lexicon
    }
    /// Appends the domain-lexicon section to the "语言画像" page. Called
    /// from `buildPhrasebookEditingSections` after the phrase-curation
    /// sections.
    func buildDomainLexiconSection(_ stack: NSStackView) {
        addSeparator(to: stack)
        stack.addArrangedSubview(sectionTitle("领域词库"))
        stack.addArrangedSubview(
            label(
                "导入 Rime .dict.yaml 词库（如雾凇 cn_dicts）挂载到指定域；"
                    + "词库词条按域命中独立建议位，优先级低于学习短语。",
                secondary: true
            )
        )
        configureLexiconTable()
        stack.addArrangedSubview(lexiconEditor.lexiconScroll)
        let lexiconButtons = NSStackView()
        lexiconButtons.orientation = .horizontal
        lexiconButtons.spacing = 8
        lexiconButtons.addArrangedSubview(
            NSButton(
                title: "导入词库…",
                target: self,
                action: #selector(importDomainLexicon(_:))
            )
        )
        lexiconButtons.addArrangedSubview(
            NSButton(
                title: "启用/禁用",
                target: self,
                action: #selector(toggleLexiconEnabled(_:))
            )
        )
        lexiconButtons.addArrangedSubview(
            NSButton(
                title: "卸载",
                target: self,
                action: #selector(uninstallDomainLexicon(_:))
            )
        )
        stack.addArrangedSubview(lexiconButtons)
        appendLexiconDomainRow(to: stack)

        stack.addArrangedSubview(
            label("选中词库的词条（同词多行 = 多音字）：", secondary: true)
        )
        configureLexiconEntryTable()
        stack.addArrangedSubview(lexiconEditor.entryScroll)
        let entryButtons = NSStackView()
        entryButtons.orientation = .horizontal
        entryButtons.spacing = 8
        entryButtons.addArrangedSubview(
            NSButton(
                title: "屏蔽词条",
                target: self,
                action: #selector(blockLexiconEntry(_:))
            )
        )
        entryButtons.addArrangedSubview(
            NSButton(
                title: "解除屏蔽",
                target: self,
                action: #selector(unblockLexiconEntry(_:))
            )
        )
        stack.addArrangedSubview(entryButtons)
        configureWrapping(lexiconEditor.statusLabel)
        lexiconEditor.statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(lexiconEditor.statusLabel)
    }

    // MARK: - 表格配置

    private func configureLexiconTable() {
        let table = lexiconEditor.lexiconTable
        table.addTableColumn(
            tableColumn("名称", identifier: "lexicon.name", width: 150)
        )
        table.addTableColumn(
            tableColumn("域", identifier: "lexicon.domain", width: 90)
        )
        table.addTableColumn(
            tableColumn("版本", identifier: "lexicon.version", width: 50)
        )
        table.addTableColumn(
            tableColumn("词条", identifier: "lexicon.count", width: 50)
        )
        table.addTableColumn(
            tableColumn("状态", identifier: "lexicon.enabled", width: 50)
        )
        configureLexiconTable(table, scroll: lexiconEditor.lexiconScroll)
    }

    private func configureLexiconEntryTable() {
        let table = lexiconEditor.entryTable
        table.addTableColumn(
            tableColumn("文本", identifier: "lexicon-entry.text", width: 200)
        )
        table.addTableColumn(
            tableColumn("拼音", identifier: "lexicon-entry.pinyin", width: 200)
        )
        table.addTableColumn(
            tableColumn("权重", identifier: "lexicon-entry.weight", width: 44)
        )
        table.addTableColumn(
            tableColumn("屏蔽", identifier: "lexicon-entry.blocked", width: 44)
        )
        configureLexiconTable(table, scroll: lexiconEditor.entryScroll)
    }

    private func configureLexiconTable(
        _ table: NSTableView,
        scroll: NSScrollView
    ) {
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.identifier = NSUserInterfaceItemIdentifier(
            table === lexiconEditor.lexiconTable
                ? "settings.domain-lexicon-table"
                : "settings.domain-lexicon-entry-table"
        )
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
    }

    private func appendLexiconDomainRow(to stack: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let column = NSStackView()
        column.orientation = .vertical
        column.spacing = 2
        column.addArrangedSubview(
            label("挂载域（默认 global）", font: .systemFont(ofSize: 11), secondary: true)
        )
        lexiconEditor.domainField.placeholderString = "例如：it"
        lexiconEditor.domainField.translatesAutoresizingMaskIntoConstraints = false
        lexiconEditor.domainField.widthAnchor.constraint(
            greaterThanOrEqualToConstant: 120
        ).isActive = true
        column.addArrangedSubview(lexiconEditor.domainField)
        row.addArrangedSubview(column)
        stack.addArrangedSubview(row)
    }

    // MARK: - 动作

    @objc private func importDomainLexicon(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "yaml") ?? .yaml,
            UTType(filenameExtension: "dict.yaml") ?? .yaml,
        ]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.importLexicon(from: url)
        }
    }

    private func importLexicon(from url: URL) {
        let domain = lexiconEditor.domainField.stringValue.isEmpty
            ? PhraseBookDomain.global
            : lexiconEditor.domainField.stringValue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let source = try String(
                    contentsOf: url,
                    encoding: .utf8
                )
                let result = try RimeAIPhraseBookService.shared
                    .installLexiconDictYAML(source: source, domain: domain)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else {
                            return
                        }
                        let lexicon = result.lexicon
                        self.lexiconEditor.statusLabel.stringValue =
                            "已导入 \(lexicon.name) \(lexicon.version)：" +
                            "词条 \(result.insertedEntries) 条" +
                            (result.rejectedLineCount > 0
                                ? "，跳过 \(result.rejectedLineCount) 行"
                                : "") +
                            (result.replacedPrevious ? "（替换旧版本）" : "") +
                            "，挂载到 \(lexicon.domain) 域。"
                        self.reloadDomainLexiconEditors()
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.presentError(
                            error,
                            message: "未能导入词库",
                            information: "文件需为 Rime .dict.yaml（含 --- 头、"
                                + "词条用 Tab 分列并带拼音）；挂载域为小写"
                                + "字母、数字或连字符（最多 64 字符）；"
                                + "单个词库最多 200,000 词条。"
                        )
                    }
                }
            }
        }
    }

    @objc private func toggleLexiconEnabled(_ sender: Any?) {
        guard
            let lexicon = lexiconEditor.lexicon(
                at: lexiconEditor.lexiconTable.selectedRow
            )
        else {
            return
        }
        do {
            _ = try RimeAIPhraseBookService.shared.setLexiconEnabled(
                id: lexicon.id,
                isEnabled: !lexicon.isEnabled
            )
            reloadDomainLexiconEditors()
        } catch {
            presentError(
                error,
                message: "未能更新词库状态",
                information: "词库文件可能正被其他进程占用。"
            )
        }
    }

    @objc private func uninstallDomainLexicon(_ sender: Any?) {
        guard
            let lexicon = lexiconEditor.lexicon(
                at: lexiconEditor.lexiconTable.selectedRow
            )
        else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "卸载词库「\(lexicon.name)」？"
        alert.informativeText =
            "将删除该词库的全部词条（\(lexicon.entryCount) 条）。学习到的"
                + "短语不受影响。此操作无法撤销。"
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            do {
                _ = try RimeAIPhraseBookService.shared.uninstallLexicon(
                    id: lexicon.id
                )
                self?.lexiconEditor.selectedLexiconId = nil
                self?.reloadDomainLexiconEditors()
            } catch {
                self?.presentError(
                    error,
                    message: "未能卸载词库",
                    information: "词库文件可能正被其他进程占用。"
                )
            }
        }
    }

    @objc private func blockLexiconEntry(_ sender: Any?) {
        toggleLexiconEntryBlocked(true)
    }

    @objc private func unblockLexiconEntry(_ sender: Any?) {
        toggleLexiconEntryBlocked(false)
    }

    private func toggleLexiconEntryBlocked(_ blocked: Bool) {
        guard
            let entry = lexiconEditor.entry(
                at: lexiconEditor.entryTable.selectedRow
            )
        else {
            return
        }
        do {
            _ = try RimeAIPhraseBookService.shared.setLexiconEntryBlocked(
                lexiconId: entry.lexiconId,
                text: entry.text,
                isBlocked: blocked
            )
            reloadDomainLexiconEditors()
        } catch {
            presentError(
                error,
                message: "未能更新词条屏蔽状态",
                information: "词库文件可能正被其他进程占用。"
            )
        }
    }

    // MARK: - 刷新

    func reloadDomainLexiconEditors() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let service = RimeAIPhraseBookService.shared
            let lexicons = (try? service.lexicons()) ?? []
            let selected = lexicons.first {
                $0.id == self?.lexiconEditorSelectedIdSnapshot()
            } ?? lexicons.first
            let entries = selected.flatMap {
                try? service.lexiconEntries(lexiconId: $0.id, limit: 300)
            } ?? []
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.lexiconEditor.lexicons = lexicons
                    self.lexiconEditor.selectedLexiconId = selected?.id
                    self.lexiconEditor.lexiconTable.reloadData()
                    self.lexiconEditor.entries = entries
                    self.lexiconEditor.entryTable.reloadData()
                }
            }
        }
    }

    /// Snapshot of the selected lexicon id for background reloads
    /// (MainActor-isolated read before hopping queues).
    private func lexiconEditorSelectedIdSnapshot() -> String? {
        lexiconEditor.selectedLexiconId
    }

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
}
