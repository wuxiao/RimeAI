import Foundation

/// Parsed payload of one Rime `.dict.yaml` file: header fields plus
/// normalized entries (one row per pronunciation — homographs with
/// multiple readings arrive as multiple rows and stay that way).
public struct ParsedRimeDictionary: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let text: String
        public let pinyinKeys: String
        public let weight: Int

        public init(text: String, pinyinKeys: String, weight: Int) {
            self.text = text
            self.pinyinKeys = pinyinKeys
            self.weight = weight
        }
    }

    /// Normalized dictionary id: lowercased `name` header restricted to
    /// `[a-z0-9_-]`; other characters collapse to `-`. Empty when the
    /// header is missing (install then requires a caller-supplied id).
    public let identifier: String
    public let name: String
    public let version: String
    public let entries: [Entry]
    /// Lines rejected by normalization, in `line: reason` form. Bounded
    /// to the first 20 reasons; the count is always complete.
    public let rejectedLines: [(line: Int, reason: String)]
    public let rejectedLineCount: Int

    public init(
        identifier: String,
        name: String,
        version: String,
        entries: [Entry],
        rejectedLines: [(line: Int, reason: String)],
        rejectedLineCount: Int
    ) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.entries = entries
        self.rejectedLines = rejectedLines
        self.rejectedLineCount = rejectedLineCount
    }

    /// Tuple arrays cannot synthesize `Equatable`; compare payloads
    /// and rejection counts (capped sample excluded).
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identifier == rhs.identifier
            && lhs.name == rhs.name
            && lhs.version == rhs.version
            && lhs.entries == rhs.entries
            && lhs.rejectedLineCount == rhs.rejectedLineCount
    }
}

/// Line-level parser for Rime `.dict.yaml` files. Deliberately free of a
/// YAML dependency: only the `name:` / `version:` header keys are read,
/// everything after the `...` document-end marker is treated as tab
/// separated `text \t code \t weight?` rows. Rime-percent weights
/// (`100%`) are accepted alongside plain integers.
public enum RimeDictYamlParser {
    /// Mirrors the store-side phrase limit: one lexicon may not exceed
    /// this many pronunciation rows after normalization.
    public static let maximumEntries = 200_000
    static let maximumTextUTF8Bytes = 1_024
    static let maximumPinyinKeysUTF8Bytes = 256

    public enum ParseError: Error, Equatable, Sendable {
        case emptyDocument
        case tooManyEntries(Int)
    }

    public static func parse(_ source: String) throws -> ParsedRimeDictionary {
        var name = ""
        var version = ""
        var inHeader = false
        var entries: [ParsedRimeDictionary.Entry] = []
        var seen: [String: Int] = [:]
        var rejected: [(line: Int, reason: String)] = []
        var rejectedCount = 0
        var headerEnded = false

        for (offset, rawLine) in source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if line == "---" {
                inHeader = true
                continue
            }
            if line == "..." {
                inHeader = false
                headerEnded = true
                continue
            }
            guard headerEnded, !line.isEmpty, !line.hasPrefix("#") else {
                if inHeader, line.hasPrefix("#") == false {
                    if let value = headerValue(line, key: "name") {
                        name = value
                    } else if let value = headerValue(line, key: "version") {
                        version = value
                    }
                }
                continue
            }
            guard
                let entry = normalize(
                    line,
                    at: lineNumber,
                    rejections: &rejected,
                    rejectionCount: &rejectedCount
                )
            else {
                continue
            }
            if entries.count >= maximumEntries {
                throw ParseError.tooManyEntries(maximumEntries)
            }
            // Same (text, pinyin) repeated in one file: keep the
            // strongest weight instead of duplicating the row.
            let key = "\(entry.text)\u{1F}\(entry.pinyinKeys)"
            if let existing = seen[key] {
                if entry.weight > entries[existing].weight {
                    entries[existing] = entry
                }
                continue
            }
            seen[key] = entries.count
            entries.append(entry)
        }

        guard headerEnded, !entries.isEmpty else {
            // A dict.yaml without `...` (or without rows) is not a
            // dictionary payload we can install.
            throw ParseError.emptyDocument
        }

        return ParsedRimeDictionary(
            identifier: normalizedIdentifier(name.isEmpty ? nil : name),
            name: name,
            version: version.isEmpty ? "1" : version,
            entries: entries,
            rejectedLines: Array(rejected.prefix(20)),
            rejectedLineCount: rejectedCount
        )
    }

    /// `name: foo` / `version: "1"` header extraction. Quoted values are
    /// unquoted; trailing comments are dropped.
    private static func headerValue(
        _ line: String,
        key: String
    ) -> String? {
        guard line.hasPrefix("\(key):") else {
            return nil
        }
        var value = String(line.dropFirst(key.count + 1))
            .trimmingCharacters(in: .whitespaces)
        if let comment = value.range(of: " #") {
            value = String(value[..<comment.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        if value.count >= 2,
           value.first == "\"", value.last == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    /// Tab-separated row normalization. Returns nil (and records a
    /// rejection reason) for malformed rows.
    private static func normalize(
        _ line: String,
        at lineNumber: Int,
        rejections: inout [(line: Int, reason: String)],
        rejectionCount: inout Int
    ) -> ParsedRimeDictionary.Entry? {
        let columns = line.split(
            separator: "\t",
            omittingEmptySubsequences: false
        )
        guard columns.count >= 2 else {
            reject(
                "缺少拼音列",
                at: lineNumber,
                rejections: &rejections,
                rejectionCount: &rejectionCount
            )
            return nil
        }
        let text = String(columns[0])
        guard !text.isEmpty,
              text.utf8.count <= maximumTextUTF8Bytes,
              !text.contains("\u{0000}")
        else {
            reject(
                "词条文本为空或超长",
                at: lineNumber,
                rejections: &rejections,
                rejectionCount: &rejectionCount
            )
            return nil
        }
        guard
            let pinyinKeys = normalizedPinyinKeys(String(columns[1]))
        else {
            reject(
                "拼音含非法字符（仅允许 a–z，ü 写作 v）",
                at: lineNumber,
                rejections: &rejections,
                rejectionCount: &rejectionCount
            )
            return nil
        }
        var weight = 50
        if columns.count >= 3 {
            weight = normalizedWeight(String(columns[2])) ?? 50
        }
        return ParsedRimeDictionary.Entry(
            text: text,
            pinyinKeys: pinyinKeys,
            weight: weight
        )
    }

    /// Pinyin normalization shared by the parser and the installer:
    /// lowercase, collapse whitespace, `ü` → `v`, drop separators. The
    /// result must be pure `[a-z]+` or the row is rejected.
    public static func normalizedPinyinKeys(_ raw: String) -> String? {
        var characters = [Character]()
        for scalar in raw.lowercased().unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9":
                characters.append(Character(scalar))
            case " ", "\t", "'", "-", "_", "·":
                continue
            case "ü":
                characters.append("v")
            case "\u{0308}" where characters.last == "u":
                // `u` + combining diaeresis is another spelling of ü.
                characters[characters.count - 1] = "v"
            default:
                return nil
            }
        }
        let joined = String(characters)
        guard !joined.isEmpty,
              joined.utf8.count <= maximumPinyinKeysUTF8Bytes
        else {
            return nil
        }
        return joined
    }

    /// Rime weights are relative frequencies; `100%` and `100` mean the
    /// same thing. Clamp the result to 1–99.
    public static func normalizedWeight(_ raw: String) -> Int? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix("%") {
            value.removeLast()
        }
        guard let parsed = Int(value), parsed > 0 else {
            return nil
        }
        return min(99, max(1, parsed / 10))
    }

    public static func normalizedIdentifier(_ raw: String?) -> String {
        let base = (raw ?? "")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var lastWasDash = false
        for character in base {
            if character.isASCII,
               character.isLetter || character.isNumber {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") {
            result.removeLast()
        }
        return result
    }

    private static func reject(
        _ reason: String,
        at line: Int,
        rejections: inout [(line: Int, reason: String)],
        rejectionCount: inout Int
    ) {
        rejectionCount += 1
        if rejections.count < 20 {
            rejections.append((line, reason))
        }
    }
}
