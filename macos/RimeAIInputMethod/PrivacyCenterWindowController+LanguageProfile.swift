import AppKit
import UniformTypeIdentifiers

/// Language-profile settings page (LP-002): learning status, style
/// profile summary, and data management for the L1/L3 artifacts.
extension PrivacyCenterWindowController {
    /// Builds the "语言画像" page content. Called from
    /// `configureInterface()` right after the cloud/history page.
    func buildLanguageProfilePage(_ profileStack: NSStackView) {
        profileStack.addArrangedSubview(sectionTitle("学习状态"))
        configureWrapping(phrasebookStatusLabel)
        phrasebookStatusLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.phrasebook-status"
        )
        phrasebookStatusLabel.setAccessibilityLabel("短语库学习状态")
        profileStack.addArrangedSubview(phrasebookStatusLabel)

        addSeparator(to: profileStack)
        profileStack.addArrangedSubview(sectionTitle("风格画像"))
        configureWrapping(profileSummaryLabel)
        profileSummaryLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.style-profile-summary"
        )
        profileSummaryLabel.setAccessibilityLabel("风格画像状态")
        profileStack.addArrangedSubview(profileSummaryLabel)
        profileStack.addArrangedSubview(
            label(
                "画像由空闲时的云压缩生成；在设置中关闭云增强后仅保留"
                    + "本地统计学习。"
            )
        )

        addSeparator(to: profileStack)
        profileStack.addArrangedSubview(sectionTitle("数据管理"))
        let profileButtons = NSStackView()
        profileButtons.orientation = .horizontal
        profileButtons.spacing = 8
        profileButtons.addArrangedSubview(
            NSButton(
                title: "导出语言画像…",
                target: self,
                action: #selector(exportPhrasebook(_:))
            )
        )
        profileButtons.addArrangedSubview(
            NSButton(
                title: "永久清除语言画像…",
                target: self,
                action: #selector(clearPhrasebook(_:))
            )
        )
        profileStack.addArrangedSubview(profileButtons)

        buildPhrasebookEditingSections(profileStack)
    }

    @objc func exportPhrasebook(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RimeAI-language-profile.json"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "json") ?? .json,
        ]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try RimeAIPhraseBookService.shared.exportJSON(to: url)
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.presentError(
                                error,
                                message: "未能导出语言画像",
                                information: "目标文件没有被完整写入。"
                            )
                        }
                    }
                }
            }
        }
    }

    @objc func clearPhrasebook(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "永久清除全部语言画像？"
        alert.informativeText =
            "将删除学习到的全部短语、风格画像与域映射，且不会移除"
                + "明文历史或 API Key。此操作无法撤销。"
        alert.addButton(withTitle: "永久清除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .critical
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try RimeAIPhraseBookService.shared.clearAll()
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.presentError(
                                error,
                                message: "未能清除短语库",
                                information: "文件可能正被其他进程占用。"
                            )
                        }
                    }
                    return
                }
                Self.removeStyleProfiles()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.refreshLanguageProfileStatus()
                    }
                }
            }
        }
    }

    private nonisolated static func removeStyleProfiles() {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let directory = layout.languageProfileDirectory
        let items =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
        for item in items
        where item.lastPathComponent.hasPrefix("profile-") {
            try? FileManager.default.removeItem(at: item)
        }
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("revisions")
        )
    }

    func refreshLanguageProfileStatus() {
        // 统计与画像 JSON 读取留在后台队列，主线程只回填文案。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let statusText: String
            if let statistics = try? RimeAIPhraseBookService.shared
                .statistics()
            {
                let domains = statistics.domains.joined(separator: "、")
                statusText =
                    "已学习短语 \(statistics.entryCount) 条（保护 "
                    + "\(statistics.protectedCount) 条），域："
                    + (domains.isEmpty ? "global" : domains) + "。"
            } else {
                statusText =
                    "短语库暂不可用；输入法启用后会自动创建。"
            }
            let summary = Self.styleProfileSummaryText()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.phrasebookStatusLabel.stringValue = statusText
                    self.profileSummaryLabel.stringValue = summary
                }
            }
        }
        reloadPhrasebookEditors()
    }

    private nonisolated static func styleProfileSummaryText() -> String {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let url = layout.languageProfileDirectory
            .appendingPathComponent("profile-global.json")
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let revision = object["revision"] as? Int
        else {
            return "尚未生成风格画像（等待空闲固化循环）。"
        }
        let traits = (object["traits"] as? [String: Any]) ?? [:]
        let phrases =
            (traits["signature_phrases"] as? [String])?.count ?? 0
        let locked =
            (object["locked_fields"] as? [String])?.count ?? 0
        return "全局画像第 \(revision) 版；常用短语 \(phrases) 条，"
            + "用户锁定字段 \(locked) 个。"
    }
}
