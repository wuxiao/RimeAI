import Foundation

private enum RimeEngineError: Error {
    case missingSharedData
    case initialization(String)
    case optionConfiguration(String)
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

    func apply(_ preferences: RimeAIInputPreferences) {
        queue.async { [self] in
            do {
                let engine = try ensureEngine()
                try configure(engine, preferences: preferences)
            } catch {
                // Candidate lookup remains fail-safe. A later request can still
                // use the last successfully applied Rime session options.
            }
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
                        min(max(limit, 1), 50),
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

    func selectCandidate(
        pinyin: String,
        index: Int,
        expectedText: String
    ) -> CandidateSelectionTransition? {
        queue.sync {
            do {
                guard index >= 0, index < 50 else {
                    throw RimeEngineError.candidateCommit(
                        "Candidate index is outside the displayed list"
                    )
                }
                let engine = try ensureEngine()
                var selectedText = [CChar](repeating: 0, count: 4_096)
                var remainingInput = [CChar](repeating: 0, count: 4_096)
                var error = [CChar](repeating: 0, count: 512)
                let result = pinyin.withCString { input in
                    expectedText.withCString { expected in
                        rai_engine_select_candidate(
                            engine,
                            input,
                            index,
                            expected,
                            &selectedText,
                            selectedText.count,
                            &remainingInput,
                            remainingInput.count,
                            &error,
                            error.count
                        )
                    }
                }
                let selected = rimeErrorMessage(selectedText)
                let remaining = rimeErrorMessage(remainingInput)
                if result == Int32(RAI_CANDIDATE_SELECTION_COMPLETE) {
                    guard remaining.isEmpty else {
                        throw RimeEngineError.candidateCommit(
                            "Complete selection unexpectedly retained input"
                        )
                    }
                } else if result == Int32(
                    RAI_CANDIDATE_SELECTION_PARTIAL
                ) {
                    guard !remaining.isEmpty else {
                        throw RimeEngineError.candidateCommit(
                            "Partial selection unexpectedly consumed all input"
                        )
                    }
                } else {
                    throw RimeEngineError.candidateCommit(
                        rimeErrorMessage(error)
                    )
                }
                return CandidateSelectionTransition(
                    originalInput: pinyin,
                    committedText: selected,
                    remainingInput: remaining
                )
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
            do {
                try configure(
                    created,
                    preferences: RimeAISettingsStore.shared.inputPreferences
                )
            } catch {
                rai_engine_destroy(created)
                throw error
            }
            engine = created
            return created
        } catch {
            initializationFailure = error
            throw error
        }
    }

    private func configure(
        _ engine: OpaquePointer,
        preferences: RimeAIInputPreferences
    ) throws {
        let characterOptions = [
            "zh_hant",
            "zh_hans",
            "zh_hant_hk",
            "zh_hant_tw",
        ]
        let selectedCharacterOption = preferences.characterSet == .simplified
            ? "zh_hans"
            : "zh_hant"
        for option in characterOptions where option != selectedCharacterOption {
            try setOption(option, enabled: false, engine: engine)
        }
        try setOption(
            selectedCharacterOption,
            enabled: true,
            engine: engine
        )
        try setOption(
            "full_shape",
            enabled: preferences.characterWidth == .full,
            engine: engine
        )
        try setOption(
            "ascii_punct",
            enabled: preferences.punctuationStyle == .western,
            engine: engine
        )
    }

    private func setOption(
        _ option: String,
        enabled: Bool,
        engine: OpaquePointer
    ) throws {
        var error = [CChar](repeating: 0, count: 512)
        let status = option.withCString { name in
            rai_engine_set_option(
                engine,
                name,
                enabled ? 1 : 0,
                &error,
                error.count
            )
        }
        guard status == 0 else {
            throw RimeEngineError.optionConfiguration(
                rimeErrorMessage(error)
            )
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
