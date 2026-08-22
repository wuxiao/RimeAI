@preconcurrency import AVFoundation
import Foundation
import RimeAIInputCore
@preconcurrency import Speech

enum AppleSpeechAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

protocol AppleSpeechAuthorizationProviding: Sendable {
    func microphoneAuthorizationStatus() -> AppleSpeechAuthorizationState
    func requestMicrophoneAuthorization(
        _ completion: @escaping @Sendable (AppleSpeechAuthorizationState) -> Void
    )

    func speechAuthorizationStatus() -> AppleSpeechAuthorizationState
    func requestSpeechAuthorization(
        _ completion: @escaping @Sendable (AppleSpeechAuthorizationState) -> Void
    )
}

private final class SystemAppleSpeechAuthorizationProvider:
    AppleSpeechAuthorizationProviding,
    @unchecked Sendable
{
    func microphoneAuthorizationStatus() -> AppleSpeechAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .restricted, .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestMicrophoneAuthorization(
        _ completion: @escaping @Sendable (AppleSpeechAuthorizationState) -> Void
    ) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted ? .authorized : .denied)
        }
    }

    func speechAuthorizationStatus() -> AppleSpeechAuthorizationState {
        Self.mapSpeechAuthorization(SFSpeechRecognizer.authorizationStatus())
    }

    func requestSpeechAuthorization(
        _ completion: @escaping @Sendable (AppleSpeechAuthorizationState) -> Void
    ) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(Self.mapSpeechAuthorization(status))
        }
    }

    private static func mapSpeechAuthorization(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> AppleSpeechAuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .restricted, .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }
}

/// Apple Speech on-device 引擎：SFSpeechRecognizer 强制本地识别 +
/// AVAudioEngine 麦克风采集。
///
/// 两项 TCC 权限在采集前分别检查；只有 `.notDetermined` 才请求授权。
/// 任一授权被拒都映射为 `mic_denied`，无有效输入格式或音频引擎无法
/// 启动映射为 `mic_unavailable`。不支持本地识别则返回
/// `asr_engine_error`，绝不静默回退到联网识别。
public final class AppleSpeechEngine: VoiceDictationEngine, @unchecked Sendable {
    public static let adapterDescriptor = VoiceEngineDescriptor.systemManagedProbe(
        adapterID: "apple-speech-ondevice",
        adapterVersion: "1.0.0",
        supportedLocales: ["zh-CN"],
        capabilities: [.localASR, .streaming],
        networkPolicy: .offline,
        audioFormat: .systemNativePCM,
        hotwordMode: .unsupported,
        maximumAlternatives: 1
    )

    public var descriptor: VoiceEngineDescriptor {
        Self.adapterDescriptor
    }

    private struct SessionResources {
        let audioEngine: AVAudioEngine?
        let recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        let recognitionTask: SFSpeechRecognitionTask?
        let inputTapInstalled: Bool
        let maximumDurationWork: DispatchWorkItem?
        let finalizationTimeoutWork: DispatchWorkItem?
    }

    private let authorizationProvider: any AppleSpeechAuthorizationProviding
    private let lock = NSLock()
    private let workQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-helper.apple-speech"
    )
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var inputTapInstalled = false
    private var lastResult: SFSpeechRecognitionResult?
    private var activeRequestID: String?
    private var eventsSink: (@Sendable (VoiceDictationEngineEvent) -> Void)?
    private var maximumDurationWork: DispatchWorkItem?
    private var finalizationTimeoutWork: DispatchWorkItem?
    private var finalizationDeadlineMilliseconds = 1_500
    private var isFinalizing = false

    public convenience init() {
        self.init(authorizationProvider: SystemAppleSpeechAuthorizationProvider())
    }

    init(authorizationProvider: any AppleSpeechAuthorizationProviding) {
        self.authorizationProvider = authorizationProvider
    }

    public func start(
        _ request: VoiceDictationEngineRequest,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {
        lock.lock()
        guard activeRequestID == nil else {
            lock.unlock()
            events(.failed(.asrOverload, retryable: true))
            return
        }
        activeRequestID = request.requestID
        eventsSink = events
        lastResult = nil
        isFinalizing = false
        finalizationDeadlineMilliseconds = max(
            VoiceDictationConstants.minimumDeadlineMilliseconds,
            min(
                request.deadlineMilliseconds,
                VoiceDictationConstants.maximumDeadlineMilliseconds
            )
        )
        lock.unlock()

        authorizeMicrophone(
            requestID: request.requestID,
            maximumDurationMilliseconds: request.maximumDurationMilliseconds
        )
    }

    /// 停止采集但保留识别任务，让 Apple Speech 在协议 deadline 内
    /// 产出 final。deadline 到期时以当前最佳转录收尾；从未产生结果则
    /// 显式返回 `asr_timeout`。
    public func stop(requestID: String) {
        lock.lock()
        guard activeRequestID == requestID, !isFinalizing else {
            lock.unlock()
            return
        }
        isFinalizing = true
        let audioEngine = self.audioEngine
        let recognitionRequest = self.recognitionRequest
        let shouldRemoveTap = inputTapInstalled
        let maximumDurationWork = self.maximumDurationWork
        let deadlineMilliseconds = finalizationDeadlineMilliseconds
        self.audioEngine = nil
        self.recognitionRequest = nil
        inputTapInstalled = false
        self.maximumDurationWork = nil

        let timeoutWork = DispatchWorkItem { [weak self] in
            self?.finishWithBestTranscription(requestID: requestID)
        }
        finalizationTimeoutWork = timeoutWork
        lock.unlock()

        maximumDurationWork?.cancel()
        workQueue.async {
            if shouldRemoveTap {
                audioEngine?.inputNode.removeTap(onBus: 0)
            }
            audioEngine?.stop()
            recognitionRequest?.endAudio()
        }
        workQueue.asyncAfter(
            deadline: .now() + Double(deadlineMilliseconds) / 1_000,
            execute: timeoutWork
        )
    }

    /// cancel 与 stop 的边界不同：cancel 立即丢弃结果并取消 ASR，绝不
    /// 因迟到回调产生 final。
    public func cancel(requestID: String) {
        lock.lock()
        guard activeRequestID == requestID else {
            lock.unlock()
            return
        }
        let resources = takeSessionResourcesLocked()
        activeRequestID = nil
        eventsSink = nil
        lastResult = nil
        isFinalizing = false
        lock.unlock()

        cleanUp(resources, cancelRecognition: true)
    }

    static func isUsableInputFormat(
        channelCount: AVAudioChannelCount,
        sampleRate: Double
    ) -> Bool {
        channelCount > 0 && sampleRate > 0 && sampleRate.isFinite
    }

    // MARK: - Authorization

    private func authorizeMicrophone(
        requestID: String,
        maximumDurationMilliseconds: Int
    ) {
        switch authorizationProvider.microphoneAuthorizationStatus() {
        case .authorized:
            authorizeSpeech(
                requestID: requestID,
                maximumDurationMilliseconds: maximumDurationMilliseconds
            )
        case .denied:
            fail(.micDenied, retryable: false, requestID: requestID)
        case .notDetermined:
            authorizationProvider.requestMicrophoneAuthorization {
                [weak self] status in
                guard let self else {
                    return
                }
                switch status {
                case .authorized:
                    self.authorizeSpeech(
                        requestID: requestID,
                        maximumDurationMilliseconds: maximumDurationMilliseconds
                    )
                case .notDetermined, .denied:
                    self.fail(
                        .micDenied,
                        retryable: false,
                        requestID: requestID
                    )
                }
            }
        }
    }

    private func authorizeSpeech(
        requestID: String,
        maximumDurationMilliseconds: Int
    ) {
        guard isActive(requestID: requestID, allowFinalizing: true) else {
            return
        }
        switch authorizationProvider.speechAuthorizationStatus() {
        case .authorized:
            scheduleRecognitionStart(
                requestID: requestID,
                maximumDurationMilliseconds: maximumDurationMilliseconds
            )
        case .denied:
            fail(.micDenied, retryable: false, requestID: requestID)
        case .notDetermined:
            authorizationProvider.requestSpeechAuthorization {
                [weak self] status in
                guard let self else {
                    return
                }
                switch status {
                case .authorized:
                    self.scheduleRecognitionStart(
                        requestID: requestID,
                        maximumDurationMilliseconds: maximumDurationMilliseconds
                    )
                case .notDetermined, .denied:
                    self.fail(
                        .micDenied,
                        retryable: false,
                        requestID: requestID
                    )
                }
            }
        }
    }

    private func scheduleRecognitionStart(
        requestID: String,
        maximumDurationMilliseconds: Int
    ) {
        guard isActive(requestID: requestID, allowFinalizing: false) else {
            return
        }
        workQueue.async { [weak self] in
            self?.beginRecognition(
                requestID: requestID,
                maximumDurationMilliseconds: maximumDurationMilliseconds
            )
        }
    }

    // MARK: - Recognition

    private func beginRecognition(
        requestID: String,
        maximumDurationMilliseconds: Int
    ) {
        guard isActive(requestID: requestID, allowFinalizing: false) else {
            return
        }

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        guard let recognizer, recognizer.isAvailable else {
            fail(.asrEngineError, retryable: true, requestID: requestID)
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            fail(.asrEngineError, retryable: false, requestID: requestID)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard Self.isUsableInputFormat(
            channelCount: inputFormat.channelCount,
            sampleRate: inputFormat.sampleRate
        ) else {
            fail(.micUnavailable, retryable: false, requestID: requestID)
            return
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 2_048,
            format: inputFormat
        ) { buffer, _ in
            request.append(buffer)
        }

        let task = recognizer.recognitionTask(
            with: request,
            resultHandler: { [weak self] result, error in
                self?.handleRecognitionResult(
                    result,
                    error: error,
                    requestID: requestID
                )
            }
        )
        let durationWork = DispatchWorkItem { [weak self] in
            self?.stop(requestID: requestID)
        }

        lock.lock()
        guard activeRequestID == requestID, !isFinalizing else {
            lock.unlock()
            inputNode.removeTap(onBus: 0)
            request.endAudio()
            task.cancel()
            return
        }
        self.audioEngine = audioEngine
        recognitionRequest = request
        recognitionTask = task
        inputTapInstalled = true
        maximumDurationWork = durationWork
        lock.unlock()

        do {
            try audioEngine.start()
        } catch {
            fail(.micUnavailable, retryable: false, requestID: requestID)
            return
        }

        workQueue.asyncAfter(
            deadline: .now()
                + Double(maximumDurationMilliseconds) / 1_000,
            execute: durationWork
        )
    }

    private func handleRecognitionResult(
        _ result: SFSpeechRecognitionResult?,
        error: Error?,
        requestID: String
    ) {
        guard isActive(requestID: requestID, allowFinalizing: true) else {
            return
        }
        if let result {
            lock.lock()
            guard activeRequestID == requestID else {
                lock.unlock()
                return
            }
            lastResult = result
            lock.unlock()

            let text = result.bestTranscription.formattedString
            let confidence = Self.confidence(for: result)
            if result.isFinal {
                emit(
                    .finished(
                        text: text,
                        confidence: confidence,
                        polishApplied: false
                    ),
                    requestID: requestID
                )
                return
            }
            emit(
                .partial(
                    stableText: text,
                    partialText: "",
                    confidence: confidence
                ),
                requestID: requestID
            )
        }
        if let error {
            let nsError = error as NSError
            if nsError.code == 216 { // kAFAssistantErrorCancelled
                return
            }
            fail(.asrEngineError, retryable: true, requestID: requestID)
        }
    }

    private func finishWithBestTranscription(requestID: String) {
        lock.lock()
        guard activeRequestID == requestID else {
            lock.unlock()
            return
        }
        let result = lastResult
        lock.unlock()

        guard let result else {
            fail(.asrTimeout, retryable: true, requestID: requestID)
            return
        }
        emit(
            .finished(
                text: result.bestTranscription.formattedString,
                confidence: Self.confidence(for: result),
                polishApplied: false
            ),
            requestID: requestID
        )
    }

    private static func confidence(for result: SFSpeechRecognitionResult) -> Double {
        let segments = result.bestTranscription.segments
        guard !segments.isEmpty else {
            return 0
        }
        return segments.map { Double($0.confidence) }.reduce(0, +)
            / Double(segments.count)
    }

    // MARK: - Session lifecycle

    private func isActive(
        requestID: String,
        allowFinalizing: Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeRequestID == requestID && (allowFinalizing || !isFinalizing)
    }

    private func emit(
        _ event: VoiceDictationEngineEvent,
        requestID: String
    ) {
        lock.lock()
        guard activeRequestID == requestID else {
            lock.unlock()
            return
        }
        let sink = eventsSink
        let resources: SessionResources?
        if case .finished = event {
            resources = takeSessionResourcesLocked()
            activeRequestID = nil
            eventsSink = nil
            lastResult = nil
            isFinalizing = false
        } else {
            resources = nil
        }
        lock.unlock()

        sink?(event)
        if let resources {
            cleanUp(resources, cancelRecognition: true)
        }
    }

    private func fail(
        _ code: VoiceDictationErrorCode,
        retryable: Bool,
        requestID: String
    ) {
        lock.lock()
        guard activeRequestID == requestID else {
            lock.unlock()
            return
        }
        let sink = eventsSink
        let resources = takeSessionResourcesLocked()
        activeRequestID = nil
        eventsSink = nil
        lastResult = nil
        isFinalizing = false
        lock.unlock()

        cleanUp(resources, cancelRecognition: true)
        sink?(.failed(code, retryable: retryable))
    }

    /// 仅在持有 `lock` 时调用。
    private func takeSessionResourcesLocked() -> SessionResources {
        let resources = SessionResources(
            audioEngine: audioEngine,
            recognitionRequest: recognitionRequest,
            recognitionTask: recognitionTask,
            inputTapInstalled: inputTapInstalled,
            maximumDurationWork: maximumDurationWork,
            finalizationTimeoutWork: finalizationTimeoutWork
        )
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        inputTapInstalled = false
        maximumDurationWork = nil
        finalizationTimeoutWork = nil
        return resources
    }

    private func cleanUp(
        _ resources: SessionResources,
        cancelRecognition: Bool
    ) {
        resources.maximumDurationWork?.cancel()
        resources.finalizationTimeoutWork?.cancel()
        workQueue.async {
            if resources.inputTapInstalled {
                resources.audioEngine?.inputNode.removeTap(onBus: 0)
            }
            resources.audioEngine?.stop()
            resources.recognitionRequest?.endAudio()
            if cancelRecognition {
                resources.recognitionTask?.cancel()
            }
        }
    }
}
