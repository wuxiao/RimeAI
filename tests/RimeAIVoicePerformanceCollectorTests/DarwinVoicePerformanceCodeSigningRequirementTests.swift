import Testing
@testable import RimeAIVoicePerformanceCollector

struct DarwinVoicePerformanceCodeSigningRequirementTests {
    @Test
    func pinsDeveloperIDAnchorTeamAndExactIdentifier() throws {
        let requirement = try DarwinVoicePerformanceCodeSigningRequirement.make(
            signingIdentifier: "fun.wwcn.rimeai.voice-helper",
            teamIdentifier: "A1B2C3D4E5"
        )

        #expect(requirement == (
            "anchor apple generic"
                + " and identifier \"fun.wwcn.rimeai.voice-helper\""
                + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
                + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                + " and certificate leaf[subject.OU] = \"A1B2C3D4E5\""
        ))
    }

    @Test
    func rejectsRequirementSyntaxInjectionAndMalformedTeamIdentifiers() {
        #expect(throws: VoicePerformanceCollectorError.invalidProcessIdentity) {
            _ = try DarwinVoicePerformanceCodeSigningRequirement.make(
                signingIdentifier: "helper\" or true",
                teamIdentifier: "A1B2C3D4E5"
            )
        }
        #expect(throws: VoicePerformanceCollectorError.invalidProcessIdentity) {
            _ = try DarwinVoicePerformanceCodeSigningRequirement.make(
                signingIdentifier: "fun.wwcn.rimeai.voice-helper",
                teamIdentifier: "a1b2c3d4e5"
            )
        }
        #expect(throws: VoicePerformanceCollectorError.invalidProcessIdentity) {
            _ = try DarwinVoicePerformanceCodeSigningRequirement.make(
                signingIdentifier: "fun.wwcn.rimeai.voice_helper",
                teamIdentifier: "A1B2C3D4E5"
            )
        }
    }
}
