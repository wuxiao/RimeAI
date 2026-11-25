import Foundation

// `VoicePolishStyle` 与 `VoiceTranslationLanguage` 已迁移到轻量的
// `VoicePreferenceTypes.swift`（iOS 便携核心只依赖那两个纯偏好类型）。

public enum VoicePostProcessAction: String, CaseIterable, Codable, Sendable {
    case dictation = "dictation"
    case polish = "polish"
    case translate = "translate"

    public var displayName: String {
        switch self {
        case .dictation:
            return "语音听写"
        case .polish:
            return "智能润色"
        case .translate:
            return "语音翻译"
        }
    }
}

public enum VoiceSessionIntent: Equatable, Sendable {
    case dictation
    case translate(VoiceTranslationLanguage)

    public var isTranslation: Bool {
        if case .translate = self {
            return true
        }
        return false
    }
}

public enum VoiceSoundEffectKind: String, CaseIterable, Sendable {
    case start
    case stop
    case success
    case cancel
    case error
}

// MARK: - Local Deterministic Smart Polisher (Offline Fallback & Instant Cleanup)

/// 本地确定性智能润色器：零延迟、完全离线。
/// 负责去除常见口语填充词（嗯、啊、呃、那个、就是说、然后呢等）、
/// 消除叠词口吃（如“我我我觉得”→“我觉得”）、整理多余标点与空格，
/// 作为未配置云端或云端超时时的立即可用润色能力。
public enum VoiceLocalPolisher {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let modified: Bool

        public init(text: String, modified: Bool) {
            self.text = text
            self.modified = modified
        }
    }

    /// 句首或标点后的口语犹豫词（移除时连同紧随的停顿标点一起清理）。
    ///
    /// 英文填充词只匹配小写或首字母大写的形式：全大写的 `ER` / `UM` / `UH` /
    /// `AH` 是缩写（如急诊室），不是口头语。
    private static let leadingFillerPatterns: [String] = [
        #"^(?:嗯+|啊+|呃+|哦+|唉+|诶+|唔+|额+|就是说|就是呢|然后呢|怎么说呢|其实吧|你看啊|我想想|等一下)[，,、。\.！!？\?\s]*"#,
        #"^(?:[Uu]m+|[Uu]h+|[Ee]r+|[Aa]h+|[Hh]mm+|[Ww]ell|[Ll]ike|[Yy]ou know)[,\s]+"#,
    ]

    /// 句中停顿夹带的独立填充词（前后带标点或明显停顿）。
    ///
    /// 英文填充词连同其后的逗号 / 空白一起移除，保留前面的空格，避免把相邻
    /// 单词粘在一起；不吞句末标点，不匹配全大写缩写（`ER` / `UM` / `UH`），
    /// 也不动“uh-huh”这类回应词。
    private static let medialFillerPatterns: [String] = [
        #"[，,、]\s*(?:嗯+|啊+|呃+|额+|唔+|那个|这个|就是说|然后呢|怎么说呢)\s*(?=[，,、。！？\?!])"#,
        #"(?<=[\u4e00-\u9fff])[，,]\s*(?:嗯+|啊+|呃+|额+|唔+)\s*(?=[\u4e00-\u9fff])"#,
        #"\b(?:[Uu]m+|[Uu]h+|[Ee]r+)(?!-)\b(?:[,\s]+|$)"#,
    ]

    /// 中文句末标点后紧跟的纯犹豫整句（如“。然后。”、“。嗯。”、“。那个。”）。
    /// 只匹配中文句末标点之后，不影响英文句子。
    private static let standaloneSentenceFillerPattern =
        #"(?<=[。！？；])\s*(?:嗯+|啊+|呃+|额+|唔+|哦+|诶+|然后呢?|那个|这个|就是说|就是呢|对)[，,、\s]*(?:[。！？；]+|$)"#

    /// 中文句末标点后新一句开头的口头语/犹豫词（如“。嗯，也没有办法”、“。那个，我觉得”）。
    private static let postSentenceLeadingFillerPattern =
        #"(?<=[。！？；])\s*(?:嗯+|啊+|呃+|额+|唔+|哦+|唉+|诶+|就是说|就是呢|然后呢|怎么说呢|其实吧|你看啊|我想想|等一下|那个|这个)[，,、\s]+"#

    /// ASR 常在中文连接词/引语后误切句号（如“问题是。它会…”、“其实是。格式化”）：
    /// 仅在连接词后紧跟单个“。”且后续仍是正文时修成逗号，不做改写。
    private static let choppyConnectorPeriodPattern =
        #"(问题是|关键是|重点是|核心是|其实是|也就是说|换句话说|比如说|比如|因为|所以|但是|不过|而且|并且|另外|还有就是|主要就是|第一呢?|第二呢?|第三呢?|第四呢?)。(?=[\u4e00-\u9fffA-Za-z0-9])"#

    /// 句中“那个/这个。嗯，…”型 ASR 断句犹豫（如“其实是那个。嗯，格式化”→“其实是格式化”）。
    private static let medialDemonstrativeBreakFillerPattern =
        #"(?<=[\u4e00-\u9fff])(?:那个|这个)[。]\s*(?:(?:嗯+|啊+|呃+|额+|唔+)[，,、\s]*)+(?=[\u4e00-\u9fff])"#

    /// 中英文 / 中文与数字混排自动加单个空格（规范排版，不破坏标点与缩写）。
    private static let cjkBeforeAsciiPattern =
        #"([\u4e00-\u9fff])([A-Za-z0-9])"#
    private static let asciiBeforeCjkPattern =
        #"([A-Za-z0-9])([\u4e00-\u9fff])"#

    /// 条理整理模式：当同一段中显式出现“第一…第二…”分点叙述时自动分行。
    private static let structuredEnumerationBreakPattern =
        #"([。！？；])\s*(第[二三四五六七八九十](?:点|个|条|步|呢)?[，,、：:\s])"#

    /// 句尾无意义语气拖音（仅在有实质内容时去除）。
    private static let trailingFillerPattern =
        #"[，,、\s]*(?:嗯+|呃+|额+|啊+|吧嗯)[，,、\s]*$"#

    /// 句首“那个 / 这个”只有两种情况是口头语：后面紧跟停顿（“那个，我觉得”），
    /// 或自身重复口吃（“那个那个方案”）。其余情况是指示代词
    /// （“那个方案很好”），必须保留。
    private static let leadingDemonstrativePausePattern =
        #"^(?:那个|这个)+(?=[，,、。\.！!？\?\s])[，,、。\.！!？\?\s]*"#
    private static let leadingDemonstrativeStutterPattern =
        #"^(?:那个|这个){2,}"#

    /// 合法的叠词（“多多关照”“事事顺心”）。折叠口吃时整体保留，不压成单字。
    private static let reduplicationWhitelist: [String] = [
        "多多", "事事", "会会", "常常", "往往", "刚刚", "人人", "天天", "年年",
        "家家", "处处", "步步", "层层", "渐渐", "慢慢", "轻轻", "紧紧", "悄悄",
        "默默", "好好", "看看", "想想", "试试", "听听", "说说", "聊聊", "走走",
        "坐坐", "等等",
    ]

    /// 中文单字口吃（连续 3 次及以上同一汉字，或常见代词/副词双叠如“我我”“这这”“那那”“就就”）。
    /// 双叠折叠前先整体放过白名单叠词。
    private static let tripleHanStutterPattern =
        #"([\u4e00-\u9fff])\1{2,}"#
    private static let commonPronounStutterOrWhitelistPattern = try? NSRegularExpression(
        pattern: #"(?:"#
            + reduplicationWhitelist.joined(separator: "|")
            + #")|([我你他她它这那就也是都很在把被会要能])\1(?![们个些里的啊呀哦呢])"#
    )

    /// 常见双字口吃重复（如“就是就是”“然后然后”“那个那个”“觉得觉得”“其实其实”）。
    private static let bigramStutterPattern =
        #"(就是|然后|那个|这个|其实|因为|所以|但是|如果|觉得|可以|应该|需要|已经|还是|或者|而且)\1+"#

    /// 连续重复标点压缩。
    private static let repeatedPunctuationPattern = #"([，。！？；：、,.!?;:])\1+"#

    /// 口语自我纠正标记：仅当标记自成一段（位于句首，或前面是停顿标点）
    /// 且后面紧跟“应该是 / 是 / 改成”时，才去掉标记、保留更正后的内容。
    /// 紧跟在主语或谓词后面的“不是”（如“这个不是，是那个”）是否定对比句，
    /// 不是自纠，必须原样保留。
    private static let leadingSelfCorrectionPattern =
        #"^(?:不对|说错了|不是)[，,、\s]*(?:应该是|是|改成)\s*"#
    private static let medialSelfCorrectionPattern =
        #"(?<=[，,、。！？!?；;\s])(?:不对|说错了|不是)[，,、\s]*(?:应该是|是|改成)\s*"#

    public static func polish(
        _ rawText: String,
        style: VoicePolishStyle = .concise
    ) -> Result {
        let original = rawText
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else {
            return Result(text: "", modified: false)
        }

        var text = original

        // 1. 压缩连续重复标点
        text = replaceRegex(
            in: text,
            pattern: repeatedPunctuationPattern,
            template: "$1"
        )

        // 2. 清理连续叠词口吃
        text = collapseStutters(in: text)

        // 3. 修复 ASR 误切的中文句中碎句号（如“问题是。它会”、“其实是那个。嗯，格式化”）
        text = repairChoppyPeriods(in: text)

        // 4. 清理句首、句末后新句开头与句中填充词（循环清理多重口头语如“嗯，那个，就是说”）
        text = stripFillers(in: text)

        // 5. 精简 / 正式 / 条理风格下清理明显句尾语气词与多余逗号
        if style != .casual, text.count >= 6 {
            let trimmedTail = replaceRegex(
                in: text,
                pattern: trailingFillerPattern,
                template: ""
            )
            if trimmedTail.count >= 2 {
                text = trimmedTail
            }
        }

        // 6. 简单自纠提示精简（如“不对，应该是”）；
        //    “这个不是，是那个”这类对比句保持原样。
        text = replaceRegex(
            in: text,
            pattern: leadingSelfCorrectionPattern,
            template: ""
        )
        text = replaceRegex(
            in: text,
            pattern: medialSelfCorrectionPattern,
            template: "，"
        )

        // 7. 清理孤立前导标点、连续标点及多余空格
        text = tidyPunctuation(in: text)

        // 8. 中英文 / 数字混排排版空格
        text = normalizeCjkAsciiSpacing(in: text)

        // 9. 若清理后为空（例如整句本来就是“嗯”），保留原文本防止丢失
        if text.isEmpty {
            return Result(text: original, modified: false)
        }

        // 10. 正式/精简/条理风格：较长中文陈述句缺句尾标点时自动补句号
        if (style == .concise || style == .formal || style == .structured),
           containsHan(text),
           text.count >= 8,
           let last = text.last,
           !"。！？!?；;：:….,，、".contains(last)
        {
            text.append("。")
        }

        // 11. 英文首字母大写（纯英文或英文开头）
        if let first = text.first, first.isASCII, first.isLowercase,
           !containsHan(String(text.prefix(4)))
        {
            text = first.uppercased() + text.dropFirst()
        }

        // 12. 条理整理风格：显式“第一…第二…”分点叙述时自动分行排版
        if style == .structured,
           text.contains("第一"),
           text.contains("第二")
        {
            text = replaceRegex(
                in: text,
                pattern: structuredEnumerationBreakPattern,
                template: "$1\n$2"
            )
        }

        return Result(text: text, modified: text != original)
    }

    /// 修复 ASR 在连接词/犹豫处误切出的句中句号（不改动原意与词序）。
    private static func repairChoppyPeriods(in text: String) -> String {
        var result = replaceRegex(
            in: text,
            pattern: medialDemonstrativeBreakFillerPattern,
            template: ""
        )
        result = replaceRegex(
            in: result,
            pattern: choppyConnectorPeriodPattern,
            template: "$1，"
        )
        return result
    }

    /// 中英文与数字之间补齐单个空格（仅在存在汉字时生效，不影响纯英文与缩写）。
    private static func normalizeCjkAsciiSpacing(in text: String) -> String {
        guard containsHan(text) else {
            return text
        }
        var result = replaceRegex(
            in: text,
            pattern: cjkBeforeAsciiPattern,
            template: "$1 $2"
        )
        result = replaceRegex(
            in: result,
            pattern: asciiBeforeCjkPattern,
            template: "$1 $2"
        )
        return result
    }

    /// 折叠口吃。句首重复的“那个 / 这个”是口头语口吃，整段去掉；它必须先于
    /// 双字口吃折叠：否则“那个那个”会先被折成单个指示代词而保留下来。
    private static func collapseStutters(in text: String) -> String {
        var result = replaceRegex(
            in: text,
            pattern: leadingDemonstrativeStutterPattern,
            template: ""
        )
        result = replaceRegex(
            in: result,
            pattern: bigramStutterPattern,
            template: "$1"
        )
        result = replaceRegex(
            in: result,
            pattern: tripleHanStutterPattern,
            template: "$1"
        )
        return collapseCommonPronounStutters(in: result)
    }

    /// 循环清理多重口头语（如“嗯，那个，就是说”与句末后的“。嗯，然后。”），直到文本不再变化。
    private static func stripFillers(in text: String) -> String {
        var result = text
        for _ in 0 ..< 5 {
            let before = result
            for pattern in leadingFillerPatterns
            + [leadingDemonstrativePausePattern, leadingDemonstrativeStutterPattern]
            {
                result = replaceRegex(in: result, pattern: pattern, template: "")
            }
            result = replaceRegex(
                in: result,
                pattern: standaloneSentenceFillerPattern,
                template: ""
            )
            result = replaceRegex(
                in: result,
                pattern: postSentenceLeadingFillerPattern,
                template: ""
            )
            for pattern in medialFillerPatterns {
                result = replaceRegex(in: result, pattern: pattern, template: "")
            }
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if result == before {
                break
            }
        }
        return result
    }

    /// 清理孤立前导标点、连续标点及多余空格。
    private static func tidyPunctuation(in text: String) -> String {
        var result = replaceRegex(
            in: text,
            pattern: #"^[，,、；;：:\s]+"#,
            template: ""
        )
        result = replaceRegex(
            in: result,
            pattern: #"[，,、]\s*([。！？\?!；;])"#,
            template: "$1"
        )
        result = replaceRegex(
            in: result,
            pattern: repeatedPunctuationPattern,
            template: "$1"
        )
        result = replaceRegex(
            in: result,
            pattern: #"[ \t]{2,}"#,
            template: " "
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsHan(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x3400 ... 0x9FFF).contains($0.value) }
    }

    /// 折叠常见代词 / 副词的单字双叠口吃（“我我”→“我”），但整体保留白名单叠词
    /// （“会会”“好好”等合法词汇）。
    private static func collapseCommonPronounStutters(in text: String) -> String {
        guard let regex = commonPronounStutterOrWhitelistPattern else {
            return text
        }
        let source = text as NSString
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: source.length)
        )
        var output = ""
        var cursor = 0
        for match in matches {
            output += source.substring(
                with: NSRange(
                    location: cursor,
                    length: match.range.location - cursor
                )
            )
            let stutterRange = match.range(at: 1)
            if stutterRange.location != NSNotFound {
                // 口吃：只保留一个字。
                output += source.substring(with: stutterRange)
            } else {
                // 白名单叠词：原样保留。
                output += source.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }

    private static func replaceRegex(
        in input: String,
        pattern: String,
        template: String,
        caseInsensitive: Bool = false
    ) -> String {
        let options: NSRegularExpression.Options = caseInsensitive
            ? [.caseInsensitive]
            : []
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: options
        ) else {
            // 模式都是编译期写死的常量：写错正则时必须在测试里暴露，
            // 而不是静默地原样返回文本、让整条清理规则失效。
            assertionFailure("VoiceLocalPolisher: invalid regular expression \(pattern)")
            return input
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}

// MARK: - Cloud Broker Voice Transform Protocol (Polish & Translate)

public enum CloudVoiceTransformTask: String, Codable, Sendable {
    case polish
    case translate
}

public struct CloudVoiceTransformRequest: Codable, Equatable, Sendable {
    public let schemaVersion = 1
    public let type = "voice_transform"
    public let requestID: String
    public let clientSessionID: String
    public let bundleIdentifier: String
    public let modelID: String
    public let task: CloudVoiceTransformTask
    public let text: String
    public let style: VoicePolishStyle?
    public let targetLanguage: VoiceTranslationLanguage?
    public let hotwords: [String]
    public let deadlineMilliseconds: Int

    public init(
        requestID: String,
        clientSessionID: String,
        bundleIdentifier: String,
        modelID: String = RimeAICloudConfiguration.defaultRankingModelID,
        task: CloudVoiceTransformTask,
        text: String,
        style: VoicePolishStyle? = nil,
        targetLanguage: VoiceTranslationLanguage? = nil,
        hotwords: [String] = [],
        deadlineMilliseconds: Int = 10_000
    ) {
        self.requestID = requestID
        self.clientSessionID = clientSessionID
        self.bundleIdentifier = bundleIdentifier
        self.modelID = modelID
        self.task = task
        self.text = text
        self.style = style
        self.targetLanguage = targetLanguage
        self.hotwords = Array(hotwords.prefix(32))
        self.deadlineMilliseconds = min(
            max(deadlineMilliseconds, 1),
            VoiceTransformTextPolicy.maximumDeadlineMilliseconds
        )
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case type
        case requestID = "request_id"
        case clientSessionID = "client_session_id"
        case bundleIdentifier = "bundle_id"
        case modelID = "model_id"
        case task
        case text
        case style
        case targetLanguage = "target_language"
        case hotwords
        case deadlineMilliseconds = "deadline_ms"
    }
}

public struct CloudVoiceTransformResponse: Codable, Equatable, Sendable {
    public let status: String
    public let requestID: String?
    public let task: String?
    public let transformedText: String?
    public let modelID: String?
    public let elapsedMilliseconds: Double?

    public init(
        status: String,
        requestID: String?,
        task: String?,
        transformedText: String?,
        modelID: String?,
        elapsedMilliseconds: Double?
    ) {
        self.status = status
        self.requestID = requestID
        self.task = task
        self.transformedText = transformedText
        self.modelID = modelID
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    enum CodingKeys: String, CodingKey {
        case status
        case requestID = "request_id"
        case task
        case transformedText = "transformed_text"
        case modelID = "model_id"
        case elapsedMilliseconds = "elapsed_ms"
    }
}

public enum VoiceTransformTextPolicy {
    public static let maximumInputCharacters = 20_000
    public static let maximumOutputCharacters = 30_000
    public static let maximumDeadlineMilliseconds = 30_000

    public static func isValid(request: CloudVoiceTransformRequest) -> Bool {
        guard request.type == "voice_transform",
              !request.requestID.isEmpty,
              request.requestID.utf8.count <= 256,
              !request.clientSessionID.isEmpty,
              !request.bundleIdentifier.isEmpty,
              !request.modelID.isEmpty,
              !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.text.count <= maximumInputCharacters,
              !request.text.contains("\u{0000}"),
              (1 ... maximumDeadlineMilliseconds).contains(request.deadlineMilliseconds)
        else {
            return false
        }
        switch request.task {
        case .polish:
            return request.style != nil
        case .translate:
            return request.targetLanguage != nil
        }
    }

    public static func sanitizedOutput(
        _ response: CloudVoiceTransformResponse,
        for request: CloudVoiceTransformRequest
    ) -> String? {
        guard response.status == "ok",
              response.requestID == request.requestID,
              let raw = response.transformedText
        else {
            return nil
        }
        let allowsNewlines = request.task == .polish && request.style == .structured
        let normalized: String
        if allowsNewlines {
            let unified = raw
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let trimmedLines = unified
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // 保留单/双换行排版，折叠连续超过两个空行。
            var collapsed: [String] = []
            var emptyRun = 0
            for line in trimmedLines {
                if line.isEmpty {
                    emptyRun += 1
                    if emptyRun <= 1 && !collapsed.isEmpty {
                        collapsed.append("")
                    }
                } else {
                    emptyRun = 0
                    collapsed.append(line)
                }
            }
            while collapsed.last == "" {
                collapsed.removeLast()
            }
            normalized = collapsed.joined(separator: "\n")
        } else {
            normalized = raw
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !normalized.isEmpty,
              normalized.count <= maximumOutputCharacters,
              !normalized.unicodeScalars.contains(where: {
                  ($0.value < 0x20 && !(allowsNewlines && $0.value == 0x0A))
                      || $0.value == 0x7F
              })
        else {
            return nil
        }
        return normalized
    }
}
