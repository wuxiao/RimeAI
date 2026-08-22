import Foundation
import Testing
@testable import RimeAIVoicePerformanceTracerProcessDarwin

@Suite("Voice performance tracer process exact argv")
struct VoicePerformanceProcessArgumentsTests {
    @Test("collector accepts only the frozen child-bundle layout and argument order")
    func collectorAcceptsFrozenLayout() throws {
        let bundle = "/Applications/RimeAIVoicePerformanceTracer.bundle"
        let executable =
            bundle
            + VoicePerformanceTracerBundleLayout.collectorExecutableSuffix
        let result = "/private/tmp/rimeai-result.json"

        let arguments = try VoicePerformanceCollectorProcessArguments.parse(
            [
                executable,
                "--tracer-bundle",
                bundle,
                "--result",
                result,
            ],
            currentExecutablePath: executable
        )

        #expect(arguments.tracerBundlePath == bundle)
        #expect(arguments.resultPath == result)
    }

    @Test("driver accepts the frozen bundle and strict continuous deadline")
    func driverAcceptsFrozenLayout() throws {
        let bundle = "/Applications/RimeAIVoicePerformanceTracer.bundle"
        let executable =
            bundle + VoicePerformanceTracerBundleLayout.driverExecutableSuffix

        let arguments = try VoicePerformanceDriverProcessArguments.parse(
            [
                executable,
                "--tracer-bundle",
                bundle,
                "--deadline-continuous-ns",
                "18446744073709551615",
            ],
            currentExecutablePath: executable
        )

        #expect(arguments.tracerBundlePath == bundle)
        #expect(arguments.deadline.nanoseconds == UInt64.max)
    }

    @Test("helper binds a strict trial number to the policy trial bound")
    func helperBindsTrialToPolicy() throws {
        let bundle = "/Applications/RimeAIVoicePerformanceTracer.bundle"
        let executable =
            bundle + VoicePerformanceTracerBundleLayout.helperExecutableSuffix

        let arguments = try VoicePerformanceHelperProcessArguments.parse(
            [
                executable,
                "--tracer-bundle",
                bundle,
                "--trial",
                "32",
                "--deadline-continuous-ns",
                "123456789",
            ],
            currentExecutablePath: executable,
            policyColdTrials: 32
        )

        #expect(arguments.tracerBundlePath == bundle)
        #expect(arguments.trial == 32)
        #expect(arguments.deadline.nanoseconds == 123_456_789)
    }

    @Test("an app lookalike cannot stand in for the frozen outer bundle")
    func appLookalikeIsRejected() {
        let bundle = "/Applications/RimeAIVoicePerformanceTracer.app"
        let executable =
            bundle + VoicePerformanceTracerBundleLayout.collectorExecutableSuffix

        #expect(throws: VoicePerformanceTracerProcessError.invalidTracerBundle) {
            try VoicePerformanceCollectorProcessArguments.parse(
                [
                    executable,
                    "--tracer-bundle",
                    bundle,
                    "--result",
                    "/private/tmp/result.json",
                ],
                currentExecutablePath: executable
            )
        }
    }

    @Test("deadline and trial values are canonical UInt64 decimals")
    func numericValuesAreCanonicalDecimals() {
        let bundle = "/Applications/RimeAIVoicePerformanceTracer.bundle"
        let driver = bundle + VoicePerformanceTracerBundleLayout.driverExecutableSuffix
        let helper = bundle + VoicePerformanceTracerBundleLayout.helperExecutableSuffix
        let invalidDecimals = [
            "", "00", "01", "+1", "-1", " 1", "1 ", "１",
            "18446744073709551616",
        ]

        for value in invalidDecimals {
            #expect(throws: VoicePerformanceTracerProcessError.invalidDeadline) {
                try VoicePerformanceDriverProcessArguments.parse(
                    [
                        driver,
                        "--tracer-bundle",
                        bundle,
                        "--deadline-continuous-ns",
                        value,
                    ],
                    currentExecutablePath: driver
                )
            }
        }
        for value in invalidDecimals + ["0", "33"] {
            #expect(throws: VoicePerformanceTracerProcessError.invalidTrial) {
                try VoicePerformanceHelperProcessArguments.parse(
                    [
                        helper,
                        "--tracer-bundle",
                        bundle,
                        "--trial",
                        value,
                        "--deadline-continuous-ns",
                        "1",
                    ],
                    currentExecutablePath: helper,
                    policyColdTrials: 32
                )
            }
        }
        #expect(throws: VoicePerformanceTracerProcessError.invalidTrial) {
            try VoicePerformanceHelperProcessArguments.parse(
                [
                    helper,
                    "--tracer-bundle",
                    bundle,
                    "--trial",
                    "3",
                    "--deadline-continuous-ns",
                    "1",
                ],
                currentExecutablePath: helper,
                policyColdTrials: 2
            )
        }
    }

    @Test("reordering, aliases, and free path flags are rejected")
    func rejectsArgumentMutationAndAliases() {
        let bundle = "/Applications/RimeAIVoicePerformanceTracer.bundle"
        let executable =
            bundle + VoicePerformanceTracerBundleLayout.collectorExecutableSuffix
        let valid = [
            executable,
            "--tracer-bundle",
            bundle,
            "--result",
            "/private/tmp/result.json",
        ]

        #expect(throws: VoicePerformanceTracerProcessError.invalidArguments) {
            try VoicePerformanceCollectorProcessArguments.parse(
                [valid[0], valid[3], valid[4], valid[1], valid[2]],
                currentExecutablePath: executable
            )
        }
        #expect(throws: VoicePerformanceTracerProcessError.invalidArguments) {
            try VoicePerformanceCollectorProcessArguments.parse(
                valid + ["--policy", "/private/tmp/policy.json"],
                currentExecutablePath: executable
            )
        }
        #expect(throws: VoicePerformanceTracerProcessError.invalidArguments) {
            try VoicePerformanceCollectorProcessArguments.parse(
                ["rimeai-voice-performance-tracer"] + valid.dropFirst(),
                currentExecutablePath: executable
            )
        }
        let shortExecutable =
            bundle
            + "/Contents/Helpers/Collector.app/Contents/MacOS/rimeai-voice-performance-tracer"
        var shortLayout = valid
        shortLayout[0] = shortExecutable
        #expect(throws: VoicePerformanceTracerProcessError.invalidTracerBundle) {
            try VoicePerformanceCollectorProcessArguments.parse(
                shortLayout,
                currentExecutablePath: shortExecutable
            )
        }
        var aliasedBundle = valid
        aliasedBundle[2] = "/Applications/./RimeAIVoicePerformanceTracer.bundle"
        #expect(throws: VoicePerformanceTracerProcessError.invalidTracerBundle) {
            try VoicePerformanceCollectorProcessArguments.parse(
                aliasedBundle,
                currentExecutablePath: executable
            )
        }
    }
}
