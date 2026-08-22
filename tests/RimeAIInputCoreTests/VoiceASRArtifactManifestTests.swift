import Darwin
import Foundation
import Testing
@_spi(RimeAIInternal) import RimeAIVoiceArtifactCore
@testable import RimeAIInputCore

private final class VoiceASRLockedResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?

    func store(_ result: Result<Value, any Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func value() throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try #require(result).get()
    }
}

@Suite("Product-managed voice ASR artifacts")
struct VoiceASRArtifactManifestTests {
    @Test("schema v2 describes artifact facts without a release approval")
    func validManifestDecodes() throws {
        let manifest = try VoiceASRArtifactManifest.decodeStrict(
            Data(Self.validManifestJSON().utf8),
            verifyContentDigest: false
        )

        #expect(manifest.schemaVersion == 2)
        #expect(manifest.artifactType == "rimeai.voice-asr-model")
        #expect(manifest.assetManagement == .productManaged)
        #expect(
            manifest.artifactID.rawValue == "sherpa-zipformer-zh-en-int8-v1"
        )
        #expect(manifest.adapter.id == "sherpa-onnx")
        #expect(manifest.adapter.version == "1.13.6")
        #expect(manifest.adapter.abiVersion == 1)
        #expect(manifest.model.format == .onnx)
        #expect(manifest.target.architecture == .arm64)
        #expect(manifest.target.minimumOSVersion == "14.0")
        #expect(manifest.audio.sampleRateHertz == 16_000)
        #expect(manifest.audio.channelCount == 1)
        #expect(manifest.audio.sampleFormat == .float32LittleEndian)
        #expect(manifest.runtime.kind == .sherpaOnnxOnlineTransducer)
        #expect(manifest.runtime.modelingUnit == .cjkCharacterAndBPE)
        #expect(manifest.locales == ["en-US", "zh-CN"])
        #expect(manifest.capabilities.hotwordMode == .boundedPhraseList)
        #expect(manifest.capabilities.maximumAlternatives == 1)
        #expect(manifest.inventory.count == 7)
    }

    @Test("unknown JSON keys are rejected instead of ignored")
    func unknownJSONKeyIsRejected() {
        let json = Self.validManifestJSON().replacingOccurrences(
            of: "\"schema_version\": 2,",
            with: "\"schema_version\": 2, \"unexpected\": true,"
        )

        #expect(
            throws: VoiceASRArtifactError.unexpectedKeys(
                context: "manifest",
                keys: ["unexpected"]
            )
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(json.utf8)
            )
        }
    }

    @Test("duplicate JSON keys are rejected before Foundation can collapse them")
    func duplicateJSONKeyIsRejected() {
        let json = Self.validManifestJSON().replacingOccurrences(
            of: "\"artifact_id\": \"sherpa-zipformer-zh-en-int8-v1\",",
            with: """
                "artifact_id": "sherpa-zipformer-zh-en-int8-v1",
                "artifact_id": "other-artifact",
                """
        )

        #expect(
            throws: VoiceASRArtifactError.duplicateJSONKey("artifact_id")
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(json.utf8)
            )
        }
    }

    @Test("system-managed metadata cannot masquerade as a product artifact")
    func systemManagedArtifactIsRejected() {
        let json = Self.validManifestJSON().replacingOccurrences(
            of: "\"asset_management\": \"product-managed\"",
            with: "\"asset_management\": \"system-managed\""
        )

        #expect(throws: VoiceASRArtifactError.productManagedRequired) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(json.utf8)
            )
        }
    }

    @Test("content identity is stable canonical metadata plus sorted inventory")
    func canonicalContentDigestIsStable() throws {
        let manifest = try VoiceASRArtifactManifest.decodeStrict(
            Data(Self.validManifestJSON().utf8),
            verifyContentDigest: false
        )

        #expect(
            manifest.calculatedContentSHA256
                == "4fa8f1ad946857620cf81ab549cf10e4135962e81eb45758d522e5df62a04504"
        )
    }

    @Test("production verifier accepts only a complete exact on-disk pack")
    func validArtifactDirectoryVerifies() throws {
        let directory = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let verified = try VoiceASRArtifactVerifier().verifyArtifact(
            at: directory
        )

        #expect(
            verified.manifest.artifactID.rawValue
                == "sherpa-zipformer-zh-en-int8-v1"
        )
        #expect(verified.contentSHA256 == verified.manifest.contentSHA256)
        #expect(verified.verifiedFileCount == 7)
        #expect(verified.verifiedPayloadBytes == 49)
    }

    @Test("selector directory ID must match the verified manifest ID")
    func storeBindsSelectorIDToManifestID() throws {
        let artifact = try Self.makeValidArtifactDirectory()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimeai-voice-store-identity-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: artifact)
            try? FileManager.default.removeItem(at: home)
        }
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let layout = RimeAIProductDataLayout(homeDirectory: home)
        try FileManager.default.createDirectory(
            at: layout.voiceASRReleasesDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let expected = VoiceASRArtifactID(rawValue: "wrong-directory-id")!
        let destination = layout.voiceASRReleaseDirectory(for: expected)
        try FileManager.default.moveItem(at: artifact, to: destination)

        let actual = VoiceASRArtifactID(
            rawValue: "sherpa-zipformer-zh-en-int8-v1"
        )!
        #expect(throws: VoiceASRArtifactStoreError.artifactIdentityMismatch(
            expected: expected,
            actual: actual
        )) {
            try VoiceASRArtifactStore(layout: layout).activate(expected)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: layout.voiceASRCurrentSelector.path
            )
        )
    }

    @Test(
        "current artifact is reverified and backend-loaded under one generation"
    )
    func verifiedCurrentArtifactBuildsControlledProductDescriptor() throws {
        let artifact = try Self.makeValidArtifactDirectory()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimeai-voice-lease-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: home)
        }
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let layout = RimeAIProductDataLayout(homeDirectory: home)
        let store = VoiceASRArtifactStore(layout: layout)
        _ = try store.selectorState()
        let artifactID = VoiceASRArtifactID(
            rawValue: "sherpa-zipformer-zh-en-int8-v1"
        )!
        try FileManager.default.moveItem(
            at: artifact,
            to: layout.voiceASRReleaseDirectory(for: artifactID)
        )
        _ = try store.activate(artifactID)

        let descriptor = try store.withVerifiedCurrentArtifact { lease in
            try VoiceEngineDescriptor.productManaged(
                lease: lease,
                loadProbe: VoiceProductEngineLoadProbe(
                    artifactGeneration: lease.generation,
                    adapterID: "sherpa-onnx",
                    adapterVersion: "1.13.6",
                    adapterABIVersion: 1,
                    runtimeKind: .sherpaOnnxOnlineTransducer,
                    supportedLocales: ["fr-FR", "zh-CN"],
                    supportsStreaming: true,
                    supportsPartialResults: true,
                    supportsEndpointDetection: true,
                    maximumHotwords: 16,
                    maximumAlternatives: 1,
                    sampleRateHertz: 16_000,
                    channelCount: 1,
                    bitsPerChannel: 32
                )
            )
        }

        #expect(descriptor.hasIntegrityVerifiedProductArtifact)
        #expect(descriptor.supportedLocales == ["zh-CN"])
        #expect(
            descriptor.hotwordMode == .boundedPhraseList(maximumEntries: 16)
        )
        #expect(
            descriptor.protocolEngineID
                == "sherpa-onnx@4fa8f1ad94685762"
        )
        #expect(descriptor.artifactGeneration != nil)
    }

    @Test("selector activation waits for the current backend load probe")
    func verifiedCurrentArtifactSerializesActivation() throws {
        let firstID = VoiceASRArtifactID(
            rawValue: "sherpa-zipformer-zh-en-int8-v1"
        )!
        let secondID = VoiceASRArtifactID(
            rawValue: "sherpa-zipformer-zh-en-int8-v2"
        )!
        let first = try Self.makeValidArtifactDirectory(
            artifactID: firstID.rawValue
        )
        let second = try Self.makeValidArtifactDirectory(
            artifactID: secondID.rawValue
        )
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimeai-voice-load-lock-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let layout = RimeAIProductDataLayout(homeDirectory: home)
        let store = VoiceASRArtifactStore(layout: layout)
        _ = try store.selectorState()
        try FileManager.default.moveItem(
            at: first,
            to: layout.voiceASRReleaseDirectory(for: firstID)
        )
        try FileManager.default.moveItem(
            at: second,
            to: layout.voiceASRReleaseDirectory(for: secondID)
        )
        _ = try store.activate(firstID)

        let loadEntered = DispatchSemaphore(value: 0)
        let releaseLoad = DispatchSemaphore(value: 0)
        let activationFinished = DispatchSemaphore(value: 0)
        let loadFinished = DispatchSemaphore(value: 0)
        let loadResult = VoiceASRLockedResultBox<UUID>()
        DispatchQueue.global().async {
            loadResult.store(Result {
                try store.withVerifiedCurrentArtifact { lease in
                    loadEntered.signal()
                    releaseLoad.wait()
                    return lease.generation
                }
            })
            loadFinished.signal()
        }
        #expect(loadEntered.wait(timeout: .now() + 2) == .success)
        let activationResult = VoiceASRLockedResultBox<VoiceASRSelectorState>()
        DispatchQueue.global().async {
            activationResult.store(Result {
                try store.activate(secondID)
            })
            activationFinished.signal()
        }

        #expect(
            activationFinished.wait(timeout: .now() + 0.1) == .timedOut
        )
        releaseLoad.signal()
        #expect(loadFinished.wait(timeout: .now() + 2) == .success)
        #expect(activationFinished.wait(timeout: .now() + 2) == .success)
        _ = try loadResult.value()
        let state = try activationResult.value()
        #expect(state.current == secondID)
    }

    @Test("product descriptor rejects a backend probe from another generation")
    func productDescriptorBindsBackendProbeGeneration() throws {
        let artifact = try Self.makeValidArtifactDirectory()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimeai-voice-generation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let layout = RimeAIProductDataLayout(homeDirectory: home)
        let store = VoiceASRArtifactStore(layout: layout)
        _ = try store.selectorState()
        let artifactID = VoiceASRArtifactID(
            rawValue: "sherpa-zipformer-zh-en-int8-v1"
        )!
        try FileManager.default.moveItem(
            at: artifact,
            to: layout.voiceASRReleaseDirectory(for: artifactID)
        )
        _ = try store.activate(artifactID)

        #expect(
            throws: VoiceProductEngineDescriptorError
                .artifactGenerationMismatch
        ) {
            _ = try store.withVerifiedCurrentArtifact { lease in
                try VoiceEngineDescriptor.productManaged(
                    lease: lease,
                    loadProbe: VoiceProductEngineLoadProbe(
                        artifactGeneration: UUID(),
                        adapterID: "sherpa-onnx",
                        adapterVersion: "1.13.6",
                        adapterABIVersion: 1,
                        runtimeKind: .sherpaOnnxOnlineTransducer,
                        supportedLocales: ["zh-CN"],
                        supportsStreaming: true,
                        supportsPartialResults: true,
                        supportsEndpointDetection: true,
                        maximumHotwords: 32,
                        maximumAlternatives: 1,
                        sampleRateHertz: 16_000,
                        channelCount: 1,
                        bitsPerChannel: 32
                    )
                )
            }
        }
    }

    @Test("backend load cannot begin without a selected artifact")
    func verifiedCurrentArtifactRequiresCurrentSelector() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimeai-voice-no-current-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let store = VoiceASRArtifactStore(
            layout: RimeAIProductDataLayout(homeDirectory: home)
        )
        #expect(throws: VoiceASRArtifactStoreError.noCurrentArtifact) {
            _ = try store.withVerifiedCurrentArtifact { _ in true }
        }
    }

    @Test("non-standard NaN is rejected by the JSON preflight")
    func nonFiniteJSONNumberIsRejected() {
        let json = Self.validManifestJSON().replacingOccurrences(
            of: "\"sample_rate_hz\": 16000",
            with: "\"sample_rate_hz\": NaN"
        )

        #expect(throws: VoiceASRArtifactError.invalidJSON) {
            _ = try VoiceASRArtifactManifest.decodeStrict(Data(json.utf8))
        }
    }

    @Test("exact-key validation applies to nested metadata")
    func nestedUnknownKeyIsRejected() {
        let json = Self.validManifestJSON().replacingOccurrences(
            of: "\"abi_version\": 1",
            with: "\"abi_version\": 1, \"unexpected\": true"
        )

        #expect(
            throws: VoiceASRArtifactError.unexpectedKeys(
                context: "adapter",
                keys: ["unexpected"]
            )
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(Data(json.utf8))
        }
    }

    @Test("escaped and literal spellings of one key still count as duplicates")
    func escapedDuplicateJSONKeyIsRejected() {
        let json = Self.validManifestJSON().replacingOccurrences(
            of: "\"artifact_id\": \"sherpa-zipformer-zh-en-int8-v1\",",
            with: """
                "artifact_id": "sherpa-zipformer-zh-en-int8-v1",
                "artifact_\\u0069d": "other-artifact",
                """
        )

        #expect(
            throws: VoiceASRArtifactError.duplicateJSONKey("artifact_id")
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(Data(json.utf8))
        }
    }

    @Test("schema and artifact type are fixed contract constants")
    func schemaAndArtifactTypeAreFixed() {
        let wrongSchema = Self.validManifestJSON().replacingOccurrences(
            of: "\"schema_version\": 2",
            with: "\"schema_version\": 1"
        )
        #expect(throws: VoiceASRArtifactError.unsupportedSchema(1)) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(wrongSchema.utf8)
            )
        }

        let unsafeArtifactID = Self.validManifestJSON().replacingOccurrences(
            of: "\"artifact_id\": \"sherpa-zipformer-zh-en-int8-v1\"",
            with: "\"artifact_id\": \"../escape\""
        )
        #expect(throws: VoiceASRArtifactError.invalidJSON) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(unsafeArtifactID.utf8)
            )
        }

        let wrongType = Self.validManifestJSON().replacingOccurrences(
            of: "\"artifact_type\": \"rimeai.voice-asr-model\"",
            with: "\"artifact_type\": \"other\""
        )
        #expect(
            throws: VoiceASRArtifactError.unsupportedArtifactType("other")
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(wrongType.utf8)
            )
        }
    }

    @Test("target, audio, locale, hotword, and N-best claims are bounded")
    func runtimeClaimsAreStrict() {
        let wrongOS = Self.validManifestJSON().replacingOccurrences(
            of: "\"minimum_os_version\": \"14.0\"",
            with: "\"minimum_os_version\": \"15.0\""
        )
        #expect(
            throws: VoiceASRArtifactError.invalidField(
                "target.minimum_os_version"
            )
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(Data(wrongOS.utf8))
        }

        let wrongAudio = Self.validManifestJSON().replacingOccurrences(
            of: "\"sample_rate_hz\": 16000",
            with: "\"sample_rate_hz\": 48000"
        )
        #expect(throws: VoiceASRArtifactError.invalidField("audio")) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(wrongAudio.utf8)
            )
        }

        let duplicateLocale = Self.validManifestJSON().replacingOccurrences(
            of: "[\"en-US\", \"zh-CN\"]",
            with: "[\"zh-CN\", \"zh-CN\"]"
        )
        #expect(throws: VoiceASRArtifactError.invalidField("locales")) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(duplicateLocale.utf8)
            )
        }

        let impossibleHotwords = Self.validManifestJSON()
            .replacingOccurrences(
                of: "\"hotword_mode\": \"bounded-phrase-list\"",
                with: "\"hotword_mode\": \"unsupported\""
            )
        #expect(throws: VoiceASRArtifactError.invalidField("capabilities")) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(impossibleHotwords.utf8)
            )
        }

        let impossibleNBest = Self.validManifestJSON().replacingOccurrences(
            of: "\"maximum_alternatives\": 1",
            with: "\"maximum_alternatives\": 0"
        )
        #expect(throws: VoiceASRArtifactError.invalidField("capabilities")) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(impossibleNBest.utf8)
            )
        }
    }

    @Test("sherpa runtime entrypoints and decoding policy are exact")
    func sherpaRuntimeContractIsStrict() {
        let unknownRuntimeKey = Self.validManifestJSON().replacingOccurrences(
            of: "\"blank_penalty_milli\": 0",
            with: "\"blank_penalty_milli\": 0, \"unexpected\": true"
        )
        #expect(
            throws: VoiceASRArtifactError.unexpectedKeys(
                context: "runtime",
                keys: ["unexpected"]
            )
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(unknownRuntimeKey.utf8)
            )
        }

        let missingEntrypoint = Self.validManifestJSON()
            .replacingOccurrences(
                of: "\"decoder_path\": \"model/decoder.onnx\"",
                with: "\"decoder_path\": \"model/missing.onnx\""
            )
        #expect(throws: VoiceASRArtifactError.invalidField("runtime")) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(missingEntrypoint.utf8)
            )
        }

        let unsupportedDecoder = Self.validManifestJSON()
            .replacingOccurrences(
                of: "\"decoding_method\": \"modified_beam_search\"",
                with: "\"decoding_method\": \"greedy_search\""
            )
        #expect(throws: VoiceASRArtifactError.invalidJSON) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(unsupportedDecoder.utf8)
            )
        }

        let invalidEndpoint = Self.validManifestJSON().replacingOccurrences(
            of: "\"rule1_min_trailing_silence_ms\": 2400",
            with: "\"rule1_min_trailing_silence_ms\": 500"
        )
        #expect(throws: VoiceASRArtifactError.invalidField("runtime")) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(invalidEndpoint.utf8)
            )
        }

        let zeroEndpointDefaults = Self.validManifestJSON()
            .replacingOccurrences(
                of: "\"rule1_min_trailing_silence_ms\": 2400",
                with: "\"rule1_min_trailing_silence_ms\": 0"
            )
            .replacingOccurrences(
                of: "\"rule2_min_trailing_silence_ms\": 1200",
                with: "\"rule2_min_trailing_silence_ms\": 0"
            )
        #expect(throws: VoiceASRArtifactError.invalidField("runtime")) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(zeroEndpointDefaults.utf8)
            )
        }

        let unsafeHotwordProbe = Self.validManifestJSON()
            .replacingOccurrences(
                of: "\"hotword_probe_phrase\": \"RimeAI\"",
                with: "\"hotword_probe_phrase\": \"bad/probe\""
            )
        #expect(throws: VoiceASRArtifactError.invalidField("capabilities")) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(unsafeHotwordProbe.utf8)
            )
        }

        let fakeNBest = Self.validManifestJSON().replacingOccurrences(
            of: "\"maximum_alternatives\": 1",
            with: "\"maximum_alternatives\": 2"
        )
        #expect(throws: VoiceASRArtifactError.invalidField("runtime")) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(fakeNBest.utf8)
            )
        }

        let licenseOverlapsRuntime = Self.validManifestJSON()
            .replacingOccurrences(
                of: "\"license_path\": \"licenses/LICENSE.txt\"",
                with: "\"license_path\": \"model/encoder.onnx\""
            )
        #expect(throws: VoiceASRArtifactError.invalidField("runtime")) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(licenseOverlapsRuntime.utf8)
            )
        }
    }

    @Test("legacy manifest release approval metadata is rejected")
    func legacyManifestApprovalIsRejected() {
        let legacy = Self.validManifestJSON().replacingOccurrences(
            of: "\"source_url\": \"https://example.invalid/model-card\"",
            with: """
            \"source_url\": \"https://example.invalid/model-card\",
            \"redistribution_approved\": true
            """
        )
        #expect(
            throws: VoiceASRArtifactError.unexpectedKeys(
                context: "license",
                keys: ["redistribution_approved"]
            )
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(legacy.utf8)
            )
        }
    }

    @Test("license source must be an HTTPS URL without credentials")
    func licenseSourceContractIsStrict() {
        let onlineRedirect = Self.validManifestJSON().replacingOccurrences(
            of: "https://example.invalid/model-card",
            with: "http://example.invalid/model-card"
        )
        #expect(
            throws: VoiceASRArtifactError.invalidField("license.source_url")
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(onlineRedirect.utf8)
            )
        }
    }

    @Test(
        "inventory paths must be canonical relative POSIX paths",
        arguments: [
            "",
            "/model/encoder.onnx",
            "../model/encoder.onnx",
            "model/../encoder.onnx",
            "./model/encoder.onnx",
            "model//encoder.onnx",
            "model\\encoder.onnx",
            "model/._encoder.onnx",
        ]
    )
    func invalidInventoryPathsAreRejected(path: String) throws {
        let encodedPath = try Self.encodedJSONString(path)
        let json = Self.validManifestJSON().replacingOccurrences(
            of: "\"path\": \"model/encoder.onnx\"",
            with: "\"path\": \(encodedPath)"
        )

        #expect(throws: VoiceASRArtifactError.invalidInventoryPath(path)) {
            _ = try VoiceASRArtifactManifest.decodeStrict(Data(json.utf8))
        }
    }

    @Test("inventory order, uniqueness, size, and hashes are strict")
    func inventoryMetadataIsStrict() {
        let duplicate = Self.validManifestJSON().replacingOccurrences(
            of: "\"path\": \"licenses/NOTICE.txt\"",
            with: "\"path\": \"licenses/LICENSE.txt\""
        )
        #expect(
            throws: VoiceASRArtifactError.duplicateInventoryPath(
                "licenses/LICENSE.txt"
            )
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(duplicate.utf8)
            )
        }

        let unsorted = Self.validManifestJSON()
            .replacingOccurrences(
                of: "\"path\": \"licenses/LICENSE.txt\"",
                with: "\"path\": \"z/LICENSE.txt\""
            )
        #expect(throws: VoiceASRArtifactError.inventoryMustBeSorted) {
            _ = try VoiceASRArtifactManifest.decodeStrict(Data(unsorted.utf8))
        }

        let negativeBytes = Self.validManifestJSON().replacingOccurrences(
            of: "\"bytes\": 4",
            with: "\"bytes\": -1"
        )
        #expect(
            throws: VoiceASRArtifactError.invalidField(
                "inventory.bytes:model/bpe.vocab"
            )
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(negativeBytes.utf8)
            )
        }

        let uppercaseHash = Self.validManifestJSON().replacingOccurrences(
            of: "b1c4c05f286afb2531d4c847c4ca1e56260fc61281b7a04d50e09d09ab7a682b",
            with: "B1C4C05F286AFB2531D4C847C4CA1E56260FC61281B7A04D50E09D09AB7A682B"
        )
        #expect(
            throws: VoiceASRArtifactError.invalidField(
                "inventory.sha256:model/encoder.onnx"
            )
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(uppercaseHash.utf8)
            )
        }
    }

    @Test("manifest, file-count, and total-byte limits fail closed")
    func boundedManifestAndInventory() {
        let data = Data(Self.validManifestJSON().utf8)
        let smallManifestLimit = VoiceASRArtifactVerificationLimits(
            maximumManifestBytes: 10,
            maximumFileCount: 512,
            maximumTotalBytes: 2_147_483_648
        )
        #expect(
            throws: VoiceASRArtifactError.manifestTooLarge(
                maximumBytes: 10,
                actualBytes: data.count
            )
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                data,
                limits: smallManifestLimit
            )
        }

        let smallFileLimit = VoiceASRArtifactVerificationLimits(
            maximumManifestBytes: 1_048_576,
            maximumFileCount: 2,
            maximumTotalBytes: 21
        )
        #expect(
            throws: VoiceASRArtifactError.inventoryFileLimitExceeded(
                maximum: 2,
                actual: 7
            )
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                data,
                limits: smallFileLimit
            )
        }

        let smallByteLimit = VoiceASRArtifactVerificationLimits(
            maximumManifestBytes: 1_048_576,
            maximumFileCount: 7,
            maximumTotalBytes: 48
        )
        #expect(
            throws: VoiceASRArtifactError.inventoryByteLimitExceeded(
                maximum: 48,
                actual: 49
            )
        ) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                data,
                limits: smallByteLimit
            )
        }

        let deepJSON = Data(
            (String(repeating: "[", count: 8)
                + "0"
                + String(repeating: "]", count: 8)).utf8
        )
        let shallowJSONLimit = VoiceASRArtifactVerificationLimits(
            maximumManifestBytes: 1_048_576,
            maximumFileCount: 512,
            maximumTotalBytes: 2_147_483_648,
            maximumJSONDepth: 4
        )
        #expect(throws: VoiceASRArtifactError.JSONResourceLimitExceeded) {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                deepJSON,
                limits: shallowJSONLimit
            )
        }
    }

    @Test("filesystem traversal has depth and total-entry budgets")
    func boundedFilesystemTraversal() throws {
        let depthRoot = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: depthRoot) }
        try FileManager.default.createDirectory(
            at: depthRoot.appendingPathComponent("extra/nested"),
            withIntermediateDirectories: true
        )
        let shallowLimit = VoiceASRArtifactVerificationLimits(
            maximumManifestBytes: 1_048_576,
            maximumFileCount: 512,
            maximumTotalBytes: 2_147_483_648,
            maximumFilesystemDepth: 1
        )
        #expect(
            throws: VoiceASRArtifactError.filesystemDepthLimitExceeded(
                maximum: 1
            )
        ) {
            _ = try VoiceASRArtifactVerifier(limits: shallowLimit)
                .verifyArtifact(at: depthRoot)
        }

        let entryRoot = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: entryRoot) }
        let entryLimit = VoiceASRArtifactVerificationLimits(
            maximumManifestBytes: 1_048_576,
            maximumFileCount: 512,
            maximumTotalBytes: 2_147_483_648,
            maximumFilesystemEntries: 2
        )
        #expect(
            throws: VoiceASRArtifactError.filesystemEntryLimitExceeded(
                maximum: 2
            )
        ) {
            _ = try VoiceASRArtifactVerifier(limits: entryLimit)
                .verifyArtifact(at: entryRoot)
        }
    }

    @Test("declared content digest must match canonical content")
    func contentDigestMismatchIsRejected() {
        let declared = String(repeating: "0", count: 64)
        #expect {
            _ = try VoiceASRArtifactManifest.decodeStrict(
                Data(Self.validManifestJSON(contentSHA256: declared).utf8)
            )
        } throws: { error in
            guard case let VoiceASRArtifactError.contentDigestMismatch(
                expected,
                actual
            ) = error else {
                return false
            }
            return expected == declared
                && actual
                    == "4fa8f1ad946857620cf81ab549cf10e4135962e81eb45758d522e5df62a04504"
        }
    }

    @Test("extra, missing, changed-size, and changed-content files are rejected")
    func exactFilesystemInventoryIsEnforced() throws {
        let extraRoot = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: extraRoot) }
        try Data("extra".utf8).write(
            to: extraRoot.appendingPathComponent("extra.bin")
        )
        #expect(throws: VoiceASRArtifactError.unexpectedFile("extra.bin")) {
            _ = try VoiceASRArtifactVerifier().verifyArtifact(at: extraRoot)
        }

        let missingRoot = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: missingRoot) }
        try FileManager.default.removeItem(
            at: missingRoot.appendingPathComponent("model/encoder.onnx")
        )
        #expect(
            throws: VoiceASRArtifactError.missingFile("model/encoder.onnx")
        ) {
            _ = try VoiceASRArtifactVerifier().verifyArtifact(at: missingRoot)
        }

        let sizeRoot = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: sizeRoot) }
        try Data("changed".utf8).write(
            to: sizeRoot.appendingPathComponent("model/encoder.onnx")
        )
        #expect(
            throws: VoiceASRArtifactError.fileSizeMismatch(
                path: "model/encoder.onnx",
                expected: 8,
                actual: 7
            )
        ) {
            _ = try VoiceASRArtifactVerifier().verifyArtifact(at: sizeRoot)
        }

        let hashRoot = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: hashRoot) }
        try Data("enc0der\n".utf8).write(
            to: hashRoot.appendingPathComponent("model/encoder.onnx")
        )
        #expect {
            _ = try VoiceASRArtifactVerifier().verifyArtifact(at: hashRoot)
        } throws: { error in
            guard case let VoiceASRArtifactError.fileHashMismatch(
                path,
                expected,
                actual
            ) = error else {
                return false
            }
            return path == "model/encoder.onnx"
                && expected
                    == "b1c4c05f286afb2531d4c847c4ca1e56260fc61281b7a04d50e09d09ab7a682b"
                && actual != expected
        }
    }

    @Test("symlinks, special files, AppleDouble, and unexplained directories fail")
    func unsafeFilesystemObjectsAreRejected() throws {
        let symlinkRoot = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: symlinkRoot) }
        let modelPath = symlinkRoot.appendingPathComponent("model/encoder.onnx")
        try FileManager.default.removeItem(at: modelPath)
        try FileManager.default.createSymbolicLink(
            atPath: modelPath.path,
            withDestinationPath: "/dev/null"
        )
        #expect(
            throws: VoiceASRArtifactError.insecureFilesystemEntry(
                "model/encoder.onnx"
            )
        ) {
            _ = try VoiceASRArtifactVerifier().verifyArtifact(at: symlinkRoot)
        }

        let specialRoot = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: specialRoot) }
        let specialPath = specialRoot.appendingPathComponent("unexpected.fifo")
        #expect(mkfifo(specialPath.path, 0o600) == 0)
        #expect(
            throws: VoiceASRArtifactError.unsupportedFilesystemEntry(
                "unexpected.fifo"
            )
        ) {
            _ = try VoiceASRArtifactVerifier().verifyArtifact(at: specialRoot)
        }

        let appleDoubleRoot = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: appleDoubleRoot) }
        try Data().write(
            to: appleDoubleRoot.appendingPathComponent("._manifest.json")
        )
        #expect(
            throws: VoiceASRArtifactError.insecureFilesystemEntry(
                "._manifest.json"
            )
        ) {
            _ = try VoiceASRArtifactVerifier().verifyArtifact(
                at: appleDoubleRoot
            )
        }

        let directoryRoot = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: directoryRoot) }
        try FileManager.default.createDirectory(
            at: directoryRoot.appendingPathComponent("extra"),
            withIntermediateDirectories: false
        )
        #expect(throws: VoiceASRArtifactError.unexpectedFile("extra/")) {
            _ = try VoiceASRArtifactVerifier().verifyArtifact(at: directoryRoot)
        }

        let hardlinkRoot = try Self.makeValidArtifactDirectory()
        let external = hardlinkRoot.deletingLastPathComponent()
            .appendingPathComponent("rimeai-voice-hardlink-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: hardlinkRoot)
            try? FileManager.default.removeItem(at: external)
        }
        try Data("model\n".utf8).write(to: external)
        let hardlinkPath = hardlinkRoot.appendingPathComponent(
            "model/encoder.onnx"
        )
        try FileManager.default.removeItem(at: hardlinkPath)
        #expect(link(external.path, hardlinkPath.path) == 0)
        #expect(
            throws: VoiceASRArtifactError.insecureFilesystemEntry(
                "model/encoder.onnx"
            )
        ) {
            _ = try VoiceASRArtifactVerifier().verifyArtifact(at: hardlinkRoot)
        }

        let writableRoot = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: writableRoot) }
        let writablePath = writableRoot.appendingPathComponent(
            "model/encoder.onnx"
        )
        #expect(chmod(writablePath.path, mode_t(0o666)) == 0)
        #expect(
            throws: VoiceASRArtifactError.insecureFilesystemEntry(
                "model/encoder.onnx"
            )
        ) {
            _ = try VoiceASRArtifactVerifier().verifyArtifact(at: writableRoot)
        }

        let aclRoot = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: aclRoot) }
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = [
            "+a",
            "everyone allow list,search",
            aclRoot.path,
        ]
        chmod.standardOutput = FileHandle.nullDevice
        chmod.standardError = FileHandle.nullDevice
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        #expect(
            throws: VoiceASRArtifactError.insecureFilesystemEntry(".")
        ) {
            _ = try VoiceASRArtifactVerifier().verifyArtifact(at: aclRoot)
        }
    }

    @Test("the verifier is a Sendable injectable seam")
    func verifierSeamIsSendable() throws {
        func requireSendable<T: Sendable>(_: T) {}

        let verifier: any VoiceASRArtifactVerifying = VoiceASRArtifactVerifier()
        requireSendable(verifier)
        let directory = try Self.makeValidArtifactDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try verifier.verifyArtifact(at: directory).verifiedFileCount == 7)

        let concreteVerifier = VoiceASRArtifactVerifier()
        let storeValidator: VoiceASRArtifactValidator = {
            artifactURL, expectedArtifactID in
            #expect(artifactURL.lastPathComponent == expectedArtifactID.rawValue)
            _ = try concreteVerifier.verifyArtifact(at: artifactURL)
        }
        let expectedArtifactID = VoiceASRArtifactID(
            rawValue: directory.lastPathComponent
        )!
        try storeValidator(directory, expectedArtifactID)
    }

    private static func validManifestJSON(
        artifactID: String = "sherpa-zipformer-zh-en-int8-v1",
        contentSHA256: String =
            "4fa8f1ad946857620cf81ab549cf10e4135962e81eb45758d522e5df62a04504"
    ) -> String {
        """
        {
          "schema_version": 2,
          "artifact_type": "rimeai.voice-asr-model",
          "asset_management": "product-managed",
          "artifact_id": "\(artifactID)",
          "adapter": {
            "id": "sherpa-onnx",
            "version": "1.13.6",
            "abi_version": 1
          },
          "model": {
            "id": "icefall-zipformer-zh-en",
            "revision": "2026-08-20",
            "format": "onnx",
            "quantization": "int8"
          },
          "target": {
            "os": "macos",
            "architecture": "arm64",
            "minimum_os_version": "14.0"
          },
          "audio": {
            "sample_rate_hz": 16000,
            "channel_count": 1,
            "sample_format": "float32le",
            "frame_duration_ms": 20
          },
          "runtime": {
            "kind": "sherpa-onnx-online-transducer",
            "encoder_path": "model/encoder.onnx",
            "decoder_path": "model/decoder.onnx",
            "joiner_path": "model/joiner.onnx",
            "tokens_path": "model/tokens.txt",
            "bpe_vocab_path": "model/bpe.vocab",
            "modeling_unit": "cjkchar+bpe",
            "model_type": "zipformer",
            "feature_dimension": 80,
            "provider": "cpu",
            "num_threads": 2,
            "decoding_method": "modified_beam_search",
            "max_active_paths": 4,
            "endpoint": {
              "enabled": true,
              "rule1_min_trailing_silence_ms": 2400,
              "rule2_min_trailing_silence_ms": 1200,
              "rule3_min_utterance_ms": 30000
            },
            "hotword_probe_phrase": "RimeAI",
            "hotwords_score_milli": 1500,
            "blank_penalty_milli": 0
          },
          "network_policy": "offline",
          "locales": ["en-US", "zh-CN"],
          "capabilities": {
            "streaming": true,
            "partial_results": true,
            "endpoint_detection": true,
            "hotword_mode": "bounded-phrase-list",
            "maximum_hotwords": 32,
            "maximum_alternatives": 1
          },
          "license": {
            "spdx_id": "Apache-2.0",
            "license_path": "licenses/LICENSE.txt",
            "notice_path": "licenses/NOTICE.txt",
            "source_url": "https://example.invalid/model-card"
          },
          "inventory": [
            {
              "path": "licenses/LICENSE.txt",
              "bytes": 8,
              "sha256": "c0c56958ef8be5c1979366896b7e0c7206949a5aa2b23f51429c7f56b10990d3"
            },
            {
              "path": "licenses/NOTICE.txt",
              "bytes": 7,
              "sha256": "5de37b4c620461f2b695f1cf6b8ee36e7d025da8334a3693c4ed9aa48a5c7d6a"
            },
            {
              "path": "model/bpe.vocab",
              "bytes": 4,
              "sha256": "9b40808e3407521a22ecb18c10da26933cbcd86dfd2ad844ce69fe961025e4f3"
            },
            {
              "path": "model/decoder.onnx",
              "bytes": 8,
              "sha256": "eacbeef293be61f2a85d929cadb4cbb5248c8b8a1478b3d4b3180ea365d5e687"
            },
            {
              "path": "model/encoder.onnx",
              "bytes": 8,
              "sha256": "b1c4c05f286afb2531d4c847c4ca1e56260fc61281b7a04d50e09d09ab7a682b"
            },
            {
              "path": "model/joiner.onnx",
              "bytes": 7,
              "sha256": "8e7fda7c0958b448ed92d9b9bbf8f04f6423097f39eb007ca5c56f4a9657c340"
            },
            {
              "path": "model/tokens.txt",
              "bytes": 7,
              "sha256": "2de8bce5133f08dc3ebb75abcb1ef6c0951800ee3ae8ca06fcf58395d1244218"
            }
          ],
          "content_sha256": "\(contentSHA256)"
        }
        """
    }

    private static func makeValidArtifactDirectory(
        artifactID: String = "sherpa-zipformer-zh-en-int8-v1"
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rimeai-voice-artifact-\(UUID().uuidString)",
                isDirectory: true
            )
        let licenses = root.appendingPathComponent(
            "licenses",
            isDirectory: true
        )
        let model = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: licenses,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: model,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("license\n".utf8).write(
            to: licenses.appendingPathComponent("LICENSE.txt")
        )
        try Data("notice\n".utf8).write(
            to: licenses.appendingPathComponent("NOTICE.txt")
        )
        try Data("encoder\n".utf8).write(
            to: model.appendingPathComponent("encoder.onnx")
        )
        try Data("decoder\n".utf8).write(
            to: model.appendingPathComponent("decoder.onnx")
        )
        try Data("joiner\n".utf8).write(
            to: model.appendingPathComponent("joiner.onnx")
        )
        try Data("tokens\n".utf8).write(
            to: model.appendingPathComponent("tokens.txt")
        )
        try Data("bpe\n".utf8).write(
            to: model.appendingPathComponent("bpe.vocab")
        )
        let placeholderDigest = String(repeating: "0", count: 64)
        let provisionalJSON = validManifestJSON(
            artifactID: artifactID,
            contentSHA256: placeholderDigest
        )
        let provisionalManifest = try VoiceASRArtifactManifest.decodeStrict(
            Data(provisionalJSON.utf8),
            verifyContentDigest: false
        )
        try Data(validManifestJSON(
            artifactID: artifactID,
            contentSHA256: provisionalManifest.calculatedContentSHA256
        ).utf8).write(
            to: root.appendingPathComponent("manifest.json")
        )
        #expect(chmod(root.path, mode_t(0o700)) == 0)
        #expect(chmod(licenses.path, mode_t(0o700)) == 0)
        #expect(chmod(model.path, mode_t(0o700)) == 0)
        for file in [
            licenses.appendingPathComponent("LICENSE.txt"),
            licenses.appendingPathComponent("NOTICE.txt"),
            model.appendingPathComponent("bpe.vocab"),
            model.appendingPathComponent("decoder.onnx"),
            model.appendingPathComponent("encoder.onnx"),
            model.appendingPathComponent("joiner.onnx"),
            model.appendingPathComponent("tokens.txt"),
            root.appendingPathComponent("manifest.json"),
        ] {
            #expect(chmod(file.path, mode_t(0o600)) == 0)
        }
        return root
    }

    private static func encodedJSONString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let result = String(data: data, encoding: .utf8) else {
            throw VoiceASRArtifactError.invalidJSON
        }
        return result
    }
}
