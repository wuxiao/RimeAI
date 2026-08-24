import Foundation

public enum VoicePerformanceTracerBundleLayout: Sendable {
    public static let outerBundleName =
        "RimeAIVoicePerformanceTracer.bundle"
    public static let collectorAppName =
        "RimeAIVoicePerformanceCollector.app"
    public static let driverAppName =
        "RimeAIVoicePerformanceDriver.app"
    public static let helperAppName =
        "RimeAIVoicePerformanceHelper.app"
    public static let measurementPolicyResourceRelativePath =
        "Contents/Resources/VoicePerformanceMeasurementPolicy.json"
    public static let driverPolicyResourceRelativePath =
        "Contents/Resources/VoicePerformanceDriverPolicy.json"
    public static let helperReleasePolicyResourceRelativePath =
        "Contents/Helpers/RimeAIVoicePerformanceHelper.app/Contents/Resources/VoiceReleasePolicy.plist"
    public static let collectorExecutableSuffix =
        "/Contents/Helpers/RimeAIVoicePerformanceCollector.app/Contents/MacOS/rimeai-voice-performance-tracer"
    public static let driverExecutableSuffix =
        "/Contents/Helpers/RimeAIVoicePerformanceDriver.app/Contents/MacOS/rimeai-voice-performance-driver"
    public static let helperExecutableSuffix =
        "/Contents/Helpers/RimeAIVoicePerformanceHelper.app/Contents/MacOS/rimeai-voice-performance-helper"
}

public struct VoicePerformanceCollectorProcessArguments: Equatable, Sendable {
    public let tracerBundlePath: String
    public let resultPath: String

    public static func parse(
        _ argv: [String],
        currentExecutablePath: String
    ) throws -> Self {
        guard argv.count == 5,
            byteExactlyEqual(argv[0], currentExecutablePath),
            argv[1] == "--tracer-bundle",
            argv[3] == "--result"
        else {
            throw VoicePerformanceTracerProcessError.invalidArguments
        }
        let bundle = try derivedBundlePath(
            currentExecutablePath: currentExecutablePath,
            suffix: VoicePerformanceTracerBundleLayout.collectorExecutableSuffix
        )
        guard byteExactlyEqual(argv[2], bundle) else {
            throw VoicePerformanceTracerProcessError.invalidTracerBundle
        }
        guard isCanonicalAbsolutePath(argv[4], requireTracerBundle: false) else {
            throw VoicePerformanceTracerProcessError.invalidResultPath
        }
        return Self(tracerBundlePath: bundle, resultPath: argv[4])
    }
}

public struct VoicePerformanceDriverProcessArguments: Equatable, Sendable {
    public let tracerBundlePath: String
    public let deadline: VoicePerformanceContinuousDeadline

    public static func parse(
        _ argv: [String],
        currentExecutablePath: String
    ) throws -> Self {
        guard argv.count == 5,
            byteExactlyEqual(argv[0], currentExecutablePath),
            argv[1] == "--tracer-bundle",
            argv[3] == "--deadline-continuous-ns"
        else {
            throw VoicePerformanceTracerProcessError.invalidArguments
        }
        let bundle = try derivedBundlePath(
            currentExecutablePath: currentExecutablePath,
            suffix: VoicePerformanceTracerBundleLayout.driverExecutableSuffix
        )
        guard byteExactlyEqual(argv[2], bundle) else {
            throw VoicePerformanceTracerProcessError.invalidTracerBundle
        }
        return Self(
            tracerBundlePath: bundle,
            deadline: try VoicePerformanceContinuousDeadline(parsing: argv[4])
        )
    }
}

public struct VoicePerformanceHelperProcessArguments: Equatable, Sendable {
    public let tracerBundlePath: String
    public let trial: UInt64
    public let deadline: VoicePerformanceContinuousDeadline

    public static func parse(
        _ argv: [String],
        currentExecutablePath: String,
        policyColdTrials: UInt64
    ) throws -> Self {
        guard argv.count == 7,
            byteExactlyEqual(argv[0], currentExecutablePath),
            argv[1] == "--tracer-bundle",
            argv[3] == "--trial",
            argv[5] == "--deadline-continuous-ns"
        else {
            throw VoicePerformanceTracerProcessError.invalidArguments
        }
        let bundle = try derivedBundlePath(
            currentExecutablePath: currentExecutablePath,
            suffix: VoicePerformanceTracerBundleLayout.helperExecutableSuffix
        )
        guard byteExactlyEqual(argv[2], bundle) else {
            throw VoicePerformanceTracerProcessError.invalidTracerBundle
        }
        guard policyColdTrials >= 1, policyColdTrials <= 32,
            let trial = parseStrictUInt64Decimal(argv[4]),
            trial >= 1, trial <= policyColdTrials
        else {
            throw VoicePerformanceTracerProcessError.invalidTrial
        }
        return Self(
            tracerBundlePath: bundle,
            trial: trial,
            deadline: try VoicePerformanceContinuousDeadline(parsing: argv[6])
        )
    }
}

private func derivedBundlePath(
    currentExecutablePath: String,
    suffix: String
) throws -> String {
    guard isCanonicalAbsolutePath(
        currentExecutablePath,
        requireTracerBundle: false
    ), currentExecutablePath.hasSuffix(suffix) else {
        throw VoicePerformanceTracerProcessError.invalidTracerBundle
    }
    let bundle = String(currentExecutablePath.dropLast(suffix.count))
    guard isCanonicalAbsolutePath(bundle, requireTracerBundle: true) else {
        throw VoicePerformanceTracerProcessError.invalidTracerBundle
    }
    return bundle
}

func isCanonicalAbsolutePath(
    _ path: String,
    requireTracerBundle: Bool
) -> Bool {
    guard path.utf8.count > 1,
        path.utf8.count < 4_096,
        path.first == "/",
        path.last != "/",
        byteExactlyEqual(path, path.precomposedStringWithCanonicalMapping),
        !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
    else {
        return false
    }
    let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
        components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
        })
    else {
        return false
    }
    return !requireTracerBundle || path.hasSuffix(".bundle")
}

func byteExactlyEqual(_ left: String, _ right: String) -> Bool {
    left.utf8.elementsEqual(right.utf8)
}
