import Foundation

/// Deterministic hotword corrector for speech transcripts, plus hotword
/// prioritization for bounded cloud budgets.
///
/// Two hotword origins, two restoration rules:
/// - **ASCII skeleton restoration** (every source): `"rime ai"` → `"RimeAI"`,
///   `"fast api"` → `"FastAPI"`. Only spacing, separators and casing change,
///   so vocabulary learned from typing or mounted lexicons is safe to apply.
/// - **Han homophone restoration** (user-curated hotwords only): a transcript
///   span whose every syllable equals the hotword's is rewritten, e.g.
///   `"无松拼音"` → `"雾凇拼音"`. Learned, lexicon and session phrases never
///   replace Han characters: rewriting every homophone of an ordinary word
///   (`"直到"` → `"知道"`, `"涉及"` → `"设计"`) corrupts transcripts, so those
///   only restore ASCII spelling and lock their own exact text.
///
/// All syllable comparisons are exact. Fuzzy initials / finals (zh/z, -n/-ng …)
/// are deliberately not used here: without acoustic evidence they turn common
/// words into each other.
public struct VoiceHotwordCorrector: Sendable {
    public struct CorrectionResult: Equatable, Sendable {
        public let text: String
        public let appliedHotwords: [String]

        public init(text: String, appliedHotwords: [String]) {
            self.text = text
            self.appliedHotwords = appliedHotwords
        }
    }

    private let compiledHotwords: [CompiledHotword]

    /// Index of the last streaming text; only `applyStreaming(to:)` uses it.
    private var streamingIndex: HotwordTranscriptIndex?

    /// - Parameters:
    ///   - hotwords: User-curated hotwords. May restore Han characters by sound.
    ///   - vocabularyHotwords: Phrases learned from typing, mounted lexicons
    ///     and session commits. ASCII spelling only.
    public init(hotwords: [String], vocabularyHotwords: [String] = []) {
        compiledHotwords = HotwordCompiler.compile(
            hotwords: hotwords,
            vocabularyHotwords: vocabularyHotwords
        )
    }

    public func apply(to text: String) -> String {
        applyReturningMatches(to: text).text
    }

    public func applyReturningMatches(to text: String) -> CorrectionResult {
        applyReturningMatches(to: text, index: HotwordTranscriptIndex(text: text))
    }

    /// Same as `apply(to:)` for a transcript that only grows between calls
    /// (streaming recognition). Equivalent output; cheaper on long dictation.
    public mutating func applyStreaming(to text: String) -> String {
        let index = HotwordTranscriptIndex(chars: Array(text), extending: streamingIndex)
        streamingIndex = index
        return applyReturningMatches(to: text, index: index).text
    }

    public static func apply(to text: String, hotwords: [String]) -> String {
        VoiceHotwordCorrector(hotwords: hotwords).apply(to: text)
    }

    public static func applyReturningMatches(
        to text: String,
        hotwords: [String]
    ) -> CorrectionResult {
        VoiceHotwordCorrector(hotwords: hotwords).applyReturningMatches(to: text)
    }

    /// Prioritizes up to `limit` of the receiver's hotwords for a cloud request,
    /// lifting entries that appear verbatim or phonetically/structurally in
    /// `transcript` ahead of general entries.
    public func prioritizedForCloud(
        transcript: String,
        limit: Int = 32
    ) -> [String] {
        guard limit > 0, !compiledHotwords.isEmpty else {
            return []
        }
        guard !transcript.isEmpty else {
            // Nothing to rank against: keep the caller's order (the merger's
            // priority: user-curated hotwords, then learned vocabulary).
            return compiledHotwords
                .sorted { $0.originalIndex < $1.originalIndex }
                .prefix(limit)
                .map(\.raw)
        }
        return rankedForCloud(in: transcript)
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier {
                    return lhs.tier > rhs.tier
                }
                return lhs.originalIndex < rhs.originalIndex
            }
            .prefix(limit)
            .map(\.hotword)
    }

    public static func prioritizeForCloud(
        hotwords: [String],
        transcript: String,
        limit: Int = 32
    ) -> [String] {
        VoiceHotwordCorrector(hotwords: hotwords)
            .prioritizedForCloud(transcript: transcript, limit: limit)
    }

    // MARK: - Replacement

    private func applyReturningMatches(
        to text: String,
        index: HotwordTranscriptIndex
    ) -> CorrectionResult {
        guard !index.chars.isEmpty else {
            return CorrectionResult(text: text, appliedHotwords: [])
        }
        let edits = collectEdits(in: index)
        guard !edits.isEmpty else {
            return CorrectionResult(text: text, appliedHotwords: [])
        }
        return rebuild(index.chars, applying: edits)
    }

    /// Longest-first lock: every hotword scans only the positions its first
    /// atom can anchor at, and a locked span is never rewritten again.
    private func collectEdits(in index: HotwordTranscriptIndex) -> [HotwordEditSpan] {
        var locked = [Bool](repeating: false, count: index.chars.count)
        var edits: [HotwordEditSpan] = []
        for hotword in compiledHotwords {
            lockMatches(of: hotword, in: index, locked: &locked, edits: &edits)
        }
        return edits.sorted { $0.start < $1.start }
    }

    private func lockMatches(
        of hotword: CompiledHotword,
        in index: HotwordTranscriptIndex,
        locked: inout [Bool],
        edits: inout [HotwordEditSpan]
    ) {
        var visited = Set<Int>()
        for cursor in HotwordMatcher.candidatePositions(for: hotword, in: index) {
            guard cursor < index.chars.count,
                  visited.insert(cursor).inserted,
                  !locked[cursor]
            else {
                continue
            }
            guard let matchEnd = HotwordMatcher.match(hotword, at: cursor, in: index),
                  !locked[cursor ..< matchEnd].contains(true)
            else {
                continue
            }
            for position in cursor ..< matchEnd {
                locked[position] = true
            }
            if String(index.chars[cursor ..< matchEnd]) != hotword.raw {
                edits.append(
                    HotwordEditSpan(start: cursor, end: matchEnd, hotword: hotword.raw)
                )
            }
        }
    }

    private func rebuild(
        _ chars: [Character],
        applying edits: [HotwordEditSpan]
    ) -> CorrectionResult {
        var rebuilt = ""
        rebuilt.reserveCapacity(chars.count + 16)
        var applied: [String] = []
        var appliedSeen: Set<String> = []
        var cursor = 0

        for edit in edits {
            if cursor < edit.start {
                rebuilt.append(contentsOf: chars[cursor ..< edit.start])
            }
            rebuilt.append(edit.hotword)
            if appliedSeen.insert(edit.hotword).inserted {
                applied.append(edit.hotword)
            }
            cursor = edit.end
        }
        if cursor < chars.count {
            rebuilt.append(contentsOf: chars[cursor ..< chars.count])
        }
        return CorrectionResult(text: rebuilt, appliedHotwords: applied)
    }

    // MARK: - Cloud prioritization

    private func rankedForCloud(in transcript: String) -> [HotwordCloudRanking] {
        let index = HotwordTranscriptIndex(text: transcript)
        var ranked: [HotwordCloudRanking] = []
        for compiled in compiledHotwords {
            ranked.append(
                HotwordCloudRanking(
                    hotword: compiled.raw,
                    tier: cloudTier(of: compiled, in: transcript, index: index),
                    originalIndex: compiled.originalIndex
                )
            )
        }
        return ranked
    }

    private func cloudTier(
        of hotword: CompiledHotword,
        in transcript: String,
        index: HotwordTranscriptIndex
    ) -> Int {
        if HotwordMatcher.appearsVerbatim(hotword, in: transcript) {
            return 3
        }
        return HotwordMatcher.containsMatch(hotword, in: index) ? 2 : 1
    }
}

// MARK: - Compiled hotwords

private enum HotwordAtom: Sendable {
    case ascii(skeleton: String)
    case han(HotwordHanAtom)
    case literal(Character)
}

/// One Han character of a hotword with its readings: the contextual reading
/// first, then the isolated reading when it differs.
private struct HotwordHanAtom: Sendable {
    let char: Character
    let syllables: [String]
}

private struct CompiledHotword: Sendable {
    let raw: String
    let atoms: [HotwordAtom]
    let firstAtomKeys: [HotwordAtomKey]
    let hanCount: Int
    let asciiLength: Int
    let literalCount: Int
    /// Only user-curated hotwords may replace Han characters by sound.
    let allowsHanRestoration: Bool
    let originalIndex: Int

    /// Longer, more specific hotwords are applied first so shorter entries
    /// never fragment them.
    var priorityScore: Int {
        hanCount * 2 + asciiLength + literalCount
    }

    static func precedes(_ lhs: CompiledHotword, _ rhs: CompiledHotword) -> Bool {
        if lhs.priorityScore != rhs.priorityScore {
            return lhs.priorityScore > rhs.priorityScore
        }
        if lhs.atoms.count != rhs.atoms.count {
            return lhs.atoms.count > rhs.atoms.count
        }
        if lhs.raw.count != rhs.raw.count {
            return lhs.raw.count > rhs.raw.count
        }
        return lhs.originalIndex < rhs.originalIndex
    }
}

private struct HotwordEditSpan {
    let start: Int
    let end: Int
    let hotword: String
}

private struct HotwordCloudRanking {
    let hotword: String
    let tier: Int
    let originalIndex: Int
}

private enum HotwordCompiler {
    /// Short English function words are only normalized next to Han text;
    /// in pure English prose `"let's go home"` must stay untouched.
    static let commonShortEnglishWords: Set<String> = [
        "am", "an", "as", "at", "be", "by", "do", "go",
        "he", "if", "in", "is", "it", "me", "my", "no",
        "of", "on", "or", "so", "to", "up", "us", "we",
    ]

    static func compile(
        hotwords: [String],
        vocabularyHotwords: [String]
    ) -> [CompiledHotword] {
        var seen = Set<String>()
        var compiled: [CompiledHotword] = []
        let tiers: [(source: [String], allowsHanRestoration: Bool)] = [
            (hotwords, true),
            (vocabularyHotwords, false),
        ]
        for tier in tiers {
            append(
                tier.source,
                allowsHanRestoration: tier.allowsHanRestoration,
                seen: &seen,
                into: &compiled
            )
        }
        return compiled.sorted(by: CompiledHotword.precedes)
    }

    private static func append(
        _ source: [String],
        allowsHanRestoration: Bool,
        seen: inout Set<String>,
        into compiled: inout [CompiledHotword]
    ) {
        for raw in source {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                continue
            }
            if let entry = compile(
                raw: trimmed,
                originalIndex: compiled.count,
                allowsHanRestoration: allowsHanRestoration
            ) {
                compiled.append(entry)
            }
        }
    }

    private static func compile(
        raw: String,
        originalIndex: Int,
        allowsHanRestoration: Bool
    ) -> CompiledHotword? {
        let chars = Array(raw)
        var builder = Builder()
        var index = 0
        while index < chars.count {
            guard let consumed = builder.appendAtomRun(in: chars, from: index),
                  consumed > 0
            else {
                return nil
            }
            index += consumed
        }
        guard builder.isValidLength, let firstAtom = builder.atoms.first else {
            return nil
        }
        return CompiledHotword(
            raw: raw,
            atoms: builder.atoms,
            firstAtomKeys: HotwordMatcher.firstAtomKeys(of: firstAtom),
            hanCount: builder.hanCount,
            asciiLength: builder.asciiLength,
            literalCount: builder.literalCount,
            allowsHanRestoration: allowsHanRestoration,
            originalIndex: originalIndex
        )
    }

    /// Readings for each Han character of a run: the contextual reading when
    /// the whole run transliterates one syllable per character (so polyphones
    /// such as `重复` and `行长` read naturally), otherwise the isolated one.
    static func readings(
        forHanRun run: [Character],
        isolatedReadings: inout [Character: String]
    ) -> [[String]] {
        let contextual = VoicePostCommitCorrectionLearner
            .contextualMandarinSyllables(for: String(run))
        let perCharacter: [String]? = contextual.count == run.count ? contextual : nil
        var result: [[String]] = []
        for offset in 0 ..< run.count {
            result.append(
                reading(
                    at: offset,
                    of: run,
                    contextual: perCharacter,
                    isolatedReadings: &isolatedReadings
                )
            )
        }
        return result
    }

    private static func reading(
        at offset: Int,
        of run: [Character],
        contextual: [String]?,
        isolatedReadings: inout [Character: String]
    ) -> [String] {
        let isolated: String
        if let cached = isolatedReadings[run[offset]] {
            isolated = cached
        } else {
            isolated = VoicePostCommitCorrectionLearner
                .mandarinSyllables(for: String(run[offset]))
                .first ?? ""
            isolatedReadings[run[offset]] = isolated
        }
        let primary = contextual?[offset] ?? isolated
        if primary.isEmpty {
            return isolated.isEmpty ? [] : [isolated]
        }
        if isolated.isEmpty || isolated == primary {
            return [primary]
        }
        return [primary, isolated]
    }

    private struct Builder {
        private(set) var atoms: [HotwordAtom] = []
        private(set) var hanCount = 0
        private(set) var asciiLength = 0
        private(set) var literalCount = 0
        private var isolatedReadings: [Character: String] = [:]

        var isValidLength: Bool {
            hanCount >= 2
                || asciiLength >= 2
                || (hanCount >= 1 && asciiLength >= 1)
                || (asciiLength >= 1 && literalCount >= 1)
        }

        /// Appends the atom run starting at `index`; returns how many
        /// characters were consumed, or nil when the hotword is unusable.
        mutating func appendAtomRun(in chars: [Character], from index: Int) -> Int? {
            let character = chars[index]
            if HotwordCharacterSet.isHorizontalWhitespace(character) || character.isNewline {
                return 1
            }
            if VoicePostCommitCorrectionLearner.isHan(character) {
                return appendHanRun(in: chars, from: index)
            }
            if HotwordCharacterSet.isASCIIAlnum(character) {
                appendASCII(in: chars, from: index)
                return asciiRunEnd(chars, from: index) - index
            }
            atoms.append(.literal(character))
            literalCount += 1
            return 1
        }

        private mutating func appendHanRun(
            in chars: [Character],
            from start: Int
        ) -> Int? {
            let end = hanRunEnd(chars, from: start)
            let run = Array(chars[start ..< end])
            let readings = HotwordCompiler.readings(
                forHanRun: run,
                isolatedReadings: &isolatedReadings
            )
            for (offset, character) in run.enumerated() {
                guard !readings[offset].isEmpty else {
                    return nil
                }
                atoms.append(.han(HotwordHanAtom(char: character, syllables: readings[offset])))
                hanCount += 1
            }
            return run.count
        }

        private mutating func appendASCII(in chars: [Character], from start: Int) {
            var skeleton = ""
            var cursor = start
            while cursor < chars.count {
                if HotwordCharacterSet.isASCIIAlnum(chars[cursor]) {
                    skeleton.append(chars[cursor].lowercased())
                    cursor += 1
                    continue
                }
                guard let resume = HotwordCharacterSet.nextAlnum(in: chars, at: cursor) else {
                    break
                }
                cursor = resume
            }
            atoms.append(.ascii(skeleton: skeleton))
            asciiLength += skeleton.count
        }

        private func hanRunEnd(_ chars: [Character], from start: Int) -> Int {
            var end = start
            while end < chars.count, VoicePostCommitCorrectionLearner.isHan(chars[end]) {
                end += 1
            }
            return end
        }

        /// Where the ASCII atom starting at `start` stops: internal separators
        /// (`fast api`, `next.js`) are skipped only while another ASCII
        /// alphanumeric follows without crossing Han characters or newlines.
        private func asciiRunEnd(_ chars: [Character], from start: Int) -> Int {
            var cursor = start
            while cursor < chars.count {
                if HotwordCharacterSet.isASCIIAlnum(chars[cursor]) {
                    cursor += 1
                    continue
                }
                guard let resume = HotwordCharacterSet.nextAlnum(in: chars, at: cursor) else {
                    break
                }
                cursor = resume
            }
            return cursor
        }
    }
}

// MARK: - Transcript index

/// Bucket key for the first atom of a hotword: every transcript position that
/// could start a match is registered under its key, so matching is linear in
/// the transcript instead of hotwords × transcript.
private enum HotwordAtomKey: Hashable, Sendable {
    case ascii(Character)
    case han(Character)
    case syllable(String)
    case literal(Character)

    static func key(for character: Character) -> HotwordAtomKey {
        if HotwordCharacterSet.isASCIIAlnum(character),
           let lowercased = character.lowercased().first
        {
            return .ascii(lowercased)
        }
        return .literal(character)
    }
}

private struct HotwordTranscriptIndex: Sendable {
    let chars: [Character]
    /// Readings per position; empty where the character is not Han or has no
    /// Mandarin reading. Contextual reading first.
    let syllables: [[String]]
    /// Start of the Han run containing each position (`-1` for non-Han).
    let hanRunStarts: [Int]
    /// Ascending positions able to start each first-atom key.
    let positions: [HotwordAtomKey: [Int]]

    init(text: String) {
        self.init(chars: Array(text), extending: nil)
    }

    /// Indexes `chars`, reusing `previous` when it is a strict prefix. A
    /// streaming transcript only ever appends, so steady-state work is
    /// proportional to the newly recognized tail, not to the whole text.
    init(chars: [Character], extending previous: HotwordTranscriptIndex?) {
        let base = HotwordTranscriptIndex.reuseBase(for: chars, extending: previous)
        var builder = Builder(count: chars.count)
        if let previous, base > 0 {
            builder.adopt(previous, upTo: base)
        }
        builder.index(chars, from: base)
        self.chars = chars
        syllables = builder.syllables
        hanRunStarts = builder.hanRunStarts
        positions = builder.positions
    }

    private static func reuseBase(
        for chars: [Character],
        extending previous: HotwordTranscriptIndex?
    ) -> Int {
        guard let previous, chars.count >= previous.chars.count,
              previous.chars.elementsEqual(chars.prefix(previous.chars.count))
        else {
            return 0
        }
        var base = previous.chars.count
        if base > 0 {
            let runStart = previous.hanRunStarts[base - 1]
            // A Han run that was still growing may read differently once
            // complete (polyphones): index it again from its start.
            if runStart >= 0 {
                base = runStart
            }
        }
        return base
    }

    private struct Builder {
        var syllables: [[String]]
        var hanRunStarts: [Int]
        var positions: [HotwordAtomKey: [Int]] = [:]
        private var isolatedReadings: [Character: String] = [:]

        init(count: Int) {
            syllables = [[String]](repeating: [], count: count)
            hanRunStarts = [Int](repeating: -1, count: count)
        }

        mutating func adopt(_ previous: HotwordTranscriptIndex, upTo base: Int) {
            for position in 0 ..< base {
                syllables[position] = previous.syllables[position]
                hanRunStarts[position] = previous.hanRunStarts[position]
            }
            for (key, list) in previous.positions {
                positions[key] = list.filter { $0 < base }
            }
        }

        mutating func index(_ chars: [Character], from start: Int) {
            var cursor = start
            while cursor < chars.count {
                if VoicePostCommitCorrectionLearner.isHan(chars[cursor]) {
                    cursor = indexHanRun(chars, startingAt: cursor)
                } else {
                    register(chars[cursor], at: cursor)
                    cursor += 1
                }
            }
        }

        private mutating func indexHanRun(
            _ chars: [Character],
            startingAt start: Int
        ) -> Int {
            var end = start
            while end < chars.count, VoicePostCommitCorrectionLearner.isHan(chars[end]) {
                end += 1
            }
            let run = Array(chars[start ..< end])
            let readings = HotwordCompiler.readings(
                forHanRun: run,
                isolatedReadings: &isolatedReadings
            )
            for (offset, reading) in readings.enumerated() {
                registerHan(
                    run[offset],
                    reading: reading,
                    runStart: start,
                    at: start + offset
                )
            }
            return end
        }

        private mutating func registerHan(
            _ character: Character,
            reading: [String],
            runStart: Int,
            at position: Int
        ) {
            hanRunStarts[position] = runStart
            syllables[position] = reading
            guard !reading.isEmpty else {
                return
            }
            positions[.han(character), default: []].append(position)
            for syllable in Set(reading) {
                positions[.syllable(syllable), default: []].append(position)
            }
        }

        private mutating func register(_ character: Character, at position: Int) {
            positions[HotwordAtomKey.key(for: character), default: []].append(position)
        }
    }
}

// MARK: - Matching

private enum HotwordMatcher {
    /// Identity bucket for every tier, sound buckets for curated hotwords.
    static func firstAtomKeys(of atom: HotwordAtom) -> [HotwordAtomKey] {
        switch atom {
        case let .ascii(skeleton):
            return [skeleton.first].compactMap { $0.map(HotwordAtomKey.ascii) }
        case let .han(hanAtom):
            return [.han(hanAtom.char)] + hanAtom.syllables.map(HotwordAtomKey.syllable)
        case let .literal(character):
            return [.literal(character)]
        }
    }

    static func candidatePositions(
        for hotword: CompiledHotword,
        in index: HotwordTranscriptIndex
    ) -> [Int] {
        var merged: [Int] = []
        for key in hotword.firstAtomKeys {
            merged.append(contentsOf: index.positions[key] ?? [])
        }
        return merged.sorted()
    }

    static func containsMatch(
        _ hotword: CompiledHotword,
        in index: HotwordTranscriptIndex
    ) -> Bool {
        candidatePositions(for: hotword, in: index)
            .contains { match(hotword, at: $0, in: index) != nil }
    }

    static func appearsVerbatim(
        _ hotword: CompiledHotword,
        in transcript: String
    ) -> Bool {
        if hotword.raw.allSatisfy(\.isASCII) {
            return transcript.lowercased().contains(hotword.raw.lowercased())
        }
        return transcript.contains(hotword.raw)
    }

    /// Returns the position just past a match of `hotword` anchored at `start`.
    static func match(
        _ hotword: CompiledHotword,
        at start: Int,
        in index: HotwordTranscriptIndex
    ) -> Int? {
        guard anchorsFirstAtom(hotword, at: start, in: index) else {
            return nil
        }
        return matchAtoms(hotword, from: start, in: index)
    }

    /// The first atom must anchor exactly at `start`: an ASCII skeleton cannot
    /// begin in the middle of a longer ASCII word.
    private static func anchorsFirstAtom(
        _ hotword: CompiledHotword,
        at start: Int,
        in index: HotwordTranscriptIndex
    ) -> Bool {
        guard start < index.chars.count else {
            return false
        }
        switch hotword.atoms[0] {
        case .ascii:
            return HotwordCharacterSet.isASCIIAlnum(index.chars[start])
                && (start == 0 || !HotwordCharacterSet.isASCIIAlnum(index.chars[start - 1]))
        case .han:
            return !index.syllables[start].isEmpty
        case let .literal(character):
            return index.chars[start] == character
        }
    }

    private static func matchAtoms(
        _ hotword: CompiledHotword,
        from start: Int,
        in index: HotwordTranscriptIndex
    ) -> Int? {
        var cursor = start
        for (atomIndex, atom) in hotword.atoms.enumerated() {
            if atomIndex > 0 {
                // Optional horizontal whitespace between atoms ("RimeAI 输入法").
                cursor = HotwordCharacterSet.skipHorizontalWhitespace(
                    in: index.chars,
                    from: cursor
                )
            }
            guard let next = matchAtom(
                atom,
                atomIndex: atomIndex,
                hotword: hotword,
                at: cursor,
                leadingStart: start,
                in: index
            ) else {
                return nil
            }
            cursor = next
        }
        return cursor
    }

    private static func matchAtom(
        _ atom: HotwordAtom,
        atomIndex: Int,
        hotword: CompiledHotword,
        at cursor: Int,
        leadingStart: Int,
        in index: HotwordTranscriptIndex
    ) -> Int? {
        switch atom {
        case let .ascii(skeleton):
            if atomIndex > 0, cursor > 0,
               HotwordCharacterSet.isASCIIAlnum(index.chars[cursor - 1])
            {
                return nil
            }
            return consumeASCIISkeleton(
                skeleton,
                at: cursor,
                in: index.chars,
                isStandaloneShortASCII: hotword.atoms.count == 1 && skeleton.count <= 2,
                leadingStart: leadingStart
            )
        case let .han(hanAtom):
            return matchHan(
                hanAtom,
                allowedBySound: hotword.allowsHanRestoration,
                at: cursor,
                in: index
            )
        case let .literal(expected):
            guard cursor < index.chars.count, index.chars[cursor] == expected else {
                return nil
            }
            return cursor + 1
        }
    }

    /// A Han atom matches the identical character. Only a user-curated hotword
    /// may instead match by an exactly equal reading.
    private static func matchHan(
        _ hanAtom: HotwordHanAtom,
        allowedBySound: Bool,
        at cursor: Int,
        in index: HotwordTranscriptIndex
    ) -> Int? {
        guard cursor < index.chars.count, !index.syllables[cursor].isEmpty else {
            return nil
        }
        if index.chars[cursor] == hanAtom.char {
            return cursor + 1
        }
        guard allowedBySound,
              !Set(index.syllables[cursor]).isDisjoint(with: hanAtom.syllables)
        else {
            return nil
        }
        return cursor + 1
    }

    private static func consumeASCIISkeleton(
        _ skeleton: String,
        at startPos: Int,
        in chars: [Character],
        isStandaloneShortASCII: Bool,
        leadingStart: Int
    ) -> Int? {
        guard startPos < chars.count,
              HotwordCharacterSet.isASCIIAlnum(chars[startPos])
        else {
            return nil
        }
        guard let endPos = consumeSkeletonCharacters(Array(skeleton), at: startPos, in: chars),
              endPos == chars.count || !HotwordCharacterSet.isASCIIAlnum(chars[endPos])
        else {
            return nil
        }
        if isStandaloneShortASCII, HotwordCompiler.commonShortEnglishWords.contains(skeleton) {
            return isAdjacentToHan(chars, before: leadingStart, after: endPos) ? endPos : nil
        }
        return endPos
    }

    /// Case-insensitive skeleton match; separators inside the skeleton
    /// (`fast-api`) may be spoken as spaces, `-`, `_`, `.` or apostrophes.
    private static func consumeSkeletonCharacters(
        _ skeleton: [Character],
        at startPos: Int,
        in chars: [Character]
    ) -> Int? {
        var skeletonIndex = 0
        var cursor = startPos
        var separatorSpaces = 0
        while skeletonIndex < skeleton.count {
            guard cursor < chars.count else {
                return nil
            }
            let character = chars[cursor]
            if HotwordCharacterSet.isASCIIAlnum(character) {
                guard character.lowercased() == String(skeleton[skeletonIndex]) else {
                    return nil
                }
                skeletonIndex += 1
                separatorSpaces = 0
            } else if skeletonIndex > 0, HotwordCharacterSet.isASCIISeparator(character) {
                separatorSpaces = HotwordCharacterSet
                    .isHorizontalWhitespace(character) ? separatorSpaces + 1 : 0
                guard separatorSpaces <= 2 else {
                    return nil
                }
            } else {
                return nil
            }
            cursor += 1
        }
        return cursor
    }

    private static func isAdjacentToHan(
        _ chars: [Character],
        before leadingStart: Int,
        after endPos: Int
    ) -> Bool {
        HotwordCharacterSet.nearestNonSpaceIsHan(in: chars, before: leadingStart)
            || HotwordCharacterSet.nearestNonSpaceIsHan(in: chars, startingAt: endPos)
    }
}

// MARK: - Character predicates

private enum HotwordCharacterSet {
    static func isASCIIAlnum(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1
        else {
            return false
        }
        let value = scalar.value
        return (0x30 ... 0x39).contains(value)
            || (0x41 ... 0x5A).contains(value)
            || (0x61 ... 0x7A).contains(value)
    }

    static func isASCIISeparator(_ character: Character) -> Bool {
        isHorizontalWhitespace(character)
            || character == "-" || character == "_"
            || character == "." || character == "'" || character == "’"
    }

    static func isHorizontalWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\u{00A0}"
    }

    static func skipHorizontalWhitespace(in chars: [Character], from start: Int) -> Int {
        var cursor = start
        while cursor < chars.count, isHorizontalWhitespace(chars[cursor]) {
            cursor += 1
        }
        return cursor
    }

    /// Next ASCII alphanumeric reached only through separators, if any.
    static func nextAlnum(in chars: [Character], at index: Int) -> Int? {
        guard isASCIISeparator(chars[index]) else {
            return nil
        }
        var peek = index + 1
        while peek < chars.count, isASCIISeparator(chars[peek]) {
            peek += 1
        }
        guard peek < chars.count, isASCIIAlnum(chars[peek]) else {
            return nil
        }
        return peek
    }

    static func nearestNonSpaceIsHan(in chars: [Character], before index: Int) -> Bool {
        var cursor = index - 1
        while cursor >= 0, isHorizontalWhitespace(chars[cursor]) {
            cursor -= 1
        }
        guard cursor >= 0 else {
            return false
        }
        return VoicePostCommitCorrectionLearner.isHan(chars[cursor])
    }

    static func nearestNonSpaceIsHan(in chars: [Character], startingAt index: Int) -> Bool {
        var cursor = index
        while cursor < chars.count, isHorizontalWhitespace(chars[cursor]) {
            cursor += 1
        }
        guard cursor < chars.count else {
            return false
        }
        return VoicePostCommitCorrectionLearner.isHan(chars[cursor])
    }
}
