import CoreAudio
import XCTest
@testable import RimeAIInputMethod

/// 语音输入期间自动静音的崩溃安全：先持久化再静音、恢复成功才清除、
/// 崩溃后自动恢复 24 小时内的遗留状态。
@MainActor
final class VoiceSystemAudioMuterTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        suites = []
        super.tearDown()
    }

    // MARK: - Test Doubles

    private final class DeviceControl {
        let log = Log()
        var events: [String] { log.events }
        var deviceID: AudioDeviceID? = 77
        var muteSettable = true
        var muted = false
        /// 模拟恢复失败（如设备暂时不可用）。
        var failsToUnmute = false
        var failsToMute = false
        var volumeSettableElements: Set<AudioObjectPropertyElement> = [
            kAudioObjectPropertyElementMain, 1,
        ]
        var volumes: [AudioObjectPropertyElement: Float32] = [
            kAudioObjectPropertyElementMain: 0.8,
            1: 0.4,
        ]

        var control: VoiceSystemAudioDeviceControl {
            DeviceControl.make(self)
        }

        private static func make(_ owner: DeviceControl) -> VoiceSystemAudioDeviceControl {
            VoiceSystemAudioDeviceControl(
                defaultOutputDeviceID: { owner.log.events.append("defaultDevice"); return owner.deviceID },
                isMuteSettable: { _ in owner.log.events.append("isMuteSettable"); return owner.muteSettable },
                getMute: { _ in owner.log.events.append("getMute"); return owner.muted },
                setMute: { deviceID, muted in
                    owner.log.events.append("setMute(\(deviceID), \(muted))")
                    if !muted, owner.failsToUnmute { return false }
                    if muted, owner.failsToMute { return false }
                    owner.muted = muted
                    return true
                },
                isScalarVolumeSettable: { _, element in
                    owner.log.events.append("isVolumeSettable(\(element))")
                    return owner.volumeSettableElements.contains(element)
                },
                getScalarVolume: { _, element in
                    owner.log.events.append("getVolume(\(element))")
                    return owner.volumes[element]
                },
                setScalarVolume: { _, element, volume in
                    owner.log.events.append("setVolume(\(element), \(volume))")
                    owner.volumes[element] = volume
                    return true
                }
            )
        }
    }

    /// 把持久化事件写进与设备控制共享的时间线，才能断言“先持久化再静音”的先后顺序。
    private final class RecordingPersistence: VoiceSystemAudioMutePersisting {
        private let defaults: UserDefaults
        private let log: Log

        init(defaults: UserDefaults, log: Log) {
            self.defaults = defaults
            self.log = log
        }

        func saveMuteSnapshot(_ snapshot: VoiceSystemAudioMuteSnapshot) {
            log.events.append("persist:save")
            defaults.saveMuteSnapshot(snapshot)
        }

        func loadMuteSnapshot() -> VoiceSystemAudioMuteSnapshot? {
            log.events.append("persist:load")
            return defaults.loadMuteSnapshot()
        }

        func clearMuteSnapshot() {
            log.events.append("persist:clear")
            defaults.clearMuteSnapshot()
        }
    }

    private final class Log {
        var events: [String] = []
    }

    private func makePersistence(log: Log) -> (RecordingPersistence, String) {
        let suite = "fun.wwcn.inputmethod.RimeAI.tests.muter.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (RecordingPersistence(defaults: defaults, log: log), suite)
    }

    private func storedSnapshot(suite: String) -> VoiceSystemAudioMuteSnapshot? {
        UserDefaults(suiteName: suite)?.loadMuteSnapshot()
    }

    /// 标准场景：设备可静音、持久化事件进入设备时间线。
    private struct Harness {
        let muter: VoiceSystemAudioMuter
        let device: DeviceControl
        let suite: String
    }

    private func makeMuter(
        configuring device: DeviceControl = DeviceControl()
    ) -> Harness {
        let (persistence, suite) = makePersistence(log: device.log)
        let muter = VoiceSystemAudioMuter(persistence: persistence, control: device.control)
        return Harness(muter: muter, device: device, suite: suite)
    }

    private func muteSnapshot(
        age: TimeInterval = 0,
        volumes: [VoiceSystemAudioMuteSnapshot.SavedVolume] = []
    ) -> VoiceSystemAudioMuteSnapshot {
        VoiceSystemAudioMuteSnapshot(
            deviceID: 77,
            mutedViaMuteProperty: volumes.isEmpty,
            savedVolumes: volumes,
            timestamp: Date(timeIntervalSinceNow: -age)
        )
    }

    // MARK: - Persistence Round-Trip

    func testSnapshotRoundTripsThroughDefaults() throws {
        let (persistence, _) = makePersistence(log: Log())
        let snapshot = VoiceSystemAudioMuteSnapshot(
            deviceID: 42,
            mutedViaMuteProperty: false,
            savedVolumes: [
                .init(element: kAudioObjectPropertyElementMain, volume: 0.5),
                .init(element: 2, volume: 0.25),
            ],
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        persistence.saveMuteSnapshot(snapshot)

        XCTAssertEqual(persistence.loadMuteSnapshot(), snapshot)
        persistence.clearMuteSnapshot()
        XCTAssertNil(persistence.loadMuteSnapshot())
    }

    func testCorruptedPersistedDataIsIgnoredSafely() {
        let (persistence, suite) = makePersistence(log: Log())
        UserDefaults(suiteName: suite)?.set(Data("not json".utf8), forKey: VoiceSystemAudioMuteSnapshot.defaultsKey)

        XCTAssertNil(persistence.loadMuteSnapshot())
    }

    func testRecoverabilityWindowIsTwentyFourHours() {
        XCTAssertFalse(VoiceSystemAudioMuteSnapshot.isRecoverable(nil))
        XCTAssertTrue(VoiceSystemAudioMuteSnapshot.isRecoverable(muteSnapshot()))
        XCTAssertTrue(VoiceSystemAudioMuteSnapshot.isRecoverable(muteSnapshot(age: 23 * 3_600)))
        XCTAssertFalse(VoiceSystemAudioMuteSnapshot.isRecoverable(muteSnapshot(age: 25 * 3_600)))
        // 时钟回拨造成的“未来”快照同样视为可恢复。
        XCTAssertTrue(VoiceSystemAudioMuteSnapshot.isRecoverable(muteSnapshot(age: -600)))
    }

    // MARK: - Persist Before Mute, Clear After Restore

    func testMuteStateIsPersistedBeforeMutingAndClearedAfterRestore() {
        let harness = makeMuter()
        let muter = harness.muter
        let device = harness.device
        let suite = harness.suite

        muter.beginMuting(enabled: true)

        XCTAssertTrue(muter.isCurrentlyMuting)
        XCTAssertTrue(device.muted)
        // 创建时先检查上次会话的遗留状态；随后：读取原状态 → 持久化 → 静音。
        // 崩溃发生在静音之后也有据可恢复。
        XCTAssertEqual(device.events, [
            "persist:load",
            "defaultDevice", "isMuteSettable", "getMute", "persist:save", "setMute(77, true)",
        ])
        XCTAssertEqual(
            storedSnapshot(suite: suite)?.deviceID,
            77,
            "静音生效时持久化里必须已有可恢复的原始状态"
        )

        muter.restoreImmediately()

        XCTAssertFalse(device.muted)
        XCTAssertFalse(muter.isCurrentlyMuting)
        XCTAssertEqual(device.events.suffix(2), ["setMute(77, false)", "persist:clear"])
        XCTAssertNil(storedSnapshot(suite: suite), "只有恢复成功后才清除持久化状态")
    }

    func testUnappliedMuteClearsPersistedState() throws {
        let device = DeviceControl()
        device.failsToMute = true
        device.volumeSettableElements = []
        let harness = makeMuter(configuring: device)
        let muter = harness.muter
        let suite = harness.suite

        muter.beginMuting(enabled: true)

        XCTAssertFalse(muter.isCurrentlyMuting)
        XCTAssertFalse(device.muted)
        // 静音属性写入失败后立即撤销持久化状态，再去探测音量回退。
        let failedMuteIndex = try XCTUnwrap(device.events.firstIndex(of: "setMute(77, true)"))
        let clearIndex = try XCTUnwrap(device.events.lastIndex(of: "persist:clear"))
        XCTAssertEqual(clearIndex, failedMuteIndex + 1, "静音未生效时不得留下悬空的恢复状态")
        XCTAssertFalse(device.events[clearIndex...].contains("persist:save"))
        XCTAssertNil(storedSnapshot(suite: suite))
    }

    func testUserAlreadyMutedLeavesDeviceAndPersistenceUntouched() {
        let preset = DeviceControl()
        preset.muted = true
        let harness = makeMuter(configuring: preset)
        let muter = harness.muter
        let device = harness.device

        muter.beginMuting(enabled: true)
        muter.restoreImmediately()

        XCTAssertFalse(muter.isCurrentlyMuting)
        XCTAssertTrue(device.muted, "结束后绝不能误取消用户自己的静音")
        XCTAssertFalse(device.events.contains { $0.hasPrefix("setMute") })
        XCTAssertFalse(device.events.contains("persist:save"))
    }

    func testVolumeFallbackRestoresTheCapturedElement() {
        // 设备不支持 Mute 属性：主音量元素可用时只归零并恢复主元素。
        let mainOnly = DeviceControl()
        mainOnly.muteSettable = false
        let harness = makeMuter(configuring: mainOnly)
        let mainMuter = harness.muter
        let mainDevice = harness.device
        let mainSuite = harness.suite
        mainMuter.beginMuting(enabled: true)
        XCTAssertEqual(mainDevice.volumes[kAudioObjectPropertyElementMain], 0)
        XCTAssertEqual(mainDevice.volumes[1], 0.4, "主元素可用时不碰其他元素")
        XCTAssertEqual(
            storedSnapshot(suite: mainSuite)?.savedVolumes,
            [.init(element: kAudioObjectPropertyElementMain, volume: 0.8)]
        )
        mainMuter.restoreImmediately()
        XCTAssertEqual(mainDevice.volumes[kAudioObjectPropertyElementMain], 0.8)
        XCTAssertFalse(mainMuter.isCurrentlyMuting)

        // 主元素不可用：回退到下一个可设置的元素。
        let secondary = DeviceControl()
        secondary.muteSettable = false
        secondary.volumeSettableElements = [1]
        let secondaryHarness = makeMuter(configuring: secondary)
        let secondaryMuter = secondaryHarness.muter
        let secondaryDevice = secondaryHarness.device
        secondaryMuter.beginMuting(enabled: true)
        XCTAssertEqual(secondaryDevice.volumes[1], 0)
        secondaryMuter.restoreImmediately()
        XCTAssertEqual(secondaryDevice.volumes[1], 0.4)
    }

    // MARK: - Crash Recovery

    func testCrashRecoveryRestoresRecentSnapshotAndClearsPersistence() {
        let device = DeviceControl()
        let (persistence, suite) = makePersistence(log: device.log)
        persistence.saveMuteSnapshot(muteSnapshot())
        // 模拟崩溃后设备仍处于我们造成的静音。
        device.muted = true

        let muter = VoiceSystemAudioMuter(persistence: persistence, control: device.control)

        XCTAssertFalse(device.muted, "启动时必须自动恢复上次会话遗留的静音")
        XCTAssertFalse(muter.isCurrentlyMuting)
        // 时间线：测试预置快照(persist:save) → 启动时加载 → 恢复 → 清除。
        XCTAssertEqual(
            device.events,
            ["persist:save", "persist:load", "setMute(77, false)", "persist:clear"]
        )
        XCTAssertNil(storedSnapshot(suite: suite))
    }

    func testCrashRecoveryDropsStaleSnapshotWithoutTouchingAudio() {
        let device = DeviceControl()
        let (persistence, suite) = makePersistence(log: device.log)
        persistence.saveMuteSnapshot(muteSnapshot(age: 25 * 3_600))
        device.muted = true

        let muter = VoiceSystemAudioMuter(persistence: persistence, control: device.control)

        XCTAssertTrue(device.muted, "过期快照不得改动当前音频")
        XCTAssertFalse(device.events.contains { $0.hasPrefix("setMute") })
        XCTAssertFalse(muter.isCurrentlyMuting)
        XCTAssertNil(storedSnapshot(suite: suite))
    }

    func testLaunchWithoutPersistedStateIsANoOp() {
        let harness = makeMuter()
        let muter = harness.muter
        let device = harness.device

        XCTAssertFalse(device.events.contains { $0.hasPrefix("setMute") })
        XCTAssertFalse(muter.isCurrentlyMuting)
    }

    // MARK: - Failed Restore Keeps State

    func testFailedRestoreRetainsStateUntilItSucceeds() {
        let harness = makeMuter()
        let muter = harness.muter
        let device = harness.device
        let suite = harness.suite
        muter.beginMuting(enabled: true)

        device.failsToUnmute = true
        muter.restoreImmediately()

        XCTAssertTrue(muter.isCurrentlyMuting, "恢复失败时不得无条件丢弃状态")
        XCTAssertNotNil(storedSnapshot(suite: suite))

        device.failsToUnmute = false
        muter.restoreImmediately()

        XCTAssertFalse(muter.isCurrentlyMuting)
        XCTAssertNil(storedSnapshot(suite: suite))
    }

    func testNewMuteDoesNotStackWhileRestoreKeepsFailing() throws {
        let harness = makeMuter()
        let muter = harness.muter
        let device = harness.device
        let suite = harness.suite
        muter.beginMuting(enabled: true)
        device.failsToUnmute = true
        muter.restoreImmediately()
        let savedBefore = storedSnapshot(suite: suite)

        muter.beginMuting(enabled: true)

        XCTAssertEqual(
            storedSnapshot(suite: suite),
            savedBefore,
            "不得用新的静音状态覆盖尚未恢复的原始状态"
        )
        XCTAssertEqual(device.events.filter { $0 == "setMute(77, true)" }.count, 1)

        // 设备恢复可用后，下一次 beginMuting 先补做恢复，再正常开启新一轮静音。
        device.failsToUnmute = false
        muter.beginMuting(enabled: true)
        let unmuteIndex = try XCTUnwrap(device.events.lastIndex(of: "setMute(77, false)"))
        let lastMuteIndex = try XCTUnwrap(device.events.lastIndex(of: "setMute(77, true)"))
        XCTAssertLessThan(unmuteIndex, lastMuteIndex, "先补做恢复，再开启新一轮静音")
        XCTAssertEqual(device.events.filter { $0 == "setMute(77, true)" }.count, 2)
        XCTAssertTrue(muter.isCurrentlyMuting)
        XCTAssertTrue(device.muted)
    }

    func testExpiredFailedRestoreIsEventuallyAbandoned() {
        let device = DeviceControl()
        let (persistence, suite) = makePersistence(log: device.log)
        var clock = Date()
        let muter = VoiceSystemAudioMuter(
            persistence: persistence,
            control: device.control,
            now: { clock }
        )
        muter.beginMuting(enabled: true)
        device.failsToUnmute = true
        muter.restoreImmediately()
        XCTAssertTrue(muter.isCurrentlyMuting)

        // 26 小时后仍恢复不了：原始状态已不可信，放弃以免永久卡住新会话。
        clock = clock.addingTimeInterval(26 * 3_600)
        muter.restoreImmediately()

        XCTAssertFalse(muter.isCurrentlyMuting)
        XCTAssertNil(storedSnapshot(suite: suite))
    }

    func testDisabledMutingNeverTouchesPersistenceOrAudio() {
        let harness = makeMuter()
        let muter = harness.muter
        let device = harness.device
        let suite = harness.suite
        // 创建时只有一次“是否有遗留状态”的只读检查。
        XCTAssertEqual(device.events, ["persist:load"])

        muter.beginMuting(enabled: false)

        XCTAssertEqual(device.events, ["persist:load"], "关闭自动静音时不得读写设备或持久化")
        XCTAssertNil(storedSnapshot(suite: suite))
        XCTAssertFalse(muter.isCurrentlyMuting)
    }
}
