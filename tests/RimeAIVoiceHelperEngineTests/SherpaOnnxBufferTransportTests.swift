// SECURITY-001 buffer 传输模式回归（hostile same-UID / 重复打开 /
// 清理）。支持 fixture 与 mock runtime 见
// SherpaBackendTestSupport.swift。
import Darwin
import Foundation
import RimeAISherpaOnnxSafeC
import SherpaOnnxC
import Testing
@_spi(RimeAIInternal) import RimeAIVoiceArtifactCore
@testable import RimeAIInputCore
@testable import RimeAIVoiceHelperEngine

// MARK: - SECURITY-001 buffer 模式回归（hostile same-UID / 重复打开 / 清理）

@Suite(.serialized)
struct SherpaOnnxBufferTransportTests {
    @Test("buffer 模式绑定已验证模型字节，pathname 仅作对照")
    func bufferTransportBindsVerifiedBytes() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let recognizer = SherpaBackendFakeRecognizer()
        let runtime = SherpaBackendFakeRuntime(recognizer: recognizer)
        let loader = SherpaOnnxProductBackendLoader(
            runtime: runtime,
            transport: .buffer
        )

        _ = try fixture.load(using: loader)
        let configuration = try #require(runtime.capturedConfiguration)
        #expect(
            configuration.encoderBytes == Data("encoder\n".utf8)
        )
        #expect(
            configuration.decoderBytes == Data("decoder\n".utf8)
        )
        #expect(
            configuration.joinerBytes == Data("joiner\n".utf8)
        )
        #expect(
            configuration.tokensBytes == Data("tokens\n".utf8)
        )
        // pathname 字段保持 manifest 绝对路径（对照），非 snapshot 目录。
        #expect(
            configuration.encoderPath
                == fixture.artifactDirectory.path + "/model/encoder.onnx"
        )
        #expect(runtime.makeRecognizerCount == 1)
        // 无 snapshot 目录残留。
        let parentPath = fixture.artifactDirectory
            .deletingLastPathComponent().path
        let entries = try FileManager.default
            .contentsOfDirectory(atPath: parentPath)
        #expect(
            !entries.contains { $0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test(
        "hostile same-UID 前验后替换 source：bytes 不受影响且后验拒绝"
    )
    func bufferTransportSurvivesHostileSameUidReplacement() async throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let encoderFile = fixture.path("model/encoder.onnx")
        let original = try Data(contentsOf: encoderFile)
        let runtime = SherpaBackendFakeRuntime(
            recognizer: SherpaBackendFakeRecognizer(),
            afterModelReads: { _ in
                // 同 UID 攻击窗口：前验完成、recognizer 构造进行时
                // 原地替换 source 文件。
                try Data("hostile-payload".utf8)
                    .write(to: encoderFile, options: .atomic)
            }
        )
        let loader = SherpaOnnxProductBackendLoader(
            runtime: runtime,
            transport: .buffer
        )

        // 后验（finalize re-hash source files）必须拒绝被替换的 source。
        await #expect(throws: SherpaOnnxProductBackendError.self) {
            _ = try fixture.load(using: loader)
        }
        // captured bytes 是前验时读入的原始字节——hostile 替换不可达
        // 模型字节流（这正是 pathname TOCTOU 窗口的消除证明）。
        let configuration = try #require(runtime.capturedConfiguration)
        #expect(configuration.encoderBytes == original)
        #expect(
            configuration.encoderBytes != Data("hostile-payload".utf8)
        )
        // 无 snapshot 目录残留。
        let parentPath = fixture.artifactDirectory
            .deletingLastPathComponent().path
        let entries = try FileManager.default
            .contentsOfDirectory(atPath: parentPath)
        #expect(
            !entries.contains { $0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
    }

    @Test("重复构造消费同一已验证字节流且互相独立")
    func bufferTransportRepeatedLoadsShareVerifiedBytes() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }
        let runtime = SherpaBackendFakeRuntime(
            recognizer: SherpaBackendFakeRecognizer()
        )
        let loader = SherpaOnnxProductBackendLoader(
            runtime: runtime,
            transport: .buffer
        )

        // 重复 load（等价重复打开/重复构造场景）：每次独立前验 + 独立
        // 字节读取，两次的模型字节一致且与 source 相同。
        _ = try fixture.load(using: loader)
        let first = try #require(runtime.capturedConfiguration)
        _ = try fixture.load(using: loader)
        let second = try #require(runtime.capturedConfiguration)
        #expect(first.encoderBytes == second.encoderBytes)
        #expect(first.decoderBytes == second.decoderBytes)
        #expect(first.joinerBytes == second.joinerBytes)
        #expect(first.tokensBytes == second.tokensBytes)
        #expect(
            first.encoderBytes == Data("encoder\n".utf8)
        )
        #expect(runtime.makeRecognizerCount == 2)
        // source 文件保持原样（单链接、内容未变）。
        for file in fixture.runtimeModelFiles {
            var status = stat()
            #expect(lstat(file.path, &status) == 0)
            #expect(status.st_nlink == 1)
        }
    }

    @Test(
        "buffer 模式坏模型：越过 config 校验、失败于模型字节、无临时产物"
    )
    func bufferTransportRealRuntimeFailsOnModelBytesNotConfig() throws {
        let fixture = try SherpaBackendStoreFixture()
        defer { fixture.remove() }

        // 真 runtime（产品无参构造 = buffer transport）。捕获 native
        // stderr：buffer 模式必须越过上游 config 校验（不得出现
        // tokens_buf 冲突或 "Errors in config!"），在坏模型字节处失败。
        // 若回归为“config 冲突先失败”，本测试必须变红。
        var thrownError: Error?
        let nativeOutput = withCapturedStderr {
            do {
                _ = try fixture.load(
                    using: SherpaOnnxProductBackendLoader()
                )
            } catch {
                thrownError = error
            }
        }
        #expect(thrownError is SherpaOnnxProductBackendError)
        #expect(!nativeOutput.contains("Errors in config!"))
        #expect(
            !nativeOutput.contains("you can not provide a tokens_buf")
        )

        // 无 snapshot 目录、无任何临时产物。
        let parentPath = fixture.artifactDirectory
            .deletingLastPathComponent().path
        let entries = try FileManager.default
            .contentsOfDirectory(atPath: parentPath)
        #expect(
            !entries.contains { $0.hasPrefix(".rimeai-sherpa-runtime-") }
        )
        // source 文件原样保留（单链接、内容未变）。
        for file in fixture.runtimeModelFiles {
            var status = stat()
            #expect(lstat(file.path, &status) == 0)
            #expect(status.st_nlink == 1)
            #expect(
                (try? Data(contentsOf: file)) != nil
            )
        }
    }
}

/// 捕获 fd 2 上的 native 输出（C 层 SHERPA_ONNX_LOGE 走 fprintf
/// stderr）。恢复 fd 后返回窗口内捕获的文本；body 内自行 do/catch，
/// 错误经捕获变量传出。
private func withCapturedStderr(_ body: () -> Void) -> String {
    let path = NSTemporaryDirectory()
        + "rimeai-stderr-\(UUID().uuidString).log"
    let captureDescriptor = Darwin.open(
        path,
        O_RDWR | O_CREAT | O_CLOEXEC,
        0o600
    )
    precondition(captureDescriptor >= 0)
    let savedDescriptor = dup(STDERR_FILENO)
    precondition(savedDescriptor >= 0)
    dup2(captureDescriptor, STDERR_FILENO)
    defer {
        dup2(savedDescriptor, STDERR_FILENO)
        Darwin.close(savedDescriptor)
        Darwin.close(captureDescriptor)
        unlink(path)
    }
    body()
    fflush(nil)
    guard
        let captured = try? String(
            contentsOf: URL(fileURLWithPath: path),
            encoding: .utf8
        )
    else {
        return ""
    }
    return captured
}
