import Foundation
import Testing
@testable import RimeAIInputCore

@Suite("File cloud credential store")
struct CloudCredentialStoreTests {
    @Test("missing credential file reports no key without an error")
    func missingFileIsNotAnError() throws {
        let store = FileCloudCredentialStore(
            path: Self.temporaryCredentialPath()
        )

        #expect(try store.containsAPIKey() == false)
        #expect(try store.loadAPIKey() == nil)
    }

    @Test("saving, loading, and deleting round-trips through the file")
    func roundTrip() throws {
        let store = FileCloudCredentialStore(
            path: Self.temporaryCredentialPath()
        )

        try store.saveAPIKey("  sk-test-123  ")

        #expect(try store.loadAPIKey() == "sk-test-123")
        #expect(try store.containsAPIKey() == true)

        try store.deleteAPIKey()

        #expect(try store.containsAPIKey() == false)
        #expect(try store.loadAPIKey() == nil)
    }

    @Test("saved file and directory use restrictive permissions")
    func restrictivePermissions() throws {
        let path = Self.temporaryCredentialPath()
        let store = FileCloudCredentialStore(path: path)

        try store.saveAPIKey("sk-test-123")

        let fileManager = FileManager.default
        let fileAttributes = try fileManager.attributesOfItem(
            atPath: path.path
        )
        #expect(
            (fileAttributes[.posixPermissions] as? NSNumber)?
                .int16Value ?? -1 == 0o600
        )
        let directoryAttributes = try fileManager.attributesOfItem(
            atPath: path.deletingLastPathComponent().path
        )
        #expect(
            (directoryAttributes[.posixPermissions] as? NSNumber)?
                .int16Value ?? -1 == 0o700
        )
    }

    @Test("parsing strips whole-line comments, blank lines, and quotes")
    func parsing() throws {
        let values = try FileCloudCredentialStore.parse(
            """
            # managed by RimeAI
            RIMEAI_CLOUD_API_KEY=sk-abc

            OTHER_KEY=ignored
            RIMEAI_CLOUD_API_KEY_QUOTED="sk-def"
            SINGLE='sk-ghi'
            """
        )

        #expect(values["RIMEAI_CLOUD_API_KEY"] == "sk-abc")
        #expect(values["OTHER_KEY"] == "ignored")
        #expect(values["RIMEAI_CLOUD_API_KEY_QUOTED"] == "sk-def")
        #expect(values["SINGLE"] == "sk-ghi")
    }

    @Test("inline hashes stay part of the value instead of truncating it")
    func inlineHashIsNotAComment() throws {
        let values = try FileCloudCredentialStore.parse(
            "RIMEAI_CLOUD_API_KEY=sk-abc#def\n"
        )

        #expect(values["RIMEAI_CLOUD_API_KEY"] == "sk-abc#def")
    }

    @Test("a non-comment line without an equals sign is malformed")
    func malformedLineThrows() {
        #expect(throws: CloudCredentialError.malformedFile) {
            _ = try FileCloudCredentialStore.parse(
                "RIMEAI_CLOUD_API_KEY sk-abc\n"
            )
        }
    }

    @Test("a present file without the credential key holds no key")
    func fileWithoutCredentialKey() throws {
        let path = Self.temporaryCredentialPath()
        try "# comment only\nOTHER=1\n".write(
            to: path,
            atomically: true,
            encoding: .utf8
        )
        let store = FileCloudCredentialStore(path: path)

        #expect(try store.containsAPIKey() == false)
        #expect(try store.loadAPIKey() == nil)
    }

    @Test("invalid API keys are rejected before touching the filesystem")
    func invalidAPIKeys() {
        let store = FileCloudCredentialStore(
            path: Self.temporaryCredentialPath()
        )

        #expect(throws: CloudCredentialError.invalidAPIKey) {
            try store.saveAPIKey("   ")
        }
        #expect(throws: CloudCredentialError.invalidAPIKey) {
            try store.saveAPIKey(String(repeating: "a", count: 513))
        }
        #expect(throws: CloudCredentialError.invalidAPIKey) {
            try store.saveAPIKey("sk-abc\ndef")
        }
    }

    @Test("symlinked credential paths are refused")
    func symlinkIsRefused() throws {
        let directory = Self.temporaryDirectory()
        let realFile = directory.appendingPathComponent("real.env")
        try "RIMEAI_CLOUD_API_KEY=sk-test\n".write(
            to: realFile,
            atomically: true,
            encoding: .utf8
        )
        let link = directory.appendingPathComponent("cloud.env")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: realFile.path
        )
        let store = FileCloudCredentialStore(path: link)

        #expect(throws: CloudCredentialError.insecurePath) {
            _ = try store.loadAPIKey()
        }
        #expect(throws: CloudCredentialError.insecurePath) {
            try store.saveAPIKey("sk-test")
        }
    }

    @Test("deleting removes an emptied credential directory")
    func deleteRemovesEmptyDirectory() throws {
        let path = Self.temporaryCredentialPath()
        let store = FileCloudCredentialStore(path: path)

        try store.saveAPIKey("sk-test")
        try store.deleteAPIKey()

        #expect(
            !FileManager.default.fileExists(
                atPath: path.deletingLastPathComponent().path
            )
        )
    }

    @Test("the shared layout points at ~/.config/rimeai/cloud.env")
    func layoutExposesCredentialFile() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let layout = RimeAIProductDataLayout(homeDirectory: home)

        #expect(
            layout.cloudCredentialFile.path
                == "/Users/example/.config/rimeai/cloud.env"
        )
        #expect(
            !layout.managedDataURLs.contains(layout.configDirectory)
        )
    }

    // MARK: - Helpers

    private static var fileManager: FileManager {
        FileManager.default
    }

    private static func temporaryDirectory() -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent(
                "rimeai-credential-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try? fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private static func temporaryCredentialPath() -> URL {
        temporaryDirectory().appendingPathComponent("cloud.env")
    }
}
