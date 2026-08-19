# 语音听写模态设计与协议草案

本文档是 [DESIGN.md](../DESIGN.md) DR-008 所要求的独立语音工作流的设计文档。
它不改变键盘语义输入主线，不进入键盘 MVP；所有内容均为 `ACCEPTED TARGET
STATE`（已接受的设计方向），尚无任何 `CHECKED IMPLEMENTATION` 证据。若与
DESIGN.md 键盘主线冲突，以 DESIGN.md 为准。

## 1. 产品边界与隐私合同

语音听写是与拼音输入并行的独立输入模态：

- 语音文本不进入拼音候选管线，不参与 candidate-ID-only 云合同；该合同
  继续只约束键盘模态。
- helper 进程只提供建议文本；上屏的唯一触发是用户显式确认
  （`Space`/回车采用听写候选，`Esc` 取消）。helper 永远不能触发上屏。
- 未配置云凭证且使用本地 ASR 时，语音链路全离线：音频不出内存、不出设备。
- 录音期间输入法 UI 必须显示麦克风状态；`Secure Event Input` 活跃时禁用
  语音入口，与既有云请求和历史写入的行为一致。
- 音频永不落盘；识别完成后内存缓冲立即释放。

模式定义：

| 模式 | 管线 | 阶段 |
|---|---|---|
| `direct` | ASR 原文 → 确认上屏 | V0 |
| `polish` | ASR → LLM 润色 → 确认上屏；润色失败显式降级为 direct 结果 | V1 |
| 自定义（翻译、prompt 优化等） | 模式即数据：名称 + prompt 模板 + 触发键 | V2 |

## 2. 进程架构

```
┌──────────────────────────────┐         ┌───────────────────────────────┐
│ RimeAI 输入法 (IMK 客户端)    │  NDJSON │ RimeAI 语音 helper (服务端)    │
│ · 语音快捷键入口               │  over   │ · 麦克风采集 16kHz mono Int16  │
│ · 听写候选面板（流式刷新）      │  UDS    │ · 本地 ASR（离线）或云 ASR     │
│ · Space/回车确认，Esc 取消     │ ──────> │ · 可选 LLM 润色（仅 V1 起）    │
│ · 熔断与 latest-wins          │         │ · LaunchAgent 按需启停          │
└──────────────────────────────┘         └───────────────────────────────┘
```

职责与不变量：

- 输入法进程不做音频采集。macOS 输入法进程无法可靠获得麦克风 TCC 授权，
  录音必须发生在有独立 bundle 标识的 helper 进程。
- helper 复用云 broker 的生命周期模式：用户级 LaunchAgent、marker 文件
  按需启停、同 UID 检查、0600 UDS。服务标识 `fun.wwcn.rimeai.voice-helper`。
- 本地 daemon 的 Offline Lock 不受影响：语音 helper 是独立进程，其网络
  策略由自身模式决定并在握手中声明。
- 单段录音上限 60 秒，超限自动按当前缓冲出 final。
- 传输沿用第 8.1 节选型理由：长度受限、版本化的 NDJSON over Unix Domain
  Socket，一行一个 JSON 对象，UTF-8。

## 3. UDS 协议 V1

所有消息共享 `protocol_version: 1` 与 `type` 字段。客户端是输入法，服务端
是 helper。客户端和服务端都必须逐字段校验；任一校验失败按 `protocol_error`
处理，不允许猜测字段语义。

### 3.1 握手

客户端连接后必须先发送：

```json
{
  "protocol_version": 1,
  "type": "voice_hello",
  "client_id": "fun.wwcn.inputmethod.RimeAI",
  "capabilities": ["dictation", "cancel", "accept-ack"]
}
```

服务端响应：

```json
{
  "protocol_version": 1,
  "type": "voice_ready",
  "server_id": "fun.wwcn.rimeai.voice-helper",
  "capabilities": ["local_asr", "streaming", "polish"],
  "network_policy": "offline",
  "asr_engine_id": "apple-speech-ondevice"
}
```

约束：

| 字段 | 要求 |
|---|---|
| `capabilities` | 仅允许 `local_asr`、`cloud_asr`、`streaming`、`polish` |
| `network_policy` | `offline`、`cloud_asr_only` 或 `cloud_asr_and_polish`；`offline` 模式下 helper 不得创建任何 INET socket |
| `asr_engine_id` | 非空；制品形式时含内容哈希 |
| `protocol_version` | 不一致时立即断开，客户端回退纯键盘 |

`network_policy` 是隐私中心展示与本地断言的依据，不是信任声明：`offline`
策略需以与 Offline Lock 相同的抓包/审计方式验证。

### 3.2 开始听写

```json
{
  "protocol_version": 1,
  "type": "dictation_start",
  "request_id": "uuid",
  "composition_id": "uuid",
  "app_session_id": "bundle#nonce",
  "bundle_id": "com.apple.Safari",
  "mode": "direct",
  "deadline_ms": 1500,
  "max_duration_ms": 60000
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
- V0 `direct` 模式不发送光标上下文；V1 `polish` 增加 `context` 字段时，
  长度 ≤600 且必须沿用键盘模态的三档上下文策略与应用级策略。

### 3.3 流式增量

```json
{
  "protocol_version": 1,
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
  "protocol_version": 1,
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
- `elapsed_ms` 有限且 ≥0，从录音结束计时。
- final 后服务端立即释放音频缓冲；同一 `request_id` 不得再产生消息。

### 3.5 取消

```json
{
  "protocol_version": 1,
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
  "protocol_version": 1,
  "type": "dictation_accept",
  "request_id": "uuid",
  "accepted_text_sha256": "sha256-前16hex"
}
```

- 仅在用户显式确认、输入法 commit 之后发送。
- 哈希对象是客户端实际 commit 的 `final_text`；服务端校验不一致时静默
  丢弃，不得重发结果。
- 回执用于 helper 侧的会话统计与（V2 起）热词沉淀；音频已释放，回执不含
  文本本体。

### 3.7 错误

```json
{
  "protocol_version": 1,
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
                                                   ├──final──> pending_confirm
                                                   ├──error──> idle（含引导）
idle <──Esc/切换/SEI── listening 或 pending_confirm（发 cancel）
pending_confirm ──Space/回车──> commit ──发 accept──> idle
pending_confirm ──Esc──> 发 cancel ──> idle
```

- `listening` 期间 delta 间隔超过 2000ms 且无 final：客户端主动 cancel，
  本次会话按静默失败处理，不打断键盘输入。
- 熔断：同一安装会话内连续 3 次协议错误或连接失败后，禁用语音入口直到
  用户在设置中心显式重试，键盘输入不受影响。

## 4. ASR 引擎与 V1 阶段划分

### V0：本地直听（direct，全离线）

- helper 骨架 + 协议全量实现 + 输入法侧听写候选 UI。
- 引擎两个候选，由质量门选择，协议不感知引擎差异：
  - Apple Speech on-device（`requiresOnDeviceRecognition`）：零新增制品、
    零许可证审查，走通链路最快；
  - vendored qwen-asr C 库（Open-Less/OpenLess 使用的 `Open-Less/qwen-asr`）：
    受控源码静态链接，制品需走与 librime 相同的来源、哈希和许可证记录。
- 冻结内部语音测试集（≥200 句，覆盖通用与开发者领域），WER 与延迟门在
  集上选定。

### V1：云 ASR 与润色（polish）

- 一家 OpenAI 兼容批量 ASR 起步；音频仅上传至用户配置端点，凭证走既有
  cloud.env（`~/.config/rimeai/`，0600）通道。
- 润色复用现有 `glm-5.3` 端点与 Key，不引入新凭证。
- 录音期间对流式中间结果的投机润色必须节流：debounce ≥800ms、增量 ≥8
  字、in-flight 排队去重（参照 Type4Me `SpeculativeLLMThrottle` 语义）。
- 上下文注入沿用三档上下文策略；`context` 上限 600 字符。

### V2：模式即数据与个性化

- 自定义模式：名称 + prompt 模板 + 独立触发键；内置模式迭代使用带指纹
  检测的版本迁移，用户自定义保留（参照 Type4Me `ModeStorage` 语义）。
- 热词与纠错 snippet：用户修正一次 ASR 错误后，泛化出音近变体与热词建议，
  经用户勾选后沉淀到本地词典；与键盘模态的错拼扩候选互不共享运行时，
  仅共享词典格式。

## 5. 放行门（进入对应阶段前必须完成）

| 门 | V0 | V1 | V2 |
|---|---|---|---|
| 协议回环测试：握手、全消息、乱序、超时、取消、latest-wins、熔断 | 必须 | 回归 | 回归 |
| 麦克风 TCC 授权路径在干净用户会话真机验证 | 必须 | 回归 | — |
| `offline` 策略下 helper 无 INET socket 的本机验证 | 必须 | 回归 | — |
| 冻结语音集 WER 与录音结束到 final 的 P95 延迟门 | 必须 | 必须 | 回归 |
| 音频不落盘审计（含崩溃场景内存缓冲检查） | 必须 | 回归 | — |
| 隐私中心披露、麦克风状态 UI 与撤销路径 | 必须 | 更新 | 更新 |
| 云 ASR/润色的数据流披露与端点白名单 | — | 必须 | 更新 |
| THIRD_PARTY_NOTICES 增补（Type4Me/OpenLess MIT、模型制品来源） | 实现引入时 | 实现 | 实现 |

## 6. 开源复用映射

| 来源（均为 MIT） | 复用内容 | 处置 |
|---|---|---|
| `joewongjc/type4me` | ASR Provider 抽象、音频采集、会话状态机 | 裁剪重写为协议客户端 |
| `joewongjc/type4me` | `SpeculativeLLMThrottle` 与单测 | V1 参照语义重写 |
| `joewongjc/type4me` | thinking-disable 矩阵 | V1 采用（`glm-5.3` 即需关闭思维链） |
| `Open-Less/openless` | qwen-asr vendored C 库 | V0 候选引擎，受控链接 |
| `Open-Less/openless` | 各家流式 ASR 协议实现 | V1+ Swift 重写的参考 |

不采纳：两者的剪贴板 + Cmd+V 注入（输入法有 IMK commit 通路）、明文凭证
路径、Tauri/Rust 工具链、Type4Me 付费云订阅层。

## 7. 待验证问题

1. Apple Speech on-device 在目标机型的中文 WER、延迟与授权引导体验。
2. qwen-asr 0.6B 的受控构建体积、最低机型内存与 Metal 依赖边界。
3. 输入法进程内语音快捷键的选择是否与 IMK 现有键位冲突。
4. 60 秒单段上限下用户真实听写长度的分布。
5. `pending_confirm` 态与宿主应用焦点丢失竞态的行为矩阵。
6. helper 双网络进程（云 broker + voice helper）并存时隐私中心的统一展示。

## 8. 实现状态

截至 2026-08-19：

| 组件 | 证据等级 | 证据 |
|---|---|---|
| 协议消息层（8 消息 + 逐字段校验） | `CHECKED IMPLEMENTATION` | `Sources/RimeAIInputCore/VoiceDictationProtocol.swift`；snake_case 编解码往返与校验拒绝矩阵（换行、超长、越界 deadline、哈希格式、能力门）测试通过 |
| 客户端状态机 | `CHECKED IMPLEMENTATION` | `Sources/RimeAIInputCore/VoiceDictationClientMachine.swift`；happy path 仅显式确认上屏、Esc/SEI/会话切换/delta 超时取消、`mic_denied` 粘性、连续 3 次协议失败熔断测试通过 |
| 服务端会话核心（引擎无关） | `CHECKED IMPLEMENTATION` | `Sources/RimeAIInputCore/VoiceDictationServerCore.swift`；latest-wins 隐含取消、sequence 严格递增、final/取消后关停并丢弃迟到事件、accept 哈希不匹配静默、`polish_failed` 独立错误按协议违规断开、输出恰好投递一次测试通过 |
| 客户端 × 服务端回环 | `CHECKED IMPLEMENTATION` | 快捷键→握手→start→delta/final→显式确认→accept 回执全链路测试通过 |
| UDS 传输层 | `CHECKED IMPLEMENTATION` | `Sources/RimeAIInputCore/VoiceDictationTransport.swift`；NDJSON 分帧（64 KiB 行上限）、未知 type/坏行按协议错误断开、连接级 latest-wins、socket 0600；真实 Unix Domain Socket 回环与坏行断开测试通过 |
| helper 可执行骨架 | `CHECKED IMPLEMENTATION` | `swift build --product rimeai-voice-helper` 构建通过；真实二进制冒烟：hello→`voice_ready`（offline 策略）→start→显式 `mic_unavailable` |
| Coordinator 粘合层 | `CHECKED IMPLEMENTATION` | `Sources/RimeAIInputCore/VoiceDictationCoordinator.swift`；绑定状态机与传输、效果执行、服务端消息回灌、delta 超时定时器；真实 socket 全栈测试（startDictation→流式预览→待确认→显式确认才 commit→accept 回执）与 delta 超时静默取消测试通过 |
| Apple Speech 引擎 | `CHECKED IMPLEMENTATION`（仅编译与失败路径） | `Sources/RimeAIVoiceHelper/AppleSpeechEngine.swift`；`SFSpeechRecognizer` 强制 `requiresOnDeviceRecognition`（不支持本地识别的机型拒绝工作而非上云）、授权拒绝映射 `mic_denied`、无输入设备映射 `mic_unavailable`、60 秒上限收尾。识别质量与 TCC 授权路径需真实 GUI 会话，未运行时验证 |
| LaunchAgent 生命周期 | `CHECKED IMPLEMENTATION` | `script/install_voice_helper.sh`；真实 launchd 验证：bootstrap→socket 600→协议健康检查、`kill -9` 后 KeepAlive 自动重启、`--uninstall` bootout 清理无残留。已知边界：移除 marker 不会杀死已运行实例（PathState 只控制是否拉起），停止需 bootout |

以上测试位于 `tests/RimeAIInputCoreTests/VoiceDictationProtocolTests.swift`
（Swift Testing，31 项）。

尚未实现：Apple Speech 识别质量与 TCC 授权路径的真机验证、冻结语音
测试集（WER 与延迟门）、输入法 Xcode 工程的快捷键与听写候选 UI 接线
（`VoiceDictationCoordinator` 的回调即为接线面）、`apple-speech` 引擎的
LaunchAgent 安装组合验证。
