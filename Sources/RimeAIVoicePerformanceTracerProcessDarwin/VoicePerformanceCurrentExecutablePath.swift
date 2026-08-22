import Darwin
import Foundation

public enum VoicePerformanceCurrentExecutablePathError:
    Error,
    Equatable,
    Sendable
{
    case unavailable
}

protocol VoicePerformanceCurrentExecutablePathSystem {
    var currentProcessIdentifier: pid_t { get }
    var lastError: Int32 { get }

    func query(
        pid: pid_t,
        buffer: UnsafeMutablePointer<CChar>,
        size: UInt32
    ) -> Int32
}

public enum VoicePerformanceCurrentExecutablePath {
    public static func resolve() throws -> String {
        try resolve(system: DarwinCurrentExecutablePathSystem())
    }

    static func resolve(
        system: any VoicePerformanceCurrentExecutablePathSystem
    ) throws -> String {
        var bytes = [CChar](
            repeating: 0,
            count: 4 * Int(MAXPATHLEN)
        )
        var count: Int32 = -1
        repeat {
            count = bytes.withUnsafeMutableBufferPointer { buffer in
                system.query(
                    pid: system.currentProcessIdentifier,
                    buffer: buffer.baseAddress!,
                    size: UInt32(buffer.count)
                )
            }
        } while count <= 0 && system.lastError == EINTR

        guard count > 1,
              Int(count) < bytes.count,
              bytes[Int(count)] == 0,
              !bytes[..<Int(count)].contains(0),
              let path = String(
                  bytes: bytes[..<Int(count)].map(
                      UInt8.init(bitPattern:)
                  ),
                  encoding: .utf8
              ),
              isCanonicalAbsolutePath(
                  path,
                  requireTracerBundle: false
              )
        else {
            throw VoicePerformanceCurrentExecutablePathError.unavailable
        }
        return path
    }
}

private struct DarwinCurrentExecutablePathSystem:
    VoicePerformanceCurrentExecutablePathSystem
{
    var currentProcessIdentifier: pid_t { getpid() }
    var lastError: Int32 { errno }

    func query(
        pid: pid_t,
        buffer: UnsafeMutablePointer<CChar>,
        size: UInt32
    ) -> Int32 {
        proc_pidpath(pid, buffer, size)
    }
}
