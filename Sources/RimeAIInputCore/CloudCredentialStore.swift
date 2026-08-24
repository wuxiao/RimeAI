import Foundation

public enum CloudCredentialError: Error, Equatable, Sendable {
    case invalidAPIKey
    case ioFailure(Int32)
    case malformedFile
    case insecurePath
}

public protocol CloudCredentialStoring: Sendable {
    func containsAPIKey() throws -> Bool
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey() throws
}

/// 凭据以 `RIMEAI_CLOUD_API_KEY=<value>` 的形式存放在 0600 的
/// `~/.config/rimeai/cloud.env`，输入法进程直接读取。
public final class FileCloudCredentialStore:
    CloudCredentialStoring,
    Sendable
{
    public static let shared = FileCloudCredentialStore(
        path: RimeAIProductDataLayout(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ).cloudCredentialFile
    )

    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    public func containsAPIKey() throws -> Bool {
        try loadAPIKey() != nil
    }

    public func loadAPIKey() throws -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path.path) else {
            return nil
        }
        try validatePathIsNotSymlink()
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw CloudCredentialError.ioFailure(
                Self.underlyingErrno(error)
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CloudCredentialError.malformedFile
        }
        let value = try Self.parse(text)[
            RimeAICloudConfiguration.credentialKey
        ] ?? ""
        return value.isEmpty ? nil : value
    }

    public func saveAPIKey(_ apiKey: String) throws {
        let normalized = apiKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty,
              normalized.utf8.count <= 512,
              !normalized.contains("\n"),
              !normalized.contains("\r"),
              !normalized.contains("\0")
        else {
            throw CloudCredentialError.invalidAPIKey
        }
        try validatePathIsNotSymlink()
        try prepareCredentialDirectory()
        let contents = """
            # RimeAI cloud credentials - managed by the input method.
            # Lines must be KEY=VALUE; only whole-line comments are stripped.
            \(RimeAICloudConfiguration.credentialKey)=\(normalized)

            """
        let temporaryURL = path.deletingLastPathComponent()
            .appendingPathComponent(
                ".cloud.env.\(UUID().uuidString).tmp",
                isDirectory: false
            )
        let fileManager = FileManager.default
        let created = fileManager.createFile(
            atPath: temporaryURL.path,
            contents: Data(contents.utf8),
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw CloudCredentialError.ioFailure(
                POSIXErrorCode.EACCES.rawValue
            )
        }
        do {
            _ = try fileManager.replaceItemAt(
                path,
                withItemAt: temporaryURL
            )
        } catch {
            _ = try? fileManager.removeItem(at: temporaryURL)
            throw CloudCredentialError.ioFailure(
                Self.underlyingErrno(error)
            )
        }
    }

    public func deleteAPIKey() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: path)
        } catch {
            throw CloudCredentialError.ioFailure(
                Self.underlyingErrno(error)
            )
        }
        removeCredentialDirectoryIfEmpty()
    }

    // MARK: - Parsing

    /// 解析 KEY=VALUE 行；仅整行 `#` 注释与空行被忽略，行内 `#`
    /// 属于值的一部分。值首尾空白被去除，成对的单/双引号被剥离。
    /// 非空、非注释却缺少 `=` 的行视为文件损坏，显式抛错——
    /// 否则手误（如漏写 `=`）会被当成"无凭据"静默关闭云端。
    public static func parse(_ text: String) throws -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let separator = line.firstIndex(of: "=") else {
                throw CloudCredentialError.malformedFile
            }
            let key = String(line[..<separator]).trimmingCharacters(
                in: .whitespaces
            )
            guard !key.isEmpty else {
                throw CloudCredentialError.malformedFile
            }
            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               let first = value.first,
               let last = value.last,
               (first == "\"" && last == "\"")
                   || (first == "'" && last == "'")
            {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }

    // MARK: - Filesystem helpers

    private func validatePathIsNotSymlink() throws {
        for url in [path, path.deletingLastPathComponent()] {
            let values = try? url.resourceValues(
                forKeys: [.isSymbolicLinkKey]
            )
            if values?.isSymbolicLink == true {
                throw CloudCredentialError.insecurePath
            }
        }
    }

    /// `~/.config` 保持 0755（其他工具共用）；`~/.config/rimeai`
    /// 强制 0700，无论新建还是已存在。
    private func prepareCredentialDirectory() throws {
        let fileManager = FileManager.default
        let rootDirectory = path.deletingLastPathComponent()
            .deletingLastPathComponent()
        let credentialDirectory = path.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: rootDirectory.path) {
            do {
                try fileManager.createDirectory(
                    at: rootDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o755]
                )
            } catch {
                throw CloudCredentialError.ioFailure(
                    Self.underlyingErrno(error)
                )
            }
        }
        if !fileManager.fileExists(atPath: credentialDirectory.path) {
            do {
                try fileManager.createDirectory(
                    at: credentialDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw CloudCredentialError.ioFailure(
                    Self.underlyingErrno(error)
                )
            }
        } else {
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: credentialDirectory.path
                )
            } catch {
                throw CloudCredentialError.ioFailure(
                    Self.underlyingErrno(error)
                )
            }
        }
    }

    private func removeCredentialDirectoryIfEmpty() {
        let credentialDirectory = path.deletingLastPathComponent()
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: credentialDirectory,
            includingPropertiesForKeys: nil
        ),
            entries.isEmpty
        else {
            return
        }
        try? fileManager.removeItem(at: credentialDirectory)
    }

    private static func underlyingErrno(_ error: Error) -> Int32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey]
            as? NSError
        {
            return Int32(underlying.code)
        }
        return POSIXErrorCode.EIO.rawValue
    }
}

extension CloudCredentialError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "API Key 必须非空、不超过 512 字节且不含换行"
        case let .ioFailure(errno):
            "凭据文件读写失败（errno \(errno)）"
        case .malformedFile:
            "凭据文件无法解析：必须是 UTF-8 的 KEY=VALUE 行"
        case .insecurePath:
            "凭据文件路径指向符号链接，已拒绝访问"
        }
    }
}
