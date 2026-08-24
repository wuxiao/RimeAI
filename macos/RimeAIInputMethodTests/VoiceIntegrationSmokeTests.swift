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
            shortcut: .default,
            onPressed: {},
            onReleased: {},
            onSecureInputDetected: {}
        )

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.options, OptionBits(kEventHotKeyExclusive))
        XCTAssertEqual(manager.registrationStatus, .registered(.default))
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
            shortcut: .default,
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
        XCTAssertEqual(shortcut, .default)
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
            shortcut: .default,
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
            shortcut: .default,
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
            shortcut: .default,
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
        XCTAssertTrue(snapshot.cancelIsHidden)
        XCTAssertFalse(snapshot.hasConfirmHandler)
        XCTAssertFalse(snapshot.hasCancelHandler)
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
