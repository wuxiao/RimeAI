import Darwin
import Foundation
#if canImport(RimeAIVoiceArtifactCore)
import RimeAIVoiceArtifactCore
#endif

public enum VoiceASRSelector: String, Equatable, Sendable {
    case current
    case previous
}

public struct VoiceASRSelectorState: Equatable, Sendable {
    public let current: VoiceASRArtifactID?
    public let previous: VoiceASRArtifactID?

    fileprivate init(
        current: VoiceASRArtifactID?,
        previous: VoiceASRArtifactID?
    ) {
        self.current = current
        self.previous = previous
    }
}

/// A single backend-load generation bound to a selector value that was
/// reverified while the Store's cooperative cross-process lock was held.
/// The model backend must be constructed inside `withVerifiedCurrentArtifact`;
/// retaining only the URL and reopening it later loses this generation bound.
public struct VoiceASRVerifiedArtifactLease: Equatable, Sendable {
    public let generation: UUID
    public let artifact: VoiceASRVerifiedArtifact

    @_spi(VoiceArtifactAdmission)
    public init(
        generation: UUID,
        artifact: VoiceASRVerifiedArtifact
    ) {
        self.generation = generation
        self.artifact = artifact
    }
}

public enum VoiceASRArtifactStoreError: Error, Equatable, Sendable {
    case unsafeManagedDirectory
    case artifactNotFound(VoiceASRArtifactID)
    case unsafeArtifactPath(VoiceASRArtifactID)
    case artifactIdentityMismatch(
        expected: VoiceASRArtifactID,
        actual: VoiceASRArtifactID
    )
    case insecureSelector(VoiceASRSelector)
    case corruptSelector(VoiceASRSelector)
    case corruptSelectorState
    case insecureTransaction
    case corruptTransaction
    case noPreviousArtifact
    case noCurrentArtifact
    case verifiedArtifactLoaderUnavailable
    case selectorChangedDuringLoad
    case ioFailure(Int32)
    case transactionRollbackFailed
}

typealias VoiceASRArtifactValidator = (
    URL,
    VoiceASRArtifactID
) throws -> Void

private typealias VoiceASRVerifiedArtifactLoader = (
    URL,
    VoiceASRArtifactID
) throws -> VoiceASRVerifiedArtifact

/// Owns only the immutable-release path boundary and the two small selector
/// files. Model format, hashes, licences, and runtime compatibility remain the
/// responsibility of the injected validator.
public final class VoiceASRArtifactStore: @unchecked Sendable {
    public let layout: RimeAIProductDataLayout

    private static let lockName = ".selector.lock"
    private static let transactionName = ".selector-transaction"
    private static let selectorMaximumBytes = 129
    private static let transactionMaximumBytes = 768

    private let artifactValidator: VoiceASRArtifactValidator
    private let verifiedArtifactLoader: VoiceASRVerifiedArtifactLoader?
    private let processLock = NSLock()
    private let expectedUserID: uid_t

    /// Production initializer. The verifier result is bound to the selector ID;
    /// a valid pack in the wrong release directory is rejected before commit.
    public init(
        layout: RimeAIProductDataLayout,
        verifier: any VoiceASRArtifactVerifying = VoiceASRArtifactVerifier()
    ) {
        self.layout = layout
        let loader: VoiceASRVerifiedArtifactLoader = {
            url, expectedArtifactID in
            let verified = try verifier.verifyArtifact(at: url)
            guard verified.manifest.artifactID == expectedArtifactID else {
                throw VoiceASRArtifactStoreError.artifactIdentityMismatch(
                    expected: expectedArtifactID,
                    actual: verified.manifest.artifactID
                )
            }
            return verified
        }
        verifiedArtifactLoader = loader
        artifactValidator = { url, expectedArtifactID in
            _ = try loader(url, expectedArtifactID)
        }
        expectedUserID = geteuid()
    }

    /// Test seam. Production callers use the verifier initializer above.
    init(
        layout: RimeAIProductDataLayout,
        artifactValidator: @escaping VoiceASRArtifactValidator
    ) {
        self.layout = layout
        self.artifactValidator = artifactValidator
        verifiedArtifactLoader = nil
        expectedUserID = geteuid()
    }

    public func selectorState() throws -> VoiceASRSelectorState {
        try withExclusiveLock { context in
            try readState(context)
        }
    }

    /// Revalidates the selected artifact and executes the backend load probe
    /// before releasing the selector lock. The body should synchronously open
    /// all model files and create the recognizer it returns. This prevents a
    /// cooperative publisher/rollback from switching `current` between
    /// verification and backend construction. The body must not call selector
    /// operations (`selectorState`, `activate`, `rollback`, or another verified
    /// load): this API deliberately holds a non-recursive process/file lock.
    public func withVerifiedCurrentArtifact<T>(
        _ body: (VoiceASRVerifiedArtifactLease) throws -> T
    ) throws -> T {
        try withExclusiveLock { context in
            let initialState = try readState(context)
            guard let artifactID = initialState.current else {
                throw VoiceASRArtifactStoreError.noCurrentArtifact
            }
            guard let verifiedArtifactLoader else {
                throw VoiceASRArtifactStoreError
                    .verifiedArtifactLoaderUnavailable
            }
            let location = try validateArtifactDirectory(
                artifactID,
                context: context
            )
            let verified = try verifiedArtifactLoader(
                location.url,
                artifactID
            )
            try revalidateArtifactDirectory(
                artifactID,
                expected: location,
                context: context
            )
            guard try readState(context).current == artifactID else {
                throw VoiceASRArtifactStoreError.selectorChangedDuringLoad
            }

            let result = try body(VoiceASRVerifiedArtifactLease(
                generation: UUID(),
                artifact: verified
            ))

            try revalidateArtifactDirectory(
                artifactID,
                expected: location,
                context: context
            )
            guard try readState(context).current == artifactID else {
                throw VoiceASRArtifactStoreError.selectorChangedDuringLoad
            }
            return result
        }
    }

    @discardableResult
    public func activate(
        _ artifactID: VoiceASRArtifactID
    ) throws -> VoiceASRSelectorState {
        try withExclusiveLock { context in
            let oldState = try readState(context)
            let location = try validateArtifactDirectory(
                artifactID,
                context: context
            )
            try artifactValidator(location.url, artifactID)
            try revalidateArtifactDirectory(
                artifactID,
                expected: location,
                context: context
            )
            if oldState.current == artifactID {
                return oldState
            }
            let newState = VoiceASRSelectorState(
                current: artifactID,
                previous: oldState.current
            )
            try transact(
                from: oldState,
                to: newState,
                context: context
            )
            return try readState(context)
        }
    }

    @discardableResult
    public func rollback() throws -> VoiceASRSelectorState {
        try withExclusiveLock { context in
            let oldState = try readState(context)
            guard let previous = oldState.previous else {
                throw VoiceASRArtifactStoreError.noPreviousArtifact
            }
            let location = try validateArtifactDirectory(
                previous,
                context: context
            )
            try artifactValidator(location.url, previous)
            try revalidateArtifactDirectory(
                previous,
                expected: location,
                context: context
            )
            let newState = VoiceASRSelectorState(
                current: previous,
                previous: oldState.current
            )
            try transact(
                from: oldState,
                to: newState,
                context: context
            )
            return try readState(context)
        }
    }

    // MARK: - Transaction

    private struct DirectoryContext {
        let root: Int32
        let releases: Int32
        let staging: Int32
    }

    private struct ValidatedArtifactLocation {
        let url: URL
        let device: dev_t
        let inode: ino_t
    }

    private struct SelectorTransaction {
        let oldState: VoiceASRSelectorState
        let newState: VoiceASRSelectorState
    }

    private func transact(
        from oldState: VoiceASRSelectorState,
        to newState: VoiceASRSelectorState,
        context: DirectoryContext
    ) throws {
        let transaction = SelectorTransaction(
            oldState: oldState,
            newState: newState
        )
        try writeTransaction(transaction, context: context)
        do {
            try apply(
                newState,
                currentIsCommitPoint: true,
                context: context
            )
            try atomicRemoveSmallFile(
                named: Self.transactionName,
                securityError: .insecureTransaction,
                context: context
            )
        } catch {
            do {
                try apply(
                    oldState,
                    currentIsCommitPoint: false,
                    context: context
                )
                try atomicRemoveSmallFile(
                    named: Self.transactionName,
                    securityError: .insecureTransaction,
                    context: context
                )
            } catch {
                throw VoiceASRArtifactStoreError.transactionRollbackFailed
            }
            throw error
        }
    }

    private func apply(
        _ state: VoiceASRSelectorState,
        currentIsCommitPoint: Bool,
        context: DirectoryContext
    ) throws {
        let first: (VoiceASRSelector, VoiceASRArtifactID?)
        let second: (VoiceASRSelector, VoiceASRArtifactID?)
        if currentIsCommitPoint {
            first = (.previous, state.previous)
            second = (.current, state.current)
        } else {
            first = (.current, state.current)
            second = (.previous, state.previous)
        }
        try setSelector(first.0, to: first.1, context: context)
        try setSelector(second.0, to: second.1, context: context)
    }

    private func recoverTransactionIfNeeded(
        _ context: DirectoryContext
    ) throws {
        guard let transaction = try readTransaction(context) else {
            return
        }
        let current = try readSelector(.current, context: context)
        guard current == transaction.oldState.current
            || current == transaction.newState.current
        else {
            throw VoiceASRArtifactStoreError.corruptTransaction
        }
        let committed = current == transaction.newState.current
        let recoveredState = committed
            ? transaction.newState
            : transaction.oldState
        try validateStateArtifacts(recoveredState, context: context)
        try apply(
            recoveredState,
            currentIsCommitPoint: committed,
            context: context
        )
        try atomicRemoveSmallFile(
            named: Self.transactionName,
            securityError: .insecureTransaction,
            context: context
        )
    }

    // MARK: - State and artifact paths

    private func readState(
        _ context: DirectoryContext
    ) throws -> VoiceASRSelectorState {
        let current = try readSelector(.current, context: context)
        let previous = try readSelector(.previous, context: context)
        guard current != nil || previous == nil,
              current == nil || current != previous
        else {
            throw VoiceASRArtifactStoreError.corruptSelectorState
        }
        let state = VoiceASRSelectorState(
            current: current,
            previous: previous
        )
        try validateStateArtifacts(state, context: context)
        return state
    }

    private func validateStateArtifacts(
        _ state: VoiceASRSelectorState,
        context: DirectoryContext
    ) throws {
        if let current = state.current {
            _ = try validateArtifactDirectory(current, context: context)
        }
        if let previous = state.previous {
            _ = try validateArtifactDirectory(previous, context: context)
        }
    }

    private func validateArtifactDirectory(
        _ artifactID: VoiceASRArtifactID,
        context: DirectoryContext
    ) throws -> ValidatedArtifactLocation {
        var status = stat()
        let result = artifactID.rawValue.withCString { name in
            fstatat(
                context.releases,
                name,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result != 0 {
            if errno == ENOENT {
                throw VoiceASRArtifactStoreError.artifactNotFound(artifactID)
            }
            throw VoiceASRArtifactStoreError.ioFailure(errno)
        }
        guard isDirectory(status),
              status.st_uid == expectedUserID,
              status.st_mode & mode_t(0o022) == 0
        else {
            throw VoiceASRArtifactStoreError.unsafeArtifactPath(artifactID)
        }

        let descriptor = artifactID.rawValue.withCString { name in
            openat(
                context.releases,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw VoiceASRArtifactStoreError.unsafeArtifactPath(artifactID)
        }
        defer { close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              sameFile(status, openedStatus),
              isDirectory(openedStatus),
              voiceASRDescriptorHasNoExtendedACL(descriptor)
        else {
            throw VoiceASRArtifactStoreError.unsafeArtifactPath(artifactID)
        }
        return ValidatedArtifactLocation(
            url: layout.voiceASRReleaseDirectory(for: artifactID),
            device: openedStatus.st_dev,
            inode: openedStatus.st_ino
        )
    }

    private func revalidateArtifactDirectory(
        _ artifactID: VoiceASRArtifactID,
        expected: ValidatedArtifactLocation,
        context: DirectoryContext
    ) throws {
        let current = try validateArtifactDirectory(
            artifactID,
            context: context
        )
        guard current.device == expected.device,
              current.inode == expected.inode
        else {
            throw VoiceASRArtifactStoreError.unsafeArtifactPath(artifactID)
        }
    }

    // MARK: - Selector files

    private func readSelector(
        _ selector: VoiceASRSelector,
        context: DirectoryContext
    ) throws -> VoiceASRArtifactID? {
        guard let data = try readSecureSmallFile(
            named: selector.rawValue,
            maximumBytes: Self.selectorMaximumBytes,
            securityError: .insecureSelector(selector),
            corruptError: .corruptSelector(selector),
            context: context
        ) else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8),
              text.last == "\n",
              text.dropLast().allSatisfy({ $0 != "\n" && $0 != "\r" })
        else {
            throw VoiceASRArtifactStoreError.corruptSelector(selector)
        }
        guard let artifactID = VoiceASRArtifactID(
            rawValue: String(text.dropLast())
        ) else {
            throw VoiceASRArtifactStoreError.corruptSelector(selector)
        }
        return artifactID
    }

    private func setSelector(
        _ selector: VoiceASRSelector,
        to artifactID: VoiceASRArtifactID?,
        context: DirectoryContext
    ) throws {
        guard let artifactID else {
            try atomicRemoveSmallFile(
                named: selector.rawValue,
                securityError: .insecureSelector(selector),
                context: context
            )
            return
        }
        try atomicWriteSmallFile(
            Data("\(artifactID.rawValue)\n".utf8),
            destinationName: selector.rawValue,
            securityError: .insecureSelector(selector),
            context: context
        )
    }

    // MARK: - Recovery journal

    private func writeTransaction(
        _ transaction: SelectorTransaction,
        context: DirectoryContext
    ) throws {
        let contents = """
            voice-asr-selector-transaction-v1
            old-current=\(transactionToken(transaction.oldState.current))
            old-previous=\(transactionToken(transaction.oldState.previous))
            new-current=\(transactionToken(transaction.newState.current))
            new-previous=\(transactionToken(transaction.newState.previous))

            """
        try atomicWriteSmallFile(
            Data(contents.utf8),
            destinationName: Self.transactionName,
            securityError: .insecureTransaction,
            context: context
        )
    }

    private func readTransaction(
        _ context: DirectoryContext
    ) throws -> SelectorTransaction? {
        guard let data = try readSecureSmallFile(
            named: Self.transactionName,
            maximumBytes: Self.transactionMaximumBytes,
            securityError: .insecureTransaction,
            corruptError: .corruptTransaction,
            context: context
        ) else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoiceASRArtifactStoreError.corruptTransaction
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard lines.count == 6,
              lines[0] == "voice-asr-selector-transaction-v1",
              lines[5].isEmpty
        else {
            throw VoiceASRArtifactStoreError.corruptTransaction
        }
        let oldCurrent = try transactionValue(
            lines[1],
            prefix: "old-current="
        )
        let oldPrevious = try transactionValue(
            lines[2],
            prefix: "old-previous="
        )
        let newCurrent = try transactionValue(
            lines[3],
            prefix: "new-current="
        )
        let newPrevious = try transactionValue(
            lines[4],
            prefix: "new-previous="
        )
        let oldState = VoiceASRSelectorState(
            current: oldCurrent,
            previous: oldPrevious
        )
        let newState = VoiceASRSelectorState(
            current: newCurrent,
            previous: newPrevious
        )
        guard oldState.current != nil || oldState.previous == nil,
              oldState.current == nil
                  || oldState.current != oldState.previous,
              newState.current != nil,
              newState.previous == oldState.current,
              newState.current != oldState.current,
              newState.current != newState.previous
        else {
            throw VoiceASRArtifactStoreError.corruptTransaction
        }
        return SelectorTransaction(
            oldState: oldState,
            newState: newState
        )
    }

    private func transactionValue(
        _ line: Substring,
        prefix: String
    ) throws -> VoiceASRArtifactID? {
        guard line.hasPrefix(prefix) else {
            throw VoiceASRArtifactStoreError.corruptTransaction
        }
        let token = String(line.dropFirst(prefix.count))
        if token == "-" {
            return nil
        }
        guard let artifactID = VoiceASRArtifactID(rawValue: token) else {
            throw VoiceASRArtifactStoreError.corruptTransaction
        }
        return artifactID
    }

    private func transactionToken(
        _ artifactID: VoiceASRArtifactID?
    ) -> String {
        artifactID?.rawValue ?? "-"
    }

    // MARK: - Filesystem operations

    private func withExclusiveLock<T>(
        _ operation: (DirectoryContext) throws -> T
    ) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }

        try prepareManagedDirectories()
        let root = try openSecureDirectory(layout.voiceASRDirectory)
        defer { close(root) }
        let releases = try openSecureChildDirectory(
            parent: root,
            name: "releases"
        )
        defer { close(releases) }
        let staging = try openSecureChildDirectory(
            parent: root,
            name: "staging"
        )
        defer { close(staging) }

        var rootStatus = stat()
        var releasesStatus = stat()
        var stagingStatus = stat()
        guard fstat(root, &rootStatus) == 0,
              fstat(releases, &releasesStatus) == 0,
              fstat(staging, &stagingStatus) == 0,
              rootStatus.st_dev == releasesStatus.st_dev,
              rootStatus.st_dev == stagingStatus.st_dev
        else {
            throw VoiceASRArtifactStoreError.unsafeManagedDirectory
        }

        let lockDescriptor = try openLockFile(root: root)
        defer { close(lockDescriptor) }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw VoiceASRArtifactStoreError.ioFailure(errno)
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }

        let context = DirectoryContext(
            root: root,
            releases: releases,
            staging: staging
        )
        try recoverTransactionIfNeeded(context)
        return try operation(context)
    }

    private func prepareManagedDirectories() throws {
        let applicationSupport = layout.supportDirectory
            .deletingLastPathComponent()
        let library = applicationSupport.deletingLastPathComponent()
        let home = library.deletingLastPathComponent()
        guard layout.supportDirectory.lastPathComponent == "RimeAI",
              applicationSupport.lastPathComponent == "Application Support",
              library.lastPathComponent == "Library",
              layout.modelDirectory.deletingLastPathComponent()
                  == layout.supportDirectory,
              layout.voiceASRDirectory.deletingLastPathComponent()
                  == layout.modelDirectory,
              layout.voiceASRReleasesDirectory.deletingLastPathComponent()
                  == layout.voiceASRDirectory,
              layout.voiceASRStagingDirectory.deletingLastPathComponent()
                  == layout.voiceASRDirectory
        else {
            throw VoiceASRArtifactStoreError.unsafeManagedDirectory
        }

        try validateDirectory(home, requireNoExtendedACL: false)
        for directory in [
            library,
            applicationSupport,
            layout.supportDirectory,
            layout.modelDirectory,
            layout.voiceASRDirectory,
            layout.voiceASRReleasesDirectory,
            layout.voiceASRStagingDirectory,
        ] {
            var status = stat()
            if lstat(directory.path, &status) != 0 {
                let lookupError = errno
                guard lookupError == ENOENT else {
                    throw VoiceASRArtifactStoreError.ioFailure(lookupError)
                }
                if mkdir(directory.path, mode_t(0o700)) != 0 {
                    let creationError = errno
                    guard creationError == EEXIST else {
                        throw VoiceASRArtifactStoreError.ioFailure(
                            creationError
                        )
                    }
                }
            }
            let requiresACLCheck = directory == layout.voiceASRDirectory
                || directory == layout.voiceASRReleasesDirectory
                || directory == layout.voiceASRStagingDirectory
            try validateDirectory(
                directory,
                requireNoExtendedACL: requiresACLCheck
            )
        }
    }

    private func validateDirectory(
        _ directory: URL,
        requireNoExtendedACL: Bool
    ) throws {
        var status = stat()
        guard lstat(directory.path, &status) == 0,
              isDirectory(status),
              status.st_uid == expectedUserID,
              status.st_mode & mode_t(0o022) == 0,
              !requireNoExtendedACL
                  || voiceASRPathHasNoExtendedACL(directory.path)
        else {
            throw VoiceASRArtifactStoreError.unsafeManagedDirectory
        }
    }

    private func openSecureDirectory(_ directory: URL) throws -> Int32 {
        var pathStatus = stat()
        guard lstat(directory.path, &pathStatus) == 0 else {
            throw VoiceASRArtifactStoreError.unsafeManagedDirectory
        }
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw VoiceASRArtifactStoreError.unsafeManagedDirectory
        }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              sameFile(pathStatus, openedStatus),
              isDirectory(openedStatus),
              openedStatus.st_uid == expectedUserID,
              openedStatus.st_mode & mode_t(0o022) == 0,
              voiceASRDescriptorHasNoExtendedACL(descriptor)
        else {
            close(descriptor)
            throw VoiceASRArtifactStoreError.unsafeManagedDirectory
        }
        return descriptor
    }

    private func openSecureChildDirectory(
        parent: Int32,
        name: String
    ) throws -> Int32 {
        var pathStatus = stat()
        let statusResult = name.withCString { pointer in
            fstatat(parent, pointer, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard statusResult == 0,
              isDirectory(pathStatus),
              pathStatus.st_uid == expectedUserID,
              pathStatus.st_mode & mode_t(0o022) == 0
        else {
            throw VoiceASRArtifactStoreError.unsafeManagedDirectory
        }
        let descriptor = name.withCString { pointer in
            openat(
                parent,
                pointer,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw VoiceASRArtifactStoreError.unsafeManagedDirectory
        }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              sameFile(pathStatus, openedStatus),
              isDirectory(openedStatus),
              openedStatus.st_uid == expectedUserID,
              openedStatus.st_mode & mode_t(0o022) == 0,
              voiceASRDescriptorHasNoExtendedACL(descriptor)
        else {
            close(descriptor)
            throw VoiceASRArtifactStoreError.unsafeManagedDirectory
        }
        return descriptor
    }

    private func openLockFile(root: Int32) throws -> Int32 {
        let createdDescriptor = Self.lockName.withCString { name in
            openat(
                root,
                name,
                O_RDWR | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW
                    | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        let descriptor: Int32
        let created: Bool
        if createdDescriptor >= 0 {
            descriptor = createdDescriptor
            created = true
        } else {
            let creationError = errno
            guard creationError == EEXIST else {
                throw VoiceASRArtifactStoreError.ioFailure(creationError)
            }
            descriptor = Self.lockName.withCString { name in
                openat(
                    root,
                    name,
                    O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw VoiceASRArtifactStoreError.unsafeManagedDirectory
            }
            created = false
        }
        var keepDescriptorOpen = false
        defer {
            if !keepDescriptorOpen {
                close(descriptor)
            }
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              isRegularFile(status),
              status.st_uid == expectedUserID,
              status.st_nlink == 1
        else {
            throw VoiceASRArtifactStoreError.unsafeManagedDirectory
        }
        if created,
           fchmod(descriptor, mode_t(0o600)) != 0 {
            throw VoiceASRArtifactStoreError.ioFailure(errno)
        }
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(0o777) == mode_t(0o600),
              voiceASRDescriptorHasNoExtendedACL(descriptor)
        else {
            throw VoiceASRArtifactStoreError.unsafeManagedDirectory
        }
        keepDescriptorOpen = true
        return descriptor
    }

    private func readSecureSmallFile(
        named name: String,
        maximumBytes: Int,
        securityError: VoiceASRArtifactStoreError,
        corruptError: VoiceASRArtifactStoreError,
        context: DirectoryContext
    ) throws -> Data? {
        var pathStatus = stat()
        let statusResult = name.withCString { value in
            fstatat(
                context.root,
                value,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if statusResult != 0 {
            if errno == ENOENT {
                return nil
            }
            throw VoiceASRArtifactStoreError.ioFailure(errno)
        }
        guard secureSmallFile(pathStatus),
              pathStatus.st_size > 0,
              pathStatus.st_size <= off_t(maximumBytes)
        else {
            if !secureSmallFile(pathStatus) {
                throw securityError
            }
            throw corruptError
        }

        let descriptor = name.withCString { value in
            openat(
                context.root,
                value,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw securityError
        }
        defer { close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              sameFile(pathStatus, openedStatus),
              secureSmallFile(openedStatus),
              voiceASRDescriptorHasNoExtendedACL(descriptor)
        else {
            throw securityError
        }
        return try readData(
            from: descriptor,
            maximumBytes: maximumBytes,
            corruptError: corruptError
        )
    }

    private func atomicWriteSmallFile(
        _ data: Data,
        destinationName: String,
        securityError: VoiceASRArtifactStoreError,
        context: DirectoryContext
    ) throws {
        let temporaryName = ".selector-write-\(UUID().uuidString)"
        let descriptor = temporaryName.withCString { value in
            openat(
                context.staging,
                value,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw VoiceASRArtifactStoreError.ioFailure(errno)
        }
        var renamed = false
        defer {
            close(descriptor)
            if !renamed {
                temporaryName.withCString { value in
                    _ = unlinkat(context.staging, value, 0)
                }
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw VoiceASRArtifactStoreError.ioFailure(errno)
        }
        try writeData(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw VoiceASRArtifactStoreError.ioFailure(errno)
        }
        try validateExistingSmallFileIfPresent(
            named: destinationName,
            securityError: securityError,
            context: context
        )
        let renameResult = temporaryName.withCString { source in
            destinationName.withCString { destination in
                renameat(
                    context.staging,
                    source,
                    context.root,
                    destination
                )
            }
        }
        guard renameResult == 0 else {
            throw VoiceASRArtifactStoreError.ioFailure(errno)
        }
        renamed = true
        try synchronizeRename(context)
    }

    private func atomicRemoveSmallFile(
        named name: String,
        securityError: VoiceASRArtifactStoreError,
        context: DirectoryContext
    ) throws {
        let exists = try validateExistingSmallFileIfPresent(
            named: name,
            securityError: securityError,
            context: context
        )
        guard exists else {
            return
        }
        let tombstoneName = ".selector-remove-\(UUID().uuidString)"
        let renameResult = name.withCString { source in
            tombstoneName.withCString { destination in
                renameat(
                    context.root,
                    source,
                    context.staging,
                    destination
                )
            }
        }
        guard renameResult == 0 else {
            throw VoiceASRArtifactStoreError.ioFailure(errno)
        }
        try synchronizeRename(context)
        let unlinkResult = tombstoneName.withCString { value in
            unlinkat(context.staging, value, 0)
        }
        guard unlinkResult == 0,
              fsync(context.staging) == 0
        else {
            throw VoiceASRArtifactStoreError.ioFailure(errno)
        }
    }

    @discardableResult
    private func validateExistingSmallFileIfPresent(
        named name: String,
        securityError: VoiceASRArtifactStoreError,
        context: DirectoryContext
    ) throws -> Bool {
        var status = stat()
        let result = name.withCString { value in
            fstatat(
                context.root,
                value,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result != 0 {
            if errno == ENOENT {
                return false
            }
            throw VoiceASRArtifactStoreError.ioFailure(errno)
        }
        guard secureSmallFile(status),
              voiceASRPathHasNoExtendedACL(
                  layout.voiceASRDirectory.appendingPathComponent(name).path
              )
        else {
            throw securityError
        }
        return true
    }

    private func synchronizeRename(_ context: DirectoryContext) throws {
        guard fsync(context.root) == 0,
              fsync(context.staging) == 0
        else {
            throw VoiceASRArtifactStoreError.ioFailure(errno)
        }
    }

    private func readData(
        from descriptor: Int32,
        maximumBytes: Int,
        corruptError: VoiceASRArtifactStoreError
    ) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while data.count <= maximumBytes {
            let capacity = min(
                buffer.count,
                maximumBytes + 1 - data.count
            )
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, capacity)
            }
            if count == 0 {
                return data
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw VoiceASRArtifactStoreError.ioFailure(errno)
            }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > maximumBytes {
                throw corruptError
            }
        }
        throw corruptError
    }

    private func writeData(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw VoiceASRArtifactStoreError.ioFailure(errno)
                }
                written += count
            }
        }
    }

    private func secureSmallFile(_ status: stat) -> Bool {
        isRegularFile(status)
            && status.st_uid == expectedUserID
            && status.st_mode & mode_t(0o777) == mode_t(0o600)
            && status.st_nlink == 1
    }

    private func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private func isDirectory(_ status: stat) -> Bool {
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private func isRegularFile(_ status: stat) -> Bool {
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
}

private func voiceASRPathHasNoExtendedACL(_ path: String) -> Bool {
    errno = 0
    guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else {
        return errno == ENOENT
    }
    acl_free(UnsafeMutableRawPointer(acl))
    return false
}

private func voiceASRDescriptorHasNoExtendedACL(_ descriptor: Int32) -> Bool {
    errno = 0
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
        return errno == ENOENT
    }
    acl_free(UnsafeMutableRawPointer(acl))
    return false
}
