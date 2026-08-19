import Testing
@testable import RimeAIInputCore

@Suite("Bounded cloud candidate pool")
struct CloudCandidatePoolAssemblerTests {
    @Test("pool is deterministic, deduplicated and candidate-only")
    func deterministicPool() {
        let fuzzy = [
            CloudFuzzyCandidateGroup(
                variant: TypoVariant(
                    pinyin: "nihao",
                    operation: .deletion
                ),
                candidateTexts: ["你好", "拟好", "你号"]
            ),
        ]

        let first = CloudCandidatePoolAssembler.assemble(
            pinyin: "niihao",
            exactCandidateTexts: ["你一号", "你好"],
            fuzzyGroups: fuzzy
        )
        let second = CloudCandidatePoolAssembler.assemble(
            pinyin: "niihao",
            exactCandidateTexts: ["你一号", "你好"],
            fuzzyGroups: fuzzy
        )

        #expect(first == second)
        #expect(first.candidates.map(\.text) == ["你一号", "你好", "拟好", "你号"])
        #expect(first.candidates[0].source == .rimeExact)
        #expect(first.candidates[2].source == .rimeFuzzy)
        #expect(first.candidates[2].alignedPinyin == "nihao")
        #expect(first.candidates.allSatisfy { $0.isValid(for: "niihao") })
        #expect(first.hash.count == 64)
    }

    @Test("pool never exceeds fifty or admits invalid candidates")
    func boundedPool() {
        let exact = (0..<60).map { "候选\($0)" }
        let fuzzy = TypoVariantGenerator.variants(
            for: "zhongguo",
            maximumCount: 32
        ).map { variant in
            CloudFuzzyCandidateGroup(
                variant: variant,
                candidateTexts: (0..<8).map { index in
                    "\(variant.pinyin)-\(index)"
                }
            )
        }

        let pool = CloudCandidatePoolAssembler.assemble(
            pinyin: "zhongguo",
            exactCandidateTexts: exact,
            fuzzyGroups: fuzzy,
            maximumCount: 999
        )

        #expect(pool.candidates.count == 50)
        #expect(Set(pool.candidates.map { $0.id }).count == 50)
        #expect(pool.candidates.allSatisfy { $0.isValid(for: "zhongguo") })
    }
}
