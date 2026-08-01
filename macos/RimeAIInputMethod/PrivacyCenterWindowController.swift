import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PrivacyCenterWindowController: NSObject {
    static let shared = PrivacyCenterWindowController()

    private let settings = RimeAISettingsStore.shared
    private let window: NSWindow
    private let aiToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let offlineToggle = NSButton(
        checkboxWithTitle: "",
        target: nil,
        action: nil
    )
    private let contextPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let disabledAIField = NSTextField()
    private let disabledContextField = NSTextField()
    private let daemonStatusLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let artifactLabel = NSTextField(labelWithString: "")
    private let diagnosticsLabel = NSTextField(labelWithString: "")
    private let dataSizeLabel = NSTextField(labelWithString: "")
    private var daemonObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "RimeAI 隐私控制中心"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 620)
        configureInterface()
        observeState()
        refresh()
    }

    func showWindow() {
        refresh()
        if settings.aiEnabled {
            DaemonClient.shared.connect()
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureInterface() {
        // The developer preview ships without any network-backed feature.
        // Keep the persisted snapshot aligned with the process-wide guard.
        settings.offlineLockEnabled = true

        let contentView = NSView()
        window.contentView = contentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -24
            ),
            stack.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: 22
            ),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: contentView.bottomAnchor,
                constant: -22
            ),
        ])

        let title = label(
            "本地输入与隐私边界",
            font: .systemFont(ofSize: 22, weight: .semibold)
        )
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(
            label(
                "Rime 同步生成候选；语义模型只通过当前用户私有的 Unix "
                    + "Domain Socket 运行。默认不记录原始按键、上下文或完整句子。",
                secondary: true
            )
        )

        aiToggle.title = "启用本地语义候选"
        aiToggle.target = self
        aiToggle.action = #selector(toggleChanged(_:))
        stack.addArrangedSubview(aiToggle)

        offlineToggle.title =
            "Offline Lock（开发者预览强制开启：daemon 禁止 IPv4 / IPv6 socket）"
        offlineToggle.isEnabled = false
        stack.addArrangedSubview(offlineToggle)

        let contextRow = NSStackView()
        contextRow.orientation = .horizontal
        contextRow.spacing = 10
        contextRow.addArrangedSubview(label("上下文模式"))
        contextPopup.addItems(
            withTitles: [
                "严格：仅拼音与候选",
                "标准：当前应用最近上屏 100 字",
                "智能：显式读取光标前最多 400 字",
            ]
        )
        contextPopup.target = self
        contextPopup.action = #selector(contextChanged(_:))
        contextRow.addArrangedSubview(contextPopup)
        stack.addArrangedSubview(contextRow)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("应用级策略"))
        stack.addArrangedSubview(
            label(
                "完全禁用 AI 的 Bundle ID（逗号分隔，精确匹配）",
                secondary: true
            )
        )
        disabledAIField.placeholderString =
            "例如：com.example.PasswordManager"
        disabledAIField.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(disabledAIField)
        disabledAIField.widthAnchor.constraint(
            equalTo: stack.widthAnchor
        ).isActive = true
        stack.addArrangedSubview(
            label(
                "仅禁用上下文的 Bundle ID（AI 退化为严格模式）",
                secondary: true
            )
        )
        disabledContextField.placeholderString = "例如：com.example.Terminal"
        disabledContextField.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(disabledContextField)
        disabledContextField.widthAnchor.constraint(
            equalTo: stack.widthAnchor
        ).isActive = true
        let savePolicies = NSButton(
            title: "保存应用策略",
            target: self,
            action: #selector(saveApplicationPolicies(_:))
        )
        stack.addArrangedSubview(savePolicies)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("本地模型与运行状态"))
        for statusLabel in [
            daemonStatusLabel,
            modelLabel,
            artifactLabel,
            dataSizeLabel,
        ] {
            configureWrapping(statusLabel)
            stack.addArrangedSubview(statusLabel)
        }

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("无原文诊断"))
        configureWrapping(diagnosticsLabel)
        stack.addArrangedSubview(diagnosticsLabel)
        let dataButtons = NSStackView()
        dataButtons.orientation = .horizontal
        dataButtons.spacing = 8
        dataButtons.addArrangedSubview(
            NSButton(
                title: "清除短期上下文",
                target: self,
                action: #selector(clearEphemeralData(_:))
            )
        )
        dataButtons.addArrangedSubview(
            NSButton(
                title: "重置诊断计数",
                target: self,
                action: #selector(resetDiagnostics(_:))
            )
        )
        dataButtons.addArrangedSubview(
            NSButton(
                title: "导出设置…",
                target: self,
                action: #selector(exportSettings(_:))
            )
        )
        dataButtons.addArrangedSubview(
            NSButton(
                title: "停用 AI 并清除本地制品…",
                target: self,
                action: #selector(clearAllProductData(_:))
            )
        )
        stack.addArrangedSubview(dataButtons)
        stack.addArrangedSubview(
            label(
                "清除操作会将 AI 模型、daemon 与 LaunchAgent 移到废纸篓，"
                    + "但不修改 Rime 用户词典；当前预览版没有云端同步、"
                    + "遥测、在线模型下载或持久个性化学习。",
                secondary: true
            )
        )
    }

    private func observeState() {
        daemonObserver = NotificationCenter.default.addObserver(
            forName: .rimeAIDaemonStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.applyDaemonStatus(notification)
            }
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .rimeAISettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    private func refresh() {
        aiToggle.state = settings.aiEnabled ? .on : .off
        offlineToggle.state = settings.offlineLockEnabled ? .on : .off
        contextPopup.selectItem(
            at: [
                ContextPolicy.strict: 0,
                ContextPolicy.standard: 1,
                ContextPolicy.smart: 2,
            ][settings.contextPolicy] ?? 1
        )
        disabledAIField.stringValue =
            settings.disabledAIApplications.joined(separator: ", ")
        disabledContextField.stringValue =
            settings.disabledContextApplications.joined(separator: ", ")
        diagnosticsLabel.stringValue = diagnosticsDescription()
        dataSizeLabel.stringValue = dataSizeDescription()
        if !settings.aiEnabled {
            daemonStatusLabel.stringValue =
                "Daemon：已停用 · 重新开启 AI 后按需加载"
        }
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        if sender === aiToggle {
            settings.aiEnabled = sender.state == .on
            if sender.state == .off {
                settings.clearEphemeralData()
                DaemonClient.shared.disconnect()
            }
            setManagedDaemonEnabled(sender.state == .on)
        }
    }

    @objc private func contextChanged(_ sender: NSPopUpButton) {
        settings.contextPolicy = [
            ContextPolicy.strict,
            ContextPolicy.standard,
            ContextPolicy.smart,
        ][max(0, min(sender.indexOfSelectedItem, 2))]
        settings.clearEphemeralData()
    }

    @objc private func saveApplicationPolicies(_ sender: Any?) {
        settings.disabledAIApplications = splitApplications(
            disabledAIField.stringValue
        )
        settings.disabledContextApplications = splitApplications(
            disabledContextField.stringValue
        )
        settings.clearEphemeralData()
        refresh()
    }

    @objc private func clearEphemeralData(_ sender: Any?) {
        settings.clearEphemeralData()
    }

    @objc private func resetDiagnostics(_ sender: Any?) {
        settings.resetDiagnostics()
    }

    @objc private func exportSettings(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "RimeAI-settings.json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [settings] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys,
                .withoutEscapingSlashes,
            ]
            guard let data = try? encoder.encode(settings.exportSnapshot())
            else {
                return
            }
            try? data.write(to: url, options: .atomic)
        }
    }

    @objc private func clearAllProductData(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "停用 AI 并清除本地制品？"
        alert.informativeText =
            "将停止 daemon，把模型、服务文件、运行文件和 LaunchAgent "
                + "移到废纸篓，并清除设置、诊断计数和短期上下文。"
                + "Rime 用户词典不会被修改；恢复 AI 需要重新安装。"
        alert.addButton(withTitle: "停用并移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            self?.disableAIAndTrashManagedData()
        }
    }

    private func disableAIAndTrashManagedData() {
        DaemonClient.shared.disconnect()
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try Self.stopManagedDaemon(layout: layout)
                try Self.trashManagedData(layout: layout)
            }
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                switch result {
                case .success:
                    self.settings.resetAllProductData()
                    self.settings.aiEnabled = false
                    self.daemonStatusLabel.stringValue =
                        "Daemon：已停用 · Internet socket：不存在"
                    self.modelLabel.stringValue = "模型制品：已移到废纸篓"
                    self.artifactLabel.stringValue =
                        "重新安装开发者预览版后可恢复本地 AI。"
                    self.refresh()
                case let .failure(error):
                    let failure = NSAlert(error: error)
                    failure.messageText = "未能完整清除 RimeAI 本地制品"
                    failure.informativeText =
                        "部分项目可能已经移到废纸篓；Rime 用户词典未被修改。"
                    failure.beginSheetModal(for: self.window)
                }
            }
        }
    }

    private func setManagedDaemonEnabled(_ enabled: Bool) {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        daemonStatusLabel.stringValue =
            enabled ? "Daemon：正在启动" : "Daemon：正在停止"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                if enabled {
                    try Self.startManagedDaemon(layout: layout)
                } else {
                    try Self.suspendManagedDaemon(layout: layout)
                }
            }
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                switch result {
                case .success:
                    if enabled {
                        DaemonClient.shared.connect()
                    } else {
                        self.daemonStatusLabel.stringValue =
                            "Daemon：已停用 · 模型资源已释放"
                    }
                case let .failure(error):
                    if enabled {
                        self.settings.aiEnabled = false
                    }
                    self.daemonStatusLabel.stringValue =
                        "Daemon：生命周期操作失败"
                    let failure = NSAlert(error: error)
                    failure.messageText = enabled
                        ? "未能启动 RimeAI daemon"
                        : "未能完整停止 RimeAI daemon"
                    failure.beginSheetModal(for: self.window)
                }
            }
        }
    }

    private func applyDaemonStatus(_ notification: Notification) {
        guard settings.aiEnabled else {
            daemonStatusLabel.stringValue =
                "Daemon：已停用 · 模型资源已释放"
            return
        }
        let status = notification.userInfo?["status"] as? String ?? "未知"
        let artifactID =
            notification.userInfo?["model_artifact_id"] as? String
            ?? "尚未加载"
        let artifacts =
            notification.userInfo?["model_artifacts"]
                as? [DaemonModelArtifact]
            ?? []
        let enforced =
            notification.userInfo?["offline_lock"] as? Bool
            ?? false
        daemonStatusLabel.stringValue =
            "Daemon：\(status) · Internet socket 拦截："
            + (enforced ? "已生效" : "未确认")
        modelLabel.stringValue = "模型制品：\(artifactID)"
        artifactLabel.stringValue = artifacts.isEmpty
            ? "文件与校验值：等待 daemon 握手"
            : artifacts.map {
                "\($0.role)：\($0.path)\nSHA-256 \($0.sha256)"
            }.joined(separator: "\n")
    }

    private func diagnosticsDescription() -> String {
        let diagnostics = settings.diagnosticSnapshot()
        guard !diagnostics.isEmpty else {
            return "尚无诊断计数（不会保存原始输入文本）"
        }
        return diagnostics.keys.sorted().map {
            "\($0)：\(diagnostics[$0, default: 0])"
        }.joined(separator: " · ")
    }

    private func dataSizeDescription() -> String {
        let layout = RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let managedBytes = layout.managedDataURLs.reduce(0) {
            $0 + dataSize(at: $1)
        }
        let rimeBytes = dataSize(at: layout.rimeUserDataDirectory)
        return "AI 服务与模型：\(formatted(bytes: managedBytes)) · "
            + "Rime 用户数据（清除时保留）：\(formatted(bytes: rimeBytes))"
    }

    private func dataSize(at root: URL) -> Int64 {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
        ]
        guard FileManager.default.fileExists(atPath: root.path) else {
            return 0
        }
        if let values = try? root.resourceValues(forKeys: resourceKeys),
           values.isRegularFile == true
        {
            return Int64(values.fileSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(
                    forKeys: resourceKeys
                ),
                values.isRegularFile == true
            else {
                continue
            }
            bytes += Int64(values.fileSize ?? 0)
        }
        return bytes
    }

    private func formatted(bytes: Int64) -> String {
        return ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }

    nonisolated private static func stopManagedDaemon(
        layout: RimeAIProductDataLayout
    ) throws {
        _ = try runProcess(
            executable: "/bin/launchctl",
            arguments: [
            "bootout",
            "gui/\(getuid())/fun.wwcn.rimeai.daemon",
            ]
        )
        try stopAdHocDaemon(layout: layout)
    }

    nonisolated private static func suspendManagedDaemon(
        layout: RimeAIProductDataLayout
    ) throws {
        if FileManager.default.fileExists(
            atPath: layout.daemonEnabledMarker.path
        ) {
            try FileManager.default.removeItem(
                at: layout.daemonEnabledMarker
            )
        }
        _ = try runProcess(
            executable: "/bin/launchctl",
            arguments: [
                "kill",
                "SIGTERM",
                "gui/\(getuid())/fun.wwcn.rimeai.daemon",
            ]
        )
        try stopAdHocDaemon(layout: layout)
    }

    nonisolated private static func startManagedDaemon(
        layout: RimeAIProductDataLayout
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(
            atPath: layout.launchAgentPlist.path
        ) else {
            throw NSError(
                domain: "fun.wwcn.inputmethod.RimeAI.daemon-lifecycle",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "LaunchAgent is missing; reinstall RimeAI",
                ]
            )
        }
        try fileManager.createDirectory(
            at: layout.controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard fileManager.createFile(
            atPath: layout.daemonEnabledMarker.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw lifecycleError(
                "could not create the local AI enable marker",
                code: 4
            )
        }
        let domain = "gui/\(getuid())"
        let printStatus = try runProcess(
            executable: "/bin/launchctl",
            arguments: [
                "print",
                "\(domain)/fun.wwcn.rimeai.daemon",
            ]
        )
        if printStatus != 0 {
            let bootstrapStatus = try runProcess(
                executable: "/bin/launchctl",
                arguments: [
                    "bootstrap",
                    domain,
                    layout.launchAgentPlist.path,
                ]
            )
            guard bootstrapStatus == 0 else {
                throw lifecycleError(
                    "launchctl could not bootstrap the daemon",
                    code: Int(bootstrapStatus)
                )
            }
        }
        let kickstartStatus = try runProcess(
            executable: "/bin/launchctl",
            arguments: [
                "kickstart",
                "\(domain)/fun.wwcn.rimeai.daemon",
            ]
        )
        guard kickstartStatus == 0 else {
            throw lifecycleError(
                "launchctl could not start the daemon",
                code: Int(kickstartStatus)
            )
        }
        let socket = layout.runtimeDirectory
            .appendingPathComponent("rimeai.sock")
        for _ in 0..<80 {
            if fileManager.fileExists(atPath: socket.path) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw lifecycleError(
            "daemon did not create its private socket",
            code: 3
        )
    }

    nonisolated private static func stopAdHocDaemon(
        layout: RimeAIProductDataLayout
    ) throws {

        let pidPath = layout.runtimeDirectory
            .appendingPathComponent("rimeai-daemon.pid")
        guard
            let rawPID = try? String(contentsOf: pidPath, encoding: .utf8),
            let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 1,
            kill(pid, 0) == 0
        else {
            return
        }
        let ps = Process()
        let output = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", "\(pid)", "-o", "command="]
        ps.standardOutput = output
        ps.standardError = Pipe()
        try ps.run()
        ps.waitUntilExit()
        let command = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let socketPath = layout.runtimeDirectory
            .appendingPathComponent("rimeai.sock")
            .path
        guard command.contains("rimeai_daemon"),
              command.contains(socketPath)
        else {
            throw NSError(
                domain: "fun.wwcn.inputmethod.RimeAI.data-lifecycle",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "refused to stop an unrelated process",
                ]
            )
        }
        if kill(pid, SIGTERM) != 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            )
        }
    }

    nonisolated private static func runProcess(
        executable: String,
        arguments: [String]
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    nonisolated private static func lifecycleError(
        _ description: String,
        code: Int
    ) -> NSError {
        NSError(
            domain: "fun.wwcn.inputmethod.RimeAI.daemon-lifecycle",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    nonisolated private static func trashManagedData(
        layout: RimeAIProductDataLayout
    ) throws {
        let fileManager = FileManager.default
        for url in layout.managedDataURLs where
            fileManager.fileExists(atPath: url.path)
        {
            try fileManager.trashItem(
                at: url,
                resultingItemURL: nil
            )
        }
    }

    private func splitApplications(_ value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private func sectionTitle(_ value: String) -> NSTextField {
        label(value, font: .systemFont(ofSize: 15, weight: .semibold))
    }

    private func label(
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

    private func configureWrapping(_ field: NSTextField) {
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
    }

    private func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 600).isActive = true
        return separator
    }
}
