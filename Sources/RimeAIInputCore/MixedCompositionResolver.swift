import Foundation

public enum MixedCompositionSegmentKind: String, Equatable, Sendable {
    case pinyin
    case ascii
}

public struct MixedCompositionSegment: Equatable, Sendable {
    public let kind: MixedCompositionSegmentKind
    public let rawText: String
    public let renderedText: String

    public init(
        kind: MixedCompositionSegmentKind,
        rawText: String,
        renderedText: String
    ) {
        self.kind = kind
        self.rawText = rawText
        self.renderedText = renderedText
    }
}

public struct MixedCompositionSuggestion: Equatable, Sendable {
    public let text: String
    public let segments: [MixedCompositionSegment]
    public let confidence: Double

    public init(
        text: String,
        segments: [MixedCompositionSegment],
        confidence: Double
    ) {
        self.text = text
        self.segments = segments
        self.confidence = confidence
    }
}

/// Builds a selectable mixed Chinese/English suggestion from one continuous
/// key stream. Space is deliberately absent from this model because the input
/// method reserves it for committing the current composition.
public struct MixedCompositionResolver: Sendable {
    public static let defaultEnglishTokens: Set<String> = [
        "api", "app", "backend", "branch", "browser", "bug", "build",
        "cache", "client", "cloud", "code", "config", "cpu", "css",
        "debug", "docker", "endpoint", "frontend", "git", "github",
        "gitlab", "golang", "gpu", "html", "http", "https", "ios",
        "ipad", "iphone", "java", "javascript", "json", "kotlin",
        "kubernetes", "linux", "llm", "mac", "macos", "merge", "model",
        "mysql", "node", "npm", "postgres", "prompt", "python", "react",
        "redis", "release", "request", "response", "rust", "server",
        "sqlite", "swift", "timeout", "token", "typescript", "ubuntu",
        "vue", "web", "xcode", "xml", "yaml",
    ]

    private let builtinEnglishTokens: Set<String>
    private let maximumOccurrences: Int
    private let maximumSearchNodes: Int
    private let maximumCandidateLookups: Int

    public init(
        builtinEnglishTokens: Set<String> = Self.defaultEnglishTokens,
        maximumOccurrences: Int = 64,
        maximumSearchNodes: Int = 512,
        maximumCandidateLookups: Int = 64
    ) {
        self.builtinEnglishTokens = Self.normalizedTokens(
            builtinEnglishTokens,
            minimumLength: 3
        )
        self.maximumOccurrences = max(1, maximumOccurrences)
        self.maximumSearchNodes = max(1, maximumSearchNodes)
        self.maximumCandidateLookups = max(1, maximumCandidateLookups)
    }

    public func resolve(
        rawInput: String,
        personalizedEnglishTokens: Set<String> = [],
        candidateLookup: (_ pinyin: String, _ limit: Int) -> [String]
    ) -> MixedCompositionSuggestion? {
        let characters = Array(rawInput)
        guard characters.count >= 3,
              characters.count <= 256,
              characters.allSatisfy(Self.isCompositionCharacter)
        else {
            return nil
        }

        let normalizedInput = rawInput.lowercased()
        let lowercaseCharacters = Array(normalizedInput)
        guard lowercaseCharacters.count == characters.count else {
            return nil
        }
        let hardOccurrences = Self.uppercaseOccurrences(in: characters)
        // An all-lowercase stream that is itself a complete pinyin sequence
        // belongs to the ordinary Rime/semantic path. Without this guard, a
        // learned word such as `men` could turn `women` into `我men`.
        if hardOccurrences.isEmpty,
           Self.isLikelyPinyinSequence(normalizedInput)
        {
            return nil
        }
        let personalized = Self.normalizedTokens(
            personalizedEnglishTokens,
            minimumLength: 3,
            rejectingPinyinSequences: true
        )
        guard hardOccurrences.count <= maximumOccurrences else {
            return nil
        }
        var optionalOccurrences = Self.dictionaryOccurrences(
            in: characters,
            lowercaseCharacters: lowercaseCharacters,
            hardOccurrences: hardOccurrences,
            personalizedTokens: personalized,
            builtinTokens: builtinEnglishTokens
        )
        optionalOccurrences = Array(
            Set(optionalOccurrences)
        ).sorted(by: Self.sortOccurrences)
        let optionalLimit = maximumOccurrences - hardOccurrences.count
        if optionalOccurrences.count > optionalLimit {
            optionalOccurrences = Array(
                optionalOccurrences.prefix(optionalLimit)
            )
        }
        let occurrences = (hardOccurrences + optionalOccurrences)
            .sorted(by: Self.sortOccurrences)
        guard !occurrences.isEmpty else {
            return nil
        }

        var lookupCache: [String: String] = [:]
        var failedLookups = Set<String>()
        var candidateLookupCount = 0
        var best: ScoredSuggestion?
        var searchedNodes = 0

        func renderedPinyin(
            from start: Int,
            to end: Int
        ) -> MixedCompositionSegment? {
            guard start < end else {
                return nil
            }
            guard !Self.overlapsRequiredOccurrence(
                start: start,
                end: end,
                occurrences: hardOccurrences
            ) else {
                return nil
            }
            let raw = String(characters[start ..< end])
            let pinyin = raw.lowercased()
            if let cached = lookupCache[pinyin] {
                return MixedCompositionSegment(
                    kind: .pinyin,
                    rawText: raw,
                    renderedText: cached
                )
            }
            guard !failedLookups.contains(pinyin),
                  candidateLookupCount < maximumCandidateLookups
            else {
                return nil
            }
            candidateLookupCount += 1
            let rendered = candidateLookup(pinyin, 3).first(
                where: Self.isChineseCandidate
            )
            guard let rendered else {
                failedLookups.insert(pinyin)
                return nil
            }
            lookupCache[pinyin] = rendered
            return MixedCompositionSegment(
                kind: .pinyin,
                rawText: raw,
                renderedText: rendered
            )
        }

        func consider(
            segments: [MixedCompositionSegment],
            score: Int,
            confidence: Double
        ) {
            guard segments.contains(where: { $0.kind == .pinyin }),
                  segments.contains(where: { $0.kind == .ascii })
            else {
                return
            }
            let suggestion = MixedCompositionSuggestion(
                text: segments.map(\.renderedText).joined(),
                segments: segments,
                confidence: confidence
            )
            let scored = ScoredSuggestion(
                suggestion: suggestion,
                score: score,
                asciiCharacterCount: segments
                    .filter { $0.kind == .ascii }
                    .reduce(0) { $0 + $1.rawText.count }
            )
            if let current = best {
                if Self.isPreferred(scored, over: current) {
                    best = scored
                }
            } else {
                best = scored
            }
        }

        func search(
            cursor: Int,
            segments: [MixedCompositionSegment],
            score: Int,
            confidence: Double
        ) {
            guard searchedNodes < maximumSearchNodes else {
                return
            }
            searchedNodes += 1

            if !Self.overlapsRequiredOccurrence(
                start: cursor,
                end: characters.count,
                occurrences: hardOccurrences
            ) {
                var completed = segments
                if cursor < characters.count {
                    if let tail = renderedPinyin(
                        from: cursor,
                        to: characters.count
                    ) {
                        completed.append(tail)
                        consider(
                            segments: completed,
                            score: score,
                            confidence: confidence
                        )
                    }
                } else {
                    consider(
                        segments: completed,
                        score: score,
                        confidence: confidence
                    )
                }
            }

            for occurrence in occurrences where occurrence.start >= cursor {
                guard !Self.overlapsRequiredOccurrence(
                    start: cursor,
                    end: occurrence.start,
                    occurrences: hardOccurrences
                ) else {
                    continue
                }
                var updatedSegments = segments
                if cursor < occurrence.start {
                    guard let pinyin = renderedPinyin(
                        from: cursor,
                        to: occurrence.start
                    ) else {
                        continue
                    }
                    updatedSegments.append(pinyin)
                }
                let raw = String(
                    characters[occurrence.start ..< occurrence.end]
                )
                updatedSegments.append(
                    MixedCompositionSegment(
                        kind: .ascii,
                        rawText: raw,
                        renderedText: raw
                    )
                )
                search(
                    cursor: occurrence.end,
                    segments: updatedSegments,
                    score: score + occurrence.score,
                    confidence: max(confidence, occurrence.confidence)
                )
            }
        }

        search(cursor: 0, segments: [], score: 0, confidence: 0)
        return best?.suggestion
    }

    /// Extracts only normalized ASCII tokens. Callers may derive these from a
    /// bounded recent-history snapshot without retaining any surrounding text.
    public static func personalizedEnglishTokens(
        from text: String
    ) -> Set<String> {
        var result = Set<String>()
        var current = ""

        func flush() {
            guard (3 ... 32).contains(current.count) else {
                current = ""
                return
            }
            let normalized = current.lowercased()
            guard !isLikelyPinyinSequence(normalized)
                    || defaultEnglishTokens.contains(normalized)
            else {
                current = ""
                return
            }
            result.insert(normalized)
            current = ""
        }

        for character in text {
            if isASCIILetter(character) {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return result
    }
}

private extension MixedCompositionResolver {
    enum OccurrenceSource: Int, Hashable {
        case builtin
        case personalized
        case uppercase
    }

    struct EnglishOccurrence: Hashable {
        let start: Int
        let end: Int
        let source: OccurrenceSource

        var score: Int {
            let sourceScore = switch source {
            case .builtin: 200
            case .personalized: 400
            case .uppercase: 1_000
            }
            return sourceScore + (end - start) * 10
        }

        var confidence: Double {
            switch source {
            case .builtin: 0.82
            case .personalized: 0.90
            case .uppercase: 0.98
            }
        }
    }

    struct ScoredSuggestion {
        let suggestion: MixedCompositionSuggestion
        let score: Int
        let asciiCharacterCount: Int
    }

    static func normalizedTokens(
        _ tokens: Set<String>,
        minimumLength: Int,
        rejectingPinyinSequences: Bool = false
    ) -> Set<String> {
        Set(tokens.compactMap { token in
            let normalized = token.lowercased()
            guard (minimumLength ... 32).contains(normalized.count),
                  normalized.allSatisfy(isASCIILetter),
                  !rejectingPinyinSequences
                    || !isLikelyPinyinSequence(normalized)
            else {
                return nil
            }
            return normalized
        })
    }

    static func isLikelyPinyinSequence(_ value: String) -> Bool {
        let characters = Array(value)
        guard !characters.isEmpty,
              characters.allSatisfy(isASCIILetter)
        else {
            return false
        }
        var reachable = Array(
            repeating: false,
            count: characters.count + 1
        )
        reachable[0] = true
        for start in characters.indices where reachable[start] {
            let maximumEnd = min(characters.count, start + 6)
            for end in (start + 1) ... maximumEnd {
                let syllable = String(characters[start ..< end])
                if pinyinSyllables.contains(syllable) {
                    reachable[end] = true
                }
            }
        }
        return reachable[characters.count]
    }

    // Frozen from the checked-in luna_pinyin dictionary. The curated builtin
    // English lexicon is kept intact, while entirely-pinyin raw streams and
    // learned/history tokens are filtered through this set.
    static let pinyinSyllables = Set(
        """
        a ai an ang ao ba bai ban bang bao bei ben beng bi bian biang biao bie bin bing bo bu ca cai can cang cao ce cei cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai dan dang dao de dei den deng di dia dian diao die din ding diu dong dou du duan dui dun duo e eh ei en eng er fa fan fang fei fen feng fiao fo fong fou fu ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo lv lvan lve ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu na nai nan nang nao ne nei nen neng ni nia nian niang niao nie nin ning niu nong nou nu nuan nun nuo nv nve o ou pa pai pan pang pao pei pen peng pi pia pian piao pie pin ping po pou pu qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo sa sai san sang sao se sei sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo ta tai tan tang tao te tei teng ti tian tiao tie ting tong tou tu tuan tui tun tuo wa wai wan wang wei wen weng wo wong wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun ya yai yan yang yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
        """.split(whereSeparator: \Character.isWhitespace).map(String.init)
    )

    static func uppercaseOccurrences(
        in characters: [Character]
    ) -> [EnglishOccurrence] {
        var values: [EnglishOccurrence] = []
        var index = 0
        while index < characters.count {
            guard isASCIIUppercase(characters[index]) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count,
                  isASCIIUppercase(characters[end])
            {
                end += 1
            }
            if end - index >= 2 {
                values.append(
                    EnglishOccurrence(
                        start: index,
                        end: end,
                        source: .uppercase
                    )
                )
            }
            index = end
        }
        return values
    }

    static func dictionaryOccurrences(
        in characters: [Character],
        lowercaseCharacters: [Character],
        hardOccurrences: [EnglishOccurrence],
        personalizedTokens: Set<String>,
        builtinTokens: Set<String>
    ) -> [EnglishOccurrence] {
        var tokenSources: [String: OccurrenceSource] = [:]
        for token in builtinTokens {
            tokenSources[token] = .builtin
        }
        for token in personalizedTokens {
            tokenSources[token] = .personalized
        }

        var values: [EnglishOccurrence] = []
        for (token, source) in tokenSources {
            let tokenCharacters = Array(token)
            guard !tokenCharacters.isEmpty,
                  tokenCharacters.count <= characters.count
            else {
                continue
            }
            for start in 0 ... (characters.count - tokenCharacters.count) {
                let end = start + tokenCharacters.count
                guard Array(lowercaseCharacters[start ..< end])
                    == tokenCharacters,
                    !overlapsAny(
                        start: start,
                        end: end,
                        occurrences: hardOccurrences
                    )
                else {
                    continue
                }
                values.append(
                    EnglishOccurrence(
                        start: start,
                        end: end,
                        source: source
                    )
                )
            }
        }
        return values
    }

    static func sortOccurrences(
        _ lhs: EnglishOccurrence,
        _ rhs: EnglishOccurrence
    ) -> Bool {
        if lhs.start != rhs.start {
            return lhs.start < rhs.start
        }
        if lhs.end != rhs.end {
            return lhs.end > rhs.end
        }
        return lhs.source.rawValue > rhs.source.rawValue
    }

    static func overlapsRequiredOccurrence(
        start: Int,
        end: Int,
        occurrences: [EnglishOccurrence]
    ) -> Bool {
        occurrences.contains {
            max(start, $0.start) < min(end, $0.end)
        }
    }

    static func overlapsAny(
        start: Int,
        end: Int,
        occurrences: [EnglishOccurrence]
    ) -> Bool {
        occurrences.contains {
            max(start, $0.start) < min(end, $0.end)
        }
    }

    static func isPreferred(
        _ candidate: ScoredSuggestion,
        over current: ScoredSuggestion
    ) -> Bool {
        if candidate.score != current.score {
            return candidate.score > current.score
        }
        if candidate.asciiCharacterCount != current.asciiCharacterCount {
            return candidate.asciiCharacterCount
                > current.asciiCharacterCount
        }
        if candidate.suggestion.segments.count
            != current.suggestion.segments.count
        {
            return candidate.suggestion.segments.count
                < current.suggestion.segments.count
        }
        return candidate.suggestion.text < current.suggestion.text
    }

    static func isCompositionCharacter(_ character: Character) -> Bool {
        isASCIILetter(character) || character == "'"
    }

    static func isASCIILetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value
        else {
            return false
        }
        return (65 ... 90).contains(value) || (97 ... 122).contains(value)
    }

    static func isASCIIUppercase(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value
        else {
            return false
        }
        return (65 ... 90).contains(value)
    }

    static func isChineseCandidate(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            (0x3400 ... 0x9FFF).contains(scalar.value)
                || (0x20000 ... 0x2EBEF).contains(scalar.value)
        }
    }
}
