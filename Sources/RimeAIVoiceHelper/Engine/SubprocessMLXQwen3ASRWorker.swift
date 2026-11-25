import Darwin
import Foundation
import RimeAIInputCore

/// Events emitted by the background Python MLX Qwen3-ASR worker process.
enum MLXQwen3ASRWorkerEvent: Equatable, Sendable {
    case ready(modelID: String, loadMilliseconds: Int)
    case partial(
        requestID: String,
        stableText: String,
        partialText: String,
        confidence: Double
    )
    case final(
        requestID: String,
        text: String,
        confidence: Double,
        polishApplied: Bool
    )
    case error(requestID: String, code: VoiceDictationErrorCode)
    case terminated
}

/// Narrow testable interface to the persistent MLX worker subprocess.
protocol MLXQwen3ASRWorkerControlling: AnyObject, Sendable {
    var isReady: Bool { get }
    func startIfNeeded(
        onEvent: @escaping @Sendable (MLXQwen3ASRWorkerEvent) -> Void
    ) throws
    func waitUntilReady(timeoutSeconds: TimeInterval) -> Bool
    func sendStart(requestID: String, hotwords: [String]) throws
    func sendAudio(requestID: String, samples: [Float]) throws
    func sendStop(requestID: String) throws
    func sendCancel(requestID: String)
    func shutdown()
}

/// Launches and supervises `script/voice_mlx_qwen3_asr_service.sh` over
/// private stdin/stdout NDJSON pipes. Never writes audio to disk.
///
/// 管道写入的生命周期约束：worker 可能停滞并停止读取 stdin，此时 `write(2)`
/// 会一直阻塞到管道重新有空间或进程退出。因此
/// - 所有 stdin 写入与 stdin 关闭只在 `writeQueue` 上执行：至多一个线程卡在
///   管道上，`shutdown()` 的调用方与 readLoop 收尾永不被它拖住；
/// - `shutdown()` 从不等待进程退出，只发 SIGTERM 并在 2 秒后 SIGKILL 兜底；
/// - stdout 读端只由 readLoop 线程关闭，进程自然退出时两端句柄都会被关闭，
///   worker 重启不泄漏 fd；
/// - 旧进程迟到的 EOF 不修改新一代 worker 的就绪状态。
final class SubprocessMLXQwen3ASRWorker:
    MLXQwen3ASRWorkerControlling,
    @unchecked Sendable
{
    enum WorkerError: Error, Equatable, Sendable {
        case serviceScriptMissing(String)
        case workerUnavailable
        case writeFailed
    }

    /// `terminate()`（SIGTERM）之后等待进程自行退出的上限；超时即 SIGKILL。
    /// 它只约束后台收尾线程与 readLoop，`shutdown()` 本身从不等待。
    static let terminationGraceSeconds: TimeInterval = 2

    private let serviceScriptPath: String
    private let modelDirectoryPath: String?
    private let lock = NSLock()
    private let readyCondition = NSCondition()
    /// 所有 stdin 写入与 stdin 关闭的唯一执行队列（串行）。关闭句柄与写入在
    /// 同一条队列上互斥：旧句柄绝不会在 fd 编号被新一代 worker 复用后再被写入。
    private let writeQueue = DispatchQueue(
        label: "fun.wwcn.rimeai.voice-helper.mlx-qwen3-asr-worker.write",
        qos: .userInitiated
    )
    /// 关闭文件句柄的实现；测试可以注入记录器，生产环境真正关闭。
    private let closeHandle: @Sendable (FileHandle) -> Void
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var eventHandler: (@Sendable (MLXQwen3ASRWorkerEvent) -> Void)?
    private var _isReady = false
    private var startupFailed = false

    init(
        serviceScriptPath: String = SubprocessMLXQwen3ASRWorker.defaultServiceScriptPath(),
        modelDirectoryPath: String? = ProcessInfo.processInfo.environment["RIMEAI_VOICE_MLX_MODEL_DIR"],
        closeHandle: @escaping @Sendable (FileHandle) -> Void = { handle in
            try? handle.close()
        }
    ) {
        self.serviceScriptPath = serviceScriptPath
        self.modelDirectoryPath = modelDirectoryPath
        self.closeHandle = closeHandle
    }

    deinit {
        shutdown()
    }

    var isReady: Bool {
        readyCondition.lock()
        defer { readyCondition.unlock() }
        return _isReady
    }

    /// 当前这一代 worker 进程（供测试观察退出时机）。
    var currentProcess: Process? {
        lock.lock()
        defer { lock.unlock() }
        return process
    }

    /// 当前这一代进程的管道句柄（供测试验证退出后确实被关闭）。
    var currentStdinHandle: FileHandle? {
        lock.lock()
        defer { lock.unlock() }
        return stdinHandle
    }

    var currentStdoutHandle: FileHandle? {
        lock.lock()
        defer { lock.unlock() }
        return stdoutHandle
    }

    /// SIGPIPE 当前是否已被进程级忽略。
    static var isBrokenPipeIgnored: Bool {
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        return unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
            == unsafeBitCast(SIG_IGN, to: Int.self)
    }

    static func defaultServiceScriptPath() -> String {
        if let env = ProcessInfo.processInfo.environment["RIMEAI_VOICE_MLX_SERVICE_SCRIPT"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return env
        }
        // Fallback for ad-hoc local development invocations.
        let fileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = fileURL
            .deletingLastPathComponent() // Engine
            .deletingLastPathComponent() // RimeAIVoiceHelper
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // project root
        return projectRoot
            .appendingPathComponent("script/voice_mlx_qwen3_asr_service.sh")
            .path
    }

    func startIfNeeded(
        onEvent: @escaping @Sendable (MLXQwen3ASRWorkerEvent) -> Void
    ) throws {
        Self.ensureBrokenPipeIsNotFatal()
        lock.lock()
        eventHandler = onEvent
        if let existing = process, existing.isRunning {
            lock.unlock()
            return
        }
        // 上一代进程已退出但 readLoop 尚未读到 EOF：不复用它的句柄；旧句柄由
        // 旧 readLoop 在退出收尾时关闭（见 finishProcessExit）。
        guard FileManager.default.isExecutableFile(atPath: serviceScriptPath) else {
            lock.unlock()
            throw WorkerError.serviceScriptMissing(serviceScriptPath)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = [serviceScriptPath]
        var env = ProcessInfo.processInfo.environment
        if let modelDirectoryPath, !modelDirectoryPath.isEmpty {
            env["RIMEAI_VOICE_MLX_MODEL_DIR"] = modelDirectoryPath
        }
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // Keep stderr inherited so LaunchAgent log captures startup diagnostics
        // (worker never logs transcripts, audio, or hotwords to stderr).
        proc.standardError = FileHandle.standardError

        readyCondition.lock()
        _isReady = false
        startupFailed = false
        readyCondition.unlock()

        do {
            try proc.run()
        } catch {
            lock.unlock()
            throw WorkerError.workerUnavailable
        }

        process = proc
        let writeHandle = stdinPipe.fileHandleForWriting
        let readHandle = stdoutPipe.fileHandleForReading
        stdinHandle = writeHandle
        stdoutHandle = readHandle
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.readLoop(
                readHandle: readHandle,
                writeHandle: writeHandle,
                process: proc
            )
        }
    }

    func waitUntilReady(timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        readyCondition.lock()
        defer { readyCondition.unlock() }
        while !_isReady && !startupFailed {
            if !readyCondition.wait(until: deadline) {
                break
            }
        }
        return _isReady
    }

    func sendStart(requestID: String, hotwords: [String]) throws {
        let payload: [String: Any] = [
            "type": "start",
            "request_id": requestID,
            "hotwords": hotwords,
        ]
        try writeJSONLine(payload)
    }

    func sendAudio(requestID: String, samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let pcmData = samples.withUnsafeBufferPointer { buffer -> Data in
            Data(
                bytes: buffer.baseAddress!,
                count: buffer.count * MemoryLayout<Float>.size
            )
        }
        let payload: [String: Any] = [
            "type": "audio",
            "request_id": requestID,
            "pcm_b64": pcmData.base64EncodedString(),
        ]
        try writeJSONLine(payload)
    }

    func sendStop(requestID: String) throws {
        let payload: [String: Any] = [
            "type": "stop",
            "request_id": requestID,
        ]
        try writeJSONLine(payload)
    }

    func sendCancel(requestID: String) {
        let payload: [String: Any] = [
            "type": "cancel",
            "request_id": requestID,
        ]
        try? writeJSONLine(payload)
    }

    /// 停止 worker 并释放句柄。绝不阻塞调用方（可能是 `deinit` 或 helper 的
    /// 关停路径），也绝不无限等待进程退出：SIGTERM 之后最多等
    /// `terminationGraceSeconds`，仍存活就 SIGKILL。
    func shutdown() {
        lock.lock()
        let proc = process
        let writeHandle = stdinHandle
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        eventHandler = nil
        lock.unlock()

        readyCondition.lock()
        _isReady = false
        startupFailed = true
        readyCondition.broadcast()
        readyCondition.unlock()

        guard let proc else {
            // 没有在跑的 worker；仍可能有上一代残留的 stdin 写端在等待关闭。
            if let writeHandle {
                writeQueue.async { [closeHandle] in closeHandle(writeHandle) }
            }
            return
        }

        // 1. 尽力发一条优雅关闭并关闭 stdin。它排在在途写入之后，可能要等到
        //    进程退出才能完成——这只占住 writeQueue，不占调用方线程。
        writeQueue.async { [closeHandle] in
            if proc.isRunning, let writeHandle {
                try? writeHandle.write(contentsOf: Self.shutdownLine)
            }
            if let writeHandle {
                closeHandle(writeHandle)
            }
        }

        // 2. 终止进程。stdout 读端不在这里关闭：readLoop 在 EOF 后自行关闭它。
        guard proc.isRunning else { return }
        proc.terminate()
        let killWork = DispatchWorkItem {
            guard proc.isRunning else { return }
            _ = kill(proc.processIdentifier, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.terminationGraceSeconds,
            execute: killWork
        )
    }

    private static let shutdownLine = Data("{\"type\":\"shutdown\"}\n".utf8)

    private func writeJSONLine(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        // 写入在 writeQueue 上串行执行；同步等待以保留 throwing 语义。
        // 即使这里被停滞的 worker 挡住，也只有调用方所在的这一条队列受影响。
        try writeQueue.sync { try self.writeData(data) }
    }

    /// 仅在 writeQueue 上调用。
    private func writeData(_ data: Data) throws {
        lock.lock()
        let handle = stdinHandle
        let running = process?.isRunning == true
        lock.unlock()
        guard running, let handle else {
            throw WorkerError.workerUnavailable
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw WorkerError.writeFailed
        }
    }

    private func readLoop(
        readHandle: FileHandle,
        writeHandle: FileHandle,
        process proc: Process
    ) {
        var buffer = Data()
        while true {
            let chunk = readHandle.availableData
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0 ..< newlineIndex)
                buffer.removeSubrange(0 ... newlineIndex)
                guard !lineData.isEmpty else { continue }
                handleLine(lineData)
            }
        }
        // stdout 已关闭：等进程真正退出。正常情况下它已经退出；shutdown 路径有
        // SIGKILL 兜底。进程关掉 stdout 却赖着不退时不再无限等待，直接强杀。
        let exitDeadline = Date().addingTimeInterval(Self.terminationGraceSeconds)
        while proc.isRunning, Date() < exitDeadline {
            usleep(20_000)
        }
        if proc.isRunning {
            _ = kill(proc.processIdentifier, SIGKILL)
        }
        proc.waitUntilExit()
        // stdout 读端只能由本线程关闭：其他线程并发 close 会让下一次
        // `availableData` 抛出 ObjC 异常并直接终止 helper。
        closeHandle(readHandle)
        finishProcessExit(process: proc, stdin: writeHandle)
    }

    /// 进程退出后的收尾。只有当退出的仍是当前这一代进程时，才修改就绪状态并
    /// 发出 `.terminated`：旧进程迟到的 EOF 绝不能打断新一代 worker 的
    /// `waitUntilReady`，也不能让进行中的会话误报引擎故障。
    private func finishProcessExit(process proc: Process, stdin writeHandle: FileHandle) {
        lock.lock()
        let isCurrentProcess = self.process === proc
        if isCurrentProcess {
            self.process = nil
            self.stdinHandle = nil
            self.stdoutHandle = nil
        }
        let handler = isCurrentProcess ? eventHandler : nil
        lock.unlock()

        if isCurrentProcess {
            readyCondition.lock()
            _isReady = false
            startupFailed = true
            readyCondition.broadcast()
            readyCondition.unlock()
        }
        // stdin 写端在 writeQueue 上关闭：与在途写入互斥。
        writeQueue.async { [closeHandle] in closeHandle(writeHandle) }
        handler?(.terminated)
    }

    /// 向已退出的 worker 管道写入时，内核会向本进程投递 SIGPIPE。XNU 的这个
    /// 信号是进程级的（可能落到任意未屏蔽它的线程），单线程屏蔽挡不住：
    /// 必须在进程级忽略它，`write` 才会以 EPIPE 失败并转成 `writeFailed` /
    /// `asrEngineError`，而不是让整个 voice helper 被杀死。
    /// 幂等；只在当前仍是默认处置时才改写，不覆盖宿主已设置的处理器。
    private static func ensureBrokenPipeIsNotFatal() {
        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        let defaultHandler = unsafeBitCast(SIG_DFL, to: Int.self)
        let currentHandler = unsafeBitCast(
            current.__sigaction_u.__sa_handler,
            to: Int.self
        )
        guard currentHandler == defaultHandler else { return }
        var ignore = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        sigemptyset(&ignore.sa_mask)
        sigaction(SIGPIPE, &ignore, nil)
    }
}

// MARK: - NDJSON line parsing

extension SubprocessMLXQwen3ASRWorker {
    private func handleLine(_ lineData: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = object["type"] as? String
        else {
            return
        }
        let event: MLXQwen3ASRWorkerEvent?
        switch type {
        case "ready":
            let modelID = object["model_id"] as? String ?? "qwen3-asr"
            let loadMs = object["load_ms"] as? Int ?? 0
            readyCondition.lock()
            _isReady = true
            startupFailed = false
            readyCondition.broadcast()
            readyCondition.unlock()
            event = .ready(modelID: modelID, loadMilliseconds: loadMs)
        case "startup_error":
            readyCondition.lock()
            _isReady = false
            startupFailed = true
            readyCondition.broadcast()
            readyCondition.unlock()
            event = .terminated
        case "partial":
            let requestID = object["request_id"] as? String ?? ""
            let stable = object["stable_text"] as? String ?? ""
            let partial = object["partial_text"] as? String ?? ""
            let confidence = (object["confidence"] as? NSNumber)?.doubleValue ?? 0.9
            event = .partial(
                requestID: requestID,
                stableText: stable,
                partialText: partial,
                confidence: confidence
            )
        case "final":
            let requestID = object["request_id"] as? String ?? ""
            let text = object["text"] as? String ?? ""
            let confidence = (object["confidence"] as? NSNumber)?.doubleValue ?? 0.95
            let polishApplied = object["polish_applied"] as? Bool ?? false
            event = .final(
                requestID: requestID,
                text: text,
                confidence: confidence,
                polishApplied: polishApplied
            )
        case "error":
            let requestID = object["request_id"] as? String ?? ""
            let rawCode = object["code"] as? String ?? "asr_engine_error"
            let code = VoiceDictationErrorCode(rawValue: rawCode) ?? .asrEngineError
            event = .error(requestID: requestID, code: code)
        default:
            event = nil
        }
        guard let event else { return }
        lock.lock()
        let handler = eventHandler
        lock.unlock()
        handler?(event)
    }
}
