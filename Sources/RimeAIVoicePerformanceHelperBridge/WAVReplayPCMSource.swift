@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation
import RimeAIInputCore
import RimeAIVoiceHelperEngine

@_spi(VoiceEvaluation)
public enum WAVReplayPCMSourceError: Error, Equatable, Sendable {
    case invalidInput
}

/// A data-only evaluation source. Construction completely reads, hashes,
/// parses, and preconverts the `O_NOFOLLOW`-opened WAV before callbacks run.
/// Full 20 ms recognizer frames target absolute offsets from each session's
/// monotonic start, so callback work does not accumulate pacing drift; overdue
/// delivery catches up without a negative delay. A final partial frame remains
/// private until normal `stop()` and is discarded by `cancel()`.
/// Consequently observation latency covers paced delivery, decoder work, and
/// ServerCore only. It excludes artifact loading, WAV IO, and PCM conversion,
/// and cannot be used as release performance or cold-load evidence.
@_spi(VoiceEvaluation)
public final class WAVReplayPCMSource: VoicePCMSource, @unchecked Sendable {
    public typealias Schedule = @Sendable (
        _ delayMilliseconds: Double,
        _ operation: @escaping @Sendable () -> Void
    ) -> Void
    public typealias MonotonicNowMilliseconds = @Sendable () -> Double

    private enum Phase {
        case idle
        case running
        case atEndOfFile
        case stopped
        case cancelled
    }

    private let fullFrames: [VoicePCMFrame]
    private let tailFrame: VoicePCMFrame?
    private let tailDurationMilliseconds: Double
    private let schedule: Schedule
    private let monotonicNowMilliseconds: MonotonicNowMilliseconds
    private let onEndOfFile: @Sendable () -> Void
    private let lock = NSLock()
    private var phase: Phase = .idle
    private var generation: UInt64 = 0
    private var nextFrameIndex = 0
    private var sessionStartMilliseconds: Double?
    private var frameSink: (@Sendable (VoicePCMFrame) -> Void)?

    public convenience init(
        audioURL: URL,
        expectedSHA256: String,
        expectedDurationMilliseconds: Double,
        expectedSampleRateHertz: Int,
        expectedChannels: Int,
        expectedFrameCount: Int,
        onEndOfFile: @escaping @Sendable () -> Void
    ) throws {
        let queue = DispatchQueue(
            label: "fun.wwcn.rimeai.voice-evaluation.wav-replay"
        )
        try self.init(
            audioURL: audioURL,
            expectedSHA256: expectedSHA256,
            expectedDurationMilliseconds: expectedDurationMilliseconds,
            expectedSampleRateHertz: expectedSampleRateHertz,
            expectedChannels: expectedChannels,
            expectedFrameCount: expectedFrameCount,
            schedule: { delayMilliseconds, operation in
                queue.asyncAfter(
                    deadline: .now() + delayMilliseconds / 1_000,
                    execute: operation
                )
            },
            monotonicNowMilliseconds: {
                ProcessInfo.processInfo.systemUptime * 1_000
            },
            onEndOfFile: onEndOfFile
        )
    }

    public init(
        audioURL: URL,
        expectedSHA256: String,
        expectedDurationMilliseconds: Double,
        expectedSampleRateHertz: Int,
        expectedChannels: Int,
        expectedFrameCount: Int,
        schedule: @escaping Schedule,
        monotonicNowMilliseconds: @escaping MonotonicNowMilliseconds = {
            ProcessInfo.processInfo.systemUptime * 1_000
        },
        onEndOfFile: @escaping @Sendable () -> Void
    ) throws {
        let decoded = try Self.openAndDecode(
            audioURL: audioURL,
            expectedSHA256: expectedSHA256,
            expectedDurationMilliseconds: expectedDurationMilliseconds,
            expectedSampleRateHertz: expectedSampleRateHertz,
            expectedChannels: expectedChannels,
            expectedFrameCount: expectedFrameCount
        )
        fullFrames = decoded.fullFrames
        tailFrame = decoded.tailFrame
        tailDurationMilliseconds = decoded.tailDurationMilliseconds
        self.schedule = schedule
        self.monotonicNowMilliseconds = monotonicNowMilliseconds
        self.onEndOfFile = onEndOfFile
    }

    public func start(
        onFrame: @escaping @Sendable (VoicePCMFrame) -> Void,
        onFailure: @escaping @Sendable (VoicePCMSourceFailure) -> Void
    ) throws {
        _ = onFailure
        let startMilliseconds = monotonicNowMilliseconds()
        guard startMilliseconds.isFinite else {
            throw WAVReplayPCMSourceError.invalidInput
        }
        lock.lock()
        guard phase == .idle else {
            lock.unlock()
            throw WAVReplayPCMSourceError.invalidInput
        }
        generation &+= 1
        let currentGeneration = generation
        phase = .running
        frameSink = onFrame
        nextFrameIndex = 0
        sessionStartMilliseconds = startMilliseconds
        let hasFullFrames = !fullFrames.isEmpty
        let eofDelay = tailDurationMilliseconds
        lock.unlock()

        if hasFullFrames {
            scheduleDelivery(atSessionElapsedMilliseconds: 20) { [weak self] in
                self?.deliverNextFrame(generation: currentGeneration)
            }
        } else if eofDelay > 0 {
            scheduleDelivery(
                atSessionElapsedMilliseconds: eofDelay
            ) { [weak self] in
                self?.deliverEndOfFile(generation: currentGeneration)
            }
        } else {
            deliverEndOfFile(generation: currentGeneration)
        }
    }

    public func stop() {
        lock.lock()
        guard phase == .running || phase == .atEndOfFile else {
            lock.unlock()
            return
        }
        let shouldFlushTail = phase == .atEndOfFile
        phase = .stopped
        generation &+= 1
        let sink = frameSink
        frameSink = nil
        let tail = shouldFlushTail ? tailFrame : nil
        lock.unlock()
        if let tail, let sink {
            sink(tail)
        }
    }

    public func cancel() {
        lock.lock()
        guard phase == .idle || phase == .running || phase == .atEndOfFile else {
            lock.unlock()
            return
        }
        phase = .cancelled
        generation &+= 1
        frameSink = nil
        lock.unlock()
    }

    private func deliverNextFrame(generation expectedGeneration: UInt64) {
        lock.lock()
        guard phase == .running,
              generation == expectedGeneration,
              nextFrameIndex < fullFrames.count,
              let sink = frameSink
        else {
            lock.unlock()
            return
        }
        let frame = fullFrames[nextFrameIndex]
        nextFrameIndex += 1
        let hasNextFrame = nextFrameIndex < fullFrames.count
        let eofDelay = tailDurationMilliseconds
        lock.unlock()

        sink(frame)
        if hasNextFrame {
            let targetElapsedMilliseconds = Double(nextFrameIndex + 1) * 20
            scheduleDelivery(
                atSessionElapsedMilliseconds: targetElapsedMilliseconds
            ) { [weak self] in
                self?.deliverNextFrame(generation: expectedGeneration)
            }
        } else if eofDelay > 0 {
            let targetElapsedMilliseconds = Double(fullFrames.count) * 20
                + eofDelay
            scheduleDelivery(
                atSessionElapsedMilliseconds: targetElapsedMilliseconds
            ) { [weak self] in
                self?.deliverEndOfFile(generation: expectedGeneration)
            }
        } else {
            deliverEndOfFile(generation: expectedGeneration)
        }
    }

    private func deliverEndOfFile(generation expectedGeneration: UInt64) {
        lock.lock()
        guard phase == .running, generation == expectedGeneration else {
            lock.unlock()
            return
        }
        phase = .atEndOfFile
        lock.unlock()
        onEndOfFile()
    }

    private func scheduleDelivery(
        atSessionElapsedMilliseconds targetElapsedMilliseconds: Double,
        _ operation: @escaping @Sendable () -> Void
    ) {
        let nowMilliseconds = monotonicNowMilliseconds()
        lock.lock()
        let startMilliseconds = sessionStartMilliseconds
        let isRunning = phase == .running
        lock.unlock()
        guard isRunning,
              let startMilliseconds,
              nowMilliseconds.isFinite,
              targetElapsedMilliseconds.isFinite,
              targetElapsedMilliseconds >= 0
        else { return }
        let targetMilliseconds = startMilliseconds
            + targetElapsedMilliseconds
        guard targetMilliseconds.isFinite else { return }
        schedule(max(0, targetMilliseconds - nowMilliseconds), operation)
    }
}

private extension WAVReplayPCMSource {
    struct DecodedAudio {
        let fullFrames: [VoicePCMFrame]
        let tailFrame: VoicePCMFrame?
        let tailDurationMilliseconds: Double
    }

    struct WAVPayload {
        let sampleRateHertz: Int
        let channels: Int
        let frameCount: Int
        let interleavedSamples: [Float]
    }

    static let maximumWAVBytes = 64 * 1_024 * 1_024
    static let maximumChunkCount = 4_096

    static func openAndDecode(
        audioURL: URL,
        expectedSHA256: String,
        expectedDurationMilliseconds: Double,
        expectedSampleRateHertz: Int,
        expectedChannels: Int,
        expectedFrameCount: Int
    ) throws -> DecodedAudio {
        guard audioURL.isFileURL,
              audioURL.path.hasPrefix("/"),
              audioURL.path == audioURL.path.precomposedStringWithCanonicalMapping,
              audioURL.standardizedFileURL.path == audioURL.path,
              isSHA256(expectedSHA256),
              expectedDurationMilliseconds.isFinite,
              expectedDurationMilliseconds > 0,
              expectedDurationMilliseconds <= 60_000,
              [16_000, 44_100, 48_000].contains(expectedSampleRateHertz),
              (1 ... 2).contains(expectedChannels),
              expectedFrameCount > 0
        else { throw WAVReplayPCMSourceError.invalidInput }

        var pathInformation = stat()
        guard lstat(audioURL.path, &pathInformation) == 0,
              pathInformation.st_mode & S_IFMT == S_IFREG
        else { throw WAVReplayPCMSourceError.invalidInput }
        let descriptor = Darwin.open(
            audioURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw WAVReplayPCMSourceError.invalidInput
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_dev == pathInformation.st_dev,
              before.st_ino == pathInformation.st_ino,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 44,
              before.st_size <= maximumWAVBytes
        else { throw WAVReplayPCMSourceError.invalidInput }
        let expectedByteCount = Int(before.st_size)
        var data = Data()
        data.reserveCapacity(expectedByteCount)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count < expectedByteCount {
            let copied = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.read(descriptor, base, bytes.count)
            }
            if copied < 0, errno == EINTR { continue }
            guard copied > 0,
                  data.count + copied <= expectedByteCount
            else { throw WAVReplayPCMSourceError.invalidInput }
            data.append(contentsOf: buffer[..<copied])
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              sha256(data) == expectedSHA256
        else { throw WAVReplayPCMSourceError.invalidInput }

        let wav = try parseWAV(data)
        let derivedDuration = Double(wav.frameCount) * 1_000
            / Double(wav.sampleRateHertz)
        let tolerance = max(0.01, 1_000 / Double(wav.sampleRateHertz))
        guard wav.sampleRateHertz == expectedSampleRateHertz,
              wav.channels == expectedChannels,
              wav.frameCount == expectedFrameCount,
              abs(derivedDuration - expectedDurationMilliseconds) <= tolerance
        else { throw WAVReplayPCMSourceError.invalidInput }
        return try makeFrames(wav)
    }

    static func parseWAV(_ data: Data) throws -> WAVPayload {
        guard data.count >= 44,
              data[0 ..< 4].elementsEqual("RIFF".utf8),
              data[8 ..< 12].elementsEqual("WAVE".utf8),
              let riffSize = uint32LE(data, at: 4),
              Int(riffSize) + 8 == data.count
        else { throw WAVReplayPCMSourceError.invalidInput }

        var offset = 12
        var format: (sampleRate: Int, channels: Int, blockAlign: Int)?
        var pcmRange: Range<Int>?
        var chunks = 0
        while offset < data.count {
            chunks += 1
            guard chunks <= maximumChunkCount,
                  offset + 8 <= data.count,
                  let chunkSizeValue = uint32LE(data, at: offset + 4)
            else { throw WAVReplayPCMSourceError.invalidInput }
            let chunkSize = Int(chunkSizeValue)
            let payloadStart = offset + 8
            let (payloadEnd, payloadOverflow) = payloadStart
                .addingReportingOverflow(chunkSize)
            let padding = chunkSize & 1
            let (nextOffset, nextOverflow) = payloadEnd
                .addingReportingOverflow(padding)
            guard !payloadOverflow,
                  !nextOverflow,
                  payloadEnd <= data.count,
                  nextOffset <= data.count
            else { throw WAVReplayPCMSourceError.invalidInput }

            let identifier = data[offset ..< offset + 4]
            if identifier.elementsEqual("fmt ".utf8) {
                guard format == nil,
                      chunkSize >= 16,
                      let audioFormat = uint16LE(data, at: payloadStart),
                      let channels = uint16LE(data, at: payloadStart + 2),
                      let sampleRate = uint32LE(data, at: payloadStart + 4),
                      let byteRate = uint32LE(data, at: payloadStart + 8),
                      let blockAlign = uint16LE(data, at: payloadStart + 12),
                      let bitsPerSample = uint16LE(data, at: payloadStart + 14),
                      audioFormat == 1,
                      (1 ... 2).contains(Int(channels)),
                      [16_000, 44_100, 48_000].contains(Int(sampleRate)),
                      bitsPerSample == 16,
                      Int(blockAlign) == Int(channels) * 2,
                      Int(byteRate) == Int(sampleRate) * Int(blockAlign)
                else { throw WAVReplayPCMSourceError.invalidInput }
                format = (Int(sampleRate), Int(channels), Int(blockAlign))
            } else if identifier.elementsEqual("data".utf8) {
                guard pcmRange == nil else {
                    throw WAVReplayPCMSourceError.invalidInput
                }
                pcmRange = payloadStart ..< payloadEnd
            }
            offset = nextOffset
        }

        guard offset == data.count,
              let format,
              let pcmRange,
              !pcmRange.isEmpty,
              pcmRange.count % format.blockAlign == 0
        else { throw WAVReplayPCMSourceError.invalidInput }
        let frameCount = pcmRange.count / format.blockAlign
        var samples: [Float] = []
        samples.reserveCapacity(frameCount * format.channels)
        var sampleOffset = pcmRange.lowerBound
        while sampleOffset < pcmRange.upperBound {
            guard let bits = uint16LE(data, at: sampleOffset) else {
                throw WAVReplayPCMSourceError.invalidInput
            }
            samples.append(Float(Int16(bitPattern: bits)) / 32_768)
            sampleOffset += 2
        }
        return WAVPayload(
            sampleRateHertz: format.sampleRate,
            channels: format.channels,
            frameCount: frameCount,
            interleavedSamples: samples
        )
    }

    static func makeFrames(_ wav: WAVPayload) throws -> DecodedAudio {
        let expectedOutputSamples = Int(
            (Double(wav.frameCount) * Double(VoicePCMFrame.sampleRateHertz)
                / Double(wav.sampleRateHertz)).rounded()
        )
        guard expectedOutputSamples > 0 else {
            throw WAVReplayPCMSourceError.invalidInput
        }

        var frames = try WAVReplayPCMFrameConverter.makeFrames(
            sampleRate: Double(wav.sampleRateHertz),
            channelCount: wav.channels,
            interleavedSamples: wav.interleavedSamples
        )

        let expectedFrameCount = (
            expectedOutputSamples + VoicePCMFrame.samplesPerFrame - 1
        ) / VoicePCMFrame.samplesPerFrame
        guard frames.count == expectedFrameCount,
              frames.allSatisfy(\.isValid)
        else { throw WAVReplayPCMSourceError.invalidInput }
        let tailSampleCount = expectedOutputSamples
            % VoicePCMFrame.samplesPerFrame
        let tail = tailSampleCount == 0 ? nil : frames.removeLast()
        return DecodedAudio(
            fullFrames: frames,
            tailFrame: tail,
            tailDurationMilliseconds: Double(tailSampleCount) * 1_000
                / Double(VoicePCMFrame.sampleRateHertz)
        )
    }

    static func uint16LE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    static func uint32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }
}

/// Evaluation-only conversion keeps WAV replay out of the production engine's
/// API surface. It intentionally mirrors the microphone converter's owned,
/// synchronous AVAudioConverter flow without exporting a cross-module PCM SPI.
private enum WAVReplayPCMFrameConverter {
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(VoicePCMFrame.sampleRateHertz),
        channels: 1,
        interleaved: false
    )!

    private final class InputProvider: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var didProvideBuffer = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    static func makeFrames(
        sampleRate: Double,
        channelCount: Int,
        interleavedSamples: [Float]
    ) throws -> [VoicePCMFrame] {
        guard sampleRate.isFinite,
              sampleRate > 0,
              (1 ... 2).contains(channelCount),
              !interleavedSamples.isEmpty,
              interleavedSamples.count % channelCount == 0,
              interleavedSamples.allSatisfy(\.isFinite)
        else { throw WAVReplayPCMSourceError.invalidInput }

        let monoSamples = try downmix(
            interleavedSamples,
            channelCount: channelCount
        )
        if abs(sampleRate - Double(VoicePCMFrame.sampleRateHertz)) < 0.001 {
            return makePaddedFrames(from: monoSamples)
        }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
            let converter = AVAudioConverter(
                from: inputFormat,
                to: outputFormat
            ),
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(monoSamples.count)
            ),
            let inputChannel = inputBuffer.floatChannelData?[0]
        else { throw WAVReplayPCMSourceError.invalidInput }

        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter.primeMethod = .normal
        inputBuffer.frameLength = AVAudioFrameCount(monoSamples.count)
        inputChannel.update(from: monoSamples, count: monoSamples.count)

        let provider = InputProvider(buffer: inputBuffer)
        let ratio = outputFormat.sampleRate / sampleRate
        let estimatedFrames = Int(ceil(Double(monoSamples.count) * ratio)) + 512
        let outputCapacity = AVAudioFrameCount(
            min(max(estimatedFrames, 512), 65_536)
        )
        var convertedSamples: [Float] = []
        var reachedInputEnd = false
        for _ in 0 ..< 128 {
            let status = try convert(
                converter,
                outputCapacity: outputCapacity,
                destination: &convertedSamples
            ) { _, inputStatus in
                if provider.didProvideBuffer {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                provider.didProvideBuffer = true
                inputStatus.pointee = .haveData
                return provider.buffer
            }
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                reachedInputEnd = true
            case .error:
                throw WAVReplayPCMSourceError.invalidInput
            @unknown default:
                throw WAVReplayPCMSourceError.invalidInput
            }
            break
        }
        guard reachedInputEnd else {
            throw WAVReplayPCMSourceError.invalidInput
        }

        var drained = false
        for _ in 0 ..< 128 {
            let status = try convert(
                converter,
                outputCapacity: 4_096,
                destination: &convertedSamples
            ) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                drained = true
            case .error:
                throw WAVReplayPCMSourceError.invalidInput
            @unknown default:
                throw WAVReplayPCMSourceError.invalidInput
            }
            break
        }
        guard drained, !convertedSamples.isEmpty else {
            throw WAVReplayPCMSourceError.invalidInput
        }
        return makePaddedFrames(from: convertedSamples)
    }

    private static func downmix(
        _ samples: [Float],
        channelCount: Int
    ) throws -> [Float] {
        guard channelCount == 2 else { return samples }
        var monoSamples: [Float] = []
        monoSamples.reserveCapacity(samples.count / 2)
        for offset in stride(from: 0, to: samples.count, by: 2) {
            monoSamples.append((samples[offset] + samples[offset + 1]) * 0.5)
        }
        guard monoSamples.allSatisfy(\.isFinite) else {
            throw WAVReplayPCMSourceError.invalidInput
        }
        return monoSamples
    }

    private static func convert(
        _ converter: AVAudioConverter,
        outputCapacity: AVAudioFrameCount,
        destination: inout [Float],
        inputProvider: @escaping AVAudioConverterInputBlock
    ) throws -> AVAudioConverterOutputStatus {
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else { throw WAVReplayPCMSourceError.invalidInput }

        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError,
            withInputFrom: inputProvider
        )
        if conversionError != nil {
            throw WAVReplayPCMSourceError.invalidInput
        }
        let count = Int(outputBuffer.frameLength)
        guard count == 0 || outputBuffer.floatChannelData != nil else {
            throw WAVReplayPCMSourceError.invalidInput
        }
        if count > 0, let channel = outputBuffer.floatChannelData?[0] {
            let output = Array(
                UnsafeBufferPointer(start: channel, count: count)
            )
            guard output.allSatisfy(\.isFinite) else {
                throw WAVReplayPCMSourceError.invalidInput
            }
            destination.append(contentsOf: output)
        }
        return status
    }

    private static func makePaddedFrames(
        from samples: [Float]
    ) -> [VoicePCMFrame] {
        stride(
            from: 0,
            to: samples.count,
            by: VoicePCMFrame.samplesPerFrame
        ).map { start in
            var values = Array(samples[
                start ..< min(
                    start + VoicePCMFrame.samplesPerFrame,
                    samples.count
                )
            ])
            if values.count < VoicePCMFrame.samplesPerFrame {
                values.append(contentsOf: repeatElement(
                    0,
                    count: VoicePCMFrame.samplesPerFrame - values.count
                ))
            }
            return VoicePCMFrame(samples: values)
        }
    }
}
