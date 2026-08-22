import Darwin
import Foundation
import Testing
@testable import RimeAIVoicePerformanceControlDarwin

@Suite("Darwin performance-control peer attestation")
struct DarwinPerformanceControlPeerAuthenticatorTests {
    @Test("expected peer identity preserves an exact canonical identity")
    func expectedPeerIdentityPreservesExactCanonicalIdentity() throws {
        let identity = try PerformanceControlExpectedPeerIdentity(
            expectedExecutablePath:
                "/Applications/RimeAI.app/Contents/MacOS/performance-driver",
            expectedExecutableSHA256: String(repeating: "a", count: 64),
            expectedSigningIdentifier:
                "fun.wwcn.rimeai.voice-performance-driver",
            expectedTeamIdentifier: "A1B2C3D4E5",
            expectedCDHash: String(repeating: "b", count: 40)
        )

        #expect(
            identity.expectedExecutablePath
                == "/Applications/RimeAI.app/Contents/MacOS/performance-driver"
        )
        #expect(
            identity.expectedExecutableSHA256
                == String(repeating: "a", count: 64)
        )
        #expect(
            identity.expectedSigningIdentifier
                == "fun.wwcn.rimeai.voice-performance-driver"
        )
        #expect(identity.expectedTeamIdentifier == "A1B2C3D4E5")
        #expect(identity.expectedCDHash == String(repeating: "b", count: 40))
    }

    @Test("expected identity rejects noncanonical or injectable fields")
    func expectedIdentityRejectsNoncanonicalOrInjectableFields() {
        let validPath =
            "/Applications/RimeAI.app/Contents/MacOS/performance-driver"
        let validSHA256 = String(repeating: "a", count: 64)
        let validSigningID = "fun.wwcn.rimeai.voice-performance-driver"
        let validTeamID = "A1B2C3D4E5"
        let validCDHash = String(repeating: "b", count: 40)
        let invalidCases: [(String, String, String, String, String)] = [
            ("relative/driver", validSHA256, validSigningID, validTeamID, validCDHash),
            ("/Applications/../tmp/driver", validSHA256, validSigningID, validTeamID, validCDHash),
            ("/tmp/e\u{301}", validSHA256, validSigningID, validTeamID, validCDHash),
            ("/tmp/driver\nname", validSHA256, validSigningID, validTeamID, validCDHash),
            ("/tmp/driver\u{7f}name", validSHA256, validSigningID, validTeamID, validCDHash),
            (validPath, String(repeating: "A", count: 64), validSigningID, validTeamID, validCDHash),
            (validPath, validSHA256, "fun.wwcn.bad_identifier", validTeamID, validCDHash),
            (validPath, validSHA256, validSigningID, "a1b2c3d4e5", validCDHash),
            (validPath, validSHA256, validSigningID, validTeamID, String(repeating: "B", count: 40)),
        ]

        for (path, sha256, signingID, teamID, cdHash) in invalidCases {
            #expect(
                throws: PerformanceControlPeerAuthenticationError
                    .invalidExpectedPeerIdentity
            ) {
                try PerformanceControlExpectedPeerIdentity(
                    expectedExecutablePath: path,
                    expectedExecutableSHA256: sha256,
                    expectedSigningIdentifier: signingID,
                    expectedTeamIdentifier: teamID,
                    expectedCDHash: cdHash
                )
            }
        }
    }

    @Test("attestation binds one live peer instance in fail-closed order")
    func attestationBindsOneLivePeerInstanceInFailClosedOrder() throws {
        let system = FakeDarwinPerformanceControlPeerSystem()
        let peer = try DarwinPerformanceControlPeerAuthenticator(
            system: system
        ).authenticate(
            connectedSocket: 42,
            expected: try expectedPeerIdentity()
        )

        #expect(peer.pid == 7_321)
        #expect(peer.euid == 501)
        #expect(peer.startToken == 12_345)
        #expect(peer.pidVersion == 9)
        #expect(peer.instanceID.utf8.count == 64)
        #expect(
            peer.instanceID.utf8.allSatisfy {
                (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
            }
        )
        #expect(!peer.authenticatedProductionDriver)
        #expect(
            system.calls
                == ["A", "credentials", "token", "path", "signature", "file", "B"]
        )
    }

    @Test("every peer identity or lifetime mismatch fails generically")
    func everyPeerIdentityOrLifetimeMismatchFailsGenerically() throws {
        let cases: [(String, (FakeDarwinPerformanceControlPeerSystem) -> Void)] = [
            ("wrong PID", { $0.credentials = .init(pid: 7_322, euid: 501) }),
            ("cross-source euid", {
                $0.token = auditToken(euid: 502)
            }),
            ("different local user", {
                $0.credentials = .init(pid: 7_321, euid: 502)
                $0.token = auditToken(euid: 502)
            }),
            ("zero pid version", { $0.token = auditToken(pidVersion: 0) }),
            ("truncated token", {
                $0.token = auditToken(data: Data(repeating: 0xAB, count: 31))
            }),
            ("proc path", { $0.path = "/tmp/other-driver" }),
            ("signed main path", {
                $0.signature = makeCodeIdentity(
                    executablePath: "/tmp/other-driver"
                )
            }),
            ("signing identifier", {
                $0.signature = makeCodeIdentity(
                    signingIdentifier: "fun.wwcn.other"
                )
            }),
            ("Team identifier", {
                $0.signature = makeCodeIdentity(
                    teamIdentifier: "Z9Y8X7W6V5"
                )
            }),
            ("CDHash", {
                $0.signature = makeCodeIdentity(
                    cdHash: String(repeating: "c", count: 40)
                )
            }),
            ("missing hardened runtime", {
                $0.signature = makeCodeIdentity(codeDirectoryFlags: 0)
            }),
            ("executable SHA-256", {
                $0.file = executableFile(
                    sha256: String(repeating: "d", count: 64)
                )
            }),
            ("start token", {
                $0.secondUsage = finalUsage(startToken: 12_346)
            }),
            ("first snapshot exited", {
                $0.firstUsage = initialUsage(exitToken: 1)
            }),
            ("second snapshot exited", {
                $0.secondUsage = finalUsage(exitToken: 1)
            }),
            ("user counter rollback", {
                $0.secondUsage = finalUsage(userCPUNanoseconds: 99)
            }),
            ("system counter rollback", {
                $0.secondUsage = finalUsage(systemCPUNanoseconds: 199)
            }),
            ("energy counter rollback", {
                $0.secondUsage = finalUsage(energyNanojoules: 299)
            }),
        ]

        for (_, mutate) in cases {
            let system = FakeDarwinPerformanceControlPeerSystem()
            mutate(system)
            #expect(
                throws: PerformanceControlPeerAuthenticationError
                    .authenticationFailed
            ) {
                try DarwinPerformanceControlPeerAuthenticator(
                    system: system
                ).authenticate(
                    connectedSocket: 42,
                    expected: try expectedPeerIdentity()
                )
            }
        }
    }

    @Test("executable ownership and mode are restricted but root ownership is valid")
    func executableOwnershipAndModeAreRestricted() throws {
        let rootOwned = FakeDarwinPerformanceControlPeerSystem()
        rootOwned.file = executableFile(ownerEUID: 0)
        _ = try DarwinPerformanceControlPeerAuthenticator(
            system: rootOwned
        ).authenticate(
            connectedSocket: 42,
            expected: try expectedPeerIdentity()
        )

        let unsafeFiles: [DarwinPerformanceControlExecutableFileIdentity] = [
            executableFile(ownerEUID: 502),
            executableFile(mode: S_IFREG | S_ISUID | 0o755),
            executableFile(mode: S_IFREG | S_ISGID | 0o755),
            executableFile(mode: S_IFREG | 0o775),
            executableFile(mode: S_IFREG | 0o757),
            executableFile(mode: S_IFDIR | 0o755),
        ]
        for file in unsafeFiles {
            let system = FakeDarwinPerformanceControlPeerSystem()
            system.file = file
            #expect(
                throws: PerformanceControlPeerAuthenticationError
                    .authenticationFailed
            ) {
                try DarwinPerformanceControlPeerAuthenticator(
                    system: system
                ).authenticate(
                    connectedSocket: 42,
                    expected: try expectedPeerIdentity()
                )
            }
        }
    }

    @Test("instance ID is stable, domain separated, and audit-token bound")
    func instanceIDIsStableDomainSeparatedAndAuditTokenBound() throws {
        let firstSystem = FakeDarwinPerformanceControlPeerSystem()
        let secondSystem = FakeDarwinPerformanceControlPeerSystem()
        let changedSystem = FakeDarwinPerformanceControlPeerSystem()
        changedSystem.token = auditToken(
            data: Data(repeating: 0xAC, count: 32)
        )
        let authenticatorA = DarwinPerformanceControlPeerAuthenticator(
            system: firstSystem
        )
        let authenticatorB = DarwinPerformanceControlPeerAuthenticator(
            system: secondSystem
        )
        let authenticatorChanged = DarwinPerformanceControlPeerAuthenticator(
            system: changedSystem
        )

        let first = try authenticatorA.authenticate(
            connectedSocket: 42,
            expected: try expectedPeerIdentity()
        ).instanceID
        let second = try authenticatorB.authenticate(
            connectedSocket: 42,
            expected: try expectedPeerIdentity()
        ).instanceID
        let changed = try authenticatorChanged.authenticate(
            connectedSocket: 42,
            expected: try expectedPeerIdentity()
        ).instanceID

        #expect(first == second)
        #expect(first != changed)
        #expect(first != String(repeating: "ab", count: 32))
        #expect(changed != String(repeating: "ac", count: 32))
    }

    @Test("real connected Unix stream credentials agree with its audit token")
    func realConnectedUnixStreamCredentialsAgreeWithAuditToken() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        guard sockets.allSatisfy({ $0 >= 0 }) else { return }
        defer {
            _ = Darwin.close(sockets[0])
            _ = Darwin.close(sockets[1])
        }

        let system = MacOSDarwinPerformanceControlPeerSystem()
        let first = try system.initialRUsage(connectedSocket: sockets[0])
        let credentials = try system.socketCredentials(
            connectedSocket: sockets[0]
        )
        let token = try system.peerAuditToken(connectedSocket: sockets[0])
        let executablePath = try system.executablePath(
            auditToken: token.data
        )
        let executableFile = try system.executableFileIdentity(
            at: executablePath,
            expectedOwnerEUID: geteuid()
        )

        #expect(first.pid == getpid())
        #expect(first.startToken > 0)
        #expect(first.exitToken == 0)
        #expect(credentials.pid == getpid())
        #expect(credentials.euid == geteuid())
        #expect(token.pid == getpid())
        #expect(token.euid == geteuid())
        #expect(token.pidVersion > 0)
        #expect(token.data.count == MemoryLayout<audit_token_t>.size)
        #expect(executablePath.hasPrefix("/"))
        #expect(executableFile.sha256.utf8.count == 64)
        #expect(
            executableFile.sha256.utf8.allSatisfy {
                (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
            }
        )
        #expect(executableFile.ownerEUID == 0 || executableFile.ownerEUID == geteuid())

        var rawToken = audit_token_t()
        withUnsafeMutableBytes(of: &rawToken) { bytes in
            _ = token.data.copyBytes(to: bytes)
        }
        #expect(token.pidVersion == audit_token_to_pidversion(rawToken))
    }

    @Test("non-stream, non-Unix, and unconnected descriptors fail closed")
    func invalidConnectedSocketKindsFailClosed() throws {
        var datagrams = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_DGRAM, 0, &datagrams) == 0)
        defer {
            if datagrams[0] >= 0 { _ = Darwin.close(datagrams[0]) }
            if datagrams[1] >= 0 { _ = Darwin.close(datagrams[1]) }
        }

        var pipes = [Int32](repeating: -1, count: 2)
        #expect(Darwin.pipe(&pipes) == 0)
        defer {
            if pipes[0] >= 0 { _ = Darwin.close(pipes[0]) }
            if pipes[1] >= 0 { _ = Darwin.close(pipes[1]) }
        }

        let unconnected = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(unconnected >= 0)
        defer {
            if unconnected >= 0 { _ = Darwin.close(unconnected) }
        }

        let authenticator = DarwinPerformanceControlPeerAuthenticator()
        for descriptor in [datagrams[0], pipes[0], unconnected, -1] {
            #expect(
                throws: PerformanceControlPeerAuthenticationError
                    .authenticationFailed
            ) {
                try authenticator.authenticate(
                    connectedSocket: descriptor,
                    expected: try expectedPeerIdentity()
                )
            }
        }
    }
}

private func expectedPeerIdentity()
    throws -> PerformanceControlExpectedPeerIdentity
{
    try PerformanceControlExpectedPeerIdentity(
        expectedExecutablePath:
            "/Applications/RimeAI.app/Contents/MacOS/performance-driver",
        expectedExecutableSHA256: String(repeating: "a", count: 64),
        expectedSigningIdentifier:
            "fun.wwcn.rimeai.voice-performance-driver",
        expectedTeamIdentifier: "A1B2C3D4E5",
        expectedCDHash: String(repeating: "b", count: 40)
    )
}

private func initialUsage(
    pid: pid_t = 7_321,
    startToken: UInt64 = 12_345,
    exitToken: UInt64 = 0,
    userCPUNanoseconds: UInt64 = 100,
    systemCPUNanoseconds: UInt64 = 200,
    energyNanojoules: UInt64 = 300
) -> DarwinPerformanceControlRUsageV6 {
    DarwinPerformanceControlRUsageV6(
        pid: pid,
        startToken: startToken,
        exitToken: exitToken,
        userCPUNanoseconds: userCPUNanoseconds,
        systemCPUNanoseconds: systemCPUNanoseconds,
        energyNanojoules: energyNanojoules
    )
}

private func finalUsage(
    pid: pid_t = 7_321,
    startToken: UInt64 = 12_345,
    exitToken: UInt64 = 0,
    userCPUNanoseconds: UInt64 = 101,
    systemCPUNanoseconds: UInt64 = 201,
    energyNanojoules: UInt64 = 301
) -> DarwinPerformanceControlRUsageV6 {
    DarwinPerformanceControlRUsageV6(
        pid: pid,
        startToken: startToken,
        exitToken: exitToken,
        userCPUNanoseconds: userCPUNanoseconds,
        systemCPUNanoseconds: systemCPUNanoseconds,
        energyNanojoules: energyNanojoules
    )
}

private func auditToken(
    data: Data = Data(repeating: 0xAB, count: 32),
    pid: pid_t = 7_321,
    euid: uid_t = 501,
    pidVersion: Int32 = 9
) -> DarwinPerformanceControlAuditTokenIdentity {
    DarwinPerformanceControlAuditTokenIdentity(
        data: data,
        pid: pid,
        euid: euid,
        pidVersion: pidVersion
    )
}

private func makeCodeIdentity(
    executablePath: String =
        "/Applications/RimeAI.app/Contents/MacOS/performance-driver",
    signingIdentifier: String =
        "fun.wwcn.rimeai.voice-performance-driver",
    teamIdentifier: String = "A1B2C3D4E5",
    cdHash: String = String(repeating: "b", count: 40),
    codeDirectoryFlags: UInt32 = 0x0001_0000
) -> DarwinPerformanceControlCodeIdentity {
    DarwinPerformanceControlCodeIdentity(
        executablePath: executablePath,
        signingIdentifier: signingIdentifier,
        teamIdentifier: teamIdentifier,
        cdHash: cdHash,
        codeDirectoryFlags: codeDirectoryFlags
    )
}

private func executableFile(
    sha256: String = String(repeating: "a", count: 64),
    ownerEUID: uid_t = 501,
    mode: mode_t = S_IFREG | 0o755
) -> DarwinPerformanceControlExecutableFileIdentity {
    DarwinPerformanceControlExecutableFileIdentity(
        sha256: sha256,
        ownerEUID: ownerEUID,
        mode: mode
    )
}

private final class FakeDarwinPerformanceControlPeerSystem:
    DarwinPerformanceControlPeerAuthenticatingSystem
{
    var calls: [String] = []
    var effectiveUserID: uid_t = 501
    var firstUsage = initialUsage()
    var credentials = DarwinPerformanceControlSocketCredentials(
        pid: 7_321,
        euid: 501
    )
    var token = auditToken()
    var path = "/Applications/RimeAI.app/Contents/MacOS/performance-driver"
    var signature = makeCodeIdentity()
    var file = executableFile()
    var secondUsage = finalUsage()

    func initialRUsage(connectedSocket: Int32) throws
        -> DarwinPerformanceControlRUsageV6
    {
        calls.append("A")
        return firstUsage
    }

    func socketCredentials(connectedSocket: Int32) throws
        -> DarwinPerformanceControlSocketCredentials
    {
        calls.append("credentials")
        return credentials
    }

    func peerAuditToken(connectedSocket: Int32) throws
        -> DarwinPerformanceControlAuditTokenIdentity
    {
        calls.append("token")
        return token
    }

    func executablePath(auditToken: Data) throws -> String {
        calls.append("path")
        return path
    }

    func codeIdentity(
        auditToken: Data,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> DarwinPerformanceControlCodeIdentity {
        calls.append("signature")
        return signature
    }

    func executableFileIdentity(
        at path: String,
        expectedOwnerEUID: uid_t
    ) throws -> DarwinPerformanceControlExecutableFileIdentity {
        calls.append("file")
        return file
    }

    func finalRUsage(pid: pid_t) throws
        -> DarwinPerformanceControlRUsageV6
    {
        calls.append("B")
        return secondUsage
    }
}
