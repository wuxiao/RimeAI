import Foundation
import Network

// MARK: - 线上消息封包

/// 客户端 → 服务端的线上消息。
public enum VoiceClientMessage: Equatable, Sendable {
    case hello(VoiceHelloRequest)
    case start(VoiceDictationStart)
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

    private static func terminate(_ json: Data) throws -> Data {
        var line = json
        line.append(0x0A)
        return line
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

/// 连接语音 helper 的 UDS 客户端。只负责字节与消息的搬运；
/// 会话语义由 `VoiceDictationClientMachine` 决定。
public final class VoiceDictationClientTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let socketPath: String
    private var connection: NWConnection?
    private var buffer = Data()
    private var messageHandler: (@Sendable (VoiceServerMessage) -> Void)?
    private var disconnectHandler: (@Sendable () -> Void)?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func setMessageHandler(
        _ handler: @escaping @Sendable (VoiceServerMessage) -> Void
    ) {
        lock.lock()
        messageHandler = handler
        lock.unlock()
    }

    public func setDisconnectHandler(
        _ handler: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        disconnectHandler = handler
        lock.unlock()
    }

    /// 建立连接。成功即返回；服务端 hello/ready 交换由调用方
    /// 通过 messageHandler 驱动状态机完成。
    public func connect(timeout: TimeInterval) async throws {
        let parameters = NWParameters.tcp ?? NWParameters()
        let endpoint = NWEndpoint.unix(path: socketPath)
        let connection = NWConnection(
            to: endpoint,
            using: parameters
        )
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
            lock.lock()
            self.connection = connection
            lock.unlock()
            connection.start(queue: DispatchQueue(
                label: "fun.wwcn.rimeai.voice-client-socket"
            ))
        }
        receiveLoop(connection)
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
        lock.unlock()
        connection?.cancel()
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
                self.ingest(data)
            }
            if error == nil && !isComplete {
                self.receiveLoop(connection)
            } else {
                self.handleDisconnect()
            }
        }
    }

    private func ingest(_ data: Data) {
        lock.lock()
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
            close()
            handleDisconnect()
            return
        }
        let handler = messageHandler
        lock.unlock()
        for line in extracted {
            guard let message = try? VoiceDictationWire
                .decodeServerLine(line)
            else {
                close()
                handleDisconnect()
                return
            }
            handler?(message)
        }
    }

    private func handleDisconnect() {
        lock.lock()
        let handler = disconnectHandler
        lock.unlock()
        handler?()
    }
}

public enum VoiceDictationTransportError: Error, Equatable {
    case connectTimeout
    case connectionCancelled
    case listenFailed
}

// MARK: - 服务端传输（helper 侧）

/// 语音 helper 的 UDS 服务端。单客户端：新连接到达时取消旧连接
/// （连接级 latest-wins）。坏行、未知消息或核心返回 disconnect 时
/// 关闭连接。socket 权限 0600。
public final class VoiceDictationServerTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let socketPath: String
    private let core: VoiceDictationServerCore
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()

    public init(
        socketPath: String,
        core: VoiceDictationServerCore
    ) {
        self.socketPath = socketPath
        self.core = core
        core.setEmitHandler { [weak self] outputs in
            self?.sendOutputs(outputs)
        }
    }

    public func start() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: socketPath) {
            // 陈旧 socket 直接清理；安装生命周期负责保证不与
            // 存活 helper 竞争同名路径。
            try? fileManager.removeItem(atPath: socketPath)
        }
        let parameters = NWParameters.tcp ?? NWParameters()
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] newConnection in
            self?.accept(newConnection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.applySocketPermissions()
            }
            if case .failed = state {
                self?.stop()
            }
        }
        lock.lock()
        self.listener = listener
        lock.unlock()
        listener.start(queue: DispatchQueue(
            label: "fun.wwcn.rimeai.voice-server-socket"
        ))
    }

    public func stop() {
        lock.lock()
        let listener = self.listener
        let connection = self.connection
        self.listener = nil
        self.connection = nil
        buffer.removeAll()
        lock.unlock()
        listener?.cancel()
        connection?.cancel()
    }

    private func applySocketPermissions() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: socketPath
        )
    }

    private func accept(_ newConnection: NWConnection) {
        lock.lock()
        let previous = connection
        connection = newConnection
        buffer.removeAll()
        lock.unlock()
        // 连接级 latest-wins：新客户端到达即断开旧客户端。
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
        lock.lock()
        if self.connection === connection {
            self.connection = nil
            buffer.removeAll()
        }
        lock.unlock()
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
        let outputs: [VoiceDictationServerCore.Output]
        switch message {
        case .hello(let value):
            outputs = core.handle(value)
        case .start(let value):
            outputs = core.handle(value)
        case .cancel(let value):
            outputs = core.handle(value)
        case .accept(let value):
            outputs = core.handle(value)
        }
        sendOutputs(outputs, connection: connection)
    }

    private func sendOutputs(_ outputs: [VoiceDictationServerCore.Output]) {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection else {
            return
        }
        sendOutputs(outputs, connection: connection)
    }

    private func sendOutputs(
        _ outputs: [VoiceDictationServerCore.Output],
        connection: NWConnection
    ) {
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
