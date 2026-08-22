import Foundation
import RimeAIInputCore

enum ProductManagedVoiceEngineBootstrapError:
    Error,
    Equatable,
    Sendable
{
    case artifactGenerationMismatch
}

/// Builds one process-lifetime product recognizer from the Store's selected
/// immutable artifact. Model verification, recognizer construction, and its
/// non-empty hotword-capacity and fresh empty-stream probes all run under the
/// Store lease. Microphone/TCC work starts only later, when
/// `VoiceDictationEngine.start` asks the injected source factory for a
/// per-session source.
struct ProductManagedVoiceEngineBootstrap: Sendable {
    private struct PreparedBackend: Sendable {
        let descriptor: VoiceEngineDescriptor
        let recognizerDriver: any VoiceStreamingRecognizerDriver
    }

    private let store: VoiceASRArtifactStore
    private let backendLoader: any VoiceProductBackendLoading

    init(
        store: VoiceASRArtifactStore,
        backendLoader: any VoiceProductBackendLoading
    ) {
        self.store = store
        self.backendLoader = backendLoader
    }

    func makeEngine(
        sourceFactory: any VoicePCMSourceFactory,
        hotwordProvider: any VoiceHotwordProviding
    ) throws -> ProductStreamingVoiceEngine {
        let prepared = try store.withVerifiedCurrentArtifact { lease in
            let loaded = try backendLoader.load(lease: lease)
            guard loaded.recognizerDriver.artifactGeneration
                    == lease.generation,
                  loaded.loadProbe.artifactGeneration == lease.generation
            else {
                throw ProductManagedVoiceEngineBootstrapError
                    .artifactGenerationMismatch
            }
            let descriptor = try VoiceEngineDescriptor.productManaged(
                lease: lease,
                loadProbe: loaded.loadProbe
            )
            return PreparedBackend(
                descriptor: descriptor,
                recognizerDriver: loaded.recognizerDriver
            )
        }

        return try ProductStreamingVoiceEngine(
            descriptor: prepared.descriptor,
            sourceFactory: sourceFactory,
            recognizerDriver: prepared.recognizerDriver,
            hotwordProvider: hotwordProvider
        )
    }
}
