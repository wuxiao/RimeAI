import Darwin
import Foundation
import Testing
@testable import RimeAIVoicePerformanceTracerProcessDarwin

@Suite("Exclusive atomic canonical tracer result writer")
struct VoicePerformanceAtomicResultWriterTests {
    @Test("an already expired deadline creates no temporary result")
    func expirationBeforeTemporaryCreationHasNoFilesystemSideEffect() {
        let system = ScriptedAtomicResultSystem()
        let deadline = ScriptedResultDeadline(expired: [true])

        #expect(throws: VoicePerformanceTracerProcessError.deadlineExpired) {
            try VoicePerformanceAtomicResultWriter(
                system: system,
                deadlineExpired: deadline.isExpired
            ).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json",
                before: .init(nanoseconds: 10_000)
            )
        }

        #expect(system.createCount == 0)
        #expect(system.renameCount == 0)
        #expect(system.entries.isEmpty)
    }

    @Test("every completed write is followed by an exclusive deadline check")
    func expirationAfterShortWriteStopsFurtherWrites() {
        let system = ScriptedAtomicResultSystem()
        system.writeOutcomes = [.count(2), .count(3)]
        let deadline = ScriptedResultDeadline(expired: [false, true])

        #expect(throws: VoicePerformanceTracerProcessError.deadlineExpired) {
            try VoicePerformanceAtomicResultWriter(
                system: system,
                deadlineExpired: deadline.isExpired
            ).write(
                canonicalResult: Data("abcde".utf8),
                to: "/private/tmp/result.json",
                before: .init(nanoseconds: 10_000)
            )
        }

        #expect(system.written == Data("ab".utf8))
        #expect(system.renameCount == 0)
        #expect(system.currentTemporaryIdentity == nil)
        #expect(system.removedNames.count == 1)
    }

    @Test("deadline crossing at temporary fsync removes only the temporary result")
    func expirationAfterTemporarySyncPreventsCommit() {
        let system = ScriptedAtomicResultSystem()
        let deadline = ScriptedResultDeadline(expired: [false, false, true])

        #expect(throws: VoicePerformanceTracerProcessError.deadlineExpired) {
            try VoicePerformanceAtomicResultWriter(
                system: system,
                deadlineExpired: deadline.isExpired
            ).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json",
                before: .init(nanoseconds: 10_000)
            )
        }

        #expect(system.renameCount == 0)
        #expect(system.entries["result.json"] == nil)
        #expect(system.currentTemporaryIdentity == nil)
        #expect(system.removedNames.count == 1)
    }

    @Test("deadline expiration immediately before rename cannot publish")
    func expirationImmediatelyBeforeRenamePreventsCommit() {
        let system = ScriptedAtomicResultSystem()
        let deadline = ScriptedResultDeadline(
            expired: [false, false, false, true]
        )

        #expect(throws: VoicePerformanceTracerProcessError.deadlineExpired) {
            try VoicePerformanceAtomicResultWriter(
                system: system,
                deadlineExpired: deadline.isExpired
            ).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json",
                before: .init(nanoseconds: 10_000)
            )
        }

        #expect(system.renameCount == 0)
        #expect(system.entries["result.json"] == nil)
        #expect(system.currentTemporaryIdentity == nil)
        #expect(system.removedNames.count == 1)
    }

    @Test("deadline expiration after rename rolls back the exact installed result")
    func expirationAfterRenameRollsBackInstallation() {
        let system = ScriptedAtomicResultSystem()
        let deadline = ScriptedResultDeadline(
            expired: [false, false, false, false, true]
        )

        #expect(throws: VoicePerformanceTracerProcessError.deadlineExpired) {
            try VoicePerformanceAtomicResultWriter(
                system: system,
                deadlineExpired: deadline.isExpired
            ).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json",
                before: .init(nanoseconds: 10_000)
            )
        }

        #expect(system.renameCount == 1)
        #expect(system.entries["result.json"] == nil)
        #expect(system.currentTemporaryIdentity == nil)
        #expect(system.removedNames == ["result.json"])
    }

    @Test("a post-commit deadline rollback failure is installation-indeterminate")
    func expirationRollbackFailureIsIndeterminate() {
        let system = ScriptedAtomicResultSystem()
        system.synchronizeOutcomes = [.success, .error(EIO)]
        let deadline = ScriptedResultDeadline(
            expired: [false, false, false, false, true]
        )

        #expect(
            throws:
                VoicePerformanceTracerProcessError
                    .resultInstallationIndeterminate
        ) {
            try VoicePerformanceAtomicResultWriter(
                system: system,
                deadlineExpired: deadline.isExpired
            ).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json",
                before: .init(nanoseconds: 10_000)
            )
        }

        #expect(system.entries["result.json"] == nil)
        #expect(system.removedNames == ["result.json"])
        #expect(system.synchronizeCount == 2)
    }

    @Test("deadline crossing during parent fsync rolls back and syncs removal")
    func expirationAfterParentSyncRollsBackDurably() {
        let system = ScriptedAtomicResultSystem()
        let deadline = ScriptedResultDeadline(
            expired: [false, false, false, false, false, true]
        )

        #expect(throws: VoicePerformanceTracerProcessError.deadlineExpired) {
            try VoicePerformanceAtomicResultWriter(
                system: system,
                deadlineExpired: deadline.isExpired
            ).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json",
                before: .init(nanoseconds: 10_000)
            )
        }

        #expect(system.entries["result.json"] == nil)
        #expect(system.removedNames == ["result.json"])
        #expect(system.synchronizeCount == 3)
    }

    @Test("deadline crossing during final pathname rewalk cannot return success")
    func expirationAfterFinalRewalkRollsBackInstallation() {
        let system = ScriptedAtomicResultSystem()
        let deadline = ScriptedResultDeadline(
            expired: [false, false, false, false, false, false, true]
        )

        #expect(throws: VoicePerformanceTracerProcessError.deadlineExpired) {
            try VoicePerformanceAtomicResultWriter(
                system: system,
                deadlineExpired: deadline.isExpired
            ).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json",
                before: .init(nanoseconds: 10_000)
            )
        }

        #expect(system.entries["result.json"] == nil)
        #expect(system.removedNames == ["result.json"])
        #expect(system.synchronizeCount == 3)
    }

    @Test("writer commits exact bytes with mode 0600 in the requested parent")
    func commitsExactBytes() throws {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
            "rimeai-result-writer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let result = parent.appendingPathComponent("result.json")
        let bytes = Data(#"{"schema_version":1}"#.utf8)

        try VoicePerformanceAtomicResultWriter().write(
            canonicalResult: bytes,
            to: result.path
        )

        #expect(try Data(contentsOf: result) == bytes)
        var status = stat()
        #expect(lstat(result.path, &status) == 0)
        #expect(status.st_mode & mode_t(0o777) == mode_t(0o600))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: parent.path)
                == ["result.json"]
        )
    }

    @Test("Darwin extended ACLs are detected and reject result parents")
    func rejectsLiveExtendedACL() throws {
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "rimeai-result-acl-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "\(NSUserName()) allow read", parent.path]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        guard chmod.terminationStatus == 0 else { return }

        let descriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { _ = Darwin.close(descriptor) }
        #expect(
            try DarwinVoicePerformanceAtomicResultSystem()
                .hasExtendedACL(fileDescriptor: descriptor)
        )

        let result = parent.appendingPathComponent("result.json")
        #expect(throws: VoicePerformanceTracerProcessError.invalidResultPath) {
            try VoicePerformanceAtomicResultWriter().write(
                canonicalResult: Data("{}".utf8),
                to: result.path
            )
        }
        #expect(!FileManager.default.fileExists(atPath: result.path))
    }

    @Test("result paths reject ACL-bearing intermediate directories")
    func rejectsLiveIntermediateACL() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "rimeai-result-ancestor-acl-\(UUID().uuidString)",
                isDirectory: true
            )
        let parent = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "\(NSUserName()) allow read", root.path]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        guard chmod.terminationStatus == 0 else { return }

        let result = parent.appendingPathComponent("result.json")
        #expect(throws: VoicePerformanceTracerProcessError.invalidResultPath) {
            try VoicePerformanceAtomicResultWriter().write(
                canonicalResult: Data("{}".utf8),
                to: result.path
            )
        }
        #expect(!FileManager.default.fileExists(atPath: result.path))
    }

    @Test("renameable ancestors and path-parent replacement never succeed")
    func rejectsRenameableOrReplacedParentPath() {
        let renameable = ScriptedAtomicResultSystem()
        renameable.directoryIdentityOverrides["/private"] =
            VoicePerformanceFileIdentity(
                device: 7,
                inode: 70,
                kind: .directory,
                permissions: 0o777,
                linkCount: 2,
                owner: 0
            )
        #expect(throws: VoicePerformanceTracerProcessError.invalidResultPath) {
            try VoicePerformanceAtomicResultWriter(system: renameable).write(
                canonicalResult: Data("{}".utf8),
                to: "/private/tmp/result.json"
            )
        }
        #expect(renameable.createCount == 0)

        let replaced = ScriptedAtomicResultSystem()
        replaced.replaceResultParentPathAfterRename = true
        #expect(
            throws:
                VoicePerformanceTracerProcessError
                    .resultInstallationIndeterminate
        ) {
            try VoicePerformanceAtomicResultWriter(system: replaced).write(
                canonicalResult: Data("{}".utf8),
                to: "/private/tmp/result.json"
            )
        }
        #expect(replaced.entries["result.json"] == nil)
        #expect(replaced.removedNames == ["result.json"])
    }

    @Test("writer retries EINTR and short writes before one exclusive commit")
    func retriesInterruptsAndShortWrites() throws {
        let system = ScriptedAtomicResultSystem()
        system.writeOutcomes = [
            .error(EINTR),
            .count(2),
            .count(3),
        ]
        system.synchronizeOutcomes = [.error(EINTR), .success, .success]

        try VoicePerformanceAtomicResultWriter(system: system).write(
            canonicalResult: Data("abcde".utf8),
            to: "/private/tmp/result.json"
        )

        #expect(system.written == Data("abcde".utf8))
        #expect(system.renameCount == 1)
        #expect(system.removedNames.isEmpty)
        // Initial component traversal plus the pre-commit and post-commit
        // pathname revalidation walks must all release their descriptors.
        #expect(system.closedDescriptors.count == 10)
    }

    @Test("result parent aliases cannot enter a protected directory")
    func rejectsProtectedDirectoryIdentityAlias() {
        let system = ScriptedAtomicResultSystem()
        let protectedIdentity = VoicePerformanceFileIdentity(
            device: 9,
            inode: 900,
            kind: .directory,
            permissions: 0o700,
            linkCount: 2,
            owner: 501
        )
        system.directoryIdentityOverrides[
            "/Applications/ProtectedArtifact"
        ] = protectedIdentity
        system.directoryIdentityOverrides[
            "/volumes/alias-to-protected"
        ] = protectedIdentity

        #expect(throws: VoicePerformanceTracerProcessError.invalidResultPath) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("{}".utf8),
                to: "/volumes/alias-to-protected/result.json",
                protectingDirectories: [
                    "/Applications/ProtectedArtifact",
                ]
            )
        }

        #expect(system.createCount == 0)
        #expect(system.renameCount == 0)
    }

    @Test("failure cleanup refuses a replaced temporary inode")
    func cleanupRefusesReplacedInode() {
        let system = ScriptedAtomicResultSystem()
        system.writeOutcomes = [.error(EIO)]
        let replacement = VoicePerformanceFileIdentity(
            device: 7,
            inode: 99,
            kind: .regular,
            permissions: 0o600,
            linkCount: 1,
            owner: 501
        )
        system.replaceTemporaryOnWriteFailure = replacement

        #expect(throws: VoicePerformanceTracerProcessError.resultWriteFailed) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }

        #expect(system.removedNames.isEmpty)
        #expect(system.currentTemporaryIdentity == replacement)
    }

    @Test("failure cleanup removes only the confirmed unchanged temporary inode")
    func cleanupRemovesConfirmedTemporary() {
        let system = ScriptedAtomicResultSystem()
        system.writeOutcomes = [.error(EIO)]

        #expect(throws: VoicePerformanceTracerProcessError.resultWriteFailed) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }

        #expect(system.removedNames.count == 1)
        #expect(system.currentTemporaryIdentity == nil)
    }

    @Test("pre-validation failures clean only the re-confirmed temporary inode")
    func prevalidationFailuresCleanTemporary() {
        let modeFailure = ScriptedAtomicResultSystem()
        modeFailure.setModeOutcomes = [.error(EIO)]
        #expect(throws: VoicePerformanceTracerProcessError.resultWriteFailed) {
            try VoicePerformanceAtomicResultWriter(system: modeFailure).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }
        #expect(modeFailure.removedNames.count == 1)
        #expect(modeFailure.currentTemporaryIdentity == nil)

        let identityFailure = ScriptedAtomicResultSystem()
        identityFailure.fileIdentityErrorsAtCalls = [2: EIO]
        #expect(throws: VoicePerformanceTracerProcessError.resultWriteFailed) {
            try VoicePerformanceAtomicResultWriter(system: identityFailure).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }
        #expect(identityFailure.removedNames.count == 1)
        #expect(identityFailure.currentTemporaryIdentity == nil)

        let aclFailure = ScriptedAtomicResultSystem()
        aclFailure.aclErrorsAtCalls = [2: EIO]
        #expect(throws: VoicePerformanceTracerProcessError.resultWriteFailed) {
            try VoicePerformanceAtomicResultWriter(system: aclFailure).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }
        #expect(aclFailure.removedNames.count == 1)
        #expect(aclFailure.currentTemporaryIdentity == nil)
    }

    @Test("parent fsync failure rolls back the exact installed inode and syncs removal")
    func parentSyncFailureRollsBackInstalledResult() {
        let system = ScriptedAtomicResultSystem()
        system.synchronizeOutcomes = [.success, .error(EIO), .success]

        #expect(throws: VoicePerformanceTracerProcessError.resultDurabilityFailed) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }

        #expect(system.entries["result.json"] == nil)
        #expect(system.currentTemporaryIdentity == nil)
        #expect(system.removedNames == ["result.json"])
    }

    @Test("an existing result is never opened or replaced")
    func existingResultIsExclusive() {
        let system = ScriptedAtomicResultSystem()
        system.entries["result.json"] = system.secureIdentity

        #expect(throws: VoicePerformanceTracerProcessError.resultAlreadyExists) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }

        #expect(system.createCount == 0)
        #expect(system.renameCount == 0)
        #expect(system.entries["result.json"] == system.secureIdentity)
    }

    @Test("an exclusive rename race preserves the winner and cleans only our inode")
    func renameRacePreservesWinner() {
        let system = ScriptedAtomicResultSystem()
        let winner = VoicePerformanceFileIdentity(
            device: 8,
            inode: 77,
            kind: .regular,
            permissions: 0o600,
            linkCount: 1,
            owner: 501
        )
        system.renameWinner = winner

        #expect(throws: VoicePerformanceTracerProcessError.resultAlreadyExists) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }

        #expect(system.entries["result.json"] == winner)
        #expect(system.removedNames.count == 1)
        #expect(system.currentTemporaryIdentity == nil)
    }

    @Test("relative, non-NFC, and symlink-parent result paths fail closed")
    func rejectsUnsafeResultPaths() throws {
        let system = ScriptedAtomicResultSystem()
        #expect(throws: VoicePerformanceTracerProcessError.invalidResultPath) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "private/tmp/result.json"
            )
        }
        #expect(throws: VoicePerformanceTracerProcessError.invalidResultPath) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/re\u{301}sult.json"
            )
        }

        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "rimeai-result-symlink-\(UUID().uuidString)",
                isDirectory: true
            )
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: real
        )
        #expect(throws: VoicePerformanceTracerProcessError.invalidResultPath) {
            try VoicePerformanceAtomicResultWriter().write(
                canonicalResult: Data("x".utf8),
                to: link.appendingPathComponent("result.json").path
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: real.appendingPathComponent("result.json").path
        ))
    }

    @Test("post-rename replacement is reported indeterminate and never deleted")
    func postRenameReplacementIsIndeterminate() {
        let system = ScriptedAtomicResultSystem()
        let replacement = VoicePerformanceFileIdentity(
            device: 9,
            inode: 91,
            kind: .regular,
            permissions: 0o600,
            linkCount: 1,
            owner: 501,
            size: 1
        )
        system.replacementAfterRename = replacement

        #expect(
            throws:
                VoicePerformanceTracerProcessError
                    .resultInstallationIndeterminate
        ) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }

        #expect(system.entries["result.json"] == replacement)
        #expect(system.removedNames.isEmpty)
    }

    @Test("post-rename ACL mutation rolls back the exact inode before ordinary failure")
    func postRenameACLMutationRollsBack() {
        let system = ScriptedAtomicResultSystem()
        system.addACLAfterRename = true

        #expect(throws: VoicePerformanceTracerProcessError.resultCommitFailed) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }

        #expect(system.entries["result.json"] == nil)
        #expect(system.removedNames == ["result.json"])
    }

    @Test("post-rename stat fault rolls back when the exact inode can be re-confirmed")
    func postRenameStatFaultRollsBack() {
        let system = ScriptedAtomicResultSystem()
        system.entryErrorsAtCalls = [2: EIO]

        #expect(throws: VoicePerformanceTracerProcessError.resultCommitFailed) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }

        #expect(system.entries["result.json"] == nil)
        #expect(system.removedNames == ["result.json"])
    }

    @Test("writer bounds one-line canonical payloads before creating a temporary file")
    func boundsCanonicalPayload() {
        for bytes in [
            Data("{\n}".utf8),
            Data("{\r}".utf8),
            Data(repeating: 0x78, count: 1_048_577),
        ] {
            let system = ScriptedAtomicResultSystem()
            #expect(throws: VoicePerformanceTracerProcessError.resultWriteFailed) {
                try VoicePerformanceAtomicResultWriter(system: system).write(
                    canonicalResult: bytes,
                    to: "/private/tmp/result.json"
                )
            }
            #expect(system.createCount == 0)
        }
    }

    @Test("secure parent and exact committed size are mandatory")
    func validatesParentAndSize() {
        let parentACL = ScriptedAtomicResultSystem()
        parentACL.descriptorsWithACL.insert(12)
        #expect(throws: VoicePerformanceTracerProcessError.invalidResultPath) {
            try VoicePerformanceAtomicResultWriter(system: parentACL).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }
        #expect(parentACL.createCount == 0)

        let wrongSize = ScriptedAtomicResultSystem()
        wrongSize.reportedTemporarySizeAfterWrite = 0
        #expect(throws: VoicePerformanceTracerProcessError.resultWriteFailed) {
            try VoicePerformanceAtomicResultWriter(system: wrongSize).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }
        #expect(wrongSize.renameCount == 0)
        #expect(wrongSize.currentTemporaryIdentity == nil)
    }

    @Test("opaque destination lookup errors are not downgraded to path errors")
    func opaqueDestinationLookupErrorIsPreserved() {
        let unexpected = AtomicResultUnexpectedError(
            description: "result-entry-secret-e9d1"
        )
        let system = ScriptedAtomicResultSystem()
        system.entryUnexpectedErrorsAtCalls[1] = unexpected

        #expect(throws: unexpected) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }
        #expect(system.createCount == 0)
    }

    @Test("opaque write errors survive successful exact temporary cleanup")
    func opaqueWriteErrorIsPreservedAfterCleanup() {
        let unexpected = AtomicResultUnexpectedError(
            description: "result-write-secret-0ec4"
        )
        let system = ScriptedAtomicResultSystem()
        system.writeOutcomes = [.unexpected(unexpected)]

        #expect(throws: unexpected) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }
        #expect(system.currentTemporaryIdentity == nil)
        #expect(system.removedNames.count == 1)
        #expect(system.entries["result.json"] == nil)
    }

    @Test("opaque pre-commit rename errors survive temporary cleanup")
    func opaqueRenameErrorIsPreservedBeforeCommit() {
        let unexpected = AtomicResultUnexpectedError(
            description: "result-rename-secret-50b2"
        )
        let system = ScriptedAtomicResultSystem()
        system.renameUnexpectedError = unexpected

        #expect(throws: unexpected) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }
        #expect(system.currentTemporaryIdentity == nil)
        #expect(system.entries["result.json"] == nil)
    }

    @Test("opaque post-commit rename errors survive a confirmed rollback")
    func opaqueRenameErrorIsPreservedAfterConfirmedRollback() {
        let unexpected = AtomicResultUnexpectedError(
            description: "result-rename-commit-secret-a7f3"
        )
        let system = ScriptedAtomicResultSystem()
        system.renameUnexpectedError = unexpected
        system.commitRenameBeforeUnexpectedError = true

        #expect(throws: unexpected) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }
        #expect(system.entries["result.json"] == nil)
        #expect(system.removedNames == ["result.json"])
    }

    @Test("an unconfirmable post-commit opaque rename keeps indeterminate priority")
    func opaqueRenameWithUnconfirmableRollbackIsIndeterminate() {
        let system = ScriptedAtomicResultSystem()
        system.renameUnexpectedError = AtomicResultUnexpectedError(
            description: "result-rename-indeterminate-secret-c38f"
        )
        system.commitRenameBeforeUnexpectedError = true
        let replacement = VoicePerformanceFileIdentity(
            device: 44,
            inode: 4_444,
            kind: .regular,
            permissions: 0o600,
            linkCount: 1,
            owner: 501,
            size: 1
        )
        system.replacementAfterRename = replacement

        #expect(
            throws: VoicePerformanceTracerProcessError
                .resultInstallationIndeterminate
        ) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }
        #expect(system.entries["result.json"] == replacement)
        #expect(system.removedNames.isEmpty)
    }

    @Test("opaque parent sync errors survive a confirmed rollback")
    func opaqueDurabilityErrorIsPreservedAfterRollback() {
        let unexpected = AtomicResultUnexpectedError(
            description: "result-sync-secret-b163"
        )
        let system = ScriptedAtomicResultSystem()
        system.synchronizeOutcomes = [.success, .unexpected(unexpected)]

        #expect(throws: unexpected) {
            try VoicePerformanceAtomicResultWriter(system: system).write(
                canonicalResult: Data("x".utf8),
                to: "/private/tmp/result.json"
            )
        }
        #expect(system.entries["result.json"] == nil)
        #expect(system.removedNames == ["result.json"])
    }
}

private enum ScriptedWriteOutcome: Sendable {
    case count(Int)
    case error(Int32)
    case unexpected(AtomicResultUnexpectedError)
}

private enum ScriptedVoidOutcome: Sendable {
    case success
    case error(Int32)
    case unexpected(AtomicResultUnexpectedError)
}

private struct AtomicResultUnexpectedError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    let description: String
}

private final class ScriptedResultDeadline: @unchecked Sendable {
    private var expired: [Bool]

    init(expired: [Bool]) {
        self.expired = expired
    }

    func isExpired(
        _ deadline: VoicePerformanceContinuousDeadline
    ) throws -> Bool {
        _ = deadline
        return expired.isEmpty ? false : expired.removeFirst()
    }
}

private final class ScriptedAtomicResultSystem:
    VoicePerformanceAtomicResultSystem, @unchecked Sendable
{
    let effectiveUserID: UInt32 = 501
    let secureIdentity = VoicePerformanceFileIdentity(
        device: 7,
        inode: 11,
        kind: .regular,
        permissions: 0o600,
        linkCount: 1,
        owner: 501
    )
    let secureDirectoryIdentity = VoicePerformanceFileIdentity(
        device: 7,
        inode: 3,
        kind: .directory,
        permissions: 0o700,
        linkCount: 2,
        owner: 501
    )
    var writeOutcomes: [ScriptedWriteOutcome] = []
    var synchronizeOutcomes: [ScriptedVoidOutcome] = []
    var setModeOutcomes: [ScriptedVoidOutcome] = []
    var entries: [String: VoicePerformanceFileIdentity] = [:]
    var written = Data()
    var renameCount = 0
    var synchronizeCount = 0
    var createCount = 0
    var removedNames: [String] = []
    var closedDescriptors: [Int32] = []
    var replaceTemporaryOnWriteFailure: VoicePerformanceFileIdentity?
    var renameWinner: VoicePerformanceFileIdentity?
    var replacementAfterRename: VoicePerformanceFileIdentity?
    var addACLAfterRename = false
    var replaceResultParentPathAfterRename = false
    var descriptorsWithACL: Set<Int32> = []
    var fileIdentityErrorsAtCalls: [Int: Int32] = [:]
    var aclErrorsAtCalls: [Int: Int32] = [:]
    var directoryIdentityOverrides:
        [String: VoicePerformanceFileIdentity] = [:]
    var entryErrorsAtCalls: [Int: Int32] = [:]
    var entryUnexpectedErrorsAtCalls: [Int: AtomicResultUnexpectedError] = [:]
    var reportedTemporarySizeAfterWrite: UInt64?
    var renameUnexpectedError: AtomicResultUnexpectedError?
    var commitRenameBeforeUnexpectedError = false
    private var entryCallCount = 0
    private var temporaryFileIdentityCallCount = 0
    private var temporaryACLCallCount = 0
    private var nextDirectoryDescriptor: Int32 = 11
    private var nextDirectoryInode: UInt64 = 100
    private var temporaryName: String?
    private var resultParentDescriptor: Int32?
    private var didRename = false
    private var directoryPathsByDescriptor: [Int32: String] = [:]
    private var defaultDirectoryIdentities:
        [String: VoicePerformanceFileIdentity] = [:]

    var currentTemporaryIdentity: VoicePerformanceFileIdentity? {
        temporaryName.flatMap { entries[$0] }
    }

    func openRootDirectory() throws -> Int32 {
        directoryPathsByDescriptor[10] = "/"
        return 10
    }

    func openDirectory(named name: String, relativeTo parent: Int32) throws
        -> Int32
    {
        let parentPath = directoryPathsByDescriptor[parent] ?? "/"
        let path = parentPath == "/"
            ? "/\(name)"
            : "\(parentPath)/\(name)"
        directoryPathsByDescriptor[nextDirectoryDescriptor] = path
        defer { nextDirectoryDescriptor += 1 }
        return nextDirectoryDescriptor
    }

    func entryIdentity(named name: String, relativeTo parent: Int32) throws
        -> VoicePerformanceFileIdentity?
    {
        entryCallCount += 1
        if let error = entryUnexpectedErrorsAtCalls[entryCallCount] {
            throw error
        }
        if let error = entryErrorsAtCalls[entryCallCount] {
            throw VoicePerformancePOSIXError(code: error)
        }
        return entries[name]
    }

    func createExclusiveFile(named name: String, relativeTo parent: Int32) throws
        -> Int32
    {
        createCount += 1
        guard entries[name] == nil else {
            throw VoicePerformancePOSIXError(code: EEXIST)
        }
        temporaryName = name
        resultParentDescriptor = parent
        entries[name] = secureIdentity
        return 20
    }

    func setMode0600(fileDescriptor: Int32) throws {
        let outcome = setModeOutcomes.isEmpty
            ? ScriptedVoidOutcome.success
            : setModeOutcomes.removeFirst()
        if case .error(let code) = outcome {
            throw VoicePerformancePOSIXError(code: code)
        }
        if case .unexpected(let error) = outcome { throw error }
    }

    func hasExtendedACL(fileDescriptor: Int32) throws -> Bool {
        if fileDescriptor == 20 {
            temporaryACLCallCount += 1
            if let error = aclErrorsAtCalls[temporaryACLCallCount] {
                throw VoicePerformancePOSIXError(code: error)
            }
        }
        return descriptorsWithACL.contains(fileDescriptor)
    }

    func fileIdentity(fileDescriptor: Int32) throws -> VoicePerformanceFileIdentity {
        guard fileDescriptor == 20 else {
            if let path = directoryPathsByDescriptor[fileDescriptor],
               replaceResultParentPathAfterRename,
               didRename,
               path == "/private/tmp",
               fileDescriptor != resultParentDescriptor
            {
                return VoicePerformanceFileIdentity(
                    device: 88,
                    inode: 8_888,
                    kind: .directory,
                    permissions: 0o700,
                    linkCount: 2,
                    owner: 501
                )
            }
            if let path = directoryPathsByDescriptor[fileDescriptor],
               let identity = directoryIdentityOverrides[path]
            {
                return identity
            }
            let path = directoryPathsByDescriptor[fileDescriptor] ?? "/"
            if let identity = defaultDirectoryIdentities[path] {
                return identity
            }
            let identity = VoicePerformanceFileIdentity(
                device: secureDirectoryIdentity.device,
                inode: nextDirectoryInode,
                kind: secureDirectoryIdentity.kind,
                permissions: secureDirectoryIdentity.permissions,
                linkCount: secureDirectoryIdentity.linkCount,
                owner: secureDirectoryIdentity.owner
            )
            nextDirectoryInode += 1
            defaultDirectoryIdentities[path] = identity
            return identity
        }
        temporaryFileIdentityCallCount += 1
        if let error = fileIdentityErrorsAtCalls[
            temporaryFileIdentityCallCount
        ] {
            throw VoicePerformancePOSIXError(code: error)
        }
        let identity = currentTemporaryIdentity ?? secureIdentity
        guard !written.isEmpty, let size = reportedTemporarySizeAfterWrite else {
            return identity
        }
        return VoicePerformanceFileIdentity(
            device: identity.device,
            inode: identity.inode,
            kind: identity.kind,
            permissions: identity.permissions,
            linkCount: identity.linkCount,
            owner: identity.owner,
            size: size
        )
    }

    func write(
        _ data: Data,
        offset: Int,
        fileDescriptor: Int32
    ) throws -> Int {
        let outcome = writeOutcomes.isEmpty
            ? ScriptedWriteOutcome.count(data.count - offset)
            : writeOutcomes.removeFirst()
        switch outcome {
        case .error(let code):
            if let name = temporaryName,
                let replacement = replaceTemporaryOnWriteFailure
            {
                entries[name] = replacement
            }
            throw VoicePerformancePOSIXError(code: code)
        case .unexpected(let error):
            throw error
        case .count(let count):
            written.append(data[offset..<(offset + count)])
            if let name = temporaryName {
                entries[name] = VoicePerformanceFileIdentity(
                    device: secureIdentity.device,
                    inode: secureIdentity.inode,
                    kind: secureIdentity.kind,
                    permissions: secureIdentity.permissions,
                    linkCount: secureIdentity.linkCount,
                    owner: secureIdentity.owner,
                    size: UInt64(written.count)
                )
            }
            return count
        }
    }

    func synchronize(fileDescriptor: Int32) throws {
        synchronizeCount += 1
        let outcome = synchronizeOutcomes.isEmpty
            ? ScriptedVoidOutcome.success
            : synchronizeOutcomes.removeFirst()
        if case .error(let code) = outcome {
            throw VoicePerformancePOSIXError(code: code)
        }
        if case .unexpected(let error) = outcome { throw error }
    }

    func renameExclusive(
        from source: String,
        to destination: String,
        relativeTo parent: Int32
    ) throws {
        renameCount += 1
        didRename = true
        if let renameUnexpectedError, !commitRenameBeforeUnexpectedError {
            throw renameUnexpectedError
        }
        if let winner = renameWinner {
            entries[destination] = winner
            throw VoicePerformancePOSIXError(code: EEXIST)
        }
        guard entries[destination] == nil, let identity = entries.removeValue(forKey: source)
        else {
            throw VoicePerformancePOSIXError(code: EEXIST)
        }
        entries[destination] = identity
        if let replacementAfterRename {
            entries[destination] = replacementAfterRename
        }
        if addACLAfterRename {
            descriptorsWithACL.insert(20)
        }
        if let renameUnexpectedError { throw renameUnexpectedError }
    }

    func remove(named name: String, relativeTo parent: Int32) throws {
        removedNames.append(name)
        entries.removeValue(forKey: name)
    }

    func close(fileDescriptor: Int32) {
        closedDescriptors.append(fileDescriptor)
    }
}
