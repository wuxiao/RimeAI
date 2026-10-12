# 跨标点整句解码（方案 C）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 输入整句拼音中途输入标点后，本地/云端能产出跨标点的整句候选（如“床前明月光，举头望明月”），选中后一次性提交全部段；无标点时行为完全不变。

**Architecture:** 在线协议中新增可选 `segments` 字段（每段 `{pinyin, separator, committed_text}`，`pinyin` 字段恒为活跃段以保持向后兼容）。解码策略：本地 daemon 逐段 beam 解码（前缀段用 committed_text 快照，末段用活跃段候选，context 累积），云端单次 LLM 往返生成整句并用 PinyinGuard 逐段对齐；separator 由客户端拼接/校验，语言模型与 PinyinGuard 都不需要输出标点。

**Tech Stack:** Swift（`Sources/RimeAIInputCore`，macOS 输入法 + iOS 共享编译）、Python（`rimeai_runtime`/`rimeai_daemon`/`rimeai_cloud_broker`，pytest）。

**根因调查:** 见对话记录——`appendCompositionLiteral`（`macos/RimeAIInputMethod/RimeAIInputController+KeyEvents.swift:382-403`）+ `CompositionState.appendLiteral`（`Sources/RimeAIInputCore/CompositionState.swift:143-166`）在标点时刻把活跃段定稿为单一首选快照并清空候选；协议层硬性拒绝含标点的拼音（`CloudBrokerProtocol.swift:166-168`、`rimeai_cloud_broker/server.py:73`）。

## Global Constraints

- 向后兼容：`segments` 为 nil/缺省时一切行为不变；旧 broker/daemon 收到带 `segments` 的请求静默走旧路径（现有校验不拒绝未知字段），协议版本号保持 1。
- `consumedLength` 语义不变：`== len(request.pinyin)`（活跃段字母数），因为 `choose` 路径与 Rime 提交/学习都是单段语义。客户端本地构造的（不进线协议的）`cloudGenerated` 候选可以用各段字母总数。
- `PinyinSegment` 校验规则（Swift 与 Python 镜像）：1 ≤ 段数 ≤ 8；每段 pinyin 匹配 `[a-z']+` 且 ≤ 64 字母；字母总数 ≤ 256；非末段 separator 非空、≤ 8 UTF-8 字节、只含标点类字符（白名单：ASCII 标点 + CJK 标点 + 全角 ASCII + General Punctuation）；末段 separator == ""；`committed_text` ≤ 64 字、无 `\n`/`\0`；**`segments.last.pinyin == request.pinyin`**（两侧硬校验）。
- iOS 只共享编译 `Sources/RimeAIInputCore`（只用 Foundation，不引 AppKit）；整句功能范围限定 macOS，iOS 行为不变。
- 所有新增/修改文件只含必要改动，不做顺手重构。

## Review Focus

- 前缀段 `committed_text` 为快照错字时（首选不是用户想要的）：解码应沿用快照或跳过该段，不得崩溃或整体弃权 → T2 测试锁定。
- 整句候选中 separator 布局与 segments 不符（LLM 漏标点/多标点）→ 三层（broker validate_decision、qwen guard、客户端 CloudGeneratedSentencePolicy）都必须拒绝 → T1/T3 测试锁定。
- 退格复活上一段后，飞行中的整句推断结果必须因 token/revision 失配被丢弃，不得把旧整句候选贴到新组合上 → T4/T5 测试锁定。
- 无前缀段（无标点）请求不得携带 `segments` 字段（精确回归，防旧服务端行为漂移）→ T4 测试锁定。
- 整句提交时不得重复前置 `committedPrefixText` → T5 测试锁定。

---

### Task 1: 协议层（Swift 共享类型 + 校验）

**Files:**
- Modify: `Sources/RimeAIInputCore/DaemonProtocol.swift`（:332-387 `SemanticInferenceRequest`；:525-567 `SemanticInferenceResult.isValid`）
- Modify: `Sources/RimeAIInputCore/CloudBrokerProtocol.swift`（:105-205 `CloudInferenceRequest`；:218-245 `CloudGeneratedSentencePolicy`；:293-461 `CloudInferenceResponse`）
- Test: `tests/RimeAIInputCoreTests/DaemonProtocolTests.swift`、`tests/RimeAIInputCoreTests/CloudBrokerProtocolTests.swift`

**Interfaces:**
- Produces（后续所有任务依赖）:
  ```swift
  public struct PinyinSegment: Codable, Equatable, Sendable {
      public let pinyin: String          // [a-z']+
      public let separator: String       // 段尾标点，末段为 ""
      public let committedText: String?  // CodingKey "committed_text"
  }
  public enum PinyinSegmentPolicy {
      public static let maximumSegments = 8
      public static let maximumSegmentPinyinLetters = 64
      public static let maximumTotalLetters = 256
      public static func isValid(_ segments: [PinyinSegment], activePinyin: String) -> Bool
      public static func canonicalJSON(_ segments: [PinyinSegment]) -> String?  // 与 Python json.dumps(..., sort_keys=True, ensure_ascii=False, separators=(",",":")) 逐字节一致
  }
  // CloudGeneratedSentencePolicy 新增重载：
  public static func allows(text: String, pinyinSegments: [PinyinSegment], confidence: Double) -> Bool
  // SemanticInferenceRequest / CloudInferenceRequest 新增：
  public let segments: [PinyinSegment]?   // init 默认 nil，encodeIfPresent
  // CloudInferenceResponse 新增：
  public let generatedSegments: String?   // CodingKey "generated_segments"，decode 缺省 nil
  // SemanticInferenceResult.isValid(for:candidates:) 新增默认参数 segments: [PinyinSegment]? = nil
  ```

- [ ] **Step 1: 写失败测试** — `test_pinyinSegmentPolicyValidation`（段数越界/长度越界/非标点 separator/末段 separator 非空/活跃段不一致均拒，合法例通过）；`test_segmentedInferenceRequestEncodesOptionalSegments`（nil 时 JSON 无 `segments` key）；`test_generateResponseRequiresSegmentEchoMatch`；`test_generatedSentencePolicyAllowsCrossPunctuationLayout`（“床前明月光，举头望山石” 通过）+ `RejectsMismatchedSeparators/NonHanPart/OverLength`。
- [ ] **Step 2: 跑 `swift test --filter RimeAIInputCoreTests` 确认新测试失败。**
- [ ] **Step 3: 实现** `PinyinSegment`、`PinyinSegmentPolicy`、四个既有类型的可选字段扩展、`allows(text:pinyinSegments:confidence:)`（按 separator 依序切分，每个非末段 separator 恰好出现一次且按序；每 part 纯汉字 0x3400...0x9FFF；汉字总数 ≤ 30；每 part 字数 ≤ 对应段字母数；confidence ≥ 0.60）。
- [ ] **Step 4: 跑 `swift test --filter RimeAIInputCoreTests` 全绿。**

### Task 2: Python 本地运行时（daemon 逐段 beam 解码）

**Files:**
- Modify: `rimeai_runtime/beam_decoder.py`（:198-234 附近新增多段编排）
- Modify: `rimeai_daemon/engine.py:184-260`（`infer` 分流）
- Modify: `rimeai_daemon/server.py:58-130`（`_validate_inference_request` 增加可选 segments 校验）
- Test: `tests/test_beam_decoder.py`、`tests/test_daemon_engine.py`、`tests/test_daemon_socket.py`

**Interfaces:**
- Consumes: T1 的 JSON 契约（`segments` 字段形状与校验规则）。
- Produces:
  ```python
  @dataclass(frozen=True)
  class SegmentDecodeInput:
      pinyin: str
      separator: str
      committed_text: str

  # BeamSentenceDecoder 新方法（raw_decode/suggest 接口不变）
  def suggest_segments(self, *, context: str,
                       segments: Sequence[SegmentDecodeInput],
                       active_candidates: Sequence[str]) -> BeamSuggestion
  ```

- [ ] **Step 1: 写失败测试** — `test_suggest_segments_decodes_each_segment_with_accumulated_context`、`test_suggest_segments_falls_back_to_committed_text`（前缀段 guard 无法对齐时沿用快照而非整体失败）、`test_suggest_segments_min_confidence_gates_joined_sentence`；engine 级 `test_engine_segment_suggestion_joins_with_separators` + 回归 `test_engine_without_segments_keeps_single_segment_behavior`；socket 级 `test_segmented_infer_request_passes_validation_and_returns_joined_sentence` + `test_segmented_request_with_mismatched_active_pinyin_rejected`。
- [ ] **Step 2: `.venv/bin/python -m pytest tests/test_beam_decoder.py tests/test_daemon_engine.py tests/test_daemon_socket.py -q` 确认新测试失败。**
- [ ] **Step 3: 实现** `suggest_segments`（前缀段 candidates=`[committed_text]`，末段 candidates=`active_candidates`，逐段调既有解码，context 累积“已解码文本 + separator”，合成置信度与 margin 取各段 min，返回含 separator 的拼接文本）；`engine.infer` 在 `segments` 存在且段数 > 1 时 sentence 路径改走 `suggest_segments`，`SENTENCE_MIN_CONFIDENCE` 作用于合成置信度；`server._validate_inference_request` 镜像 T1 校验。
- [ ] **Step 4: 上述 pytest 全绿 + `.venv/bin/python -m pytest tests/ -q` 无回归。**

### Task 3: 云端 broker（qwen generate 跨标点）

**Files:**
- Modify: `rimeai_cloud_broker/server.py:55-156`（`validate_request`）、`:159-222`（`validate_decision`）、`:532-555`（响应构造）
- Modify: `rimeai_cloud_broker/qwen.py:55-179`（`rank` prompt）、`:295-342`（`_validate_generated_decision`）
- Test: `tests/test_cloud_broker.py`

**Interfaces:**
- Consumes: T1 的 JSON 契约；`rimeai_runtime.pinyin_guard.PinyinGuard.matches`（逐段复用，不改）。
- Produces: generate 响应新增 `generated_segments` 字段 = 请求 segments 的规范 JSON 回显（`json.dumps(..., sort_keys=True, ensure_ascii=False, separators=(",",":"))`）。

- [ ] **Step 1: 写失败测试**（沿用现有 fake-ranker 模式）— `test_segmented_generate_joins_separators_and_passes_alignment`、`test_segmented_generate_with_wrong_separator_abstains`、`test_segmented_generate_with_misaligned_single_part_abstains`、`test_segments_request_validation_rejects_mismatched_active_pinyin_and_bad_separators`、`test_generated_segments_echoed_verbatim_in_response`。
- [ ] **Step 2: `.venv/bin/python -m pytest tests/test_cloud_broker.py -q` 确认新测试失败。**
- [ ] **Step 3: 实现** — `validate_request` 增加可选 segments 校验（镜像 T1）；`rank` 在 segments 存在时 prompt 增加 `"segments"` 字段（含 committed_text 提示）并在 task 文案追加“逐段理解，输出整句时段间原样保留给定 separator，段内纯汉字逐字对应该段拼音”（单次往返，不逐段调用）；`_validate_generated_decision` 增加 segments 参数，按 separator 切分后逐段 `guard.matches`，布局不符即 abstain；响应构造追加 `generated_segments` 回显。
- [ ] **Step 4: `.venv/bin/python -m pytest tests/test_cloud_broker.py -q` 全绿 + 全套 pytest 无回归。**

### Task 4: Swift 客户端——组合状态 + 推断携带 segments

**Files:**
- Modify: `Sources/RimeAIInputCore/CompositionState.swift`（:143-166, :251-266, 各清理点 :163/:199-202/:221-222/:239-244/:271-272/:331）
- Modify: `Sources/RimeAIInputCore/SemanticSuggestionPipeline.swift`（:171-175 依赖闭包、:380-462 `scheduleInference`、:513-642 `buildAndSendCloudInference`、:679-847 `applyLocalResult`、:960-1029 `applyCloudGeneratedResult`）
- Modify: `macos/RimeAIInputMethod/RimeAIInputController+Pipeline.swift`（`applySemanticCandidate` 闭包实现）
- Test: `tests/RimeAIInputCoreTests/CompositionStateTests.swift`、`tests/RimeAIInputCoreTests/SemanticSuggestionPipelineTests.swift`

**Interfaces:**
- Consumes: T1 的 `PinyinSegment`/`PinyinSegmentPolicy`。
- Produces（T5 依赖）:
  ```swift
  // CompositionState
  public private(set) var semanticCandidateSegments: [PinyinSegment]?  // 随 semanticCandidate 在所有清理点同步清空
  public var inferenceSegments: [PinyinSegment]?  // prefixSegments 以 committedPinyin 开头且活跃段非空时构造；紧随拼音段的连续 literal 拼接为其 separator；末段 separator ""。前导 literal 或无前缀 → nil
  func applySemanticCandidate(..., segments: [PinyinSegment]? = nil)
  ```

- [ ] **Step 1: 写失败测试** — `test_inferenceSegmentsBuiltFromCommittedPrefix`（含多 literal 拼接、末段空 separator、前导 literal 返回 nil）；`test_reviveLastPinyinSegmentClearsSemanticCandidateSegments`；`test_applySemanticCandidateStoresSegments`；管线级 `test_scheduleInferenceSendsSegmentsWhenPrefixPresent`、`test_cloudGeneratedSegmentsResultAppliedWithSegmentsRecorded`、回归 `test_noSegmentsWhenPrefixEmpty`。
- [ ] **Step 2: `swift test --filter RimeAIInputCoreTests` 确认新测试失败。**
- [ ] **Step 3: 实现** — CompositionState 新属性与清理点同步；`scheduleInference` 取 `composition.inferenceSegments` 注入 local 请求，`allowSentence` 用各段字母总数判 `LocalSentenceSuggestionPolicy`；`buildAndSendCloudInference` 构造请求时从 `compositionSnapshot()` 再取一次 segments（防竞态）；`applyLocalResult` 调 `result.isValid(for:candidates:segments:)`；`applyCloudGeneratedResult` 本地 CloudCandidate 的 `consumedLength` 用各段字母总数并透传 segments。
- [ ] **Step 4: `swift test --filter RimeAIInputCoreTests` 全绿。**

### Task 5: Swift 客户端——提交路径 + 退格交互锁定

**Files:**
- Modify: `macos/RimeAIInputMethod/RimeAIInputController+Selection.swift:122-178`（`selectSemanticCandidate`）
- Test: `tests/RimeAIInputCoreTests/CompositionStateTests.swift`

**Interfaces:**
- Consumes: T4 的 `semanticCandidateSegments`、T1 的 `CloudGeneratedSentencePolicy.allows(text:pinyinSegments:confidence:)`。

- [ ] **Step 1: 写失败测试** — `test_wholeCompositionSentenceCommitDoesNotPrependPrefix`（组合状态级：segments 布局匹配的整句候选提交文本不前置 `committedPrefixText`）；回归 `test_plainSentenceCommitStillPrependsPrefix`。
- [ ] **Step 2: 跑测试确认失败。**
- [ ] **Step 3: 实现** — `selectSemanticCandidate` 直连提交分支：
  ```swift
  let coversWholeComposition = composition.semanticCandidateSegments != nil
      && CloudGeneratedSentencePolicy.allows(text: committedCandidate,
                                             pinyinSegments: composition.semanticCandidateSegments!,
                                             confidence: 1)
  let text = coversWholeComposition ? committedCandidate
                                    : composition.committedPrefixText + committedCandidate
  let historyPinyin = composition.historyPinyin
  ```
  `commitText` 的 `resetComposition` 负责清空前缀与 marked text。面板与 `appendCompositionLiteral` 不改（标点后下一击键整句候选出现在 AI 槽）。
- [ ] **Step 4: `swift test` 全绿。**

### Task 6: 端到端验证

- [ ] **Step 1:** `.venv/bin/python -m pytest tests/ -q` 全绿。
- [ ] **Step 2:** `swift test` 全绿。
- [ ] **Step 3:** 构建并安装调试版输入法（`script/build_and_run.sh` / `script/install_debug_input_method.sh`）。
- [ ] **Step 4:** 手工验收：
  - 输入 `chuangqianmingyueguang` → 全角 `，` → `jutousanchiyoushengming`：AI 槽出现跨标点整句候选（daemon 通道与云端通道各验一次：断 daemon / 关 API key 分别测试）；上屏一次性提交全部段（含逗号），无重复前缀。
  - 退格链路：整句候选展示后逐字母回删 → 候选收敛；删空活跃段 → 复活上一段；无残留整句候选、无重复上屏。
  - 回归：无标点输入（`nihao`、长句）行为与现在一致（请求 JSON 无 `segments`）。
  - 兼容：对旧 broker 请求仍合法，降级为仅活跃段生成。

## 依赖关系

```
T1 (协议类型+校验) ──┬─→ T2 (daemon Python)
                    ├─→ T3 (broker Python)
                    └─→ T4 (Swift 组合状态+管线) ─→ T5 (提交/退格) ─→ T6 (端到端)
```
T1 冻结 JSON 契约后 T2/T3/T4 可并行；T6 需全部完成。
