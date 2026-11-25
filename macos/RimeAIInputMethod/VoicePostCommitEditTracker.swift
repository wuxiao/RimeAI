import AppKit
import ApplicationServices
import Carbon
import Foundation
import InputMethodKit

/// 语音上屏后的短窗口编辑观察器：
/// - 优先通过 IMK (`IMKTextInput.attributedSubstring`) 读取光标附近文本，无需额外权限；
/// - 若宿主不支持 IMK 回读，只有在用户显式开启“通过辅助功能读取光标周边文本”
///   （默认关闭）且进程已获得辅助功能权限时，才降级为只读 `AXUIElement` 回读
///   （绝不弹窗申请权限）；
/// - 若两者均不可用，兜底使用上屏后紧随的 Backspace 计数 + Rime 提交文本提取纠错；
/// - 严格遵守 Secure Event Input 与 strict 隐私策略（全部 fail-closed）。
@MainActor
final class VoicePostCommitEditTracker {
    static let shared = VoicePostCommitEditTracker()

    enum SettleReason {
        case debounce
        case returnKey
        case nextDictation
        case sessionSwitched
        case deactivated
        case windowExpired
    }

    private struct ActiveSession {
        let anchor: VoicePostCommitAnchor
        weak var clientObject: AnyObject?
        let anchorRect: NSRect
        var hasUserEdited: Bool = false
        var tailEditTrackable: Bool = true
        var trailingBackspaces: Int = 0
        var lastRimeCommittedPhrase: String?
        var lastRimeCommittedPinyin: String?
    }

    private let settings: RimeAISettingsStore
    private var activeSession: ActiveSession?
    private var debounceWorkItem: DispatchWorkItem?
    private var expiryWorkItem: DispatchWorkItem?

    var onCorrectionsLearned: (([VoiceLearnedCorrection], NSRect) -> Void)?

    private init() {
        settings = .shared
    }

    /// 测试注入独立设置存储。
    init(settings: RimeAISettingsStore) {
        self.settings = settings
    }

    /// AX 回读是否放行。读取光标周边文本属于额外的隐私边界：必须是
    /// 用户显式 opt-in、进程已授权辅助功能、且不在安全输入之下，三者缺一不可。
    var isAXFallbackReadEnabled: Bool {
        Self.axFallbackReadIsAllowed(
            optIn: settings.voiceAXFallbackReadEnabled,
            isProcessTrusted: AXIsProcessTrusted(),
            isSecureInput: IsSecureEventInputEnabled()
        )
    }

    static func axFallbackReadIsAllowed(
        optIn: Bool,
        isProcessTrusted: Bool,
        isSecureInput: Bool
    ) -> Bool {
        optIn && isProcessTrusted && !isSecureInput
    }

    /// 在语音文本真正写入输入框之前抓取锚点（前缀、后缀与插入偏移）。
    func capturePreCommitAnchor(
        committedText: String,
        bundleIdentifier: String,
        appSessionID: String,
        client: (any IMKTextInput)?,
        selection: NSRange
    ) -> VoicePostCommitAnchor? {
        guard canLearn(for: bundleIdentifier),
              committedText.count >= 2,
              committedText.count <= VoicePostCommitCorrectionLearner
                .maximumTrackedCommittedCharacters,
              !committedText.contains("\n"),
              !committedText.contains("\r")
        else {
            return nil
        }

        var insertionOffset = selection.location
        var prefixAnchor = ""
        var suffixAnchor = ""

        if let client, insertionOffset != NSNotFound {
            if insertionOffset > 0 {
                let prefixLen = min(insertionOffset, 16)
                let prefixRange = NSRange(
                    location: insertionOffset - prefixLen,
                    length: prefixLen
                )
                if let str = readIMKSubstring(client: client, range: prefixRange) {
                    prefixAnchor = str
                }
            }
            let afterOffset = insertionOffset + max(0, selection.length)
            let suffixRange = NSRange(location: afterOffset, length: 16)
            if let str = readIMKSubstring(client: client, range: suffixRange) {
                suffixAnchor = str
            }
        } else if let axSnapshot = readAXAnchorSnapshot() {
            insertionOffset = axSnapshot.offset
            prefixAnchor = axSnapshot.prefix
            suffixAnchor = axSnapshot.suffix
        }

        return VoicePostCommitAnchor(
            committedText: committedText,
            bundleIdentifier: bundleIdentifier,
            appSessionID: appSessionID,
            insertionUTF16Offset: insertionOffset,
            prefixAnchor: prefixAnchor,
            suffixAnchor: suffixAnchor,
            committedAt: Date()
        )
    }

    /// 语音成功上屏后启动观察窗口（仅限非翻译听写、非安全输入且允许学习时）。
    func arm(
        anchor: VoicePostCommitAnchor,
        client: AnyObject?,
        anchorRect: NSRect
    ) {
        guard canLearn(for: anchor.bundleIdentifier) else {
            disarm()
            return
        }
        // 若上一轮观察窗口仍有未结算的修改，先就地结算。
        if activeSession != nil {
            settleActiveSession(reason: .nextDictation)
        }
        disarm()

        activeSession = ActiveSession(
            anchor: anchor,
            clientObject: client,
            anchorRect: anchorRect
        )

        let expiry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.settleActiveSession(reason: .windowExpired)
            }
        }
        expiryWorkItem = expiry
        DispatchQueue.main.asyncAfter(
            deadline: .now() + VoicePostCommitCorrectionLearner.observationWindowSeconds,
            execute: expiry
        )
    }

    /// 无组合态的 Backspace：记录可能发生在语音上屏末尾的回删。
    func noteUncomposedBackspace(client: AnyObject?) {
        guard var session = activeSession else {
            return
        }
        guard !IsSecureEventInputEnabled() else {
            cancelForSecureInput()
            return
        }
        if let tracked = session.clientObject, let client, tracked !== client {
            return
        }
        session.hasUserEdited = true
        if session.tailEditTrackable {
            // 若刚刚已输入替换词再回删，重新统计连续回删。
            if session.lastRimeCommittedPhrase != nil {
                session.tailEditTrackable = false
            } else {
                session.trailingBackspaces += 1
            }
        }
        activeSession = session
        scheduleDebouncedSettle()
    }

    /// 键盘通过 RimeAI 上屏了新词条（可用于提供精确词边界与拼音，也用于回删兜底）。
    func noteKeyboardCommit(
        text: String,
        pinyin: String,
        client: AnyObject?
    ) {
        guard var session = activeSession else {
            return
        }
        guard !IsSecureEventInputEnabled() else {
            cancelForSecureInput()
            return
        }
        if let tracked = session.clientObject, let client, tracked !== client {
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        session.hasUserEdited = true
        session.lastRimeCommittedPhrase = trimmed
        session.lastRimeCommittedPinyin = pinyin.isEmpty ? nil : pinyin
        activeSession = session
        scheduleDebouncedSettle()
    }

    /// 任意其他编辑动作（方向键移动光标、选区覆盖、⌘V 粘贴、英文直输等）。
    func noteDocumentActivity(
        client: AnyObject?,
        invalidatesTailTracking: Bool
    ) {
        guard var session = activeSession else {
            return
        }
        guard !IsSecureEventInputEnabled() else {
            cancelForSecureInput()
            return
        }
        if let tracked = session.clientObject, let client, tracked !== client {
            return
        }
        session.hasUserEdited = true
        if invalidatesTailTracking {
            session.tailEditTrackable = false
        }
        activeSession = session
        scheduleDebouncedSettle()
    }

    /// 立即结算当前活跃会话（如按 Enter 发送消息前、或开始下一次听写前）。
    func settleNowIfMatching(
        client: AnyObject?,
        reason: SettleReason
    ) {
        guard let session = activeSession else {
            return
        }
        if let tracked = session.clientObject, let client, tracked !== client {
            return
        }
        settleActiveSession(reason: reason)
    }

    /// 切换会话或失活时尝试结算后立即撤防。
    func settleAndDisarm(reason: SettleReason) {
        guard activeSession != nil else {
            return
        }
        settleActiveSession(reason: reason)
    }

    /// 进入安全输入时 fail-closed：不读取、不结算、立刻清空全部内存状态。
    func cancelForSecureInput() {
        disarm()
    }

    func clearEphemeralData() {
        disarm()
    }

    // MARK: - Settlement & Persistence

    private func scheduleDebouncedSettle() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.settleActiveSession(reason: .debounce)
            }
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + VoicePostCommitCorrectionLearner.settleDebounceSeconds,
            execute: work
        )
    }

    private func settleActiveSession(reason: SettleReason) {
        guard let session = activeSession else {
            return
        }
        guard !IsSecureEventInputEnabled(),
              canLearn(for: session.anchor.bundleIdentifier)
        else {
            disarm()
            return
        }

        // 若窗口内未观测到任何编辑动作：
        // - 在 debounce / nextDictation / returnKey 时直接撤防（如果窗口结束仍无编辑也撤防）；
        // - 但若用户用鼠标/外设编辑绕过了 IMK 键事件，允许在 returnKey/deactivated/sessionSwitched/windowExpired 时做一次低成本回读检查。
        let shouldAttemptReadback = session.hasUserEdited
            || reason == .returnKey
            || reason == .nextDictation
            || reason == .sessionSwitched
            || reason == .deactivated
            || reason == .windowExpired

        guard shouldAttemptReadback else {
            return
        }

        let corrections = extractCorrections(for: session)
        if !corrections.isEmpty {
            persistAndNotify(
                corrections,
                bundleIdentifier: session.anchor.bundleIdentifier,
                anchorRect: session.anchorRect
            )
            disarm()
            return
        }

        // debounce 阶段未检测到最终纠错（例如用户刚按了 Backspace 还没打完新词）：
        // 保持观察窗口继续等待，直到下次编辑或窗口结束/切换再撤防。
        if reason != .debounce {
            disarm()
        }
    }

    private func extractCorrections(
        for session: ActiveSession
    ) -> [VoiceLearnedCorrection] {
        let anchor = session.anchor

        // 1. 优先尝试 IMK 局部回读
        var documentWindow: String?
        if let inputClient = session.clientObject as? any IMKTextInput {
            documentWindow = readIMKDocumentWindow(
                client: inputClient,
                anchor: anchor
            )
        }

        // 2. IMK 不支持时，仅在已授权辅助功能且非密码框时尝试只读 AX 回读
        if documentWindow == nil {
            documentWindow = readAXDocumentWindow(anchor: anchor)
        }

        if let documentWindow, !documentWindow.isEmpty {
            let extracted = VoicePostCommitCorrectionLearner.extractCorrections(
                anchor: anchor,
                documentWindow: documentWindow,
                hintedRimePhrase: session.lastRimeCommittedPhrase,
                hintedRimePinyin: session.lastRimeCommittedPinyin
            )
            if !extracted.isEmpty {
                return extracted
            }
        } else if session.tailEditTrackable,
                  session.trailingBackspaces > 0,
                  let phrase = session.lastRimeCommittedPhrase
        {
            // 3. 宿主既不提供 IMK attributedSubstring 也没有 AX 权限：
            // 走纯输入法侧「回删计数 + Rime 新上屏词」兜底提取。
            let tailEdit = VoicePostCommitTailEdit(
                deletedTrailingCharacters: session.trailingBackspaces,
                replacementText: phrase,
                replacementPinyin: session.lastRimeCommittedPinyin
            )
            if let fallback = VoicePostCommitCorrectionLearner
                .extractCorrectionFromTailEdit(
                    committedText: anchor.committedText,
                    tailEdit: tailEdit
                )
            {
                return [fallback]
            }
        }

        return []
    }

    private func persistAndNotify(
        _ corrections: [VoiceLearnedCorrection],
        bundleIdentifier: String,
        anchorRect: NSRect
    ) {
        guard !IsSecureEventInputEnabled(),
              canLearn(for: bundleIdentifier)
        else {
            return
        }
        var newlyLearned: [VoiceLearnedCorrection] = []
        for correction in corrections {
            let changed = settings.recordVoiceLearnedCorrection(
                wrong: correction.wrongText,
                corrected: correction.correctedText,
                hotword: correction.hotword
            )
            if let pinyin = correction.pinyinKeys, !pinyin.isEmpty {
                RimeAIPhraseBookService.shared.recordVoiceLearnedPhraseAsync(
                    text: correction.hotword,
                    pinyinKeys: pinyin,
                    bundleIdentifier: bundleIdentifier
                )
            }
            if changed {
                settings.record(.voiceCorrectionLearned)
                newlyLearned.append(correction)
            }
        }
        if !newlyLearned.isEmpty {
            onCorrectionsLearned?(newlyLearned, anchorRect)
        }
    }

    private func disarm() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        expiryWorkItem?.cancel()
        expiryWorkItem = nil
        activeSession = nil
    }

    private func canLearn(for bundleIdentifier: String) -> Bool {
        !IsSecureEventInputEnabled()
            && settings.aiEnabled
            && settings.voiceEnabled
            && settings.voiceAutoLearnCorrectionsEnabled
            && settings.isAIAllowed(for: bundleIdentifier)
            && settings.contextPolicy(for: bundleIdentifier) != .strict
    }

    // MARK: - IMK Document Readback

    private func readIMKDocumentWindow(
        client: any IMKTextInput,
        anchor: VoicePostCommitAnchor
    ) -> String? {
        let currentSelection = client.selectedRange()
        let baseOffset: Int
        if anchor.insertionUTF16Offset != NSNotFound {
            baseOffset = anchor.insertionUTF16Offset
        } else if currentSelection.location != NSNotFound {
            baseOffset = max(
                0,
                currentSelection.location - anchor.committedText.utf16.count
            )
        } else {
            return nil
        }

        let start = max(0, baseOffset - 24)
        let prefixSpan = baseOffset - start
        let committedUTF16 = anchor.committedText.utf16.count
        let desiredLength = min(
            VoicePostCommitCorrectionLearner.maximumReadbackCharacters,
            prefixSpan + committedUTF16 + 48
        )

        // 先尝试宽松长度；部分宿主对超出文档末尾的 NSRange 返回 nil，
        // 失败时按当前光标位置逐步收窄重试。
        var candidateLengths: [Int] = [desiredLength]
        if currentSelection.location != NSNotFound,
           currentSelection.location >= start
        {
            let upToCaret = currentSelection.location - start
            if upToCaret > 0 {
                candidateLengths.append(min(desiredLength, upToCaret + 24))
                candidateLengths.append(min(desiredLength, upToCaret))
            }
        }
        candidateLengths.append(min(desiredLength, prefixSpan + committedUTF16 + 16))
        candidateLengths.append(min(desiredLength, prefixSpan + committedUTF16))

        var tried = Set<Int>()
        for length in candidateLengths where length > 0 && tried.insert(length).inserted {
            let range = NSRange(location: start, length: length)
            if let text = readIMKSubstring(client: client, range: range),
               !text.isEmpty
            {
                return text
            }
        }
        return nil
    }

    private func readIMKSubstring(
        client: any IMKTextInput,
        range: NSRange
    ) -> String? {
        guard range.location != NSNotFound, range.length > 0 else {
            return nil
        }
        guard let attributed = client.attributedSubstring(from: range) else {
            return nil
        }
        let value = attributed.string
        return value.isEmpty ? nil : value
    }

    // MARK: - Optional Read-Only Accessibility Fallback (Never Prompts)

    private struct AXAnchorSnapshot {
        let offset: Int
        let prefix: String
        let suffix: String
    }

    private func focusedSafeAXElement() -> AXUIElement? {
        guard isAXFallbackReadEnabled else {
            return nil
        }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
        let focusedRef,
        CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let element = focusedRef as! AXUIElement
        // 严禁读取任何密码/安全输入框。
        if let subrole = axStringAttribute(element, kAXSubroleAttribute),
           subrole == "AXSecureTextField"
        {
            return nil
        }
        if let role = axStringAttribute(element, kAXRoleAttribute),
           role == "AXSecureTextField"
        {
            return nil
        }
        return element
    }

    private func readAXAnchorSnapshot() -> AXAnchorSnapshot? {
        guard let element = focusedSafeAXElement(),
              let selection = axSelectedRange(element)
        else {
            return nil
        }
        let offset = selection.location
        guard offset >= 0 else {
            return nil
        }
        let prefixLen = min(offset, 16)
        let prefix = prefixLen > 0
            ? (axSubstring(element, location: offset - prefixLen, length: prefixLen) ?? "")
            : ""
        let suffix = axSubstring(
            element,
            location: offset + max(0, selection.length),
            length: 16
        ) ?? ""
        return AXAnchorSnapshot(offset: offset, prefix: prefix, suffix: suffix)
    }

    private func readAXDocumentWindow(
        anchor: VoicePostCommitAnchor
    ) -> String? {
        guard let element = focusedSafeAXElement() else {
            return nil
        }
        let committedUTF16 = anchor.committedText.utf16.count
        let desiredLen = min(
            VoicePostCommitCorrectionLearner.maximumReadbackCharacters,
            committedUTF16 + 72
        )

        if anchor.insertionUTF16Offset != NSNotFound {
            let start = max(0, anchor.insertionUTF16Offset - 24)
            if let paramText = axSubstring(
                element,
                location: start,
                length: desiredLen
            ), !paramText.isEmpty {
                return paramText
            }
        }

        // 部分 Electron/Web 文本框不实现 parameterized stringForRange，
        // 但允许读取短文本 kAXValueAttribute（仅在长度可控时读取，避免大文档开销）。
        if let totalChars = axIntAttribute(element, kAXNumberOfCharactersAttribute),
           totalChars > 16_000
        {
            return nil
        }
        guard let fullValue = axStringAttribute(element, kAXValueAttribute),
              !fullValue.isEmpty,
              fullValue.utf16.count <= 16_000
        else {
            return nil
        }

        let nsFull = fullValue as NSString
        if anchor.insertionUTF16Offset != NSNotFound {
            let start = max(0, min(anchor.insertionUTF16Offset - 24, nsFull.length))
            let len = min(desiredLen, nsFull.length - start)
            guard len > 0 else {
                return nil
            }
            return nsFull.substring(with: NSRange(location: start, length: len))
        }
        if !anchor.prefixAnchor.isEmpty,
           let range = fullValue.range(of: anchor.prefixAnchor)
        {
            let startOffset = fullValue.distance(
                from: fullValue.startIndex,
                to: range.lowerBound
            )
            let slice = fullValue.dropFirst(startOffset)
            return String(
                slice.prefix(
                    VoicePostCommitCorrectionLearner.maximumReadbackCharacters
                )
            )
        }
        return String(
            fullValue.suffix(
                VoicePostCommitCorrectionLearner.maximumReadbackCharacters
            )
        )
    }

    private func axStringAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func axIntAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let number = value as? NSNumber
        else {
            return nil
        }
        return number.intValue
    }

    private func axSelectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private func axSubstring(
        _ element: AXUIElement,
        location: Int,
        length: Int
    ) -> String? {
        guard location >= 0, length > 0 else {
            return nil
        }
        var cfRange = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        ) == .success else {
            return nil
        }
        return result as? String
    }
}
