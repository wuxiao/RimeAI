// Cloud generated-sentence policy: structural validation shared by the
// cloud transport (macOS main line) and the daemon result contract
// (DaemonProtocol, iOS keyboard subset). Same module, split into its own
// file so both target subsets compile it.

public enum CloudGeneratedSentencePolicy {
    public static let maximumCharacterCount = 128
    public static let minimumConfidence = 0.60

    /// Single-segment variant (no cross-punctuation layout): structural
    /// bounds only, mixed Chinese/English text allowed.
    public static func allows(
        text: String,
        confidence: Double
    ) -> Bool {
        !text.isEmpty
            && text.count <= maximumCharacterCount
            && text.unicodeScalars.allSatisfy { scalar in
                scalar.value > 0x20 && scalar.value != 0x7F
            }
            && confidence.isFinite
            && confidence >= minimumConfidence
    }

    /// Cross-punctuation variant: the text is split by the requested
    /// separators in order and each part must be non-empty (a dropped
    /// or misplaced separator breaks the layout); the whole text is
    /// then bounded by the single-segment structural rules. Each part
    /// is not required to be pure Han or to fit its segment's pinyin
    /// letter count.
    /// 按段拆分整句建议（KBD-007 按段接受的基础）：依据各段分隔
    /// 符按序切割，返回与段一一对应的文本切片；分隔符缺失或任何
    /// 切片为空时返回 nil。与 `allows(text:pinyinSegments:confidence:)`
    /// 的结构校验同口径。
    public static func segmentTexts(
        text: String,
        pinyinSegments: [PinyinSegment]
    ) -> [String]? {
        guard let lastSegment = pinyinSegments.last,
              PinyinSegmentPolicy.isValid(
                  pinyinSegments,
                  activePinyin: lastSegment.pinyin
              )
        else {
            return nil
        }
        var remainder = Substring(text)
        var parts: [String] = []
        for segment in pinyinSegments.dropLast() {
            guard let separatorRange = remainder.range(of: segment.separator)
            else {
                return nil
            }
            parts.append(String(remainder[..<separatorRange.lowerBound]))
            remainder = remainder[separatorRange.upperBound...]
        }
        parts.append(String(remainder))
        guard parts.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return parts
    }

    public static func allows(
        text: String,
        pinyinSegments: [PinyinSegment],
        confidence: Double
    ) -> Bool {
        guard confidence.isFinite,
              confidence >= minimumConfidence,
              segmentTexts(text: text, pinyinSegments: pinyinSegments) != nil
        else {
            return false
        }
        return allows(text: text, confidence: confidence)
    }
}
