import Foundation
import Network
import os

/// 传输层连接诊断（LM-002 验证插桩）：failConnection 的具体原因
/// 经 unified log 可被 `log stream --predicate 'subsystem == "fun.wwcn.rimeai"'` 抓取。
private let ndjsonTransportLog = Logger(
    subsystem: "fun.wwcn.rimeai",
    category: "ndjson-transport"
)

/// NDJSON 行组装器：把字节流按换行符（`0x0A`）切成完整行，
/// 并对未换行的残留缓冲施加上限。纯值类型，无锁。
struct NDJSONLineAssembler: Sendable {
    private(set) var buffer = Data()
    private let maximumLineBytes: Int

    init(maximumLineBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
    }

    struct Assembly: Equatable, Sendable {
        /// 本次新完成的非空行，按到达顺序排列。
        var lines: [Data] = []
        /// 残留缓冲（无换行结尾）是否已超过上限。
        var isOverLimit = false
    }

    /// 追加字节并提取所有完整行。空行按协议忽略。
    mutating func append(_ data: Data) -> Assembly {
        buffer.append(data)
        var assembly = Assembly()
        let newline = UInt8(ascii: "\n")
        while let index = buffer.firstIndex(of: newline) {
            let line = Data(buffer[..<index])
            buffer.removeSubrange(...index)
            guard !line.isEmpty else {
                continue
            }
            assembly.lines.append(line)
        }
        assembly.isOverLimit = buffer.count > maximumLineBytes
        return assembly
    }

    mutating func removeAll() {
        buffer.removeAll(keepingCapacity: false)
    }
}

/// 待发帧队列：握手完成前的 FIFO 缓冲，支持按请求撤回。
/// 纯值类型，由传输层队列串行化。
struct NDJSONOutboundQueue: Sendable {
    private(set) var frames: [NDJSONUDSTransport.OutboundFrame] = []

    var isEmpty: Bool { frames.isEmpty }

    mutating func enqueue(data: Data, requestID: String?) {
        frames.append(
            NDJSONUDSTransport.OutboundFrame(
                requestID: requestID,
                data: data
            )
        )
    }

    /// 撤回指定请求仍在队列中的帧，返回是否确有帧被移除
    /// （调用方据此决定是否补发线上 cancel）。
    @discardableResult
    mutating func removeFrames(requestID: String) -> Bool {
        let before = frames.count
        frames.removeAll { $0.requestID == requestID }
        return frames.count != before
    }

    /// 取出全部待发帧，保留容量以便复用。
    mutating func drain() -> [NDJSONUDSTransport.OutboundFrame] {
        let drained = frames
        frames.removeAll(keepingCapacity: true)
        return drained
    }

    mutating func removeAll() {
        frames.removeAll(keepingCapacity: false)
    }
}

/// NDJSON-over-UDS 共享传输层。
///
/// 抽取自 DaemonClient / CloudBrokerClient 重复实现的连接管线：
/// 连接生命周期与代际计数、换行行分帧、1 MiB 接收上限、重连、
/// 队列化串行发送、握手前直发通道以及超时调度。协议级握手
/// （hello/ready 交换、熔断、请求配对与状态通知）由上层客户端完成。
///
/// 线程模型与被替换的客户端一致：全部可变状态都限制在 `queue`
/// 上，事件回调也在 `queue` 上同步派发。公开方法必须在
/// `queue` 上调用（方法内部带 `dispatchPrecondition` 断言）；
/// 调用方应把该队列当作自己的串行队列使用。
public final class NDJSONUDSTransport: @unchecked Sendable {
    /// 连接被传输层主动关闭的原因。客户端据此映射自身的
    /// 用户可见状态字符串。
    public enum CloseReason: Equatable, Sendable {
        /// NWConnection 进入 `.failed` / `.cancelled`。
        case connectFailed
        /// 在 `connectTimeoutMilliseconds` 内未进入 `.ready`。
        case connectTimedOut
        /// 连接建立后收到错误或 EOF。
        case connectionLost
        /// 握手帧（`sendImmediate`）发送失败。
        case handshakeSendFailed
        /// 已放行的应用帧发送失败。
        case applicationSendFailed
        /// 未换行的缓冲超过 `maximumLineBytes`。
        case lineTooLarge
    }

    /// 传输层事件，全部携带产生它的连接代际。
    public enum Event: Sendable {
        /// 底层连接就绪，可以发送握手帧（`sendImmediate`）。
        case connectionReady(generation: UInt64)
        /// 收到一条完整且非空的 NDJSON 行。
        case lineReceived(generation: UInt64, line: Data)
        /// 传输层因 `CloseReason` 拆除当前代连接。
        case connectionClosed(generation: UInt64, reason: CloseReason)
    }

    /// 待发帧。`requestID` 用于上层按请求撤回尚未发出的帧；
    /// 控制帧（如 cancel）不携带请求 ID。
    public struct OutboundFrame: Equatable, Sendable {
        public let requestID: String?
        public let data: Data
    }

    public struct Configuration: Sendable {
        /// UDS 套接字路径。
        public var socketPath: String
        /// 传输层串行队列的标签；调用方复用该队列。
        public var queueLabel: String
        /// 连接建立超时（毫秒）。`nil` 表示不启用（云端客户端行为）。
        public var connectTimeoutMilliseconds: Int?
        /// 未换行接收缓冲的上限，超出即按 `lineTooLarge` 断开。
        public var maximumLineBytes: Int
        /// 单次 `receive` 的最大字节数。
        public var receiveChunkBytes: Int

        public init(
            socketPath: String,
            queueLabel: String,
            connectTimeoutMilliseconds: Int? = nil,
            maximumLineBytes: Int = 1_048_576,
            receiveChunkBytes: Int = 65_536
        ) {
            self.socketPath = socketPath
            self.queueLabel = queueLabel
            self.connectTimeoutMilliseconds = connectTimeoutMilliseconds
            self.maximumLineBytes = maximumLineBytes
            self.receiveChunkBytes = receiveChunkBytes
        }
    }

    /// 传输层串行队列。所有公开方法都必须在该队列上调用，
    /// 事件回调也在该队列上派发。
    public let queue: DispatchQueue

    private let configuration: Configuration
    private var eventHandler: (@Sendable (Event) -> Void)?

    private enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
    }

    private var connection: NWConnection?
    private var generation: UInt64 = 0
    private var phase: Phase = .disconnected
    /// 上层协议握手完成标志。只有握手完成后应用帧才允许发出。
    private var protocolReady = false
    private var lineAssembler = NDJSONLineAssembler(maximumLineBytes: 1)
    private var outbound = NDJSONOutboundQueue()
    private var connectTimeout: DispatchWorkItem?

    public init(
        configuration: Configuration,
        eventHandler: (@Sendable (Event) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.eventHandler = eventHandler
        queue = DispatchQueue(label: configuration.queueLabel)
        lineAssembler = NDJSONLineAssembler(
            maximumLineBytes: configuration.maximumLineBytes
        )
    }

    /// 注册或替换事件回调。可在任意线程调用：注册块在该队列上
    /// 排队，先于之后经由该队列发起的任何连接动作生效。适合
    /// 持有方在自身初始化完成后再绑定回调（构造期捕获尚未完成
    /// 初始化的 self 是不被编译器允许的）。
    public func setEventHandler(_ handler: (@Sendable (Event) -> Void)?) {
        queue.async { [weak self] in
            self?.eventHandler = handler
        }
    }

    // MARK: - 连接生命周期

    /// 建立连接；若当前代连接仍存活则直接复用并返回其代际。
    /// 每次真正的重建都会使代际加一，调用方可用于配对等待。
    @discardableResult
    public func open() -> UInt64 {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .disconnected, connection == nil else {
            return generation
        }
        generation += 1
        let newGeneration = generation
        phase = .connecting
        protocolReady = false
        let connection = NWConnection(
            to: .unix(path: configuration.socketPath),
            using: .tcp
        )
        self.connection = connection
        if let timeoutMilliseconds =
            configuration.connectTimeoutMilliseconds
        {
            armConnectTimeout(
                milliseconds: timeoutMilliseconds,
                generation: newGeneration
            )
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else {
                return
            }
            self.queue.async {
                self.handle(
                    state: state,
                    connection: connection,
                    generation: newGeneration
                )
            }
        }
        connection.start(queue: queue)
        return newGeneration
    }

    /// 拆除当前连接并清空接收缓冲与待发队列。幂等；由调用方
    /// 负责发布自身的状态通知。不会派发 `connectionClosed` 事件。
    public func close() {
        dispatchPrecondition(condition: .onQueue(queue))
        tearDownConnection()
    }

    /// 是否存在未拆除的连接（连接中或已就绪）。
    public var hasActiveConnection: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return phase != .disconnected
    }

    /// 当前连接代际。
    public var currentGeneration: UInt64 {
        dispatchPrecondition(condition: .onQueue(queue))
        return generation
    }

    // MARK: - 发送

    /// 应用帧是否已被允许发出（底层连接就绪且上层握手已完成）。
    public var canSendApplicationFrames: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return phase == .connected && protocolReady
    }

    /// 声明上层协议握手完成：打开发送闸门并立刻冲刷缓冲帧。
    public func markProtocolReady() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard phase == .connected else {
            return
        }
        protocolReady = true
        flushOutbound()
    }

    /// 绕过握手闸门直发一帧（hello 等握手帧专用）。
    /// 发送失败按 `handshakeSendFailed` 拆除连接。
    public func sendImmediate(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let connection, phase == .connected else {
            return
        }
        sendFrame(
            data,
            on: connection,
            failureReason: .handshakeSendFailed
        )
    }

    /// 追加一帧到待发队列；仅在 `flushOutbound` 且闸门开启时发出。
    public func enqueueOutbound(data: Data, requestID: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        outbound.enqueue(data: data, requestID: requestID)
    }

    /// 撤回指定请求仍在队列中的帧。
    /// 返回是否确有帧被移除（调用方据此决定是否补发线上 cancel）。
    @discardableResult
    public func removeOutboundFrames(requestID: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return outbound.removeFrames(requestID: requestID)
    }

    /// 闸门开启时按 FIFO 串行发出全部缓冲帧。
    public func flushOutbound() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard canSendApplicationFrames, let connection else {
            return
        }
        for frame in outbound.drain() {
            sendFrame(
                frame.data,
                on: connection,
                failureReason: .applicationSendFailed
            )
        }
    }

    // MARK: - 超时调度

    /// 在传输队列上安排一次性超时任务，返回可取消的 work item。
    /// 供上层实现握手超时与按请求的到期过期。
    @discardableResult
    public func scheduleTimeout(
        afterMilliseconds milliseconds: Int,
        execute work: @escaping @Sendable () -> Void
    ) -> DispatchWorkItem {
        dispatchPrecondition(condition: .onQueue(queue))
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(
            deadline: .now() + .milliseconds(milliseconds),
            execute: item
        )
        return item
    }

    // MARK: - 内部实现

    /// 在指定连接上发出一帧；发送失败时若该连接仍是当前代，
    /// 按 `failureReason` 拆除。迟到的错误回调由连接身份与
    /// 代际双重过滤。
    private func sendFrame(
        _ data: Data,
        on connection: NWConnection,
        failureReason: CloseReason
    ) {
        let sendGeneration = generation
        connection.send(
            content: data,
            completion: .contentProcessed {
                [weak self, weak connection] error in
                guard error != nil,
                      let self,
                      let connection
                else {
                    return
                }
                self.queue.async {
                    guard self.connection === connection,
                          self.generation == sendGeneration,
                          self.phase != .disconnected
                    else {
                        return
                    }
                    self.failConnection(
                        generation: sendGeneration,
                        reason: failureReason
                    )
                }
            }
        )
    }

    private func armConnectTimeout(
        milliseconds: Int,
        generation timeoutGeneration: UInt64
    ) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.queue.async {
                guard self.generation == timeoutGeneration,
                      self.phase == .connecting
                else {
                    return
                }
                self.failConnection(
                    generation: timeoutGeneration,
                    reason: .connectTimedOut
                )
            }
        }
        connectTimeout = work
        queue.asyncAfter(
            deadline: .now() + .milliseconds(milliseconds),
            execute: work
        )
    }

    private func handle(
        state: NWConnection.State,
        connection: NWConnection,
        generation eventGeneration: UInt64
    ) {
        guard self.connection === connection,
              generation == eventGeneration,
              phase != .disconnected
        else {
            return
        }
        switch state {
        case .ready:
            connectTimeout?.cancel()
            connectTimeout = nil
            phase = .connected
            eventHandler?(.connectionReady(generation: eventGeneration))
            // 上层可能同步拆除了本代连接（如握手编码失败），
            // 此时不能再对旧连接启动接收循环。
            guard self.connection === connection,
                  generation == eventGeneration,
                  phase != .disconnected
            else {
                return
            }
            receiveNext(on: connection, generation: eventGeneration)
        case let .failed(error):
            ndjsonTransportLog.notice(
                "nw state failed: \(String(describing: error), privacy: .public)"
            )
            failConnection(
                generation: eventGeneration,
                reason: .connectFailed
            )
        case .cancelled:
            ndjsonTransportLog.notice("nw state cancelled (connect timeout arm)")
            failConnection(
                generation: eventGeneration,
                reason: .connectFailed
            )
        default:
            break
        }
    }

    private func receiveNext(
        on connection: NWConnection,
        generation eventGeneration: UInt64
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: configuration.receiveChunkBytes
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else {
                return
            }
            self.queue.async {
                guard self.connection === connection,
                      self.generation == eventGeneration,
                      self.phase != .disconnected
                else {
                    return
                }
                if let data, !data.isEmpty {
                    self.ingest(
                        data,
                        generation: eventGeneration
                    )
                }
                // 行处理可能同步失效本代连接（协议不兼容等）。
                // 不能让同一回调里的 EOF/错误对它二次拆除。
                guard self.connection === connection,
                      self.generation == eventGeneration,
                      self.phase != .disconnected
                else {
                    return
                }
                if error != nil || isComplete {
                    self.failConnection(
                        generation: eventGeneration,
                        reason: .connectionLost
                    )
                    return
                }
                self.receiveNext(
                    on: connection,
                    generation: eventGeneration
                )
            }
        }
    }

    private func ingest(_ data: Data, generation eventGeneration: UInt64) {
        let assembly = lineAssembler.append(data)
        for line in assembly.lines {
            eventHandler?(
                .lineReceived(generation: eventGeneration, line: line)
            )
            guard self.generation == eventGeneration,
                  self.phase != .disconnected
            else {
                return
            }
        }
        if assembly.isOverLimit {
            failConnection(generation: eventGeneration, reason: .lineTooLarge)
        }
    }

    private func failConnection(
        generation failedGeneration: UInt64,
        reason: CloseReason
    ) {
        guard generation == failedGeneration, phase != .disconnected else {
            return
        }
        ndjsonTransportLog.notice(
            "connection failed: generation=\(failedGeneration, privacy: .public) reason=\(String(describing: reason), privacy: .public)"
        )
        tearDownConnection()
        eventHandler?(
            .connectionClosed(
                generation: failedGeneration,
                reason: reason
            )
        )
    }

    private func tearDownConnection() {
        connectTimeout?.cancel()
        connectTimeout = nil
        let oldConnection = connection
        connection = nil
        phase = .disconnected
        protocolReady = false
        lineAssembler.removeAll()
        outbound.removeAll()
        oldConnection?.stateUpdateHandler = nil
        oldConnection?.cancel()
    }
}

public extension NDJSONUDSTransport.CloseReason {
    /// 客户端共享的用户可见状态文案（daemon 与 cloud-broker 两个
    /// 客户端原先各自维护一份逐字相同的映射）。
    var localizedStatusDescription: String {
        switch self {
        case .connectFailed:
            "连接失败"
        case .connectTimedOut:
            "连接建立超时"
        case .connectionLost:
            "连接中断"
        case .handshakeSendFailed:
            "握手发送失败"
        case .applicationSendFailed:
            "发送失败"
        case .lineTooLarge:
            "协议帧过大"
        }
    }
}
