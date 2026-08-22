import Foundation
import RimeAIVoiceArtifactCore

public struct VoicePerformanceASRArtifactVerifier:
    VoicePerformanceArtifactVerifying,
    Sendable
{
    private let verifier: VoiceASRArtifactVerifier

    public init(verifier: VoiceASRArtifactVerifier = VoiceASRArtifactVerifier()) {
        self.verifier = verifier
    }

    public func verifyArtifact(
        at artifactDirectory: URL
    ) throws -> VoicePerformanceArtifactEvidence {
        do {
            let verified = try verifier.verifyArtifact(at: artifactDirectory)
            let digest = verified.contentSHA256
            let adapterID = verified.manifest.adapter.id
            let candidateEngineID = "\(adapterID)@\(digest.prefix(16))"
            let engineID = candidateEngineID.utf8.count <= 128
                ? candidateEngineID
                : "product@\(digest.prefix(16))"
            return VoicePerformanceArtifactEvidence(
                artifactID: verified.manifest.artifactID.rawValue,
                artifactContentSHA256: digest,
                adapterID: adapterID,
                engineID: engineID,
                modelID: verified.manifest.model.id,
                modelRevision: verified.manifest.model.revision,
                verifiedPayloadBytes: verified.verifiedPayloadBytes,
                verifiedFileCount: verified.verifiedFileCount
            )
        } catch {
            throw VoicePerformanceCollectorError.invalidArtifact
        }
    }
}
