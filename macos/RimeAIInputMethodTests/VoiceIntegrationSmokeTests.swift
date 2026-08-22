import AppKit
import CryptoKit
import XCTest
@testable import RimeAIInputMethod

@MainActor
final class VoiceIntegrationSmokeTests: XCTestCase {
#if DEBUG
    func testDebugBuildIncludesEvaluationArtifactAdmissionBoundary() {
        XCTAssertTrue(
            String(reflecting: VoiceASREvaluationArtifact.self)
                .hasSuffix(".VoiceASREvaluationArtifact")
        )
    }

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
