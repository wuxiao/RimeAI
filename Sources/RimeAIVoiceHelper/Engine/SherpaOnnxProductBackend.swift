import Darwin
import CryptoKit
import Foundation
import RimeAIInputCore
import RimeAISherpaOnnxSafeC

enum SherpaOnnxProductBackendError: Error, Equatable, Sendable {
    case unsupportedArtifactContract
    case untrustedArtifact(VoiceASRArtifactID)
    case runtimeMetadataUnavailable
    case runtimeVersionMismatch(expected: String, actual: String)
    case runtimeRevisionMismatch(expected: String, actual: String)
    case onnxRuntimeVersionMismatch(expected: String, actual: String)
    case unsafeModelPath(String)
    case modelFileUnavailable(String)
    case recognizerInitializationFailed
    case streamInitializationFailed
    case runtimeCallFailed
    case resultUnavailable
    case invalidAudioFrame
    case decodeStepLimitExceeded
    case hotwordsUnsupported
}

struct SherpaOnnxRuntimeIdentity: Equatable, Sendable {
    let sherpaVersion: String
    let sherpaGitRevision: String
    let onnxRuntimeVersion: String
}

struct SherpaOnnxRecognizerConfiguration: Equatable, Sendable {
    let encoderPath: String
    let decoderPath: String
    let joinerPath: String
    let tokensPath: String
    let bpeVocabularyPath: String
    let sampleRateHertz: Int
    let featureDimension: Int
    let numberOfThreads: Int
    let provider: String
    let modelType: String
    let modelingUnit: String
    let decodingMethod: String
    let maximumActivePaths: Int
    let endpointEnabled: Bool
    let rule1MinimumTrailingSilenceSeconds: Float
    let rule2MinimumTrailingSilenceSeconds: Float
    let rule3MinimumUtteranceSeconds: Float
    let hotwordsScore: Float
    let blankPenalty: Float
}

protocol SherpaOnnxRecognizerRunning: AnyObject, Sendable {
    func startSession(hotwords: [String]) throws
    func resetEndpoint() throws
    func accept(samples: [Float]) throws -> VoiceStreamingRecognitionUpdate
    func finish() throws -> VoiceStreamingRecognitionUpdate
    func cancel()
}

protocol SherpaOnnxRuntimeLoading: Sendable {
    func identity() throws -> SherpaOnnxRuntimeIdentity
    func makeRecognizer(
        configuration: SherpaOnnxRecognizerConfiguration
    ) throws -> any SherpaOnnxRecognizerRunning
}

struct SherpaOnnxRuntimeSnapshotOperations: Sendable {
    let cloneFile: @Sendable (Int32, Int32, String) -> Int32
    let readFile: @Sendable (
        Int32,
        UnsafeMutableRawPointer?,
        Int,
        off_t
    ) -> Int
    let writeFile: @Sendable (Int32, UnsafeRawPointer?, Int) -> Int
    let syncFile: @Sendable (Int32) -> Int32
    let chmodFile: @Sendable (Int32, mode_t) -> Int32
    let statCreatedDirectory: @Sendable (
        Int32,
        String,
        UnsafeMutablePointer<stat>
    ) -> Int32
    let statCreatedFile: @Sendable (
        Int32,
        UnsafeMutablePointer<stat>
    ) -> Int32
    let openMaterializedDirectory: @Sendable (Int32, String) -> Int32
    let openMaterializedFile: @Sendable (Int32, String) -> Int32

    init(
        cloneFile: @escaping @Sendable (
            Int32,
            Int32,
            String
        ) -> Int32 = { sourceDescriptor, directoryDescriptor, name in
            name.withCString { pointer in
                fclonefileat(
                    sourceDescriptor,
                    directoryDescriptor,
                    pointer,
                    0
                )
            }
        },
        readFile: @escaping @Sendable (
            Int32,
            UnsafeMutableRawPointer?,
            Int,
            off_t
        ) -> Int = { descriptor, buffer, count, offset in
            pread(descriptor, buffer, count, offset)
        },
        writeFile: @escaping @Sendable (
            Int32,
            UnsafeRawPointer?,
            Int
        ) -> Int = { descriptor, buffer, count in
            write(descriptor, buffer, count)
        },
        syncFile: @escaping @Sendable (Int32) -> Int32 = { descriptor in
            fsync(descriptor)
        },
        chmodFile: @escaping @Sendable (
            Int32,
            mode_t
        ) -> Int32 = { descriptor, mode in
            fchmod(descriptor, mode)
        },
        statCreatedDirectory: @escaping @Sendable (
            Int32,
            String,
            UnsafeMutablePointer<stat>
        ) -> Int32 = { parentDescriptor, name, status in
            name.withCString { pointer in
                fstatat(
                    parentDescriptor,
                    pointer,
                    status,
                    AT_SYMLINK_NOFOLLOW
                )
            }
        },
        statCreatedFile: @escaping @Sendable (
            Int32,
            UnsafeMutablePointer<stat>
        ) -> Int32 = { descriptor, status in
            fstat(descriptor, status)
        },
        openMaterializedDirectory: @escaping @Sendable (
            Int32,
            String
        ) -> Int32 = { parentDescriptor, name in
            name.withCString { pointer in
                openat(
                    parentDescriptor,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
        },
        openMaterializedFile: @escaping @Sendable (
            Int32,
            String
        ) -> Int32 = { directoryDescriptor, name in
            name.withCString { pointer in
                openat(
                    directoryDescriptor,
                    pointer,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
        }
    ) {
        self.cloneFile = cloneFile
        self.readFile = readFile
        self.writeFile = writeFile
        self.syncFile = syncFile
        self.chmodFile = chmodFile
        self.statCreatedDirectory = statCreatedDirectory
        self.statCreatedFile = statCreatedFile
        self.openMaterializedDirectory = openMaterializedDirectory
        self.openMaterializedFile = openMaterializedFile
    }

    static let live = SherpaOnnxRuntimeSnapshotOperations()
}

/// Product backend for the pinned static sherpa-onnx runtime. The model is
/// still supplied by the verified artifact store; this type never downloads
/// or repairs runtime/model content.
final class SherpaOnnxProductBackendLoader:
    VoiceProductBackendLoading,
    @unchecked Sendable
{
    static let adapterID = "sherpa-onnx"
    static let adapterVersion = "1.13.6"
    static let adapterABIVersion = 1
    /// Revision embedded by the official v1.13.6 static XCFramework. This is
    /// intentionally distinct from the source tag commit; the binary archive
    /// checksum in Package.swift remains the primary artifact identity.
    static let embeddedSherpaGitRevision = "0fdffb3e"
    static let onnxRuntimeVersion = "1.27.1"
    static let supportedLocales: Set<String> = ["en-US", "zh-CN"]

    private let runtime: any SherpaOnnxRuntimeLoading
    private let snapshotOperations: SherpaOnnxRuntimeSnapshotOperations

    convenience init() {
        self.init(runtime: SystemSherpaOnnxRuntime())
    }

    init(
        runtime: any SherpaOnnxRuntimeLoading,
        snapshotOperations: SherpaOnnxRuntimeSnapshotOperations = .live
    ) {
        self.runtime = runtime
        self.snapshotOperations = snapshotOperations
    }

    func load(
        lease: VoiceASRVerifiedArtifactLease
    ) throws -> VoiceProductBackendLoad {
        let artifact = lease.artifact
        let manifest = artifact.manifest
        try Self.validateProductContract(manifest)
        try Self.validateRuntimeIdentity(runtime.identity())

        let configuration = try Self.makeConfiguration(for: artifact)
        let openFiles = try Self.openRuntimeFiles(
            for: artifact,
            configuration: configuration,
            snapshotOperations: snapshotOperations
        )
        let recognizer: any SherpaOnnxRecognizerRunning
        do {
            try Self.validateRuntimeSnapshot(openFiles)
            recognizer = try runtime.makeRecognizer(
                configuration: Self.configuration(
                    configuration,
                    boundTo: openFiles
                )
            )
            try Self.finalizeRuntimeFilesAfterRecognizerCreation(
                openFiles,
                artifactRootPath: artifact.artifactDirectory.path
            )
        } catch {
            try? openFiles.runtimeSnapshot.remove()
            throw error
        }
        let driver = SherpaOnnxRecognizerDriver(
            artifactGeneration: lease.generation,
            recognizer: recognizer,
            openedRuntimeFiles: openFiles,
            hotwordsSupported: manifest.capabilities.hotwordMode
                == .boundedPhraseList
        )

        // Exercise a model-approved non-empty hotword, end-of-input, result
        // extraction, and a fresh empty stream before this generation is
        // advertised to the server. The manifest phrase is integrity-bound
        // metadata, never user text.
        do {
            if manifest.capabilities.hotwordMode == .boundedPhraseList {
                let probeHotwords = Array(
                    repeating: manifest.runtime.hotwordProbePhrase,
                    count: min(
                        manifest.capabilities.maximumHotwords,
                        VoiceDictationConstants.maximumHotwordCount
                    )
                )
                try driver.startSession(
                    hotwords: probeHotwords
                )
                let hotwordProbe = try driver.finish()
                guard hotwordProbe.text.isEmpty else {
                    throw VoiceProductBackendLoadError.emptyStreamProbeFailed
                }
                driver.cancel()
            }
            try driver.startSession(hotwords: [])
            let freshProbe = try driver.finish()
            guard freshProbe.text.isEmpty else {
                throw VoiceProductBackendLoadError.emptyStreamProbeFailed
            }
            driver.cancel()
        } catch let error as VoiceProductBackendLoadError {
            throw error
        } catch {
            driver.cancel()
            throw VoiceProductBackendLoadError.emptyStreamProbeFailed
        }

        let locales = Set(manifest.locales).intersection(
            Self.supportedLocales
        )
        let probe = VoiceProductEngineLoadProbe(
            artifactGeneration: lease.generation,
            adapterID: Self.adapterID,
            adapterVersion: Self.adapterVersion,
            adapterABIVersion: Self.adapterABIVersion,
            runtimeKind: manifest.runtime.kind,
            supportedLocales: locales,
            supportsStreaming: true,
            supportsPartialResults: true,
            supportsEndpointDetection: true,
            maximumHotwords: min(
                manifest.capabilities.maximumHotwords,
                128
            ),
            maximumAlternatives: 1,
            sampleRateHertz: VoicePCMFrame.sampleRateHertz,
            channelCount: 1,
            bitsPerChannel: 32
        )
        return try VoiceProductBackendLoad(
            recognizerDriver: driver,
            loadProbe: probe
        )
    }

    private static func validateProductContract(
        _ manifest: VoiceASRArtifactManifest
    ) throws {
        guard manifest.adapter.id == adapterID,
              manifest.adapter.version == adapterVersion,
              manifest.adapter.abiVersion == adapterABIVersion,
              manifest.runtime.kind == .sherpaOnnxOnlineTransducer
                  || manifest.runtime.kind == .sherpaOnnxOnlineParaformer,
              manifest.networkPolicy == .offline,
              !Set(manifest.locales).intersection(supportedLocales).isEmpty,
              manifest.capabilities.maximumAlternatives == 1
        else {
            throw SherpaOnnxProductBackendError
                .unsupportedArtifactContract
        }
    }

    private static func validateRuntimeIdentity(
        _ identity: SherpaOnnxRuntimeIdentity
    ) throws {
        guard identity.sherpaVersion == adapterVersion else {
            throw SherpaOnnxProductBackendError.runtimeVersionMismatch(
                expected: adapterVersion,
                actual: identity.sherpaVersion
            )
        }
        let revision = identity.sherpaGitRevision.lowercased()
        guard revision == embeddedSherpaGitRevision
        else {
            throw SherpaOnnxProductBackendError.runtimeRevisionMismatch(
                expected: embeddedSherpaGitRevision,
                actual: identity.sherpaGitRevision
            )
        }
        guard identity.onnxRuntimeVersion == onnxRuntimeVersion else {
            throw SherpaOnnxProductBackendError
                .onnxRuntimeVersionMismatch(
                    expected: onnxRuntimeVersion,
                    actual: identity.onnxRuntimeVersion
                )
        }
    }

    private static func makeConfiguration(
        for artifact: VoiceASRVerifiedArtifact
    ) throws -> SherpaOnnxRecognizerConfiguration {
        let manifest = artifact.manifest
        let runtime = manifest.runtime
        let rootPath = artifact.artifactDirectory.path
        guard artifact.artifactDirectory.isFileURL,
              isCanonicalAbsolutePath(rootPath)
        else {
            throw SherpaOnnxProductBackendError
                .unsafeModelPath(rootPath)
        }

        func absolutePath(_ relativePath: String) throws -> String {
            guard Self.isCanonicalRelativePath(relativePath) else {
                throw SherpaOnnxProductBackendError
                    .unsafeModelPath(relativePath)
            }
            return rootPath + "/" + relativePath
        }

        return try SherpaOnnxRecognizerConfiguration(
            encoderPath: absolutePath(runtime.encoderPath),
            decoderPath: absolutePath(runtime.decoderPath),
            joinerPath: runtime.joinerPath.map(absolutePath) ?? "",
            tokensPath: absolutePath(runtime.tokensPath),
            bpeVocabularyPath: runtime.bpeVocabularyPath.map(
                absolutePath
            ) ?? "",
            sampleRateHertz: manifest.audio.sampleRateHertz,
            featureDimension: runtime.featureDimension,
            numberOfThreads: runtime.numberOfThreads,
            provider: runtime.provider.rawValue,
            modelType: runtime.modelType.rawValue,
            modelingUnit: runtime.modelingUnit.rawValue,
            decodingMethod: runtime.decodingMethod.rawValue,
            maximumActivePaths: runtime.maximumActivePaths,
            endpointEnabled: runtime.endpoint.enabled,
            rule1MinimumTrailingSilenceSeconds: Float(
                runtime.endpoint
                    .rule1MinimumTrailingSilenceMilliseconds
            ) / 1_000,
            rule2MinimumTrailingSilenceSeconds: Float(
                runtime.endpoint
                    .rule2MinimumTrailingSilenceMilliseconds
            ) / 1_000,
            rule3MinimumUtteranceSeconds: Float(
                runtime.endpoint.rule3MinimumUtteranceMilliseconds
            ) / 1_000,
            hotwordsScore: Float(runtime.hotwordsScoreMilli) / 1_000,
            blankPenalty: Float(runtime.blankPenaltyMilli) / 1_000
        )
    }

    private static func openRuntimeFiles(
        for artifact: VoiceASRVerifiedArtifact,
        configuration: SherpaOnnxRecognizerConfiguration,
        snapshotOperations: SherpaOnnxRuntimeSnapshotOperations
    ) throws -> SherpaOnnxOpenedRuntimeFiles {
        let runtime = artifact.manifest.runtime
        var paths = [
            (runtime.encoderPath, configuration.encoderPath),
            (runtime.decoderPath, configuration.decoderPath),
        ]
        if runtime.kind == .sherpaOnnxOnlineTransducer {
            paths.append((runtime.joinerPath ?? "", configuration.joinerPath))
            paths.append((runtime.tokensPath, configuration.tokensPath))
            paths.append((
                runtime.bpeVocabularyPath ?? "",
                configuration.bpeVocabularyPath
            ))
        } else {
            paths.append((runtime.tokensPath, configuration.tokensPath))
        }
        let inventory = Dictionary(uniqueKeysWithValues:
            artifact.manifest.inventory.map { ($0.path, $0) }
        )
        let rootDescriptor = try openArtifactRoot(
            artifact.artifactDirectory.path
        )
        var boundFiles: [SherpaOnnxBoundRuntimeFile] = []
        do {
            for (relativePath, path) in paths {
                guard let expected = inventory[relativePath] else {
                    throw SherpaOnnxProductBackendError
                        .unsupportedArtifactContract
                }
                let expectedPath = artifact.artifactDirectory.path
                    + "/" + relativePath
                guard path.utf8.elementsEqual(expectedPath.utf8) else {
                    throw SherpaOnnxProductBackendError
                        .unsafeModelPath(relativePath)
                }
                let descriptor = try openRuntimeFile(
                    relativePath: relativePath,
                    displayPath: path,
                    rootDescriptor: rootDescriptor,
                    expectedBytes: expected.bytes
                )
                let digest: String
                do {
                    digest = try descriptorSHA256(descriptor)
                } catch {
                    close(descriptor)
                    throw error
                }
                guard digest == expected.sha256,
                      lseek(descriptor, 0, SEEK_SET) == 0
                else {
                    close(descriptor)
                    throw SherpaOnnxProductBackendError
                        .modelFileUnavailable(path)
                }
                var status = stat()
                guard fstat(descriptor, &status) == 0 else {
                    close(descriptor)
                    throw SherpaOnnxProductBackendError
                        .modelFileUnavailable(path)
                }
                boundFiles.append(SherpaOnnxBoundRuntimeFile(
                    descriptor: descriptor,
                    relativePath: relativePath,
                    displayPath: path,
                    expectedBytes: expected.bytes,
                    expectedSHA256: expected.sha256,
                    device: status.st_dev,
                    inode: status.st_ino
                ))
            }
            guard Set(boundFiles.map(\.identity)).count
                    == boundFiles.count
            else {
                throw SherpaOnnxProductBackendError
                    .unsupportedArtifactContract
            }
            try revalidateArtifactRoot(
                artifact.artifactDirectory.path,
                heldDescriptor: rootDescriptor
            )
            let snapshot = try makeRuntimeSnapshot(
                artifactRootPath: artifact.artifactDirectory.path,
                rootDescriptor: rootDescriptor,
                boundFiles: boundFiles,
                snapshotOperations: snapshotOperations
            )
            return SherpaOnnxOpenedRuntimeFiles(
                artifactRootDescriptor: rootDescriptor,
                boundFiles: boundFiles,
                runtimeSnapshot: snapshot
            )
        } catch {
            for file in boundFiles {
                close(file.descriptor)
            }
            close(rootDescriptor)
            throw error
        }
    }

    private static func makeRuntimeSnapshot(
        artifactRootPath: String,
        rootDescriptor: Int32,
        boundFiles: [SherpaOnnxBoundRuntimeFile],
        snapshotOperations: SherpaOnnxRuntimeSnapshotOperations
    ) throws -> SherpaOnnxRuntimeSnapshot {
        let failure = SherpaOnnxProductBackendError
            .unsafeModelPath(artifactRootPath)
        let parentPath = try lexicalParentPath(of: artifactRootPath)
        let parentDescriptor = openat(
            rootDescriptor,
            "..",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else { throw failure }

        var directoryName: String?
        var createdDirectoryNameByThisCall = false
        var directoryDescriptor: Int32 = -1
        var directoryDevice: dev_t?
        var directoryInode: ino_t?
        var snapshotFiles: [SherpaOnnxRuntimeSnapshotFile] = []
        do {
            var heldParent = stat()
            guard fstat(parentDescriptor, &heldParent) == 0,
                  heldParent.st_mode & S_IFMT == S_IFDIR,
                  heldParent.st_uid == geteuid(),
                  heldParent.st_mode & mode_t(0o022) == 0,
                  descriptorHasNoExtendedACL(parentDescriptor)
            else { throw failure }
            let reboundParent = try openArtifactRoot(parentPath)
            var reboundParentStatus = stat()
            defer { close(reboundParent) }
            guard fstat(reboundParent, &reboundParentStatus) == 0,
                  reboundParentStatus.st_dev == heldParent.st_dev,
                  reboundParentStatus.st_ino == heldParent.st_ino
            else { throw failure }

            for _ in 0 ..< 8 {
                let candidate = ".rimeai-sherpa-runtime-"
                    + UUID().uuidString.lowercased()
                let result = candidate.withCString { pointer in
                    mkdirat(parentDescriptor, pointer, mode_t(0o700))
                }
                if result == 0 {
                    directoryName = candidate
                    createdDirectoryNameByThisCall = true
                    break
                }
                guard errno == EEXIST else { throw failure }
            }
            guard let directoryName else { throw failure }
            var namedDirectory = stat()
            let namedDirectoryResult = snapshotOperations
                .statCreatedDirectory(
                    parentDescriptor,
                    directoryName,
                    &namedDirectory
                )
            guard namedDirectoryResult == 0,
                  namedDirectory.st_mode & S_IFMT == S_IFDIR,
                  namedDirectory.st_uid == geteuid(),
                  namedDirectory.st_dev > 0,
                  namedDirectory.st_ino > 0
            else { throw failure }
            directoryDevice = namedDirectory.st_dev
            directoryInode = namedDirectory.st_ino
            let snapshotPath = parentPath == "/"
                ? "/" + directoryName
                : parentPath + "/" + directoryName
            guard snapshotPath.utf8.count < 4_096 else { throw failure }
            directoryDescriptor =
                snapshotOperations.openMaterializedDirectory(
                    parentDescriptor,
                    directoryName
                )
            guard directoryDescriptor >= 0 else { throw failure }
            var directoryStatus = stat()
            guard fstat(directoryDescriptor, &directoryStatus) == 0,
                  directoryStatus.st_mode & S_IFMT == S_IFDIR,
                  directoryStatus.st_uid == geteuid(),
                  directoryStatus.st_dev == namedDirectory.st_dev,
                  directoryStatus.st_ino == namedDirectory.st_ino,
                  directoryStatus.st_mode & mode_t(0o777)
                    == mode_t(0o700),
                  descriptorHasNoExtendedACL(directoryDescriptor)
            else { throw failure }

            var runtimePaths: [String] = []
            for (index, file) in boundFiles.enumerated() {
                guard let baseName = file.relativePath.split(
                    separator: "/",
                    omittingEmptySubsequences: false
                ).last else { throw failure }
                let snapshotName = "\(index)-\(baseName)"
                let snapshotFile = try materializeRuntimeSnapshotFile(
                    file,
                    directoryDescriptor: directoryDescriptor,
                    name: snapshotName,
                    failure: failure,
                    snapshotOperations: snapshotOperations
                )
                snapshotFiles.append(snapshotFile)
                runtimePaths.append(snapshotPath + "/" + snapshotName)
            }
            guard fchmod(directoryDescriptor, mode_t(0o500)) == 0,
                  fstat(directoryDescriptor, &directoryStatus) == 0,
                  directoryStatus.st_mode & mode_t(0o777)
                    == mode_t(0o500),
                  descriptorHasNoExtendedACL(directoryDescriptor)
            else {
                throw failure
            }
            return SherpaOnnxRuntimeSnapshot(
                parentDescriptor: parentDescriptor,
                directoryDescriptor: directoryDescriptor,
                directoryName: directoryName,
                directoryPath: snapshotPath,
                directoryDevice: directoryStatus.st_dev,
                directoryInode: directoryStatus.st_ino,
                files: snapshotFiles,
                runtimePaths: runtimePaths
            )
        } catch {
            if directoryDescriptor >= 0 {
                _ = fchmod(directoryDescriptor, mode_t(0o700))
                for file in snapshotFiles.reversed() {
                    _ = unlinkBoundRuntimeSnapshotFile(
                        directoryDescriptor: directoryDescriptor,
                        file: file
                    )
                }
                close(directoryDescriptor)
            }
            if let directoryName,
               let directoryDevice,
               let directoryInode
            {
                _ = unlinkBoundRuntimeSnapshotDirectory(
                    parentDescriptor: parentDescriptor,
                    directoryName: directoryName,
                    expectedDevice: directoryDevice,
                    expectedInode: directoryInode
                )
            } else if let directoryName,
                      createdDirectoryNameByThisCall
            {
                // mkdirat used an exclusive UUID name in an authoritative
                // parent. Before an inode token exists the directory is empty,
                // so a best-effort name cleanup cannot target prior content.
                _ = directoryName.withCString { pointer in
                    unlinkat(parentDescriptor, pointer, AT_REMOVEDIR)
                }
            }
            close(parentDescriptor)
            throw error
        }
    }

    private static func materializeRuntimeSnapshotFile(
        _ source: SherpaOnnxBoundRuntimeFile,
        directoryDescriptor: Int32,
        name: String,
        failure: SherpaOnnxProductBackendError,
        snapshotOperations: SherpaOnnxRuntimeSnapshotOperations
    ) throws -> SherpaOnnxRuntimeSnapshotFile {
        var cleanupFile: SherpaOnnxRuntimeSnapshotFile?
        var createdNameByThisCall = false
        var completed = false
        defer {
            if !completed {
                if let cleanupFile {
                    _ = unlinkBoundRuntimeSnapshotFile(
                        directoryDescriptor: directoryDescriptor,
                        file: cleanupFile
                    )
                } else if createdNameByThisCall {
                    // Before an inode token exists, the entry is still the
                    // unique name just created inside our authoritative 0700
                    // directory. Once bound, cleanup is identity-only.
                    _ = name.withCString { pointer in
                        unlinkat(directoryDescriptor, pointer, 0)
                    }
                }
            }
        }

        let cloneResult = snapshotOperations.cloneFile(
            source.descriptor,
            directoryDescriptor,
            name
        )
        if cloneResult == 0 {
            createdNameByThisCall = true
            var clonedStatus = stat()
            let clonedStatusResult = name.withCString { pointer in
                fstatat(
                    directoryDescriptor,
                    pointer,
                    &clonedStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard clonedStatusResult == 0,
                  clonedStatus.st_mode & S_IFMT == S_IFREG,
                  clonedStatus.st_dev > 0,
                  clonedStatus.st_ino > 0
            else { throw failure }
            // Bind cleanup before the pathname is reopened. If openat or a
            // later validation fails, the exact O_EXCL clone is still removed.
            cleanupFile = SherpaOnnxRuntimeSnapshotFile(
                name: name,
                device: clonedStatus.st_dev,
                inode: clonedStatus.st_ino,
                expectedBytes: source.expectedBytes,
                expectedSHA256: source.expectedSHA256
            )
            guard clonedStatus.st_uid == geteuid(),
                  clonedStatus.st_nlink == 1,
                  clonedStatus.st_dev != source.device
                    || clonedStatus.st_ino != source.inode
            else { throw failure }
        } else {
            guard errno != EEXIST else { throw failure }
            let destination = name.withCString { pointer in
                openat(
                    directoryDescriptor,
                    pointer,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o400)
                )
            }
            guard destination >= 0 else { throw failure }
            createdNameByThisCall = true
            var destinationStatus = stat()
            guard snapshotOperations.statCreatedFile(
                      destination,
                      &destinationStatus
                  ) == 0,
                  destinationStatus.st_mode & S_IFMT == S_IFREG,
                  destinationStatus.st_dev > 0,
                  destinationStatus.st_ino > 0
            else {
                close(destination)
                throw failure
            }
            cleanupFile = SherpaOnnxRuntimeSnapshotFile(
                name: name,
                device: destinationStatus.st_dev,
                inode: destinationStatus.st_ino,
                expectedBytes: source.expectedBytes,
                expectedSHA256: source.expectedSHA256
            )
            guard destinationStatus.st_uid == geteuid(),
                  destinationStatus.st_nlink == 1,
                  destinationStatus.st_dev != source.device
                    || destinationStatus.st_ino != source.inode
            else {
                close(destination)
                throw failure
            }
            do {
                try copyRuntimeFile(
                    sourceDescriptor: source.descriptor,
                    destinationDescriptor: destination,
                    expectedBytes: source.expectedBytes,
                    failure: failure,
                    snapshotOperations: snapshotOperations
                )
                guard snapshotOperations.syncFile(destination) == 0,
                      snapshotOperations.chmodFile(
                          destination,
                          mode_t(0o400)
                      ) == 0
                else { throw failure }
                close(destination)
            } catch {
                close(destination)
                throw error
            }
        }

        let descriptor = snapshotOperations.openMaterializedFile(
            directoryDescriptor,
            name
        )
        guard descriptor >= 0 else { throw failure }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_size == source.expectedBytes,
              status.st_dev > 0,
              status.st_ino > 0,
              status.st_dev != source.device || status.st_ino != source.inode,
              descriptorHasNoExtendedACL(descriptor)
        else { throw failure }
        if let cleanupFile {
            guard status.st_dev == cleanupFile.device,
                  status.st_ino == cleanupFile.inode
            else { throw failure }
        }
        let snapshotFile = SherpaOnnxRuntimeSnapshotFile(
            name: name,
            device: status.st_dev,
            inode: status.st_ino,
            expectedBytes: source.expectedBytes,
            expectedSHA256: source.expectedSHA256
        )
        cleanupFile = snapshotFile
        guard snapshotOperations.chmodFile(
                  descriptor,
                  mode_t(0o400)
              ) == 0,
              fstat(descriptor, &status) == 0,
              status.st_dev == snapshotFile.device,
              status.st_ino == snapshotFile.inode,
              status.st_mode & mode_t(0o777) == mode_t(0o400),
              descriptorHasNoExtendedACL(descriptor),
              try descriptorSHA256(descriptor) == source.expectedSHA256
        else { throw failure }
        completed = true
        return snapshotFile
    }

    private static func copyRuntimeFile(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        expectedBytes: Int64,
        failure: SherpaOnnxProductBackendError,
        snapshotOperations: SherpaOnnxRuntimeSnapshotOperations
    ) throws {
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < expectedBytes {
            let maximum = min(
                Int64(buffer.count),
                expectedBytes - offset
            )
            let count = buffer.withUnsafeMutableBytes { bytes in
                snapshotOperations.readFile(
                    sourceDescriptor,
                    bytes.baseAddress,
                    Int(maximum),
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw failure }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { bytes in
                    snapshotOperations.writeFile(
                        destinationDescriptor,
                        bytes.baseAddress?.advanced(by: written),
                        count - written
                    )
                }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw failure }
                written += result
            }
            offset += Int64(count)
        }
        guard offset == expectedBytes else { throw failure }
    }

    private static func validateRuntimeSnapshot(
        _ files: SherpaOnnxOpenedRuntimeFiles
    ) throws {
        let snapshot = files.runtimeSnapshot
        let failure = SherpaOnnxProductBackendError
            .unsafeModelPath(snapshot.directoryPath)
        let rebound = try openArtifactRoot(snapshot.directoryPath)
        defer { close(rebound) }
        var heldDirectory = stat()
        var reboundDirectory = stat()
        guard fstat(snapshot.directoryDescriptor, &heldDirectory) == 0,
              fstat(rebound, &reboundDirectory) == 0,
              heldDirectory.st_dev == snapshot.directoryDevice,
              heldDirectory.st_ino == snapshot.directoryInode,
              reboundDirectory.st_dev == snapshot.directoryDevice,
              reboundDirectory.st_ino == snapshot.directoryInode,
              heldDirectory.st_mode & mode_t(0o777) == mode_t(0o500),
              heldDirectory.st_uid == geteuid(),
              reboundDirectory.st_uid == geteuid(),
              descriptorHasNoExtendedACL(snapshot.directoryDescriptor),
              descriptorHasNoExtendedACL(rebound),
              snapshot.files.count == files.boundFiles.count
        else { throw failure }

        for snapshotFile in snapshot.files {
            let descriptor = snapshotFile.name.withCString { pointer in
                openat(
                    snapshot.directoryDescriptor,
                    pointer,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else { throw failure }
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_dev == snapshotFile.device,
                  status.st_ino == snapshotFile.inode,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  status.st_mode & mode_t(0o777) == mode_t(0o400),
                  status.st_size == snapshotFile.expectedBytes,
                  descriptorHasNoExtendedACL(descriptor),
                  try descriptorSHA256(descriptor)
                    == snapshotFile.expectedSHA256
            else { throw failure }

        }
    }

    private static func finalizeRuntimeFilesAfterRecognizerCreation(
        _ files: SherpaOnnxOpenedRuntimeFiles,
        artifactRootPath: String
    ) throws {
        try validateRuntimeSnapshot(files)
        try revalidateArtifactRoot(
            artifactRootPath,
            heldDescriptor: files.artifactRootDescriptor
        )
        try files.runtimeSnapshot.remove()
        for file in files.boundFiles {
            var status = stat()
            guard fstat(file.descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_dev == file.device,
                  status.st_ino == file.inode,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  status.st_mode & mode_t(0o022) == 0,
                  status.st_size == file.expectedBytes,
                  descriptorHasNoExtendedACL(file.descriptor),
                  lseek(file.descriptor, 0, SEEK_SET) == 0,
                  try descriptorSHA256(file.descriptor)
                    == file.expectedSHA256,
                  lseek(file.descriptor, 0, SEEK_SET) == 0
            else {
                throw SherpaOnnxProductBackendError
                    .modelFileUnavailable(file.displayPath)
            }
        }
        try revalidateArtifactRoot(
            artifactRootPath,
            heldDescriptor: files.artifactRootDescriptor
        )
    }

    private static func lexicalParentPath(of path: String) throws -> String {
        guard let separator = path.lastIndex(of: "/"),
              separator != path.startIndex
        else {
            throw SherpaOnnxProductBackendError.unsafeModelPath(path)
        }
        return String(path[..<separator])
    }

    private static func revalidateArtifactRoot(
        _ path: String,
        heldDescriptor: Int32
    ) throws {
        let reboundDescriptor = try openArtifactRoot(path)
        defer { close(reboundDescriptor) }
        var held = stat()
        var rebound = stat()
        guard fstat(heldDescriptor, &held) == 0,
              fstat(reboundDescriptor, &rebound) == 0,
              held.st_mode & S_IFMT == S_IFDIR,
              rebound.st_mode & S_IFMT == S_IFDIR,
              held.st_dev == rebound.st_dev,
              held.st_ino == rebound.st_ino,
              descriptorHasNoExtendedACL(heldDescriptor),
              descriptorHasNoExtendedACL(reboundDescriptor)
        else {
            throw SherpaOnnxProductBackendError.unsafeModelPath(path)
        }
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

    private static func isCanonicalRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.utf8.count <= 512,
              path.utf8.elementsEqual(
                  path.precomposedStringWithCanonicalMapping.utf8
              ),
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !path.contains("//"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 })
        else {
            return false
        }
        return path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
                && $0.utf8.count <= 255
                && !$0.hasPrefix("._")
        }
    }

    private static func openArtifactRoot(_ path: String) throws -> Int32 {
        guard isCanonicalAbsolutePath(path) else {
            throw SherpaOnnxProductBackendError.unsafeModelPath(path)
        }
        let components = path.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        var current = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            throw SherpaOnnxProductBackendError.unsafeModelPath(path)
        }
        do {
            for component in components {
                let next = try openBoundDirectory(
                    parentDescriptor: current,
                    name: component,
                    failure: .unsafeModelPath(path)
                )
                close(current)
                current = next
            }
            var rootStatus = stat()
            guard fstat(current, &rootStatus) == 0,
                  rootStatus.st_mode & S_IFMT == S_IFDIR,
                  rootStatus.st_uid == geteuid(),
                  rootStatus.st_mode & mode_t(0o022) == 0,
                  rootStatus.st_mode & mode_t(0o6000) == 0,
                  descriptorHasNoExtendedACL(current)
            else {
                throw SherpaOnnxProductBackendError.unsafeModelPath(path)
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private static func openRuntimeFile(
        relativePath: String,
        displayPath: String,
        rootDescriptor: Int32,
        expectedBytes: Int64
    ) throws -> Int32 {
        guard isCanonicalRelativePath(relativePath) else {
            throw SherpaOnnxProductBackendError
                .unsafeModelPath(relativePath)
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let fileName = components.last else {
            throw SherpaOnnxProductBackendError
                .unsafeModelPath(relativePath)
        }
        var current = openat(
            rootDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            throw SherpaOnnxProductBackendError
                .modelFileUnavailable(displayPath)
        }
        do {
            for component in components.dropLast() {
                let next = try openBoundDirectory(
                    parentDescriptor: current,
                    name: component,
                    failure: .modelFileUnavailable(displayPath)
                )
                guard descriptorHasNoExtendedACL(next) else {
                    close(next)
                    throw SherpaOnnxProductBackendError
                        .modelFileUnavailable(displayPath)
                }
                close(current)
                current = next
            }

            var named = stat()
            let statusResult = fileName.withCString { pointer in
                fstatat(
                    current,
                    pointer,
                    &named,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard statusResult == 0,
                  named.st_mode & S_IFMT == S_IFREG
            else {
                throw SherpaOnnxProductBackendError
                    .modelFileUnavailable(displayPath)
            }
            let descriptor = fileName.withCString { pointer in
                openat(
                    current,
                    pointer,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard descriptor >= 0 else {
                throw SherpaOnnxProductBackendError
                    .modelFileUnavailable(displayPath)
            }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  opened.st_mode & S_IFMT == S_IFREG,
                  opened.st_dev == named.st_dev,
                  opened.st_ino == named.st_ino,
                  opened.st_uid == geteuid(),
                  opened.st_nlink == 1,
                  opened.st_mode & mode_t(0o022) == 0,
                  opened.st_size == expectedBytes,
                  descriptorHasNoExtendedACL(descriptor)
            else {
                close(descriptor)
                throw SherpaOnnxProductBackendError
                    .modelFileUnavailable(displayPath)
            }
            close(current)
            return descriptor
        } catch {
            close(current)
            throw error
        }
    }

    private static func openBoundDirectory(
        parentDescriptor: Int32,
        name: String,
        failure: SherpaOnnxProductBackendError
    ) throws -> Int32 {
        var parent = stat()
        var named = stat()
        let statusResult = name.withCString { pointer in
            fstatat(
                parentDescriptor,
                pointer,
                &named,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard fstat(parentDescriptor, &parent) == 0,
              parent.st_mode & S_IFMT == S_IFDIR,
              parent.st_uid == 0 || parent.st_uid == geteuid(),
              parent.st_mode & mode_t(0o6000) == 0,
              descriptorACLDoesNotGrantAuthority(parentDescriptor),
              statusResult == 0,
              named.st_mode & S_IFMT == S_IFDIR,
              named.st_uid == 0 || named.st_uid == geteuid(),
              named.st_mode & mode_t(0o6000) == 0
        else {
            throw failure
        }
        if parent.st_mode & mode_t(0o022) != 0 {
            // A root-owned sticky directory such as /private/tmp cannot
            // rename a child owned by root or this effective UID. No other
            // group/other-writable edge is an authority boundary.
            guard parent.st_uid == 0,
                  parent.st_mode & mode_t(S_ISVTX) != 0
            else { throw failure }
        }
        let descriptor = name.withCString { pointer in
            openat(
                parentDescriptor,
                pointer,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw failure
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFDIR,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino,
              opened.st_uid == 0 || opened.st_uid == geteuid(),
              opened.st_mode & mode_t(0o6000) == 0,
              descriptorACLDoesNotGrantAuthority(descriptor)
        else {
            close(descriptor)
            throw failure
        }
        return descriptor
    }

    private static func descriptorHasNoExtendedACL(
        _ descriptor: Int32
    ) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT
        }
        acl_free(UnsafeMutableRawPointer(acl))
        return false
    }

    private static func descriptorACLDoesNotGrantAuthority(
        _ descriptor: Int32
    ) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return false }

        var entry: acl_entry_t?
        var entryID = ACL_FIRST_ENTRY
        while true {
            errno = 0
            let result = acl_get_entry(
                acl,
                entryID.rawValue,
                &entry
            )
            if result < 0 {
                return errno == EINVAL
            }
            guard result == 0, let entry else { return false }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0,
                  tag == ACL_EXTENDED_DENY
            else { return false }
            entryID = ACL_NEXT_ENTRY
        }
    }

    private static func configuration(
        _ configuration: SherpaOnnxRecognizerConfiguration,
        boundTo files: SherpaOnnxOpenedRuntimeFiles
    ) -> SherpaOnnxRecognizerConfiguration {
        let paths = files.runtimeSnapshot.runtimePaths
        if configuration.modelType
            == VoiceASRArtifactManifest.Runtime.ModelType.paraformer.rawValue
        {
            precondition(paths.count == 3)
            return SherpaOnnxRecognizerConfiguration(
                encoderPath: paths[0],
                decoderPath: paths[1],
                joinerPath: "",
                tokensPath: paths[2],
                bpeVocabularyPath: "",
                sampleRateHertz: configuration.sampleRateHertz,
                featureDimension: configuration.featureDimension,
                numberOfThreads: configuration.numberOfThreads,
                provider: configuration.provider,
                modelType: configuration.modelType,
                modelingUnit: configuration.modelingUnit,
                decodingMethod: configuration.decodingMethod,
                maximumActivePaths: configuration.maximumActivePaths,
                endpointEnabled: configuration.endpointEnabled,
                rule1MinimumTrailingSilenceSeconds:
                    configuration.rule1MinimumTrailingSilenceSeconds,
                rule2MinimumTrailingSilenceSeconds:
                    configuration.rule2MinimumTrailingSilenceSeconds,
                rule3MinimumUtteranceSeconds:
                    configuration.rule3MinimumUtteranceSeconds,
                hotwordsScore: configuration.hotwordsScore,
                blankPenalty: configuration.blankPenalty
            )
        }
        precondition(paths.count == 5)
        return SherpaOnnxRecognizerConfiguration(
            encoderPath: paths[0],
            decoderPath: paths[1],
            joinerPath: paths[2],
            tokensPath: paths[3],
            bpeVocabularyPath: paths[4],
            sampleRateHertz: configuration.sampleRateHertz,
            featureDimension: configuration.featureDimension,
            numberOfThreads: configuration.numberOfThreads,
            provider: configuration.provider,
            modelType: configuration.modelType,
            modelingUnit: configuration.modelingUnit,
            decodingMethod: configuration.decodingMethod,
            maximumActivePaths: configuration.maximumActivePaths,
            endpointEnabled: configuration.endpointEnabled,
            rule1MinimumTrailingSilenceSeconds:
                configuration.rule1MinimumTrailingSilenceSeconds,
            rule2MinimumTrailingSilenceSeconds:
                configuration.rule2MinimumTrailingSilenceSeconds,
            rule3MinimumUtteranceSeconds:
                configuration.rule3MinimumUtteranceSeconds,
            hotwordsScore: configuration.hotwordsScore,
            blankPenalty: configuration.blankPenalty
        )
    }

    private static func descriptorSHA256(_ descriptor: Int32) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { storage in
                read(descriptor, storage.baseAddress, storage.count)
            }
            if count > 0 {
                hasher.update(data: Data(buffer.prefix(count)))
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw SherpaOnnxProductBackendError
                .modelFileUnavailable("descriptor:\(descriptor)")
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

}

private struct SherpaOnnxBoundRuntimeFileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
}

private struct SherpaOnnxBoundRuntimeFile {
    let descriptor: Int32
    let relativePath: String
    let displayPath: String
    let expectedBytes: Int64
    let expectedSHA256: String
    let device: dev_t
    let inode: ino_t

    var identity: SherpaOnnxBoundRuntimeFileIdentity {
        SherpaOnnxBoundRuntimeFileIdentity(device: device, inode: inode)
    }
}

private struct SherpaOnnxRuntimeSnapshotFile {
    let name: String
    let device: dev_t
    let inode: ino_t
    let expectedBytes: Int64
    let expectedSHA256: String
}

private func unlinkBoundRuntimeSnapshotFile(
    directoryDescriptor: Int32,
    file: SherpaOnnxRuntimeSnapshotFile
) -> Bool {
    var named = stat()
    let statusResult = file.name.withCString { pointer in
        fstatat(
            directoryDescriptor,
            pointer,
            &named,
            AT_SYMLINK_NOFOLLOW
        )
    }
    guard statusResult == 0,
          named.st_mode & S_IFMT == S_IFREG,
          named.st_dev == file.device,
          named.st_ino == file.inode
    else { return false }
    return file.name.withCString { pointer in
        unlinkat(directoryDescriptor, pointer, 0)
    } == 0
}

private func unlinkBoundRuntimeSnapshotDirectory(
    parentDescriptor: Int32,
    directoryName: String,
    expectedDevice: dev_t,
    expectedInode: ino_t
) -> Bool {
    var named = stat()
    let statusResult = directoryName.withCString { pointer in
        fstatat(
            parentDescriptor,
            pointer,
            &named,
            AT_SYMLINK_NOFOLLOW
        )
    }
    guard statusResult == 0,
          named.st_mode & S_IFMT == S_IFDIR,
          named.st_dev == expectedDevice,
          named.st_ino == expectedInode
    else { return false }
    return directoryName.withCString { pointer in
        unlinkat(parentDescriptor, pointer, AT_REMOVEDIR)
    } == 0
}

private final class SherpaOnnxRuntimeSnapshot {
    let parentDescriptor: Int32
    let directoryDescriptor: Int32
    let directoryName: String
    let directoryPath: String
    let directoryDevice: dev_t
    let directoryInode: ino_t
    let files: [SherpaOnnxRuntimeSnapshotFile]
    let runtimePaths: [String]
    private var removed = false

    init(
        parentDescriptor: Int32,
        directoryDescriptor: Int32,
        directoryName: String,
        directoryPath: String,
        directoryDevice: dev_t,
        directoryInode: ino_t,
        files: [SherpaOnnxRuntimeSnapshotFile],
        runtimePaths: [String]
    ) {
        self.parentDescriptor = parentDescriptor
        self.directoryDescriptor = directoryDescriptor
        self.directoryName = directoryName
        self.directoryPath = directoryPath
        self.directoryDevice = directoryDevice
        self.directoryInode = directoryInode
        self.files = files
        self.runtimePaths = runtimePaths
    }

    func remove() throws {
        guard !removed else { return }
        let failure = SherpaOnnxProductBackendError
            .unsafeModelPath(directoryPath)
        guard fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
            throw failure
        }
        for file in files.reversed() {
            guard unlinkBoundRuntimeSnapshotFile(
                directoryDescriptor: directoryDescriptor,
                file: file
            ) else { throw failure }
        }
        guard unlinkBoundRuntimeSnapshotDirectory(
            parentDescriptor: parentDescriptor,
            directoryName: directoryName,
            expectedDevice: directoryDevice,
            expectedInode: directoryInode
        ) else { throw failure }
        removed = true
    }

    deinit {
        if !removed {
            _ = fchmod(directoryDescriptor, mode_t(0o700))
            for file in files.reversed() {
                _ = unlinkBoundRuntimeSnapshotFile(
                    directoryDescriptor: directoryDescriptor,
                    file: file
                )
            }
            _ = unlinkBoundRuntimeSnapshotDirectory(
                parentDescriptor: parentDescriptor,
                directoryName: directoryName,
                expectedDevice: directoryDevice,
                expectedInode: directoryInode
            )
        }
        close(directoryDescriptor)
        close(parentDescriptor)
    }
}

private final class SherpaOnnxOpenedRuntimeFiles: @unchecked Sendable {
    let artifactRootDescriptor: Int32
    let boundFiles: [SherpaOnnxBoundRuntimeFile]
    let runtimeSnapshot: SherpaOnnxRuntimeSnapshot

    init(
        artifactRootDescriptor: Int32,
        boundFiles: [SherpaOnnxBoundRuntimeFile],
        runtimeSnapshot: SherpaOnnxRuntimeSnapshot
    ) {
        self.artifactRootDescriptor = artifactRootDescriptor
        self.boundFiles = boundFiles
        self.runtimeSnapshot = runtimeSnapshot
    }

    deinit {
        for file in boundFiles {
            close(file.descriptor)
        }
        close(artifactRootDescriptor)
    }
}

private final class SherpaOnnxRecognizerDriver:
    VoiceStreamingRecognizerDriver,
    @unchecked Sendable
{
    let artifactGeneration: UUID
    private let recognizer: any SherpaOnnxRecognizerRunning
    private let openedRuntimeFiles: SherpaOnnxOpenedRuntimeFiles
    private let hotwordsSupported: Bool

    init(
        artifactGeneration: UUID,
        recognizer: any SherpaOnnxRecognizerRunning,
        openedRuntimeFiles: SherpaOnnxOpenedRuntimeFiles,
        hotwordsSupported: Bool
    ) {
        self.artifactGeneration = artifactGeneration
        self.recognizer = recognizer
        self.openedRuntimeFiles = openedRuntimeFiles
        self.hotwordsSupported = hotwordsSupported
    }

    func startSession(hotwords: [String]) throws {
        guard hotwordsSupported || hotwords.isEmpty else {
            throw SherpaOnnxProductBackendError.hotwordsUnsupported
        }
        try recognizer.startSession(hotwords: hotwords)
    }

    func resetEndpoint() throws {
        try recognizer.resetEndpoint()
    }

    func accept(samples: [Float]) throws -> VoiceStreamingRecognitionUpdate {
        try recognizer.accept(samples: samples)
    }

    func finish() throws -> VoiceStreamingRecognitionUpdate {
        try recognizer.finish()
    }

    func cancel() {
        recognizer.cancel()
    }
}

private struct SystemSherpaOnnxRuntime:
    SherpaOnnxRuntimeLoading,
    Sendable
{
    func identity() throws -> SherpaOnnxRuntimeIdentity {
        var sherpa: UnsafePointer<CChar>?
        var revision: UnsafePointer<CChar>?
        var onnx: UnsafePointer<CChar>?
        guard RimeAISherpaOnnxGetVersionStr(&sherpa)
                == RimeAISherpaOnnxStatusSuccess,
              let sherpa,
              RimeAISherpaOnnxGetGitSha1(&revision)
                == RimeAISherpaOnnxStatusSuccess,
              let revision,
              RimeAISherpaOnnxGetOnnxruntimeVersionStr(&onnx)
                == RimeAISherpaOnnxStatusSuccess,
              let onnx
        else {
            throw SherpaOnnxProductBackendError.runtimeMetadataUnavailable
        }
        return SherpaOnnxRuntimeIdentity(
            sherpaVersion: String(cString: sherpa),
            sherpaGitRevision: String(cString: revision),
            onnxRuntimeVersion: String(cString: onnx)
        )
    }

    func makeRecognizer(
        configuration: SherpaOnnxRecognizerConfiguration
    ) throws -> any SherpaOnnxRecognizerRunning {
        let strings = SherpaOnnxCStringArena()
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = Int32(
            configuration.sampleRateHertz
        )
        config.feat_config.feature_dim = Int32(
            configuration.featureDimension
        )
        if configuration.modelType
            == VoiceASRArtifactManifest.Runtime.ModelType.paraformer.rawValue
        {
            config.model_config.paraformer.encoder = try strings.copy(
                configuration.encoderPath
            )
            config.model_config.paraformer.decoder = try strings.copy(
                configuration.decoderPath
            )
            config.model_config.tokens = try strings.copy(
                configuration.tokensPath
            )
        } else {
            config.model_config.transducer.encoder = try strings.copy(
                configuration.encoderPath
            )
            config.model_config.transducer.decoder = try strings.copy(
                configuration.decoderPath
            )
            config.model_config.transducer.joiner = try strings.copy(
                configuration.joinerPath
            )
            config.model_config.tokens = try strings.copy(
                configuration.tokensPath
            )
            config.model_config.bpe_vocab = try strings.copy(
                configuration.bpeVocabularyPath
            )
        }
        config.model_config.num_threads = Int32(
            configuration.numberOfThreads
        )
        config.model_config.provider = try strings.copy(
            configuration.provider
        )
        config.model_config.model_type = try strings.copy(
            configuration.modelType
        )
        config.model_config.modeling_unit = try strings.copy(
            configuration.modelingUnit
        )
        config.decoding_method = try strings.copy(
            configuration.decodingMethod
        )
        config.max_active_paths = Int32(
            configuration.maximumActivePaths
        )
        config.enable_endpoint = configuration.endpointEnabled ? 1 : 0
        config.rule1_min_trailing_silence =
            configuration.rule1MinimumTrailingSilenceSeconds
        config.rule2_min_trailing_silence =
            configuration.rule2MinimumTrailingSilenceSeconds
        config.rule3_min_utterance_length =
            configuration.rule3MinimumUtteranceSeconds
        config.hotwords_score = configuration.hotwordsScore
        config.blank_penalty = configuration.blankPenalty

        var recognizer: OpaquePointer?
        guard RimeAISherpaOnnxCreateOnlineRecognizer(
                  &config,
                  &recognizer
              ) == RimeAISherpaOnnxStatusSuccess,
              let recognizer
        else {
            throw SherpaOnnxProductBackendError
                .recognizerInitializationFailed
        }
        var stream: OpaquePointer?
        guard RimeAISherpaOnnxCreateOnlineStream(
                  recognizer,
                  &stream
              ) == RimeAISherpaOnnxStatusSuccess,
              let stream
        else {
            _ = RimeAISherpaOnnxDestroyOnlineRecognizer(recognizer)
            throw SherpaOnnxProductBackendError.streamInitializationFailed
        }
        return SherpaOnnxCRecognizer(
            recognizer: recognizer,
            stream: stream
        )
    }
}

private final class SherpaOnnxCStringArena {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    func copy(_ value: String) throws -> UnsafePointer<CChar> {
        guard let pointer = strdup(value) else {
            throw SherpaOnnxProductBackendError
                .recognizerInitializationFailed
        }
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }

    deinit {
        for pointer in pointers {
            free(pointer)
        }
    }
}

private final class SherpaOnnxCRecognizer:
    SherpaOnnxRecognizerRunning,
    @unchecked Sendable
{
    private static let maximumIncrementalDecodeSteps = 256
    private static let maximumFinalDecodeSteps = 8_192

    private let recognizer: OpaquePointer
    private var stream: OpaquePointer?

    init(recognizer: OpaquePointer, stream: OpaquePointer) {
        self.recognizer = recognizer
        self.stream = stream
    }

    deinit {
        if let stream {
            _ = RimeAISherpaOnnxDestroyOnlineStream(stream)
        }
        _ = RimeAISherpaOnnxDestroyOnlineRecognizer(recognizer)
    }

    func startSession(hotwords: [String]) throws {
        var newStream: OpaquePointer?
        let status: RimeAISherpaOnnxStatus
        if hotwords.isEmpty {
            status = RimeAISherpaOnnxCreateOnlineStream(
                recognizer,
                &newStream
            )
        } else {
            let text = hotwords.joined(separator: "\n")
            status = text.withCString {
                RimeAISherpaOnnxCreateOnlineStreamWithHotwords(
                    recognizer,
                    $0,
                    &newStream
                )
            }
        }
        guard status == RimeAISherpaOnnxStatusSuccess,
              let newStream
        else {
            throw SherpaOnnxProductBackendError.streamInitializationFailed
        }
        if let oldStream = stream {
            _ = RimeAISherpaOnnxDestroyOnlineStream(oldStream)
        }
        stream = newStream
    }

    func resetEndpoint() throws {
        guard let stream else {
            throw SherpaOnnxProductBackendError.streamInitializationFailed
        }
        guard RimeAISherpaOnnxOnlineStreamReset(recognizer, stream)
                == RimeAISherpaOnnxStatusSuccess
        else {
            throw SherpaOnnxProductBackendError.runtimeCallFailed
        }
    }

    func accept(samples: [Float]) throws -> VoiceStreamingRecognitionUpdate {
        guard samples.count == VoicePCMFrame.samplesPerFrame,
              samples.allSatisfy(\.isFinite),
              let stream
        else {
            throw SherpaOnnxProductBackendError.invalidAudioFrame
        }
        let status = samples.withUnsafeBufferPointer { buffer in
            RimeAISherpaOnnxOnlineStreamAcceptWaveform(
                stream,
                Int32(VoicePCMFrame.sampleRateHertz),
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard status == RimeAISherpaOnnxStatusSuccess else {
            throw SherpaOnnxProductBackendError.runtimeCallFailed
        }
        try decodeReadyStream(
            stream,
            maximumSteps: Self.maximumIncrementalDecodeSteps
        )
        return try currentUpdate(stream)
    }

    func finish() throws -> VoiceStreamingRecognitionUpdate {
        guard let stream else {
            throw SherpaOnnxProductBackendError.resultUnavailable
        }
        guard RimeAISherpaOnnxOnlineStreamInputFinished(stream)
                == RimeAISherpaOnnxStatusSuccess
        else {
            throw SherpaOnnxProductBackendError.runtimeCallFailed
        }
        try decodeReadyStream(
            stream,
            maximumSteps: Self.maximumFinalDecodeSteps
        )
        return try currentUpdate(stream)
    }

    func cancel() {
        guard let stream else { return }
        self.stream = nil
        _ = RimeAISherpaOnnxDestroyOnlineStream(stream)
    }

    private func decodeReadyStream(
        _ stream: OpaquePointer,
        maximumSteps: Int
    ) throws {
        var steps = 0
        while true {
            var isReady: Int32 = 0
            guard RimeAISherpaOnnxIsOnlineStreamReady(
                      recognizer,
                      stream,
                      &isReady
                  ) == RimeAISherpaOnnxStatusSuccess
            else {
                throw SherpaOnnxProductBackendError.runtimeCallFailed
            }
            guard isReady != 0 else { return }
            guard steps < maximumSteps else {
                throw SherpaOnnxProductBackendError
                    .decodeStepLimitExceeded
            }
            guard RimeAISherpaOnnxDecodeOnlineStream(
                      recognizer,
                      stream
                  ) == RimeAISherpaOnnxStatusSuccess
            else {
                throw SherpaOnnxProductBackendError.runtimeCallFailed
            }
            steps += 1
        }
    }

    private func currentUpdate(
        _ stream: OpaquePointer
    ) throws -> VoiceStreamingRecognitionUpdate {
        var result: UnsafePointer<SherpaOnnxOnlineRecognizerResult>?
        guard RimeAISherpaOnnxGetOnlineStreamResult(
                  recognizer,
                  stream,
                  &result
              ) == RimeAISherpaOnnxStatusSuccess,
              let result
        else {
            throw SherpaOnnxProductBackendError.resultUnavailable
        }
        defer {
            _ = RimeAISherpaOnnxDestroyOnlineRecognizerResult(result)
        }
        let text = result.pointee.text.map(String.init(cString:)) ?? ""
        var isEndpoint: Int32 = 0
        guard RimeAISherpaOnnxOnlineStreamIsEndpoint(
                  recognizer,
                  stream,
                  &isEndpoint
              ) == RimeAISherpaOnnxStatusSuccess
        else {
            throw SherpaOnnxProductBackendError.runtimeCallFailed
        }
        return VoiceStreamingRecognitionUpdate(
            text: text,
            isEndpoint: isEndpoint != 0
        )
    }
}

/// Explicitly empty baseline provider used until a bounded Rime-derived
/// snapshot is supplied. It does not read dictionaries, documents, clipboard,
/// or history.
public struct EmptyVoiceHotwordProvider: VoiceHotwordProviding, Sendable {
    public init() {}

    public func snapshot(
        for request: VoiceDictationEngineRequest,
        maximumEntries: Int
    ) throws -> VoiceHotwordSnapshot {
        .empty
    }
}

/// Narrow assembly seam for an artifact lease admitted by another module.
/// This API cannot select a URL, invoke a verifier, read the product Store, or
/// consult the release catalog; callers must first construct the exact lease.
@_spi(VoiceArtifactAssembly)
public enum VoiceAdmittedArtifactEngineAssemblyError:
    Error,
    Equatable,
    Sendable
{
    case backendLoadFailed
}

@_spi(VoiceArtifactAssembly)
public enum SherpaOnnxAdmittedArtifactVoiceEngineFactory {
    private struct PreparedBackend: Sendable {
        let descriptor: VoiceEngineDescriptor
        let recognizerDriver: any VoiceStreamingRecognizerDriver
    }

    @_spi(VoiceArtifactAssembly)
    public static func makeEngine(
        lease: VoiceASRVerifiedArtifactLease,
        sourceFactory: any VoicePCMSourceFactory,
        hotwordProvider: any VoiceHotwordProviding =
            RequestVoiceHotwordProvider()
    ) throws -> any VoiceDictationEngine {
        do {
            return try makeEngine(
                lease: lease,
                backendLoader: SherpaOnnxProductBackendLoader(),
                sourceFactory: sourceFactory,
                hotwordProvider: hotwordProvider
            )
        } catch let error as SherpaOnnxProductBackendError {
            _ = error
            throw VoiceAdmittedArtifactEngineAssemblyError.backendLoadFailed
        } catch is VoiceProductBackendLoadError {
            throw VoiceAdmittedArtifactEngineAssemblyError.backendLoadFailed
        } catch is ProductManagedVoiceEngineBootstrapError {
            throw VoiceAdmittedArtifactEngineAssemblyError.backendLoadFailed
        } catch is VoiceProductEngineDescriptorError {
            throw VoiceAdmittedArtifactEngineAssemblyError.backendLoadFailed
        } catch is ProductStreamingVoiceEngineError {
            throw VoiceAdmittedArtifactEngineAssemblyError.backendLoadFailed
        }
    }

    static func makeEngine(
        lease: VoiceASRVerifiedArtifactLease,
        backendLoader: any VoiceProductBackendLoading,
        sourceFactory: any VoicePCMSourceFactory,
        hotwordProvider: any VoiceHotwordProviding
    ) throws -> ProductStreamingVoiceEngine {
        let loaded = try backendLoader.load(lease: lease)
        guard loaded.recognizerDriver.artifactGeneration
                == lease.generation,
              loaded.loadProbe.artifactGeneration == lease.generation
        else {
            throw ProductManagedVoiceEngineBootstrapError
                .artifactGenerationMismatch
        }
        let prepared = PreparedBackend(
            descriptor: try VoiceEngineDescriptor.productManaged(
                lease: lease,
                loadProbe: loaded.loadProbe
            ),
            recognizerDriver: loaded.recognizerDriver
        )

        return try ProductStreamingVoiceEngine(
            descriptor: prepared.descriptor,
            sourceFactory: sourceFactory,
            recognizerDriver: prepared.recognizerDriver,
            hotwordProvider: hotwordProvider
        )
    }
}

/// The only production assembly entry point exported to the helper executable.
/// It fails closed when no verified current artifact exists or when the pinned
/// runtime/model contract cannot be loaded.
public enum SherpaOnnxProductVoiceEngineFactory {
    public static func makeEngine(
        layout: RimeAIProductDataLayout,
        hotwordProvider: any VoiceHotwordProviding =
            RequestVoiceHotwordProvider()
    ) throws -> any VoiceDictationEngine {
        try makeEngine(
            store: VoiceASRArtifactStore(layout: layout),
            backendLoader: SherpaOnnxProductBackendLoader(),
            sourceFactory: AVAudioEnginePCMSourceFactory(),
            hotwordProvider: hotwordProvider
        )
    }

    static func makeEngine(
        store: VoiceASRArtifactStore,
        backendLoader: any VoiceProductBackendLoading,
        sourceFactory: any VoicePCMSourceFactory,
        hotwordProvider: any VoiceHotwordProviding
    ) throws -> ProductStreamingVoiceEngine {
        try ProductManagedVoiceEngineBootstrap(
            store: store,
            backendLoader: ProductionApprovedSherpaOnnxBackendLoader(
                delegate: backendLoader
            )
        ).makeEngine(
            sourceFactory: sourceFactory,
            hotwordProvider: hotwordProvider
        )
    }
}

private struct ProductionApprovedSherpaOnnxBackendLoader:
    VoiceProductBackendLoading,
    Sendable
{
    private let delegate: any VoiceProductBackendLoading

    init(delegate: any VoiceProductBackendLoading) {
        self.delegate = delegate
    }

    func load(
        lease: VoiceASRVerifiedArtifactLease
    ) throws -> VoiceProductBackendLoad {
        guard VoiceASRTrustedArtifactCatalog.production.approves(
            lease.artifact
        ) else {
            throw SherpaOnnxProductBackendError.untrustedArtifact(
                lease.artifact.manifest.artifactID
            )
        }
        return try delegate.load(lease: lease)
    }
}
