import Testing
@testable import RimeAIInputCore

struct MixedCompositionResolverTests {
    private let candidates: [String: [String]] = [
        "zhege": ["这个"],
        "xuyao": ["需要"],
        "xuyaozengjia": ["需要增加"],
        "peizhi": ["配置"],
    ]

    @Test("uppercase acronym forms a hard English boundary without spaces")
    func uppercaseAcronym() {
        let suggestion = resolve("zhegeAPIxuyao")

        #expect(suggestion?.text == "这个API需要")
        #expect(suggestion?.segments == [
            MixedCompositionSegment(kind: .pinyin, rawText: "zhege", renderedText: "这个"),
            MixedCompositionSegment(kind: .ascii, rawText: "API", renderedText: "API"),
            MixedCompositionSegment(kind: .pinyin, rawText: "xuyao", renderedText: "需要"),
        ])
        #expect(suggestion?.confidence == 0.98)
    }

    @Test("lowercase technical terms are segmented inside one continuous input")
    func lowercaseTechnicalTerms() {
        let suggestion = resolve(
            "zhegeapixuyaozengjiatimeoutpeizhi"
        )

        #expect(suggestion?.text == "这个api需要增加timeout配置")
        #expect(suggestion?.segments.map(\.kind) == [
            .pinyin, .ascii, .pinyin, .ascii, .pinyin,
        ])
        #expect(suggestion?.segments.filter { $0.kind == .ascii }.map(\.rawText) == [
            "api", "timeout",
        ])
    }

    @Test("English casing is preserved verbatim")
    func casingIsPreserved() {
        let suggestion = resolve(
            "zhegeAPIxuyaozengjiatimeoutpeizhi"
        )

        #expect(suggestion?.text == "这个API需要增加timeout配置")
    }

    @Test("personal history can teach a lowercase English token")
    func personalizedToken() {
        let suggestion = resolve(
            "zhegewaynexuyao",
            personalizedEnglishTokens: ["wayne"]
        )

        #expect(suggestion?.text == "这个wayne需要")
        #expect(suggestion?.confidence == 0.90)
    }

    @Test("history token extraction learns English without storing surrounding text")
    func historyTokenExtraction() {
        let tokens = MixedCompositionResolver.personalizedEnglishTokens(
            from: "这个 API 使用 timeoutConfig，men 和 AI 不应学习。"
        )

        #expect(tokens.contains("api"))
        #expect(tokens.contains("timeoutconfig"))
        #expect(!tokens.contains("men"))
        #expect(!tokens.contains("ai"))
        #expect(!tokens.contains("这个"))
    }

    @Test("pure pinyin and pure English do not become mixed suggestions")
    func requiresBothLanguages() {
        #expect(resolve("zhege") == nil)
        #expect(resolve("API") == nil)
    }

    @Test("every pinyin gap must have a Chinese candidate")
    func requiresCompleteChineseGaps() {
        let resolver = MixedCompositionResolver()
        let suggestion = resolver.resolve(
            rawInput: "zhegeAPIbukexuyao",
            personalizedEnglishTokens: []
        ) { pinyin, _ in
            self.candidates[pinyin] ?? []
        }

        #expect(suggestion == nil)
    }

    @Test("a single shifted letter remains pinyin, not an English boundary")
    func singleUppercaseLetterIsNotMixed() {
        #expect(resolve("Zhege") == nil)
    }

    @Test("two-letter learned tokens do not split ordinary pinyin")
    func twoLetterLearnedTokenIsIgnored() {
        let resolver = MixedCompositionResolver()
        var lookupCount = 0
        let suggestion = resolver.resolve(
            rawInput: "aihaoma",
            personalizedEnglishTokens: ["ai"]
        ) { _, _ in
            lookupCount += 1
            return ["爱好吗"]
        }

        #expect(suggestion == nil)
        #expect(lookupCount == 0)
    }

    @Test("learned pinyin-like words do not split pure pinyin")
    func learnedPinyinWordDoesNotSplitPurePinyin() {
        let resolver = MixedCompositionResolver(builtinEnglishTokens: [])
        let suggestion = resolver.resolve(
            rawInput: "women",
            personalizedEnglishTokens: ["men"]
        ) { pinyin, _ in
            ["wo": ["我"], "women": ["我们"]][pinyin] ?? []
        }

        #expect(suggestion == nil)
    }

    @Test("curated lowercase tokens do not override all-pinyin streams")
    func builtinTokenDoesNotOverrideEntirePinyinStream() {
        let resolver = MixedCompositionResolver(
            builtinEnglishTokens: ["api"]
        )
        let suggestion = resolver.resolve(rawInput: "womenapi") {
            pinyin,
            _ in
            ["women": ["我们"], "womenapi": ["我们阿皮"]][pinyin] ?? []
        }

        #expect(suggestion == nil)
    }

    @Test("leading letters that cannot begin a pinyin syllable form a raw English prefix")
    func leadingNonPinyinPrefix() {
        let resolver = MixedCompositionResolver()
        let suggestion = resolver.resolve(rawInput: "inihao") { pinyin, _ in
            ["nihao": ["你好"]][pinyin] ?? []
        }

        #expect(suggestion?.text == "i你好")
        #expect(suggestion?.segments == [
            MixedCompositionSegment(kind: .ascii, rawText: "i", renderedText: "i"),
            MixedCompositionSegment(kind: .pinyin, rawText: "nihao", renderedText: "你好"),
        ])
    }

    @Test("a leading i/u/v run stays one raw prefix")
    func leadingNonPinyinRun() {
        let resolver = MixedCompositionResolver()
        let suggestion = resolver.resolve(rawInput: "uvwang") { pinyin, _ in
            ["wang": ["王"]][pinyin] ?? []
        }

        #expect(suggestion?.text == "uv王")
        #expect(suggestion?.segments == [
            MixedCompositionSegment(kind: .ascii, rawText: "uv", renderedText: "uv"),
            MixedCompositionSegment(kind: .pinyin, rawText: "wang", renderedText: "王"),
        ])
    }

    @Test("a raw prefix requires the remainder to be complete pinyin")
    func rawPrefixRequiresPinyinRemainder() {
        let resolver = MixedCompositionResolver()
        let suggestion = resolver.resolve(rawInput: "iphone") { pinyin, _ in
            ["phone": ["不支持"]][pinyin] ?? []
        }

        #expect(suggestion == nil)
    }

    @Test("raw lead split separates non-initial letters from a pinyin remainder")
    func rawLeadSplit() {
        let split1 = MixedCompositionResolver.rawLeadSplit(of: "inihao")
        #expect(split1?.lead == "i")
        #expect(split1?.remainder == "nihao")
        let split2 = MixedCompositionResolver.rawLeadSplit(of: "uvwang")
        #expect(split2?.lead == "uv")
        #expect(split2?.remainder == "wang")
        let split3 = MixedCompositionResolver.rawLeadSplit(of: "UVnihao")
        #expect(split3?.lead == "uv")
        #expect(split3?.remainder == "nihao")
    }

    @Test("raw lead split requires a complete pinyin remainder")
    func rawLeadSplitRejectsNonPinyinRemainder() {
        #expect(MixedCompositionResolver.rawLeadSplit(of: "iphone") == nil)
        #expect(MixedCompositionResolver.rawLeadSplit(of: "iuu") == nil)
        #expect(MixedCompositionResolver.rawLeadSplit(of: "nihao") == nil)
        #expect(MixedCompositionResolver.rawLeadSplit(of: "") == nil)
    }

    @Test("candidate lookups have an independent hard budget")
    func lookupBudget() {
        let resolver = MixedCompositionResolver(
            builtinEnglishTokens: ["api", "app", "timeout"],
            maximumOccurrences: 64,
            maximumSearchNodes: 512,
            maximumCandidateLookups: 8
        )
        var lookupCount = 0
        _ = resolver.resolve(
            rawInput: String(repeating: "maapiapptimeout", count: 12),
            personalizedEnglishTokens: []
        ) { _, _ in
            lookupCount += 1
            return ["吗"]
        }

        #expect(lookupCount <= 8)
    }

    private func resolve(
        _ rawInput: String,
        personalizedEnglishTokens: Set<String> = []
    ) -> MixedCompositionSuggestion? {
        MixedCompositionResolver().resolve(
            rawInput: rawInput,
            personalizedEnglishTokens: personalizedEnglishTokens
        ) { pinyin, _ in
            candidates[pinyin] ?? []
        }
    }
}
