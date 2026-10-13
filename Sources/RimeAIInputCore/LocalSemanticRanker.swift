import Foundation

public struct LocalSemanticRanking: Equatable, Sendable {
    public let rankedCandidates: [String]
    public let confidence: Double
}

public struct LocalSemanticEvaluation: Equatable, Sendable {
    public let decision: SemanticInferenceDecision
    public let candidate: String?
    public let confidence: Double

    public var candidatePresentation: SemanticCandidatePresentation {
        switch decision {
        case .rankedCandidate, .sentenceSuggestion, .mixedComposition:
            guard let candidate else {
                return .failure
            }
            return .candidate(
                text: candidate,
                decision: decision,
                confidence: confidence
            )
        case .phraseBook:
            // Client-side-only decision: the local ranker never emits it.
            return .failure
        case .sameTopCandidate:
            return .sameTopCandidate
        case .insufficientCandidates:
            return .insufficientCandidates
        case .belowConfidence:
            return .belowConfidence
        case .noCandidate:
            return .noCandidate
        case .sentenceTooLong:
            return .sentenceTooLong
        case .sentenceIncomplete:
            return .sentenceIncomplete
        }
    }
}

public enum LocalSemanticRankerError: Error, LocalizedError, Sendable {
    case invalidArtifact(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidArtifact(message):
            return "本地语义模型制品无效：\(message)"
        }
    }
}

public struct LocalSemanticRanker: Sendable {
    private static let orders = [2, 3, 4, 5]
    private static let candidateFrequencyTable = 0
    private static let ngramTableOffset = 0
    private static let prefixTableOffset = 10

    private let rankWeight: Double
    private let frequencyWeight: Double
    private let languageWeight: Double
    private let backoffAlpha: Double
    private let maximumContextCharacters: Int
    private let topCandidateCount: Int
    private let storage: CountStorage

    public let artifactID: String

    public init(contentsOf url: URL) throws {
        let compact = try CompactCountStorage(contentsOf: url)
        rankWeight = compact.rankWeight
        frequencyWeight = compact.frequencyWeight
        languageWeight = compact.languageWeight
        backoffAlpha = compact.backoffAlpha
        maximumContextCharacters = compact.maximumContextCharacters
        topCandidateCount = compact.topCandidateCount
        artifactID = compact.artifactID
        storage = .compact(compact)
    }

    public init(
        rankWeight: Double,
        frequencyWeight: Double,
        languageWeight: Double,
        candidateFrequencies: [String: Int],
        ngramCounts: [Int: [String: Int]],
        prefixCounts: [Int: [String: Int]],
        maximumContextCharacters: Int = 40,
        topCandidateCount: Int = 10,
        backoffAlpha: Double = 0.4
    ) {
        self.rankWeight = rankWeight
        self.frequencyWeight = frequencyWeight
        self.languageWeight = languageWeight
        self.backoffAlpha = backoffAlpha
        self.maximumContextCharacters = maximumContextCharacters
        self.topCandidateCount = topCandidateCount
        artifactID = "in-memory-test-model"
        storage = .memory(
            MemoryCountStorage(
                candidateFrequencies: candidateFrequencies,
                ngramCounts: ngramCounts,
                prefixCounts: prefixCounts
            )
        )
    }

    public func evaluate(
        context: String,
        candidates: [String],
        minimumConfidence: Double = 0.55
    ) -> LocalSemanticEvaluation {
        let ranking = rank(context: context, candidates: candidates)
        guard let first = ranking.rankedCandidates.first,
              let baseline = candidates.first
        else {
            return LocalSemanticEvaluation(
                decision: .noCandidate,
                candidate: nil,
                confidence: ranking.confidence
            )
        }
        let comparisonTarget = comparisonLength(baseline)
        let comparableCount = candidates.prefix(topCandidateCount).reduce(0) {
            $0 + (comparisonLength($1) == comparisonTarget ? 1 : 0)
        }
        if comparableCount < 2 {
            return LocalSemanticEvaluation(
                decision: .insufficientCandidates,
                candidate: nil,
                confidence: 0
            )
        }
        if first == baseline {
            return LocalSemanticEvaluation(
                decision: .sameTopCandidate,
                candidate: nil,
                confidence: ranking.confidence
            )
        }
        if ranking.confidence < minimumConfidence {
            return LocalSemanticEvaluation(
                decision: .belowConfidence,
                candidate: nil,
                confidence: ranking.confidence
            )
        }
        return LocalSemanticEvaluation(
            decision: .rankedCandidate,
            candidate: first,
            confidence: ranking.confidence
        )
    }

    public func rank(
        context: String,
        candidates: [String]
    ) -> LocalSemanticRanking {
        let semanticWindow = Array(candidates.prefix(topCandidateCount))
        guard let targetLength = semanticWindow.first.map(comparisonLength)
        else {
            return LocalSemanticRanking(
                rankedCandidates: [],
                confidence: 0
            )
        }
        let indexed = semanticWindow.enumerated().map {
            (index: $0.offset, text: $0.element)
        }
        let eligible = indexed.filter {
            comparisonLength($0.text) == targetLength
        }
        let preserved = indexed.filter {
            comparisonLength($0.text) != targetLength
        }
        let scored = eligible.map { candidate in
            (
                score: candidateScore(
                    context: context,
                    candidate: candidate.text,
                    baselineIndex: candidate.index
                ),
                index: candidate.index,
                text: candidate.text
            )
        }.sorted { left, right in
            if left.score == right.score {
                return left.index < right.index
            }
            return left.score > right.score
        }
        var ranked = scored.map(\.text)
        ranked.append(contentsOf: preserved.map(\.text))
        ranked.append(contentsOf: candidates.dropFirst(topCandidateCount))

        let confidence: Double
        if scored.count < 2 {
            confidence = scored.isEmpty ? 0 : 1
        } else {
            let margin = max(-30, min(30, scored[0].score - scored[1].score))
            confidence = 1 / (1 + Foundation.exp(-margin))
        }
        return LocalSemanticRanking(
            rankedCandidates: ranked,
            confidence: confidence
        )
    }

    private func candidateScore(
        context: String,
        candidate: String,
        baselineIndex: Int
    ) -> Double {
        -rankWeight * Double(baselineIndex)
            + frequencyWeight * Foundation.log1p(
                Double(
                    value(
                        table: Self.candidateFrequencyTable,
                        key: candidate
                    )
                )
            )
            + languageWeight * languageScore(
                context: context,
                candidate: candidate
            )
    }

    private func languageScore(context: String, candidate: String) -> Double {
        let boundedContext = String(context.suffix(maximumContextCharacters))
        let characters = Array("^" + boundedContext + candidate)
        let candidateStart = characters.count - candidate.count
        var total = 0.0
        var terms = 0
        for position in candidateStart ..< characters.count {
            var backedOff: Double?
            for order in Self.orders.reversed() {
                let start = position - order + 1
                guard start >= 0 else {
                    continue
                }
                let gram = String(characters[start ... position])
                let prefix = String(gram.dropLast())
                let count = value(
                    table: Self.ngramTableOffset + order,
                    key: gram
                )
                let prefixCount = value(
                    table: Self.prefixTableOffset + order,
                    key: prefix
                )
                if count > 0 && prefixCount > 0 {
                    backedOff = (Double(count) / Double(prefixCount))
                        * pow(backoffAlpha, Double(5 - order))
                    break
                }
            }
            let gram = String(characters[position - 1 ... position])
            let count = value(table: Self.ngramTableOffset + 2, key: gram)
            let prefixCount = value(
                table: Self.prefixTableOffset + 2,
                key: String(gram.dropLast())
            )
            let probability = backedOff
                ?? ((Double(count) + 0.1) / (Double(prefixCount) + 1_000))
                    * pow(backoffAlpha, 3)
            total += Foundation.log(probability)
            terms += 1
        }
        return total / Double(max(1, terms))
    }

    private func value(table: Int, key: String) -> Int {
        switch storage {
        case let .memory(memory):
            return memory.value(table: table, key: key)
        case let .compact(compact):
            return compact.value(table: table, key: key)
        }
    }

    private func comparisonLength(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                count += 1
            }
        }
    }
}

private enum CountStorage: Sendable {
    case memory(MemoryCountStorage)
    case compact(CompactCountStorage)
}

private struct MemoryCountStorage: Sendable {
    let candidateFrequencies: [String: Int]
    let ngramCounts: [Int: [String: Int]]
    let prefixCounts: [Int: [String: Int]]

    func value(table: Int, key: String) -> Int {
        if table == 0 {
            return candidateFrequencies[key, default: 0]
        }
        if table >= 10 {
            return prefixCounts[table - 10]?[key] ?? 0
        }
        return ngramCounts[table]?[key] ?? 0
    }
}

private struct CompactCountStorage: Sendable {
    private static let magic = Array("RAINGRM2".utf8)
    private static let headerSize = 184
    private static let directoryEntrySize = 24
    private static let recordSize = 12
    private static let requiredTables: Set<Int> = [
        0, 2, 3, 4, 5, 12, 13, 14, 15,
    ]

    struct Table: Sendable {
        let offset: Int
        let count: Int
    }

    let data: Data
    let tables: [Int: Table]
    let rankWeight: Double
    let frequencyWeight: Double
    let languageWeight: Double
    let backoffAlpha: Double
    let maximumContextCharacters: Int
    let topCandidateCount: Int
    let artifactID: String

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= Self.headerSize,
              Array(data.prefix(Self.magic.count)) == Self.magic,
              data.readUInt32LE(at: 8) == 2
        else {
            throw LocalSemanticRankerError.invalidArtifact(
                "头部或版本不兼容；请 retrain 并重新导出 schema v2 工件"
            )
        }
        let tableCount = Int(data.readUInt32LE(at: 12))
        guard tableCount == Self.requiredTables.count else {
            throw LocalSemanticRankerError.invalidArtifact("索引表数量不完整")
        }
        let directoryEnd = Self.headerSize
            + tableCount * Self.directoryEntrySize
        guard directoryEnd <= data.count else {
            throw LocalSemanticRankerError.invalidArtifact("索引目录越界")
        }
        var parsedTables: [Int: Table] = [:]
        for index in 0 ..< tableCount {
            let entry = Self.headerSize + index * Self.directoryEntrySize
            let identifier = Int(data.readUInt32LE(at: entry))
            let offset = Int(data.readUInt64LE(at: entry + 8))
            let count = Int(data.readUInt64LE(at: entry + 16))
            guard Self.requiredTables.contains(identifier),
                  parsedTables[identifier] == nil,
                  offset >= directoryEnd,
                  count >= 0,
                  offset <= data.count,
                  count <= (data.count - offset) / Self.recordSize
            else {
                throw LocalSemanticRankerError.invalidArtifact("索引表越界")
            }
            parsedTables[identifier] = Table(offset: offset, count: count)
        }
        guard Set(parsedTables.keys) == Self.requiredTables else {
            throw LocalSemanticRankerError.invalidArtifact("缺少必要索引表")
        }
        guard let datasetHash = String(
            bytes: data[56 ..< 120],
            encoding: .ascii
        ),
        let sourceHash = String(
            bytes: data[120 ..< 184],
            encoding: .ascii
        ),
        datasetHash.count == 64,
        sourceHash.count == 64
        else {
            throw LocalSemanticRankerError.invalidArtifact("来源校验值无效")
        }
        self.data = data
        tables = parsedTables
        rankWeight = data.readDoubleLE(at: 16)
        frequencyWeight = data.readDoubleLE(at: 24)
        languageWeight = data.readDoubleLE(at: 32)
        backoffAlpha = data.readDoubleLE(at: 40)
        maximumContextCharacters = Int(data.readUInt32LE(at: 48))
        topCandidateCount = Int(data.readUInt32LE(at: 52))
        artifactID = "p0-char-ngram:\(sourceHash.prefix(12)):"
            + "dataset-\(datasetHash.prefix(12))"
        guard rankWeight.isFinite,
              frequencyWeight.isFinite,
              languageWeight.isFinite,
              backoffAlpha.isFinite,
              backoffAlpha > 0,
              backoffAlpha <= 1,
              (1 ... 400).contains(maximumContextCharacters),
              (1 ... 10).contains(topCandidateCount)
        else {
            throw LocalSemanticRankerError.invalidArtifact("超参数无效")
        }
    }

    func value(table identifier: Int, key: String) -> Int {
        guard let table = tables[identifier] else {
            return 0
        }
        let target = fnv1a64(key.utf8)
        var lower = 0
        var upper = table.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let offset = table.offset + middle * Self.recordSize
            let candidate = data.readUInt64LE(at: offset)
            if candidate < target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < table.count else {
            return 0
        }
        let offset = table.offset + lower * Self.recordSize
        guard data.readUInt64LE(at: offset) == target else {
            return 0
        }
        return Int(data.readUInt32LE(at: offset + 8))
    }
}

private func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return hash
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        UInt64(readUInt32LE(at: offset))
            | UInt64(readUInt32LE(at: offset + 4)) << 32
    }

    func readDoubleLE(at offset: Int) -> Double {
        Double(bitPattern: readUInt64LE(at: offset))
    }
}
