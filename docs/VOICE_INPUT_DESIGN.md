# 语音听写模态设计、协议与实现状态

本文档是 [DESIGN.md](../DESIGN.md) DR-008 所要求的独立语音工作流的设计文档。
它不改变键盘语义输入主线，也不自动进入公开版。本文同时记录
`ACCEPTED TARGET STATE`（已接受的设计方向）与第 8 节列出的
`CHECKED IMPLEMENTATION`（已验证实现）。Debug 私有 UDS 与 Release 双向认证
NSXPC/Mach service 均已接线；真实 Developer ID 对端、macOS 14、麦克风/TCC、
公证与清洁机器发布门尚未通过。若与 DESIGN.md 键盘主线冲突，以 DESIGN.md
为准；若与 PRD 的产品阶段冲突，以 PRD 为准。本文统一使用：V0=冻结语音集与
引擎评测，V1=通过 V0 后的按住说话技术原型。当前已接线的交互链路是提前完成
的 V1 技术探针；Debug helper 的 exact evaluation 入口与独立 V0 WAV eval driver
都可验证并真实加载调用方明确指定的产品模型候选，但不代表 V0 已通过，也不具备
发布资格。

## 1. 产品边界与隐私合同

语音听写是与拼音输入并行的独立输入模态：

- 语音文本不进入拼音候选管线，不参与 candidate-ID-only 云合同；该合同
  继续只约束键盘模态。
- helper 进程只提供建议文本；上屏的唯一触发是用户显式确认
  （`Space`/回车采用听写候选，`Esc` 取消）。helper 永远不能触发上屏。
- 本地 direct 模式的设计合同是音频只驻留内存且不出设备：只允许 on-device
  引擎，无法满足时 fail-closed，且当前 helper 不含云 ASR 或音频上传代码
  路径；运行态证据仍属于放行门。
- 录音期间输入法 UI 必须显示麦克风状态；`Secure Event Input` 活跃时禁用
  语音入口，与既有云请求和历史写入的行为一致。
- 音频永不落盘；识别完成后内存缓冲立即释放。

模式定义：

| 模式 | 管线 | 阶段 |
|---|---|---|
| `direct` | ASR 原文 → 确认上屏 | V1 技术探针；必须先通过 V0 引擎门 |
| `polish` | ASR → LLM 润色 → 确认上屏；润色失败显式降级为 direct 结果 | V1 之外的未来独立范围 |
| 自定义（翻译、prompt 优化等） | 模式即数据：名称 + prompt 模板 + 触发键 | 未来独立范围 |

## 2. 进程架构

```
┌──────────────────────────────┐         ┌───────────────────────────────┐
│ RimeAI 输入法 (IMK 客户端)    │ Debug:  │ RimeAI 语音 helper (服务端)    │
│ · 语音快捷键入口               │ 私有 UDS│ · 麦克风采集（引擎原生格式）   │
│ · 听写候选面板（流式刷新）      │────────>│ · 本地 ASR（on-device）        │
│ · Space/回车确认，Esc 取消     │ Release:│ · LaunchAgent 按需启停          │
│ · 熔断、目标门与代际           │ 认证 XPC│ · 云 ASR/润色不在当前范围       │
└──────────────────────────────┘ Mach ──> └───────────────────────────────┘
```

职责与不变量：

- 输入法进程不做音频采集。macOS 输入法进程无法可靠获得麦克风 TCC 授权，
  录音必须发生在有独立 bundle 标识的 helper 进程。
- helper 复用云 broker 的生命周期模式：用户级 LaunchAgent、marker 文件
  按需启停与当前用户权限门。服务标识和 Release Mach service 均为
  `fun.wwcn.rimeai.voice-helper`。
- 本地 daemon 的 Offline Lock 不受影响：语音 helper 是独立进程，其网络
  策略由自身模式决定并在握手中声明。
- 单段录音上限 60 秒，超限自动按当前缓冲出 final。
- 传输由编译配置决定，不能在运行时降级：Debug 只允许显式
  `developmentInsecureUDS`；Release 只允许双向认证 NSXPC/Mach service。
  两者复用同一套长度受限、版本化 JSON 语义和状态机。

### 2.1 传输安全不变量

- Debug UDS 位于当前用户 0700 runtime 目录，socket 必须为当前用户所有、0600
  且无扩展 ACL；helper 使用 0177 umask。它只能隔离其他普通用户，不能认证
  同 UID 进程，因此明确标为开发后端。
- Release 的 helper listener 与输入法 connection 在 `activate()` 前分别设置
  对端 requirement。requirement 固定 Apple generic anchor、Developer ID
  中间证书和 Application 叶证书 OID、同一 10 字符 Team ID 与精确对端
  identifier；Apple Development、ad-hoc、错误 Team/identifier 均不满足。
- Release 在 listener admission/首个 ping 后检查 peer PID 与 effective UID，
  并在 `ping`、`sendFrame`、`receiveFrame` 每次进入导出对象时通过当前 XPC
  connection 再校验 PID/UID。任何签名或 UID 门失败都在业务 `hello`/`start`
  前 fail-closed，不能请求 TCC，也不能回退 UDS。
- XPC 顶层只允许 `NSData` 和基础 reply；两个方向都是 ACK 驱动的单飞 FIFO，
  每帧最多 64 KiB，默认队列最多 32 帧/256 KiB。超限、负 ACK 或 proxy 错误
  会作废并清空该连接的队列。
- 只有首个合法 `voice_hello` 才把候选连接 promotion 为 current；client
  connection/authentication generation、server connection UUID、server-core
  epoch 与 request/session ID 一起阻止旧帧、旧 ACK、旧 disconnect 和旧异步
  引擎输出跨连接生效。

## 3. 共用语音协议 V2

所有消息共享 `protocol_version: 2` 与 `type` 字段。客户端是输入法，服务端
是 helper。客户端和服务端都必须逐字段校验；任一校验失败按 `protocol_error`
处理，不允许猜测字段语义。Debug UDS 以 UTF-8 NDJSON（一行一个对象）成帧；
Release XPC 每次方法调用承载一条无尾随换行的 `Data` JSON。两条路径都在解码
前执行 64 KiB 上限。

### 3.1 握手

客户端连接后必须先发送：

```json
{
  "protocol_version": 2,
  "type": "voice_hello",
  "client_id": "fun.wwcn.inputmethod.RimeAI",
  "capabilities": ["dictation", "cancel", "accept-ack"]
}
```

服务端响应：

```json
{
  "protocol_version": 2,
  "type": "voice_ready",
  "server_id": "fun.wwcn.rimeai.voice-helper",
  "capabilities": ["hotword_snapshot", "local_asr", "streaming"],
  "network_policy": "offline",
  "asr_engine_id": "sherpa-onnx@sha256-prefix",
  "maximum_hotwords": 32
}
```

约束：

| 字段 | 要求 |
|---|---|
| `capabilities` | 仅允许 `local_asr`、`cloud_asr`、`streaming`、`polish`、`hotword_snapshot` |
| `network_policy` | `offline`、`cloud_asr_only` 或 `cloud_asr_and_polish`；`offline` 模式下 helper 不得创建任何 INET socket |
| `asr_engine_id` | 非空；制品形式时含内容哈希 |
| `maximum_hotwords` | 有 `hotword_snapshot` 能力时为 1–128，否则必须为 0 |
| `protocol_version` | 不一致时立即断开，客户端回退纯键盘 |

`network_policy` 是隐私中心展示与本地断言的依据，不是信任声明。direct 的
`offline` 由 `requiresOnDeviceRecognition` 不满足即失败和无云代码路径实现。
签名不含 `com.apple.security.network.*` entitlement 仅是最小权限静态信号；
helper 不是 App Sandbox 进程，缺少这些 entitlement 不会强制禁止联网。发布
仍需以运行态无 INET socket 和与 Offline Lock 相同的抓包/审计方式验证。

### 3.2 开始听写

```json
{
  "protocol_version": 2,
  "type": "dictation_start",
  "request_id": "uuid",
  "composition_id": "uuid",
  "app_session_id": "bundle#nonce",
  "bundle_id": "com.apple.Safari",
  "mode": "direct",
  "deadline_ms": 1500,
  "max_duration_ms": 60000,
  "hotword_snapshot": {
    "normalization_version": 1,
    "phrases": ["API", "接口", "模型"],
    "hotword_set_sha256": "64-lowercase-hex"
  }
}
```

约束：

- 输入法侧只允许无活跃拼音 composition 时发起；有 composition 时语音入口
  置灰，避免两种模态争夺上屏。
- `mode` 仅允许 `direct` 与 `polish`；`polish` 需要握手能力包含 `polish`，
  否则按 `invalid_request` 拒绝。
- `deadline_ms` 限录音结束后到 `dictation_final` 的最大等待，1–5000。
- latest-wins：服务端收到新的 `dictation_start` 时，隐含取消前一会话并
  丢弃其音频缓冲，不产生任何前会话响应。
- 只有 `voice_ready` 协商到 `hotword_snapshot` 时才允许携带快照；
  客户端按 `maximum_hotwords` 截断后重新计算摘要。不支持热词的
  引擎必须省略字段，支持的引擎即使没有词也必须发合法空快照。
- 快照最多 128 条、每条 2–32 个 Character 且不超过 128 UTF-8
  bytes，总 UTF-8 不超过 16 KiB。以 NFKC+去首尾空白归一化，
  去重并拒绝 C0/C1 控制字符及 sherpa 控制语法 `/ : # @`。
  `hotword_set_sha256` 绑定归一化后的有序数组，仅作本地可比性
  校验，不是认证或防篡改边界；Release 信任仍来自双向签名 XPC。
- 当前输入法另设默认关闭的“Rime 会话热词辅助”明示开关；只有该开关
  启用时，才从同一宿主焦点会话中“用户已确认且 Rime
  `commitCandidate` 成功”的词条维护易失 MRU。它不枚举 Rime userdb，
  不读取历史、剪贴板或光标文本。关闭该策略、切应用/焦点、Secure Input、
  strict 策略、关闭语音/AI 或清理数据都会清空，重新启用不会恢复旧词；
  完整既有用户词典枚举仍是后续未完成项。
- 当前 `direct` 模式不发送光标上下文；未来 `polish` 增加 `context` 字段时，
  长度 ≤600 且必须沿用键盘模态的三档上下文策略与应用级策略。

### 3.2.1 松开结束采集

```json
{
  "protocol_version": 2,
  "type": "dictation_stop",
  "request_id": "uuid"
}
```

- 客户端仅在按住说话键松开后发送；`stop` 表示停止接收新音频并等待当前
  会话的唯一 final，不等同于丢弃会话的 `cancel`。
- 服务端收到匹配的首个 `stop` 后进入 finalizing，并要求引擎结束音频、
  异步产生 final；重复、迟到或不匹配的 `stop` 静默忽略。
- 客户端等待时间使用本次 `dictation_start.deadline_ms`；超时则发送
  `dictation_cancel(client_timeout)`，不提交临时文本。

### 3.3 流式增量

```json
{
  "protocol_version": 2,
  "type": "dictation_delta",
  "request_id": "uuid",
  "sequence": 4,
  "stable_text": "我们需要给数据库",
  "partial_text": "增加一个",
  "confidence": 0.87,
  "elapsed_ms": 812.5
}
```

约束：

- `sequence` 从 1 严格递增；客户端丢弃乱序或重复。
- `stable_text` + `partial_text` 为累计全量文本，非增量 diff；两者均单行、
  合计 ≤200 字，超限立即截断并按 final 结束。
- `confidence` 为 `[0, 1]` 内有限数值。
- 客户端只把 `stable_text + partial_text` 渲染为听写候选的预览态；
  任何 delta 都不得触发上屏。
- 服务端无法流式时允许跳过 delta，直接发 final。

### 3.4 最终结果

```json
{
  "protocol_version": 2,
  "type": "dictation_final",
  "request_id": "uuid",
  "final_text": "我们需要给数据库增加一个索引",
  "confidence": 0.92,
  "asr_engine_id": "apple-speech-ondevice",
  "polish_applied": false,
  "elapsed_ms": 1240.0
}
```

约束：

- `final_text` 单行、非空、≤200 字；`polish` 模式下为润色后文本，润色失败
  时为 ASR 原文且 `polish_applied: false`，并由客户端以降级状态展示。
- `elapsed_ms` 有限且 ≥0，由服务端单调时钟从对应会话的
  `dictation_start` 开始计时。
- final 后服务端立即释放音频缓冲；同一 `request_id` 不得再产生消息。

### 3.5 取消

```json
{
  "protocol_version": 2,
  "type": "dictation_cancel",
  "request_id": "uuid",
  "reason": "user_abort"
}
```

- `reason` 仅允许 `user_abort`、`session_switch`、`secure_input`、
  `client_timeout`。
- 双向语义：客户端取消（Esc、应用切换、SEI 检测、delta 间隔超时）；服务端
  遇到麦克风或引擎故障时用 `dictation_error` 而不是 cancel。
- 取消后服务端丢弃缓冲，不得返回任何后续消息。

### 3.6 接受回执

```json
{
  "protocol_version": 2,
  "type": "dictation_accept",
  "request_id": "uuid",
  "accepted_text_sha256": "sha256-前16hex"
}
```

- 仅在用户显式确认、输入法 commit 之后发送。
- 哈希对象是客户端实际 commit 的 `final_text`；服务端校验不一致时静默
  丢弃，不得重发结果。
- 回执只用于 helper 侧不含原文的会话统计；音频已释放，回执不含
  文本本体，也不从语音结果自动沉淀热词。

### 3.7 错误

```json
{
  "protocol_version": 2,
  "type": "dictation_error",
  "request_id": "uuid",
  "error_code": "mic_denied",
  "retryable": false
}
```

- `error_code` 仅允许 `mic_denied`、`mic_unavailable`、`asr_engine_error`、
  `asr_timeout`、`asr_overload`、`polish_failed`、`invalid_request`、
  `incompatible_protocol`、`internal_error`。
- `mic_denied` 时客户端必须引导到系统设置授权页并记住禁用状态。
- `polish_failed` 不得作为独立错误出现：润色失败一律降级为 direct final。

### 3.8 客户端状态机

```
idle ──语音快捷键──> connecting ──voice_ready──> listening
                        │                          │
                        └─连接失败/不兼容─> idle      ├──delta──> listening
                                                   ├──松开/stop──> finalizing
                                                   ├──final────────> pending_confirm
                                                   ├──error──> idle（含引导）
finalizing ──final──> pending_confirm
idle <──Esc/切换/SEI── listening、finalizing 或 pending_confirm（发 cancel）
pending_confirm ──Space/回车──> commit ──发 accept──> idle
pending_confirm ──Esc──> 发 cancel ──> idle
```

- `listening` 期间 delta 间隔超过 2000ms 且无 final：客户端主动 cancel，
  本次会话按静默失败处理，不打断键盘输入。
- `connecting` 期间松开直接放弃启动；迟到的 ready 不得开始麦克风会话。
- `finalizing` 超时按静默取消处理，任何临时文本都不得上屏。
- 熔断：同一安装会话内连续 3 次协议错误或连接失败后，禁用语音入口直到
  用户在设置中心显式重试，键盘输入不受影响。

## 4. ASR 引擎与产品阶段

### V0：冻结语音集与引擎评测

- V0 不以输入法 UI 或 IPC 是否可运行作为通过证据；它先建立授权真实录音、
  说话人隔离、冻结规则、版本化 normalization 与离线评分器，再在相同录音、
  硬件和系统版本上比较候选。
- macOS 14/15 的发布候选必须是产品管理本地模型，并携带来源、许可证、版本、
  内容哈希和离线导入合同。当前产品 adapter 已选择并精确链接静态
  sherpa-onnx/ONNX Runtime，但 runtime 可用不等于模型获批；模型候选仍未因列名、
  model-card 标签或能被加载而获得发布资格。
- Debug helper 只以 exact argv
  `--socket <path> --engine evaluation-product-managed --artifact-dir <absolute-canonical-directory>`
  接受单个候选：先执行 schema v2 严格验证，再调用
  真实 sherpa loader。该路径绕过且不修改产品 Store、publisher、selector 与
  trusted catalog，只用于测量；helper 的 evaluation main dispatch 仅存在于 Debug，
  Release main 的 fixed argv 无法到达该模式。evaluation factory 另由非发布的
  `rimeai-voice-eval-driver` 在 Release 优化构建中复用，以便把冻结 WAV 经真实
  verifier、sherpa loader、产品流式引擎与 ServerCore 生成 observations；该工具不
  嵌入输入法/helper 包，也不读产品 Store/catalog。不能把一次成功 load 或 WAV
  回放变成模型权利、再分发、TCC、资源、no-INET 或发布放行证据。
- macOS 26+ 可评测 Apple `SpeechAnalyzer` / `SpeechTranscriber` 这一系统管理
  候选，但要披露资产不可冻结与系统更新边界。
- 当前 `SFSpeechRecognizer` + `requiresOnDeviceRecognition` 适配器用于验证
  helper、TCC、停止/取消和协议链路。在 macOS 14/15 上它是
  `probe_only/policy_ineligible`；即使指标达标也不能通过产品模型质量门，且不
  伪造产品模型哈希。
- 正式 V0 至少使用 200 句授权真实录音，并同时评测 CER/WER、技术术语、标点、
  空白误输出、临时结果 churn、首结果、停止到 final、资源和热词误伤。
- 产品管理模型的严格 manifest/inventory、目录权限、资源上限和原子
  `current` / `previous` selector 基础层已经实现，合同与“不等于发布资格”的
  边界见 [`VOICE_ASR_ARTIFACT.md`](VOICE_ASR_ARTIFACT.md)。runtime binary、真实
  C API driver 与严格 load 路径已经接入；production trusted catalog 因模型来源/
  权利未完成而保持为空，当前没有可发布的产品模型或产品 ASR 声明。manifest
  schema v2 只记录制品事实并拒绝 legacy 再分发键；产品审批及四项审核/质量证据
  只存在于 code-shipped trusted catalog v2。

### V1：按住说话技术原型（direct）

- 只有通过 V0 的合格引擎才能进入 V1；当前已接线的按住说话、流式浮层、
  松开 final、确认上屏、取消、Secure Input 和目标代际仅是提前完成的默认关闭
  技术探针。
- V1 保持本地 direct、短句和显式确认，不把云 ASR、自由改写或润色混入同一
  放行结论。

### 未来独立范围：云 ASR 与润色（polish）

- 一家 OpenAI 兼容批量 ASR 起步；音频仅上传至用户配置端点，凭证走既有
  cloud.env（`~/.config/rimeai/`，0600）通道。
- 润色复用现有 `glm-5.3` 端点与 Key，不引入新凭证。
- 录音期间对流式中间结果的投机润色必须节流：debounce ≥800ms、增量 ≥8
  字、in-flight 排队去重（参照 Type4Me `SpeculativeLLMThrottle` 语义）。
- 上下文注入沿用三档上下文策略；`context` 上限 600 字符。

### 未来独立范围：模式即数据与个性化

- 自定义模式：名称 + prompt 模板 + 独立触发键；内置模式迭代使用带指纹
  检测的版本迁移，用户自定义保留（参照 Type4Me `ModeStorage` 语义）。
- 热词与纠错 snippet：用户修正一次 ASR 错误后，泛化出音近变体与热词建议，
  经用户勾选后沉淀到本地词典；与键盘模态的错拼扩候选互不共享运行时，
  仅共享词典格式。

## 5. 放行门（进入对应阶段前必须完成）

| 门 | V0 引擎评测 | V1 按住说话 | 未来云/润色 |
|---|---|---|---|
| 冻结语音集合同、授权/说话人隔离与可复现评分器 | 必须 | 回归 | 回归 |
| 合格引擎的质量、流式稳定性、延迟、资源、热词误伤和资产/许可证门 | 必须 | 回归 | 回归 |
| 共用协议/状态机：握手、全消息、乱序、超时、取消、latest-wins、熔断与确认后 commit | 测量适配器需要 | 必须 | 回归 |
| Debug UDS：owner/mode/ACL/umask、真实 socket 回环与坏帧 fail-closed | — | 必须 | 回归 |
| Release XPC：双向严格 Developer ID requirement、逐调用 UID/PID、64 KiB/有界 FIFO、connection/core 代际且无 UDS fallback | — | 必须 | 回归 |
| 真实 Developer ID 对端 + 命名 LaunchAgent Mach service，在 macOS 14 清洁机器完成安装/升级/回滚 | — | 必须 | 回归 |
| 麦克风 TCC 授权路径在干净用户会话真机验证 | 采集/适配器需要 | 必须 | 回归 |
| `offline` 策略下 helper 运行态无 INET socket/抓包审计 | 必须 | 回归 | 不适用 |
| 音频不落盘审计（含崩溃场景内存缓冲检查） | 必须 | 回归 | 重新定义 |
| 隐私中心披露、麦克风状态 UI 与撤销路径 | — | 必须 | 更新 |
| 云 ASR/润色的数据流披露与端点白名单 | — | — | 必须 |
| THIRD_PARTY_NOTICES 与模型制品来源 | 引擎引入时 | 回归 | 更新 |

## 6. 开源复用映射

| 来源（均为 MIT） | 复用内容 | 处置 |
|---|---|---|
| `joewongjc/type4me` | ASR Provider 抽象、音频采集、会话状态机 | 裁剪重写为协议客户端 |
| `joewongjc/type4me` | `SpeculativeLLMThrottle` 与单测 | 未来 polish 范围参照语义重写 |
| `joewongjc/type4me` | thinking-disable 矩阵 | 未来 polish 范围采用 |
| `Open-Less/openless` | qwen-asr vendored C 库 | 历史候选参考；须先经 V0、许可证和分发门，不是当前选型 |
| `Open-Less/openless` | 各家流式 ASR 协议实现 | 未来适配器参考 |

不采纳：两者的剪贴板 + Cmd+V 注入（输入法有 IMK commit 通路）、明文凭证
路径、Tauri/Rust 工具链、Type4Me 付费云订阅层。

## 7. 待验证问题

1. 当前 Apple Speech 技术探针在目标机型的中文 WER、延迟与授权引导体验
   （其结果不改变 macOS 14/15 的 policy-ineligible 状态）。
2. macOS 14/15 产品管理候选的质量、受控构建体积、最低机型内存、许可证与
   离线资产导入边界。
3. 真实 Developer ID 双端在命名 Mach service 上的 requirement、UID/PID 与
   interruption 行为，尤其是最低支持 macOS 14 的实际运行差异。
4. 麦克风与 Speech Recognition TCC 首次授权、拒绝、撤销和重试在清洁用户
   会话中的完整体验。
5. 60 秒单段上限下用户真实听写长度的分布。
6. helper 双网络进程（云 broker + voice helper）并存时隐私中心的统一展示。
7. 公证/stapling/Gatekeeper 后的首次安装、输入法/helper 错峰升级、回滚与
   清洁机器宿主矩阵。

## 8. 实现状态

截至 2026-08-21：

| 组件 | 证据等级 | 证据 |
|---|---|---|
| 协议消息层（9 消息 + 逐字段校验） | `CHECKED IMPLEMENTATION` | `Sources/RimeAIInputCore/VoiceDictationProtocol.swift`；V2 增加可协商的有界热词快照、引擎上限和归一化集合 SHA-256，并覆盖 snake_case 往返、换行/超长、deadline、哈希与能力校验 |
| 客户端状态机 | `CHECKED IMPLEMENTATION` | `VoiceDictationClientMachine.swift`；覆盖 connecting 期松开/取消、listening→finalizing→pending confirm、SEI/会话切换、delta/final 超时、麦克风拒绝粘性与熔断 |
| 服务端会话核心（引擎无关） | `CHECKED IMPLEMENTATION` | `VoiceDictationServerCore.swift`；stop 只结束采集并等待 final，cancel 丢弃会话；latest-wins、200 字安全截断、单调时钟 elapsed、迟到事件与 accept 哈希均有测试 |
| Coordinator | `CHECKED IMPLEMENTATION` | `VoiceDictationCoordinator.swift` 由编译配置选择 transport；hello 发出后 3 秒未收到合法 `voice_ready` 即关闭该代连接并允许重试；连接/效果代际与原子 callback 快照阻断旧 transport/旧 UI effect；提交返回 true 后才发 accept，shutdown 释放计时器与连接 |
| Debug 私有 UDS | `CHECKED IMPLEMENTATION` | `VoiceDictationTransport.swift`；当前用户 0700 runtime 与 0600 socket 均 fail-closed 复验并拒绝扩展 ACL，helper 以 0177 umask 消除 socket 初生权限窗口；真实 UDS 回环覆盖 stop→final、超时、坏帧、重新握手与 connecting 期立即重启。同 UID 代码身份不受保护，不能作为发布安全证据 |
| Release 认证 NSXPC | `CHECKED IMPLEMENTATION / NAMED SERVICE RUNTIME PENDING` | `VoiceDictationXPCTransport.swift`；双端严格 Developer ID requirement、连接与逐调用 UID/PID、`NSData` allowlist、64 KiB 预解码门、每方向 32 帧/256 KiB 单飞 FIFO、首个合法 hello promotion、connection token/generation 与 server-core epoch 已实现；Developer ID 输入法/Helper 配对制品已静态验签，安装后的命名 service 双向运行仍待外部验证；Release 初始化或认证失败不回退 UDS |
| helper App bundle | `CHECKED IMPLEMENTATION`（Developer ID 成对构建与静态校验） | `RimeAIVoiceHelper.app` 使用独立 bundle ID、麦克风与语音识别用途声明、唯一 audio-input entitlement；Debug 在构造引擎前只接受 exact socket-first argv，只有 `evaluation-product-managed` 可再携带一个 canonical absolute `--artifact-dir`，并可使用 Application Support 开发安装；Release 只接受固定 `--mach-service`，以相同 Team/version/build 内嵌在输入法 `Contents/Helpers` 并原位执行。Release LaunchAgent 只有 3 个 argv，不得选择引擎；helper 在模型/TCC/server 前复验自身 exact identifier、Developer ID Team/OID 与 bundle 资源封印，再严格读取签名 schema 2 policy。policy 绑定 trusted catalog v2 全字段与四项 release evidence 的 canonical SHA-256，宿主与 helper 副本逐字一致。当前 policy 明确 `ReleaseEligible=false` 且只允许 Apple probe |
| Apple Speech 引擎 | `CHECKED IMPLEMENTATION`（仅编译与注入测试） | `Sources/RimeAIVoiceHelper/Engine/AppleSpeechEngine.swift`；区分麦克风拒绝/不可用，强制 on-device，松开时 stop tap + endAudio 并有限等待 final，取消释放内存资源。真实识别与 TCC 尚未验证 |
| V0 冻结语料、回放与评分工具 | `CHECKED IMPLEMENTATION / REAL CORPUS PENDING` | `voice_dataset.py`、`voice_observation_collection.py`、`voice_evaluation.py`、独立 `rimeai-voice-eval-driver` 与 `VOICE_EVAL_FORMAT.md`；严格校验授权/说话人隔离/PCM WAV/内容指纹，native driver 以 20 ms cadence 将 WAV 送入真实 product engine/ServerCore，并以共同单调锚点产出 exact-once observations；聚合 CER/WER、标点、术语、空白误输出、churn、延迟、资源与热词误伤，并以 fail-closed gates 阻止 fixture、缺测子集及 macOS 14/15 system-managed 引擎获得 `quality_gate_pass`。回放在 session 前预加载模型、预读并转换音频，因此不替代性能/TCC/真机发布证据；正式授权语料与 observations 尚未采集 |
| 产品管理 ASR 制品、真实 backend 与流式核心 | `CHECKED IMPLEMENTATION / PRODUCTION MODEL BLOCKED` | Manifest schema v2 只记录制品事实，v1 与 legacy 再分发键 fail-closed；发布审批位于携带 `sourceReviewID`、`modelRightsReviewID`、`redistributionReviewID`、`qualityReportSHA256` 的 code-shipped catalog v2，production approvals 仍为空。质量字段必须绑定 schema v2 报告的 `quality_report_sha256`；Swift 仅校验摘要形状并纳入 catalog，首个 approval 前发布流程仍须重算摘要、确认 `quality_gate_pass == true` 并核对制品 provenance。`Package.swift` 以 exact checksum 直接接入 sherpa-onnx `1.13.6` 与 ONNX Runtime `1.27.1` static XCFramework；`SherpaOnnxProductBackend.swift` 通过真实 C API 严格校验 sherpa version、embedded revision `0fdffb3e` 与 ORT `1.27.1`，加载 artifact、执行非空热词容量 probe、fresh empty-stream probe 和流式识别。Debug helper 的 `evaluation-product-managed` 与独立非发布 eval driver 可对显式目录执行严格验证和真实 loader，且不触碰 Store/catalog；Release helper 只能由签名 policy 选择。制品/selector、lease→load probe→driver→descriptor 同代绑定、16 kHz/20 ms PCM、有界队列、endpoint、请求级热词快照和 stop/cancel/final 已接线；final 发布前显式销毁原生 stream，不把前一段热词/解码状态带到下一段。production catalog 为空，故 Release 仍为 Apple probe-only、没有产品模型声明；原生深层校验可能终止 helper，安全边界是进入 C 前的 policy/catalog/checksum 门与独立 helper 进程重启，而不是同进程捕获所有错误 |
| 输入法语音运行时与 UI | `CHECKED IMPLEMENTATION`（构建与纯逻辑测试） | 进程级 `VoiceDictationRuntime`、固定 `⌃⇧V` Carbon pressed/released、独立非激活浮层、Space/回车确认与 Esc 取消；owner/client/focus epoch/selection/caret/SEI/generation 在预览与上屏前复验，语音不写长期历史；另行明示开启的会话热词策略才把当前焦点会话中用户已确认的 Rime commit 作为有界易失 MRU 快照传入支持能力的产品引擎，不读历史/用户库；输入法 Debug 构建通过 |
| 设置与生命周期 | `CHECKED IMPLEMENTATION`（非 TCC 运行态） | 语音独立 opt-in 且默认关闭，受 AI 总开关约束；进程级串行 lifecycle manager 以设置为 desired 真值，在启动时 reconcile marker/LaunchAgent；Release 只在启用时从签名模板渲染指向 nested helper 的 LaunchAgent，环境令牌同时绑定 host build 与签名 policy SHA-256，模板、版本或 policy 不匹配即 fail closed，变更时先 bootout 旧 job；Debug 仍保留独立开发安装。停用区分 job 未加载与 bootout 失败并复验卸载；Debug 健康检查解析完整 `voice_ready`，Release 不以 `nc -U` 冒充客户端；隐私中心展示权限入口与无录音/听写历史边界 |

已通过的自动化包括：协议/客户端/服务端/Coordinator/快捷键状态机，真实私有
UDS 回环与 ACL/权限门，Apple Speech 授权依赖注入，匿名 NSXPC 全流程、错误
候选、认证前回调拒绝、错误 UID ping、64 KiB 帧、单飞 FIFO/背压和跨连接/
core epoch，以及安装器和 bundle verifier 的 Debug/Release 选择、Developer ID
requirement、完整 `voice_ready`、Debug evaluation exact argv/临时 lease/factory
隔离与回滚 shell harness。面向 macOS 14 SDK 的
Swift 5/6 编译探针也已通过；它只证明 API 可用，不是 macOS 14 真机结果。本次
新增的 V0 driver/WAV/真实 factory 定向 SwiftPM 测试与 eval-driver Release product
build 已通过；没有重新运行 Xcode 或真机链路。

以上实现仍是提前完成的 V1 交互阶段内部技术探针（wire contract
已为 V2），不等于 V0 评测或 V1 发布放行。
当前 Apple 适配器在 macOS 14/15 明确为 probe-only；产品管理分支也因生产 catalog
为空、无获批模型而不可用，不能对外声明本地产品 ASR。尚未完成：真实 Developer
ID 签名输入法/helper 在命名 Mach service 上的双向认证与拒绝矩阵、真实 macOS
14 运行、清洁用户会话中的麦克风与 Speech Recognition TCC 全流程、真实麦克风/
蓝牙/USB 设备矩阵、正式冻结语音集的 WER/术语准确率/首结果与 final P95、音频不
落盘和无 INET socket 的运行态审计、实际宿主应用的 Carbon 按住说话兼容性、
notarization/stapling/Gatekeeper，以及清洁机器的安装、错峰升级与回滚。任一
门未通过时，公开预览继续保持语音默认关闭。
