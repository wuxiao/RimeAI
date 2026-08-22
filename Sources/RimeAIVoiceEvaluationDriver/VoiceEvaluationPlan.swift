import Foundation
import RimeAIInputCore

struct VoiceEvaluationArtifactIdentity: Equatable, Sendable {
    let artifactID: String
    let artifactContentSHA256: String
    let adapterID: String
    let engineID: String
    let modelID: String
    let modelRevision: String
}

struct VoiceEvaluationPolicy: Equatable, Sendable {
    let endpointStrategy: String
    let hotwordsEnabled: Bool
    let postprocessorID: String
    let hotwordSetSHA256: String?
}

struct VoiceEvaluationSample: Equatable, Sendable {
    let sampleID: String
    let audioURL: URL
    let audioSHA256: String
    let durationMilliseconds: Double
    let sampleRateHertz: Int
    let channels: Int
    let frameCount: Int
}

struct VoiceEvaluationPlan: Equatable, Sendable {
    static let maximumEncodedBytes = 4 * 1_024 * 1_024
    static let maximumSamples = 10_000

    let collectionMethod: String
    let corpusFingerprint: String
    let nativeDriverSHA256: String
    let artifactDirectory: URL
    let artifact: VoiceEvaluationArtifactIdentity
    let recognizerLocale: String
    let policy: VoiceEvaluationPolicy
    let hotwordSnapshot: VoiceHotwordSnapshot
    let samples: [VoiceEvaluationSample]
    let outputURL: URL

    static func decodeStrict(_ data: Data) throws -> Self {
        do {
            let value = try VoiceEvaluationStrictJSON.validate(
                data,
                maximumBytes: maximumEncodedBytes,
                maximumDepth: 8,
                maximumNodes: 160_128
            )
            guard VoiceEvaluationStrictJSON.hasExactKeys(value, [
                "schema_version",
                "collection_method",
                "corpus_fingerprint",
                "native_driver_sha256",
                "artifact_directory",
                "artifact",
                "recognizer_locale",
                "policy",
                "hotword_snapshot",
                "samples",
                "output_path",
            ]),
                let object = value as? [String: Any],
                VoiceEvaluationStrictJSON.strictUInt(
                    object["schema_version"], maximum: 1
                ) == 1,
                VoiceEvaluationStrictJSON.hasExactKeys(
                    object["artifact"] as Any,
                    [
                        "artifact_id",
                        "artifact_content_sha256",
                        "adapter_id",
                        "engine_id",
                        "model_id",
                        "model_revision",
                    ]
                ),
                VoiceEvaluationStrictJSON.hasExactKeys(
                    object["hotword_snapshot"] as Any,
                    [
                        "normalization_version",
                        "phrases",
                        "hotword_set_sha256",
                    ]
                ),
                let snapshotObject = object["hotword_snapshot"]
                    as? [String: Any],
                VoiceEvaluationStrictJSON.strictUInt(
                    snapshotObject["normalization_version"], maximum: 1
                ) == 1,
                let sampleObjects = object["samples"] as? [[String: Any]],
                !sampleObjects.isEmpty,
                sampleObjects.count <= maximumSamples,
                sampleObjects.allSatisfy({ sample in
                    VoiceEvaluationStrictJSON.hasExactKeys(sample, [
                        "sample_id",
                        "audio_path",
                        "audio_sha256",
                        "duration_ms",
                        "sample_rate_hz",
                        "channels",
                        "frame_count",
                    ])
                        && VoiceEvaluationStrictJSON.strictFiniteNumber(
                            sample["duration_ms"]
                        ) != nil
                        && VoiceEvaluationStrictJSON.strictUInt(
                            sample["sample_rate_hz"]
                        ) != nil
                        && VoiceEvaluationStrictJSON.strictUInt(
                            sample["channels"]
                        ) != nil
                        && VoiceEvaluationStrictJSON.strictUInt(
                            sample["frame_count"]
                        ) != nil
                })
            else {
                throw VoiceEvaluationError.rejected
            }

            guard let hotwordsEnabled = object["policy"]
                .flatMap({ $0 as? [String: Any] })?["hotwords_enabled"]
                as? Bool
            else { throw VoiceEvaluationError.rejected }
            let expectedPolicyKeys: Set<String> = hotwordsEnabled
                ? [
                    "endpoint_strategy",
                    "hotwords_enabled",
                    "postprocessor_id",
                    "hotword_set_sha256",
                ]
                : [
                    "endpoint_strategy",
                    "hotwords_enabled",
                    "postprocessor_id",
                ]
            guard VoiceEvaluationStrictJSON.hasExactKeys(
                object["policy"] as Any,
                expectedPolicyKeys
            ) else { throw VoiceEvaluationError.rejected }

            let wire = try JSONDecoder().decode(Wire.self, from: data)
            guard wire.schemaVersion == 1,
                  wire.collectionMethod == "evaluation_replay",
                  Validation.isSHA256(wire.corpusFingerprint),
                  Validation.isSHA256(wire.nativeDriverSHA256),
                  Validation.isCanonicalAbsolutePath(wire.artifactDirectory),
                  Validation.isCanonicalAbsolutePath(wire.outputPath),
                  ["zh-CN", "en-US"].contains(wire.recognizerLocale),
                  wire.hotwordSnapshot.isValid,
                  wire.policy.endpointStrategy == "push-to-talk",
                  wire.policy.postprocessorID == "none",
                  wire.policy.hotwordsEnabled == !wire.hotwordSnapshot.isEmpty,
                  wire.policy.hotwordSetSHA256
                    == (wire.policy.hotwordsEnabled
                        ? wire.hotwordSnapshot.hotwordSetSHA256 : nil)
            else { throw VoiceEvaluationError.rejected }

            let identity = try VoiceEvaluationArtifactIdentity(
                validating: wire.artifact
            )
            let samples = try wire.samples.map(
                VoiceEvaluationSample.init(validating:)
            )
            guard Set(samples.map(\.sampleID)).count == samples.count,
                  !samples.map(\.audioURL.path).contains(wire.outputPath),
                  wire.outputPath != wire.artifactDirectory,
                  !Validation.isDescendant(
                    wire.outputPath,
                    of: wire.artifactDirectory
                  )
            else { throw VoiceEvaluationError.rejected }

            return Self(
                collectionMethod: wire.collectionMethod,
                corpusFingerprint: wire.corpusFingerprint,
                nativeDriverSHA256: wire.nativeDriverSHA256,
                artifactDirectory: URL(
                    fileURLWithPath: wire.artifactDirectory,
                    isDirectory: true
                ),
                artifact: identity,
                recognizerLocale: wire.recognizerLocale,
                policy: VoiceEvaluationPolicy(
                    endpointStrategy: wire.policy.endpointStrategy,
                    hotwordsEnabled: wire.policy.hotwordsEnabled,
                    postprocessorID: wire.policy.postprocessorID,
                    hotwordSetSHA256: wire.policy.hotwordSetSHA256
                ),
                hotwordSnapshot: wire.hotwordSnapshot,
                samples: samples,
                outputURL: URL(fileURLWithPath: wire.outputPath)
            )
        } catch let error as VoiceEvaluationError {
            throw error
        } catch {
            throw VoiceEvaluationError.rejected
        }
    }

    private struct Wire: Decodable {
        let schemaVersion: Int
        let collectionMethod: String
        let corpusFingerprint: String
        let nativeDriverSHA256: String
        let artifactDirectory: String
        let artifact: ArtifactWire
        let recognizerLocale: String
        let policy: PolicyWire
        let hotwordSnapshot: VoiceHotwordSnapshot
        let samples: [SampleWire]
        let outputPath: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case collectionMethod = "collection_method"
            case corpusFingerprint = "corpus_fingerprint"
            case nativeDriverSHA256 = "native_driver_sha256"
            case artifactDirectory = "artifact_directory"
            case artifact
            case recognizerLocale = "recognizer_locale"
            case policy
            case hotwordSnapshot = "hotword_snapshot"
            case samples
            case outputPath = "output_path"
        }
    }

    fileprivate struct ArtifactWire: Decodable {
        let artifactID: String
        let artifactContentSHA256: String
        let adapterID: String
        let engineID: String
        let modelID: String
        let modelRevision: String

        enum CodingKeys: String, CodingKey {
            case artifactID = "artifact_id"
            case artifactContentSHA256 = "artifact_content_sha256"
            case adapterID = "adapter_id"
            case engineID = "engine_id"
            case modelID = "model_id"
            case modelRevision = "model_revision"
        }
    }

    private struct PolicyWire: Decodable {
        let endpointStrategy: String
        let hotwordsEnabled: Bool
        let postprocessorID: String
        let hotwordSetSHA256: String?

        enum CodingKeys: String, CodingKey {
            case endpointStrategy = "endpoint_strategy"
            case hotwordsEnabled = "hotwords_enabled"
            case postprocessorID = "postprocessor_id"
            case hotwordSetSHA256 = "hotword_set_sha256"
        }
    }

    fileprivate struct SampleWire: Decodable {
        let sampleID: String
        let audioPath: String
        let audioSHA256: String
        let durationMilliseconds: Double
        let sampleRateHertz: Int
        let channels: Int
        let frameCount: Int

        enum CodingKeys: String, CodingKey {
            case sampleID = "sample_id"
            case audioPath = "audio_path"
            case audioSHA256 = "audio_sha256"
            case durationMilliseconds = "duration_ms"
            case sampleRateHertz = "sample_rate_hz"
            case channels
            case frameCount = "frame_count"
        }
    }
}

private extension VoiceEvaluationArtifactIdentity {
    init(validating wire: VoiceEvaluationPlan.ArtifactWire) throws {
        let digest = wire.artifactContentSHA256
        let candidate = "\(wire.adapterID)@\(digest.prefix(16))"
        let derivedEngineID = candidate.utf8.count <= 128
            ? candidate : "product@\(digest.prefix(16))"
        guard VoiceEvaluationPlan.Validation.isSafeIdentifier(wire.artifactID),
              VoiceEvaluationPlan.Validation.isSHA256(digest),
              VoiceEvaluationPlan.Validation.isSafeIdentifier(wire.adapterID),
              VoiceEvaluationPlan.Validation.isEngineIdentifier(wire.engineID),
              wire.engineID == derivedEngineID,
              VoiceEvaluationPlan.Validation.isSafeIdentifier(wire.modelID),
              VoiceEvaluationPlan.Validation.isSafeIdentifier(wire.modelRevision)
        else { throw VoiceEvaluationError.rejected }
        self.init(
            artifactID: wire.artifactID,
            artifactContentSHA256: digest,
            adapterID: wire.adapterID,
            engineID: wire.engineID,
            modelID: wire.modelID,
            modelRevision: wire.modelRevision
        )
    }
}

private extension VoiceEvaluationSample {
    init(validating wire: VoiceEvaluationPlan.SampleWire) throws {
        let derivedDuration = Double(wire.frameCount) * 1_000
            / Double(wire.sampleRateHertz)
        let tolerance = max(0.01, 1_000 / Double(wire.sampleRateHertz))
        guard VoiceEvaluationPlan.Validation.isSafeIdentifier(wire.sampleID),
              VoiceEvaluationPlan.Validation.isCanonicalAbsolutePath(
                wire.audioPath
              ),
              VoiceEvaluationPlan.Validation.isSHA256(wire.audioSHA256),
              wire.durationMilliseconds.isFinite,
              wire.durationMilliseconds > 0,
              wire.durationMilliseconds <= 60_000,
              [16_000, 44_100, 48_000].contains(wire.sampleRateHertz),
              (1 ... 2).contains(wire.channels),
              wire.frameCount > 0,
              abs(wire.durationMilliseconds - derivedDuration) <= tolerance
        else { throw VoiceEvaluationError.rejected }
        self.init(
            sampleID: wire.sampleID,
            audioURL: URL(fileURLWithPath: wire.audioPath),
            audioSHA256: wire.audioSHA256,
            durationMilliseconds: wire.durationMilliseconds,
            sampleRateHertz: wire.sampleRateHertz,
            channels: wire.channels,
            frameCount: wire.frameCount
        )
    }
}

private extension VoiceEvaluationPlan {
    enum Validation {
        static func isSHA256(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy {
                (0x30 ... 0x39).contains($0)
                    || (0x61 ... 0x66).contains($0)
            }
        }

        static func isSafeIdentifier(_ value: String) -> Bool {
            guard (1 ... 128).contains(value.utf8.count),
                  let first = value.utf8.first,
                  isAlphaNumeric(first)
            else { return false }
            return value.utf8.dropFirst().allSatisfy {
                isAlphaNumeric($0) || [0x2E, 0x5F, 0x2D].contains($0)
            }
        }

        static func isEngineIdentifier(_ value: String) -> Bool {
            guard (1 ... 128).contains(value.utf8.count),
                  let first = value.utf8.first,
                  isAlphaNumeric(first)
            else { return false }
            return value.utf8.dropFirst().allSatisfy {
                isAlphaNumeric($0)
                    || [0x2E, 0x5F, 0x2D, 0x40].contains($0)
            }
        }

        static func isCanonicalAbsolutePath(_ value: String) -> Bool {
            value.hasPrefix("/")
                && value.utf8.count <= 4_096
                && !value.utf8.contains(0)
                && value == value.precomposedStringWithCanonicalMapping
                && URL(fileURLWithPath: value).standardizedFileURL.path == value
        }

        static func isDescendant(_ path: String, of directory: String) -> Bool {
            path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
        }

        private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
            (0x30 ... 0x39).contains(byte)
                || (0x41 ... 0x5A).contains(byte)
                || (0x61 ... 0x7A).contains(byte)
        }
    }
}
