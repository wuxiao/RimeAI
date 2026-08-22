import Darwin
import Testing

@testable import RimeAIVoicePerformanceTracerProcessDarwin

@Suite("Voice performance current executable path")
struct VoicePerformanceCurrentExecutablePathTests {
    @Test("proc_pidpath retries EINTR for the same current process")
    func retriesInterruptedQuery() throws {
        let expected = "/Applications/RimeAI.app/Contents/MacOS/rimeai"
        let system = ScriptedCurrentExecutablePathSystem(
            processIdentifier: 41,
            replies: [
                .failure(error: EINTR),
                .path(expected),
            ]
        )

        let resolved = try VoicePerformanceCurrentExecutablePath.resolve(
            system: system
        )

        #expect(resolved.utf8.elementsEqual(expected.utf8))
        #expect(system.queriedProcessIdentifiers == [41, 41])
    }

    @Test("noncanonical kernel paths are rejected without normalization")
    func rejectsNoncanonicalPaths() {
        let decomposed = "/Applications/Cafe\u{301}/rimeai"
        let overlongComponent = "/" + String(repeating: "a", count: 256)
        let invalidPaths = [
            "relative/rimeai",
            "/Applications/./rimeai",
            "/Applications/../rimeai",
            "/Applications//rimeai",
            "/Applications/rimeai/",
            "/Applications/rime\n",
            decomposed,
            overlongComponent,
        ]

        for path in invalidPaths {
            let system = ScriptedCurrentExecutablePathSystem(
                processIdentifier: 42,
                replies: [.path(path)]
            )
            #expect(
                throws: VoicePerformanceCurrentExecutablePathError
                    .unavailable
            ) {
                try VoicePerformanceCurrentExecutablePath.resolve(
                    system: system
                )
            }
        }
    }

    @Test("malformed proc_pidpath byte results fail closed")
    func rejectsMalformedKernelResults() {
        let bufferSize = 4 * Int(MAXPATHLEN)
        let replies: [ScriptedCurrentExecutablePathSystem.Reply] = [
            .raw(count: 0, bytes: []),
            .raw(count: -1, error: EIO, bytes: []),
            .raw(
                count: Int32(bufferSize),
                bytes: [UInt8](repeating: 0x61, count: bufferSize)
            ),
            .raw(count: 4, bytes: [0x2f, 0x61, 0x62, 0x63, 0x78]),
            .raw(count: 4, bytes: [0x2f, 0x61, 0x00, 0x62, 0x00]),
            .raw(count: 3, bytes: [0x2f, 0xff, 0x61, 0x00]),
        ]

        for reply in replies {
            let system = ScriptedCurrentExecutablePathSystem(
                processIdentifier: 43,
                replies: [reply]
            )
            #expect(
                throws: VoicePerformanceCurrentExecutablePathError
                    .unavailable
            ) {
                try VoicePerformanceCurrentExecutablePath.resolve(
                    system: system
                )
            }
        }
    }
}

private final class ScriptedCurrentExecutablePathSystem:
    VoicePerformanceCurrentExecutablePathSystem
{
    struct Reply {
        let count: Int32
        let error: Int32
        let bytes: [CChar]

        static func failure(error: Int32) -> Self {
            Self(count: -1, error: error, bytes: [])
        }

        static func path(_ value: String) -> Self {
            let bytes = value.utf8.map(CChar.init(bitPattern:)) + [0]
            return Self(
                count: Int32(bytes.count - 1),
                error: 0,
                bytes: bytes
            )
        }

        static func raw(
            count: Int32,
            error: Int32 = 0,
            bytes: [UInt8]
        ) -> Self {
            Self(
                count: count,
                error: error,
                bytes: bytes.map(CChar.init(bitPattern:))
            )
        }
    }

    let currentProcessIdentifier: pid_t
    private(set) var lastError: Int32 = 0
    private(set) var queriedProcessIdentifiers: [pid_t] = []
    private var replies: [Reply]

    init(processIdentifier: pid_t, replies: [Reply]) {
        currentProcessIdentifier = processIdentifier
        self.replies = replies
    }

    func query(
        pid: pid_t,
        buffer: UnsafeMutablePointer<CChar>,
        size: UInt32
    ) -> Int32 {
        queriedProcessIdentifiers.append(pid)
        guard !replies.isEmpty else { return -1 }
        let reply = replies.removeFirst()
        lastError = reply.error
        if !reply.bytes.isEmpty {
            let count = min(reply.bytes.count, Int(size))
            buffer.update(from: reply.bytes, count: count)
        }
        return reply.count
    }
}
