import Foundation
#if canImport(RimeAIVoiceArtifactCore)
import RimeAIVoiceArtifactCore
#endif

/// 语音适配器的资产管理边界。系统管理资产没有产品可验证的制品哈希；
/// 产品管理资产只有在 descriptor 同时携带合法 artifact ID 与 SHA-256 时，
/// 才可能进入发布能力声明。
public enum VoiceEngineAssetManagement: String, Equatable, Sendable {
    case none
    case systemManaged = "system-managed"
    case productManaged = "product-managed"
}

/// descriptor 的证据等级。这里的“完整性已验证”只表示本地 manifest 与
/// inventory/hash 一致，不代表来源签名、许可证、质量、TCC、no-INET 或
/// 公证等 Release gate 已通过。
public enum VoiceEngineQualification: String, Equatable, Sendable {
    case unavailable
    case probeOnly = "probe-only"
    case integrityVerifiedProductArtifact = "integrity-verified-product-artifact"
}

/// 与协议 V2 `voice_ready.capabilities` 一一对应的已知能力。
public enum VoiceEngineCapability: String, CaseIterable, Equatable, Sendable {
    case localASR = "local_asr"
    case cloudASR = "cloud_asr"
    case streaming
    case polish
    case hotwordSnapshot = "hotword_snapshot"
}

/// 适配器实际接收的音频合同。Apple Speech 直接消费系统麦克风的原生 PCM，
/// 因而不能伪造一个固定采样率或声道数。
public enum VoiceEngineAudioFormat: Equatable, Sendable {
    case unavailable
    case systemNativePCM
    case fixedLinearPCM(
        sampleRateHertz: Int,
        channelCount: Int,
        bitsPerChannel: Int
    )

    fileprivate var isValid: Bool {
        switch self {
        case .unavailable, .systemNativePCM:
            return true
        case let .fixedLinearPCM(sampleRate, channels, bits):
            return sampleRate > 0 && channels > 0 && bits > 0
        }
    }
}

public enum VoiceEngineHotwordMode: Equatable, Sendable {
    case unsupported
    case boundedPhraseList(maximumEntries: Int)

    fileprivate var isValid: Bool {
        switch self {
        case .unsupported:
            return true
        case let .boundedPhraseList(maximumEntries):
            return maximumEntries > 0
        }
    }
}

/// Facts observed only after the concrete product backend has constructed a
/// recognizer and completed its non-empty hotword-capacity probe followed by a
/// fresh empty-stream probe. The descriptor factory intersects these facts with
/// the verified manifest instead of trusting either source alone.
public struct VoiceProductEngineLoadProbe: Equatable, Sendable {
    public let artifactGeneration: UUID
    public let adapterID: String
    public let adapterVersion: String
    public let adapterABIVersion: Int
    public let runtimeKind: VoiceASRArtifactManifest.Runtime.Kind
    public let supportedLocales: Set<String>
    public let supportsStreaming: Bool
    public let supportsPartialResults: Bool
    public let supportsEndpointDetection: Bool
    public let maximumHotwords: Int
    public let maximumAlternatives: Int
    public let sampleRateHertz: Int
    public let channelCount: Int
    public let bitsPerChannel: Int

    public init(
        artifactGeneration: UUID,
        adapterID: String,
        adapterVersion: String,
        adapterABIVersion: Int,
        runtimeKind: VoiceASRArtifactManifest.Runtime.Kind,
        supportedLocales: Set<String>,
        supportsStreaming: Bool,
        supportsPartialResults: Bool,
        supportsEndpointDetection: Bool,
        maximumHotwords: Int,
        maximumAlternatives: Int,
        sampleRateHertz: Int,
        channelCount: Int,
        bitsPerChannel: Int
    ) {
        self.artifactGeneration = artifactGeneration
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.adapterABIVersion = adapterABIVersion
        self.runtimeKind = runtimeKind
        self.supportedLocales = supportedLocales
        self.supportsStreaming = supportsStreaming
        self.supportsPartialResults = supportsPartialResults
        self.supportsEndpointDetection = supportsEndpointDetection
        self.maximumHotwords = maximumHotwords
        self.maximumAlternatives = maximumAlternatives
        self.sampleRateHertz = sampleRateHertz
        self.channelCount = channelCount
        self.bitsPerChannel = bitsPerChannel
    }
}

public enum VoiceProductEngineDescriptorError: Error, Equatable, Sendable {
    case artifactGenerationMismatch
    case adapterMismatch
    case runtimeMismatch
    case audioFormatMismatch
    case noSupportedLocale
    case requiredStreamingCapabilityMissing
    case requiredPartialResultsCapabilityMissing
    case requiredEndpointCapabilityMissing
    case requiredHotwordCapabilityMissing
    case alternativesCapabilityMismatch
    case invalidDescriptor
}

/// 不进入 wire 的严格、值语义引擎描述。协议 V2 只发送受约束的能力摘要；
/// `advertisedProtocolCapabilities` 是 ServerCore 的唯一能力来源。
public struct VoiceEngineDescriptor: Equatable, Sendable {
    public let adapterID: String
    public let adapterVersion: String
    public let assetManagement: VoiceEngineAssetManagement
    public let qualification: VoiceEngineQualification
    public let artifactID: VoiceASRArtifactID?
    public let artifactSHA256: String?
    public let artifactGeneration: UUID?
    public let supportedLocales: Set<String>
    public let capabilities: Set<VoiceEngineCapability>
    public let networkPolicy: VoiceNetworkPolicy
    public let audioFormat: VoiceEngineAudioFormat
    public let hotwordMode: VoiceEngineHotwordMode
    public let maximumAlternatives: Int

    init(
        adapterID: String,
        adapterVersion: String,
        assetManagement: VoiceEngineAssetManagement,
        qualification: VoiceEngineQualification,
        artifactID: VoiceASRArtifactID? = nil,
        artifactSHA256: String? = nil,
        artifactGeneration: UUID? = nil,
        supportedLocales: Set<String>,
        capabilities: Set<VoiceEngineCapability>,
        networkPolicy: VoiceNetworkPolicy,
        audioFormat: VoiceEngineAudioFormat,
        hotwordMode: VoiceEngineHotwordMode,
        maximumAlternatives: Int
    ) {
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.assetManagement = assetManagement
        self.qualification = qualification
        self.artifactID = artifactID
        self.artifactSHA256 = artifactSHA256
        self.artifactGeneration = artifactGeneration
        self.supportedLocales = supportedLocales
        self.capabilities = capabilities
        self.networkPolicy = networkPolicy
        self.audioFormat = audioFormat
        self.hotwordMode = hotwordMode
        self.maximumAlternatives = maximumAlternatives
    }

    public static func unavailable(
        adapterID: String,
        adapterVersion: String
    ) -> Self {
        Self(
            adapterID: adapterID,
            adapterVersion: adapterVersion,
            assetManagement: .none,
            qualification: .unavailable,
            supportedLocales: [],
            capabilities: [],
            networkPolicy: .offline,
            audioFormat: .unavailable,
            hotwordMode: .unsupported,
            maximumAlternatives: 0
        )
    }

    /// 系统管理引擎只可作为运行时/V0 探针。该工厂不会产生产品制品证据。
    public static func systemManagedProbe(
        adapterID: String,
        adapterVersion: String,
        supportedLocales: Set<String>,
        capabilities: Set<VoiceEngineCapability>,
        networkPolicy: VoiceNetworkPolicy,
        audioFormat: VoiceEngineAudioFormat,
        hotwordMode: VoiceEngineHotwordMode,
        maximumAlternatives: Int
    ) -> Self {
        Self(
            adapterID: adapterID,
            adapterVersion: adapterVersion,
            assetManagement: .systemManaged,
            qualification: .probeOnly,
            supportedLocales: supportedLocales,
            capabilities: capabilities,
            networkPolicy: networkPolicy,
            audioFormat: audioFormat,
            hotwordMode: hotwordMode,
            maximumAlternatives: maximumAlternatives
        )
    }

    /// The only public product-managed constructor. Callers obtain `lease`
    /// from `VoiceASRArtifactStore.withVerifiedCurrentArtifact` and must create
    /// the concrete recognizer before constructing `loadProbe`.
    public static func productManaged(
        lease: VoiceASRVerifiedArtifactLease,
        loadProbe: VoiceProductEngineLoadProbe
    ) throws -> Self {
        let artifact = lease.artifact
        let manifest = artifact.manifest
        guard loadProbe.artifactGeneration == lease.generation else {
            throw VoiceProductEngineDescriptorError
                .artifactGenerationMismatch
        }
        guard loadProbe.adapterID == manifest.adapter.id,
              loadProbe.adapterVersion == manifest.adapter.version,
              loadProbe.adapterABIVersion == manifest.adapter.abiVersion
        else {
            throw VoiceProductEngineDescriptorError.adapterMismatch
        }
        guard loadProbe.runtimeKind == manifest.runtime.kind else {
            throw VoiceProductEngineDescriptorError.runtimeMismatch
        }
        guard loadProbe.sampleRateHertz == manifest.audio.sampleRateHertz,
              loadProbe.channelCount == manifest.audio.channelCount,
              loadProbe.bitsPerChannel == 32
        else {
            throw VoiceProductEngineDescriptorError.audioFormatMismatch
        }
        let locales = Set(manifest.locales).intersection(
            loadProbe.supportedLocales
        )
        guard !locales.isEmpty else {
            throw VoiceProductEngineDescriptorError.noSupportedLocale
        }
        guard manifest.capabilities.streaming,
              loadProbe.supportsStreaming
        else {
            throw VoiceProductEngineDescriptorError
                .requiredStreamingCapabilityMissing
        }
        guard manifest.capabilities.partialResults,
              loadProbe.supportsPartialResults
        else {
            throw VoiceProductEngineDescriptorError
                .requiredPartialResultsCapabilityMissing
        }
        guard manifest.capabilities.endpointDetection,
              loadProbe.supportsEndpointDetection
        else {
            throw VoiceProductEngineDescriptorError
                .requiredEndpointCapabilityMissing
        }
        let maximumHotwords = min(
            manifest.capabilities.maximumHotwords,
            loadProbe.maximumHotwords
        )
        guard manifest.capabilities.hotwordMode == .boundedPhraseList,
              maximumHotwords > 0
        else {
            throw VoiceProductEngineDescriptorError
                .requiredHotwordCapabilityMissing
        }
        let maximumAlternatives = min(
            manifest.capabilities.maximumAlternatives,
            loadProbe.maximumAlternatives
        )
        guard maximumAlternatives == 1 else {
            throw VoiceProductEngineDescriptorError
                .alternativesCapabilityMismatch
        }

        let descriptor = Self(
            adapterID: manifest.adapter.id,
            adapterVersion: manifest.adapter.version,
            assetManagement: .productManaged,
            qualification: .integrityVerifiedProductArtifact,
            artifactID: manifest.artifactID,
            artifactSHA256: artifact.contentSHA256,
            artifactGeneration: lease.generation,
            supportedLocales: locales,
            capabilities: [.localASR, .streaming, .hotwordSnapshot],
            networkPolicy: .offline,
            audioFormat: .fixedLinearPCM(
                sampleRateHertz: manifest.audio.sampleRateHertz,
                channelCount: manifest.audio.channelCount,
                bitsPerChannel: 32
            ),
            hotwordMode: .boundedPhraseList(
                maximumEntries: maximumHotwords
            ),
            maximumAlternatives: maximumAlternatives
        )
        guard descriptor.isStructurallyValid else {
            throw VoiceProductEngineDescriptorError.invalidDescriptor
        }
        return descriptor
    }

    /// descriptor 本身可由测试或未来适配器构造，因此消费方必须先验证，
    /// 不能只依赖类型名称推断它已有发布证据。
    public var isStructurallyValid: Bool {
        guard Self.isBoundedIdentifier(adapterID),
              Self.isBoundedVersion(adapterVersion),
              supportedLocales.allSatisfy(Self.isLocaleIdentifier),
              audioFormat.isValid,
              hotwordMode.isValid,
              (0 ... 8).contains(maximumAlternatives),
              (artifactID == nil) == (artifactSHA256 == nil),
              (artifactID == nil) == (artifactGeneration == nil)
        else {
            return false
        }

        if artifactID != nil, let artifactSHA256 {
            guard Self.isSHA256(artifactSHA256)
            else {
                return false
            }
        }

        let hasASR = capabilities.contains(.localASR)
            || capabilities.contains(.cloudASR)
        guard (!capabilities.contains(.streaming) || hasASR),
              (!capabilities.contains(.polish) || hasASR),
              (!capabilities.contains(.hotwordSnapshot) || hasASR)
        else {
            return false
        }
        switch hotwordMode {
        case .unsupported:
            guard !capabilities.contains(.hotwordSnapshot) else {
                return false
            }
        case .boundedPhraseList:
            guard capabilities.contains(.hotwordSnapshot) else {
                return false
            }
        }
        switch networkPolicy {
        case .offline:
            guard !capabilities.contains(.cloudASR) else { return false }
        case .cloudASROnly:
            guard capabilities.contains(.cloudASR),
                  !capabilities.contains(.localASR),
                  !capabilities.contains(.polish)
            else { return false }
        case .cloudASRAndPolish:
            guard hasASR,
                  capabilities.contains(.polish)
            else { return false }
        }

        switch qualification {
        case .unavailable:
            return assetManagement == .none
                && artifactID == nil
                && supportedLocales.isEmpty
                && capabilities.isEmpty
                && audioFormat == .unavailable
                && hotwordMode == .unsupported
                && maximumAlternatives == 0
        case .probeOnly:
            return assetManagement != .none
                && artifactID == nil
                && artifactSHA256 == nil
                && hasASR
                && maximumAlternatives > 0
                && !supportedLocales.isEmpty
                && audioFormat != .unavailable
        case .integrityVerifiedProductArtifact:
            return hasIntegrityVerifiedProductArtifact
                && networkPolicy == .offline
                && capabilities.contains(.localASR)
                && !capabilities.contains(.cloudASR)
                && maximumAlternatives > 0
                && !supportedLocales.isEmpty
                && audioFormat != .unavailable
        }
    }

    public var hasIntegrityVerifiedProductArtifact: Bool {
        qualification == .integrityVerifiedProductArtifact
            && assetManagement == .productManaged
            && artifactID != nil
            && artifactSHA256.map(Self.isSHA256) == true
            && artifactGeneration != nil
    }

    /// Stable wire identity for one immutable product artifact. The random
    /// generation stays process-local; the digest prefix lets diagnostics and
    /// final results distinguish model revisions across helper restarts.
    public var protocolEngineID: String {
        guard let artifactSHA256 else { return adapterID }
        let digest = String(artifactSHA256.prefix(16))
        let candidate = "\(adapterID)@\(digest)"
        return candidate.utf8.count <= 128 ? candidate : "product@\(digest)"
    }

    /// 协议 V2 广播的是运行时真实能力。系统管理的 probe-only 适配器仍须
    /// 广播其实际能力，才能完成 V0/TCC 探针；只有声称使用产品管理资产、
    /// 却没有已验证 artifact 的适配器必须被抑制 `local_asr`。过滤后没有
    /// ASR 时，streaming/polish 也没有独立语义，必须一并移除。
    public var advertisedProtocolCapabilities: [String] {
        guard isStructurallyValid else {
            return []
        }
        var advertised = capabilities
        if advertised.contains(.localASR),
           assetManagement == .productManaged,
           !hasIntegrityVerifiedProductArtifact
        {
            advertised.remove(.localASR)
        }
        if !advertised.contains(.localASR), !advertised.contains(.cloudASR) {
            advertised.remove(.streaming)
            advertised.remove(.polish)
            advertised.remove(.hotwordSnapshot)
        }
        return advertised.map(\.rawValue).sorted()
    }

    public var advertisedMaximumHotwords: Int {
        guard advertisedProtocolCapabilities.contains(
            VoiceEngineCapability.hotwordSnapshot.rawValue
        ) else {
            return 0
        }
        guard case let .boundedPhraseList(maximumEntries) = hotwordMode else {
            return 0
        }
        return min(
            maximumEntries,
            VoiceDictationConstants.maximumHotwordCount
        )
    }

    private static func isBoundedIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
        }
    }

    private static func isBoundedVersion(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
            && !value.contains("\n") && !value.contains("\r")
    }

    private static func isLocaleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 35 else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x61 && byte <= 0x66)
        }
    }
}
