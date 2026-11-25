import AppKit
import CoreAudio
import Foundation

/// 崩溃安全的静音状态快照（纯值类型，便于单测与持久化往返）。
struct VoiceSystemAudioMuteSnapshot: Codable, Equatable {
    struct SavedVolume: Codable, Equatable {
        let element: UInt32
        let volume: Float32
    }

    static let defaultsKey = "RimeAIVoiceSystemAudioMuteSnapshot"
    /// 崩溃后自动恢复的最大时限：超过后视为过期状态直接丢弃，
    /// 绝不根据一天前的音量去改动当前音频。
    static let maximumRecoveryAge: TimeInterval = 24 * 60 * 60

    let deviceID: UInt32
    let mutedViaMuteProperty: Bool
    let savedVolumes: [SavedVolume]
    let timestamp: Date

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    static func decode(_ data: Data) -> VoiceSystemAudioMuteSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }

    /// 仅当快照足够新时才允许自动恢复（时钟回拨造成的“未来”时间同样视为可恢复）。
    static func isRecoverable(
        _ snapshot: VoiceSystemAudioMuteSnapshot?,
        now: Date = Date()
    ) -> Bool {
        guard let snapshot else {
            return false
        }
        return now.timeIntervalSince(snapshot.timestamp) <= maximumRecoveryAge
    }
}

/// 静音状态的持久化出口；默认写入 UserDefaults，单测注入独立 suite。
protocol VoiceSystemAudioMutePersisting: AnyObject {
    func saveMuteSnapshot(_ snapshot: VoiceSystemAudioMuteSnapshot)
    func loadMuteSnapshot() -> VoiceSystemAudioMuteSnapshot?
    func clearMuteSnapshot()
}

extension UserDefaults: VoiceSystemAudioMutePersisting {
    func saveMuteSnapshot(_ snapshot: VoiceSystemAudioMuteSnapshot) {
        guard let data = snapshot.encoded() else {
            return
        }
        set(data, forKey: VoiceSystemAudioMuteSnapshot.defaultsKey)
    }

    func loadMuteSnapshot() -> VoiceSystemAudioMuteSnapshot? {
        guard let data = data(forKey: VoiceSystemAudioMuteSnapshot.defaultsKey) else {
            return nil
        }
        return VoiceSystemAudioMuteSnapshot.decode(data)
    }

    func clearMuteSnapshot() {
        removeObject(forKey: VoiceSystemAudioMuteSnapshot.defaultsKey)
    }
}

/// 语音输入期间自动静音系统默认输出设备，并在录音结束/取消/失活/退出时
/// 严格恢复原静音状态或音量。如果用户在开始语音前本就处于静音状态，
/// 结束后不会误取消用户的静音。
///
/// 崩溃安全：原始状态先持久化再静音，只有恢复成功后才清除；进程被杀
/// 或崩溃后，下次启动会发现 24 小时内的未恢复状态并自动恢复。
@MainActor
final class VoiceSystemAudioMuter {
    static let shared = VoiceSystemAudioMuter()

    private struct SavedDeviceState {
        let deviceID: AudioDeviceID
        let mutedViaMuteProperty: Bool
        let savedScalarVolumes: [(element: AudioObjectPropertyElement, volume: Float32)]
        let savedAt: Date

        var snapshot: VoiceSystemAudioMuteSnapshot {
            VoiceSystemAudioMuteSnapshot(
                deviceID: deviceID,
                mutedViaMuteProperty: mutedViaMuteProperty,
                savedVolumes: savedScalarVolumes.map {
                    .init(element: $0.element, volume: $0.volume)
                },
                timestamp: savedAt
            )
        }

        init(snapshot: VoiceSystemAudioMuteSnapshot) {
            deviceID = snapshot.deviceID
            mutedViaMuteProperty = snapshot.mutedViaMuteProperty
            savedScalarVolumes = snapshot.savedVolumes.map {
                (element: $0.element, volume: $0.volume)
            }
            savedAt = snapshot.timestamp
        }

        init(
            deviceID: AudioDeviceID,
            mutedViaMuteProperty: Bool,
            savedScalarVolumes: [(element: AudioObjectPropertyElement, volume: Float32)],
            savedAt: Date = Date()
        ) {
            self.deviceID = deviceID
            self.mutedViaMuteProperty = mutedViaMuteProperty
            self.savedScalarVolumes = savedScalarVolumes
            self.savedAt = savedAt
        }
    }

    private var savedState: SavedDeviceState?
    private var pendingMuteWorkItem: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?
    private let persistence: any VoiceSystemAudioMutePersisting
    private let control: VoiceSystemAudioDeviceControl
    private let now: () -> Date

    private convenience init() {
        self.init(persistence: UserDefaults.standard)
    }

    /// 创建即检查上次会话遗留的静音状态并自动恢复。测试可注入独立
    /// UserDefaults、假设备控制与可控时钟。
    init(
        persistence: any VoiceSystemAudioMutePersisting = UserDefaults.standard,
        control: VoiceSystemAudioDeviceControl? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.persistence = persistence
        // 主 actor 隔离的默认值不能写在默认参数里（默认参数在调用方上下文求值）。
        self.control = control ?? .coreAudio
        self.now = now
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restoreImmediately()
            }
        }
        restorePersistedStateAfterCrash()
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    var isCurrentlyMuting: Bool {
        savedState != nil
    }

    /// 启动静音；可传入短暂延迟，确保“开始录音”提示音完整播完后再静音。
    func beginMuting(
        afterMilliseconds delayMs: Int = 0,
        enabled: Bool = RimeAISettingsStore.shared.voiceMuteSystemAudioEnabled
    ) {
        pendingMuteWorkItem?.cancel()
        pendingMuteWorkItem = nil
        guard enabled else {
            return
        }
        if savedState != nil {
            // 上一轮恢复失败遗留（设备暂时不可用）：先重试恢复；仍失败则
            // 不叠加新的静音，以免覆盖尚未恢复的原始音量。
            restoreImmediately()
            guard savedState == nil else {
                return
            }
        }
        if delayMs <= 0 {
            applyMuteNow()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingMuteWorkItem = nil
                self?.applyMuteNow()
            }
        }
        pendingMuteWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(delayMs),
            execute: work
        )
    }

    /// 立即恢复音频状态并取消尚未生效的延时静音任务。恢复失败时保留
    /// 状态与持久化快照，等待下次重试（设备重新可用），最长保留 24 小时。
    func restoreImmediately() {
        pendingMuteWorkItem?.cancel()
        pendingMuteWorkItem = nil
        guard let state = savedState else {
            return
        }
        if restore(state) {
            // 只有恢复成功才清除持久化状态。
            savedState = nil
            persistence.clearMuteSnapshot()
            return
        }
        retainOrExpireAfterFailedRestore(state)
    }

    // MARK: - Crash Recovery

    private func restorePersistedStateAfterCrash() {
        guard let snapshot = persistence.loadMuteSnapshot() else {
            return
        }
        guard VoiceSystemAudioMuteSnapshot.isRecoverable(snapshot, now: now()) else {
            // 过期状态：绝不根据陈旧快照改动当前音频。
            persistence.clearMuteSnapshot()
            return
        }
        NSLog(
            "[VoiceSystemAudioMuter] 检测到上次会话未恢复的静音状态（device=%u），尝试自动恢复",
            snapshot.deviceID
        )
        savedState = SavedDeviceState(snapshot: snapshot)
        restoreImmediately()
    }

    private func retainOrExpireAfterFailedRestore(_ state: SavedDeviceState) {
        guard !VoiceSystemAudioMuteSnapshot.isRecoverable(state.snapshot, now: now()) else {
            // 恢复失败：保留状态与持久化快照，下次 beginMuting / 退出时重试。
            NSLog(
                "[VoiceSystemAudioMuter] 恢复音频状态失败（device=%u），已保留状态等待重试",
                state.deviceID
            )
            return
        }
        // 超过 24 小时仍未恢复：原始状态已不可信，放弃以免永久卡住新会话。
        NSLog(
            "[VoiceSystemAudioMuter] 遗留静音状态已过期（device=%u），放弃恢复",
            state.deviceID
        )
        savedState = nil
        persistence.clearMuteSnapshot()
    }

    // MARK: - Mute / Restore

    private func applyMuteNow() {
        guard savedState == nil,
              let deviceID = control.defaultOutputDeviceID()
        else {
            return
        }

        // 优先使用系统标准 kAudioDevicePropertyMute
        if control.isMuteSettable(deviceID),
           let currentlyMuted = control.getMute(deviceID)
        {
            // 用户原本已经静音：记录为无需干预，结束时绝不误打开声音。
            guard !currentlyMuted else {
                return
            }
            let muteState = SavedDeviceState(
                deviceID: deviceID,
                mutedViaMuteProperty: true,
                savedScalarVolumes: [],
                savedAt: now()
            )
            if beginTrackedMute(muteState) {
                if control.setMute(deviceID, true) {
                    return
                }
                abandonUnappliedMute()
            }
        }

        // 回退：部分外接 DAC/蓝牙设备不支持 Mute 属性，改用标量音量归零并恢复
        guard let volumeState = volumeFallbackState(deviceID: deviceID),
              beginTrackedMute(volumeState)
        else {
            return
        }
        let applied = volumeState.savedScalarVolumes.map {
            control.setScalarVolume(deviceID, $0.element, 0.0)
        }
        if !applied.contains(true) {
            abandonUnappliedMute()
        }
    }

    private func volumeFallbackState(
        deviceID: AudioDeviceID
    ) -> SavedDeviceState? {
        let candidateElements: [AudioObjectPropertyElement] = [
            kAudioObjectPropertyElementMain,
            1,
            2,
        ]
        var captured: [(AudioObjectPropertyElement, Float32)] = []
        for element in candidateElements {
            guard control.isScalarVolumeSettable(deviceID, element),
                  let volume = control.getScalarVolume(deviceID, element)
            else {
                continue
            }
            captured.append((element, volume))
            if element == kAudioObjectPropertyElementMain {
                break
            }
        }
        guard captured.contains(where: { $0.1 > 0.001 }) else {
            return nil
        }
        return SavedDeviceState(
            deviceID: deviceID,
            mutedViaMuteProperty: false,
            savedScalarVolumes: captured,
            savedAt: now()
        )
    }

    /// 先持久化再应用静音：静音与恢复之间进程崩溃，下次启动仍能恢复。
    /// 返回 false 表示上一轮状态仍未恢复，本次不得叠加。
    private func beginTrackedMute(_ state: SavedDeviceState) -> Bool {
        guard savedState == nil else {
            return false
        }
        savedState = state
        persistence.saveMuteSnapshot(state.snapshot)
        return true
    }

    private func abandonUnappliedMute() {
        savedState = nil
        persistence.clearMuteSnapshot()
    }

    private func restore(_ state: SavedDeviceState) -> Bool {
        if state.mutedViaMuteProperty {
            return control.setMute(state.deviceID, false)
        }
        guard !state.savedScalarVolumes.isEmpty else {
            return false
        }
        // 逐项恢复；任何一项失败都必须让状态保留，其余项仍继续尝试。
        let results = state.savedScalarVolumes.map {
            control.setScalarVolume(
                state.deviceID,
                $0.element,
                $0.volume
            )
        }
        return results.allSatisfy { $0 }
    }
}
