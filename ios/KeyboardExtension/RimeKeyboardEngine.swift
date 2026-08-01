import Foundation

struct RimeKeyboardCandidate: Sendable {
    let text: String
    let comment: String?
    let index: Int
}

enum RimeKeyboardEngineError: Error, LocalizedError, Sendable {
    case resource(String)
    case engine(String)

    var errorDescription: String? {
        switch self {
        case let .resource(message), let .engine(message):
            message
        }
    }
}

private final class CandidateCollector {
    var candidates: [RimeKeyboardCandidate] = []
}

private func collectRimeCandidate(
    _ text: UnsafePointer<CChar>?,
    _ comment: UnsafePointer<CChar>?,
    _ index: Int,
    _ context: UnsafeMutableRawPointer?
) {
    guard let text, let context else {
        return
    }
    let collector = Unmanaged<CandidateCollector>
        .fromOpaque(context)
        .takeUnretainedValue()
    collector.candidates.append(
        RimeKeyboardCandidate(
            text: String(cString: text),
            comment: comment.map(String.init(cString:)),
            index: index
        )
    )
}

final class RimeKeyboardEngine: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "fun.wwcn.rimeai.keyboard.librime",
        qos: .userInitiated
    )
    private var engine: OpaquePointer?

    func start(
        completion: @escaping @Sendable (
            Result<String, RimeKeyboardEngineError>
        ) -> Void
    ) {
        queue.async { [self] in
            guard engine == nil else {
                completion(.success(version ?? "unknown"))
                return
            }

            do {
                let paths = try RimeResourceInstaller.prepare()
                var error = [CChar](repeating: 0, count: 512)
                let created = error.withUnsafeMutableBufferPointer { errorBuffer in
                    paths.shared.path.withCString { shared in
                        paths.user.path.withCString { user in
                            "luna_pinyin_simp".withCString { schema in
                                rai_engine_create_prebuilt(
                                    shared,
                                    user,
                                    schema,
                                    errorBuffer.baseAddress,
                                    errorBuffer.count
                                )
                            }
                        }
                    }
                }
                guard let created else {
                    completion(
                        .failure(
                            .engine(
                                Self.message(
                                    from: error,
                                    fallback: "无法启动 librime"
                                )
                            )
                        )
                    )
                    return
                }
                engine = created
                completion(.success(version ?? "unknown"))
            } catch let error as RimeKeyboardEngineError {
                completion(.failure(error))
            } catch {
                completion(.failure(.resource(error.localizedDescription)))
            }
        }
    }

    func candidates(
        for pinyin: String,
        limit: Int = 10,
        completion: @escaping @Sendable (
            Result<[RimeKeyboardCandidate], RimeKeyboardEngineError>
        ) -> Void
    ) {
        queue.async { [self] in
            guard let engine else {
                completion(.failure(.engine("librime 尚未就绪")))
                return
            }
            let collector = CandidateCollector()
            let context = Unmanaged.passUnretained(collector).toOpaque()
            var error = [CChar](repeating: 0, count: 512)
            let count = error.withUnsafeMutableBufferPointer { errorBuffer in
                pinyin.withCString { input in
                    rai_engine_candidates(
                        engine,
                        input,
                        limit,
                        collectRimeCandidate,
                        context,
                        errorBuffer.baseAddress,
                        errorBuffer.count
                    )
                }
            }
            guard count >= 0 else {
                completion(
                    .failure(
                        .engine(
                            Self.message(
                                from: error,
                                fallback: "未找到候选词"
                            )
                        )
                    )
                )
                return
            }
            completion(.success(collector.candidates))
        }
    }

    func commit(
        pinyin: String,
        candidateIndex: Int,
        completion: @escaping @Sendable (
            Result<String, RimeKeyboardEngineError>
        ) -> Void
    ) {
        queue.async { [self] in
            guard let engine else {
                completion(.failure(.engine("librime 尚未就绪")))
                return
            }
            var committed = [CChar](repeating: 0, count: 4096)
            var error = [CChar](repeating: 0, count: 512)
            let result = committed.withUnsafeMutableBufferPointer {
                committedBuffer in
                error.withUnsafeMutableBufferPointer { errorBuffer in
                    pinyin.withCString { input in
                        rai_engine_commit_candidate(
                            engine,
                            input,
                            candidateIndex,
                            committedBuffer.baseAddress,
                            committedBuffer.count,
                            errorBuffer.baseAddress,
                            errorBuffer.count
                        )
                    }
                }
            }
            guard result >= 0 else {
                completion(
                    .failure(
                        .engine(
                            Self.message(
                                from: error,
                                fallback: "无法提交候选词"
                            )
                        )
                    )
                )
                return
            }
            let text = committed.withUnsafeBufferPointer { pointer in
                String(cString: pointer.baseAddress!)
            }
            completion(.success(text))
        }
    }

    private var version: String? {
        guard let engine, let value = rai_engine_version(engine) else {
            return nil
        }
        return String(cString: value)
    }

    private static func message(
        from buffer: [CChar],
        fallback: String
    ) -> String {
        buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress,
                  baseAddress.pointee != 0
            else {
                return fallback
            }
            return String(cString: baseAddress)
        }
    }
}

private enum RimeResourceInstaller {
    private static let installedVersion = "rimeai-ios-data-2026-07-31"

    static func prepare() throws -> (shared: URL, user: URL) {
        let fileManager = FileManager.default
        guard let bundledRoot = Bundle.main.url(
            forResource: "RimeData",
            withExtension: nil
        ) else {
            throw RimeKeyboardEngineError.resource(
                "安装包缺少 RimeData"
            )
        }
        let bundledShared = bundledRoot.appendingPathComponent(
            "shared",
            isDirectory: true
        )
        let bundledBuild = bundledRoot.appendingPathComponent(
            "user-build",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: bundledShared.path),
              fileManager.fileExists(atPath: bundledBuild.path)
        else {
            throw RimeKeyboardEngineError.resource(
                "安装包内的 Rime 数据不完整"
            )
        }

        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw RimeKeyboardEngineError.resource(
                "无法访问键盘私有数据目录"
            )
        }
        let root = applicationSupport.appendingPathComponent(
            "RimeAI",
            isDirectory: true
        )
        let marker = root.appendingPathComponent("seed-version.txt")
        let currentVersion = try? String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let user = root.appendingPathComponent("user", isDirectory: true)

        if currentVersion != installedVersion {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: shared.path) {
                try fileManager.removeItem(at: shared)
            }
            try fileManager.copyItem(at: bundledShared, to: shared)

            try fileManager.createDirectory(
                at: user,
                withIntermediateDirectories: true
            )
            let build = user.appendingPathComponent(
                "build",
                isDirectory: true
            )
            if fileManager.fileExists(atPath: build.path) {
                try fileManager.removeItem(at: build)
            }
            try fileManager.copyItem(at: bundledBuild, to: build)
            try Data(installedVersion.utf8).write(
                to: marker,
                options: .atomic
            )
        }

        return (shared, user)
    }
}
