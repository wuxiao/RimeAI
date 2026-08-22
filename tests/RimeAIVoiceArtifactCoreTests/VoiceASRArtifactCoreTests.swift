import Testing
import RimeAIVoiceArtifactCore

struct VoiceASRArtifactCoreTests {
    @Test
    func artifactIdentifiersRemainPathSafe() {
        #expect(VoiceASRArtifactID(rawValue: "release-2026.08_1") != nil)
        #expect(VoiceASRArtifactID(rawValue: "../release") == nil)
        #expect(VoiceASRArtifactID(rawValue: "release/child") == nil)
    }

    @Test
    func verifierAndProductionLimitsAreAvailableWithoutInputCore() {
        _ = VoiceASRArtifactVerifier()
        let limits = VoiceASRArtifactVerificationLimits.production

        #expect(limits.maximumManifestBytes == 1_048_576)
        #expect(limits.maximumFileCount == 512)
    }
}
