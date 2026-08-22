import CryptoKit
import Foundation
import Testing
@testable import RimeAIVoiceHelperEngine
@_spi(VoiceEvaluation) @testable import RimeAIVoicePerformanceHelperBridge

@Suite(.serialized)
struct WAVReplayPCMSourceTests {
    @Test
    func replaysAtTwentyMillisecondsAndFlushesOnlyTheTailOnStop() throws {
        let fixture = try WAVFixture(frameCount: 400)
        defer { fixture.remove() }
        let clock = ManualReplayClock()
        let scheduler = ManualReplayScheduler(clock: clock)
        let state = ReplayObservationState()
        let source = try WAVReplayPCMSource(
            audioURL: fixture.url,
            expectedSHA256: fixture.sha256,
            expectedDurationMilliseconds: 25,
            expectedSampleRateHertz: 16_000,
            expectedChannels: 1,
            expectedFrameCount: 400,
            schedule: scheduler.schedule,
            monotonicNowMilliseconds: clock.now,
            onEndOfFile: { state.markEOF() }
        )

        try source.start(
            onFrame: { state.append($0) },
            onFailure: { state.fail($0) }
        )

        #expect(scheduler.delays == [20])
        scheduler.runNext()
        #expect(state.frames.count == 1)
        #expect(state.eofCount == 0)
        #expect(scheduler.delays == [20, 5])

        scheduler.runNext()
        #expect(state.eofCount == 1)
        #expect(state.frames.count == 1)

        source.stop()
        #expect(state.failures.isEmpty)
        #expect(state.frames.count == 2)
        #expect(state.frames[1].samples.prefix(80).allSatisfy { $0 != 0 })
        #expect(state.frames[1].samples.dropFirst(80).allSatisfy { $0 == 0 })
    }

    @Test(arguments: [44_100, 48_000])
    func stereoResamplingPreservesTheDeclaredFortyMillisecondFrameCount(
        sampleRate: Int
    ) throws {
        let fixture = try WAVFixture(
            sampleRateHertz: sampleRate,
            channels: 2,
            frameCount: sampleRate * 40 / 1_000
        )
        defer { fixture.remove() }
        let clock = ManualReplayClock()
        let scheduler = ManualReplayScheduler(clock: clock)
        let state = ReplayObservationState()
        let source = try WAVReplayPCMSource(
            audioURL: fixture.url,
            expectedSHA256: fixture.sha256,
            expectedDurationMilliseconds: 40,
            expectedSampleRateHertz: sampleRate,
            expectedChannels: 2,
            expectedFrameCount: sampleRate * 40 / 1_000,
            schedule: scheduler.schedule,
            monotonicNowMilliseconds: clock.now,
            onEndOfFile: { state.markEOF() }
        )

        try source.start(
            onFrame: { state.append($0) },
            onFailure: { state.fail($0) }
        )
        scheduler.runAll()
        source.stop()

        #expect(state.failures.isEmpty)
        #expect(state.eofCount == 1)
        #expect(state.frames.count == 2)
        #expect(state.frames.allSatisfy { $0.isValid })
    }

    @Test
    func tenMillisecondInputIsDeliveredOnlyWhenStopFlushesTheTail() throws {
        let fixture = try WAVFixture(frameCount: 160)
        defer { fixture.remove() }
        let clock = ManualReplayClock()
        let scheduler = ManualReplayScheduler(clock: clock)
        let state = ReplayObservationState()
        let source = try WAVReplayPCMSource(
            audioURL: fixture.url,
            expectedSHA256: fixture.sha256,
            expectedDurationMilliseconds: 10,
            expectedSampleRateHertz: 16_000,
            expectedChannels: 1,
            expectedFrameCount: 160,
            schedule: scheduler.schedule,
            monotonicNowMilliseconds: clock.now,
            onEndOfFile: { state.markEOF() }
        )
        try source.start(
            onFrame: { state.append($0) },
            onFailure: { state.fail($0) }
        )

        #expect(scheduler.delays == [10])
        scheduler.runAll()
        #expect(state.frames.isEmpty)
        #expect(state.eofCount == 1)
        source.stop()
        #expect(state.frames.count == 1)
        #expect(state.frames[0].samples.prefix(160).allSatisfy { $0 != 0 })
        #expect(state.frames[0].samples.dropFirst(160).allSatisfy { $0 == 0 })
    }

    @Test
    func exactFortyMillisecondsDoesNotInventATailFrame() throws {
        let fixture = try WAVFixture(frameCount: 640)
        defer { fixture.remove() }
        let clock = ManualReplayClock()
        let scheduler = ManualReplayScheduler(clock: clock)
        let state = ReplayObservationState()
        let source = try WAVReplayPCMSource(
            audioURL: fixture.url,
            expectedSHA256: fixture.sha256,
            expectedDurationMilliseconds: 40,
            expectedSampleRateHertz: 16_000,
            expectedChannels: 1,
            expectedFrameCount: 640,
            schedule: scheduler.schedule,
            monotonicNowMilliseconds: clock.now,
            onEndOfFile: { state.markEOF() }
        )
        try source.start(
            onFrame: { state.append($0) },
            onFailure: { state.fail($0) }
        )
        scheduler.runAll()
        #expect(scheduler.delays == [20, 20])
        #expect(state.frames.count == 2)
        #expect(state.eofCount == 1)
        source.stop()
        #expect(state.frames.count == 2)
    }

    @Test
    func cancelInvalidatesAlreadyScheduledDelivery() throws {
        let fixture = try WAVFixture(frameCount: 640)
        defer { fixture.remove() }
        let clock = ManualReplayClock()
        let scheduler = ManualReplayScheduler(clock: clock)
        let state = ReplayObservationState()
        let source = try WAVReplayPCMSource(
            audioURL: fixture.url,
            expectedSHA256: fixture.sha256,
            expectedDurationMilliseconds: 40,
            expectedSampleRateHertz: 16_000,
            expectedChannels: 1,
            expectedFrameCount: 640,
            schedule: scheduler.schedule,
            monotonicNowMilliseconds: clock.now,
            onEndOfFile: { state.markEOF() }
        )
        try source.start(
            onFrame: { state.append($0) },
            onFailure: { state.fail($0) }
        )
        source.cancel()
        scheduler.runAll()

        #expect(state.frames.isEmpty)
        #expect(state.failures.isEmpty)
        #expect(state.eofCount == 0)
    }

    @Test
    func lateFrameCallbackKeepsTheNextFrameOnTheSessionTimeline() throws {
        let fixture = try WAVFixture(frameCount: 640)
        defer { fixture.remove() }
        let clock = ManualReplayClock()
        let scheduler = ManualReplayScheduler(clock: clock)
        let state = ReplayObservationState()
        let source = try WAVReplayPCMSource(
            audioURL: fixture.url,
            expectedSHA256: fixture.sha256,
            expectedDurationMilliseconds: 40,
            expectedSampleRateHertz: 16_000,
            expectedChannels: 1,
            expectedFrameCount: 640,
            schedule: scheduler.schedule,
            monotonicNowMilliseconds: clock.now,
            onEndOfFile: { state.markEOF() }
        )
        try source.start(
            onFrame: {
                state.append($0)
                clock.advance(by: 7)
            },
            onFailure: { state.fail($0) }
        )

        #expect(scheduler.delays == [20])
        scheduler.runNext()
        #expect(scheduler.delays == [20, 13])
        scheduler.runAll()

        #expect(state.frames.count == 2)
        #expect(state.eofCount == 1)
        #expect(state.failures.isEmpty)
    }

    @Test
    func overloadedFrameCallbacksCatchUpWithoutNegativeScheduling() throws {
        let fixture = try WAVFixture(frameCount: 960)
        defer { fixture.remove() }
        let clock = ManualReplayClock()
        let scheduler = ManualReplayScheduler(clock: clock)
        let state = ReplayObservationState()
        let source = try WAVReplayPCMSource(
            audioURL: fixture.url,
            expectedSHA256: fixture.sha256,
            expectedDurationMilliseconds: 60,
            expectedSampleRateHertz: 16_000,
            expectedChannels: 1,
            expectedFrameCount: 960,
            schedule: scheduler.schedule,
            monotonicNowMilliseconds: clock.now,
            onEndOfFile: { state.markEOF() }
        )
        try source.start(
            onFrame: {
                state.append($0)
                clock.advance(by: 25)
            },
            onFailure: { state.fail($0) }
        )

        scheduler.runNext()
        #expect(scheduler.delays == [20, 0])
        scheduler.runAll()

        #expect(scheduler.delays == [20, 0, 0])
        #expect(state.frames.count == 3)
        #expect(state.eofCount == 1)
        #expect(state.failures.isEmpty)
    }
}

private final class ManualReplayScheduler: @unchecked Sendable {
    private struct ScheduledAction {
        let delayMilliseconds: Double
        let operation: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let clock: ManualReplayClock?
    private var actions: [ScheduledAction] = []
    private(set) var delays: [Double] = []

    init(clock: ManualReplayClock? = nil) {
        self.clock = clock
    }

    func schedule(
        _ delayMilliseconds: Double,
        _ action: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        delays.append(delayMilliseconds)
        actions.append(ScheduledAction(
            delayMilliseconds: delayMilliseconds,
            operation: action
        ))
        lock.unlock()
    }

    func runNext() {
        lock.lock()
        let action = actions.removeFirst()
        lock.unlock()
        clock?.advance(by: action.delayMilliseconds)
        action.operation()
    }

    func runAll() {
        for _ in 0 ..< 10_000 {
            lock.lock()
            let hasAction = !actions.isEmpty
            lock.unlock()
            guard hasAction else { return }
            runNext()
        }
        Issue.record("replay scheduler did not quiesce")
    }
}

private final class ManualReplayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds = 0.0

    func now() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return milliseconds
    }

    func advance(by value: Double) {
        lock.lock()
        milliseconds += value
        lock.unlock()
    }
}

private final class ReplayObservationState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var frames: [VoicePCMFrame] = []
    private(set) var failures: [VoicePCMSourceFailure] = []
    private(set) var eofCount = 0

    func append(_ frame: VoicePCMFrame) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    func fail(_ failure: VoicePCMSourceFailure) {
        lock.lock()
        failures.append(failure)
        lock.unlock()
    }

    func markEOF() {
        lock.lock()
        eofCount += 1
        lock.unlock()
    }
}

private final class WAVFixture {
    let url: URL
    let sha256: String

    convenience init(frameCount: Int) throws {
        try self.init(
            sampleRateHertz: 16_000,
            channels: 1,
            frameCount: frameCount
        )
    }

    init(
        sampleRateHertz: Int,
        channels: Int,
        frameCount: Int
    ) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimeai-wav-replay-\(UUID().uuidString).wav"
        )
        var data = Data()
        let pcmBytes = frameCount * channels * 2
        data.append(contentsOf: "RIFF".utf8)
        data.appendUInt32LE(UInt32(36 + pcmBytes))
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(UInt16(channels))
        data.appendUInt32LE(UInt32(sampleRateHertz))
        data.appendUInt32LE(UInt32(sampleRateHertz * channels * 2))
        data.appendUInt16LE(UInt16(channels * 2))
        data.appendUInt16LE(16)
        data.append(contentsOf: "data".utf8)
        data.appendUInt32LE(UInt32(pcmBytes))
        for index in 0 ..< frameCount {
            for channel in 0 ..< channels {
                data.appendUInt16LE(UInt16(bitPattern: Int16(
                    1_000 + index + channel
                )))
            }
        }
        try data.write(to: url, options: .withoutOverwriting)
        sha256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
