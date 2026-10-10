import Foundation

public enum RimeAICharacterSetPreference: String, Codable, Sendable {
    case simplified
    case traditional
}

public enum RimeAICharacterWidth: String, Codable, Sendable {
    case half
    case full
}

public enum RimeAIPunctuationStyle: String, Codable, Sendable {
    case chinese
    case western
}

public struct RimeAIInputPreferences: Codable, Equatable, Sendable {
    public let characterSet: RimeAICharacterSetPreference
    public let characterWidth: RimeAICharacterWidth
    public let punctuationStyle: RimeAIPunctuationStyle

    public init(
        characterSet: RimeAICharacterSetPreference = .simplified,
        characterWidth: RimeAICharacterWidth = .half,
        punctuationStyle: RimeAIPunctuationStyle = .chinese
    ) {
        self.characterSet = characterSet
        self.characterWidth = characterWidth
        self.punctuationStyle = punctuationStyle
    }
}

public enum LocalSentenceSuggestionPolicy {
    /// Skip only single-key compositions. Abbreviated pinyin such as `fjfww`
    /// must still reach the dictionary-constrained sentence decoder.
    public static let minimumPinyinLength = 2

    public static func allows(
        pinyin: String,
        characterSet: RimeAICharacterSetPreference
    ) -> Bool {
        characterSet == .simplified
            && pinyin.count >= minimumPinyinLength
    }
}

public enum SemanticCandidateScriptPolicy {
    private static let traditionalToSimplified = StringTransform(
        "Traditional-Simplified"
    )
    private static let simplifiedToTraditional = StringTransform(
        "Simplified-Traditional"
    )

    /// Keep locally generated sentence text in the script selected by the
    /// user. Rime's dictionary contains both simplified and traditional
    /// characters, so pinyin consistency alone is not sufficient here.
    public static func allows(
        text: String,
        characterSet: RimeAICharacterSetPreference
    ) -> Bool {
        guard !text.isEmpty else {
            return false
        }
        return normalized(text: text, characterSet: characterSet) == text
    }

    /// Returns the user's preferred rendering of the text: unchanged when
    /// the text already matches the script preference, otherwise converted
    /// (e.g. traditional characters simplified in place). Candidates are
    /// shown instead of being silently dropped, so this only returns nil
    /// when no acceptable rendering exists at all.
    public static func sanitized(
        text: String,
        characterSet: RimeAICharacterSetPreference
    ) -> String? {
        guard !text.isEmpty else {
            return nil
        }
        if let normalized = normalized(
            text: text,
            characterSet: characterSet
        ), normalized == text {
            return text
        }
        let transform = transform(for: characterSet)
        let converted = text.applyingTransform(transform, reverse: false)
        guard let converted,
              !converted.isEmpty,
              converted.applyingTransform(
                  transform,
                  reverse: false
              ) == converted
        else {
            return nil
        }
        return converted
    }

    private static func normalized(
        text: String,
        characterSet: RimeAICharacterSetPreference
    ) -> String? {
        text.applyingTransform(
            transform(for: characterSet),
            reverse: false
        )
    }

    private static func transform(
        for characterSet: RimeAICharacterSetPreference
    ) -> StringTransform {
        switch characterSet {
        case .simplified:
            traditionalToSimplified
        case .traditional:
            simplifiedToTraditional
        }
    }
}

public enum RimeAIInputTextTransformer {
    private static let chinesePunctuation: [UnicodeScalar: String] = [
        ",": "，",
        ".": "。",
        "?": "？",
        "!": "！",
        ":": "：",
        ";": "；",
        "(": "（",
        ")": "）",
        "[": "【",
        "]": "】",
        "<": "《",
        ">": "》",
        "\\": "、",
    ]

    /// Whether the ASCII key belongs to the punctuation table. This must be
    /// decided independently of `transformedLiteral`'s optional return:
    /// under western punctuation + half width that function returns nil for
    /// these keys, yet they still have to enter the composition instead of
    /// committing it.
    public static func isPunctuationLiteral(_ scalar: UnicodeScalar) -> Bool {
        chinesePunctuation[scalar] != nil
    }

    /// The text a printable-ASCII keystroke contributes as a composition
    /// literal segment, or nil when the key must not enter the composition.
    ///
    /// Table punctuation enters under both punctuation styles (mapped to
    /// full-width Chinese punctuation, or kept verbatim under western
    /// style). Under full width every other printable symbol also enters,
    /// stored full-width, matching what `transformedLiteral` would render.
    public static func compositionLiteralText(
        _ scalar: UnicodeScalar,
        preferences: RimeAIInputPreferences
    ) -> String? {
        guard (0x21 ... 0x7E).contains(scalar.value) else {
            return nil
        }
        if preferences.punctuationStyle == .chinese,
           let punctuation = chinesePunctuation[scalar]
        {
            return punctuation
        }
        if isPunctuationLiteral(scalar) {
            return String(Character(scalar))
        }
        if preferences.characterWidth == .full,
           let fullWidth = UnicodeScalar(scalar.value - 0x21 + 0xFF01)
        {
            return String(Character(fullWidth))
        }
        return nil
    }

    /// Returns a replacement only when the literal should be consumed by the
    /// input method. Letters remain available to the pinyin composition path.
    public static func transformedLiteral(
        _ literal: String,
        preferences: RimeAIInputPreferences
    ) -> String? {
        let scalars = Array(literal.unicodeScalars)
        guard !scalars.isEmpty,
              scalars.allSatisfy({ (0x20 ... 0x7E).contains($0.value) })
        else {
            return nil
        }

        var transformed = ""
        var didTransform = false
        for scalar in scalars {
            if preferences.punctuationStyle == .chinese,
               let punctuation = chinesePunctuation[scalar]
            {
                transformed += punctuation
                didTransform = true
                continue
            }
            if preferences.characterWidth == .full {
                if scalar.value == 0x20 {
                    transformed.unicodeScalars.append("　")
                } else if let fullWidth = UnicodeScalar(
                    scalar.value - 0x21 + 0xFF01
                ) {
                    transformed.unicodeScalars.append(fullWidth)
                }
                didTransform = true
                continue
            }
            transformed.unicodeScalars.append(scalar)
        }
        return didTransform ? transformed : nil
    }
}
