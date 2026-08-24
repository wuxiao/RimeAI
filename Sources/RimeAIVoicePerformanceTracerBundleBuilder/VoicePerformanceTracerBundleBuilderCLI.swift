import Foundation

public enum VoicePerformanceTracerBundleBuilderCLIError:
    Error,
    Equatable,
    Sendable
{
    case invalidArguments
}

public struct VoicePerformanceTracerBundleBuilderCLIResult:
    Equatable,
    Sendable
{
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

public enum VoicePerformanceTracerBundleBuilderCLI {
    public static let usage =
        "usage: rimeai-voice-performance-tracer-bundle-builder "
        + "--final-bundle <absolute-path> "
        + "--release-bin-dir <absolute-path> "
        + "--repo-root <absolute-path> "
        + "--verified-artifact-dir <absolute-path> "
        + "--control-socket <absolute-path> "
        + "--cold-trials <1...32> "
        + "--marketing-version <version> "
        + "--build-number <positive-integer> "
        + "--signing-identity <identity> "
        + "[--signing-keychain <absolute-path>]"

    public static func parse(
        arguments: [String]
    ) throws -> VoicePerformanceTracerBundleBuildRequest {
        guard arguments.count == 19 || arguments.count == 21,
              !arguments[0].isEmpty,
              arguments[1] == "--final-bundle",
              arguments[3] == "--release-bin-dir",
              arguments[5] == "--repo-root",
              arguments[7] == "--verified-artifact-dir",
              arguments[9] == "--control-socket",
              arguments[11] == "--cold-trials",
              arguments[13] == "--marketing-version",
              arguments[15] == "--build-number",
              arguments[17] == "--signing-identity",
              arguments.count == 19
                || arguments[19] == "--signing-keychain",
              let coldTrials = strictUInt64(arguments[12])
        else {
            throw VoicePerformanceTracerBundleBuilderCLIError
                .invalidArguments
        }
        let request = VoicePerformanceTracerBundleBuildRequest(
            finalBundlePath: arguments[2],
            releaseBinDirectoryPath: arguments[4],
            repositoryRootPath: arguments[6],
            verifiedArtifactDirectoryPath: arguments[8],
            controlSocketPath: arguments[10],
            coldTrials: coldTrials,
            marketingVersion: arguments[14],
            buildNumber: arguments[16],
            signingIdentity: arguments[18],
            signingKeychainPath:
                arguments.count == 21 ? arguments[20] : nil
        )
        guard VoicePerformanceTracerBundleBuilder.isValid(request) else {
            throw VoicePerformanceTracerBundleBuilderCLIError
                .invalidArguments
        }
        return request
    }

    public static func execute(
        arguments: [String],
        builder: VoicePerformanceTracerBundleBuilder = .init()
    ) -> VoicePerformanceTracerBundleBuilderCLIResult {
        let request: VoicePerformanceTracerBundleBuildRequest
        do {
            request = try parse(arguments: arguments)
        } catch {
            return .init(
                exitCode: 64,
                standardOutput: Data(),
                standardError: Data("error: invalid arguments\n".utf8)
            )
        }
        do {
            let receipt = try builder.build(request)
            var output = try receipt.canonicalJSONData()
            output.append(0x0A)
            return .init(
                exitCode: 0,
                standardOutput: output,
                standardError: Data()
            )
        } catch {
            return .init(
                exitCode: 70,
                standardOutput: Data(),
                standardError: Data("error: bundle build failed\n".utf8)
            )
        }
    }

    private static func strictUInt64(_ value: String) -> UInt64? {
        guard !value.isEmpty,
              value == "0" || value.first != "0",
              value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
        else {
            return nil
        }
        var result: UInt64 = 0
        for byte in value.utf8 {
            let (multiplied, multiplyOverflow) =
                result.multipliedReportingOverflow(by: 10)
            let (added, addOverflow) = multiplied.addingReportingOverflow(
                UInt64(byte - 0x30)
            )
            guard !multiplyOverflow, !addOverflow else { return nil }
            result = added
        }
        return result
    }
}
