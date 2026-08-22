import Foundation
@_spi(VoiceArtifactAdmission) import RimeAIInputCore
@_spi(VoiceArtifactAssembly) import RimeAIVoiceHelperEngine

/// Evaluation-only assembly for one explicitly supplied artifact directory.
/// URL selection and verification end here; the helper engine receives only
/// the already-constructed lease through its neutral artifact-assembly SPI.
@_spi(VoiceEvaluation)
public enum SherpaOnnxEvaluationVoiceEngineFactory {
    typealias AdmittedEngineFactory = @Sendable (
        _ lease: VoiceASRVerifiedArtifactLease,
        _ sourceFactory: any VoicePCMSourceFactory,
        _ hotwordProvider: any VoiceHotwordProviding
    ) throws -> any VoiceDictationEngine

#if DEBUG
    public static func makeEngine(
        at artifactDirectory: URL,
        hotwordProvider: any VoiceHotwordProviding =
            RequestVoiceHotwordProvider()
    ) throws -> any VoiceDictationEngine {
        try makeEngine(
            at: artifactDirectory,
            verifier: VoiceASRArtifactVerifier(),
            sourceFactory: AVAudioEnginePCMSourceFactory(),
            hotwordProvider: hotwordProvider,
            admittedEngineFactory: admittedEngine
        )
    }
#endif

    static func makeTracerEngine(
        at artifactDirectory: URL
    ) throws -> any VoiceDictationEngine {
        try makeEngine(
            at: artifactDirectory,
            verifier: VoiceASRArtifactVerifier(),
            sourceFactory: AVAudioEnginePCMSourceFactory(),
            hotwordProvider: RequestVoiceHotwordProvider(),
            admittedEngineFactory: admittedEngine
        )
    }

    @_spi(VoiceEvaluation)
    public static func makeEngine(
        at artifactDirectory: URL,
        sourceFactory: any VoicePCMSourceFactory,
        hotwordProvider: any VoiceHotwordProviding =
            RequestVoiceHotwordProvider()
    ) throws -> any VoiceDictationEngine {
        try makeEngine(
            at: artifactDirectory,
            verifier: VoiceASRArtifactVerifier(),
            sourceFactory: sourceFactory,
            hotwordProvider: hotwordProvider,
            admittedEngineFactory: admittedEngine
        )
    }

    static func makeEngine(
        at artifactDirectory: URL,
        verifier: any VoiceASRArtifactVerifying,
        sourceFactory: any VoicePCMSourceFactory,
        hotwordProvider: any VoiceHotwordProviding,
        admittedEngineFactory: @escaping AdmittedEngineFactory
    ) throws -> any VoiceDictationEngine {
        try VoiceASREvaluationArtifact.withVerifiedArtifact(
            at: artifactDirectory,
            verifier: verifier
        ) { lease in
            try admittedEngineFactory(
                lease,
                sourceFactory,
                hotwordProvider
            )
        }
    }

    private static func admittedEngine(
        lease: VoiceASRVerifiedArtifactLease,
        sourceFactory: any VoicePCMSourceFactory,
        hotwordProvider: any VoiceHotwordProviding
    ) throws -> any VoiceDictationEngine {
        try SherpaOnnxAdmittedArtifactVoiceEngineFactory.makeEngine(
            lease: lease,
            sourceFactory: sourceFactory,
            hotwordProvider: hotwordProvider
        )
    }
}
