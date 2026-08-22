import Foundation
import Testing
import RimeAIInputCore
@testable import RimeAIVoiceEvaluationDriver

struct VoiceEvaluationPlanTests {
    @Test
    func decodesTheExactSchemaV1EvaluationReplayPlan() throws {
        let data = Data(Self.validPlanJSON.utf8)

        let plan = try VoiceEvaluationPlan.decodeStrict(data)

        #expect(plan.collectionMethod == "evaluation_replay")
        #expect(plan.recognizerLocale == "zh-CN")
        #expect(plan.artifact.engineID == "sherpa-onnx@cccccccccccccccc")
        #expect(plan.samples.map(\.sampleID) == ["sample-1"])
        #expect(plan.hotwordSnapshot.isEmpty)
    }

    @Test
    func acceptsCorpusDerivedFractionalAudioDuration() throws {
        let json = Self.validPlanJSON
            .replacingOccurrences(
                of: "\"duration_ms\": 20,",
                with: "\"duration_ms\": 0.022675736961451247,"
            )
            .replacingOccurrences(
                of: "\"sample_rate_hz\": 16000,",
                with: "\"sample_rate_hz\": 44100,"
            )
            .replacingOccurrences(
                of: "\"frame_count\": 320",
                with: "\"frame_count\": 1"
            )

        let plan = try VoiceEvaluationPlan.decodeStrict(Data(json.utf8))

        #expect(plan.samples[0].durationMilliseconds > 0)
        #expect(plan.samples[0].sampleRateHertz == 44_100)
        #expect(plan.samples[0].frameCount == 1)
    }

    @Test
    func acceptsEnabledPolicyOnlyWhenItBindsTheValidSnapshotDigest() throws {
        let snapshot = try VoiceHotwordSnapshot(phrases: ["RimeAI"])
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(Self.validPlanJSON.utf8))
                as? [String: Any]
        )
        object["hotword_snapshot"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(snapshot)
        )
        object["policy"] = [
            "endpoint_strategy": "push-to-talk",
            "hotwords_enabled": true,
            "postprocessor_id": "none",
            "hotword_set_sha256": snapshot.hotwordSetSHA256,
        ]

        let plan = try VoiceEvaluationPlan.decodeStrict(
            JSONSerialization.data(withJSONObject: object)
        )

        #expect(plan.policy.hotwordsEnabled)
        #expect(plan.hotwordSnapshot == snapshot)
    }

    @Test
    func rejectsDuplicateKeysUnknownKeysUnsafeScalarsAndMismatchedPolicy() throws {
        let duplicateKey = Self.validPlanJSON.replacingOccurrences(
            of: "\"schema_version\": 1,",
            with: "\"schema_version\": 1, \"schema_version\": 1,"
        )
        #expect(throws: VoiceEvaluationError.self) {
            try VoiceEvaluationPlan.decodeStrict(Data(duplicateKey.utf8))
        }

        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["unknown"] = true },
            { $0["recognizer_locale"] = "fr-FR" },
            { $0["corpus_fingerprint"] = String(repeating: "A", count: 64) },
            {
                var samples = $0["samples"] as! [[String: Any]]
                samples[0].removeValue(forKey: "audio_sha256")
                $0["samples"] = samples
            },
            {
                var samples = $0["samples"] as! [[String: Any]]
                samples[0]["sample_id"] = "../unsafe"
                $0["samples"] = samples
            },
            {
                var samples = $0["samples"] as! [[String: Any]]
                samples[0]["frame_count"] = 320.5
                $0["samples"] = samples
            },
            {
                var samples = $0["samples"] as! [[String: Any]]
                samples[0]["channels"] = true
                $0["samples"] = samples
            },
            {
                var samples = $0["samples"] as! [[String: Any]]
                samples.append(samples[0])
                $0["samples"] = samples
            },
            {
                var policy = $0["policy"] as! [String: Any]
                policy["endpoint_strategy"] = "vad"
                $0["policy"] = policy
            },
            {
                var policy = $0["policy"] as! [String: Any]
                policy["hotword_set_sha256"] = String(repeating: "f", count: 64)
                $0["policy"] = policy
            },
        ]
        for mutation in mutations {
            var object = try #require(
                JSONSerialization.jsonObject(
                    with: Data(Self.validPlanJSON.utf8),
                    options: [.mutableContainers]
                ) as? [String: Any]
            )
            mutation(&object)
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: VoiceEvaluationError.self) {
                try VoiceEvaluationPlan.decodeStrict(data)
            }
        }

        let oversized = Data(
            repeating: 0x20,
            count: VoiceEvaluationPlan.maximumEncodedBytes + 1
        )
        #expect(throws: VoiceEvaluationError.self) {
            try VoiceEvaluationPlan.decodeStrict(oversized)
        }
    }

    static let validPlanJSON = """
    {
      "schema_version": 1,
      "collection_method": "evaluation_replay",
      "corpus_fingerprint": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "native_driver_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "artifact_directory": "/tmp/rimeai-artifact",
      "artifact": {
        "artifact_id": "artifact-v1",
        "artifact_content_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        "adapter_id": "sherpa-onnx",
        "engine_id": "sherpa-onnx@cccccccccccccccc",
        "model_id": "streaming-zipformer-zh-en",
        "model_revision": "2026.08.1"
      },
      "recognizer_locale": "zh-CN",
      "policy": {
        "endpoint_strategy": "push-to-talk",
        "hotwords_enabled": false,
        "postprocessor_id": "none"
      },
      "hotword_snapshot": {
        "normalization_version": 1,
        "phrases": [],
        "hotword_set_sha256": "3065f942bf0c8072df531e3a79a403a90a7c0ac884cb3d24085d838911c9adda"
      },
      "samples": [{
        "sample_id": "sample-1",
        "audio_path": "/tmp/sample-1.wav",
        "audio_sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "duration_ms": 20,
        "sample_rate_hz": 16000,
        "channels": 1,
        "frame_count": 320
      }],
      "output_path": "/tmp/observations.jsonl"
    }
    """
}
