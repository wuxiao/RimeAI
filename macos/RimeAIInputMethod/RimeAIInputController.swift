import AppKit
import Carbon
import InputMethodKit

/// IMK 控制器主体：生命周期、组合状态与依赖持有。按键处理、
/// 组合写入、候选选择、面板、语音、菜单与语义流水线接线分别
/// 位于同名 `RimeAIInputController+*.swift` extension 文件。
@objc(RimeAIInputController)
@MainActor
final class RimeAIInputController: IMKInputController,
    VoiceDictationRuntimeOwner, @unchecked Sendable
{
    static var contextStore = SessionContextStore(maxCharacters: 100)

    let sessionNonce = UUID().uuidString
    let candidatePanel: CandidatePanelController
    let mixedCompositionResolver = MixedCompositionResolver()
    var composition = CompositionState(appSessionID: "inactive")
    var pipeline: SemanticSuggestionPipeline!
    var phrasebookEnglishTokens = Set<String>()
    var phrasebookEnglishTokensLoaded = false
    var phrasebookEnglishTokensLoading = false
    var phrasebookEnglishTokensGeneration: UInt64 = 0
    var legacyEnglishTokensMigrated = false
    weak var activeClientObject: AnyObject?
    var currentBundleIdentifier: String?
    var hostFocusEpoch: UInt64 = 0
    var settingsObservers: [NSObjectProtocol] = []
    let settings = RimeAISettingsStore.shared
    var voiceHotKeyRegistrationFailed = false
    var voiceHotKeyIsRegistered = false
    var isHostActive = false
    var voiceHotwordAdmission = VoiceHotwordAdmissionState()
    /// 上屏后续写协调器（惰性装配，依赖注入见 +Continuation.swift）。
    lazy var continuationCoordinator: PostCommitContinuationCoordinator =
        makeContinuationCoordinator()
    /// 最近一次上屏时的光标锚点：续写 chip 的展示位置。
    var continuationAnchorRect: NSRect?

    override init!(
        server: IMKServer!,
        delegate: Any!,
        client inputClient: Any!
    ) {
        candidatePanel = MainActor.assumeIsolated {
            CandidatePanelController()
        }
        super.init(
            server: server,
            delegate: delegate,
            client: inputClient
        )
        MainActor.assumeIsolated {
            activeClientObject = inputClient as AnyObject
            pipeline = makeSuggestionPipeline()
            observeSettings()
        }
    }

    deinit {
        for observer in settingsObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        // IMK controllers normally die on main. Do not call assumeIsolated
        // off-main; runtime/HotKeyManager hold owners weakly and their timers
        // invalidate an owner that has disappeared.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                VoiceDictationRuntime.shared.deactivate(owner: self)
            }
        }
    }

    override nonisolated func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        MainActor.assumeIsolated {
            guard let client = sender as? any IMKTextInput else {
                return
            }
            beginHostActivation(sender as AnyObject)
            activateSession(for: client)
            if IsSecureEventInputEnabled() {
                enterSecureInput(client: client)
            } else {
                VoiceDictationRuntime.shared.secureInputChanged(
                    active: false,
                    owner: self
                )
                configureVoiceHotKey()
            }
        }
    }

    override nonisolated func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated {
            VoiceDictationRuntime.shared.deactivate(owner: self)
            voiceHotKeyIsRegistered = false
            isHostActive = false
            invalidateInference(clearPresentation: true)
            candidatePanel.hide()
            // 兜底：部分失活路径（如经菜单栏切换输入源）不会先收到
            // 系统 commitComposition:，这里主动按同一语义原样提交，
            // 避免组合内容被静默丢弃；系统已提交过则为空操作。
            commitCompositionOnMain(sender)
            // 强制提交会走 commitText 的续写 arm，但会话正在结束，
            // 任何续写请求或 chip 都不得比会话活得更久；此处一次
            // cancel 同时撤掉提交前的在途状态与提交刚 arm 的一轮。
            continuationCoordinator.cancel(.deactivated)
            continuationAnchorRect = nil
            composition.reset()
            Self.contextStore.suspend(ownerID: sessionNonce)
            voiceHotwordAdmission.deactivate()
            activeClientObject = nil
        }
        super.deactivateServer(sender)
    }

    override nonisolated func handle(
        _ event: NSEvent!,
        client sender: Any!
    ) -> Bool {
        MainActor.assumeIsolated {
            handleOnMain(event, client: sender)
        }
    }

    override nonisolated func commitComposition(_ sender: Any!) {
        MainActor.assumeIsolated {
            commitCompositionOnMain(sender)
        }
    }

    /// IMK 强制提交（切换输入法、宿主终止输入会话等）：用户从未
    /// 显式确认转换，活跃拼音段原样上屏，定稿前缀按其定稿文本
    /// 上屏（"你好，ma"语义），绝不上屏候选；与 squirrel 的
    /// commitComposition 语义一致。
    private func commitCompositionOnMain(_ sender: Any!) {
        guard let client = sender as? any IMKTextInput else {
            return
        }
        cancelVoiceDictation()
        adoptActiveClient(sender as AnyObject)
        guard composition.hasComposition else {
            return
        }
        commitText(
            composition.committedPrefixText + composition.pinyin,
            source: .rawPinyin,
            client: client,
            historyPinyin: composition.historyPinyin
        )
    }

    override nonisolated func composedString(_ sender: Any!) -> Any! {
        MainActor.assumeIsolated {
            composition.displayString
        }
    }

    override nonisolated func originalString(
        _ sender: Any!
    ) -> NSAttributedString! {
        let original = MainActor.assumeIsolated {
            composition.displayString
        }
        return NSAttributedString(string: original)
    }

    override nonisolated func candidates(_ sender: Any!) -> [Any]! {
        MainActor.assumeIsolated {
            // IMK 协议兜底回调，无实际显示路径；候选分页仅存在于
            // 自绘 CandidatePanelController，此处维持全量返回。
            composition.mainCandidates
        }
    }

    override nonisolated func menu() -> NSMenu! {
        makeInputMethodMenu()
    }

    func activateSession(for client: any IMKTextInput) {
        let bundleIdentifier = client.bundleIdentifier()
            ?? "unknown-client"
        currentBundleIdentifier = bundleIdentifier
        prewarmPhrasebookEnglishTokens(for: bundleIdentifier)
        let sessionID = applicationSessionID(for: client)
        voiceHotwordAdmission.activate(
            session: voiceHotwordSession(for: client),
            policy: voiceHotwordPolicy(for: bundleIdentifier)
        )
        Self.contextStore.activate(
            sessionID: bundleIdentifier,
            ownerID: sessionNonce
        )
        if composition.appSessionID != sessionID {
            VoiceDictationRuntime.shared.sessionSwitched(owner: self)
            invalidateInference(clearPresentation: true)
            candidatePanel.hide()
            continuationCoordinator.cancel(.sessionSwitched)
            continuationAnchorRect = nil
            composition.switchApplicationSession(to: sessionID)
        }
        configureVoiceHotKey()
    }

    func applicationSessionID(
        for client: any IMKTextInput
    ) -> String {
        let bundleIdentifier = client.bundleIdentifier()
            ?? "unknown-client"
        return "\(bundleIdentifier)#\(sessionNonce)#\(hostFocusEpoch)"
    }

    func adoptActiveClient(_ clientObject: AnyObject) {
        if let activeClientObject, activeClientObject !== clientObject {
            VoiceHotKeyManager.shared.deactivate(owner: self)
            voiceHotKeyIsRegistered = false
            VoiceDictationRuntime.shared.sessionSwitched(owner: self)
            hostFocusEpoch &+= 1
        }
        activeClientObject = clientObject
    }

    func beginHostActivation(_ clientObject: AnyObject) {
        isHostActive = true
        VoiceHotKeyManager.shared.deactivate(owner: self)
        voiceHotKeyIsRegistered = false
        VoiceDictationRuntime.shared.claim(owner: self)
        VoiceDictationRuntime.shared.sessionSwitched(owner: self)
        hostFocusEpoch &+= 1
        activeClientObject = clientObject
    }

    func enterSecureInput(client: any IMKTextInput) {
        VoiceDictationRuntime.shared.secureInputChanged(
            active: true,
            owner: self
        )
        VoiceHotKeyManager.shared.deactivate(owner: self)
        voiceHotKeyIsRegistered = false
        continuationCoordinator.cancel(.secureInput)
        continuationAnchorRect = nil
        invalidateInference(clearPresentation: true)
        composition.enterSecureInput()
        Self.contextStore.enterSecureInput()
        voiceHotwordAdmission.enterSecureInput()
        client.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: notFoundRange
        )
        candidatePanel.hide()
        settings.record(.privacyBlocked)
    }

    func enterSecureInputIfPossible() {
        guard let client = activeClientObject as? any IMKTextInput else {
            VoiceDictationRuntime.shared.secureInputChanged(
                active: true,
                owner: self
            )
            VoiceHotKeyManager.shared.deactivate(owner: self)
            voiceHotKeyIsRegistered = false
            continuationCoordinator.cancel(.secureInput)
            continuationAnchorRect = nil
            invalidateInference(clearPresentation: true)
            composition.enterSecureInput()
            Self.contextStore.enterSecureInput()
            voiceHotwordAdmission.enterSecureInput()
            return
        }
        enterSecureInput(client: client)
    }

    func inferenceContext(
        policy: ContextPolicy,
        client: any IMKTextInput
    ) -> String {
        switch policy {
        case .strict:
            return ""
        case .standard:
            return Self.contextStore.context(
                for: currentBundleIdentifier ?? "unknown-client"
            )
        case .smart:
            let cursorContext = cursorPrecedingContext(client: client)
            if !cursorContext.isEmpty {
                return cursorContext
            }
            return Self.contextStore.context(
                for: currentBundleIdentifier ?? "unknown-client"
            )
        }
    }

    private func cursorPrecedingContext(
        client: any IMKTextInput
    ) -> String {
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.location > 0 else {
            return ""
        }
        let length = min(selection.location, 400)
        let range = NSRange(
            location: selection.location - length,
            length: length
        )
        guard let substring = client.attributedSubstring(from: range) else {
            return ""
        }
        return String(substring.string.suffix(400))
    }

    var notFoundRange: NSRange {
        NSRange(location: NSNotFound, length: NSNotFound)
    }
}
