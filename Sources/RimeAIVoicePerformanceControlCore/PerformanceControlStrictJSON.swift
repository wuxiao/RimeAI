import Foundation

enum PerformanceControlStrictJSON {
    static let maximumDepth = 4
    static let maximumNodes = 64

    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.parseDocument()
    }

    static func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        switch String(cString: number.objCType) {
        case "s", "i", "l", "q":
            let signed = number.int64Value
            return signed >= 0 ? UInt64(signed) : nil
        case "C", "S", "I", "L", "Q":
            return number.uint64Value
        default:
            // In particular, reject ObjC bool (`c`) and floating-point
            // encodings (`f`/`d`) instead of coercing them to integers.
            return nil
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0

        mutating func parseDocument() throws {
            try parseValue(depth: 1)
            skipWhitespace()
            guard index == bytes.count else { throw invalid }
        }

        private mutating func parseValue(depth: Int) throws {
            skipWhitespace()
            guard depth <= PerformanceControlStrictJSON.maximumDepth,
                  index < bytes.count
            else {
                throw invalid
            }
            nodes += 1
            guard nodes <= PerformanceControlStrictJSON.maximumNodes else {
                throw invalid
            }

            switch bytes[index] {
            case 0x7B: // {
                try parseObject(depth: depth)
            case 0x5B: // [
                try parseArray(depth: depth)
            case 0x22: // "
                _ = try parseString()
            case 0x2D, 0x30 ... 0x39: // - or digit
                try parseNumber()
            case 0x74: // true
                try consumeLiteral([0x74, 0x72, 0x75, 0x65])
            case 0x66: // false
                try consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
            case 0x6E: // null
                try consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
            default:
                throw invalid
            }
        }

        private mutating func parseObject(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consume(0x7D) { return }

            var keys = Set<String>()
            while true {
                guard index < bytes.count, bytes[index] == 0x22 else {
                    throw invalid
                }
                let key = try parseString()
                guard keys.insert(key).inserted else { throw invalid }
                skipWhitespace()
                guard consume(0x3A) else { throw invalid }
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consume(0x7D) { return }
                guard consume(0x2C) else { throw invalid }
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
                guard consume(0x2C) else { throw invalid }
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
                    let token = Data(bytes[start ..< index])
                    guard let decoded = try? JSONSerialization.jsonObject(
                        with: token,
                        options: .fragmentsAllowed
                    ) as? String
                    else {
                        throw invalid
                    }
                    return decoded
                }
                if byte == 0x5C {
                    index += 1
                    guard index < bytes.count else { throw invalid }
                    let escape = bytes[index]
                    if escape == 0x75 {
                        guard index + 4 < bytes.count,
                              bytes[(index + 1) ... (index + 4)]
                                .allSatisfy(Self.isHexDigit)
                        else {
                            throw invalid
                        }
                        index += 5
                        continue
                    }
                    guard [0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74]
                        .contains(escape)
                    else {
                        throw invalid
                    }
                    index += 1
                    continue
                }
                guard byte >= 0x20 else { throw invalid }
                index += 1
            }
            throw invalid
        }

        private mutating func parseNumber() throws {
            _ = consume(0x2D)
            guard index < bytes.count else { throw invalid }

            if consume(0x30) {
                guard index == bytes.count || !Self.isDigit(bytes[index]) else {
                    throw invalid
                }
            } else {
                guard index < bytes.count,
                      (0x31 ... 0x39).contains(bytes[index])
                else {
                    throw invalid
                }
                index += 1
                while index < bytes.count, Self.isDigit(bytes[index]) {
                    index += 1
                }
            }

            if consume(0x2E) {
                try consumeDigits()
            }
            if index < bytes.count
                && (bytes[index] == 0x65 || bytes[index] == 0x45) {
                index += 1
                if index < bytes.count
                    && (bytes[index] == 0x2B || bytes[index] == 0x2D) {
                    index += 1
                }
                try consumeDigits()
            }
        }

        private mutating func consumeDigits() throws {
            guard index < bytes.count, Self.isDigit(bytes[index]) else {
                throw invalid
            }
            repeat {
                index += 1
            } while index < bytes.count && Self.isDigit(bytes[index])
        }

        private mutating func consumeLiteral(_ literal: [UInt8]) throws {
            guard index + literal.count <= bytes.count,
                  Array(bytes[index ..< index + literal.count]) == literal
            else {
                throw invalid
            }
            index += literal.count
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else {
                return false
            }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while index < bytes.count,
                  [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index])
            {
                index += 1
            }
        }

        private static func isDigit(_ byte: UInt8) -> Bool {
            (0x30 ... 0x39).contains(byte)
        }

        private static func isHexDigit(_ byte: UInt8) -> Bool {
            isDigit(byte)
                || (0x41 ... 0x46).contains(byte)
                || (0x61 ... 0x66).contains(byte)
        }

        private var invalid: PerformanceControlError { .invalidFrame }
    }
}
