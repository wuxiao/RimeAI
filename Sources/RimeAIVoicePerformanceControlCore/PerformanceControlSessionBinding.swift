import CryptoKit
import Foundation

public enum PerformanceControlSessionBindingError:
    Error,
    Equatable,
    Sendable
{
    case invalidTrial
}

public struct PerformanceControlSessionBinding: Equatable, Sendable {
    public static let supportedTrials = UInt64(1) ... UInt64(32)

    public let sessionID: PerformanceControlNonce
    public let planNonce: PerformanceControlNonce

    public static func derive(
        controlSessionNonce: PerformanceControlNonce,
        trial: UInt64
    ) throws -> Self {
        guard supportedTrials.contains(trial) else {
            throw PerformanceControlSessionBindingError.invalidTrial
        }

        let nonceBytes = decodeHex(controlSessionNonce.rawValue)
        return try Self(
            sessionID: digest(
                domain: "rimeai.performance-control.session.v1\0",
                nonceBytes: nonceBytes,
                trial: trial
            ),
            planNonce: digest(
                domain: "rimeai.performance-control.plan.v1\0",
                nonceBytes: nonceBytes,
                trial: trial
            )
        )
    }

    private static func digest(
        domain: String,
        nonceBytes: [UInt8],
        trial: UInt64
    ) throws -> PerformanceControlNonce {
        var input = Data(domain.utf8)
        input.append(contentsOf: nonceBytes)
        input.append(contentsOf: withUnsafeBytes(of: trial.bigEndian, Array.init))
        let encoded = SHA256.hash(data: input).map {
            String(format: "%02x", $0)
        }.joined()
        return try PerformanceControlNonce(encoded)
    }

    private static func decodeHex(_ encoded: String) -> [UInt8] {
        let bytes = Array(encoded.utf8)
        return stride(from: 0, to: bytes.count, by: 2).map { index in
            (nibble(bytes[index]) << 4) | nibble(bytes[index + 1])
        }
    }

    private static func nibble(_ byte: UInt8) -> UInt8 {
        byte <= 0x39 ? byte - 0x30 : byte - 0x61 + 10
    }
}
