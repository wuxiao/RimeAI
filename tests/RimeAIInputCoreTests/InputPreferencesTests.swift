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

    @Test("punctuation keys are recognized under both punctuation styles")
    func punctuationLiteralRecognition() {
        for scalar in [",", ".", "?", "!", ":", ";", "(", ")", "[", "]", "<", ">", "\\"].map({ $0.unicodeScalars.first! }) {
            #expect(RimeAIInputTextTransformer.isPunctuationLiteral(scalar))
        }
        #expect(!RimeAIInputTextTransformer.isPunctuationLiteral("a"))
        #expect(!RimeAIInputTextTransformer.isPunctuationLiteral("="))
        #expect(!RimeAIInputTextTransformer.isPunctuationLiteral(" "))

        let chinese = RimeAIInputPreferences(punctuationStyle: .chinese)
        let western = RimeAIInputPreferences(punctuationStyle: .western)

        // 标点两种风格都进入 composition；chinese 映射全角，western 原样
        #expect(
            RimeAIInputTextTransformer.compositionLiteralText(
                ",".unicodeScalars.first!,
                preferences: chinese
            ) == "，"
        )
        #expect(
            RimeAIInputTextTransformer.compositionLiteralText(
                ",".unicodeScalars.first!,
                preferences: western
            ) == ","
        )

        // 未映射符号在 half 模式不进入 composition（走 flush 放行）
        #expect(
            RimeAIInputTextTransformer.compositionLiteralText(
                "=".unicodeScalars.first!,
                preferences: chinese
            ) == nil
        )
        // 全角模式下其余符号全角化后进入 composition
        let fullWidth = RimeAIInputPreferences(
            characterWidth: .full,
            punctuationStyle: .western
        )
        #expect(
            RimeAIInputTextTransformer.compositionLiteralText(
                "=".unicodeScalars.first!,
                preferences: fullWidth
            ) == "＝"
        )
        // 拼音分隔符 ' 不作为字面量（字母路径保留）
        #expect(
            RimeAIInputTextTransformer.compositionLiteralText(
                "'".unicodeScalars.first!,
                preferences: chinese
            ) == nil
        )
    }

    @Test("leading punctuation commits directly instead of entering composition")
    func leadingPunctuationCommit() {
        let chinese = RimeAIInputPreferences(punctuationStyle: .chinese)
        let western = RimeAIInputPreferences(punctuationStyle: .western)

        // 空缓冲（第一个字符）：标点直接上屏，按风格转换
        #expect(
            RimeAIInputTextTransformer.leadingLiteralCommitText(
                ",".unicodeScalars.first!,
                hasComposition: false,
                preferences: chinese
            ) == "，"
        )
        #expect(
            RimeAIInputTextTransformer.leadingLiteralCommitText(
                ".".unicodeScalars.first!,
                hasComposition: false,
                preferences: chinese
            ) == "。"
        )
        #expect(
            RimeAIInputTextTransformer.leadingLiteralCommitText(
                ",".unicodeScalars.first!,
                hasComposition: false,
                preferences: western
            ) == ","
        )

        // 已有 composition：标点仍进入 composition，不直接上屏
        #expect(
            RimeAIInputTextTransformer.leadingLiteralCommitText(
                ",".unicodeScalars.first!,
                hasComposition: true,
                preferences: chinese
            ) == nil
        )

        // 非标点符号即使空缓冲也不直接上屏（全角模式下仍进入
        // composition，走字面量路径）
        let fullWidth = RimeAIInputPreferences(
            characterWidth: .full,
            punctuationStyle: .western
        )
        #expect(
            RimeAIInputTextTransformer.leadingLiteralCommitText(
                "=".unicodeScalars.first!,
                hasComposition: false,
                preferences: fullWidth
            ) == nil
        )
        #expect(
            RimeAIInputTextTransformer.leadingLiteralCommitText(
                "a".unicodeScalars.first!,
                hasComposition: false,
                preferences: chinese
            ) == nil
        )
    }
}

@Test("script sanitization converts instead of rejecting")
func scriptSanitizationConvertsInsteadOfRejecting() {
    // 已符合设置：原样返回
    #expect(
        SemanticCandidateScriptPolicy.sanitized(
            text: "诗人疾之不能默",
            characterSet: .simplified
        ) == "诗人疾之不能默"
    )
    // 混入繁体：就地转换（字典简繁混收的真实场景）
    #expect(
        SemanticCandidateScriptPolicy.sanitized(
            text: "詩人極之不能摹",
            characterSet: .simplified
        ) == "诗人极之不能摹"
    )
    // 繁体模式下反向转换
    #expect(
        SemanticCandidateScriptPolicy.sanitized(
            text: "诗人",
            characterSet: .traditional
        ) != nil
    )
    // 空文本不可用
    #expect(
        SemanticCandidateScriptPolicy.sanitized(
            text: "",
            characterSet: .simplified
        ) == nil
    )
}
