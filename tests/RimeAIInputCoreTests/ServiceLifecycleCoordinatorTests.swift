import Darwin
import Foundation
import Testing
@testable import RimeAIInputCore

// MARK: - 测试替身与夹具

@MainActor
private final class LifecycleEventRecorder {
    private(set) var events: [ServiceLifecycleEvent] = []

    func record(_ event: ServiceLifecycleEvent) {
        events.append(event)
    }
}

/// 手动驱动的执行器：按全局发放序记录 completion，供测试逐步推进队列
/// 并重复触发历史 completion 以模拟迟到回调。
@MainActor
private final class ManualLifecycleExecutor {
    private(set) var started: [ServiceLifecycleOperation] = []
    private var issued: [(
        operation: ServiceLifecycleOperation,
        completion: ServiceLifecycleCompletion
    )] = []

    func handle(
        _ operation: ServiceLifecycleOperation,
        completion: @escaping ServiceLifecycleCompletion
    ) {
        started.append(operation)
        issued.append((operation, completion))
    }

    func operation(at index: Int) -> ServiceLifecycleOperation? {
        guard issued.indices.contains(index) else {
            return nil
        }
        return issued[index].operation
    }

    func completion(at index: Int) -> ServiceLifecycleCompletion? {
        guard issued.indices.contains(index) else {
            return nil
        }
        return issued[index].completion
    }

    func complete(_ index: Int, with result: Result<Void, Error>) {
        completion(at: index)?(result)
    }
}

/// 自动完成的执行器：按操作预设结果，未预设视为成功。
@MainActor
private final class AutoLifecycleExecutor {
    private(set) var started: [ServiceLifecycleOperation] = []
    var results: [ServiceLifecycleOperation: Result<Void, Error>] = [:]

    func handle(
        _ operation: ServiceLifecycleOperation,
        completion: @escaping ServiceLifecycleCompletion
    ) {
        started.append(operation)
        completion(results[operation] ?? .success(()))
    }
}

private struct ServiceLifecycleTestError: LocalizedError, Equatable {
    let message: String

    var errorDescription: String? {
        message
    }
}

/// 线程安全的进程调用记录器：按调用顺序返回预设退出码，耗尽后返回 0。
private final class LaunchctlCallRecorder: @unchecked Sendable {
    struct Call: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var statuses: [Int32]

    init(statuses: [Int32] = []) {
        self.statuses = statuses
    }

    func call(
        _ executable: String,
        _ arguments: [String]
    ) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        calls.append(Call(executable: executable, arguments: arguments))
        if statuses.isEmpty {
            return 0
        }
        return statuses.removeFirst()
    }

    var recorded: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var runner: ServiceLifecycleProcessRunner {
        { try self.call($0, $1) }
    }
}

private func launchctl(_ arguments: [String]) -> LaunchctlCallRecorder.Call {
    LaunchctlCallRecorder.Call(
        executable: "/bin/launchctl",
        arguments: arguments
    )
}

private enum ServiceLifecycleTestSupport {
    static var guiDaemonService: String {
        "gui/\(getuid())/fun.wwcn.rimeai.daemon"
    }

    static var guiCloudBrokerService: String {
        "gui/\(getuid())/fun.wwcn.rimeai.cloud-broker"
    }

    static func makeTemporaryLayout() throws -> (
        layout: RimeAIProductDataLayout,
        home: URL
    ) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rimeai-service-lifecycle-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        return (RimeAIProductDataLayout(homeDirectory: home), home)
    }

    static func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data()
            )
        )
    }

    static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func removeHome(_ home: URL) {
        try? FileManager.default.removeItem(at: home)
    }
}

// MARK: - 收敛状态机

@MainActor
@Suite("Service lifecycle convergence")
struct ServiceLifecycleConvergenceTests {
    private func makeManualHarness() -> (
        coordinator: ServiceLifecycleCoordinator,
        executor: ManualLifecycleExecutor,
        recorder: LifecycleEventRecorder
    ) {
        let executor = ManualLifecycleExecutor()
        let recorder = LifecycleEventRecorder()
        let coordinator = ServiceLifecycleCoordinator(
            eventHandler: { recorder.record($0) },
            performOperation: { operation, completion in
                executor.handle(operation, completion: completion)
            }
        )
        return (coordinator, executor, recorder)
    }

    private func makeAutoHarness() -> (
        coordinator: ServiceLifecycleCoordinator,
        executor: AutoLifecycleExecutor,
        recorder: LifecycleEventRecorder
    ) {
        let executor = AutoLifecycleExecutor()
        let recorder = LifecycleEventRecorder()
        let coordinator = ServiceLifecycleCoordinator(
            eventHandler: { recorder.record($0) },
            performOperation: { operation, completion in
                executor.handle(operation, completion: completion)
            }
        )
        return (coordinator, executor, recorder)
    }

    @Test("reconcile 按冻结的收敛顺序执行队列")
    func frozenConvergenceOrder() {
        struct OrderingRow {
            let operations: [ServiceLifecycleOperation]
            let services: [String]
        }
        let rows: [OrderingRow] = [
            OrderingRow(
                operations: [.daemon(true)],
                services: ["daemon"]
            ),
            OrderingRow(
                operations: [
                    .voiceHelper(false), .cloudBroker(false), .daemon(false),
                ],
                services: ["语音 helper", "云端 broker", "daemon"]
            ),
            OrderingRow(
                operations: [
                    .daemon(true), .cloudBroker(true), .voiceHelper(true),
                ],
                services: ["daemon", "云端 broker", "语音 helper"]
            ),
            OrderingRow(
                operations: [
                    .voiceHelper(false), .daemon(true), .cloudBroker(true),
                ],
                services: ["语音 helper", "daemon", "云端 broker"]
            ),
        ]
        for row in rows {
            let (coordinator, executor, recorder) = makeAutoHarness()

            coordinator.reconcile(row.operations, description: "本轮收敛")

            #expect(executor.started == row.operations)
            #expect(recorder.events == [
                .started(
                    description: "本轮收敛",
                    services: row.services
                ),
                .succeeded(
                    description: "本轮收敛",
                    applied: row.operations
                ),
            ])
            #expect(!coordinator.isReconciling)
        }
    }

    @Test("运行中的 reconcile 被拒绝为 busy 且不破坏当前队列")
    func busyRejectionKeepsActiveQueueIntact() {
        let (coordinator, executor, recorder) = makeManualHarness()

        coordinator.reconcile(
            [.daemon(false), .cloudBroker(false)],
            description: "第一轮"
        )
        #expect(executor.started == [.daemon(false)])
        #expect(recorder.events == [
            .started(
                description: "第一轮",
                services: ["daemon", "云端 broker"]
            ),
        ])

        coordinator.reconcile([.voiceHelper(true)], description: "第二轮")
        #expect(recorder.events.count == 2)
        #expect(recorder.events.last == .busy)
        #expect(coordinator.isReconciling)
        #expect(executor.started == [.daemon(false)])

        executor.complete(0, with: .success(()))
        #expect(executor.started == [.daemon(false), .cloudBroker(false)])
        executor.complete(1, with: .success(()))
        #expect(recorder.events.count == 3)
        #expect(recorder.events.last == .succeeded(
            description: "第一轮",
            applied: [.daemon(false), .cloudBroker(false)]
        ))
        #expect(!coordinator.isReconciling)
    }

    @Test("被新一轮取代的旧 completion 不推进当前队列")
    func staleCompletionFromSupersededRunIsDropped() {
        let (coordinator, executor, recorder) = makeManualHarness()

        coordinator.reconcile([.daemon(true)], description: "旧轮")
        #expect(executor.operation(at: 0) == .daemon(true))
        executor.complete(0, with: .success(()))
        #expect(recorder.events.last == .succeeded(
            description: "旧轮",
            applied: [.daemon(true)]
        ))

        coordinator.reconcile(
            [.cloudBroker(true), .voiceHelper(true)],
            description: "新轮"
        )
        #expect(executor.started == [.daemon(true), .cloudBroker(true)])
        #expect(recorder.events.count == 3)

        // 旧轮的 completion 再次触发（模拟迟到回调）：generation 已失效，
        // 既不能产生新事件，也不能推进或重放当前队列。
        executor.complete(0, with: .failure(
            ServiceLifecycleTestError(message: "迟到回调")
        ))
        #expect(recorder.events.count == 3)
        #expect(coordinator.isReconciling)
        #expect(executor.started == [.daemon(true), .cloudBroker(true)])

        executor.complete(1, with: .success(()))
        executor.complete(2, with: .success(()))
        #expect(recorder.events.last == .succeeded(
            description: "新轮",
            applied: [.cloudBroker(true), .voiceHelper(true)]
        ))
        #expect(!coordinator.isReconciling)
    }

    @Test("单个服务失败继续队列并报告回退")
    func singleServiceFailureContinuesQueueAndReportsRollback() {
        struct FailureRow {
            let label: String
            let operations: [ServiceLifecycleOperation]
            let failing: [ServiceLifecycleOperation: String]
            let initialFailures: [ServiceLifecycleFailure]
            let expectedFailures: [ServiceLifecycleFailure]
        }
        let rows: [FailureRow] = [
            FailureRow(
                label: "中间服务失败后队列继续",
                operations: [
                    .daemon(true), .cloudBroker(true), .voiceHelper(true),
                ],
                failing: [.cloudBroker(true): "broker 未能创建私有 socket"],
                initialFailures: [],
                expectedFailures: [
                    ServiceLifecycleFailure(
                        service: "云端 broker",
                        error: "broker 未能创建私有 socket"
                    ),
                ]
            ),
            FailureRow(
                label: "首个服务失败不阻断后续服务",
                operations: [
                    .voiceHelper(false), .cloudBroker(false), .daemon(false),
                ],
                failing: [.voiceHelper(false): "语音 helper 停止失败"],
                initialFailures: [],
                expectedFailures: [
                    ServiceLifecycleFailure(
                        service: "语音 helper",
                        error: "语音 helper 停止失败"
                    ),
                ]
            ),
            FailureRow(
                label: "全部操作成功但初始失败仍报告回退",
                operations: [.cloudBroker(false)],
                failing: [:],
                initialFailures: [
                    ServiceLifecycleFailure(
                        service: "API Key",
                        error: "凭据文件无法删除"
                    ),
                ],
                expectedFailures: [
                    ServiceLifecycleFailure(
                        service: "API Key",
                        error: "凭据文件无法删除"
                    ),
                ]
            ),
        ]
        for row in rows {
            let (coordinator, executor, recorder) = makeAutoHarness()
            for (operation, message) in row.failing {
                let failure: Result<Void, Error> = .failure(
                    ServiceLifecycleTestError(message: message)
                )
                executor.results[operation] = failure
            }

            coordinator.reconcile(
                row.operations,
                description: row.label,
                initialFailures: row.initialFailures
            )

            #expect(executor.started == row.operations)
            #expect(recorder.events == [
                .started(
                    description: row.label,
                    services: row.operations.map(\.displayName)
                ),
                .failed(
                    description: row.label,
                    failures: row.expectedFailures
                ),
            ])
            #expect(!coordinator.isReconciling)
        }
    }

    @Test("空操作集短路完成且不触发执行器")
    func emptyOperationSetShortCircuits() {
        let (coordinator, executor, recorder) = makeAutoHarness()

        coordinator.reconcile([], description: "无需变更")

        #expect(
            recorder.events == [.alreadyConsistent(description: "无需变更")]
        )
        #expect(executor.started.isEmpty)
        #expect(!coordinator.isReconciling)
    }

    @Test("独占生命周期区段阻塞 reconcile 直到显式解除")
    func exclusiveSectionBlocksReconcile() {
        let (coordinator, executor, recorder) = makeAutoHarness()

        coordinator.setReconciling(true)
        coordinator.reconcile([.daemon(true)], description: "独占期间")
        #expect(recorder.events == [.busy])
        #expect(executor.started.isEmpty)
        #expect(coordinator.isReconciling)

        coordinator.setReconciling(false)
        coordinator.reconcile([.daemon(true)], description: "独占结束")
        #expect(executor.started == [.daemon(true)])
        #expect(recorder.events.last == .succeeded(
            description: "独占结束",
            applied: [.daemon(true)]
        ))
    }
}

// MARK: - 启动向量（print/bootstrap/kickstart 与失败回滚）

@Suite("Managed service launchctl start vectors")
struct ManagedServiceLaunchctlStartTests {
    struct ManagedStartSpec {
        let label: String
        let statuses: [Int32]
        let bootstrapExpected: Bool
        let expectMarker: Bool
        let expectedErrorCode: Int?
    }

    /// 期望向量按真实 fixture 的 plist 路径构建：print（→ 视状态 bootstrap）
    /// → kickstart；kickstart 失败时追加回滚 kill SIGTERM。
    private func expectedCalls(
        for spec: ManagedStartSpec,
        service: String,
        bootstrapPlistPath: String
    ) -> [LaunchctlCallRecorder.Call] {
        var calls = [launchctl(["print", service])]
        if spec.bootstrapExpected {
            calls.append(launchctl([
                "bootstrap", "gui/\(getuid())", bootstrapPlistPath,
            ]))
        }
        calls.append(launchctl(["kickstart", service]))
        if spec.expectedErrorCode != nil {
            calls.append(launchctl(["kill", "SIGTERM", service]))
        }
        return calls
    }

    private func assertStartOutcome(
        _ spec: ManagedStartSpec,
        recorder: LaunchctlCallRecorder,
        markerURL: URL,
        invoke: () throws -> Void
    ) {
        do {
            try invoke()
            #expect(spec.expectedErrorCode == nil)
        } catch {
            let nsError = error as NSError
            #expect(nsError.code == spec.expectedErrorCode)
            #expect(
                nsError.domain
                    == "fun.wwcn.inputmethod.RimeAI.daemon-lifecycle"
            )
        }
        #expect(
            ServiceLifecycleTestSupport.fileExists(markerURL)
                == spec.expectMarker
        )
    }

    @Test("startManagedDaemon 逐字保留 print/bootstrap/kickstart 向量")
    func startManagedDaemonVectors() throws {
        let specs: [ManagedStartSpec] = [
            ManagedStartSpec(
                label: "已加载时只 kickstart",
                statuses: [],
                bootstrapExpected: false,
                expectMarker: true,
                expectedErrorCode: nil
            ),
            ManagedStartSpec(
                label: "未加载时先 bootstrap",
                statuses: [113, 0, 0],
                bootstrapExpected: true,
                expectMarker: true,
                expectedErrorCode: nil
            ),
            ManagedStartSpec(
                label: "kickstart 失败回滚为挂起并清理 marker",
                statuses: [0, 9],
                bootstrapExpected: false,
                expectMarker: false,
                expectedErrorCode: 9
            ),
        ]
        for spec in specs {
            let fixture = try ServiceLifecycleTestSupport.makeTemporaryLayout()
            defer { ServiceLifecycleTestSupport.removeHome(fixture.home) }
            try ServiceLifecycleTestSupport.touch(
                fixture.layout.launchAgentPlist
            )
            let recorder = LaunchctlCallRecorder(statuses: spec.statuses)

            assertStartOutcome(
                spec,
                recorder: recorder,
                markerURL: fixture.layout.daemonEnabledMarker
            ) {
                try ServiceLifecycleCoordinator.startManagedDaemon(
                    layout: fixture.layout,
                    processRunner: recorder.runner,
                    socketExists: { _ in true }
                )
            }

            #expect(recorder.recorded == expectedCalls(
                for: spec,
                service: ServiceLifecycleTestSupport.guiDaemonService,
                bootstrapPlistPath: fixture.layout.launchAgentPlist.path
            ))
        }
    }

    @Test("startManagedCloudBroker 逐字保留 print/bootstrap/kickstart 向量")
    func startManagedCloudBrokerVectors() throws {
        let specs: [ManagedStartSpec] = [
            ManagedStartSpec(
                label: "已加载时只 kickstart",
                statuses: [],
                bootstrapExpected: false,
                expectMarker: true,
                expectedErrorCode: nil
            ),
            ManagedStartSpec(
                label: "未加载时先 bootstrap",
                statuses: [113, 0, 0],
                bootstrapExpected: true,
                expectMarker: true,
                expectedErrorCode: nil
            ),
            ManagedStartSpec(
                label: "kickstart 失败时 kill SIGTERM 并清理 marker",
                statuses: [0, 7],
                bootstrapExpected: false,
                expectMarker: false,
                expectedErrorCode: 7
            ),
        ]
        for spec in specs {
            let fixture = try ServiceLifecycleTestSupport.makeTemporaryLayout()
            defer { ServiceLifecycleTestSupport.removeHome(fixture.home) }
            try ServiceLifecycleTestSupport.touch(
                fixture.layout.cloudBrokerLaunchAgentPlist
            )
            let recorder = LaunchctlCallRecorder(statuses: spec.statuses)

            assertStartOutcome(
                spec,
                recorder: recorder,
                markerURL: fixture.layout.cloudBrokerEnabledMarker
            ) {
                try ServiceLifecycleCoordinator.startManagedCloudBroker(
                    layout: fixture.layout,
                    processRunner: recorder.runner,
                    socketExists: { _ in true }
                )
            }

            #expect(recorder.recorded == expectedCalls(
                for: spec,
                service: ServiceLifecycleTestSupport.guiCloudBrokerService,
                bootstrapPlistPath:
                    fixture.layout.cloudBrokerLaunchAgentPlist.path
            ))
        }
    }
}

// MARK: - 其余 launchctl 期望态操作与进程执行器

@Suite("Managed service launchctl operations")
struct ManagedServiceLaunchctlTests {

    @Test("suspendManagedDaemon 保留 kill 向量并移除启用 marker")
    func suspendManagedDaemonVectors() throws {
        let fixture = try ServiceLifecycleTestSupport.makeTemporaryLayout()
        defer { ServiceLifecycleTestSupport.removeHome(fixture.home) }
        try ServiceLifecycleTestSupport.touch(
            fixture.layout.daemonEnabledMarker
        )

        let recorder = LaunchctlCallRecorder()
        try ServiceLifecycleCoordinator.suspendManagedDaemon(
            layout: fixture.layout,
            processRunner: recorder.runner
        )

        #expect(recorder.recorded == [
            launchctl([
                "kill", "SIGTERM", ServiceLifecycleTestSupport.guiDaemonService,
            ]),
        ])
        #expect(
            !ServiceLifecycleTestSupport.fileExists(
                fixture.layout.daemonEnabledMarker
            )
        )
    }

    @Test("suspendManagedDaemon 在 launchctl kill 失败时收集关闭失败")
    func suspendManagedDaemonCollectsLaunchctlFailure() throws {
        let fixture = try ServiceLifecycleTestSupport.makeTemporaryLayout()
        defer { ServiceLifecycleTestSupport.removeHome(fixture.home) }
        try ServiceLifecycleTestSupport.touch(
            fixture.layout.daemonEnabledMarker
        )

        let recorder = LaunchctlCallRecorder(statuses: [5])
        #expect(throws: ServiceDaemonDeactivationError.self) {
            try ServiceLifecycleCoordinator.suspendManagedDaemon(
                layout: fixture.layout,
                processRunner: recorder.runner
            )
        }

        #expect(recorder.recorded == [
            launchctl([
                "kill", "SIGTERM", ServiceLifecycleTestSupport.guiDaemonService,
            ]),
        ])
        #expect(
            !ServiceLifecycleTestSupport.fileExists(
                fixture.layout.daemonEnabledMarker
            )
        )
    }

    @Test("stopManagedDaemon 只执行 bootout 且无 pid 文件时不启动 ps")
    func stopManagedDaemonVectors() throws {
        let fixture = try ServiceLifecycleTestSupport.makeTemporaryLayout()
        defer { ServiceLifecycleTestSupport.removeHome(fixture.home) }

        let recorder = LaunchctlCallRecorder()
        try ServiceLifecycleCoordinator.stopManagedDaemon(
            layout: fixture.layout,
            processRunner: recorder.runner
        )

        #expect(recorder.recorded == [
            launchctl(["bootout", ServiceLifecycleTestSupport.guiDaemonService]),
        ])
    }

    @Test("suspendManagedCloudBroker 先移除 marker 再 kill SIGTERM")
    func suspendManagedCloudBrokerVectors() throws {
        let fixture = try ServiceLifecycleTestSupport.makeTemporaryLayout()
        defer { ServiceLifecycleTestSupport.removeHome(fixture.home) }
        try ServiceLifecycleTestSupport.touch(
            fixture.layout.cloudBrokerEnabledMarker
        )

        let recorder = LaunchctlCallRecorder()
        try ServiceLifecycleCoordinator.suspendManagedCloudBroker(
            layout: fixture.layout,
            processRunner: recorder.runner
        )

        #expect(recorder.recorded == [
            launchctl([
                "kill",
                "SIGTERM",
                ServiceLifecycleTestSupport.guiCloudBrokerService,
            ]),
        ])
        #expect(
            !ServiceLifecycleTestSupport.fileExists(
                fixture.layout.cloudBrokerEnabledMarker
            )
        )
    }

    @Test("stopManagedCloudBroker bootout 后移除启用 marker")
    func stopManagedCloudBrokerVectors() throws {
        let fixture = try ServiceLifecycleTestSupport.makeTemporaryLayout()
        defer { ServiceLifecycleTestSupport.removeHome(fixture.home) }
        try ServiceLifecycleTestSupport.touch(
            fixture.layout.cloudBrokerEnabledMarker
        )

        let recorder = LaunchctlCallRecorder()
        try ServiceLifecycleCoordinator.stopManagedCloudBroker(
            layout: fixture.layout,
            processRunner: recorder.runner
        )

        #expect(recorder.recorded == [
            launchctl([
                "bootout",
                ServiceLifecycleTestSupport.guiCloudBrokerService,
            ]),
        ])
        #expect(
            !ServiceLifecycleTestSupport.fileExists(
                fixture.layout.cloudBrokerEnabledMarker
            )
        )
    }

    @Test("缺 LaunchAgent plist 时启动操作立即失败且不调用 launchctl")
    func missingPlistsFailFast() throws {
        let fixture = try ServiceLifecycleTestSupport.makeTemporaryLayout()
        defer { ServiceLifecycleTestSupport.removeHome(fixture.home) }

        let daemonRecorder = LaunchctlCallRecorder()
        #expect(throws: NSError.self) {
            try ServiceLifecycleCoordinator.startManagedDaemon(
                layout: fixture.layout,
                processRunner: daemonRecorder.runner,
                socketExists: { _ in true }
            )
        }
        #expect(daemonRecorder.recorded.isEmpty)

        let cloudRecorder = LaunchctlCallRecorder()
        #expect(throws: NSError.self) {
            try ServiceLifecycleCoordinator.startManagedCloudBroker(
                layout: fixture.layout,
                processRunner: cloudRecorder.runner,
                socketExists: { _ in true }
            )
        }
        #expect(cloudRecorder.recorded.isEmpty)
    }

    @Test("默认进程执行器只返回退出码")
    func defaultProcessRunnerReturnsExitStatus() throws {
        #expect(
            try ServiceLifecycleProcess.run(
                executable: "/usr/bin/true",
                arguments: []
            ) == 0
        )
        #expect(
            try ServiceLifecycleProcess.run(
                executable: "/usr/bin/false",
                arguments: []
            ) == 1
        )
    }

    @Test("socket 节点探测不把普通文件或缺席路径当 socket")
    func socketNodeRejectsNonSockets() throws {
        let fixture = try ServiceLifecycleTestSupport.makeTemporaryLayout()
        defer { ServiceLifecycleTestSupport.removeHome(fixture.home) }
        let regularFile = fixture.layout.controlDirectory
            .appendingPathComponent("regular", isDirectory: false)
        try ServiceLifecycleTestSupport.touch(regularFile)

        #expect(!ServiceLifecycleSocketNode.exists(at: regularFile))
        #expect(!ServiceLifecycleSocketNode.exists(
            at: fixture.layout.runtimeDirectory
                .appendingPathComponent("absent.sock", isDirectory: false)
        ))
    }

    @Test("daemon 关闭错误保留逐项失败描述")
    func deactivationErrorDescription() {
        let error = ServiceDaemonDeactivationError(failures: [
            ServiceDaemonDeactivationFailure(
                step: .stopLaunchAgent,
                description:
                    "launchctl kill returned 5; daemon runtime state is uncertain"
            ),
        ])
        #expect(
            error.errorDescription
                == "Daemon 关闭未完整完成，运行态不确定："
                    + "停止 launchd job："
                    + "launchctl kill returned 5; daemon runtime state is uncertain"
        )
        #expect(
            ServiceDaemonLaunchAgentStopError(status: 5).errorDescription
                == "launchctl kill returned 5; daemon runtime state is uncertain"
        )
    }
}
