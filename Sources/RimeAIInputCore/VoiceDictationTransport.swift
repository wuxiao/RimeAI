import Darwin
import Foundation
import Network

// MARK: - 线上消息封包

/// 客户端 → 服务端的线上消息。
public enum VoiceClientMessage: Equatable, Sendable {
    case hello(VoiceHelloRequest)
    case start(VoiceDictationStart)
    case stop(VoiceDictationStop)
    case cancel(VoiceDictationCancel)
    case accept(VoiceDictationAccept)
}

/// 服务端 → 客户端的线上消息。断开不是线上消息，由传输层直接
/// 关闭连接表达。
public enum VoiceServerMessage: Equatable, Sendable {
    case ready(VoiceReadyResponse)
    case delta(VoiceDictationDelta)
    case final(VoiceDictationFinal)
    case error(VoiceDictationError)
}

public enum VoiceDictationWireError: Error, Equatable, CustomStringConvertible {
    case lineTooLong
    case emptyLine
    case malformedJSON
    case unknownType(String)

    public var description: String {
        switch self {
        case .lineTooLong:
            return "wire line exceeds \(VoiceDictationWire.maximumLineBytes) bytes"
        case .emptyLine:
            return "empty wire line"
        case .malformedJSON:
            return "malformed JSON line"
        case .unknownType(let type):
            return "unknown message type \(type)"
        }
    }
}

/// NDJSON 编解码：一行一个 JSON 对象，行上限 64 KiB，
/// 超限或坏行按协议错误处理（断开，不猜测语义）。
public enum VoiceDictationWire {
    public static let maximumLineBytes = 65_536

    private static let typeKey = "type"

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder = JSONDecoder()

    // MARK: 编码

    public static func encode(_ message: VoiceClientMessage) throws -> Data {
        let payload: Encodable
        switch message {
        case .hello(let value): payload = value
        case .start(let value): payload = value
        case .stop(let value): payload = value
        case .cancel(let value): payload = value
        case .accept(let value): payload = value
        }
        return try terminate(try encoder.encode(payload))
    }

    public static func encode(_ message: VoiceServerMessage) throws -> Data {
        let payload: Encodable
        switch message {
        case .ready(let value): payload = value
        case .delta(let value): payload = value
        case .final(let value): payload = value
        case .error(let value): payload = value
        }
        return try terminate(try encoder.encode(payload))
    }

    /// XPC 已经保留每次方法调用的消息边界，因此不携带 NDJSON 的尾随
    /// 换行。业务 JSON 与 UDS 完全相同，只移除 framing delimiter；这样
    /// 每个 XPC 参数仍受精确的 64 KiB 上限约束，而不是再维护第二套协议。
    public static func encodeXPCPayload(
        _ message: VoiceClientMessage
    ) throws -> Data {
        try stripTerminator(from: encode(message))
    }

    public static func encodeXPCPayload(
        _ message: VoiceServerMessage
    ) throws -> Data {
        try stripTerminator(from: encode(message))
    }

    public static func decodeXPCClientPayload(
        _ payload: Data
    ) throws -> VoiceClientMessage {
        try validateXPCPayload(payload)
        return try decodeClientLine(payload)
    }

    public static func decodeXPCServerPayload(
        _ payload: Data
    ) throws -> VoiceServerMessage {
        try validateXPCPayload(payload)
        return try decodeServerLine(payload)
    }

    private static func terminate(_ json: Data) throws -> Data {
        var line = json
        line.append(0x0A)
        return line
    }

    private static func stripTerminator(from line: Data) throws -> Data {
        guard line.last == 0x0A else {
            throw VoiceDictationWireError.malformedJSON
        }
        let payload = line.dropLast()
        try validateXPCPayload(Data(payload))
        return Data(payload)
    }

    private static func validateXPCPayload(_ payload: Data) throws {
        guard !payload.isEmpty else {
            throw VoiceDictationWireError.emptyLine
        }
        guard payload.count <= maximumLineBytes else {
            throw VoiceDictationWireError.lineTooLong
        }
        // 一次 XPC 调用必须恰好是一条消息；拒绝把 NDJSON 的多行语义
        // 偷渡进 Data 参数。JSONEncoder 会把字符串内部换行转义，因此
        // 合法产品消息不会包含字面 LF/CR。
        guard !payload.contains(0x0A), !payload.contains(0x0D) else {
            throw VoiceDictationWireError.malformedJSON
        }
    }

    // MARK: 解码

    public static func decodeClientLine(_ line: Data) throws -> VoiceClientMessage {
        guard !line.isEmpty else {
            throw VoiceDictationWireError.emptyLine
        }
        guard let object = try? JSONSerialization.jsonObject(with: line)
            as? [String: Any],
            let type = object[typeKey] as? String
        else {
            throw VoiceDictationWireError.malformedJSON
        }
        switch type {
        case "voice_hello":
            return .hello(try decoder.decode(
                VoiceHelloRequest.self, from: line
            ))
        case "dictation_start":
            return .start(try decoder.decode(
                VoiceDictationStart.self, from: line
            ))
        case "dictation_stop":
            return .stop(try decoder.decode(
                VoiceDictationStop.self, from: line
            ))
        case "dictation_cancel":
            return .cancel(try decoder.decode(
                VoiceDictationCancel.self, from: line
            ))
        case "dictation_accept":
            return .accept(try decoder.decode(
                VoiceDictationAccept.self, from: line
            ))
        default:
            throw VoiceDictationWireError.unknownType(type)
        }
    }

    public static func decodeServerLine(_ line: Data) throws -> VoiceServerMessage {
        guard !line.isEmpty else {
            throw VoiceDictationWireError.emptyLine
        }
        guard let object = try? JSONSerialization.jsonObject(with: line)
            as? [String: Any],
            let type = object[typeKey] as? String
        else {
            throw VoiceDictationWireError.malformedJSON
        }
        switch type {
        case "voice_ready":
            return .ready(try decoder.decode(
                VoiceReadyResponse.self, from: line
            ))
        case "dictation_delta":
            return .delta(try decoder.decode(
                VoiceDictationDelta.self, from: line
            ))
        case "dictation_final":
            return .final(try decoder.decode(
                VoiceDictationFinal.self, from: line
            ))
        case "dictation_error":
            return .error(try decoder.decode(
                VoiceDictationError.self, from: line
            ))
        default:
            throw VoiceDictationWireError.unknownType(type)
        }
    }

    /// 从缓冲区提取完整的行。返回剩余缓冲区；超限抛出 lineTooLong。
    public static func extractLines(
        from buffer: Data
    ) throws -> (lines: [Data], remainder: Data) {
        var lines: [Data] = []
        var remainder = buffer
        while let newlineIndex = remainder.firstIndex(of: 0x0A) {
            let line = remainder[remainder.startIndex ..< newlineIndex]
            if line.count > maximumLineBytes {
                throw VoiceDictationWireError.lineTooLong
            }
            if !line.isEmpty {
                lines.append(Data(line))
            }
            remainder.removeSubrange(
                remainder.startIndex ... newlineIndex
            )
        }
        if remainder.count > maximumLineBytes {
            throw VoiceDictationWireError.lineTooLong
        }
        return (lines, remainder)
    }
}

extension VoiceDictationServerCore.Output {
    /// disconnect 不是线上消息：传输层直接关闭连接。
    var wireMessage: VoiceServerMessage? {
        switch self {
        case .ready(let message):
            return .ready(message)
        case .delta(let message):
            return .delta(message)
        case .final(let message):
            return .final(message)
        case .error(let message):
            return .error(message)
        case .disconnect:
            return nil
        }
    }
}

// MARK: - 客户端传输（输入法侧）

/// Coordinator 只依赖这组连接/代际语义。UDS 与认证 XPC 必须保持相同
/// 的 latest-wins、迟到回调失效和显式 close 合同。
protocol VoiceDictationClientTransporting: AnyObject, Sendable {
    func setGenerationMessageHandler(
        _ handler: @escaping @Sendable (VoiceServerMessage, UInt64) -> Void
    )
    func setGenerationDisconnectHandler(
        _ handler: @escaping @Sendable (UInt64) -> Void
    )
    func isCurrentConnectionGeneration(_ generation: UInt64) -> Bool
    func connectionGenerationSnapshot() -> UInt64
    func connect(timeout: TimeInterval) async throws
    func send(_ message: VoiceClientMessage)
    func close()
}

/// 连接语音 helper 的 UDS 客户端。只负责字节与消息的搬运；
/// 会话语义由 `VoiceDictationClientMachine` 决定。
public final class VoiceDictationClientTransport:
    VoiceDictationClientTransporting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let socketPath: String
    private var connection: NWConnection?
    private var connectionGeneration: UInt64 = 0
    private var buffer = Data()
    private var messageHandler: (@Sendable (VoiceServerMessage) -> Void)?
    private var generationMessageHandler: (@Sendable (
        VoiceServerMessage, UInt64
    ) -> Void)?
    private var disconnectHandler: (@Sendable () -> Void)?
    private var generationDisconnectHandler: (@Sendable (UInt64) -> Void)?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func setMessageHandler(
        _ handler: @escaping @Sendable (VoiceServerMessage) -> Void
    ) {
        lock.lock()
        messageHandler = handler
        generationMessageHandler = nil
        lock.unlock()
    }

    /// Coordinator 使用带代际的入口，在自身状态锁内再次确认消息仍
    /// 属于当前连接，避免已抽取的旧 ready 启动新会话。
    func setGenerationMessageHandler(
        _ handler: @escaping @Sendable (VoiceServerMessage, UInt64) -> Void
    ) {
        lock.lock()
        generationMessageHandler = handler
        messageHandler = nil
        lock.unlock()
    }

    func isCurrentConnectionGeneration(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection != nil && connectionGeneration == generation
    }

    public func setDisconnectHandler(
        _ handler: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        disconnectHandler = handler
        generationDisconnectHandler = nil
        lock.unlock()
    }

    func setGenerationDisconnectHandler(
        _ handler: @escaping @Sendable (UInt64) -> Void
    ) {
        lock.lock()
        generationDisconnectHandler = handler
        disconnectHandler = nil
        lock.unlock()
    }

    func connectionGenerationSnapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return connectionGeneration
    }

    /// 建立连接。成功即返回；服务端 hello/ready 交换由调用方
    /// 通过 messageHandler 驱动状态机完成。
    public func connect(timeout: TimeInterval) async throws {
        let parameters = NWParameters.tcp
        let endpoint = NWEndpoint.unix(path: socketPath)
        let connection = NWConnection(
            to: endpoint,
            using: parameters
        )
        let installed = installConnection(connection)
        let previous = installed.previous
        let generation = installed.generation
        previous?.cancel()

        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let once = OnceFlag()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.claim() {
                            continuation.resume()
                        }
                    case .failed(let error):
                        if once.claim() {
                            continuation.resume(throwing: error)
                        }
                    case .cancelled:
                        if once.claim() {
                            continuation.resume(
                                throwing: VoiceDictationTransportError
                                    .connectionCancelled
                            )
                        }
                    default:
                        break
                    }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + timeout
                ) {
                    if once.claim() {
                        connection.cancel()
                        continuation.resume(
                            throwing: VoiceDictationTransportError
                                .connectTimeout
                        )
                    }
                }
                connection.start(queue: DispatchQueue(
                    label: "fun.wwcn.rimeai.voice-client-socket"
                ))
            }
        } catch {
            discardConnection(connection, generation: generation)
            throw error
        }
        guard isCurrentConnection(connection, generation: generation) else {
            connection.cancel()
            throw VoiceDictationTransportError.connectionCancelled
        }
        receiveLoop(connection, generation: generation)
    }

    public func send(_ message: VoiceClientMessage) {
        guard let line = try? VoiceDictationWire.encode(message) else {
            return
        }
        sendRaw(line)
    }

    /// 直接发送原始行。仅供协议测试构造坏行；
    /// 产品代码只应使用 `send(_:)`。
    public func sendRaw(_ data: Data) {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection else {
            return
        }
        connection.send(
            content: data,
            completion: .contentProcessed { _ in }
        )
    }

    public func close() {
        lock.lock()
        let connection = self.connection
        self.connection = nil
        connectionGeneration &+= 1
        buffer.removeAll()
        lock.unlock()
        connection?.cancel()
    }

    private func receiveLoop(
        _ connection: NWConnection,
        generation: UInt64
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: VoiceDictationWire.maximumLineBytes
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                self.ingest(
                    data,
                    connection: connection,
                    generation: generation
                )
            }
            if error == nil && !isComplete {
                self.receiveLoop(connection, generation: generation)
            } else {
                self.failConnection(connection, generation: generation)
            }
        }
    }

    private func ingest(
        _ data: Data,
        connection: NWConnection,
        generation: UInt64
    ) {
        lock.lock()
        guard self.connection === connection,
              connectionGeneration == generation
        else {
            lock.unlock()
            return
        }
        buffer.append(data)
        let extracted: [Data]
        do {
            let result = try VoiceDictationWire.extractLines(from: buffer)
            buffer = result.remainder
            extracted = result.lines
        } catch {
            lock.unlock()
            // 坏行按协议错误处理：断开，不猜测语义。
            failConnection(connection, generation: generation)
            return
        }
        lock.unlock()
        for line in extracted {
            guard isCurrentConnection(connection, generation: generation)
            else {
                return
            }
            guard let message = try? VoiceDictationWire
                .decodeServerLine(line)
            else {
                failConnection(connection, generation: generation)
                return
            }
            lock.lock()
            guard self.connection === connection,
                  connectionGeneration == generation
            else {
                lock.unlock()
                return
            }
            let handler = messageHandler
            let generationHandler = generationMessageHandler
            lock.unlock()
            generationHandler?(message, generation)
            handler?(message)
        }
    }

    /// 只有当前连接可触发断开回调；旧 NWConnection 的迟到事件不能
    /// 击穿已经建立的新连接。
    private func failConnection(
        _ connection: NWConnection,
        generation: UInt64
    ) {
        lock.lock()
        guard self.connection === connection,
              connectionGeneration == generation
        else {
            lock.unlock()
            return
        }
        self.connection = nil
        connectionGeneration &+= 1
        let invalidatedGeneration = connectionGeneration
        buffer.removeAll()
        let handler = disconnectHandler
        let generationHandler = generationDisconnectHandler
        lock.unlock()
        connection.cancel()
        generationHandler?(invalidatedGeneration)
        handler?()
    }

    private func discardConnection(
        _ connection: NWConnection,
        generation: UInt64
    ) {
        lock.lock()
        if self.connection === connection,
           connectionGeneration == generation
        {
            self.connection = nil
            connectionGeneration &+= 1
            buffer.removeAll()
        }
        lock.unlock()
        connection.cancel()
    }

    private func installConnection(
        _ connection: NWConnection
    ) -> (previous: NWConnection?, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let previous = self.connection
        connectionGeneration &+= 1
        self.connection = connection
        buffer.removeAll()
        return (previous, connectionGeneration)
    }

    private func isCurrentConnection(
        _ connection: NWConnection,
        generation: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.connection === connection
            && connectionGeneration == generation
    }
}

public enum VoiceDictationTransportError: Error, Equatable {
    case connectTimeout
    case connectionCancelled
    case listenFailed
    case insecureSocketDirectory
    case insecureSocket
    case unsignedProcess
    case invalidPeerIdentity
    case peerUserMismatch
    case queueOverflow
    case rejectedFrame
}

// MARK: - 服务端传输（helper 侧）

/// 语音 helper 的 UDS 服务端。单客户端：新连接到达时取消旧连接
/// （连接级 latest-wins）。坏行、未知消息或核心返回 disconnect 时
/// 关闭连接。socket 权限 0600。
public final class VoiceDictationServerTransport: @unchecked Sendable {
    private let lock = NSLock()
    /// 串行化 connection 切换/reset 与单条消息的 core.route。
    private let routeLock = NSRecursiveLock()
    private let socketPath: String
    private let core: VoiceDictationServerCore
    private var listener: NWListener?
    private var connection: NWConnection?
    private var connectionEpoch: UInt64?
    private var buffer = Data()
    private var listenerReady = false
    private var socketPermissionsReady = false

    public init(
        socketPath: String,
        core: VoiceDictationServerCore
    ) {
        self.socketPath = socketPath
        self.core = core
        core.setConnectionScopedEmitHandler {
            [weak self] outputs, connectionEpoch, outputEpoch in
            self?.sendOutputs(
                outputs,
                coreEpoch: connectionEpoch,
                outputEpoch: outputEpoch
            )
        }
    }

    public func start() throws {
        let fileManager = FileManager.default
        try prepareSocketDirectory()
        if fileManager.fileExists(atPath: socketPath) {
            // 陈旧 socket 直接清理；安装生命周期负责保证不与
            // 存活 helper 竞争同名路径。
            try fileManager.removeItem(atPath: socketPath)
            guard !fileManager.fileExists(atPath: socketPath) else {
                throw VoiceDictationTransportError.listenFailed
            }
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] newConnection in
            self?.accept(newConnection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let listener else {
                return
            }
            self?.handleListenerState(state, listener: listener)
        }
        lock.lock()
        self.listener = listener
        listenerReady = false
        socketPermissionsReady = false
        lock.unlock()
        listener.start(queue: DispatchQueue(
            label: "fun.wwcn.rimeai.voice-server-socket"
        ))
        do {
            try waitUntilListenerIsPrivateAndReady(listener)
        } catch {
            stop()
            try? fileManager.removeItem(atPath: socketPath)
            throw error
        }
    }

    public func stop() {
        routeLock.lock()
        lock.lock()
        let listener = self.listener
        let connection = self.connection
        self.listener = nil
        self.connection = nil
        connectionEpoch = nil
        listenerReady = false
        socketPermissionsReady = false
        buffer.removeAll()
        lock.unlock()
        core.resetConnection()
        routeLock.unlock()
        listener?.cancel()
        connection?.cancel()
    }

    private func prepareSocketDirectory() throws {
        guard socketPath.hasPrefix("/") else {
            throw VoiceDictationTransportError.insecureSocketDirectory
        }
        let directoryPath = URL(fileURLWithPath: socketPath)
            .deletingLastPathComponent().path
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directoryPath) {
            try fileManager.createDirectory(
                atPath: directoryPath,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var status = stat()
        guard lstat(directoryPath, &status) == 0,
              status.st_uid == geteuid(),
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_mode & mode_t(0o777) == mode_t(0o700),
              voicePathHasNoExtendedACL(directoryPath)
        else {
            throw VoiceDictationTransportError.insecureSocketDirectory
        }
    }

    private func handleListenerState(
        _ state: NWListener.State,
        listener: NWListener
    ) {
        let shouldStop: Bool
        lock.lock()
        guard self.listener === listener else {
            lock.unlock()
            return
        }
        switch state {
        case .ready:
            listenerReady = true
            shouldStop = false
        case .failed:
            shouldStop = true
        default:
            shouldStop = false
        }
        lock.unlock()
        if shouldStop {
            stop()
        }
    }

    private func waitUntilListenerIsPrivateAndReady(
        _ expectedListener: NWListener
    ) throws {
        let deadline = Date().addingTimeInterval(3)
        var permissionsWereApplied = false
        while Date() < deadline {
            lock.lock()
            let isCurrent = listener === expectedListener
            let isReady = listenerReady
            let permissionsAreReady = socketPermissionsReady
            lock.unlock()
            guard isCurrent else {
                throw VoiceDictationTransportError.listenFailed
            }
            if isReady, permissionsAreReady {
                return
            }

            if !permissionsWereApplied,
               FileManager.default.fileExists(atPath: socketPath)
            {
                guard chmod(socketPath, mode_t(0o600)) == 0 else {
                    throw VoiceDictationTransportError.insecureSocket
                }
                var status = stat()
                guard lstat(socketPath, &status) == 0,
                      status.st_uid == geteuid(),
                      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
                      status.st_mode & mode_t(0o777) == mode_t(0o600),
                      voicePathHasNoExtendedACL(socketPath)
                else {
                    throw VoiceDictationTransportError.insecureSocket
                }
                lock.lock()
                guard listener === expectedListener else {
                    lock.unlock()
                    throw VoiceDictationTransportError.listenFailed
                }
                socketPermissionsReady = true
                lock.unlock()
                permissionsWereApplied = true
                continue
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        throw VoiceDictationTransportError.listenFailed
    }

    private func accept(_ newConnection: NWConnection) {
        routeLock.lock()
        lock.lock()
        guard listenerReady, socketPermissionsReady else {
            lock.unlock()
            routeLock.unlock()
            newConnection.cancel()
            return
        }
        let previous = connection
        connection = newConnection
        connectionEpoch = nil
        buffer.removeAll()
        lock.unlock()
        // 连接级 latest-wins：新客户端到达即断开旧客户端。
        let epoch = core.resetConnection()
        lock.lock()
        if connection === newConnection {
            connectionEpoch = epoch
        }
        lock.unlock()
        routeLock.unlock()
        previous?.cancel()
        newConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveLoop(newConnection)
            case .failed, .cancelled:
                self?.clearConnection(newConnection)
            default:
                break
            }
        }
        newConnection.start(queue: DispatchQueue(
            label: "fun.wwcn.rimeai.voice-server-socket"
        ))
    }

    private func clearConnection(_ connection: NWConnection) {
        routeLock.lock()
        lock.lock()
        let wasCurrent: Bool
        if self.connection === connection {
            self.connection = nil
            connectionEpoch = nil
            buffer.removeAll()
            wasCurrent = true
        } else {
            wasCurrent = false
        }
        lock.unlock()
        if wasCurrent {
            core.resetConnection()
        }
        routeLock.unlock()
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: VoiceDictationWire.maximumLineBytes
        ) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data, !data.isEmpty {
                self.ingest(data, connection: connection)
            }
            if error == nil && !isComplete {
                self.receiveLoop(connection)
            } else {
                self.clearConnection(connection)
            }
        }
    }

    private func ingest(_ data: Data, connection: NWConnection) {
        lock.lock()
        guard self.connection === connection else {
            lock.unlock()
            return
        }
        buffer.append(data)
        let extracted: [Data]
        do {
            let result = try VoiceDictationWire.extractLines(from: buffer)
            buffer = result.remainder
            extracted = result.lines
        } catch {
            buffer.removeAll()
            lock.unlock()
            // 坏行按协议错误处理：断开，不猜测语义。
            connection.cancel()
            clearConnection(connection)
            return
        }
        lock.unlock()
        for line in extracted {
            guard isCurrentConnection(connection) else {
                return
            }
            guard let message = try? VoiceDictationWire
                .decodeClientLine(line)
            else {
                connection.cancel()
                clearConnection(connection)
                return
            }
            route(message, connection: connection)
        }
    }

    private func route(
        _ message: VoiceClientMessage,
        connection: NWConnection
    ) {
        routeLock.lock()
        guard isCurrentConnection(connection) else {
            routeLock.unlock()
            return
        }
        let outputs: [VoiceDictationServerCore.Output]
        switch message {
        case .hello(let value):
            outputs = core.handle(value)
        case .start(let value):
            outputs = core.handle(value)
        case .stop(let value):
            outputs = core.handle(value)
        case .cancel(let value):
            outputs = core.handle(value)
        case .accept(let value):
            outputs = core.handle(value)
        }
        sendOutputs(outputs, connection: connection)
        routeLock.unlock()
    }

    private func isCurrentConnection(_ connection: NWConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.connection === connection
    }

    private func sendOutputs(
        _ outputs: [VoiceDictationServerCore.Output],
        coreEpoch: UInt64,
        outputEpoch: UInt64
    ) {
        routeLock.lock()
        defer { routeLock.unlock() }
        guard core.isCurrentOutputScope(
            connectionEpoch: coreEpoch,
            outputEpoch: outputEpoch
        ) else {
            return
        }
        lock.lock()
        let connection = self.connection
        let isCurrentEpoch = connectionEpoch == coreEpoch
        lock.unlock()
        guard isCurrentEpoch, let connection else {
            return
        }
        sendOutputs(outputs, connection: connection)
    }

    private func sendOutputs(
        _ outputs: [VoiceDictationServerCore.Output],
        connection: NWConnection
    ) {
        routeLock.lock()
        defer { routeLock.unlock() }
        guard isCurrentConnection(connection) else {
            return
        }
        for output in outputs {
            if let message = output.wireMessage,
               let line = try? VoiceDictationWire.encode(message)
            {
                connection.send(
                    content: line,
                    completion: .contentProcessed { _ in }
                )
            } else if case .disconnect = output {
                connection.cancel()
                clearConnection(connection)
            }
        }
    }
}

/// POSIX mode bits alone do not account for macOS extended ACL entries.
/// `acl_get_file` reports ENOENT when no extended ACL exists; every other
/// outcome is rejected so an unreadable ACL cannot silently widen access.
private func voicePathHasNoExtendedACL(_ path: String) -> Bool {
    errno = 0
    guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else {
        return errno == ENOENT
    }
    acl_free(UnsafeMutableRawPointer(acl))
    return false
}

/// 一次性恢复保护：continuation 恰好 resume 一次。
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// 尝试占用；已被占用时返回 false。
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed {
            return false
        }
        claimed = true
        return true
    }
}
