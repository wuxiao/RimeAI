import Darwin
import CryptoKit
import Foundation

/// 管理语音 helper。Debug 使用开发安装器放在 Application Support 中的
/// bundle；Release 始终原位执行输入法 App 内独立签名的 nested helper，避免
/// 输入法与 helper 被分别升级。用户启用语音时才从签名资源渲染 LaunchAgent。
enum VoiceHelperLifecycle {
    static let label = "fun.wwcn.rimeai.voice-helper"
    private static let launchctlServiceNotFoundStatus: Int32 = 113

    private enum ServiceState: Equatable {
        case loaded
        case absent
    }

    enum InstallationStatus: Equatable {
        case notInstalled
        case disabled
        case starting
        /// helper 进程已经运行；认证 XPC 的业务 ready 仍由 Coordinator 确认。
        case running
    }

    static func installationStatus(
        layout: RimeAIProductDataLayout
    ) -> InstallationStatus {
        let fileManager = FileManager.default
        let executable = helperApplication(layout: layout)
            .appendingPathComponent(
                "Contents/MacOS/rimeai-voice-helper",
                isDirectory: false
            )
        guard fileManager.isExecutableFile(atPath: executable.path),
              launchAgentIsAvailable(layout: layout)
        else {
            return .notInstalled
        }
        var markerStatus = stat()
        guard lstat(layout.voiceEnabledMarker.path, &markerStatus) == 0 else {
            return .disabled
        }
        return isPrivateMarker(layout.voiceEnabledMarker.path)
            && isPrivateDirectory(layout.controlDirectory.path)
            && isPrivateDirectory(layout.runtimeDirectory.path)
            && transportRuntimeIsReady(layout: layout)
            && launchAgentIsRunning()
            ? .running
            : .starting
    }

    static func start(layout: RimeAIProductDataLayout) throws {
        let fileManager = FileManager.default
        do {
            let helperApplication = helperApplication(layout: layout)
            let launchAgentChanged = try ensureReleaseLaunchAgent(
                layout: layout,
                helperApplication: helperApplication
            )
            let executable = helperApplication
                .appendingPathComponent(
                    "Contents/MacOS/rimeai-voice-helper",
                    isDirectory: false
                )
            guard fileManager.isExecutableFile(atPath: executable.path),
                  fileManager.fileExists(
                      atPath: layout.voiceLaunchAgentPlist.path
                  )
            else {
                throw lifecycleError(
                    "语音 helper 尚未安装，请先重新安装 RimeAI 语音组件。",
                    code: 1
                )
            }
            guard Bundle(url: helperApplication)?.bundleIdentifier
                == label
            else {
                throw lifecycleError(
                    "语音 helper 的 bundle 标识不正确，拒绝启动。",
                    code: 2
                )
            }

            try ensurePrivateDirectory(
                layout.controlDirectory,
                errorCode: 3,
                description: "语音控制目录权限不安全。"
            )
            try ensurePrivateDirectory(
                layout.runtimeDirectory,
                errorCode: 4,
                description: "语音 runtime 目录权限不安全。"
            )
            try ensurePrivateMarker(layout.voiceEnabledMarker)

            if shouldReuseRunningReleaseService(
                launchAgentChanged: launchAgentChanged,
                transportReady: transportRuntimeIsReady(layout: layout),
                serviceRunning: launchAgentIsRunning()
            ) {
                return
            }

            let domain = "gui/\(getuid())"
            let service = "\(domain)/\(label)"
            if launchAgentChanged,
               try serviceState(domain: domain) == .loaded
            {
                let status = try runLaunchctl(["bootout", service])
                guard status == 0 else {
                    throw lifecycleError(
                        "launchctl 无法替换旧版语音 helper。",
                        code: Int(status)
                    )
                }
                for _ in 0..<20 {
                    if try serviceState(domain: domain) == .absent {
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                guard try serviceState(domain: domain) == .absent else {
                    throw lifecycleError(
                        "旧版语音 helper 在更新后仍未退出。",
                        code: 5
                    )
                }
            }
            let enableStatus = try runLaunchctl(["enable", service])
            guard enableStatus == 0 else {
                throw lifecycleError(
                    "launchctl 无法启用语音 helper。",
                    code: Int(enableStatus)
                )
            }
            if try serviceState(domain: domain) == .absent {
                let status = try runLaunchctl([
                    "bootstrap",
                    domain,
                    layout.voiceLaunchAgentPlist.path,
                ])
                guard status == 0 else {
                    throw lifecycleError(
                        "launchctl 无法加载语音 helper。",
                        code: Int(status)
                    )
                }
            }
            try removeDevelopmentSocketIfPresent(layout: layout)
            let kickstart = try runLaunchctl([
                "kickstart", "-k", service,
            ])
            guard kickstart == 0 else {
                throw lifecycleError(
                    "launchctl 无法启动语音 helper。",
                    code: Int(kickstart)
                )
            }

            for _ in 0..<50 {
                if isPrivateDirectory(layout.runtimeDirectory.path),
                   transportRuntimeIsReady(layout: layout),
                   launchAgentIsRunning()
                {
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw lifecycleError(
                "语音 helper 未进入可连接的运行状态。",
                code: 4
            )
        } catch let startError {
            do {
                try suspend(layout: layout)
            } catch let rollbackError {
                throw lifecycleError(
                    "\(startError.localizedDescription) 启动失败后的停用回滚也失败：\(rollbackError.localizedDescription)",
                    code: 6
                )
            }
            throw startError
        }
    }

    static func suspend(layout: RimeAIProductDataLayout) throws {
        let fileManager = FileManager.default
        var failures: [String] = []
        var markerStatus = stat()
        let markerResult = lstat(
            layout.voiceEnabledMarker.path,
            &markerStatus
        )
        if markerResult == 0 {
            do {
                try fileManager.removeItem(at: layout.voiceEnabledMarker)
            } catch {
                failures.append("无法删除语音启用标记：\(error.localizedDescription)")
            }
        } else if errno != ENOENT {
            failures.append("无法检查语音启用标记。")
        }

        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(label)"
        var serviceIsStopped = false
        do {
            switch try serviceState(domain: domain) {
            case .absent:
                serviceIsStopped = true
            case .loaded:
                let status = try runLaunchctl(["bootout", service])
                guard status == 0 else {
                    throw lifecycleError(
                        "launchctl 无法停止语音 helper。",
                        code: Int(status)
                    )
                }
                for _ in 0..<20 {
                    if try serviceState(domain: domain) == .absent {
                        serviceIsStopped = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                guard serviceIsStopped else {
                    throw lifecycleError(
                        "语音 helper 在 bootout 后仍未退出。",
                        code: 5
                    )
                }
            }
        } catch {
            failures.append(error.localizedDescription)
        }

        do {
            let status = try runLaunchctl(["disable", service])
            if status != 0 {
                failures.append("launchctl 无法禁止语音 helper 被按需启动。")
            }
        } catch {
            failures.append(error.localizedDescription)
        }

        if serviceIsStopped {
            var socketStatus = stat()
            let socketResult = lstat(layout.voiceSocket.path, &socketStatus)
            if socketResult == 0 {
                do {
                    try fileManager.removeItem(at: layout.voiceSocket)
                } catch {
                    failures.append(
                        "无法删除语音 socket：\(error.localizedDescription)"
                    )
                }
            } else if errno != ENOENT {
                failures.append("无法检查语音 socket。")
            }
        }
        guard failures.isEmpty else {
            throw lifecycleError(failures.joined(separator: " "), code: 7)
        }
    }

    private static func helperApplication(
        layout: RimeAIProductDataLayout
    ) -> URL {
#if DEBUG
        layout.voiceHelperApplication
#else
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(
                "RimeAIVoiceHelper.app",
                isDirectory: true
            )
#endif
    }

    private static func launchAgentIsAvailable(
        layout: RimeAIProductDataLayout
    ) -> Bool {
        if FileManager.default.fileExists(
            atPath: layout.voiceLaunchAgentPlist.path
        ) {
            return true
        }
#if DEBUG
        return false
#else
        return releaseResourceURL(
            named: "fun.wwcn.rimeai.voice-helper",
            extension: "plist"
        ) != nil
#endif
    }

    static func shouldReuseRunningReleaseService(
        launchAgentChanged: Bool,
        transportReady: Bool,
        serviceRunning: Bool
    ) -> Bool {
        !launchAgentChanged && transportReady && serviceRunning
    }

    /// Returns true when the on-disk LaunchAgent changed and a loaded job must
    /// be replaced before bootstrap. Debug keeps using the development
    /// installer and therefore performs no rendering here.
    private static func ensureReleaseLaunchAgent(
        layout: RimeAIProductDataLayout,
        helperApplication: URL
    ) throws -> Bool {
#if DEBUG
        return false
#else
        let policyData = try validateEmbeddedReleaseComponent(
            helperApplication: helperApplication
        )
        guard let templateURL = releaseResourceURL(
            named: "fun.wwcn.rimeai.voice-helper",
            extension: "plist"
        ) else {
            throw lifecycleError(
                "语音 LaunchAgent 模板不在签名发布包中。",
                code: 9
            )
        }
        let templateData = try Data(contentsOf: templateURL)
        guard let hostBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String,
              !hostBuild.isEmpty
        else {
            throw lifecycleError(
                "输入法构建版本缺失，拒绝启动语音 helper。",
                code: 9
            )
        }
        let rendered = try renderReleaseLaunchAgent(
            templateData: templateData,
            helperApplication: helperApplication,
            layout: layout,
            hostBuild: hostBuild,
            policySHA256: sha256Hex(policyData)
        )
        let fileManager = FileManager.default
        let destination = layout.voiceLaunchAgentPlist
        if let existing = try? Data(contentsOf: destination),
           existing == rendered
        {
            return false
        }
        var destinationStatus = stat()
        let destinationResult = lstat(destination.path, &destinationStatus)
        if destinationResult == 0 {
            guard destinationStatus.st_mode & mode_t(S_IFMT)
                == mode_t(S_IFREG)
            else {
                throw lifecycleError(
                    "语音 LaunchAgent 安装目标类型不安全。",
                    code: 9
                )
            }
        } else if errno != ENOENT {
            throw lifecycleError(
                "无法检查语音 LaunchAgent 安装目标。",
                code: 9
            )
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).installing.\(UUID().uuidString)",
                isDirectory: false
            )
        guard fileManager.createFile(
            atPath: staging.path,
            contents: rendered,
            attributes: [.posixPermissions: 0o644]
        ) else {
            throw lifecycleError(
                "无法暂存语音 LaunchAgent。",
                code: 9
            )
        }
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: staging.path
        )
        guard rename(staging.path, destination.path) == 0 else {
            throw lifecycleError(
                "无法原子安装语音 LaunchAgent。",
                code: Int(errno)
            )
        }
        return true
#endif
    }

    private static func releaseResourceURL(
        named name: String,
        extension pathExtension: String
    ) -> URL? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("VoiceHelper", isDirectory: true)
            .appendingPathComponent(
                "\(name).\(pathExtension)",
                isDirectory: false
            )
        else {
            return nil
        }
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            return nil
        }
        return url
    }

    private static func validateEmbeddedReleaseComponent(
        helperApplication: URL
    ) throws -> Data {
        let fileManager = FileManager.default
        let executable = helperApplication.appendingPathComponent(
            "Contents/MacOS/rimeai-voice-helper",
            isDirectory: false
        )
        guard fileManager.isExecutableFile(atPath: executable.path),
              let helperBundle = Bundle(url: helperApplication),
              helperBundle.bundleIdentifier == label,
              helperBundle.object(
                  forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String == Bundle.main.object(
                  forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              helperBundle.object(
                  forInfoDictionaryKey: "CFBundleVersion"
              ) as? String == Bundle.main.object(
                  forInfoDictionaryKey: "CFBundleVersion"
              ) as? String,
              let policyURL = releaseResourceURL(
                  named: "VoiceReleasePolicy",
                  extension: "plist"
              ),
              let policyData = regularFileData(at: policyURL),
              let helperPolicyData = regularFileData(
                  at: helperApplication
                      .appendingPathComponent(
                          "Contents/Resources/VoiceReleasePolicy.plist",
                          isDirectory: false
                      )
              ),
              policyData == helperPolicyData,
              releasePolicyIsFailClosed(policyData)
        else {
            throw lifecycleError(
                "内嵌语音组件的身份、版本或发布策略不匹配。",
                code: 9
            )
        }
        return policyData
    }

    static func renderReleaseLaunchAgent(
        templateData: Data,
        helperApplication: URL,
        layout: RimeAIProductDataLayout,
        hostBuild: String,
        policySHA256: String
    ) throws -> Data {
        let value = try PropertyListSerialization.propertyList(
            from: templateData,
            options: [],
            format: nil
        )
        let executable = helperApplication.appendingPathComponent(
            "Contents/MacOS/rimeai-voice-helper",
            isDirectory: false
        ).path
        let log = layout.runtimeDirectory.appendingPathComponent(
            "rimeai-voice-helper.log",
            isDirectory: false
        ).path
        let replacements = [
            "__HELPER_APP__": helperApplication.path,
            "__TRANSPORT_FLAG__": "--mach-service",
            "__TRANSPORT_ENDPOINT__": label,
            "__ENABLED_MARKER__": layout.voiceEnabledMarker.path,
            "__LOG_PATH__": log,
            "__HOST_BUILD__": hostBuild,
            "__VOICE_POLICY_SHA256__": policySHA256,
        ]
        var rendered = replaceTemplateValues(
            value,
            replacements: replacements
        )
        // Release helper 从自身签名 bundle 内的 VoiceReleasePolicy.plist
        // 选择引擎。删除模板中的开发 argv 槽位，避免用户级 LaunchAgent
        // 成为第二份可变策略。
        if var root = rendered as? [String: Any],
           let arguments = root["ProgramArguments"] as? [String]
        {
            root["ProgramArguments"] = arguments.filter {
                $0 != "__ENGINE_FLAG__" && $0 != "__ENGINE_NAME__"
            }
            rendered = root
        }
        guard validateRenderedLaunchAgent(
            rendered,
            executable: executable,
            marker: layout.voiceEnabledMarker.path,
            log: log,
            hostBuild: hostBuild,
            policySHA256: policySHA256
        ) else {
            throw lifecycleError(
                "语音 LaunchAgent 模板不符合发布合同。",
                code: 9
            )
        }
        return try PropertyListSerialization.data(
            fromPropertyList: rendered,
            format: .xml,
            options: 0
        )
    }

    static func releasePolicyIsFailClosed(_ data: Data) -> Bool {
        (try? VoiceReleasePolicy.decodeStrict(data)) != nil
    }

    private static func regularFileData(at url: URL) -> Data? {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            return nil
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func replaceTemplateValues(
        _ value: Any,
        replacements: [String: String]
    ) -> Any {
        if let string = value as? String {
            return replacements.reduce(string) { partial, entry in
                partial.replacingOccurrences(
                    of: entry.key,
                    with: entry.value
                )
            }
        }
        if let array = value as? [Any] {
            return array.map {
                replaceTemplateValues($0, replacements: replacements)
            }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                let key = replacements.reduce(entry.key) { partial, item in
                    partial.replacingOccurrences(
                        of: item.key,
                        with: item.value
                    )
                }
                result[key] = replaceTemplateValues(
                    entry.value,
                    replacements: replacements
                )
            }
        }
        return value
    }

    private static func validateRenderedLaunchAgent(
        _ value: Any,
        executable: String,
        marker: String,
        log: String,
        hostBuild: String,
        policySHA256: String
    ) -> Bool {
        guard let root = value as? [String: Any],
              !hostBuild.isEmpty,
              hostBuild.allSatisfy({ $0.isNumber }),
              policySHA256.utf8.count == 64,
              policySHA256.utf8.allSatisfy({ byte in
                  (byte >= 0x30 && byte <= 0x39)
                      || (byte >= 0x61 && byte <= 0x66)
              }),
              Set(root.keys) == Set([
                  "Label", "ProgramArguments", "MachServices", "RunAtLoad",
                  "KeepAlive", "ProcessType", "ThrottleInterval",
                  "StandardOutPath", "StandardErrorPath",
                  "EnvironmentVariables",
              ]),
              root["Label"] as? String == label,
              root["ProgramArguments"] as? [String] == [
                  executable,
                  "--mach-service",
                  label,
              ],
              root["MachServices"] as? [String: Bool] == [label: true],
              root["EnvironmentVariables"] as? [String: String] == [
                  "RIMEAI_PAIRED_BUILD": hostBuild,
                  "RIMEAI_VOICE_POLICY_SHA256": policySHA256,
              ],
              root["RunAtLoad"] as? Bool == false,
              root["ProcessType"] as? String == "Interactive",
              root["ThrottleInterval"] as? Int == 5,
              root["StandardOutPath"] as? String == log,
              root["StandardErrorPath"] as? String == log,
              let keepAlive = root["KeepAlive"] as? [String: Any],
              Set(keepAlive.keys) == ["PathState"],
              keepAlive["PathState"] as? [String: Bool] == [marker: true]
        else {
            return false
        }
        return true
    }

    private static func serviceState(domain: String) throws -> ServiceState {
        let status = try runLaunchctl(["print", "\(domain)/\(label)"])
        switch status {
        case 0:
            return .loaded
        case launchctlServiceNotFoundStatus:
            return .absent
        default:
            throw lifecycleError(
                "launchctl 无法确定语音 helper 是否已加载。",
                code: Int(status)
            )
        }
    }

    private static func runLaunchctl(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        // 这里只使用退出码；把输出导向 /dev/null，避免 launchctl print
        // 填满无人读取的 Pipe 后与 waitUntilExit 互相等待。
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func ensurePrivateDirectory(
        _ url: URL,
        errorCode: Int,
        description: String
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
            try removeExtendedACL(from: url)
        } catch {
            throw lifecycleError(description, code: errorCode)
        }
        guard isPrivateDirectory(url.path) else {
            throw lifecycleError(description, code: errorCode)
        }
    }

    private static func ensurePrivateMarker(_ url: URL) throws {
        let fileManager = FileManager.default
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard status.st_uid == geteuid(),
                  status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            else {
                throw lifecycleError(
                    "语音启用标记的类型或所有者不安全。",
                    code: 3
                )
            }
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
            } catch {
                throw lifecycleError("无法保护语音启用标记。", code: 3)
            }
        } else {
            guard fileManager.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw lifecycleError("无法创建语音启用标记。", code: 3)
            }
        }
        do {
            try removeExtendedACL(from: url)
        } catch {
            throw lifecycleError("无法保护语音启用标记。", code: 3)
        }
        guard isPrivateMarker(url.path) else {
            throw lifecycleError("语音启用标记权限不安全。", code: 3)
        }
    }

    private static func removeExtendedACL(from url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-N", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw lifecycleError("无法清除扩展 ACL。", code: 8)
        }
    }

    private static func isPrivateDirectory(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
            && status.st_uid == geteuid()
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && status.st_mode & mode_t(0o777) == mode_t(0o700)
            && pathHasNoExtendedACL(path)
    }

    private static func isPrivateMarker(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
            && status.st_uid == geteuid()
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && status.st_mode & mode_t(0o777) == mode_t(0o600)
            && pathHasNoExtendedACL(path)
    }

    private static func isPrivateSocket(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
            && status.st_uid == geteuid()
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
            && status.st_mode & mode_t(0o777) == mode_t(0o600)
            && pathHasNoExtendedACL(path)
    }

    private static func transportRuntimeIsReady(
        layout: RimeAIProductDataLayout
    ) -> Bool {
#if DEBUG
        isPrivateSocket(layout.voiceSocket.path)
#else
        true
#endif
    }

    private static func removeDevelopmentSocketIfPresent(
        layout: RimeAIProductDataLayout
    ) throws {
#if DEBUG
        if FileManager.default.fileExists(atPath: layout.voiceSocket.path) {
            try FileManager.default.removeItem(at: layout.voiceSocket)
        }
#endif
    }

    private static func pathHasNoExtendedACL(_ path: String) -> Bool {
        errno = 0
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT
        }
        acl_free(UnsafeMutableRawPointer(acl))
        return false
    }

    private static func launchAgentIsRunning() -> Bool {
        let domain = "gui/\(getuid())"
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "\(domain)/\(label)"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // 在等待退出前持续排空 stdout，避免大输出死锁。
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let description = String(data: data, encoding: .utf8)
            else {
                return false
            }
            return description.contains("state = running")
                && description.contains("pid =")
        } catch {
            return false
        }
    }

    private static func lifecycleError(
        _ description: String,
        code: Int
    ) -> NSError {
        NSError(
            domain: "fun.wwcn.inputmethod.RimeAI.voice-lifecycle",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

/// 进程内唯一的 helper desired-state 串行器。UserDefaults 是持久化真值；
/// marker/LaunchAgent 只是可恢复的执行态。所有设置操作与启动 reconcile
/// 共用同一队列和 generation，确保崩溃后的下一次启动最终收敛。
final class VoiceHelperLifecycleCoordinator: @unchecked Sendable {
    static let shared = VoiceHelperLifecycleCoordinator()

    private let queue = DispatchQueue(
        label: "fun.wwcn.inputmethod.RimeAI.voice-lifecycle",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var generation: UInt64 = 0

    private init() {}

    func setDesired(
        _ enabled: Bool,
        layout: RimeAIProductDataLayout,
        completion: @escaping @MainActor @Sendable (
            Result<Void, Error>
        ) -> Void
    ) {
        let expectedGeneration = advanceGeneration()
        queue.async { [weak self] in
            guard let self else {
                return
            }
            let result = Result {
                if enabled {
                    try VoiceHelperLifecycle.start(layout: layout)
                } else {
                    try VoiceHelperLifecycle.suspend(layout: layout)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.isCurrent(expectedGeneration)
                else {
                    return
                }
                MainActor.assumeIsolated {
                    completion(result)
                }
            }
        }
    }

    /// 清除所有产品数据时使用：先使所有旧 completion 失效，再等待队列
    /// 中已开始的 start，最后以 suspend 作为确定的终态。
    func suspendSynchronously(
        layout: RimeAIProductDataLayout
    ) throws {
        _ = advanceGeneration()
        try queue.sync {
            try VoiceHelperLifecycle.suspend(layout: layout)
        }
    }

    private func advanceGeneration() -> UInt64 {
        lock.lock()
        generation &+= 1
        let value = generation
        lock.unlock()
        return value
    }

    private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == expectedGeneration
    }
}
