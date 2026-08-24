import Foundation
import Testing
@testable import RimeAIVoiceEvaluationArtifactSealer

@Suite("Internal voice evaluation artifact sealer CLI")
struct VoiceEvaluationArtifactSealerCLITests {
    @Test("exact argv emits only one canonical success receipt")
    func successfulCLIReceiptIsCanonical() throws {
        let fixture = try EvaluationArtifactFixtureForCLI()
        defer { fixture.remove() }

        let result = VoiceEvaluationArtifactSealerCLI.execute(
            arguments: [
                "rimeai-voice-evaluation-artifact-sealer",
                "--artifact-dir",
                fixture.root.path,
            ],
            sealer: VoiceEvaluationArtifactSealer(expectedPayloads: nil)
        )

        #expect(result.exitCode == 0)
        #expect(result.standardError.isEmpty)
        #expect(result.standardOutput.last == 0x0A)
        let line = Data(result.standardOutput.dropLast())
        #expect(!line.contains(0x0A))
        #expect(!line.contains(0x0D))
        let object = try #require(
            JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
        #expect(object.keys.sorted() == [
            "artifact_id", "content_sha256", "verified_file_count",
            "verified_payload_bytes",
        ])
        #expect(
            object["artifact_id"] as? String
                == VoiceEvaluationArtifactCohort.artifactID
        )
        #expect(object["verified_file_count"] as? Int == 7)
    }

    @Test("empty or malformed argv maps to fixed usage failure")
    func invalidArgumentsAreUsage() {
        for arguments in [
            [String](),
            ["tool"],
            ["tool", "--wrong", "/private/tmp/artifact"],
            ["tool", "--artifact-dir", "/private/tmp/artifact", "extra"],
        ] {
            let result = VoiceEvaluationArtifactSealerCLI.execute(
                arguments: arguments
            )
            #expect(result.exitCode == 64)
            #expect(result.standardOutput.isEmpty)
            #expect(result.standardError == Data("E_USAGE\n".utf8))
        }
    }

    @Test("noncanonical or rejected input maps to fixed data failure")
    func rejectedInputIsData() {
        let relative = VoiceEvaluationArtifactSealerCLI.execute(
            arguments: ["tool", "--artifact-dir", "relative/artifact"]
        )
        #expect(relative.exitCode == 65)
        #expect(relative.standardOutput.isEmpty)
        #expect(relative.standardError == Data("E_DATA\n".utf8))

        let typed = VoiceEvaluationArtifactSealerCLI.execute(
            arguments: ["tool", "--artifact-dir", "/private/tmp/artifact"],
            sealer: TypedFailureSealer(error: .invalidArtifactTree)
        )
        #expect(typed.exitCode == 65)
        #expect(typed.standardOutput.isEmpty)
        #expect(typed.standardError == Data("E_DATA\n".utf8))
    }

    @Test("write uncertainty maps to fixed IO failure")
    func writeUncertaintyIsIO() {
        let result = VoiceEvaluationArtifactSealerCLI.execute(
            arguments: ["tool", "--artifact-dir", "/private/tmp/artifact"],
            sealer: TypedFailureSealer(error: .manifestCleanupIndeterminate)
        )
        #expect(result.exitCode == 74)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError == Data("E_IO\n".utf8))
    }

    @Test("unknown errors map to E_INTERNAL without leaking their description")
    func unknownFailureIsInternalAndSecretFree() {
        let result = VoiceEvaluationArtifactSealerCLI.execute(
            arguments: ["tool", "--artifact-dir", "/private/tmp/artifact"],
            sealer: UnexpectedFailureSealer()
        )
        #expect(result.exitCode == 70)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError == Data("E_INTERNAL\n".utf8))
        #expect(
            result.standardError.range(of: Data("TOP_SECRET".utf8)) == nil
        )
    }
}

private struct TypedFailureSealer: VoiceEvaluationArtifactSealing {
    let error: VoiceEvaluationArtifactSealerError

    func sealArtifact(
        at artifactDirectory: URL
    ) throws -> VoiceEvaluationArtifactSealReceipt {
        _ = artifactDirectory
        throw error
    }
}

private struct UnexpectedFailureSealer: VoiceEvaluationArtifactSealing {
    func sealArtifact(
        at artifactDirectory: URL
    ) throws -> VoiceEvaluationArtifactSealReceipt {
        _ = artifactDirectory
        throw UnexpectedSealerError(
            description: "TOP_SECRET /private/tmp/credential-bearing-path"
        )
    }
}

private struct UnexpectedSealerError: Error, CustomStringConvertible {
    let description: String
}

private final class EvaluationArtifactFixtureForCLI {
    private static let payloads: [(String, Data)] = [
        ("licenses/LICENSE.txt", Data("license\n".utf8)),
        (
            "licenses/NOTICE.txt",
            Data(
                """
                RimeAI Voice Evaluation Artifact Notice

                Internal evaluation only.
                Redistribution is not approved.
                Production use or release is not approved.
                Upstream rights, immutable revision mapping, and NOTICE obligations remain unresolved.

                """.utf8
            )
        ),
        ("model/bpe.vocab", Data("bpe\n".utf8)),
        ("model/decoder.onnx", Data("decoder\n".utf8)),
        ("model/encoder.onnx", Data("encoder\n".utf8)),
        ("model/joiner.onnx", Data("joiner\n".utf8)),
        ("model/tokens.txt", Data("tokens\n".utf8)),
    ]

    let root: URL

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "rimeai-evaluation-sealer-cli-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for directory in ["licenses", "model"] {
            let url = root.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        }
        for (path, data) in Self.payloads {
            let url = root.appendingPathComponent(path)
            try data.write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
