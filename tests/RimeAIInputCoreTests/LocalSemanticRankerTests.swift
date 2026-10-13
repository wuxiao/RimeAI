import Foundation
import Testing
@testable import RimeAIInputCore

@Test
func localSemanticRankerPromotesAContextualCandidate() throws {
    let ranker = LocalSemanticRanker(
        rankWeight: 0.1,
        frequencyWeight: 1,
        languageWeight: 2,
        candidateFrequencies: ["命令": 2],
        ngramCounts: [
            2: ["条命": 2, "命令": 2],
            3: ["这条命": 2, "条命令": 2],
            4: [:],
            5: [:],
        ],
        prefixCounts: [
            2: ["条": 2, "命": 2],
            3: ["这条": 2, "条命": 2],
            4: [:],
            5: [:],
        ]
    )

    let result = ranker.rank(
        context: "请执行这条",
        candidates: ["明令", "命令"]
    )

    #expect(result.rankedCandidates.first == "命令")
    #expect(result.confidence > 0.55)
}

@Test
func languageScoreAppliesStupidBackoffLikeThePythonRanker() throws {
    // Mirrors tests/test_ngram_ranker.py::test_backoff_falls_to_lower_order_
    // when_high_order_unseen: context "好" + candidate "天气" gives text
    // "^好天气" — position "天" hits the bigram MLE scaled by alpha^3,
    // position "气" hits the trigram MLE scaled by alpha^2.
    let ranker = LocalSemanticRanker(
        rankWeight: 0,
        frequencyWeight: 0,
        languageWeight: 1,
        candidateFrequencies: [:],
        ngramCounts: [
            2: ["好天": 1],
            3: ["好天气": 1],
            4: [:],
            5: [:],
        ],
        prefixCounts: [
            2: ["好": 1],
            3: ["好天": 1],
            4: [:],
            5: [:],
        ],
        backoffAlpha: 0.4
    )

    let result = ranker.rank(
        context: "好",
        candidates: ["天气", "zz"]
    )

    let hitScore = (Foundation.log(0.4 * 0.4 * 0.4) + Foundation.log(0.4 * 0.4)) / 2
    let unseenScore = (
        Foundation.log(0.1 / 1_001 * 0.4 * 0.4 * 0.4)
            + Foundation.log(0.1 / 1_000 * 0.4 * 0.4 * 0.4)
    ) / 2
    let margin = hitScore - unseenScore
    let confidence = 1 / (1 + Foundation.exp(-margin))

    #expect(result.rankedCandidates == ["天气", "zz"])
    #expect(abs(result.confidence - confidence) < 0.000_000_001)
}

@Test
func localSemanticDecisionMakesAbstentionObservable() throws {
    let ranker = LocalSemanticRanker(
        rankWeight: 0.1,
        frequencyWeight: 0,
        languageWeight: 0,
        candidateFrequencies: [:],
        ngramCounts: [2: [:], 3: [:], 4: [:], 5: [:]],
        prefixCounts: [2: [:], 3: [:], 4: [:], 5: [:]]
    )

    let result = ranker.evaluate(
        context: "",
        candidates: ["时间", "事件"],
        minimumConfidence: 0.55
    )

    #expect(result.decision == .sameTopCandidate)
    #expect(result.candidate == nil)
}

@Test
func localSemanticDecisionDoesNotReportAgreementWithoutAComparison() throws {
    let ranker = LocalSemanticRanker(
        rankWeight: 0.1,
        frequencyWeight: 0,
        languageWeight: 0,
        candidateFrequencies: [:],
        ngramCounts: [2: [:], 3: [:], 4: [:], 5: [:]],
        prefixCounts: [2: [:], 3: [:], 4: [:], 5: [:]]
    )

    let result = ranker.evaluate(
        context: "",
        candidates: ["附近服务为", "放进去", "风景区"]
    )

    #expect(result.decision == .insufficientCandidates)
    #expect(result.confidence == 0)
}

@Test
func compactIOSArtifactMatchesApprovedPythonRankerFixtures() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let artifact = repositoryRoot
        .appendingPathComponent("ios/SemanticModel/rimeai-p0-ngram-v2.bin")
    let ranker = try LocalSemanticRanker(contentsOf: artifact)

    #expect(
        ranker.artifactID
            == "p0-char-ngram:05213235f4b7:dataset-f0d46219a334"
    )
    let command = ranker.rank(
        context: "请执行这条",
        candidates: ["明令", "命令"]
    )
    #expect(command.rankedCandidates == ["命令", "明令"])
    #expect(abs(command.confidence - 0.9979906149508826) < 0.000_000_001)

    let emptyContext = ranker.rank(
        context: "",
        candidates: ["你好", "你号"]
    )
    #expect(emptyContext.rankedCandidates == ["你好", "你号"])
    #expect(abs(emptyContext.confidence - 0.5621765008857981) < 0.000_000_001)
}

@Test
func compactArtifactParserRejectsLegacyV1Artifacts() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let legacy = repositoryRoot
        .appendingPathComponent("ios/SemanticModel/rimeai-p0-ngram-v1.bin")

    do {
        _ = try LocalSemanticRanker(contentsOf: legacy)
        Issue.record("expected the RAINGRM1 artifact to be rejected")
    } catch let error as LocalSemanticRankerError {
        #expect(error.errorDescription?.contains("retrain") == true)
    }
}
