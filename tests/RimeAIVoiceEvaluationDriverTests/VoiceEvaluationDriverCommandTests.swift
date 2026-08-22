import Darwin
import Foundation
import Testing
@testable import RimeAIVoiceEvaluationDriver

@Suite(.serialized)
struct VoiceEvaluationDriverCommandTests {
    @Test
    func rejectsEveryArgumentShapeExceptPlanFlagAndAbsolutePath() throws {
        for arguments in [
            ["driver"],
            ["driver", "--plan"],
            ["driver", "--plan", "relative.json"],
            ["driver", "--other", "/tmp/plan.json"],
            ["driver", "--plan", "/tmp/plan.json", "extra"],
        ] {
            let stdout = Pipe()
            let stderr = Pipe()

            let status = VoiceEvaluationDriverCommand.runForTesting(
                arguments: arguments,
                output: stdout.fileHandleForWriting,
                errorOutput: stderr.fileHandleForWriting
            )
            try stdout.fileHandleForWriting.close()
            try stderr.fileHandleForWriting.close()

            #expect(status == 64)
            #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
            #expect(
                String(
                    decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                ) == "rimeai-voice-eval-driver:E_USAGE\n"
            )
        }
    }

    @Test
    func successWritesOrderedJSONLExclusivelyWithPrivatePermissions() throws {
        let fixture = try EvaluationCommandFixture()
        defer { fixture.remove() }
        let stdout = Pipe()
        let stderr = Pipe()
        let dependencies = VoiceEvaluationDriverDependencies(
            selfSHA256: { String(repeating: "b", count: 64) },
            verifyArtifact: { plan in
                #expect(plan.artifact.artifactID == "artifact-v1")
            },
            evaluate: { plan in
                #expect(plan.samples.map(\.sampleID) == ["sample-1"])
                return [VoiceEvaluationObservation.final(
                    sampleID: "sample-1",
                    partials: [VoiceEvaluationPartial(
                        sequence: 1,
                        text: "你好",
                        elapsedMilliseconds: 10
                    )],
                    stopReceivedElapsedMilliseconds: 20,
                    text: "你好",
                    confidence: 0.75,
                    elapsedMilliseconds: 22
                )]
            }
        )

        let status = VoiceEvaluationDriverCommand.runForTesting(
            arguments: ["driver", "--plan", fixture.planURL.path],
            output: stdout.fileHandleForWriting,
            errorOutput: stderr.fileHandleForWriting,
            dependencies: dependencies
        )
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()

        #expect(status == 0)
        #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
        #expect(stderr.fileHandleForReading.readDataToEndOfFile().isEmpty)
        var information = stat()
        #expect(lstat(fixture.outputURL.path, &information) == 0)
        #expect(information.st_mode & S_IFMT == S_IFREG)
        #expect(information.st_mode & 0o777 == 0o600)
        let lines = try String(contentsOf: fixture.outputURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 1)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8))
                as? [String: Any]
        )
        #expect(object["sample_id"] as? String == "sample-1")
        #expect(object["outcome"] as? String == "final")

        let secondStatus = VoiceEvaluationDriverCommand.runForTesting(
            arguments: ["driver", "--plan", fixture.planURL.path],
            output: FileHandle.nullDevice,
            errorOutput: FileHandle.nullDevice,
            dependencies: dependencies
        )
        #expect(secondStatus == 65)
        #expect(
            try String(contentsOf: fixture.outputURL, encoding: .utf8)
                .split(separator: "\n").count == 1
        )
    }

    @Test
    func rejectsJSONLWhoseTotalSizeExceedsSixteenMebibytes() throws {
        let fixture = try EvaluationCommandFixture(sampleCount: 40)
        defer { fixture.remove() }
        let stdout = Pipe()
        let stderr = Pipe()
        let partials = (1 ... 2_000).map { sequence in
            VoiceEvaluationPartial(
                sequence: sequence,
                text: String(repeating: "x", count: 200),
                elapsedMilliseconds: Double(sequence)
            )
        }
        let dependencies = VoiceEvaluationDriverDependencies(
            selfSHA256: { String(repeating: "b", count: 64) },
            verifyArtifact: { _ in },
            evaluate: { plan in
                plan.samples.map { sample in
                    VoiceEvaluationObservation.final(
                        sampleID: sample.sampleID,
                        partials: partials,
                        stopReceivedElapsedMilliseconds: 2_001,
                        text: "final",
                        confidence: 0.75,
                        elapsedMilliseconds: 2_002
                    )
                }
            }
        )

        let status = VoiceEvaluationDriverCommand.runForTesting(
            arguments: ["driver", "--plan", fixture.planURL.path],
            output: stdout.fileHandleForWriting,
            errorOutput: stderr.fileHandleForWriting,
            dependencies: dependencies
        )
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()

        #expect(status == 65)
        #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
        #expect(
            String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ) == "rimeai-voice-eval-driver:E_EVALUATION_REJECTED\n"
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.outputURL.path))
    }
}

private final class EvaluationCommandFixture {
    let root: URL
    let planURL: URL
    let outputURL: URL

    init(sampleCount: Int = 1) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimeai-evaluation-command-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        planURL = root.appendingPathComponent("plan.json")
        outputURL = root.appendingPathComponent("observations.jsonl")
        let artifactURL = root.appendingPathComponent(
            "artifact",
            isDirectory: true
        )
        let audioURL = root.appendingPathComponent("sample.wav")
        let json = VoiceEvaluationPlanTests.validPlanJSON
            .replacingOccurrences(
                of: "/tmp/rimeai-artifact",
                with: artifactURL.path
            )
            .replacingOccurrences(
                of: "/tmp/sample-1.wav",
                with: audioURL.path
            )
            .replacingOccurrences(
                of: "/tmp/observations.jsonl",
                with: outputURL.path
            )
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8))
                as? [String: Any]
        )
        let sample = try #require(
            (object["samples"] as? [[String: Any]])?.first
        )
        object["samples"] = (1 ... sampleCount).map { index in
            var value = sample
            value["sample_id"] = "sample-\(index)"
            return value
        }
        let planData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try planData.write(to: planURL, options: .withoutOverwriting)
        #expect(chmod(planURL.path, 0o600) == 0)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
