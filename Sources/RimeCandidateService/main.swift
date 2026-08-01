import CryptoKit
import Foundation
import RimeBridgeC

private struct ServiceConfiguration {
    let sharedDataDirectory: String
    let userDataDirectory: String
    let schemaID: String

    static func parse(_ arguments: [String]) throws -> ServiceConfiguration {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard ["--shared-data", "--user-data", "--schema"].contains(key),
                  index + 1 < arguments.count
            else {
                throw ServiceError.configuration(
                    "usage: rime-candidate-service --shared-data PATH --user-data PATH --schema ID"
                )
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard let sharedDataDirectory = values["--shared-data"],
              let userDataDirectory = values["--user-data"],
              let schemaID = values["--schema"],
              !sharedDataDirectory.isEmpty,
              !userDataDirectory.isEmpty,
              !schemaID.isEmpty
        else {
            throw ServiceError.configuration(
                "usage: rime-candidate-service --shared-data PATH --user-data PATH --schema ID"
            )
        }
        return ServiceConfiguration(
            sharedDataDirectory: sharedDataDirectory,
            userDataDirectory: userDataDirectory,
            schemaID: schemaID
        )
    }
}

private enum ServiceError: Error, CustomStringConvertible {
    case configuration(String)
    case engine(String)

    var description: String {
        switch self {
        case let .configuration(message), let .engine(message):
            return message
        }
    }
}

private struct CandidateRequest: Decodable {
    let schemaVersion: Int
    let task: String
    let requestID: String
    let pinyin: String
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case task
        case requestID = "request_id"
        case pinyin
        case limit
    }
}

private struct EngineMetadata: Encodable {
    let name: String
    let version: String
    let schemaID: String
    let dataSHA256: String

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case schemaID = "schema_id"
        case dataSHA256 = "data_sha256"
    }
}

private struct CandidateResponse: Encodable {
    let schemaVersion = 1
    let requestID: String
    let candidates: [String]
    let engine: EngineMetadata

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case candidates
        case engine
    }
}

private final class CandidateCollector {
    var values: [String] = []
    private var seen = Set<String>()

    func append(_ value: String) {
        if seen.insert(value).inserted {
            values.append(value)
        }
    }
}

private func collectCandidate(
    _ text: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _: Int,
    _ context: UnsafeMutableRawPointer?
) {
    guard let text, let context else {
        return
    }
    let collector = Unmanaged<CandidateCollector>
        .fromOpaque(context)
        .takeUnretainedValue()
    collector.append(String(cString: text))
}

private func errorMessage(from buffer: [CChar]) -> String {
    let bytes = buffer
        .prefix { $0 != 0 }
        .map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

private func dataDirectorySHA256(at directory: String) throws -> String {
    let rootURL = URL(fileURLWithPath: directory, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw ServiceError.configuration("cannot enumerate Rime shared data")
    }
    var files: [URL] = []
    for case let fileURL as URL in enumerator {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
        if values.isRegularFile == true {
            files.append(fileURL)
        }
    }
    files.sort {
        $0.path.replacingOccurrences(of: rootURL.path, with: "")
            < $1.path.replacingOccurrences(of: rootURL.path, with: "")
    }
    var hasher = SHA256()
    for fileURL in files {
        let relativePath = fileURL.path.replacingOccurrences(
            of: rootURL.path + "/",
            with: ""
        )
        hasher.update(data: Data(relativePath.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: try Data(contentsOf: fileURL))
        hasher.update(data: Data([0]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func writeResponse<T: Encodable>(_ response: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(response)
    data.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: data)
}

private func makeEngine(configuration: ServiceConfiguration) throws -> OpaquePointer {
    var error = [CChar](repeating: 0, count: 512)
    let engine = configuration.sharedDataDirectory.withCString { sharedData in
        configuration.userDataDirectory.withCString { userData in
            configuration.schemaID.withCString { schema in
                rai_engine_create(
                    sharedData,
                    userData,
                    schema,
                    &error,
                    error.count
                )
            }
        }
    }
    guard let engine else {
        throw ServiceError.engine(errorMessage(from: error))
    }
    return engine
}

private func candidates(
    for request: CandidateRequest,
    engine: OpaquePointer
) throws -> [String] {
    guard request.schemaVersion == 1,
          request.task == "candidates",
          !request.requestID.isEmpty,
          !request.pinyin.isEmpty,
          request.pinyin.utf8.count <= 256,
          (1 ... 20).contains(request.limit)
    else {
        throw ServiceError.engine("candidate request failed validation")
    }
    let collector = CandidateCollector()
    let context = Unmanaged.passUnretained(collector).toOpaque()
    var error = [CChar](repeating: 0, count: 512)
    let count = request.pinyin.withCString { pinyin in
        rai_engine_candidates(
            engine,
            pinyin,
            request.limit,
            collectCandidate,
            context,
            &error,
            error.count
        )
    }
    guard count >= 0, !collector.values.isEmpty else {
        throw ServiceError.engine(errorMessage(from: error))
    }
    return collector.values
}

do {
    let configuration = try ServiceConfiguration.parse(CommandLine.arguments)
    let dataSHA256 = try dataDirectorySHA256(
        at: configuration.sharedDataDirectory
    )
    let engine = try makeEngine(configuration: configuration)
    defer {
        rai_engine_destroy(engine)
    }
    let version = rai_engine_version(engine).map(String.init(cString:)) ?? "unknown"
    let metadata = EngineMetadata(
        name: "librime",
        version: version,
        schemaID: configuration.schemaID,
        dataSHA256: dataSHA256
    )
    let decoder = JSONDecoder()
    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8) else {
            throw ServiceError.engine("request is not valid UTF-8")
        }
        let request = try decoder.decode(CandidateRequest.self, from: data)
        let response = CandidateResponse(
            requestID: request.requestID,
            candidates: try candidates(for: request, engine: engine),
            engine: metadata
        )
        try writeResponse(response)
    }
} catch {
    FileHandle.standardError.write(
        Data("rime-candidate-service: \(error)\n".utf8)
    )
    exit(2)
}
