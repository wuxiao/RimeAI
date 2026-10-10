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
        cancellation: CloudCandidateBuildCancellation,
        characterSet: RimeAICharacterSetPreference = .simplified
    ) -> CloudCandidatePool {
        guard !cancellation.isCancelled else {
            return CloudCandidatePool(candidates: [], hash: "")
        }
        // Rime 会话选项是异步应用的：查询可能取到尚未按用户字形设置
        // 简化/繁化的候选。进池前就地转换到用户字形，防止繁体候选经
        // 云端回传上屏，同时不损失候选。
        let exact = RimeEngine.shared.candidates(
            for: pinyin,
            limit: 30
        ).compactMap {
            SemanticCandidateScriptPolicy.sanitized(
                text: $0,
                characterSet: characterSet
            )
        }
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
            ).compactMap {
                SemanticCandidateScriptPolicy.sanitized(
                    text: $0,
                    characterSet: characterSet
                )
            }
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
