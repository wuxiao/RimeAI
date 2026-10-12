# 上屏后智能续句联想（Post-Commit Continuation）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 上屏"床前明月光"后，光标附近主动出现"疑是地上霜"建议 chip，单击即上屏；用户开始打字/切换应用/Secure Input 时建议立即消失，绝不残留。

**Architecture:** 云 broker 新增 `continuation` 消息类型（纯上下文续写，不做拼音对齐，新校验梯 `continuation_text_allows`）；客户端新增 `PostCommitContinuationCoordinator`（Sources/RimeAIInputCore，闭包注入依赖，不引 AppKit）持有触发/防抖/守卫/去重状态机；UI 复用 `CandidatePanelController` 的 AI 槽，新增绕过 `hasComposition` 守卫的 `showContinuation` 渲染路径。功能默认关闭，独立 opt-in 开关。

**Tech Stack:** Swift（`Sources/RimeAIInputCore` 共享类型 + `macos/RimeAIInputMethod` 接线）、Python（`rimeai_cloud_broker`，pytest）、UDS NDJSON 传输。

**Spec:** `docs/superpowers/specs/2026-10-12-post-commit-continuation-design.md`（本计划的依据，执行者需同时阅读）。

## Global Constraints

- 默认关闭：`continuationSuggestionEnabled` 默认 `false`，且 `aiEnabled == false` 时视为关；未开启时 commit 后零请求、零 UI、零行为变化（回归锁定）。
- 协议向后兼容：新消息 `type == "continuation"`、`schemaVersion == 1`；不改动既有 `"inference"` 校验与行为；旧 broker 收到 `continuation` 类型按未知类型断连/忽略，客户端静默降级（记诊断，无 UI 提示）。
- `Sources/RimeAIInputCore` 只用 Foundation，不引 AppKit；锚点 rect、NSPanel 操作全部留在 `macos/RimeAIInputMethod`。
- iOS 只共享编译 `Sources/RimeAIInputCore`，行为不变（新 presentation case 在 iOS 侧不触发）。
- 常量（Swift/Python 两侧镜像）：防抖 250ms；请求 deadline ≤ 3000ms；自动隐藏 8s；`MIN_CONTEXT_HAN = 4`；`MAX_CONTEXT_CHARS = 400`；`CONTINUATION_MIN_HAN = 2`；`CONTINUATION_MAX_HAN = 16`；`CONTINUATION_MINIMUM_CONFIDENCE = 0.65`；去重 context 尾部长 32 字、尾部重叠 ≥ 4 字拒；连续 3 次 abstain/error 后冷却 60s。
- stale 判据用协调器内部 commitEpoch，不用 historyGeneration（commit 的异步历史写入会 bump generation，见 spec §5.3）。
- 所有新增/修改文件只含必要改动，不做顺手重构。每个任务全绿后提交一次（`feat:`/`test:` 前缀）。
- 测试命令：Swift 用 `swift test --filter RimeAIInputCoreTests`（完整形式见 README.md:83-86）；Python 用 `PYTHONDONTWRITEBYTECODE=1 python3.11 -m pytest tests/... -q -p no:cacheprovider`。

## Review Focus

- 迟到响应竞态：用户已击键/已开始新组合，飞行中的 continuation 结果返回 → 必须被 epoch/空组合/cancel 三重守卫丢弃，不得显示更不得上屏 → T4 测试锁定。
- 非纯汉字、超长（>16）、低置信（<0.65）、复读 context 尾部的生成文本 → broker 与 Swift 两侧校验都必须拒（abstain/丢弃）→ T1/T2 测试锁定。
- 未开启开关 / per-app 禁用 / policy=strict / Secure Input / 上屏文本不足 4 汉字 → 不得发请求、不得显示面板 → T4 门槛矩阵测试锁定。
- 能力协商缺失（旧客户端连新 broker、新客户端连旧 broker）→ broker abstain/忽略，客户端静默，不崩溃、不重试风暴 → T2/T6 测试锁定。
- 8s 自动隐藏与既有路径回归：`refreshCandidatePanelIfActive` 在空组合时行为不变；连续多次 commit 只显示最后一次的建议（latest-wins）→ T4/T5 测试锁定。

---

### Task 1: Swift 协议类型与文本校验镜像

**Files:**
- Modify: `Sources/RimeAIInputCore/CloudBrokerProtocol.swift`（:105 起的请求区之后新增类型）
- Test: `tests/RimeAIInputCoreTests/CloudBrokerProtocolTests.swift`

**Interfaces:**
- Produces（后续所有任务依赖）:
  ```swift
  public struct CloudContinuationRequest: Codable, Sendable {
      public let schemaVersion = 1          // CodingKey "schema_version"
      public let type = "continuation"
      public let requestID: String          // "request_id"
      public let clientSessionID: String    // "client_session_id"
      public let bundleIdentifier: String   // "bundle_id"
      public let modelID: String            // "model_id"
      public let recentContext: String      // "recent_context"
      public let historySnippets: [CloudHistorySnippet]  // "history_snippets"
      public let historyGeneration: Int64?  // "history_generation"
      public let deadlineMilliseconds: Int  // "deadline_ms"，init 夹取 1...3000
      public init(...)                      // recentContext 由调用方负责按 policy 截断
  }
  public struct CloudContinuationResponse: Codable, Sendable {
      public let status: String             // "status"
      public let requestID: String?         // "request_id"
      public let decision: String?          // "decision"：generate | abstain
      public let generatedText: String?     // "generated_text"
      public let confidence: Double?        // "confidence"
      public let reason: String?            // "reason"
      public let modelID: String?           // "model_id"
      public let elapsedMilliseconds: Double?  // "elapsed_ms"
  }
  public enum ContinuationTextPolicy {
      public static let minHanCharacters = 2
      public static let maxHanCharacters = 16
      public static let minimumConfidence = 0.65
      public static let minimumContextHanCharacters = 4
      public static let maximumContextCharacters = 400
      public static let dedupTailLength = 32
      public static let maximumTailOverlap = 3   // 重叠 ≥ 4 字拒
      public static func hanCount(_ text: String) -> Int
      public static func allows(text: String, context: String, confidence: Double) -> Bool
      public static func isValid(request: CloudContinuationRequest) -> Bool
      public static func isValid(response: CloudContinuationResponse, for request: CloudContinuationRequest) -> Bool
  }
  ```
- `allows` 规则（与 T2 Python 镜像逐条对应）：text 全部为汉字（0x3400...0x9FFF）且 2–16 字；confidence ≥ 0.65；text 不是 `context.suffix(32)` 的子串；text 与 context 尾部的最长公共后缀 ≤ 3 字。
- `isValid(request)`：recentContext 汉字数 4...400（字符总数 ≤ 400）；deadline 1...3000；type == "continuation"。
- `isValid(response:)`：status=="ok" ∧ requestID 匹配 ∧ (decision=="generate" → generatedText 非空且 `allows` 通过；decision=="abstain" → 可接受但不产生建议)。

- [ ] **Step 1: 写失败测试** — `test_continuationRequestEncodingRoundTrip`（CodingKeys 全覆盖，JSON key 为 snake_case）；`test_continuationRequestValidation`（context 3 汉字拒 / 401 字拒 / deadline 0 与 3001 拒 / 合法例通过且夹取）；`test_continuationTextPolicyAllows`（"床前明月光"→"疑是地上霜" 通过；含标点/16+1 字/confidence 0.64/context 尾部子串/尾部重叠 4 字 各拒）；`test_continuationResponseValidation`（generate 缺文本拒、requestID 失配拒、abstain 通过）。
- [ ] **Step 2: 跑 `swift test --filter CloudBrokerProtocolTests` 确认新测试失败。**
- [ ] **Step 3: 实现** 上述类型与 `ContinuationTextPolicy`（汉字判定用 unicodeScalars 区间 0x3400...0x9FFF，与 `CloudGeneratedSentencePolicy` 现有写法一致）。
- [ ] **Step 4: 跑 `swift test --filter RimeAIInputCoreTests` 全绿。**

### Task 2: 云 broker continuation 路由与校验

**Files:**
- Modify: `rimeai_cloud_broker/server.py`（`_handle_client` :520-526 之间加分支；`validate_request` :158 旁新增 validator；能力广播 :497-504）
- Modify: `rimeai_cloud_broker/qwen.py`（`rank` :111 旁新增方法；:23 附近新增常量）
- Test: `tests/test_cloud_broker.py`

**Interfaces:**
- Consumes: T1 的 JSON 契约（字段名、常量值镜像）。
- Produces:
  ```python
  CONTINUATION_MINIMUM_CONFIDENCE = 0.65   # qwen.py，与 Swift 0.65 镜像
  CONTINUATION_MIN_HAN = 2
  CONTINUATION_MAX_HAN = 16

  # qwen.py
  def continuation_text_allows(text: str, context: str, confidence: float) -> bool
  class QwenCandidateRanker:
      def rank_continuation(self, cloud_request: dict[str, Any]) -> dict[str, Any]
      # 返回 {"status","request_id","decision","generated_text","confidence","reason","model_id","elapsed_ms"}

  # server.py
  def _validate_continuation_request(self, message: dict) -> dict   # 抛 RequestError 同现有风格
  async def _run_continuation(self, client_writer, request: dict) -> None
  ```
- 路由：`_handle_client` 中 `message_type == "continuation"` → 校验 → `asyncio.create_task(self._run_continuation(...))`；`"cancel"` 分支复用（按 request_id 取消，若 continuation 与 inference 的 pending 需区分则用独立 pending 表）。
- **`_run_continuation` 不做 `history_generation` 响应期比对**（既有 `_run` :628-632 的静默丢弃对 continuation 是竞态陷阱：commit 的异步历史写入恰在请求飞行中 bump generation；新鲜度由客户端 commitEpoch 保证，见 spec §5.3）。历史增强路径（:696-704 的 generation 检查）对 continuation 同样跳过，直接 augment。
- 能力协商：hello 响应 capabilities 追加 `"continuation-generation"`（与 `text_generation_enabled` 同门控）；`_run_continuation` 开头检查 `"continuation-generation" not in client_capabilities` 时直接回 `decision="abstain", reason="capability_absent"`。
- `rank_continuation` prompt：task 文案（内联常量，风格同 :140-154）："续写任务：给定 recent_context 与 history_snippets，输出紧接 recent_context 之后的下一短语。只输出 2-16 个汉字，不含标点、数字、字母或任何解释。"；messages 结构复用 :262 起的 payload 组装（system + user=JSON、temperature 0、response_format json_object、max_tokens 64）；输出契约 `{decision, generated_text, confidence, reason}`。校验失败一律 abstain 并带 reason（`low_confidence` / `invalid_text` / `echoes_context`）。
- 请求校验（`_validate_continuation_request`）：type/schema_version==1、request_id/client_session_id/bundle_id/model_id 非空、model_id ∈ 白名单、recent_context 汉字数 4...400、deadline_ms 1...3000、api_key 存在（注入方式同 inference）。

- [ ] **Step 1: 写失败测试**（沿用 StubQwenRanker/StubGenerateRanker 模式）— `test_continuation_request_validation_rejects_short_context_and_bad_model`、`test_continuation_capability_absent_abstains`、`test_continuation_generates_passage_continuation`（fake 返回 "疑是地上霜" conf 0.8，context "床前明月光…" → 响应 decision generate、文本原样）、`test_continuation_rejects_non_han_text`（fake 返回 "疑是地上霜。" 含标点 → abstain reason invalid_text）、`test_continuation_rejects_low_confidence`、`test_continuation_rejects_context_echo`（生成文本 == context 尾 5 字 → abstain echoes_context）、`test_continuation_ignores_history_generation_drift`（请求携带旧 generation，响应照常返回不被静默丢弃——锁定 T2 路由不做 generation 比对的决策）、`test_continuation_text_allows_unit`（纯函数逐条对齐 T1 规则）。
- [ ] **Step 2: 跑 `PYTHONDONTWRITEBYTECODE=1 python3.11 -m pytest tests/test_cloud_broker.py -q -p no:cacheprovider` 确认新测试失败。**
- [ ] **Step 3: 实现** 上述函数与路由分支。
- [ ] **Step 4: 上述 pytest 全绿 + `PYTHONDONTWRITEBYTECODE=1 python3.11 -m pytest tests/ -q -p no:cacheprovider` 无回归。**

### Task 2.5: 真实模型冒烟（Go/No-Go 闸门）

**前置决策依据：** spec §3.1——qwen3.5:0.8b 实测会复读 prompt 中的 context（`qwen.py:34-39`），continuation 是纯上下文任务，fake ranker 测试测不出真实模型质量。**本任务不过，T3-T7 不得开工。**

- [ ] **Step 1: 启动真实 broker 与 Ollama**，向 continuation 路由发送 10 条固定上下文集（3 条名句续写："床前明月光，"→"疑是地上霜"等；3 条日常对话；4 条复读陷阱：context 尾部含高频短语/回文结构）。记录每条的 decision/generated_text/confidence。
- [ ] **Step 2: 判定** — ≥7/10 通过 `continuation_text_allows` 且非复读 → 继续后续任务；否则按 spec §3.1 预案：扩 continuation 专用白名单（在 qwen2.5:1.5b / qwen3.5:1.5b 等 ≥1.5B 候选中重跑冒烟选定），Swift 侧 `RimeAICloudConfiguration` 镜像新增 `continuationModelIDs`，并将冒烟数据写入 `qwen.py` 注释。模型变更只影响 continuation 路由，既有 inference 路径模型锁定不动。
- [ ] **Step 3: 记录结论** — 把冒烟结果（通过率、选定模型）追加到本任务下方的完成记录，TASKS.md 一行说明。

**完成记录（2026-10-12）：GO。** 真实 Ollama qwen3.5:0.8b，10 条固定上下文（3 名句 / 3 日常 / 4 复读陷阱）：嵌套 JSON 指令 prompt 0/10（模型逐字复读 prompt，max_tokens 截断），改单例 few-shot 会话形态后 **10/10** 通过 `continuation_text_allows` 且零复读（如 "床前明月光，"→"疑是地上霜" conf 0.95；陷阱 "上海自来水来自海上"→"水落石出"）。结论：模型保留 qwen3.5:0.8b，不扩白名单；prompt 形态改为 few-shot（`rank_continuation` 内注释已记录数据），validator 宽容缺省 decision 字段（按 generated_text 推断）。质量注记：诗歌续写有时跳句/错句（"春眠不觉晓，"→"夜来风雨声"），但均过校验梯、非复读，可发布观察。

### Task 3: 设置项、诊断事件与历史 source

**Files:**
- Modify: `Sources/RimeAIInputCore/RimeAISettingsStore.swift`（Keys :250-271；属性仿 voiceEnabled :434-440；`RimeAIDiagnosticEvent` :19-68；`RimeAISettingsExport` schemaVersion :107 与迁移 :172-183、导入 :775-777）
- Modify: `Sources/RimeAIInputCore/HistoryStore.swift`（`HistoryCommitSource` :4-12 新增 case）
- Modify: `macos/RimeAIInputMethod/RimeAIInputController+MenuAndSettings.swift`（`makeInputMethodMenu` :6-59 加 `preferenceMenuItem` 开关项）
- Test: `tests/RimeAIInputCoreTests/RimeAISettingsStoreTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // RimeAISettingsStore
  public static let continuationSuggestionEnabledKey = "RimeAIContinuationSuggestionEnabled"  // Keys 内常量
  public var continuationSuggestionEnabled: Bool   // 默认 false；set 后 notifySettingsChanged()
  // RimeAIDiagnosticEvent 新增 rawValue：
  // "continuation_requested" / "continuation_shown" / "continuation_accepted"
  // / "continuation_dismissed" / "continuation_abstained" / "continuation_cooldown"
  // HistoryCommitSource 新增：
  case continuation = "continuation"
  ```
- 导出 schemaVersion 6→7：`init(from:)` 迁移 `if schemaVersion == 6 { continuationSuggestionEnabled = decodeIfPresent(...) ?? false } else { decode }`；导入 guard 放行 6 与 7。
- 菜单项：`preferenceMenuItem(title: "上屏后续写联想…", action: #selector(toggleContinuationSuggestion(_:)), selected: settings.continuationSuggestionEnabled)`，action 翻转 UserDefaults 并刷新菜单状态。

- [ ] **Step 1: 写失败测试** — `test_continuationSuggestionEnabledDefaultsFalse`；`test_continuationExportRoundTripBumpsSchemaVersion`（6 导入 → 7 导出含新字段；7 导入通过；5 导入仍走既有 voice 迁移不回归）；`test_continuationImportRequiresAI`（导入 `continuationSuggestionEnabled=true` 且 `aiEnabled=false` 抛 `continuationRequiresAI`，仿 `voiceRequiresAI` 守卫 `RimeAISettingsStore.swift:799-801`）；`test_historyCommitSourceContinuationRawValue`。
- [ ] **Step 2: 跑 `swift test --filter RimeAISettingsStoreTests` 确认新测试失败。**
- [ ] **Step 3: 实现** 设置属性、事件枚举、source case、导出迁移、`applyImport` 守卫与菜单项（菜单项无单测，编译 + T7 手动验收覆盖）。
- [ ] **Step 4: 跑 `swift test --filter RimeAIInputCoreTests` 全绿。**

### Task 4: PostCommitContinuationCoordinator（状态机）

**Files:**
- Create: `Sources/RimeAIInputCore/PostCommitContinuationCoordinator.swift`
- Test: `tests/RimeAIInputCoreTests/PostCommitContinuationCoordinatorTests.swift`（自带 mini harness：仿 `SemanticSuggestionPipelineTests` 的 `ManualScheduling`/`HarnessFlags` 写法，不跨文件复用其 private fakes）

**Interfaces:**
- Consumes: T1 的 `CloudContinuationRequest/Response/ContinuationTextPolicy`、T3 的诊断事件与 `HistoryContextSnapshot`、既有 `SemanticSuggestionScheduling`（复用，不新建）、`ContextPolicy`。
- Produces（T5/T6 依赖）:
  ```swift
  public enum PostCommitContinuationEvent: Sendable {
    case showSuggestion(String)     // T6 据此调 candidatePanel.showContinuation
    case hideSuggestion             // T6 据此隐藏
    case diagnostic(RimeAIDiagnosticEvent)
  }
  public enum PostCommitContinuationCancelReason: String, Sendable {
    case userTyped, compositionBegan, sessionSwitched, secureInput, deactivated, timedOut
    // 无 panelClosed：面板是 borderless NSPanel，无关闭按钮，不存在该事件
  }
  public struct PostCommitContinuationDependencies: Sendable {
    public var now: @Sendable () -> TimeInterval
    public var scheduling: any SemanticSuggestionScheduling
    public var isSecureEventInputEnabled: @Sendable () -> Bool
    public var isContinuationEnabled: @Sendable () -> Bool       // settings ∧ aiEnabled ∧ cloudConfigured 已在注入处合成
    public var isAIAllowed: @Sendable (String) -> Bool
    public var contextPolicy: @Sendable (String) -> ContextPolicy
    public var loadCloudAPIKey: @Sendable () -> String?
    public var cloudModelID: @Sendable () -> String
    public var clientSessionID: String
    public var cloudHistorySnapshot: @Sendable (String) -> HistoryContextSnapshot?  // 与 SemanticSuggestionPipeline seam 同名
    public var sendContinuation: @Sendable (CloudContinuationRequest, String,
        @escaping @Sendable (CloudContinuationResponse?) -> Void) -> Void
    public var cancelContinuation: @Sendable (String) -> Void
    public var compositionIsEmpty: @MainActor @Sendable () -> Bool
    public var compositionIsSelecting: @MainActor @Sendable () -> Bool
    public var onEvent: (@MainActor @Sendable (PostCommitContinuationEvent) -> Void)?
  }
  @MainActor public final class PostCommitContinuationCoordinator {
    public init(dependencies: PostCommitContinuationDependencies)
    public func commitDidHappen(appSessionID: String, bundleIdentifier: String,
                                committedText: String,
                                contextProvider: (ContextPolicy) -> String) -> Void
    public func cancel(_ reason: PostCommitContinuationCancelReason) -> Void
    public func acceptCandidate(_ text: String) -> Void   // 清状态 + 记 continuation_accepted
  }
  ```
- 行为规格：`commitDidHappen` bump 内部 `commitEpoch`、取消在飞请求与既有展示、排 250ms 防抖（latest-wins：再次 commit 重排）；防抖到期做门槛检查（`isContinuationEnabled` ∧ `isAIAllowed(bundle)` ∧ `contextPolicy != .strict` ∧ 非 secure ∧ committedText 汉字 ≥ 4 ∧ 冷却未激活），通过则快照 {epoch, appSessionID, bundle, context(contextProvider(policy) 截断 400), cloudHistorySnapshot, generation} 并发送请求（记 `continuation_requested`）。结果到达守卫梯（与 spec §5.3 一一对应）：requestID 最新 ∧ epoch 相同 ∧ `compositionIsEmpty()` 且非 selecting ∧ appSessionID 相同 ∧ 非 secure ∧ 到达时间在 `deadline+50ms` 内 ∧ `ContinuationTextPolicy.isValid(response:for:)` → emit `showSuggestion(text)`（记 shown）+ 排 8s 自动隐藏（fire `cancel(.timedOut)`）；abstain/error/超时记 `continuation_abstained` 并累计冷却计数，连续 3 次进入 60s 冷却（记 `continuation_cooldown`，期间 arm 静默），一次成功 generate 清零计数。展示期间任何 `cancel` → `hideSuggestion` + 记 `continuation_dismissed`。去重：容量 64 的会话内 LRU（context.suffix(32) → Set[已展示文本]），重复建议不 emit showSuggestion；被 keyTyped 顶掉的建议记入该 Set。`acceptCandidate` 清状态并允许再次 arm；链式联想的下一轮 arm 由 T6 `commitContinuation` 显式调用 `commitDidHappen` 触发。

- [ ] **Step 1: 写失败测试** — `test_commitDebounceLatestWins`（两次 commit 只发最后一次的 context）；`test_gateMatrix`（开关关 / AI 禁用 app / policy strict / secure / 上屏 3 汉字 → 零请求零事件）；`test_guardLadderDropsLateResults`（结果返回前 keyTyped 取消 / epoch 变化（新 commit）/ composition 非空 / isSelecting / appSessionID 切换 / secure / 超过 deadline+50ms 才到达 → 均不 emit showSuggestion）；`test_brokerSilenceLeavesPendingUntilNextCommit`（旧 broker 静默不回包：无 showSuggestion、无错误事件，下一次 commit 正常回收并重新 arm）；`test_abstainCooldown`（3 连 abstain → 第 4 次 commit 不发请求；模拟 60s 后恢复）+ `test_cooldownResetsOnGenerate`（2 次 abstain 后一次 generate → 计数清零）；`test_dedupSameContextTail`（同 context 尾不再推同一文本）+ `test_dedupLRUBoundedAt64`；`test_autoHideAfter8Seconds`（ManualScheduling 推进 8s → hideSuggestion + dismissed）；`test_acceptRecordsDiagnosticAndAllowsRearm`。
- [ ] **Step 2: 跑 `swift test --filter PostCommitContinuationCoordinatorTests` 确认失败。**
- [ ] **Step 3: 实现** 协调器（状态字段：`commitEpoch/pendingRequestID/inFlightSnapshot/armedDebounce/hideTimer/shownSuggestions:[[String: Set<String>]]/consecutiveAbstains/cooldownUntil`）。
- [ ] **Step 4: 跑 `swift test --filter RimeAIInputCoreTests` 全绿。**

### Task 5: 候选面板续写形态

**Files:**
- Modify: `Sources/RimeAIInputCore/DaemonProtocol.swift`（`SemanticCandidatePresentation` :33-54 新增 case）
- Modify: `macos/RimeAIInputMethod/CandidatePanelController.swift`（`Content` :6-13；`update` :91-94；`show` :205）
- Test: `macos/RimeAIInputMethodTests/CandidatePanelContinuationTests.swift`（新建；该 target 为 XCTest 风格：`import XCTest` + `@testable import RimeAIInputMethod`，仿 `SettingsWindowSupportTests.swift`）

**Interfaces:**
- Consumes: T3 的 `HistoryCommitSource.continuation`。
- Produces（T6 依赖）:
  ```swift
  // SemanticCandidatePresentation 新增：
  case continuation(candidate: String)   // isSelectable == true；historySource == .continuation

  // CandidatePanelController 新增：
  func showContinuation(_ text: String, anchor: NSRect,
                        onSelection: @escaping () -> Void) -> Void
  // 内部：构造 semanticPresentation == .continuation(candidate: text)、主候选行为空、
  // pageLabel nil、cloudInFlight false 的 Content，走既有 update + show(anchorRect:)
  // 路径；semanticSelectionHandler 接 onSelection。不经过 refreshCandidatePanelIfActive。
  ```
- `update` 的 semantic 分支对 `.continuation` 渲染标题 "✦ 续写"（样式同 `:127-145` 的 LLM 生成分支）。

- [ ] **Step 1: 写失败测试** — `test_continuationPresentationIsSelectableAndLabeledContinuation`；`test_showContinuationDisplaysSingleChipAndFiresSelection`（模拟点击 semanticButton → onSelection 恰好一次）；`test_showContinuationWithoutCompositionDoesNotAffectRefreshPath`（空 Content 时 `refreshCandidatePanelIfActive` 等价行为回归：不显示）。
- [ ] **Step 2: 跑 `xcodebuild test -project macos/RimeAIInputMethod.xcodeproj -scheme RimeAIInputMethod -destination 'platform=macOS'` 确认新测试失败。**
- [ ] **Step 3: 实现** presentation case、面板标题分支与 `showContinuation`。
- [ ] **Step 4: 相关 Swift 测试全绿 + `swift test --filter RimeAIInputCoreTests` 无回归。**

### Task 6: 控制器接线与云传输

**Files:**
- Modify: `macos/RimeAIInputMethod/CloudBrokerClient.swift`（`HelloRequest.capabilities` :28 追加；仿 `infer` :116 新增 continuation 发送/响应解码）
- Modify: `macos/RimeAIInputMethod/RimeAIInputController.swift`（持有 coordinator；`activateSession` 的 session 变更分支 :186-190 / `deactivateServer` :89 / `enterSecureInput` :222 加 cancel）
- Modify: `macos/RimeAIInputMethod/RimeAIInputController+CompositionIO.swift`（`commitText` :162 成功路径末尾 arm；commit 前记录 anchor）
- Modify: `macos/RimeAIInputMethod/RimeAIInputController+KeyEvents.swift`（`handleOnMain` :16-19 prelude 后加空组合取消）
- Modify: `macos/RimeAIInputMethod/RimeAIInputController+Selection.swift`（新增 `commitContinuation(_:client:)`）
- Test: `tests/RimeAIInputCoreTests/`（能下沉的核心逻辑）；macos target 测试覆盖接线

**Interfaces:**
- Consumes: T1-T5 全部 Produces。
- Produces:
  ```swift
  // CloudBrokerClient
  func continuation(_ request: CloudContinuationRequest, apiKey: String,
                    completion: @escaping @Sendable (CloudContinuationResponse?) -> Void) -> Void
  // 超时口径与 infer 一致：deadline + 50ms 后 pending 移除并以 nil 回调（协调器计入冷却计数）
  // HelloRequest.capabilities = ["text-generation", "continuation-generation"]

  // RimeAIInputController+Selection.swift
  func commitContinuation(_ text: String, client sender: Any!) -> Void
  // 1) client.insertText(text, replacementRange: NSMakeRange(NSNotFound, NSNotFound))
  // 2) contextStore.appendCommittedText(text)（AI 允许 ∧ policy 非 strict 时，同 insertCommittedText :212-219）
  // 3) historyService.appendAsync(HistoryCommit(..., source: .continuation))（同 :225-241 门控）
  // 4) 记 continuation_accepted、隐藏面板
  // 5) 链式联想：显式调 coordinator.commitDidHappen(...)（commitContinuation 不经过 commitText，
  //    不 arm 就没有下一轮；同 context 同一建议由 T4 去重拦住）
  ```
- 接线要点：`onEvent` 里 `showSuggestion` → `candidatePanel.showContinuation(text, anchor: lastCommitAnchor)`，回调走 `coordinator.acceptCandidate` + `commitContinuation`；`hideSuggestion` → `candidatePanel.hide()`（仅当面板处于续写形态，避免误关正常候选面板——面板加 `isShowingContinuation` 标志）。`lastCommitAnchor` 在 `commitText` 里 `resetComposition` 之前用 `cursorAnchorRect(client:client:characterIndex:0)`（+Panel.swift:61-77）取。空组合 keyDown 取消插在 `handleOnMain` 的 prelude 之后、keyCode 分派之前：`if !composition.hasComposition { continuationCoordinator.cancel(.userTyped) }`，返回值不变。
- `isContinuationEnabled` 注入合成：`settings.continuationSuggestionEnabled && settings.aiEnabled && settings.cloudConfigured`。

- [ ] **Step 1: 写失败测试** — 核心逻辑（能进 InputCore 测试的）：无；接线行为用 macos target 测试（若 `RimeAIInputController` 现无单测基建，则以 T4 状态机测试 + 编译 + Step 4 手动验收兜底，并在任务记录中注明）。可测的最小件：`CloudBrokerClient.continuation` 的编解码单测（仿现有 CloudBrokerClient 测试若存在；否则构造 NDJSON 假 socket pair）`test_continuationLineEncodingIncludesApiKeyAndType`、`test_continuationResponseDecoding`。
- [ ] **Step 2: 跑相关测试确认新测试失败。**
- [ ] **Step 3: 实现** 上述接线；`compositionInput`（`+CompositionIO.swift:7`）开头加 `cancel(.compositionBegan)`。
- [ ] **Step 4: `swift test --filter RimeAIInputCoreTests` 全绿 + macos target 构建通过（`script/build_and_run.sh` 或 xcodebuild，按仓库惯例）。**

### Task 7: 真实键盘验收、文档与任务表

**Files:**
- Modify: `TASKS.md`（新增一行任务，状态 `IN-PROGRESS` → 验收后 `DONE-INTERNAL`，遵守维护规则）
- Modify: `macos/RimeAIInputMethod/PrivacyCenterWindowController.swift`（文案补一行"上屏后续写联想会发送最近上屏文本"）
- Modify: `README.md`（交付边界摘要，若 README 有功能清单则补一行）

- [ ] **Step 1: 启动 broker（`script/` 下云 broker LaunchAgent 或手动 `python -m rimeai_cloud_broker`）与 debug 输入法，开启菜单"上屏后续写联想"。**
- [ ] **Step 2: 手动验收清单** — ① 打"床前明月光"+空格上屏 → 1s 内出现"疑是地上霜"chip → 点击 → 上屏且 `history_commits` 新增 `source='continuation'` 行；② chip 出现后立即打字/按任意键 → chip 即刻消失、无残留、无重复上屏；③ 切换应用、⌃Space 切输入法、Secure Input（Terminal sudo）三种场景 chip 不出现/即消失；④ 关闭开关后 commit 零请求（诊断无 continuation_requested）；⑤ 连续上屏多句只出最后一次的建议；⑥ 等待 8s chip 自动消失。全项通过后把 TASKS.md 状态改为 `DONE-INTERNAL` 并更新日期。
- [ ] **Step 3: 全套回归** — `swift test --filter RimeAIInputCoreTests` + macos target 测试 + `PYTHONDONTWRITEBYTECODE=1 python3.11 -m pytest tests/ -q -p no:cacheprovider` 全绿，提交。

## 依赖关系

```
T1（协议类型）──┬──► T2（broker）──► T2.5（真实模型冒烟闸门）
                └──► T4（协调器）──► T6（控制器接线）──► T7（真实键盘验收）
T3（设置/诊断/HistorySource）独立，可与 T1/T2 并行
T5（面板）依赖 T3 的 HistoryCommitSource.continuation，完成后并入 T6
```

- T2.5 是 go/no-go 闸门：不过则先按 spec §3.1 扩白名单再继续。
- T1→T2/T4 是硬接口依赖（CloudContinuationRequest/Response、ContinuationTextPolicy）。
- T4→T6 是硬接口依赖（协调器 API 与事件枚举）。
