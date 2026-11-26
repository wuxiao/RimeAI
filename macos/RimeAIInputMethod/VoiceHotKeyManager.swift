import AppKit
import Carbon
import Foundation

extension Notification.Name {
    static let rimeAIVoiceHotKeyRegistrationDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.voice-hotkey-registration-did-change"
    )
    static let rimeAIVoiceSecondaryHotKeyRegistrationDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.voice-secondary-hotkey-registration-did-change"
    )
    static let rimeAIVoiceTranslateHotKeyRegistrationDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.voice-translate-hotkey-registration-did-change"
    )
}

enum VoiceHotKeyRegistrationFailureKind: Equatable, Sendable {
    case conflict
    case system
}

enum VoiceHotKeyRegistrationStatus: Equatable, Sendable {
    case inactive
    case registered(VoiceDictationShortcut)
    case failed(
        shortcut: VoiceDictationShortcut,
        kind: VoiceHotKeyRegistrationFailureKind,
        code: Int32,
        message: String
    )
}

struct VoiceHotKeyRegistrar {
    struct Request {
        let keyCode: UInt32
        let modifiers: UInt32
        let identifier: EventHotKeyID
        let options: OptionBits
    }

    struct Result {
        let status: OSStatus
        let reference: EventHotKeyRef?
    }

    let register: (Request) -> Result
    let unregister: (EventHotKeyRef) -> OSStatus

    @MainActor static let carbon = Self(
        register: { request in
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                request.keyCode,
                request.modifiers,
                request.identifier,
                GetApplicationEventTarget(),
                request.options,
                &reference
            )
            return Result(status: status, reference: reference)
        },
        unregister: { reference in
            UnregisterEventHotKey(reference)
        }
    )
}

/// InputMethodKit 的 `handle(_:client:)` 只可靠接收 key-down；按住说话还
/// 需要 key-up。Carbon 注册热键会同时发送 pressed/released 事件，且不需
/// 读取或记录普通按键流。注册层只接收经过核心安全策略验证的单一用户快捷键。
@MainActor
final class VoiceHotKeyManager: @unchecked Sendable {
    static let shared = VoiceHotKeyManager()
    nonisolated static var displayShortcut: String {
        VoiceDictationShortcut.displaySummary(
            RimeAISettingsStore.shared.voiceShortcuts
        )
    }
    nonisolated static var displayTranslateShortcut: String {
        RimeAISettingsStore.shared.voiceTranslateShortcut.displayName
    }
    nonisolated static var isModifierTapShortcut: Bool {
        RimeAISettingsStore.shared.voiceShortcuts.contains(where: \.isModifierTap)
    }

    nonisolated private static let signature: OSType =
        (UInt32(ascii: "R") << 24)
        | (UInt32(ascii: "V") << 16)
        | (UInt32(ascii: "O") << 8)
        | UInt32(ascii: "I")
    nonisolated private static let secondarySignature: OSType =
        (UInt32(ascii: "R") << 24)
        | (UInt32(ascii: "V") << 16)
        | (UInt32(ascii: "O") << 8)
        | UInt32(ascii: "2")
    nonisolated private static let translateSignature: OSType =
        (UInt32(ascii: "R") << 24)
        | (UInt32(ascii: "V") << 16)
        | (UInt32(ascii: "T") << 8)
        | UInt32(ascii: "R")
    private weak var activeOwner: AnyObject?
    private var onPressed: (() -> Void)?
    private var onReleased: (() -> Void)?
    private var onSecureInputDetected: (() -> Void)?
    private weak var secondaryOwner: AnyObject?
    private var onSecondaryPressed: (() -> Void)?
    private var onSecondaryReleased: (() -> Void)?
    private weak var translateOwner: AnyObject?
    private var onTranslatePressed: (() -> Void)?
    private var onTranslateReleased: (() -> Void)?
    private var eventHandler: EventHandlerRef?
    private var eventHandlerIsAvailable = false
    private var hotKey: EventHotKeyRef?
    private var secondaryHotKey: EventHotKeyRef?
    private var translateHotKey: EventHotKeyRef?
    private var secureInputTimer: DispatchSourceTimer?
    private var registrationState = VoiceHotKeyRegistrationState()
    private var secondaryRegistrationState = VoiceHotKeyRegistrationState()
    private var translateRegistrationState = VoiceHotKeyRegistrationState()
    private(set) var registrationStatus: VoiceHotKeyRegistrationStatus = .inactive
    private(set) var secondaryRegistrationStatus: VoiceHotKeyRegistrationStatus =
        .inactive
    private(set) var translateRegistrationStatus: VoiceHotKeyRegistrationStatus =
        .inactive
    private let registrar: VoiceHotKeyRegistrar

    private init() {
        registrar = .carbon
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
        eventHandlerIsAvailable = eventHandler != nil
    }

    init(testingRegistrar registrar: VoiceHotKeyRegistrar) {
        self.registrar = registrar
        eventHandlerIsAvailable = true
    }

    isolated deinit {
        secureInputTimer?.cancel()
        if let hotKey {
            _ = registrar.unregister(hotKey)
        }
        if let secondaryHotKey {
            _ = registrar.unregister(secondaryHotKey)
        }
        if let translateHotKey {
            _ = registrar.unregister(translateHotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func activate(
        owner: AnyObject,
        shortcut: VoiceDictationShortcut = RimeAISettingsStore.shared
            .voiceShortcut,
        onPressed: @escaping () -> Void,
        onReleased: @escaping () -> Void,
        onSecureInputDetected: @escaping () -> Void
    ) throws {
        if shortcut.isModifierTap {
            // 右侧 Command 点按切换由 IMKInputController 的 flagsChanged 直接处理，
            // 无需 Carbon RegisterEventHotKey（Carbon 也不支持裸修饰键）。
            if activeOwner === owner,
               hotKey == nil,
               registrationState.registeredShortcut == shortcut
            {
                self.onPressed = onPressed
                self.onReleased = onReleased
                self.onSecureInputDetected = onSecureInputDetected
                updateRegistrationStatus(.registered(shortcut))
                return
            }
            let previousRelease = unregisterCurrentHotKey(
                endingPressedSession: activeOwner != nil
            )
            activeOwner = nil
            self.onPressed = nil
            self.onReleased = nil
            self.onSecureInputDetected = nil
            previousRelease?()

            _ = registrationState.activate(shortcut: shortcut)
            activeOwner = owner
            self.onPressed = onPressed
            self.onReleased = onReleased
            self.onSecureInputDetected = onSecureInputDetected
            updateRegistrationStatus(.registered(shortcut))
            startSecureInputTimer()
            return
        }

        guard eventHandlerIsAvailable else {
            let message = "无法安装语音快捷键事件处理器。"
            updateRegistrationStatus(.failed(
                shortcut: shortcut,
                kind: .system,
                code: -1,
                message: message
            ))
            throw hotKeyError(message, code: -1)
        }
        if activeOwner === owner,
           hotKey != nil,
           registrationState.registeredShortcut == shortcut
        {
            self.onPressed = onPressed
            self.onReleased = onReleased
            self.onSecureInputDetected = onSecureInputDetected
            updateRegistrationStatus(.registered(shortcut))
            return
        }

        let previousRelease = unregisterCurrentHotKey(
            endingPressedSession: activeOwner != nil
        )
        activeOwner = nil
        self.onPressed = nil
        self.onReleased = nil
        self.onSecureInputDetected = nil
        previousRelease?()

        let activation = registrationState.activate(shortcut: shortcut)
        guard case let .register(registrationID, _) = activation else {
            let message = "无法建立新的语音快捷键注册代际。"
            updateRegistrationStatus(.failed(
                shortcut: shortcut,
                kind: .system,
                code: Int32(paramErr),
                message: message
            ))
            throw hotKeyError(message, code: Int32(paramErr))
        }
        activeOwner = owner
        self.onPressed = onPressed
        self.onReleased = onReleased
        self.onSecureInputDetected = onSecureInputDetected
        let identifier = EventHotKeyID(
            signature: Self.signature,
            id: registrationID
        )

        let registrationOptions = OptionBits(kEventHotKeyExclusive)
        let result = registrar.register(.init(
            keyCode: UInt32(shortcut.keyCode),
            modifiers: Self.carbonModifiers(for: shortcut.modifiers),
            identifier: identifier,
            options: registrationOptions
        ))
        let evaluation = VoiceHotKeyRegistrationPolicy.evaluate(
            requestedExclusive: registrationOptions
                == OptionBits(kEventHotKeyExclusive),
            status: result.status,
            referenceWasCreated: result.reference != nil,
            conflictStatus: OSStatus(eventHotKeyExistsErr)
        )
        if case .registered = evaluation, let reference = result.reference {
            hotKey = reference
            updateRegistrationStatus(.registered(shortcut))
            if eventHandler != nil {
                startSecureInputTimer()
            }
            return
        }

        let failure: (kind: VoiceHotKeyRegistrationFailureKind, code: Int32)
        switch evaluation {
        case .conflict:
            failure = (.conflict, OSStatus(eventHotKeyExistsErr))
        case let .systemFailure(status):
            failure = (.system, status)
        case .invalidRegistration, .registered:
            failure = (.system, Int32(paramErr))
        }
        registrationState.registrationFailed(
            registrationID: registrationID
        )
        activeOwner = nil
        self.onPressed = nil
        self.onReleased = nil
        self.onSecureInputDetected = nil
        let message = failure.kind == .conflict
            ? "快捷键 \(shortcut.displayName) 已被其他应用占用。"
            : "快捷键 \(shortcut.displayName) 无法注册（错误 \(failure.code)）。"
        updateRegistrationStatus(.failed(
            shortcut: shortcut,
            kind: failure.kind,
            code: failure.code,
            message: message
        ))
        throw hotKeyError(message, code: failure.code)
    }

    func deactivate(owner: AnyObject) {
        deactivateSecondary(owner: owner)
        deactivateTranslation(owner: owner)
        guard activeOwner === owner else {
            return
        }
        let release = unregisterCurrentHotKey(endingPressedSession: true)
        activeOwner = nil
        onPressed = nil
        onReleased = nil
        onSecureInputDetected = nil
        release?()
    }

    /// 注册备用语音听写快捷键（独立 Carbon 签名 RVO2，不与主听写或翻译热键冲突）。
    func activateSecondary(
        owner: AnyObject,
        shortcut: VoiceDictationShortcut,
        onPressed: @escaping () -> Void,
        onReleased: @escaping () -> Void,
        onSecureInputDetected: (() -> Void)? = nil
    ) throws {
        if shortcut.isModifierTap {
            if secondaryOwner === owner,
               secondaryHotKey == nil,
               secondaryRegistrationState.registeredShortcut == shortcut
            {
                onSecondaryPressed = onPressed
                onSecondaryReleased = onReleased
                if let onSecureInputDetected, self.onSecureInputDetected == nil {
                    self.onSecureInputDetected = onSecureInputDetected
                }
                updateSecondaryRegistrationStatus(.registered(shortcut))
                return
            }
            let previousRelease = unregisterSecondaryHotKey(
                endingPressedSession: secondaryOwner != nil
            )
            secondaryOwner = nil
            onSecondaryPressed = nil
            onSecondaryReleased = nil
            previousRelease?()

            _ = secondaryRegistrationState.activate(shortcut: shortcut)
            secondaryOwner = owner
            onSecondaryPressed = onPressed
            onSecondaryReleased = onReleased
            if let onSecureInputDetected, self.onSecureInputDetected == nil {
                self.onSecureInputDetected = onSecureInputDetected
            }
            updateSecondaryRegistrationStatus(.registered(shortcut))
            if secureInputTimer == nil, eventHandler != nil {
                startSecureInputTimer()
            }
            return
        }

        guard eventHandlerIsAvailable else {
            let message = "无法安装备用语音快捷键事件处理器。"
            updateSecondaryRegistrationStatus(.failed(
                shortcut: shortcut,
                kind: .system,
                code: -1,
                message: message
            ))
            throw hotKeyError(message, code: -1)
        }
        if secondaryOwner === owner,
           secondaryHotKey != nil,
           secondaryRegistrationState.registeredShortcut == shortcut
        {
            onSecondaryPressed = onPressed
            onSecondaryReleased = onReleased
            if let onSecureInputDetected, self.onSecureInputDetected == nil {
                self.onSecureInputDetected = onSecureInputDetected
            }
            updateSecondaryRegistrationStatus(.registered(shortcut))
            return
        }

        let previousRelease = unregisterSecondaryHotKey(
            endingPressedSession: secondaryOwner != nil
        )
        secondaryOwner = nil
        onSecondaryPressed = nil
        onSecondaryReleased = nil
        previousRelease?()

        let activation = secondaryRegistrationState.activate(shortcut: shortcut)
        guard case let .register(registrationID, _) = activation else {
            let message = "无法建立新的备用语音快捷键注册代际。"
            updateSecondaryRegistrationStatus(.failed(
                shortcut: shortcut,
                kind: .system,
                code: Int32(paramErr),
                message: message
            ))
            throw hotKeyError(message, code: Int32(paramErr))
        }
        secondaryOwner = owner
        onSecondaryPressed = onPressed
        onSecondaryReleased = onReleased
        if let onSecureInputDetected, self.onSecureInputDetected == nil {
            self.onSecureInputDetected = onSecureInputDetected
        }
        let identifier = EventHotKeyID(
            signature: Self.secondarySignature,
            id: registrationID
        )
        let registrationOptions = OptionBits(kEventHotKeyExclusive)
        let result = registrar.register(.init(
            keyCode: UInt32(shortcut.keyCode),
            modifiers: Self.carbonModifiers(for: shortcut.modifiers),
            identifier: identifier,
            options: registrationOptions
        ))
        let evaluation = VoiceHotKeyRegistrationPolicy.evaluate(
            requestedExclusive: registrationOptions
                == OptionBits(kEventHotKeyExclusive),
            status: result.status,
            referenceWasCreated: result.reference != nil,
            conflictStatus: OSStatus(eventHotKeyExistsErr)
        )
        if case .registered = evaluation, let reference = result.reference {
            secondaryHotKey = reference
            updateSecondaryRegistrationStatus(.registered(shortcut))
            if secureInputTimer == nil, eventHandler != nil {
                startSecureInputTimer()
            }
            return
        }

        let failure: (kind: VoiceHotKeyRegistrationFailureKind, code: Int32)
        switch evaluation {
        case .conflict:
            failure = (.conflict, OSStatus(eventHotKeyExistsErr))
        case let .systemFailure(status):
            failure = (.system, status)
        case .invalidRegistration, .registered:
            failure = (.system, Int32(paramErr))
        }
        secondaryRegistrationState.registrationFailed(
            registrationID: registrationID
        )
        secondaryOwner = nil
        onSecondaryPressed = nil
        onSecondaryReleased = nil
        let message = failure.kind == .conflict
            ? "备用快捷键 \(shortcut.displayName) 已被其他应用占用。"
            : "备用快捷键 \(shortcut.displayName) 无法注册（错误 \(failure.code)）。"
        updateSecondaryRegistrationStatus(.failed(
            shortcut: shortcut,
            kind: failure.kind,
            code: failure.code,
            message: message
        ))
        throw hotKeyError(message, code: failure.code)
    }

    func deactivateSecondary(owner: AnyObject) {
        guard secondaryOwner === owner else {
            return
        }
        let release = unregisterSecondaryHotKey(endingPressedSession: true)
        secondaryOwner = nil
        onSecondaryPressed = nil
        onSecondaryReleased = nil
        if activeOwner == nil {
            secureInputTimer?.cancel()
            secureInputTimer = nil
            onSecureInputDetected = nil
        }
        release?()
    }

    private func handleSecondary(
        eventKind: UInt32,
        eventRegistrationID: UInt32
    ) {
        guard secondaryOwner != nil else {
            _ = unregisterSecondaryHotKey(endingPressedSession: false)
            return
        }
        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            guard secondaryRegistrationState.press(
                registrationID: eventRegistrationID
            ) else {
                return
            }
            onSecondaryPressed?()
        case UInt32(kEventHotKeyReleased):
            guard secondaryRegistrationState.release(
                registrationID: eventRegistrationID
            ) else {
                return
            }
            onSecondaryReleased?()
        default:
            break
        }
    }

    private func unregisterSecondaryHotKey(
        endingPressedSession: Bool
    ) -> (() -> Void)? {
        let release = endingPressedSession
            && secondaryRegistrationState.pressedRegistrationID != nil
            ? onSecondaryReleased
            : nil
        if let secondaryHotKey {
            _ = registrar.unregister(secondaryHotKey)
            self.secondaryHotKey = nil
        }
        secondaryRegistrationState.deactivate()
        updateSecondaryRegistrationStatus(.inactive)
        return release
    }

    private func updateSecondaryRegistrationStatus(
        _ status: VoiceHotKeyRegistrationStatus
    ) {
        guard secondaryRegistrationStatus != status else {
            return
        }
        secondaryRegistrationStatus = status
        NotificationCenter.default.post(
            name: .rimeAIVoiceSecondaryHotKeyRegistrationDidChange,
            object: self
        )
    }

    /// 注册一键语音翻译快捷键（独立 Carbon 签名 RVTR，不与主听写热键冲突）。
    func activateTranslation(
        owner: AnyObject,
        shortcut: VoiceDictationShortcut = RimeAISettingsStore.shared
            .voiceTranslateShortcut,
        onPressed: @escaping () -> Void,
        onReleased: @escaping () -> Void
    ) throws {
        if shortcut.isModifierTap {
            if translateOwner === owner,
               translateHotKey == nil,
               translateRegistrationState.registeredShortcut == shortcut
            {
                onTranslatePressed = onPressed
                onTranslateReleased = onReleased
                updateTranslateRegistrationStatus(.registered(shortcut))
                return
            }
            let previousRelease = unregisterTranslateHotKey(
                endingPressedSession: translateOwner != nil
            )
            translateOwner = nil
            onTranslatePressed = nil
            onTranslateReleased = nil
            previousRelease?()

            _ = translateRegistrationState.activate(shortcut: shortcut)
            translateOwner = owner
            onTranslatePressed = onPressed
            onTranslateReleased = onReleased
            updateTranslateRegistrationStatus(.registered(shortcut))
            return
        }

        guard eventHandlerIsAvailable else {
            let message = "无法安装语音翻译快捷键事件处理器。"
            updateTranslateRegistrationStatus(.failed(
                shortcut: shortcut,
                kind: .system,
                code: -1,
                message: message
            ))
            throw hotKeyError(message, code: -1)
        }
        if translateOwner === owner,
           translateHotKey != nil,
           translateRegistrationState.registeredShortcut == shortcut
        {
            onTranslatePressed = onPressed
            onTranslateReleased = onReleased
            updateTranslateRegistrationStatus(.registered(shortcut))
            return
        }

        let previousRelease = unregisterTranslateHotKey(
            endingPressedSession: translateOwner != nil
        )
        translateOwner = nil
        onTranslatePressed = nil
        onTranslateReleased = nil
        previousRelease?()

        let activation = translateRegistrationState.activate(shortcut: shortcut)
        guard case let .register(registrationID, _) = activation else {
            let message = "无法建立新的语音翻译快捷键注册代际。"
            updateTranslateRegistrationStatus(.failed(
                shortcut: shortcut,
                kind: .system,
                code: Int32(paramErr),
                message: message
            ))
            throw hotKeyError(message, code: Int32(paramErr))
        }
        translateOwner = owner
        onTranslatePressed = onPressed
        onTranslateReleased = onReleased
        let identifier = EventHotKeyID(
            signature: Self.translateSignature,
            id: registrationID
        )
        let registrationOptions = OptionBits(kEventHotKeyExclusive)
        let result = registrar.register(.init(
            keyCode: UInt32(shortcut.keyCode),
            modifiers: Self.carbonModifiers(for: shortcut.modifiers),
            identifier: identifier,
            options: registrationOptions
        ))
        let evaluation = VoiceHotKeyRegistrationPolicy.evaluate(
            requestedExclusive: registrationOptions
                == OptionBits(kEventHotKeyExclusive),
            status: result.status,
            referenceWasCreated: result.reference != nil,
            conflictStatus: OSStatus(eventHotKeyExistsErr)
        )
        if case .registered = evaluation, let reference = result.reference {
            translateHotKey = reference
            updateTranslateRegistrationStatus(.registered(shortcut))
            return
        }

        let failure: (kind: VoiceHotKeyRegistrationFailureKind, code: Int32)
        switch evaluation {
        case .conflict:
            failure = (.conflict, OSStatus(eventHotKeyExistsErr))
        case let .systemFailure(status):
            failure = (.system, status)
        case .invalidRegistration, .registered:
            failure = (.system, Int32(paramErr))
        }
        translateRegistrationState.registrationFailed(
            registrationID: registrationID
        )
        translateOwner = nil
        onTranslatePressed = nil
        onTranslateReleased = nil
        let message = failure.kind == .conflict
            ? "翻译快捷键 \(shortcut.displayName) 已被其他应用占用。"
            : "翻译快捷键 \(shortcut.displayName) 无法注册（错误 \(failure.code)）。"
        updateTranslateRegistrationStatus(.failed(
            shortcut: shortcut,
            kind: failure.kind,
            code: failure.code,
            message: message
        ))
        throw hotKeyError(message, code: failure.code)
    }

    func deactivateTranslation(owner: AnyObject) {
        guard translateOwner === owner else {
            return
        }
        let release = unregisterTranslateHotKey(endingPressedSession: true)
        translateOwner = nil
        onTranslatePressed = nil
        onTranslateReleased = nil
        release?()
    }

    private func handleTranslate(
        eventKind: UInt32,
        eventRegistrationID: UInt32
    ) {
        guard translateOwner != nil else {
            _ = unregisterTranslateHotKey(endingPressedSession: false)
            return
        }
        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            guard translateRegistrationState.press(
                registrationID: eventRegistrationID
            ) else {
                return
            }
            onTranslatePressed?()
        case UInt32(kEventHotKeyReleased):
            guard translateRegistrationState.release(
                registrationID: eventRegistrationID
            ) else {
                return
            }
            onTranslateReleased?()
        default:
            break
        }
    }

    private func unregisterTranslateHotKey(
        endingPressedSession: Bool
    ) -> (() -> Void)? {
        let release = endingPressedSession
            && translateRegistrationState.pressedRegistrationID != nil
            ? onTranslateReleased
            : nil
        if let translateHotKey {
            _ = registrar.unregister(translateHotKey)
            self.translateHotKey = nil
        }
        translateRegistrationState.deactivate()
        updateTranslateRegistrationStatus(.inactive)
        return release
    }

    private func updateTranslateRegistrationStatus(
        _ status: VoiceHotKeyRegistrationStatus
    ) {
        guard translateRegistrationStatus != status else {
            return
        }
        translateRegistrationStatus = status
        NotificationCenter.default.post(
            name: .rimeAIVoiceTranslateHotKeyRegistrationDidChange,
            object: self
        )
    }

    private func handle(eventKind: UInt32, eventRegistrationID: UInt32) {
        guard activeOwner != nil else {
            _ = unregisterCurrentHotKey(endingPressedSession: false)
            return
        }
        switch eventKind {
        case UInt32(kEventHotKeyPressed):
            guard registrationState.press(
                registrationID: eventRegistrationID
            ) else {
                return
            }
            onPressed?()
        case UInt32(kEventHotKeyReleased):
            guard registrationState.release(
                registrationID: eventRegistrationID
            ) else {
                return
            }
            onReleased?()
        default:
            break
        }
    }

    private func unregisterCurrentHotKey(
        endingPressedSession: Bool
    ) -> (() -> Void)? {
        let release = endingPressedSession
            && registrationState.pressedRegistrationID != nil
            ? onReleased
            : nil
        if secondaryOwner == nil {
            secureInputTimer?.cancel()
            secureInputTimer = nil
        }
        if let hotKey {
            _ = registrar.unregister(hotKey)
            self.hotKey = nil
        }
        registrationState.deactivate()
        updateRegistrationStatus(.inactive)
        return release
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
            guard self.activeOwner != nil || self.secondaryOwner != nil else {
                self.secureInputTimer?.cancel()
                self.secureInputTimer = nil
                _ = self.unregisterCurrentHotKey(
                    endingPressedSession: false
                )
                return
            }
            guard IsSecureEventInputEnabled() else {
                return
            }
            let handler = self.onSecureInputDetected
            self.secondaryOwner = nil
            self.onSecondaryPressed = nil
            self.onSecondaryReleased = nil
            _ = self.unregisterSecondaryHotKey(endingPressedSession: false)
            _ = self.unregisterCurrentHotKey(endingPressedSession: false)
            _ = self.unregisterTranslateHotKey(endingPressedSession: false)
            self.activeOwner = nil
            self.onPressed = nil
            self.onReleased = nil
            self.onSecureInputDetected = nil
            self.translateOwner = nil
            self.onTranslatePressed = nil
            self.onTranslateReleased = nil
            handler?()
        }
        secureInputTimer = timer
        timer.resume()
    }

    nonisolated static func makeShortcut(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> VoiceDictationShortcut? {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: VoiceDictationKeyModifiers = []
        let mapping: [(NSEvent.ModifierFlags, VoiceDictationKeyModifiers)] = [
            (.shift, .shift),
            (.control, .control),
            (.option, .option),
            (.command, .command),
            (.help, .help),
            (.function, .function),
        ]
        for (flag, modifier) in mapping where flags.contains(flag) {
            modifiers.insert(modifier)
        }
        return VoiceDictationShortcut(
            keyCode: keyCode,
            modifiers: modifiers
        )
    }

    nonisolated private static func carbonModifiers(
        for modifiers: VoiceDictationKeyModifiers
    ) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.shift) {
            result |= UInt32(shiftKey)
        }
        if modifiers.contains(.control) {
            result |= UInt32(controlKey)
        }
        if modifiers.contains(.option) {
            result |= UInt32(optionKey)
        }
        if modifiers.contains(.command) {
            result |= UInt32(cmdKey)
        }
        return result
    }

    private func updateRegistrationStatus(
        _ status: VoiceHotKeyRegistrationStatus
    ) {
        guard registrationStatus != status else {
            return
        }
        registrationStatus = status
        NotificationCenter.default.post(
            name: .rimeAIVoiceHotKeyRegistrationDidChange,
            object: self
        )
    }

    private func hotKeyError(
        _ description: String,
        code: Int32
    ) -> NSError {
        NSError(
            domain: "fun.wwcn.inputmethod.RimeAI.voice-hotkey",
            code: Int(code),
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
    let isDictation = identifier.signature == VoiceHotKeyManager.eventSignature
    let isSecondaryDictation =
        identifier.signature == VoiceHotKeyManager.secondaryEventSignature
    let isTranslate =
        identifier.signature == VoiceHotKeyManager.translateEventSignature
    guard status == noErr, isDictation || isSecondaryDictation || isTranslate else {
        return OSStatus(eventNotHandledErr)
    }
    let eventRegistrationID = identifier.id
    // ApplicationEventTarget 在主事件循环串行派发 pressed/released；同步
    // 转交可保留这两个边沿的严格顺序。独立 unstructured Task 可能让极快
    // 的 release 先于 press 执行，从而留下无法停止的录音。
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            if isTranslate {
                manager.handleTranslateFromCarbon(
                    eventKind: kind,
                    registrationID: eventRegistrationID
                )
            } else if isSecondaryDictation {
                manager.handleSecondaryFromCarbon(
                    eventKind: kind,
                    registrationID: eventRegistrationID
                )
            } else {
                manager.handleFromCarbon(
                    eventKind: kind,
                    registrationID: eventRegistrationID
                )
            }
        }
    } else {
        // 防御性回退；正常的 ApplicationEventTarget 不会走到这里。
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if isTranslate {
                    manager.handleTranslateFromCarbon(
                        eventKind: kind,
                        registrationID: eventRegistrationID
                    )
                } else if isSecondaryDictation {
                    manager.handleSecondaryFromCarbon(
                        eventKind: kind,
                        registrationID: eventRegistrationID
                    )
                } else {
                    manager.handleFromCarbon(
                        eventKind: kind,
                        registrationID: eventRegistrationID
                    )
                }
            }
        }
    }
    return noErr
}

extension VoiceHotKeyManager {
    nonisolated static var eventSignature: OSType { signature }
    nonisolated static var secondaryEventSignature: OSType { secondarySignature }
    nonisolated static var translateEventSignature: OSType { translateSignature }

    func handleFromCarbon(eventKind: UInt32, registrationID: UInt32) {
        handle(
            eventKind: eventKind,
            eventRegistrationID: registrationID
        )
    }

    func handleSecondaryFromCarbon(eventKind: UInt32, registrationID: UInt32) {
        handleSecondary(
            eventKind: eventKind,
            eventRegistrationID: registrationID
        )
    }

    func handleTranslateFromCarbon(eventKind: UInt32, registrationID: UInt32) {
        handleTranslate(
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
