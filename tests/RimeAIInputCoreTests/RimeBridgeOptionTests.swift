import Foundation
import RimeBridgeC
import Testing
@testable import RimeAIInputCore

private enum RimeBridgeOptionTestError: Error {
    case operation(String)
}

private final class RimeBridgeCandidateCollector {
    var values: [String] = []
}

private func collectRimeBridgeCandidate(
    _ text: UnsafePointer<CChar>?,
    _: UnsafePointer<CChar>?,
    _: Int,
    _ context: UnsafeMutableRawPointer?
) {
    guard let text, let context else { return }
    Unmanaged<RimeBridgeCandidateCollector>
        .fromOpaque(context)
        .takeUnretainedValue()
        .values.append(String(cString: text))
}

@Suite("Rime visible options", .serialized)
struct RimeBridgeOptionTests {
    @Test("librime accepts simplified, traditional and width options")
    func optionRoundTrip() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sharedData = repository
            .appendingPathComponent(".rimeai/rime/shared", isDirectory: true)
        let userData = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RimeBridgeOptionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: userData,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: userData) }

        var error = [CChar](repeating: 0, count: 512)
        let engine = sharedData.path.withCString { sharedPath in
            userData.path.withCString { userPath in
                "luna_pinyin_simp".withCString { schema in
                    rai_engine_create(
                        sharedPath,
                        userPath,
                        schema,
                        &error,
                        error.count
                    )
                }
            }
        }
        let message = errorMessage(error)
        let activeEngine = try #require(engine, "librime init: \(message)")
        defer { rai_engine_destroy(activeEngine) }

        try set("zh_hans", true, engine: activeEngine)
        #expect(try get("zh_hans", engine: activeEngine))
        let simplifiedCandidates = try candidates(
            "taiwan",
            engine: activeEngine
        )
        #expect(
            simplifiedCandidates.contains("台湾"),
            "simplified candidates: \(simplifiedCandidates)"
        )
        try set("zh_hans", false, engine: activeEngine)
        try set("zh_hant", true, engine: activeEngine)
        #expect(try get("zh_hant", engine: activeEngine))
        let traditionalCandidates = try candidates(
            "taiwan",
            engine: activeEngine
        )
        #expect(
            traditionalCandidates.contains("臺灣"),
            "traditional candidates: \(traditionalCandidates)"
        )
        try set("full_shape", true, engine: activeEngine)
        #expect(try get("full_shape", engine: activeEngine))
        try set("full_shape", false, engine: activeEngine)
        #expect(!(try get("full_shape", engine: activeEngine)))
    }

    @Test("continuous mixed composition resolves with real librime candidates")
    func mixedCompositionWithRealRime() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sharedData = repository
            .appendingPathComponent(".rimeai/rime/shared", isDirectory: true)
        let userData = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RimeBridgeMixedTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: userData,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: userData) }

        var error = [CChar](repeating: 0, count: 512)
        let engine = sharedData.path.withCString { sharedPath in
            userData.path.withCString { userPath in
                "luna_pinyin_simp".withCString { schema in
                    rai_engine_create(
                        sharedPath,
                        userPath,
                        schema,
                        &error,
                        error.count
                    )
                }
            }
        }
        let activeEngine = try #require(
            engine,
            "librime init: \(errorMessage(error))"
        )
        defer { rai_engine_destroy(activeEngine) }
        try set("zh_hans", true, engine: activeEngine)

        let resolver = MixedCompositionResolver()
        let suggestion = resolver.resolve(
            rawInput: "zhegeAPIxuyaozengjiatimeoutpeizhi"
        ) { pinyin, limit in
            (try? candidates(
                pinyin,
                limit: limit,
                engine: activeEngine
            )) ?? []
        }
        let lowercaseSuggestion = resolver.resolve(
            rawInput: "zhegeapixuyaozengjiatimeoutpeizhi"
        ) { pinyin, limit in
            (try? candidates(
                pinyin,
                limit: limit,
                engine: activeEngine
            )) ?? []
        }
        let rawLeadSuggestion = resolver.resolve(
            rawInput: "inihao"
        ) { pinyin, limit in
            (try? candidates(
                pinyin,
                limit: limit,
                engine: activeEngine
            )) ?? []
        }
        // 韵母首字母开头的输入：Rime 无法解析整串，但切分出的余串
        // nihao 必须与 nihaoi 等 Rime 可见形式给出一致的候选。
        let inihaoCandidates = (try? candidates(
            "inihao",
            limit: 10,
            engine: activeEngine
        )) ?? []
        let nihaoiCandidates = (try? candidates(
            "nihaoi",
            limit: 10,
            engine: activeEngine
        )) ?? []
        let split = try #require(
            MixedCompositionResolver.rawLeadSplit(of: "inihao")
        )
        let remainderCandidates = (try? candidates(
            split.remainder,
            limit: 10,
            engine: activeEngine
        )) ?? []

        #expect(suggestion?.text == "这个API需要增加timeout配置")
        #expect(
            lowercaseSuggestion?.text
                == "这个api需要增加timeout配置"
        )
        #expect(rawLeadSuggestion?.text == "i你好")
        #expect(inihaoCandidates.isEmpty)
        #expect(!nihaoiCandidates.isEmpty)
        #expect(remainderCandidates == nihaoiCandidates)
    }

    private func set(
        _ option: String,
        _ enabled: Bool,
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
            throw RimeBridgeOptionTestError.operation(errorMessage(error))
        }
    }

    private func get(
        _ option: String,
        engine: OpaquePointer
    ) throws -> Bool {
        var value: Int32 = 0
        var error = [CChar](repeating: 0, count: 512)
        let status = option.withCString { name in
            rai_engine_get_option(
                engine,
                name,
                &value,
                &error,
                error.count
            )
        }
        guard status == 0 else {
            throw RimeBridgeOptionTestError.operation(errorMessage(error))
        }
        return value != 0
    }

    private func candidates(
        _ pinyin: String,
        limit: Int = 20,
        engine: OpaquePointer
    ) throws -> [String] {
        let collector = RimeBridgeCandidateCollector()
        let context = Unmanaged.passUnretained(collector).toOpaque()
        var error = [CChar](repeating: 0, count: 512)
        let status = pinyin.withCString { input in
            rai_engine_candidates(
                engine,
                input,
                min(max(limit, 1), 50),
                collectRimeBridgeCandidate,
                context,
                &error,
                error.count
            )
        }
        guard status >= 0 else {
            throw RimeBridgeOptionTestError.operation(errorMessage(error))
        }
        return collector.values
    }

    private func errorMessage(_ buffer: [CChar]) -> String {
        String(
            decoding: buffer
                .prefix { $0 != 0 }
                .map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}
