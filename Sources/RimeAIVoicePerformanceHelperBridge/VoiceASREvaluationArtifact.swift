import Foundation
#if canImport(RimeAIVoiceArtifactCore)
import RimeAIVoiceArtifactCore
#endif
@_spi(VoiceArtifactAdmission) import RimeAIInputCore

/// SPI-only admission boundary for evaluating one caller-selected artifact.
///
/// This deliberately bypasses the product Store, publisher, selectors, and
/// trusted release catalog. Verification and `body` are synchronous so the
/// module-owned lease is consumed only while the verified artifact is being
/// admitted into an evaluation backend.
@_spi(VoiceEvaluation)
public enum VoiceASREvaluationArtifact {
    @_spi(VoiceEvaluation)
    public static func withVerifiedArtifact<T>(
        at artifactDirectory: URL,
        verifier: any VoiceASRArtifactVerifying = VoiceASRArtifactVerifier(),
        body: (VoiceASRVerifiedArtifactLease) throws -> T
    ) throws -> T {
        let verified = try verifier.verifyArtifact(at: artifactDirectory)
        return try body(VoiceASRVerifiedArtifactLease(
            generation: UUID(),
            artifact: verified
        ))
    }
}
