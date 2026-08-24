import Darwin
import Foundation

struct VoicePerformancePOSIXError: Error, Equatable, Sendable {
    let code: Int32
}

enum VoicePerformanceFileKind: Equatable, Sendable {
    case regular
    case directory
    case other
}

struct VoicePerformanceFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let kind: VoicePerformanceFileKind
    let permissions: UInt16
    let linkCount: UInt64
    let owner: UInt32
    let size: UInt64

    init(
        device: UInt64,
        inode: UInt64,
        kind: VoicePerformanceFileKind,
        permissions: UInt16,
        linkCount: UInt64,
        owner: UInt32,
        size: UInt64 = 0
    ) {
        self.device = device
        self.inode = inode
        self.kind = kind
        self.permissions = permissions
        self.linkCount = linkCount
        self.owner = owner
        self.size = size
    }

    init(status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        let type = status.st_mode & mode_t(S_IFMT)
        switch type {
        case mode_t(S_IFREG): kind = .regular
        case mode_t(S_IFDIR): kind = .directory
        default: kind = .other
        }
        permissions = UInt16(status.st_mode & mode_t(0o7777))
        linkCount = UInt64(status.st_nlink)
        owner = status.st_uid
        size = status.st_size < 0 ? 0 : UInt64(status.st_size)
    }

    var isSecureResultFile: Bool {
        kind == .regular && permissions == 0o600 && linkCount == 1
    }

    func isSameNode(as other: Self) -> Bool {
        device == other.device && inode == other.inode && kind == other.kind
            && owner == other.owner
    }
}

protocol VoicePerformanceAtomicResultSystem: Sendable {
    var effectiveUserID: UInt32 { get }
    func openRootDirectory() throws -> Int32
    func openDirectory(named name: String, relativeTo parent: Int32) throws -> Int32
    func entryIdentity(named name: String, relativeTo parent: Int32) throws
        -> VoicePerformanceFileIdentity?
    func createExclusiveFile(named name: String, relativeTo parent: Int32) throws
        -> Int32
    func setMode0600(fileDescriptor: Int32) throws
    func hasExtendedACL(fileDescriptor: Int32) throws -> Bool
    func fileIdentity(fileDescriptor: Int32) throws -> VoicePerformanceFileIdentity
    func write(
        _ data: Data,
        offset: Int,
        fileDescriptor: Int32
    ) throws -> Int
    func synchronize(fileDescriptor: Int32) throws
    func renameExclusive(
        from source: String,
        to destination: String,
        relativeTo parent: Int32
    ) throws
    func remove(named name: String, relativeTo parent: Int32) throws
    func close(fileDescriptor: Int32)
}

struct DarwinVoicePerformanceAtomicResultSystem:
    VoicePerformanceAtomicResultSystem, Sendable
{
    var effectiveUserID: UInt32 { geteuid() }

    func openRootDirectory() throws -> Int32 {
        let descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw currentError() }
        return descriptor
    }

    func openDirectory(named name: String, relativeTo parent: Int32) throws
        -> Int32
    {
        let descriptor = name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else { throw currentError() }
        return descriptor
    }

    func entryIdentity(named name: String, relativeTo parent: Int32) throws
        -> VoicePerformanceFileIdentity?
    {
        var status = stat()
        let result = name.withCString {
            Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return VoicePerformanceFileIdentity(status: status) }
        if errno == ENOENT { return nil }
        throw currentError()
    }

    func createExclusiveFile(named name: String, relativeTo parent: Int32) throws
        -> Int32
    {
        let descriptor = name.withCString {
            Darwin.openat(
                parent,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw currentError() }
        return descriptor
    }

    func setMode0600(fileDescriptor: Int32) throws {
        guard Darwin.fchmod(fileDescriptor, mode_t(0o600)) == 0 else {
            throw currentError()
        }
    }

    func hasExtendedACL(fileDescriptor: Int32) throws -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(fileDescriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return false }
            throw currentError()
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return true
    }

    func fileIdentity(fileDescriptor: Int32) throws -> VoicePerformanceFileIdentity {
        var status = stat()
        guard Darwin.fstat(fileDescriptor, &status) == 0 else {
            throw currentError()
        }
        return VoicePerformanceFileIdentity(status: status)
    }

    func write(
        _ data: Data,
        offset: Int,
        fileDescriptor: Int32
    ) throws -> Int {
        let written = data.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            return Darwin.write(
                fileDescriptor,
                base.advanced(by: offset),
                bytes.count - offset
            )
        }
        guard written >= 0 else { throw currentError() }
        return written
    }

    func synchronize(fileDescriptor: Int32) throws {
        guard Darwin.fsync(fileDescriptor) == 0 else { throw currentError() }
    }

    func renameExclusive(
        from source: String,
        to destination: String,
        relativeTo parent: Int32
    ) throws {
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                Darwin.renameatx_np(
                    parent,
                    sourcePointer,
                    parent,
                    destinationPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else { throw currentError() }
    }

    func remove(named name: String, relativeTo parent: Int32) throws {
        let result = name.withCString { Darwin.unlinkat(parent, $0, 0) }
        guard result == 0 else { throw currentError() }
    }

    func close(fileDescriptor: Int32) {
        _ = Darwin.close(fileDescriptor)
    }

    private func currentError() -> VoicePerformancePOSIXError {
        VoicePerformancePOSIXError(code: errno)
    }
}

public struct VoicePerformanceAtomicResultWriter: Sendable {
    private let system: any VoicePerformanceAtomicResultSystem
    private let deadlineExpired: @Sendable (
        VoicePerformanceContinuousDeadline
    ) throws -> Bool

    public init() {
        system = DarwinVoicePerformanceAtomicResultSystem()
        deadlineExpired = { try $0.isExpired() }
    }

    init(system: any VoicePerformanceAtomicResultSystem) {
        self.system = system
        deadlineExpired = { try $0.isExpired() }
    }

    init(
        system: any VoicePerformanceAtomicResultSystem,
        deadlineExpired: @escaping @Sendable (
            VoicePerformanceContinuousDeadline
        ) throws -> Bool
    ) {
        self.system = system
        self.deadlineExpired = deadlineExpired
    }

    public func write(canonicalResult: Data, to resultPath: String) throws {
        try write(
            canonicalResult: canonicalResult,
            to: resultPath,
            protectingDirectories: [],
            deadline: nil
        )
    }

    public func write(
        canonicalResult: Data,
        to resultPath: String,
        before deadline: VoicePerformanceContinuousDeadline
    ) throws {
        try write(
            canonicalResult: canonicalResult,
            to: resultPath,
            protectingDirectories: [],
            deadline: deadline
        )
    }

    public func write(
        canonicalResult: Data,
        to resultPath: String,
        protectingDirectories protectedDirectoryPaths: [String]
    ) throws {
        try write(
            canonicalResult: canonicalResult,
            to: resultPath,
            protectingDirectories: protectedDirectoryPaths,
            deadline: nil
        )
    }

    public func write(
        canonicalResult: Data,
        to resultPath: String,
        protectingDirectories protectedDirectoryPaths: [String],
        before deadline: VoicePerformanceContinuousDeadline
    ) throws {
        try write(
            canonicalResult: canonicalResult,
            to: resultPath,
            protectingDirectories: protectedDirectoryPaths,
            deadline: deadline
        )
    }

    private func write(
        canonicalResult: Data,
        to resultPath: String,
        protectingDirectories protectedDirectoryPaths: [String],
        deadline: VoicePerformanceContinuousDeadline?
    ) throws {
        guard !canonicalResult.isEmpty,
            canonicalResult.count <= 1_048_576,
            !canonicalResult.contains(0x0a),
            !canonicalResult.contains(0x0d)
        else {
            throw VoicePerformanceTracerProcessError.resultWriteFailed
        }
        guard isCanonicalAbsolutePath(
            resultPath,
            requireTracerBundle: false
        ) else {
            throw VoicePerformanceTracerProcessError.invalidResultPath
        }
        let components = resultPath.dropFirst().split(separator: "/").map(String.init)
        guard let resultName = components.last else {
            throw VoicePerformanceTracerProcessError.invalidResultPath
        }

        let protectedDirectoryIdentities = try protectedDirectoryPaths.map {
            try directoryIdentity(at: $0)
        }
        let parentComponents = Array(components.dropLast())
        let parent = try openParent(
            components: parentComponents,
            rejecting: protectedDirectoryIdentities
        )
        defer { system.close(fileDescriptor: parent) }
        let parentIdentity: VoicePerformanceFileIdentity
        do {
            let identity = try fileIdentity(fileDescriptor: parent)
            guard identity.kind == .directory,
                identity.owner == system.effectiveUserID,
                identity.permissions & 0o077 == 0,
                try !hasExtendedACL(fileDescriptor: parent)
            else {
                throw VoicePerformanceTracerProcessError.invalidResultPath
            }
            parentIdentity = identity
        } catch let error as VoicePerformanceTracerProcessError {
            throw error
        } catch is VoicePerformancePOSIXError {
            throw VoicePerformanceTracerProcessError.invalidResultPath
        }
        let existing: VoicePerformanceFileIdentity?
        do {
            existing = try system.entryIdentity(named: resultName, relativeTo: parent)
        } catch is VoicePerformancePOSIXError {
            throw VoicePerformanceTracerProcessError.invalidResultPath
        }
        guard existing == nil else {
            throw VoicePerformanceTracerProcessError.resultAlreadyExists
        }

        try requireTimeRemaining(before: deadline)
        let (temporaryName, temporaryDescriptor) = try createTemporaryFile(parent: parent)
        var confirmedTemporaryIdentity: VoicePerformanceFileIdentity?
        var wasRenamed = false
        defer { system.close(fileDescriptor: temporaryDescriptor) }

        do {
            do {
                let createdIdentity = try fileIdentity(
                    fileDescriptor: temporaryDescriptor
                )
                guard createdIdentity.kind == .regular,
                      createdIdentity.owner == system.effectiveUserID,
                      createdIdentity.linkCount == 1,
                      createdIdentity.size == 0
                else {
                    throw VoicePerformanceTracerProcessError.resultWriteFailed
                }
                confirmedTemporaryIdentity = createdIdentity
                try setMode0600(fileDescriptor: temporaryDescriptor)
                let identity = try fileIdentity(
                    fileDescriptor: temporaryDescriptor
                )
                guard identity.isSecureResultFile,
                    identity.owner == system.effectiveUserID,
                    identity.size == 0,
                    try !hasExtendedACL(
                        fileDescriptor: temporaryDescriptor
                    )
                else {
                    throw VoicePerformanceTracerProcessError.resultWriteFailed
                }
                confirmedTemporaryIdentity = identity
                try writeAll(
                    canonicalResult,
                    fileDescriptor: temporaryDescriptor,
                    before: deadline
                )
                try synchronize(fileDescriptor: temporaryDescriptor)
                try requireTimeRemaining(before: deadline)
                let writtenIdentity = try fileIdentity(
                    fileDescriptor: temporaryDescriptor
                )
                guard writtenIdentity.isSameNode(as: identity),
                    writtenIdentity.isSecureResultFile,
                    writtenIdentity.permissions == identity.permissions,
                    writtenIdentity.linkCount == identity.linkCount,
                    writtenIdentity.size == UInt64(canonicalResult.count),
                    try !hasExtendedACL(
                        fileDescriptor: temporaryDescriptor
                    )
                else {
                    throw VoicePerformanceTracerProcessError.resultWriteFailed
                }
                confirmedTemporaryIdentity = writtenIdentity
            } catch let error as VoicePerformanceTracerProcessError {
                throw error
            } catch is VoicePerformancePOSIXError {
                throw VoicePerformanceTracerProcessError.resultWriteFailed
            }

            guard try pathStillNamesParent(
                components: parentComponents,
                expectedIdentity: parentIdentity,
                rejecting: protectedDirectoryIdentities
            ) else {
                throw VoicePerformanceTracerProcessError.resultCommitFailed
            }
            try requireTimeRemaining(before: deadline)

            do {
                try system.renameExclusive(
                    from: temporaryName,
                    to: resultName,
                    relativeTo: parent
                )
                wasRenamed = true
            } catch let error as VoicePerformancePOSIXError where error.code == EEXIST {
                throw VoicePerformanceTracerProcessError.resultAlreadyExists
            } catch is VoicePerformancePOSIXError {
                throw VoicePerformanceTracerProcessError.resultCommitFailed
            } catch {
                guard let installedIdentity = confirmedTemporaryIdentity else {
                    throw VoicePerformanceTracerProcessError
                        .resultInstallationIndeterminate
                }
                do {
                    let destination = try system.entryIdentity(
                        named: resultName,
                        relativeTo: parent
                    )
                    let temporary = try system.entryIdentity(
                        named: temporaryName,
                        relativeTo: parent
                    )
                    if destination == installedIdentity, temporary == nil {
                        try rollbackInstalledResult(
                            named: resultName,
                            identity: installedIdentity,
                            parent: parent
                        )
                    } else if destination == nil,
                              temporary == installedIdentity
                    {
                        // The exclusive rename did not commit. The outer
                        // failure path removes this exact temporary inode.
                    } else {
                        throw VoicePerformanceTracerProcessError
                            .resultInstallationIndeterminate
                    }
                } catch {
                    throw VoicePerformanceTracerProcessError
                        .resultInstallationIndeterminate
                }
                throw error
            }
            guard let installedIdentity = confirmedTemporaryIdentity else {
                throw VoicePerformanceTracerProcessError
                    .resultInstallationIndeterminate
            }
            try requireTimeRemainingAfterCommit(
                before: deadline,
                installedName: resultName,
                installedIdentity: installedIdentity,
                parent: parent
            )

            do {
                guard try system.entryIdentity(named: resultName, relativeTo: parent)
                    == confirmedTemporaryIdentity,
                    try !hasExtendedACL(
                        fileDescriptor: temporaryDescriptor
                    )
                else {
                    throw VoicePerformanceTracerProcessError.resultCommitFailed
                }
            } catch {
                let primary = error
                do {
                    try rollbackInstalledResult(
                        named: resultName,
                        identity: installedIdentity,
                        parent: parent
                    )
                } catch {
                    throw VoicePerformanceTracerProcessError
                        .resultInstallationIndeterminate
                }
                if primary is VoicePerformanceTracerProcessError
                    || primary is VoicePerformancePOSIXError
                {
                    throw VoicePerformanceTracerProcessError.resultCommitFailed
                }
                throw primary
            }

            do {
                try synchronize(fileDescriptor: parent)
            } catch {
                let primary = error
                do {
                    try rollbackInstalledResult(
                        named: resultName,
                        identity: installedIdentity,
                        parent: parent
                    )
                } catch {
                    throw VoicePerformanceTracerProcessError
                        .resultInstallationIndeterminate
                }
                if primary is VoicePerformancePOSIXError {
                    throw VoicePerformanceTracerProcessError
                        .resultDurabilityFailed
                }
                throw primary
            }
            try requireTimeRemainingAfterCommit(
                before: deadline,
                installedName: resultName,
                installedIdentity: installedIdentity,
                parent: parent
            )

            do {
                guard try pathStillNamesInstalledResult(
                    components: parentComponents,
                    expectedParentIdentity: parentIdentity,
                    resultName: resultName,
                    expectedResultIdentity: installedIdentity,
                    rejecting: protectedDirectoryIdentities
                ) else {
                    throw VoicePerformanceTracerProcessError
                        .resultInstallationIndeterminate
                }
            } catch {
                do {
                    try rollbackInstalledResult(
                        named: resultName,
                        identity: installedIdentity,
                        parent: parent
                    )
                } catch {
                    throw VoicePerformanceTracerProcessError
                        .resultInstallationIndeterminate
                }
                throw VoicePerformanceTracerProcessError
                    .resultInstallationIndeterminate
            }
            try requireTimeRemainingAfterCommit(
                before: deadline,
                installedName: resultName,
                installedIdentity: installedIdentity,
                parent: parent
            )
        } catch {
            if !wasRenamed {
                let cleanupIdentity = confirmedTemporaryIdentity
                    ?? revalidateTemporaryForCleanup(
                        fileDescriptor: temporaryDescriptor
                    )
                if let cleanupIdentity {
                    removeTemporaryIfUnchanged(
                        named: temporaryName,
                        identity: cleanupIdentity,
                        parent: parent
                    )
                }
            }
            throw error
        }
    }

    private func directoryIdentity(
        at path: String
    ) throws -> VoicePerformanceFileIdentity {
        guard isCanonicalAbsolutePath(path, requireTracerBundle: false),
              path != "/"
        else {
            throw VoicePerformanceTracerProcessError.invalidResultPath
        }
        let components = path.dropFirst().split(separator: "/").map(String.init)
        let descriptor = try openDirectory(components: components)
        defer { system.close(fileDescriptor: descriptor) }
        do {
            let identity = try fileIdentity(fileDescriptor: descriptor)
            guard identity.kind == .directory else {
                throw VoicePerformanceTracerProcessError.invalidResultPath
            }
            return identity
        } catch let error as VoicePerformanceTracerProcessError {
            throw error
        } catch is VoicePerformancePOSIXError {
            throw VoicePerformanceTracerProcessError.invalidResultPath
        }
    }

    private func openParent(
        components: [String],
        rejecting protectedIdentities: [VoicePerformanceFileIdentity]
    ) throws -> Int32 {
        try openDirectory(
            components: components,
            rejecting: protectedIdentities
        )
    }

    private func openDirectory(
        components: [String],
        rejecting protectedIdentities: [VoicePerformanceFileIdentity] = []
    ) throws -> Int32 {
        let root: Int32
        do {
            root = try system.openRootDirectory()
        } catch is VoicePerformancePOSIXError {
            throw VoicePerformanceTracerProcessError.invalidResultPath
        }
        var current = root
        var currentIdentity: VoicePerformanceFileIdentity
        do {
            currentIdentity = try fileIdentity(fileDescriptor: current)
            try rejectProtectedDirectory(
                identity: currentIdentity,
                protectedIdentities: protectedIdentities
            )
        } catch let error as VoicePerformanceTracerProcessError {
            system.close(fileDescriptor: current)
            throw error
        } catch is VoicePerformancePOSIXError {
            system.close(fileDescriptor: current)
            throw VoicePerformanceTracerProcessError.invalidResultPath
        } catch {
            system.close(fileDescriptor: current)
            throw error
        }
        for component in components {
            let next: Int32
            do {
                next = try system.openDirectory(
                    named: component,
                    relativeTo: current
                )
            } catch is VoicePerformancePOSIXError {
                system.close(fileDescriptor: current)
                throw VoicePerformanceTracerProcessError.invalidResultPath
            } catch {
                system.close(fileDescriptor: current)
                throw error
            }
            do {
                let nextIdentity = try fileIdentity(
                    fileDescriptor: next
                )
                try validateDirectoryEdge(
                    parentDescriptor: current,
                    parentIdentity: currentIdentity,
                    childIdentity: nextIdentity
                )
                try rejectProtectedDirectory(
                    identity: nextIdentity,
                    protectedIdentities: protectedIdentities
                )
                currentIdentity = nextIdentity
            } catch let error as VoicePerformanceTracerProcessError {
                system.close(fileDescriptor: next)
                system.close(fileDescriptor: current)
                throw error
            } catch is VoicePerformancePOSIXError {
                system.close(fileDescriptor: next)
                system.close(fileDescriptor: current)
                throw VoicePerformanceTracerProcessError.invalidResultPath
            } catch {
                system.close(fileDescriptor: next)
                system.close(fileDescriptor: current)
                throw error
            }
            system.close(fileDescriptor: current)
            current = next
        }
        do {
            guard currentIdentity.kind == .directory,
                  currentIdentity.owner == 0
                    || currentIdentity.owner == system.effectiveUserID,
                  currentIdentity.permissions & 0o6000 == 0,
                  try !hasExtendedACL(fileDescriptor: current)
            else {
                throw VoicePerformanceTracerProcessError.invalidResultPath
            }
        } catch let error as VoicePerformanceTracerProcessError {
            system.close(fileDescriptor: current)
            throw error
        } catch is VoicePerformancePOSIXError {
            system.close(fileDescriptor: current)
            throw VoicePerformanceTracerProcessError.invalidResultPath
        } catch {
            system.close(fileDescriptor: current)
            throw error
        }
        return current
    }

    private func rejectProtectedDirectory(
        identity: VoicePerformanceFileIdentity,
        protectedIdentities: [VoicePerformanceFileIdentity]
    ) throws {
        guard !protectedIdentities.contains(where: {
            identity.device == $0.device && identity.inode == $0.inode
        }) else {
            throw VoicePerformanceTracerProcessError.invalidResultPath
        }
    }

    private func validateDirectoryEdge(
        parentDescriptor: Int32,
        parentIdentity: VoicePerformanceFileIdentity,
        childIdentity: VoicePerformanceFileIdentity
    ) throws {
        guard parentIdentity.kind == .directory,
              childIdentity.kind == .directory,
              parentIdentity.owner == 0
                || parentIdentity.owner == system.effectiveUserID,
              childIdentity.owner == 0
                || childIdentity.owner == system.effectiveUserID,
              parentIdentity.permissions & 0o6000 == 0,
              try !hasExtendedACL(fileDescriptor: parentDescriptor)
        else {
            throw VoicePerformanceTracerProcessError.invalidResultPath
        }
        guard parentIdentity.permissions & 0o022 != 0 else { return }
        guard parentIdentity.owner == 0,
              parentIdentity.permissions & 0o1000 != 0,
              childIdentity.owner == 0
                || childIdentity.owner == system.effectiveUserID
        else {
            throw VoicePerformanceTracerProcessError.invalidResultPath
        }
    }

    private func pathStillNamesParent(
        components: [String],
        expectedIdentity: VoicePerformanceFileIdentity,
        rejecting protectedIdentities: [VoicePerformanceFileIdentity]
    ) throws -> Bool {
        let reopened = try openDirectory(
            components: components,
            rejecting: protectedIdentities
        )
        defer { system.close(fileDescriptor: reopened) }
        return try fileIdentity(fileDescriptor: reopened)
            .isSameNode(as: expectedIdentity)
    }

    private func pathStillNamesInstalledResult(
        components: [String],
        expectedParentIdentity: VoicePerformanceFileIdentity,
        resultName: String,
        expectedResultIdentity: VoicePerformanceFileIdentity,
        rejecting protectedIdentities: [VoicePerformanceFileIdentity]
    ) throws -> Bool {
        let reopened = try openDirectory(
            components: components,
            rejecting: protectedIdentities
        )
        defer { system.close(fileDescriptor: reopened) }
        guard try fileIdentity(fileDescriptor: reopened)
                .isSameNode(as: expectedParentIdentity),
              let result = try system.entryIdentity(
                  named: resultName,
                  relativeTo: reopened
              )
        else {
            return false
        }
        return result == expectedResultIdentity
    }

    private func createTemporaryFile(parent: Int32) throws -> (String, Int32) {
        for _ in 0..<8 {
            let name = ".rimeai-voice-performance-result.\(UUID().uuidString.lowercased()).tmp"
            do {
                return (
                    name,
                    try system.createExclusiveFile(named: name, relativeTo: parent)
                )
            } catch let error as VoicePerformancePOSIXError where error.code == EEXIST {
                continue
            } catch is VoicePerformancePOSIXError {
                throw VoicePerformanceTracerProcessError.resultWriteFailed
            }
        }
        throw VoicePerformanceTracerProcessError.resultWriteFailed
    }

    private func setMode0600(fileDescriptor: Int32) throws {
        while true {
            do {
                try system.setMode0600(fileDescriptor: fileDescriptor)
                return
            } catch let error as VoicePerformancePOSIXError
                where error.code == EINTR
            {
                continue
            }
        }
    }

    private func fileIdentity(
        fileDescriptor: Int32
    ) throws -> VoicePerformanceFileIdentity {
        while true {
            do {
                return try system.fileIdentity(
                    fileDescriptor: fileDescriptor
                )
            } catch let error as VoicePerformancePOSIXError
                where error.code == EINTR
            {
                continue
            }
        }
    }

    private func hasExtendedACL(fileDescriptor: Int32) throws -> Bool {
        while true {
            do {
                return try system.hasExtendedACL(
                    fileDescriptor: fileDescriptor
                )
            } catch let error as VoicePerformancePOSIXError
                where error.code == EINTR
            {
                continue
            }
        }
    }

    private func revalidateTemporaryForCleanup(
        fileDescriptor: Int32
    ) -> VoicePerformanceFileIdentity? {
        guard let identity = try? fileIdentity(
            fileDescriptor: fileDescriptor
        ),
              identity.kind == .regular,
              identity.owner == system.effectiveUserID,
              identity.linkCount == 1
        else {
            return nil
        }
        return identity
    }

    private func writeAll(
        _ data: Data,
        fileDescriptor: Int32,
        before deadline: VoicePerformanceContinuousDeadline?
    ) throws {
        var offset = 0
        while offset < data.count {
            do {
                let count = try system.write(
                    data,
                    offset: offset,
                    fileDescriptor: fileDescriptor
                )
                guard count > 0, count <= data.count - offset else {
                    throw VoicePerformanceTracerProcessError.resultWriteFailed
                }
                offset += count
                try requireTimeRemaining(before: deadline)
            } catch let error as VoicePerformancePOSIXError where error.code == EINTR {
                continue
            }
        }
    }

    private func requireTimeRemaining(
        before deadline: VoicePerformanceContinuousDeadline?
    ) throws {
        guard let deadline else { return }
        guard try !deadlineExpired(deadline) else {
            throw VoicePerformanceTracerProcessError.deadlineExpired
        }
    }

    private func requireTimeRemainingAfterCommit(
        before deadline: VoicePerformanceContinuousDeadline?,
        installedName: String,
        installedIdentity: VoicePerformanceFileIdentity,
        parent: Int32
    ) throws {
        do {
            try requireTimeRemaining(before: deadline)
        } catch {
            do {
                try rollbackInstalledResult(
                    named: installedName,
                    identity: installedIdentity,
                    parent: parent
                )
            } catch {
                throw VoicePerformanceTracerProcessError
                    .resultInstallationIndeterminate
            }
            throw error
        }
    }

    private func synchronize(fileDescriptor: Int32) throws {
        while true {
            do {
                try system.synchronize(fileDescriptor: fileDescriptor)
                return
            } catch let error as VoicePerformancePOSIXError where error.code == EINTR {
                continue
            }
        }
    }

    private func removeTemporaryIfUnchanged(
        named name: String,
        identity: VoicePerformanceFileIdentity,
        parent: Int32
    ) {
        guard let current = try? system.entryIdentity(
            named: name,
            relativeTo: parent
        ), current.isSameNode(as: identity) else {
            return
        }
        try? system.remove(named: name, relativeTo: parent)
    }

    private func rollbackInstalledResult(
        named name: String,
        identity: VoicePerformanceFileIdentity,
        parent: Int32
    ) throws {
        guard let current = try system.entryIdentity(
            named: name,
            relativeTo: parent
        ), current == identity else {
            throw VoicePerformanceTracerProcessError
                .resultInstallationIndeterminate
        }
        try system.remove(named: name, relativeTo: parent)
        guard try system.entryIdentity(named: name, relativeTo: parent) == nil else {
            throw VoicePerformanceTracerProcessError
                .resultInstallationIndeterminate
        }
        try synchronize(fileDescriptor: parent)
    }
}
