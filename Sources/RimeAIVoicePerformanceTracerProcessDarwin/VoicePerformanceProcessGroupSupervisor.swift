import Darwin
import Foundation

public struct VoicePerformanceSupervisedProcessGeneration: Equatable, Hashable,
    Sendable
{
    public let pid: Int32
    public let startToken: UInt64
    public let processGroupID: Int32

    public init(pid: Int32, startToken: UInt64, processGroupID: Int32) {
        self.pid = pid
        self.startToken = startToken
        self.processGroupID = processGroupID
    }
}

public struct VoicePerformanceLiveProcessGenerationReader: Sendable {
    private let system: any VoicePerformanceProcessGroupSystem

    public init() {
        system = DarwinVoicePerformanceProcessGroupSystem()
    }

    init(system: any VoicePerformanceProcessGroupSystem) {
        self.system = system
    }

    public func currentGeneration() throws
        -> VoicePerformanceSupervisedProcessGeneration
    {
        let pid = system.currentProcessID
        guard pid > 1 else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        do {
            guard let generation = try system.generation(pid: pid),
                generation.pid == pid,
                generation.startToken > 0,
                generation.processGroupID > 1
            else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
            return generation
        } catch {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
    }
}

enum VoicePerformanceTerminationSignal: Equatable, Sendable {
    case terminate
    case kill
}

enum VoicePerformanceWaitOutcome: Equatable, Sendable {
    case running
    case exited(code: Int32)
    case signaled(signal: Int32)
}

protocol VoicePerformanceProcessGroupSystem: Sendable {
    var currentProcessID: Int32 { get }
    func setProcessGroup(pid: Int32, processGroupID: Int32) throws
    func generation(pid: Int32) throws
        -> VoicePerformanceSupervisedProcessGeneration?
    func signalProcessGroup(
        _ signal: VoicePerformanceTerminationSignal,
        processGroupID: Int32
    ) throws
    func signalProcess(
        _ signal: VoicePerformanceTerminationSignal,
        pid: Int32
    ) throws
    func processGroupHasLiveProcesses(processGroupID: Int32) throws -> Bool
    func processGroupLiveProcessesExactlyMatch(
        processGroupID: Int32,
        expectedProcessIDs: Set<Int32>
    ) throws -> Bool
    func peekNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome
    func waitNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome
    func currentContinuousNanoseconds() throws -> UInt64
    func sleep(nanoseconds: UInt64) throws
}

struct DarwinVoicePerformanceProcessGroupSystem:
    VoicePerformanceProcessGroupSystem, Sendable
{
    var currentProcessID: Int32 { getpid() }

    func setProcessGroup(pid: Int32, processGroupID: Int32) throws {
        guard Darwin.setpgid(pid, processGroupID) == 0 else {
            throw VoicePerformancePOSIXError(code: errno)
        }
    }

    func generation(pid: Int32) throws
        -> VoicePerformanceSupervisedProcessGeneration?
    {
        guard let first = try usage(pid: pid) else { return nil }
        let firstProcessGroupID = Darwin.getpgid(pid)
        if firstProcessGroupID < 0 {
            if errno == ESRCH { return nil }
            throw VoicePerformancePOSIXError(code: errno)
        }
        guard let second = try usage(pid: pid) else { return nil }
        let secondProcessGroupID = Darwin.getpgid(pid)
        if secondProcessGroupID < 0 {
            if errno == ESRCH { return nil }
            throw VoicePerformancePOSIXError(code: errno)
        }
        guard let third = try usage(pid: pid) else { return nil }
        guard first.ri_proc_start_abstime > 0,
            first.ri_proc_start_abstime == second.ri_proc_start_abstime,
            second.ri_proc_start_abstime == third.ri_proc_start_abstime,
            firstProcessGroupID == secondProcessGroupID
        else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        return .init(
            pid: pid,
            startToken: third.ri_proc_start_abstime,
            processGroupID: secondProcessGroupID
        )
    }

    func signalProcessGroup(
        _ signal: VoicePerformanceTerminationSignal,
        processGroupID: Int32
    ) throws {
        guard processGroupID > 1 else {
            throw VoicePerformanceTracerProcessError.processGroupFailure
        }
        guard Darwin.kill(-processGroupID, rawSignal(signal)) == 0 else {
            throw VoicePerformancePOSIXError(code: errno)
        }
    }

    func signalProcess(
        _ signal: VoicePerformanceTerminationSignal,
        pid: Int32
    ) throws {
        guard pid > 1 else {
            throw VoicePerformanceTracerProcessError.processGroupFailure
        }
        guard Darwin.kill(pid, rawSignal(signal)) == 0 else {
            throw VoicePerformancePOSIXError(code: errno)
        }
    }

    func processGroupHasLiveProcesses(processGroupID: Int32) throws -> Bool {
        try !liveProcessIDs(processGroupID: processGroupID).isEmpty
    }

    func processGroupLiveProcessesExactlyMatch(
        processGroupID: Int32,
        expectedProcessIDs: Set<Int32>
    ) throws -> Bool {
        try liveProcessIDs(processGroupID: processGroupID)
            == expectedProcessIDs
    }

    private func liveProcessIDs(processGroupID: Int32) throws -> Set<Int32> {
        guard processGroupID > 1 else {
            throw VoicePerformanceTracerProcessError.processGroupFailure
        }
        let type = UInt32(PROC_PGRP_ONLY)
        let typeInfo = UInt32(bitPattern: processGroupID)
        errno = 0
        let requiredBytes = proc_listpids(type, typeInfo, nil, 0)
        if requiredBytes == 0 {
            guard errno == 0 || errno == ESRCH else {
                throw VoicePerformancePOSIXError(code: errno)
            }
            return []
        }
        guard requiredBytes > 0 else {
            throw VoicePerformancePOSIXError(code: errno)
        }
        var capacity = max(
            Int(requiredBytes) + 32 * MemoryLayout<pid_t>.stride,
            256 * MemoryLayout<pid_t>.stride
        )
        for _ in 0..<8 {
            guard capacity <= 1_048_576 else {
                throw VoicePerformanceTracerProcessError.processGroupFailure
            }
            var pids = [pid_t](
                repeating: 0,
                count: capacity / MemoryLayout<pid_t>.stride
            )
            errno = 0
            let filledBytes = pids.withUnsafeMutableBytes { buffer in
                proc_listpids(
                    type,
                    typeInfo,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }
            if filledBytes == 0 {
                guard errno == 0 || errno == ESRCH else {
                    throw VoicePerformancePOSIXError(code: errno)
                }
                return []
            }
            guard filledBytes > 0 else {
                throw VoicePerformancePOSIXError(code: errno)
            }
            guard Int(filledBytes) < capacity else {
                capacity *= 2
                continue
            }
            let count = min(
                pids.count,
                Int(filledBytes) / MemoryLayout<pid_t>.stride
            )
            var live: Set<Int32> = []
            for pid in pids.prefix(count) where pid > 0 {
                if let usage = try usage(pid: pid),
                    usage.ri_proc_exit_abstime == 0
                {
                    live.insert(pid)
                }
            }
            return live
        }
        throw VoicePerformanceTracerProcessError.processGroupFailure
    }

    func waitNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        var status: Int32 = 0
        let result = Darwin.waitpid(pid, &status, WNOHANG)
        if result == 0 { return .running }
        guard result == pid else {
            throw VoicePerformancePOSIXError(code: errno)
        }
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 {
            return .exited(code: (status >> 8) & 0xff)
        }
        return .signaled(signal: terminationSignal)
    }

    func peekNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        var information = siginfo_t()
        let result = Darwin.waitid(
            P_PID,
            id_t(pid),
            &information,
            WEXITED | WNOHANG | WNOWAIT
        )
        guard result == 0 else {
            throw VoicePerformancePOSIXError(code: errno)
        }
        if information.si_pid == 0 { return .running }
        if information.si_code == CLD_EXITED {
            return .exited(code: information.si_status)
        }
        return .signaled(signal: information.si_status)
    }

    func currentContinuousNanoseconds() throws -> UInt64 {
        try VoicePerformanceContinuousDeadline.currentNanoseconds()
    }

    func sleep(nanoseconds: UInt64) throws {
        var request = timespec(
            tv_sec: Int(nanoseconds / 1_000_000_000),
            tv_nsec: Int(nanoseconds % 1_000_000_000)
        )
        var remainder = timespec()
        while Darwin.nanosleep(&request, &remainder) != 0 {
            guard errno == EINTR else {
                throw VoicePerformancePOSIXError(code: errno)
            }
            request = remainder
        }
    }

    private func rawSignal(_ signal: VoicePerformanceTerminationSignal) -> Int32 {
        signal == .terminate ? SIGTERM : SIGKILL
    }

    private func usage(pid: Int32) throws -> rusage_info_v6? {
        var value = rusage_info_v6()
        errno = 0
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        if result == 0 { return value }
        let code = errno
        if code == ESRCH { return nil }
        throw VoicePerformancePOSIXError(code: code)
    }
}

private struct VoicePerformanceSupervisorOperations {
    static let terminateGraceNanoseconds: UInt64 = 2_000_000_000
    static let killGraceNanoseconds: UInt64 = 3_000_000_000
    static let driverSuccessWaitCapNanoseconds: UInt64 = 15_000_000_000
    static let helperSuccessWaitCapNanoseconds: UInt64 = 125_000_000_000
    static let pollNanoseconds: UInt64 = 10_000_000

    let system: any VoicePerformanceProcessGroupSystem

    func setProcessGroup(pid: Int32, processGroupID: Int32) throws {
        while true {
            do {
                try system.setProcessGroup(
                    pid: pid,
                    processGroupID: processGroupID
                )
                return
            } catch let error as VoicePerformancePOSIXError where error.code == EINTR {
                continue
            } catch {
                throw VoicePerformanceTracerProcessError.processGroupFailure
            }
        }
    }

    func probeGeneration(pid: Int32) throws
        -> VoicePerformanceSupervisedProcessGeneration?
    {
        while true {
            do {
                return try system.generation(pid: pid)
            } catch let error as VoicePerformancePOSIXError where error.code == EINTR {
                continue
            } catch {
                throw VoicePerformanceTracerProcessError.processGenerationMismatch
            }
        }
    }

    func wait(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        while true {
            do {
                return try system.waitNonBlocking(pid: pid)
            } catch let error as VoicePerformancePOSIXError where error.code == EINTR {
                continue
            } catch {
                throw VoicePerformanceTracerProcessError.processWaitFailed
            }
        }
    }

    func peek(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        while true {
            do {
                return try system.peekNonBlocking(pid: pid)
            } catch let error as VoicePerformancePOSIXError where error.code == EINTR {
                continue
            } catch {
                throw VoicePerformanceTracerProcessError.processWaitFailed
            }
        }
    }

    func groupHasLiveProcesses(_ processGroupID: Int32) throws -> Bool {
        while true {
            do {
                return try system.processGroupHasLiveProcesses(
                    processGroupID: processGroupID
                )
            } catch let error as VoicePerformancePOSIXError where error.code == EINTR {
                continue
            } catch let error as VoicePerformancePOSIXError where error.code == ESRCH {
                return false
            } catch {
                throw VoicePerformanceTracerProcessError.processGroupFailure
            }
        }
    }

    func groupLiveProcessesExactlyMatch(
        _ processGroupID: Int32,
        expectedProcessIDs: Set<Int32>
    ) throws -> Bool {
        while true {
            do {
                return try system.processGroupLiveProcessesExactlyMatch(
                    processGroupID: processGroupID,
                    expectedProcessIDs: expectedProcessIDs
                )
            } catch let error as VoicePerformancePOSIXError
                where error.code == EINTR
            {
                continue
            } catch let error as VoicePerformancePOSIXError
                where error.code == ESRCH
            {
                return false
            } catch {
                throw VoicePerformanceTracerProcessError.processGroupFailure
            }
        }
    }

    func currentNanoseconds() throws -> UInt64 {
        do {
            return try system.currentContinuousNanoseconds()
        } catch {
            throw VoicePerformanceTracerProcessError.processWaitFailed
        }
    }

    func deadline(after duration: UInt64) throws -> UInt64 {
        let (value, overflow) = try currentNanoseconds()
            .addingReportingOverflow(duration)
        guard !overflow else {
            throw VoicePerformanceTracerProcessError.processWaitFailed
        }
        return value
    }

    func successDeadline(
        boundedBy globalDeadline: VoicePerformanceContinuousDeadline,
        maximumWaitNanoseconds: UInt64
    ) throws -> UInt64 {
        let now = try currentNanoseconds()
        let (phaseDeadline, overflow) = now.addingReportingOverflow(
            maximumWaitNanoseconds
        )
        return min(
            globalDeadline.nanoseconds,
            overflow ? UInt64.max : phaseDeadline
        )
    }

    func sleep(until deadline: UInt64) throws {
        let now = try currentNanoseconds()
        guard now < deadline else { return }
        do {
            try system.sleep(
                nanoseconds: min(Self.pollNanoseconds, deadline - now)
            )
        } catch let error as VoicePerformancePOSIXError where error.code == EINTR {
            return
        } catch {
            throw VoicePerformanceTracerProcessError.processWaitFailed
        }
    }
}

public final class VoicePerformanceCollectorDriverSupervisor {
    private struct DriverOwnership {
        let generation: VoicePerformanceSupervisedProcessGeneration
        var hasExclusiveProcessGroup: Bool
        var isPrepared: Bool
    }

    private let operations: VoicePerformanceSupervisorOperations
    private var driverOwnership: DriverOwnership?

    public var driverGeneration: VoicePerformanceSupervisedProcessGeneration? {
        driverOwnership?.generation
    }

    public convenience init() {
        self.init(system: DarwinVoicePerformanceProcessGroupSystem())
    }

    init(system: any VoicePerformanceProcessGroupSystem) {
        operations = .init(system: system)
    }

    public func adoptSpawnedDriverForCleanup(
        expected: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        guard driverOwnership == nil,
            expected.pid > 1,
            expected.startToken > 0,
            expected.processGroupID == expected.pid
        else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }

        driverOwnership = .init(
            generation: expected,
            hasExclusiveProcessGroup: false,
            isPrepared: false
        )

        do {
            // A successful WNOWAIT observation proves this is our direct,
            // unreaped child. Its PID cannot be reused while ownership is held.
            guard try operations.peek(pid: expected.pid) == .running else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
            guard let observed = try operations.probeGeneration(
                pid: expected.pid
            ),
                observed.pid == expected.pid,
                observed.startToken == expected.startToken
            else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
            driverOwnership?.hasExclusiveProcessGroup =
                observed.processGroupID == expected.processGroupID
        } catch {
            // Until the exact pgrp has been observed, only the raw spawner has
            // enough authority to handle a zombie leader plus live descendants.
            driverOwnership = nil
            throw error
        }
    }

    public func prepareDriver(
        expected: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        if driverOwnership == nil {
            try adoptSpawnedDriverForCleanup(expected: expected)
        }
        guard var ownership = driverOwnership,
            ownership.generation == expected,
            !ownership.isPrepared
        else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        if !ownership.hasExclusiveProcessGroup {
            try operations.setProcessGroup(
                pid: expected.pid,
                processGroupID: expected.pid
            )
            ownership.hasExclusiveProcessGroup = true
            driverOwnership = ownership
        }
        guard try operations.probeGeneration(pid: expected.pid) == expected else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        ownership.isPrepared = true
        driverOwnership = ownership
    }

    public func abortSpawnedDriver(
        exactGeneration: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        guard driverOwnership?.generation == exactGeneration else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        try terminateDriverGroupAndReap()
    }

    @discardableResult
    public func waitForSucceededDriver(
        until globalDeadline: VoicePerformanceContinuousDeadline
    ) throws -> Int32 {
        guard let ownership = driverOwnership, ownership.isPrepared else {
            throw VoicePerformanceTracerProcessError.processWaitFailed
        }
        let driver = ownership.generation
        let deadline = try operations.successDeadline(
            boundedBy: globalDeadline,
            maximumWaitNanoseconds:
                VoicePerformanceSupervisorOperations
                    .driverSuccessWaitCapNanoseconds
        )
        while true {
            guard try operations.currentNanoseconds() < deadline else {
                throw VoicePerformanceTracerProcessError
                    .processTerminationTimedOut
            }
            let observed = try operations.peek(pid: driver.pid)
            switch observed {
            case .running:
                guard try operations.probeGeneration(pid: driver.pid) == driver
                else {
                    throw VoicePerformanceTracerProcessError
                        .processGenerationMismatch
                }
            case .exited(let code):
                guard code == 0 else {
                    throw VoicePerformanceTracerProcessError
                        .processExitedUnsuccessfully
                }
                if try !operations.groupHasLiveProcesses(
                    driver.processGroupID
                ) {
                    guard try operations.wait(pid: driver.pid) == observed else {
                        throw VoicePerformanceTracerProcessError
                            .processWaitFailed
                    }
                    driverOwnership = nil
                    return code
                }
            case .signaled:
                throw VoicePerformanceTracerProcessError
                    .processExitedUnsuccessfully
            }
            try operations.sleep(until: deadline)
        }
    }

    @discardableResult
    public func waitForSucceededDriver(
        exactGeneration: VoicePerformanceSupervisedProcessGeneration,
        until globalDeadline: VoicePerformanceContinuousDeadline
    ) throws -> Int32 {
        guard driverOwnership?.generation == exactGeneration else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        return try waitForSucceededDriver(until: globalDeadline)
    }

    @discardableResult
    public func reapSucceededDriver() throws -> Int32 {
        guard let ownership = driverOwnership, ownership.isPrepared else {
            throw VoicePerformanceTracerProcessError.processWaitFailed
        }
        let driver = ownership.generation
        let observed = try operations.peek(pid: driver.pid)
        switch observed {
        case .running:
            guard try operations.probeGeneration(pid: driver.pid) == driver else {
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
            throw VoicePerformanceTracerProcessError.processWaitFailed
        case .exited(let code):
            guard try !operations.groupHasLiveProcesses(driver.processGroupID)
            else {
                throw VoicePerformanceTracerProcessError.processGroupFailure
            }
            guard code == 0 else {
                throw VoicePerformanceTracerProcessError
                    .processExitedUnsuccessfully
            }
            guard try operations.wait(pid: driver.pid) == observed else {
                throw VoicePerformanceTracerProcessError.processWaitFailed
            }
            driverOwnership = nil
            return code
        case .signaled:
            throw VoicePerformanceTracerProcessError.processExitedUnsuccessfully
        }
    }

    public func terminateDriverGroupAndReap() throws {
        guard var ownership = driverOwnership else { return }
        if !ownership.hasExclusiveProcessGroup,
            let observed = try? operations.probeGeneration(
                pid: ownership.generation.pid
            ),
            observed.pid == ownership.generation.pid,
            observed.startToken == ownership.generation.startToken,
            observed.processGroupID
                == ownership.generation.processGroupID
        {
            ownership.hasExclusiveProcessGroup = true
            driverOwnership = ownership
        }
        guard ownership.hasExclusiveProcessGroup else {
            try terminateAdoptedDriverAndReap(ownership.generation)
            return
        }
        let driver = ownership.generation
        if try !operations.groupHasLiveProcesses(driver.processGroupID) {
            try reapTerminatedDriver(driver)
            return
        }
        try verifyExclusiveGroupOwnership(driver)
        let termDelivered = try signalGroupOrConfirmGone(
            .terminate,
            driver: driver
        )
        if termDelivered {
            let deadline = try operations.deadline(
                after: VoicePerformanceSupervisorOperations
                    .terminateGraceNanoseconds
            )
            if try !waitForGroupToBecomeIdle(driver: driver, until: deadline) {
                try verifyExclusiveGroupOwnership(driver)
                let killDelivered = try signalGroupOrConfirmGone(
                    .kill,
                    driver: driver
                )
                if killDelivered {
                    let killDeadline = try operations.deadline(
                        after: VoicePerformanceSupervisorOperations
                            .killGraceNanoseconds
                    )
                    guard try waitForGroupToBecomeIdle(
                        driver: driver,
                        until: killDeadline
                    ) else {
                        throw VoicePerformanceTracerProcessError
                            .processTerminationTimedOut
                    }
                }
            }
        }
        try reapTerminatedDriver(driver)
    }

    private func verifyExclusiveGroupOwnership(
        _ driver: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        switch try operations.peek(pid: driver.pid) {
        case .exited, .signaled:
            // WNOWAIT keeps the direct child unreaped, so its PID cannot be
            // reused while it continues to anchor this exclusive pgrp.
            return
        case .running:
            if try operations.probeGeneration(pid: driver.pid) == driver {
                return
            }
            // The leader can become a zombie between the two observations.
            switch try operations.peek(pid: driver.pid) {
            case .exited, .signaled:
                return
            case .running:
                throw VoicePerformanceTracerProcessError
                    .processGenerationMismatch
            }
        }
    }

    private func signalGroupOrConfirmGone(
        _ signal: VoicePerformanceTerminationSignal,
        driver: VoicePerformanceSupervisedProcessGeneration
    ) throws -> Bool {
        while true {
            do {
                try operations.system.signalProcessGroup(
                    signal,
                    processGroupID: driver.processGroupID
                )
                return true
            } catch let error as VoicePerformancePOSIXError where error.code == EINTR {
                continue
            } catch let error as VoicePerformancePOSIXError where error.code == ESRCH {
                guard try !operations.groupHasLiveProcesses(
                    driver.processGroupID
                ) else {
                    throw VoicePerformanceTracerProcessError.processGroupFailure
                }
                return false
            } catch {
                throw VoicePerformanceTracerProcessError.processGroupFailure
            }
        }
    }

    private func waitForGroupToBecomeIdle(
        driver: VoicePerformanceSupervisedProcessGeneration,
        until deadline: UInt64
    ) throws -> Bool {
        while try operations.groupHasLiveProcesses(driver.processGroupID) {
            try verifyExclusiveGroupOwnership(driver)
            guard try operations.currentNanoseconds() < deadline else {
                return false
            }
            try operations.sleep(until: deadline)
        }
        return true
    }

    private func reapTerminatedDriver(
        _ driver: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        guard try !operations.groupHasLiveProcesses(driver.processGroupID) else {
            throw VoicePerformanceTracerProcessError.processGroupFailure
        }
        switch try operations.wait(pid: driver.pid) {
        case .running:
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        case .exited, .signaled:
            driverOwnership = nil
        }
        guard try !operations.groupHasLiveProcesses(driver.processGroupID) else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
    }

    private func terminateAdoptedDriverAndReap(
        _ driver: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        if try reapAdoptedDriverIfExited(driver) { return }
        try signalAdoptedDriver(.terminate, driver: driver)
        let terminateDeadline = try operations.deadline(
            after: VoicePerformanceSupervisorOperations
                .terminateGraceNanoseconds
        )
        if try !waitForAdoptedDriverExit(driver, until: terminateDeadline) {
            try signalAdoptedDriver(.kill, driver: driver)
            let killDeadline = try operations.deadline(
                after: VoicePerformanceSupervisorOperations
                    .killGraceNanoseconds
            )
            guard try waitForAdoptedDriverExit(driver, until: killDeadline)
            else {
                throw VoicePerformanceTracerProcessError
                    .processTerminationTimedOut
            }
        }
    }

    private func signalAdoptedDriver(
        _ signal: VoicePerformanceTerminationSignal,
        driver: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        guard try operations.peek(pid: driver.pid) == .running else {
            _ = try reapAdoptedDriverIfExited(driver)
            return
        }
        while true {
            do {
                try operations.system.signalProcess(signal, pid: driver.pid)
                return
            } catch let error as VoicePerformancePOSIXError
                where error.code == EINTR
            {
                continue
            } catch let error as VoicePerformancePOSIXError
                where error.code == ESRCH
            {
                guard try reapAdoptedDriverIfExited(driver) else {
                    throw VoicePerformanceTracerProcessError
                        .processGenerationMismatch
                }
                return
            } catch {
                throw VoicePerformanceTracerProcessError.processGroupFailure
            }
        }
    }

    private func waitForAdoptedDriverExit(
        _ driver: VoicePerformanceSupervisedProcessGeneration,
        until deadline: UInt64
    ) throws -> Bool {
        while true {
            if try reapAdoptedDriverIfExited(driver) { return true }
            guard try operations.currentNanoseconds() < deadline else {
                return false
            }
            try operations.sleep(until: deadline)
        }
    }

    private func reapAdoptedDriverIfExited(
        _ driver: VoicePerformanceSupervisedProcessGeneration
    ) throws -> Bool {
        switch try operations.wait(pid: driver.pid) {
        case .running:
            return false
        case .exited, .signaled:
            driverOwnership = nil
            return true
        }
    }
}

public final class VoicePerformanceDriverHelperSupervisor {
    private struct HelperOwnership {
        let generation: VoicePerformanceSupervisedProcessGeneration
        var hasJoinedDriverProcessGroup: Bool
        var isPrepared: Bool
    }

    private let operations: VoicePerformanceSupervisorOperations
    private var helperOwnership: HelperOwnership?
    public private(set) var currentDriverGeneration:
        VoicePerformanceSupervisedProcessGeneration?
    public var activeHelperGeneration:
        VoicePerformanceSupervisedProcessGeneration?
    {
        helperOwnership?.generation
    }

    public convenience init() {
        self.init(system: DarwinVoicePerformanceProcessGroupSystem())
    }

    init(system: any VoicePerformanceProcessGroupSystem) {
        operations = .init(system: system)
    }

    public func bindCurrentDriver(
        expected: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        guard currentDriverGeneration == nil,
            expected.pid == operations.system.currentProcessID,
            expected.pid > 1,
            expected.startToken > 0,
            expected.processGroupID == expected.pid,
            try operations.probeGeneration(pid: expected.pid) == expected
        else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        currentDriverGeneration = expected
    }

    public func adoptSpawnedHelperForCleanup(
        expected: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        guard let driver = currentDriverGeneration,
            helperOwnership == nil,
            expected.pid > 1,
            expected.pid != driver.pid,
            expected.startToken > 0,
            expected.processGroupID == driver.processGroupID
        else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }

        helperOwnership = .init(
            generation: expected,
            hasJoinedDriverProcessGroup: false,
            isPrepared: false
        )
        guard try operations.peek(pid: expected.pid) == .running else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        guard let observed = try operations.probeGeneration(pid: expected.pid),
            observed.pid == expected.pid,
            observed.startToken == expected.startToken
        else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        helperOwnership?.hasJoinedDriverProcessGroup =
            observed.processGroupID == driver.processGroupID
    }

    public func prepareHelper(
        expected: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        if helperOwnership == nil {
            try adoptSpawnedHelperForCleanup(expected: expected)
        }
        guard let driver = currentDriverGeneration,
            var ownership = helperOwnership,
            ownership.generation == expected,
            !ownership.isPrepared
        else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        if !ownership.hasJoinedDriverProcessGroup {
            try operations.setProcessGroup(
                pid: expected.pid,
                processGroupID: driver.processGroupID
            )
            ownership.hasJoinedDriverProcessGroup = true
            helperOwnership = ownership
        }
        guard try operations.probeGeneration(pid: expected.pid) == expected else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        guard try operations.groupLiveProcessesExactlyMatch(
            driver.processGroupID,
            expectedProcessIDs: [driver.pid, expected.pid]
        ) else {
            throw VoicePerformanceTracerProcessError.processGroupFailure
        }
        ownership.isPrepared = true
        helperOwnership = ownership
    }

    @discardableResult
    public func reapSucceededHelper() throws -> Int32 {
        guard let ownership = helperOwnership, ownership.isPrepared else {
            throw VoicePerformanceTracerProcessError.processWaitFailed
        }
        let helper = ownership.generation
        let observed = try operations.peek(pid: helper.pid)
        switch observed {
        case .running:
            try verifyPreparedHelperGeneration(helper)
            throw VoicePerformanceTracerProcessError.processWaitFailed
        case .exited(let code):
            if code == 0 {
                try requireNoHelperDescendants(helper)
            }
            guard try operations.wait(pid: helper.pid) == observed else {
                throw VoicePerformanceTracerProcessError.processWaitFailed
            }
            helperOwnership = nil
            guard code == 0 else {
                throw VoicePerformanceTracerProcessError
                    .processExitedUnsuccessfully
            }
            return code
        case .signaled:
            guard try operations.wait(pid: helper.pid) == observed else {
                throw VoicePerformanceTracerProcessError.processWaitFailed
            }
            helperOwnership = nil
            throw VoicePerformanceTracerProcessError.processExitedUnsuccessfully
        }
    }

    @discardableResult
    public func reapSucceededHelper(
        exactGeneration: VoicePerformanceSupervisedProcessGeneration
    ) throws -> Int32 {
        guard helperOwnership?.generation == exactGeneration else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        return try reapSucceededHelper()
    }

    public func terminateHelperAndReap() throws {
        guard let helper = helperOwnership?.generation else { return }
        if try reapIfExited(helper) { return }
        try verifyActiveHelper(helper)
        let termDelivered = try signalHelperOrConfirmExited(
            .terminate,
            helper: helper
        )
        if termDelivered {
            let deadline = try operations.deadline(
                after: VoicePerformanceSupervisorOperations
                    .terminateGraceNanoseconds
            )
            if try !waitForHelperExit(helper, until: deadline) {
                try verifyActiveHelper(helper)
                let killDelivered = try signalHelperOrConfirmExited(
                    .kill,
                    helper: helper
                )
                if killDelivered {
                    let killDeadline = try operations.deadline(
                        after: VoicePerformanceSupervisorOperations
                            .killGraceNanoseconds
                    )
                    guard try waitForHelperExit(helper, until: killDeadline)
                    else {
                        throw VoicePerformanceTracerProcessError
                            .processTerminationTimedOut
                    }
                }
            }
        }
    }

    public func terminateHelperAndReap(
        exactGeneration: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        guard helperOwnership?.generation == exactGeneration else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        try terminateHelperAndReap()
    }

    public func abortSpawnedHelper(
        exactGeneration: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        try terminateHelperAndReap(exactGeneration: exactGeneration)
    }

    @discardableResult
    public func waitForSucceededHelper(
        until globalDeadline: VoicePerformanceContinuousDeadline
    ) throws -> Int32 {
        guard let ownership = helperOwnership, ownership.isPrepared else {
            throw VoicePerformanceTracerProcessError.processWaitFailed
        }
        let helper = ownership.generation
        let deadline = try operations.successDeadline(
            boundedBy: globalDeadline,
            maximumWaitNanoseconds:
                VoicePerformanceSupervisorOperations
                    .helperSuccessWaitCapNanoseconds
        )
        while true {
            guard try operations.currentNanoseconds() < deadline else {
                throw VoicePerformanceTracerProcessError
                    .processTerminationTimedOut
            }
            let observed = try operations.peek(pid: helper.pid)
            switch observed {
            case .running:
                try verifyPreparedHelperGeneration(helper)
                try operations.sleep(until: deadline)
            case .exited(let code):
                if code == 0 {
                    try requireNoHelperDescendants(helper)
                }
                guard try operations.wait(pid: helper.pid) == observed else {
                    throw VoicePerformanceTracerProcessError.processWaitFailed
                }
                helperOwnership = nil
                guard code == 0 else {
                    throw VoicePerformanceTracerProcessError
                        .processExitedUnsuccessfully
                }
                return code
            case .signaled:
                guard try operations.wait(pid: helper.pid) == observed else {
                    throw VoicePerformanceTracerProcessError.processWaitFailed
                }
                helperOwnership = nil
                throw VoicePerformanceTracerProcessError
                    .processExitedUnsuccessfully
            }
        }
    }

    @discardableResult
    public func waitForSucceededHelper(
        exactGeneration: VoicePerformanceSupervisedProcessGeneration,
        until globalDeadline: VoicePerformanceContinuousDeadline
    ) throws -> Int32 {
        guard helperOwnership?.generation == exactGeneration else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        return try waitForSucceededHelper(until: globalDeadline)
    }

    private func verifyActiveHelper(
        _ helper: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        guard let ownership = helperOwnership,
            ownership.generation == helper,
            try operations.peek(pid: helper.pid) == .running
        else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
        guard ownership.isPrepared else { return }
        try verifyPreparedHelperGeneration(helper)
    }

    private func verifyPreparedHelperGeneration(
        _ helper: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        guard let ownership = helperOwnership,
            ownership.generation == helper,
            ownership.isPrepared,
            try operations.probeGeneration(pid: helper.pid) == helper
        else {
            throw VoicePerformanceTracerProcessError.processGenerationMismatch
        }
    }

    private func requireNoHelperDescendants(
        _ helper: VoicePerformanceSupervisedProcessGeneration
    ) throws {
        guard let driver = currentDriverGeneration,
            driver.processGroupID == helper.processGroupID,
            try operations.groupLiveProcessesExactlyMatch(
                driver.processGroupID,
                expectedProcessIDs: [driver.pid]
            )
        else {
            throw VoicePerformanceTracerProcessError.processGroupFailure
        }
    }

    private func reapIfExited(
        _ helper: VoicePerformanceSupervisedProcessGeneration
    ) throws -> Bool {
        switch try operations.wait(pid: helper.pid) {
        case .running:
            try verifyActiveHelper(helper)
            return false
        case .exited, .signaled:
            helperOwnership = nil
            return true
        }
    }

    private func signalHelperOrConfirmExited(
        _ signal: VoicePerformanceTerminationSignal,
        helper: VoicePerformanceSupervisedProcessGeneration
    ) throws -> Bool {
        try verifyActiveHelper(helper)
        while true {
            do {
                try operations.system.signalProcess(signal, pid: helper.pid)
                return true
            } catch let error as VoicePerformancePOSIXError where error.code == EINTR {
                continue
            } catch let error as VoicePerformancePOSIXError where error.code == ESRCH {
                guard try reapIfExited(helper) else {
                    throw VoicePerformanceTracerProcessError
                        .processGenerationMismatch
                }
                return false
            } catch {
                throw VoicePerformanceTracerProcessError.processGroupFailure
            }
        }
    }

    private func waitForHelperExit(
        _ helper: VoicePerformanceSupervisedProcessGeneration,
        until deadline: UInt64
    ) throws -> Bool {
        while true {
            if try reapIfExited(helper) { return true }
            guard try operations.currentNanoseconds() < deadline else {
                return false
            }
            try operations.sleep(until: deadline)
        }
    }
}
