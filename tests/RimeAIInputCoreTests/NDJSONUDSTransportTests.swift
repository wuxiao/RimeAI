import Foundation
import Network
import Testing
@testable import RimeAIInputCore

// MARK: - 测试基建

/// 线程安全地记录传输层事件，供测试线程轮询断言。
private final class TransportEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NDJSONUDSTransport.Event] = []

    func record(_ event: NDJSONUDSTransport.Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [NDJSONUDSTransport.Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// 每代连接进入就绪事件的代际，按发生顺序。
    var readyGenerations: [UInt64] {
        snapshot.compactMap { event in
            guard case let .connectionReady(generation) = event else {
                return nil
            }
            return generation
        }
    }

    /// 传输层主动关闭的原因，按发生顺序。
    var closeReasons: [NDJSONUDSTransport.CloseReason] {
        snapshot.compactMap { event in
            guard case let .connectionClosed(_, reason) = event else {
                return nil
            }
            return reason
        }
    }

    /// 收到的完整行（解码为 UTF-8 便于断言），按到达顺序。
    var lines: [String] {
        snapshot.compactMap { event in
            guard case let .lineReceived(_, line) = event else {
                return nil
            }
            return String(decoding: line, as: UTF8.self)
        }
    }
}

/// 线程安全的结果盒，用于把传输队列上的结果带回测试线程。
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// UDS 测试服务端：接受连接、记录收到的字节、可回发数据。
/// 与生产代码零共享，仅用于驱动真实套接字交互。
private final class NDJSONUDSTestServer: @unchecked Sendable {
    let queue = DispatchQueue(
        label: "fun.wwcn.rimeai.test.ndjson-server"
    )
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private let lock = NSLock()
    private var receivedBytes = Data()
    private var readyConnections = 0

    init(socketPath: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(
            path: socketPath
        )
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.newConnectionHandler = {
            [weak self] (connection: NWConnection) in
            guard let self else {
                return
            }
            queue.async { self.accept(connection) }
        }
        listener.start(queue: queue)
    }

    var readyConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readyConnections
    }

    var receivedText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: receivedBytes, as: UTF8.self)
    }

    func send(_ data: Data) {
        queue.async { [self] in
            for connection in connections {
                connection.send(
                    content: data,
                    completion: .contentProcessed { _ in }
                )
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            for connection in connections {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                return
            }
            queue.async {
                if case .ready = state {
                    self.lock.lock()
                    self.readyConnections += 1
                    self.lock.unlock()
                }
            }
        }
        connection.start(queue: queue)
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else {
                return
            }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.lock.lock()
                    self.receivedBytes.append(data)
                    self.lock.unlock()
                }
                if error == nil {
                    self.receiveLoop(connection)
                }
            }
        }
    }
}

/// 每个用例独享一个套接字路径。路径必须远短于 sun_path 的
/// 104 字节上限——超长路径会让 NWConnection 在初始化时直接
/// 崩溃（libnetwork trap），因此使用短前缀加截断 UUID，不走
/// 长层级的临时目录。
private func makeSocketPath() -> String {
    let path = "/tmp/rimeai-ndjson-test-\(UUID().uuidString.prefix(8)).sock"
    try? FileManager.default.removeItem(atPath: path)
    return path
}

/// 轮询等待条件成立；超时前最后复查一次再放弃。
private func waitFor(
    timeout seconds: TimeInterval = 10,
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// MARK: - 用例

@Suite("NDJSONUDSTransport")
struct NDJSONUDSTransportTests {
    @Test("跨块到达的行按换行组装，空行被忽略")
    func assemblesPartialLinesAcrossChunks() async throws {
        let socketPath = makeSocketPath()
        let server = try NDJSONUDSTestServer(socketPath: socketPath)
        server.start()
        let log = TransportEventLog()
        let transport = NDJSONUDSTransport(
            configuration: NDJSONUDSTransport.Configuration(
                socketPath: socketPath,
                queueLabel: "test.ndjson.partial-lines"
            ),
            eventHandler: { log.record($0) }
        )
        defer {
            transport.queue.async { transport.close() }
            server.stop()
        }

        transport.queue.async { transport.open() }
        #expect(
            await waitFor {
                !log.readyGenerations.isEmpty
                    && server.readyConnectionCount >= 1
            }
        )

        // 一行拆成两块，随后单块里携带多行与空行。
        server.send(Data("{\"a\":".utf8))
        server.send(Data("1}\n".utf8))
        server.send(Data("{\"b\":2}\n\n{\"c\":3}\n".utf8))

        #expect(
            await waitFor {
                log.lines == ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"]
            }
        )
    }

    @Test("超过 1 MiB 上限的未换行缓冲触发断开")
    func rejectsOversizeLineAtOneMebibyteCap() async throws {
        let socketPath = makeSocketPath()
        let server = try NDJSONUDSTestServer(socketPath: socketPath)
        server.start()
        let log = TransportEventLog()
        let transport = NDJSONUDSTransport(
            configuration: NDJSONUDSTransport.Configuration(
                socketPath: socketPath,
                queueLabel: "test.ndjson.oversize"
            ),
            eventHandler: { log.record($0) }
        )
        defer {
            transport.queue.async { transport.close() }
            server.stop()
        }

        transport.queue.async { transport.open() }
        #expect(
            await waitFor {
                !log.readyGenerations.isEmpty
                    && server.readyConnectionCount >= 1
            }
        )

        server.send(Data(repeating: 0x61, count: 1_048_577))

        // 1 MiB 以 ~8 KiB 分片流动，高负载下耗时可达数秒，
        // 因此这里给足轮询预算。
        #expect(
            await waitFor(timeout: 30) {
                log.closeReasons.contains(.lineTooLarge)
            }
        )
        // 无换行的超限字节不得被拼成任何行。
        #expect(log.lines.isEmpty)
    }

    @Test("重连产生新的连接代际")
    func reconnectProducesNewGeneration() async throws {
        let socketPath = makeSocketPath()
        let server = try NDJSONUDSTestServer(socketPath: socketPath)
        server.start()
        let log = TransportEventLog()
        let transport = NDJSONUDSTransport(
            configuration: NDJSONUDSTransport.Configuration(
                socketPath: socketPath,
                queueLabel: "test.ndjson.reconnect"
            ),
            eventHandler: { log.record($0) }
        )
        defer {
            transport.queue.async { transport.close() }
            server.stop()
        }

        let firstGeneration = LockedBox<UInt64?>(nil)
        transport.queue.async {
            firstGeneration.set(transport.open())
        }
        #expect(await waitFor { !log.readyGenerations.isEmpty })
        let generation1 = try #require(firstGeneration.get())
        #expect(generation1 >= 1)

        transport.queue.async { transport.close() }
        let secondGeneration = LockedBox<UInt64?>(nil)
        transport.queue.async {
            secondGeneration.set(transport.open())
        }
        #expect(await waitFor { log.readyGenerations.count == 2 })
        let generation2 = try #require(secondGeneration.get())
        #expect(generation2 == generation1 + 1)
        #expect(log.readyGenerations == [generation1, generation2])
    }

    @Test("缓冲帧等待握手放行并按 FIFO 串行发出")
    func queuedSendsWaitForProtocolReadinessAndStayOrdered() async throws {
        let socketPath = makeSocketPath()
        let server = try NDJSONUDSTestServer(socketPath: socketPath)
        server.start()
        let log = TransportEventLog()
        let transport = NDJSONUDSTransport(
            configuration: NDJSONUDSTransport.Configuration(
                socketPath: socketPath,
                queueLabel: "test.ndjson.queued-sends"
            ),
            eventHandler: { log.record($0) }
        )
        defer {
            transport.queue.async { transport.close() }
            server.stop()
        }

        transport.queue.async { transport.open() }
        #expect(
            await waitFor {
                !log.readyGenerations.isEmpty
                    && server.readyConnectionCount >= 1
            }
        )

        // 握手帧走直发通道；应用帧在握手放行前必须保持缓冲。
        let handshakeText = "{\"type\":\"hello\"}\n"
        transport.queue.async {
            transport.sendImmediate(Data(handshakeText.utf8))
            transport.enqueueOutbound(
                data: Data("first\n".utf8),
                requestID: "r1"
            )
            transport.enqueueOutbound(
                data: Data("second\n".utf8),
                requestID: "r2"
            )
            transport.enqueueOutbound(
                data: Data("third\n".utf8),
                requestID: "r3"
            )
            transport.flushOutbound()
        }
        #expect(await waitFor { server.receivedText == handshakeText })
        // 放行之前缓冲帧不得提前泄漏。
        try await Task.sleep(for: .milliseconds(250))
        #expect(server.receivedText == handshakeText)

        transport.queue.async { transport.markProtocolReady() }
        #expect(
            await waitFor {
                server.receivedText == handshakeText + "first\nsecond\nthird\n"
            }
        )
    }

    @Test("close 丢弃缓冲帧；removeOutboundFrames 如实报告撤回结果")
    func closeDiscardsBufferedFramesAndReportsRemoval() async throws {
        let socketPath = makeSocketPath()
        let server = try NDJSONUDSTestServer(socketPath: socketPath)
        server.start()
        let log = TransportEventLog()
        let transport = NDJSONUDSTransport(
            configuration: NDJSONUDSTransport.Configuration(
                socketPath: socketPath,
                queueLabel: "test.ndjson.close-discards"
            ),
            eventHandler: { log.record($0) }
        )
        defer {
            transport.queue.async { transport.close() }
            server.stop()
        }

        // 旧代连接上缓冲一帧后拆除；新代连接放行后不得发出残帧。
        transport.queue.async { transport.open() }
        #expect(await waitFor { !log.readyGenerations.isEmpty })
        transport.queue.async {
            transport.enqueueOutbound(
                data: Data("stale\n".utf8),
                requestID: "r1"
            )
            transport.close()
            transport.open()
        }
        #expect(await waitFor { log.readyGenerations.count == 2 })
        transport.queue.async { transport.markProtocolReady() }

        // 撤回语义：队列中有该请求的帧 → true；再次撤回 → false。
        let firstRemoval = LockedBox<Bool?>(nil)
        let secondRemoval = LockedBox<Bool?>(nil)
        transport.queue.async {
            transport.enqueueOutbound(
                data: Data("x\n".utf8),
                requestID: "q1"
            )
            firstRemoval.set(
                transport.removeOutboundFrames(requestID: "q1")
            )
            secondRemoval.set(
                transport.removeOutboundFrames(requestID: "q1")
            )
        }
        #expect(await waitFor { firstRemoval.get() != nil })
        #expect(firstRemoval.get() == true)
        #expect(await waitFor { secondRemoval.get() != nil })
        #expect(secondRemoval.get() == false)

        // 给任何残帧留出发送窗口：服务端必须一字节都收不到。
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.receivedText.isEmpty)
    }

    @Test("scheduleTimeout 在传输队列上延迟触发且可取消")
    func schedulesCancellableTimeoutsOnTransportQueue() async throws {
        let transport = NDJSONUDSTransport(
            configuration: NDJSONUDSTransport.Configuration(
                socketPath: "/nonexistent/rimeai-ndjson-test.sock",
                queueLabel: "test.ndjson.timeout"
            )
        )
        defer { transport.queue.async { transport.close() } }

        let fired = LockedBox(false)
        transport.queue.async {
            _ = transport.scheduleTimeout(afterMilliseconds: 100) {
                // 必须运行在传输队列上：队列限制 API 可直接调用。
                _ = transport.currentGeneration
                fired.set(true)
            }
        }
        #expect(await waitFor { fired.get() })

        let cancelledFired = LockedBox(false)
        transport.queue.async {
            let item = transport.scheduleTimeout(
                afterMilliseconds: 80
            ) {
                cancelledFired.set(true)
            }
            item.cancel()
        }
        try await Task.sleep(for: .milliseconds(350))
        #expect(!cancelledFired.get())
    }
}
