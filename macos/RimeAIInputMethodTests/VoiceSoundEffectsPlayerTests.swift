import AppKit
import XCTest
@testable import RimeAIInputMethod

/// 交互提示音：关闭时绝不触碰声音加载，开启时每种音效只加载一次并逐次分发。
/// 用程序生成的静音 WAV 作为样本，测试过程不出声。
@MainActor
final class VoiceSoundEffectsPlayerTests: XCTestCase {
    private func silentWAVData(sampleCount: Int = 16, sampleRate: Int = 8_000) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let dataSize = sampleCount * 2
        data.append(Data("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(Data("data".utf8))
        append(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }

    private final class ProviderProbe {
        var requestedKinds: [VoiceSoundEffectKind] = []
        var sample: NSSound?

        var provider: VoiceSoundEffectsPlayer.SoundProvider {
            { [self] kind in
                requestedKinds.append(kind)
                return sample
            }
        }
    }

    func testDisabledNeverTouchesTheSoundProvider() {
        let probe = ProviderProbe()
        probe.sample = NSSound(data: silentWAVData())
        let player = VoiceSoundEffectsPlayer(soundProvider: probe.provider)

        for kind in [VoiceSoundEffectKind.start, .stop, .success, .cancel, .error] {
            player.play(kind, enabled: false)
        }

        XCTAssertTrue(probe.requestedKinds.isEmpty, "关闭提示音时不得加载任何声音")
        XCTAssertTrue(player.playedKinds.isEmpty)
    }

    func testEnabledDispatchesEachKindOncePerPlay() throws {
        let probe = ProviderProbe()
        probe.sample = try XCTUnwrap(NSSound(data: silentWAVData()), "系统应能解析 PCM WAV")
        let player = VoiceSoundEffectsPlayer(soundProvider: probe.provider)

        player.play(.start, enabled: true)
        player.play(.success, enabled: true)
        player.play(.success, enabled: true)

        XCTAssertEqual(player.playedKinds, [.start, .success, .success])
        XCTAssertEqual(
            probe.requestedKinds,
            [.start, .success],
            "同一种音效只加载一次，之后复用模板"
        )
    }

    func testMissingSoundIsIgnoredSafely() {
        let probe = ProviderProbe()
        probe.sample = nil
        let player = VoiceSoundEffectsPlayer(soundProvider: probe.provider)

        player.play(.error, enabled: true)
        player.play(.error, enabled: true)

        XCTAssertTrue(player.playedKinds.isEmpty)
        XCTAssertFalse(probe.requestedKinds.isEmpty)
    }

    func testVolumeMappingIsDistinctAndBounded() {
        for kind in [VoiceSoundEffectKind.start, .stop, .success, .cancel, .error] {
            let volume = VoiceSoundEffectsPlayer.volume(for: kind)
            XCTAssertGreaterThan(volume, 0)
            XCTAssertLessThanOrEqual(volume, 1)
        }
        XCTAssertGreaterThan(
            VoiceSoundEffectsPlayer.volume(for: .start),
            VoiceSoundEffectsPlayer.volume(for: .cancel)
        )
    }

    func testStartLeadInDelayProtectsTheStartSoundFromAutoMute() {
        XCTAssertEqual(VoiceSoundEffectsPlayer.startSoundLeadInMilliseconds, 140)
        XCTAssertGreaterThan(VoiceSoundEffectsPlayer.startSoundLeadInMilliseconds, 0)
    }
}
