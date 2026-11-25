import CoreAudio
import Foundation

/// CoreAudio 操作出口：生产环境走真实设备，单测注入记录调用的假实现。
struct VoiceSystemAudioDeviceControl {
    var defaultOutputDeviceID: () -> AudioDeviceID?
    var isMuteSettable: (AudioDeviceID) -> Bool
    var getMute: (AudioDeviceID) -> Bool?
    var setMute: (AudioDeviceID, Bool) -> Bool
    var isScalarVolumeSettable: (AudioDeviceID, AudioObjectPropertyElement) -> Bool
    var getScalarVolume: (AudioDeviceID, AudioObjectPropertyElement) -> Float32?
    var setScalarVolume: (AudioDeviceID, AudioObjectPropertyElement, Float32) -> Bool

    @MainActor static let coreAudio = VoiceSystemAudioDeviceControl(
        defaultOutputDeviceID: VoiceSystemAudioDeviceAccess.defaultOutputDeviceID,
        isMuteSettable: VoiceSystemAudioDeviceAccess.isMuteSettable,
        getMute: VoiceSystemAudioDeviceAccess.getMute,
        setMute: VoiceSystemAudioDeviceAccess.setMute,
        isScalarVolumeSettable: VoiceSystemAudioDeviceAccess.isScalarVolumeSettable,
        getScalarVolume: VoiceSystemAudioDeviceAccess.getScalarVolume,
        setScalarVolume: VoiceSystemAudioDeviceAccess.setScalarVolume
    )
}

/// 真实设备的属性读写（纯 C API 包装，无状态）。
enum VoiceSystemAudioDeviceAccess {
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    static func isMuteSettable(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(
            deviceID,
            &address,
            &settable
        )
        return status == noErr && settable.boolValue
    }

    static func getMute(deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &muted
        )
        guard status == noErr else {
            return nil
        }
        return muted != 0
    }

    @discardableResult
    static func setMute(deviceID: AudioDeviceID, muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            size,
            &value
        ) == noErr
    }

    static func isScalarVolumeSettable(
        deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(
            deviceID,
            &address,
            &settable
        )
        return status == noErr && settable.boolValue
    }

    static func getScalarVolume(
        deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &volume
        )
        guard status == noErr else {
            return nil
        }
        return volume
    }

    @discardableResult
    static func setScalarVolume(
        deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement,
        volume: Float32
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        var value = max(0, min(1, volume))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            size,
            &value
        ) == noErr
    }
}
