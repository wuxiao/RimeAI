import Testing
@testable import RimeAIInputCore

@Test("typo variants are deterministic bounded single edits")
func typoVariantsAreBounded() {
    let first = TypoVariantGenerator.variants(for: "dagn")
    let second = TypoVariantGenerator.variants(for: "dagn")

    #expect(first == second)
    #expect(first.count <= 32)
    #expect(Set(first.map(\.pinyin)).count == first.count)
    #expect(first.allSatisfy { $0.editCost == 1 })
    #expect(first.contains { $0.operation == .transposition })
    #expect(first.contains { $0.operation == .deletion })
    #expect(first.contains { $0.operation == .adjacentSubstitution })
    #expect(first.contains { $0.operation == .insertion })
}

@Test("typo variants reject malformed or oversized input")
func typoVariantsRejectMalformedInput() {
    #expect(TypoVariantGenerator.variants(for: "").isEmpty)
    #expect(TypoVariantGenerator.variants(for: "ni hao").isEmpty)
    #expect(
        TypoVariantGenerator.variants(
            for: String(repeating: "a", count: 257)
        ).isEmpty
    )
}
