import CoreFoundation
import Foundation

enum VoiceEvaluationError: Error, Equatable, Sendable {
    case rejected
}

enum VoiceEvaluationStrictJSON {
    static func validate(
        _ data: Data,
        maximumBytes: Int,
        maximumDepth: Int,
        maximumNodes: Int
    ) throws -> Any {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw VoiceEvaluationError.rejected
        }
        var scanner = Scanner(
            data: data,
            maximumDepth: maximumDepth,
            maximumNodes: maximumNodes
        )
        try scanner.validate()
        do {
            return try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw VoiceEvaluationError.rejected
        }
    }

    static func hasExactKeys(_ value: Any, _ expected: Set<String>) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        return Set(object.keys) == expected
    }

    static func strictUInt(_ value: Any?, maximum: Int = Int.max) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number),
              number.int64Value >= 0,
              number.int64Value <= Int64(maximum)
        else { return nil }
        return number.intValue
    }

    static func strictFiniteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }

    private struct Scanner {
        private let bytes: [UInt8]
        private let maximumDepth: Int
        private let maximumNodes: Int
        private var index = 0
        private var nodes = 0

        init(data: Data, maximumDepth: Int, maximumNodes: Int) {
            bytes = Array(data)
            self.maximumDepth = maximumDepth
            self.maximumNodes = maximumNodes
        }

        mutating func validate() throws {
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else { try fail() }
        }

        private mutating func parseValue(depth: Int) throws {
            guard index < bytes.count,
                  depth <= maximumDepth,
                  nodes < maximumNodes
            else { try fail() }
            nodes += 1
            switch bytes[index] {
            case 0x7B: try parseObject(depth: depth)
            case 0x5B: try parseArray(depth: depth)
            case 0x22: _ = try parseString()
            case 0x74: try parseLiteral([0x74, 0x72, 0x75, 0x65])
            case 0x66: try parseLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
            case 0x6E: try parseLiteral([0x6E, 0x75, 0x6C, 0x6C])
            case 0x2D, 0x30 ... 0x39: try parseNumber()
            default: try fail()
            }
        }

        private mutating func parseObject(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consume(0x7D) { return }
            var keys = Set<String>()
            while true {
                guard index < bytes.count, bytes[index] == 0x22 else {
                    try fail()
                }
                let key = try parseString()
                guard keys.insert(key).inserted else { try fail() }
                skipWhitespace()
                guard consume(0x3A) else { try fail() }
                skipWhitespace()
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consume(0x7D) { return }
                guard consume(0x2C) else { try fail() }
                skipWhitespace()
            }
        }

        private mutating func parseArray(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consume(0x5D) { return }
            while true {
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consume(0x5D) { return }
                guard consume(0x2C) else { try fail() }
                skipWhitespace()
            }
        }

        private mutating func parseString() throws -> String {
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    do {
                        return try JSONDecoder().decode(
                            String.self,
                            from: Data(bytes[start ..< index])
                        )
                    } catch { try fail() }
                }
                guard byte >= 0x20 else { try fail() }
                if byte == 0x5C {
                    index += 1
                    guard index < bytes.count else { try fail() }
                    if bytes[index] == 0x75 {
                        guard index + 4 < bytes.count else { try fail() }
                        for offset in 1 ... 4
                        where !Self.isHex(bytes[index + offset]) {
                            try fail()
                        }
                        index += 5
                        continue
                    }
                    guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74]
                        .contains(bytes[index])
                    else { try fail() }
                }
                index += 1
            }
            try fail()
        }

        private mutating func parseLiteral(_ literal: [UInt8]) throws {
            guard index + literal.count <= bytes.count,
                  Array(bytes[index ..< index + literal.count]) == literal
            else { try fail() }
            index += literal.count
        }

        private mutating func parseNumber() throws {
            if consume(0x2D), index == bytes.count { try fail() }
            guard index < bytes.count else { try fail() }
            if consume(0x30) {
                if index < bytes.count, Self.isDigit(bytes[index]) { try fail() }
            } else {
                guard bytes[index] >= 0x31, bytes[index] <= 0x39 else {
                    try fail()
                }
                while index < bytes.count, Self.isDigit(bytes[index]) {
                    index += 1
                }
            }
            if consume(0x2E) {
                guard index < bytes.count, Self.isDigit(bytes[index]) else {
                    try fail()
                }
                while index < bytes.count, Self.isDigit(bytes[index]) {
                    index += 1
                }
            }
            if index < bytes.count,
               bytes[index] == 0x65 || bytes[index] == 0x45 {
                index += 1
                if index < bytes.count,
                   bytes[index] == 0x2B || bytes[index] == 0x2D {
                    index += 1
                }
                guard index < bytes.count, Self.isDigit(bytes[index]) else {
                    try fail()
                }
                while index < bytes.count, Self.isDigit(bytes[index]) {
                    index += 1
                }
            }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while index < bytes.count,
                  [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        private static func isDigit(_ byte: UInt8) -> Bool {
            (0x30 ... 0x39).contains(byte)
        }

        private static func isHex(_ byte: UInt8) -> Bool {
            isDigit(byte)
                || (0x41 ... 0x46).contains(byte)
                || (0x61 ... 0x66).contains(byte)
        }

        private func fail() throws -> Never {
            throw VoiceEvaluationError.rejected
        }
    }
}
