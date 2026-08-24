import Darwin
import Foundation
import RimeAIVoicePerformanceControlCore

public enum PerformanceControlTransportError: Error, Equatable, Sendable {
    case invalidSocketPath
    case insecureParentDirectory
    case socketPathOccupied
    case insecureSocket
    case alreadyStarted
    case notStarted
    case operationTimedOut
    case peerDisconnected
    case invalidFrameLength
    case authenticationFailed
    case ioFailure
    case closed
}

public struct PerformanceControlTransportDeadlines: Equatable, Sendable {
    public static let tracer = Self(
        connect: .seconds(3),
        accept: .seconds(15),
        frame: .seconds(5),
        engineLoad: .seconds(60)
    )

    public let connect: Duration
    public let accept: Duration
    public let frame: Duration
    public let engineLoad: Duration

    public init(
        connect: Duration,
        accept: Duration,
        frame: Duration,
        engineLoad: Duration
    ) {
        self.connect = connect
        self.accept = accept
        self.frame = frame
        self.engineLoad = engineLoad
    }
}

struct DarwinPerformanceControlAuthenticationGate: Sendable {
    private let checkClosure: @Sendable () throws -> Void

    init(_ check: @escaping @Sendable () throws -> Void) {
        checkClosure = check
    }

    func check() throws {
        try checkClosure()
    }

    static let unbounded = Self {}
}

protocol DarwinPerformanceControlTransportAuthenticating {
    func authenticate(
        connectedSocket: Int32,
        expected: PerformanceControlExpectedPeerIdentity,
        gate: DarwinPerformanceControlAuthenticationGate
    ) throws -> PerformanceControlAttestedPeer
}

extension DarwinPerformanceControlPeerAuthenticator:
    DarwinPerformanceControlTransportAuthenticating {}

protocol DarwinPerformanceControlUnixSystem: Sendable {
    var effectiveUserID: uid_t { get }
    var now: ContinuousClock.Instant { get }

    func poll(
        _ descriptor: UnsafeMutablePointer<pollfd>,
        count: nfds_t,
        timeoutMilliseconds: Int32
    ) -> Int32
    func accept(_ descriptor: Int32) -> Int32
    func read(
        _ descriptor: Int32,
        into buffer: UnsafeMutableRawPointer,
        count: Int
    ) -> Int
    func write(
        _ descriptor: Int32,
        from buffer: UnsafeRawPointer,
        count: Int
    ) -> Int
    func shutdown(_ descriptor: Int32)
    func close(_ descriptor: Int32)
}

struct LiveDarwinPerformanceControlUnixSystem:
    DarwinPerformanceControlUnixSystem
{
    private let clock = ContinuousClock()

    var effectiveUserID: uid_t { geteuid() }
    var now: ContinuousClock.Instant { clock.now }

    func poll(
        _ descriptor: UnsafeMutablePointer<pollfd>,
        count: nfds_t,
        timeoutMilliseconds: Int32
    ) -> Int32 {
        Darwin.poll(descriptor, count, timeoutMilliseconds)
    }

    func accept(_ descriptor: Int32) -> Int32 {
        Darwin.accept(descriptor, nil, nil)
    }

    func read(
        _ descriptor: Int32,
        into buffer: UnsafeMutableRawPointer,
        count: Int
    ) -> Int {
        Darwin.read(descriptor, buffer, count)
    }

    func write(
        _ descriptor: Int32,
        from buffer: UnsafeRawPointer,
        count: Int
    ) -> Int {
        Darwin.write(descriptor, buffer, count)
    }

    func close(_ descriptor: Int32) {
        _ = Darwin.close(descriptor)
    }

    func shutdown(_ descriptor: Int32) {
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    }
}

public final class DarwinPerformanceControlAuthenticatedConnection:
    @unchecked Sendable
{
    public let attestedPeer: PerformanceControlAttestedPeer

    private let system: any DarwinPerformanceControlUnixSystem
    private let stateLock = NSLock()
    private let readLock = NSLock()
    private let writeLock = NSLock()
    private var descriptor: Int32

    init(
        adoptingAuthenticatedSocket descriptor: Int32,
        attestedPeer: PerformanceControlAttestedPeer,
        system: any DarwinPerformanceControlUnixSystem =
            LiveDarwinPerformanceControlUnixSystem()
    ) throws {
        guard descriptor >= 0 else {
            throw PerformanceControlTransportError.ioFailure
        }
        try configurePerformanceControlSocket(descriptor)
        self.descriptor = descriptor
        self.attestedPeer = attestedPeer
        self.system = system
    }

    deinit {
        close()
    }

    public func send(
        _ frame: PerformanceControlWireFrame,
        deadline: ContinuousClock.Instant
    ) throws {
        let payload = try frame.encodedCanonical()
        guard !payload.isEmpty,
              payload.count <= PerformanceControlWireFrame.maximumEncodedBytes
        else {
            throw PerformanceControlTransportError.invalidFrameLength
        }
        var length = UInt32(payload.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }

        writeLock.lock()
        do {
            try writeAll(header, deadline: deadline)
            try writeAll(payload, deadline: deadline)
            writeLock.unlock()
        } catch {
            let closing = beginTerminalShutdown()
            writeLock.unlock()
            finishTerminalClose(closing)
            throw error
        }
    }

    public func receive(
        deadline: ContinuousClock.Instant
    ) throws -> PerformanceControlWireFrame {
        readLock.lock()
        do {
            let header = try readExactly(4, deadline: deadline)
            let length = header.reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard length > 0,
                  length <= UInt32(
                      PerformanceControlWireFrame.maximumEncodedBytes
                  )
            else {
                throw PerformanceControlTransportError.invalidFrameLength
            }
            let payload = try readExactly(Int(length), deadline: deadline)
            let frame = try PerformanceControlWireFrame.decodeCanonical(payload)
            readLock.unlock()
            return frame
        } catch {
            let closing = beginTerminalShutdown()
            readLock.unlock()
            finishTerminalClose(closing)
            throw error
        }
    }

    public func close() {
        finishTerminalClose(beginTerminalShutdown())
    }

    private func beginTerminalShutdown() -> Int32 {
        stateLock.lock()
        let closing = descriptor
        descriptor = -1
        stateLock.unlock()

        if closing >= 0 {
            system.shutdown(closing)
        }
        return closing
    }

    private func finishTerminalClose(_ closing: Int32) {
        guard closing >= 0 else { return }
        readLock.lock()
        writeLock.lock()
        system.close(closing)
        writeLock.unlock()
        readLock.unlock()
    }

    private func currentDescriptor() throws -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0 else {
            throw PerformanceControlTransportError.closed
        }
        return descriptor
    }

    private func readExactly(
        _ count: Int,
        deadline: ContinuousClock.Instant
    ) throws -> Data {
        var output = Data(count: count)
        var offset = 0
        while offset < count {
            try requireDeadline(deadline, system: system)
            let descriptor = try currentDescriptor()
            let result = output.withUnsafeMutableBytes { bytes in
                system.read(
                    descriptor,
                    into: bytes.baseAddress!.advanced(by: offset),
                    count: count - offset
                )
            }
            if result > 0 {
                try requireDeadline(deadline, system: system)
                offset += result
                continue
            }
            if result == 0 {
                throw PerformanceControlTransportError.peerDisconnected
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                _ = try waitForDescriptor(
                    descriptor,
                    events: Int16(POLLIN),
                    deadline: deadline,
                    system: system
                )
            case EBADF:
                throw PerformanceControlTransportError.closed
            default:
                throw PerformanceControlTransportError.ioFailure
            }
        }
        return output
    }

    private func writeAll(
        _ data: Data,
        deadline: ContinuousClock.Instant
    ) throws {
        var offset = 0
        while offset < data.count {
            try requireDeadline(deadline, system: system)
            let descriptor = try currentDescriptor()
            let result = data.withUnsafeBytes { bytes in
                system.write(
                    descriptor,
                    from: bytes.baseAddress!.advanced(by: offset),
                    count: data.count - offset
                )
            }
            if result > 0 {
                try requireDeadline(deadline, system: system)
                offset += result
                continue
            }
            if result == 0 {
                throw PerformanceControlTransportError.peerDisconnected
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                _ = try waitForDescriptor(
                    descriptor,
                    events: Int16(POLLOUT),
                    deadline: deadline,
                    system: system
                )
            case EPIPE, ECONNRESET:
                throw PerformanceControlTransportError.peerDisconnected
            case EBADF:
                throw PerformanceControlTransportError.closed
            default:
                throw PerformanceControlTransportError.ioFailure
            }
        }
    }
}

public final class DarwinPerformanceControlUnixListener: @unchecked Sendable {
    private struct State {
        var descriptor: Int32 = -1
        var wakeReadDescriptor: Int32 = -1
        var wakeWriteDescriptor: Int32 = -1
        var pendingAcceptedDescriptors = Set<Int32>()
        var parentDescriptor: Int32 = -1
        var parentIdentity: PerformanceControlFileIdentity?
        var socketIdentity: PerformanceControlFileIdentity?
        var didClose = false
        var closeSucceeded: Bool?
    }

    public let socketPath: String

    private let path: PerformanceControlUnixSocketPath
    private let authenticator: any DarwinPerformanceControlTransportAuthenticating
    private let system: any DarwinPerformanceControlUnixSystem
    private let fileSystem: any DarwinPerformanceControlUnixFileSystem
    private let stateLock = NSLock()
    private let acceptLock = NSLock()
    private let closeLock = NSLock()
    private var state = State()

    public convenience init(socketPath: String) throws {
        try self.init(
            socketPath: socketPath,
            authenticator: DarwinPerformanceControlPeerAuthenticator(),
            system: LiveDarwinPerformanceControlUnixSystem(),
            fileSystem: LiveDarwinPerformanceControlUnixFileSystem()
        )
    }

    init(
        socketPath: String,
        authenticator: any DarwinPerformanceControlTransportAuthenticating,
        system: any DarwinPerformanceControlUnixSystem =
            LiveDarwinPerformanceControlUnixSystem(),
        fileSystem: any DarwinPerformanceControlUnixFileSystem =
            LiveDarwinPerformanceControlUnixFileSystem()
    ) throws {
        path = try PerformanceControlUnixSocketPath(socketPath)
        self.socketPath = socketPath
        self.authenticator = authenticator
        self.system = system
        self.fileSystem = fileSystem
    }

    init(
        testingSocketPath socketPath: String,
        adoptingListeningDescriptor descriptor: Int32,
        authenticator: any DarwinPerformanceControlTransportAuthenticating,
        system: any DarwinPerformanceControlUnixSystem =
            LiveDarwinPerformanceControlUnixSystem(),
        fileSystem: any DarwinPerformanceControlUnixFileSystem =
            LiveDarwinPerformanceControlUnixFileSystem()
    ) throws {
        path = try PerformanceControlUnixSocketPath(socketPath)
        self.socketPath = socketPath
        self.authenticator = authenticator
        self.system = system
        self.fileSystem = fileSystem
        let wake = try makePerformanceControlWakePipe()
        state.descriptor = descriptor
        state.wakeReadDescriptor = wake.read
        state.wakeWriteDescriptor = wake.write
    }

    deinit {
        _ = close()
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard state.descriptor < 0 else {
            throw PerformanceControlTransportError.alreadyStarted
        }
        guard !state.didClose else {
            throw PerformanceControlTransportError.closed
        }

        let parentDescriptor = try openVerifiedPerformanceControlParent(
            path.parent,
            system: system
        )
        var createdDescriptor: Int32 = -1
        var wakeReadDescriptor: Int32 = -1
        var wakeWriteDescriptor: Int32 = -1
        var parentIdentity: PerformanceControlFileIdentity?
        var socketIdentity: PerformanceControlFileIdentity?
        do {
            parentIdentity = try verifiedPerformanceControlParentIdentity(
                parentDescriptor,
                system: system
            )
            guard try performanceControlEntryStatus(
                parentDescriptor: parentDescriptor,
                name: path.basename,
                fileSystem: fileSystem
            ) == nil else {
                throw PerformanceControlTransportError.socketPathOccupied
            }

            createdDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard createdDescriptor >= 0 else {
                throw PerformanceControlTransportError.ioFailure
            }
            try configurePerformanceControlSocket(createdDescriptor)
            let wake = try makePerformanceControlWakePipe()
            wakeReadDescriptor = wake.read
            wakeWriteDescriptor = wake.write
            let bindResult = withPerformanceControlSockAddr(path.fullPath) {
                address, length in
                Darwin.bind(createdDescriptor, address, length)
            }
            guard bindResult == 0 else {
                if errno == EADDRINUSE || errno == EEXIST {
                    throw PerformanceControlTransportError.socketPathOccupied
                }
                throw PerformanceControlTransportError.ioFailure
            }

            socketIdentity = try verifiedCreatedSocketIdentity(
                parentDescriptor: parentDescriptor,
                name: path.basename,
                expectedUserID: system.effectiveUserID,
                requiredMode: nil
            )
            guard fchmodat(
                parentDescriptor,
                path.basename,
                mode_t(0o600),
                0
            ) == 0 else {
                throw PerformanceControlTransportError.ioFailure
            }
            let finalIdentity = try verifiedCreatedSocketIdentity(
                parentDescriptor: parentDescriptor,
                name: path.basename,
                expectedUserID: system.effectiveUserID,
                requiredMode: mode_t(0o600)
            )
            guard finalIdentity == socketIdentity,
                  performanceControlPathHasNoExtendedACL(path.fullPath),
                  try verifiedCreatedSocketIdentity(
                      parentDescriptor: parentDescriptor,
                      name: path.basename,
                      expectedUserID: system.effectiveUserID,
                      requiredMode: mode_t(0o600)
                  ) == finalIdentity
            else {
                throw PerformanceControlTransportError.insecureSocket
            }
            guard Darwin.listen(createdDescriptor, SOMAXCONN) == 0 else {
                throw PerformanceControlTransportError.ioFailure
            }

            state.descriptor = createdDescriptor
            state.wakeReadDescriptor = wakeReadDescriptor
            state.wakeWriteDescriptor = wakeWriteDescriptor
            state.parentDescriptor = parentDescriptor
            state.parentIdentity = parentIdentity
            state.socketIdentity = finalIdentity
        } catch {
            if let parentIdentity, let socketIdentity {
                cleanupPerformanceControlSocket(
                    parentDescriptor: parentDescriptor,
                    parentIdentity: parentIdentity,
                    name: path.basename,
                    socketIdentity: socketIdentity,
                    system: system,
                    fileSystem: fileSystem
                )
            }
            if createdDescriptor >= 0 {
                system.close(createdDescriptor)
            }
            if wakeReadDescriptor >= 0 {
                system.close(wakeReadDescriptor)
            }
            if wakeWriteDescriptor >= 0 {
                system.close(wakeWriteDescriptor)
            }
            system.close(parentDescriptor)
            throw error
        }
    }

    public func acceptAuthenticated(
        expectedPeer: PerformanceControlExpectedPeerIdentity,
        deadline: ContinuousClock.Instant
    ) throws -> DarwinPerformanceControlAuthenticatedConnection {
        let accepted = try acceptSocket(deadline: deadline)
        do {
            let gate = DarwinPerformanceControlAuthenticationGate {
                [weak self] in
                guard let self else {
                    throw PerformanceControlTransportError.closed
                }
                try requireDeadline(deadline, system: self.system)
                self.stateLock.lock()
                let closed = self.state.didClose
                self.stateLock.unlock()
                guard !closed else {
                    throw PerformanceControlTransportError.closed
                }
            }
            let peer = try authenticator.authenticate(
                connectedSocket: accepted,
                expected: expectedPeer,
                gate: gate
            )
            try gate.check()
            stateLock.lock()
            guard !state.didClose,
                  state.pendingAcceptedDescriptors.contains(accepted)
            else {
                stateLock.unlock()
                throw PerformanceControlTransportError.closed
            }
            state.pendingAcceptedDescriptors.remove(accepted)
            stateLock.unlock()
            return try DarwinPerformanceControlAuthenticatedConnection(
                adoptingAuthenticatedSocket: accepted,
                attestedPeer: peer,
                system: system
            )
        } catch let error as PerformanceControlTransportError {
            clearPendingAcceptedDescriptor(accepted)
            system.close(accepted)
            throw error
        } catch is PerformanceControlPeerAuthenticationError {
            clearPendingAcceptedDescriptor(accepted)
            system.close(accepted)
            throw PerformanceControlTransportError.authenticationFailed
        } catch {
            clearPendingAcceptedDescriptor(accepted)
            system.close(accepted)
            throw error
        }
    }

    private func acceptSocket(
        deadline: ContinuousClock.Instant
    ) throws -> Int32 {
        acceptLock.lock()
        defer { acceptLock.unlock() }
        stateLock.lock()
        let listener = state.descriptor
        let wakeReader = state.wakeReadDescriptor
        let didClose = state.didClose
        stateLock.unlock()
        guard listener >= 0, wakeReader >= 0 else {
            throw didClose
                ? PerformanceControlTransportError.closed
                : PerformanceControlTransportError.notStarted
        }

        var accepted: Int32 = -1
        while accepted < 0 {
            try requireDeadline(deadline, system: system)
            accepted = system.accept(listener)
            if accepted >= 0 { break }
            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                try waitForListenerOrCancellation(
                    listener,
                    wakeReader: wakeReader,
                    deadline: deadline,
                    system: system
                )
            case EBADF, EINVAL:
                throw PerformanceControlTransportError.closed
            default:
                throw PerformanceControlTransportError.ioFailure
            }
        }

        do {
            try requireDeadline(deadline, system: system)
            try configurePerformanceControlSocket(accepted)
            stateLock.lock()
            guard !state.didClose else {
                stateLock.unlock()
                throw PerformanceControlTransportError.closed
            }
            state.pendingAcceptedDescriptors.insert(accepted)
            stateLock.unlock()
            return accepted
        } catch {
            system.close(accepted)
            throw error
        }
    }

    @discardableResult
    public func close() -> Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        stateLock.lock()
        guard !state.didClose else {
            let succeeded = state.closeSucceeded ?? false
            stateLock.unlock()
            return succeeded
        }
        let closing = state
        state.didClose = true
        stateLock.unlock()

        if closing.wakeWriteDescriptor >= 0 {
            var marker: UInt8 = 1
            _ = withUnsafePointer(to: &marker) {
                system.write(
                    closing.wakeWriteDescriptor,
                    from: $0,
                    count: 1
                )
            }
        }
        for pending in closing.pendingAcceptedDescriptors {
            system.shutdown(pending)
        }
        acceptLock.lock()
        var closeSucceeded = true
        if closing.parentDescriptor >= 0,
           let parentIdentity = closing.parentIdentity,
           let socketIdentity = closing.socketIdentity
        {
            closeSucceeded = cleanupPerformanceControlSocket(
                parentDescriptor: closing.parentDescriptor,
                parentIdentity: parentIdentity,
                name: path.basename,
                socketIdentity: socketIdentity,
                system: system,
                fileSystem: fileSystem
            )
        }
        if closing.descriptor >= 0 {
            system.close(closing.descriptor)
        }
        if closing.wakeReadDescriptor >= 0 {
            system.close(closing.wakeReadDescriptor)
        }
        if closing.wakeWriteDescriptor >= 0 {
            system.close(closing.wakeWriteDescriptor)
        }
        acceptLock.unlock()
        if closing.parentDescriptor >= 0 {
            system.close(closing.parentDescriptor)
        }
        stateLock.lock()
        state.descriptor = -1
        state.wakeReadDescriptor = -1
        state.wakeWriteDescriptor = -1
        state.pendingAcceptedDescriptors.removeAll()
        state.parentDescriptor = -1
        state.closeSucceeded = closeSucceeded
        stateLock.unlock()
        return closeSucceeded
    }

    private func clearPendingAcceptedDescriptor(_ descriptor: Int32) {
        stateLock.lock()
        state.pendingAcceptedDescriptors.remove(descriptor)
        stateLock.unlock()
    }
}

public enum DarwinPerformanceControlUnixClient {
    public static func connectAuthenticated(
        socketPath: String,
        expectedCollector: PerformanceControlExpectedPeerIdentity,
        deadline: ContinuousClock.Instant
    ) throws -> DarwinPerformanceControlAuthenticatedConnection {
        try connectAuthenticated(
            socketPath: socketPath,
            expectedCollector: expectedCollector,
            deadline: deadline,
            authenticator: DarwinPerformanceControlPeerAuthenticator(),
            system: LiveDarwinPerformanceControlUnixSystem()
        )
    }

    static func connectAuthenticated(
        socketPath: String,
        expectedCollector: PerformanceControlExpectedPeerIdentity,
        deadline: ContinuousClock.Instant,
        authenticator: any DarwinPerformanceControlTransportAuthenticating,
        system: any DarwinPerformanceControlUnixSystem =
            LiveDarwinPerformanceControlUnixSystem(),
        fileSystem: any DarwinPerformanceControlUnixFileSystem =
            LiveDarwinPerformanceControlUnixFileSystem()
    ) throws -> DarwinPerformanceControlAuthenticatedConnection {
        let path = try PerformanceControlUnixSocketPath(socketPath)
        let parent = try openVerifiedPerformanceControlParent(
            path.parent,
            system: system
        )
        defer { system.close(parent) }
        let parentIdentity = try verifiedPerformanceControlParentIdentity(
            parent,
            system: system
        )
        let socketIdentity = try verifiedClientSocketIdentity(
            parentDescriptor: parent,
            path: path,
            system: system,
            fileSystem: fileSystem
        )

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw PerformanceControlTransportError.ioFailure
        }
        do {
            try configurePerformanceControlSocket(descriptor)
            try requireDeadline(deadline, system: system)
            let connectResult = withPerformanceControlSockAddr(path.fullPath) {
                address, length in
                Darwin.connect(descriptor, address, length)
            }
            if connectResult != 0 {
                guard errno == EINPROGRESS || errno == EALREADY
                        || errno == EINTR
                else {
                    throw PerformanceControlTransportError.ioFailure
                }
                _ = try waitForDescriptor(
                    descriptor,
                    events: Int16(POLLOUT),
                    deadline: deadline,
                    system: system
                )
                var socketError: Int32 = 0
                var errorBytes = socklen_t(MemoryLayout<Int32>.size)
                let status = withUnsafeMutablePointer(to: &socketError) {
                    getsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_ERROR,
                        $0,
                        &errorBytes
                    )
                }
                guard status == 0, errorBytes == MemoryLayout<Int32>.size,
                      socketError == 0
                else {
                    throw PerformanceControlTransportError.ioFailure
                }
            }
            try requireDeadline(deadline, system: system)

            guard try verifiedPerformanceControlParentIdentity(
                parent,
                system: system
            ) == parentIdentity,
                try verifiedClientSocketIdentity(
                    parentDescriptor: parent,
                    path: path,
                    system: system,
                    fileSystem: fileSystem
                ) == socketIdentity
            else {
                throw PerformanceControlTransportError.insecureSocket
            }

            let peer = try authenticator.authenticate(
                connectedSocket: descriptor,
                expected: expectedCollector,
                gate: DarwinPerformanceControlAuthenticationGate {
                    try requireDeadline(deadline, system: system)
                }
            )
            try requireDeadline(deadline, system: system)
            return try DarwinPerformanceControlAuthenticatedConnection(
                adoptingAuthenticatedSocket: descriptor,
                attestedPeer: peer,
                system: system
            )
        } catch let error as PerformanceControlTransportError {
            system.close(descriptor)
            throw error
        } catch is PerformanceControlPeerAuthenticationError {
            system.close(descriptor)
            throw PerformanceControlTransportError.authenticationFailed
        } catch {
            system.close(descriptor)
            throw error
        }
    }
}

private struct PerformanceControlUnixSocketPath {
    static let maximumUTF8Bytes = 103

    let fullPath: String
    let parent: String
    let basename: String

    init(_ value: String) throws {
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard value == value.precomposedStringWithCanonicalMapping,
              value.hasPrefix("/"), value != "/",
              !value.utf8.contains(0),
              value.utf8.count <= Self.maximumUTF8Bytes,
              value.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value != 0x7F
              }),
              components.count >= 3,
              components.first?.isEmpty == true,
              components.dropFirst().allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              })
        else {
            throw PerformanceControlTransportError.invalidSocketPath
        }
        fullPath = value
        basename = String(components.last!)
        let parentEnd = value.index(
            value.endIndex,
            offsetBy: -(basename.count + 1)
        )
        parent = parentEnd == value.startIndex
            ? "/"
            : String(value[..<parentEnd])
    }
}

struct PerformanceControlFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
    }
}

protocol DarwinPerformanceControlUnixFileSystem: Sendable {
    func entryStatus(parentDescriptor: Int32, name: String) throws -> stat?
    func unlinkEntry(parentDescriptor: Int32, name: String) -> Int32
}

struct LiveDarwinPerformanceControlUnixFileSystem:
    DarwinPerformanceControlUnixFileSystem
{
    func entryStatus(parentDescriptor: Int32, name: String) throws -> stat? {
        var status = stat()
        let result = name.withCString {
            fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return status }
        if errno == ENOENT { return nil }
        throw PerformanceControlTransportError.ioFailure
    }

    func unlinkEntry(parentDescriptor: Int32, name: String) -> Int32 {
        name.withCString { unlinkat(parentDescriptor, $0, 0) }
    }
}

private func configurePerformanceControlSocket(_ descriptor: Int32) throws {
    var one: Int32 = 1
    guard setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &one,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        throw PerformanceControlTransportError.ioFailure
    }
    let descriptorFlags = fcntl(descriptor, F_GETFD)
    guard descriptorFlags >= 0,
          fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
    else {
        throw PerformanceControlTransportError.ioFailure
    }
    let statusFlags = fcntl(descriptor, F_GETFL)
    guard statusFlags >= 0,
          fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0
    else {
        throw PerformanceControlTransportError.ioFailure
    }
}

private func waitForDescriptor(
    _ descriptor: Int32,
    events: Int16,
    deadline: ContinuousClock.Instant,
    system: any DarwinPerformanceControlUnixSystem
) throws -> Int16 {
    while true {
        let timeout = try pollTimeoutMilliseconds(
            now: system.now,
            deadline: deadline
        )
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: events,
            revents: 0
        )
        let result = system.poll(
            &pollDescriptor,
            count: 1,
            timeoutMilliseconds: timeout
        )
        if result > 0 {
            try requireDeadline(deadline, system: system)
            if pollDescriptor.revents & Int16(POLLNVAL) != 0 {
                throw PerformanceControlTransportError.closed
            }
            if pollDescriptor.revents & Int16(POLLERR) != 0 {
                throw PerformanceControlTransportError.ioFailure
            }
            if pollDescriptor.revents & events != 0 {
                return pollDescriptor.revents
            }
            if pollDescriptor.revents & Int16(POLLHUP) != 0 {
                throw PerformanceControlTransportError.peerDisconnected
            }
            continue
        }
        if result == 0 {
            throw PerformanceControlTransportError.operationTimedOut
        }
        if errno == EINTR { continue }
        if errno == EBADF {
            throw PerformanceControlTransportError.closed
        }
        throw PerformanceControlTransportError.ioFailure
    }
}

private func waitForListenerOrCancellation(
    _ listener: Int32,
    wakeReader: Int32,
    deadline: ContinuousClock.Instant,
    system: any DarwinPerformanceControlUnixSystem
) throws {
    while true {
        let timeout = try pollTimeoutMilliseconds(
            now: system.now,
            deadline: deadline
        )
        var descriptors = [
            pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakeReader, events: Int16(POLLIN), revents: 0),
        ]
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            system.poll(
                buffer.baseAddress!,
                count: nfds_t(buffer.count),
                timeoutMilliseconds: timeout
            )
        }
        if result > 0 {
            if descriptors[1].revents & (Int16(POLLIN) | Int16(POLLHUP)) != 0 {
                throw PerformanceControlTransportError.closed
            }
            try requireDeadline(deadline, system: system)
            if descriptors[0].revents & Int16(POLLNVAL) != 0 {
                throw PerformanceControlTransportError.closed
            }
            if descriptors[0].revents & Int16(POLLERR) != 0 {
                throw PerformanceControlTransportError.ioFailure
            }
            if descriptors[0].revents & Int16(POLLIN) != 0 {
                return
            }
            if descriptors[0].revents & Int16(POLLHUP) != 0 {
                throw PerformanceControlTransportError.closed
            }
            continue
        }
        if result == 0 {
            throw PerformanceControlTransportError.operationTimedOut
        }
        if errno == EINTR { continue }
        if errno == EBADF {
            throw PerformanceControlTransportError.closed
        }
        throw PerformanceControlTransportError.ioFailure
    }
}

private func requireDeadline(
    _ deadline: ContinuousClock.Instant,
    system: any DarwinPerformanceControlUnixSystem
) throws {
    guard system.now < deadline else {
        throw PerformanceControlTransportError.operationTimedOut
    }
}

func pollTimeoutMilliseconds(
    now: ContinuousClock.Instant,
    deadline: ContinuousClock.Instant
) throws -> Int32 {
    guard now < deadline else {
        throw PerformanceControlTransportError.operationTimedOut
    }
    let components = now.duration(to: deadline).components
    let maximum = Int64(Int32.max)
    let maximumWholeSeconds = maximum / 1_000
    if components.seconds > maximumWholeSeconds {
        return Int32.max
    }
    let fractionalMilliseconds =
        (components.attoseconds + 999_999_999_999_999)
            / 1_000_000_000_000_000
    let milliseconds = components.seconds * 1_000
        + fractionalMilliseconds
    return Int32(min(maximum, max(1, milliseconds)))
}

private func makePerformanceControlWakePipe() throws
    -> (read: Int32, write: Int32)
{
    var descriptors = [Int32](repeating: -1, count: 2)
    guard pipe(&descriptors) == 0 else {
        throw PerformanceControlTransportError.ioFailure
    }
    do {
        for descriptor in descriptors {
            let descriptorFlags = fcntl(descriptor, F_GETFD)
            guard descriptorFlags >= 0,
                  fcntl(
                      descriptor,
                      F_SETFD,
                      descriptorFlags | FD_CLOEXEC
                  ) == 0
            else {
                throw PerformanceControlTransportError.ioFailure
            }
            let statusFlags = fcntl(descriptor, F_GETFL)
            guard statusFlags >= 0,
                  fcntl(
                      descriptor,
                      F_SETFL,
                      statusFlags | O_NONBLOCK
                  ) == 0
            else {
                throw PerformanceControlTransportError.ioFailure
            }
        }
        return (descriptors[0], descriptors[1])
    } catch {
        _ = Darwin.close(descriptors[0])
        _ = Darwin.close(descriptors[1])
        throw error
    }
}

private func withPerformanceControlSockAddr<T>(
    _ path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
) -> T {
    var address = sockaddr_un()
    let pathBytes = Array(path.utf8)
    let pathOffset = MemoryLayout<sockaddr_un>.size
        - MemoryLayout.size(ofValue: address.sun_path)
    let addressLength = pathOffset + pathBytes.count + 1
    address.sun_len = UInt8(addressLength)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: pathBytes)
        destination[pathBytes.count] = 0
    }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(addressLength))
        }
    }
}

private func openVerifiedPerformanceControlParent(
    _ path: String,
    system: any DarwinPerformanceControlUnixSystem
) throws -> Int32 {
    var descriptor = Darwin.open(
        "/",
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
        throw PerformanceControlTransportError.insecureParentDirectory
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    for component in components {
        let next = component.withCString {
            openat(
                descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard next >= 0 else {
            system.close(descriptor)
            throw PerformanceControlTransportError.insecureParentDirectory
        }
        system.close(descriptor)
        descriptor = next
    }
    do {
        _ = try verifiedPerformanceControlParentIdentity(
            descriptor,
            system: system
        )
        return descriptor
    } catch {
        system.close(descriptor)
        throw error
    }
}

private func verifiedPerformanceControlParentIdentity(
    _ descriptor: Int32,
    system: any DarwinPerformanceControlUnixSystem
) throws -> PerformanceControlFileIdentity {
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          status.st_uid == system.effectiveUserID,
          status.st_mode & mode_t(0o7777) == mode_t(0o700),
          performanceControlDescriptorHasNoExtendedACL(descriptor)
    else {
        throw PerformanceControlTransportError.insecureParentDirectory
    }
    return PerformanceControlFileIdentity(status)
}

private func performanceControlEntryStatus(
    parentDescriptor: Int32,
    name: String,
    fileSystem: any DarwinPerformanceControlUnixFileSystem =
        LiveDarwinPerformanceControlUnixFileSystem()
) throws -> stat? {
    try fileSystem.entryStatus(
        parentDescriptor: parentDescriptor,
        name: name
    )
}

private func verifiedCreatedSocketIdentity(
    parentDescriptor: Int32,
    name: String,
    expectedUserID: uid_t,
    requiredMode: mode_t?,
    fileSystem: any DarwinPerformanceControlUnixFileSystem =
        LiveDarwinPerformanceControlUnixFileSystem()
) throws -> PerformanceControlFileIdentity {
    guard let status = try performanceControlEntryStatus(
        parentDescriptor: parentDescriptor,
        name: name,
        fileSystem: fileSystem
    ),
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
        status.st_uid == expectedUserID,
        requiredMode.map({
            status.st_mode & mode_t(0o7777) == $0
        }) ?? true
    else {
        throw PerformanceControlTransportError.insecureSocket
    }
    return PerformanceControlFileIdentity(status)
}

private func verifiedClientSocketIdentity(
    parentDescriptor: Int32,
    path: PerformanceControlUnixSocketPath,
    system: any DarwinPerformanceControlUnixSystem,
    fileSystem: any DarwinPerformanceControlUnixFileSystem =
        LiveDarwinPerformanceControlUnixFileSystem()
) throws -> PerformanceControlFileIdentity {
    let identity = try verifiedCreatedSocketIdentity(
        parentDescriptor: parentDescriptor,
        name: path.basename,
        expectedUserID: system.effectiveUserID,
        requiredMode: mode_t(0o600),
        fileSystem: fileSystem
    )
    guard performanceControlPathHasNoExtendedACL(path.fullPath),
          try verifiedCreatedSocketIdentity(
              parentDescriptor: parentDescriptor,
              name: path.basename,
              expectedUserID: system.effectiveUserID,
              requiredMode: mode_t(0o600),
              fileSystem: fileSystem
          ) == identity
    else {
        throw PerformanceControlTransportError.insecureSocket
    }
    return identity
}

@discardableResult
func cleanupPerformanceControlSocket(
    parentDescriptor: Int32,
    parentIdentity: PerformanceControlFileIdentity,
    name: String,
    socketIdentity: PerformanceControlFileIdentity,
    system: any DarwinPerformanceControlUnixSystem,
    fileSystem: any DarwinPerformanceControlUnixFileSystem =
        LiveDarwinPerformanceControlUnixFileSystem()
) -> Bool {
    guard let currentParent = try? verifiedPerformanceControlParentIdentity(
        parentDescriptor,
        system: system
    ),
        currentParent == parentIdentity,
        let status = try? performanceControlEntryStatus(
            parentDescriptor: parentDescriptor,
            name: name,
            fileSystem: fileSystem
        ),
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
        PerformanceControlFileIdentity(status) == socketIdentity
    else {
        return false
    }
    // Darwin has no compare-and-unlink syscall. The listening descriptor is
    // deliberately kept alive across this check/unlink window, but a same-UID
    // actor that can mutate the private 0700 parent can still race replacement.
    let result = fileSystem.unlinkEntry(
        parentDescriptor: parentDescriptor,
        name: name
    )
    return result == 0
}

private func performanceControlPathHasNoExtendedACL(_ path: String) -> Bool {
    errno = 0
    guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else {
        return errno == ENOENT
    }
    acl_free(UnsafeMutableRawPointer(acl))
    return false
}

private func performanceControlDescriptorHasNoExtendedACL(
    _ descriptor: Int32
) -> Bool {
    errno = 0
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
        return errno == ENOENT
    }
    acl_free(UnsafeMutableRawPointer(acl))
    return false
}
