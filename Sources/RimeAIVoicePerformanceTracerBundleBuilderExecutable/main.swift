import Darwin
import Foundation
import RimeAIVoicePerformanceTracerBundleBuilder

let result = VoicePerformanceTracerBundleBuilderCLI.execute(
    arguments: CommandLine.arguments
)
if !result.standardOutput.isEmpty {
    FileHandle.standardOutput.write(result.standardOutput)
}
if !result.standardError.isEmpty {
    FileHandle.standardError.write(result.standardError)
}
exit(result.exitCode)
