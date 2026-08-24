import Darwin
import CryptoKit
import Foundation
#if canImport(RimeAIVoiceArtifactCore)
@_spi(RimeAIInternal) import RimeAIVoiceArtifactCore
#endif

/// Immutable audit references for the independent reviews that authorize a
/// product-managed ASR release. This evidence is compiled into the product;
/// it is never accepted from an imported artifact.
public struct VoiceASRReleaseEvidence: Equatable, Sendable {
    public let sourceReviewID: String
    public let modelRightsReviewID: String
    public let redistributionReviewID: String
    public let qualityReportSHA256: String

    init(
        sourceReviewID: String,
        modelRightsReviewID: String,
        redistributionReviewID: String,
        qualityReportSHA256: String
    ) {
        self.sourceReviewID = sourceReviewID
        self.modelRightsReviewID = modelRightsReviewID
        self.redistributionReviewID = redistributionReviewID
        self.qualityReportSHA256 = qualityReportSHA256
    }

    fileprivate var isValid: Bool {
        Self.isControlledIdentifier(sourceReviewID)
            && Self.isControlledIdentifier(modelRightsReviewID)
            && Self.isControlledIdentifier(redistributionReviewID)
            && Self.isSHA256(qualityReportSHA256)
    }

    private static func isControlledIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              let first = value.utf8.first,
              isASCIIAlphaNumeric(first)
        else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { byte in
            isASCIIAlphaNumeric(byte)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x61 && byte <= 0x66)
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
    }
}

/// A release approval compiled into the product. Unlike the artifact manifest,
/// this value is not supplied by the imported directory.
public struct VoiceASRTrustedArtifactApproval: Equatable, Sendable {
    public let artifactID: VoiceASRArtifactID
    public let contentSHA256: String
    public let adapterID: String
    public let adapterVersion: String
    public let adapterABIVersion: Int
    public let modelID: String
    public let modelRevision: String
    public let modelFormat: VoiceASRArtifactManifest.ModelFormat
    public let modelQuantization: VoiceASRArtifactManifest.ModelQuantization
    public let licenseSPDXID: String
    public let licensePath: String
    public let noticePath: String
    public let sourceURL: String
    public let redistributionApproved: Bool
    public let releaseEvidence: VoiceASRReleaseEvidence

    init(
        artifactID: VoiceASRArtifactID,
        contentSHA256: String,
        adapterID: String,
        adapterVersion: String,
        adapterABIVersion: Int,
        modelID: String,
        modelRevision: String,
        modelFormat: VoiceASRArtifactManifest.ModelFormat,
        modelQuantization: VoiceASRArtifactManifest.ModelQuantization,
        licenseSPDXID: String,
        licensePath: String,
        noticePath: String,
        sourceURL: String,
        redistributionApproved: Bool,
        releaseEvidence: VoiceASRReleaseEvidence
    ) {
        self.artifactID = artifactID
        self.contentSHA256 = contentSHA256
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.adapterABIVersion = adapterABIVersion
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.modelFormat = modelFormat
        self.modelQuantization = modelQuantization
        self.licenseSPDXID = licenseSPDXID
        self.licensePath = licensePath
        self.noticePath = noticePath
        self.sourceURL = sourceURL
        self.redistributionApproved = redistributionApproved
        self.releaseEvidence = releaseEvidence
    }

    fileprivate func approves(_ artifact: VoiceASRVerifiedArtifact) -> Bool {
        let manifest = artifact.manifest
        return isValidReleaseApproval
            && artifactID == manifest.artifactID
            && contentSHA256 == artifact.contentSHA256
            && contentSHA256 == manifest.contentSHA256
            && adapterID == manifest.adapter.id
            && adapterVersion == manifest.adapter.version
            && adapterABIVersion == manifest.adapter.abiVersion
            && modelID == manifest.model.id
            && modelRevision == manifest.model.revision
            && modelFormat == manifest.model.format
            && modelQuantization == manifest.model.quantization
            && licenseSPDXID == manifest.license.spdxID
            && licensePath == manifest.license.licensePath
            && noticePath == manifest.license.noticePath
            && sourceURL == manifest.license.sourceURL
            && redistributionApproved
    }

    fileprivate var isValidReleaseApproval: Bool {
        redistributionApproved
            && releaseEvidence.isValid
            && Self.isSHA256(contentSHA256)
            && Self.isControlledIdentifier(adapterID, maximumBytes: 128)
            && Self.isBoundedASCIIValue(adapterVersion, maximumBytes: 64)
            && (1 ... 65_535).contains(adapterABIVersion)
            && Self.isControlledIdentifier(modelID, maximumBytes: 128)
            && Self.isBoundedASCIIValue(modelRevision, maximumBytes: 128)
            && Self.isSPDXID(licenseSPDXID)
            && licensePath != noticePath
            && Self.isCanonicalRelativePath(licensePath)
            && Self.isCanonicalRelativePath(noticePath)
            && Self.isHTTPSURLWithoutCredentials(sourceURL)
    }

    fileprivate var canonicalCatalogRecord: Data {
        let fields = [
            artifactID.rawValue,
            contentSHA256,
            adapterID,
            adapterVersion,
            String(adapterABIVersion),
            modelID,
            modelRevision,
            modelFormat.rawValue,
            modelQuantization.rawValue,
            licenseSPDXID,
            licensePath,
            noticePath,
            sourceURL,
            redistributionApproved ? "true" : "false",
            releaseEvidence.sourceReviewID,
            releaseEvidence.modelRightsReviewID,
            releaseEvidence.redistributionReviewID,
            releaseEvidence.qualityReportSHA256,
        ]
        var data = Data()
        data.appendUInt64BigEndian(UInt64(fields.count))
        for field in fields {
            data.appendLengthPrefixedUTF8(field)
        }
        return data
    }

    private static func isControlledIdentifier(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              let first = value.utf8.first,
              isASCIIAlphaNumeric(first)
        else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { byte in
            isASCIIAlphaNumeric(byte)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
        }
    }

    private static func isBoundedASCIIValue(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    private static func isSPDXID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            isASCIIAlphaNumeric(byte)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x2B
        }
    }

    private static func isCanonicalRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= 512,
              path == path.precomposedStringWithCanonicalMapping,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !path.contains("//"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 })
        else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.allSatisfy { component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && component.utf8.count <= 255
                && !component.hasPrefix("._")
        }
    }

    private static func isHTTPSURLWithoutCredentials(_ value: String) -> Bool {
        guard value.utf8.count <= 2_048,
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil
        else {
            return false
        }
        return true
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x61 && byte <= 0x66)
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
    }
}

/// Product trust is intentionally independent from data supplied by an import.
/// The production list remains empty until a runtime/model/license cohort has
/// completed source and redistribution review.
public struct VoiceASRTrustedArtifactCatalog: Sendable {
    public static let production = Self(approvals: [])

    private static let digestDomain =
        "rimeai.voice-asr.trusted-artifact-catalog.v2"

    private let approvals: [VoiceASRTrustedArtifactApproval]

    init(approvals: [VoiceASRTrustedArtifactApproval]) {
        self.approvals = approvals
    }

    public var isEmpty: Bool {
        approvals.isEmpty
    }

    /// True only when the complete catalog is structurally fit for Release.
    /// A mixed valid/invalid catalog or duplicate artifact identity fails
    /// closed rather than treating its valid subset as an approval cohort.
    public var hasReleaseApprovals: Bool {
        guard !approvals.isEmpty,
              approvals.allSatisfy(\.isValidReleaseApproval)
        else {
            return false
        }
        return Set(approvals.map(\.artifactID)).count == approvals.count
    }

    /// Stable identity of the complete code-shipped approval cohort.
    ///
    /// Records are encoded independently with fixed field order and UInt64
    /// big-endian length prefixes, sorted by their encoded bytes, then hashed
    /// under a versioned domain. Every approval field, including the explicit
    /// redistribution decision and all release evidence, participates in the
    /// digest.
    public var canonicalSHA256: String {
        let records = approvals.map(\.canonicalCatalogRecord).sorted {
            $0.lexicographicallyPrecedes($1)
        }
        var canonical = Data()
        canonical.appendLengthPrefixedUTF8(Self.digestDomain)
        canonical.appendUInt64BigEndian(UInt64(records.count))
        for record in records {
            canonical.appendUInt64BigEndian(UInt64(record.count))
            canonical.append(record)
        }
        return SHA256.hash(data: canonical).map {
            String(format: "%02x", $0)
        }.joined()
    }

    public var approvedArtifactIDs: [VoiceASRArtifactID] {
        approvals.map(\.artifactID).sorted {
            $0.rawValue < $1.rawValue
        }
    }

    /// Returns whether the independently verified artifact exactly matches a
    /// code-shipped approval. Runtime assembly must repeat this check; a
    /// selector file alone is not product authorization.
    public func approves(_ artifact: VoiceASRVerifiedArtifact) -> Bool {
        approvals.contains { $0.approves(artifact) }
    }
}

private extension Data {
    mutating func appendUInt64BigEndian(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendLengthPrefixedUTF8(_ value: String) {
        let encoded = Data(value.utf8)
        appendUInt64BigEndian(UInt64(encoded.count))
        append(encoded)
    }
}

public enum VoiceASRArtifactPublishDisposition: String, Equatable, Sendable {
    case published
    case alreadyPublished = "already-published"
}

public struct VoiceASRArtifactPublishResult: Equatable, Sendable {
    public let disposition: VoiceASRArtifactPublishDisposition
    public let artifact: VoiceASRVerifiedArtifact
    public let selectorState: VoiceASRSelectorState?

    fileprivate init(
        disposition: VoiceASRArtifactPublishDisposition,
        artifact: VoiceASRVerifiedArtifact,
        selectorState: VoiceASRSelectorState?
    ) {
        self.disposition = disposition
        self.artifact = artifact
        self.selectorState = selectorState
    }
}

public enum VoiceASRArtifactPublisherError: Error, Equatable, Sendable {
    case sourceMustBeLocalDirectory
    case untrustedArtifact(VoiceASRArtifactID)
    case immutableReleaseConflict(VoiceASRArtifactID)
    case unsafeExistingRelease(VoiceASRArtifactID)
    case unsafeManagedDirectory
    case unsafeStagingDirectory
    case stagingCleanupFailed
    case ioFailure(path: String, errno: Int32)
}

/// Offline-only importer for immutable, product-managed ASR releases.
public final class VoiceASRArtifactPublisher: @unchecked Sendable {
    public let layout: RimeAIProductDataLayout

    private static let processLock = NSLock()
    private static let lockName = ".publisher.lock"
    private static let stagingPrefix = ".import-"

    private let trustedCatalog: VoiceASRTrustedArtifactCatalog
    private let verifier: any VoiceASRArtifactVerifying
    private let expectedUserID: uid_t

    public init(layout: RimeAIProductDataLayout) {
        self.layout = layout
        trustedCatalog = .production
        verifier = VoiceASRArtifactVerifier()
        expectedUserID = geteuid()
    }

    init(
        layout: RimeAIProductDataLayout,
        trustedCatalog: VoiceASRTrustedArtifactCatalog,
        verifier: any VoiceASRArtifactVerifying = VoiceASRArtifactVerifier()
    ) {
        self.layout = layout
        self.trustedCatalog = trustedCatalog
        self.verifier = verifier
        expectedUserID = geteuid()
    }

    @discardableResult
    public func publishLocalArtifact(
        from sourceDirectory: URL,
        activate: Bool = false
    ) throws -> VoiceASRArtifactPublishResult {
        guard sourceDirectory.isFileURL,
              Self.isCanonicalAbsolutePath(sourceDirectory.path)
        else {
            throw VoiceASRArtifactPublisherError.sourceMustBeLocalDirectory
        }
        let source = try verifier.verifyArtifact(at: sourceDirectory)
        guard source.artifactDirectory.isFileURL,
              source.artifactDirectory.path.utf8.elementsEqual(
                  sourceDirectory.path.utf8
              )
        else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(".")
        }
        guard trustedCatalog.approves(source) else {
            throw VoiceASRArtifactPublisherError.untrustedArtifact(
                source.manifest.artifactID
            )
        }

        let published = try withExclusivePublishLock { context in
            try publishVerifiedSource(
                source,
                sourceDirectory: sourceDirectory,
                context: context
            )
        }
        let selectorState = activate
            ? try VoiceASRArtifactStore(
                layout: layout,
                verifier: verifier
            ).activate(source.manifest.artifactID)
            : nil
        return VoiceASRArtifactPublishResult(
            disposition: published.disposition,
            artifact: published.artifact,
            selectorState: selectorState
        )
    }

    private struct DirectoryContext {
        let root: Int32
        let releases: Int32
        let staging: Int32
    }

    private struct PublishedArtifact {
        let disposition: VoiceASRArtifactPublishDisposition
        let artifact: VoiceASRVerifiedArtifact
    }

    private struct OpenedRegularFile {
        let descriptor: Int32
        let status: stat
    }

    private struct OpenedSourceDirectory {
        let descriptor: Int32
        let namedStatus: stat
    }

    private func publishVerifiedSource(
        _ source: VoiceASRVerifiedArtifact,
        sourceDirectory: URL,
        context: DirectoryContext
    ) throws -> PublishedArtifact {
        let artifactID = source.manifest.artifactID
        if let existing = try verifiedExistingRelease(
            artifactID,
            context: context
        ) {
            guard existing.contentSHA256 == source.contentSHA256,
                  existing.manifest == source.manifest
            else {
                throw VoiceASRArtifactPublisherError
                    .immutableReleaseConflict(artifactID)
            }
            guard trustedCatalog.approves(existing) else {
                throw VoiceASRArtifactPublisherError.untrustedArtifact(
                    artifactID
                )
            }
            return PublishedArtifact(
                disposition: .alreadyPublished,
                artifact: existing
            )
        }

        let stagingName = Self.stagingPrefix + UUID().uuidString
        let stagingURL = layout.voiceASRStagingDirectory.appendingPathComponent(
            stagingName,
            isDirectory: true
        )
        let stagingDescriptor = try createPrivateStagingDirectory(
            named: stagingName,
            context: context
        )
        defer { close(stagingDescriptor) }
        var renamed = false
        do {
            try copyArtifact(
                source,
                sourceDirectory: sourceDirectory,
                destinationRoot: stagingDescriptor
            )
            guard fsync(stagingDescriptor) == 0 else {
                throw ioError(path: stagingURL.path)
            }

            let staged = try verifier.verifyArtifact(at: stagingURL)
            guard staged.manifest == source.manifest,
                  staged.contentSHA256 == source.contentSHA256,
                  trustedCatalog.approves(staged)
            else {
                throw VoiceASRArtifactPublisherError.untrustedArtifact(
                    artifactID
                )
            }
            try revalidatePrivateStaging(
                named: stagingName,
                expectedDescriptor: stagingDescriptor,
                context: context
            )

            let renameResult = stagingName.withCString { sourceName in
                artifactID.rawValue.withCString { destinationName in
                    renameatx_np(
                        context.staging,
                        sourceName,
                        context.releases,
                        destinationName,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            if renameResult != 0 {
                let renameError = errno
                if renameError == EEXIST,
                   let existing = try verifiedExistingRelease(
                       artifactID,
                       context: context
                   )
                {
                    guard existing.contentSHA256 == source.contentSHA256,
                          existing.manifest == source.manifest,
                          trustedCatalog.approves(existing)
                    else {
                        throw VoiceASRArtifactPublisherError
                            .immutableReleaseConflict(artifactID)
                    }
                    try removeTreeIfPresent(
                        parent: context.staging,
                        name: stagingName,
                        displayPath: stagingURL.path
                    )
                    guard fsync(context.staging) == 0 else {
                        throw ioError(
                            path: layout.voiceASRStagingDirectory.path
                        )
                    }
                    return PublishedArtifact(
                        disposition: .alreadyPublished,
                        artifact: existing
                    )
                }
                throw VoiceASRArtifactPublisherError.ioFailure(
                    path: layout.voiceASRReleaseDirectory(
                        for: artifactID
                    ).path,
                    errno: renameError
                )
            }
            renamed = true
            guard fsync(context.releases) == 0,
                  fsync(context.staging) == 0
            else {
                throw ioError(path: layout.voiceASRDirectory.path)
            }
            try validatePublishedIdentity(
                artifactID,
                expectedDescriptor: stagingDescriptor,
                context: context
            )

            return PublishedArtifact(
                disposition: .published,
                artifact: VoiceASRVerifiedArtifact(
                    artifactDirectory: layout.voiceASRReleaseDirectory(
                        for: artifactID
                    ),
                    manifest: staged.manifest,
                    contentSHA256: staged.contentSHA256,
                    verifiedFileCount: staged.verifiedFileCount,
                    verifiedPayloadBytes: staged.verifiedPayloadBytes
                )
            )
        } catch {
            if !renamed {
                do {
                    try removeTreeIfPresent(
                        parent: context.staging,
                        name: stagingName,
                        displayPath: stagingURL.path
                    )
                    guard fsync(context.staging) == 0 else {
                        throw ioError(path: layout.voiceASRStagingDirectory.path)
                    }
                } catch {
                    throw VoiceASRArtifactPublisherError.stagingCleanupFailed
                }
            }
            throw error
        }
    }

    private func verifiedExistingRelease(
        _ artifactID: VoiceASRArtifactID,
        context: DirectoryContext
    ) throws -> VoiceASRVerifiedArtifact? {
        var status = stat()
        let statusResult = artifactID.rawValue.withCString { name in
            fstatat(
                context.releases,
                name,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if statusResult != 0 {
            if errno == ENOENT {
                return nil
            }
            throw ioError(
                path: layout.voiceASRReleaseDirectory(for: artifactID).path
            )
        }
        guard isDirectory(status),
              status.st_uid == expectedUserID,
              status.st_mode & mode_t(0o022) == 0
        else {
            throw VoiceASRArtifactPublisherError.unsafeExistingRelease(
                artifactID
            )
        }
        let descriptor = artifactID.rawValue.withCString { name in
            openat(
                context.releases,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw VoiceASRArtifactPublisherError.unsafeExistingRelease(
                artifactID
            )
        }
        defer { close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              sameFile(status, openedStatus),
              isDirectory(openedStatus),
              openedStatus.st_uid == expectedUserID,
              openedStatus.st_mode & mode_t(0o022) == 0,
              publisherDescriptorHasNoExtendedACL(descriptor)
        else {
            throw VoiceASRArtifactPublisherError.unsafeExistingRelease(
                artifactID
            )
        }
        let verified = try verifier.verifyArtifact(
            at: layout.voiceASRReleaseDirectory(for: artifactID)
        )
        guard verified.manifest.artifactID == artifactID else {
            throw VoiceASRArtifactPublisherError.unsafeExistingRelease(
                artifactID
            )
        }
        var finalPathStatus = stat()
        var finalOpenedStatus = stat()
        guard fstat(descriptor, &finalOpenedStatus) == 0,
              artifactID.rawValue.withCString({ name in
                  fstatat(
                      context.releases,
                      name,
                      &finalPathStatus,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              sameFile(openedStatus, finalOpenedStatus),
              sameFile(openedStatus, finalPathStatus),
              isDirectory(finalOpenedStatus),
              finalOpenedStatus.st_uid == expectedUserID,
              finalOpenedStatus.st_mode & mode_t(0o022) == 0,
              publisherDescriptorHasNoExtendedACL(descriptor)
        else {
            throw VoiceASRArtifactPublisherError.unsafeExistingRelease(
                artifactID
            )
        }
        return verified
    }

    private func copyArtifact(
        _ source: VoiceASRVerifiedArtifact,
        sourceDirectory: URL,
        destinationRoot: Int32
    ) throws {
        let sourceRoot = try openSecureSourceDirectory(sourceDirectory)
        defer { close(sourceRoot) }

        let directoryPaths = directoryPrefixes(
            for: source.manifest.inventory.map(\.path)
        ).sorted { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            return lhsDepth == rhsDepth ? lhs < rhs : lhsDepth < rhsDepth
        }
        for path in directoryPaths {
            try createPrivateDirectory(
                relativePath: path,
                rootDescriptor: destinationRoot
            )
        }

        try copyRegularFile(
            relativePath: VoiceASRArtifactManifest.manifestFileName,
            expectedBytes: nil,
            maximumBytes: Int64(
                VoiceASRArtifactVerificationLimits.production
                    .maximumManifestBytes
            ),
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot
        )
        for entry in source.manifest.inventory {
            try copyRegularFile(
                relativePath: entry.path,
                expectedBytes: entry.bytes,
                maximumBytes: entry.bytes,
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot
            )
        }

        for path in directoryPaths.reversed() {
            let descriptor = try openPrivateDirectory(
                relativePath: path,
                rootDescriptor: destinationRoot
            )
            if fsync(descriptor) != 0 {
                let savedErrno = errno
                close(descriptor)
                throw VoiceASRArtifactPublisherError.ioFailure(
                    path: path,
                    errno: savedErrno
                )
            }
            close(descriptor)
        }
        try revalidateSecureSourceDirectory(
            sourceRoot,
            at: sourceDirectory
        )
    }

    private func openSecureSourceDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL,
              Self.isCanonicalAbsolutePath(url.path)
        else {
            throw VoiceASRArtifactError.artifactRootMustBeDirectory
        }
        let opened = try openSourceDirectoryByComponents(url.path)
        let descriptor = opened.descriptor
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              sameFile(opened.namedStatus, openedStatus),
              isDirectory(openedStatus),
              openedStatus.st_uid == expectedUserID,
              openedStatus.st_mode & mode_t(0o022) == 0,
              publisherDescriptorHasNoExtendedACL(descriptor)
        else {
            close(descriptor)
            throw VoiceASRArtifactError.insecureFilesystemEntry(".")
        }
        return descriptor
    }

    private func revalidateSecureSourceDirectory(
        _ descriptor: Int32,
        at url: URL
    ) throws {
        var heldStatus = stat()
        guard fstat(descriptor, &heldStatus) == 0,
              isDirectory(heldStatus),
              heldStatus.st_uid == expectedUserID,
              heldStatus.st_mode & mode_t(0o022) == 0,
              publisherDescriptorHasNoExtendedACL(descriptor)
        else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(".")
        }
        let rebound: OpenedSourceDirectory
        do {
            rebound = try openSourceDirectoryByComponents(url.path)
        } catch {
            throw VoiceASRArtifactError.insecureFilesystemEntry(".")
        }
        defer { close(rebound.descriptor) }
        var reboundStatus = stat()
        guard fstat(rebound.descriptor, &reboundStatus) == 0,
              sameFile(heldStatus, reboundStatus),
              sameFile(rebound.namedStatus, reboundStatus),
              isDirectory(reboundStatus),
              reboundStatus.st_uid == expectedUserID,
              reboundStatus.st_mode & mode_t(0o022) == 0,
              publisherDescriptorHasNoExtendedACL(rebound.descriptor)
        else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(".")
        }
    }

    private func openSourceDirectoryByComponents(
        _ path: String
    ) throws -> OpenedSourceDirectory {
        let components = path.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty else {
            throw VoiceASRArtifactError.artifactRootMustBeDirectory
        }
        var current = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            throw VoiceASRArtifactError.artifactRootMustBeDirectory
        }
        do {
            for (index, component) in components.enumerated() {
                var named = stat()
                let statusResult = component.withCString { pointer in
                    fstatat(current, pointer, &named, AT_SYMLINK_NOFOLLOW)
                }
                guard statusResult == 0 else {
                    throw VoiceASRArtifactError.artifactRootMustBeDirectory
                }
                guard !isSymbolicLink(named) else {
                    throw VoiceASRArtifactError.insecureFilesystemEntry(".")
                }
                guard isDirectory(named) else {
                    throw VoiceASRArtifactError.artifactRootMustBeDirectory
                }
                let next = component.withCString { pointer in
                    openat(
                        current,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else {
                    throw VoiceASRArtifactError.insecureFilesystemEntry(".")
                }
                var opened = stat()
                guard fstat(next, &opened) == 0,
                      isDirectory(opened),
                      sameFile(named, opened)
                else {
                    close(next)
                    throw VoiceASRArtifactError.insecureFilesystemEntry(".")
                }
                close(current)
                current = next
                if index == components.count - 1 {
                    return OpenedSourceDirectory(
                        descriptor: current,
                        namedStatus: named
                    )
                }
            }
        } catch {
            close(current)
            throw error
        }
        close(current)
        throw VoiceASRArtifactError.artifactRootMustBeDirectory
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.utf8.count > 1,
              path.utf8.count < 4_096,
              path.first == "/",
              path.last != "/",
              path.utf8.elementsEqual(
                  path.precomposedStringWithCanonicalMapping.utf8
              ),
              !path.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7F
              })
        else {
            return false
        }
        return path.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        ).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
                && $0.utf8.count <= 255
        }
    }

    private func copyRegularFile(
        relativePath: String,
        expectedBytes: Int64?,
        maximumBytes: Int64,
        sourceRoot: Int32,
        destinationRoot: Int32
    ) throws {
        let source = try openSecureRegularFile(
            relativePath: relativePath,
            rootDescriptor: sourceRoot
        )
        defer { close(source.descriptor) }
        if let expectedBytes, source.status.st_size != expectedBytes {
            throw VoiceASRArtifactError.fileSizeMismatch(
                path: relativePath,
                expected: expectedBytes,
                actual: source.status.st_size
            )
        }
        guard source.status.st_size <= maximumBytes else {
            throw VoiceASRArtifactPublisherError.ioFailure(
                path: relativePath,
                errno: EFBIG
            )
        }

        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(relativePath)
        }
        let parentPath = components.dropLast().joined(separator: "/")
        let destinationParent = try openPrivateDirectory(
            relativePath: parentPath,
            rootDescriptor: destinationRoot
        )
        defer { close(destinationParent) }
        let destination = name.withCString { value in
            openat(
                destinationParent,
                value,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard destination >= 0 else {
            throw ioError(path: relativePath)
        }
        defer { close(destination) }
        guard fchmod(destination, mode_t(0o600)) == 0 else {
            throw ioError(path: relativePath)
        }
        guard publisherDescriptorHasNoExtendedACL(destination) else {
            throw VoiceASRArtifactPublisherError.unsafeStagingDirectory
        }

        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var copied: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    source.descriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw ioError(path: relativePath)
            }
            let (newCount, overflow) = copied.addingReportingOverflow(
                Int64(count)
            )
            guard !overflow, newCount <= maximumBytes else {
                throw VoiceASRArtifactPublisherError.ioFailure(
                    path: relativePath,
                    errno: EFBIG
                )
            }
            copied = newCount
            try writeAll(
                buffer,
                count: count,
                to: destination,
                path: relativePath
            )
        }
        if let expectedBytes, copied != expectedBytes {
            throw VoiceASRArtifactError.fileSizeMismatch(
                path: relativePath,
                expected: expectedBytes,
                actual: copied
            )
        }
        var finalSourceStatus = stat()
        guard fstat(source.descriptor, &finalSourceStatus) == 0 else {
            throw ioError(path: relativePath)
        }
        guard sameFile(source.status, finalSourceStatus),
              finalSourceStatus.st_size == source.status.st_size
        else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(relativePath)
        }
        guard fsync(destination) == 0 else {
            throw ioError(path: relativePath)
        }
    }

    private func openSecureRegularFile(
        relativePath: String,
        rootDescriptor: Int32
    ) throws -> OpenedRegularFile {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(relativePath)
        }
        var parent = dup(rootDescriptor)
        guard parent >= 0 else {
            throw ioError(path: relativePath)
        }
        for component in components.dropLast() {
            let next = component.withCString { value in
                openat(
                    parent,
                    value,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            let savedErrno = errno
            close(parent)
            guard next >= 0 else {
                if savedErrno == ELOOP {
                    throw VoiceASRArtifactError.insecureFilesystemEntry(
                        relativePath
                    )
                }
                throw VoiceASRArtifactError.ioFailure(
                    path: relativePath,
                    errno: savedErrno
                )
            }
            do {
                try validateSecureSourceDirectory(
                    descriptor: next,
                    path: relativePath
                )
            } catch {
                close(next)
                throw error
            }
            parent = next
        }

        let descriptor = name.withCString { value in
            openat(
                parent,
                value,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        let savedErrno = errno
        close(parent)
        guard descriptor >= 0 else {
            if savedErrno == ELOOP {
                throw VoiceASRArtifactError.insecureFilesystemEntry(
                    relativePath
                )
            }
            throw VoiceASRArtifactError.ioFailure(
                path: relativePath,
                errno: savedErrno
            )
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              isRegularFile(status),
              status.st_uid == expectedUserID,
              status.st_mode & mode_t(0o022) == 0,
              status.st_nlink == 1,
              publisherDescriptorHasNoExtendedACL(descriptor)
        else {
            close(descriptor)
            throw VoiceASRArtifactError.insecureFilesystemEntry(relativePath)
        }
        return OpenedRegularFile(descriptor: descriptor, status: status)
    }

    private func validateSecureSourceDirectory(
        descriptor: Int32,
        path: String
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              isDirectory(status),
              status.st_uid == expectedUserID,
              status.st_mode & mode_t(0o022) == 0,
              publisherDescriptorHasNoExtendedACL(descriptor)
        else {
            throw VoiceASRArtifactError.insecureFilesystemEntry(path)
        }
    }

    private func createPrivateDirectory(
        relativePath: String,
        rootDescriptor: Int32
    ) throws {
        var parent = dup(rootDescriptor)
        guard parent >= 0 else {
            throw ioError(path: relativePath)
        }
        defer { close(parent) }
        for component in relativePath.split(separator: "/").map(String.init) {
            let creationResult = component.withCString { value in
                mkdirat(parent, value, mode_t(0o700))
            }
            if creationResult != 0, errno != EEXIST {
                throw ioError(path: relativePath)
            }
            let next = component.withCString { value in
                openat(
                    parent,
                    value,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard next >= 0 else {
                throw VoiceASRArtifactPublisherError.unsafeStagingDirectory
            }
            guard fchmod(next, mode_t(0o700)) == 0 else {
                close(next)
                throw ioError(path: relativePath)
            }
            do {
                try validatePrivateDirectory(
                    descriptor: next,
                    path: relativePath
                )
            } catch {
                close(next)
                throw error
            }
            close(parent)
            parent = next
        }
    }

    private func openPrivateDirectory(
        relativePath: String,
        rootDescriptor: Int32
    ) throws -> Int32 {
        var current = dup(rootDescriptor)
        guard current >= 0 else {
            throw ioError(path: relativePath.isEmpty ? "." : relativePath)
        }
        if relativePath.isEmpty {
            return current
        }
        for component in relativePath.split(separator: "/").map(String.init) {
            let next = component.withCString { value in
                openat(
                    current,
                    value,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            close(current)
            guard next >= 0 else {
                throw VoiceASRArtifactPublisherError.unsafeStagingDirectory
            }
            do {
                try validatePrivateDirectory(
                    descriptor: next,
                    path: relativePath
                )
            } catch {
                close(next)
                throw error
            }
            current = next
        }
        return current
    }

    private func validatePrivateDirectory(
        descriptor: Int32,
        path: String
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              isDirectory(status),
              status.st_uid == expectedUserID,
              status.st_mode & mode_t(0o777) == mode_t(0o700),
              publisherDescriptorHasNoExtendedACL(descriptor)
        else {
            throw VoiceASRArtifactPublisherError.unsafeStagingDirectory
        }
    }

    private func createPrivateStagingDirectory(
        named name: String,
        context: DirectoryContext
    ) throws -> Int32 {
        let creationResult = name.withCString { value in
            mkdirat(context.staging, value, mode_t(0o700))
        }
        guard creationResult == 0 else {
            throw ioError(
                path: layout.voiceASRStagingDirectory
                    .appendingPathComponent(name).path
            )
        }
        var descriptor: Int32 = -1
        do {
            descriptor = name.withCString { value in
                openat(
                    context.staging,
                    value,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw VoiceASRArtifactPublisherError.unsafeStagingDirectory
            }
            guard fchmod(descriptor, mode_t(0o700)) == 0 else {
                let savedErrno = errno
                throw VoiceASRArtifactPublisherError.ioFailure(
                    path: name,
                    errno: savedErrno
                )
            }
            try validatePrivateDirectory(descriptor: descriptor, path: name)
            return descriptor
        } catch {
            if descriptor >= 0 {
                close(descriptor)
            }
            let cleanupResult = name.withCString { value in
                unlinkat(context.staging, value, AT_REMOVEDIR)
            }
            guard cleanupResult == 0,
                  fsync(context.staging) == 0
            else {
                throw VoiceASRArtifactPublisherError.stagingCleanupFailed
            }
            throw error
        }
    }

    private func revalidatePrivateStaging(
        named name: String,
        expectedDescriptor: Int32,
        context: DirectoryContext
    ) throws {
        var expected = stat()
        var pathStatus = stat()
        guard fstat(expectedDescriptor, &expected) == 0,
              name.withCString({ value in
                  fstatat(
                      context.staging,
                      value,
                      &pathStatus,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              sameFile(expected, pathStatus),
              isDirectory(pathStatus),
              pathStatus.st_uid == expectedUserID,
              pathStatus.st_mode & mode_t(0o777) == mode_t(0o700),
              publisherDescriptorHasNoExtendedACL(expectedDescriptor)
        else {
            throw VoiceASRArtifactPublisherError.unsafeStagingDirectory
        }
    }

    private func validatePublishedIdentity(
        _ artifactID: VoiceASRArtifactID,
        expectedDescriptor: Int32,
        context: DirectoryContext
    ) throws {
        var expected = stat()
        var published = stat()
        guard fstat(expectedDescriptor, &expected) == 0,
              artifactID.rawValue.withCString({ value in
                  fstatat(
                      context.releases,
                      value,
                      &published,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              sameFile(expected, published),
              isDirectory(published),
              published.st_uid == expectedUserID,
              published.st_mode & mode_t(0o777) == mode_t(0o700),
              publisherDescriptorHasNoExtendedACL(expectedDescriptor)
        else {
            throw VoiceASRArtifactPublisherError.unsafeExistingRelease(
                artifactID
            )
        }
    }

    private func withExclusivePublishLock<T>(
        _ operation: (DirectoryContext) throws -> T
    ) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        try prepareManagedDirectories()
        let root = try openSecureManagedDirectory(layout.voiceASRDirectory)
        defer { close(root) }
        let releases = try openSecureManagedChild(
            parent: root,
            name: "releases"
        )
        defer { close(releases) }
        let staging = try openSecureManagedChild(
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
            throw VoiceASRArtifactPublisherError.unsafeManagedDirectory
        }

        let lock = try openPublisherLock(root: root)
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else {
            throw VoiceASRArtifactPublisherError.ioFailure(
                path: layout.voiceASRDirectory.path,
                errno: errno
            )
        }
        defer { _ = flock(lock, LOCK_UN) }
        return try operation(
            DirectoryContext(
                root: root,
                releases: releases,
                staging: staging
            )
        )
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
            throw VoiceASRArtifactPublisherError.unsafeManagedDirectory
        }
        try validateManagedDirectory(home, requireNoExtendedACL: false)
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
                    throw VoiceASRArtifactPublisherError.ioFailure(
                        path: directory.path,
                        errno: lookupError
                    )
                }
                if mkdir(directory.path, mode_t(0o700)) != 0 {
                    let creationError = errno
                    guard creationError == EEXIST else {
                        throw VoiceASRArtifactPublisherError.ioFailure(
                            path: directory.path,
                            errno: creationError
                        )
                    }
                }
            }
            let requiresACLCheck = directory == layout.voiceASRDirectory
                || directory == layout.voiceASRReleasesDirectory
                || directory == layout.voiceASRStagingDirectory
            try validateManagedDirectory(
                directory,
                requireNoExtendedACL: requiresACLCheck
            )
        }
    }

    private func validateManagedDirectory(
        _ url: URL,
        requireNoExtendedACL: Bool
    ) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              isDirectory(status),
              status.st_uid == expectedUserID,
              status.st_mode & mode_t(0o022) == 0,
              !requireNoExtendedACL
                  || publisherPathHasNoExtendedACL(url.path)
        else {
            throw VoiceASRArtifactPublisherError.unsafeManagedDirectory
        }
    }

    private func openSecureManagedDirectory(_ url: URL) throws -> Int32 {
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0 else {
            throw VoiceASRArtifactPublisherError.unsafeManagedDirectory
        }
        let descriptor = open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw VoiceASRArtifactPublisherError.unsafeManagedDirectory
        }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              sameFile(pathStatus, openedStatus),
              isDirectory(openedStatus),
              openedStatus.st_uid == expectedUserID,
              openedStatus.st_mode & mode_t(0o022) == 0,
              publisherDescriptorHasNoExtendedACL(descriptor)
        else {
            close(descriptor)
            throw VoiceASRArtifactPublisherError.unsafeManagedDirectory
        }
        return descriptor
    }

    private func openSecureManagedChild(
        parent: Int32,
        name: String
    ) throws -> Int32 {
        var pathStatus = stat()
        guard name.withCString({ value in
            fstatat(parent, value, &pathStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
            isDirectory(pathStatus),
            pathStatus.st_uid == expectedUserID,
            pathStatus.st_mode & mode_t(0o022) == 0
        else {
            throw VoiceASRArtifactPublisherError.unsafeManagedDirectory
        }
        let descriptor = name.withCString { value in
            openat(
                parent,
                value,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw VoiceASRArtifactPublisherError.unsafeManagedDirectory
        }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              sameFile(pathStatus, openedStatus),
              isDirectory(openedStatus),
              openedStatus.st_uid == expectedUserID,
              openedStatus.st_mode & mode_t(0o022) == 0,
              publisherDescriptorHasNoExtendedACL(descriptor)
        else {
            close(descriptor)
            throw VoiceASRArtifactPublisherError.unsafeManagedDirectory
        }
        return descriptor
    }

    private func openPublisherLock(root: Int32) throws -> Int32 {
        let createdDescriptor = Self.lockName.withCString { value in
            openat(
                root,
                value,
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
            let savedErrno = errno
            guard savedErrno == EEXIST else {
                throw VoiceASRArtifactPublisherError.ioFailure(
                    path: layout.voiceASRDirectory.path,
                    errno: savedErrno
                )
            }
            descriptor = Self.lockName.withCString { value in
                openat(
                    root,
                    value,
                    O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw VoiceASRArtifactPublisherError.unsafeManagedDirectory
            }
            created = false
        }
        var keepOpen = false
        defer {
            if !keepOpen {
                close(descriptor)
            }
        }
        if created, fchmod(descriptor, mode_t(0o600)) != 0 {
            throw ioError(path: Self.lockName)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              isRegularFile(status),
              status.st_uid == expectedUserID,
              status.st_mode & mode_t(0o777) == mode_t(0o600),
              status.st_nlink == 1,
              publisherDescriptorHasNoExtendedACL(descriptor)
        else {
            throw VoiceASRArtifactPublisherError.unsafeManagedDirectory
        }
        keepOpen = true
        return descriptor
    }

    private func removeTreeIfPresent(
        parent: Int32,
        name: String,
        displayPath: String
    ) throws {
        var status = stat()
        let statusResult = name.withCString { value in
            fstatat(parent, value, &status, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0 {
            if errno == ENOENT {
                return
            }
            throw ioError(path: displayPath)
        }
        if isDirectory(status) {
            let directoryDescriptor = name.withCString { value in
                openat(
                    parent,
                    value,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard directoryDescriptor >= 0 else {
                throw ioError(path: displayPath)
            }
            do {
                defer { close(directoryDescriptor) }
                let iterationDescriptor = dup(directoryDescriptor)
                guard iterationDescriptor >= 0,
                      let directory = fdopendir(iterationDescriptor)
                else {
                    if iterationDescriptor >= 0 {
                        close(iterationDescriptor)
                    }
                    throw ioError(path: displayPath)
                }
                var names: [String] = []
                errno = 0
                while let entry = readdir(directory) {
                    let child = withUnsafeBytes(of: &entry.pointee.d_name) {
                        buffer in
                        String(
                            cString: buffer.baseAddress!.assumingMemoryBound(
                                to: CChar.self
                            )
                        )
                    }
                    if child != ".", child != ".." {
                        names.append(child)
                    }
                }
                let readError = errno
                closedir(directory)
                if readError != 0 {
                    throw VoiceASRArtifactPublisherError.ioFailure(
                        path: displayPath,
                        errno: readError
                    )
                }
                for child in names {
                    try removeTreeIfPresent(
                        parent: directoryDescriptor,
                        name: child,
                        displayPath: displayPath + "/" + child
                    )
                }
            }
            let removal = name.withCString { value in
                unlinkat(parent, value, AT_REMOVEDIR)
            }
            guard removal == 0 else {
                throw ioError(path: displayPath)
            }
        } else {
            let removal = name.withCString { value in
                unlinkat(parent, value, 0)
            }
            guard removal == 0 else {
                throw ioError(path: displayPath)
            }
        }
    }

    private func writeAll(
        _ buffer: [UInt8],
        count: Int,
        to descriptor: Int32,
        path: String
    ) throws {
        try buffer.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var written = 0
            while written < count {
                let writtenCount = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    count - written
                )
                if writtenCount < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw ioError(path: path)
                }
                guard writtenCount > 0 else {
                    throw VoiceASRArtifactPublisherError.ioFailure(
                        path: path,
                        errno: EIO
                    )
                }
                written += writtenCount
            }
        }
    }

    private func directoryPrefixes(for paths: [String]) -> Set<String> {
        var result: Set<String> = []
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            for count in 1 ..< components.count {
                result.insert(
                    components.prefix(count).joined(separator: "/")
                )
            }
        }
        return result
    }

    private func ioError(path: String) -> VoiceASRArtifactPublisherError {
        .ioFailure(path: path, errno: errno)
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

    private func isSymbolicLink(_ status: stat) -> Bool {
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
    }
}

private func publisherPathHasNoExtendedACL(_ path: String) -> Bool {
    errno = 0
    guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else {
        return errno == ENOENT
    }
    acl_free(UnsafeMutableRawPointer(acl))
    return false
}

private func publisherDescriptorHasNoExtendedACL(
    _ descriptor: Int32
) -> Bool {
    errno = 0
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
        return errno == ENOENT
    }
    acl_free(UnsafeMutableRawPointer(acl))
    return false
}
