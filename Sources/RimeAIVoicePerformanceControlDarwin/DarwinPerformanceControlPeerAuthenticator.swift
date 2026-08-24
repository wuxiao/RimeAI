import CryptoKit
import Darwin
import Foundation
import RimeAIVoicePerformanceControlCore
import Security

public enum PerformanceControlPeerAuthenticationError:
    Error,
    Equatable,
    Sendable
{
    case invalidExpectedPeerIdentity
    case authenticationFailed
}

private func isCanonicalPerformanceControlExecutablePath(
    _ value: String
) -> Bool {
    guard value.utf8.count > 1,
          value.utf8.count < Int(MAXPATHLEN),
          value.first == "/",
          value.last != "/",
          value.utf8.elementsEqual(
              value.precomposedStringWithCanonicalMapping.utf8
          ),
          !value.unicodeScalars.contains(where: {
              $0.value < 0x20 || $0.value == 0x7F
          })
    else {
        return false
    }
    let components = value.dropFirst().split(
        separator: "/",
        omittingEmptySubsequences: false
    )
    return !components.isEmpty
        && components.allSatisfy {
            !$0.isEmpty
                && $0 != "."
                && $0 != ".."
                && $0.utf8.count <= Int(NAME_MAX)
        }
}

private func performanceControlPathsMatchExactly(
    _ left: String,
    _ right: String
) -> Bool {
    left.utf8.elementsEqual(right.utf8)
}

/// Exact peer identity supplied by the sealed tracer policy.
///
/// This value is an input to tracer attestation, not a production trust
/// authority. In particular, it cannot make
/// `authenticatedProductionDriver` true.
public struct PerformanceControlExpectedPeerIdentity: Equatable, Sendable {
    public let expectedExecutablePath: String
    public let expectedExecutableSHA256: String
    public let expectedSigningIdentifier: String
    public let expectedTeamIdentifier: String
    public let expectedCDHash: String

    public init(
        expectedExecutablePath: String,
        expectedExecutableSHA256: String,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String,
        expectedCDHash: String
    ) throws {
        guard isCanonicalPerformanceControlExecutablePath(
                  expectedExecutablePath
              ),
              (try? PerformanceControlSHA256(
                  expectedExecutableSHA256
              )) != nil,
              Self.isSigningIdentifier(expectedSigningIdentifier),
              Self.isTeamIdentifier(expectedTeamIdentifier),
              Self.isLowercaseHex(expectedCDHash, byteCount: 20)
        else {
            throw PerformanceControlPeerAuthenticationError
                .invalidExpectedPeerIdentity
        }
        self.expectedExecutablePath = expectedExecutablePath
        self.expectedExecutableSHA256 = expectedExecutableSHA256
        self.expectedSigningIdentifier = expectedSigningIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.expectedCDHash = expectedCDHash
    }

    private static func isSigningIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 255,
              let first = value.utf8.first,
              isASCIIAlphaNumeric(first)
        else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { byte in
            isASCIIAlphaNumeric(byte) || byte == 0x2D || byte == 0x2E
        }
    }

    private static func isTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte)
                || (0x41 ... 0x5A).contains(byte)
        }
    }

    private static func isLowercaseHex(
        _ value: String,
        byteCount: Int
    ) -> Bool {
        value.utf8.count == byteCount * 2 && value.utf8.allSatisfy { byte in
            (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte)
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x5A).contains(byte)
            || (0x61 ... 0x7A).contains(byte)
    }
}

public struct PerformanceControlAttestedPeer: Equatable, Sendable {
    public let pid: pid_t
    public let euid: uid_t
    public let startToken: UInt64
    public let pidVersion: Int32
    public let instanceID: String

    /// Tracer peer attestation cannot upgrade measurement evidence to
    /// production-driver evidence.
    public let authenticatedProductionDriver = false
}

struct DarwinPerformanceControlRUsageV6: Equatable {
    let pid: pid_t
    let startToken: UInt64
    let exitToken: UInt64
    let userCPUNanoseconds: UInt64
    let systemCPUNanoseconds: UInt64
    let energyNanojoules: UInt64
}

struct DarwinPerformanceControlSocketCredentials: Equatable {
    let pid: pid_t
    let euid: uid_t
}

struct DarwinPerformanceControlAuditTokenIdentity: Equatable {
    let data: Data
    let pid: pid_t
    let euid: uid_t
    let pidVersion: Int32
}

struct DarwinPerformanceControlCodeIdentity: Equatable {
    // Stable Darwin code-signing ABI value from kern/cs_blobs.h.
    static let hardenedRuntimeFlag: UInt32 = 0x0001_0000

    let executablePath: String
    let signingIdentifier: String
    let teamIdentifier: String
    let cdHash: String
    let codeDirectoryFlags: UInt32
}

struct DarwinPerformanceControlExecutableFileIdentity: Equatable {
    let sha256: String
    let ownerEUID: uid_t
    let mode: mode_t
}

protocol DarwinPerformanceControlPeerAuthenticatingSystem {
    var effectiveUserID: uid_t { get }

    func initialRUsage(connectedSocket: Int32) throws
        -> DarwinPerformanceControlRUsageV6
    func socketCredentials(connectedSocket: Int32) throws
        -> DarwinPerformanceControlSocketCredentials
    func peerAuditToken(connectedSocket: Int32) throws
        -> DarwinPerformanceControlAuditTokenIdentity
    func executablePath(auditToken: Data) throws -> String
    func codeIdentity(
        auditToken: Data,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> DarwinPerformanceControlCodeIdentity
    func executableFileIdentity(
        at path: String,
        expectedOwnerEUID: uid_t
    ) throws -> DarwinPerformanceControlExecutableFileIdentity
    func finalRUsage(pid: pid_t) throws
        -> DarwinPerformanceControlRUsageV6
}

protocol DarwinPerformanceControlCancellableExecutableIdentitySystem {
    func executableFileIdentity(
        at path: String,
        expectedOwnerEUID: uid_t,
        gate: DarwinPerformanceControlAuthenticationGate
    ) throws -> DarwinPerformanceControlExecutableFileIdentity
}

public struct DarwinPerformanceControlPeerAuthenticator {
    private let system: any DarwinPerformanceControlPeerAuthenticatingSystem

    public init() {
        system = MacOSDarwinPerformanceControlPeerSystem()
    }

    init(system: any DarwinPerformanceControlPeerAuthenticatingSystem) {
        self.system = system
    }

    public func authenticate(
        connectedSocket: Int32,
        expected: PerformanceControlExpectedPeerIdentity
    ) throws -> PerformanceControlAttestedPeer {
        try authenticate(
            connectedSocket: connectedSocket,
            expected: expected,
            gate: .unbounded
        )
    }

    func authenticate(
        connectedSocket: Int32,
        expected: PerformanceControlExpectedPeerIdentity,
        gate: DarwinPerformanceControlAuthenticationGate
    ) throws -> PerformanceControlAttestedPeer {
        do {
            try gate.check()
            guard connectedSocket >= 0 else {
                throw PerformanceControlPeerAuthenticationError
                    .authenticationFailed
            }
            let first = try system.initialRUsage(
                connectedSocket: connectedSocket
            )
            try gate.check()
            guard Self.isLive(first) else {
                throw PerformanceControlPeerAuthenticationError
                    .authenticationFailed
            }

            let credentials = try system.socketCredentials(
                connectedSocket: connectedSocket
            )
            try gate.check()
            let token = try system.peerAuditToken(
                connectedSocket: connectedSocket
            )
            try gate.check()
            guard first.pid > 0,
                  first.pid == credentials.pid,
                  credentials.pid == token.pid,
                  credentials.euid == token.euid,
                  credentials.euid == system.effectiveUserID,
                  token.pidVersion > 0,
                  token.data.count == MemoryLayout<audit_token_t>.size
            else {
                throw PerformanceControlPeerAuthenticationError
                    .authenticationFailed
            }

            let executablePath = try system.executablePath(
                auditToken: token.data
            )
            try gate.check()
            guard performanceControlPathsMatchExactly(
                      executablePath,
                      expected.expectedExecutablePath
                  )
            else {
                throw PerformanceControlPeerAuthenticationError
                    .authenticationFailed
            }

            let codeIdentity = try system.codeIdentity(
                auditToken: token.data,
                expectedSigningIdentifier:
                    expected.expectedSigningIdentifier,
                expectedTeamIdentifier: expected.expectedTeamIdentifier
            )
            try gate.check()
            guard performanceControlPathsMatchExactly(
                      codeIdentity.executablePath,
                      executablePath
                  ),
                  codeIdentity.signingIdentifier
                    == expected.expectedSigningIdentifier,
                  codeIdentity.teamIdentifier
                    == expected.expectedTeamIdentifier,
                  codeIdentity.cdHash == expected.expectedCDHash,
                  codeIdentity.codeDirectoryFlags
                    & DarwinPerformanceControlCodeIdentity
                        .hardenedRuntimeFlag != 0
            else {
                throw PerformanceControlPeerAuthenticationError
                    .authenticationFailed
            }

            let fileIdentity: DarwinPerformanceControlExecutableFileIdentity
            if let cancellable = system as?
                any DarwinPerformanceControlCancellableExecutableIdentitySystem
            {
                fileIdentity = try cancellable.executableFileIdentity(
                    at: executablePath,
                    expectedOwnerEUID: credentials.euid,
                    gate: gate
                )
            } else {
                try gate.check()
                fileIdentity = try system.executableFileIdentity(
                    at: executablePath,
                    expectedOwnerEUID: credentials.euid
                )
                try gate.check()
            }
            guard fileIdentity.sha256 == expected.expectedExecutableSHA256,
                  fileIdentity.ownerEUID == 0
                    || fileIdentity.ownerEUID == credentials.euid,
                  fileIdentity.mode & S_IFMT == S_IFREG,
                  fileIdentity.mode & (S_ISUID | S_ISGID) == 0,
                  fileIdentity.mode & (S_IWGRP | S_IWOTH) == 0
            else {
                throw PerformanceControlPeerAuthenticationError
                    .authenticationFailed
            }

            let second = try system.finalRUsage(pid: credentials.pid)
            try gate.check()
            guard Self.isLive(second),
                  second.pid == credentials.pid,
                  second.startToken == first.startToken,
                  second.userCPUNanoseconds >= first.userCPUNanoseconds,
                  second.systemCPUNanoseconds >= first.systemCPUNanoseconds,
                  second.energyNanojoules >= first.energyNanojoules
            else {
                throw PerformanceControlPeerAuthenticationError
                    .authenticationFailed
            }

            return PerformanceControlAttestedPeer(
                pid: credentials.pid,
                euid: credentials.euid,
                startToken: second.startToken,
                pidVersion: token.pidVersion,
                instanceID: Self.instanceID(
                    token: token,
                    startToken: second.startToken,
                    expected: expected
                )
            )
        } catch let error as PerformanceControlTransportError {
            throw error
        } catch {
            // Do not expose caller-controlled identity or filesystem input in
            // authentication errors.
            throw PerformanceControlPeerAuthenticationError
                .authenticationFailed
        }
    }

    private static func isLive(
        _ usage: DarwinPerformanceControlRUsageV6
    ) -> Bool {
        usage.pid > 0 && usage.startToken > 0 && usage.exitToken == 0
    }

    private static func instanceID(
        token: DarwinPerformanceControlAuditTokenIdentity,
        startToken: UInt64,
        expected: PerformanceControlExpectedPeerIdentity
    ) -> String {
        var hasher = SHA256()
        hasher.update(
            data: Data(
                "rimeai.performance-control.attested-peer-instance.v1\u{0}"
                    .utf8
            )
        )
        hasher.update(data: token.data)
        hasher.update(data: canonicalBytes(UInt32(bitPattern: token.pid)))
        hasher.update(data: canonicalBytes(token.euid))
        hasher.update(
            data: canonicalBytes(UInt32(bitPattern: token.pidVersion))
        )
        hasher.update(data: canonicalBytes(startToken))
        hasher.update(data: Data(expected.expectedExecutableSHA256.utf8))
        hasher.update(data: Data(expected.expectedCDHash.utf8))
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func canonicalBytes<T: FixedWidthInteger>(
        _ value: T
    ) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}

private enum DarwinPerformanceControlSystemError: Error {
    case failed
}

struct MacOSDarwinPerformanceControlPeerSystem:
    DarwinPerformanceControlPeerAuthenticatingSystem,
    DarwinPerformanceControlCancellableExecutableIdentitySystem
{
    private static let maximumExecutableBytes: off_t = 512 * 1_024 * 1_024

    var effectiveUserID: uid_t { geteuid() }

    func initialRUsage(connectedSocket: Int32) throws
        -> DarwinPerformanceControlRUsageV6
    {
        try validateConnectedUnixStream(connectedSocket)
        return try rusageV6(pid: peerPID(connectedSocket))
    }

    func socketCredentials(connectedSocket: Int32) throws
        -> DarwinPerformanceControlSocketCredentials
    {
        try validateConnectedUnixStream(connectedSocket)
        var peerEUID = uid_t.max
        var peerEGID = gid_t.max
        let status = retryOnEINTR {
            getpeereid(connectedSocket, &peerEUID, &peerEGID)
        }
        guard status == 0 else {
            throw DarwinPerformanceControlSystemError.failed
        }
        return DarwinPerformanceControlSocketCredentials(
            pid: try peerPID(connectedSocket),
            euid: peerEUID
        )
    }

    func peerAuditToken(connectedSocket: Int32) throws
        -> DarwinPerformanceControlAuditTokenIdentity
    {
        try validateConnectedUnixStream(connectedSocket)
        var token = audit_token_t()
        var byteCount = socklen_t(MemoryLayout<audit_token_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            retryOnEINTR {
                getsockopt(
                    connectedSocket,
                    SOL_LOCAL,
                    LOCAL_PEERTOKEN,
                    pointer,
                    &byteCount
                )
            }
        }
        guard status == 0,
              byteCount == MemoryLayout<audit_token_t>.size
        else {
            throw DarwinPerformanceControlSystemError.failed
        }
        return DarwinPerformanceControlAuditTokenIdentity(
            data: withUnsafeBytes(of: &token) { Data($0) },
            pid: audit_token_to_pid(token),
            euid: audit_token_to_euid(token),
            pidVersion: audit_token_to_pidversion(token)
        )
    }

    func executablePath(auditToken: Data) throws -> String {
        var token = try decodedAuditToken(auditToken)
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var copied: Int32 = -1
        repeat {
            copied = buffer.withUnsafeMutableBufferPointer { bytes in
                proc_pidpath_audittoken(
                    &token,
                    bytes.baseAddress,
                    UInt32(bytes.count)
                )
            }
        } while copied < 0 && errno == EINTR
        let count = Int(copied)
        guard count > 1,
              count < buffer.count,
              buffer[count] == 0,
              !buffer[..<count].contains(0),
              let path = String(
                  bytes: buffer[..<count].map(UInt8.init(bitPattern:)),
                  encoding: .utf8
              ),
              isCanonicalPerformanceControlExecutablePath(path)
        else {
            throw DarwinPerformanceControlSystemError.failed
        }
        return path
    }

    func codeIdentity(
        auditToken: Data,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String
    ) throws -> DarwinPerformanceControlCodeIdentity {
        let code = try dynamicCode(auditToken: auditToken)
        let requirementText = "anchor apple generic"
            + " and identifier \"\(expectedSigningIdentifier)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(
                  code,
                  SecCSFlags(rawValue: kSecCSStrictValidate),
                  requirement
              ) == errSecSuccess
        else {
            throw DarwinPerformanceControlSystemError.failed
        }

        // Signing-information APIs accept a dynamic SecCode, although the
        // imported Swift signature exposes the nominal SecStaticCode type.
        let signingCode = unsafeBitCast(code, to: SecStaticCode.self)
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            signingCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let information = signingInformation as? [CFString: Any],
              let signingIdentifier = information[
                  kSecCodeInfoIdentifier
              ] as? String,
              let teamIdentifier = information[
                  kSecCodeInfoTeamIdentifier
              ] as? String,
              let cdHashData = information[kSecCodeInfoUnique] as? Data,
              cdHashData.count == 20,
              let codeDirectoryFlags = information[
                  kSecCodeInfoFlags
              ] as? NSNumber,
              let mainExecutable = information[
                  kSecCodeInfoMainExecutable
              ] as? URL,
              isCanonicalPerformanceControlExecutablePath(
                  mainExecutable.path
              )
        else {
            throw DarwinPerformanceControlSystemError.failed
        }
        return DarwinPerformanceControlCodeIdentity(
            executablePath: mainExecutable.path,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            cdHash: cdHashData.map { String(format: "%02x", $0) }.joined(),
            codeDirectoryFlags: codeDirectoryFlags.uint32Value
        )
    }

    func executableFileIdentity(
        at path: String,
        expectedOwnerEUID: uid_t
    ) throws -> DarwinPerformanceControlExecutableFileIdentity {
        try executableFileIdentity(
            at: path,
            expectedOwnerEUID: expectedOwnerEUID,
            gate: .unbounded
        )
    }

    func executableFileIdentity(
        at path: String,
        expectedOwnerEUID: uid_t,
        gate: DarwinPerformanceControlAuthenticationGate
    ) throws -> DarwinPerformanceControlExecutableFileIdentity {
        try gate.check()
        var descriptor: Int32 = -1
        repeat {
            descriptor = Darwin.open(
                path,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        } while descriptor < 0 && errno == EINTR
        guard descriptor >= 0 else {
            throw DarwinPerformanceControlSystemError.failed
        }
        // POSIX close must not be retried after EINTR: the descriptor may
        // already have been released and reused by another thread.
        defer { _ = Darwin.close(descriptor) }

        try gate.check()
        let before = try stableStat(descriptor)
        guard before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0,
              before.st_size <= Self.maximumExecutableBytes,
              before.st_uid == 0 || before.st_uid == expectedOwnerEUID,
              before.st_mode & (S_ISUID | S_ISGID) == 0,
              before.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            throw DarwinPerformanceControlSystemError.failed
        }

        var hasher = SHA256()
        var totalBytes: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try gate.check()
            var copied: Int = -1
            repeat {
                copied = buffer.withUnsafeMutableBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else {
                        return -1
                    }
                    return Darwin.read(
                        descriptor,
                        baseAddress,
                        bytes.count
                    )
                }
            } while copied < 0 && errno == EINTR
            guard copied >= 0 else {
                throw DarwinPerformanceControlSystemError.failed
            }
            if copied == 0 { break }
            totalBytes += off_t(copied)
            guard totalBytes <= before.st_size else {
                throw DarwinPerformanceControlSystemError.failed
            }
            hasher.update(data: Data(buffer[..<copied]))
        }

        try gate.check()
        let after = try stableStat(descriptor)
        guard totalBytes == before.st_size,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_uid == after.st_uid,
              before.st_mode == after.st_mode,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else {
            throw DarwinPerformanceControlSystemError.failed
        }
        try gate.check()
        return DarwinPerformanceControlExecutableFileIdentity(
            sha256: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined(),
            ownerEUID: after.st_uid,
            mode: after.st_mode
        )
    }

    func finalRUsage(pid: pid_t) throws
        -> DarwinPerformanceControlRUsageV6
    {
        try rusageV6(pid: pid)
    }

    private func validateConnectedUnixStream(_ descriptor: Int32) throws {
        guard descriptor >= 0 else {
            throw DarwinPerformanceControlSystemError.failed
        }
        var socketType: Int32 = 0
        var socketTypeBytes = socklen_t(MemoryLayout<Int32>.size)
        let typeStatus = withUnsafeMutablePointer(to: &socketType) { pointer in
            retryOnEINTR {
                getsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_TYPE,
                    pointer,
                    &socketTypeBytes
                )
            }
        }
        guard typeStatus == 0,
              socketTypeBytes == MemoryLayout<Int32>.size,
              socketType == SOCK_STREAM
        else {
            throw DarwinPerformanceControlSystemError.failed
        }

        var localAddress = sockaddr_storage()
        var localAddressBytes = socklen_t(MemoryLayout.size(ofValue: localAddress))
        let localStatus = withUnsafeMutablePointer(to: &localAddress) {
            pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                address in
                retryOnEINTR {
                    getsockname(descriptor, address, &localAddressBytes)
                }
            }
        }
        guard localStatus == 0,
              localAddressBytes >= MemoryLayout<sockaddr>.size,
              localAddress.ss_family == sa_family_t(AF_UNIX)
        else {
            throw DarwinPerformanceControlSystemError.failed
        }

        var peerAddress = sockaddr_storage()
        var peerAddressBytes = socklen_t(MemoryLayout.size(ofValue: peerAddress))
        let peerStatus = withUnsafeMutablePointer(to: &peerAddress) {
            pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                address in
                retryOnEINTR {
                    getpeername(descriptor, address, &peerAddressBytes)
                }
            }
        }
        guard peerStatus == 0,
              peerAddressBytes >= MemoryLayout<sockaddr>.size,
              peerAddress.ss_family == sa_family_t(AF_UNIX)
        else {
            throw DarwinPerformanceControlSystemError.failed
        }
    }

    private func peerPID(_ descriptor: Int32) throws -> pid_t {
        var pid = pid_t(-1)
        var byteCount = socklen_t(MemoryLayout<pid_t>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pointer in
            retryOnEINTR {
                getsockopt(
                    descriptor,
                    SOL_LOCAL,
                    LOCAL_PEERPID,
                    pointer,
                    &byteCount
                )
            }
        }
        guard status == 0,
              byteCount == MemoryLayout<pid_t>.size,
              pid > 0
        else {
            throw DarwinPerformanceControlSystemError.failed
        }
        return pid
    }

    private func rusageV6(pid: pid_t) throws
        -> DarwinPerformanceControlRUsageV6
    {
        var usage = rusage_info_v6()
        var status: Int32 = -1
        repeat {
            status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(
                    to: rusage_info_t?.self,
                    capacity: 1
                ) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
        } while status != 0 && errno == EINTR
        guard status == 0 else {
            throw DarwinPerformanceControlSystemError.failed
        }
        return DarwinPerformanceControlRUsageV6(
            pid: pid,
            startToken: usage.ri_proc_start_abstime,
            exitToken: usage.ri_proc_exit_abstime,
            userCPUNanoseconds: usage.ri_user_time,
            systemCPUNanoseconds: usage.ri_system_time,
            energyNanojoules: usage.ri_energy_nj
        )
    }

    private func dynamicCode(auditToken: Data) throws -> SecCode {
        _ = try decodedAuditToken(auditToken)
        let attributes = [
            kSecGuestAttributeAudit as String: auditToken as NSData,
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &code
        ) == errSecSuccess,
              let code
        else {
            throw DarwinPerformanceControlSystemError.failed
        }
        return code
    }

    private func decodedAuditToken(_ data: Data) throws -> audit_token_t {
        guard data.count == MemoryLayout<audit_token_t>.size else {
            throw DarwinPerformanceControlSystemError.failed
        }
        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token) { bytes in
            _ = data.copyBytes(to: bytes)
        }
        return token
    }

    private func stableStat(_ descriptor: Int32) throws -> stat {
        var value = stat()
        var status: Int32 = -1
        repeat {
            status = fstat(descriptor, &value)
        } while status != 0 && errno == EINTR
        guard status == 0 else {
            throw DarwinPerformanceControlSystemError.failed
        }
        return value
    }

    private func retryOnEINTR(_ operation: () -> Int32) -> Int32 {
        var status: Int32
        repeat {
            status = operation()
        } while status != 0 && errno == EINTR
        return status
    }

}
