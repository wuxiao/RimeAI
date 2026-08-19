import Foundation

public enum TypoOperation: String, Codable, Sendable {
    case adjacentSubstitution = "adjacent_substitution"
    case insertion
    case deletion
    case transposition
}

public struct TypoVariant: Codable, Equatable, Sendable {
    public let pinyin: String
    public let operation: TypoOperation
    public let editCost: Double

    public init(
        pinyin: String,
        operation: TypoOperation,
        editCost: Double = 1
    ) {
        self.pinyin = pinyin
        self.operation = operation
        self.editCost = editCost
    }
}

public enum TypoVariantGenerator {
    public static func variants(
        for rawPinyin: String,
        maximumCount: Int = 32
    ) -> [TypoVariant] {
        let pinyin = rawPinyin.lowercased()
        guard maximumCount > 0,
              !pinyin.isEmpty,
              pinyin.utf8.count <= 256,
              pinyin.unicodeScalars.allSatisfy({
                  $0.value == 39 || (97 ... 122).contains($0.value)
              })
        else {
            return []
        }

        let characters = Array(pinyin)
        let buckets: [[TypoVariant]] = [
            transpositions(characters),
            deletions(characters),
            adjacentSubstitutions(characters),
            insertions(characters),
        ]
        var offsets = Array(repeating: 0, count: buckets.count)
        var seen = Set([pinyin])
        var result: [TypoVariant] = []

        while result.count < min(maximumCount, 32) {
            var madeProgress = false
            for index in buckets.indices {
                while offsets[index] < buckets[index].count {
                    let candidate = buckets[index][offsets[index]]
                    offsets[index] += 1
                    if seen.insert(candidate.pinyin).inserted {
                        result.append(candidate)
                        madeProgress = true
                        break
                    }
                }
                if result.count >= min(maximumCount, 32) {
                    break
                }
            }
            if !madeProgress {
                break
            }
        }
        return result
    }

    private static func transpositions(
        _ characters: [Character]
    ) -> [TypoVariant] {
        guard characters.count >= 2 else {
            return []
        }
        return (0 ..< characters.count - 1).compactMap { index in
            guard characters[index] != characters[index + 1] else {
                return nil
            }
            var value = characters
            value.swapAt(index, index + 1)
            return TypoVariant(
                pinyin: String(value),
                operation: .transposition
            )
        }
    }

    private static func deletions(
        _ characters: [Character]
    ) -> [TypoVariant] {
        guard characters.count > 1 else {
            return []
        }
        return characters.indices.map { index in
            var value = characters
            value.remove(at: index)
            return TypoVariant(
                pinyin: String(value),
                operation: .deletion
            )
        }
    }

    private static func adjacentSubstitutions(
        _ characters: [Character]
    ) -> [TypoVariant] {
        characters.indices.flatMap { index -> [TypoVariant] in
            guard let adjacent = qwertyAdjacency[characters[index]] else {
                return []
            }
            return adjacent.map { replacement in
                var value = characters
                value[index] = replacement
                return TypoVariant(
                    pinyin: String(value),
                    operation: .adjacentSubstitution
                )
            }
        }
    }

    private static func insertions(
        _ characters: [Character]
    ) -> [TypoVariant] {
        let likelyMissing: [Character] = [
            "h", "g", "n", "r", "i", "u", "a", "e", "o",
        ]
        return (0 ... characters.count).flatMap { index in
            likelyMissing.map { inserted in
                var value = characters
                value.insert(inserted, at: index)
                return TypoVariant(
                    pinyin: String(value),
                    operation: .insertion
                )
            }
        }
    }

    private static let qwertyAdjacency: [Character: [Character]] = [
        "q": ["w", "a"],
        "w": ["q", "e", "a", "s"],
        "e": ["w", "r", "s", "d"],
        "r": ["e", "t", "d", "f"],
        "t": ["r", "y", "f", "g"],
        "y": ["t", "u", "g", "h"],
        "u": ["y", "i", "h", "j"],
        "i": ["u", "o", "j", "k"],
        "o": ["i", "p", "k", "l"],
        "p": ["o", "l"],
        "a": ["q", "w", "s", "z"],
        "s": ["w", "e", "a", "d", "z", "x"],
        "d": ["e", "r", "s", "f", "x", "c"],
        "f": ["r", "t", "d", "g", "c", "v"],
        "g": ["t", "y", "f", "h", "v", "b"],
        "h": ["y", "u", "g", "j", "b", "n"],
        "j": ["u", "i", "h", "k", "n", "m"],
        "k": ["i", "o", "j", "l", "m"],
        "l": ["o", "p", "k"],
        "z": ["a", "s", "x"],
        "x": ["s", "d", "z", "c"],
        "c": ["d", "f", "x", "v"],
        "v": ["f", "g", "c", "b"],
        "b": ["g", "h", "v", "n"],
        "n": ["h", "j", "b", "m"],
        "m": ["j", "k", "n"],
    ]
}
