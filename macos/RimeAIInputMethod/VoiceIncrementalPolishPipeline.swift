import Foundation

/// 边说边润色（分句流水线）的纯状态与切分策略。
///
/// 在录音期间，ASR 每完成一段停顿提交，`stable` 文本会向前增长。本状态机把
/// 已经落定的完整句子前缀切出来，在后台提前发往云端润色；等用户结束录音拿
/// 到最终文本时，直接复用已润色前缀、只把尚未润色的尾部发出去（若已全覆盖
/// 则 0ms 直接出稿），大幅压缩长口述的收尾等待时间。
struct VoiceIncrementalPolishPipeline: Equatable {
    /// 单次增量润色块的最小字符数：太短的句子留在末尾一次处理，避免频繁小请求。
    static let minimumChunkCharacters = 24
    /// 单次增量润色块的上限字符数。
    static let maximumChunkCharacters = 400
    /// 增量块的云端超时上限（比最终整段更紧，避免拖慢后续分段）。
    static let incrementalDeadlineMilliseconds = 4_500

    private static let sentenceBoundaryCharacters: Set<Character> = [
        "。", "！", "？", "!", "?",
    ]

    enum FinalizationPlan: Equatable {
        /// 全部最终文本都已在录音期间润色完成：0ms 直接出稿。
        case completeImmediately(polishedText: String)
        /// 前缀已润色完成，只需对尾部做一次小请求。
        case polishTail(polishedPrefix: String, rawTail: String)
        /// 无可复用前缀（短句、ASR 修订了前文或增量尚未完成）：整段处理。
        case polishFull(rawText: String)
    }

    private(set) var style: VoicePolishStyle = .concise
    private(set) var completedSourcePrefix = ""
    private(set) var completedPolishedPrefix = ""
    private(set) var inFlightRequestID: String?
    private(set) var inFlightSourceChunk: String?
    private(set) var inFlightBasePrefix: String?

    mutating func reset(style: VoicePolishStyle = .concise) {
        self.style = style
        completedSourcePrefix = ""
        completedPolishedPrefix = ""
        inFlightRequestID = nil
        inFlightSourceChunk = nil
        inFlightBasePrefix = nil
    }

    /// 检查当前 `stableText` 是否新增了足够长的完整句子前缀可提前派发润色。
    /// 同一时刻至多 1 个在途增量请求，避免并发洪峰与乱序。
    mutating func nextChunkToDispatch(
        stableText: String,
        requestIDGenerator: () -> String = { "voice-inc-\(UUID().uuidString)" }
    ) -> (requestID: String, chunk: String)? {
        guard inFlightRequestID == nil else {
            return nil
        }
        let normalized = stableText
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.hasPrefix(completedSourcePrefix)
        else {
            return nil
        }
        let remaining = String(normalized.dropFirst(completedSourcePrefix.count))
        guard let candidate = extractDispatchableChunk(from: remaining) else {
            return nil
        }
        let requestID = requestIDGenerator()
        inFlightRequestID = requestID
        inFlightSourceChunk = candidate
        inFlightBasePrefix = completedSourcePrefix
        return (requestID: requestID, chunk: candidate)
    }

    /// 增量润色成功返回：校验代际、前缀一致与截断守卫后并入缓存前缀。
    @discardableResult
    mutating func completeInFlight(
        requestID: String,
        polishedChunk: String
    ) -> Bool {
        guard inFlightRequestID == requestID,
              let sourceChunk = inFlightSourceChunk,
              let basePrefix = inFlightBasePrefix
        else {
            return false
        }
        clearInFlight()
        guard basePrefix == completedSourcePrefix else {
            return false
        }
        let trimmed = polishedChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !VoiceCloudPolishTruncationGuard.looksTruncated(
                  input: sourceChunk,
                  output: trimmed
              )
        else {
            return false
        }
        completedSourcePrefix += sourceChunk
        completedPolishedPrefix = Self.joinPolished(
            completedPolishedPrefix,
            trimmed,
            style: style
        )
        return true
    }

    mutating func failInFlight(requestID: String) {
        guard inFlightRequestID == requestID else {
            return
        }
        clearInFlight()
    }

    mutating func cancelInFlight() -> String? {
        let active = inFlightRequestID
        clearInFlight()
        return active
    }

    /// 录音结束后，根据最终文本与已缓存前缀生成最优收尾计划。
    func planForFinal(_ finalRawText: String) -> FinalizationPlan {
        let normalized = finalRawText
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !completedSourcePrefix.isEmpty,
              !completedPolishedPrefix.isEmpty,
              normalized.hasPrefix(completedSourcePrefix)
        else {
            return .polishFull(rawText: normalized)
        }
        let rawTail = String(normalized.dropFirst(completedSourcePrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTail.isEmpty {
            return .completeImmediately(polishedText: completedPolishedPrefix)
        }
        return .polishTail(
            polishedPrefix: completedPolishedPrefix,
            rawTail: rawTail
        )
    }

    /// 把已润色的前缀和后缀干净地拼接在一起。
    static func joinPolished(
        _ prefix: String,
        _ suffix: String,
        style: VoicePolishStyle
    ) -> String {
        let left = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }

        if style == .structured, shouldBreakLine(between: left, and: right) {
            return left + "\n" + right
        }
        if needsAsciiSpace(between: left, and: right) {
            return left + " " + right
        }
        return left + right
    }

    // MARK: - Helpers

    private mutating func clearInFlight() {
        inFlightRequestID = nil
        inFlightSourceChunk = nil
        inFlightBasePrefix = nil
    }

    private func extractDispatchableChunk(from remaining: String) -> String? {
        guard remaining.count >= Self.minimumChunkCharacters else {
            return nil
        }
        let bounded = remaining.count > Self.maximumChunkCharacters
            ? String(remaining.prefix(Self.maximumChunkCharacters))
            : remaining
        // 找到最后一个完整句末标点位置，避免把半句话拆开润色。
        guard let lastBoundary = bounded.lastIndex(where: {
            Self.sentenceBoundaryCharacters.contains($0)
        }) else {
            return nil
        }
        let endIndex = bounded.index(after: lastBoundary)
        let candidate = String(bounded[..<endIndex])
        guard candidate.trimmingCharacters(in: .whitespacesAndNewlines).count
            >= Self.minimumChunkCharacters
        else {
            return nil
        }
        return candidate
    }

    private static func shouldBreakLine(
        between left: String,
        and right: String
    ) -> Bool {
        guard let lastChar = left.last,
              sentenceBoundaryCharacters.contains(lastChar)
        else {
            return false
        }
        if right.hasPrefix("第") || right.hasPrefix("- ") || right.hasPrefix("• ") {
            return true
        }
        if let first = right.first, first.isNumber,
           right.dropFirst().first == "." || right.dropFirst().first == "、"
        {
            return true
        }
        return false
    }

    private static func needsAsciiSpace(
        between left: String,
        and right: String
    ) -> Bool {
        guard let last = left.last, let first = right.first else {
            return false
        }
        let leftIsAsciiWord = last.isASCII && (last.isLetter || last.isNumber || ".,!?;:".contains(last))
        let rightIsAsciiWord = first.isASCII && (first.isLetter || first.isNumber)
        return leftIsAsciiWord && rightIsAsciiWord
    }
}
