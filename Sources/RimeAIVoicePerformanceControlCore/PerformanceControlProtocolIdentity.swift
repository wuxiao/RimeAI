import Foundation

public struct PerformanceControlProtocolIdentity: Hashable, Sendable {
    public static let requiredID = "rimeai-performance-control-v2"

    public let id: String
    public let sha256: String

    public init(
        id: String = Self.requiredID,
        sha256: String
    ) throws {
        guard id == Self.requiredID,
              sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ byte in
                  (0x30 ... 0x39).contains(byte)
                      || (0x61 ... 0x66).contains(byte)
              })
        else {
            throw PerformanceControlError.invalidProtocolIdentity
        }
        self.id = id
        self.sha256 = sha256
    }
}
