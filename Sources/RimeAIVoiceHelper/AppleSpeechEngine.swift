@preconcurrency import AVFAudio
import Foundation
import RimeAIInputCore
@preconcurrency import Speech

/// Apple Speech on-device 引擎：SFSpeechRecognizer 强制本地识别 +
/// AVAudioEngine 麦克风采集。
///
/// 证据边界（对齐 docs/VOICE_INPUT_DESIGN.md 第 8 节）：识别路径需要
/// 语音与麦克风 TCC 授权，只能在真实 GUI 会话中验证；当前证据仅
/// 覆盖编译通过与授权/设备不可用时经协议显式报错。授权被拒映射为
/// `mic_denied`（客户端引导系统设置），无输入设备映射为
/// `mic_unavailable`，不支持本地识别的机型映射为 `asr_engine_error`
/// （不能保证离线网络策略时拒绝工作，而不是悄悄上云）。
final class AppleSpeechEngine: VoiceDictationEngine, @unchecked Sendable {
    let engineID = "apple-speech-ondevice"

    private let lock = NSLock()
    private let workQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-helper.apple-speech"
    )
    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastResult: SFSpeechRecognitionResult?
    private var activeRequestID: String?
    private var eventsSink: (@Sendable (VoiceDictationEngineEvent) -> Void)?
    private var maxDurationWork: DispatchWorkItem?

    func start(
        requestID: String,
        mode: VoiceDictationMode,
        deadlineMilliseconds: Int,
        maximumDurationMilliseconds: Int,
        events: @escaping @Sendable (VoiceDictationEngineEvent) -> Void
    ) {
        lock.lock()
        // 引擎互斥：同一麦克风同一时间只服务一个会话。
        guard activeRequestID == nil else {
            lock.unlock()
            events(.failed(.asrOverload, retryable: true))
            return
        }
        activeRequestID = requestID
        eventsSink = events
        lock.unlock()

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else {
                return
            }
            guard status == .authorized else {
                self.fail(.micDenied, retryable: false)
                return
            }
            self.workQueue.async {
                self.beginRecognition(
                    requestID: requestID,
                    maximumDurationMilliseconds: maximumDurationMilliseconds
                )
            }
        }
    }

    func cancel(requestID: String) {
        lock.lock()
        guard activeRequestID == requestID else {
            lock.unlock()
            return
        }
        activeRequestID = nil
        eventsSink = nil
        let audioEngine = self.audioEngine
        let recognitionTask = self.recognitionTask
        let maxDurationWork = self.maxDurationWork
        self.audioEngine = nil
        self.recognitionTask = nil
        self.maxDurationWork = nil
        lock.unlock()

        maxDurationWork?.cancel()
        workQueue.async {
            audioEngine?.stop()
            recognitionTask?.cancel()
        }
    }

    // MARK: - 私有

    private func beginRecognition(
        requestID: String,
        maximumDurationMilliseconds: Int
    ) {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        guard let recognizer, recognizer.isAvailable else {
            fail(.asrEngineError, retryable: true)
            return
        }
        // 离线合同：无法本地识别时拒绝工作，绝不静默上云。
        guard recognizer.supportsOnDeviceRecognition else {
            fail(.asrEngineError, retryable: false)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            fail(.micUnavailable, retryable: false)
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
                self?.handleRecognitionResult(result, error: error)
            }
        )

        lock.lock()
        self.audioEngine = audioEngine
        self.recognitionTask = task
        lock.unlock()

        do {
            try audioEngine.start()
        } catch {
            fail(.micUnavailable, retryable: false)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            // 单段上限：直接以当前最佳转录收尾。
            self?.finishWithBestTranscription()
        }
        maxDurationWork = work
        workQueue.asyncAfter(
            deadline: .now()
                + Double(maximumDurationMilliseconds) / 1_000,
            execute: work
        )
    }

    private func handleRecognitionResult(
        _ result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        if let result {
            lock.lock()
            lastResult = result
            lock.unlock()
            let text = result.bestTranscription.formattedString
            let confidence = result.bestTranscription.segments
                .map { Double($0.confidence) }
                .reduce(0, +)
                / Double(max(result.bestTranscription.segments.count, 1))
            if result.isFinal {
                emit(.finished(
                    text: text,
                    confidence: confidence,
                    polishApplied: false
                ))
                return
            }
            // Apple Speech 的部分结果是整段重写：作为累计 stable 文本。
            emit(.partial(
                stableText: text,
                partialText: "",
                confidence: confidence
            ))
        }
        if let error {
            let nsError = error as NSError
            if nsError.code == 216 { // kAFAssistantErrorCancelled
                // 主动取消：会话已被 ServerCore 关闭，静默即可。
                teardown()
                return
            }
            fail(.asrEngineError, retryable: true)
        }
    }

    private func finishWithBestTranscription() {
        lock.lock()
        let result = lastResult
        lock.unlock()
        guard let result else {
            // 没有任何识别结果：按超时显式失败。
            fail(.asrTimeout, retryable: true)
            return
        }
        emit(.finished(
            text: result.bestTranscription.formattedString,
            confidence: 1,
            polishApplied: false
        ))
    }

    private func emit(_ event: VoiceDictationEngineEvent) {
        lock.lock()
        let sink = eventsSink
        if case .finished = event {
            // final 之后引擎会话结束。
            activeRequestID = nil
            eventsSink = nil
        }
        lock.unlock()
        sink?(event)
        if case .finished = event {
            teardown()
        }
    }

    private func fail(
        _ code: VoiceDictationErrorCode,
        retryable: Bool
    ) {
        lock.lock()
        let sink = eventsSink
        activeRequestID = nil
        eventsSink = nil
        lock.unlock()
        teardown()
        sink?(.failed(code, retryable: retryable))
    }

    private func teardown() {
        lock.lock()
        let audioEngine = self.audioEngine
        let recognitionTask = self.recognitionTask
        let maxDurationWork = self.maxDurationWork
        self.audioEngine = nil
        self.recognitionTask = nil
        self.maxDurationWork = nil
        lock.unlock()
        maxDurationWork?.cancel()
        workQueue.async {
            audioEngine?.stop()
            recognitionTask?.cancel()
        }
    }
}
