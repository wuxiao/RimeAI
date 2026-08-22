import Darwin
import Foundation
import Testing
@testable import RimeAIVoicePerformanceTracerHelperProcess

@Suite("Voice performance tracer helper home directory")
struct VoicePerformanceTracerHelperHomeDirectoryTests {
    @Test("layout root comes from getpwuid identity, never HOME")
    func resolvesEffectiveUserRecord() throws {
        let system = FakeHelperUserRecordSystem(
            effectiveUserID: 501,
            homeDirectory: "/Users/measured-user"
        )

        let url = try VoicePerformanceTracerHomeDirectoryResolver(
            system: system
        ).resolve()

        #expect(url.path == "/Users/measured-user")
        #expect(system.requestedUserIDs == [501])
    }

    @Test("relative, root, and normalized-splice home paths fail closed")
    func rejectsNonCanonicalHomeDirectory() {
        for path in [
            "Users/measured-user",
            "/",
            "/Users/../private/tmp",
            "/Users//measured-user",
        ] {
            let system = FakeHelperUserRecordSystem(
                effectiveUserID: 501,
                homeDirectory: path
            )
            #expect(throws: (any Error).self) {
                _ = try VoicePerformanceTracerHomeDirectoryResolver(
                    system: system
                ).resolve()
            }
        }
    }
}

private final class FakeHelperUserRecordSystem:
    VoicePerformanceTracerUserRecordSystem,
    @unchecked Sendable
{
    let effectiveUserID: uid_t
    let homeDirectory: String
    private(set) var requestedUserIDs: [uid_t] = []

    init(effectiveUserID: uid_t, homeDirectory: String) {
        self.effectiveUserID = effectiveUserID
        self.homeDirectory = homeDirectory
    }

    func homeDirectory(for userID: uid_t) throws -> String {
        requestedUserIDs.append(userID)
        return homeDirectory
    }
}
