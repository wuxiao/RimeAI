# 语音听写交互与 V2 协议

更新日期：2026-10-13
状态：`INTERNAL PROBE / NOT RELEASED`

本文是语音用户行为和 wire contract 的权威定义。总体产品与技术边界见
[../PRD.md](../PRD.md)、[../PRODUCT_DESIGN.md](../PRODUCT_DESIGN.md) 和
[../TECHNICAL_DESIGN.md](../TECHNICAL_DESIGN.md)；开发状态见
[../TASKS.md](../TASKS.md)。

## 1. 产品边界与隐私合同

- 语音默认关闭，且依赖 AI 总开关。
- 当前只支持按住说话，不持续监听、不提供唤醒词或会议转写。
- 松开结束采集并等待 final；final 必须由用户再次确认才进入宿主应用。
- 语音文本不写入键盘长期历史；音频不属于诊断或设置导出。
- 产品目标是本地音频只存在于当前会话内存中、不落盘、不联网；真实运行态
  no-INET/不落盘审计尚未完成，因此这仍是发布门而不是已放行声明。
- Secure Event Input、宿主/焦点/光标变化、设置关闭和旧代际消息必须取消会话。
- 语音失败只影响语音入口，Rime 键盘主链继续可用。
- 默认按住说话快捷键为 `⌃⇧V`。用户可在设置中录制并恢复快捷键；只接受
  `Control+Shift` 或 `Option+Shift` 加普通字母、数字或标点键的精确组合。
- 快捷键按物理键码保存并请求独占的系统级注册；注册冲突或系统拒绝必须在设置
  中显示，不能静默换用其他组合或继续显示为可用。

## 2. 进程架构

```text
InputMethodKit host
  └─ VoiceDictationRuntime / Coordinator / overlay
       ├─ Debug: owner-only UDS
       └─ Release: authenticated NSXPC Mach service
                          └─ RimeAIVoiceHelper
                               ├─ Apple Speech probe
                               └─ product-managed ASR (production not approved)
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
- 1–5000ms deadline 与不超过 60 秒的最大时长；
- 可选、规范化、有摘要且受服务端上限裁剪的热词快照。

当前产品只启用 `direct`。热词辅助另行默认关闭，只来自当前焦点会话中用户
已确认的有界 Rime commit，不读取完整用户词典、云历史或完整文档。

### 3.3 松开与 finalizing

松开快捷键发送 `dictation_stop`。服务端停止接收新音频、结束当前 stream 并
生成一次 final；客户端进入 `finalizing`，此时旧 delta 不得覆盖最终状态。

### 3.4 流式增量

`dictation_delta` 包含严格递增 sequence、stable text、partial text、confidence
和单调 elapsed time。文本必须单行，总长度不超过 200 个 Swift Character。

- 重复、乱序或旧 request delta 直接丢弃。
- delta 只更新 RimeAI 浮层，不写入宿主应用。
- stable/partial 不能跨会话继承。

### 3.5 最终结果

`dictation_final` 包含 final text、confidence、engine ID、polish 标记和 elapsed
time。合法 final 进入 `pending_confirm`，不会自动上屏。

- Space/回车：请求宿主插入文本。
- Esc：取消。
- final 最长 200 Character，必须在组合字素边界安全截断。

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
```

所有 IO effect 都绑定 connection/session/effect generation。reset、disconnect、
设置变化或新宿主会先推进 generation，使已排队但未执行的旧 effect 失效。连续
协议失败达到门限后熔断；一次合法 final 会重置连续失败计数。

## 4. ASR 引擎与评测路径

### 4.1 V0 质量评测

V0 使用独立 `rimeai-voice-eval-driver --plan <owner-only-plan>` 读取计划，计划再
引用受控候选 artifact。它复用产品 verifier、backend、流式 engine 与 ServerCore，
但不嵌入输入法/helper 包，也不读写产品 Store/catalog。

Debug helper **不**支持 `evaluation-product-managed --artifact-dir`。当前 Debug
语法只允许：

```text
--socket <path>
--socket <path> --engine unavailable|apple-speech|product-managed
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

- 云 ASR、自由润色、翻译、续写、持续听写和会议转写未进入当前范围。
- 不宣称枚举或复制完整 Rime 用户词典。
- 当前 sherpa pathname snapshot 不抵御任意 hostile same-UID rename/cleanup。
- 当前 production catalog 为空；不得对外声明产品本地 ASR 已可用。
- 真实 TCC、设备、宿主、隐私和发布矩阵尚未完成。

## 8. 稳定组件边界

- V2 协议统一客户端、helper 与评测 driver 的消息语义。
- Debug UDS 只提供同 UID 开发边界；Release 只允许认证 XPC。
- product-managed runtime 只能从 Store、selector 和 production catalog 装配。
- evaluation sealer、eval driver 与 schema-2 tracer 只生成诊断/评测材料，不能
  转换成 release evidence。
- 公开语音产品仍须满足第 5 节全部放行门。

实现和任务状态只在 [../TASKS.md](../TASKS.md) 维护。
