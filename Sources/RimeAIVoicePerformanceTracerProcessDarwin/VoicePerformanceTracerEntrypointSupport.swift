import Darwin

package enum VoicePerformanceTracerEntrypointExitStatus:
    Int32,
    CaseIterable,
    Sendable
{
    case success = 0
    case usage = 64
    case data = 65
    case internalFailure = 70
    case io = 74
    case temporary = 75
    case authority = 77

    fileprivate var diagnosticCode: String? {
        switch self {
        case .success:
            nil
        case .usage:
            "E_USAGE"
        case .data:
            "E_DATA"
        case .internalFailure:
            "E_INTERNAL"
        case .io:
            "E_IO"
        case .temporary:
            "E_TEMPORARY"
        case .authority:
            "E_AUTHORITY"
        }
    }
}

package enum VoicePerformanceTracerExecutableRole: Sendable {
    case collector
    case driver
    case helper

    fileprivate var binaryName: String {
        switch self {
        case .collector:
            "rimeai-voice-performance-tracer"
        case .driver:
            "rimeai-voice-performance-driver"
        case .helper:
            "rimeai-voice-performance-helper"
        }
    }
}

package enum VoicePerformanceTracerEntrypointSupport {
    package static func diagnosticLine(
        role: VoicePerformanceTracerExecutableRole,
        status: VoicePerformanceTracerEntrypointExitStatus
    ) -> String? {
        guard let code = status.diagnosticCode else { return nil }
        return role.binaryName + ":" + code + "\n"
    }

    package static func writeStandardError(_ line: String) {
        let bytes = Array(line.utf8)
        bytes.withUnsafeBytes { storage in
            guard let baseAddress = storage.baseAddress else { return }
            var offset = 0
            while offset < storage.count {
                let written = Darwin.write(
                    STDERR_FILENO,
                    baseAddress.advanced(by: offset),
                    storage.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}
