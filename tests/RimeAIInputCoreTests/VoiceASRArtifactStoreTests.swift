import Darwin
import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("Voice ASR artifact selector store")
struct VoiceASRArtifactStoreTests {
    @Test("artifact IDs cannot encode arbitrary paths")
    func artifactIDValidation() {
        for value in [
            "",
            ".",
            "..",
            "../model",
            "model/escape",
            "/absolute",
            "model\\escape",
            "model name",
            "模型",
            "model\nnext",
            String(repeating: "a", count: 129),
        ] {
            #expect(VoiceASRArtifactID(rawValue: value) == nil)
        }

        for value in [
            "sherpa-onnx.zh_v1",
            "Model-2026.08_arm64",
            "1-model",
            String(repeating: "a", count: 128),
        ] {
            #expect(VoiceASRArtifactID(rawValue: value)?.rawValue == value)
        }
    }

    @Test("activation writes private selectors and rollback swaps them")
    func activationAndRollback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.id("sherpa-onnx.zh-v1")
        let second = fixture.id("sherpa-onnx.zh-v2")
        try fixture.createRelease(first)
        try fixture.createRelease(second)
        var validated: [String] = []
        let store = VoiceASRArtifactStore(layout: fixture.layout) {
            url, expectedArtifactID in
            guard FileManager.default.fileExists(
                atPath: url.appendingPathComponent("validated.marker").path
            ) else {
                throw ValidationFailure.rejected
            }
            #expect(url.lastPathComponent == expectedArtifactID.rawValue)
            validated.append(url.lastPathComponent)
        }

        let initial = try store.selectorState()
        #expect(initial.current == nil)
        #expect(initial.previous == nil)

        let firstState = try store.activate(first)
        #expect(firstState.current == first)
        #expect(firstState.previous == nil)
        try fixture.expectSecureSelector(
            fixture.layout.voiceASRCurrentSelector,
            contents: "\(first.rawValue)\n"
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.layout.voiceASRPreviousSelector.path
            )
        )

        let secondState = try store.activate(second)
        #expect(secondState.current == second)
        #expect(secondState.previous == first)
        try fixture.expectSecureSelector(
            fixture.layout.voiceASRCurrentSelector,
            contents: "\(second.rawValue)\n"
        )
        try fixture.expectSecureSelector(
            fixture.layout.voiceASRPreviousSelector,
            contents: "\(first.rawValue)\n"
        )

        let rolledBack = try store.rollback()
        #expect(rolledBack.current == first)
        #expect(rolledBack.previous == second)
        #expect(validated == [
            first.rawValue,
            second.rawValue,
            first.rawValue,
        ])
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.layout.voiceASRDirectory
                    .appendingPathComponent(".selector-transaction").path
            )
        )
        let stagingEntries = try FileManager.default.contentsOfDirectory(
            atPath: fixture.layout.voiceASRStagingDirectory.path
        )
        #expect(
            !stagingEntries.contains {
                $0.hasPrefix(".selector-write-")
                    || $0.hasPrefix(".selector-remove-")
            }
        )
        try fixture.expectSameFileSystemForSelectors()
    }

    @Test("rollback without a previous release fails closed")
    func rollbackRequiresPrevious() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let artifactID = fixture.id("sherpa-onnx.zh-v1")
        try fixture.createRelease(artifactID)
        let store = fixture.store()
        _ = try store.activate(artifactID)

        #expect(throws: VoiceASRArtifactStoreError.noPreviousArtifact) {
            try store.rollback()
        }
    }

    @Test("injected model validation runs before selector mutation")
    func validatorFailurePreservesState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let accepted = fixture.id("accepted-model")
        let rejected = fixture.id("rejected-model")
        try fixture.createRelease(accepted)
        try fixture.createRelease(rejected)
        let store = VoiceASRArtifactStore(layout: fixture.layout) {
            url, expectedArtifactID in
            #expect(url.lastPathComponent == expectedArtifactID.rawValue)
            if url.lastPathComponent == rejected.rawValue {
                throw ValidationFailure.rejected
            }
        }
        _ = try store.activate(accepted)

        #expect(throws: ValidationFailure.rejected) {
            try store.activate(rejected)
        }
        let state = try store.selectorState()
        #expect(state.current == accepted)
        #expect(state.previous == nil)
    }

    @Test("missing, symlinked, and special release paths are rejected")
    func unsafeReleasePaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = fixture.id("missing-model")
        let symlinked = fixture.id("symlinked-model")
        let special = fixture.id("special-model")
        let withACL = fixture.id("acl-model")
        let store = fixture.store()
        _ = try store.selectorState()

        #expect(
            throws: VoiceASRArtifactStoreError.artifactNotFound(missing)
        ) {
            try store.activate(missing)
        }

        let outside = fixture.home.appendingPathComponent(
            "outside-release",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.layout.voiceASRReleaseDirectory(for: symlinked),
            withDestinationURL: outside
        )
        #expect(
            throws: VoiceASRArtifactStoreError.unsafeArtifactPath(symlinked)
        ) {
            try store.activate(symlinked)
        }

        let specialPath = fixture.layout.voiceASRReleaseDirectory(for: special)
        #expect(mkfifo(specialPath.path, mode_t(0o600)) == 0)
        #expect(
            throws: VoiceASRArtifactStoreError.unsafeArtifactPath(special)
        ) {
            try store.activate(special)
        }

        try fixture.createRelease(withACL)
        let aclPath = fixture.layout.voiceASRReleaseDirectory(for: withACL)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = [
            "+a",
            "everyone allow list,search",
            aclPath.path,
        ]
        chmod.standardOutput = FileHandle.nullDevice
        chmod.standardError = FileHandle.nullDevice
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        #expect(
            throws: VoiceASRArtifactStoreError.unsafeArtifactPath(withACL)
        ) {
            try store.activate(withACL)
        }
    }

    @Test("selector symlinks and widened permissions are rejected")
    func insecureSelectors() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let artifactID = fixture.id("sherpa-onnx.zh-v1")
        try fixture.createRelease(artifactID)
        let store = fixture.store()
        _ = try store.selectorState()

        let realSelector = fixture.layout.voiceASRDirectory
            .appendingPathComponent("real-current")
        try fixture.writeSecure(
            "\(artifactID.rawValue)\n",
            to: realSelector
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.layout.voiceASRCurrentSelector,
            withDestinationURL: realSelector
        )
        #expect(
            throws: VoiceASRArtifactStoreError.insecureSelector(.current)
        ) {
            try store.selectorState()
        }

        try FileManager.default.removeItem(
            at: fixture.layout.voiceASRCurrentSelector
        )
        _ = try store.activate(artifactID)
        #expect(
            chmod(
                fixture.layout.voiceASRCurrentSelector.path,
                mode_t(0o644)
            ) == 0
        )
        #expect(
            throws: VoiceASRArtifactStoreError.insecureSelector(.current)
        ) {
            try store.selectorState()
        }
    }

    @Test("corrupt and special selector files are rejected")
    func corruptSelectors() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.id("sherpa-onnx.zh-v1")
        let second = fixture.id("sherpa-onnx.zh-v2")
        try fixture.createRelease(first)
        try fixture.createRelease(second)
        let store = fixture.store()
        _ = try store.activate(first)

        try fixture.writeSecure(
            "../escape\n",
            to: fixture.layout.voiceASRCurrentSelector
        )
        #expect(
            throws: VoiceASRArtifactStoreError.corruptSelector(.current)
        ) {
            try store.selectorState()
        }

        try FileManager.default.removeItem(
            at: fixture.layout.voiceASRCurrentSelector
        )
        try fixture.writeSecure(
            "\(first.rawValue)\n",
            to: fixture.layout.voiceASRCurrentSelector
        )
        let previousPath = fixture.layout.voiceASRPreviousSelector
        #expect(mkfifo(previousPath.path, mode_t(0o600)) == 0)
        #expect(
            throws: VoiceASRArtifactStoreError.insecureSelector(.previous)
        ) {
            try store.selectorState()
        }
    }

    @Test("selectors never silently point at a removed release")
    func missingSelectedReleaseIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let artifactID = fixture.id("sherpa-onnx.zh-v1")
        try fixture.createRelease(artifactID)
        let store = fixture.store()
        _ = try store.activate(artifactID)
        try FileManager.default.removeItem(
            at: fixture.layout.voiceASRReleaseDirectory(for: artifactID)
        )

        #expect(
            throws: VoiceASRArtifactStoreError.artifactNotFound(artifactID)
        ) {
            try store.selectorState()
        }
    }

    @Test("a symlinked managed voice directory cannot escape the model root")
    func managedDirectorySymlinkIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.layout.modelDirectory,
            withIntermediateDirectories: true
        )
        let outside = fixture.home.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.layout.voiceASRDirectory,
            withDestinationURL: outside
        )
        let store = fixture.store()

        #expect(throws: VoiceASRArtifactStoreError.unsafeManagedDirectory) {
            try store.selectorState()
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("current").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("releases").path
            )
        )
    }

    @Test("an interrupted pre-commit selector transaction rolls back")
    func transactionRecoveryRollsBack() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.id("sherpa-onnx.zh-v1")
        let second = fixture.id("sherpa-onnx.zh-v2")
        try fixture.createRelease(first)
        try fixture.createRelease(second)
        let store = fixture.store()
        _ = try store.activate(first)

        try fixture.writeSecure(
            "\(first.rawValue)\n",
            to: fixture.layout.voiceASRPreviousSelector
        )
        try fixture.writeSecure(
            """
            voice-asr-selector-transaction-v1
            old-current=\(first.rawValue)
            old-previous=-
            new-current=\(second.rawValue)
            new-previous=\(first.rawValue)

            """,
            to: fixture.layout.voiceASRDirectory
                .appendingPathComponent(".selector-transaction")
        )

        let recovered = try store.selectorState()
        #expect(recovered.current == first)
        #expect(recovered.previous == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.layout.voiceASRPreviousSelector.path
            )
        )
    }

    @Test("an interrupted committed selector transaction finishes forward")
    func transactionRecoveryFinishesCommit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.id("sherpa-onnx.zh-v1")
        let second = fixture.id("sherpa-onnx.zh-v2")
        try fixture.createRelease(first)
        try fixture.createRelease(second)
        let store = fixture.store()
        _ = try store.activate(first)

        try fixture.writeSecure(
            "\(first.rawValue)\n",
            to: fixture.layout.voiceASRPreviousSelector
        )
        try fixture.writeSecure(
            "\(second.rawValue)\n",
            to: fixture.layout.voiceASRCurrentSelector
        )
        try fixture.writeSecure(
            """
            voice-asr-selector-transaction-v1
            old-current=\(first.rawValue)
            old-previous=-
            new-current=\(second.rawValue)
            new-previous=\(first.rawValue)

            """,
            to: fixture.layout.voiceASRDirectory
                .appendingPathComponent(".selector-transaction")
        )

        let recovered = try store.selectorState()
        #expect(recovered.current == second)
        #expect(recovered.previous == first)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.layout.voiceASRDirectory
                    .appendingPathComponent(".selector-transaction").path
            )
        )
    }

    @Test("an unsafe existing lock file is rejected without chmod")
    func unsafeLockFileIsNotMutated() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        _ = try store.selectorState()
        let lock = fixture.layout.voiceASRDirectory
            .appendingPathComponent(".selector.lock")
        try FileManager.default.removeItem(at: lock)
        let victim = fixture.home.appendingPathComponent("lock-victim")
        try fixture.writeSecure("leave permissions alone", to: victim)
        #expect(chmod(victim.path, mode_t(0o644)) == 0)
        #expect(link(victim.path, lock.path) == 0)

        #expect(throws: VoiceASRArtifactStoreError.unsafeManagedDirectory) {
            try store.selectorState()
        }
        var status = stat()
        #expect(lstat(victim.path, &status) == 0)
        #expect(status.st_mode & mode_t(0o777) == mode_t(0o644))
    }
}

private enum ValidationFailure: Error, Equatable {
    case rejected
}

private struct Fixture {
    let home: URL
    let layout: RimeAIProductDataLayout

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimeai-voice-artifact-store-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        layout = RimeAIProductDataLayout(homeDirectory: home)
    }

    func id(_ value: String) -> VoiceASRArtifactID {
        VoiceASRArtifactID(rawValue: value)!
    }

    func store() -> VoiceASRArtifactStore {
        VoiceASRArtifactStore(
            layout: layout,
            artifactValidator: { _, _ in }
        )
    }

    func createRelease(_ artifactID: VoiceASRArtifactID) throws {
        let directory = layout.voiceASRReleaseDirectory(for: artifactID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data().write(
            to: directory.appendingPathComponent("validated.marker")
        )
    }

    func writeSecure(_ contents: String, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        #expect(
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data(contents.utf8),
                attributes: [.posixPermissions: 0o600]
            )
        )
        #expect(chmod(url.path, mode_t(0o600)) == 0)
    }

    func expectSecureSelector(
        _ url: URL,
        contents: String
    ) throws {
        #expect(try String(contentsOf: url, encoding: .utf8) == contents)
        var status = stat()
        #expect(lstat(url.path, &status) == 0)
        #expect(status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        #expect(status.st_uid == geteuid())
        #expect(status.st_mode & mode_t(0o777) == mode_t(0o600))
        #expect(status.st_nlink == 1)
    }

    func expectSameFileSystemForSelectors() throws {
        var rootStatus = stat()
        var stagingStatus = stat()
        #expect(lstat(layout.voiceASRDirectory.path, &rootStatus) == 0)
        #expect(
            lstat(
                layout.voiceASRStagingDirectory.path,
                &stagingStatus
            ) == 0
        )
        #expect(rootStatus.st_dev == stagingStatus.st_dev)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}
