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
        let transform = switch characterSet {
        case .simplified:
            traditionalToSimplified
        case .traditional:
            simplifiedToTraditional
        }
        guard let normalized = text.applyingTransform(
            transform,
            reverse: false
        ) else {
            return false
        }
        return normalized == text
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
