import Darwin
import Foundation

public struct VoiceEvaluationArtifactSealerCLIResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(
        exitCode: Int32,
        standardOutput: Data,
        standardError: Data
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum VoiceEvaluationArtifactSealerCLI {
    public static let usage =
        "usage: rimeai-voice-evaluation-artifact-sealer "
        + "--artifact-dir <canonical-absolute-path>"

    public static func run() -> Int32 {
        let result = execute(arguments: CommandLine.arguments)
        if !result.standardOutput.isEmpty {
            FileHandle.standardOutput.write(result.standardOutput)
        }
        if !result.standardError.isEmpty {
            FileHandle.standardError.write(result.standardError)
        }
        return result.exitCode
    }

    public static func execute(
        arguments: [String],
        sealer: any VoiceEvaluationArtifactSealing =
            VoiceEvaluationArtifactSealer()
    ) -> VoiceEvaluationArtifactSealerCLIResult {
        guard arguments.count == 3,
              !arguments[0].isEmpty,
              arguments[1] == "--artifact-dir",
              !arguments[2].isEmpty
        else {
            return failure(exitCode: 64, diagnostic: "E_USAGE\n")
        }
        guard VoiceEvaluationArtifactSealer.isCanonicalAbsolutePath(
            arguments[2]
        ) else {
            return failure(exitCode: 65, diagnostic: "E_DATA\n")
        }
        let artifactDirectory = URL(
            fileURLWithPath: arguments[2],
            isDirectory: true
        )
        do {
            let receipt = try sealer.sealArtifact(at: artifactDirectory)
            var output = receipt.canonicalJSONData()
            output.append(0x0A)
            return VoiceEvaluationArtifactSealerCLIResult(
                exitCode: 0,
                standardOutput: output,
                standardError: Data()
            )
        } catch let error as VoiceEvaluationArtifactSealerError {
            switch error {
            case .invalidArtifactPath, .invalidArtifactTree,
                 .existingManifest, .payloadDoesNotMatchFrozenCohort,
                 .payloadMutation, .postSealVerificationFailed:
                return failure(exitCode: 65, diagnostic: "E_DATA\n")
            case .payloadDurabilityFailed, .manifestWriteFailed,
                 .manifestDurabilityFailed, .manifestCleanupIndeterminate:
                return failure(exitCode: 74, diagnostic: "E_IO\n")
            case .manifestEncodingFailed, .internalResourceFailure:
                return failure(exitCode: 70, diagnostic: "E_INTERNAL\n")
            }
        } catch {
            return failure(exitCode: 70, diagnostic: "E_INTERNAL\n")
        }
    }

    private static func failure(
        exitCode: Int32,
        diagnostic: String
    ) -> VoiceEvaluationArtifactSealerCLIResult {
        VoiceEvaluationArtifactSealerCLIResult(
            exitCode: exitCode,
            standardOutput: Data(),
            standardError: Data(diagnostic.utf8)
        )
    }
}
