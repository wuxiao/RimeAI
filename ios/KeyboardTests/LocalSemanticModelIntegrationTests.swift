import XCTest

final class LocalSemanticModelIntegrationTests: XCTestCase {
    func testBundledP0ModelLoadsAndMatchesApprovedFixture() throws {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(
            forResource: "rimeai-p0-ngram-v2",
            withExtension: "bin",
            subdirectory: "SemanticModel"
        ) ?? bundle.url(
            forResource: "rimeai-p0-ngram-v2",
            withExtension: "bin"
        )
        let modelURL = try XCTUnwrap(url, "P0 semantic model is not bundled")
        let ranker = try LocalSemanticRanker(contentsOf: modelURL)

        XCTAssertEqual(
            ranker.artifactID,
            "p0-char-ngram:05213235f4b7:dataset-f0d46219a334"
        )
        let evaluation = ranker.evaluate(
            context: "请执行这条",
            candidates: ["明令", "命令"]
        )
        XCTAssertEqual(evaluation.decision, .rankedCandidate)
        XCTAssertEqual(evaluation.candidate, "命令")
        XCTAssertGreaterThan(evaluation.confidence, 0.9)
    }
}
