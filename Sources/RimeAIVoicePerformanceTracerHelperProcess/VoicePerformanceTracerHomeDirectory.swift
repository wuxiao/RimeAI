import Darwin
import Foundation

enum VoicePerformanceTracerHomeDirectoryError:
    Error,
    Equatable,
    Sendable
{
    case userRecordUnavailable
    case invalidHomeDirectory
}

protocol VoicePerformanceTracerUserRecordSystem: Sendable {
    var effectiveUserID: uid_t { get }
    func homeDirectory(for userID: uid_t) throws -> String
}

struct VoicePerformanceTracerHomeDirectoryResolver: Sendable {
    private let system: any VoicePerformanceTracerUserRecordSystem

    init(
        system: any VoicePerformanceTracerUserRecordSystem =
            DarwinVoicePerformanceTracerUserRecordSystem()
    ) {
        self.system = system
    }

    func resolve() throws -> URL {
        let path = try system.homeDirectory(
            for: system.effectiveUserID
        )
        guard path == path.precomposedStringWithCanonicalMapping,
              path.hasPrefix("/"),
              path != "/",
              !path.hasSuffix("/"),
              path.utf8.count < Int(MAXPATHLEN),
              !path.utf8.contains(0),
              path.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value != 0x7f
              })
        else {
            throw VoicePerformanceTracerHomeDirectoryError
                .invalidHomeDirectory
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard url.path == path,
              url.standardizedFileURL.path == path
        else {
            throw VoicePerformanceTracerHomeDirectoryError
                .invalidHomeDirectory
        }
        return url
    }
}

private struct DarwinVoicePerformanceTracerUserRecordSystem:
    VoicePerformanceTracerUserRecordSystem,
    Sendable
{
    var effectiveUserID: uid_t { geteuid() }

    func homeDirectory(for userID: uid_t) throws -> String {
        let recommended = sysconf(_SC_GETPW_R_SIZE_MAX)
        var capacity = recommended > 0
            ? max(1_024, Int(recommended))
            : 16_384
        capacity = min(capacity, 1_048_576)

        while capacity <= 1_048_576 {
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: capacity)
            let status = buffer.withUnsafeMutableBufferPointer { storage in
                getpwuid_r(
                    userID,
                    &record,
                    storage.baseAddress,
                    storage.count,
                    &result
                )
            }
            if status == 0,
               result != nil,
               record.pw_uid == userID,
               let directory = record.pw_dir,
               directory.pointee != 0
            {
                return String(cString: directory)
            }
            guard status == ERANGE,
                  capacity < 1_048_576
            else {
                throw VoicePerformanceTracerHomeDirectoryError
                    .userRecordUnavailable
            }
            capacity = min(capacity * 2, 1_048_576)
        }
        throw VoicePerformanceTracerHomeDirectoryError
            .userRecordUnavailable
    }
}
