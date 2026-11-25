# 语音听写交互与 V2 协议

更新日期：2026-11-25
状态：`INTERNAL / NOT RELEASED`

本文是语音用户行为和 wire contract 的权威定义。总体产品与技术边界见
[../PRD.md](../PRD.md)、[../PRODUCT_DESIGN.md](../PRODUCT_DESIGN.md) 和
[../TECHNICAL_DESIGN.md](../TECHNICAL_DESIGN.md)；开发状态见
[../TASKS.md](../TASKS.md)。

## 1. 产品边界与隐私合同

- 语音默认关闭，且依赖 AI 总开关。
- 支持按住说话与右 `⌘` 单键点按切换，不持续监听、不提供唤醒词或会议转写。
- 默认听写快捷键为 `⌃⇧V`；用户可在设置中录制 `Control+Shift` 或 `Option+Shift`
  加普通字母/数字/标点键，或一键设为 **右 `⌘`**（`keyCode 54`，按一下开始、再按一下结束）。
- 另设默认 `⌃⇧T` 一键语音翻译快捷键：直接进入翻译意图，松开后识别并经云端
  `voice_transform` 翻译为目标语言（中英自动互译 / 英 / 中 / 日 / 韩 / 法 / 德 / 西）。
- 录音期间可选自动静音系统媒体音频（结束后严格恢复原静音/音量状态，不误取消用户原静音）
  并播放交互提示音；极简非激活浮窗仅展示状态指示点与实时自动换行文本。
- 支持 4 种风格智能润色（精简书面 / 正式专业 / 自然流畅 / 条理整理）：内置零延迟离线
  确定性润色器（去除口头语、消除叠词口吃、整理标点），配置云增强后自动升级为大模型深度
  润色（离线或超时自动回退本地润色，不丢字）。
- 成稿上屏有两条并行路径，由“自动粘贴”开关（`voiceAutoPasteEnabled`，默认开启）
  决定：**开启**时立即上屏——优先 IMK 直接插入，宿主拒绝且光标仍有效时回退
  剪贴板 + `⌘V` 并自动恢复原剪贴板；**关闭**时进入 `pending_confirm`，由 `Space`/
  回车确认、`Esc` 取消。两条路径在无焦点或无权限时都不强推：浮窗常驻供点击或
  `⌘C` 复制；Secure Event Input 下全阻断。
- 云端润色/翻译进行中按下 `Space`/回车不再等待：放弃在途转换，直接以已识别的
  原始文本走正常上屏流程（历史、自动粘贴与回退策略不变）。
- 语音子功能的默认值（仅在语音总开关开启后生效）：自动粘贴、交互提示音、录音时
  静音系统音频、本机语音历史与统计、智能润色、上屏后纠错学习均为**默认开启**，
  且都可单独关闭。
- 两项数据边界须**独立显式开启、默认关闭**：向云端润色/翻译发送热词上下文
  （`voiceCloudHotwordsEnabled`）与经辅助功能接口回读文档文本
  （`voiceAXFallbackReadEnabled`）。详见 3.10。
- 音频仅驻留当前会话进程内存中，不落盘、不上传云端；语音识别文本不进入键盘长期历史。
  独立的本机语音历史与使用统计（SQLite `VoiceHistoryStore`）完全仅存本机且可关闭、
  检索、导出与清除。真实运行态 no-INET/不落盘审计尚未完成，因此仍是发布门而非已放行声明。
- Secure Event Input、宿主/焦点/光标变化、设置关闭和旧代际消息必须取消会话。
- 语音失败只影响语音入口，Rime 键盘主链继续可用。
- 快捷键按物理键码保存并请求独占的系统级注册；注册冲突或系统拒绝必须在设置
  中显示，不能静默换用其他组合或继续显示为可用。

## 2. 进程架构

```text
InputMethodKit host
  ├─ VoiceDictationRuntime / Coordinator / minimal adaptive overlay
  ├─ VoiceLocalPolisher / VoiceClipboardPaster / VoiceSystemAudioMuter / VoiceSoundEffectsPlayer
  ├─ VoicePostCommitEditTracker / VoicePostCommitCorrectionLearner (post-commit correction learning)
  ├─ VoiceHistoryStore (local-only SQLite, isolated from keyboard history)
  ├─ Optional CloudBrokerClient -> voice_transform (polish / translate: 7 target languages + auto zh<->en, opt-in)
  └─ Transport
       ├─ Debug: owner-only UDS
       └─ Release: authenticated NSXPC Mach service
                          └─ RimeAIVoiceHelper
                               ├─ MLX Qwen3-ASR offline worker (Debug, no-INET, 2-layer hotwords)
                               ├─ Apple Speech probe
                               └─ product-managed sherpa-onnx buffer fork (production not approved)
```

Debug UDS 是开发边界；Release 初始化或认证失败不得回退 UDS。Release XPC
必须校验签名 requirement、Team/bundle、effective UID/PID、连接与消息代际。
详细威胁模型见 [VOICE_IPC_SECURITY.md](VOICE_IPC_SECURITY.md)。

## 3. 共用语音协议 V2

`protocol_version` 固定为 2。输入法是客户端，helper 是服务端。

- Debug UDS：UTF-8 NDJSON，每行一条消息。
- Release XPC：每次 Data RPC 一条无尾随换行的 JSON。
- 预解码记录上限 64 KiB；未知字段、重复键、超长值和非法枚举 fail-closed。
- request ID、composition、app session 和当前连接代际共同限定消息归属。

### 3.1 握手

客户端先发 `voice_hello`，服务端只在协议、身份与能力兼容时回
`voice_ready`。

`voice_ready` 必须明确：

- `server_id`；
- 能力集合；
- `network_policy`；
- `asr_engine_id`；
- 如支持热词，声明 `maximum_hotwords`。

客户端不得把 transport activate 当作 ready。hello 独立超时，迟到 ready 不得启动
麦克风。

### 3.2 开始听写

`dictation_start` 绑定：

- request、composition、app session、bundle ID；
- `direct` 或未来单独放行的 `polish` 模式；
- 1–30,000 ms deadline（协议上限 `maximumDeadlineMilliseconds = 30_000`；产品默认
  识别收尾 10,000 ms）与不超过 60 秒的最大时长；
- 可选、规范化、有摘要且受服务端上限裁剪的热词快照。

当前协议层 `dictation_start` 仍以 `direct` 模式获取原始离线转写，智能润色与翻译在
客户端管线层执行（本地确定性润色 + 可选云端 `voice_transform`，失败时安全回退原文或
本地润色）。热词快照支持融合三源：自定义常用语热词（最多 128 条）、语言画像短语库与
当前领域词库（独立开关），以及默认关闭的当前焦点会话已确认有限 Rime commit；不读取
完整 Rime 用户词典、键盘云历史或完整文档。

### 3.3 松开与 finalizing

松开快捷键发送 `dictation_stop`。服务端停止接收新音频、结束当前 stream 并
生成一次 final；客户端进入 `finalizing`，此时旧 delta 不得覆盖最终状态。

### 3.4 流式增量

`dictation_delta` 包含严格递增 sequence、stable text、partial text、confidence
和单调 elapsed time。文本必须单行，总长度不超过 200 个 Swift Character。

- 重复、乱序或旧 request delta 直接丢弃。
- delta 只更新 RimeAI 浮层，不写入宿主应用。
- stable/partial 不能跨会话继承。

### 3.5 最终结果与上屏路径

`dictation_final` 包含 final text、confidence、engine ID、polish 标记和 elapsed
time。final 最长 200 Character，必须在组合字素边界安全截断。

协议层保证“合法 final **不会自行上屏**”；是否需要用户二次确认由客户端管线按
设置决定，二者并不矛盾：

1. **final → 客户端后处理**：先应用已学习的纠错，再按意图执行本地确定性润色、
   云端 `voice_transform`（润色或翻译）或跳过润色。
2. **上屏路径 A（`auto-paste`，默认）**：后处理完成即 `confirm`——IMK 直接插入；
   宿主拒绝且光标仍有效时回退剪贴板 + `⌘V` 并恢复原剪贴板。
3. **上屏路径 B（`pending_confirm`）**：关闭自动粘贴时展示成稿，`Space`/回车
   请求宿主插入，`Esc` 取消。
4. **无焦点 / 无权限**：两条路径都不自动上屏，转为常驻复制浮窗。
5. **转换中直接上屏**：云端润色/翻译尚未返回时按下 `Space`/回车，放弃在途转换，
   以已识别原文进入上述上屏流程（`commitRawDuringTransform`）。

只有宿主 `insertText` 确认成功后，客户端才发 `dictation_accept`（见 3.7）。

### 3.6 取消

`dictation_cancel` 的原因限定为用户取消、会话切换、Secure Input 或客户端
超时。取消后服务端停止会话并丢弃晚到文本；同一 request 不得再次产生可接纳
final。

### 3.7 接受与错误

只有宿主 `insertText` 确认成功后，客户端才发 `dictation_accept`，并携带当前
request 和上屏文本的短 SHA-256 绑定。插入失败不得伪造 accept。

`dictation_error` 只使用稳定错误码，区分麦克风拒绝、设备不可用、引擎错误、
超时、过载、无效请求、协议不兼容和内部错误。润色失败若未来启用，应降级
direct final，而不是丢失已有识别文本。

### 3.8 客户端状态机

```text
idle
  └─ press -> connecting
       └─ compatible ready -> listening
            ├─ release -> finalizing
            ├─ final -> pending_confirm
            └─ cancel/error/SEI/switch -> idle

finalizing
  ├─ final -> pending_confirm
  └─ cancel/error/timeout -> idle

pending_confirm
  ├─ Space/Return + host insert success -> accept -> idle
  └─ Esc/SEI/switch/focus change -> cancel -> idle

transforming (client-side, after final: cloud polish / translate in flight)
  ├─ transform result -> auto-paste (confirm) | pending_confirm
  ├─ Space/Return -> cancel transform -> commit raw text -> idle
  ├─ timeout (polish 6s / translate 10s) / error / offline -> local fallback -> idle
  └─ Esc/SEI/switch -> cancel -> idle
```

`transforming` 是客户端管线状态，不是协议状态：期间旧 delta 与迟到的云端结果
同样不得覆盖最终状态。

所有 IO effect 都绑定 connection/session/effect generation。reset、disconnect、
设置变化或新宿主会先推进 generation，使已排队但未执行的旧 effect 失效。连续
协议失败达到门限后熔断；一次合法 final 会重置连续失败计数。

### 3.9 时限与文本上限

| 项 | 当前值 | 说明 |
|---|---|---|
| 协议 deadline 上限 | `maximumDeadlineMilliseconds = 30_000` | `dictation_start` 的 deadline 必须落在 1–30,000 ms |
| 识别收尾（finalization） | 默认 10 s | 松开后等待 final 的上限；超时走失败浮窗并可重试 |
| 云端润色 deadline | 6 s | 超时回退本地润色，不丢字 |
| 云端翻译 deadline | 10 s | 超时保留本地润色后的原文并提示 |
| `voice_transform` 输入 | ≤ 20,000 字符 | 超限直接走本地处理，不发云请求 |
| `voice_transform` 输出 | ≤ 30,000 字符 | broker 与客户端双重校验，超出视为无效结果 |
| `max_tokens` | `min(8192, max(512, 2×输入字符数 + 256))` | 随听写长度伸缩；残句守卫：输入 ≥ 80 字且输出不足原文 60% 判为截断并回退本地 |

### 3.10 上屏后纠错学习与 opt-in 隐私开关

- **纠错学习（默认开启）**：成稿上屏后，`VoicePostCommitEditTracker` 记录插入
  锚点并跟踪用户对该段文本的修改；`VoicePostCommitCorrectionLearner` 把“成稿
  片段 → 用户改后的片段”学习为纠错对（`voiceLearnedCorrections`），后续成稿先经
  纠正再上屏，并以 toast 告知。仅在 AI 开启、非 Secure Input、上下文策略非严格
  且 `voiceAutoLearnCorrectionsEnabled` 为真时生效。
- **云端热词（`voiceCloudHotwordsEnabled`，默认关闭）**：热词上下文可能包含个人
  常用语与专有名词；只有用户显式开启，云端润色/翻译请求才携带热词，否则发送
  空列表（`VoiceCloudHotwordPolicy`）。本地 ASR 的热词校正不受影响。
- **AX 回读（`voiceAXFallbackReadEnabled`，默认关闭）**：纠错学习默认只用 IMK
  提供的光标周边文本；IMK 无法提供时，只有在用户显式开启、进程已获辅助功能
  授权且非 Secure Input 三者同时满足，才经辅助功能接口回读文档锚点
  （`axFallbackReadIsAllowed`）。

两项开关缺省均为 `false`，导入不含这两个键的旧设置时同样按关闭解码；它们与
语音总开关、自动粘贴等默认开启项彼此独立。

## 4. ASR 引擎与评测路径

### 4.1 V0 质量评测

V0 使用独立 `rimeai-voice-eval-driver --plan <owner-only-plan>` 读取计划，计划再
引用受控候选 artifact。它复用产品 verifier、backend、流式 engine 与 ServerCore，
但不嵌入输入法/helper 包，也不读写产品 Store/catalog。

Debug helper **不**支持 `evaluation-product-managed --artifact-dir`。当前 Debug
语法只允许：

```text
--socket <path>
--socket <path> --engine unavailable|apple-speech|mlx-qwen3-asr|product-managed
```

Release 只允许：

```text
--mach-service fun.wwcn.rimeai.voice-helper
```

### 4.2 V1 交互探针

快捷键、流式浮层、确认/取消、设置、UDS/XPC 代码和 helper 生命周期已经存在于
当前工作树并纳入内部 clean baseline（XCFramework headers 缺口已于
2026-08-24 修复，见 [`TASKS.md`](../TASKS.md) BUILD-001/VERIFY-001）。它
仍是默认关闭的内部探针，不会因代码完成自动获得产品资格。

### 4.3 产品管理引擎

manifest schema v2 只证明内容完整性。模型来源、权利、再分发和质量审批必须来自
code-shipped production catalog；当前 catalog 为空。Apple Speech 在 macOS 14/15
只作系统管理 probe，不满足产品管理资产要求。

artifact、runtime 和评测合同分别见：

- [VOICE_ASR_ARTIFACT.md](VOICE_ASR_ARTIFACT.md)
- [VOICE_ASR_RUNTIME_INTAKE.md](VOICE_ASR_RUNTIME_INTAKE.md)
- [VOICE_EVAL_FORMAT.md](VOICE_EVAL_FORMAT.md)

## 5. 放行门

公开语音必须全部完成：

1. 获批产品模型、来源/权利/再分发和非空 production catalog。
2. 至少 200 句授权、说话人隔离的真实录音及冻结转录。
3. WER/CER、术语、标点、延迟、资源、churn 和热词误伤质量门。
4. 与真实 corpus/run 及产品三进程绑定的 authenticated schema-3 evidence。
5. 安装后的命名 XPC 双向身份、真实 TCC、麦克风/蓝牙/USB 和代表宿主矩阵。
6. 运行态 no-INET、无音频落盘和无正文日志审计。
7. Developer ID、公证、Gatekeeper、清洁机安装/升级/回滚。

schema-2 causal tracer、合成 WAV、静态签名或一次 backend load 都不能替代上述
任一项。

## 6. 相关稳定合同

- IPC 身份与传输：[VOICE_IPC_SECURITY.md](VOICE_IPC_SECURITY.md)
- 制品与 selector：[VOICE_ASR_ARTIFACT.md](VOICE_ASR_ARTIFACT.md)
- runtime/model intake：[VOICE_ASR_RUNTIME_INTAKE.md](VOICE_ASR_RUNTIME_INTAKE.md)
- corpus、observation、gate 和 performance schema：
  [VOICE_EVAL_FORMAT.md](VOICE_EVAL_FORMAT.md)

这些文档只维护专项合同，不维护全局任务或易过期测试计数。

## 7. 非目标与已知限制

- 云端音频上传/云 ASR、无边界开放式改写、持续听写与会议转写未进入当前范围（文本级
  智能润色与一键语音翻译仅在本地转写完成后按用户显式配置执行，音频绝不离开本机）。
- 不宣称枚举或复制完整 Rime 用户词典。
- `SECURITY-001`（2026-10-26）已通过冻结 `sherpa-onnx` v1.13.6 buffer-loader fork
  消除自管模型的同 UID pathname open TOCTOU 窗口；snapshot pathname 仅保留作回归对照。
- 当前 production catalog 为空；不得对外声明产品本地 ASR 已具备公开发布资格。
- 真实 TCC、设备、宿主、隐私和发布矩阵尚未完成。

## 8. 稳定组件边界

- V2 协议统一客户端、helper 与评测 driver 的消息语义。
- Debug UDS 只提供同 UID 开发边界；Release 只允许认证 XPC。
- product-managed runtime 只能从 Store、selector 和 production catalog 装配。
- evaluation sealer、eval driver 与 schema-2 tracer 只生成诊断/评测材料，不能
  转换成 release evidence。
- 公开语音产品仍须满足第 5 节全部放行门。

实现和任务状态只在 [../TASKS.md](../TASKS.md) 维护。
