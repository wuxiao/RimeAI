import Testing
@testable import RimeAIInputCore

struct VoiceHotwordCorrectorTests {
    @Test("restores ASCII spacing, casing, and separators within mixed text")
    func asciiSkeletonRestoration() {
        let hotwords = ["RimeAI", "FastAPI", "Next.js"]
        let result = VoiceHotwordCorrector.applyReturningMatches(
            to: "我在用 rime ai 和 fast api 以及 next js 写接口",
            hotwords: hotwords
        )

        #expect(result.text == "我在用 RimeAI 和 FastAPI 以及 Next.js 写接口")
        #expect(result.appliedHotwords == ["RimeAI", "FastAPI", "Next.js"])

        // Must never split or corrupt partial/larger ASCII tokens.
        let negative = VoiceHotwordCorrector.applyReturningMatches(
            to: "faster api and fastapix are untouched, RimeAI stays clean",
            hotwords: hotwords
        )
        #expect(negative.text == "faster api and fastapix are untouched, RimeAI stays clean")
        #expect(negative.appliedHotwords.isEmpty)
    }

    @Test("guards short common English words in English prose while restoring in Chinese context")
    func shortCommonWordContextGuard() {
        let hotwords = ["Go", "In"]

        let prose = VoiceHotwordCorrector.apply(
            to: "let's go home and stay in touch",
            hotwords: hotwords
        )
        #expect(prose == "let's go home and stay in touch")

        let mixed = VoiceHotwordCorrector.apply(
            to: "我想用 go 语言写后端",
            hotwords: hotwords
        )
        #expect(mixed == "我想用 Go 语言写后端")
    }

    @Test("restores Chinese phonetic homophones and fuzzy syllables")
    func chineseHomophoneRestoration() {
        let hotwords = ["雾凇拼音", "王伟"]
        let result = VoiceHotwordCorrector.applyReturningMatches(
            to: "无松拼音很好用，是王维推荐给我的。",
            hotwords: hotwords
        )

        #expect(result.text == "雾凇拼音很好用，是王伟推荐给我的。")
        #expect(result.appliedHotwords == ["雾凇拼音", "王伟"])
    }

    @Test("restores mixed hotwords and enforces longest-first non-overlapping lock")
    func mixedHotwordAndLongestFirstLock() {
        let hotwords = ["RimeAI", "RimeAI输入法"]
        let result = VoiceHotwordCorrector.applyReturningMatches(
            to: "我在用 rime ai 输如法，比原版 rime ai 更好",
            hotwords: hotwords
        )

        #expect(result.text == "我在用 RimeAI输入法，比原版 RimeAI 更好")
        #expect(result.appliedHotwords == ["RimeAI输入法", "RimeAI"])
    }

    @Test("prioritizeForCloud lifts matching hotwords into bounded budget")
    func prioritizeForCloudMatchesAheadOfGeneralEntries() {
        var hotwords = (1 ... 38).map { "通用词条\($0)" }
        hotwords.append("雾凇拼音")
        hotwords.append("FastAPI")

        let prioritized = VoiceHotwordCorrector.prioritizeForCloud(
            hotwords: hotwords,
            transcript: "请问无松拼音和 fast api 怎么配合",
            limit: 32
        )

        #expect(prioritized.count == 32)
        #expect(prioritized.prefix(2).contains("FastAPI"))
        #expect(prioritized.prefix(2).contains("雾凇拼音"))
    }

    @Test("contextual derivePinyinKeys reads polyphonic runs and honors explicit Rime hint")
    func contextualPinyinKeyDerivation() {
        #expect(
            VoicePostCommitCorrectionLearner.derivePinyinKeys(for: "雾凇拼音")
                == "wusongpinyin"
        )
        #expect(
            VoicePostCommitCorrectionLearner.derivePinyinKeys(for: "RimeAI输入法")
                == "rimeaishurufa"
        )
        #expect(
            VoicePostCommitCorrectionLearner.derivePinyinKeys(for: "重复")
                == "zhongfu"
        )
        #expect(
            VoicePostCommitCorrectionLearner.derivePinyinKeys(
                for: "重载",
                hintedPhrase: "重载",
                hintedPinyin: "chongzai"
            ) == "chongzai"
        )
    }

    @Test("vocabulary-tier hotwords restore ASCII spelling but never replace Han characters by sound")
    func vocabularyTierNeverRewritesHan() {
        let corrector = VoiceHotwordCorrector(
            hotwords: [],
            vocabularyHotwords: ["知道", "设计", "他们", "FastAPI"]
        )

        // L1 / 词库里的普通词曾把无关转录的同音词成片改错。
        #expect(corrector.apply(to: "一直到现在都没回复") == "一直到现在都没回复")
        #expect(corrector.apply(to: "这个设计涉及安全") == "这个设计涉及安全")
        #expect(corrector.apply(to: "她们去公园了") == "她们去公园了")
        #expect(corrector.apply(to: "我在用 fast api 写接口") == "我在用 FastAPI 写接口")
    }

    @Test("user-curated hotwords restore exact homophones only, never fuzzy near-homophones")
    func curatedHotwordsNeedExactSyllables() {
        let corrector = VoiceHotwordCorrector(hotwords: ["雾凇拼音", "王伟"])

        #expect(corrector.apply(to: "无松拼音很好用") == "雾凇拼音很好用")
        #expect(corrector.apply(to: "王维推荐给我的") == "王伟推荐给我的")
        // 比较的是无调拼音（“五”与“雾”同音，照常还原）；前后鼻音等模糊音不再触发。
        #expect(corrector.apply(to: "无松拼英很好用") == "无松拼英很好用")
        #expect(corrector.apply(to: "五松拼音很好用") == "雾凇拼音很好用")
    }

    @Test("streaming application equals one-shot application on a growing transcript")
    func streamingMatchesOneShot() throws {
        let hotwords = ["RimeAI", "雾凇拼音", "FastAPI"]
        let full = "我先用了 rime ai，后来换成 fast api，无松拼音也不错，最后还是回到 rime ai。"
        let oneShot = VoiceHotwordCorrector.apply(to: full, hotwords: hotwords)
        var streaming = VoiceHotwordCorrector(hotwords: hotwords)

        var prefix = ""
        for character in full {
            prefix.append(character)
            let expected = VoiceHotwordCorrector.apply(to: prefix, hotwords: hotwords)
            let actual = streaming.applyStreaming(to: prefix)
            try #require(
                actual == expected,
                "streaming diverged at \(prefix.count) characters"
            )
        }

        #expect(oneShot.contains("RimeAI"))
        #expect(oneShot.contains("FastAPI"))
        #expect(oneShot.contains("雾凇拼音"))
    }

    @Test("instance prioritization reuses compiled hotwords and matches the static helper")
    func instancePrioritizationMatchesStaticHelper() {
        let hotwords = (1 ... 38).map { "通用词条\($0)" } + ["雾凇拼音", "FastAPI"]
        let transcript = "请问无松拼音和 fast api 怎么配合"
        let corrector = VoiceHotwordCorrector(hotwords: hotwords)

        #expect(
            corrector.prioritizedForCloud(transcript: transcript, limit: 32)
                == VoiceHotwordCorrector.prioritizeForCloud(
                    hotwords: hotwords,
                    transcript: transcript,
                    limit: 32
                )
        )

        // Without a transcript there is nothing to rank against: the caller's
        // order (hotword priority) must survive untouched.
        let mixed = ["张三", "RimeAI", "雾凇拼音"]
        #expect(
            VoiceHotwordCorrector(hotwords: mixed)
                .prioritizedForCloud(transcript: "", limit: 32) == mixed
        )
        #expect(
            VoiceHotwordCorrector(
                hotwords: ["王伟"],
                vocabularyHotwords: ["FastAPI"]
            )
            .prioritizedForCloud(transcript: "", limit: 32) == ["王伟", "FastAPI"]
        )
    }
}
