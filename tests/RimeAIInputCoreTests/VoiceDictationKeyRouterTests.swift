import Testing
@testable import RimeAIInputCore

@Suite("Voice dictation key routing")
struct VoiceDictationKeyRouterTests {
    @Test("only Carbon owns start; IMK consumes an already registered shortcut")
    func shortcutRegistrationGate() {
        #expect(decision(
            keyCode: 9,
            exactShortcut: true,
            registered: true
        ) == .consumeShortcut)
        #expect(decision(
            keyCode: 9,
            exactShortcut: true,
            registered: false
        ) == .passThrough)
    }

    @Test("shortcut auto-repeat is consumed during an active session")
    func activeShortcutIsConsumed() {
        #expect(decision(
            keyCode: 9,
            exactShortcut: true,
            registered: true,
            active: true
        ) == .consumeShortcut)
    }

    @Test(arguments: [UInt16(49), 36, 76])
    func onlySpaceAndReturnConfirm(keyCode: UInt16) {
        #expect(decision(
            keyCode: keyCode,
            active: true,
            pending: true
        ) == .confirm)
    }

    @Test(arguments: [UInt16(48), 18, 19, 20])
    func tabAndNumbersNeverConfirm(keyCode: UInt16) {
        #expect(decision(
            keyCode: keyCode,
            active: true,
            pending: true
        ) == .cancelAndContinue)
    }

    @Test(arguments: [UInt16(49), 36, 76])
    func modifiedSpaceAndReturnNeverConfirm(keyCode: UInt16) {
        #expect(decision(
            keyCode: keyCode,
            active: true,
            pending: true,
            plainConfirmation: false
        ) == .cancelAndContinue)
    }

    @Test("Escape cancels and is consumed in every active phase")
    func escapeCancels() {
        #expect(decision(
            keyCode: 53,
            active: true,
            pending: false
        ) == .cancelAndConsume)
        #expect(decision(
            keyCode: 53,
            active: true,
            pending: true
        ) == .cancelAndConsume)
    }

    @Test("ordinary keyboard input cancels voice then follows keyboard routing")
    func ordinaryInputCancelsAndContinues() {
        #expect(decision(
            keyCode: 0,
            active: true
        ) == .cancelAndContinue)
        #expect(decision(keyCode: 0) == .passThrough)
    }

    @Test("voice shortcut rejects semantic modifiers but tolerates Caps Lock")
    func voiceShortcutModifierPolicy() {
        #expect(VoiceDictationKeyRouter.isExactVoiceShortcut(
            modifiers: [.control, .shift]
        ))
        #expect(VoiceDictationKeyRouter.isExactVoiceShortcut(
            modifiers: [.capsLock, .control, .shift]
        ))
        #expect(!VoiceDictationKeyRouter.isExactVoiceShortcut(
            modifiers: [.function, .control, .shift]
        ))
        #expect(!VoiceDictationKeyRouter.isExactVoiceShortcut(
            modifiers: [.help, .control, .shift]
        ))
    }

    @Test("confirmation allows keypad metadata only, not Fn or Help")
    func confirmationModifierPolicy() {
        #expect(VoiceDictationKeyRouter.isPlainConfirmation(modifiers: []))
        #expect(VoiceDictationKeyRouter.isPlainConfirmation(
            modifiers: [.capsLock, .numericPad]
        ))
        #expect(!VoiceDictationKeyRouter.isPlainConfirmation(
            modifiers: [.function]
        ))
        #expect(!VoiceDictationKeyRouter.isPlainConfirmation(
            modifiers: [.help]
        ))
        #expect(!VoiceDictationKeyRouter.isPlainConfirmation(
            modifiers: [.command]
        ))
    }

    private func decision(
        keyCode: UInt16,
        exactShortcut: Bool = false,
        registered: Bool = false,
        active: Bool = false,
        pending: Bool = false,
        plainConfirmation: Bool = true
    ) -> VoiceDictationKeyDecision {
        VoiceDictationKeyRouter.decision(
            keyCode: keyCode,
            isExactVoiceShortcut: exactShortcut,
            shortcutRegistered: registered,
            hasActiveSession: active,
            pendingConfirmation: pending,
            isPlainConfirmationKey: plainConfirmation
        )
    }
}
