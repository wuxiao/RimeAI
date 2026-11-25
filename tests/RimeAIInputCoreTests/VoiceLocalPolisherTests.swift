import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("Voice local smart polisher & transform policy")
struct VoiceLocalPolisherTests {
    @Test("removes leading and medial oral filler words cleanly")
    func removesFillerWords() {
        let result = VoiceLocalPolisher.polish(
            "嗯，那个，就是说今天下午，呃，三点开个会",
            style: .concise
        )

        #expect(result.modified)
        #expect(result.text == "今天下午，三点开个会。")
    }

    @Test("collapses Chinese stutters and bigram repetitions")
    func collapsesStutters() {
        let result = VoiceLocalPolisher.polish(
            "我我我觉得就是就是这个方案很好",
            style: .concise
        )

        #expect(result.modified)
        #expect(result.text == "我觉得就是这个方案很好。")
    }

    @Test("preserves casual tone without forcing trailing period")
    func casualStylePreservesEnding() {
        let result = VoiceLocalPolisher.polish(
            "嗯，我一会儿下楼拿个外卖",
            style: .casual
        )

        #expect(result.modified)
        #expect(result.text == "我一会儿下楼拿个外卖")
    }

    @Test("never erases an utterance consisting solely of a filler")
    func neverErasesShortUtterance() {
        let result = VoiceLocalPolisher.polish("嗯", style: .concise)

        #expect(result.text == "嗯")
        #expect(!result.modified)
    }

    @Test("capitalizes pure English sentence and cleans English fillers")
    func cleansEnglishFillers() {
        let result = VoiceLocalPolisher.polish(
            "um, please send the report by 5pm",
            style: .formal
        )

        #expect(result.modified)
        #expect(result.text == "Please send the report by 5pm")
    }

    @Test("voice transform request and response validation enforces bounds")
    func transformProtocolValidation() {
        let polishRequest = CloudVoiceTransformRequest(
            requestID: "req-1",
            clientSessionID: "session-1",
            bundleIdentifier: "com.apple.Notes",
            task: .polish,
            text: "嗯，明天开会",
            style: .concise
        )
        #expect(VoiceTransformTextPolicy.isValid(request: polishRequest))

        let invalidPolish = CloudVoiceTransformRequest(
            requestID: "req-2",
            clientSessionID: "session-1",
            bundleIdentifier: "com.apple.Notes",
            task: .polish,
            text: "明天开会",
            style: nil
        )
        #expect(!VoiceTransformTextPolicy.isValid(request: invalidPolish))

        let translateRequest = CloudVoiceTransformRequest(
            requestID: "req-3",
            clientSessionID: "session-1",
            bundleIdentifier: "com.apple.Notes",
            task: .translate,
            text: "你好世界",
            targetLanguage: .english
        )
        #expect(VoiceTransformTextPolicy.isValid(request: translateRequest))

        let response = CloudVoiceTransformResponse(
            status: "ok",
            requestID: "req-3",
            task: "translate",
            transformedText: "Hello, world!\n",
            modelID: RimeAICloudConfiguration.defaultRankingModelID,
            elapsedMilliseconds: 120
        )
        #expect(
            VoiceTransformTextPolicy.sanitizedOutput(
                response,
                for: translateRequest
            ) == "Hello, world!"
        )
    }

    // MARK: - Over-correction guards

    @Test(arguments: [
        "多多关照",
        "事事顺心",
        "我会会他聊聊这个问题",
        "好好想想再试试",
        "常常往往刚刚慢慢轻轻",
    ])
    func preservesLegitimateReduplicatedWords(phrase: String) {
        let result = VoiceLocalPolisher.polish(phrase, style: .concise)

        #expect(result.text.hasPrefix(phrase))
    }

    @Test(arguments: [
        ("会会会去开会", "会去开会"),
        ("我我也想去", "我也想去"),
        ("我我我的想法", "我的想法"),
    ])
    func stillCollapsesRealStutters(input: String, expected: String) {
        let result = VoiceLocalPolisher.polish(input, style: .concise)

        #expect(result.text == expected)
    }

    @Test("never strips uppercase acronyms that look like English fillers")
    func preservesUppercaseAcronyms() {
        let er = VoiceLocalPolisher.polish(
            "went to the ER, then home",
            style: .formal
        )
        #expect(er.text == "Went to the ER, then home")

        let leading = VoiceLocalPolisher.polish(
            "ER doctors were busy",
            style: .formal
        )
        #expect(leading.text == "ER doctors were busy")
        #expect(!leading.modified)
    }

    @Test(arguments: [
        ("I think, um, that we should go", "I think, that we should go"),
        ("she went to the ER um and then left", "She went to the ER and then left"),
        ("Um, uh, the report is due Friday", "The report is due Friday"),
        ("I saw it. um. It was late", "I saw it. um. It was late"),
    ])
    func stripsEnglishFillersWithoutGluingWords(input: String, expected: String) {
        let result = VoiceLocalPolisher.polish(input, style: .formal)

        #expect(result.text == expected)
        #expect(!result.text.contains("  "))
    }

    @Test(arguments: [
        ("那个方案很好", "那个方案很好"),
        ("这个方案很好", "这个方案很好"),
        ("嗯，那个方案很好", "那个方案很好"),
        ("那个，那个方案很好", "那个方案很好"),
        ("那个那个方案很好", "方案很好"),
    ])
    func keepsDemonstrativePronouns(input: String, expected: String) {
        let result = VoiceLocalPolisher.polish(input, style: .concise)

        #expect(result.text == expected)
    }

    @Test("leading demonstratives are only fillers before a pause or as a stutter")
    func demonstrativeFillerRules() {
        let pause = VoiceLocalPolisher.polish("那个，我觉得可以", style: .concise)
        #expect(pause.text == "我觉得可以")

        let stutter = VoiceLocalPolisher.polish("这个这个明天再说", style: .casual)
        #expect(stutter.text == "明天再说")
    }

    @Test("contrast sentences with 不是…是… are not treated as self-correction")
    func keepsContrastSentences() {
        let contrast = VoiceLocalPolisher.polish("这个不是，是那个", style: .concise)
        // 只有常规的句尾补句号；“不是，是”这个对比结构原样保留。
        #expect(contrast.text == "这个不是，是那个。")

        let attributed = VoiceLocalPolisher.polish(
            "我要的不是这个，是那个",
            style: .concise
        )
        #expect(attributed.text == "我要的不是这个，是那个。")
    }

    @Test("standalone self-correction markers are still simplified")
    func stillSimplifiesSelfCorrections() {
        let leading = VoiceLocalPolisher.polish("不对，应该是明天", style: .concise)
        #expect(leading.text == "明天")

        let medial = VoiceLocalPolisher.polish(
            "明天开会，说错了，是后天开会",
            style: .concise
        )
        #expect(medial.text == "明天开会，后天开会。")
    }

    @Test("cleans post-sentence fillers, choppy ASR connector periods, and CJK-ASCII spacing")
    func cleansChoppyASRAndSpacing() {
        let raw = "现在有一个很严重的问题是。它会因为润色卡很久。嗯，也没有办法去解决。然后。第二呢，其实是那个。嗯，格式化对吧？在macOS上使用RimeAI输入法。"
        let result = VoiceLocalPolisher.polish(raw, style: .concise)

        #expect(result.modified)
        #expect(result.text.contains("问题是，它会"))
        #expect(!result.text.contains("。嗯，"))
        #expect(!result.text.contains("。然后。"))
        #expect(result.text.contains("其实是格式化对吧？"))
        #expect(result.text.contains("在 macOS 上使用 RimeAI 输入法"))
    }

    @Test("structured style inserts clean newlines for explicit numbered enumerations")
    func structuredStyleFormatsEnumerations() {
        let result = VoiceLocalPolisher.polish(
            "第一，先去掉口语语气词。第二，做好基本格式化。第三，尽量不要大改原意。",
            style: .structured
        )

        #expect(result.modified)
        #expect(result.text == "第一，先去掉口语语气词。\n第二，做好基本格式化。\n第三，尽量不要大改原意。")
    }

    @Test("sanitizedOutput preserves newlines for structured polish only and rejects control chars")
    func sanitizedOutputMultilineContract() {
        let structuredRequest = CloudVoiceTransformRequest(
            requestID: "req-struct",
            clientSessionID: "session-1",
            bundleIdentifier: "com.apple.Notes",
            task: .polish,
            text: "第一，去除语气词。第二，做好格式化。",
            style: .structured
        )
        let structuredResponse = CloudVoiceTransformResponse(
            status: "ok",
            requestID: "req-struct",
            task: "polish",
            transformedText: "1. 去除语气词。\r\n\r\n\r\n2. 做好格式化。  \n",
            modelID: RimeAICloudConfiguration.defaultRankingModelID,
            elapsedMilliseconds: 180
        )
        #expect(
            VoiceTransformTextPolicy.sanitizedOutput(
                structuredResponse,
                for: structuredRequest
            ) == "1. 去除语气词。\n\n2. 做好格式化。"
        )

        let conciseRequest = CloudVoiceTransformRequest(
            requestID: "req-concise",
            clientSessionID: "session-1",
            bundleIdentifier: "com.apple.Notes",
            task: .polish,
            text: "第一行 第二行",
            style: .concise
        )
        let multilineForConcise = CloudVoiceTransformResponse(
            status: "ok",
            requestID: "req-concise",
            task: "polish",
            transformedText: "第一行\n第二行",
            modelID: RimeAICloudConfiguration.defaultRankingModelID,
            elapsedMilliseconds: 120
        )
        #expect(
            VoiceTransformTextPolicy.sanitizedOutput(
                multilineForConcise,
                for: conciseRequest
            ) == "第一行 第二行"
        )

        let badControlResponse = CloudVoiceTransformResponse(
            status: "ok",
            requestID: "req-struct",
            task: "polish",
            transformedText: "1. 正常\u{0007}响铃",
            modelID: RimeAICloudConfiguration.defaultRankingModelID,
            elapsedMilliseconds: 120
        )
        #expect(
            VoiceTransformTextPolicy.sanitizedOutput(
                badControlResponse,
                for: structuredRequest
            ) == nil
        )
    }
}
