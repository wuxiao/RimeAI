import Darwin
import Foundation

// MARK: - 期望态操作模型

/// 单个受管服务（daemon / cloud broker / 语音 helper）的期望态操作。
///
/// 与设置窗口的 `SettingsRuntimeOperation` 一一对应：设置窗口侧保留 UI
/// 与偏好回写；本模块承载纯粹的生命周期收敛。语音 helper 本轮仍由
/// `VoiceHelperLifecycleCoordinator` 经注入的执行器完成，该 case 先进入
/// 统一模型，后续可直接并入同一收敛队列。
public enum ServiceLifecycleOperation: Hashable, Sendable {
    case daemon(Bool)
    case cloudBroker(Bool)
    case voiceHelper(Bool)

    public var displayName: String {
        switch self {
        case .daemon:
            return "daemon"
        case .cloudBroker:
            return "云端 broker"
        case .voiceHelper:
            return "语音 helper"
        }
    }
}

/// 单个服务收敛失败的展示记录（服务名 + 本地化错误描述）。
public struct ServiceLifecycleFailure: Equatable, Sendable {
    public let service: String
    public let error: String

    public init(service: String, error: String) {
        self.service = service
        self.error = error
    }
}

public typealias ServiceLifecycleCompletion = @MainActor @Sendable (
    Result<Void, Error>
) -> Void

/// 收敛队列的单步执行器。宿主注入 daemon / cloud / voice 的具体编排
/// （客户端连接、偏好回写与 UI 状态）；队列顺序、generation 失效与失败
/// 收集全部由 coordinator 负责。
public typealias ServiceLifecycleOperationHandler = @MainActor @Sendable (
    ServiceLifecycleOperation,
    @escaping ServiceLifecycleCompletion
) -> Void

// MARK: - 面向宿主 UI 的语义事件

/// 供设置窗口翻译为状态文案与告警的语义事件；本模块不依赖 AppKit。
public enum ServiceLifecycleEvent: Equatable, Sendable {
    /// 收敛被拒绝：另一个生命周期操作仍在进行。
    case busy
    /// 队列为空：认证运行态与期望状态一致，直接短路完成。
    case alreadyConsistent(description: String)
    /// 队列开始：按冻结顺序同步 services。
    case started(description: String, services: [String])
    /// 队列完成且无失败；applied 为本轮实际执行的操作。
    case succeeded(
        description: String,
        applied: [ServiceLifecycleOperation]
    )
    /// 队列完成但存在失败；失败项由执行器保持或回退为关闭偏好。
    case failed(
        description: String,
        failures: [ServiceLifecycleFailure]
    )
}

public typealias ServiceLifecycleEventHandler = @MainActor @Sendable (
    ServiceLifecycleEvent
) -> Void

// MARK: - 收敛状态机

/// 服务生命周期的运行态收敛状态机：generation 计数、按序操作队列与失败
/// 收集。收敛顺序由调用方按冻结语义给定（停止 voice → cloud → daemon，
/// 启动 daemon → cloud → voice）；单个服务失败不中断队列，由执行器把
/// 失败服务回退为关闭偏好。
@MainActor
public final class ServiceLifecycleCoordinator {
    private let emitEvent: ServiceLifecycleEventHandler
    private let performOperation: ServiceLifecycleOperationHandler

    private var generation: UInt64 = 0
    private var pendingOperations: [ServiceLifecycleOperation] = []
    private var activeOperations: [ServiceLifecycleOperation] = []
    private var failures: [ServiceLifecycleFailure] = []
    private var runDescription = ""

    /// 是否有生命周期收敛（或宿主声明的独占生命周期操作）正在进行。
    public private(set) var isReconciling = false

    public init(
        eventHandler: @escaping ServiceLifecycleEventHandler,
        performOperation: @escaping ServiceLifecycleOperationHandler
    ) {
        self.emitEvent = eventHandler
        self.performOperation = performOperation
    }

    /// 提交一轮收敛。正在进行时发出 `.busy`；空队列短路发出
    /// `.alreadyConsistent`；否则发出 `.started` 后按队列顺序执行，
    /// 结束时按是否收集到失败发出 `.succeeded` / `.failed`。
    public func reconcile(
        _ operations: [ServiceLifecycleOperation],
        description: String,
        initialFailures: [ServiceLifecycleFailure] = []
    ) {
        guard !isReconciling else {
            emitEvent(.busy)
            return
        }
        generation &+= 1
        if generation == 0 {
            generation = 1
        }
        pendingOperations = operations
        activeOperations = pendingOperations
        failures = initialFailures
        runDescription = description
        guard !pendingOperations.isEmpty else {
            activeOperations = []
            isReconciling = false
            emitEvent(.alreadyConsistent(description: description))
            return
        }
        isReconciling = true
        emitEvent(.started(
            description: description,
            services: pendingOperations.map(\.displayName)
        ))
        runNextOperation(runGeneration: generation)
    }

    /// 供“清除全部产品数据”等不走收敛队列的独占生命周期操作占用同一
    /// 互斥。与既有行为一致：只置忙，不推进 generation。
    public func setReconciling(_ inProgress: Bool) {
        isReconciling = inProgress
    }

    private func runNextOperation(runGeneration: UInt64) {
        guard runGeneration == generation else {
            return
        }
        guard !pendingOperations.isEmpty else {
            isReconciling = false
            if failures.isEmpty {
                emitEvent(.succeeded(
                    description: runDescription,
                    applied: activeOperations
                ))
            } else {
                emitEvent(.failed(
                    description: runDescription,
                    failures: failures
                ))
            }
            activeOperations = []
            return
        }
        let next = pendingOperations.removeFirst()
        performOperation(next) { [weak self] result in
            guard let self,
                  runGeneration == self.generation
            else {
                return
            }
            if case let .failure(error) = result {
                self.failures.append(ServiceLifecycleFailure(
                    service: next.displayName,
                    error: error.localizedDescription
                ))
            }
            self.runNextOperation(runGeneration: runGeneration)
        }
    }
}

// MARK: - launchctl 进程执行

/// 子进程执行器（默认为真实 `Process`）。测试可注入录制实现以逐字断言
/// launchctl 参数向量。
public typealias ServiceLifecycleProcessRunner = @Sendable (
    _ executable: String,
    _ arguments: [String]
) throws -> Int32

public enum ServiceLifecycleProcess {
    /// 默认执行器：stdout/stderr 接入无人读取的 Pipe，只返回退出码
    /// （与原设置窗口实现逐字一致）。
    public static func run(
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
}

// MARK: - 共享的小型生命周期原语

/// 只确认文件系统节点类型是 socket；它不证明存在监听者或能通过认证
/// 协议握手。
public enum ServiceLifecycleSocketNode {
    public static func exists(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeSocket
    }
}

/// marker 先行、失败回滚的启用事务：回滚本身失败是必须上抛的
/// fail-closed 错误，不能留下已布防的启用 marker。
public enum ServiceLifecycleMarkerTransaction {
    public static func run(
        createMarker: () throws -> Void,
        rollbackMarker: () throws -> Void,
        operation: () throws -> Void
    ) throws {
        try createMarker()
        do {
            try operation()
        } catch let operationError {
            do {
                try rollbackMarker()
            } catch let rollbackError {
                // A rollback failure is the actionable fail-closed error: the
                // caller must not leave an enable marker silently armed.
                throw rollbackError
            }
            throw operationError
        }
    }
}

public enum ServiceDaemonDeactivationStep: String, Equatable, Sendable {
    case removeMarker = "删除启用 marker"
    case stopLaunchAgent = "停止 launchd job"
    case stopAdHocProcess = "停止 ad-hoc daemon"
}

public struct ServiceDaemonDeactivationFailure: Equatable, Sendable {
    public let step: ServiceDaemonDeactivationStep
    public let description: String

    public init(
        step: ServiceDaemonDeactivationStep,
        description: String
    ) {
        self.step = step
        self.description = description
    }
}

public struct ServiceDaemonDeactivationError: Error, Equatable, Sendable {
    public let failures: [ServiceDaemonDeactivationFailure]

    public init(failures: [ServiceDaemonDeactivationFailure]) {
        self.failures = failures
    }
}

extension ServiceDaemonDeactivationError: LocalizedError {
    public var errorDescription: String? {
        let details = failures.map {
            "\($0.step.rawValue)：\($0.description)"
        }.joined(separator: "；")
        return "Daemon 关闭未完整完成，运行态不确定：\(details)"
    }
}

public struct ServiceDaemonLaunchAgentStopError: Error, Equatable, Sendable {
    public let status: Int32

    public init(status: Int32) {
        self.status = status
    }
}

extension ServiceDaemonLaunchAgentStopError: LocalizedError {
    public var errorDescription: String? {
        "launchctl kill returned \(status); daemon runtime state is uncertain"
    }
}

/// daemon 关闭的尽力而为策略：逐项执行并收集失败，最终统一上抛。
public enum ServiceDaemonDeactivationPolicy {
    public typealias Operation = (
        step: ServiceDaemonDeactivationStep,
        perform: () throws -> Void
    )

    public static func requireSuccessfulLaunchctlKill(
        _ status: Int32
    ) throws {
        guard status == 0 else {
            throw ServiceDaemonLaunchAgentStopError(status: status)
        }
    }

    public static func run(_ operations: [Operation]) throws {
        var failures: [ServiceDaemonDeactivationFailure] = []
        for operation in operations {
            do {
                try operation.perform()
            } catch {
                failures.append(ServiceDaemonDeactivationFailure(
                    step: operation.step,
                    description: error.localizedDescription
                ))
            }
        }
        if !failures.isEmpty {
            throw ServiceDaemonDeactivationError(failures: failures)
        }
    }
}

// MARK: - 受管 daemon / cloud broker 的 launchctl 期望态操作

extension ServiceLifecycleCoordinator {
    /// 停止受管 daemon：bootout LaunchAgent 并处理 ad-hoc 进程。
    /// launchctl 参数向量与 stdout/stderr 处理自设置窗口原实现逐字保留。
    public nonisolated static func stopManagedDaemon(
        layout: RimeAIProductDataLayout,
        processRunner: @escaping ServiceLifecycleProcessRunner =
            ServiceLifecycleProcess.run
    ) throws {
        _ = try processRunner(
            "/bin/launchctl",
            [
                "bootout",
                "gui/\(getuid())/fun.wwcn.rimeai.daemon",
            ]
        )
        try stopAdHocDaemon(layout: layout)
    }

    /// 停止受管 cloud broker：bootout LaunchAgent 并移除启用 marker。
    public nonisolated static func stopManagedCloudBroker(
        layout: RimeAIProductDataLayout,
        processRunner: @escaping ServiceLifecycleProcessRunner =
            ServiceLifecycleProcess.run
    ) throws {
        _ = try processRunner(
            "/bin/launchctl",
            [
                "bootout",
                "gui/\(getuid())/fun.wwcn.rimeai.cloud-broker",
            ]
        )
        if FileManager.default.fileExists(
            atPath: layout.cloudBrokerEnabledMarker.path
        ) {
            try FileManager.default.removeItem(
                at: layout.cloudBrokerEnabledMarker
            )
        }
    }

    /// 挂起受管 cloud broker：移除启用 marker 后 kill SIGTERM。
    public nonisolated static func suspendManagedCloudBroker(
        layout: RimeAIProductDataLayout,
        processRunner: @escaping ServiceLifecycleProcessRunner =
            ServiceLifecycleProcess.run
    ) throws {
        if FileManager.default.fileExists(
            atPath: layout.cloudBrokerEnabledMarker.path
        ) {
            try FileManager.default.removeItem(
                at: layout.cloudBrokerEnabledMarker
            )
        }
        _ = try processRunner(
            "/bin/launchctl",
            [
                "kill",
                "SIGTERM",
                "gui/\(getuid())/fun.wwcn.rimeai.cloud-broker",
            ]
        )
    }

    /// 启动受管 cloud broker：确保 marker 与 LaunchAgent 就绪，kickstart
    /// 后等待私有 socket 节点出现；失败路径统一 kill SIGTERM 并清理 marker。
    public nonisolated static func startManagedCloudBroker(
        layout: RimeAIProductDataLayout,
        processRunner: @escaping ServiceLifecycleProcessRunner =
            ServiceLifecycleProcess.run,
        socketExists: @Sendable (URL) -> Bool = {
            ServiceLifecycleSocketNode.exists(at: $0)
        }
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(
            atPath: layout.cloudBrokerLaunchAgentPlist.path
        ) else {
            throw lifecycleError(
                "cloud broker LaunchAgent is missing; reinstall RimeAI",
                code: 20
            )
        }
        try fileManager.createDirectory(
            at: layout.controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard fileManager.createFile(
            atPath: layout.cloudBrokerEnabledMarker.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw lifecycleError(
                "could not create the cloud broker enable marker",
                code: 21
            )
        }
        do {
            let domain = "gui/\(getuid())"
            let label = "fun.wwcn.rimeai.cloud-broker"
            let printStatus = try processRunner(
                "/bin/launchctl",
                ["print", "\(domain)/\(label)"]
            )
            if printStatus != 0 {
                let bootstrapStatus = try processRunner(
                    "/bin/launchctl",
                    [
                        "bootstrap",
                        domain,
                        layout.cloudBrokerLaunchAgentPlist.path,
                    ]
                )
                guard bootstrapStatus == 0 else {
                    throw lifecycleError(
                        "launchctl could not bootstrap the cloud broker",
                        code: Int(bootstrapStatus)
                    )
                }
            }
            let kickstartStatus = try processRunner(
                "/bin/launchctl",
                ["kickstart", "\(domain)/\(label)"]
            )
            guard kickstartStatus == 0 else {
                throw lifecycleError(
                    "launchctl could not start the cloud broker",
                    code: Int(kickstartStatus)
                )
            }
            let socket = layout.runtimeDirectory
                .appendingPathComponent("rimeai-cloud.sock")
            for _ in 0..<40 {
                if socketExists(socket) {
                    // A socket node is only a launch milestone. Authenticated
                    // protocol readiness continues asynchronously in the
                    // client.
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw lifecycleError(
                "cloud broker did not create its private socket",
                code: 22
            )
        } catch {
            _ = try? processRunner(
                "/bin/launchctl",
                [
                    "kill",
                    "SIGTERM",
                    "gui/\(getuid())/fun.wwcn.rimeai.cloud-broker",
                ]
            )
            if fileManager.fileExists(
                atPath: layout.cloudBrokerEnabledMarker.path
            ) {
                try? fileManager.removeItem(
                    at: layout.cloudBrokerEnabledMarker
                )
            }
            throw error
        }
    }

    /// 挂起受管 daemon：移除启用 marker、kill SIGTERM LaunchAgent 并处理
    /// ad-hoc 进程；逐项尽力执行并统一收集失败。
    public nonisolated static func suspendManagedDaemon(
        layout: RimeAIProductDataLayout,
        processRunner: @escaping ServiceLifecycleProcessRunner =
            ServiceLifecycleProcess.run
    ) throws {
        try ServiceDaemonDeactivationPolicy.run([
            (.removeMarker, {
                if FileManager.default.fileExists(
                    atPath: layout.daemonEnabledMarker.path
                ) {
                    try FileManager.default.removeItem(
                        at: layout.daemonEnabledMarker
                    )
                }
            }),
            (.stopLaunchAgent, {
                let status = try processRunner(
                    "/bin/launchctl",
                    [
                        "kill",
                        "SIGTERM",
                        "gui/\(getuid())/fun.wwcn.rimeai.daemon",
                    ]
                )
                try ServiceDaemonDeactivationPolicy
                    .requireSuccessfulLaunchctlKill(status)
            }),
            (.stopAdHocProcess, {
                try stopAdHocDaemon(layout: layout)
            }),
        ])
    }

    /// 启动受管 daemon：marker 事务包裹 print/bootstrap/kickstart 与私有
    /// socket 节点等待；启动失败时回滚为挂起。
    public nonisolated static func startManagedDaemon(
        layout: RimeAIProductDataLayout,
        processRunner: @escaping ServiceLifecycleProcessRunner =
            ServiceLifecycleProcess.run,
        socketExists: @Sendable (URL) -> Bool = {
            ServiceLifecycleSocketNode.exists(at: $0)
        }
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
        try ServiceLifecycleMarkerTransaction.run(
            createMarker: {
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
            },
            rollbackMarker: {
                try suspendManagedDaemon(
                    layout: layout,
                    processRunner: processRunner
                )
            },
            operation: {
                let domain = "gui/\(getuid())"
                let printStatus = try processRunner(
                    "/bin/launchctl",
                    [
                        "print",
                        "\(domain)/fun.wwcn.rimeai.daemon",
                    ]
                )
                if printStatus != 0 {
                    let bootstrapStatus = try processRunner(
                        "/bin/launchctl",
                        [
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
                let kickstartStatus = try processRunner(
                    "/bin/launchctl",
                    [
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
                    if socketExists(socket) {
                        // This deliberately does not claim daemon hello/ready;
                        // a typed generation-bound probe remains future work.
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                throw lifecycleError(
                    "daemon did not create its private socket",
                    code: 3
                )
            }
        )
    }

    private nonisolated static func stopAdHocDaemon(
        layout: RimeAIProductDataLayout
    ) throws {
        let pidPath = layout.runtimeDirectory
            .appendingPathComponent("rimeai-daemon.pid")
        guard
            let rawPID = try? String(contentsOf: pidPath, encoding: .utf8),
            let pid = Int32(
                rawPID.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
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

    private nonisolated static func lifecycleError(
        _ description: String,
        code: Int
    ) -> NSError {
        NSError(
            domain: "fun.wwcn.inputmethod.RimeAI.daemon-lifecycle",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
