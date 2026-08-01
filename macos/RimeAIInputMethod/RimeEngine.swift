import Foundation

private enum RimeEngineError: Error {
    case missingSharedData
    case initialization(String)
    case candidateLookup(String)
    case candidateCommit(String)
}

private final class RimeCandidateCollector {
    var candidates: [String] = []
    private var seen = Set<String>()

    func append(_ text: String) {
        if seen.insert(text).inserted {
            candidates.append(text)
        }
    }
}

private func collectRimeCandidate(
    _ text: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _: Int,
    _ context: UnsafeMutableRawPointer?
) {
    guard let text, let context else {
        return
    }
    let collector = Unmanaged<RimeCandidateCollector>
        .fromOpaque(context)
        .takeUnretainedValue()
    collector.append(String(cString: text))
}

private func rimeErrorMessage(_ buffer: [CChar]) -> String {
    let bytes = buffer
        .prefix { $0 != 0 }
        .map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

final class RimeEngine: @unchecked Sendable {
    static let shared = RimeEngine()

    private let queue = DispatchQueue(label: "fun.wwcn.rimeai.rime")
    private var engine: OpaquePointer?
    private var initializationFailure: Error?

    private init() {}

    deinit {
        queue.sync {
            if let engine {
                rai_engine_destroy(engine)
            }
        }
    }

    func warm() {
        queue.async { [self] in
            _ = try? ensureEngine()
        }
    }

    func candidates(for pinyin: String, limit: Int = 10) -> [String] {
        queue.sync {
            do {
                let engine = try ensureEngine()
                let collector = RimeCandidateCollector()
                let context = Unmanaged.passUnretained(collector).toOpaque()
                var error = [CChar](repeating: 0, count: 512)
                let count = pinyin.withCString { input in
                    rai_engine_candidates(
                        engine,
                        input,
                        min(max(limit, 1), 10),
                        collectRimeCandidate,
                        context,
                        &error,
                        error.count
                    )
                }
                guard count >= 0 else {
                    throw RimeEngineError.candidateLookup(
                        rimeErrorMessage(error)
                    )
                }
                return collector.candidates
            } catch {
                return []
            }
        }
    }

    func commitCandidate(
        pinyin: String,
        index: Int
    ) -> String? {
        queue.sync {
            do {
                let engine = try ensureEngine()
                var committedText = [CChar](repeating: 0, count: 4_096)
                var error = [CChar](repeating: 0, count: 512)
                let count = pinyin.withCString { input in
                    rai_engine_commit_candidate(
                        engine,
                        input,
                        max(index, 0),
                        &committedText,
                        committedText.count,
                        &error,
                        error.count
                    )
                }
                guard count >= 0 else {
                    throw RimeEngineError.candidateCommit(
                        rimeErrorMessage(error)
                    )
                }
                return String(cString: committedText)
            } catch {
                return nil
            }
        }
    }

    private func ensureEngine() throws -> OpaquePointer {
        if let engine {
            return engine
        }
        if let initializationFailure {
            throw initializationFailure
        }
        do {
            guard let sharedDataDirectory = Bundle.main.resourceURL?
                .appendingPathComponent("shared", isDirectory: true),
                FileManager.default.fileExists(
                    atPath: sharedDataDirectory.path
                )
            else {
                throw RimeEngineError.missingSharedData
            }
            let userDataDirectory = try prepareUserDataDirectory()
            var error = [CChar](repeating: 0, count: 512)
            let created = sharedDataDirectory.path.withCString { sharedData in
                userDataDirectory.path.withCString { userData in
                    "luna_pinyin_simp".withCString { schema in
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
            guard let created else {
                throw RimeEngineError.initialization(
                    rimeErrorMessage(error)
                )
            }
            engine = created
            return created
        } catch {
            initializationFailure = error
            throw error
        }
    }

    private func prepareUserDataDirectory() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appendingPathComponent("RimeAI", isDirectory: true)
            .appendingPathComponent("Rime", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return directory
    }
}
