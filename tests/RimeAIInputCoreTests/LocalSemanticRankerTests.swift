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
func compactIOSArtifactMatchesApprovedPythonRankerFixtures() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let artifact = repositoryRoot
        .appendingPathComponent("ios/SemanticModel/rimeai-p0-ngram-v1.bin")
    let ranker = try LocalSemanticRanker(contentsOf: artifact)

    #expect(
        ranker.artifactID
            == "p0-char-ngram:36457c630dc8:dataset-f0d46219a334"
    )
    let command = ranker.rank(
        context: "请执行这条",
        candidates: ["明令", "命令"]
    )
    #expect(command.rankedCandidates == ["命令", "明令"])
    #expect(abs(command.confidence - 0.9180312945877884) < 0.000_000_001)

    let emptyContext = ranker.rank(
        context: "",
        candidates: ["你好", "你号"]
    )
    #expect(emptyContext.rankedCandidates == ["你好", "你号"])
    #expect(abs(emptyContext.confidence - 0.5249791874789399) < 0.000_000_001)
}
