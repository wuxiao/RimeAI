# 上屏后智能续句联想（Post-Commit Continuation Suggestion）设计

**日期:** 2026-10-12
**状态:** 已实现（2026-10-12 完成真实键盘验收，KBD-003 DONE-INTERNAL）
**范围:** macOS 输入法（iOS 不在本期范围）

## 1. 问题与目标

用户打完一句并上屏（如"床前明月光"）后，当前系统不再有任何智能辅助——候选面板无条件隐藏（`macos/RimeAIInputMethod/RimeAIInputController+CompositionIO.swift:256`），用户必须重新敲下半句的拼音才能得到整句建议（跨标点整句方案 `docs/superpowers/plans/2026-10-11-cross-punctuation-sentence-decoding.md` 也要求先敲标点+拼音）。

目标：**上屏后基于已上屏文本主动推荐下一句（如"疑是地上霜"），用户单击即可上屏，零按键成本。** 成功标准：

1. 上屏"床前明月光"后 1s 内，光标附近出现"疑是地上霜"建议 chip；点击即上屏并计入历史/上下文（与手打一致）。
2. 用户开始任何新击键、切换应用、进入 Secure Input、开始新组合时，建议立即消失，绝不残留、绝不误上屏。
3. 功能默认关闭，独立开关 opt-in；per-app 禁用名单与 ContextPolicy=strict 的应用完全不触发。
4. 不延迟、不干扰正常打字路径（建议是纯增量 UI，不阻塞拼音组合）。

非目标（明确排除）：
- ~~键盘快捷键接受建议（Tab/方向键）——上屏后空组合状态下拦截按键会与应用焦点导航冲突，二期再评估。~~（2026-10-12 修订，见下方修订记录）
- iOS 端（现有结构在空组合时移除全部候选视图，`ios/KeyboardExtension/KeyboardViewController.swift:509-514`，需要独立设计）。
- 本地 daemon 开放式生成（见备选方案 B，留作二期）。
- 多候选并列（MVP 单 chip；接受率数据证明需要后再扩展）。

### 修订记录

- **2026-10-12（实现期修订）：裸 Tab 接受纳入本期。** 原排除理由是"空组合状态拦截按键与焦点导航冲突"。实现采用收窄后的安全形态：仅当续写 chip 正在显示、且为不带任何修饰键（Command/Control/Option/Shift）的裸 Tab 时拦截接受；带修饰键的 Tab 组合（如 Shift+Tab 反向焦点导航）一律放行给宿主；chip 未显示时 Tab 完全走原路径。真实键盘验收通过（接受→上屏→链式续写）。方向键接受仍为二期。

## 2. 现状关键事实（探索结论）

| 事实 | 位置 | 对设计的影响 |
|---|---|---|
| commit 链路：`commitText` → `insertCommittedText`（写 contextStore + 异步写历史）→ `resetComposition` → 面板隐藏 | `+CompositionIO.swift:162-261` | 触发点唯一且清晰：`commitText` 返回后 |
| 面板刷新有 `composition.hasComposition` 守卫 | `+Panel.swift:52-54` | 需要新的空组合渲染路径 |
| 面板 `hasVisibleContent` 允许"仅 AI 槽"撑起面板 | `CandidatePanelController.swift:193-209` | UI 可复用，不必新建窗口 |
| 本地 beam 解码强依赖拼音（候选字来自音节反查表） | `rimeai_runtime/beam_decoder.py:172-175` | 本地通道无法产出零拼音续写 |
| user_lm 只有 `rerank` 接口，无生成接口 | `rimeai_daemon/user_lm.py:181` | 同上 |
| 云 broker generate 决策强制 PinyinGuard 逐字对齐，不对齐即 abstain；请求要求非空 pinyin | `rimeai_cloud_broker/qwen.py:433-439`、`server.py:174-177` | 需要新的请求形态与校验梯 |
| 云端有客户端能力协商（`text-generation`） | `server.py:644-656` | 新能力位照抄该模式 |
| `HistoryContextSnapshot`（recentText/snippets/generation）现成 | `Sources/RimeAIInputCore/HistoryStore.swift:75-89` | 上下文来源直接复用 |
| `voiceEnabled` 是"默认关、要求 aiEnabled、独立菜单项"的开关范本 | `RimeAISettingsStore.swift:434-440` | 设置项照抄该模式 |
| 云防护梯用 `historyGeneration` 做 stale 判据 | `SemanticSuggestionPipeline.swift:902` | 见 §5.3 epoch 方案 |
| **现有冻结模型（qwen3.5:0.8b）实测会逐字复读 prompt 中的 context，且"context reasoning needs a larger model"；`PROMPT_INCLUDE_HISTORY` 因此冻结为 False** | `rimeai_cloud_broker/qwen.py:34-39`、白名单 `:22-24` | **与本功能正面冲突：续句联想是纯上下文推理任务。见 §3.1 模型能力约束** |

## 3. 方案选择

**方案 A（选定）：云 broker 新增 `continuation` 请求形态 + 客户端 PostCommit 协调器 + 复用候选面板 AI 槽。**
上屏后由新协调器向云 broker 发送"纯上下文续写"请求，broker 用 Qwen 生成下一句并用新的 `ContinuationTextPolicy`（不要求拼音对齐）校验；结果以单 chip 显示在现有候选面板，点击上屏。

**方案 B（否决，留二期）：本地 user_lm 开放式生成。**
给 `UserLanguageModel` 加 greedy/beam 续写接口。优点：离线、免费、隐私最优；缺点：字符 n-gram（orders 2-5）对"床前明月光→疑是地上霜"这类知识型续写质量不可控（用户历史里没有的诗句无法可靠产出），且需新增生成+置信度框架，工程量不小。协调器按"多源仲裁、云端优先"设计，二期可把本地源插进来而不动 UI/触发层。

**方案 C（否决）：不满足零按键，只强化打字时整句建议。**
即现状增强，不解决本需求。

### 3.1 模型能力约束（go/no-go 前置）

仓库内已有实测证据与本功能正面冲突：`qwen.py:34-39` 记录 qwen3.5:0.8b 会把 prompt 里的 recent_context/history snippet **逐字复读进生成文本**（剥掉后 10/10 可见生成 vs 带上下文 3-7/10），结论原文"context reasoning needs a larger model"；白名单冻结为 `{"qwen3.5:0.8b"}`（`qwen.py:22-24`）。续句联想是纯上下文推理任务——prompt 必须携带 recentContext，否则无从续写——且 §5.2 的 `echoes_context` 校验会把复读输出全部打成 abstain，叠加连续 3 次 abstain 冷却 60s，结果是功能静默失效而非出错。`PROMPT_INCLUDE_HISTORY = False` 只作用于既有 rank/generate 的拼音约束路径，不影响本任务（本任务没有拼音）。

因此决策分两步走：
1. **冒烟闸门（实现计划 Task 2.5）**：用真实 broker + 真实 Ollama 模型跑 10 条固定上下文集（含"床前明月光，"→"疑是地上霜"等名句续写、日常对话续写、易复读陷阱样例），要求 ≥7/10 通过 §5.2 校验且非复读，才继续客户端任务；不达标即走第 2 步。
2. **白名单扩展（预案）**：为 continuation 引入独立白名单（如 `CONTINUATION_ALLOWED_MODELS`），纳入一个 ≥1.5B 档模型（具体型号由冒烟测试在 qwen2.5:1.5b / qwen3.5:1.5b 等候选中选定），Swift 侧 `RimeAICloudConfiguration` 镜像新增 `continuationModelIDs`；不改既有 inference 路径的模型锁定。冒烟数据同时回写到 `qwen.py` 的注释约定处，防止该决策再次丢失。

这同时修正 §5.2 原表述："生成模型、Ollama 端点、白名单复用现有配置"仅作起点假设，最终模型由冒烟闸门决定。

## 4. 架构总览

```
commitText (上屏)
   │  bump continuationEpoch; 记录 anchor rect
   ▼
PostCommitContinuationCoordinator (新, Sources/RimeAIInputCore)
   │  防抖 250ms (latest-wins); 门槛: 开关+aiEnabled+cloudConfigured+policy≠strict+非secure+context≥4汉字
   │  快照: epoch / appSessionID / bundleID / context(按policy截断) / historySnapshot / anchor
   ▼
CloudBrokerClient.sendContinuation(CloudContinuationRequest)   ──► 云 broker (qwen.py 新 continuation task)
   │                                                              │  ContinuationTextPolicy 校验
   │  应用时守卫梯: epoch 相同 ∧ 组合仍空 ∧ appSessionID 相同        │  (纯汉字 2–16 字, conf ≥ 0.65, 防复读)
   │  ∧ 非 secure input ∧ 未超时(3s) ∧ epoch 内无新击键              ▼
   ▼                                                    CloudContinuationResponse
CandidatePanelController.showContinuation(text:anchor:)   (generate | abstain)
   │  单 chip, 标题"✦ 续写"; 8s 自动隐藏; 任意 keyDown 即撤
   ▼ 点击
client.insertText(text) → 写历史(HistoryCommit source=.continuation) → contextStore.appendCommittedText
```

组件边界：
- **协议层**（`CloudBrokerProtocol.swift` + `rimeai_cloud_broker/`）：定义 `CloudContinuationRequest/Response` 与两侧镜像校验；不依赖组合状态。
- **协调器**（新文件 `Sources/RimeAIInputCore/PostCommitContinuationCoordinator.swift`）：拥有触发/取消/守卫/应用全部状态机；依赖全部以闭包注入（仿 `SemanticSuggestionPipeline` 的 seams 模式），不 import AppKit。
- **UI/接线**（`macos/RimeAIInputMethod/`）：面板新形态 + 控制器把 commit/keyDown/accept 事件接到协调器。

## 5. 详细设计

### 5.1 协议：CloudContinuationRequest / Response

`Sources/RimeAIInputCore/CloudBrokerProtocol.swift` 新增：

```swift
public struct CloudContinuationRequest: Codable, Sendable {
    public let schemaVersion = 1
    public let type = "continuation"
    public let requestID: String
    public let clientSessionID: String
    public let bundleIdentifier: String
    public let modelID: String            // 复用现有白名单
    public let recentContext: String      // 汉字数 ≥ 4, ≤ 400, 已按 ContextPolicy 截断
    public let historySnippets: [CloudHistorySnippet]
    public let historyGeneration: Int64?
    public let deadlineMilliseconds: Int  // 1...3000
}
public struct CloudContinuationResponse: Codable, Sendable {
    public let status: String             // ok | error
    public let requestID: String?
    public let decision: String?          // generate | abstain
    public let generatedText: String?     // decision == generate 时非空
    public let confidence: Double?
    public let reason: String?
    public let modelID: String?
    public let elapsedMilliseconds: Double?
}
```

客户端校验（Swift `isValid`）：recentContext ≥ 4 个汉字且 ≤ 400 字；deadline 夹取 ≤ 3000；type=="continuation"。

broker 侧（`rimeai_cloud_broker/server.py` + `qwen.py`）镜像校验；能力协商走既有 hello 握手（客户端 `HelloRequest.capabilities` 追加 `"continuation-generation"`，服务端 hello 广播与消费照抄 `text-generation` 模式，`server.py:489-504`/`:644-656`），未声明时 broker 直接 abstain。

### 5.2 broker：continuation 任务与 ContinuationTextPolicy

`qwen.py` 新增任务 `continuation-v1`：prompt 给 recentContext + historySnippets，要求"只输出紧接上文的下一短语，纯汉字，不加解释"。新校验（替代 PinyinGuard 对齐）：

```python
CONTINUATION_MINIMUM_CONFIDENCE = 0.65
CONTINUATION_MIN_HAN = 2
CONTINUATION_MAX_HAN = 16

def continuation_text_allows(text: str, context: str, confidence: float) -> bool:
    # 1) 2–16 个汉字 (0x3400..0x9FFF)，不允许任何标点/数字/字母/空白
    # 2) confidence >= 0.65
    # 3) 防复读：text 不得是 context 尾部 32 字的子串；
    #    text 与 context 尾部重叠 ≥ 4 字亦拒（半句重复）
```

任一不过 → `abstain`（带 reason）。生成模型与白名单的决策以 §3.1 的冒烟闸门为准（起点复用现有 qwen3.5:0.8b，不达标则扩 continuation 专用白名单）；Ollama 端点不变。能力位 `"continuation-generation"` 有意复用 `text_generation_enabled` 门控（同部署、同模型档位，解耦无收益），在此注明以避免误读。

### 5.3 触发、取消与守卫（协调器状态机）

**触发：** `commitText` 成功返回后，控制器 `continuationCoordinator.arm(...)` 并 bump `continuationEpoch`（控制器持有的 UInt64 计数器，每次 commit +1）。防抖 250ms 内多次 commit 只保留最后一次（latest-wins，复用 `SemanticSuggestionScheduling.scheduleOnMain` seam）。

**触发门槛（arm 时评估，任一不满足则静默不触发）：**
- `continuationSuggestionEnabled`（新设置，默认 false）∧ `aiEnabled` ∧ `cloudConfigured`
- `isAIAllowed(for: bundleID)` ∧ `contextPolicy(for: bundleID) != .strict`
- 非 Secure Input（`isSecureEventInputEnabled()`）
- 上屏文本含 ≥ 4 个汉字（英文/纯数字上屏不触发）

**快照（防抖到期发送前取）：** epoch、appSessionID、bundleID、context（`contextStore` 当前值按 policy 截断）、`cloudHistorySnapshot` seam（实作 `HistoryStore.contextSnapshot(query:...)`，`HistoryStore+Retrieval.swift:32`）、anchor rect（commit 时刻由控制器记录的最后一次 marked/cursor 位置）。

**取消（任一发生立即撤建议/取消飞行中请求）：**
- 任意 keyDown（含非拼音键）：控制器 `handleOnMain`（`+KeyEvents.swift`）在空组合分支第一步调 `coordinator.cancel(.userTyped)`
- 新组合第一键：`compositionInput`（`+CompositionIO.swift:7`）开头调 `cancel(.compositionBegan)`
- 应用会话切换：`activateSession` 内 `composition.switchApplicationSession` 分支（`RimeAIInputController.swift:186-190`）调 `cancel(.sessionSwitched)`；`deactivateServer`（`:89`）调 `cancel(.deactivated)`
- 进入 Secure Input：`enterSecureInput`（`:222`）调 `cancel(.secureInput)`
- 8s 超时自动隐藏（`.timedOut`）。注：面板是 borderless NSPanel、无关闭按钮，不存在"用户手动关闭面板"事件，不设该取消理由。

**应用守卫梯（结果返回时依次校验，任一失败丢弃且不显示）：**
1. `pendingRequestID == requestID`（latest-wins）
2. epoch 未变（**用 `continuationEpoch` 而非 historyGeneration 做 stale 判据**——`insertCommittedText` 的异步历史写入会 bump generation，用它会把建议自己顶掉；epoch 只被"新 commit"bump，语义精确。**broker 侧 continuation 路由也不做 history_generation 响应期比对**（既有 `_run` 在 `server.py:628-632` 的静默丢弃对 continuation 是竞态陷阱：commit 的异步写历史恰好在请求飞行中 bump generation），新鲜度完全由客户端 epoch 保证）
3. 组合仍空（`!composition.hasComposition`）∧ 非 `isSelecting`
4. appSessionID 相同
5. 非 Secure Input
6. 未超时：响应在 `deadline + 50ms` 之后到达即丢弃（与 `CloudBrokerClient` 既有超时口径一致），超时/传输失败计入 cooldown 计数
7. 响应 `isValid`（requestID 匹配、status ok、decision generate、文本过 Swift 侧 `ContinuationTextPolicy` 镜像校验）

### 5.4 UI：面板续写形态

- `SemanticCandidatePresentation` 新增 case `continuation(candidate: String)`，`isSelectable == true`。
- `CandidatePanelController` 新增入口 `showContinuation(_ text: String, anchor: NSRect)`：主候选行为空、semantic 槽渲染为标题"✦ 续写"的单 chip；不经过 `refreshCandidatePanelIfActive` 的 `hasComposition` 守卫（该函数不改，避免影响既有路径）。
- 8s 自动隐藏（`scheduleOnMain` seam 排一个一次性计时，被任何取消条件清掉）。
- 点击 → `onContinuationSelection` 回调 → 控制器 `commitContinuation(_:client:)`。

### 5.5 接受上屏

`RimeAIInputController+Selection.swift` 新增 `commitContinuation(_ text: String, client:)`（client 类型与 `insertCommittedText` 的入参一致）：
1. `client.insertText(text, replacementRange: NSMakeRange(NSNotFound, NSNotFound))`（与 `insertCommittedText` 同参语义）
2. `contextStore.appendCommittedText(text)`（与手打一致，使下一次续写有正确上下文）
3. `historyService.appendAsync(HistoryCommit(..., source: .continuation))`（`HistoryCommit.source` 枚举新增 case；受同一 `shouldCaptureCloudHistory` 门控）
4. 诊断 `continuationAccepted`；面板隐藏
5. **链式联想**：末尾显式调 `coordinator.commitDidHappen(...)`（以含新上屏文本的 context 开下一轮；`commitContinuation` 不经过 `commitText`，不 arm 就不会有下一轮；同 context 的同一建议由 §5.7 去重拦住）

### 5.6 设置与隐私

- `RimeAISettingsStore` 新增 `continuationSuggestionEnabled`（key `RimeAIContinuationSuggestionEnabled`，默认 false，仿 `voiceEnabled` :434-440）；`aiEnabled == false` 时视为关。
- 菜单项（`+MenuAndSettings.swift`），设置导出 schemaVersion +1 并迁移。
- 导入一致性：`applyImport` 仿 `voiceRequiresAI` 守卫（`RimeAISettingsStore.swift:799-801`）新增 `continuationRequiresAI`——导入文档 `continuationSuggestionEnabled=true` 且 `aiEnabled=false` 时拒绝导入。
- 发送的上下文只有：recentContext（≤ policy 上限 400 字）+ historySnippets（复用现有检索与脱敏）；不发送 pinyin/candidates（本请求没有这些字段）。
- `disabledAIApplications` / `disabledContextApplications` / policy=strict 的应用零触发（arm 门槛即拦截）。
- PrivacyCenter 文案补一行用途说明。

### 5.7 防骚扰与去重

- **同上下文去重：** 协调器维护会话内 LRU（容量 64 条；context 尾 32 字 hash → 已展示文本集合），相同尾部上下文不重复展示同一建议；已拒绝（被 keyDown 顶掉）的建议在本会话内不再推第二次。
- **频率上限：** 连续 3 次 abstain/error 后冷却 60s 内不再 arm（本地计数器，非熔断器，不跨进程）；一次成功 generate 即清零该计数。
- 诊断事件：`continuationRequested / continuationShown / continuationAccepted / continuationDismissed / continuationAbstained / continuationCooldown`。

### 5.8 诊断与验收指标

以现有 `RimeAISettingsStore.record` 计数为准，验收看：`continuationAccepted / continuationShown` 比值、abstain 率、p95 延迟（`elapsedMilliseconds` 已有通道）。

## 6. 测试策略

- **协议**：Swift `CloudBrokerProtocolTests` 补 request/response 编解码与 `isValid`；pytest 补 broker 校验镜像（context <4 汉字拒、>400 拒、能力缺省 abstain）。
- **broker**：fake-ranker 模式测 `continuation_text_allows`（非纯汉字/超长/低置信/复读 context 尾部均 abstain；"床前明月光"→"疑是地上霜" 通过）。
- **协调器**：新 `PostCommitContinuationCoordinatorTests.swift`，自带 mini harness（复制 `SemanticSuggestionPipelineTests` 的 `ManualScheduling` 思路，其 fakes 是 private，不跨文件复用）：防抖 latest-wins、门槛矩阵、守卫梯（epoch 变化/组合非空/session 切换/secure/超时）、8s 自动隐藏、去重与冷却。
- **面板**：`CandidatePanelController` 测 `showContinuation` 内容与点击回调。
- **回归**：空组合时 `refreshCandidatePanelIfActive` 行为不变；未开启设置时 commit 后零请求零面板。
- **真实键盘验收**（发布门前的手动验收，写入 plan 最后一个 task）：开启开关 → 上屏"床前明月光" → chip 出现 → 点击上屏；随后的任何击键/切窗/secure 场景无残留。

## 7. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 幻觉/不当续写（部分上下文被断章取义） | conf ≥ 0.65 + 纯汉字白名单 + 默认关闭 + per-app 禁用 + 8s 自动隐藏 |
| 干扰感（频繁弹出） | 单 chip、8s 超时、同上下文去重、3 连 abstain 冷却、接受率指标监控 |
| 竞态误上屏（用户已开始打字建议才回来） | epoch + 空组合 + appSessionID + keyDown 即撤，四重守卫；应用路径永不写 marked text |
| 面板锚点漂移（上屏后光标移动） | anchor 取 commit 时刻位置；keyDown 即撤已覆盖绝大多数移动场景；MVP 不追踪鼠标移动光标（记录为已知限制） |
| broker/Ollama 未运行 | 云失败路径静默（记诊断），无 UI 提示，与现有云通道行为一致 |
| 模型复读上下文或质量不足（qwen3.5:0.8b 实测复读，`qwen.py:34-39`） | §3.1 冒烟闸门前置拦截；`echoes_context` 校验拒收；失败形态是 abstain 静默 + 冷却，用户无感 |

## 8. 分期

- **一期（本设计）**：macOS + 云 broker continuation 通道 + 单 chip UI + 默认关闭。
- **二期候选**：本地 user_lm 生成源（协调器多源仲裁已预留）；键盘接受；多候选；iOS 适配。二期均需真实接受率数据支撑（TASKS.md 维护规则：只有新的真实数据证明必要时才新建任务）。
