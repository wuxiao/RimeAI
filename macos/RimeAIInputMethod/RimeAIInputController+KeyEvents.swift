import AppKit
import InputMethodKit

/// 按键事件处理：前置路由（宿主激活/Secure Input/语音/修饰键）、
/// 功能键分派与字符路径（数字选词、字母、标点、flush-then-dispatch）。
extension RimeAIInputController {
    func handleOnMain(
        _ event: NSEvent!,
        client sender: Any!
    ) -> Bool {
        guard event?.type == .keyDown,
              let client = sender as? any IMKTextInput
        else {
            return false
        }
        // Tab 接受续写 chip 必须先于 prelude：上屏后宿主可能已结束旧
        // 输入会话，prelude 的会话重建会先 cancel(.sessionSwitched)
        // 把 chip 撤掉，导致 Tab 永远无法接受。仅裸 Tab 接受——
        // Shift/Option 等修饰组合属于宿主的焦点导航，不得吞掉。
        let isBareTab = event.keyCode == 48
            && event.modifierFlags.intersection(
                [.command, .control, .option, .shift]
            ).isEmpty
        if isBareTab,
           candidatePanel.acceptContinuationIfShowing()
        {
            return true
        }
        if let resolved = resolveKeyEventPrelude(event, client: client) {
            return resolved
        }
        if !composition.hasComposition, !isBareTab {
            // 无组合内容时的任意按键：续写 chip 即刻撤销。
            // 裸 Tab 除外——它是续写 chip 的接受键，由
            // handleTabKey 走接受路径。
            continuationCoordinator.cancel(.userTyped)
            continuationAnchorRect = nil
        }
        switch event.keyCode {
        case 51:
            return deleteBackward(client: client)
        case 53:
            return handleEscapeKey(client: client)
        case 36, 76:
            return handleReturnKey(client: client)
        case 48:
            return handleTabKey(client: client)
        case 49:
            return handleSpaceKey(client: client)
        case 27, 24:
            // shift + `-`/`=` 是下划线/加号字面量，不参与候选翻页：
            // 段间下划线分段（KBD-005）依赖它进入字符路径后作为
            // 字面量定稿前缀段。
            if event.modifierFlags.contains(.shift) {
                break
            }
            if let resolved = handleCandidatePageKey(event, client: client) {
                return resolved
            }
        case 123, 124, 125, 126, 116, 121:
            return handleArrowKey(event, client: client)
        default:
            break
        }
        return handleCharacterInput(event, client: client)
    }

    /// 按键前置处理（宿主激活、Secure Input、语音路由、修饰键）。
    /// 返回 nil 表示继续正常按键分派；非 nil 为该事件的最终返回值。
    private func resolveKeyEventPrelude(
        _ event: NSEvent,
        client: any IMKTextInput
    ) -> Bool? {
        if isHostActive {
            adoptActiveClient(client as AnyObject)
        } else {
            beginHostActivation(client as AnyObject)
        }
        activateSession(for: client)
        if IsSecureEventInputEnabled() {
            enterSecureInput(client: client)
            return false
        }
        if composition.isSecureInput {
            recoverFromSecureInputSession(client: client)
        }
        if let consumed = resolveVoiceKeyRouting(event) {
            return consumed
        }
        VoiceDictationRuntime.shared.dismissTransientPanel(owner: self)
        let modifiers = event.modifierFlags.intersection(
            [.command, .control, .option]
        )
        if !modifiers.isEmpty {
            invalidateCurrentResult()
            return false
        }
        return nil
    }

    /// Secure Input 解除后的首个真实键事件：迁移会话并恢复热键注册。
    private func recoverFromSecureInputSession(client: any IMKTextInput) {
        composition.switchApplicationSession(
            to: applicationSessionID(for: client)
        )
        Self.contextStore.activate(
            sessionID: client.bundleIdentifier() ?? "unknown-client",
            ownerID: sessionNonce
        )
        VoiceDictationRuntime.shared.secureInputChanged(
            active: false,
            owner: self
        )
        configureVoiceHotKey()
    }

    /// 语音键路由。返回 nil 表示语音层不消费该事件。
    private func resolveVoiceKeyRouting(_ event: NSEvent) -> Bool? {
        let voiceRuntime = VoiceDictationRuntime.shared
        let voiceDecision = VoiceDictationKeyRouter.decision(
            keyCode: event.keyCode,
            isExactVoiceShortcut: isVoiceShortcut(event),
            shortcutRegistered: voiceHotKeyIsRegistered,
            hasActiveSession: voiceRuntime.isActive(owner: self),
            pendingConfirmation: voiceRuntime.isPendingConfirmation(owner: self),
            isPlainConfirmationKey: VoiceDictationKeyRouter
                .isPlainConfirmation(
                    modifiers: voiceKeyModifiers(event.modifierFlags)
                )
        )
        switch voiceDecision {
        case .consumeShortcut:
            return true
        case .confirm:
            voiceRuntime.confirm(owner: self)
            return true
        case .cancelAndConsume:
            cancelVoiceDictation()
            return true
        case .cancelAndContinue:
            // 先使语音目标永久失效，再继续原有键盘路径。
            cancelVoiceDictation()
        case .passThrough:
            break
        }
        return nil
    }

    private func handleEscapeKey(client: any IMKTextInput) -> Bool {
        guard composition.hasComposition else {
            return false
        }
        resetComposition(client: client)
        return true
    }

    private func handleReturnKey(client: any IMKTextInput) -> Bool {
        guard composition.hasComposition else {
            return false
        }
        commitText(
            composition.rawCompositionString,
            source: .rawPinyin,
            client: client,
            historyPinyin: composition.historyPinyin
        )
        return true
    }

    private func handleTabKey(client: any IMKTextInput) -> Bool {
        if let semanticCandidate = composition.semanticCandidate {
            // KBD-007：跨段整句建议（段数 ≥ 2）先按段应用不提交，
            // 用户可 ←→ 逐段复核后经 Space 上屏；不符合条件时回退
            // 既有整句提交路径。
            if applySegmentedSuggestionIfEligible(
                semanticCandidate,
                client: client
            ) {
                return true
            }
            selectSemanticCandidate(semanticCandidate, client: client)
            return true
        }
        // 云端表态"与首选一致"：无独立语义候选可采纳，Tab 直接上屏
        // 该一致首选（全局第一候选，与表态的比较基准相同）；走主候选
        // 选择路径以保留 Rime 学习与历史记录。
        if pipeline.presentation.tabCommitsFirstMainCandidate,
           !composition.mainCandidates.isEmpty
        {
            selectMainCandidate(index: 0, client: client)
            return true
        }
        // 有 composition（含仅前缀）时 Tab 不能直通，否则宿主
        // 对 marked range 的原生处理会吞掉编码区。
        return composition.hasComposition
    }

    private func handleSpaceKey(client: any IMKTextInput) -> Bool {
        if !composition.mainCandidates.isEmpty {
            selectMainCandidate(
                index: currentCommitCandidateIndex,
                client: client
            )
            return true
        }
        if let semanticCandidate = composition.semanticCandidate {
            selectSemanticCandidate(semanticCandidate, client: client)
            return true
        }
        guard composition.pinyin.isEmpty else {
            commitText(
                composition.rawCompositionString,
                source: .rawPinyin,
                client: client,
                historyPinyin: composition.historyPinyin
            )
            return true
        }
        if composition.hasComposition {
            // 仅前缀状态：Space 提交前缀定稿，空格字面随后按
            // 现有宽度偏好处理。
            flushCompositionAsFinal(client: client)
        }
        if let literal = transformedLiteral(" ") {
            client.insertText(literal, replacementRange: notFoundRange)
            return true
        }
        return false
    }

    /// 候选翻页（`=` 向后 / `-` 向前）。返回 nil 表示面板没有候选可翻，
    /// 调用方继续按普通符号路径处理该键——仅前缀或混输无候选态下，
    /// 这两个字符必须仍然可以输入，而不是被静默吞掉。
    private func handleCandidatePageKey(
        _ event: NSEvent,
        client: any IMKTextInput
    ) -> Bool? {
        guard !composition.mainCandidates.isEmpty else {
            return nil
        }
        let moved = event.keyCode == 24
            ? composition.advanceCandidatePage()
            : composition.retreatCandidatePage()
        if moved {
            refreshCandidatePanelIfActive()
        }
        return true
    }

    /// 方向键：←/→ 在拼音段之间移动焦点（任意段修正）。焦点移
    /// 动后新焦点段按其拼音重新查候选；↑↓/PgUp/PgDn 与无可聚焦
    /// 段时维持既有行为（活跃段空且存在前缀时吞掉，其余透传）。
    private func handleArrowKey(
        _ event: NSEvent,
        client: any IMKTextInput
    ) -> Bool {
        let keyCode = event.keyCode
        guard keyCode == 123 || keyCode == 124 else {
            return swallowOrPassThroughArrow(client: client)
        }
        if keyCode == 123, composition.canMoveFocusLeft {
            composition.moveFocusLeft(
                finalizedText: activeSegmentFinalizedText()
            )
            invalidateInference(clearPresentation: true)
            compositionInput(composition.pinyin, client: client)
            scheduleSuffixRefinement(client: client)
            return true
        }
        if keyCode == 124, composition.canMoveFocusRight {
            composition.moveFocusRight(
                finalizedText: activeSegmentFinalizedText()
            )
            invalidateInference(clearPresentation: true)
            compositionInput(composition.pinyin, client: client)
            scheduleSuffixRefinement(client: client)
            return true
        }
        return swallowOrPassThroughArrow(client: client)
    }

    /// 既有方向键行为：活跃段空且存在前缀时吞掉（marked range 与
    /// 状态失联防护），其余透传。
    private func swallowOrPassThroughArrow(client: any IMKTextInput) -> Bool {
        invalidateCurrentResult()
        if composition.pinyin.isEmpty, !composition.prefixSegments.isEmpty {
            return true
        }
        clearContextForCurrentApplication()
        return false
    }

    /// 字符路径：数字选词 → Shift 直通 → 拼音字母 → 标点（首键直接
    /// 上屏，进行中进 composition）→ 未映射符号 flush-then-dispatch。
    private func handleCharacterInput(
        _ event: NSEvent,
        client: any IMKTextInput
    ) -> Bool {
        let characters = event.charactersIgnoringModifiers ?? ""
        if let resolved = handleNumericSelection(
            from: characters,
            event: event,
            client: client
        ) {
            return resolved
        }
        if event.modifierFlags.contains(.shift),
           !composition.hasComposition
        {
            return false
        }
        if let character = acceptedCompositionCharacter(
            from: event.characters ?? characters
        ) {
            compositionInput(
                composition.pinyin + String(character),
                client: client
            )
            configureVoiceHotKey()
            return true
        }
        return handleLiteralInput(event, characters: characters, client: client)
    }

    /// 数字键选词。仅前缀状态无候选可选：先提交前缀，数字键作为
    /// 普通字符放行。
    private func handleNumericSelection(
        from characters: String,
        event: NSEvent,
        client: any IMKTextInput
    ) -> Bool? {
        guard let candidateIndex = numericCandidateIndex(from: characters),
              composition.hasComposition
        else {
            return nil
        }
        if !composition.pinyin.isEmpty {
            if let globalIndex = composition.globalCandidateIndex(
                forPageSlot: candidateIndex + 1
            ) {
                selectMainCandidate(index: globalIndex, client: client)
            }
            return true
        }
        flushCompositionAsFinal(client: client)
        return false
    }

    /// 标点/未映射符号路径：空缓冲（第一个字符）时标点直接上屏，
    /// 不进入组词缓冲；composition 进行中标点进入 composition；
    /// 未映射符号先整段提交（前缀定稿 + 当前内容）再放行该符号，
    /// 保持"符号出现在文本流"的既有语义。
    private func handleLiteralInput(
        _ event: NSEvent,
        characters: String,
        client: any IMKTextInput
    ) -> Bool {
        let keyCharacters = event.characters ?? characters
        if let scalar = keyCharacters.unicodeScalars.first,
           keyCharacters.unicodeScalars.count == 1
        {
            if let leadingCommit = RimeAIInputTextTransformer
                .leadingLiteralCommitText(
                    scalar,
                    hasComposition: composition.hasComposition,
                    preferences: settings.inputPreferences
                )
            {
                client.insertText(
                    leadingCommit,
                    replacementRange: notFoundRange
                )
                return true
            }
            // 组合进行中的下划线：半角字面量进入 composition（段间
            // 分隔符，KBD-005），优先于标点表与 flush 判定。
            if composition.hasComposition,
               let segmentLiteral = RimeAIInputTextTransformer
                   .compositionSegmentLiteralText(scalar)
            {
                appendCompositionLiteral(segmentLiteral, client: client)
                configureVoiceHotKey()
                return true
            }
            if let literalText = RimeAIInputTextTransformer
                .compositionLiteralText(
                    scalar,
                    preferences: settings.inputPreferences
                )
            {
                appendCompositionLiteral(literalText, client: client)
                configureVoiceHotKey()
                return true
            }
        }
        let literal = transformedLiteral(keyCharacters)
        if composition.hasComposition {
            flushCompositionAsFinal(client: client)
            return false
        } else if let literal {
            client.insertText(literal, replacementRange: notFoundRange)
            return true
        }
        return false
    }

    func deleteBackward(client: any IMKTextInput) -> Bool {
        if !composition.pinyin.isEmpty {
            var updated = composition.pinyin
            updated.removeLast()
            if updated.isEmpty {
                if composition.prefixSegments.isEmpty {
                    resetComposition(client: client)
                } else {
                    // 活跃段删空但前缀仍在编辑：保留前缀与显示。
                    composition.clearActivePinyin()
                    invalidateInference(clearPresentation: true)
                    client.setMarkedText(
                        composition.displayString,
                        selectionRange: NSRange(
                            location: composition.displayString.utf16.count,
                            length: 0
                        ),
                        replacementRange: notFoundRange
                    )
                    candidatePanel.hide()
                }
            } else {
                compositionInput(updated, client: client)
            }
            return true
        }
        if composition.popTrailingLiteral() != nil {
            // 删除末尾标点，前缀其余部分保持。
            invalidateInference(clearPresentation: true)
            client.setMarkedText(
                composition.displayString,
                selectionRange: NSRange(
                    location: composition.displayString.utf16.count,
                    length: 0
                ),
                replacementRange: notFoundRange
            )
            return true
        }
        if composition.moveFocusLeft() {
            // 前一个拼音段复活为焦点段继续编辑。
            compositionInput(composition.pinyin, client: client)
            return true
        }
        return false
    }

    /// 提交基准索引：翻页后为当前页第一个候选，未翻页时即全局首选；
    /// 页状态异常时回落 0。Space 与 flush-then-dispatch 共用，保证
    /// "当前高亮项上屏"的体验一致；IMK 强制提交已改为原样上屏，
    /// 不再走此索引。
    var currentCommitCandidateIndex: Int {
        composition.globalCandidateIndex(forPageSlot: 1) ?? 0
    }

    /// 活跃段定稿文本：与提交路径同一基准（当前页第一项候选），
    /// 字形转换到用户偏好（Rime 简繁选项异步应用的窗口期里，
    /// mainCandidates 可能仍是繁体，不能原样上屏）；无法转换或
    /// 无候选（混输态）时回退原始字母。
    func activeSegmentFinalizedText() -> String? {
        guard !composition.pinyin.isEmpty else {
            return nil
        }
        let index = currentCommitCandidateIndex
        guard composition.mainCandidates.indices.contains(index) else {
            return composition.pinyin
        }
        return SemanticCandidateScriptPolicy.sanitized(
            text: composition.mainCandidates[index],
            characterSet: settings.characterSet
        ) ?? composition.pinyin
    }

    /// 标点/符号进入 composition：定稿活跃段并追加字面量段，绝不
    /// 触发上屏。面板与推断随之收敛到"仅前缀"状态。
    func appendCompositionLiteral(
        _ text: String,
        client: any IMKTextInput
    ) {
        cancelVoiceDictation()
        invalidateInference(clearPresentation: true)
        pipeline.markUnavailable()
        composition.appendLiteral(
            text,
            finalizedText: activeSegmentFinalizedText()
        )
        client.setMarkedText(
            composition.displayString,
            selectionRange: NSRange(
                location: composition.displayString.utf16.count,
                length: 0
            ),
            replacementRange: notFoundRange
        )
        candidatePanel.hide()
        configureVoiceHotKey()
    }

    /// flush-then-dispatch：把整段 composition（定稿前缀 + 活跃内容）
    /// 作为最终文本提交。活跃段有候选时取 Rime 首选，无候选（混输
    /// 态等）回落原始字母，与 `appendLiteral` 的定稿语义一致；语义
    /// 候选不参与，AI 候选仅可经 Tab 显式采用。
    @discardableResult
    func flushCompositionAsFinal(client: any IMKTextInput) -> Bool {
        guard composition.hasComposition else {
            return false
        }
        if !composition.pinyin.isEmpty {
            if !composition.mainCandidates.isEmpty {
                selectMainCandidate(
                    index: currentCommitCandidateIndex,
                    client: client
                )
            } else {
                commitText(
                    composition.rawCompositionString,
                    source: .rawPinyin,
                    client: client,
                    historyPinyin: composition.historyPinyin
                )
            }
            return true
        }
        return commitText(
            composition.committedOuterText,
            source: .rimeMain,
            client: client,
            historyPinyin: composition.historyPinyin
        )
    }

    func transformedLiteral(_ literal: String) -> String? {
        RimeAIInputTextTransformer.transformedLiteral(
            literal,
            preferences: settings.inputPreferences
        )
    }

    func acceptedCompositionCharacter(
        from characters: String
    ) -> Character? {
        guard characters.count == 1,
              let character = characters.first,
              character == "'" || character.isASCII && character.isLetter
        else {
            return nil
        }
        return character
    }

    func numericCandidateIndex(
        from characters: String
    ) -> Int? {
        guard characters.count == 1,
              let character = characters.first,
              character.isNumber
        else {
            return nil
        }
        if character == "0" {
            return 9
        }
        guard let value = character.wholeNumberValue else {
            return nil
        }
        return value - 1
    }
}
