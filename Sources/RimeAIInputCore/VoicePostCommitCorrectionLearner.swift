import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

// MARK: - Data Types

/// A verified correction extracted from a user's post-commit edit of
/// voice-dictated text.
public struct VoiceLearnedCorrection: Codable, Equatable, Sendable {
    /// Original misrecognized phrase (e.g. "八哥说" or "Rime AI").
    public let wrongText: String
    /// User-corrected phrase (e.g. "叭哥说" or "RimeAI").
    public let correctedText: String
    /// Hotword to register in the voice hotword lexicon (usually equal to
    /// `correctedText`).
    public let hotword: String
    /// Normalized toneless pinyin keys for L1 phrasebook registration when
    /// available (e.g. "bageshuo" or "rimeai").
    public let pinyinKeys: String?

    public init(
        wrongText: String,
        correctedText: String,
        hotword: String,
        pinyinKeys: String? = nil
    ) {
        self.wrongText = wrongText
        self.correctedText = correctedText
        self.hotword = hotword
        self.pinyinKeys = pinyinKeys
    }
}

/// Snapshot captured at the exact moment voice dictation commits text into a
/// host input field.
public struct VoicePostCommitAnchor: Equatable, Sendable {
    public let committedText: String
    public let bundleIdentifier: String
    public let appSessionID: String
    /// UTF-16 offset where `committedText` was inserted (`NSNotFound` if the
    /// host does not report selection locations).
    public let insertionUTF16Offset: Int
    /// Up to 16 characters immediately preceding the insertion point.
    public let prefixAnchor: String
    /// Up to 16 characters immediately following the insertion point.
    public let suffixAnchor: String
    public let committedAt: Date

    public init(
        committedText: String,
        bundleIdentifier: String,
        appSessionID: String,
        insertionUTF16Offset: Int = NSNotFound,
        prefixAnchor: String = "",
        suffixAnchor: String = "",
        committedAt: Date = Date()
    ) {
        self.committedText = committedText
        self.bundleIdentifier = bundleIdentifier
        self.appSessionID = appSessionID
        self.insertionUTF16Offset = insertionUTF16Offset
        self.prefixAnchor = String(prefixAnchor.suffix(16))
        self.suffixAnchor = String(suffixAnchor.prefix(16))
        self.committedAt = committedAt
    }
}

/// Fallback keystroke trace recorded when the host application does not expose
/// readable document text (`attributedSubstring` returns nil and AX is
/// unavailable).
public struct VoicePostCommitTailEdit: Equatable, Sendable {
    public let deletedTrailingCharacters: Int
    public let replacementText: String
    public let replacementPinyin: String?

    public init(
        deletedTrailingCharacters: Int,
        replacementText: String,
        replacementPinyin: String? = nil
    ) {
        self.deletedTrailingCharacters = deletedTrailingCharacters
        self.replacementText = replacementText
        self.replacementPinyin = replacementPinyin
    }
}

// MARK: - Deterministic Learned Correction Applier

/// Applies user-learned `wrongText -> correctedText` mappings deterministically
/// to voice dictation transcripts before commit.
public enum VoiceLearnedCorrectionApplier {
    public static func apply(
        _ text: String,
        corrections: [String: String]
    ) -> String {
        guard !text.isEmpty, !corrections.isEmpty else {
            return text
        }
        // Longest wrongText first so specific multi-character phrases win over
        // shorter substrings; deterministic tie-breaking by lexicographic key.
        let ordered = corrections
            .filter { key, value in
                !key.isEmpty && !value.isEmpty && key != value
            }
            .sorted { lhs, rhs in
                if lhs.key.count != rhs.key.count {
                    return lhs.key.count > rhs.key.count
                }
                return lhs.key < rhs.key
            }
        guard !ordered.isEmpty else {
            return text
        }

        var result = text
        for (wrong, right) in ordered {
            result = replaceTerm(
                in: result,
                target: wrong,
                replacement: right
            )
        }
        return result
    }

    private static func replaceTerm(
        in text: String,
        target: String,
        replacement: String
    ) -> String {
        let startsASCII = target.first.map(isASCIIAlphaNumeric) ?? false
        let endsASCII = target.last.map(isASCIIAlphaNumeric) ?? false
        let compareOptions: String.CompareOptions = (startsASCII && endsASCII)
            ? [.caseInsensitive]
            : []

        var output = ""
        output.reserveCapacity(text.count)
        var searchStart = text.startIndex

        while searchStart < text.endIndex,
              let range = text.range(
                  of: target,
                  options: compareOptions,
                  range: searchStart ..< text.endIndex
              )
        {
            let leftOK: Bool
            if startsASCII, range.lowerBound > text.startIndex {
                let before = text[text.index(before: range.lowerBound)]
                leftOK = !isASCIIAlphaNumeric(before)
            } else {
                leftOK = true
            }

            let rightOK: Bool
            if endsASCII, range.upperBound < text.endIndex {
                let after = text[range.upperBound]
                rightOK = !isASCIIAlphaNumeric(after)
            } else {
                rightOK = true
            }

            if leftOK && rightOK {
                output.append(contentsOf: text[searchStart ..< range.lowerBound])
                output.append(replacement)
                searchStart = range.upperBound
            } else {
                let nextIndex = text.index(after: range.lowerBound)
                output.append(contentsOf: text[searchStart ..< nextIndex])
                searchStart = nextIndex
            }
        }

        if searchStart < text.endIndex {
            output.append(contentsOf: text[searchStart...])
        }
        return output
    }

    private static func isASCIIAlphaNumeric(_ ch: Character) -> Bool {
        guard ch.isASCII, let scalar = ch.unicodeScalars.first else {
            return false
        }
        return (48 ... 57).contains(scalar.value)
            || (65 ... 90).contains(scalar.value)
            || (97 ... 122).contains(scalar.value)
    }
}

// MARK: - Post-Commit Diff & Phonetic Learner

/// Extracts high-confidence vocabulary corrections from post-commit user edits
/// while aggressively filtering out meaning changes, rewrites, stopwords, and
/// sensitive tokens.
public enum VoicePostCommitCorrectionLearner {
    public static let observationWindowSeconds: TimeInterval = 25
    public static let settleDebounceSeconds: TimeInterval = 1.6
    public static let maximumTrackedCommittedCharacters = 240
    public static let maximumReadbackCharacters = 320
    public static let maximumCorrectionsPerCommit = 2

    private static let punctuationAndWhitespace: Set<Character> = Set(
        " \t\n\r,，.。!！?？;；:：、\"'“”‘’()（）[]【】{}《》<>—–-…~·"
    )

    /// Common high-frequency Chinese function characters that should not be
    /// pulled in as noise when expanding a 1-character Han edit into a phrase.
    private static let hanBoundaryStopChars: Set<Character> = Set(
        "的了是在我你他她它这那就也都和与把被给从到对向为以而但可要会能很更最么吗呢吧啊呀哦嗯呃"
    )

    /// Trivial single-char swaps (pronouns / de-particles / demonstratives)
    /// that represent grammar fixes rather than dictionary vocabulary.
    private static let trivialSingleCharPairs: Set<String> = [
        "他|她", "她|他", "他|它", "它|他", "她|它", "它|她",
        "的|地", "地|的", "的|得", "得|的", "地|得", "得|地",
        "那|哪", "哪|那", "在|再", "再|在", "做|作", "作|做",
        "象|像", "像|象", "以|已", "已|以", "连|联", "联|连",
    ]

    /// High-level entry point: given the commit anchor and a readback window
    /// around the insertion site, extract verified corrections.
    public static func extractCorrections(
        anchor: VoicePostCommitAnchor,
        documentWindow: String,
        hintedRimePhrase: String? = nil,
        hintedRimePinyin: String? = nil
    ) -> [VoiceLearnedCorrection] {
        let original = anchor.committedText
        guard original.count >= 2,
              original.count <= maximumTrackedCommittedCharacters,
              !documentWindow.isEmpty
        else {
            return []
        }

        guard let edited = isolateEditedSpan(
            original: original,
            prefixAnchor: anchor.prefixAnchor,
            suffixAnchor: anchor.suffixAnchor,
            documentWindow: documentWindow
        ) else {
            return []
        }

        return extractCorrections(
            original: original,
            edited: edited,
            hintedRimePhrase: hintedRimePhrase,
            hintedRimePinyin: hintedRimePinyin
        )
    }

    /// Fallback entry point when the host application does not allow reading
    /// back document text, but the user pressed Backspace N times immediately
    /// after voice commit and typed a replacement via RimeAI.
    public static func extractCorrectionFromTailEdit(
        committedText: String,
        tailEdit: VoicePostCommitTailEdit
    ) -> VoiceLearnedCorrection? {
        let deletedCount = tailEdit.deletedTrailingCharacters
        guard deletedCount >= 1,
              deletedCount <= min(12, committedText.count)
        else {
            return nil
        }
        let replacement = tailEdit.replacementText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty,
              replacement.count <= 24
        else {
            return nil
        }

        let prefixCount = committedText.count - deletedCount
        let edited = String(committedText.prefix(prefixCount)) + replacement
        let extracted = extractCorrections(
            original: committedText,
            edited: edited,
            hintedRimePhrase: replacement,
            hintedRimePinyin: tailEdit.replacementPinyin
        )
        return extracted.first
    }

    /// Core comparison between original committed sentence and edited sentence.
    public static func extractCorrections(
        original: String,
        edited: String,
        hintedRimePhrase: String? = nil,
        hintedRimePinyin: String? = nil
    ) -> [VoiceLearnedCorrection] {
        let orig = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let edit = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard orig != edit,
              orig.count >= 2,
              edit.count >= 2,
              orig.count <= maximumTrackedCommittedCharacters,
              edit.count <= maximumReadbackCharacters
        else {
            return []
        }

        let origChars = Array(orig)
        let editChars = Array(edit)

        // Reject wholesale rewrites / massive deletions right away.
        let hunks = computeCoalescedHunks(origChars, editChars)
        guard !hunks.isEmpty else {
            return []
        }

        // Ignore pure trailing additions after the end of the original text
        // (common when user fixes a word mid-sentence and keeps typing).
        let meaningfulHunks = hunks.filter { hunk in
            if hunk.origRange.lowerBound == origChars.count
                && hunk.origRange.isEmpty
            {
                return false
            }
            let oldText = String(origChars[hunk.origRange])
            let newText = String(editChars[hunk.editRange])
            if isPurePunctuationOrWhitespace(oldText)
                && isPurePunctuationOrWhitespace(newText)
            {
                // Keep space-removal inside ASCII words (e.g. "Rime AI" -> "RimeAI").
                let adjacentOrigASCII = isAdjacentASCII(
                    origChars,
                    around: hunk.origRange
                )
                let adjacentEditASCII = isAdjacentASCII(
                    editChars,
                    around: hunk.editRange
                )
                return oldText.contains(" ")
                    && newText.isEmpty
                    && adjacentOrigASCII
                    && adjacentEditASCII
            }
            return true
        }

        guard !meaningfulHunks.isEmpty,
              meaningfulHunks.count <= maximumCorrectionsPerCommit
        else {
            return []
        }

        // Reject if too large a fraction of a long sentence was rewritten.
        let totalOrigEdited = meaningfulHunks.reduce(0) {
            $0 + $1.origRange.count
        }
        let totalEditInserted = meaningfulHunks.reduce(0) {
            $0 + $1.editRange.count
        }
        if origChars.count >= 8,
           Double(max(totalOrigEdited, totalEditInserted))
               / Double(origChars.count) > 0.65
        {
            return []
        }

        var results: [VoiceLearnedCorrection] = []
        var seenPairs = Set<String>()

        for hunk in meaningfulHunks {
            guard let correction = buildVerifiedCorrection(
                origChars: origChars,
                editChars: editChars,
                hunk: hunk,
                hintedRimePhrase: hintedRimePhrase,
                hintedRimePinyin: hintedRimePinyin
            ) else {
                continue
            }
            let key = "\(correction.wrongText)->\(correction.correctedText)"
            if seenPairs.insert(key).inserted {
                results.append(correction)
            }
        }

        return results
    }

    // MARK: - Anchor Isolation

    static func isolateEditedSpan(
        original: String,
        prefixAnchor: String,
        suffixAnchor: String,
        documentWindow: String
    ) -> String? {
        guard !documentWindow.isEmpty else {
            return nil
        }

        var startIndex = documentWindow.startIndex
        if !prefixAnchor.isEmpty {
            if let range = documentWindow.range(of: prefixAnchor) {
                startIndex = range.upperBound
            } else {
                // Try shorter suffix of prefixAnchor (last 6 chars) in case
                // earlier text was trimmed by the host window.
                let shortPrefix = String(prefixAnchor.suffix(6))
                if shortPrefix.count >= 2,
                   let range = documentWindow.range(of: shortPrefix)
                {
                    startIndex = range.upperBound
                } else {
                    return nil
                }
            }
        }

        var endIndex = documentWindow.endIndex
        if !suffixAnchor.isEmpty {
            if let range = documentWindow.range(
                of: suffixAnchor,
                range: startIndex ..< documentWindow.endIndex
            ) {
                endIndex = range.lowerBound
            } else {
                let shortSuffix = String(suffixAnchor.prefix(6))
                if shortSuffix.count >= 2,
                   let range = documentWindow.range(
                       of: shortSuffix,
                       range: startIndex ..< documentWindow.endIndex
                   )
                {
                    endIndex = range.lowerBound
                }
            }
        }

        guard startIndex < endIndex else {
            return nil
        }

        var slice = String(documentWindow[startIndex ..< endIndex])
        if !original.contains("\n"), !original.contains("\r"),
           let newlineIdx = slice.firstIndex(where: { $0 == "\n" || $0 == "\r" })
        {
            slice = String(slice[..<newlineIdx])
        }
        guard !slice.isEmpty else {
            return nil
        }
        if slice.count > maximumReadbackCharacters {
            slice = String(slice.prefix(maximumReadbackCharacters))
        }
        return slice
    }

    // MARK: - LCS Diff & Hunk Coalescing

    private struct DiffHunk {
        var origRange: Range<Int>
        var editRange: Range<Int>
    }

    private static func computeCoalescedHunks(
        _ a: [Character],
        _ b: [Character]
    ) -> [DiffHunk] {
        // Fast common prefix / suffix trim before DP LCS.
        var prefix = 0
        let minLen = min(a.count, b.count)
        while prefix < minLen && a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < (minLen - prefix)
            && a[a.count - 1 - suffix] == b[b.count - 1 - suffix]
        {
            suffix += 1
        }

        let aMidStart = prefix
        let aMidEnd = a.count - suffix
        let bMidStart = prefix
        let bMidEnd = b.count - suffix

        let aMid = Array(a[aMidStart ..< aMidEnd])
        let bMid = Array(b[bMidStart ..< bMidEnd])
        let m = aMid.count
        let n = bMid.count
        if m == 0 && n == 0 {
            return []
        }

        // Standard O(m*n) LCS table (bounded by ≤ 240 * 320, < 0.3 ms).
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        if m > 0 && n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    if aMid[i] == bMid[j] {
                        dp[i][j] = dp[i + 1][j + 1] + 1
                    } else {
                        dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }
        }

        var rawHunks: [DiffHunk] = []
        var i = 0
        var j = 0
        while i < m || j < n {
            if i < m && j < n && aMid[i] == bMid[j] {
                i += 1
                j += 1
                continue
            }
            let startI = i
            let startJ = j
            while i < m || j < n {
                if i < m && j < n && aMid[i] == bMid[j] {
                    break
                }
                if i < m && (j == n || dp[i + 1][j] >= dp[i][j + 1]) {
                    i += 1
                } else {
                    j += 1
                }
            }
            rawHunks.append(DiffHunk(
                origRange: (aMidStart + startI) ..< (aMidStart + i),
                editRange: (bMidStart + startJ) ..< (bMidStart + j)
            ))
        }

        // Coalesce adjacent hunks separated by at most 1 non-punctuation char
        // (e.g. "雾松拼英" -> "雾凇拼音"), OR separated purely by ASCII word
        // chars (e.g. "wisper" -> "Wispr", "fast api" -> "FastAPI").
        var merged: [DiffHunk] = []
        for hunk in rawHunks {
            if var last = merged.last {
                let origGap = hunk.origRange.lowerBound - last.origRange.upperBound
                let editGap = hunk.editRange.lowerBound - last.editRange.upperBound
                let gapValid = origGap >= 0 && editGap >= 0
                let gapSlice = gapValid
                    ? a[last.origRange.upperBound ..< hunk.origRange.lowerBound]
                    : [][...]
                let gapHasPunct = gapSlice.contains {
                    punctuationAndWhitespace.contains($0)
                }
                let gapIsSmall = gapValid && origGap <= 1 && editGap <= 1 && !gapHasPunct
                let gapIsSameASCIIWord = gapValid
                    && origGap <= 8 && editGap <= 8
                    && !gapSlice.isEmpty
                    && gapSlice.allSatisfy(isASCIIWordChar)
                if gapIsSmall || gapIsSameASCIIWord {
                    last.origRange = last.origRange.lowerBound ..< hunk.origRange.upperBound
                    last.editRange = last.editRange.lowerBound ..< hunk.editRange.upperBound
                    merged[merged.count - 1] = last
                    continue
                }
            }
            merged.append(hunk)
        }
        return merged
    }

    // MARK: - Hunk Expansion & Verification

    private static func buildVerifiedCorrection(
        origChars: [Character],
        editChars: [Character],
        hunk: DiffHunk,
        hintedRimePhrase: String?,
        hintedRimePinyin: String?
    ) -> VoiceLearnedCorrection? {
        let rawOld = String(origChars[hunk.origRange])
        let rawNew = String(editChars[hunk.editRange])

        // Reject pure deletions (user removing words) unless it's ASCII space
        // collapsing (e.g. "Rime AI" -> "RimeAI").
        let isASCIISpaceCollapse = rawOld.trimmingCharacters(in: .whitespaces).isEmpty
            && rawOld.contains(" ")
            && rawNew.isEmpty
            && isAdjacentASCII(origChars, around: hunk.origRange)
            && isAdjacentASCII(editChars, around: hunk.editRange)

        if !isASCIISpaceCollapse {
            guard !rawOld.isEmpty, !rawNew.isEmpty else {
                return nil
            }
        }

        // Reject overly long edits (likely rewriting a whole clause).
        guard rawOld.count <= 16, rawNew.count <= 16 else {
            return nil
        }

        // Reject trivial 1-char grammar/pronoun swaps before expansion.
        if rawOld.count == 1 && rawNew.count == 1,
           trivialSingleCharPairs.contains("\(rawOld)|\(rawNew)")
        {
            return nil
        }

        // Expand hunk to natural lexical phrase boundaries.
        let (expandedOld, expandedNew) = expandToLexicalBounds(
            origChars: origChars,
            editChars: editChars,
            hunk: hunk,
            isASCIISpaceCollapse: isASCIISpaceCollapse,
            hintedRimePhrase: hintedRimePhrase
        )

        let wrongText = expandedOld.trimmingCharacters(in: .whitespacesAndNewlines)
        let correctedText = expandedNew.trimmingCharacters(in: .whitespacesAndNewlines)

        guard wrongText != correctedText,
              isEligibleHotword(correctedText),
              isEligibleWrongSpan(wrongText),
              !containsDigitsOnlyOrDate(wrongText, correctedText)
        else {
            return nil
        }

        // Verify that this edit looks like an ASR misrecognition correction
        // rather than a semantic mind-change.
        guard isLikelyASRCorrection(
            rawOld: rawOld,
            rawNew: rawNew,
            wrongPhrase: wrongText,
            correctedPhrase: correctedText,
            isASCIISpaceCollapse: isASCIISpaceCollapse
        ) else {
            return nil
        }

        let pinyinKeys = Self.derivePinyinKeys(
            for: correctedText,
            hintedPhrase: hintedRimePhrase,
            hintedPinyin: hintedRimePinyin
        )

        return VoiceLearnedCorrection(
            wrongText: wrongText,
            correctedText: correctedText,
            hotword: correctedText,
            pinyinKeys: pinyinKeys
        )
    }

    private static func expandToLexicalBounds(
        origChars: [Character],
        editChars: [Character],
        hunk: DiffHunk,
        isASCIISpaceCollapse: Bool,
        hintedRimePhrase: String?
    ) -> (String, String) {
        var oStart = hunk.origRange.lowerBound
        var oEnd = hunk.origRange.upperBound
        var eStart = hunk.editRange.lowerBound
        var eEnd = hunk.editRange.upperBound

        // 1. ASCII / mixed-alphanumeric token expansion (handles "Rime AI" ->
        // "RimeAI", "wisper" -> "Wispr", "fast api" -> "FastAPI").
        let touchesASCII = isASCIISpaceCollapse
            || origChars[oStart ..< oEnd].contains(where: isASCIIWordChar)
            || editChars[eStart ..< eEnd].contains(where: isASCIIWordChar)

        if touchesASCII {
            while oStart > 0 && eStart > 0
                && origChars[oStart - 1] == editChars[eStart - 1]
                && isASCIIWordChar(origChars[oStart - 1])
            {
                oStart -= 1
                eStart -= 1
            }
            while oEnd < origChars.count && eEnd < editChars.count
                && origChars[oEnd] == editChars[eEnd]
                && isASCIIWordChar(origChars[oEnd])
            {
                oEnd += 1
                eEnd += 1
            }
            return (
                String(origChars[oStart ..< oEnd]),
                String(editChars[eStart ..< eEnd])
            )
        }

        // 2. If user typed the replacement via RimeAI and the exact Rime phrase
        // surrounds/covers the edit range, honor Rime's lexical boundary!
        if let hinted = hintedRimePhrase?.trimmingCharacters(in: .whitespacesAndNewlines),
           hinted.count >= 2, hinted.count <= 12
        {
            let hintedChars = Array(hinted)
            let searchFrom = max(0, eEnd - hintedChars.count)
            let searchTo = min(eStart, editChars.count - hintedChars.count)
            if searchFrom <= searchTo {
                for candidateStart in searchFrom ... searchTo {
                    let candidateEnd = candidateStart + hintedChars.count
                    guard candidateStart <= eStart && candidateEnd >= eEnd else {
                        continue
                    }
                    if Array(editChars[candidateStart ..< candidateEnd]) == hintedChars {
                        let leftDelta = eStart - candidateStart
                        let rightDelta = candidateEnd - eEnd
                        let newOStart = oStart - leftDelta
                        let newOEnd = oEnd + rightDelta
                        if newOStart >= 0 && newOEnd <= origChars.count {
                            return (
                                String(origChars[newOStart ..< newOEnd]),
                                String(editChars[candidateStart ..< candidateEnd])
                            )
                        }
                    }
                }
            }
        }

        // 3. Pure Han expansion: snap to natural word boundaries when available,
        // and guarantee ≥ 2 chars for single-char fixes (e.g. "八 -> 叭" in
        // "网易八哥说" -> "八哥说" / "叭哥说").
        if let snapped = expandHanWithNaturalWordBounds(
            origChars: origChars,
            editChars: editChars,
            oStart: oStart,
            oEnd: oEnd,
            eStart: eStart,
            eEnd: eEnd
        ) {
            return snapped
        }

        return (
            String(origChars[oStart ..< oEnd]),
            String(editChars[eStart ..< eEnd])
        )
    }

    private static func expandHanWithNaturalWordBounds(
        origChars: [Character],
        editChars: [Character],
        oStart: Int,
        oEnd: Int,
        eStart: Int,
        eEnd: Int
    ) -> (String, String)? {
        // Compute symmetric unchanged Han room around the hunk.
        var maxLeft = 0
        while oStart - maxLeft > 0 && eStart - maxLeft > 0 {
            let oc = origChars[oStart - maxLeft - 1]
            let ec = editChars[eStart - maxLeft - 1]
            guard oc == ec, isHan(oc), !hanBoundaryStopChars.contains(oc) else {
                break
            }
            maxLeft += 1
        }
        var maxRight = 0
        while oEnd + maxRight < origChars.count && eEnd + maxRight < editChars.count {
            let oc = origChars[oEnd + maxRight]
            let ec = editChars[eEnd + maxRight]
            guard oc == ec, isHan(oc), !hanBoundaryStopChars.contains(oc) else {
                break
            }
            maxRight += 1
        }

        let coreLen = eEnd - eStart

        // First try NLTokenizer on the edited clause to respect real Chinese
        // words (e.g. "试了一下网易叭哥说" -> token "网易" vs "叭哥说").
        #if canImport(NaturalLanguage)
        let clauseStart = eStart - maxLeft
        let clauseEnd = eEnd + maxRight
        if clauseEnd > clauseStart {
            let clause = String(editChars[clauseStart ..< clauseEnd])
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = clause
            tokenizer.setLanguage(.simplifiedChinese)

            let localStart = eStart - clauseStart
            let localEnd = eEnd - clauseStart
            var tokStart = localStart
            var tokEnd = localEnd
            tokenizer.enumerateTokens(
                in: clause.startIndex ..< clause.endIndex
            ) { range, _ in
                let startOff = clause.distance(
                    from: clause.startIndex,
                    to: range.lowerBound
                )
                let endOff = clause.distance(
                    from: clause.startIndex,
                    to: range.upperBound
                )
                if startOff < localEnd && endOff > localStart {
                    tokStart = min(tokStart, startOff)
                    tokEnd = max(tokEnd, endOff)
                }
                return true
            }
            let leftDelta = localStart - tokStart
            let rightDelta = tokEnd - localEnd
            let snappedLen = tokEnd - tokStart
            if snappedLen >= 2 && snappedLen <= 8
                && leftDelta <= maxLeft && rightDelta <= maxRight
            {
                return (
                    String(origChars[(oStart - leftDelta) ..< (oEnd + rightDelta)]),
                    String(editChars[(eStart - leftDelta) ..< (eEnd + rightDelta)])
                )
            }
        }
        #endif

        // If already ≥ 2 chars and not fragmented, check if 1 trailing/leading
        // unsplit Han neighbor completes a short 2-3 char term (e.g. "八哥" + "说"
        // when clause ends at "说").
        if coreLen >= 2 {
            // If NLTokenizer didn't expand and coreLen is already ≥ 2, keep it
            // tight (unless maxRight == 1 and clause ends immediately, e.g.
            // "八哥" -> "叭哥" followed by single char "说" before comma).
            if coreLen == 2 && maxRight == 1 && maxLeft == 0 {
                return (
                    String(origChars[oStart ..< (oEnd + 1)]),
                    String(editChars[eStart ..< (eEnd + 1)])
                )
            }
            return (
                String(origChars[oStart ..< oEnd]),
                String(editChars[eStart ..< eEnd])
            )
        }

        // Single-char edit: expand to form a clean 2–4 char phrase.
        // Prefer expanding right first (Chinese proper nouns often fix the
        // first character, e.g. "八哥说" -> "叭哥说" where "网易" precedes it
        // and "哥说" follows up to punctuation).
        var takeLeft = 0
        var takeRight = 0
        if maxRight > 0 && maxRight <= 3 {
            takeRight = maxRight
        } else if maxRight > 3 {
            takeRight = 2
        }
        if coreLen + takeRight < 2 && maxLeft > 0 {
            takeLeft = min(maxLeft, 2)
        }

        let finalLen = coreLen + takeLeft + takeRight
        guard finalLen >= 2 && finalLen <= 8 else {
            return nil
        }
        return (
            String(origChars[(oStart - takeLeft) ..< (oEnd + takeRight)]),
            String(editChars[(eStart - takeLeft) ..< (eEnd + takeRight)])
        )
    }

    // MARK: - ASR Error Verification (Phonetic & Similarity)

    private static func isLikelyASRCorrection(
        rawOld: String,
        rawNew: String,
        wrongPhrase: String,
        correctedPhrase: String,
        isASCIISpaceCollapse: Bool
    ) -> Bool {
        if isASCIISpaceCollapse {
            return asciiSkeleton(wrongPhrase) == asciiSkeleton(correctedPhrase)
                && asciiSkeleton(correctedPhrase).count >= 3
        }

        let oldHasHan = wrongPhrase.contains(where: isHan)
        let newHasHan = correctedPhrase.contains(where: isHan)
        let oldHasASCII = wrongPhrase.contains(where: isASCIILetter)
        let newHasASCII = correctedPhrase.contains(where: isASCIILetter)

        // Case 1: Pure Chinese Han -> Pure Chinese Han
        if oldHasHan && newHasHan && !oldHasASCII && !newHasASCII {
            // Check phonetic similarity on the changed core AND overall phrase.
            if areChinesePhoneticallySimilar(rawOld, rawNew) {
                return true
            }
            if wrongPhrase.count == correctedPhrase.count,
               wrongPhrase.count >= 2,
               areChinesePhoneticallySimilar(wrongPhrase, correctedPhrase)
            {
                return true
            }
            return false
        }

        // Case 2: ASCII / Mixed English -> ASCII / Mixed English
        if oldHasASCII && newHasASCII && !oldHasHan && !newHasHan {
            let oldSkel = asciiSkeleton(wrongPhrase)
            let newSkel = asciiSkeleton(correctedPhrase)
            if oldSkel == newSkel {
                // Casing / spacing / hyphen normalization (e.g. "rime ai" -> "RimeAI").
                return true
            }
            // Small spelling / phonetic edit (e.g. "wisper" -> "Wispr",
            // "claude" -> "Clawd", "pyton" -> "Python").
            let maxLen = max(oldSkel.count, newSkel.count)
            guard maxLen >= 3 else {
                return false
            }
            let dist = levenshteinDistance(Array(oldSkel), Array(newSkel))
            let ratio = Double(dist) / Double(maxLen)
            return dist <= 2 || ratio <= 0.4
        }

        // Case 3: Cross-script transliteration fix — very common in Chinese
        // ASR (e.g. "克劳德" -> "Claude", "威斯帕" -> "Wispr", "雷姆AI" -> "RimeAI").
        // Allow short Han/mixed span replaced by an ASCII/mixed proper noun
        // (length 2...16) when phonetic skeleton or bounded substitution fits.
        if (oldHasHan && newHasASCII) || (oldHasASCII && newHasHan) {
            guard wrongPhrase.count <= 12, correctedPhrase.count <= 16 else {
                return false
            }
            // Require phonetic plausibility: compare Chinese pinyin skeleton
            // against English ASCII skeleton (or shared ASCII suffix/prefix like
            // "雷姆AI" -> "RimeAI").
            if hasSharedASCIISubstring(wrongPhrase, correctedPhrase, minLength: 2) {
                return true
            }
            let hanPart = oldHasHan ? wrongPhrase : correctedPhrase
            let asciiPart = newHasASCII ? correctedPhrase : wrongPhrase
            if areCrossScriptPhoneticallyPlausible(
                han: hanPart,
                ascii: asciiPart
            ) {
                return true
            }
            return false
        }

        return false
    }

    // MARK: - Mandarin Phonetic Helpers (Foundation CFStringTransform)

    static func mandarinSyllables(for text: String) -> [String] {
        var syllables: [String] = []
        for ch in text where isHan(ch) {
            let s = String(ch)
            guard let latin = s.applyingTransform(
                .mandarinToLatin,
                reverse: false
            ),
            let stripped = latin.applyingTransform(
                .stripDiacritics,
                reverse: false
            ) else {
                return []
            }
            let cleaned = stripped
                .lowercased()
                .filter { $0 >= "a" && $0 <= "z" }
            if cleaned.isEmpty {
                return []
            }
            syllables.append(cleaned)
        }
        return syllables
    }

    /// Converts a string's Han characters into toneless lowercase Mandarin syllables,
    /// transforming each contiguous Han run in phrase context so polyphones (such as
    /// `重复` or `行长`) match natural context, and falling back per-character if needed.
    static func contextualMandarinSyllables(for text: String) -> [String] {
        var result: [String] = []
        var hanRun: [Character] = []

        func flushHanRun() -> Bool {
            guard !hanRun.isEmpty else {
                return true
            }
            if hanRun.count > 1,
               let latin = String(hanRun).applyingTransform(
                   .mandarinToLatin,
                   reverse: false
               ),
               let stripped = latin.applyingTransform(
                   .stripDiacritics,
                   reverse: false
               )
            {
                let tokens = stripped
                    .split(whereSeparator: \.isWhitespace)
                    .map { token in
                        String(token.lowercased().filter { $0 >= "a" && $0 <= "z" })
                    }
                    .filter { !$0.isEmpty }
                if tokens.count == hanRun.count {
                    result.append(contentsOf: tokens)
                    hanRun.removeAll(keepingCapacity: true)
                    return true
                }
            }
            for ch in hanRun {
                guard let single = mandarinSyllables(for: String(ch)).first else {
                    return false
                }
                result.append(single)
            }
            hanRun.removeAll(keepingCapacity: true)
            return true
        }

        for ch in text {
            if isHan(ch) {
                hanRun.append(ch)
            } else if !flushHanRun() {
                return []
            }
        }
        guard flushHanRun() else {
            return []
        }
        return result
    }

    /// Normalizes common Mandarin ASR fuzzy pairs (retroflex zh/ch/sh, n/l,
    /// f/h, -n/-ng) so near-homophone slips still register as phonetic matches.
    static func fuzzyMandarinSkeleton(_ syllable: String) -> String {
        var s = syllable.lowercased()
        // Initials
        if s.hasPrefix("zh") {
            s = "z" + s.dropFirst(2)
        } else if s.hasPrefix("ch") {
            s = "c" + s.dropFirst(2)
        } else if s.hasPrefix("sh") {
            s = "s" + s.dropFirst(2)
        } else if s.hasPrefix("n") && s.count >= 2 {
            s = "l" + s.dropFirst(1)
        } else if s.hasPrefix("r") && s.count >= 2 {
            s = "l" + s.dropFirst(1)
        } else if s.hasPrefix("f") && s.count >= 2 {
            s = "h" + s.dropFirst(1)
        }
        // Finals (-ng -> -n)
        if s.hasSuffix("ng") && s.count >= 3 {
            s = String(s.dropLast(1))
        }
        return s
    }

    static func areChinesePhoneticallySimilar(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        let s1 = mandarinSyllables(for: lhs)
        let s2 = mandarinSyllables(for: rhs)
        guard !s1.isEmpty, s1.count == s2.count else {
            return false
        }
        var similarCount = 0
        for (a, b) in zip(s1, s2) {
            if a == b || fuzzyMandarinSkeleton(a) == fuzzyMandarinSkeleton(b) {
                similarCount += 1
                continue
            }
            // Allow 1-edit-distance on longer syllables (e.g. "biao" vs "piao",
            // "ge" vs "ke" — voiced/unvoiced stop confusion in ASR).
            let aChars = Array(a)
            let bChars = Array(b)
            if isVoicingSwapPair(a, b) {
                similarCount += 1
                continue
            }
            if max(aChars.count, bChars.count) >= 3,
               levenshteinDistance(aChars, bChars) == 1,
               aChars.last == bChars.last
            {
                similarCount += 1
            }
        }
        // For 1-2 syllable edits, every syllable must be phonetically similar;
        // for ≥ 3 syllables, allow at most 1 non-matching syllable (≥ 66%).
        if s1.count <= 2 {
            return similarCount == s1.count
        }
        return Double(similarCount) / Double(s1.count) >= 0.66
    }

    private static func isVoicingSwapPair(_ a: String, _ b: String) -> Bool {
        let pairs: [(String, String)] = [
            ("b", "p"), ("d", "t"), ("g", "k"),
            ("j", "q"), ("z", "c"), ("zh", "ch"),
        ]
        for (x, y) in pairs {
            if a.hasPrefix(x) && b.hasPrefix(y)
                && a.dropFirst(x.count) == b.dropFirst(y.count)
            {
                return true
            }
            if a.hasPrefix(y) && b.hasPrefix(x)
                && a.dropFirst(y.count) == b.dropFirst(x.count)
            {
                return true
            }
        }
        return false
    }

    private static func areCrossScriptPhoneticallyPlausible(
        han: String,
        ascii: String
    ) -> Bool {
        let syllables = mandarinSyllables(for: han)
        let asciiSkel = asciiSkeleton(ascii)
        guard !syllables.isEmpty, asciiSkel.count >= 2 else {
            return false
        }
        let pinyinJoined = syllables.joined()
        let pConsonants = consonantSkeleton(pinyinJoined)
        let aConsonants = consonantSkeleton(asciiSkel)
        guard !pConsonants.isEmpty, !aConsonants.isEmpty else {
            return false
        }
        // Check consonant overlap / edit similarity (e.g. "kelaode" -> "kld" vs
        // "claude" -> "cld"; "weisipa" -> "wsp" vs "wispr" -> "wspr").
        let normalizedP = normalizeCrossScriptConsonants(pConsonants)
        let normalizedA = normalizeCrossScriptConsonants(aConsonants)
        let dist = levenshteinDistance(Array(normalizedP), Array(normalizedA))
        let maxLen = max(normalizedP.count, normalizedA.count)
        return maxLen > 0 && Double(dist) / Double(maxLen) <= 0.5
    }

    private static func consonantSkeleton(_ s: String) -> String {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        return String(s.lowercased().filter { $0 >= "a" && $0 <= "z" && !vowels.contains($0) })
    }

    private static func normalizeCrossScriptConsonants(_ s: String) -> String {
        s.replacingOccurrences(of: "c", with: "k")
            .replacingOccurrences(of: "q", with: "k")
            .replacingOccurrences(of: "v", with: "w")
            .replacingOccurrences(of: "r", with: "l")
            .replacingOccurrences(of: "p", with: "b")
            .replacingOccurrences(of: "t", with: "d")
            .replacingOccurrences(of: "f", with: "h")
    }

    private static func hasSharedASCIISubstring(
        _ lhs: String,
        _ rhs: String,
        minLength: Int
    ) -> Bool {
        let l = asciiSkeleton(lhs)
        let r = asciiSkeleton(rhs)
        guard l.count >= minLength, r.count >= minLength else {
            return false
        }
        let lChars = Array(l)
        for start in 0 ... (lChars.count - minLength) {
            let sub = String(lChars[start ..< (start + minLength)])
            if r.contains(sub) {
                return true
            }
        }
        return false
    }

    // MARK: - Eligibility & Safety Guards

    private static func isEligibleHotword(_ value: String) -> Bool {
        let normalized = RimeAISettingsStore.normalizedVoiceCustomHotwords([value])
        guard let candidate = normalized.first, candidate == value else {
            return false
        }
        // Reject pure numbers, URLs, emails, paths, or punctuation-heavy strings.
        let hasLetterOrHan = value.contains { isHan($0) || isASCIILetter($0) }
        guard hasLetterOrHan else {
            return false
        }
        if value.contains("http") || value.contains("www.")
            || value.contains(".com") || value.contains("\\")
        {
            return false
        }
        return !isPurePunctuationOrWhitespace(value)
    }

    private static func isEligibleWrongSpan(_ value: String) -> Bool {
        guard (2 ... 32).contains(value.count),
              value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: {
                  $0.value < 0x20 || (0x7f ... 0x9f).contains($0.value)
              })
        else {
            return false
        }
        return value.contains { isHan($0) || isASCIILetter($0) }
    }

    private static func containsDigitsOnlyOrDate(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        // Use ASCII digits only (0-9): Unicode `Character.isNumber` includes
        // Chinese numerals like "八" / "三" which appear in ordinary words
        // ("八哥说", "张三").
        let digitsL = lhs.filter(isASCIIDigit)
        let digitsR = rhs.filter(isASCIIDigit)
        // If digits changed (e.g. "2025年" -> "2026年", "3点" -> "4点"), that's
        // almost always a factual/numeric edit rather than a dictionary word,
        // unless it's a versioned tech term where letters dominate (e.g. Qwen3).
        if digitsL != digitsR {
            let lettersR = rhs.filter(isASCIILetter).count
            if lettersR < 3 || digitsL.count > 2 || digitsR.count > 2 {
                return true
            }
        }
        return false
    }

    private static func isASCIIDigit(_ ch: Character) -> Bool {
        guard ch.isASCII, let scalar = ch.unicodeScalars.first else {
            return false
        }
        return (48 ... 57).contains(scalar.value)
    }

    /// Derives lowercase toneless pinyin / ASCII letter keys for a phrase, preferring an
    /// explicit Rime hint when present and otherwise reading contiguous Han runs in context.
    public static func derivePinyinKeys(
        for phrase: String,
        hintedPhrase: String? = nil,
        hintedPinyin: String? = nil
    ) -> String? {
        if let hintedPhrase,
           let hintedPinyin,
           hintedPhrase == phrase
        {
            let cleaned = hintedPinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
            if !cleaned.isEmpty && cleaned.count <= 64 {
                return cleaned
            }
        }
        var keys = ""
        var hanRun: [Character] = []

        func flushHanRun() -> Bool {
            guard !hanRun.isEmpty else {
                return true
            }
            let syllables = contextualMandarinSyllables(for: String(hanRun))
            guard syllables.count == hanRun.count else {
                return false
            }
            for syllable in syllables {
                keys.append(syllable)
            }
            hanRun.removeAll(keepingCapacity: true)
            return true
        }

        for ch in phrase {
            if isHan(ch) {
                hanRun.append(ch)
            } else {
                guard flushHanRun() else {
                    return nil
                }
                if isASCIILetter(ch) {
                    keys.append(ch.lowercased())
                }
            }
        }
        guard flushHanRun(), keys.count >= 2 && keys.count <= 64 else {
            return nil
        }
        return keys
    }

    // MARK: - Character & Distance Utilities

    private static func asciiSkeleton(_ text: String) -> String {
        String(
            text.lowercased().filter { ch in
                isASCIIWordChar(ch) && ch != "-" && ch != "_" && ch != "."
            }
        )
    }

    static func isHan(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            return false
        }
        return (0x4E00 ... 0x9FFF).contains(scalar.value)
            || (0x3400 ... 0x4DBF).contains(scalar.value)
    }

    private static func isASCIILetter(_ ch: Character) -> Bool {
        guard ch.isASCII, let scalar = ch.unicodeScalars.first else {
            return false
        }
        return (65 ... 90).contains(scalar.value)
            || (97 ... 122).contains(scalar.value)
    }

    private static func isASCIIWordChar(_ ch: Character) -> Bool {
        guard ch.isASCII, let scalar = ch.unicodeScalars.first else {
            return false
        }
        return (48 ... 57).contains(scalar.value)
            || (65 ... 90).contains(scalar.value)
            || (97 ... 122).contains(scalar.value)
            || ch == "-" || ch == "_" || ch == "+" || ch == "."
    }

    private static func isAdjacentASCII(
        _ chars: [Character],
        around range: Range<Int>
    ) -> Bool {
        let leftASCII = range.lowerBound > 0
            && isASCIIWordChar(chars[range.lowerBound - 1])
        let rightASCII = range.upperBound < chars.count
            && isASCIIWordChar(chars[range.upperBound])
        return leftASCII && rightASCII
    }

    private static func isPurePunctuationOrWhitespace(_ text: String) -> Bool {
        text.allSatisfy { punctuationAndWhitespace.contains($0) }
    }

    static func levenshteinDistance(
        _ a: [Character],
        _ b: [Character]
    ) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0 ... b.count)
        var curr = Array(repeating: 0, count: b.count + 1)
        for i in 1 ... a.count {
            curr[0] = i
            for j in 1 ... b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,
                    min(curr[j - 1] + 1, prev[j - 1] + cost)
                )
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
