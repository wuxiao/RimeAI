import Darwin

public struct VoicePerformanceMachTimebase: Equatable, Sendable {
    public let numerator: UInt32
    public let denominator: UInt32

    public init(numerator: UInt32, denominator: UInt32) {
        self.numerator = numerator
        self.denominator = denominator
    }
}

public protocol VoicePerformanceContinuousClock: Sendable {
    func continuousTicks() throws -> UInt64
    func machTimebase() throws -> VoicePerformanceMachTimebase
}

public struct DarwinVoicePerformanceContinuousClock:
    VoicePerformanceContinuousClock, Sendable
{
    public init() {}

    public func continuousTicks() throws -> UInt64 {
        mach_continuous_time()
    }

    public func machTimebase() throws -> VoicePerformanceMachTimebase {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS else {
            throw VoicePerformanceTracerProcessError.clockFailure
        }
        return .init(numerator: info.numer, denominator: info.denom)
    }
}

public struct VoicePerformanceContinuousDeadline: Equatable, Hashable, Sendable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public init(parsing value: String) throws {
        guard let parsed = parseStrictUInt64Decimal(value) else {
            throw VoicePerformanceTracerProcessError.invalidDeadline
        }
        nanoseconds = parsed
    }

    public var encoded: String { String(nanoseconds) }

    public func remainingNanoseconds(
        using clock: any VoicePerformanceContinuousClock =
            DarwinVoicePerformanceContinuousClock()
    ) throws -> UInt64 {
        let now = try Self.currentNanoseconds(using: clock)
        return now >= nanoseconds ? 0 : nanoseconds - now
    }

    public func isExpired(
        using clock: any VoicePerformanceContinuousClock =
            DarwinVoicePerformanceContinuousClock()
    ) throws -> Bool {
        try Self.currentNanoseconds(using: clock) >= nanoseconds
    }

    public static func currentNanoseconds(
        using clock: any VoicePerformanceContinuousClock =
            DarwinVoicePerformanceContinuousClock()
    ) throws -> UInt64 {
        let ticks: UInt64
        let timebase: VoicePerformanceMachTimebase
        do {
            ticks = try clock.continuousTicks()
            timebase = try clock.machTimebase()
        } catch {
            throw VoicePerformanceTracerProcessError.clockFailure
        }
        return try nanoseconds(forContinuousTicks: ticks, timebase: timebase)
    }

    public static func after(
        nanoseconds duration: UInt64,
        using clock: any VoicePerformanceContinuousClock =
            DarwinVoicePerformanceContinuousClock()
    ) throws -> Self {
        let now = try currentNanoseconds(using: clock)
        let (absolute, overflow) = now.addingReportingOverflow(duration)
        guard !overflow else {
            throw VoicePerformanceTracerProcessError.clockFailure
        }
        return Self(nanoseconds: absolute)
    }

    public static func nanoseconds(
        forContinuousTicks ticks: UInt64,
        timebase: VoicePerformanceMachTimebase
    ) throws -> UInt64 {
        guard timebase.numerator > 0, timebase.denominator > 0 else {
            throw VoicePerformanceTracerProcessError.clockFailure
        }
        let product = ticks.multipliedFullWidth(by: UInt64(timebase.numerator))
        let divisor = UInt64(timebase.denominator)
        guard product.high < divisor else {
            throw VoicePerformanceTracerProcessError.clockFailure
        }
        return divisor.dividingFullWidth(product).quotient
    }
}

func parseStrictUInt64Decimal(_ value: String) -> UInt64? {
    guard !value.isEmpty,
        value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
        value == "0" || value.first != "0"
    else {
        return nil
    }
    var result: UInt64 = 0
    for byte in value.utf8 {
        let digit = UInt64(byte - 0x30)
        let (scaled, multiplyOverflow) = result.multipliedReportingOverflow(by: 10)
        let (advanced, addOverflow) = scaled.addingReportingOverflow(digit)
        guard !multiplyOverflow, !addOverflow else { return nil }
        result = advanced
    }
    return result
}
