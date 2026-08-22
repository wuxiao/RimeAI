import Darwin
import Testing
@testable import RimeAIVoicePerformanceTracerProcessDarwin

@Suite("Role-separated tracer child supervision")
struct VoicePerformanceRoleSeparatedSupervisorTests {
    @Test("live current generation reader returns the exact pid start and pgrp")
    func readsCurrentGeneration() throws {
        let current = generation(pid: 501, start: 5_001, group: 501)
        let system = RoleSeparatedProcessSystem(
            currentPID: 501,
            generations: [501: current]
        )

        #expect(
            try VoicePerformanceLiveProcessGenerationReader(system: system)
                .currentGeneration() == current
        )
    }

    @Test("collector creates and naturally reaps only its driver child")
    func collectorNaturallyReapsDriver() throws {
        let driver = VoicePerformanceSupervisedProcessGeneration(
            pid: 601,
            startToken: 6_001,
            processGroupID: 601
        )
        let system = RoleSeparatedProcessSystem(
            currentPID: 500,
            generations: [601: driver]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(
            system: system
        )

        try supervisor.prepareDriver(expected: driver)
        system.peekOutcomes[601] = [.exited(code: 0)]
        system.waitOutcomes[601] = [.exited(code: 0)]
        let status = try supervisor.reapSucceededDriver()

        #expect(status == 0)
        #expect(system.waitedPIDs == [601])
        #expect(system.groupChanges.isEmpty)
        #expect(system.groupSignals.isEmpty)
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("driver binds self but waits and reaps only one active helper child")
    func driverNaturallyReapsOneHelper() throws {
        let driver = generation(pid: 701, start: 7_001, group: 701)
        let helper = generation(pid: 702, start: 7_002, group: 701)
        let second = generation(pid: 703, start: 7_003, group: 701)
        let system = RoleSeparatedProcessSystem(
            currentPID: 701,
            generations: [701: driver, 702: helper, 703: second]
        )
        let supervisor = VoicePerformanceDriverHelperSupervisor(system: system)

        try supervisor.bindCurrentDriver(expected: driver)
        try supervisor.prepareHelper(expected: helper)
        #expect(throws: VoicePerformanceTracerProcessError.processGenerationMismatch) {
            try supervisor.prepareHelper(expected: second)
        }
        system.peekOutcomes[702] = [.exited(code: 0)]
        system.waitOutcomes[702] = [.exited(code: 0)]
        #expect(try supervisor.reapSucceededHelper() == 0)
        try supervisor.prepareHelper(expected: second)

        #expect(system.waitedPIDs == [702])
        #expect(system.groupChanges.isEmpty)
        #expect(system.waitedPIDs.contains(701) == false)
        #expect(system.processSignals.contains(where: { $0.pid == 701 }) == false)
        #expect(supervisor.currentDriverGeneration == driver)
        #expect(supervisor.activeHelperGeneration == second)
    }

    @Test("collector cleanup signals the whole group but waits only its driver child")
    func collectorEscalatesForGroupSurvivor() throws {
        let driver = generation(pid: 801, start: 8_001, group: 801)
        let system = RoleSeparatedProcessSystem(
            currentPID: 700,
            generations: [801: driver]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(system: system)
        try supervisor.prepareDriver(expected: driver)
        system.groupLiveOutcomes = [true, true, true, true, false, false, false]
        system.nextWakeTimes = [2_000_000_000, 5_000_000_000]
        system.waitOutcomes[801] = [.exited(code: 9)]

        try supervisor.terminateDriverGroupAndReap()

        #expect(system.groupSignals.map(\.signal) == [.terminate, .kill])
        #expect(system.groupSignals.map(\.time) == [0, 2_000_000_000])
        #expect(system.waitedPIDs == [801])
        #expect(system.processSignals.isEmpty)
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("collector still kills group survivors after its leader becomes a zombie")
    func collectorEscalatesAfterLeaderExit() throws {
        let driver = generation(pid: 811, start: 8_101, group: 811)
        let system = RoleSeparatedProcessSystem(
            currentPID: 710,
            generations: [811: driver]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(system: system)
        try supervisor.prepareDriver(expected: driver)
        system.groupLiveOutcomes = [true, true, true, false, false, false]
        system.peekOutcomes[811] = [
            .running,
            .running,
            .exited(code: 0),
            .exited(code: 0),
        ]
        system.generationPIDsRemovedAfterWake = [811]
        system.nextWakeTimes = [2_000_000_000]
        system.waitOutcomes[811] = [.exited(code: 0)]

        try supervisor.terminateDriverGroupAndReap()

        #expect(system.groupSignals.map(\.signal) == [.terminate, .kill])
        #expect(system.groupSignals.map(\.time) == [0, 2_000_000_000])
        #expect(system.waitedPIDs == [811])
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("driver cleanup never signals self and verifies helper before KILL")
    func driverEscalatesOnlyHelper() throws {
        let driver = generation(pid: 901, start: 9_001, group: 901)
        let helper = generation(pid: 902, start: 9_002, group: 901)
        let system = RoleSeparatedProcessSystem(
            currentPID: 901,
            generations: [901: driver, 902: helper]
        )
        let supervisor = VoicePerformanceDriverHelperSupervisor(system: system)
        try supervisor.bindCurrentDriver(expected: driver)
        try supervisor.prepareHelper(expected: helper)
        system.waitOutcomes[902] = [
            .running, .running, .running, .running, .signaled(signal: SIGKILL),
        ]
        system.nextWakeTimes = [2_000_000_000, 5_000_000_000]

        try supervisor.terminateHelperAndReap()

        #expect(system.processSignals.map(\.signal) == [.terminate, .kill])
        #expect(system.processSignals.map(\.pid) == [902, 902])
        #expect(system.processSignals.map(\.time) == [0, 2_000_000_000])
        #expect(system.waitedPIDs.allSatisfy { $0 == 902 })
        #expect(supervisor.currentDriverGeneration == driver)
        #expect(supervisor.activeHelperGeneration == nil)
    }

    @Test("ECHILD is a non-child failure and never clears the tracked generation")
    func nonChildWaitFailsClosed() throws {
        let driver = generation(pid: 1_001, start: 10_001, group: 1_001)
        let system = RoleSeparatedProcessSystem(
            currentPID: 999,
            generations: [1_001: driver]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(system: system)
        try supervisor.prepareDriver(expected: driver)
        system.peekErrors[1_001] = [ECHILD]

        #expect(throws: VoicePerformanceTracerProcessError.processWaitFailed) {
            try supervisor.reapSucceededDriver()
        }

        #expect(supervisor.driverGeneration == driver)
        #expect(system.groupSignals.isEmpty)
    }

    @Test("natural driver exit retains cleanup authority while group survivors remain")
    func driverExitWithSurvivorRetainsGeneration() throws {
        let driver = generation(pid: 1_101, start: 11_001, group: 1_101)
        let system = RoleSeparatedProcessSystem(
            currentPID: 1_000,
            generations: [1_101: driver]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(system: system)
        try supervisor.prepareDriver(expected: driver)
        system.peekOutcomes[1_101] = [.exited(code: 0)]
        system.groupLiveOutcomes = [true]

        #expect(throws: VoicePerformanceTracerProcessError.processGroupFailure) {
            try supervisor.reapSucceededDriver()
        }

        #expect(supervisor.driverGeneration == driver)
        #expect(system.waitedPIDs.isEmpty)
    }

    @Test("ESRCH group signal is success only after the group is confirmed gone")
    func missingGroupSignalConfirmsGone() throws {
        let driver = generation(pid: 1_201, start: 12_001, group: 1_201)
        let system = RoleSeparatedProcessSystem(
            currentPID: 1_100,
            generations: [1_201: driver]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(system: system)
        try supervisor.prepareDriver(expected: driver)
        system.groupLiveOutcomes = [true, false, false, false]
        system.groupSignalErrors = [ESRCH]
        system.waitOutcomes[1_201] = [.exited(code: 0)]

        try supervisor.terminateDriverGroupAndReap()

        #expect(system.groupSignals.map(\.signal) == [.terminate])
        #expect(system.waitedPIDs == [1_201])
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("helper PID reuse after TERM is rejected before KILL")
    func helperReuseBlocksKill() throws {
        let driver = generation(pid: 1_301, start: 13_001, group: 1_301)
        let helper = generation(pid: 1_302, start: 13_002, group: 1_301)
        let system = RoleSeparatedProcessSystem(
            currentPID: 1_301,
            generations: [1_301: driver, 1_302: helper]
        )
        let supervisor = VoicePerformanceDriverHelperSupervisor(system: system)
        try supervisor.bindCurrentDriver(expected: driver)
        try supervisor.prepareHelper(expected: helper)
        system.waitOutcomes[1_302] = [.running, .running, .running]
        system.nextWakeTimes = [2_000_000_000]
        system.generationReplacementsAfterWake[1_302] = generation(
            pid: 1_302,
            start: 99_999,
            group: 1_399
        )

        #expect(
            throws:
                VoicePerformanceTracerProcessError.processGenerationMismatch
        ) {
            try supervisor.terminateHelperAndReap()
        }

        #expect(system.processSignals.map(\.signal) == [.terminate])
        #expect(system.processSignals.map(\.pid) == [1_302])
        #expect(supervisor.activeHelperGeneration == helper)
    }

    @Test("nonzero helper exit is reaped and cleared before reporting failure")
    func nonzeroHelperIsStillReaped() throws {
        let driver = generation(pid: 1_401, start: 14_001, group: 1_401)
        let helper = generation(pid: 1_402, start: 14_002, group: 1_401)
        let system = RoleSeparatedProcessSystem(
            currentPID: 1_401,
            generations: [1_401: driver, 1_402: helper]
        )
        let supervisor = VoicePerformanceDriverHelperSupervisor(system: system)
        try supervisor.bindCurrentDriver(expected: driver)
        try supervisor.prepareHelper(expected: helper)
        system.peekOutcomes[1_402] = [.exited(code: 7)]
        system.waitOutcomes[1_402] = [.exited(code: 7)]

        #expect(
            throws:
                VoicePerformanceTracerProcessError.processExitedUnsuccessfully
        ) {
            try supervisor.reapSucceededHelper()
        }

        #expect(system.waitedPIDs == [1_402])
        #expect(supervisor.activeHelperGeneration == nil)
    }

    @Test("setpgid failure retains adopted-child cleanup authority")
    func setProcessGroupFailureCanStillAbortSpawnedDriver() throws {
        let driver = generation(pid: 1_501, start: 15_001, group: 1_501)
        let system = RoleSeparatedProcessSystem(
            currentPID: 1_500,
            generations: [
                1_501: generation(pid: 1_501, start: 15_001, group: 1_500)
            ]
        )
        system.groupChangeErrors = [EPERM]
        let supervisor = VoicePerformanceCollectorDriverSupervisor(system: system)

        #expect(throws: VoicePerformanceTracerProcessError.processGroupFailure) {
            try supervisor.prepareDriver(expected: driver)
        }
        #expect(supervisor.driverGeneration == driver)

        system.waitOutcomes[1_501] = [
            .running, .signaled(signal: SIGTERM),
        ]
        try supervisor.abortSpawnedDriver(exactGeneration: driver)

        #expect(system.groupSignals.isEmpty)
        #expect(system.processSignals.map(\.signal) == [.terminate])
        #expect(system.processSignals.map(\.pid) == [1_501])
        #expect(system.waitedPIDs == [1_501, 1_501])
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("post-setpgid generation mismatch retains group cleanup authority")
    func generationProbeMismatchCanStillAbortSpawnedDriver() throws {
        let driver = generation(pid: 1_601, start: 16_001, group: 1_601)
        let replacement = generation(pid: 1_601, start: 99_001, group: 1_601)
        let system = RoleSeparatedProcessSystem(
            currentPID: 1_600,
            generations: [
                1_601: generation(pid: 1_601, start: 16_001, group: 1_600)
            ]
        )
        system.generationOverridesByCall[1_601] = [2: replacement]
        let supervisor = VoicePerformanceCollectorDriverSupervisor(system: system)

        #expect(
            throws:
                VoicePerformanceTracerProcessError.processGenerationMismatch
        ) {
            try supervisor.prepareDriver(expected: driver)
        }
        #expect(supervisor.driverGeneration == driver)

        system.groupLiveOutcomes = [true, false, false, false]
        system.waitOutcomes[1_601] = [.signaled(signal: SIGTERM)]
        try supervisor.abortSpawnedDriver(exactGeneration: driver)

        #expect(system.groupSignals.map(\.signal) == [.terminate])
        #expect(system.waitedPIDs == [1_601])
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("transport bind failure can abort the exact prepared driver")
    func preparedDriverCanBeAbortedAfterBindFailure() throws {
        let driver = generation(pid: 1_701, start: 17_001, group: 1_701)
        let system = RoleSeparatedProcessSystem(
            currentPID: 1_700,
            generations: [1_701: driver]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(system: system)
        try supervisor.prepareDriver(expected: driver)

        system.groupLiveOutcomes = [true, false, false, false]
        system.waitOutcomes[1_701] = [.signaled(signal: SIGTERM)]
        try supervisor.abortSpawnedDriver(exactGeneration: driver)

        #expect(system.groupSignals.map(\.signal) == [.terminate])
        #expect(system.waitedPIDs == [1_701])
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("abort refuses a generation other than the adopted child")
    func abortRefusesWrongGeneration() throws {
        let driver = generation(pid: 1_801, start: 18_001, group: 1_801)
        let wrong = generation(pid: 1_801, start: 88_001, group: 1_801)
        let system = RoleSeparatedProcessSystem(
            currentPID: 1_800,
            generations: [1_801: driver]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(system: system)
        try supervisor.prepareDriver(expected: driver)

        #expect(
            throws:
                VoicePerformanceTracerProcessError.processGenerationMismatch
        ) {
            try supervisor.abortSpawnedDriver(exactGeneration: wrong)
        }

        #expect(supervisor.driverGeneration == driver)
        #expect(system.groupSignals.isEmpty)
        #expect(system.processSignals.isEmpty)
        #expect(system.waitedPIDs.isEmpty)
    }

    @Test("collector waits for driver exit zero and an empty process group")
    func collectorWaitsForSuccessfulGroupCompletion() throws {
        let driver = generation(pid: 1_901, start: 19_001, group: 1_901)
        let system = RoleSeparatedProcessSystem(
            currentPID: 1_900,
            generations: [1_901: driver]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(system: system)
        try supervisor.prepareDriver(expected: driver)
        system.peekOutcomes[1_901] = [
            .running, .exited(code: 0), .exited(code: 0),
        ]
        system.groupLiveOutcomes = [true, false]
        system.waitOutcomes[1_901] = [.exited(code: 0)]
        system.nextWakeTimes = [10_000_000, 20_000_000]

        let code = try supervisor.waitForSucceededDriver(
            exactGeneration: driver,
            until: .init(nanoseconds: 30_000_000_000)
        )

        #expect(code == 0)
        #expect(system.waitedPIDs == [1_901])
        #expect(supervisor.driverGeneration == nil)
    }

    @Test("driver success wait is capped at fifteen seconds and retains cleanup")
    func collectorSuccessWaitUsesPhaseCap() throws {
        let driver = generation(pid: 2_001, start: 20_001, group: 2_001)
        let system = RoleSeparatedProcessSystem(
            currentPID: 2_000,
            generations: [2_001: driver]
        )
        let supervisor = VoicePerformanceCollectorDriverSupervisor(system: system)
        try supervisor.prepareDriver(expected: driver)
        system.nextWakeTimes = [15_000_000_000]

        #expect(
            throws:
                VoicePerformanceTracerProcessError.processTerminationTimedOut
        ) {
            try supervisor.waitForSucceededDriver(
                until: .init(nanoseconds: 60_000_000_000)
            )
        }

        #expect(system.now == 15_000_000_000)
        #expect(supervisor.driverGeneration == driver)
        #expect(system.waitedPIDs.isEmpty)
    }

    @Test("driver waits for helper exit zero before allowing the next trial")
    func driverWaitsForSuccessfulHelper() throws {
        let driver = generation(pid: 2_101, start: 21_001, group: 2_101)
        let helper = generation(pid: 2_102, start: 21_002, group: 2_101)
        let system = RoleSeparatedProcessSystem(
            currentPID: 2_101,
            generations: [2_101: driver, 2_102: helper]
        )
        let supervisor = VoicePerformanceDriverHelperSupervisor(system: system)
        try supervisor.bindCurrentDriver(expected: driver)
        try supervisor.prepareHelper(expected: helper)
        system.peekOutcomes[2_102] = [.running, .exited(code: 0)]
        system.waitOutcomes[2_102] = [.exited(code: 0)]
        system.nextWakeTimes = [10_000_000]

        let code = try supervisor.waitForSucceededHelper(
            exactGeneration: helper,
            until: .init(nanoseconds: 1_000_000_000)
        )

        #expect(code == 0)
        #expect(system.waitedPIDs == [2_102])
        #expect(supervisor.activeHelperGeneration == nil)
    }

    @Test("helper success wait permits a legitimate sixty-second cold load")
    func helperSuccessWaitPermitsColdLoadLifetime() throws {
        let driver = generation(pid: 2_111, start: 21_101, group: 2_111)
        let helper = generation(pid: 2_112, start: 21_102, group: 2_111)
        let system = RoleSeparatedProcessSystem(
            currentPID: 2_111,
            generations: [2_111: driver, 2_112: helper]
        )
        let supervisor = VoicePerformanceDriverHelperSupervisor(system: system)
        try supervisor.bindCurrentDriver(expected: driver)
        try supervisor.prepareHelper(expected: helper)
        system.peekOutcomes[2_112] = [
            .running,
            .running,
            .exited(code: 0),
        ]
        system.waitOutcomes[2_112] = [.exited(code: 0)]
        system.nextWakeTimes = [16_000_000_000, 60_000_000_000]

        let code = try supervisor.waitForSucceededHelper(
            exactGeneration: helper,
            until: .init(nanoseconds: 130_000_000_000)
        )

        #expect(code == 0)
        #expect(system.now == 60_000_000_000)
        #expect(system.waitedPIDs == [2_112])
        #expect(supervisor.activeHelperGeneration == nil)
    }

    @Test("helper success wait is capped at one hundred twenty-five seconds")
    func helperSuccessWaitUsesLifetimeCap() throws {
        let driver = generation(pid: 2_121, start: 21_201, group: 2_121)
        let helper = generation(pid: 2_122, start: 21_202, group: 2_121)
        let system = RoleSeparatedProcessSystem(
            currentPID: 2_121,
            generations: [2_121: driver, 2_122: helper]
        )
        let supervisor = VoicePerformanceDriverHelperSupervisor(system: system)
        try supervisor.bindCurrentDriver(expected: driver)
        try supervisor.prepareHelper(expected: helper)
        system.nextWakeTimes = [16_000_000_000]

        #expect(
            throws:
                VoicePerformanceTracerProcessError.processTerminationTimedOut
        ) {
            try supervisor.waitForSucceededHelper(
                exactGeneration: helper,
                until: .init(nanoseconds: 300_000_000_000)
            )
        }

        #expect(system.now == 125_000_000_000)
        #expect(supervisor.activeHelperGeneration == helper)
        #expect(system.waitedPIDs.isEmpty)
    }

    @Test("helper exit zero with a surviving descendant is never successful")
    func helperDescendantBlocksSuccess() throws {
        let driver = generation(pid: 2_301, start: 23_001, group: 2_301)
        let helper = generation(pid: 2_302, start: 23_002, group: 2_301)
        let system = RoleSeparatedProcessSystem(
            currentPID: 2_301,
            generations: [2_301: driver, 2_302: helper]
        )
        let supervisor = VoicePerformanceDriverHelperSupervisor(system: system)
        try supervisor.bindCurrentDriver(expected: driver)
        try supervisor.prepareHelper(expected: helper)
        system.peekOutcomes[2_302] = [.exited(code: 0)]
        system.exactGroupProcessIDOutcomes = [Set([driver.pid, 9_999])]

        #expect(throws: VoicePerformanceTracerProcessError.processGroupFailure) {
            try supervisor.waitForSucceededHelper(
                exactGeneration: helper,
                until: .init(nanoseconds: 1_000_000_000)
            )
        }

        #expect(system.waitedPIDs.isEmpty)
        #expect(supervisor.activeHelperGeneration == helper)
    }

    @Test("helper prepare rejects a pgrp scan missing the live driver")
    func helperPrepareRejectsMissingDriver() throws {
        let driver = generation(pid: 2_401, start: 24_001, group: 2_401)
        let helper = generation(pid: 2_402, start: 24_002, group: 2_401)
        let system = RoleSeparatedProcessSystem(
            currentPID: 2_401,
            generations: [2_401: driver, 2_402: helper]
        )
        system.exactGroupProcessIDOutcomes = [Set([helper.pid])]
        let supervisor = VoicePerformanceDriverHelperSupervisor(system: system)
        try supervisor.bindCurrentDriver(expected: driver)

        #expect(throws: VoicePerformanceTracerProcessError.processGroupFailure) {
            try supervisor.prepareHelper(expected: helper)
        }

        #expect(supervisor.activeHelperGeneration == helper)
    }

    @Test("helper prepare rejects a pgrp scan missing the live helper")
    func helperPrepareRejectsMissingHelper() throws {
        let driver = generation(pid: 2_501, start: 25_001, group: 2_501)
        let helper = generation(pid: 2_502, start: 25_002, group: 2_501)
        let system = RoleSeparatedProcessSystem(
            currentPID: 2_501,
            generations: [2_501: driver, 2_502: helper]
        )
        system.exactGroupProcessIDOutcomes = [Set([driver.pid])]
        let supervisor = VoicePerformanceDriverHelperSupervisor(system: system)
        try supervisor.bindCurrentDriver(expected: driver)

        #expect(throws: VoicePerformanceTracerProcessError.processGroupFailure) {
            try supervisor.prepareHelper(expected: helper)
        }

        #expect(supervisor.activeHelperGeneration == helper)
    }

    @Test("helper success wait honors an earlier global deadline")
    func helperSuccessWaitHonorsGlobalDeadline() throws {
        let driver = generation(pid: 2_201, start: 22_001, group: 2_201)
        let helper = generation(pid: 2_202, start: 22_002, group: 2_201)
        let system = RoleSeparatedProcessSystem(
            currentPID: 2_201,
            generations: [2_201: driver, 2_202: helper]
        )
        let supervisor = VoicePerformanceDriverHelperSupervisor(system: system)
        try supervisor.bindCurrentDriver(expected: driver)
        try supervisor.prepareHelper(expected: helper)
        system.nextWakeTimes = [25_000_000]

        #expect(
            throws:
                VoicePerformanceTracerProcessError.processTerminationTimedOut
        ) {
            try supervisor.waitForSucceededHelper(
                until: .init(nanoseconds: 25_000_000)
            )
        }

        #expect(system.now == 25_000_000)
        #expect(supervisor.activeHelperGeneration == helper)
    }

    private func generation(pid: Int32, start: UInt64, group: Int32)
        -> VoicePerformanceSupervisedProcessGeneration
    {
        .init(pid: pid, startToken: start, processGroupID: group)
    }
}

private final class RoleSeparatedProcessSystem:
    VoicePerformanceProcessGroupSystem, @unchecked Sendable
{
    struct GroupChange: Equatable {
        let pid: Int32
        let group: Int32
    }

    struct GroupSignal: Equatable {
        let signal: VoicePerformanceTerminationSignal
        let group: Int32
        let time: UInt64
    }

    struct ProcessSignal: Equatable {
        let signal: VoicePerformanceTerminationSignal
        let pid: Int32
        let time: UInt64
    }

    let currentProcessID: Int32
    var generations: [Int32: VoicePerformanceSupervisedProcessGeneration]
    var waitOutcomes: [Int32: [VoicePerformanceWaitOutcome]] = [:]
    var waitErrors: [Int32: [Int32]] = [:]
    var peekOutcomes: [Int32: [VoicePerformanceWaitOutcome]] = [:]
    var peekErrors: [Int32: [Int32]] = [:]
    var waitedPIDs: [Int32] = []
    var groupChanges: [GroupChange] = []
    var groupChangeErrors: [Int32] = []
    var groupSignals: [GroupSignal] = []
    var processSignals: [ProcessSignal] = []
    var groupLiveOutcomes: [Bool] = []
    var exactGroupProcessIDOutcomes: [Set<Int32>] = []
    var groupSignalErrors: [Int32] = []
    var nextWakeTimes: [UInt64] = []
    var generationReplacementsAfterWake:
        [Int32: VoicePerformanceSupervisedProcessGeneration] = [:]
    var generationPIDsRemovedAfterWake: Set<Int32> = []
    var generationOverridesByCall:
        [Int32: [Int: VoicePerformanceSupervisedProcessGeneration]] = [:]
    var generationCallCounts: [Int32: Int] = [:]
    var now: UInt64 = 0

    init(
        currentPID: Int32,
        generations: [Int32: VoicePerformanceSupervisedProcessGeneration]
    ) {
        currentProcessID = currentPID
        self.generations = generations
    }

    func setProcessGroup(pid: Int32, processGroupID: Int32) throws {
        groupChanges.append(.init(pid: pid, group: processGroupID))
        if !groupChangeErrors.isEmpty {
            throw VoicePerformancePOSIXError(
                code: groupChangeErrors.removeFirst()
            )
        }
        if let current = generations[pid] {
            generations[pid] = .init(
                pid: current.pid,
                startToken: current.startToken,
                processGroupID: processGroupID
            )
        }
    }

    func generation(pid: Int32) throws
        -> VoicePerformanceSupervisedProcessGeneration?
    {
        generationCallCounts[pid, default: 0] += 1
        if let override = generationOverridesByCall[pid]?[
            generationCallCounts[pid, default: 0]
        ] {
            return override
        }
        return generations[pid]
    }

    func signalProcessGroup(
        _ signal: VoicePerformanceTerminationSignal,
        processGroupID: Int32
    ) throws {
        groupSignals.append(.init(signal: signal, group: processGroupID, time: now))
        if !groupSignalErrors.isEmpty {
            throw VoicePerformancePOSIXError(code: groupSignalErrors.removeFirst())
        }
    }

    func signalProcess(
        _ signal: VoicePerformanceTerminationSignal,
        pid: Int32
    ) throws {
        processSignals.append(.init(signal: signal, pid: pid, time: now))
    }

    func processGroupHasLiveProcesses(processGroupID: Int32) throws -> Bool {
        groupLiveOutcomes.isEmpty ? false : groupLiveOutcomes.removeFirst()
    }

    func processGroupLiveProcessesExactlyMatch(
        processGroupID: Int32,
        expectedProcessIDs: Set<Int32>
    ) throws -> Bool {
        exactGroupProcessIDOutcomes.isEmpty
            || exactGroupProcessIDOutcomes.removeFirst() == expectedProcessIDs
    }

    func waitNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        waitedPIDs.append(pid)
        if var errors = waitErrors[pid], !errors.isEmpty {
            let error = errors.removeFirst()
            waitErrors[pid] = errors
            throw VoicePerformancePOSIXError(code: error)
        }
        guard var outcomes = waitOutcomes[pid], !outcomes.isEmpty else {
            return .running
        }
        let outcome = outcomes.removeFirst()
        waitOutcomes[pid] = outcomes
        return outcome
    }

    func peekNonBlocking(pid: Int32) throws -> VoicePerformanceWaitOutcome {
        if !peekErrors[pid, default: []].isEmpty {
            let error = peekErrors[pid]!.removeFirst()
            throw VoicePerformancePOSIXError(code: error)
        }
        guard !peekOutcomes[pid, default: []].isEmpty else {
            return .running
        }
        return peekOutcomes[pid]!.removeFirst()
    }

    func currentContinuousNanoseconds() throws -> UInt64 { now }

    func sleep(nanoseconds: UInt64) throws {
        if nextWakeTimes.isEmpty {
            now += nanoseconds
        } else {
            now = nextWakeTimes.removeFirst()
        }
        for (pid, generation) in generationReplacementsAfterWake {
            generations[pid] = generation
        }
        generationReplacementsAfterWake.removeAll()
        for pid in generationPIDsRemovedAfterWake {
            generations[pid] = nil
        }
        generationPIDsRemovedAfterWake.removeAll()
    }
}
