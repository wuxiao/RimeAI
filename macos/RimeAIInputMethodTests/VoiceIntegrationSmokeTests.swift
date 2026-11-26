import AppKit
import Carbon
import CryptoKit
import XCTest
@testable import RimeAIInputMethod
#if canImport(RimeAIVoicePerformanceHelperBridge)
@_spi(VoiceEvaluation) import RimeAIVoicePerformanceHelperBridge
#endif

@MainActor
final class VoiceIntegrationSmokeTests: XCTestCase {
    private let carbonDictationShortcut = VoiceDictationShortcut(
        keyCode: 9,
        modifiers: [.control, .shift]
    )!

    func testDefaultFunctionShortcutActivatesAsModifierTapWithoutCarbonRegistration() throws {
        var registerCount = 0
        let registrar = VoiceHotKeyRegistrar(
            register: { _ in
                registerCount += 1
                return .init(status: noErr, reference: nil)
            },
            unregister: { _ in noErr }
        )
        let manager = VoiceHotKeyManager(testingRegistrar: registrar)
        let owner = NSObject()

        try manager.activate(
            owner: owner,
            shortcut: .default,
            onPressed: {},
            onReleased: {},
            onSecureInputDetected: {}
        )

        XCTAssertEqual(registerCount, 0)
        XCTAssertEqual(manager.registrationStatus, .registered(.function))
        manager.deactivate(owner: owner)
    }

    func testHotKeyRegistrationRequestsExclusiveCarbonOwnership() throws {
        let reference = try XCTUnwrap(EventHotKeyRef(bitPattern: 1))
        var requests: [VoiceHotKeyRegistrar.Request] = []
        let registrar = VoiceHotKeyRegistrar(
            register: { request in
                requests.append(request)
                return .init(status: noErr, reference: reference)
            },
            unregister: { _ in noErr }
        )
        let manager = VoiceHotKeyManager(testingRegistrar: registrar)
        let owner = NSObject()

        try manager.activate(
            owner: owner,
            shortcut: carbonDictationShortcut,
            onPressed: {},
            onReleased: {},
            onSecureInputDetected: {}
        )

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.options, OptionBits(kEventHotKeyExclusive))
        XCTAssertEqual(
            manager.registrationStatus,
            .registered(carbonDictationShortcut)
        )
        manager.deactivate(owner: owner)
    }

    func testHotKeyRegistrationMapsExistingHolderToConflict() {
        let registrar = VoiceHotKeyRegistrar(
            register: { _ in
                .init(
                    status: OSStatus(eventHotKeyExistsErr),
                    reference: nil
                )
            },
            unregister: { _ in noErr }
        )
        let manager = VoiceHotKeyManager(testingRegistrar: registrar)
        let owner = NSObject()

        XCTAssertThrowsError(try manager.activate(
            owner: owner,
            shortcut: carbonDictationShortcut,
            onPressed: {},
            onReleased: {},
            onSecureInputDetected: {}
        )) { error in
            XCTAssertEqual(
                (error as NSError).code,
                Int(eventHotKeyExistsErr)
            )
        }
        guard case let .failed(shortcut, kind, code, _) =
            manager.registrationStatus
        else {
            return XCTFail("Expected a conflict registration status.")
        }
        XCTAssertEqual(shortcut, carbonDictationShortcut)
        XCTAssertEqual(kind, .conflict)
        XCTAssertEqual(code, OSStatus(eventHotKeyExistsErr))
    }

    func testHotKeyRegistrationPreservesUnexpectedSystemStatus() {
        let expectedStatus = OSStatus(-12_345)
        let registrar = VoiceHotKeyRegistrar(
            register: { _ in
                .init(status: expectedStatus, reference: nil)
            },
            unregister: { _ in noErr }
        )
        let manager = VoiceHotKeyManager(testingRegistrar: registrar)
        let owner = NSObject()

        XCTAssertThrowsError(try manager.activate(
            owner: owner,
            shortcut: carbonDictationShortcut,
            onPressed: {},
            onReleased: {},
            onSecureInputDetected: {}
        ))
        guard case let .failed(_, kind, code, _) = manager.registrationStatus
        else {
            return XCTFail("Expected a system registration status.")
        }
        XCTAssertEqual(kind, .system)
        XCTAssertEqual(code, expectedStatus)
    }

    func testHotKeyRegistrationRejectsNoErrWithoutReference() {
        var unregisterCount = 0
        let registrar = VoiceHotKeyRegistrar(
            register: { _ in .init(status: noErr, reference: nil) },
            unregister: { _ in
                unregisterCount += 1
                return noErr
            }
        )
        let manager = VoiceHotKeyManager(testingRegistrar: registrar)
        let owner = NSObject()

        XCTAssertThrowsError(try manager.activate(
            owner: owner,
            shortcut: carbonDictationShortcut,
            onPressed: {},
            onReleased: {},
            onSecureInputDetected: {}
        )) { error in
            XCTAssertEqual((error as NSError).code, Int(paramErr))
        }
        guard case let .failed(_, kind, code, _) = manager.registrationStatus
        else {
            return XCTFail("Expected an invalid registration status.")
        }
        XCTAssertEqual(kind, .system)
        XCTAssertEqual(code, OSStatus(paramErr))
        XCTAssertEqual(unregisterCount, 0)
    }

    func testHotKeyReplacementUnregistersOnceAndEndsPressedSession() throws {
        let firstReference = try XCTUnwrap(EventHotKeyRef(bitPattern: 1))
        let secondReference = try XCTUnwrap(EventHotKeyRef(bitPattern: 2))
        var results = [
            VoiceHotKeyRegistrar.Result(
                status: noErr,
                reference: firstReference
            ),
            VoiceHotKeyRegistrar.Result(
                status: noErr,
                reference: secondReference
            ),
        ]
        var requests: [VoiceHotKeyRegistrar.Request] = []
        var unregistered: [EventHotKeyRef] = []
        let registrar = VoiceHotKeyRegistrar(
            register: { request in
                requests.append(request)
                return results.removeFirst()
            },
            unregister: { reference in
                unregistered.append(reference)
                return noErr
            }
        )
        let manager = VoiceHotKeyManager(testingRegistrar: registrar)
        let owner = NSObject()
        var pressCount = 0
        var releaseCount = 0

        try manager.activate(
            owner: owner,
            shortcut: carbonDictationShortcut,
            onPressed: { pressCount += 1 },
            onReleased: { releaseCount += 1 },
            onSecureInputDetected: {}
        )
        let firstRegistrationID = try XCTUnwrap(requests.first).identifier.id
        manager.handleFromCarbon(
            eventKind: UInt32(kEventHotKeyPressed),
            registrationID: firstRegistrationID
        )
        XCTAssertEqual(pressCount, 1)

        let replacement = try XCTUnwrap(VoiceDictationShortcut(
            keyCode: 0,
            modifiers: [.option, .shift]
        ))
        try manager.activate(
            owner: owner,
            shortcut: replacement,
            onPressed: { pressCount += 1 },
            onReleased: { releaseCount += 100 },
            onSecureInputDetected: {}
        )

        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(unregistered, [firstReference])
        manager.handleFromCarbon(
            eventKind: UInt32(kEventHotKeyReleased),
            registrationID: firstRegistrationID
        )
        XCTAssertEqual(releaseCount, 1)

        manager.deactivate(owner: owner)
        manager.deactivate(owner: owner)
        XCTAssertEqual(unregistered, [firstReference, secondReference])
        XCTAssertEqual(
            unregistered.filter { $0 == firstReference }.count,
            1
        )
        XCTAssertEqual(
            unregistered.filter { $0 == secondReference }.count,
            1
        )
        XCTAssertEqual(releaseCount, 1)
    }

    func testTranslationHotKeyRegistersWithDistinctSignatureAndRoutesIndependently()
        throws
    {
        let dictationRef = try XCTUnwrap(EventHotKeyRef(bitPattern: 11))
        let translateRef = try XCTUnwrap(EventHotKeyRef(bitPattern: 22))
        var requests: [VoiceHotKeyRegistrar.Request] = []
        var unregistered: [EventHotKeyRef] = []
        let registrar = VoiceHotKeyRegistrar(
            register: { request in
                requests.append(request)
                let ref = request.identifier.signature
                    == VoiceHotKeyManager.translateEventSignature
                    ? translateRef
                    : dictationRef
                return .init(status: noErr, reference: ref)
            },
            unregister: { ref in
                unregistered.append(ref)
                return noErr
            }
        )
        let manager = VoiceHotKeyManager(testingRegistrar: registrar)
        let owner = NSObject()
        var dictationPressed = 0
        var translatePressed = 0
        var translateReleased = 0

        try manager.activate(
            owner: owner,
            shortcut: carbonDictationShortcut,
            onPressed: { dictationPressed += 1 },
            onReleased: {},
            onSecureInputDetected: {}
        )
        try manager.activateTranslation(
            owner: owner,
            shortcut: .defaultTranslate,
            onPressed: { translatePressed += 1 },
            onReleased: { translateReleased += 1 }
        )

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            manager.translateRegistrationStatus,
            .registered(.defaultTranslate)
        )
        let translateID = try XCTUnwrap(requests.last).identifier.id
        manager.handleTranslateFromCarbon(
            eventKind: UInt32(kEventHotKeyPressed),
            registrationID: translateID
        )
        manager.handleTranslateFromCarbon(
            eventKind: UInt32(kEventHotKeyReleased),
            registrationID: translateID
        )

        XCTAssertEqual(dictationPressed, 0)
        XCTAssertEqual(translatePressed, 1)
        XCTAssertEqual(translateReleased, 1)

        manager.deactivate(owner: owner)
        XCTAssertTrue(unregistered.contains(dictationRef))
        XCTAssertTrue(unregistered.contains(translateRef))
        XCTAssertEqual(manager.translateRegistrationStatus, .inactive)
    }

#if DEBUG && canImport(RimeAIVoicePerformanceHelperBridge)
    func testDebugBuildIncludesEvaluationArtifactAdmissionBoundary() {
        XCTAssertTrue(
            String(reflecting: VoiceASREvaluationArtifact.self)
                .hasSuffix(".VoiceASREvaluationArtifact")
        )
    }
#endif

#if DEBUG
    func testVoicePanelHideErasesTranscriptAccessibilityAndActions() {
        let panel = VoiceDictationPanelController()
        panel.populateForHideTesting()

        panel.hide()

        let snapshot = panel.testingSnapshot
        XCTAssertEqual(snapshot.status, "")
        XCTAssertEqual(snapshot.transcript, "")
        XCTAssertNil(snapshot.accessibilityLabel)
        XCTAssertTrue(snapshot.confirmIsHidden)
        XCTAssertTrue(snapshot.copyIsHidden)
        XCTAssertTrue(snapshot.cancelIsHidden)
        XCTAssertFalse(snapshot.hasConfirmHandler)
        XCTAssertFalse(snapshot.hasCopyHandler)
        XCTAssertFalse(snapshot.hasCancelHandler)
        XCTAssertFalse(snapshot.isPersistentCopy)
    }

    func testVoicePanelListeningIsMinimalAndWrapsDynamically() {
        let panel = VoiceDictationPanelController()
        let anchor = NSRect(x: 300, y: 400, width: 2, height: 20)

        panel.showListening(anchorRect: anchor, onCancel: {})
        let listeningSnapshot = panel.testingSnapshot
        XCTAssertEqual(listeningSnapshot.status, "")
        XCTAssertTrue(listeningSnapshot.confirmIsHidden)
        XCTAssertTrue(listeningSnapshot.copyIsHidden)
        XCTAssertTrue(listeningSnapshot.cancelIsHidden)

        panel.updatePreview(
            stable: "你好",
            partial: "",
            pendingConfirm: false,
            polishApplied: false,
            anchorRect: anchor,
            onConfirm: {},
            onCancel: {}
        )
        let shortSize = panel.testingSnapshot.panelSize

        let longText = String(repeating: "这是一段需要自动换行并动态调整弹窗高度的语音转写测试内容。", count: 4)
        panel.updatePreview(
            stable: longText,
            partial: "",
            pendingConfirm: false,
            polishApplied: false,
            anchorRect: anchor,
            onConfirm: {},
            onCancel: {}
        )
        let longSnapshot = panel.testingSnapshot
        XCTAssertLessThanOrEqual(longSnapshot.panelSize.width, 380)
        XCTAssertGreaterThan(longSnapshot.panelSize.height, shortSize.height + 24)
        XCTAssertTrue(longSnapshot.cancelIsHidden)
        panel.hide()
    }

    func testVoicePanelPersistentCopyModeRetainsCopyActionUntilDismissed() {
        let panel = VoiceDictationPanelController()
        let anchor = NSRect(x: 300, y: 400, width: 2, height: 20)
        var copied = false

        panel.showPersistentCopy(
            text: "没有光标焦点时应持续悬浮并支持手动复制。",
            anchorRect: anchor,
            onCopied: { copied = true },
            onClose: {}
        )
        let snapshot = panel.testingSnapshot
        XCTAssertTrue(snapshot.isPersistentCopy)
        XCTAssertTrue(snapshot.confirmIsHidden)
        XCTAssertFalse(snapshot.copyIsHidden)
        XCTAssertFalse(snapshot.cancelIsHidden)
        XCTAssertTrue(snapshot.hasCopyHandler)

        XCTAssertTrue(panel.triggerCopyFromShortcut())
        XCTAssertTrue(copied)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "没有光标焦点时应持续悬浮并支持手动复制。"
        )
        panel.hide()
        XCTAssertFalse(panel.testingSnapshot.isPersistentCopy)
    }
#endif

    func testHelperInstallationStatusDistinguishesMissingAndDisabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let layout = RimeAIProductDataLayout(homeDirectory: root)
        XCTAssertEqual(
            VoiceHelperLifecycle.installationStatus(layout: layout),
            .notInstalled
        )

        let executable = layout.voiceHelperApplication
            .appendingPathComponent(
                "Contents/MacOS/rimeai-voice-helper",
                isDirectory: false
            )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: executable.path,
            contents: Data()
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        try FileManager.default.createDirectory(
            at: layout.voiceLaunchAgentPlist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: layout.voiceLaunchAgentPlist.path,
            contents: Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>".utf8)
        ))

#if DEBUG
        let expectedStatus: VoiceHelperLifecycle.InstallationStatus = .disabled
#else
        // Release must ignore a standalone Application Support helper and use
        // only the paired nested component from the signed host app.
        let expectedStatus: VoiceHelperLifecycle.InstallationStatus =
            .notInstalled
#endif
        XCTAssertEqual(
            VoiceHelperLifecycle.installationStatus(layout: layout),
            expectedStatus
        )
    }

    func testBuildConfigurationUsesOnlyItsExplicitTransport() {
#if DEBUG
        XCTAssertEqual(
            VoiceDictationPreferredTransport.currentBuildConfiguration,
            .developmentInsecureUDS
        )
#else
        XCTAssertEqual(
            VoiceDictationPreferredTransport.currentBuildConfiguration,
            .authenticatedXPC
        )
#endif
    }

    func testChangedReleaseLaunchAgentCannotReuseRunningService() {
        XCTAssertTrue(VoiceHelperLifecycle.shouldReuseRunningReleaseService(
            launchAgentChanged: false,
            transportReady: true,
            serviceRunning: true
        ))
        XCTAssertFalse(VoiceHelperLifecycle.shouldReuseRunningReleaseService(
            launchAgentChanged: true,
            transportReady: true,
            serviceRunning: true
        ))
    }

    func testReleaseLaunchAgentRenderingTargetsOnlyNestedHelper() throws {
        let template = try bundledData(
            named: "fun.wwcn.rimeai.voice-helper",
            extension: "plist"
        )
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("home & release", isDirectory: true)
        let layout = RimeAIProductDataLayout(homeDirectory: home)
        let helper = home
            .appendingPathComponent("Library/Input Methods", isDirectory: true)
            .appendingPathComponent("RimeAIInputMethod.app", isDirectory: true)
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("RimeAIVoiceHelper.app", isDirectory: true)

        let policy = try bundledData(
            named: "VoiceReleasePolicy",
            extension: "plist"
        )
        let policySHA256 = SHA256.hash(data: policy).map {
            String(format: "%02x", $0)
        }.joined()
        let rendered = try VoiceHelperLifecycle.renderReleaseLaunchAgent(
            templateData: template,
            helperApplication: helper,
            layout: layout,
            hostBuild: "28",
            policySHA256: policySHA256
        )
        let root = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: rendered,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(root["ProgramArguments"] as? [String], [
            helper.appendingPathComponent(
                "Contents/MacOS/rimeai-voice-helper"
            ).path,
            "--mach-service",
            "fun.wwcn.rimeai.voice-helper",
        ])
        XCTAssertEqual(
            root["MachServices"] as? [String: Bool],
            ["fun.wwcn.rimeai.voice-helper": true]
        )
        XCTAssertEqual(
            root["EnvironmentVariables"] as? [String: String],
            [
                "RIMEAI_PAIRED_BUILD": "28",
                "RIMEAI_VOICE_POLICY_SHA256": policySHA256,
            ]
        )
        XCTAssertFalse(String(data: rendered, encoding: .utf8)!.contains("__"))

        let nextBuild = try VoiceHelperLifecycle.renderReleaseLaunchAgent(
            templateData: template,
            helperApplication: helper,
            layout: layout,
            hostBuild: "29",
            policySHA256: policySHA256
        )
        XCTAssertNotEqual(rendered, nextBuild)

        let changedPolicySHA256 = policySHA256 == String(
            repeating: "0",
            count: 64
        )
            ? String(repeating: "1", count: 64)
            : String(repeating: "0", count: 64)
        let changedPolicy = try VoiceHelperLifecycle.renderReleaseLaunchAgent(
            templateData: template,
            helperApplication: helper,
            layout: layout,
            hostBuild: "28",
            policySHA256: changedPolicySHA256
        )
        XCTAssertNotEqual(rendered, changedPolicy)
    }

    func testReleasePolicyCannotPromoteAppleProbe() throws {
        let policy = try bundledData(
            named: "VoiceReleasePolicy",
            extension: "plist"
        )
        XCTAssertTrue(VoiceHelperLifecycle.releasePolicyIsFailClosed(policy))

        var root = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: policy,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        root["ReleaseEligible"] = true
        let promoted = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .xml,
            options: 0
        )
        XCTAssertFalse(
            VoiceHelperLifecycle.releasePolicyIsFailClosed(promoted)
        )
    }

    private func bundledData(
        named name: String,
        extension fileExtension: String
    ) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: fileExtension)
        )
        return try Data(contentsOf: url)
    }
}
