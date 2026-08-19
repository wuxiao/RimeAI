import Testing
@testable import RimeAIInputCore

@Test
func localSentenceSuggestionsIncludeShortAbbreviatedPinyin() {
    #expect(
        LocalSentenceSuggestionPolicy.allows(
            pinyin: "fjfww",
            characterSet: .simplified
        )
    )
    #expect(
        !LocalSentenceSuggestionPolicy.allows(
            pinyin: "f",
            characterSet: .simplified
        )
    )
    #expect(
        !LocalSentenceSuggestionPolicy.allows(
            pinyin: "fjfww",
            characterSet: .traditional
        )
    )
}

@Test
func semanticSentenceSuggestionsRespectTheSelectedChineseScript() {
    #expect(
        SemanticCandidateScriptPolicy.allows(
            text: "飞机",
            characterSet: .simplified
        )
    )
    #expect(
        !SemanticCandidateScriptPolicy.allows(
            text: "飛機",
            characterSet: .simplified
        )
    )
    #expect(
        SemanticCandidateScriptPolicy.allows(
            text: "飛機",
            characterSet: .traditional
        )
    )
    #expect(
        !SemanticCandidateScriptPolicy.allows(
            text: "飞机",
            characterSet: .traditional
        )
    )
}

@Suite("Visible input preferences")
struct InputPreferencesTests {
    @Test("default preferences are simplified half-width Chinese punctuation")
    func defaults() {
        #expect(RimeAIInputPreferences() == RimeAIInputPreferences(
            characterSet: .simplified,
            characterWidth: .half,
            punctuationStyle: .chinese
        ))
    }

    @Test("Chinese punctuation is inserted in half-width mode")
    func chinesePunctuation() {
        let preferences = RimeAIInputPreferences()

        #expect(
            RimeAIInputTextTransformer.transformedLiteral(
                ",.?!(<>",
                preferences: preferences
            ) == "，。？！（《》"
        )
        #expect(
            RimeAIInputTextTransformer.transformedLiteral(
                "7",
                preferences: preferences
            ) == nil
        )
    }

    @Test("full-width mode converts printable ASCII after punctuation mapping")
    func fullWidth() {
        let preferences = RimeAIInputPreferences(
            characterWidth: .full,
            punctuationStyle: .western
        )

        #expect(
            RimeAIInputTextTransformer.transformedLiteral(
                "A7, ",
                preferences: preferences
            ) == "Ａ７，　"
        )
    }

    @Test("western half-width mode lets the host insert unchanged literals")
    func westernHalfWidth() {
        let preferences = RimeAIInputPreferences(
            punctuationStyle: .western
        )

        #expect(
            RimeAIInputTextTransformer.transformedLiteral(
                ",.",
                preferences: preferences
            ) == nil
        )
        #expect(
            RimeAIInputTextTransformer.transformedLiteral(
                "\n",
                preferences: preferences
            ) == nil
        )
    }
}
