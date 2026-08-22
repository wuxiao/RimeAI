import CryptoKit
import Darwin
import Foundation
import RimeAIVoiceArtifactCore

struct VoiceEvaluationDriverDependencies: Sendable {
    let selfSHA256: @Sendable () throws -> String
    let verifyArtifact: @Sendable (VoiceEvaluationPlan) throws -> Void
    let evaluate: @Sendable (VoiceEvaluationPlan) throws
        -> [VoiceEvaluationObservation]

    static let production = Self(
        selfSHA256: VoiceEvaluationDriverCommand.productionExecutableSHA256,
        verifyArtifact: VoiceEvaluationDriverCommand.verifyArtifactIdentity,
        evaluate: { plan in
            try VoiceEvaluationRunner.production.run(plan: plan)
        }
    )
}

public enum VoiceEvaluationDriverCommand {
    public static func run(arguments: [String]) -> Int32 {
        runForTesting(
            arguments: arguments,
            output: .standardOutput,
            errorOutput: .standardError,
            dependencies: .production
        )
    }

    static func runForTesting(
        arguments: [String],
        output: FileHandle,
        errorOutput: FileHandle,
        dependencies: VoiceEvaluationDriverDependencies = .production
    ) -> Int32 {
        _ = output
        guard arguments.count == 3,
              arguments[1] == "--plan",
              arguments[2].hasPrefix("/")
        else {
            writeSafeError("E_USAGE", to: errorOutput)
            return 64
        }

        do {
            let planData = try readSecurePlan(at: arguments[2])
            let plan = try VoiceEvaluationPlan.decodeStrict(planData)
            guard try dependencies.selfSHA256()
                    == plan.nativeDriverSHA256
            else { throw VoiceEvaluationError.rejected }
            try dependencies.verifyArtifact(plan)
            let observations = try dependencies.evaluate(plan)
            guard observations.count == plan.samples.count else {
                throw VoiceEvaluationError.rejected
            }
            for (observation, sample) in zip(observations, plan.samples) {
                try observation.validate(expectedSampleID: sample.sampleID)
            }
            let encoded = try encodeJSONL(observations)
            try writeExclusive(encoded, to: plan.outputURL)
            return 0
        } catch {
            writeSafeError("E_EVALUATION_REJECTED", to: errorOutput)
            return 65
        }
    }

    private static func writeSafeError(
        _ code: StaticString,
        to output: FileHandle
    ) {
        let line = "rimeai-voice-eval-driver:\(code)\n"
        try? output.write(contentsOf: Data(line.utf8))
    }

    private static func readSecurePlan(at path: String) throws -> Data {
        guard isCanonicalAbsolutePath(path) else {
            throw VoiceEvaluationError.rejected
        }
        var pathInformation = stat()
        guard lstat(path, &pathInformation) == 0,
              pathInformation.st_mode & S_IFMT == S_IFREG,
              pathInformation.st_uid == geteuid(),
              pathInformation.st_mode & 0o077 == 0
        else { throw VoiceEvaluationError.rejected }
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw VoiceEvaluationError.rejected }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_dev == pathInformation.st_dev,
              before.st_ino == pathInformation.st_ino,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(),
              before.st_mode & 0o077 == 0,
              before.st_size > 0,
              before.st_size <= VoiceEvaluationPlan.maximumEncodedBytes
        else { throw VoiceEvaluationError.rejected }
        let count = Int(before.st_size)
        var data = Data()
        data.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while data.count < count {
            let copied = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.read(descriptor, base, bytes.count)
            }
            if copied < 0, errno == EINTR { continue }
            guard copied > 0, data.count + copied <= count else {
                throw VoiceEvaluationError.rejected
            }
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
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
        else { throw VoiceEvaluationError.rejected }
        return data
    }

    private static func encodeJSONL(
        _ observations: [VoiceEvaluationObservation]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var result = Data()
        for observation in observations {
            var line = try encoder.encode(observation)
            line.append(0x0A)
            guard line.count <= 1 * 1_024 * 1_024,
                  result.count + line.count <= 16 * 1_024 * 1_024
            else { throw VoiceEvaluationError.rejected }
            result.append(line)
        }
        guard !result.isEmpty else { throw VoiceEvaluationError.rejected }
        return result
    }

    private static func writeExclusive(_ data: Data, to url: URL) throws {
        let path = url.path
        guard isCanonicalAbsolutePath(path) else {
            throw VoiceEvaluationError.rejected
        }
        let descriptor = Darwin.open(
            path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { throw VoiceEvaluationError.rejected }
        var committed = false
        defer {
            if !committed {
                _ = Darwin.close(descriptor)
                _ = Darwin.unlink(path)
            }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw VoiceEvaluationError.rejected
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_mode & 0o777 == 0o600
        else { throw VoiceEvaluationError.rejected }

        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw VoiceEvaluationError.rejected
            }
            var written = 0
            while written < bytes.count {
                let copied = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    bytes.count - written
                )
                if copied < 0, errno == EINTR { continue }
                guard copied > 0 else {
                    throw VoiceEvaluationError.rejected
                }
                written += copied
            }
        }
        guard fsync(descriptor) == 0,
              Darwin.close(descriptor) == 0
        else { throw VoiceEvaluationError.rejected }
        committed = true
    }

    fileprivate static func verifyArtifactIdentity(
        _ plan: VoiceEvaluationPlan
    ) throws {
        let verified = try VoiceASRArtifactVerifier().verifyArtifact(
            at: plan.artifactDirectory
        )
        let manifest = verified.manifest
        guard manifest.artifactID.rawValue == plan.artifact.artifactID,
              verified.contentSHA256
                == plan.artifact.artifactContentSHA256,
              manifest.adapter.id == plan.artifact.adapterID,
              manifest.model.id == plan.artifact.modelID,
              manifest.model.revision == plan.artifact.modelRevision,
              manifest.locales.contains(plan.recognizerLocale)
        else { throw VoiceEvaluationError.rejected }
    }

    fileprivate static func productionExecutableSHA256() throws -> String {
        guard let executableURL = Bundle.main.executableURL else {
            throw VoiceEvaluationError.rejected
        }
        return try secureFileSHA256(
            executableURL.resolvingSymlinksInPath().path
        )
    }

    private static func secureFileSHA256(_ path: String) throws -> String {
        var pathInformation = stat()
        guard lstat(path, &pathInformation) == 0,
              pathInformation.st_mode & S_IFMT == S_IFREG
        else { throw VoiceEvaluationError.rejected }
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw VoiceEvaluationError.rejected }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_dev == pathInformation.st_dev,
              before.st_ino == pathInformation.st_ino,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0
        else { throw VoiceEvaluationError.rejected }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var total: Int64 = 0
        while true {
            let copied = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.read(descriptor, base, bytes.count)
            }
            if copied < 0, errno == EINTR { continue }
            guard copied >= 0 else { throw VoiceEvaluationError.rejected }
            if copied == 0 { break }
            total += Int64(copied)
            hasher.update(data: Data(buffer[..<copied]))
        }
        var after = stat()
        guard total == before.st_size,
              fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
        else { throw VoiceEvaluationError.rejected }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && path.utf8.count <= 4_096
            && !path.utf8.contains(0)
            && path == path.precomposedStringWithCanonicalMapping
            && URL(fileURLWithPath: path).standardizedFileURL.path == path
    }
}
