import Foundation

public enum PerformanceControlError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidFrame
    case frameTooLarge
    case carriageReturnForbidden
    case nonCanonicalJSON
    case invalidProtocolIdentity
    case invalidNonce
    case invalidSHA256
    case invalidEngineSummary
    case invalidDriverPolicy
    case controlProtocolMismatch
    case unsupportedQualification
    case invalidHelperGeneration
    case unauthorizedDirection
    case invalidTransition
    case sequenceViolation
    case bindingMismatch
    case trialReplay
    case ticketReplay
    case generationReuse
    case artifactGenerationReuse
}

public struct ControlledPerformanceID: Hashable, Sendable {
    public static let maximumUTF8Bytes = 128

    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue == rawValue.precomposedStringWithCanonicalMapping,
              !rawValue.isEmpty,
              rawValue.utf8.count <= Self.maximumUTF8Bytes,
              let first = rawValue.utf8.first,
              Self.isASCIIAlphaNumeric(first),
              rawValue.utf8.dropFirst().allSatisfy({ byte in
                  Self.isASCIIAlphaNumeric(byte)
                      || byte == 0x2D
                      || byte == 0x2E
                      || byte == 0x5F
              })
        else {
            throw PerformanceControlError.invalidIdentifier
        }
        self.rawValue = rawValue
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x5A).contains(byte)
            || (0x61 ... 0x7A).contains(byte)
    }
}

public struct PerformanceControlNonce: Hashable, Sendable {
    public static let encodedLength = 64

    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.utf8.count == Self.encodedLength,
              rawValue.utf8.allSatisfy({ byte in
                  (0x30 ... 0x39).contains(byte)
                      || (0x61 ... 0x66).contains(byte)
              })
        else {
            throw PerformanceControlError.invalidNonce
        }
        self.rawValue = rawValue
    }
}

public struct PerformanceControlSHA256: Hashable, Sendable {
    public static let encodedLength = 64

    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.utf8.count == Self.encodedLength,
              rawValue.utf8.allSatisfy({ byte in
                  (0x30 ... 0x39).contains(byte)
                      || (0x61 ... 0x66).contains(byte)
              })
        else {
            throw PerformanceControlError.invalidSHA256
        }
        self.rawValue = rawValue
    }
}

public enum PerformanceControlPeerRole:
    String,
    Equatable,
    Hashable,
    Sendable
{
    case driver
    case helper
}
