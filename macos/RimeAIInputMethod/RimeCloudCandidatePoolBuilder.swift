import Foundation

final class CloudCandidateBuildCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

enum RimeCloudCandidatePoolBuilder {
    static func build(
        for pinyin: String,
        cancellation: CloudCandidateBuildCancellation
    ) -> CloudCandidatePool {
        guard !cancellation.isCancelled else {
            return CloudCandidatePool(candidates: [], hash: "")
        }
        let exact = RimeEngine.shared.candidates(
            for: pinyin,
            limit: 30
        )
        guard !cancellation.isCancelled else {
            return CloudCandidatePool(candidates: [], hash: "")
        }
        let fuzzyGroups = TypoVariantGenerator.variants(
            for: pinyin,
            maximumCount: 12
        ).prefix { _ in !cancellation.isCancelled }
        .compactMap { variant -> CloudFuzzyCandidateGroup? in
            guard !cancellation.isCancelled else {
                return nil
            }
            let candidates = RimeEngine.shared.candidates(
                for: variant.pinyin,
                limit: 4
            )
            guard !candidates.isEmpty else {
                return nil
            }
            return CloudFuzzyCandidateGroup(
                variant: variant,
                candidateTexts: candidates
            )
        }
        return CloudCandidatePoolAssembler.assemble(
            pinyin: pinyin,
            exactCandidateTexts: exact,
            fuzzyGroups: fuzzyGroups,
            maximumCount: 50
        )
    }
}
