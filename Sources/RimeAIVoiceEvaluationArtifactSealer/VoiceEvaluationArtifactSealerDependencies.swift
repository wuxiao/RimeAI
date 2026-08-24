import Darwin
import Foundation
import RimeAIVoiceArtifactCore

enum VoiceEvaluationArtifactSealerSystemFailure: Error {
    case write
    case synchronize
}

struct VoiceEvaluationArtifactSealerDependencies: @unchecked Sendable {
    var effectiveUserID: () -> uid_t
    var hasNoExtendedACL: (Int32) -> Bool
    var afterInitialPayloadsHashed: () throws -> Void
    var writeManifest: (Int32, Data) throws -> Void
    var synchronize: (Int32) throws -> Void
    var unlinkManifest: (Int32) -> Int32
    var verifyArtifact: (URL) throws -> VoiceASRVerifiedArtifact

    static let live = Self(
        effectiveUserID: { geteuid() },
        hasNoExtendedACL: { descriptor in
            errno = 0
            guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
                return errno == ENOENT
            }
            acl_free(UnsafeMutableRawPointer(acl))
            return false
        },
        afterInitialPayloadsHashed: {},
        writeManifest: { descriptor, data in
            var offset = 0
            try data.withUnsafeBytes { bytes in
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw VoiceEvaluationArtifactSealerSystemFailure.write
                    }
                    offset += count
                }
            }
        },
        synchronize: { descriptor in
            guard fsync(descriptor) == 0 else {
                throw VoiceEvaluationArtifactSealerSystemFailure.synchronize
            }
        },
        unlinkManifest: { rootDescriptor in
            unlinkat(
                rootDescriptor,
                VoiceASRArtifactManifest.manifestFileName,
                0
            )
        },
        verifyArtifact: { directory in
            try VoiceASRArtifactVerifier().verifyArtifact(at: directory)
        }
    )
}
