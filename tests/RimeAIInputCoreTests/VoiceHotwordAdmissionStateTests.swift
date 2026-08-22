import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("Voice hotword admission state")
struct VoiceHotwordAdmissionStateTests {
    @Test
    func eligibleSuccessfulRimeCommitAppearsInSnapshot() throws {
        var state = VoiceHotwordAdmissionState()
        let session = VoiceHotwordAdmissionSession(
            applicationIdentifier: "com.example.editor",
            controllerSessionIdentifier: "controller-a",
            focusEpoch: 1
        )

        state.activate(session: session, policy: .eligible)
        state.recordRimeCommitResult("  ＡＰＩ  ", session: session)

        #expect(state.snapshot(session: session).phrases == ["API"])
    }

    @Test
    func keepsExactlyTheNewest128Commits() {
        var state = VoiceHotwordAdmissionState()
        let session = makeSession()
        state.activate(session: session, policy: .eligible)

        for index in 0 ..< VoiceDictationConstants.maximumHotwordCount {
            state.recordRimeCommitResult(
                String(format: "术语%03d", index),
                session: session
            )
        }

        let phrases = state.snapshot(session: session).phrases
        #expect(phrases.count == 128)
        #expect(phrases.first == "术语127")
        #expect(phrases.last == "术语000")
    }

    @Test
    func commit129EvictsOnlyTheOldestCommit() {
        var state = VoiceHotwordAdmissionState()
        let session = makeSession()
        state.activate(session: session, policy: .eligible)

        for index in 0 ... VoiceDictationConstants.maximumHotwordCount {
            state.recordRimeCommitResult(
                String(format: "术语%03d", index),
                session: session
            )
        }

        let phrases = state.snapshot(session: session).phrases
        #expect(phrases.count == 128)
        #expect(phrases.first == "术语128")
        #expect(phrases.last == "术语001")
        #expect(!phrases.contains("术语000"))
    }

    @Test
    func duplicateCommitMovesNormalizedPhraseToFront() {
        var state = VoiceHotwordAdmissionState()
        let session = makeSession()
        state.activate(session: session, policy: .eligible)
        state.recordRimeCommitResult("接口", session: session)
        state.recordRimeCommitResult("模型", session: session)

        state.recordRimeCommitResult("  接口  ", session: session)

        #expect(
            state.snapshot(session: session).phrases == ["接口", "模型"]
        )
    }

    @Test
    func applicationControllerSessionAndFocusBoundariesAreIsolated() {
        let origin = makeSession()
        let otherBoundaries = [
            makeSession(applicationIdentifier: "com.example.chat"),
            makeSession(controllerSessionIdentifier: "controller-b"),
            makeSession(focusEpoch: 2),
        ]

        for other in otherBoundaries {
            var state = VoiceHotwordAdmissionState()
            state.activate(session: origin, policy: .eligible)
            state.recordRimeCommitResult("接口", session: origin)

            #expect(state.snapshot(session: other).isEmpty)
            state.activate(session: other, policy: .eligible)
            #expect(state.snapshot(session: other).isEmpty)
            state.activate(session: origin, policy: .eligible)
            #expect(state.snapshot(session: origin).isEmpty)
        }
    }

    @Test
    func deactivateErasesSessionAndPhrases() {
        var state = VoiceHotwordAdmissionState()
        let session = makeSession()
        state.activate(session: session, policy: .eligible)
        state.recordRimeCommitResult("接口", session: session)

        state.deactivate()

        #expect(state.snapshot(session: session).isEmpty)
        state.activate(session: session, policy: .eligible)
        #expect(state.snapshot(session: session).isEmpty)
    }

    @Test
    func enteringSecureInputErasesAndBlocksHotwords() {
        var state = VoiceHotwordAdmissionState()
        let session = makeSession()
        state.activate(session: session, policy: .eligible)
        state.recordRimeCommitResult("接口", session: session)

        state.enterSecureInput()
        state.recordRimeCommitResult("模型", session: session)

        #expect(state.snapshot(session: session).isEmpty)
        state.activate(session: session, policy: .eligible)
        #expect(state.snapshot(session: session).isEmpty)
    }

    @Test
    func everyPrivacyGateErasesAndCannotResurrectPriorPhrases() {
        let blockedPolicies = [
            makePolicy(isVoiceEnabled: false),
            makePolicy(isAIAllowed: false),
            makePolicy(isHotwordAssistEnabled: false),
            makePolicy(contextPolicy: .strict),
            makePolicy(isSecureInput: true),
        ]

        for blockedPolicy in blockedPolicies {
            var state = VoiceHotwordAdmissionState()
            let session = makeSession()
            state.activate(session: session, policy: .eligible)
            state.recordRimeCommitResult("旧词", session: session)

            state.updatePolicy(blockedPolicy)
            state.recordRimeCommitResult("新词", session: session)
            #expect(state.snapshot(session: session).isEmpty)

            state.updatePolicy(.eligible)
            #expect(state.snapshot(session: session).isEmpty)
        }
    }

    @Test
    func explicitClearCannotResurrectOldPhrasesAndAllowsFreshCommits() {
        var state = VoiceHotwordAdmissionState()
        let session = makeSession()
        state.activate(session: session, policy: .eligible)
        state.recordRimeCommitResult("旧词", session: session)

        state.clear()
        state.updatePolicy(.eligible)

        #expect(state.snapshot(session: session).isEmpty)
        state.recordRimeCommitResult("新词", session: session)
        #expect(state.snapshot(session: session).phrases == ["新词"])
    }

    @Test
    func onlySuccessfulMatchingRimeCommitResultsAreRecorded() {
        var state = VoiceHotwordAdmissionState()
        let session = makeSession()
        state.activate(session: session, policy: .eligible)

        state.recordRimeCommitResult(nil, session: session)
        state.recordRimeCommitResult(
            "回退候选",
            matching: "语义候选",
            session: session
        )
        #expect(state.snapshot(session: session).isEmpty)

        state.recordRimeCommitResult(
            "语义候选",
            matching: "语义候选",
            session: session
        )
        #expect(state.snapshot(session: session).phrases == ["语义候选"])
    }
}

private extension VoiceHotwordAdmissionPolicy {
    static let eligible = VoiceHotwordAdmissionPolicy(
        isVoiceEnabled: true,
        isAIAllowed: true,
        isHotwordAssistEnabled: true,
        contextPolicy: .standard,
        isSecureInput: false
    )
}

private func makeSession(
    applicationIdentifier: String = "com.example.editor",
    controllerSessionIdentifier: String = "controller-a",
    focusEpoch: UInt64 = 1
) -> VoiceHotwordAdmissionSession {
    VoiceHotwordAdmissionSession(
        applicationIdentifier: applicationIdentifier,
        controllerSessionIdentifier: controllerSessionIdentifier,
        focusEpoch: focusEpoch
    )
}

private func makePolicy(
    isVoiceEnabled: Bool = true,
    isAIAllowed: Bool = true,
    isHotwordAssistEnabled: Bool = true,
    contextPolicy: ContextPolicy = .standard,
    isSecureInput: Bool = false
) -> VoiceHotwordAdmissionPolicy {
    VoiceHotwordAdmissionPolicy(
        isVoiceEnabled: isVoiceEnabled,
        isAIAllowed: isAIAllowed,
        isHotwordAssistEnabled: isHotwordAssistEnabled,
        contextPolicy: contextPolicy,
        isSecureInput: isSecureInput
    )
}
