import Foundation
import Testing
@testable import RimeAIVoiceHelperEngine

// MARK: - Test support

private final class WorkerEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MLXQwen3ASRWorkerEvent] = []

    func append(_ event: MLXQwen3ASRWorkerEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [MLXQwen3ASRWorkerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var terminatedCount: Int {
        snapshot.filter { $0 == .terminated }.count
    }
}

/// 记录被关闭的句柄，并真正关闭它们。
private final class HandleCloseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: [ObjectIdentifier] = []

    func close(_ handle: FileHandle) {
        lock.lock()
        identifiers.append(ObjectIdentifier(handle))
        lock.unlock()
        try? handle.close()
    }

    var closedIdentifiers: Set<ObjectIdentifier> {
        lock.lock()
        defer { lock.unlock() }
        return Set(identifiers)
    }
}

private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        usleep(5_000)
    }
    return condition()
}

/// 伪造的 MLX worker 服务脚本（真实子进程，用 `/bin/zsh` 运行，与生产启动方式一致）。
private enum FakeWorkerScript {
    static let header = """
    print -r -- '{"type":"ready","model_id":"fake","load_ms":0}'

    """

    /// 收到 cancel 后立即退出。
    static let exitOnCancel = header + """
    while IFS= read -r line; do
      case "$line" in
        *'"type":"cancel"'*) exit 3 ;;
        *'"type":"shutdown"'*) exit 0 ;;
      esac
    done

    """

    /// 收到 cancel 后退出，但留下一个子进程把 stdout 再撑 2 秒：
    /// 父进程的 EOF 会迟到，足以覆盖一次 worker 重启。
    static let lingerAfterCancel = header + """
    while IFS= read -r line; do
      case "$line" in
        *'"type":"cancel"'*) ( sleep 2 ) &; exit 3 ;;
        *'"type":"shutdown"'*) exit 0 ;;
      esac
    done

    """

    /// 忽略 SIGTERM 且从不读 stdin：只有 SIGKILL 能结束它。
    static let stubborn = """
    trap '' TERM
    print -r -- '{"type":"ready","model_id":"fake","load_ms":0}'
    exec sleep 60

    """

    /// 从不读 stdin：写入会一直阻塞到管道写满。
    static let stalled = """
    print -r -- '{"type":"ready","model_id":"fake","load_ms":0}'
    exec sleep 60

    """

    /// 先关闭自己的 stdin 再报告就绪：之后的每次写入都是 broken pipe。
    static let closedStdin = """
    exec 0<&-
    print -r -- '{"type":"ready","model_id":"fake","load_ms":0}'
    exec sleep 60

    """

    static func install(_ body: String) throws -> (path: String, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXWorkerTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("fake-worker.sh")
        try ("#!/bin/zsh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return (url.path, directory)
    }
}

private enum WriteOutcome: Equatable {
    case completed
    case failed(SubprocessMLXQwen3ASRWorker.WorkerError)
}

private final class WriteOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: WriteOutcome?

    func set(_ value: WriteOutcome) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: WriteOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite("SubprocessMLXQwen3ASRWorker lifecycle")
struct SubprocessMLXQwen3ASRWorkerTests {
    private func makeWorker(
        script: String,
        closeHandle: @escaping @Sendable (FileHandle) -> Void = { try? $0.close() }
    ) throws -> (worker: SubprocessMLXQwen3ASRWorker, directory: URL) {
        let installed = try FakeWorkerScript.install(script)
        let worker = SubprocessMLXQwen3ASRWorker(
            serviceScriptPath: installed.path,
            modelDirectoryPath: nil,
            closeHandle: closeHandle
        )
        return (worker, installed.directory)
    }

    @Test("natural worker exit closes both pipe handles, resets readiness and reports termination")
    func naturalExitClosesHandles() throws {
        let closed = HandleCloseRecorder()
        let (worker, directory) = try makeWorker(
            script: FakeWorkerScript.exitOnCancel,
            closeHandle: closed.close
        )
        defer { worker.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let events = WorkerEventRecorder()

        try worker.startIfNeeded { events.append($0) }
        #expect(worker.waitUntilReady(timeoutSeconds: 5))
        #expect(worker.isReady)
        // 向已退出 worker 的管道写入不能杀死 helper：SIGPIPE 必须已被进程级忽略。
        #expect(SubprocessMLXQwen3ASRWorker.isBrokenPipeIgnored)
        let stdinHandle = try #require(worker.currentStdinHandle)
        let stdoutHandle = try #require(worker.currentStdoutHandle)

        worker.sendCancel(requestID: "req-1")

        #expect(waitUntil { events.terminatedCount == 1 })
        #expect(!worker.isReady)
        #expect(worker.currentProcess == nil)
        // 两端句柄都被关闭：stdout 由 readLoop 关闭，stdin 排在 writeQueue 上稍后关闭。
        #expect(waitUntil {
            closed.closedIdentifiers.isSuperset(of: [
                ObjectIdentifier(stdinHandle),
                ObjectIdentifier(stdoutHandle),
            ])
        })
        #expect(worker.currentStdinHandle == nil)
        #expect(worker.currentStdoutHandle == nil)
    }

    @Test("a stale EOF from the previous worker never aborts the restarted one")
    func staleEOFDoesNotAbortRestartedWorker() throws {
        let closed = HandleCloseRecorder()
        let (worker, directory) = try makeWorker(
            script: FakeWorkerScript.lingerAfterCancel,
            closeHandle: closed.close
        )
        defer { worker.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let events = WorkerEventRecorder()

        try worker.startIfNeeded { events.append($0) }
        #expect(worker.waitUntilReady(timeoutSeconds: 5))
        let oldProcess = try #require(worker.currentProcess)
        let oldStdout = try #require(worker.currentStdoutHandle)
        let oldStdin = try #require(worker.currentStdinHandle)

        // 旧进程退出，但它的子进程仍占着 stdout：EOF 要 2 秒后才会到达。
        worker.sendCancel(requestID: "req-1")
        #expect(waitUntil { !oldProcess.isRunning })
        #expect(closed.closedIdentifiers.isEmpty)

        // 在旧 EOF 到达之前重启 worker。
        try worker.startIfNeeded { events.append($0) }
        #expect(worker.waitUntilReady(timeoutSeconds: 5))
        let newProcess = try #require(worker.currentProcess)
        #expect(newProcess !== oldProcess)
        let newStdin = try #require(worker.currentStdinHandle)

        // 旧进程迟到的 EOF：只关闭它自己的句柄，不碰新一代 worker 的状态。
        #expect(waitUntil(timeout: 8) {
            closed.closedIdentifiers.contains(ObjectIdentifier(oldStdout))
        })
        #expect(waitUntil {
            closed.closedIdentifiers.contains(ObjectIdentifier(oldStdin))
        })
        #expect(worker.isReady)
        #expect(events.terminatedCount == 0)
        #expect(worker.currentProcess === newProcess)
        #expect(worker.currentStdinHandle === newStdin)
        #expect(!closed.closedIdentifiers.contains(ObjectIdentifier(newStdin)))
    }

    @Test("shutdown never waits and falls back to SIGKILL when SIGTERM is ignored")
    func shutdownFallsBackToSigkill() throws {
        let (worker, directory) = try makeWorker(script: FakeWorkerScript.stubborn)
        defer { try? FileManager.default.removeItem(at: directory) }
        try worker.startIfNeeded { _ in }
        #expect(worker.waitUntilReady(timeoutSeconds: 5))
        let process = try #require(worker.currentProcess)

        let started = Date()
        worker.shutdown()
        // shutdown 立即返回，不等待进程退出。
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(worker.currentProcess == nil)
        #expect(!worker.isReady)

        // 进程忽略 SIGTERM：2 秒后的 SIGKILL 兜底把它结束掉。
        #expect(waitUntil(timeout: 8) { !process.isRunning })
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= SubprocessMLXQwen3ASRWorker.terminationGraceSeconds - 0.2)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
    }

    @Test("shutdown returns at once even while a write is blocked on a full pipe")
    func shutdownDoesNotBlockOnAFullPipe() throws {
        let (worker, directory) = try makeWorker(script: FakeWorkerScript.stalled)
        defer { try? FileManager.default.removeItem(at: directory) }
        try worker.startIfNeeded { _ in }
        #expect(worker.waitUntilReady(timeoutSeconds: 5))

        let box = WriteOutcomeBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var outcome: WriteOutcome = .completed
            do {
                // 每条音频约 8.6 KB；管道缓冲最多 64 KB，写到第 10 条之前必然阻塞。
                for _ in 0 ..< 40 {
                    try worker.sendAudio(
                        requestID: "req-1",
                        samples: Array(repeating: 0, count: 1_600)
                    )
                }
            } catch let error as SubprocessMLXQwen3ASRWorker.WorkerError {
                outcome = .failed(error)
            } catch {
                Issue.record("unexpected error \(error)")
            }
            box.set(outcome)
            finished.signal()
        }

        // 写入线程已经卡在管道上（远超管道容量的数据不可能写完）。
        #expect(finished.wait(timeout: .now() + 0.5) == .timedOut)

        let shutdownStarted = Date()
        worker.shutdown()
        #expect(Date().timeIntervalSince(shutdownStarted) < 1)

        // 进程被终止后，卡住的写入以 writeFailed 返回；调用方线程没有被 SIGPIPE 杀死。
        #expect(finished.wait(timeout: .now() + 8) == .success)
        #expect(box.value == .failed(.writeFailed))
    }

    @Test("writing to a worker that closed stdin fails with writeFailed instead of killing the host")
    func brokenPipeSurfacesAsWriteFailed() throws {
        let (worker, directory) = try makeWorker(script: FakeWorkerScript.closedStdin)
        defer { worker.shutdown(); try? FileManager.default.removeItem(at: directory) }
        try worker.startIfNeeded { _ in }
        #expect(worker.waitUntilReady(timeoutSeconds: 5))
        // 进程仍在运行，只是读端已经关闭：EPIPE 必须变成可捕获的错误。
        #expect(worker.currentProcess?.isRunning == true)

        do {
            try worker.sendStart(requestID: "req-1", hotwords: [])
            Issue.record("expected sendStart to throw writeFailed")
        } catch let error as SubprocessMLXQwen3ASRWorker.WorkerError {
            #expect(error == .writeFailed)
        }
        // 之后的写入同样失败，而不是崩溃或挂起。
        do {
            try worker.sendStop(requestID: "req-1")
            Issue.record("expected sendStop to throw writeFailed")
        } catch let error as SubprocessMLXQwen3ASRWorker.WorkerError {
            #expect(error == .writeFailed)
        }
    }
}
