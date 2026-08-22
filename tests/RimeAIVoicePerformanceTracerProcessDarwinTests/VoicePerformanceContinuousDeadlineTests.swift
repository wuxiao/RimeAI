import Testing
@testable import RimeAIVoicePerformanceTracerProcessDarwin

@Suite("Shared mach continuous absolute deadline")
struct VoicePerformanceContinuousDeadlineTests {
    @Test("remaining and expiration use one cross-process nanosecond domain")
    func remainingAndExpired() throws {
        let clock = StubContinuousClock(
            ticks: 12,
            timebase: .init(numerator: 5, denominator: 2)
        )
        let deadline = VoicePerformanceContinuousDeadline(nanoseconds: 35)

        #expect(try deadline.remainingNanoseconds(using: clock) == 5)
        #expect(try !deadline.isExpired(using: clock))

        clock.ticks = 14
        #expect(try deadline.remainingNanoseconds(using: clock) == 0)
        #expect(try deadline.isExpired(using: clock))
    }

    @Test("relative construction checks absolute nanosecond overflow")
    func relativeConstructionChecksOverflow() throws {
        let clock = StubContinuousClock(
            ticks: UInt64.max - 4,
            timebase: .init(numerator: 1, denominator: 1)
        )

        let deadline = try VoicePerformanceContinuousDeadline.after(
            nanoseconds: 4,
            using: clock
        )
        #expect(deadline.nanoseconds == UInt64.max)
        #expect(throws: VoicePerformanceTracerProcessError.clockFailure) {
            try VoicePerformanceContinuousDeadline.after(
                nanoseconds: 5,
                using: clock
            )
        }
    }

    @Test("timebase conversion uses full width arithmetic and rejects invalid ratios")
    func conversionIsOverflowSafe() throws {
        #expect(
            try VoicePerformanceContinuousDeadline.nanoseconds(
                forContinuousTicks: UInt64.max,
                timebase: .init(numerator: 2, denominator: 2)
            ) == UInt64.max
        )
        #expect(throws: VoicePerformanceTracerProcessError.clockFailure) {
            try VoicePerformanceContinuousDeadline.nanoseconds(
                forContinuousTicks: UInt64.max,
                timebase: .init(numerator: UInt32.max, denominator: 1)
            )
        }
        #expect(throws: VoicePerformanceTracerProcessError.clockFailure) {
            try VoicePerformanceContinuousDeadline.nanoseconds(
                forContinuousTicks: 1,
                timebase: .init(numerator: 1, denominator: 0)
            )
        }
    }
}

private final class StubContinuousClock: VoicePerformanceContinuousClock,
    @unchecked Sendable
{
    var ticks: UInt64
    let timebase: VoicePerformanceMachTimebase

    init(ticks: UInt64, timebase: VoicePerformanceMachTimebase) {
        self.ticks = ticks
        self.timebase = timebase
    }

    func continuousTicks() throws -> UInt64 { ticks }

    func machTimebase() throws -> VoicePerformanceMachTimebase { timebase }
}
