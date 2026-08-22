import CryptoKit
import Darwin
import Foundation
import IOKit.ps
import Security

enum DarwinVoicePerformanceCodeSigningRequirement {
    static func make(
        signingIdentifier: String,
        teamIdentifier: String
    ) throws -> String {
        guard isValidSigningIdentifier(signingIdentifier),
              isValidTeamIdentifier(teamIdentifier)
        else {
            throw VoicePerformanceCollectorError.invalidProcessIdentity
        }
        return "anchor apple generic"
            + " and identifier \"\(signingIdentifier)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    private static func isValidSigningIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255 else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D
                || byte == 0x2E
        }
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
        }
    }
}

struct DarwinVoicePerformanceRUsageV6: Equatable, Sendable {
    let processStartAbsoluteTime: UInt64
    let processExitAbsoluteTime: UInt64
    let userCPUNanoseconds: UInt64
    let systemCPUNanoseconds: UInt64
    let energyNanojoules: UInt64
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
}

struct DarwinVoicePerformanceProcessIdentity: Equatable, Sendable {
    let effectiveUserID: uid_t
    let executablePath: String
    let signingIdentifier: String
    let teamIdentifier: String
    let cdHash: String
}

protocol DarwinVoicePerformanceSystem: Sendable {
    var effectiveUserID: uid_t { get }

    func collectorExecutableSHA256() throws -> String
    func collectorTeamIdentifier() throws -> String
    func collectorSigningIdentifier() throws -> String
    func validateCollectorDeveloperID(
        signingIdentifier: String,
        teamIdentifier: String
    ) throws
    func validateDeveloperID(
        processIdentifier: pid_t,
        signingIdentifier: String,
        teamIdentifier: String
    ) throws
    func environmentSnapshot() throws -> VoicePerformanceEnvironmentSnapshot
    func continuousTimeNanoseconds() throws -> UInt64
    func rusageV6(processIdentifier: pid_t) throws
        -> DarwinVoicePerformanceRUsageV6
    func processIdentity(processIdentifier: pid_t) throws
        -> DarwinVoicePerformanceProcessIdentity
}

struct MacOSVoicePerformanceSystem: DarwinVoicePerformanceSystem {
    var effectiveUserID: uid_t { geteuid() }

    func collectorExecutableSHA256() throws -> String {
        let processID = getpid()
        let executablePath = try executablePath(
            processIdentifier: processID
        )
        let codeIdentity = try codeSigningIdentity(
            processIdentifier: processID
        )
        guard codeIdentity.executablePath == executablePath else {
            throw VoicePerformanceCollectorError.invalidCollectorIdentity
        }
        return try sha256OfRegularFile(at: executablePath)
    }

    func collectorTeamIdentifier() throws -> String {
        do {
            return try codeSigningIdentity(
                processIdentifier: getpid()
            ).teamIdentifier
        } catch {
            throw VoicePerformanceCollectorError.invalidCollectorIdentity
        }
    }

    func collectorSigningIdentifier() throws -> String {
        do {
            return try codeSigningIdentity(
                processIdentifier: getpid()
            ).signingIdentifier
        } catch {
            throw VoicePerformanceCollectorError.invalidCollectorIdentity
        }
    }

    func validateCollectorDeveloperID(
        signingIdentifier: String,
        teamIdentifier: String
    ) throws {
        do {
            try validateDeveloperIDCode(
                processIdentifier: getpid(),
                signingIdentifier: signingIdentifier,
                teamIdentifier: teamIdentifier
            )
        } catch {
            throw VoicePerformanceCollectorError.invalidCollectorIdentity
        }
    }

    func validateDeveloperID(
        processIdentifier: pid_t,
        signingIdentifier: String,
        teamIdentifier: String
    ) throws {
        do {
            try validateDeveloperIDCode(
                processIdentifier: processIdentifier,
                signingIdentifier: signingIdentifier,
                teamIdentifier: teamIdentifier
            )
        } catch {
            throw VoicePerformanceCollectorError.invalidProcessIdentity
        }
    }

    func environmentSnapshot() throws -> VoicePerformanceEnvironmentSnapshot {
        let processInfo = ProcessInfo.processInfo
        guard let powerSourceReference = IOPSCopyPowerSourcesInfo() else {
            throw VoicePerformanceCollectorError.invalidEnvironment
        }
        let powerSourceInfo = powerSourceReference.takeRetainedValue()
        guard let powerSourceType = IOPSGetProvidingPowerSourceType(
            powerSourceInfo
        ) else {
            throw VoicePerformanceCollectorError.invalidEnvironment
        }
        let powerSourceValue = powerSourceType.takeUnretainedValue() as String
        let powerSource: VoicePerformancePowerSource
        switch powerSourceValue {
        case "AC Power":
            powerSource = .ac
        case "Battery Power":
            powerSource = .battery
        default:
            throw VoicePerformanceCollectorError.invalidEnvironment
        }
        let thermalState: VoicePerformanceThermalState
        switch processInfo.thermalState {
        case .nominal:
            thermalState = .nominal
        case .fair:
            thermalState = .fair
        case .serious:
            thermalState = .serious
        case .critical:
            thermalState = .critical
        @unknown default:
            throw VoicePerformanceCollectorError.invalidEnvironment
        }
        return VoicePerformanceEnvironmentSnapshot(
            hardwareModel: try hardwareModel(),
            physicalMemoryBytes: processInfo.physicalMemory,
            logicalCPUCount: processInfo.processorCount,
            powerSource: powerSource,
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            thermalState: thermalState
        )
    }

    func continuousTimeNanoseconds() throws -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS,
              timebase.numer > 0,
              timebase.denom > 0
        else {
            throw VoicePerformanceCollectorError.samplingFailed
        }
        let ticks = mach_continuous_time()
        let denominator = UInt64(timebase.denom)
        let numerator = UInt64(timebase.numer)
        let whole = (ticks / denominator).multipliedReportingOverflow(
            by: numerator
        )
        let fraction = (ticks % denominator).multipliedReportingOverflow(
            by: numerator
        )
        guard !whole.overflow, !fraction.overflow else {
            throw VoicePerformanceCollectorError.samplingFailed
        }
        let sum = whole.partialValue.addingReportingOverflow(
            fraction.partialValue / denominator
        )
        guard !sum.overflow else {
            throw VoicePerformanceCollectorError.samplingFailed
        }
        return sum.partialValue
    }

    func rusageV6(processIdentifier: pid_t) throws
        -> DarwinVoicePerformanceRUsageV6
    {
        var usage = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) {
                proc_pid_rusage(processIdentifier, RUSAGE_INFO_V6, $0)
            }
        }
        guard status == 0 else {
            throw VoicePerformanceCollectorError.samplingFailed
        }
        return DarwinVoicePerformanceRUsageV6(
            processStartAbsoluteTime: usage.ri_proc_start_abstime,
            processExitAbsoluteTime: usage.ri_proc_exit_abstime,
            userCPUNanoseconds: usage.ri_user_time,
            systemCPUNanoseconds: usage.ri_system_time,
            energyNanojoules: usage.ri_energy_nj,
            residentBytes: usage.ri_resident_size,
            physicalFootprintBytes: usage.ri_phys_footprint
        )
    }

    func processIdentity(processIdentifier: pid_t) throws
        -> DarwinVoicePerformanceProcessIdentity
    {
        do {
            var processInfo = proc_bsdinfo()
            let processInfoSize = MemoryLayout<proc_bsdinfo>.size
            let copied = withUnsafeMutablePointer(to: &processInfo) {
                proc_pidinfo(
                    processIdentifier,
                    PROC_PIDTBSDINFO,
                    0,
                    $0,
                    Int32(processInfoSize)
                )
            }
            guard copied == processInfoSize else {
                throw VoicePerformanceCollectorError.invalidProcessIdentity
            }
            let path = try executablePath(
                processIdentifier: processIdentifier
            )
            let codeIdentity = try codeSigningIdentity(
                processIdentifier: processIdentifier
            )
            guard codeIdentity.executablePath == path else {
                throw VoicePerformanceCollectorError.invalidProcessIdentity
            }
            return DarwinVoicePerformanceProcessIdentity(
                effectiveUserID: processInfo.pbi_uid,
                executablePath: path,
                signingIdentifier: codeIdentity.signingIdentifier,
                teamIdentifier: codeIdentity.teamIdentifier,
                cdHash: codeIdentity.cdHash
            )
        } catch let error as VoicePerformanceCollectorError {
            throw error
        } catch {
            throw VoicePerformanceCollectorError.invalidProcessIdentity
        }
    }

    private func hardwareModel() throws -> String {
        var byteCount = 0
        guard sysctlbyname("hw.model", nil, &byteCount, nil, 0) == 0,
              byteCount > 1,
              byteCount <= 1_024
        else {
            throw VoicePerformanceCollectorError.invalidEnvironment
        }
        var bytes = [CChar](repeating: 0, count: byteCount)
        guard sysctlbyname("hw.model", &bytes, &byteCount, nil, 0) == 0,
              let terminator = bytes.firstIndex(of: 0),
              let model = String(
                  bytes: bytes[..<terminator].map(UInt8.init(bitPattern:)),
                  encoding: .utf8
              ),
              !model.isEmpty
        else {
            throw VoicePerformanceCollectorError.invalidEnvironment
        }
        return model
    }

    private func executablePath(processIdentifier: pid_t) throws -> String {
        var buffer = [CChar](
            repeating: 0,
            count: 4 * Int(MAXPATHLEN)
        )
        let copied = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(
                processIdentifier,
                pointer.baseAddress,
                UInt32(pointer.count)
            )
        }
        let copiedCount = Int(copied)
        guard copiedCount > 1,
              copiedCount < buffer.count,
              buffer[copiedCount] == 0,
              !buffer[..<copiedCount].contains(0),
              let path = String(
                  bytes: buffer[..<copiedCount].map(UInt8.init(bitPattern:)),
                  encoding: .utf8
              ),
              path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path
        else {
            throw VoicePerformanceCollectorError.invalidProcessIdentity
        }
        return path
    }

    private func codeSigningIdentity(
        processIdentifier: pid_t
    ) throws -> MacOSCodeSigningIdentity {
        let code = try dynamicCode(processIdentifier: processIdentifier)
        guard SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess else {
            throw VoicePerformanceCollectorError.invalidProcessIdentity
        }
        // Security documents that signing-information APIs accept a dynamic
        // SecCodeRef directly. Swift's imported signature exposes only the
        // nominal SecStaticCodeRef type even though both are CF references.
        let signingInformationCode = unsafeBitCast(
            code,
            to: SecStaticCode.self
        )
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            signingInformationCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let information = signingInformation as? [CFString: Any],
              let signingIdentifier = information[
                  kSecCodeInfoIdentifier
              ] as? String,
              !signingIdentifier.isEmpty,
              let teamIdentifier = information[
                  kSecCodeInfoTeamIdentifier
              ] as? String,
              !teamIdentifier.isEmpty,
              let unique = information[kSecCodeInfoUnique] as? Data,
              unique.count == 20,
              let mainExecutable = information[
                  kSecCodeInfoMainExecutable
              ] as? URL
        else {
            throw VoicePerformanceCollectorError.invalidProcessIdentity
        }
        return MacOSCodeSigningIdentity(
            executablePath: mainExecutable.path,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            cdHash: unique.map { String(format: "%02x", $0) }.joined()
        )
    }

    private func dynamicCode(processIdentifier: pid_t) throws -> SecCode {
        let attributes = NSDictionary(
            object: NSNumber(value: processIdentifier),
            forKey: NSString(string: kSecGuestAttributePid as String)
        )
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &code
        ) == errSecSuccess,
              let code
        else {
            throw VoicePerformanceCollectorError.invalidProcessIdentity
        }
        return code
    }

    private func validateDeveloperIDCode(
        processIdentifier: pid_t,
        signingIdentifier: String,
        teamIdentifier: String
    ) throws {
        let requirementString = try DarwinVoicePerformanceCodeSigningRequirement
            .make(
                signingIdentifier: signingIdentifier,
                teamIdentifier: teamIdentifier
            )
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementString as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(
                  try dynamicCode(processIdentifier: processIdentifier),
                  SecCSFlags(rawValue: kSecCSStrictValidate),
                  requirement
              ) == errSecSuccess
        else {
            throw VoicePerformanceCollectorError.invalidProcessIdentity
        }
    }

    private func sha256OfRegularFile(at path: String) throws -> String {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw VoicePerformanceCollectorError.invalidCollectorIdentity
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0
        else {
            throw VoicePerformanceCollectorError.invalidCollectorIdentity
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let copied = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.read(
                    descriptor,
                    baseAddress,
                    rawBuffer.count
                )
            }
            if copied < 0, errno == EINTR { continue }
            guard copied >= 0 else {
                throw VoicePerformanceCollectorError.invalidCollectorIdentity
            }
            if copied == 0 { break }
            hasher.update(data: Data(buffer[..<copied]))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else {
            throw VoicePerformanceCollectorError.invalidCollectorIdentity
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct MacOSCodeSigningIdentity {
    let executablePath: String
    let signingIdentifier: String
    let teamIdentifier: String
    let cdHash: String
}

public struct DarwinVoicePerformancePlatform: VoicePerformancePlatform {
    public static let collectorSigningIdentifier =
        "fun.wwcn.rimeai.voice-performance-collector"

    private let system: any DarwinVoicePerformanceSystem

    public init() {
        system = MacOSVoicePerformanceSystem()
    }

    init(system: any DarwinVoicePerformanceSystem) {
        self.system = system
    }

    public func verifyCollectorIdentity(
        expectedSHA256: String,
        expectedTeamIdentifier: String
    ) throws {
        let executableSHA256 = try system.collectorExecutableSHA256()
        let teamIdentifier = try system.collectorTeamIdentifier()
        let signingIdentifier = try system.collectorSigningIdentifier()
        guard executableSHA256 == expectedSHA256,
              teamIdentifier == expectedTeamIdentifier,
              signingIdentifier == Self.collectorSigningIdentifier
        else {
            throw VoicePerformanceCollectorError.invalidCollectorIdentity
        }
        try system.validateCollectorDeveloperID(
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier
        )
    }

    public func environmentSnapshot() throws
        -> VoicePerformanceEnvironmentSnapshot
    {
        try system.environmentSnapshot()
    }

    public func continuousTimeNanoseconds() throws -> UInt64 {
        try system.continuousTimeNanoseconds()
    }

    public func attestedSnapshot(
        for process: VoicePerformanceProcessPlan,
        expectedTeamIdentifier: String
    ) throws -> VoicePerformanceProcessSnapshot {
        let first = try system.rusageV6(
            processIdentifier: process.processIdentifier
        )
        try validateLive(first)

        let identity = try system.processIdentity(
            processIdentifier: process.processIdentifier
        )
        guard identity.effectiveUserID == system.effectiveUserID,
              identity.executablePath == process.expectedExecutablePath,
              identity.signingIdentifier == process.expectedSigningIdentifier,
              identity.teamIdentifier == expectedTeamIdentifier,
              identity.cdHash == process.expectedCDHash
        else {
            throw VoicePerformanceCollectorError.invalidProcessIdentity
        }
        try system.validateDeveloperID(
            processIdentifier: process.processIdentifier,
            signingIdentifier: process.expectedSigningIdentifier,
            teamIdentifier: expectedTeamIdentifier
        )

        let second = try system.rusageV6(
            processIdentifier: process.processIdentifier
        )
        try validateLive(second)
        guard second.processStartAbsoluteTime
                == first.processStartAbsoluteTime,
              second.userCPUNanoseconds >= first.userCPUNanoseconds,
              second.systemCPUNanoseconds >= first.systemCPUNanoseconds,
              second.energyNanojoules >= first.energyNanojoules
        else {
            throw VoicePerformanceCollectorError.invalidProcessIdentity
        }

        return VoicePerformanceProcessSnapshot(
            processIdentifier: process.processIdentifier,
            processStartAbsoluteTime: second.processStartAbsoluteTime,
            userCPUNanoseconds: second.userCPUNanoseconds,
            systemCPUNanoseconds: second.systemCPUNanoseconds,
            energyNanojoules: second.energyNanojoules,
            residentBytes: second.residentBytes,
            physicalFootprintBytes: second.physicalFootprintBytes
        )
    }

    private func validateLive(
        _ usage: DarwinVoicePerformanceRUsageV6
    ) throws {
        guard usage.processStartAbsoluteTime > 0,
              usage.processExitAbsoluteTime == 0
        else {
            throw VoicePerformanceCollectorError.invalidProcessIdentity
        }
    }
}
