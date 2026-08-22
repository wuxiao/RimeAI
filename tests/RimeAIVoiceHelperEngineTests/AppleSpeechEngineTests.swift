import Foundation
import RimeAIInputCore
import Testing
@testable import RimeAIVoiceHelperEngine

private final class AuthorizationProviderDouble:
    AppleSpeechAuthorizationProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let microphoneStatus: AppleSpeechAuthorizationState
    private let microphoneRequestResult: AppleSpeechAuthorizationState
    private let speechStatus: AppleSpeechAuthorizationState
    private let speechRequestResult: AppleSpeechAuthorizationState
    private let deferMicrophoneRequest: Bool
    private var pendingMicrophoneCompletion:
        (@Sendable (AppleSpeechAuthorizationState) -> Void)?
    private(set) var microphoneRequestCount = 0
    private(set) var speechRequestCount = 0

    init(
        microphoneStatus: AppleSpeechAuthorizationState,
        microphoneRequestResult: AppleSpeechAuthorizationState = .denied,
        speechStatus: AppleSpeechAuthorizationState = .authorized,
        speechRequestResult: AppleSpeechAuthorizationState = .denied,
        deferMicrophoneRequest: Bool = false
    ) {
        self.microphoneStatus = microphoneStatus
        self.microphoneRequestResult = microphoneRequestResult
        self.speechStatus = speechStatus
        self.speechRequestResult = speechRequestResult
        self.deferMicrophoneRequest = deferMicrophoneRequest
    }

    func microphoneAuthorizationStatus() -> AppleSpeechAuthorizationState {
        microphoneStatus
    }

    func requestMicrophoneAuthorization(
        _ completion: @escaping @Sendable (AppleSpeechAuthorizationState) -> Void
    ) {
        lock.lock()
        microphoneRequestCount += 1
        if deferMicrophoneRequest {
            pendingMicrophoneCompletion = completion
            lock.unlock()
            return
        }
        lock.unlock()
        completion(microphoneRequestResult)
    }

    func speechAuthorizationStatus() -> AppleSpeechAuthorizationState {
        speechStatus
    }

    func requestSpeechAuthorization(
        _ completion: @escaping @Sendable (AppleSpeechAuthorizationState) -> Void
    ) {
        lock.lock()
        speechRequestCount += 1
        lock.unlock()
        completion(speechRequestResult)
    }

    var requestCounts: (microphone: Int, speech: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (microphoneRequestCount, speechRequestCount)
    }

    func resolveMicrophoneRequest(
        with status: AppleSpeechAuthorizationState
    ) {
        lock.lock()
        let completion = pendingMicrophoneCompletion
        pendingMicrophoneCompletion = nil
        lock.unlock()
        completion?(status)
    }
}

private final class EngineEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [VoiceDictationEngineEvent] = []

    func append(_ event: VoiceDictationEngineEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [VoiceDictationEngineEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func start(
    _ engine: some VoiceDictationEngine,
    deadlineMilliseconds: Int = 50
) -> EngineEventCollector {
    let collector = EngineEventCollector()
    engine.start(
        VoiceDictationEngineRequest(
            requestID: "permission-test",
            wireRequestID: "permission-test-wire",
            compositionID: "2CAFDFF1-2719-44DC-BCFA-11541314AC76",
            applicationSessionID: "tests#permission",
            bundleID: "com.example.tests",
            mode: .direct,
            deadlineMilliseconds: deadlineMilliseconds,
            maximumDurationMilliseconds: 100
        ),
        events: collector.append
    )
    return collector
}

private func waitUntil(
    _ predicate: @escaping @Sendable () -> Bool
) async -> Bool {
    for _ in 0..<50 {
        if predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
}

@Test
func existingMicrophoneDenialMapsToMicDeniedWithoutRequestingAgain() {
    let provider = AuthorizationProviderDouble(microphoneStatus: .denied)
    let collector = start(AppleSpeechEngine(authorizationProvider: provider))

    #expect(collector.events == [.failed(.micDenied, retryable: false)])
    #expect(provider.requestCounts.microphone == 0)
    #expect(provider.requestCounts.speech == 0)
}

@Test
func undeterminedMicrophonePermissionIsRequestedAndDenialIsMapped() {
    let provider = AuthorizationProviderDouble(
        microphoneStatus: .notDetermined,
        microphoneRequestResult: .denied
    )
    let collector = start(AppleSpeechEngine(authorizationProvider: provider))

    #expect(collector.events == [.failed(.micDenied, retryable: false)])
    #expect(provider.requestCounts.microphone == 1)
    #expect(provider.requestCounts.speech == 0)
}

@Test
func speechDenialAfterMicrophoneAuthorizationFailsClosed() {
    let provider = AuthorizationProviderDouble(
        microphoneStatus: .authorized,
        speechStatus: .denied
    )
    let collector = start(AppleSpeechEngine(authorizationProvider: provider))

    #expect(collector.events == [.failed(.micDenied, retryable: false)])
    #expect(provider.requestCounts.microphone == 0)
    #expect(provider.requestCounts.speech == 0)
}

@Test
func invalidAudioFormatsAreClassifiedAsMicrophoneUnavailable() {
    #expect(!AppleSpeechEngine.isUsableInputFormat(
        channelCount: 0,
        sampleRate: 48_000
    ))
    #expect(!AppleSpeechEngine.isUsableInputFormat(
        channelCount: 1,
        sampleRate: 0
    ))
    #expect(AppleSpeechEngine.isUsableInputFormat(
        channelCount: 1,
        sampleRate: 48_000
    ))
}

@Test
func unavailableStubNeverPretendsToRecognize() {
    let engine = UnavailableVoiceEngine()
    let collector = start(engine)
    #expect(collector.events == [.failed(.micUnavailable, retryable: false)])
    #expect(engine.descriptor.qualification == .unavailable)
    #expect(engine.descriptor.capabilities.isEmpty)
    #expect(engine.descriptor.supportedLocales.isEmpty)
    #expect(engine.descriptor.audioFormat == .unavailable)
    #expect(engine.descriptor.maximumAlternatives == 0)
    #expect(engine.descriptor.advertisedProtocolCapabilities.isEmpty)
    #expect(!engine.descriptor.hasIntegrityVerifiedProductArtifact)

    let ready = VoiceDictationServerCore(engine: engine).readyResponse
    #expect(ready.capabilities.isEmpty)
    #expect(!ready.isCompatible)
}

@Test
func appleSpeechDescriptorAllowsProbeButIsIneligibleForProductRelease() {
    let engine = AppleSpeechEngine(
        authorizationProvider: AuthorizationProviderDouble(
            microphoneStatus: .denied
        )
    )
    let descriptor = engine.descriptor

    #expect(descriptor.adapterID == "apple-speech-ondevice")
    #expect(descriptor.adapterVersion == "1.0.0")
    #expect(descriptor.assetManagement == .systemManaged)
    #expect(descriptor.qualification == .probeOnly)
    #expect(descriptor.artifactID == nil)
    #expect(descriptor.artifactSHA256 == nil)
    #expect(descriptor.supportedLocales == ["zh-CN"])
    #expect(descriptor.capabilities == [.localASR, .streaming])
    #expect(descriptor.audioFormat == .systemNativePCM)
    #expect(descriptor.hotwordMode == .unsupported)
    #expect(descriptor.maximumAlternatives == 1)
    #expect(descriptor.isStructurallyValid)
    #expect(!descriptor.hasIntegrityVerifiedProductArtifact)
    #expect(descriptor.advertisedProtocolCapabilities == [
        "local_asr", "streaming",
    ])

    let ready = VoiceDictationServerCore(engine: engine).readyResponse
    #expect(ready.asrEngineID == "apple-speech-ondevice")
    #expect(ready.networkPolicy == .offline)
    #expect(ready.capabilities == ["local_asr", "streaming"])
    #expect(ready.isCompatible)
}

@Test
func stopWhileAuthorizationIsPendingTimesOutWithoutStartingCapture() async {
    let provider = AuthorizationProviderDouble(
        microphoneStatus: .notDetermined,
        deferMicrophoneRequest: true
    )
    let engine = AppleSpeechEngine(authorizationProvider: provider)
    let collector = start(engine, deadlineMilliseconds: 10)

    engine.stop(requestID: "permission-test")
    #expect(await waitUntil { !collector.events.isEmpty })
    #expect(collector.events == [.failed(.asrTimeout, retryable: true)])

    // 迟到授权回调不得复活已结束会话，也不会进入真实音频路径。
    provider.resolveMicrophoneRequest(with: .authorized)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(collector.events == [.failed(.asrTimeout, retryable: true)])
}

@Test
func cancelWhileAuthorizationIsPendingDropsTheLateAuthorizationCallback() async {
    let provider = AuthorizationProviderDouble(
        microphoneStatus: .notDetermined,
        deferMicrophoneRequest: true
    )
    let engine = AppleSpeechEngine(authorizationProvider: provider)
    let collector = start(engine)

    engine.cancel(requestID: "permission-test")
    provider.resolveMicrophoneRequest(with: .authorized)
    try? await Task.sleep(for: .milliseconds(20))

    #expect(collector.events.isEmpty)
}
