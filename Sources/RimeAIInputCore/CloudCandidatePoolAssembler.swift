import CryptoKit
import Foundation

public struct CloudFuzzyCandidateGroup: Equatable, Sendable {
    public let variant: TypoVariant
    public let candidateTexts: [String]

    public init(variant: TypoVariant, candidateTexts: [String]) {
        self.variant = variant
        self.candidateTexts = candidateTexts
    }
}

public struct CloudCandidatePool: Equatable, Sendable {
    public let candidates: [CloudCandidate]
    public let hash: String

    public init(candidates: [CloudCandidate], hash: String) {
        self.candidates = candidates
        self.hash = hash
    }
}

public enum CloudCandidatePoolAssembler {
    public static func assemble(
        pinyin: String,
        exactCandidateTexts: [String],
        fuzzyGroups: [CloudFuzzyCandidateGroup],
        maximumCount: Int = 50
    ) -> CloudCandidatePool {
        let limit = min(max(maximumCount, 1), 50)
        var seenTexts = Set<String>()
        var values: [CloudCandidate] = []

        for (index, text) in exactCandidateTexts.prefix(30).enumerated() {
            append(
                text: text,
                source: .rimeExact,
                rimeIndex: index,
                originalPinyin: pinyin,
                alignedPinyin: pinyin,
                editCost: 0,
                to: &values,
                seenTexts: &seenTexts,
                limit: limit
            )
        }
        for group in fuzzyGroups {
            for (index, text) in group.candidateTexts.prefix(4).enumerated() {
                append(
                    text: text,
                    source: .rimeFuzzy,
                    rimeIndex: index,
                    originalPinyin: pinyin,
                    alignedPinyin: group.variant.pinyin,
                    editCost: group.variant.editCost,
                    to: &values,
                    seenTexts: &seenTexts,
                    limit: limit
                )
            }
            if values.count >= limit {
                break
            }
        }
        let poolHash = digest(
            values.map(\.id).joined(separator: "\u{001f}")
        )
        return CloudCandidatePool(candidates: values, hash: poolHash)
    }

    private static func append(
        text: String,
        source: CloudCandidateSource,
        rimeIndex: Int,
        originalPinyin: String,
        alignedPinyin: String,
        editCost: Double,
        to values: inout [CloudCandidate],
        seenTexts: inout Set<String>,
        limit: Int
    ) {
        guard values.count < limit,
              !text.isEmpty,
              seenTexts.insert(text).inserted
        else {
            return
        }
        let identity = [
            source.rawValue,
            alignedPinyin,
            String(rimeIndex),
            text,
        ].joined(separator: "\u{001f}")
        let candidate = CloudCandidate(
            id: "candidate-\(digest(identity).prefix(32))",
            text: text,
            source: source,
            rimeIndex: rimeIndex,
            consumedLength: originalPinyin.count,
            alignedPinyin: alignedPinyin,
            editCost: editCost
        )
        guard candidate.isValid(for: originalPinyin) else {
            seenTexts.remove(text)
            return
        }
        values.append(candidate)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
