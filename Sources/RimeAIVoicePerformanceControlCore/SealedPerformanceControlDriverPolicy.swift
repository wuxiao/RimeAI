import CryptoKit
import Foundation

public enum PerformanceControlQualification:
    String,
    Equatable,
    Hashable,
    Sendable
{
    case tracer
    case production
}

public enum PerformanceControlCapability:
    String,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case authenticatedControl = "authenticated_control"
    case corpusSessions = "corpus_sessions"
    case helperGenerationRotation = "helper_generation_rotation"
    case keyboardPhases = "keyboard_phases"
    case lateChallenges = "late_challenges"
    case lazyLoadTicket = "lazy_load_ticket"
}

public struct SealedPerformanceControlDriverPolicy: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumEncodedBytes = 4_096

    public static let tracerCapabilities: [PerformanceControlCapability] = [
        .authenticatedControl,
        .lazyLoadTicket,
    ]
    public static let productionCapabilities: [PerformanceControlCapability] = [
        .authenticatedControl,
        .corpusSessions,
        .helperGenerationRotation,
        .keyboardPhases,
        .lateChallenges,
        .lazyLoadTicket,
    ]

    public let qualification: PerformanceControlQualification
    public let capabilities: [PerformanceControlCapability]
    public let controlProtocol: PerformanceControlProtocolIdentity
    public let canonicalSHA256: PerformanceControlSHA256
    public let authenticatedProductionDriver: Bool

    public static func decodeCanonical(
        _ data: Data,
        expectedControlProtocol: PerformanceControlProtocolIdentity
    ) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw PerformanceControlError.invalidDriverPolicy
        }
        guard !data.contains(0x0D) else {
            throw PerformanceControlError.carriageReturnForbidden
        }
        try PerformanceControlStrictJSON.validate(data)
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(object.keys) == [
                  "capabilities",
                  "control_protocol",
                  "qualification",
                  "schema_version",
              ],
              strictUInt(object["schema_version"]) == UInt64(schemaVersion),
              let rawQualification = object["qualification"] as? String,
              let qualification = PerformanceControlQualification(
                  rawValue: rawQualification
              ),
              let capabilityValues = object["capabilities"] as? [String],
              let protocolObject = object["control_protocol"]
                as? [String: Any],
              Set(protocolObject.keys) == ["id", "sha256"],
              let protocolID = protocolObject["id"] as? String,
              let protocolSHA256 = protocolObject["sha256"] as? String
        else {
            throw PerformanceControlError.invalidDriverPolicy
        }
        let capabilities = capabilityValues.compactMap(
            PerformanceControlCapability.init(rawValue:)
        )
        let expectedCapabilities = switch qualification {
        case .tracer: tracerCapabilities
        case .production: productionCapabilities
        }
        guard capabilities.count == capabilityValues.count,
              capabilities == expectedCapabilities
        else {
            throw PerformanceControlError.invalidDriverPolicy
        }
        let controlProtocol = try PerformanceControlProtocolIdentity(
            id: protocolID,
            sha256: protocolSHA256
        )
        guard controlProtocol == expectedControlProtocol else {
            throw PerformanceControlError.controlProtocolMismatch
        }
        let canonical = canonicalData(
            qualification: qualification,
            capabilities: capabilities,
            controlProtocol: controlProtocol
        )
        guard canonical == data else {
            throw PerformanceControlError.nonCanonicalJSON
        }
        let digest = SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
        return try Self(
            qualification: qualification,
            capabilities: capabilities,
            controlProtocol: controlProtocol,
            canonicalSHA256: PerformanceControlSHA256(digest),
            authenticatedProductionDriver: false
        )
    }

    private static func canonicalData(
        qualification: PerformanceControlQualification,
        capabilities: [PerformanceControlCapability],
        controlProtocol: PerformanceControlProtocolIdentity
    ) -> Data {
        let capabilityJSON = capabilities
            .map { "\"\($0.rawValue)\"" }
            .joined(separator: ",")
        let string = "{\"capabilities\":[\(capabilityJSON)],"
            + "\"control_protocol\":{"
            + "\"id\":\"\(controlProtocol.id)\","
            + "\"sha256\":\"\(controlProtocol.sha256)\"},"
            + "\"qualification\":\"\(qualification.rawValue)\","
            + "\"schema_version\":1}"
        return Data(string.utf8)
    }

    private static func strictUInt(_ value: Any?) -> UInt64? {
        PerformanceControlStrictJSON.uint64(value)
    }
}
