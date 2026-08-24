import Darwin
import Foundation
import RimeAIVoicePerformanceCollector
import RimeAIVoicePerformanceControlCore
import RimeAIVoicePerformanceControlDarwin

protocol DarwinVoicePerformanceTracerControlConnection:
    AnyObject,
    Sendable
{
    var attestedPeer: PerformanceControlAttestedPeer { get }

    func send(
        _ frame: PerformanceControlWireFrame,
        deadline: ContinuousClock.Instant
    ) throws

    func receive(
        deadline: ContinuousClock.Instant
    ) throws -> PerformanceControlWireFrame

    func close()
}

extension DarwinPerformanceControlAuthenticatedConnection:
    DarwinVoicePerformanceTracerControlConnection {}

protocol DarwinVoicePerformanceTracerControlListening:
    AnyObject,
    Sendable
{
    func acceptControlConnection(
        expectedPeer: PerformanceControlExpectedPeerIdentity,
        deadline: ContinuousClock.Instant
    ) throws -> any DarwinVoicePerformanceTracerControlConnection

    @discardableResult
    func close() -> Bool
}

extension DarwinPerformanceControlUnixListener:
    DarwinVoicePerformanceTracerControlListening
{
    func acceptControlConnection(
        expectedPeer: PerformanceControlExpectedPeerIdentity,
        deadline: ContinuousClock.Instant
    ) throws -> any DarwinVoicePerformanceTracerControlConnection {
        try acceptAuthenticated(
            expectedPeer: expectedPeer,
            deadline: deadline
        )
    }
}

struct DarwinVoicePerformanceTracerRUsageV6: Equatable, Sendable {
    let processStartToken: UInt64
    let processExitToken: UInt64
    let userCPUNanoseconds: UInt64
    let systemCPUNanoseconds: UInt64
    let energyNanojoules: UInt64
}

struct DarwinVoicePerformanceTracerBSDInfo: Equatable, Sendable {
    let processIdentifier: Int32
    let parentProcessIdentifier: Int32
    let processGroupIdentifier: Int32
}

enum DarwinVoicePerformanceTracerBSDProbe: Equatable, Sendable {
    case info(DarwinVoicePerformanceTracerBSDInfo)
    case noSuchProcess
    case interrupted
}

enum DarwinVoicePerformanceTracerProcessProbe: Equatable, Sendable {
    case usage(DarwinVoicePerformanceTracerRUsageV6)
    case noSuchProcess
    case interrupted
}

protocol DarwinVoicePerformanceTracerProcessSystem: Sendable {
    var now: ContinuousClock.Instant { get }

    func probe(processIdentifier: Int32) throws
        -> DarwinVoicePerformanceTracerProcessProbe
    func probeBSDInfo(processIdentifier: Int32) throws
        -> DarwinVoicePerformanceTracerBSDProbe
    func wait(for duration: Duration) throws
}

private enum DarwinVoicePerformanceTracerSystemError: Error {
    case failed
}

private struct LiveDarwinVoicePerformanceTracerProcessSystem:
    DarwinVoicePerformanceTracerProcessSystem
{
    private let clock = ContinuousClock()

    var now: ContinuousClock.Instant { clock.now }

    func probe(processIdentifier: Int32) throws
        -> DarwinVoicePerformanceTracerProcessProbe
    {
        var usage = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) {
                proc_pid_rusage(processIdentifier, RUSAGE_INFO_V6, $0)
            }
        }
        if status == 0 {
            return .usage(
                DarwinVoicePerformanceTracerRUsageV6(
                    processStartToken: usage.ri_proc_start_abstime,
                    processExitToken: usage.ri_proc_exit_abstime,
                    userCPUNanoseconds: usage.ri_user_time,
                    systemCPUNanoseconds: usage.ri_system_time,
                    energyNanojoules: usage.ri_energy_nj
                )
            )
        }
        switch errno {
        case ESRCH:
            return .noSuchProcess
        case EINTR:
            return .interrupted
        default:
            throw DarwinVoicePerformanceTracerSystemError.failed
        }
    }

    func probeBSDInfo(processIdentifier: Int32) throws
        -> DarwinVoicePerformanceTracerBSDProbe
    {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let receivedSize = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                $0,
                expectedSize
            )
        }
        if receivedSize == expectedSize {
            guard let pid = Int32(exactly: info.pbi_pid),
                  let parentPID = Int32(exactly: info.pbi_ppid),
                  let processGroupID = Int32(exactly: info.pbi_pgid)
            else {
                throw DarwinVoicePerformanceTracerSystemError.failed
            }
            return .info(
                DarwinVoicePerformanceTracerBSDInfo(
                    processIdentifier: pid,
                    parentProcessIdentifier: parentPID,
                    processGroupIdentifier: processGroupID
                )
            )
        }
        guard receivedSize == 0 else {
            throw DarwinVoicePerformanceTracerSystemError.failed
        }
        switch errno {
        case ESRCH:
            return .noSuchProcess
        case EINTR:
            return .interrupted
        default:
            throw DarwinVoicePerformanceTracerSystemError.failed
        }
    }

    func wait(for duration: Duration) throws {
        let components = duration.components
        guard duration > .zero,
              components.seconds >= 0,
              components.attoseconds >= 0
        else {
            throw DarwinVoicePerformanceTracerSystemError.failed
        }
        var seconds = components.seconds
        var nanoseconds = (
            components.attoseconds + 999_999_999
        ) / 1_000_000_000
        if nanoseconds == 1_000_000_000 {
            seconds += 1
            nanoseconds = 0
        }
        var request = timespec(
            tv_sec: Int(seconds),
            tv_nsec: Int(nanoseconds)
        )
        var remaining = timespec()
        while nanosleep(&request, &remaining) != 0 {
            guard errno == EINTR else {
                throw DarwinVoicePerformanceTracerSystemError.failed
            }
            request = remaining
        }
    }
}

public final class DarwinVoicePerformanceTracerTransport:
    VoicePerformanceTracerTransport,
    @unchecked Sendable
{
    public let controlSocketPath: String
    private let listener: any DarwinVoicePerformanceTracerControlListening
    private let processSystem: any DarwinVoicePerformanceTracerProcessSystem
    private let stateLock = NSLock()
    private var state = State.unbound

    private enum State {
        case unbound
        case awaitingDriver(VoicePerformanceTracerLaunchedDriverIdentity)
        case acceptingDriver(VoicePerformanceTracerLaunchedDriverIdentity)
        case ready(
            VoicePerformanceTracerLaunchedDriverIdentity,
            DarwinVoicePerformanceTracerRUsageV6
        )
        case acceptingHelper(
            VoicePerformanceTracerLaunchedDriverIdentity,
            DarwinVoicePerformanceTracerRUsageV6
        )
        case terminal
    }

    private enum AcceptContext {
        case driver(VoicePerformanceTracerLaunchedDriverIdentity)
        case helper(
            VoicePerformanceTracerLaunchedDriverIdentity,
            DarwinVoicePerformanceTracerRUsageV6
        )
    }

    public convenience init(socketPath: String) throws {
        let listener: DarwinPerformanceControlUnixListener
        do {
            listener = try DarwinPerformanceControlUnixListener(
                socketPath: socketPath
            )
            try listener.start()
        } catch {
            if let known = normalizedTracerTransportError(error) {
                throw known
            }
            throw error
        }
        self.init(
            controlSocketPath: socketPath,
            listener: listener,
            processSystem: LiveDarwinVoicePerformanceTracerProcessSystem()
        )
    }

    init(
        controlSocketPath: String = "/private/var/empty/control.sock",
        listener: any DarwinVoicePerformanceTracerControlListening,
        processSystem: any DarwinVoicePerformanceTracerProcessSystem
    ) {
        self.controlSocketPath = controlSocketPath
        self.listener = listener
        self.processSystem = processSystem
    }

    deinit {
        _ = listener.close()
    }

    public func bindLaunchedDriver(
        _ identity: VoicePerformanceTracerLaunchedDriverIdentity
    ) throws {
        stateLock.lock()
        guard case .unbound = state,
              identity.role == .driver,
              identity.pid > 0,
              identity.processStartToken > 0,
              identity.processGroupID == identity.pid
        else {
            state = .terminal
            stateLock.unlock()
            listener.close()
            throw VoicePerformanceTracerTransportError.failed
        }
        state = .awaitingDriver(identity)
        stateLock.unlock()
    }

    public func acceptAuthenticatedConnection(
        _ request: VoicePerformanceTracerPeerRequest,
        deadline: ContinuousClock.Instant
    ) throws -> any VoicePerformanceTracerConnection {
        do {
            let context = try reserveAccept(request)
            let expected = try PerformanceControlExpectedPeerIdentity(
                expectedExecutablePath: request.expectedExecutablePath,
                expectedExecutableSHA256:
                    request.expectedExecutableSHA256,
                expectedSigningIdentifier:
                    request.expectedSigningIdentifier,
                expectedTeamIdentifier: request.expectedTeamIdentifier,
                expectedCDHash: request.expectedCDHash
            )
            let controlConnection = try listener.acceptControlConnection(
                expectedPeer: expected,
                deadline: deadline
            )
            let driverUsage: DarwinVoicePerformanceTracerRUsageV6
            do {
                let peer = controlConnection.attestedPeer
                switch context {
                case .driver(let launchedDriver):
                    guard peer.pid == launchedDriver.pid,
                          peer.startToken
                            == launchedDriver.processStartToken
                    else {
                        throw VoicePerformanceTracerTransportError
                            .authenticationFailed
                    }
                    driverUsage = try verifyDriverGeneration(
                        launchedDriver,
                        deadline: deadline
                    )
                case .helper(
                    let launchedDriver,
                    let previousDriverUsage
                ):
                    driverUsage = try verifyHelperGeneration(
                        peer,
                        launchedDriver: launchedDriver,
                        previousDriverUsage: previousDriverUsage,
                        deadline: deadline
                    )
                }
            } catch let error as VoicePerformanceTracerTransportError {
                controlConnection.close()
                failTerminal()
                if error == .timedOut {
                    throw error
                }
                throw VoicePerformanceTracerTransportError
                    .authenticationFailed
            } catch is DarwinVoicePerformanceTracerSystemError {
                controlConnection.close()
                failTerminal()
                throw VoicePerformanceTracerTransportError
                    .authenticationFailed
            } catch {
                controlConnection.close()
                failTerminal()
                throw error
            }
            do {
                let connection = try DarwinVoicePerformanceTracerConnection(
                    controlConnection: controlConnection,
                    role: request.role,
                    processSystem: processSystem
                )
                guard completeAccept(
                    context,
                    driverUsage: driverUsage
                ) else {
                    throw VoicePerformanceTracerTransportError.failed
                }
                return connection
            } catch {
                controlConnection.close()
                failTerminal()
                throw error
            }
        } catch {
            failTerminal()
            if let known = normalizedTracerTransportError(error) {
                throw known
            }
            throw error
        }
    }

    @discardableResult
    public func close() -> Bool {
        failTerminal()
    }

    private func reserveAccept(
        _ request: VoicePerformanceTracerPeerRequest
    ) throws -> AcceptContext {
        stateLock.lock()
        let context: AcceptContext?
        switch (state, request.role, request.trial) {
        case (.awaitingDriver(let identity), .driver, nil):
            state = .acceptingDriver(identity)
            context = .driver(identity)
        case (
            .ready(let identity, let usage),
            .helper,
            let trial?
        ) where PerformanceControlSessionBinding.supportedTrials
            .contains(trial):
            state = .acceptingHelper(identity, usage)
            context = .helper(identity, usage)
        default:
            state = .terminal
            context = nil
        }
        stateLock.unlock()
        guard let context else {
            listener.close()
            throw VoicePerformanceTracerTransportError.failed
        }
        return context
    }

    private func completeAccept(
        _ context: AcceptContext,
        driverUsage: DarwinVoicePerformanceTracerRUsageV6
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch (state, context) {
        case (
            .acceptingDriver(let stateIdentity),
            .driver(let contextIdentity)
        ) where stateIdentity == contextIdentity:
            state = .ready(stateIdentity, driverUsage)
            return true
        case (
            .acceptingHelper(let stateIdentity, let stateUsage),
            .helper(let contextIdentity, let contextUsage)
        ) where stateIdentity == contextIdentity
            && stateUsage == contextUsage:
            state = .ready(stateIdentity, driverUsage)
            return true
        default:
            state = .terminal
            return false
        }
    }

    @discardableResult
    private func failTerminal() -> Bool {
        stateLock.lock()
        state = .terminal
        stateLock.unlock()
        return listener.close()
    }

    private func verifyDriverGeneration(
        _ identity: VoicePerformanceTracerLaunchedDriverIdentity,
        deadline: ContinuousClock.Instant
    ) throws -> DarwinVoicePerformanceTracerRUsageV6 {
        let usageA = try activeUsage(
            processIdentifier: identity.pid,
            deadline: deadline
        )
        let infoA = try liveBSDInfo(
            processIdentifier: identity.pid,
            deadline: deadline
        )
        let infoB = try liveBSDInfo(
            processIdentifier: identity.pid,
            deadline: deadline
        )
        let usageB = try activeUsage(
            processIdentifier: identity.pid,
            deadline: deadline
        )
        guard usageA.processStartToken == identity.processStartToken,
              usageB.processStartToken == identity.processStartToken,
              Self.countersDoNotRollBack(from: usageA, to: usageB),
              infoA == infoB,
              infoA.processIdentifier == identity.pid,
              infoA.processGroupIdentifier == identity.processGroupID
        else {
            throw VoicePerformanceTracerTransportError
                .authenticationFailed
        }
        return usageB
    }

    private func verifyHelperGeneration(
        _ peer: PerformanceControlAttestedPeer,
        launchedDriver: VoicePerformanceTracerLaunchedDriverIdentity,
        previousDriverUsage: DarwinVoicePerformanceTracerRUsageV6,
        deadline: ContinuousClock.Instant
    ) throws -> DarwinVoicePerformanceTracerRUsageV6 {
        guard peer.pid > 0,
              peer.pid != launchedDriver.pid,
              peer.startToken > 0
        else {
            throw VoicePerformanceTracerTransportError
                .authenticationFailed
        }
        let driverUsageA = try activeUsage(
            processIdentifier: launchedDriver.pid,
            deadline: deadline
        )
        let driverInfoA = try liveBSDInfo(
            processIdentifier: launchedDriver.pid,
            deadline: deadline
        )
        let helperUsageA = try activeUsage(
            processIdentifier: peer.pid,
            deadline: deadline
        )
        let helperInfoA = try liveBSDInfo(
            processIdentifier: peer.pid,
            deadline: deadline
        )
        let helperInfoB = try liveBSDInfo(
            processIdentifier: peer.pid,
            deadline: deadline
        )
        let helperUsageB = try activeUsage(
            processIdentifier: peer.pid,
            deadline: deadline
        )
        let driverInfoB = try liveBSDInfo(
            processIdentifier: launchedDriver.pid,
            deadline: deadline
        )
        let driverUsageB = try activeUsage(
            processIdentifier: launchedDriver.pid,
            deadline: deadline
        )
        guard driverUsageA.processStartToken
                == launchedDriver.processStartToken,
              driverUsageB.processStartToken
                == launchedDriver.processStartToken,
              Self.countersDoNotRollBack(
                from: previousDriverUsage,
                to: driverUsageA
              ),
              Self.countersDoNotRollBack(
                from: driverUsageA,
                to: driverUsageB
              ),
              driverInfoA == driverInfoB,
              driverInfoA.processIdentifier == launchedDriver.pid,
              driverInfoA.processGroupIdentifier
                == launchedDriver.processGroupID,
              helperUsageA.processStartToken == peer.startToken,
              helperUsageB.processStartToken == peer.startToken,
              Self.countersDoNotRollBack(
                from: helperUsageA,
                to: helperUsageB
              ),
              helperInfoA == helperInfoB,
              helperInfoA.processIdentifier == peer.pid,
              helperInfoA.parentProcessIdentifier
                == launchedDriver.pid,
              helperInfoA.processGroupIdentifier
                == launchedDriver.processGroupID
        else {
            throw VoicePerformanceTracerTransportError
                .authenticationFailed
        }
        return driverUsageB
    }

    private func activeUsage(
        processIdentifier: Int32,
        deadline: ContinuousClock.Instant
    ) throws -> DarwinVoicePerformanceTracerRUsageV6 {
        try requireTimeRemaining(deadline)
        let result = try processSystem.probe(
            processIdentifier: processIdentifier
        )
        try requireTimeRemaining(deadline)
        guard case .usage(let usage) = result,
              usage.processStartToken > 0,
              usage.processExitToken == 0
        else {
            throw VoicePerformanceTracerTransportError
                .authenticationFailed
        }
        return usage
    }

    private func liveBSDInfo(
        processIdentifier: Int32,
        deadline: ContinuousClock.Instant
    ) throws -> DarwinVoicePerformanceTracerBSDInfo {
        try requireTimeRemaining(deadline)
        let result = try processSystem.probeBSDInfo(
            processIdentifier: processIdentifier
        )
        try requireTimeRemaining(deadline)
        guard case .info(let info) = result else {
            throw VoicePerformanceTracerTransportError
                .authenticationFailed
        }
        return info
    }

    private func requireTimeRemaining(
        _ deadline: ContinuousClock.Instant
    ) throws {
        guard processSystem.now < deadline else {
            throw VoicePerformanceTracerTransportError.timedOut
        }
    }

    private static func countersDoNotRollBack(
        from earlier: DarwinVoicePerformanceTracerRUsageV6,
        to later: DarwinVoicePerformanceTracerRUsageV6
    ) -> Bool {
        later.userCPUNanoseconds >= earlier.userCPUNanoseconds
            && later.systemCPUNanoseconds
                >= earlier.systemCPUNanoseconds
            && later.energyNanojoules >= earlier.energyNanojoules
    }
}

final class DarwinVoicePerformanceTracerConnection:
    VoicePerformanceTracerConnection,
    @unchecked Sendable
{
    let attestedPeer: VoicePerformanceTracerAttestedPeer

    private let controlConnection:
        any DarwinVoicePerformanceTracerControlConnection
    private let role: PerformanceControlPeerRole
    private let processSystem: any DarwinVoicePerformanceTracerProcessSystem

    init(
        controlConnection:
            any DarwinVoicePerformanceTracerControlConnection,
        role: PerformanceControlPeerRole,
        processSystem: any DarwinVoicePerformanceTracerProcessSystem
    ) throws {
        let peer = controlConnection.attestedPeer
        do {
            attestedPeer = try VoicePerformanceTracerAttestedPeer(
                pid: peer.pid,
                effectiveUserID: peer.euid,
                processStartToken: peer.startToken,
                pidVersion: peer.pidVersion,
                instanceID: peer.instanceID
            )
        } catch is VoicePerformanceTracerCollectorError {
            throw VoicePerformanceTracerTransportError.authenticationFailed
        }
        self.controlConnection = controlConnection
        self.role = role
        self.processSystem = processSystem
    }

    func send(
        _ frame: PerformanceControlWireFrame,
        deadline: ContinuousClock.Instant
    ) throws {
        do {
            try controlConnection.send(frame, deadline: deadline)
        } catch {
            if let known = normalizedTracerTransportError(error) {
                throw known
            }
            throw error
        }
    }

    func receive(
        deadline: ContinuousClock.Instant
    ) throws -> PerformanceControlWireFrame {
        do {
            return try controlConnection.receive(deadline: deadline)
        } catch {
            if let known = normalizedTracerTransportError(error) {
                throw known
            }
            throw error
        }
    }

    func close() {
        controlConnection.close()
    }

    func closeAndConfirmPeerExit(
        deadline: ContinuousClock.Instant
    ) throws {
        controlConnection.close()
        guard role == .helper else {
            throw VoicePerformanceTracerTransportError.failed
        }
        var previousUsage: DarwinVoicePerformanceTracerRUsageV6?
        while true {
            guard processSystem.now < deadline else {
                throw VoicePerformanceTracerTransportError.timedOut
            }
            let probe: DarwinVoicePerformanceTracerProcessProbe
            do {
                probe = try processSystem.probe(
                    processIdentifier: attestedPeer.pid
                )
            } catch {
                if let known = normalizedTracerTransportError(error) {
                    throw known
                }
                throw error
            }
            guard processSystem.now < deadline else {
                throw VoicePerformanceTracerTransportError.timedOut
            }
            switch probe {
            case .noSuchProcess:
                return
            case .interrupted:
                continue
            case .usage(let usage):
                if usage.processStartToken
                    > attestedPeer.processStartToken
                {
                    return
                }
                guard usage.processStartToken
                        == attestedPeer.processStartToken
                else {
                    throw VoicePerformanceTracerTransportError.failed
                }
                if let previousUsage {
                    guard usage.userCPUNanoseconds
                            >= previousUsage.userCPUNanoseconds,
                          usage.systemCPUNanoseconds
                            >= previousUsage.systemCPUNanoseconds,
                          usage.energyNanojoules
                            >= previousUsage.energyNanojoules
                    else {
                        throw VoicePerformanceTracerTransportError.failed
                    }
                }
                if usage.processExitToken > 0 {
                    guard usage.processExitToken
                            >= usage.processStartToken
                    else {
                        throw VoicePerformanceTracerTransportError.failed
                    }
                    return
                }
                previousUsage = usage
            }
            let now = processSystem.now
            guard now < deadline else {
                throw VoicePerformanceTracerTransportError.timedOut
            }
            let remaining = now.duration(to: deadline)
            do {
                try processSystem.wait(
                    for: min(remaining, Duration.milliseconds(10))
                )
            } catch {
                if let known = normalizedTracerTransportError(error) {
                    throw known
                }
                throw error
            }
        }
    }
}

func normalizedTracerTransportError(
    _ error: any Error
) -> VoicePerformanceTracerTransportError? {
    if let error = error as? VoicePerformanceTracerTransportError {
        return error
    }
    if let error = error as? PerformanceControlTransportError {
        switch error {
        case .operationTimedOut:
            return .timedOut
        case .peerDisconnected:
            return .disconnected
        case .authenticationFailed:
            return .authenticationFailed
        default:
            return .failed
        }
    }
    if error is PerformanceControlPeerAuthenticationError {
        return .authenticationFailed
    }
    if error is PerformanceControlError
        || error is DarwinVoicePerformanceTracerSystemError
    {
        return .failed
    }
    return nil
}
