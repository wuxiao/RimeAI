import Darwin
import Foundation
import RimeAIVoicePerformanceControlCore
import Testing
@testable import RimeAIVoicePerformanceControlDarwin

@Suite("Darwin performance-control Unix transport", .serialized)
struct DarwinPerformanceControlUnixTransportTests {
    @Test("socket paths must be canonical absolute Darwin paths")
    func rejectsInvalidSocketPaths() {
        for path in [
            "relative/control.sock",
            "/tmp/../tmp/control.sock",
            "/tmp/control\n.sock",
            "/" + String(repeating: "a", count: 104),
        ] {
            #expect(throws: PerformanceControlTransportError.invalidSocketPath) {
                _ = try DarwinPerformanceControlUnixListener(socketPath: path)
            }
        }
    }

    @Test("poll timeout conversion clamps only at the exact Int32 boundary")
    func pollTimeoutConversionUsesExactThreshold() throws {
        let now = ContinuousClock().now
        #expect(
            try pollTimeoutMilliseconds(
                now: now,
                deadline: now.advanced(
                    by: .milliseconds(Int64(Int32.max) - 1)
                )
            ) == Int32.max - 1
        )
        #expect(
            try pollTimeoutMilliseconds(
                now: now,
                deadline: now.advanced(
                    by: .milliseconds(Int64(Int32.max))
                )
            ) == Int32.max
        )
        #expect(
            try pollTimeoutMilliseconds(
                now: now,
                deadline: now.advanced(
                    by: .milliseconds(Int64(Int32.max) + 1)
                )
            ) == Int32.max
        )
    }

    @Test(
        "real listener and client attest before canonical frame I/O",
        .enabled(
            if: fileSystemUnixSocketsAvailable,
            "host sandbox must permit filesystem AF_UNIX bind"
        )
    )
    func realSocketRoundTripAuthenticatesBeforeIO() async throws {
        let fixture = try SocketDirectoryFixture()
        defer { fixture.remove() }
        let system = CountingUnixSystem()
        let authenticator = RecordingAuthenticator {
            system.ioCallCount > 0
        }
        let listener = try DarwinPerformanceControlUnixListener(
            socketPath: fixture.socketPath,
            authenticator: authenticator,
            system: system
        )
        try listener.start()
        defer { listener.close() }

        #expect(try mode(at: fixture.directory.path) == 0o700)
        #expect(try mode(at: fixture.socketPath) == 0o600)

        let expected = try expectedPeerIdentity()
        let clock = ContinuousClock()
        let acceptTask = Task.detached {
            try listener.acceptAuthenticated(
                expectedPeer: expected,
                deadline: clock.now.advanced(by: .seconds(2))
            )
        }
        let client = try DarwinPerformanceControlUnixClient
            .connectAuthenticated(
                socketPath: fixture.socketPath,
                expectedCollector: expected,
                deadline: clock.now.advanced(by: .seconds(2)),
                authenticator: authenticator,
                system: system
            )
        defer { client.close() }
        let server = try await acceptTask.value
        defer { server.close() }

        #expect(authenticator.callCount == 2)
        #expect(!authenticator.sawTransportIOBeforeAuthentication)
        let frame = try challengeFrame()
        try client.send(
            frame,
            deadline: clock.now.advanced(by: .seconds(1))
        )
        #expect(
            try server.receive(
                deadline: clock.now.advanced(by: .seconds(1))
            ) == frame
        )
    }

    @Test("one-byte partial I/O and EINTR preserve the frame")
    func partialIOAndEINTRRoundTrip() throws {
        let system = CappedUnixSystem(
            maximumTransfer: 1,
            interruptFirstRead: true,
            interruptFirstWrite: true
        )
        let (sender, receiver) = try connectionPair(system: system)
        defer {
            sender.close()
            receiver.close()
        }
        let clock = ContinuousClock()
        let frame = try challengeFrame()

        try sender.send(
            frame,
            deadline: clock.now.advanced(by: .seconds(1))
        )
        #expect(
            try receiver.receive(
                deadline: clock.now.advanced(by: .seconds(1))
            ) == frame
        )
        #expect(system.didInterruptRead)
        #expect(system.didInterruptWrite)
    }

    @Test("a single absolute deadline covers every partial read")
    func readDeadlineDoesNotReset() throws {
        let system = CappedUnixSystem(
            maximumTransfer: 1,
            readDelayMicroseconds: 20_000
        )
        let (connection, peer) = try connectionAndRawPeer(system: system)
        defer {
            connection.close()
            _ = Darwin.close(peer)
        }
        try writeRaw(framed(try challengeFrame().encodedCanonical()), to: peer)
        let clock = ContinuousClock()

        #expect(throws: PerformanceControlTransportError.operationTimedOut) {
            try connection.receive(
                deadline: clock.now.advanced(by: .milliseconds(35))
            )
        }
        #expect(throws: PerformanceControlTransportError.closed) {
            try connection.receive(
                deadline: clock.now.advanced(by: .seconds(1))
            )
        }
    }

    @Test("a partial write timeout terminally closes the stream")
    func writeDeadlineDoesNotReset() throws {
        let system = CappedUnixSystem(
            maximumTransfer: 1,
            writeDelayMicroseconds: 20_000
        )
        let (connection, peer) = try connectionAndRawPeer(system: system)
        defer {
            connection.close()
            _ = Darwin.close(peer)
        }
        let clock = ContinuousClock()

        #expect(throws: PerformanceControlTransportError.operationTimedOut) {
            try connection.send(
                try challengeFrame(),
                deadline: clock.now.advanced(by: .milliseconds(35))
            )
        }
        #expect(throws: PerformanceControlTransportError.closed) {
            try connection.send(
                try challengeFrame(),
                deadline: clock.now.advanced(by: .seconds(1))
            )
        }
    }

    @Test("zero and 4097-byte frames are rejected and terminal")
    func invalidLengthsAreTerminal() throws {
        for length in [UInt32(0), UInt32(4_097)] {
            let (connection, peer) = try connectionAndRawPeer()
            defer {
                connection.close()
                _ = Darwin.close(peer)
            }
            try writeRaw(lengthHeader(length), to: peer)
            let clock = ContinuousClock()

            #expect(throws: PerformanceControlTransportError.invalidFrameLength) {
                try connection.receive(
                    deadline: clock.now.advanced(by: .seconds(1))
                )
            }
            #expect(throws: PerformanceControlTransportError.closed) {
                try connection.receive(
                    deadline: clock.now.advanced(by: .seconds(1))
                )
            }
        }
    }

    @Test("4096 bytes pass framing and fail only canonical decoding")
    func maximumFrameLengthReachesCanonicalDecoder() throws {
        let (connection, peer) = try connectionAndRawPeer()
        defer {
            connection.close()
            _ = Darwin.close(peer)
        }
        let payload = Data(repeating: 0x20, count: 4_096)
        try writeRaw(lengthHeader(4_096) + payload, to: peer)
        let clock = ContinuousClock()

        do {
            _ = try connection.receive(
                deadline: clock.now.advanced(by: .seconds(1))
            )
            Issue.record("noncanonical 4096-byte payload was accepted")
        } catch let error as PerformanceControlTransportError {
            #expect(error != .invalidFrameLength)
        } catch {
            // A Core canonical-decoding error is the expected boundary.
        }
        #expect(throws: PerformanceControlTransportError.closed) {
            try connection.receive(
                deadline: clock.now.advanced(by: .seconds(1))
            )
        }
    }

    @Test("EOF in a frame and POLLHUP terminate the connection")
    func eofAndHUPAreTerminal() throws {
        do {
            let (connection, peer) = try connectionAndRawPeer()
            try writeRaw(lengthHeader(10) + Data([1, 2, 3]), to: peer)
            _ = Darwin.close(peer)
            let clock = ContinuousClock()
            #expect(throws: PerformanceControlTransportError.peerDisconnected) {
                try connection.receive(
                    deadline: clock.now.advanced(by: .seconds(1))
                )
            }
            #expect(throws: PerformanceControlTransportError.closed) {
                try connection.receive(
                    deadline: clock.now.advanced(by: .seconds(1))
                )
            }
            connection.close()
        }

        do {
            let system = HUPUnixSystem()
            let (connection, peer) = try connectionAndRawPeer(system: system)
            defer {
                connection.close()
                _ = Darwin.close(peer)
            }
            #expect(throws: PerformanceControlTransportError.peerDisconnected) {
                try connection.receive(
                    deadline: ContinuousClock().now.advanced(by: .seconds(1))
                )
            }
        }
    }

    @Test("sockets are nonblocking, close-on-exec, and SIGPIPE-safe")
    func socketFlagsAndIdempotentClose() throws {
        let (connection, peer, ownedDescriptor) = try connectionRawPeerAndFD()
        defer { _ = Darwin.close(peer) }
        var noSIGPIPE: Int32 = 0
        var bytes = socklen_t(MemoryLayout<Int32>.size)

        #expect(fcntl(ownedDescriptor, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(ownedDescriptor, F_GETFL) & O_NONBLOCK != 0)
        #expect(
            getsockopt(
                ownedDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSIGPIPE,
                &bytes
            ) == 0
        )
        #expect(noSIGPIPE == 1)

        connection.close()
        connection.close()
        errno = 0
        #expect(fcntl(ownedDescriptor, F_GETFD) == -1)
        #expect(errno == EBADF)
    }

    @Test("close does not release an fd while an operation still owns it")
    func closeDrainsActiveOperationBeforeReleasingFD() throws {
        let system = BlockingReadUnixSystem()
        let (connection, peer, ownedDescriptor) = try connectionRawPeerAndFD(
            system: system
        )
        defer { _ = Darwin.close(peer) }
        let receiveDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? connection.receive(
                deadline: ContinuousClock().now.advanced(by: .seconds(2))
            )
            receiveDone.signal()
        }
        #expect(system.readEntered.wait(timeout: .now() + 1) == .success)
        let closeDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            connection.close()
            closeDone.signal()
        }

        usleep(20_000)
        #expect(fcntl(ownedDescriptor, F_GETFD) >= 0)
        system.allowRead.signal()
        #expect(receiveDone.wait(timeout: .now() + 1) == .success)
        #expect(closeDone.wait(timeout: .now() + 1) == .success)
        errno = 0
        #expect(fcntl(ownedDescriptor, F_GETFD) == -1)
        #expect(errno == EBADF)
    }

    @Test("parent must be exact 0700, ACL-free, and symlink-free at every component")
    func rejectsInsecureParents() throws {
        do {
            let fixture = try SocketDirectoryFixture(mode: 0o710)
            defer { fixture.remove() }
            let listener = try DarwinPerformanceControlUnixListener(
                socketPath: fixture.socketPath
            )
            #expect(
                throws: PerformanceControlTransportError.insecureParentDirectory
            ) {
                try listener.start()
            }
        }

        do {
            let fixture = try SocketDirectoryFixture()
            defer { fixture.remove() }
            let listener = try DarwinPerformanceControlUnixListener(
                socketPath: fixture.socketPath,
                authenticator: RecordingAuthenticator(),
                system: WrongEUIDUnixSystem()
            )
            #expect(
                throws: PerformanceControlTransportError.insecureParentDirectory
            ) {
                try listener.start()
            }
        }

        do {
            let fixture = try SocketDirectoryFixture()
            defer { fixture.remove() }
            try addExtendedACL(to: fixture.directory.path)
            let listener = try DarwinPerformanceControlUnixListener(
                socketPath: fixture.socketPath
            )
            #expect(
                throws: PerformanceControlTransportError.insecureParentDirectory
            ) {
                try listener.start()
            }
        }

        do {
            let root = try SocketDirectoryFixture(socketName: "unused")
            defer { root.remove() }
            let realParent = root.directory.appendingPathComponent("real")
            let linkedParent = root.directory.appendingPathComponent("linked")
            try FileManager.default.createDirectory(
                at: realParent,
                withIntermediateDirectories: false
            )
            #expect(chmod(realParent.path, mode_t(0o700)) == 0)
            try FileManager.default.createSymbolicLink(
                at: linkedParent,
                withDestinationURL: realParent
            )
            let listener = try DarwinPerformanceControlUnixListener(
                socketPath: linkedParent
                    .appendingPathComponent("control.sock").path
            )
            #expect(
                throws: PerformanceControlTransportError.insecureParentDirectory
            ) {
                try listener.start()
            }
        }
    }

    @Test("a preexisting non-socket entry is preserved without bind or unlink")
    func preexistingEntryIsPreserved() throws {
        let fixture = try SocketDirectoryFixture()
        defer { fixture.remove() }
        let sentinel = Data("sentinel".utf8)
        try sentinel.write(to: URL(fileURLWithPath: fixture.socketPath))
        let identity = try fileIdentity(at: fixture.socketPath)
        let listener = try DarwinPerformanceControlUnixListener(
            socketPath: fixture.socketPath
        )

        #expect(throws: PerformanceControlTransportError.socketPathOccupied) {
            try listener.start()
        }
        listener.close()
        #expect(try fileIdentity(at: fixture.socketPath) == identity)
        #expect(
            try Data(contentsOf: URL(fileURLWithPath: fixture.socketPath))
                == sentinel
        )
    }

    @Test("filesystem seam preserves a preexisting socket without bind or unlink")
    func fileSystemSeamPreservesPreexistingSocket() throws {
        let fixture = try SocketDirectoryFixture()
        defer { fixture.remove() }
        let fileSystem = RecordingUnixFileSystem(
            status: socketStatus(device: 7, inode: 11)
        )
        let listener = try DarwinPerformanceControlUnixListener(
            socketPath: fixture.socketPath,
            authenticator: RecordingAuthenticator(),
            fileSystem: fileSystem
        )
        #expect(throws: PerformanceControlTransportError.socketPathOccupied) {
            try listener.start()
        }
        listener.close()
        #expect(fileSystem.unlinkCallCount == 0)
    }

    @Test("filesystem seam only unlinks the recorded socket identity")
    func fileSystemSeamCleanupUsesIdentity() throws {
        let fixture = try SocketDirectoryFixture()
        defer { fixture.remove() }
        let parent = Darwin.open(
            fixture.directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        #expect(parent >= 0)
        defer { _ = Darwin.close(parent) }
        var parentStatus = stat()
        #expect(fstat(parent, &parentStatus) == 0)
        let recordedStatus = socketStatus(device: 7, inode: 11)
        let replacement = RecordingUnixFileSystem(
            status: socketStatus(device: 7, inode: 12)
        )
        #expect(!cleanupPerformanceControlSocket(
            parentDescriptor: parent,
            parentIdentity: PerformanceControlFileIdentity(parentStatus),
            name: "control.sock",
            socketIdentity: PerformanceControlFileIdentity(recordedStatus),
            system: LiveDarwinPerformanceControlUnixSystem(),
            fileSystem: replacement
        ))
        #expect(replacement.unlinkCallCount == 0)

        let matching = RecordingUnixFileSystem(
            status: recordedStatus,
            unlinkResult: -1
        )
        #expect(!cleanupPerformanceControlSocket(
            parentDescriptor: parent,
            parentIdentity: PerformanceControlFileIdentity(parentStatus),
            name: "control.sock",
            socketIdentity: PerformanceControlFileIdentity(recordedStatus),
            system: LiveDarwinPerformanceControlUnixSystem(),
            fileSystem: matching
        ))
        #expect(matching.unlinkCallCount == 1)
    }

    @Test(
        "listener close reports an authoritative unlink failure",
        .enabled(
            if: fileSystemUnixSocketsAvailable,
            "host sandbox must permit filesystem AF_UNIX bind"
        )
    )
    func listenerCloseReportsUnlinkFailure() throws {
        let fixture = try SocketDirectoryFixture()
        defer { fixture.remove() }
        let fileSystem = FailingUnlinkUnixFileSystem()
        let listener = try DarwinPerformanceControlUnixListener(
            socketPath: fixture.socketPath,
            authenticator: RecordingAuthenticator(),
            fileSystem: fileSystem
        )
        try listener.start()

        #expect(!listener.close())
        #expect(fileSystem.unlinkCallCount == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.socketPath))
        #expect(!listener.close())
        #expect(fileSystem.unlinkCallCount == 1)
    }

    @Test(
        "a preexisting socket is neither replaced nor deleted",
        .enabled(
            if: fileSystemUnixSocketsAvailable,
            "host sandbox must permit filesystem AF_UNIX bind"
        )
    )
    func preexistingSocketIsPreserved() throws {
        let fixture = try SocketDirectoryFixture()
        defer { fixture.remove() }
        let first = try DarwinPerformanceControlUnixListener(
            socketPath: fixture.socketPath
        )
        try first.start()
        defer { first.close() }
        let identity = try fileIdentity(at: fixture.socketPath)

        let second = try DarwinPerformanceControlUnixListener(
            socketPath: fixture.socketPath
        )
        #expect(throws: PerformanceControlTransportError.socketPathOccupied) {
            try second.start()
        }
        second.close()
        #expect(try fileIdentity(at: fixture.socketPath) == identity)
    }

    @Test(
        "listener cleanup preserves a replacement entry with a new identity",
        .enabled(
            if: fileSystemUnixSocketsAvailable,
            "host sandbox must permit filesystem AF_UNIX bind"
        )
    )
    func cleanupPreservesReplacement() throws {
        let fixture = try SocketDirectoryFixture()
        defer { fixture.remove() }
        let listener = try DarwinPerformanceControlUnixListener(
            socketPath: fixture.socketPath
        )
        try listener.start()
        #expect(unlink(fixture.socketPath) == 0)
        let replacement = Data("replacement".utf8)
        try replacement.write(to: URL(fileURLWithPath: fixture.socketPath))

        listener.close()
        #expect(
            try Data(contentsOf: URL(fileURLWithPath: fixture.socketPath))
                == replacement
        )
    }

    @Test(
        "client rejects a socket whose mode is not exact 0600 before auth",
        .enabled(
            if: fileSystemUnixSocketsAvailable,
            "host sandbox must permit filesystem AF_UNIX bind"
        )
    )
    func clientPreflightRejectsSocketMode() throws {
        let fixture = try SocketDirectoryFixture()
        defer { fixture.remove() }
        let listener = try DarwinPerformanceControlUnixListener(
            socketPath: fixture.socketPath
        )
        try listener.start()
        defer { listener.close() }
        #expect(chmod(fixture.socketPath, mode_t(0o660)) == 0)
        let authenticator = RecordingAuthenticator()

        #expect(throws: PerformanceControlTransportError.insecureSocket) {
            try DarwinPerformanceControlUnixClient.connectAuthenticated(
                socketPath: fixture.socketPath,
                expectedCollector: try expectedPeerIdentity(),
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                authenticator: authenticator
            )
        }
        #expect(authenticator.callCount == 0)
    }

    @Test("filesystem seam makes client mode rejection mandatory in sandboxes")
    func clientModePreflightUsesFileSystemSeam() throws {
        let fixture = try SocketDirectoryFixture()
        defer { fixture.remove() }
        var insecure = socketStatus(device: 7, inode: 11)
        insecure.st_mode = mode_t(S_IFSOCK) | mode_t(0o660)
        let authenticator = RecordingAuthenticator()
        #expect(throws: PerformanceControlTransportError.insecureSocket) {
            try DarwinPerformanceControlUnixClient.connectAuthenticated(
                socketPath: fixture.socketPath,
                expectedCollector: expectedPeerIdentity(),
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                authenticator: authenticator,
                fileSystem: RecordingUnixFileSystem(status: insecure)
            )
        }
        #expect(authenticator.callCount == 0)
    }

    @Test(
        "attestation failure closes the accepted fd without returning a connection",
        .enabled(
            if: fileSystemUnixSocketsAvailable,
            "host sandbox must permit filesystem AF_UNIX bind"
        )
    )
    func authenticationFailureIsFailClosed() async throws {
        let fixture = try SocketDirectoryFixture()
        defer { fixture.remove() }
        let listenerAuthenticator = RecordingAuthenticator(failAtCall: 1)
        let clientAuthenticator = RecordingAuthenticator()
        let listener = try DarwinPerformanceControlUnixListener(
            socketPath: fixture.socketPath,
            authenticator: listenerAuthenticator
        )
        try listener.start()
        defer { listener.close() }
        let expected = try expectedPeerIdentity()
        let clock = ContinuousClock()
        let acceptTask = Task.detached {
            try listener.acceptAuthenticated(
                expectedPeer: expected,
                deadline: clock.now.advanced(by: .seconds(2))
            )
        }
        let client = try DarwinPerformanceControlUnixClient
            .connectAuthenticated(
                socketPath: fixture.socketPath,
                expectedCollector: expected,
                deadline: clock.now.advanced(by: .seconds(2)),
                authenticator: clientAuthenticator
            )
        defer { client.close() }

        do {
            _ = try await acceptTask.value
            Issue.record("listener returned an unauthenticated connection")
        } catch let error as PerformanceControlTransportError {
            #expect(error == .authenticationFailed)
        }
        #expect(listenerAuthenticator.callCount == 1)
    }

    @Test("adopted-listener seam makes attestation failure fail closed")
    func adoptedListenerAuthenticationFailureIsFailClosed() throws {
        var listenerPair = [Int32](repeating: -1, count: 2)
        var acceptedPair = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &listenerPair) == 0)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &acceptedPair) == 0)
        defer {
            _ = Darwin.close(listenerPair[1])
            _ = Darwin.close(acceptedPair[1])
        }
        let authenticator = RecordingAuthenticator(failAtCall: 1)
        let listener = try DarwinPerformanceControlUnixListener(
            testingSocketPath: "/private/var/empty/control.sock",
            adoptingListeningDescriptor: listenerPair[0],
            authenticator: authenticator,
            system: SingleAcceptUnixSystem(accepted: acceptedPair[0])
        )
        defer { listener.close() }
        #expect(throws: PerformanceControlTransportError.authenticationFailed) {
            _ = try listener.acceptAuthenticated(
                expectedPeer: expectedPeerIdentity(),
                deadline: ContinuousClock().now.advanced(by: .seconds(1))
            )
        }
        #expect(authenticator.callCount == 1)
        var byte: UInt8 = 0
        #expect(Darwin.read(acceptedPair[1], &byte, 1) == 0)
    }

    @Test("adopted listener closes the fd but preserves an opaque authenticator error")
    func adoptedListenerPreservesOpaqueAuthenticationError() throws {
        var listenerPair = [Int32](repeating: -1, count: 2)
        var acceptedPair = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &listenerPair) == 0)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &acceptedPair) == 0)
        defer {
            _ = Darwin.close(listenerPair[1])
            _ = Darwin.close(acceptedPair[1])
        }
        let unexpected = SensitiveTransportUnexpectedError(
            description: "listener-auth-secret-64a9"
        )
        let listener = try DarwinPerformanceControlUnixListener(
            testingSocketPath: "/private/var/empty/control.sock",
            adoptingListeningDescriptor: listenerPair[0],
            authenticator: OpaqueThrowingAuthenticator(error: unexpected),
            system: SingleAcceptUnixSystem(accepted: acceptedPair[0])
        )
        defer { listener.close() }

        #expect(throws: unexpected) {
            _ = try listener.acceptAuthenticated(
                expectedPeer: expectedPeerIdentity(),
                deadline: ContinuousClock().now.advanced(by: .seconds(1))
            )
        }
        var byte: UInt8 = 0
        #expect(Darwin.read(acceptedPair[1], &byte, 1) == 0)
    }

    @Test(
        "client closes its fd but preserves an opaque authenticator error",
        .enabled(
            if: fileSystemUnixSocketsAvailable,
            "host sandbox must permit filesystem AF_UNIX bind"
        )
    )
    func clientPreservesOpaqueAuthenticationError() throws {
        let fixture = try SocketDirectoryFixture()
        defer { fixture.remove() }
        let listener = try DarwinPerformanceControlUnixListener(
            socketPath: fixture.socketPath,
            authenticator: RecordingAuthenticator()
        )
        try listener.start()
        defer { listener.close() }
        let unexpected = SensitiveTransportUnexpectedError(
            description: "client-auth-secret-785c"
        )

        #expect(throws: unexpected) {
            _ = try DarwinPerformanceControlUnixClient.connectAuthenticated(
                socketPath: fixture.socketPath,
                expectedCollector: expectedPeerIdentity(),
                deadline: ContinuousClock().now.advanced(by: .seconds(1)),
                authenticator: OpaqueThrowingAuthenticator(error: unexpected)
            )
        }
    }

    @Test("adopted listener authenticates before any framed I/O")
    func adoptedListenerAuthenticatesBeforeIO() throws {
        var listenerPair = [Int32](repeating: -1, count: 2)
        var acceptedPair = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &listenerPair) == 0)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &acceptedPair) == 0)
        defer {
            _ = Darwin.close(listenerPair[1])
            _ = Darwin.close(acceptedPair[1])
        }
        let system = SingleAcceptCountingUnixSystem(accepted: acceptedPair[0])
        let authenticator = RecordingAuthenticator {
            system.ioCallCount > 0
        }
        let listener = try DarwinPerformanceControlUnixListener(
            testingSocketPath: "/private/var/empty/control.sock",
            adoptingListeningDescriptor: listenerPair[0],
            authenticator: authenticator,
            system: system
        )
        defer { listener.close() }
        let connection = try listener.acceptAuthenticated(
            expectedPeer: expectedPeerIdentity(),
            deadline: ContinuousClock().now.advanced(by: .seconds(1))
        )
        defer { connection.close() }
        #expect(authenticator.callCount == 1)
        #expect(!authenticator.sawTransportIOBeforeAuthentication)
        try connection.send(
            challengeFrame(),
            deadline: ContinuousClock().now.advanced(by: .seconds(1))
        )
        #expect(system.ioCallCount > 0)
    }

    @Test("listener close wakes an active accept through its cancel pipe")
    func listenerCloseWakesActiveAccept() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { _ = Darwin.close(descriptors[1]) }
        let system = AlwaysEAGAINAcceptUnixSystem()
        let listener = try DarwinPerformanceControlUnixListener(
            testingSocketPath: "/private/var/empty/control.sock",
            adoptingListeningDescriptor: descriptors[0],
            authenticator: RecordingAuthenticator(),
            system: system
        )
        let acceptDone = DispatchSemaphore(value: 0)
        let observedError = LockedError()
        DispatchQueue.global().async {
            do {
                _ = try listener.acceptAuthenticated(
                    expectedPeer: expectedPeerIdentity(),
                    deadline: ContinuousClock().now.advanced(by: .seconds(30))
                )
            } catch {
                observedError.set(error)
            }
            acceptDone.signal()
        }
        #expect(system.pollEntered.wait(timeout: .now() + 1) == .success)
        let closeDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            listener.close()
            closeDone.signal()
        }
        #expect(acceptDone.wait(timeout: .now() + 1) == .success)
        #expect(closeDone.wait(timeout: .now() + 1) == .success)
        #expect(observedError.transportError == .closed)
        #expect(!system.didShutdownListener)
    }

    @Test("listener close cancels attestation before waiting for accept to drain")
    func listenerCloseCancelsBlockingAuthentication() throws {
        var listenerPair = [Int32](repeating: -1, count: 2)
        var acceptedPair = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &listenerPair) == 0)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &acceptedPair) == 0)
        defer {
            _ = Darwin.close(listenerPair[1])
            _ = Darwin.close(acceptedPair[1])
        }
        let system = SingleAcceptUnixSystem(accepted: acceptedPair[0])
        let authenticator = BlockingGateAuthenticator()
        let listener = try DarwinPerformanceControlUnixListener(
            testingSocketPath: "/private/var/empty/control.sock",
            adoptingListeningDescriptor: listenerPair[0],
            authenticator: authenticator,
            system: system
        )
        let acceptDone = DispatchSemaphore(value: 0)
        let observedError = LockedError()
        DispatchQueue.global().async {
            do {
                _ = try listener.acceptAuthenticated(
                    expectedPeer: expectedPeerIdentity(),
                    deadline: ContinuousClock().now.advanced(by: .seconds(30))
                )
            } catch {
                observedError.set(error)
            }
            acceptDone.signal()
        }
        #expect(authenticator.entered.wait(timeout: .now() + 1) == .success)
        let closeDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            listener.close()
            closeDone.signal()
        }
        #expect(system.acceptedShutdown.wait(timeout: .now() + 1) == .success)
        authenticator.allowGateCheck.signal()
        #expect(acceptDone.wait(timeout: .now() + 1) == .success)
        #expect(closeDone.wait(timeout: .now() + 1) == .success)
        #expect(observedError.transportError == .closed)
    }

    @Test("listener close does not wait for an authenticator that ignores cancellation")
    func listenerCloseDoesNotWaitForUncooperativeAuthenticator() throws {
        var listenerPair = [Int32](repeating: -1, count: 2)
        var acceptedPair = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &listenerPair) == 0)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &acceptedPair) == 0)
        defer {
            _ = Darwin.close(listenerPair[1])
            _ = Darwin.close(acceptedPair[1])
        }
        let system = SingleAcceptUnixSystem(accepted: acceptedPair[0])
        let authenticator = UncooperativeAuthenticator()
        let listener = try DarwinPerformanceControlUnixListener(
            testingSocketPath: "/private/var/empty/control.sock",
            adoptingListeningDescriptor: listenerPair[0],
            authenticator: authenticator,
            system: system
        )
        let acceptDone = DispatchSemaphore(value: 0)
        let observedError = LockedError()
        DispatchQueue.global().async {
            do {
                _ = try listener.acceptAuthenticated(
                    expectedPeer: expectedPeerIdentity(),
                    deadline: ContinuousClock().now.advanced(by: .seconds(30))
                )
            } catch {
                observedError.set(error)
            }
            acceptDone.signal()
        }
        #expect(authenticator.entered.wait(timeout: .now() + 1) == .success)
        let closeDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            listener.close()
            closeDone.signal()
        }
        #expect(closeDone.wait(timeout: .now() + 1) == .success)
        authenticator.allowReturn.signal()
        #expect(acceptDone.wait(timeout: .now() + 1) == .success)
        #expect(observedError.transportError == .closed)
    }

    @Test("one absolute deadline bounds blocking attestation")
    func authenticationUsesAcceptDeadline() throws {
        var listenerPair = [Int32](repeating: -1, count: 2)
        var acceptedPair = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &listenerPair) == 0)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &acceptedPair) == 0)
        defer {
            _ = Darwin.close(listenerPair[1])
            _ = Darwin.close(acceptedPair[1])
        }
        let system = SingleAcceptUnixSystem(accepted: acceptedPair[0])
        let listener = try DarwinPerformanceControlUnixListener(
            testingSocketPath: "/private/var/empty/control.sock",
            adoptingListeningDescriptor: listenerPair[0],
            authenticator: DeadlineGateAuthenticator(),
            system: system
        )
        defer { listener.close() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(20))
        #expect(throws: PerformanceControlTransportError.operationTimedOut) {
            _ = try listener.acceptAuthenticated(
                expectedPeer: expectedPeerIdentity(),
                deadline: deadline
            )
        }
        #expect(clock.now >= deadline)
    }
}

private final class LockedError: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    var transportError: PerformanceControlTransportError? {
        lock.lock()
        defer { lock.unlock() }
        return error as? PerformanceControlTransportError
    }
}

private final class RecordingUnixFileSystem:
    DarwinPerformanceControlUnixFileSystem,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let status: stat?
    private let unlinkResult: Int32
    private var unlinkCalls = 0

    init(status: stat?, unlinkResult: Int32 = 0) {
        self.status = status
        self.unlinkResult = unlinkResult
    }

    func entryStatus(parentDescriptor: Int32, name: String) throws -> stat? {
        status
    }

    func unlinkEntry(parentDescriptor: Int32, name: String) -> Int32 {
        lock.lock()
        unlinkCalls += 1
        lock.unlock()
        return unlinkResult
    }

    var unlinkCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unlinkCalls
    }
}

private final class FailingUnlinkUnixFileSystem:
    DarwinPerformanceControlUnixFileSystem,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let live = LiveDarwinPerformanceControlUnixFileSystem()
    private var unlinkCalls = 0

    func entryStatus(parentDescriptor: Int32, name: String) throws -> stat? {
        try live.entryStatus(parentDescriptor: parentDescriptor, name: name)
    }

    func unlinkEntry(parentDescriptor: Int32, name: String) -> Int32 {
        lock.lock()
        unlinkCalls += 1
        lock.unlock()
        return -1
    }

    var unlinkCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unlinkCalls
    }
}

private func socketStatus(device: dev_t, inode: ino_t) -> stat {
    var status = stat()
    status.st_dev = device
    status.st_ino = inode
    status.st_uid = geteuid()
    status.st_mode = mode_t(S_IFSOCK) | mode_t(0o600)
    return status
}

private final class BlockingGateAuthenticator:
    DarwinPerformanceControlTransportAuthenticating,
    @unchecked Sendable
{
    let entered = DispatchSemaphore(value: 0)
    let allowGateCheck = DispatchSemaphore(value: 0)

    func authenticate(
        connectedSocket: Int32,
        expected: PerformanceControlExpectedPeerIdentity,
        gate: DarwinPerformanceControlAuthenticationGate
    ) throws -> PerformanceControlAttestedPeer {
        entered.signal()
        allowGateCheck.wait()
        try gate.check()
        return attestedPeer()
    }
}

private struct DeadlineGateAuthenticator:
    DarwinPerformanceControlTransportAuthenticating
{
    func authenticate(
        connectedSocket: Int32,
        expected: PerformanceControlExpectedPeerIdentity,
        gate: DarwinPerformanceControlAuthenticationGate
    ) throws -> PerformanceControlAttestedPeer {
        while true {
            try gate.check()
        }
    }
}

private final class UncooperativeAuthenticator:
    DarwinPerformanceControlTransportAuthenticating,
    @unchecked Sendable
{
    let entered = DispatchSemaphore(value: 0)
    let allowReturn = DispatchSemaphore(value: 0)

    func authenticate(
        connectedSocket: Int32,
        expected: PerformanceControlExpectedPeerIdentity,
        gate: DarwinPerformanceControlAuthenticationGate
    ) throws -> PerformanceControlAttestedPeer {
        entered.signal()
        allowReturn.wait()
        return attestedPeer()
    }
}

private final class RecordingAuthenticator:
    DarwinPerformanceControlTransportAuthenticating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let ioObservation: (() -> Bool)?
    private let failAtCall: Int?
    private var calls = 0
    private var sawEarlyIO = false

    init(
        failAtCall: Int? = nil,
        ioObservation: (() -> Bool)? = nil
    ) {
        self.failAtCall = failAtCall
        self.ioObservation = ioObservation
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var sawTransportIOBeforeAuthentication: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawEarlyIO
    }

    func authenticate(
        connectedSocket: Int32,
        expected: PerformanceControlExpectedPeerIdentity,
        gate: DarwinPerformanceControlAuthenticationGate
    ) throws -> PerformanceControlAttestedPeer {
        try gate.check()
        let observedEarlyIO = ioObservation?() ?? false
        lock.lock()
        calls += 1
        sawEarlyIO = sawEarlyIO || observedEarlyIO
        let currentCall = calls
        lock.unlock()
        if currentCall == failAtCall {
            throw PerformanceControlPeerAuthenticationError
                .authenticationFailed
        }
        return attestedPeer()
    }
}

private struct SensitiveTransportUnexpectedError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    let description: String
}

private struct OpaqueThrowingAuthenticator:
    DarwinPerformanceControlTransportAuthenticating,
    Sendable
{
    let error: SensitiveTransportUnexpectedError

    func authenticate(
        connectedSocket: Int32,
        expected: PerformanceControlExpectedPeerIdentity,
        gate: DarwinPerformanceControlAuthenticationGate
    ) throws -> PerformanceControlAttestedPeer {
        try gate.check()
        throw error
    }
}

private class ForwardingUnixSystem:
    DarwinPerformanceControlUnixSystem,
    @unchecked Sendable
{
    let live = LiveDarwinPerformanceControlUnixSystem()

    var effectiveUserID: uid_t { live.effectiveUserID }
    var now: ContinuousClock.Instant { live.now }

    func poll(
        _ descriptor: UnsafeMutablePointer<pollfd>,
        count: nfds_t,
        timeoutMilliseconds: Int32
    ) -> Int32 {
        live.poll(
            descriptor,
            count: count,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    func accept(_ descriptor: Int32) -> Int32 {
        live.accept(descriptor)
    }

    func read(
        _ descriptor: Int32,
        into buffer: UnsafeMutableRawPointer,
        count: Int
    ) -> Int {
        live.read(descriptor, into: buffer, count: count)
    }

    func write(
        _ descriptor: Int32,
        from buffer: UnsafeRawPointer,
        count: Int
    ) -> Int {
        live.write(descriptor, from: buffer, count: count)
    }

    func close(_ descriptor: Int32) {
        live.close(descriptor)
    }

    func shutdown(_ descriptor: Int32) {
        live.shutdown(descriptor)
    }
}

private final class AlwaysEAGAINAcceptUnixSystem: ForwardingUnixSystem,
    @unchecked Sendable
{
    let pollEntered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var listener: Int32 = -1
    private(set) var didShutdownListener = false

    override func accept(_ descriptor: Int32) -> Int32 {
        lock.lock()
        listener = descriptor
        lock.unlock()
        errno = EAGAIN
        return -1
    }

    override func poll(
        _ descriptor: UnsafeMutablePointer<pollfd>,
        count: nfds_t,
        timeoutMilliseconds: Int32
    ) -> Int32 {
        pollEntered.signal()
        return super.poll(
            descriptor,
            count: count,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    override func shutdown(_ descriptor: Int32) {
        lock.lock()
        if descriptor == listener {
            didShutdownListener = true
        }
        lock.unlock()
        super.shutdown(descriptor)
    }
}

private class SingleAcceptUnixSystem: ForwardingUnixSystem,
    @unchecked Sendable
{
    let acceptedShutdown = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var accepted: Int32

    init(accepted: Int32) {
        self.accepted = accepted
    }

    override func accept(_ descriptor: Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard accepted >= 0 else {
            errno = EAGAIN
            return -1
        }
        let result = accepted
        accepted = -1
        return result
    }

    override func shutdown(_ descriptor: Int32) {
        acceptedShutdown.signal()
        super.shutdown(descriptor)
    }
}

private final class SingleAcceptCountingUnixSystem: SingleAcceptUnixSystem,
    @unchecked Sendable
{
    private let ioLock = NSLock()
    private var calls = 0

    var ioCallCount: Int {
        ioLock.lock()
        defer { ioLock.unlock() }
        return calls
    }

    override func read(
        _ descriptor: Int32,
        into buffer: UnsafeMutableRawPointer,
        count: Int
    ) -> Int {
        ioLock.lock()
        calls += 1
        ioLock.unlock()
        return super.read(descriptor, into: buffer, count: count)
    }

    override func write(
        _ descriptor: Int32,
        from buffer: UnsafeRawPointer,
        count: Int
    ) -> Int {
        ioLock.lock()
        calls += 1
        ioLock.unlock()
        return super.write(descriptor, from: buffer, count: count)
    }
}

private final class CountingUnixSystem: ForwardingUnixSystem,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var calls = 0

    var ioCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    override func read(
        _ descriptor: Int32,
        into buffer: UnsafeMutableRawPointer,
        count: Int
    ) -> Int {
        lock.lock()
        calls += 1
        lock.unlock()
        return super.read(descriptor, into: buffer, count: count)
    }

    override func write(
        _ descriptor: Int32,
        from buffer: UnsafeRawPointer,
        count: Int
    ) -> Int {
        lock.lock()
        calls += 1
        lock.unlock()
        return super.write(descriptor, from: buffer, count: count)
    }
}

private final class CappedUnixSystem: ForwardingUnixSystem,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let maximumTransfer: Int
    private let readDelayMicroseconds: useconds_t
    private let writeDelayMicroseconds: useconds_t
    private var interruptRead: Bool
    private var interruptWrite: Bool
    private(set) var didInterruptRead = false
    private(set) var didInterruptWrite = false

    init(
        maximumTransfer: Int,
        interruptFirstRead: Bool = false,
        interruptFirstWrite: Bool = false,
        readDelayMicroseconds: useconds_t = 0,
        writeDelayMicroseconds: useconds_t = 0
    ) {
        self.maximumTransfer = maximumTransfer
        interruptRead = interruptFirstRead
        interruptWrite = interruptFirstWrite
        self.readDelayMicroseconds = readDelayMicroseconds
        self.writeDelayMicroseconds = writeDelayMicroseconds
    }

    override func read(
        _ descriptor: Int32,
        into buffer: UnsafeMutableRawPointer,
        count: Int
    ) -> Int {
        lock.lock()
        if interruptRead {
            interruptRead = false
            didInterruptRead = true
            lock.unlock()
            errno = EINTR
            return -1
        }
        lock.unlock()
        let result = super.read(
            descriptor,
            into: buffer,
            count: min(count, maximumTransfer)
        )
        if readDelayMicroseconds > 0 { usleep(readDelayMicroseconds) }
        return result
    }

    override func write(
        _ descriptor: Int32,
        from buffer: UnsafeRawPointer,
        count: Int
    ) -> Int {
        lock.lock()
        if interruptWrite {
            interruptWrite = false
            didInterruptWrite = true
            lock.unlock()
            errno = EINTR
            return -1
        }
        lock.unlock()
        let result = super.write(
            descriptor,
            from: buffer,
            count: min(count, maximumTransfer)
        )
        if writeDelayMicroseconds > 0 { usleep(writeDelayMicroseconds) }
        return result
    }
}

private final class HUPUnixSystem: ForwardingUnixSystem,
    @unchecked Sendable
{
    override func read(
        _ descriptor: Int32,
        into buffer: UnsafeMutableRawPointer,
        count: Int
    ) -> Int {
        errno = EAGAIN
        return -1
    }

    override func poll(
        _ descriptor: UnsafeMutablePointer<pollfd>,
        count: nfds_t,
        timeoutMilliseconds: Int32
    ) -> Int32 {
        descriptor.pointee.revents = Int16(POLLHUP)
        return 1
    }
}

private final class WrongEUIDUnixSystem: ForwardingUnixSystem,
    @unchecked Sendable
{
    override var effectiveUserID: uid_t { live.effectiveUserID &+ 1 }
}

private final class BlockingReadUnixSystem: ForwardingUnixSystem,
    @unchecked Sendable
{
    let readEntered = DispatchSemaphore(value: 0)
    let allowRead = DispatchSemaphore(value: 0)

    override func read(
        _ descriptor: Int32,
        into buffer: UnsafeMutableRawPointer,
        count: Int
    ) -> Int {
        readEntered.signal()
        _ = allowRead.wait(timeout: .now() + 1)
        errno = EBADF
        return -1
    }
}

private final class BlockingPollUnixSystem: ForwardingUnixSystem,
    @unchecked Sendable
{
    let pollEntered = DispatchSemaphore(value: 0)
    let shutdownEntered = DispatchSemaphore(value: 0)
    let allowPoll = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pollingDescriptor: Int32 = -1
    private var isPolling = false
    private(set) var closedWhilePolling = false

    override func poll(
        _ descriptor: UnsafeMutablePointer<pollfd>,
        count: nfds_t,
        timeoutMilliseconds: Int32
    ) -> Int32 {
        lock.lock()
        pollingDescriptor = descriptor.pointee.fd
        isPolling = true
        lock.unlock()
        pollEntered.signal()
        _ = allowPoll.wait(timeout: .now() + 1)
        lock.lock()
        isPolling = false
        lock.unlock()
        errno = EBADF
        return -1
    }

    override func shutdown(_ descriptor: Int32) {
        lock.lock()
        let isActiveListener = isPolling && pollingDescriptor == descriptor
        lock.unlock()
        super.shutdown(descriptor)
        if isActiveListener { shutdownEntered.signal() }
    }

    override func close(_ descriptor: Int32) {
        lock.lock()
        if isPolling && pollingDescriptor == descriptor {
            closedWhilePolling = true
        }
        lock.unlock()
        super.close(descriptor)
    }
}

private struct SocketDirectoryFixture {
    let directory: URL
    let socketPath: String

    init(mode: mode_t = 0o700, socketName: String = "control.sock") throws {
        let suffix = UUID().uuidString.prefix(8)
        directory = URL(
            fileURLWithPath: "/private/tmp/rimeai-pc-\(suffix)",
            isDirectory: true
        )
        socketPath = directory.appendingPathComponent(socketName).path
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        guard chmod(directory.path, mode) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func challengeFrame() throws -> PerformanceControlWireFrame {
    try .challenge(
        peerRole: .helper,
        sessionID: PerformanceControlNonce(String(repeating: "1", count: 64)),
        planNonce: PerformanceControlNonce(String(repeating: "2", count: 64)),
        collectorNonce: PerformanceControlNonce(String(repeating: "3", count: 64))
    )
}

private func expectedPeerIdentity() throws
    -> PerformanceControlExpectedPeerIdentity
{
    try PerformanceControlExpectedPeerIdentity(
        expectedExecutablePath: "/usr/bin/true",
        expectedExecutableSHA256: String(repeating: "a", count: 64),
        expectedSigningIdentifier: "fun.wwcn.rimeai.test-peer",
        expectedTeamIdentifier: "A1B2C3D4E5",
        expectedCDHash: String(repeating: "b", count: 40)
    )
}

private func attestedPeer() -> PerformanceControlAttestedPeer {
    PerformanceControlAttestedPeer(
        pid: getpid(),
        euid: geteuid(),
        startToken: 1,
        pidVersion: 1,
        instanceID: String(repeating: "c", count: 64)
    )
}

private func connectionPair(
    system: any DarwinPerformanceControlUnixSystem =
        LiveDarwinPerformanceControlUnixSystem()
) throws -> (
    DarwinPerformanceControlAuthenticatedConnection,
    DarwinPerformanceControlAuthenticatedConnection
) {
    var sockets = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
        throw PerformanceControlTransportError.ioFailure
    }
    do {
        let first = try DarwinPerformanceControlAuthenticatedConnection(
            adoptingAuthenticatedSocket: sockets[0],
            attestedPeer: attestedPeer(),
            system: system
        )
        let second = try DarwinPerformanceControlAuthenticatedConnection(
            adoptingAuthenticatedSocket: sockets[1],
            attestedPeer: attestedPeer(),
            system: system
        )
        return (first, second)
    } catch {
        _ = Darwin.close(sockets[0])
        _ = Darwin.close(sockets[1])
        throw error
    }
}

private func connectionAndRawPeer(
    system: any DarwinPerformanceControlUnixSystem =
        LiveDarwinPerformanceControlUnixSystem()
) throws -> (DarwinPerformanceControlAuthenticatedConnection, Int32) {
    let (connection, peer, _) = try connectionRawPeerAndFD(system: system)
    return (connection, peer)
}

private func connectionRawPeerAndFD(
    system: any DarwinPerformanceControlUnixSystem =
        LiveDarwinPerformanceControlUnixSystem()
) throws -> (DarwinPerformanceControlAuthenticatedConnection, Int32, Int32) {
    var sockets = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
        throw PerformanceControlTransportError.ioFailure
    }
    do {
        return (
            try DarwinPerformanceControlAuthenticatedConnection(
                adoptingAuthenticatedSocket: sockets[0],
                attestedPeer: attestedPeer(),
                system: system
            ),
            sockets[1],
            sockets[0]
        )
    } catch {
        _ = Darwin.close(sockets[0])
        _ = Darwin.close(sockets[1])
        throw error
    }
}

private func framed(_ payload: Data) -> Data {
    lengthHeader(UInt32(payload.count)) + payload
}

private func lengthHeader(_ length: UInt32) -> Data {
    var encoded = length.bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}

private func writeRaw(_ data: Data, to descriptor: Int32) throws {
    var offset = 0
    while offset < data.count {
        let result = data.withUnsafeBytes { bytes in
            Darwin.write(
                descriptor,
                bytes.baseAddress!.advanced(by: offset),
                data.count - offset
            )
        }
        guard result > 0 else {
            if result < 0 && errno == EINTR { return }
            throw PerformanceControlTransportError.ioFailure
        }
        offset += result
    }
}

private func mode(at path: String) throws -> mode_t {
    var status = stat()
    guard lstat(path, &status) == 0 else {
        throw PerformanceControlTransportError.ioFailure
    }
    return status.st_mode & mode_t(0o7777)
}

private func fileIdentity(at path: String) throws -> [UInt64] {
    var status = stat()
    guard lstat(path, &status) == 0 else {
        throw PerformanceControlTransportError.ioFailure
    }
    return [UInt64(status.st_dev), UInt64(status.st_ino)]
}

private func addExtendedACL(to path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["+a", "\(NSUserName()) allow read", path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw PerformanceControlTransportError.ioFailure
    }
}

private let fileSystemUnixSocketsAvailable: Bool = {
    guard let fixture = try? SocketDirectoryFixture(socketName: "probe.sock")
    else {
        return false
    }
    defer { fixture.remove() }
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { _ = Darwin.close(descriptor) }

    var address = sockaddr_un()
    let bytes = Array(fixture.socketPath.utf8)
    let offset = MemoryLayout<sockaddr_un>.size
        - MemoryLayout.size(ofValue: address.sun_path)
    let length = offset + bytes.count + 1
    address.sun_len = UInt8(length)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: bytes)
        destination[bytes.count] = 0
    }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(length)) == 0
        }
    }
}()
