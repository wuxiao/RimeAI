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
        + "--artifact-dir <canonical-absolute-path> "
        + "[--cohort zipformer-bilingual-zh-en|paraformer-bilingual-zh-en]"

    public static func cohortDefinition(
        named name: String
    ) -> VoiceEvaluationArtifactCohortDefinition? {
        switch name {
        case "zipformer-bilingual-zh-en":
            return .zipformerBilingualZhEn2023
        case "paraformer-bilingual-zh-en":
            return .paraformerBilingualZhEn
        default:
            return nil
        }
    }

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
        sealer: any VoiceEvaluationArtifactSealing
    ) -> VoiceEvaluationArtifactSealerCLIResult {
        execute(arguments: arguments, sealerForCohort: { _ in sealer })
    }

    public static func execute(
        arguments: [String],
        sealerForCohort:
            @Sendable (VoiceEvaluationArtifactCohortDefinition)
                -> any VoiceEvaluationArtifactSealing = { cohort in
                VoiceEvaluationArtifactSealer(cohort: cohort)
            }
    ) -> VoiceEvaluationArtifactSealerCLIResult {
        guard arguments.count >= 3,
              !arguments[0].isEmpty,
              arguments[1] == "--artifact-dir",
              !arguments[2].isEmpty
        else {
            return failure(exitCode: 64, diagnostic: "E_USAGE\n")
        }
        var cohort = VoiceEvaluationArtifactCohortDefinition
            .zipformerBilingualZhEn2023
        if arguments.count == 5 {
            guard arguments[3] == "--cohort",
                  let named = cohortDefinition(named: arguments[4])
            else {
                return failure(exitCode: 64, diagnostic: "E_USAGE\n")
            }
            cohort = named
        } else if arguments.count != 3 {
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
            let receipt = try sealerForCohort(cohort)
                .sealArtifact(at: artifactDirectory)
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
