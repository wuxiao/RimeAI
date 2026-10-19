import Foundation
import Testing
@testable import RimeAIInputCore

private func fixtureSegments(
    activePinyin: String = "jutouwangshanshi"
) -> [PinyinSegment] {
    [
        PinyinSegment(
            pinyin: "chuangqianmingyueguang",
            separator: "，",
            committedText: "床前明月光"
        ),
        PinyinSegment(
            pinyin: activePinyin,
            separator: "",
            committedText: nil
        ),
    ]
}

private func uniformSegments(
    count: Int,
    letters: Int = 1,
    lastSeparator: String = ""
) -> [PinyinSegment] {
    (0 ..< count).map { index in
        PinyinSegment(
            pinyin: String(repeating: "a", count: letters),
            separator: index == count - 1 ? lastSeparator : "，",
            committedText: index == count - 1 ? nil : "一"
        )
    }
}

@Test
func test_pinyinSegmentPolicyValidation() {
    let segments = fixtureSegments()

    #expect(
        PinyinSegmentPolicy.isValid(segments, activePinyin: "jutouwangshanshi")
    )
    #expect(!PinyinSegmentPolicy.isValid([], activePinyin: ""))
    #expect(
        PinyinSegmentPolicy.isValid(
            uniformSegments(count: 8),
            activePinyin: "a"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            uniformSegments(count: 9),
            activePinyin: "a"
        )
    )

    // Per-segment pinyin charset and letter bounds.
    #expect(
        !PinyinSegmentPolicy.isValid(
            [PinyinSegment(pinyin: "ming4", separator: "")],
            activePinyin: "ming4"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [PinyinSegment(pinyin: "", separator: "")],
            activePinyin: ""
        )
    )
    #expect(
        PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: String(repeating: "a", count: 64),
                    separator: ""
                ),
            ],
            activePinyin: String(repeating: "a", count: 64)
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: String(repeating: "a", count: 65),
                    separator: ""
                ),
            ],
            activePinyin: String(repeating: "a", count: 65)
        )
    )

    // Total letters across all segments.
    #expect(
        PinyinSegmentPolicy.isValid(
            uniformSegments(count: 4, letters: 64),
            activePinyin: String(repeating: "a", count: 64)
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            uniformSegments(count: 8, letters: 33),
            activePinyin: String(repeating: "a", count: 33)
        )
    )

    // Separators must be punctuation, bounded, and empty only on the
    // last segment.
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(pinyin: "ming", separator: "明"),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(pinyin: "ming", separator: "a"),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: "ming",
                    separator: String(repeating: "。", count: 3)
                ),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: "ming",
                    separator: String(repeating: "。", count: 2)
                ),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(pinyin: "ming", separator: "，"),
                PinyinSegment(pinyin: "ling", separator: "。"),
            ],
            activePinyin: "ling"
        )
    )

    // The active segment must echo the request pinyin exactly.
    #expect(
        !PinyinSegmentPolicy.isValid(segments, activePinyin: "chuangqian")
    )

    // committed_text bounds.
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: "ming",
                    separator: "，",
                    committedText: String(repeating: "字", count: 65)
                ),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: "ming",
                    separator: "，",
                    committedText: "明\n令"
                ),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        !PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: "ming",
                    separator: "，",
                    committedText: "明\u{0}令"
                ),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )
    #expect(
        PinyinSegmentPolicy.isValid(
            [
                PinyinSegment(
                    pinyin: "ming",
                    separator: "，",
                    committedText: String(repeating: "字", count: 64)
                ),
                PinyinSegment(pinyin: "ling", separator: ""),
            ],
            activePinyin: "ling"
        )
    )

    // Canonical JSON must match the Python mirror byte for byte
    // (json.dumps(..., sort_keys=True, ensure_ascii=False,
    // separators=(",", ":"))).
    #expect(
        PinyinSegmentPolicy.canonicalJSON(segments)
            == #"[{"committed_text":"床前明月光","pinyin":"chuangqianmingyueguang","separator":"，"},{"pinyin":"jutouwangshanshi","separator":""}]"#
    )
    #expect(PinyinSegmentPolicy.canonicalJSON([]) == nil)
    #expect(PinyinSegmentPolicy.canonicalJSON(uniformSegments(count: 9)) == nil)
}

@Test
func test_canonicalJSONMatchesPythonForSlashSeparator() {
    // Python: json.dumps(..., sort_keys=True, ensure_ascii=False,
    // separators=(",", ":")) leaves "/" unescaped while Swift's
    // JSONEncoder escapes it as "\/".
    let slashSegments = [
        PinyinSegment(
            pinyin: "chuangqianmingyueguang",
            separator: "/",
            committedText: "床前/明月\\光"
        ),
        PinyinSegment(pinyin: "jutouwangshanshi", separator: ""),
    ]
    #expect(
        PinyinSegmentPolicy.isValid(
            slashSegments,
            activePinyin: "jutouwangshanshi"
        )
    )
    #expect(
        PinyinSegmentPolicy.canonicalJSON(slashSegments)
            == #"[{"committed_text":"床前/明月\\光","pinyin":"chuangqianmingyueguang","separator":"/"},{"pinyin":"jutouwangshanshi","separator":""}]"#
    )
}

@Test
func test_segmentedInferenceRequestEncodesOptionalSegments() throws {
    var state = CompositionState(appSessionID: "app-1")
    let token = state.replaceInput(
        pinyin: "shijian",
        candidates: ["时间", "事件"]
    )

    let plain = SemanticInferenceRequest(
        requestID: "request-1",
        token: token,
        contextPolicy: .strict,
        context: "",
        pinyin: state.pinyin,
        candidates: state.mainCandidates,
        deadlineMilliseconds: 400,
        allowSentence: true
    )
    let plainObject = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(plain)
        ) as? [String: Any]
    )
    #expect(plainObject["segments"] == nil)

    let segmented = SemanticInferenceRequest(
        requestID: "request-2",
        token: token,
        contextPolicy: .strict,
        context: "",
        pinyin: state.pinyin,
        candidates: state.mainCandidates,
        deadlineMilliseconds: 400,
        allowSentence: true,
        segments: fixtureSegments(activePinyin: state.pinyin)
    )
    let segmentedObject = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(segmented)
        ) as? [String: Any]
    )
    let encodedSegments = try #require(
        segmentedObject["segments"] as? [[String: Any]]
    )
    #expect(encodedSegments.count == 2)
    #expect(encodedSegments[0]["pinyin"] as? String == "chuangqianmingyueguang")
    #expect(encodedSegments[0]["separator"] as? String == "，")
    #expect(encodedSegments[0]["committed_text"] as? String == "床前明月光")
    #expect(encodedSegments[1]["pinyin"] as? String == "shijian")
    #expect(encodedSegments[1]["separator"] as? String == "")
    #expect(encodedSegments[1]["committed_text"] == nil)
}

@Test
func test_inferenceRequestEncodesOptionalDomain() throws {
    var state = CompositionState(appSessionID: "app-1")
    let token = state.replaceInput(
        pinyin: "koujing",
        candidates: ["口径", "口经"]
    )

    // P2-4：旧客户端不发送 domain——键必须整个缺省（encodeIfPresent），
    // daemon 侧按缺省 None 处理，协议保持向后兼容。
    let plain = SemanticInferenceRequest(
        requestID: "request-d1",
        token: token,
        contextPolicy: .strict,
        context: "",
        pinyin: state.pinyin,
        candidates: state.mainCandidates,
        deadlineMilliseconds: 400,
        allowSentence: false
    )
    let plainObject = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(plain)
        ) as? [String: Any]
    )
    #expect(plainObject["domain"] == nil)

    let mapped = SemanticInferenceRequest(
        requestID: "request-d2",
        token: token,
        contextPolicy: .strict,
        context: "",
        pinyin: state.pinyin,
        candidates: state.mainCandidates,
        deadlineMilliseconds: 400,
        allowSentence: false,
        domain: "work"
    )
    let mappedObject = try #require(
        JSONSerialization.jsonObject(
            with: JSONEncoder().encode(mapped)
        ) as? [String: Any]
    )
    #expect(mappedObject["domain"] as? String == "work")
    #expect(mapped.domain == "work")
    #expect(plain.domain == nil)
}

private struct SegmentedSentenceFixture {
    let state: CompositionState
    let segments: [PinyinSegment]
    let sentence: String
}

private func segmentedSentenceFixture() -> SegmentedSentenceFixture {
    var state = CompositionState(appSessionID: "app-1")
    _ = state.replaceInput(
        pinyin: "jutouwangshanshi",
        candidates: ["举头望山石"]
    )
    let segments = [
        PinyinSegment(
            pinyin: String(repeating: "a", count: 15),
            separator: "，",
            committedText: "一二三四五六七八九十一二三四五"
        ),
        PinyinSegment(pinyin: String(repeating: "b", count: 15), separator: ""),
    ]
    let sentence =
        "一二三四五六七八九十一二三四五，二二二二二二二二二二二二二二二"
    return SegmentedSentenceFixture(
        state: state,
        segments: segments,
        sentence: sentence
    )
}

private func segmentedSentenceResult(
    _ suggestion: String,
    confidence: Double,
    token: CompositionToken
) -> SemanticInferenceResult {
    SemanticInferenceResult(
        status: "ok",
        requestID: "request-1",
        compositionID: token.compositionID.uuidString,
        revision: token.revision,
        appSessionID: token.appSessionID,
        rankedCandidate: "",
        sentenceSuggestion: suggestion,
        confidence: confidence,
        decision: .sentenceSuggestion
    )
}

@Test
func test_segmentedSentenceIsBoundedAsWholeText() {
    let fixture = segmentedSentenceFixture()
    let state = fixture.state
    let token = state.token
    // The single policy bounds the whole text (≤128 printable
    // characters), so a 31-character sentence validates with or
    // without the segment layout.
    #expect(fixture.sentence.count == 31)
    #expect(
        segmentedSentenceResult(
            fixture.sentence,
            confidence: 0.9,
            token: token
        ).isValid(for: token, candidates: state.mainCandidates)
    )
    #expect(
        segmentedSentenceResult(
            fixture.sentence,
            confidence: 0.9,
            token: token
        ).isValid(
            for: token,
            candidates: state.mainCandidates,
            segments: fixture.segments
        )
    )
}

@Test
func test_segmentedSentenceRequiresLayoutMatchAndConfidence() {
    let fixture = segmentedSentenceFixture()
    let state = fixture.state
    let token = state.token
    // The separator layout and confidence floor must match the contract.
    #expect(
        !segmentedSentenceResult(
            "一二三四五六七八九十一二三四五。二二二二二二二二二二二二二二二",
            confidence: 0.9,
            token: token
        ).isValid(
            for: token,
            candidates: state.mainCandidates,
            segments: fixture.segments
        )
    )
    #expect(
        !segmentedSentenceResult(
            fixture.sentence,
            confidence: 0.55,
            token: token
        ).isValid(
            for: token,
            candidates: state.mainCandidates,
            segments: fixture.segments
        )
    )
}

@Test
func daemonCannotInjectAClientOnlyMixedComposition() {
    let token = CompositionState(appSessionID: "app").token
    let result = SemanticInferenceResult(
        status: "ok",
        requestID: "request",
        compositionID: token.compositionID.uuidString,
        revision: token.revision,
        appSessionID: token.appSessionID,
        rankedCandidate: "",
        sentenceSuggestion: "这个API",
        confidence: 0.99,
        decision: .mixedComposition
    )

    #expect(!result.isValid(for: token, candidates: ["这个"]))
    #expect(result.candidatePresentation(characterSet: .simplified) == .failure)
}
