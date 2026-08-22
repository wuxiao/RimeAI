import Carbon
import Foundation

/// InputMethodKit 的 `handle(_:client:)` 只可靠接收 key-down；按住说话还
/// 需要 key-up。Carbon 注册热键会同时发送 pressed/released 事件，且不需
/// 读取或记录普通按键流，因此将这个兼容层限制在单一固定快捷键。
@MainActor
final class VoiceHotKeyManager: @unchecked Sendable {
    static let shared = VoiceHotKeyManager()
    nonisolated static let displayShortcut = "⌃⇧V"

    nonisolated private static let signature: OSType =
        (UInt32(ascii: "R") << 24)
        | (UInt32(ascii: "V") << 16)
        | (UInt32(ascii: "O") << 8)
        | UInt32(ascii: "I")
    private weak var activeOwner: AnyObject?
    private var onPressed: (() -> Void)?
    private var onReleased: (() -> Void)?
    private var onSecureInputDetected: (() -> Void)?
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var secureInputTimer: DispatchSourceTimer?
    private var registrationID: UInt32 = 0
    private var pressedRegistrationID: UInt32?

    private init() {
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        let context = UnsafeMutableRawPointer(
            Unmanaged.passUnretained(self).toOpaque()
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            voiceHotKeyEventHandler,
            eventTypes.count,
            &eventTypes,
            context,
            &eventHandler
        )
        if status != noErr {
            eventHandler = nil
        }
    }

    deinit {
        secureInputTimer?.cancel()
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func activate(
        owner: AnyObject,
        onPressed: @escaping () -> Void,
        onReleased: @escaping () -> Void,
        onSecureInputDetected: @escaping () -> Void
    ) throws {
        guard eventHandler != nil else {
            throw hotKeyError(
                "无法安装语音快捷键事件处理器。",
                code: -1
            )
        }
        if let activeOwner, activeOwner !== owner {
            unregisterCurrentHotKey()
        }
        activeOwner = owner
        self.onPressed = onPressed
        self.onReleased = onReleased
        self.onSecureInputDetected = onSecureInputDetected
        guard hotKey == nil else {
            return
        }

        registrationID &+= 1
        if registrationID == 0 {
            registrationID = 1
        }
        let identifier = EventHotKeyID(
            signature: Self.signature,
            id: registrationID
        )

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &reference
        )
        guard status == noErr, let reference else {
            activeOwner = nil
            self.onPressed = nil
            self.onReleased = nil
            self.onSecureInputDetected = nil
            throw hotKeyError(
                "快捷键 \(Self.displayShortcut) 已被其他应用占用或无法注册。",
                code: Int(status)
            )
        }
        hotKey = reference
        startSecureInputTimer()
    }

    func deactivate(owner: AnyObject) {
        guard activeOwner === owner else {
            return
        }
        unregisterCurrentHotKey()
        activeOwner = nil
        onPressed = nil
        onReleased = nil
        onSecureInputDetected = nil
    }

    private func handle(eventKind: UInt32, eventRegistrationID: UInt32) {
        guard activeOwner != nil else {
            unregisterCurrentHotKey()
            return
        }
        guard eventRegistrationID == registrationID else {
            return
        }
        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            guard pressedRegistrationID == nil else {
                return
            }
            pressedRegistrationID = eventRegistrationID
            onPressed?()
        case UInt32(kEventHotKeyReleased):
            guard pressedRegistrationID == eventRegistrationID else {
                return
            }
            pressedRegistrationID = nil
            onReleased?()
        default:
            break
        }
    }

    private func unregisterCurrentHotKey() {
        secureInputTimer?.cancel()
        secureInputTimer = nil
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        pressedRegistrationID = nil
        registrationID &+= 1
    }

    private func startSecureInputTimer() {
        secureInputTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(150),
            repeating: .milliseconds(150),
            leeway: .milliseconds(25)
        )
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            guard self.activeOwner != nil else {
                self.unregisterCurrentHotKey()
                return
            }
            guard IsSecureEventInputEnabled() else {
                return
            }
            let handler = self.onSecureInputDetected
            self.unregisterCurrentHotKey()
            self.activeOwner = nil
            self.onPressed = nil
            self.onReleased = nil
            self.onSecureInputDetected = nil
            handler?()
        }
        secureInputTimer = timer
        timer.resume()
    }

    private func hotKeyError(
        _ description: String,
        code: Int
    ) -> NSError {
        NSError(
            domain: "fun.wwcn.inputmethod.RimeAI.voice-hotkey",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

private let voiceHotKeyEventHandler: EventHandlerUPP = {
    _, event, context in
    guard let event, let context else {
        return OSStatus(eventNotHandledErr)
    }
    let manager = Unmanaged<VoiceHotKeyManager>
        .fromOpaque(context)
        .takeUnretainedValue()
    let kind = GetEventKind(event)
    var identifier = EventHotKeyID(signature: 0, id: 0)
    var actualSize = 0
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        &actualSize,
        &identifier
    )
    guard status == noErr,
          identifier.signature == VoiceHotKeyManager.eventSignature
    else {
        return OSStatus(eventNotHandledErr)
    }
    // ApplicationEventTarget 在主事件循环串行派发 pressed/released；同步
    // 转交可保留这两个边沿的严格顺序。独立 unstructured Task 可能让极快
    // 的 release 先于 press 执行，从而留下无法停止的录音。
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            manager.handleFromCarbon(
                eventKind: kind,
                registrationID: identifier.id
            )
        }
    } else {
        // 防御性回退；正常的 ApplicationEventTarget 不会走到这里。
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                manager.handleFromCarbon(
                    eventKind: kind,
                    registrationID: identifier.id
                )
            }
        }
    }
    return noErr
}

private extension VoiceHotKeyManager {
    nonisolated static var eventSignature: OSType { signature }

    func handleFromCarbon(eventKind: UInt32, registrationID: UInt32) {
        handle(
            eventKind: eventKind,
            eventRegistrationID: registrationID
        )
    }
}

private extension UInt32 {
    init(ascii character: Character) {
        self = character.asciiValue.map(UInt32.init) ?? 0
    }
}
