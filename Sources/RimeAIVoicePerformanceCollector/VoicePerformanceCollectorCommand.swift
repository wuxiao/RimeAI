import Foundation

struct VoicePerformanceBoundedNDJSONReader {
    private let maximumLineBytes: Int
    private var pending: [UInt8] = []
    private var failed = false

    init(maximumLineBytes: Int) {
        precondition(maximumLineBytes > 0)
        self.maximumLineBytes = maximumLineBytes
        pending.reserveCapacity(maximumLineBytes)
    }

    mutating func append(_ data: Data) throws -> [Data] {
        guard !failed else {
            throw VoicePerformanceCollectorError.invalidEvent
        }
        var records: [Data] = []
        do {
            for byte in data {
                if byte == 0x0A {
                    records.append(Data(pending))
                    pending.removeAll(keepingCapacity: true)
                } else {
                    guard byte != 0x0D else {
                        throw VoicePerformanceCollectorError.invalidEvent
                    }
                    guard pending.count < maximumLineBytes else {
                        throw VoicePerformanceCollectorError.invalidEvent
                    }
                    pending.append(byte)
                }
            }
            return records
        } catch {
            failed = true
            pending.removeAll(keepingCapacity: false)
            throw VoicePerformanceCollectorError.invalidEvent
        }
    }

    mutating func finish() throws {
        guard !failed, pending.isEmpty else {
            failed = true
            pending.removeAll(keepingCapacity: false)
            throw VoicePerformanceCollectorError.invalidEvent
        }
    }
}

final class VoicePerformanceSerialCollector: @unchecked Sendable {
    private enum State {
        case running
        case finishing
        case finished
        case failed(VoicePerformanceCollectorError)
    }

    private let queue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-performance-collector.sampler"
    )
    private let collection: VoicePerformanceCollection
    private var timer: DispatchSourceTimer?
    private var state: State = .running

    init(
        collection: VoicePerformanceCollection,
        sampleIntervalMilliseconds: Int,
        startsTimer: Bool = true
    ) {
        self.collection = collection
        if startsTimer {
            let source = DispatchSource.makeTimerSource(queue: queue)
            timer = source
            source.schedule(
                deadline: .now() + .milliseconds(sampleIntervalMilliseconds),
                repeating: .milliseconds(sampleIntervalMilliseconds),
                leeway: .milliseconds(max(1, sampleIntervalMilliseconds / 10))
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                _ = try? sampleOnQueue()
            }
            source.resume()
        }
    }

    func consume(
        _ event: VoicePerformanceLiveEvent
    ) throws -> VoicePerformanceUnboundResult? {
        try queue.sync {
            switch state {
            case .running:
                break
            case let .failed(error):
                throw error
            case .finishing, .finished:
                throw VoicePerformanceCollectorError.invalidStateTransition
            }

            if case .finish = event {
                state = .finishing
                cancelTimerOnQueue()
                do {
                    try collection.consume(event)
                    let result = try collection.finish()
                    state = .finished
                    return result
                } catch {
                    let collectorError = Self.collectorError(error)
                    state = .failed(collectorError)
                    throw collectorError
                }
            }

            do {
                try collection.consume(event)
                return nil
            } catch {
                let collectorError = Self.collectorError(error)
                state = .failed(collectorError)
                cancelTimerOnQueue()
                throw collectorError
            }
        }
    }

    @discardableResult
    func sampleIfRunning() throws -> Bool {
        try queue.sync {
            try sampleOnQueue()
        }
    }

    func failAndStop() {
        queue.sync {
            switch state {
            case .running, .finishing:
                state = .failed(.invalidEvent)
                cancelTimerOnQueue()
            case .finished, .failed:
                break
            }
        }
    }

    private func sampleOnQueue() throws -> Bool {
        switch state {
        case .running:
            do {
                try collection.sample()
                return true
            } catch {
                let collectorError = Self.collectorError(error)
                state = .failed(collectorError)
                cancelTimerOnQueue()
                throw collectorError
            }
        case .finishing, .finished:
            return false
        case let .failed(error):
            throw error
        }
    }

    private func cancelTimerOnQueue() {
        timer?.cancel()
        timer = nil
    }

    private static func collectorError(_ error: Error)
        -> VoicePerformanceCollectorError
    {
        error as? VoicePerformanceCollectorError ?? .samplingFailed
    }
}

public enum VoicePerformanceCollectorCommand {
    private static let maximumResultBytes = 4 * 1_024 * 1_024

    public static func run(
        arguments: [String],
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        errorOutput: FileHandle = .standardError
    ) -> Int32 {
        run(
            arguments: arguments,
            input: input,
            output: output,
            errorOutput: errorOutput,
            platform: DarwinVoicePerformancePlatform(),
            artifactVerifier: VoicePerformanceASRArtifactVerifier(),
            startsTimer: true
        )
    }

    static func runForTesting(
        arguments: [String],
        input: FileHandle,
        output: FileHandle,
        errorOutput: FileHandle,
        platform: any VoicePerformancePlatform,
        artifactVerifier: any VoicePerformanceArtifactVerifying =
            VoicePerformanceASRArtifactVerifier()
    ) -> Int32 {
        run(
            arguments: arguments,
            input: input,
            output: output,
            errorOutput: errorOutput,
            platform: platform,
            artifactVerifier: artifactVerifier,
            startsTimer: false
        )
    }

    private static func run(
        arguments: [String],
        input: FileHandle,
        output: FileHandle,
        errorOutput: FileHandle,
        platform: any VoicePerformancePlatform,
        artifactVerifier: any VoicePerformanceArtifactVerifying,
        startsTimer: Bool
    ) -> Int32 {
        guard arguments.count == 3,
              arguments[1] == "--plan"
        else {
            writeSafeError("E_USAGE", to: errorOutput)
            return 64
        }
        do {
            let planData = try readSecurePlan(at: arguments[2])
            let plan = try VoicePerformanceCollectionPlan.decodeStrict(planData)
            try requireLiveInput(input)
            let collection = try VoicePerformanceCollection(
                plan: plan,
                platform: platform,
                artifactVerifier: artifactVerifier
            )
            let serial = VoicePerformanceSerialCollector(
                collection: collection,
                sampleIntervalMilliseconds: plan.sampleIntervalMilliseconds,
                startsTimer: startsTimer
            )
            var completed = false
            defer {
                if !completed { serial.failAndStop() }
            }
            var reader = VoicePerformanceBoundedNDJSONReader(
                maximumLineBytes: VoicePerformanceLiveEvent.maximumEncodedBytes
            )
            var finalResult: VoicePerformanceUnboundResult?
            while true {
                guard let chunk = try input.read(upToCount: 4_096),
                      !chunk.isEmpty
                else { break }
                for record in try reader.append(chunk) {
                    guard finalResult == nil else {
                        throw VoicePerformanceCollectorError
                            .invalidStateTransition
                    }
                    let event = try VoicePerformanceLiveEvent
                        .decodeStrictNDJSONLine(record)
                    if let result = try serial.consume(event) {
                        finalResult = result
                    }
                }
            }
            try reader.finish()
            guard let finalResult else {
                throw VoicePerformanceCollectorError.incompleteCollection
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var encoded = try encoder.encode(finalResult)
            encoded.append(0x0A)
            guard encoded.count <= maximumResultBytes else {
                throw VoicePerformanceCollectorError.samplingFailed
            }
            try output.write(contentsOf: encoded)
            completed = true
            return 0
        } catch {
            writeSafeError("E_COLLECTION_REJECTED", to: errorOutput)
            return 65
        }
    }

    private static func requireLiveInput(_ input: FileHandle) throws {
        var information = stat()
        guard fstat(input.fileDescriptor, &information) == 0
        else {
            throw VoicePerformanceCollectorError.invalidEvent
        }
        let fileType = information.st_mode & S_IFMT
        guard fileType == S_IFIFO
                || fileType == S_IFSOCK
                || fileType == S_IFCHR
        else {
            throw VoicePerformanceCollectorError.invalidEvent
        }
    }

    private static func readSecurePlan(at path: String) throws -> Data {
        guard path.hasPrefix("/"),
              path == path.precomposedStringWithCanonicalMapping,
              URL(fileURLWithPath: path).standardizedFileURL.path == path
        else {
            throw VoicePerformanceCollectorError.invalidPlan
        }
        var pathInformation = stat()
        guard lstat(path, &pathInformation) == 0,
              pathInformation.st_mode & S_IFMT == S_IFREG,
              pathInformation.st_uid == geteuid(),
              pathInformation.st_mode & 0o077 == 0
        else {
            throw VoicePerformanceCollectorError.invalidPlan
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw VoicePerformanceCollectorError.invalidPlan
        }
        defer { Darwin.close(descriptor) }
        var descriptorInformation = stat()
        guard fstat(descriptor, &descriptorInformation) == 0,
              descriptorInformation.st_dev == pathInformation.st_dev,
              descriptorInformation.st_ino == pathInformation.st_ino,
              descriptorInformation.st_mode & S_IFMT == S_IFREG,
              descriptorInformation.st_uid == geteuid(),
              descriptorInformation.st_mode & 0o077 == 0,
              descriptorInformation.st_size > 0,
              descriptorInformation.st_size
                <= VoicePerformanceCollectionPlan.maximumEncodedBytes
        else {
            throw VoicePerformanceCollectorError.invalidPlan
        }

        let expectedCount = Int(descriptorInformation.st_size)
        var data = Data()
        data.reserveCapacity(expectedCount)
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while data.count <= expectedCount {
            let copied = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(descriptor, baseAddress, rawBuffer.count)
            }
            if copied < 0, errno == EINTR { continue }
            guard copied >= 0 else {
                throw VoicePerformanceCollectorError.invalidPlan
            }
            if copied == 0 { break }
            guard data.count + copied
                    <= VoicePerformanceCollectionPlan.maximumEncodedBytes
            else {
                throw VoicePerformanceCollectorError.invalidPlan
            }
            data.append(contentsOf: buffer[..<copied])
        }
        var after = stat()
        guard data.count == expectedCount,
              fstat(descriptor, &after) == 0,
              after.st_dev == descriptorInformation.st_dev,
              after.st_ino == descriptorInformation.st_ino,
              after.st_size == descriptorInformation.st_size,
              after.st_mtimespec.tv_sec
                == descriptorInformation.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec
                == descriptorInformation.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec
                == descriptorInformation.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec
                == descriptorInformation.st_ctimespec.tv_nsec
        else {
            throw VoicePerformanceCollectorError.invalidPlan
        }
        return data
    }

    private static func writeSafeError(
        _ code: StaticString,
        to output: FileHandle
    ) {
        let line = "rimeai-voice-performance-collector:\(code)\n"
        try? output.write(contentsOf: Data(line.utf8))
    }
}
