import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("Voice dictation key routing")
struct VoiceDictationKeyRouterTests {
    @Test("voice shortcut defaults to Control-Shift-V")
    func defaultShortcut() {
        #expect(
            VoiceDictationShortcut.default
                == VoiceDictationShortcut(
                    keyCode: 9,
                    modifiers: [.control, .shift]
                )
        )
        #expect(VoiceDictationShortcut.default.displayName == "⌃⇧V")
    }

    @Test("unsafe shortcuts are rejected before registration")
    func unsafeShortcutsAreRejected() {
        #expect(VoiceDictationShortcut(keyCode: 0, modifiers: []) == nil)
        #expect(
            VoiceDictationShortcut(keyCode: 0, modifiers: [.shift]) == nil
        )
        #expect(
            VoiceDictationShortcut(
                keyCode: 0,
                modifiers: [.control, .function]
            ) == nil
        )
        for keyCode in [
            UInt16(36), 48, 49, 53, 55, 56, 58, 59, 63, 76, 122,
        ] {
            #expect(
                VoiceDictationShortcut(
                    keyCode: keyCode,
                    modifiers: [.control, .shift]
                ) == nil
            )
        }
    }

    @Test("shortcut combinations stay outside common editing command namespaces")
    func commonEditingCommandNamespacesAreRejected() {
        let representativeKeys: [UInt16] = [
            0, 7, 8, 9, // A, X, C, V
            12, 18, 24, 47, // Q, 1, =, .
        ]
        for keyCode in representativeKeys {
            #expect(VoiceDictationShortcut(
                keyCode: keyCode,
                modifiers: [.command]
            ) == nil)
            #expect(VoiceDictationShortcut(
                keyCode: keyCode,
                modifiers: [.command, .shift]
            ) == nil)
            #expect(VoiceDictationShortcut(
                keyCode: keyCode,
                modifiers: [.control]
            ) == nil)
            #expect(VoiceDictationShortcut(
                keyCode: keyCode,
                modifiers: [.option]
            ) == nil)
        }

        #expect(VoiceDictationShortcut(
            keyCode: 0,
            modifiers: [.control, .shift]
        ) != nil)
        #expect(VoiceDictationShortcut(
            keyCode: 0,
            modifiers: [.option, .shift]
        ) != nil)
    }

    @Test("only exact Control-Shift or Option-Shift modifier shapes are allowed")
    func modifierShapeAllowlistIsExact() {
        let ordinaryKeys: [UInt16] = [0, 18, 47] // A, 1, .
        let allowed: [VoiceDictationKeyModifiers] = [
            [.control, .shift],
            [.option, .shift],
        ]
        let rejected: [VoiceDictationKeyModifiers] = [
            [],
            [.shift],
            [.control],
            [.option],
            [.command],
            [.command, .shift],
            [.control, .option],
            [.control, .command],
            [.option, .command],
            [.control, .option, .shift],
            [.control, .shift, .command],
            [.option, .shift, .command],
            [.control, .option, .command],
            [.control, .option, .shift, .command],
        ]

        for keyCode in ordinaryKeys {
            for modifiers in allowed {
                #expect(VoiceDictationShortcut(
                    keyCode: keyCode,
                    modifiers: modifiers
                ) != nil)
            }
            for modifiers in rejected {
                #expect(VoiceDictationShortcut(
                    keyCode: keyCode,
                    modifiers: modifiers
                ) == nil)
            }
        }
    }

    @Test("VoiceOver modifier space stays reserved even with extra modifiers")
    func voiceOverModifierSpaceIsRejected() {
        let reservedModifiers: [VoiceDictationKeyModifiers] = [
            [.control, .option],
            [.control, .option, .shift],
            [.control, .option, .command],
            [.control, .option, .shift, .command],
        ]

        for modifiers in reservedModifiers {
            #expect(VoiceDictationShortcut(
                keyCode: 0,
                modifiers: modifiers
            ) == nil)
        }
    }

    @Test("system-reserved shortcuts reject modifier-superset bypasses")
    func systemReservedShortcutSupersetsAreRejected() {
        let reserved: [(keyCode: UInt16, modifiers: VoiceDictationKeyModifiers)] = [
            (20, [.shift, .command]),
            (20, [.control, .shift, .command]),
            (20, [.option, .shift, .command]),
            (21, [.shift, .command]),
            (21, [.control, .shift, .command]),
            (21, [.option, .shift, .command]),
            (23, [.shift, .command]),
            (23, [.control, .shift, .command]),
            (23, [.option, .shift, .command]),
            (12, [.control, .command]),
            (12, [.control, .shift, .command]),
            (12, [.shift, .command]),
            (12, [.option, .shift, .command]),
            (2, [.option, .command]),
            (2, [.option, .shift, .command]),
            (4, [.option, .command]),
            (4, [.option, .shift, .command]),
            (46, [.option, .command]),
            (46, [.option, .shift, .command]),
            (13, [.option, .command]),
            (13, [.option, .shift, .command]),
            (2, [.control, .command]),
            (2, [.control, .shift, .command]),
            (3, [.control, .command]),
            (3, [.control, .shift, .command]),
        ]

        for combination in reserved {
            #expect(VoiceDictationShortcut(
                keyCode: combination.keyCode,
                modifiers: combination.modifiers
            ) == nil)
        }
    }

    @Test("shortcut validation guidance explains reserved combinations")
    func shortcutValidationGuidanceIsActionable() {
        let guidance = VoiceDictationShortcut.validationFailureDescription

        #expect(guidance.contains("仅支持 Control-Shift 或 Option-Shift"))
        #expect(guidance.contains("字母、数字或标点键"))
        #expect(guidance.contains("VoiceOver"))
        #expect(guidance.contains("系统或编辑命令"))
    }

    @Test("custom shortcut matches exact semantic modifiers and event metadata")
    func customShortcutMatching() throws {
        let shortcut = try #require(
            VoiceDictationShortcut(
                keyCode: 0,
                modifiers: [.option, .shift]
            )
        )

        #expect(shortcut.displayName == "⌥⇧A")
        #expect(shortcut.matches(
            keyCode: 0,
            modifiers: [.capsLock, .numericPad, .option, .shift]
        ))
        #expect(!shortcut.matches(
            keyCode: 0,
            modifiers: [.option, .shift, .command]
        ))
        #expect(!shortcut.matches(
            keyCode: 0,
            modifiers: [.function, .option, .shift]
        ))
        #expect(!shortcut.matches(
            keyCode: 1,
            modifiers: [.option, .shift]
        ))
    }

    @Test("shortcut decoding cannot bypass validation")
    func shortcutDecodingUsesValidation() throws {
        let valid = Data(#"{"keyCode":0,"modifiers":10}"#.utf8)
        let decoded = try JSONDecoder().decode(
            VoiceDictationShortcut.self,
            from: valid
        )
        #expect(decoded.displayName == "⌥⇧A")

        for invalid in [
            #"{"keyCode":0,"modifiers":132}"#,
            #"{"keyCode":49,"modifiers":6}"#,
            #"{"keyCode":255,"modifiers":6}"#,
            #"{"keyCode":0,"modifiers":12}"#,
            #"{"keyCode":0,"modifiers":24}"#,
            #"{"keyCode":20,"modifiers":22}"#,
            #"{"keyCode":12,"modifiers":20}"#,
        ] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    VoiceDictationShortcut.self,
                    from: Data(invalid.utf8)
                )
            }
        }
    }

    @Test("router matches the configured shortcut instead of a fixed key")
    func routerUsesConfiguredShortcut() throws {
        let shortcut = try #require(
            VoiceDictationShortcut(keyCode: 0, modifiers: [.control, .shift])
        )
        #expect(VoiceDictationKeyRouter.isExactVoiceShortcut(
            keyCode: 0,
            modifiers: [.capsLock, .control, .shift],
            shortcut: shortcut
        ))
        #expect(!VoiceDictationKeyRouter.isExactVoiceShortcut(
            keyCode: 9,
            modifiers: [.control, .shift],
            shortcut: shortcut
        ))
    }

    @Test("hot-key registration replacement ends one press and rejects stale release")
    func registrationReplacementIsGenerationSafe() throws {
        var state = VoiceHotKeyRegistrationState()
        let first = state.activate(shortcut: .default)
        guard case let .register(firstID, endedPress) = first else {
            Issue.record("Initial activation must request registration.")
            return
        }
        #expect(endedPress == nil)
        let acceptedFirstPress = state.press(registrationID: firstID)
        #expect(acceptedFirstPress)

        let custom = try #require(
            VoiceDictationShortcut(keyCode: 0, modifiers: [.option, .shift])
        )
        let replacement = state.activate(shortcut: custom)
        guard case let .register(secondID, endedFirstPress) = replacement else {
            Issue.record("Changed shortcut must request replacement.")
            return
        }
        #expect(secondID != firstID)
        #expect(endedFirstPress == firstID)
        let acceptedStaleRelease = state.release(registrationID: firstID)
        #expect(!acceptedStaleRelease)
        let acceptedSecondPress = state.press(registrationID: secondID)
        #expect(acceptedSecondPress)
        let endedSecondPress = state.deactivate()
        #expect(endedSecondPress == secondID)
        let acceptedPostDeactivationRelease = state.release(
            registrationID: secondID
        )
        #expect(!acceptedPostDeactivationRelease)
    }

    @Test("reactivating the same shortcut keeps the registration generation")
    func sameRegistrationIsIdempotent() {
        var state = VoiceHotKeyRegistrationState()
        guard case let .register(identifier, _) = state.activate(
            shortcut: .default
        ) else {
            Issue.record("Initial activation must request registration.")
            return
        }

        #expect(
            state.activate(shortcut: .default)
                == .unchanged(registrationID: identifier)
        )
    }

    @Test("non-exclusive Carbon success never proves hot-key availability")
    func nonExclusiveCarbonSuccessIsRejected() {
        let outcome = VoiceHotKeyRegistrationPolicy.evaluate(
            requestedExclusive: false,
            status: 0,
            referenceWasCreated: true,
            conflictStatus: -9_878
        )

        #expect(outcome == .invalidRegistration)
    }

    @Test("exclusive Carbon holder is reported as a shortcut conflict")
    func exclusiveCarbonConflictIsReported() {
        let outcome = VoiceHotKeyRegistrationPolicy.evaluate(
            requestedExclusive: true,
            status: -9_878,
            referenceWasCreated: false,
            conflictStatus: -9_878
        )

        #expect(outcome == .conflict)
    }

    @Test("only exclusive Carbon noErr with a reference is registered")
    func exclusiveCarbonSuccessRequiresReference() {
        #expect(VoiceHotKeyRegistrationPolicy.evaluate(
            requestedExclusive: true,
            status: 0,
            referenceWasCreated: true,
            conflictStatus: -9_878
        ) == .registered)
        #expect(VoiceHotKeyRegistrationPolicy.evaluate(
            requestedExclusive: true,
            status: 0,
            referenceWasCreated: false,
            conflictStatus: -9_878
        ) == .invalidRegistration)
    }

    @Test("unexpected exclusive Carbon errors retain their system status")
    func exclusiveCarbonSystemErrorIsReported() {
        #expect(VoiceHotKeyRegistrationPolicy.evaluate(
            requestedExclusive: true,
            status: -50,
            referenceWasCreated: false,
            conflictStatus: -9_878
        ) == .systemFailure(status: -50))
    }

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
