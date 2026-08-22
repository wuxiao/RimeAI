import Darwin
import Foundation
import Security

// MARK: - 固定发布身份

public enum VoiceDictationXPCConstants {
    public static let machServiceName =
        "fun.wwcn.rimeai.voice-helper"
    public static let inputMethodSigningIdentifier =
        "fun.wwcn.inputmethod.RimeAI"
    public static let helperSigningIdentifier =
        "fun.wwcn.rimeai.voice-helper"
}

/// 代码签名 Team 取自当前运行制品自身的签名，而不是用户偏好、LaunchAgent
/// 或候选 peer。Developer ID 构建据此形成稳定的 Team+identifier requirement；
/// ad-hoc 构建没有 TeamIdentifier，只能进入显式的内部 UDS 开发后端。
public enum VoiceDictationCodeSigningIdentity {
    public static func currentTeamIdentifier() -> String? {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
              let dynamicCode
        else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode)
                == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(
            staticCode,
            flags,
            &information
        ) == errSecSuccess,
              let dictionary = information as? [CFString: Any],
              let teamIdentifier = dictionary[
                  kSecCodeInfoTeamIdentifier
              ] as? String,
              !teamIdentifier.isEmpty
        else {
            return nil
        }
        return teamIdentifier
    }
}

public struct VoiceDictationXPCPeerPolicy: Equatable, Sendable {
    public let expectedIdentifier: String
    public let expectedTeamIdentifier: String
    public let expectedEffectiveUserIdentifier: uid_t

    public init(
        expectedIdentifier: String,
        expectedTeamIdentifier: String,
        expectedEffectiveUserIdentifier: uid_t = geteuid()
    ) throws {
        guard Self.isValidSigningIdentifier(expectedIdentifier),
              Self.isValidTeamIdentifier(expectedTeamIdentifier)
        else {
            throw VoiceDictationTransportError.invalidPeerIdentity
        }
        self.expectedIdentifier = expectedIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.expectedEffectiveUserIdentifier =
            expectedEffectiveUserIdentifier
    }

    public static func forCurrentProcess(
        expectedPeerIdentifier: String
    ) throws -> VoiceDictationXPCPeerPolicy {
        guard let teamIdentifier = VoiceDictationCodeSigningIdentity
            .currentTeamIdentifier()
        else {
            throw VoiceDictationTransportError.unsignedProcess
        }
        return try VoiceDictationXPCPeerPolicy(
            expectedIdentifier: expectedPeerIdentifier,
            expectedTeamIdentifier: teamIdentifier
        )
    }

    /// 固定语法片段均在初始化时限制为 ASCII identifier/Team 字符集，
    /// 因此不会让可写字符串逃逸 requirement 表达式。
    public var codeSigningRequirement: String {
        "anchor apple generic"
            + " and identifier \"\(expectedIdentifier)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = "
            + "\"\(expectedTeamIdentifier)\""
    }

    private static func isValidSigningIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255 else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D
                || byte == 0x2E
        }
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
        }
    }
}

public enum VoiceDictationPreferredTransport: Equatable, Sendable {
    case authenticatedXPC
    case developmentInsecureUDS

    /// 后端来自不可变的构建配置，不用“是否恰好读到 TeamIdentifier”猜测。
    /// Release 查询签名失败时仍会构造 fail-closed transport，绝不降级 UDS。
    public static var currentBuildConfiguration: Self {
#if DEBUG
        .developmentInsecureUDS
#else
        .authenticatedXPC
#endif
    }
}

// MARK: - XPC 接口

/// 协议只允许顶层 Data 与基础 reply 标量，不开放 Foundation collection
/// 或自定义对象图。Data 内仍是现有 Codable JSON，每次 RPC 恰好一条消息。
@objc(RAIVoiceDictationXPCService)
public protocol VoiceDictationXPCServiceProtocol: NSObjectProtocol {
    func ping(withReply reply: @escaping () -> Void)
    func sendFrame(
        _ frame: Data,
        withReply reply: @escaping (Bool) -> Void
    )
}

@objc(RAIVoiceDictationXPCClient)
public protocol VoiceDictationXPCClientProtocol: NSObjectProtocol {
    func receiveFrame(
        _ frame: Data,
        withReply reply: @escaping (Bool) -> Void
    )
}

private func voiceXPCServiceInterface() -> NSXPCInterface {
    let interface = NSXPCInterface(
        with: VoiceDictationXPCServiceProtocol.self
    )
    interface.setClasses(
        NSSet(object: NSData.self) as! Set<AnyHashable>,
        for: #selector(
            VoiceDictationXPCServiceProtocol.sendFrame(_:withReply:)
        ),
        argumentIndex: 0,
        ofReply: false
    )
    return interface
}

private func voiceXPCClientInterface() -> NSXPCInterface {
    let interface = NSXPCInterface(
        with: VoiceDictationXPCClientProtocol.self
    )
    interface.setClasses(
        NSSet(object: NSData.self) as! Set<AnyHashable>,
        for: #selector(
            VoiceDictationXPCClientProtocol.receiveFrame(_:withReply:)
        ),
        argumentIndex: 0,
        ofReply: false
    )
    return interface
}

// MARK: - 有界单飞发送队列

/// XPC proxy 方法本身会在内存中排队。以 reply 作为“远端已经消费该帧”的
/// ACK，每个方向只保留一个 in-flight，并给剩余队列设置明确上限。
final class VoiceDictationXPCFrameQueue: @unchecked Sendable {
    typealias Sender = (
        Data,
        @escaping (Bool) -> Void
    ) -> Void

    private let stateQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-xpc-frame-queue"
    )
    private let failureQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-xpc-frame-queue.failure"
    )
    private let sender: Sender
    private let onFailure: () -> Void
    private let maximumFrameCount: Int
    private let maximumQueuedBytes: Int
    private var frames: [Data] = []
    private var queuedBytes = 0
    private var isSending = false
    private var isActive = true
    private var hasScheduledFailure = false

    init(
        maximumFrameCount: Int = 32,
        maximumQueuedBytes: Int =
            VoiceDictationWire.maximumLineBytes * 4,
        sender: @escaping Sender,
        onFailure: @escaping () -> Void
    ) {
        self.maximumFrameCount = maximumFrameCount
        self.maximumQueuedBytes = maximumQueuedBytes
        self.sender = sender
        self.onFailure = onFailure
    }

    @discardableResult
    func enqueue(_ frame: Data) -> Bool {
        var accepted = false
        stateQueue.sync {
            guard isActive else {
                return
            }
            guard frames.count < maximumFrameCount,
                  frame.count <= maximumQueuedBytes,
                  queuedBytes <= maximumQueuedBytes - frame.count
            else {
                failLocked()
                return
            }
            frames.append(frame)
            queuedBytes += frame.count
            accepted = true
            if !isSending {
                isSending = true
                sendFirstLocked()
            }
        }
        return accepted
    }

    func invalidate() {
        stateQueue.sync {
            deactivateLocked()
        }
    }

    /// 确定性测试缝：等待串行状态迁移及其异步失败通知全部处理。
    func waitForPendingStateTransitionsForTesting() {
        stateQueue.sync {}
        failureQueue.sync {}
    }

    /// 只在 stateQueue 上调用。把“仍 active + 选中首帧 + 交给 XPC proxy”
    /// 线性化；invalidate 若先取得队列就不会再有迟发帧。
    private func sendFirstLocked() {
        guard isActive, isSending, let frame = frames.first else {
            return
        }
        let once = OnceFlag()
        sender(frame) { [weak self] accepted in
            guard once.claim(), let self else {
                return
            }
            self.stateQueue.async { [weak self] in
                self?.didCompleteLocked(accepted: accepted)
            }
        }
    }

    /// 只在 stateQueue 上调用；reply/error 即使竞态到达也由 OnceFlag 去重。
    private func didCompleteLocked(accepted: Bool) {
        guard isActive, isSending, !frames.isEmpty else {
            return
        }
        let completed = frames.removeFirst()
        queuedBytes -= completed.count
        guard accepted else {
            failLocked()
            return
        }
        if frames.isEmpty {
            isSending = false
            return
        }
        sendFirstLocked()
    }

    /// 只在 stateQueue 上调用。失败通知与 NACK 一样异步派发，避免
    /// enqueue 调用方仍持有 Coordinator/transport 锁时同步重入。
    private func failLocked() {
        guard isActive, !hasScheduledFailure else {
            return
        }
        hasScheduledFailure = true
        deactivateLocked()
        failureQueue.async { [self] in
            onFailure()
        }
    }

    private func deactivateLocked() {
        isActive = false
        frames.removeAll()
        queuedBytes = 0
        isSending = false
    }
}

// MARK: - 客户端

private final class VoiceDictationXPCClientEndpoint:
    NSObject,
    VoiceDictationXPCClientProtocol
{
    let authorizeCaller: () -> Bool
    let receive: (Data) -> Bool

    init(
        authorizeCaller: @escaping () -> Bool,
        receive: @escaping (Data) -> Bool
    ) {
        self.authorizeCaller = authorizeCaller
        self.receive = receive
    }

    func receiveFrame(
        _ frame: Data,
        withReply reply: @escaping (Bool) -> Void
    ) {
        guard authorizeCaller() else {
            reply(false)
            return
        }
        reply(receive(frame))
    }
}

public final class VoiceDictationXPCClientTransport:
    VoiceDictationClientTransporting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let connectionFactory: () -> NSXPCConnection
    private let peerPolicy: VoiceDictationXPCPeerPolicy?
    private let expectedEffectiveUserIdentifier: uid_t
    private var connection: NSXPCConnection?
    private var endpoint: VoiceDictationXPCClientEndpoint?
    private var outboundQueue: VoiceDictationXPCFrameQueue?
    private var connectionGeneration: UInt64 = 0
    private var authenticatedGeneration: UInt64?
    private var generationMessageHandler: (@Sendable (
        VoiceServerMessage,
        UInt64
    ) -> Void)?
    private var generationDisconnectHandler: (@Sendable (UInt64) -> Void)?

    public convenience init(
        machServiceName: String =
            VoiceDictationXPCConstants.machServiceName,
        expectedServerIdentifier: String =
            VoiceDictationXPCConstants.helperSigningIdentifier
    ) throws {
        let policy = try VoiceDictationXPCPeerPolicy.forCurrentProcess(
            expectedPeerIdentifier: expectedServerIdentifier
        )
        self.init(
            connectionFactory: {
                NSXPCConnection(
                    machServiceName: machServiceName,
                    options: []
                )
            },
            peerPolicy: policy,
            expectedEffectiveUserIdentifier:
                policy.expectedEffectiveUserIdentifier
        )
    }

    /// 匿名 listener 只用于进程内自动化；产品初始化器始终要求签名策略。
    convenience init(
        listenerEndpoint: NSXPCListenerEndpoint,
        expectedEffectiveUserIdentifier: uid_t = geteuid()
    ) {
        self.init(
            connectionFactory: {
                NSXPCConnection(listenerEndpoint: listenerEndpoint)
            },
            peerPolicy: nil,
            expectedEffectiveUserIdentifier:
                expectedEffectiveUserIdentifier
        )
    }

    private init(
        connectionFactory: @escaping () -> NSXPCConnection,
        peerPolicy: VoiceDictationXPCPeerPolicy?,
        expectedEffectiveUserIdentifier: uid_t
    ) {
        self.connectionFactory = connectionFactory
        self.peerPolicy = peerPolicy
        self.expectedEffectiveUserIdentifier =
            expectedEffectiveUserIdentifier
    }

    func setGenerationMessageHandler(
        _ handler: @escaping @Sendable (
            VoiceServerMessage,
            UInt64
        ) -> Void
    ) {
        lock.lock()
        generationMessageHandler = handler
        lock.unlock()
    }

    func setGenerationDisconnectHandler(
        _ handler: @escaping @Sendable (UInt64) -> Void
    ) {
        lock.lock()
        generationDisconnectHandler = handler
        lock.unlock()
    }

    func isCurrentConnectionGeneration(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection != nil && connectionGeneration == generation
    }

    func connectionGenerationSnapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return connectionGeneration
    }

    public func connect(timeout: TimeInterval) async throws {
        let connection = connectionFactory()
        let installed = install(connection)
        installed.previous?.invalidate()
        let generation = installed.generation

        let endpoint = VoiceDictationXPCClientEndpoint(
            authorizeCaller: { [weak self, weak connection] in
                guard let self, let connection,
                      let caller = NSXPCConnection.current(),
                      caller === connection,
                      caller.processIdentifier > 0,
                      caller.effectiveUserIdentifier
                        == self.expectedEffectiveUserIdentifier
                else {
                    return false
                }
                return true
            },
            receive: { [weak self, weak connection] frame in
                guard let self, let connection else {
                    return false
                }
                return self.receive(
                    frame,
                    connection: connection,
                    generation: generation
                )
            }
        )
        connection.exportedInterface = voiceXPCClientInterface()
        connection.exportedObject = endpoint
        connection.remoteObjectInterface = voiceXPCServiceInterface()
        if let peerPolicy {
            connection.setCodeSigningRequirement(
                peerPolicy.codeSigningRequirement
            )
        }
        connection.interruptionHandler = { [weak self, weak connection] in
            guard let self, let connection else {
                return
            }
            self.fail(connection, generation: generation)
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else {
                return
            }
            self.fail(connection, generation: generation)
        }

        guard installEndpointIfCurrent(
            endpoint,
            connection: connection,
            generation: generation
        ) else {
            connection.invalidate()
            throw VoiceDictationTransportError.connectionCancelled
        }
        connection.activate()

        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let once = OnceFlag()
                let proxy = connection.remoteObjectProxyWithErrorHandler {
                    error in
                    guard once.claim() else {
                        return
                    }
                    continuation.resume(throwing: error)
                } as? VoiceDictationXPCServiceProtocol
                guard let proxy else {
                    if once.claim() {
                        continuation.resume(
                            throwing: VoiceDictationTransportError
                                .connectionCancelled
                        )
                    }
                    return
                }
                proxy.ping { [weak self, weak connection] in
                    guard once.claim() else {
                        return
                    }
                    guard let self, let connection,
                          connection.processIdentifier > 0,
                          connection.effectiveUserIdentifier
                            == self.expectedEffectiveUserIdentifier,
                          self.markAuthenticatedIfCurrent(
                              connection,
                              generation: generation
                          )
                    else {
                        continuation.resume(
                            throwing: VoiceDictationTransportError
                                .peerUserMismatch
                        )
                        return
                    }
                    continuation.resume()
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + timeout
                ) {
                    guard once.claim() else {
                        return
                    }
                    continuation.resume(
                        throwing: VoiceDictationTransportError
                            .connectTimeout
                    )
                }
            }
        } catch {
            discard(connection, generation: generation)
            throw error
        }
        guard isCurrent(connection, generation: generation) else {
            connection.invalidate()
            throw VoiceDictationTransportError.connectionCancelled
        }
        installOutboundQueue(
            for: connection,
            generation: generation
        )
    }

    public func send(_ message: VoiceClientMessage) {
        guard let frame = try? VoiceDictationWire.encodeXPCPayload(message)
        else {
            return
        }
        lock.lock()
        let queue = outboundQueue
        lock.unlock()
        _ = queue?.enqueue(frame)
    }

    public func close() {
        lock.lock()
        let connection = self.connection
        // 与 ACK 驱动的下一帧发送线性化：先同步作废队列，再推进连接代际。
        outboundQueue?.invalidate()
        self.connection = nil
        endpoint = nil
        outboundQueue = nil
        authenticatedGeneration = nil
        connectionGeneration &+= 1
        lock.unlock()
        connection?.invalidate()
    }

    private func install(
        _ connection: NSXPCConnection
    ) -> (
        previous: NSXPCConnection?,
        generation: UInt64
    ) {
        lock.lock()
        defer { lock.unlock() }
        let previous = self.connection
        outboundQueue?.invalidate()
        connectionGeneration &+= 1
        self.connection = connection
        endpoint = nil
        outboundQueue = nil
        authenticatedGeneration = nil
        return (previous, connectionGeneration)
    }

    private func installOutboundQueue(
        for connection: NSXPCConnection,
        generation: UInt64
    ) {
        let queue = VoiceDictationXPCFrameQueue(
            sender: { [weak connection] frame, completion in
                guard let connection else {
                    completion(false)
                    return
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler {
                    _ in completion(false)
                } as? VoiceDictationXPCServiceProtocol
                guard let proxy else {
                    completion(false)
                    return
                }
                proxy.sendFrame(frame, withReply: completion)
            },
            onFailure: { [weak self, weak connection] in
                guard let self, let connection else {
                    return
                }
                self.fail(connection, generation: generation)
            }
        )
        lock.lock()
        guard self.connection === connection,
              connectionGeneration == generation,
              authenticatedGeneration == generation
        else {
            lock.unlock()
            queue.invalidate()
            return
        }
        outboundQueue = queue
        lock.unlock()
    }

    private func installEndpointIfCurrent(
        _ endpoint: VoiceDictationXPCClientEndpoint,
        connection: NSXPCConnection,
        generation: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.connection === connection,
              connectionGeneration == generation
        else {
            return false
        }
        self.endpoint = endpoint
        return true
    }

    private func receive(
        _ frame: Data,
        connection: NSXPCConnection,
        generation: UInt64
    ) -> Bool {
        guard frame.count <= VoiceDictationWire.maximumLineBytes,
              let message = try? VoiceDictationWire
                .decodeXPCServerPayload(frame)
        else {
            fail(connection, generation: generation)
            return false
        }
        lock.lock()
        guard self.connection === connection,
              connectionGeneration == generation,
              authenticatedGeneration == generation
        else {
            lock.unlock()
            return false
        }
        let handler = generationMessageHandler
        lock.unlock()
        handler?(message, generation)
        return isCurrent(connection, generation: generation)
    }

    private func fail(
        _ connection: NSXPCConnection,
        generation: UInt64
    ) {
        lock.lock()
        guard self.connection === connection,
              connectionGeneration == generation
        else {
            lock.unlock()
            return
        }
        outboundQueue?.invalidate()
        self.connection = nil
        endpoint = nil
        outboundQueue = nil
        authenticatedGeneration = nil
        connectionGeneration &+= 1
        let invalidatedGeneration = connectionGeneration
        let handler = generationDisconnectHandler
        lock.unlock()
        connection.invalidate()
        handler?(invalidatedGeneration)
    }

    private func discard(
        _ connection: NSXPCConnection,
        generation: UInt64
    ) {
        lock.lock()
        if self.connection === connection,
           connectionGeneration == generation
        {
            outboundQueue?.invalidate()
            self.connection = nil
            endpoint = nil
            outboundQueue = nil
            authenticatedGeneration = nil
            connectionGeneration &+= 1
        }
        lock.unlock()
        connection.invalidate()
    }

    private func isCurrent(
        _ connection: NSXPCConnection,
        generation: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.connection === connection
            && connectionGeneration == generation
    }

    private func markAuthenticatedIfCurrent(
        _ connection: NSXPCConnection,
        generation: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.connection === connection,
              connectionGeneration == generation
        else {
            return false
        }
        authenticatedGeneration = generation
        return true
    }
}

// MARK: - 服务端

private final class VoiceDictationXPCServerEndpoint:
    NSObject,
    VoiceDictationXPCServiceProtocol
{
    let authorizeCaller: () -> Bool
    let pingHandler: () -> Bool
    let frameHandler: (Data) -> Bool

    init(
        authorizeCaller: @escaping () -> Bool,
        pingHandler: @escaping () -> Bool,
        frameHandler: @escaping (Data) -> Bool
    ) {
        self.authorizeCaller = authorizeCaller
        self.pingHandler = pingHandler
        self.frameHandler = frameHandler
    }

    func ping(withReply reply: @escaping () -> Void) {
        guard authorizeCaller(), pingHandler() else {
            return
        }
        reply()
    }

    func sendFrame(
        _ frame: Data,
        withReply reply: @escaping (Bool) -> Void
    ) {
        guard authorizeCaller() else {
            reply(false)
            return
        }
        reply(frameHandler(frame))
    }
}

public final class VoiceDictationXPCServerTransport:
    NSObject,
    NSXPCListenerDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let routeLock = NSRecursiveLock()
    private let listener: NSXPCListener
    private let peerPolicy: VoiceDictationXPCPeerPolicy?
    private let expectedEffectiveUserIdentifier: uid_t
    private let core: VoiceDictationServerCore
    private var pendingConnection: NSXPCConnection?
    private var pendingEndpoint: VoiceDictationXPCServerEndpoint?
    private var pendingToken: UUID?
    private var connection: NSXPCConnection?
    private var endpoint: VoiceDictationXPCServerEndpoint?
    private var connectionToken: UUID?
    private var connectionCoreEpoch: UInt64?
    private var outboundQueue: VoiceDictationXPCFrameQueue?
    private var isStarted = false

    public convenience init(
        machServiceName: String =
            VoiceDictationXPCConstants.machServiceName,
        expectedClientIdentifier: String =
            VoiceDictationXPCConstants.inputMethodSigningIdentifier,
        core: VoiceDictationServerCore
    ) throws {
        let policy = try VoiceDictationXPCPeerPolicy.forCurrentProcess(
            expectedPeerIdentifier: expectedClientIdentifier
        )
        self.init(
            listener: NSXPCListener(
                machServiceName: machServiceName
            ),
            peerPolicy: policy,
            expectedEffectiveUserIdentifier:
                policy.expectedEffectiveUserIdentifier,
            core: core
        )
    }

    /// 匿名 listener 只供进程内测试；产品构造器不会绕过签名 requirement。
    convenience init(
        anonymousListener: NSXPCListener,
        expectedEffectiveUserIdentifier: uid_t = geteuid(),
        core: VoiceDictationServerCore
    ) {
        self.init(
            listener: anonymousListener,
            peerPolicy: nil,
            expectedEffectiveUserIdentifier:
                expectedEffectiveUserIdentifier,
            core: core
        )
    }

    private init(
        listener: NSXPCListener,
        peerPolicy: VoiceDictationXPCPeerPolicy?,
        expectedEffectiveUserIdentifier: uid_t,
        core: VoiceDictationServerCore
    ) {
        self.listener = listener
        self.peerPolicy = peerPolicy
        self.expectedEffectiveUserIdentifier =
            expectedEffectiveUserIdentifier
        self.core = core
        super.init()
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
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()
        if let peerPolicy {
            listener.setConnectionCodeSigningRequirement(
                peerPolicy.codeSigningRequirement
            )
        }
        listener.delegate = self
        listener.activate()
    }

    public func stop() {
        routeLock.lock()
        lock.lock()
        guard isStarted else {
            lock.unlock()
            routeLock.unlock()
            return
        }
        isStarted = false
        let pending = pendingConnection
        let active = connection
        outboundQueue?.invalidate()
        pendingConnection = nil
        pendingEndpoint = nil
        pendingToken = nil
        connection = nil
        endpoint = nil
        connectionToken = nil
        connectionCoreEpoch = nil
        outboundQueue = nil
        lock.unlock()
        core.resetConnection()
        routeLock.unlock()
        pending?.invalidate()
        active?.invalidate()
        listener.invalidate()
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard newConnection.processIdentifier > 0,
              newConnection.effectiveUserIdentifier
                == expectedEffectiveUserIdentifier
        else {
            return false
        }

        let token = UUID()
        let endpoint = VoiceDictationXPCServerEndpoint(
            authorizeCaller: { [weak self, weak newConnection] in
                guard let self, let newConnection,
                      let caller = NSXPCConnection.current(),
                      caller === newConnection,
                      caller.processIdentifier > 0,
                      caller.effectiveUserIdentifier
                        == self.expectedEffectiveUserIdentifier
                else {
                    return false
                }
                return true
            },
            pingHandler: { [weak self, weak newConnection] in
                guard let self, let newConnection else {
                    return false
                }
                return self.candidateCanPing(
                    newConnection,
                    token: token
                )
            },
            frameHandler: { [weak self, weak newConnection] frame in
                guard let self, let newConnection else {
                    return false
                }
                return self.receive(
                    frame,
                    connection: newConnection,
                    token: token
                )
            }
        )
        newConnection.exportedInterface = voiceXPCServiceInterface()
        newConnection.exportedObject = endpoint
        newConnection.remoteObjectInterface = voiceXPCClientInterface()
        newConnection.interruptionHandler = {
            [weak self, weak newConnection] in
            guard let self, let newConnection else {
                return
            }
            self.clear(newConnection, token: token)
        }
        newConnection.invalidationHandler = {
            [weak self, weak newConnection] in
            guard let self, let newConnection else {
                return
            }
            self.clear(newConnection, token: token)
        }

        lock.lock()
        guard isStarted else {
            lock.unlock()
            return false
        }
        let oldPending = pendingConnection
        pendingConnection = newConnection
        pendingEndpoint = endpoint
        pendingToken = token
        lock.unlock()
        oldPending?.invalidate()
        newConnection.activate()
        return true
    }

    /// ping 只为客户端提供签名/UID 后的连接屏障，不替换当前会话。
    /// candidate 必须随后发送合法 hello，才能 promotion 为 latest-wins。
    private func candidateCanPing(
        _ candidate: NSXPCConnection,
        token: UUID
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStarted
            && pendingConnection === candidate
            && pendingToken == token
    }

    private func receive(
        _ frame: Data,
        connection: NSXPCConnection,
        token: UUID
    ) -> Bool {
        guard frame.count <= VoiceDictationWire.maximumLineBytes,
              let message = try? VoiceDictationWire
                .decodeXPCClientPayload(frame)
        else {
            clear(connection, token: token)
            return false
        }
        if isPending(connection, token: token) {
            guard case .hello(let hello) = message, hello.isValid else {
                clear(connection, token: token)
                return false
            }
            return promoteAndRouteHello(
                hello,
                connection: connection,
                token: token
            )
        }
        routeLock.lock()
        guard isCurrent(connection, token: token) else {
            routeLock.unlock()
            return false
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
        sendOutputs(outputs, connection: connection, token: token)
        routeLock.unlock()
        return isCurrent(connection, token: token)
    }

    /// 首个合法 hello 的校验、连接 promotion、旧 core reset 与 hello route
    /// 在同一 routeLock 临界区完成。旧连接之后即使有已排队 frame/ACK，也
    /// 会因 connection token 不匹配而被丢弃。
    private func promoteAndRouteHello(
        _ hello: VoiceHelloRequest,
        connection candidate: NSXPCConnection,
        token: UUID
    ) -> Bool {
        routeLock.lock()
        lock.lock()
        guard isStarted,
              pendingConnection === candidate,
              pendingToken == token,
              let candidateEndpoint = pendingEndpoint
        else {
            lock.unlock()
            routeLock.unlock()
            return false
        }
        let previous = connection
        let previousQueue = outboundQueue
        // promotion 与旧队列失效必须处于同一临界区；否则旧 ACK 可能在
        // token 切换后继续向旧 peer 发送下一帧。
        previousQueue?.invalidate()
        pendingConnection = nil
        pendingEndpoint = nil
        pendingToken = nil
        connection = candidate
        endpoint = candidateEndpoint
        connectionToken = token
        connectionCoreEpoch = nil
        outboundQueue = makeOutboundQueue(
            connection: candidate,
            token: token
        )
        lock.unlock()
        let epoch = core.resetConnection()
        lock.lock()
        guard connection === candidate, connectionToken == token else {
            lock.unlock()
            routeLock.unlock()
            previous?.invalidate()
            candidate.invalidate()
            return false
        }
        connectionCoreEpoch = epoch
        lock.unlock()
        let outputs = core.handle(hello)
        routeLock.unlock()

        previous?.invalidate()
        sendOutputs(outputs, connection: candidate, token: token)
        return isCurrent(candidate, token: token)
    }

    private func makeOutboundQueue(
        connection: NSXPCConnection,
        token: UUID
    ) -> VoiceDictationXPCFrameQueue {
        VoiceDictationXPCFrameQueue(
            sender: { [weak connection] frame, completion in
                guard let connection else {
                    completion(false)
                    return
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler {
                    _ in completion(false)
                } as? VoiceDictationXPCClientProtocol
                guard let proxy else {
                    completion(false)
                    return
                }
                proxy.receiveFrame(frame, withReply: completion)
            },
            onFailure: { [weak self, weak connection] in
                guard let self, let connection else {
                    return
                }
                self.clear(connection, token: token)
            }
        )
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
        let token = connectionToken
        let isCurrentEpoch = connectionCoreEpoch == coreEpoch
        lock.unlock()
        guard isCurrentEpoch, let connection, let token else {
            return
        }
        sendOutputs(outputs, connection: connection, token: token)
    }

    private func sendOutputs(
        _ outputs: [VoiceDictationServerCore.Output],
        connection: NSXPCConnection,
        token: UUID
    ) {
        routeLock.lock()
        defer { routeLock.unlock() }
        for output in outputs {
            if case .disconnect = output {
                clear(connection, token: token)
                return
            }
            guard let message = output.wireMessage,
                  let frame = try? VoiceDictationWire
                    .encodeXPCPayload(message)
            else {
                clear(connection, token: token)
                return
            }
            lock.lock()
            guard self.connection === connection,
                  connectionToken == token
            else {
                lock.unlock()
                return
            }
            let queue = outboundQueue
            lock.unlock()
            guard queue?.enqueue(frame) == true else {
                return
            }
        }
    }

    private func clear(
        _ connection: NSXPCConnection,
        token: UUID
    ) {
        routeLock.lock()
        lock.lock()
        let shouldReset: Bool
        if self.connection === connection,
           connectionToken == token
        {
            outboundQueue?.invalidate()
            self.connection = nil
            endpoint = nil
            connectionToken = nil
            connectionCoreEpoch = nil
            outboundQueue = nil
            shouldReset = true
        } else {
            if pendingConnection === connection,
               pendingToken == token
            {
                pendingConnection = nil
                pendingEndpoint = nil
                pendingToken = nil
            }
            shouldReset = false
        }
        lock.unlock()
        if shouldReset {
            core.resetConnection()
        }
        routeLock.unlock()
        connection.invalidate()
    }

    private func isCurrent(
        _ connection: NSXPCConnection,
        token: UUID
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.connection === connection
            && connectionToken == token
    }

    private func isPending(
        _ connection: NSXPCConnection,
        token: UUID
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingConnection === connection
            && pendingToken == token
    }
}

// MARK: - 产品 transport 选择

enum VoiceDictationClientTransportFactory {
    static func make(
        preference: VoiceDictationPreferredTransport,
        developmentSocketPath: String
    ) -> any VoiceDictationClientTransporting {
        switch preference {
        case .developmentInsecureUDS:
            return VoiceDictationClientTransport(
                socketPath: developmentSocketPath
            )
        case .authenticatedXPC:
            do {
                return try VoiceDictationXPCClientTransport()
            } catch {
                // 已签名制品绝不降级到未认证 UDS。这个传输只会在
                // connect 时返回初始化错误，让普通键盘路径继续可用。
                return VoiceDictationFailClosedClientTransport(error: error)
            }
        }
    }
}

private final class VoiceDictationFailClosedClientTransport:
    VoiceDictationClientTransporting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let error: Error
    private var generation: UInt64 = 0
    private var messageHandler: (@Sendable (
        VoiceServerMessage,
        UInt64
    ) -> Void)?
    private var disconnectHandler: (@Sendable (UInt64) -> Void)?

    init(error: Error) {
        self.error = error
    }

    func setGenerationMessageHandler(
        _ handler: @escaping @Sendable (
            VoiceServerMessage,
            UInt64
        ) -> Void
    ) {
        lock.lock()
        messageHandler = handler
        lock.unlock()
    }

    func setGenerationDisconnectHandler(
        _ handler: @escaping @Sendable (UInt64) -> Void
    ) {
        lock.lock()
        disconnectHandler = handler
        lock.unlock()
    }

    func isCurrentConnectionGeneration(_ generation: UInt64) -> Bool {
        false
    }

    func connectionGenerationSnapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func connect(timeout: TimeInterval) async throws {
        throw error
    }

    func send(_ message: VoiceClientMessage) {}

    func close() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }
}
