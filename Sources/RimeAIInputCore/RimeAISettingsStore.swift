import Foundation

public extension Notification.Name {
    static let rimeAISettingsDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.settings-did-change"
    )
    static let rimeAIClearEphemeralData = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.clear-ephemeral-data"
    )
    static let rimeAIDiagnosticsDidChange = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.diagnostics-did-change"
    )
    static let rimeAIVoiceRetryRequested = Notification.Name(
        "fun.wwcn.inputmethod.RimeAI.voice-retry-requested"
    )
}

public enum RimeAIDiagnosticEvent: String, CaseIterable, Codable, Sendable {
    case requestStarted = "request_started"
    case requestCancelled = "request_cancelled"
    case resultShown = "result_shown"
    case resultRejected = "result_rejected"
    case staleResult = "stale_result"
    case supersededByNeuralLate = "superseded_by_neural_late"
    case invalidResult = "invalid_result"
    case sameTopCandidate = "same_top_candidate"
    case insufficientCandidates = "insufficient_candidates"
    case belowConfidence = "below_confidence"
    case noCandidate = "no_candidate"
    case rankedCandidateShown = "ranked_candidate_shown"
    case phraseBookSuggestionShown = "phrase_book_suggestion_shown"
    case phraseBookSuggestionAccepted = "phrase_book_suggestion_accepted"
    case sentenceSuggestionShown = "sentence_suggestion_shown"
    case mixedCompositionShown = "mixed_composition_shown"
    case sentenceTooLong = "sentence_too_long"
    case sentenceIncomplete = "sentence_incomplete"
    case inputTooLong = "input_too_long"
    case sentenceScriptMismatch = "sentence_script_mismatch"
    case semanticAccepted = "semantic_accepted"
    case semanticRankedAccepted = "semantic_ranked_accepted"
    case semanticSentenceAccepted = "semantic_sentence_accepted"
    case mixedCompositionAccepted = "mixed_composition_accepted"
    case mainAccepted = "main_accepted"
    case privacyBlocked = "privacy_blocked"
    case timeout
    case circuitOpen = "circuit_open"
    case daemonFailure = "daemon_failure"
    case historyRecorded = "history_recorded"
    case historyWriteFailed = "history_write_failed"
    case cloudRequestStarted = "cloud_request_started"
    case cloudSuggestionShown = "cloud_suggestion_shown"
    case cloudSuggestionAccepted = "cloud_suggestion_accepted"
    case cloudCorrectionShown = "cloud_correction_shown"
    case cloudCorrectionAccepted = "cloud_correction_accepted"
    case cloudGeneratedShown = "cloud_generated_shown"
    case cloudGeneratedAccepted = "cloud_generated_accepted"
    case cloudGenerateReceived = "cloud_generate_received"
    case modelDowngraded = "model_downgraded"
    case cloudTimeout = "cloud_timeout"
    case cloudInvalidResult = "cloud_invalid_result"
    case cloudInvalidRequest = "cloud_invalid_request"
    case cloudTransportFailure = "cloud_transport_failure"
    case voiceStarted = "voice_started"
    case voiceStopped = "voice_stopped"
    case voicePreviewShown = "voice_preview_shown"
    case voiceFinalShown = "voice_final_shown"
    case voiceAccepted = "voice_accepted"
    case voiceCancelled = "voice_cancelled"
    case voiceMicrophoneDenied = "voice_microphone_denied"
    case voiceFailure = "voice_failure"
    case voiceDisabled = "voice_disabled"
    case voicePolished = "voice_polished"
    case voiceTranslated = "voice_translated"
    case voiceAutoPasted = "voice_auto_pasted"
    case voiceCorrectionLearned = "voice_correction_learned"
    case continuationRequested = "continuation_requested"
    case continuationShown = "continuation_shown"
    case continuationAccepted = "continuation_accepted"
    case continuationDismissed = "continuation_dismissed"
    case continuationDismissedUserTyped =
        "continuation_dismissed_user_typed"
    case continuationDismissedCompositionBegan =
        "continuation_dismissed_composition_began"
    case continuationDismissedSessionSwitched =
        "continuation_dismissed_session_switched"
    case continuationDismissedSecureInput =
        "continuation_dismissed_secure_input"
    case continuationDismissedDeactivated =
        "continuation_dismissed_deactivated"
    case continuationDismissedTimedOut =
        "continuation_dismissed_timed_out"
    case continuationAbstained = "continuation_abstained"
    case continuationCooldown = "continuation_cooldown"
}

public struct RimeAISettingsExport: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case inputPreferences
        case aiEnabled
        case offlineLockEnabled
        case cloudConfigured
        case cloudProvider
        case cloudEndpoint
        case cloudModelID
        case voiceEnabled
        case voiceShortcut
        case voiceSecondaryShortcut
        case voiceSecondaryShortcutDisabled
        case voiceRimeHotwordsEnabled
        case voicePhraseBookHotwordsEnabled
        case voiceCustomHotwords
        case voiceAutoLearnCorrectionsEnabled
        case voiceLearnedCorrections
        case voiceLearnedCorrectionsOrder
        case voiceHistoryEnabled
        case voiceSmartPolishEnabled
        case voicePolishStyle
        case voiceTranslateShortcut
        case voiceTranslateTargetLanguage
        case voiceAutoPasteEnabled
        case voiceSoundEffectsEnabled
        case voiceMuteSystemAudioEnabled
        case voiceCloudHotwordsEnabled
        case voiceAXFallbackReadEnabled
        case continuationSuggestionEnabled
        case contextPolicy
        case disabledAIApplications
        case disabledContextApplications
        case diagnostics
    }

    public let schemaVersion: Int
    public let inputPreferences: RimeAIInputPreferences
    public let aiEnabled: Bool
    public let offlineLockEnabled: Bool
    public let cloudConfigured: Bool
    public let cloudProvider: String
    public let cloudEndpoint: String
    public let cloudModelID: String
    public let voiceEnabled: Bool
    public let voiceShortcut: VoiceDictationShortcut
    public let voiceSecondaryShortcut: VoiceDictationShortcut?
    /// 备用听写快捷键是否被用户显式清除。与 `voiceSecondaryShortcut == nil` 同时成立
    /// 表示「保持未绑定」；两者皆无表示「沿用默认值（右 ⌘）」。
    public let voiceSecondaryShortcutDisabled: Bool
    public let voiceRimeHotwordsEnabled: Bool
    public let voicePhraseBookHotwordsEnabled: Bool
    public let voiceCustomHotwords: [String]
    public let voiceAutoLearnCorrectionsEnabled: Bool
    /// 错词 → 正词映射（无序）；`voiceLearnedCorrectionsOrder` 保存其最近使用顺序。
    public let voiceLearnedCorrections: [String: String]
    /// 学习到的纠错词条的最近使用顺序（旧 → 新）。128 条上限淘汰的是最旧条目，
    /// 因此必须与映射一起导出 / 导入，否则导入后新学词条会被字母序淘汰。
    public let voiceLearnedCorrectionsOrder: [String]
    public let voiceHistoryEnabled: Bool
    public let voiceSmartPolishEnabled: Bool
    public let voicePolishStyle: VoicePolishStyle
    public let voiceTranslateShortcut: VoiceDictationShortcut
    public let voiceTranslateTargetLanguage: VoiceTranslationLanguage
    public let voiceAutoPasteEnabled: Bool
    public let voiceSoundEffectsEnabled: Bool
    public let voiceMuteSystemAudioEnabled: Bool
    /// 允许云端润色 / 翻译请求携带热词上下文（独立 opt-in，默认关闭）。
    public let voiceCloudHotwordsEnabled: Bool
    /// 允许在无法直接读取编辑结果时使用只读辅助功能（AX）回退回读
    /// （独立 opt-in，默认关闭）。
    public let voiceAXFallbackReadEnabled: Bool
    public let continuationSuggestionEnabled: Bool
    public let contextPolicy: ContextPolicy
    public let disabledAIApplications: [String]
    public let disabledContextApplications: [String]
    public let diagnostics: [String: Int]

    public init(
        schemaVersion: Int = 8,
        inputPreferences: RimeAIInputPreferences = RimeAIInputPreferences(),
        aiEnabled: Bool,
        offlineLockEnabled: Bool,
        cloudConfigured: Bool = false,
        cloudProvider: String = RimeAICloudConfiguration.provider,
        cloudEndpoint: String = RimeAICloudConfiguration.endpoint.absoluteString,
        cloudModelID: String = RimeAICloudConfiguration.defaultRankingModelID,
        voiceEnabled: Bool = false,
        voiceShortcut: VoiceDictationShortcut = .default,
        voiceSecondaryShortcut: VoiceDictationShortcut? = nil,
        voiceSecondaryShortcutDisabled: Bool = false,
        voiceRimeHotwordsEnabled: Bool = false,
        voicePhraseBookHotwordsEnabled: Bool = true,
        voiceCustomHotwords: [String] = [],
        voiceAutoLearnCorrectionsEnabled: Bool = true,
        voiceLearnedCorrections: [String: String] = [:],
        voiceLearnedCorrectionsOrder: [String] = [],
        voiceHistoryEnabled: Bool = true,
        voiceSmartPolishEnabled: Bool = true,
        voicePolishStyle: VoicePolishStyle = .concise,
        voiceTranslateShortcut: VoiceDictationShortcut = .defaultTranslate,
        voiceTranslateTargetLanguage: VoiceTranslationLanguage = .autoEnZh,
        voiceAutoPasteEnabled: Bool = true,
        voiceSoundEffectsEnabled: Bool = true,
        voiceMuteSystemAudioEnabled: Bool = true,
        voiceCloudHotwordsEnabled: Bool = false,
        voiceAXFallbackReadEnabled: Bool = false,
        continuationSuggestionEnabled: Bool = false,
        contextPolicy: ContextPolicy,
        disabledAIApplications: [String],
        disabledContextApplications: [String],
        diagnostics: [String: Int]
    ) {
        self.schemaVersion = schemaVersion
        self.inputPreferences = inputPreferences
        self.aiEnabled = aiEnabled
        self.offlineLockEnabled = offlineLockEnabled
        self.cloudConfigured = cloudConfigured
        self.cloudProvider = cloudProvider
        self.cloudEndpoint = cloudEndpoint
        self.cloudModelID = cloudModelID
        self.voiceEnabled = voiceEnabled
        self.voiceShortcut = voiceShortcut
        self.voiceSecondaryShortcut =
            voiceSecondaryShortcut == voiceShortcut
            ? nil
            : voiceSecondaryShortcut
        self.voiceSecondaryShortcutDisabled =
            self.voiceSecondaryShortcut == nil && voiceSecondaryShortcutDisabled
        self.voiceRimeHotwordsEnabled = voiceRimeHotwordsEnabled
        self.voicePhraseBookHotwordsEnabled = voicePhraseBookHotwordsEnabled
        self.voiceCustomHotwords = voiceCustomHotwords
        self.voiceAutoLearnCorrectionsEnabled = voiceAutoLearnCorrectionsEnabled
        self.voiceLearnedCorrections = voiceLearnedCorrections
        self.voiceLearnedCorrectionsOrder = voiceLearnedCorrectionsOrder
        self.voiceHistoryEnabled = voiceHistoryEnabled
        self.voiceSmartPolishEnabled = voiceSmartPolishEnabled
        self.voicePolishStyle = voicePolishStyle
        self.voiceTranslateShortcut = voiceTranslateShortcut
        self.voiceTranslateTargetLanguage = voiceTranslateTargetLanguage
        self.voiceAutoPasteEnabled = voiceAutoPasteEnabled
        self.voiceSoundEffectsEnabled = voiceSoundEffectsEnabled
        self.voiceMuteSystemAudioEnabled = voiceMuteSystemAudioEnabled
        self.voiceCloudHotwordsEnabled = voiceCloudHotwordsEnabled
        self.voiceAXFallbackReadEnabled = voiceAXFallbackReadEnabled
        self.continuationSuggestionEnabled = continuationSuggestionEnabled
        self.contextPolicy = contextPolicy
        self.disabledAIApplications = disabledAIApplications
        self.disabledContextApplications = disabledContextApplications
        self.diagnostics = diagnostics
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        self.schemaVersion = schemaVersion
        inputPreferences = try container.decode(
            RimeAIInputPreferences.self,
            forKey: .inputPreferences
        )
        aiEnabled = try container.decode(Bool.self, forKey: .aiEnabled)
        offlineLockEnabled = try container.decode(
            Bool.self,
            forKey: .offlineLockEnabled
        )
        cloudConfigured = try container.decode(
            Bool.self,
            forKey: .cloudConfigured
        )
        cloudProvider = try container.decode(
            String.self,
            forKey: .cloudProvider
        )
        cloudEndpoint = try container.decode(
            String.self,
            forKey: .cloudEndpoint
        )
        cloudModelID = try container.decode(
            String.self,
            forKey: .cloudModelID
        )
        voiceEnabled = try container.decode(Bool.self, forKey: .voiceEnabled)
        if schemaVersion == 5 {
            voiceShortcut = try container.decodeIfPresent(
                VoiceDictationShortcut.self,
                forKey: .voiceShortcut
            ) ?? .default
        } else {
            voiceShortcut = try container.decode(
                VoiceDictationShortcut.self,
                forKey: .voiceShortcut
            )
        }
        let decodedSecondaryShortcut = try container.decodeIfPresent(
            VoiceDictationShortcut.self,
            forKey: .voiceSecondaryShortcut
        )
        voiceSecondaryShortcut = decodedSecondaryShortcut == voiceShortcut
            ? nil
            : decodedSecondaryShortcut
        // 旧版本文档没有该字段：视为「沿用默认值」。
        let decodedSecondaryDisabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .voiceSecondaryShortcutDisabled
        ) ?? false
        voiceSecondaryShortcutDisabled =
            voiceSecondaryShortcut == nil && decodedSecondaryDisabled
        voiceRimeHotwordsEnabled = try container.decode(
            Bool.self,
            forKey: .voiceRimeHotwordsEnabled
        )
        voicePhraseBookHotwordsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .voicePhraseBookHotwordsEnabled
        ) ?? true
        voiceCustomHotwords = try container.decodeIfPresent(
            [String].self,
            forKey: .voiceCustomHotwords
        ) ?? []
        voiceAutoLearnCorrectionsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .voiceAutoLearnCorrectionsEnabled
        ) ?? true
        voiceLearnedCorrections = try container.decodeIfPresent(
            [String: String].self,
            forKey: .voiceLearnedCorrections
        ) ?? [:]
        voiceLearnedCorrectionsOrder = try container.decodeIfPresent(
            [String].self,
            forKey: .voiceLearnedCorrectionsOrder
        ) ?? []
        voiceHistoryEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .voiceHistoryEnabled
        ) ?? true
        voiceSmartPolishEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .voiceSmartPolishEnabled
        ) ?? true
        voicePolishStyle = try container.decodeIfPresent(
            VoicePolishStyle.self,
            forKey: .voicePolishStyle
        ) ?? .concise
        voiceTranslateShortcut = try container.decodeIfPresent(
            VoiceDictationShortcut.self,
            forKey: .voiceTranslateShortcut
        ) ?? .defaultTranslate
        voiceTranslateTargetLanguage = try container.decodeIfPresent(
            VoiceTranslationLanguage.self,
            forKey: .voiceTranslateTargetLanguage
        ) ?? .autoEnZh
        voiceAutoPasteEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .voiceAutoPasteEnabled
        ) ?? true
        voiceSoundEffectsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .voiceSoundEffectsEnabled
        ) ?? true
        voiceMuteSystemAudioEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .voiceMuteSystemAudioEnabled
        ) ?? true
        // Schema-8 documents written before these opt-ins existed import as
        // disabled: absence never grants consent.
        voiceCloudHotwordsEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .voiceCloudHotwordsEnabled
        ) ?? false
        voiceAXFallbackReadEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .voiceAXFallbackReadEnabled
        ) ?? false
        if schemaVersion >= 7 {
            continuationSuggestionEnabled = try container.decode(
                Bool.self,
                forKey: .continuationSuggestionEnabled
            )
        } else {
            // Schema 5/6 documents predate the continuation opt-in.
            continuationSuggestionEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .continuationSuggestionEnabled
            ) ?? false
        }
        contextPolicy = try container.decode(
            ContextPolicy.self,
            forKey: .contextPolicy
        )
        // `pinyinAlignment` (removed with the tier design) is ignored
        // when present: unknown keys do not fail Codable decoding, so
        // schema-8 exports written by older builds still import.
        disabledAIApplications = try container.decode(
            [String].self,
            forKey: .disabledAIApplications
        )
        disabledContextApplications = try container.decode(
            [String].self,
            forKey: .disabledContextApplications
        )
        diagnostics = try container.decode(
            [String: Int].self,
            forKey: .diagnostics
        )
    }
}

public enum RimeAISettingsImportError: Error, Equatable, Sendable {
    case invalidDocument
    case documentTooLarge
    case unsupportedSchemaVersion(Int)
    case offlineLockRequired
    case unsupportedCloudProvider
    case unsupportedCloudEndpoint
    case unsupportedCloudModelID
    case cloudCredentialRequired
    case voiceRequiresAI
    case continuationRequiresAI
    case applicationPolicyLimitExceeded
}

extension RimeAISettingsImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDocument:
            "设置文件格式无效或包含不安全的快捷键。"
        case .documentTooLarge:
            "设置文件超过 \(RimeAISettingsStore.maxImportDocumentBytes / 1_024) KiB 限制。"
        case let .unsupportedSchemaVersion(version):
            "不支持设置文件版本 \(version)，仅接受版本 5、6、7 或 8。"
        case .offlineLockRequired:
            "离线网络隔离是强制策略，不能通过导入关闭。"
        case .unsupportedCloudProvider:
            "设置文件包含不受支持的云服务提供方。"
        case .unsupportedCloudEndpoint:
            "设置文件包含不受支持的云服务地址。"
        case .unsupportedCloudModelID:
            "设置文件包含不受支持的云模型。"
        case .cloudCredentialRequired:
            "启用云服务前必须重新验证本机已有凭据。"
        case .voiceRequiresAI:
            "启用语音听写时必须同时启用 AI 功能。"
        case .continuationRequiresAI:
            "启用上屏后续写联想时必须同时启用 AI 功能。"
        case .applicationPolicyLimitExceeded:
            "应用策略列表过大或包含无效的应用标识。"
        }
    }
}

public final class RimeAISettingsStore: @unchecked Sendable {
    public static let maxImportDocumentBytes = 128 * 1_024

    public enum Keys {
        public static let aiEnabled = "RimeAIEnabled"
        public static let characterSet = "RimeAICharacterSet"
        public static let characterWidth = "RimeAICharacterWidth"
        public static let punctuationStyle = "RimeAIPunctuationStyle"
        public static let offlineLockEnabled = "RimeAIOfflineLockEnabled"
        public static let cloudConfigured = "RimeAICloudConfigured"
        public static let cloudModelID = "RimeAICloudModelID"
        public static let voiceEnabled = "RimeAIVoiceEnabled"
        public static let voiceShortcut = "RimeAIVoiceShortcut"
        public static let voiceSecondaryShortcut =
            "RimeAIVoiceSecondaryShortcut"
        public static let voiceSecondaryShortcutDisabled =
            "RimeAIVoiceSecondaryShortcutDisabled"
        public static let voiceRimeHotwordsEnabled =
            "RimeAIVoiceRimeHotwordsEnabled"
        public static let voicePhraseBookHotwordsEnabled =
            "RimeAIVoicePhraseBookHotwordsEnabled"
        public static let voiceCustomHotwords = "RimeAIVoiceCustomHotwords"
        public static let voiceAutoLearnCorrectionsEnabled =
            "RimeAIVoiceAutoLearnCorrectionsEnabled"
        public static let voiceLearnedCorrections =
            "RimeAIVoiceLearnedCorrections"
        public static let voiceLearnedCorrectionsOrder =
            "RimeAIVoiceLearnedCorrectionsOrder"
        public static let voiceHistoryEnabled = "RimeAIVoiceHistoryEnabled"
        public static let voiceSmartPolishEnabled =
            "RimeAIVoiceSmartPolishEnabled"
        public static let voicePolishStyle = "RimeAIVoicePolishStyle"
        public static let voiceTranslateShortcut =
            "RimeAIVoiceTranslateShortcut"
        public static let voiceTranslateTargetLanguage =
            "RimeAIVoiceTranslateTargetLanguage"
        public static let voiceAutoPasteEnabled = "RimeAIVoiceAutoPasteEnabled"
        public static let voiceSoundEffectsEnabled =
            "RimeAIVoiceSoundEffectsEnabled"
        public static let voiceMuteSystemAudioEnabled =
            "RimeAIVoiceMuteSystemAudioEnabled"
        public static let voiceCloudHotwordsEnabled =
            "RimeAIVoiceCloudHotwordsEnabled"
        public static let voiceAXFallbackReadEnabled =
            "RimeAIVoiceAXFallbackReadEnabled"
        public static let contextPolicy = "RimeAIContextPolicy"
        public static let disabledAIApplications =
            "RimeAIDisabledAIApplications"
        public static let disabledContextApplications =
            "RimeAIDisabledContextApplications"
        public static let diagnostics = "RimeAIDiagnostics"
        public static let personalEnglishTokens = "RimeAIPersonalEnglishTokens"
        public static let cloudConsolidationEnabled =
            "RimeAICloudConsolidationEnabled"
        public static let continuationSuggestionEnabled =
            "RimeAIContinuationSuggestionEnabled"
    }

    public static let shared = RimeAISettingsStore()

    private let defaults: UserDefaults
    private let diagnosticsLock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var characterSet: RimeAICharacterSetPreference {
        get {
            guard let value = defaults.string(forKey: Keys.characterSet) else {
                return .simplified
            }
            return RimeAICharacterSetPreference(rawValue: value) ?? .simplified
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.characterSet)
            notifySettingsChanged()
        }
    }

    public var characterWidth: RimeAICharacterWidth {
        get {
            guard let value = defaults.string(forKey: Keys.characterWidth) else {
                return .half
            }
            return RimeAICharacterWidth(rawValue: value) ?? .half
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.characterWidth)
            notifySettingsChanged()
        }
    }

    public var punctuationStyle: RimeAIPunctuationStyle {
        get {
            guard let value = defaults.string(forKey: Keys.punctuationStyle)
            else {
                return .chinese
            }
            return RimeAIPunctuationStyle(rawValue: value) ?? .chinese
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.punctuationStyle)
            notifySettingsChanged()
        }
    }

    public var inputPreferences: RimeAIInputPreferences {
        RimeAIInputPreferences(
            characterSet: characterSet,
            characterWidth: characterWidth,
            punctuationStyle: punctuationStyle
        )
    }

    public var personalEnglishTokens: Set<String> {
        Set(
            (defaults.stringArray(forKey: Keys.personalEnglishTokens) ?? [])
                .compactMap(Self.normalizedPersonalEnglishToken)
        )
    }

    public var aiEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.aiEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.aiEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.aiEnabled)
            notifySettingsChanged()
        }
    }

    public var offlineLockEnabled: Bool {
        get { true }
        set {
            // The local daemon's process-wide INET guard is an invariant, not
            // a user-facing switch. Keep the legacy key pinned to true so an
            // older build cannot accidentally present a disabled lock.
            // The requested value is deliberately ignored.
            _ = newValue
            defaults.set(true, forKey: Keys.offlineLockEnabled)
            notifySettingsChanged()
        }
    }

    public var cloudConfigured: Bool {
        get {
            defaults.bool(forKey: Keys.cloudConfigured)
        }
        set {
            defaults.set(newValue, forKey: Keys.cloudConfigured)
            notifySettingsChanged()
        }
    }

    public func reconcileCloudConfiguration(
        hasCredential: Bool?
    ) {
        guard cloudConfigured, hasCredential == false else {
            return
        }
        cloudConfigured = false
    }

    /// 云压缩（L3 LLM 画像固化）默认开启；关闭后 broker 以
    /// `--no-consolidation` 运行，仅保留本地统计固化。
    public var cloudConsolidationEnabled: Bool {
        get {
            guard defaults.object(
                forKey: Keys.cloudConsolidationEnabled
            ) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.cloudConsolidationEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.cloudConsolidationEnabled)
            notifySettingsChanged()
        }
    }

    public var cloudModelID: String {
        get {
            guard
                let stored = defaults.string(forKey: Keys.cloudModelID),
                RimeAICloudConfiguration.rankingModelIDs.contains(stored)
            else {
                return RimeAICloudConfiguration.defaultRankingModelID
            }
            return stored
        }
        set {
            let validated = RimeAICloudConfiguration.rankingModelIDs
                .contains(newValue)
                ? newValue
                : RimeAICloudConfiguration.defaultRankingModelID
            defaults.set(validated, forKey: Keys.cloudModelID)
            notifySettingsChanged()
        }
    }

    /// 语音是独立 opt-in 的实验能力，默认关闭；只有用户显式启用且 AI
    /// 总开关允许时，输入法才注册按住说话快捷键并连接 voice helper。
    public var voiceEnabled: Bool {
        get { defaults.bool(forKey: Keys.voiceEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.voiceEnabled)
            notifySettingsChanged()
        }
    }

    public var voiceShortcut: VoiceDictationShortcut {
        get {
            guard let data = defaults.data(forKey: Keys.voiceShortcut),
                  let shortcut = try? JSONDecoder().decode(
                      VoiceDictationShortcut.self,
                      from: data
                  )
            else {
                return .default
            }
            return shortcut
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                assertionFailure("Voice shortcut encoding must not fail.")
                return
            }
            defaults.set(data, forKey: Keys.voiceShortcut)
            if let secondaryData = defaults.data(
                forKey: Keys.voiceSecondaryShortcut
            ),
               let storedSecondary = try? JSONDecoder().decode(
                   VoiceDictationShortcut.self,
                   from: secondaryData
               ),
               storedSecondary == newValue
            {
                // 已绑定的备用键与新主快捷键重复：保持「未绑定」，
                // 不回落到默认的右 ⌘。
                defaults.removeObject(forKey: Keys.voiceSecondaryShortcut)
                defaults.set(true, forKey: Keys.voiceSecondaryShortcutDisabled)
            }
            notifySettingsChanged()
        }
    }

    /// 可选的第二（备用）语音听写快捷键（例如 Mac 内置键盘用 Fn、外接键盘用右 ⌘）。
    ///
    /// 三种状态：
    /// - 从未设置：返回默认值 `VoiceDictationShortcut.defaultSecondary`（右 ⌘）；
    /// - 用户已清除：返回 nil，直到重新绑定或恢复默认；
    /// - 已绑定：返回该快捷键。
    /// 任何状态下与主快捷键重复都视为未绑定（返回 nil）。
    public var voiceSecondaryShortcut: VoiceDictationShortcut? {
        get {
            if let data = defaults.data(forKey: Keys.voiceSecondaryShortcut),
               let shortcut = try? JSONDecoder().decode(
                   VoiceDictationShortcut.self,
                   from: data
               )
            {
                return shortcut == voiceShortcut ? nil : shortcut
            }
            if isVoiceSecondaryShortcutDisabled {
                return nil
            }
            let defaultShortcut = VoiceDictationShortcut.defaultSecondary
            return defaultShortcut == voiceShortcut ? nil : defaultShortcut
        }
        set {
            guard let newValue else {
                // 显式清除：记录「已停用」，避免回落到默认的右 ⌘。
                defaults.removeObject(forKey: Keys.voiceSecondaryShortcut)
                defaults.set(true, forKey: Keys.voiceSecondaryShortcutDisabled)
                notifySettingsChanged()
                return
            }
            guard newValue != voiceShortcut else {
                // 与主快捷键重复的绑定请求被忽略，现有配置保持不变。
                return
            }
            guard let data = try? JSONEncoder().encode(newValue) else {
                assertionFailure("Voice secondary shortcut encoding must not fail.")
                return
            }
            defaults.set(data, forKey: Keys.voiceSecondaryShortcut)
            defaults.removeObject(forKey: Keys.voiceSecondaryShortcutDisabled)
            notifySettingsChanged()
        }
    }

    /// 备用听写快捷键是否被用户显式清除（区别于「从未设置 → 沿用默认值」）。
    private var isVoiceSecondaryShortcutDisabled: Bool {
        defaults.bool(forKey: Keys.voiceSecondaryShortcutDisabled)
    }

    /// 所有生效的语音听写快捷键（主快捷键在前，若已绑定不重复的备用快捷键则追加其后）。
    public var voiceShortcuts: [VoiceDictationShortcut] {
        if let secondary = voiceSecondaryShortcut, secondary != voiceShortcut {
            return [voiceShortcut, secondary]
        }
        return [voiceShortcut]
    }

    /// 独立于语音总开关的明示策略。开启后只允许使用当前焦点会话中用户
    /// 已经通过 Rime 成功确认的有界词条；不会读取完整 userdb、历史或光标文本。
    /// 默认关闭，避免把“语音已启用”误解为授权传递最近上屏词条。
    public var voiceRimeHotwordsEnabled: Bool {
        get { defaults.bool(forKey: Keys.voiceRimeHotwordsEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.voiceRimeHotwordsEnabled)
            notifySettingsChanged()
        }
    }

    /// 允许自动把语言画像 L1 常用语库与当前域的领域词库作为语音热词上下文。
    /// 默认开启；在 strict 上下文策略或安全输入下自动关闭。
    public var voicePhraseBookHotwordsEnabled: Bool {
        get {
            guard defaults.object(
                forKey: Keys.voicePhraseBookHotwordsEnabled
            ) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.voicePhraseBookHotwordsEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.voicePhraseBookHotwordsEnabled)
            notifySettingsChanged()
        }
    }

    /// 用户显式维护的语音热词 / 常用语列表（支持中英混合与专有名词，
    /// 最多 128 条）。用于引导本地 ASR 偏置与同音词校正。
    public var voiceCustomHotwords: [String] {
        get {
            Self.normalizedVoiceCustomHotwords(
                defaults.stringArray(forKey: Keys.voiceCustomHotwords) ?? []
            )
        }
        set {
            defaults.set(
                Self.normalizedVoiceCustomHotwords(newValue),
                forKey: Keys.voiceCustomHotwords
            )
            notifySettingsChanged()
        }
    }

    /// 语音上屏后，在短窗口内监听用户对错字的手动修正并自动收录进热词与纠错词典。
    /// 默认开启；在 strict 上下文策略或安全输入下自动 fail-closed。
    public var voiceAutoLearnCorrectionsEnabled: Bool {
        get {
            guard defaults.object(
                forKey: Keys.voiceAutoLearnCorrectionsEnabled
            ) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.voiceAutoLearnCorrectionsEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.voiceAutoLearnCorrectionsEnabled)
            notifySettingsChanged()
        }
    }

    /// 从用户上屏后修改中自动学到的确定性纠错映射（错词 → 正词，最多 128 条）。
    /// 超出上限时淘汰最近最少使用的词条，而不是按字母序淘汰。
    public var voiceLearnedCorrections: [String: String] {
        get {
            Self.normalizedVoiceLearnedCorrections(
                storedVoiceLearnedCorrections,
                order: storedVoiceLearnedCorrectionsOrder
            )
        }
        set {
            writeVoiceLearnedCorrections(
                newValue,
                baseOrder: storedVoiceLearnedCorrectionsOrder
            )
            notifySettingsChanged()
        }
    }

    /// 已学习纠错词条的最近使用顺序（错词，旧 → 新），与
    /// `voiceLearnedCorrections` 的键一一对应。
    public var voiceLearnedCorrectionsOrder: [String] {
        Self.normalizedVoiceLearnedCorrectionsWithOrder(
            storedVoiceLearnedCorrections,
            order: storedVoiceLearnedCorrectionsOrder
        ).order
    }

    private var storedVoiceLearnedCorrections: [String: String] {
        defaults.dictionary(forKey: Keys.voiceLearnedCorrections) as? [String: String]
            ?? [:]
    }

    private var storedVoiceLearnedCorrectionsOrder: [String] {
        defaults.stringArray(forKey: Keys.voiceLearnedCorrectionsOrder) ?? []
    }

    /// 写入纠错映射并持久化最近使用顺序：已知词条保持原有先后，
    /// 不在 `baseOrder` 里的词条排在已知词条之后，`promotingKey` 被提升为最新。
    private func writeVoiceLearnedCorrections(
        _ input: [String: String],
        baseOrder: [String],
        promoting promotingKey: String? = nil
    ) {
        var order: [String] = []
        var seen = Set<String>()
        let inputKeys = Set(input.keys.map(Self.normalizedVoiceCorrectionKey))
        for key in baseOrder
        where inputKeys.contains(key) && seen.insert(key).inserted {
            order.append(key)
        }
        // 没有顺序信息的词条（旧版本只存了字典）按字母序倒序补在后面：
        // 字母序靠后的被视为更旧、超限时先淘汰，与旧实现保持一致。
        for key in inputKeys.sorted().reversed() where seen.insert(key).inserted {
            order.append(key)
        }
        if let promotingKey {
            order.removeAll { $0 == promotingKey }
            order.append(promotingKey)
        }

        let normalized = Self.normalizedVoiceLearnedCorrectionsWithOrder(
            input,
            order: order
        )
        defaults.set(
            normalized.corrections,
            forKey: Keys.voiceLearnedCorrections
        )
        defaults.set(
            normalized.order,
            forKey: Keys.voiceLearnedCorrectionsOrder
        )
    }

    /// 记录一条用户上屏后修正学到的词条：
    /// 1. 写入 `wrong -> corrected` 确定性纠错映射（同时清理可能冲突的反向旧映射）；
    /// 2. 将 `hotword` 置顶收录进 `voiceCustomHotwords`（上限 128 条）。
    /// 返回 true 表示有新增或更新。
    @discardableResult
    public func recordVoiceLearnedCorrection(
        wrong: String,
        corrected: String,
        hotword: String
    ) -> Bool {
        guard let normalizedHotword = Self.normalizedVoiceCustomHotwords([hotword]).first,
              let normalizedCorrected = Self.normalizedVoiceCustomHotwords([corrected]).first
        else {
            return false
        }
        let normalizedWrong = wrong
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidVoiceCorrectionKey(normalizedWrong),
              normalizedWrong != normalizedCorrected
        else {
            return false
        }

        var corrections = voiceLearnedCorrections
        let hadExactMapping = corrections[normalizedWrong] == normalizedCorrected
        // Remove stale reverse mapping if user corrected back the other way.
        if corrections[normalizedCorrected] == normalizedWrong {
            corrections.removeValue(forKey: normalizedCorrected)
        }
        corrections[normalizedWrong] = normalizedCorrected

        var hotwords = voiceCustomHotwords
        let hadHotword = hotwords.contains(normalizedHotword)
        hotwords.removeAll { $0 == normalizedHotword }
        hotwords.insert(normalizedHotword, at: 0)
        hotwords = Self.normalizedVoiceCustomHotwords(hotwords)

        // 新学到的词条标记为最新：超出 128 条时淘汰的是最旧的词条，
        // 这条新修正一定保留。
        writeVoiceLearnedCorrections(
            corrections,
            baseOrder: storedVoiceLearnedCorrectionsOrder,
            promoting: normalizedWrong
        )
        defaults.set(hotwords, forKey: Keys.voiceCustomHotwords)
        notifySettingsChanged()
        return !hadExactMapping || !hadHotword
    }

    /// 语音纠错词典上限：超出时淘汰最近最少使用的词条。
    public static let maximumVoiceLearnedCorrections = 128

    /// 归一化纠错映射并截断到 128 条。
    ///
    /// `order` 是词条的最近使用顺序（旧 → 新）。超出上限时淘汰 `order`
    /// 中最靠前（最旧）的词条；没有顺序信息的旧数据按字母序排在最后，
    /// 保证结果确定。
    public static func normalizedVoiceLearnedCorrections(
        _ raw: [String: String],
        order: [String] = []
    ) -> [String: String] {
        normalizedVoiceLearnedCorrectionsWithOrder(raw, order: order).corrections
    }

    /// 与 `normalizedVoiceLearnedCorrections` 相同，同时返回保留下来的
    /// 词条顺序（旧 → 新），供调用方持久化为 companion order 数组。
    public static func normalizedVoiceLearnedCorrectionsWithOrder(
        _ raw: [String: String],
        order: [String]
    ) -> (corrections: [String: String], order: [String]) {
        // 归一化键 → 原值。重复键按字母序后者覆盖，与旧实现一致。
        var rawValues: [String: String] = [:]
        for key in raw.keys.sorted() {
            rawValues[normalizedVoiceCorrectionKey(key)] = raw[key]
        }

        // 候选序列按“最旧 → 最新”排列，超限时从头部淘汰：
        // 1) 没有顺序信息的词条（旧版本只保存了字典）视为最旧，按字母序倒序排在
        //    最前：超限时先淘汰，结果与旧实现“保留字母序靠前的 128 条”一致；
        // 2) 随后是 `order` 给出的最近使用顺序（旧 → 新）。
        var seen = Set<String>()
        var recentKeys: [String] = []
        for rawOrderEntry in order {
            let key = normalizedVoiceCorrectionKey(rawOrderEntry)
            guard rawValues[key] != nil, seen.insert(key).inserted else {
                continue
            }
            recentKeys.append(key)
        }
        var candidateKeys = rawValues.keys
            .sorted()
            .reversed()
            .filter { !seen.contains($0) }
        candidateKeys.append(contentsOf: recentKeys)

        var retained: [(key: String, value: String)] = []
        for key in candidateKeys {
            guard isValidVoiceCorrectionKey(key),
                  let normalizedValue = normalizedVoiceCustomHotwords(
                      [rawValues[key] ?? ""]
                  ).first,
                  key != normalizedValue
            else {
                continue
            }
            retained.append((key, normalizedValue))
        }
        if retained.count > maximumVoiceLearnedCorrections {
            // 淘汰最旧的词条；最新学到的修正总是保留。
            retained.removeFirst(
                retained.count - maximumVoiceLearnedCorrections
            )
        }

        var corrections: [String: String] = [:]
        var retainedKeys: [String] = []
        corrections.reserveCapacity(retained.count)
        retainedKeys.reserveCapacity(retained.count)
        for entry in retained {
            corrections[entry.key] = entry.value
            retainedKeys.append(entry.key)
        }
        return (corrections, retainedKeys)
    }

    private static func normalizedVoiceCorrectionKey(_ key: String) -> String {
        key.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidVoiceCorrectionKey(_ key: String) -> Bool {
        (2 ... 32).contains(key.count)
            && key.utf8.count <= 128
            && !key.unicodeScalars.contains(where: {
                $0.value < 0x20 || (0x7f ... 0x9f).contains($0.value)
            })
            && !key.contains("/")
            && !key.contains(":")
            && !key.contains("#")
            && !key.contains("@")
    }

    /// 本地语音历史记录开关（默认开启，仅保存在本机 SQLite，不上传）。
    public var voiceHistoryEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.voiceHistoryEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.voiceHistoryEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.voiceHistoryEnabled)
            notifySettingsChanged()
        }
    }

    /// 智能润色开关：去除口语填充词、修正重复与标点（离线使用本地确定性
    /// 润色，配置云增强后自动升级为大模型润色并保留本地降级）。
    public var voiceSmartPolishEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.voiceSmartPolishEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.voiceSmartPolishEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.voiceSmartPolishEnabled)
            notifySettingsChanged()
        }
    }

    public var voicePolishStyle: VoicePolishStyle {
        get {
            guard let raw = defaults.string(forKey: Keys.voicePolishStyle),
                  let style = VoicePolishStyle(rawValue: raw)
            else {
                return .concise
            }
            return style
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.voicePolishStyle)
            notifySettingsChanged()
        }
    }

    /// 一键语音翻译快捷键（默认 ⌃⇧T）。
    public var voiceTranslateShortcut: VoiceDictationShortcut {
        get {
            guard let data = defaults.data(forKey: Keys.voiceTranslateShortcut),
                  let shortcut = try? JSONDecoder().decode(
                      VoiceDictationShortcut.self,
                      from: data
                  )
            else {
                return .defaultTranslate
            }
            return shortcut
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                assertionFailure("Voice translate shortcut encoding must not fail.")
                return
            }
            defaults.set(data, forKey: Keys.voiceTranslateShortcut)
            notifySettingsChanged()
        }
    }

    /// 一键语音翻译目标语言（默认中英互译自动识别）。
    public var voiceTranslateTargetLanguage: VoiceTranslationLanguage {
        get {
            guard let raw = defaults.string(
                forKey: Keys.voiceTranslateTargetLanguage
            ),
            let language = VoiceTranslationLanguage(rawValue: raw)
            else {
                return .autoEnZh
            }
            return language
        }
        set {
            defaults.set(
                newValue.rawValue,
                forKey: Keys.voiceTranslateTargetLanguage
            )
            notifySettingsChanged()
        }
    }

    /// 听写/翻译完成后自动上屏（支持 IMK 直插，必要时回退剪贴板自动粘贴）。
    public var voiceAutoPasteEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.voiceAutoPasteEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.voiceAutoPasteEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.voiceAutoPasteEnabled)
            notifySettingsChanged()
        }
    }

    /// 语音交互提示音（开始、停止、完成、取消）。
    public var voiceSoundEffectsEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.voiceSoundEffectsEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.voiceSoundEffectsEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.voiceSoundEffectsEnabled)
            notifySettingsChanged()
        }
    }

    /// 语音输入期间自动静音系统输出音频，结束后自动恢复原音量/静音状态。
    public var voiceMuteSystemAudioEnabled: Bool {
        get {
            guard defaults.object(
                forKey: Keys.voiceMuteSystemAudioEnabled
            ) != nil else {
                return true
            }
            return defaults.bool(forKey: Keys.voiceMuteSystemAudioEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.voiceMuteSystemAudioEnabled)
            notifySettingsChanged()
        }
    }

    /// 允许云端润色 / 翻译请求携带语音热词上下文。独立 opt-in，默认关闭：
    /// 开启语音或本地热词并不等于同意把热词发送到云端。
    public var voiceCloudHotwordsEnabled: Bool {
        get { defaults.bool(forKey: Keys.voiceCloudHotwordsEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.voiceCloudHotwordsEnabled)
            notifySettingsChanged()
        }
    }

    public func setVoiceCloudHotwordsEnabled(_ enabled: Bool) {
        voiceCloudHotwordsEnabled = enabled
    }

    /// 允许在无法直接读取编辑结果时使用只读辅助功能（AX）回退回读。
    /// 独立 opt-in，默认关闭；仅影响回读路径，密码框 / 安全输入永不回读。
    public var voiceAXFallbackReadEnabled: Bool {
        get { defaults.bool(forKey: Keys.voiceAXFallbackReadEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.voiceAXFallbackReadEnabled)
            notifySettingsChanged()
        }
    }

    public func setVoiceAXFallbackReadEnabled(_ enabled: Bool) {
        voiceAXFallbackReadEnabled = enabled
    }

    public static func normalizedVoiceCustomHotwords(
        _ rawPhrases: [String]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(min(rawPhrases.count, 128))
        for raw in rawPhrases {
            guard result.count < 128 else {
                break
            }
            let normalized = raw
                .precomposedStringWithCompatibilityMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2 ... 32).contains(normalized.count),
                  normalized.utf8.count <= 128,
                  !normalized.unicodeScalars.contains(where: {
                      $0.value < 0x20 || (0x7f ... 0x9f).contains($0.value)
                  }),
                  !normalized.contains("/"),
                  !normalized.contains(":"),
                  !normalized.contains("#"),
                  !normalized.contains("@")
            else {
                continue
            }
            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    /// 上屏后续写联想是独立 opt-in 的实验能力，默认关闭；只有用户显式
    /// 启用、AI 总开关允许且云已配置时，输入法才在 commit 后请求续写建议。
    public var continuationSuggestionEnabled: Bool {
        get { defaults.bool(forKey: Keys.continuationSuggestionEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.continuationSuggestionEnabled)
            notifySettingsChanged()
        }
    }

    public func shouldCaptureCloudHistory(
        isSecureInput: Bool
    ) -> Bool {
        cloudConfigured && !isSecureInput
    }

    public var contextPolicy: ContextPolicy {
        get {
            guard
                let rawValue = defaults.string(forKey: Keys.contextPolicy)
            else {
                return .standard
            }
            return ContextPolicy(rawValue: rawValue) ?? .standard
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.contextPolicy)
            notifySettingsChanged()
        }
    }

    public var disabledAIApplications: [String] {
        get {
            normalizedApplications(
                defaults.stringArray(forKey: Keys.disabledAIApplications) ?? []
            )
        }
        set {
            defaults.set(
                normalizedApplications(newValue),
                forKey: Keys.disabledAIApplications
            )
            notifySettingsChanged()
        }
    }

    public var disabledContextApplications: [String] {
        get {
            normalizedApplications(
                defaults.stringArray(
                    forKey: Keys.disabledContextApplications
                ) ?? []
            )
        }
        set {
            defaults.set(
                normalizedApplications(newValue),
                forKey: Keys.disabledContextApplications
            )
            notifySettingsChanged()
        }
    }

    public func isAIAllowed(for bundleIdentifier: String) -> Bool {
        aiEnabled
            && !disabledAIApplications.contains(
                normalizedApplication(bundleIdentifier)
            )
    }

    public func contextPolicy(
        for bundleIdentifier: String
    ) -> ContextPolicy {
        if disabledContextApplications.contains(
            normalizedApplication(bundleIdentifier)
        ) {
            return .strict
        }
        return contextPolicy
    }

    private func loadDiagnostics() -> [String: Int] {
        let raw = defaults.dictionary(forKey: Keys.diagnostics) ?? [:]
        return raw.reduce(into: [:]) { result, entry in
            if let value = entry.value as? NSNumber {
                result[entry.key] = value.intValue
            }
        }
    }

    private func normalizedApplications(
        _ applications: [String]
    ) -> [String] {
        Array(
            Set(
                applications
                    .map(normalizedApplication)
                    .filter { !$0.isEmpty }
            )
        ).sorted()
    }

    private static func isValidImportedApplicationPolicy(
        _ applications: [String]
    ) -> Bool {
        guard applications.count <= 256 else {
            return false
        }
        return applications.allSatisfy { application in
            let trimmed = application.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return application == trimmed
                && (1 ... 255).contains(application.utf8.count)
                && application.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                }
        }
    }

    private func normalizedApplication(
        _ application: String
    ) -> String {
        application.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedPersonalEnglishToken(
        _ token: String
    ) -> String? {
        let normalized = token.lowercased()
        guard (3 ... 32).contains(normalized.count),
              normalized.unicodeScalars.allSatisfy({ scalar in
                  (65 ... 90).contains(scalar.value)
                      || (97 ... 122).contains(scalar.value)
              })
        else {
            return nil
        }
        return normalized
    }

    private func notifySettingsChanged() {
        NotificationCenter.default.post(
            name: .rimeAISettingsDidChange,
            object: self
        )
    }

    private func notifyDiagnosticsChanged() {
        NotificationCenter.default.post(
            name: .rimeAIDiagnosticsDidChange,
            object: self
        )
    }
}

// MARK: - Diagnostics, reset and transfer
// 同文件 extension：诊断计数、数据重置与导入导出，保持对
// private 成员（defaults/diagnosticsLock/Keys）的访问。
extension RimeAISettingsStore {
    public func record(_ event: RimeAIDiagnosticEvent) {
        incrementDiagnostic(key: event.rawValue)
    }

    public func recordLatency(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else {
            return
        }
        let bucket: String
        switch milliseconds {
        case ..<50:
            bucket = "latency_lt_50_ms"
        case ..<100:
            bucket = "latency_lt_100_ms"
        case ..<250:
            bucket = "latency_lt_250_ms"
        case ..<400:
            bucket = "latency_lt_400_ms"
        default:
            bucket = "latency_gte_400_ms"
        }
        incrementDiagnostic(key: bucket)
    }

    private func incrementDiagnostic(key: String) {
        diagnosticsLock.withLock {
            var diagnostics = loadDiagnostics()
            diagnostics[key, default: 0] += 1
            defaults.set(diagnostics, forKey: Keys.diagnostics)
        }
        notifyDiagnosticsChanged()
    }

    public func diagnosticCount(
        _ event: RimeAIDiagnosticEvent
    ) -> Int {
        diagnosticsLock.withLock {
            loadDiagnostics()[event.rawValue, default: 0]
        }
    }

    public func diagnosticSnapshot() -> [String: Int] {
        diagnosticsLock.withLock {
            loadDiagnostics()
        }
    }

    public func resetDiagnostics() {
        diagnosticsLock.withLock {
            defaults.removeObject(forKey: Keys.diagnostics)
        }
        notifyDiagnosticsChanged()
    }

    public func clearEphemeralData() {
        NotificationCenter.default.post(
            name: .rimeAIClearEphemeralData,
            object: self
        )
    }

    public func resetAllProductData() {
        for key in [
            Keys.aiEnabled,
            Keys.characterSet,
            Keys.characterWidth,
            Keys.punctuationStyle,
            Keys.offlineLockEnabled,
            Keys.cloudConfigured,
            Keys.cloudModelID,
            Keys.voiceEnabled,
            Keys.voiceShortcut,
            Keys.voiceSecondaryShortcut,
            Keys.voiceSecondaryShortcutDisabled,
            Keys.voiceRimeHotwordsEnabled,
            Keys.voicePhraseBookHotwordsEnabled,
            Keys.voiceCustomHotwords,
            Keys.voiceAutoLearnCorrectionsEnabled,
            Keys.voiceLearnedCorrections,
            Keys.voiceLearnedCorrectionsOrder,
            Keys.voiceHistoryEnabled,
            Keys.voiceSmartPolishEnabled,
            Keys.voicePolishStyle,
            Keys.voiceTranslateShortcut,
            Keys.voiceTranslateTargetLanguage,
            Keys.voiceAutoPasteEnabled,
            Keys.voiceSoundEffectsEnabled,
            Keys.voiceMuteSystemAudioEnabled,
            Keys.voiceCloudHotwordsEnabled,
            Keys.voiceAXFallbackReadEnabled,
            Keys.contextPolicy,
            Keys.disabledAIApplications,
            Keys.disabledContextApplications,
            Keys.diagnostics,
            Keys.personalEnglishTokens,
            Keys.cloudConsolidationEnabled,
            Keys.continuationSuggestionEnabled,
        ] {
            defaults.removeObject(forKey: key)
        }
        clearEphemeralData()
        notifySettingsChanged()
    }

    public func restoreDefaults() {
        for key in [
            Keys.aiEnabled,
            Keys.characterSet,
            Keys.characterWidth,
            Keys.punctuationStyle,
            Keys.offlineLockEnabled,
            Keys.cloudConfigured,
            Keys.cloudModelID,
            Keys.voiceEnabled,
            Keys.voiceShortcut,
            Keys.voiceSecondaryShortcut,
            Keys.voiceSecondaryShortcutDisabled,
            Keys.voiceRimeHotwordsEnabled,
            Keys.voicePhraseBookHotwordsEnabled,
            Keys.voiceAutoLearnCorrectionsEnabled,
            Keys.voiceHistoryEnabled,
            Keys.voiceSmartPolishEnabled,
            Keys.voicePolishStyle,
            Keys.voiceTranslateShortcut,
            Keys.voiceTranslateTargetLanguage,
            Keys.voiceAutoPasteEnabled,
            Keys.voiceSoundEffectsEnabled,
            Keys.voiceMuteSystemAudioEnabled,
            Keys.voiceCloudHotwordsEnabled,
            Keys.voiceAXFallbackReadEnabled,
            Keys.contextPolicy,
            Keys.disabledAIApplications,
            Keys.disabledContextApplications,
            Keys.continuationSuggestionEnabled,
        ] {
            defaults.removeObject(forKey: key)
        }
        notifySettingsChanged()
    }

    public func exportSnapshot() -> RimeAISettingsExport {
        RimeAISettingsExport(
            inputPreferences: inputPreferences,
            aiEnabled: aiEnabled,
            offlineLockEnabled: offlineLockEnabled,
            cloudConfigured: cloudConfigured,
            cloudModelID: cloudModelID,
            voiceEnabled: voiceEnabled,
            voiceShortcut: voiceShortcut,
            voiceSecondaryShortcut: voiceSecondaryShortcut,
            voiceSecondaryShortcutDisabled:
                voiceSecondaryShortcut == nil && isVoiceSecondaryShortcutDisabled,
            voiceRimeHotwordsEnabled: voiceRimeHotwordsEnabled,
            voicePhraseBookHotwordsEnabled: voicePhraseBookHotwordsEnabled,
            voiceCustomHotwords: voiceCustomHotwords,
            voiceAutoLearnCorrectionsEnabled: voiceAutoLearnCorrectionsEnabled,
            voiceLearnedCorrections: voiceLearnedCorrections,
            voiceLearnedCorrectionsOrder: voiceLearnedCorrectionsOrder,
            voiceHistoryEnabled: voiceHistoryEnabled,
            voiceSmartPolishEnabled: voiceSmartPolishEnabled,
            voicePolishStyle: voicePolishStyle,
            voiceTranslateShortcut: voiceTranslateShortcut,
            voiceTranslateTargetLanguage: voiceTranslateTargetLanguage,
            voiceAutoPasteEnabled: voiceAutoPasteEnabled,
            voiceSoundEffectsEnabled: voiceSoundEffectsEnabled,
            voiceMuteSystemAudioEnabled: voiceMuteSystemAudioEnabled,
            voiceCloudHotwordsEnabled: voiceCloudHotwordsEnabled,
            voiceAXFallbackReadEnabled: voiceAXFallbackReadEnabled,
            continuationSuggestionEnabled: continuationSuggestionEnabled,
            contextPolicy: contextPolicy,
            disabledAIApplications: disabledAIApplications,
            disabledContextApplications: disabledContextApplications,
            diagnostics: diagnosticSnapshot()
        )
    }

    public func applyImport(
        _ data: Data,
        hasCloudCredential: Bool
    ) throws {
        guard data.count <= Self.maxImportDocumentBytes else {
            throw RimeAISettingsImportError.documentTooLarge
        }
        let snapshot: RimeAISettingsExport
        do {
            snapshot = try JSONDecoder().decode(
                RimeAISettingsExport.self,
                from: data
            )
        } catch {
            throw RimeAISettingsImportError.invalidDocument
        }
        try applyImport(
            snapshot,
            hasCloudCredential: hasCloudCredential
        )
    }

    public func applyImport(
        _ snapshot: RimeAISettingsExport,
        hasCloudCredential: Bool
    ) throws {
        guard snapshot.schemaVersion == 5 || snapshot.schemaVersion == 6
            || snapshot.schemaVersion == 7 || snapshot.schemaVersion == 8
        else {
            throw RimeAISettingsImportError.unsupportedSchemaVersion(
                snapshot.schemaVersion
            )
        }
        guard snapshot.offlineLockEnabled else {
            throw RimeAISettingsImportError.offlineLockRequired
        }
        guard snapshot.cloudProvider == RimeAICloudConfiguration.provider else {
            throw RimeAISettingsImportError.unsupportedCloudProvider
        }
        guard snapshot.cloudEndpoint
            == RimeAICloudConfiguration.endpoint.absoluteString
        else {
            throw RimeAISettingsImportError.unsupportedCloudEndpoint
        }
        guard RimeAICloudConfiguration.rankingModelIDs.contains(
            snapshot.cloudModelID
        ) else {
            throw RimeAISettingsImportError.unsupportedCloudModelID
        }
        guard !snapshot.cloudConfigured || hasCloudCredential else {
            throw RimeAISettingsImportError.cloudCredentialRequired
        }
        guard snapshot.aiEnabled || !snapshot.voiceEnabled else {
            throw RimeAISettingsImportError.voiceRequiresAI
        }
        guard snapshot.aiEnabled || !snapshot.continuationSuggestionEnabled
        else {
            throw RimeAISettingsImportError.continuationRequiresAI
        }
        guard Self.isValidImportedApplicationPolicy(
            snapshot.disabledAIApplications
        ), Self.isValidImportedApplicationPolicy(
            snapshot.disabledContextApplications
        ) else {
            throw RimeAISettingsImportError.applicationPolicyLimitExceeded
        }
        let encodedShortcut = try JSONEncoder().encode(snapshot.voiceShortcut)
        let normalizedSecondary =
            snapshot.voiceSecondaryShortcut == snapshot.voiceShortcut
            ? nil
            : snapshot.voiceSecondaryShortcut
        let encodedSecondaryShortcut = try normalizedSecondary.map {
            try JSONEncoder().encode($0)
        }
        let encodedTranslateShortcut = try JSONEncoder().encode(
            snapshot.voiceTranslateShortcut
        )

        defaults.set(
            snapshot.inputPreferences.characterSet.rawValue,
            forKey: Keys.characterSet
        )
        defaults.set(
            snapshot.inputPreferences.characterWidth.rawValue,
            forKey: Keys.characterWidth
        )
        defaults.set(
            snapshot.inputPreferences.punctuationStyle.rawValue,
            forKey: Keys.punctuationStyle
        )
        defaults.set(snapshot.aiEnabled, forKey: Keys.aiEnabled)
        defaults.set(true, forKey: Keys.offlineLockEnabled)
        defaults.set(snapshot.cloudConfigured, forKey: Keys.cloudConfigured)
        defaults.set(snapshot.cloudModelID, forKey: Keys.cloudModelID)
        defaults.set(snapshot.voiceEnabled, forKey: Keys.voiceEnabled)
        defaults.set(
            encodedShortcut,
            forKey: Keys.voiceShortcut
        )
        if let encodedSecondaryShortcut {
            defaults.set(
                encodedSecondaryShortcut,
                forKey: Keys.voiceSecondaryShortcut
            )
            defaults.set(false, forKey: Keys.voiceSecondaryShortcutDisabled)
        } else {
            defaults.removeObject(forKey: Keys.voiceSecondaryShortcut)
            if snapshot.voiceSecondaryShortcutDisabled {
                // 导出时已明确清除：保持未绑定，不回落到默认的右 ⌘。
                defaults.set(true, forKey: Keys.voiceSecondaryShortcutDisabled)
            } else {
                // 导出未提及备用键（旧版本文档或沿用默认值）：继续沿用默认值。
                defaults.removeObject(forKey: Keys.voiceSecondaryShortcutDisabled)
            }
        }
        defaults.set(
            snapshot.voiceRimeHotwordsEnabled,
            forKey: Keys.voiceRimeHotwordsEnabled
        )
        defaults.set(
            snapshot.voicePhraseBookHotwordsEnabled,
            forKey: Keys.voicePhraseBookHotwordsEnabled
        )
        defaults.set(
            Self.normalizedVoiceCustomHotwords(snapshot.voiceCustomHotwords),
            forKey: Keys.voiceCustomHotwords
        )
        defaults.set(
            snapshot.voiceAutoLearnCorrectionsEnabled,
            forKey: Keys.voiceAutoLearnCorrectionsEnabled
        )
        writeVoiceLearnedCorrections(
            snapshot.voiceLearnedCorrections,
            baseOrder: snapshot.voiceLearnedCorrectionsOrder
        )
        defaults.set(
            snapshot.voiceHistoryEnabled,
            forKey: Keys.voiceHistoryEnabled
        )
        defaults.set(
            snapshot.voiceSmartPolishEnabled,
            forKey: Keys.voiceSmartPolishEnabled
        )
        defaults.set(
            snapshot.voicePolishStyle.rawValue,
            forKey: Keys.voicePolishStyle
        )
        defaults.set(
            encodedTranslateShortcut,
            forKey: Keys.voiceTranslateShortcut
        )
        defaults.set(
            snapshot.voiceTranslateTargetLanguage.rawValue,
            forKey: Keys.voiceTranslateTargetLanguage
        )
        defaults.set(
            snapshot.voiceAutoPasteEnabled,
            forKey: Keys.voiceAutoPasteEnabled
        )
        defaults.set(
            snapshot.voiceSoundEffectsEnabled,
            forKey: Keys.voiceSoundEffectsEnabled
        )
        defaults.set(
            snapshot.voiceMuteSystemAudioEnabled,
            forKey: Keys.voiceMuteSystemAudioEnabled
        )
        defaults.set(
            snapshot.voiceCloudHotwordsEnabled,
            forKey: Keys.voiceCloudHotwordsEnabled
        )
        defaults.set(
            snapshot.voiceAXFallbackReadEnabled,
            forKey: Keys.voiceAXFallbackReadEnabled
        )
        defaults.set(
            snapshot.continuationSuggestionEnabled,
            forKey: Keys.continuationSuggestionEnabled
        )
        defaults.set(snapshot.contextPolicy.rawValue, forKey: Keys.contextPolicy)
        defaults.set(
            normalizedApplications(snapshot.disabledAIApplications),
            forKey: Keys.disabledAIApplications
        )
        defaults.set(
            normalizedApplications(snapshot.disabledContextApplications),
            forKey: Keys.disabledContextApplications
        )
        notifySettingsChanged()
    }
}
