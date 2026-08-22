import Foundation

public enum PerformanceControlNetworkPolicy:
    String,
    Equatable,
    Hashable,
    Sendable
{
    case offline
}

public struct PerformanceControlArtifactGeneration: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard let uuid = UUID(uuidString: rawValue),
              rawValue == uuid.uuidString.lowercased()
        else {
            throw PerformanceControlError.invalidEngineSummary
        }
        self.rawValue = rawValue
    }
}

public struct PerformanceControlEngineSummary: Equatable, Sendable {
    public let adapterID: ControlledPerformanceID
    public let engineID: String
    public let artifactID: ControlledPerformanceID
    public let artifactContentSHA256: PerformanceControlSHA256
    public let artifactGeneration: PerformanceControlArtifactGeneration
    public let capabilities: [ControlledPerformanceID]
    public let networkPolicy: PerformanceControlNetworkPolicy
    public let maximumHotwords: UInt64

    public static func protocolEngineID(
        adapterID: ControlledPerformanceID,
        artifactContentSHA256: PerformanceControlSHA256
    ) -> String {
        let suffix = "@" + String(
            artifactContentSHA256.rawValue.prefix(16)
        )
        let candidate = adapterID.rawValue + suffix
        if candidate.utf8.count <= ControlledPerformanceID.maximumUTF8Bytes {
            return candidate
        }
        return "product" + suffix
    }

    public init(
        adapterID: ControlledPerformanceID,
        engineID: String,
        artifactID: ControlledPerformanceID,
        artifactContentSHA256: PerformanceControlSHA256,
        artifactGeneration: PerformanceControlArtifactGeneration,
        capabilities: [ControlledPerformanceID],
        networkPolicy: PerformanceControlNetworkPolicy,
        maximumHotwords: UInt64
    ) throws {
        let capabilityValues = capabilities.map(\.rawValue)
        let expectedEngineID = Self.protocolEngineID(
            adapterID: adapterID,
            artifactContentSHA256: artifactContentSHA256
        )
        guard engineID == expectedEngineID,
              capabilityValues == [
                  "hotword_snapshot", "local_asr", "streaming",
              ],
              (1 ... 128).contains(maximumHotwords)
        else {
            throw PerformanceControlError.invalidEngineSummary
        }
        self.adapterID = adapterID
        self.engineID = engineID
        self.artifactID = artifactID
        self.artifactContentSHA256 = artifactContentSHA256
        self.artifactGeneration = artifactGeneration
        self.capabilities = capabilities
        self.networkPolicy = networkPolicy
        self.maximumHotwords = maximumHotwords
    }
}

public struct ExpectedPerformanceControlEngine: Equatable, Sendable {
    public static let evaluationCapabilities = [
        "hotword_snapshot", "local_asr", "streaming",
    ]

    public let adapterID: ControlledPerformanceID
    public let engineID: String
    public let artifactID: ControlledPerformanceID
    public let artifactContentSHA256: PerformanceControlSHA256
    public let capabilities: [ControlledPerformanceID]
    public let networkPolicy: PerformanceControlNetworkPolicy
    public let maximumHotwords: UInt64

    public init(_ summary: PerformanceControlEngineSummary) {
        adapterID = summary.adapterID
        engineID = summary.engineID
        artifactID = summary.artifactID
        artifactContentSHA256 = summary.artifactContentSHA256
        capabilities = summary.capabilities
        networkPolicy = summary.networkPolicy
        maximumHotwords = summary.maximumHotwords
    }

    public init(
        adapterID: ControlledPerformanceID,
        artifactID: ControlledPerformanceID,
        artifactContentSHA256: PerformanceControlSHA256,
        maximumHotwords: UInt64
    ) throws {
        guard (1 ... 128).contains(maximumHotwords) else {
            throw PerformanceControlError.invalidEngineSummary
        }
        self.adapterID = adapterID
        engineID = PerformanceControlEngineSummary.protocolEngineID(
            adapterID: adapterID,
            artifactContentSHA256: artifactContentSHA256
        )
        self.artifactID = artifactID
        self.artifactContentSHA256 = artifactContentSHA256
        capabilities = try Self.evaluationCapabilities.map(
            ControlledPerformanceID.init
        )
        networkPolicy = .offline
        self.maximumHotwords = maximumHotwords
    }

    public func matches(_ summary: PerformanceControlEngineSummary) -> Bool {
        adapterID == summary.adapterID
            && engineID == summary.engineID
            && artifactID == summary.artifactID
            && artifactContentSHA256 == summary.artifactContentSHA256
            && capabilities == summary.capabilities
            && networkPolicy == summary.networkPolicy
            && maximumHotwords == summary.maximumHotwords
    }
}
