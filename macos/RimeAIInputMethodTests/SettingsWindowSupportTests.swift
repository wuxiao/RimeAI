import XCTest
@testable import RimeAIInputMethod

@MainActor
final class SettingsWindowSupportTests: XCTestCase {
    func testDaemonReadinessFailureDisablesAIAndVoicePreferences() throws {
        let suiteName = "SettingsWindowSupportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RimeAISettingsStore(defaults: defaults)
        store.aiEnabled = true
        store.voiceEnabled = true

        SettingsDaemonActivationFailurePolicy.apply(to: store)

        XCTAssertFalse(store.aiEnabled)
        XCTAssertFalse(store.voiceEnabled)
    }

    func testDaemonReadinessFailurePerformsRollbackBeforeReturningError() {
        enum ExpectedError: Error, Equatable {
            case readiness
        }
        var didRollback = false

        let error = SettingsDaemonActivationFailurePolicy.rollbackError(
            readinessError: ExpectedError.readiness,
            performRollback: { didRollback = true }
        )

        XCTAssertTrue(didRollback)
        XCTAssertEqual(error as? ExpectedError, .readiness)
    }

    func testDaemonReadinessFailureReportsIncompleteRollback() {
        enum ExpectedError: Error {
            case readiness
            case rollback
        }

        let error = SettingsDaemonActivationFailurePolicy.rollbackError(
            readinessError: ExpectedError.readiness,
            performRollback: { throw ExpectedError.rollback }
        )

        XCTAssertTrue(error.localizedDescription.contains("握手失败"))
        XCTAssertTrue(error.localizedDescription.contains("回滚未完整完成"))
        XCTAssertNotNil((error as NSError).userInfo[NSUnderlyingErrorKey])
    }

    func testDaemonDeactivationAttemptsEveryStepAndAggregatesFailures() {
        enum ExpectedError: LocalizedError {
            case marker
            case launchctl
            case adHoc

            var errorDescription: String? {
                switch self {
                case .marker:
                    "marker failed"
                case .launchctl:
                    "launchctl failed"
                case .adHoc:
                    "ad-hoc failed"
                }
            }
        }
        var events: [SettingsDaemonDeactivationStep] = []

        XCTAssertThrowsError(
            try SettingsDaemonDeactivationPolicy.run([
                (.removeMarker, {
                    events.append(.removeMarker)
                    throw ExpectedError.marker
                }),
                (.stopLaunchAgent, {
                    events.append(.stopLaunchAgent)
                    throw ExpectedError.launchctl
                }),
                (.stopAdHocProcess, {
                    events.append(.stopAdHocProcess)
                    throw ExpectedError.adHoc
                }),
            ])
        ) { error in
            let cleanupError = error as? SettingsDaemonDeactivationError
            XCTAssertEqual(events, [
                .removeMarker,
                .stopLaunchAgent,
                .stopAdHocProcess,
            ])
            XCTAssertEqual(
                cleanupError?.failures.map(\.step),
                [
                    .removeMarker,
                    .stopLaunchAgent,
                    .stopAdHocProcess,
                ]
            )
            XCTAssertTrue(
                error.localizedDescription.contains("运行态不确定")
            )
        }
    }

    func testDaemonDeactivationTreatsNonzeroLaunchctlKillAsUncertain() {
        XCTAssertNoThrow(
            try SettingsDaemonDeactivationPolicy
                .requireSuccessfulLaunchctlKill(0)
        )
        XCTAssertThrowsError(
            try SettingsDaemonDeactivationPolicy
                .requireSuccessfulLaunchctlKill(37)
        ) { error in
            XCTAssertEqual(
                error as? SettingsDaemonLaunchAgentStopError,
                SettingsDaemonLaunchAgentStopError(status: 37)
            )
            XCTAssertTrue(
                error.localizedDescription.contains("state is uncertain")
            )
        }
    }

    func testSettingsDocumentRoundTripPreservesExportedSnapshot() throws {
        let suiteName = "SettingsWindowSupportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RimeAISettingsStore(defaults: defaults)
        store.characterSet = .traditional
        store.characterWidth = .full
        store.punctuationStyle = .western
        store.aiEnabled = false
        store.contextPolicy = .strict
        store.disabledAIApplications = ["com.example.Editor"]

        let snapshot = store.exportSnapshot()
        let document = try SettingsDocumentCodec.encode(snapshot)

        XCTAssertEqual(
            try SettingsDocumentCodec.decode(document),
            snapshot
        )
    }

    func testRuntimeTransitionRepairsConfirmedRuntimeDrift() throws {
        let suiteName = "SettingsWindowSupportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RimeAISettingsStore(defaults: defaults)
        store.cloudConfigured = true
        store.voiceEnabled = true
        let desired = store.exportSnapshot()

        XCTAssertEqual(
            SettingsRuntimeTransition.plan(
                desired: desired,
                observation: SettingsRuntimeObservation(
                    daemon: .confirmedEnabled,
                    cloudBroker: .confirmedDisabled,
                    voiceHelper: .unverified
                )
            ),
            SettingsRuntimeTransition(
                daemonEnabled: nil,
                cloudBrokerEnabled: true,
                voiceHelperEnabled: true
            )
        )
    }

    func testLifecycleMarkerTransactionRollsBackAfterOperationFailure() {
        enum ExpectedFailure: Error, Equatable {
            case operation
        }
        var events: [String] = []

        XCTAssertThrowsError(
            try SettingsLifecycleMarkerTransaction.run(
                createMarker: { events.append("create") },
                rollbackMarker: { events.append("rollback") },
                operation: {
                    events.append("operation")
                    throw ExpectedFailure.operation
                }
            )
        ) { error in
            XCTAssertEqual(error as? ExpectedFailure, .operation)
        }
        XCTAssertEqual(events, ["create", "operation", "rollback"])
    }

    func testRuntimeSocketNodeCheckRejectsARegularFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let regularFile = directory.appendingPathComponent("rimeai.sock")
        try Data().write(to: regularFile)

        XCTAssertFalse(SettingsRuntimeSocketNode.exists(at: regularFile))
    }

    func testRuntimeSuccessCopyDoesNotClaimAuthenticatedReadiness() {
        for operation in [
            SettingsRuntimeOperation.daemon(true),
            .cloudBroker(true),
            .voiceHelper(false),
        ] {
            let message = SettingsRuntimeStatusCopy.applied(operation)
            XCTAssertTrue(message.contains("期望状态已应用"))
            XCTAssertTrue(message.contains("连接状态继续刷新"))
            XCTAssertFalse(message.contains("已启动"))
            XCTAssertFalse(message.contains("已停止"))
            XCTAssertFalse(message.contains("就绪"))
        }
    }

    func testRuntimeTransitionReconcilesUnknownRuntimeWhenPreferencesUnchanged()
        throws
    {
        let suiteName = "SettingsWindowSupportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RimeAISettingsStore(defaults: defaults)
        store.cloudConfigured = true
        store.voiceEnabled = true
        let unchanged = store.exportSnapshot()

        XCTAssertEqual(
            SettingsRuntimeTransition.plan(
                desired: unchanged,
                observation: .unverified
            ).orderedOperations,
            [
                .daemon(true),
                .cloudBroker(true),
                .voiceHelper(true),
            ]
        )
    }

    func testRuntimeTransitionStopsDependentsBeforeDaemonAndStartsDaemonFirst() {
        let disabling = SettingsRuntimeTransition(
            daemonEnabled: false,
            cloudBrokerEnabled: false,
            voiceHelperEnabled: false
        )
        let enabling = SettingsRuntimeTransition(
            daemonEnabled: true,
            cloudBrokerEnabled: true,
            voiceHelperEnabled: true
        )

        XCTAssertEqual(disabling.orderedOperations, [
            .voiceHelper(false),
            .cloudBroker(false),
            .daemon(false),
        ])
        XCTAssertEqual(enabling.orderedOperations, [
            .daemon(true),
            .cloudBroker(true),
            .voiceHelper(true),
        ])
    }

    func testShortcutCaptureButtonShowsTheCurrentShortcut() {
        let button = SettingsShortcutCaptureButton()

        button.showShortcut("⌃⇧V")

        XCTAssertEqual(button.title, "更改…（当前 ⌃⇧V）")
        XCTAssertEqual(button.accessibilityValue() as? String, "⌃⇧V")
    }

    func testSettingsDocumentRejectsFilesLargerThanTheStoreLimit() {
        let oversized = Data(
            repeating: 0,
            count: SettingsDocumentCodec.maximumDocumentBytes + 1
        )

        XCTAssertThrowsError(try SettingsDocumentCodec.decode(oversized)) {
            error in
            XCTAssertEqual(
                (error as? CocoaError)?.code,
                CocoaError.Code.fileReadTooLarge
            )
        }
    }

    func testSettingsDocumentFileSizePreflightUsesTheStoreLimit() {
        XCTAssertEqual(
            SettingsDocumentCodec.maximumDocumentBytes,
            RimeAISettingsStore.maxImportDocumentBytes
        )
        XCTAssertNoThrow(
            try SettingsDocumentCodec.validateDocumentByteCount(
                SettingsDocumentCodec.maximumDocumentBytes
            )
        )
        XCTAssertThrowsError(
            try SettingsDocumentCodec.validateDocumentByteCount(
                SettingsDocumentCodec.maximumDocumentBytes + 1
            )
        ) { error in
            XCTAssertEqual(
                (error as? CocoaError)?.code,
                CocoaError.Code.fileReadTooLarge
            )
        }
    }

    func testEscapeCancelsCaptureWithoutReplacingThePreviousShortcut() throws {
        let button = SettingsShortcutCaptureButton()
        var cancellationCount = 0
        var captureStates: [Bool] = []
        button.onCancel = { cancellationCount += 1 }
        button.onCaptureStateChanged = { captureStates.append($0) }
        button.showShortcut("⌃⇧V")
        button.beginCapture()
        button.showValidationFailure()
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        ))

        button.keyDown(with: escape)

        XCTAssertFalse(button.isCapturing)
        XCTAssertEqual(button.title, "更改…（当前 ⌃⇧V）")
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(captureStates, [true, false])
    }

    func testLosingFocusCancelsShortcutCapture() {
        let button = SettingsShortcutCaptureButton()
        button.showShortcut("⌃⇧V")
        button.beginCapture()

        XCTAssertTrue(button.resignFirstResponder())

        XCTAssertFalse(button.isCapturing)
        XCTAssertEqual(button.title, "更改…（当前 ⌃⇧V）")
    }

    func testSettingsActionStatusChangePostsNotification() {
        let center = SettingsActionStatusCenter.shared
        center.update(SettingsActionStatus(
            kind: .ready,
            message: "测试前状态"
        ))
        let notification = expectation(description: "status changed")
        let token = NotificationCenter.default.addObserver(
            forName: .rimeAISettingsActionStatusDidChange,
            object: center,
            queue: .main
        ) { _ in
            notification.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(token)
            center.update(.ready)
        }
        let changed = SettingsActionStatus(
            kind: .failure,
            message: "导出失败"
        )

        center.update(changed)

        wait(for: [notification], timeout: 0.1)
        XCTAssertEqual(center.current, changed)
    }
}

@MainActor
final class CandidateSelectionControllerTransitionTests: XCTestCase {
    func testPartialSelectionCommitsOnlyConfirmedPrefixAndRetainsTail() throws {
        let transition = try XCTUnwrap(CandidateSelectionTransition(
            originalInput: "mingtiantianqi",
            committedText: "明天",
            remainingInput: "tianqi"
        ))
        var insertedTexts: [String] = []
        var historyCommits: [(pinyin: String, text: String)] = []
        var markedInputs: [String] = []
        var hotwords: [String] = []

        let applied = CandidateSelectionApplicationTransition.apply(
            transition,
            secureInputIsActive: { false },
            cancelForSecureInput: {
                XCTFail("non-secure selection must not cancel")
            },
            insertConfirmedPrefix: { text, pinyin in
                insertedTexts.append(text)
                historyCommits.append((pinyin, text))
                return true
            },
            retainMarkedComposition: { markedInputs.append($0) },
            resetComposition: {
                XCTFail("partial selection must retain its raw tail")
            },
            recordConfirmedHotword: { hotwords.append($0) }
        )

        XCTAssertTrue(applied)
        XCTAssertEqual(insertedTexts, ["明天"])
        XCTAssertEqual(historyCommits.map(\.pinyin), ["mingtian"])
        XCTAssertEqual(historyCommits.map(\.text), ["明天"])
        XCTAssertEqual(markedInputs, ["tianqi"])
        XCTAssertEqual(hotwords, ["明天"])
    }

    func testSecureInputFlipBeforeApplyCancelsWithoutCommitOrLearning() throws {
        let transition = try XCTUnwrap(CandidateSelectionTransition(
            originalInput: "mingtiantianqi",
            committedText: "明天",
            remainingInput: "tianqi"
        ))
        var cancellationCount = 0
        var insertedTexts: [String] = []
        var historyCommits: [(pinyin: String, text: String)] = []
        var markedInputs: [String] = []
        var resetCount = 0
        var hotwords: [String] = []

        let applied = CandidateSelectionApplicationTransition.apply(
            transition,
            secureInputIsActive: { true },
            cancelForSecureInput: { cancellationCount += 1 },
            insertConfirmedPrefix: { text, pinyin in
                insertedTexts.append(text)
                historyCommits.append((pinyin, text))
                return true
            },
            retainMarkedComposition: { markedInputs.append($0) },
            resetComposition: { resetCount += 1 },
            recordConfirmedHotword: { hotwords.append($0) }
        )

        XCTAssertFalse(applied)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertTrue(insertedTexts.isEmpty)
        XCTAssertTrue(historyCommits.isEmpty)
        XCTAssertTrue(markedInputs.isEmpty)
        XCTAssertEqual(resetCount, 0)
        XCTAssertTrue(hotwords.isEmpty)
    }
}
