@preconcurrency import AVFoundation
import Foundation

enum VoicePCMConversionError: Error, Equatable {
    case invalidFormat
    case unsupportedChannelCount
    case unsupportedSampleType
    case nonFiniteSample
    case inconsistentFormat
    case converterUnavailable
    case conversionFailed
    case alreadyFinished
}

enum VoicePCMStorageLayout: Equatable, Sendable {
    case interleaved
    case planar
}

/// An owned snapshot of an audio tap buffer. No `AVAudioPCMBuffer` storage is
/// retained, so this value may safely cross the source's serial work queue.
struct VoicePCMInputChunk: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let storageLayout: VoicePCMStorageLayout
    let samples: [Float]

    init(
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        storageLayout: VoicePCMStorageLayout,
        samples: [Float]
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0, frameCount >= 0 else {
            throw VoicePCMConversionError.invalidFormat
        }
        guard (1...2).contains(channelCount) else {
            throw VoicePCMConversionError.unsupportedChannelCount
        }
        let (expectedSampleCount, overflow) = frameCount.multipliedReportingOverflow(
            by: channelCount
        )
        guard !overflow, samples.count == expectedSampleCount else {
            throw VoicePCMConversionError.invalidFormat
        }
        guard samples.allSatisfy(\.isFinite) else {
            throw VoicePCMConversionError.nonFiniteSample
        }

        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.storageLayout = storageLayout
        self.samples = samples
    }

    init(copying buffer: AVAudioPCMBuffer) throws {
        let format = buffer.format
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw VoicePCMConversionError.unsupportedSampleType
        }

        let channelCount = Int(format.channelCount)
        guard (1...2).contains(channelCount) else {
            throw VoicePCMConversionError.unsupportedChannelCount
        }
        guard format.sampleRate.isFinite, format.sampleRate > 0 else {
            throw VoicePCMConversionError.invalidFormat
        }
        guard buffer.frameLength <= buffer.frameCapacity else {
            throw VoicePCMConversionError.invalidFormat
        }

        let frameCount = Int(buffer.frameLength)
        let (sampleCount, overflow) = frameCount.multipliedReportingOverflow(
            by: channelCount
        )
        guard !overflow else {
            throw VoicePCMConversionError.invalidFormat
        }
        guard sampleCount == 0 || buffer.floatChannelData != nil else {
            throw VoicePCMConversionError.unsupportedSampleType
        }

        var ownedSamples: [Float] = []
        ownedSamples.reserveCapacity(sampleCount)
        if sampleCount > 0, let channelData = buffer.floatChannelData {
            if format.isInterleaved {
                ownedSamples.append(
                    contentsOf: UnsafeBufferPointer(
                        start: channelData[0],
                        count: sampleCount
                    )
                )
            } else {
                for channel in 0..<channelCount {
                    ownedSamples.append(
                        contentsOf: UnsafeBufferPointer(
                            start: channelData[channel],
                            count: frameCount
                        )
                    )
                }
            }
        }

        try self.init(
            sampleRate: format.sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            storageLayout: format.isInterleaved ? .interleaved : .planar,
            samples: ownedSamples
        )
    }

    func downmixedMonoSamples() throws -> [Float] {
        guard channelCount == 2 else {
            return samples
        }

        var mono = [Float](repeating: 0, count: frameCount)
        switch storageLayout {
        case .interleaved:
            for frame in 0..<frameCount {
                let offset = frame * channelCount
                mono[frame] = (samples[offset] + samples[offset + 1]) * 0.5
            }
        case .planar:
            let rightOffset = frameCount
            for frame in 0..<frameCount {
                mono[frame] = (samples[frame] + samples[rightOffset + frame]) * 0.5
            }
        }

        guard mono.allSatisfy(\.isFinite) else {
            throw VoicePCMConversionError.nonFiniteSample
        }
        return mono
    }
}

protocol VoicePCMConverting: AnyObject, Sendable {
    func append(_ chunk: VoicePCMInputChunk) throws -> [VoicePCMFrame]
    func finish(padTail: Bool) throws -> [VoicePCMFrame]
    func discard()
}

/// Stateful, synchronous conversion seam used by the microphone source and by
/// synthetic-buffer tests. Calls must be serialized by the owner.
final class VoicePCMConverter: VoicePCMConverting, @unchecked Sendable {
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

    private var converter: AVAudioConverter?
    private var inputSampleRate: Double?
    private var pendingSamples: [Float] = []
    private var isFinished = false

    func append(_ buffer: AVAudioPCMBuffer) throws -> [VoicePCMFrame] {
        try append(VoicePCMInputChunk(copying: buffer))
    }

    func append(_ chunk: VoicePCMInputChunk) throws -> [VoicePCMFrame] {
        guard !isFinished else {
            throw VoicePCMConversionError.alreadyFinished
        }
        guard chunk.frameCount > 0 else {
            return []
        }

        do {
            let monoSamples = try chunk.downmixedMonoSamples()
            let converted = try convert(
                monoSamples,
                inputSampleRate: chunk.sampleRate
            )
            return appendConvertedSamples(converted)
        } catch {
            discard()
            throw error
        }
    }

    func finish(padTail: Bool = true) throws -> [VoicePCMFrame] {
        guard !isFinished else {
            return []
        }

        do {
            var frames: [VoicePCMFrame] = []
            if let converter {
                frames.append(contentsOf: appendConvertedSamples(try drain(converter)))
            }

            if padTail, !pendingSamples.isEmpty {
                pendingSamples.append(
                    contentsOf: repeatElement(
                        0,
                        count: VoicePCMFrame.samplesPerFrame - pendingSamples.count
                    )
                )
                frames.append(VoicePCMFrame(samples: pendingSamples))
            }

            pendingSamples.removeAll(keepingCapacity: false)
            converter = nil
            inputSampleRate = nil
            isFinished = true
            return frames
        } catch {
            discard()
            throw error
        }
    }

    func discard() {
        converter?.reset()
        converter = nil
        inputSampleRate = nil
        pendingSamples.removeAll(keepingCapacity: false)
        isFinished = true
    }

    private func convert(
        _ monoSamples: [Float],
        inputSampleRate: Double
    ) throws -> [Float] {
        let converter = try converterForInput(sampleRate: inputSampleRate)
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: 1,
            interleaved: false
        ),
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(monoSamples.count)
            ),
            let inputChannel = inputBuffer.floatChannelData?[0]
        else {
            throw VoicePCMConversionError.invalidFormat
        }

        inputBuffer.frameLength = AVAudioFrameCount(monoSamples.count)
        inputChannel.update(from: monoSamples, count: monoSamples.count)

        let provider = InputProvider(buffer: inputBuffer)
        let ratio = Self.outputFormat.sampleRate / inputSampleRate
        let estimatedFrames = Int(ceil(Double(monoSamples.count) * ratio)) + 512
        let outputCapacity = AVAudioFrameCount(
            min(max(estimatedFrames, 512), 65_536)
        )

        var convertedSamples: [Float] = []
        for _ in 0..<128 {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw VoicePCMConversionError.converterUnavailable
            }

            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                if provider.didProvideBuffer {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                provider.didProvideBuffer = true
                inputStatus.pointee = .haveData
                return provider.buffer
            }

            try appendOutput(from: outputBuffer, to: &convertedSamples)
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return convertedSamples
            case .error:
                _ = conversionError
                throw VoicePCMConversionError.conversionFailed
            @unknown default:
                throw VoicePCMConversionError.conversionFailed
            }
        }

        throw VoicePCMConversionError.conversionFailed
    }

    private func converterForInput(sampleRate: Double) throws -> AVAudioConverter {
        if let converter, let configuredRate = inputSampleRate {
            guard abs(configuredRate - sampleRate) < 0.001 else {
                throw VoicePCMConversionError.inconsistentFormat
            }
            return converter
        }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
            let converter = AVAudioConverter(
                from: inputFormat,
                to: Self.outputFormat
            )
        else {
            throw VoicePCMConversionError.converterUnavailable
        }

        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter.primeMethod = .normal
        self.converter = converter
        inputSampleRate = sampleRate
        return converter
    }

    private func drain(_ converter: AVAudioConverter) throws -> [Float] {
        var convertedSamples: [Float] = []
        for _ in 0..<128 {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.outputFormat,
                frameCapacity: 4_096
            ) else {
                throw VoicePCMConversionError.converterUnavailable
            }

            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }

            try appendOutput(from: outputBuffer, to: &convertedSamples)
            switch status {
            case .haveData:
                continue
            case .endOfStream, .inputRanDry:
                return convertedSamples
            case .error:
                _ = conversionError
                throw VoicePCMConversionError.conversionFailed
            @unknown default:
                throw VoicePCMConversionError.conversionFailed
            }
        }

        throw VoicePCMConversionError.conversionFailed
    }

    private func appendOutput(
        from buffer: AVAudioPCMBuffer,
        to destination: inout [Float]
    ) throws {
        let count = Int(buffer.frameLength)
        guard count == 0 || buffer.floatChannelData != nil else {
            throw VoicePCMConversionError.conversionFailed
        }
        guard count > 0, let outputChannel = buffer.floatChannelData?[0] else {
            return
        }

        let output = Array(
            UnsafeBufferPointer(start: outputChannel, count: count)
        )
        guard output.allSatisfy(\.isFinite) else {
            throw VoicePCMConversionError.nonFiniteSample
        }
        destination.append(contentsOf: output)
    }

    private func appendConvertedSamples(_ samples: [Float]) -> [VoicePCMFrame] {
        pendingSamples.append(contentsOf: samples)

        var frames: [VoicePCMFrame] = []
        var consumed = 0
        while pendingSamples.count - consumed >= VoicePCMFrame.samplesPerFrame {
            let end = consumed + VoicePCMFrame.samplesPerFrame
            frames.append(
                VoicePCMFrame(samples: Array(pendingSamples[consumed..<end]))
            )
            consumed = end
        }
        if consumed > 0 {
            pendingSamples.removeFirst(consumed)
        }
        return frames
    }
}
