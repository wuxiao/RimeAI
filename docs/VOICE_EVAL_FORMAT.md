# 语音评测数据与质量门报告格式

状态：实现合同。本文定义离线语音质量评测的输入、归一化、聚合指标和
quality gate。该 gate 只证明指定语料、模型、平台、延迟与资源证据满足冻结策略，
不替代模型权利、TCC、运行态隐私、公证或干净机器等产品发布门。协议字段一律
使用 JSON integer `schema_version`，布尔值或浮点数即使数值相等也无效；产品阶段
代号不得作为 schema 名称或兼容性判断。

当前 performance sidecar schema v3 的能力等级永久是 unauthenticated
measurement-only：它只提供严格测量，不具备获批 identity policy
与已认证的 production event producer。聚合报告因此固定公开
`authenticated_production_driver: false`；一旦提供 gates，只能得到
`policy_incomplete`、`quality_gate_pass: false` 和退出码 1。该限制不能由 sidecar、
gates 或用户字段改写；未来须由新 schema 和完整 authenticated control plane 明确
取代，不能静默升级 v3。

## 1. 命令与退出码

```bash
set -o pipefail

python -m rimeai_eval validate-voice CORPUS_ROOT \
  --profile fixture

python -m rimeai_eval validate-voice CORPUS_ROOT \
  --profile frozen-quality

python -m rimeai_eval collect-voice-observations \
  CORPUS_ROOT RUN.json \
  --native-driver /absolute/path/rimeai-voice-eval-driver \
  --artifact-dir /absolute/path/candidate-artifact \
  --output OBSERVATIONS.jsonl \
  [--hotwords-file HOTWORDS.json]

CONTROLLED_REALTIME_DRIVER | python -m rimeai_eval \
  collect-voice-performance \
  CORPUS_ROOT RUN.json COLLECTION-PLAN.json \
  --native-collector /absolute/path/rimeai-voice-performance-collector \
  --output PERFORMANCE.json

python -m rimeai_eval evaluate-voice \
  CORPUS_ROOT RUN.json OBSERVATIONS.jsonl

python -m rimeai_eval evaluate-voice \
  CORPUS_ROOT RUN.json OBSERVATIONS.jsonl \
  --baseline-run BASELINE-RUN.json \
  --baseline-observations BASELINE-OBSERVATIONS.jsonl \
  --performance-evidence PERFORMANCE.json \
  --gates-config GATES.json
```

`validate-voice` 的 CLI profile `frozen-quality` 对应 manifest 中的
`purpose: frozen_quality`。退出码合同如下：

| 情形 | 退出码 | 标准输出 |
|---|---:|---|
| corpus、run、observations、performance sidecar 或 gates 的 JSON/schema 无效 | 2 | 无；错误写 stderr，不含原文 |
| V0 observation 回放成功 | 0 | 不含逐样本文本的摘要；验证后的 JSONL 原子写入 `--output` |
| observation plan、driver/制品身份、WAV、原生输出或原子安装无效 | 2 | 无；统一脱敏错误，不得留下可用 observations |
| 受控性能采集成功 | 0 | 不含逐样本数据的成功摘要；证据原子写入 `--output` |
| collection plan、实时事件、签名身份、采样或原子输出无效 | 2 | 无；不得留下可用证据 |
| 仅测量，未传 `--gates-config` | 0 | schema v2 聚合报告，不含 `quality_gate_pass` |
| schema v3 sidecar 配合 gates，即使所有数值与分母通过 | 1 | `policy_incomplete`；报告固定 `authenticated_production_driver: false`、`quality_gate_pass: false` |
| gates 策略不完整、证据不完整、不具资格或任一阈值失败 | 1 | 聚合报告，`quality_gate_pass: false` |

baseline 的 run 和 observations 必须成对提供。缺少其中一个属于 CLI 无效输入，
在读取 corpus 前以退出码 2 失败。

`CONTROLLED_REALTIME_DRIVER` 只是命令形状中的占位符，不是 `cat`、重放文件或人工
输入。采集 CLI 和 native collector 都拒绝 regular-file stdin，但 pipe/socket/TTY
本身不证明事件生产者或业务因果；只有固定版本、受控且与真实语音/键盘流程相连的
driver 才能产生正式证据。当前仓库尚未把该产品 driver 接入输入法运行流程。

## 2. 四层证据模型

四层文件各自有单一职责，不能把声明当作测量，也不能从聚合报告反推出原文。

1. **Corpus**：冻结的音频、参考文本、子集标签、授权声明与内容哈希。
2. **Run**：一次采集所用实现、系统、设备、策略、时钟及不支持子集。
3. **Observations**：逐样本的识别结果与单调时间点；评测器只输出聚合值。
4. **Performance sidecar**：与同一 run、模型制品及全部 corpus session 绑定的
   三进程资源、加载耗时和键盘共存证据；不含音频或文本。

collection plan 与实时 boundary event 是生成第 4 层证据的控制输入，不是新的
测量层。它们只命名待复验的进程/制品和无文本事件边界，不能携带延迟、CPU、内存、
能耗或音频时长；这些数值只能由 native collector 的连续时钟与系统计数器产生。

`gates.json` 是质量策略，不是第五层测量数据。它必须引用与 run 相同的
`evaluation_profile_id`。提供 gates 但未提供 performance sidecar 时只能得到
`policy_incomplete`，不得形成质量门通过结论。提供有效 schema v3 sidecar 时仍因
production driver 未认证而得到 `policy_incomplete`；sidecar 的 schema 或身份绑定
无效才属于输入错误，以退出码 2 拒绝且不生成报告。

## 3. Corpus schema

`CORPUS_ROOT` 固定包含 `manifest.json`、`samples.jsonl`，以及相对路径引用的 WAV；
manifest 的 `samples_file` 也必须精确为 `samples.jsonl`。loader 对 manifest 和每条
sample 使用 exact-key 校验；未知字段、重复 JSON key、NaN/Infinity、绝对路径、
`..`、符号链接、哈希/帧数/时长不一致均失败。

manifest 的键集合为：

```json
{
  "schema_version": 1,
  "corpus_id": "zh-cn-voice-quality-2026-08",
  "purpose": "frozen_quality",
  "normalization_profile": "rimeai-voice-v1",
  "samples_file": "samples.jsonl",
  "synthetic_fixture": false,
  "rights": {
    "basis": "participant_consent",
    "record_ref": "external-rights-register-voice-2026-08"
  },
  "quality_declarations": {
    "authorized_real_recordings": true,
    "speaker_disjoint_by_identity": true
  }
}
```

字段约束：

- `purpose` 只能为 `fixture`、`development`、`frozen_quality`。
- `normalization_profile` 当前只能为 `rimeai-voice-v1`。
- `fixture` 必须是可公开提交的合成小样；`frozen_quality` 必须是真实、已授权、
  说话人隔离的冻结集，不能用合成音替代。
- `frozen_quality` 至少包含 200 条样本，必须覆盖 `general|software` 全部 domain、
  `zh|en|mixed|blank` 全部 language composition、`quiet|common_noise`，以及
  `near_field|far_field`；这是 loader 的最低完整性门，不代表样本量已足够证明质量。
- `rights` 可为 `null`，但真实录音用于质量门时必须有非敏感 `basis` 和
  `record_ref`。`basis` 只能为 `participant_consent|licensed_corpus`。这里只引用
  外部授权登记，绝不存放姓名或联系信息。`record_ref` 使用 controlled-ID
  `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`，不允许自由文本。
- manifest、samples 和每个音频都进入 corpus fingerprint；run 必须精确引用该
  fingerprint，禁止以相同 `corpus_id` 冒充不同内容。

每行 sample 的语义字段为：

```json
{
  "schema_version": 1,
  "id": "voice-000001",
  "split": "test",
  "speaker_group_id": "speaker-group-001",
  "domain": "general",
  "language_composition": "zh",
  "conditions": {
    "noise": "quiet",
    "distance": "near_field"
  },
  "audio": {
    "path": "audio/voice-000001.wav",
    "sha256": "<64 lowercase hex>",
    "container": "wav",
    "encoding": "pcm_s16le",
    "duration_ms": 1840,
    "sample_rate_hz": 16000,
    "channels": 1
  },
  "reference": "参考文本只存在于受控 corpus 与逐条内存计算中",
  "terms": [
    {"text": "RimeAI", "match_mode": "ascii_casefold_word"}
  ],
  "is_blank": false
}
```

稳定枚举与关系：

- `domain`：`general|software`。
- `language_composition`：`zh|en|mixed|blank`。
- `split`：`train|validation|test`。
- `conditions.noise`：
  `quiet|common_noise|keyboard_noise|fan_noise|other`；
  `conditions.distance`：`near_field|far_field`。
- `terms[].match_mode`：`exact|ascii_casefold_word`。
- `is_blank: true` 时参考文本必须为空，且 `language_composition` 必须为
  `blank`；非空样本不得伪装成 blank。
- WAV 必须是 `container: wav`、`encoding: pcm_s16le`；PCM16 WAV header、采样率、
  声道、帧数推导的 duration 与 SHA-256 必须互相一致。合法 WAV metadata 或
  trailing chunk 不因其自身被拒绝，但同样进入文件 SHA-256。修改音频或声明都会
  改变 fingerprint。采样率只允许 `16000|44100|48000` Hz，声道只允许 `1|2`。
- `speaker_group_id` 仅是不可逆分组标识，用于防止同一说话人跨训练/测试泄漏；
  不是个人身份。

## 4. Run schema

run 是一次不可变采集声明。顶层 exact keys 为：

```json
{
  "schema_version": 2,
  "evaluation_profile_id": "voice-release-zh-cn-2026-08",
  "corpus_fingerprint": "<64 lowercase hex>",
  "implementation_fingerprint": "<64 lowercase hex>",
  "collection_method": "automated",
  "engine": {
    "adapter_id": "sherpa-onnx",
    "engine_id": "sherpa-onnx@0123456789abcdef",
    "asset_management": "product",
    "recognizer_locale": "zh-CN",
    "requires_on_device": true,
    "supports_on_device_at_run": true,
    "artifact_id": "rimeai-voice-zh-en-v1",
    "artifact_content_sha256": "<64 lowercase hex>",
    "model_id": "streaming-zipformer-zh-en",
    "model_revision": "2026.08.1"
  },
  "platform": {
    "os_version": "14.7.6",
    "os_build": "23H626",
    "hardware_class": "Mac15,7",
    "arch": "arm64"
  },
  "audio_io": {
    "device_class": "built_in",
    "sample_format": "pcm_s16le",
    "sample_rate_hz": 16000,
    "channels": 1
  },
  "policy": {
    "endpoint_strategy": "on_device_required",
    "hotwords_enabled": false,
    "postprocessor_id": "none"
  },
  "unsupported_subsets": [],
  "clock": {
    "domain": "helper_server_monotonic",
    "unit": "ms"
  }
}
```

关键约束：

- `evaluation_profile_id` 必填，用来标识冻结评测计划，独立于 corpus 的
  `normalization_profile`；gates 必须与 run 完全相同。
- `corpus_fingerprint` 必须等于 loader 根据当前 corpus 重算的值。
- `implementation_fingerprint` 标识被测实现，而不是可编辑的展示版本。
- `collection_method` 只能为 `automated|manual_assistive`。
- run 中除硬件型号外的受控标识（包括 profile、adapter/engine/locale、platform
  描述、endpoint、postprocessor、unsupported value/reason）统一匹配
  `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`；不得用自由文本承载设备名、用户名或备注。
  `platform.hardware_class` 必须原样记录 macOS `sysctl hw.model`，使用字段专用语法
  `[A-Za-z0-9][A-Za-z0-9._,-]{0,127}`，以容纳真实值中的逗号；不得把逗号改写为点
  或做其他归一化，以免两个硬件身份碰撞。
- run schema 当前严格为 `2`；schema v1 不做静默升级。
- engine 公共 exact keys 为 `adapter_id`、`engine_id`、`asset_management`、
  `recognizer_locale`、`requires_on_device`、`supports_on_device_at_run`。
  `asset_management` 只能为 `system|product`。
- `product` 还必须同时提供 `artifact_id`、`artifact_content_sha256`、`model_id`、
  `model_revision`；缺任一字段都无效。这组身份进入报告 provenance、A/B
  可比性、run SHA-256 与 performance sidecar 逐字段绑定。
- `system` 禁止上述四个产品制品字段。旧 `artifact_sha256` 对两类引擎都是未知
  字段，不能作为新内容摘要的兼容别名。
- `audio_io.device_class`：
  `built_in|usb|headset|bluetooth|virtual_fixture`；sample format 当前只能为
  `pcm_s16le`，当前受支持的 `platform.arch` 只能为 `arm64`。
- `platform.os_version` 必须是 `major.minor[.patch]` 数字版本且不低于 macOS 14；
  未知字符串不能被当成新系统而绕过引擎资格门。
- policy exact keys 为 `endpoint_strategy`、`hotwords_enabled`、
  `postprocessor_id`，以及仅在启用热词时出现的 `hotword_set_sha256`。
- 每个 `unsupported_subsets` 元素 exact keys 为
  `dimension,value,reason_code`；dimension 只能为
  `language_composition|domain|noise|distance`。`endpoint_strategy` 和
  `reason_code` 是有长度与字符集限制的版本化 ID，不是开放自然语言，也不是
  永久封闭 enum；aggregate 只回显摘要 ID。
- 时钟只能是 `{domain:"helper_server_monotonic",unit:"ms"}`。壁钟、客户端钟、
  跨进程相减或把日志时间戳混入延迟统计都无效。
- `unsupported_subsets` 是显式缺失证据；gates 要求的子集出现在其中时必须
  fail-closed，不能把缺样本折算为零错误。

Apple Speech 属于 `asset_management: system`。低于 macOS 26 的系统管理模型
由 Apple 管理，无法由本仓库冻结或以 artifact hash 重现，因此在产品测试计划中
只能归类为 probe-only 平台覆盖。`probe-only` 不是本 report schema 的 decision：
未提供 gates 时仍输出 `measurement_only`，提供 gates 时输出
`policy_ineligible`。这些结果可以报告单机测量和回归信号，但不能单独充当
`frozen_quality` 的可复现质量放行证据，也不能把两个系统版本混成一个 aggregate。

### 4.1 V0 产品候选 WAV 回放

`collect-voice-observations` 是 V0 候选质量采集入口。Python 先用第 3、4 节的
authoritative loader 复验 corpus/run，再生成 owner-only 临时 plan，调用独立
`rimeai-voice-eval-driver`。该 native driver 通过同一 schema v2 artifact verifier、
真实 sherpa loader、`ProductStreamingVoiceEngine` 与
`VoiceDictationServerCore` 回放冻结 WAV；它不是 scripted recognizer，也不经过
麦克风或 helper IPC。

该入口只接受 product run，并额外冻结：`collection_method: automated`、
`audio_io.device_class: virtual_fixture`、`endpoint_strategy: push-to-talk`、
`postprocessor_id: none`、on-device required/available，以及
`helper_server_monotonic` 时钟。native plan 的顶层 exact keys 为：

```text
schema_version, collection_method, corpus_fingerprint,
native_driver_sha256, artifact_directory, artifact, recognizer_locale,
policy, hotword_snapshot, samples, output_path
```

- plan 的 `collection_method` 固定为 `evaluation_replay`；这与 run 中描述采集方式的
  `automated` 不是同一个字段语义。
- `artifact` exact keys 为
  `artifact_id,artifact_content_sha256,adapter_id,engine_id,model_id,model_revision`；
  `engine_id` 必须等于 descriptor 的派生值，且真实 loaded descriptor、
  `voice_ready` 与每个 final 都必须绑定同一值。
- 每个 `samples` 元素 exact keys 为
  `sample_id,audio_path,audio_sha256,duration_ms,sample_rate_hz,channels,frame_count`；
  sample 顺序就是输出顺序。WAV 以 `O_NOFOLLOW` 打开并复验 vnode、完整 SHA、
  PCM16 header、帧数、采样率、声道与 duration；只允许 16/44.1/48 kHz、1/2 声道。
- `hotword_snapshot` 总是存在，exact keys 为
  `normalization_version,phrases,hotword_set_sha256`。是否为空必须与 run policy 的
  `hotwords_enabled` 一致；启用时 run、snapshot 与 Swift-compatible canonical
  digest 必须精确相等，且数量不得超过 `voice_ready.maximum_hotwords`。
- driver 可执行文件必须是规范、非符号链接普通文件，其 SHA-256 必须等于 run 的
  `implementation_fingerprint`。Python 从同一个已打开并复验的 inode 流式复制到
  0700 staging 中的 0500 私有副本，native 再自验同一摘要；原始路径随后被替换也
  不会改变实际执行字节。制品目录也会在 native 进程中重新严格验证。
- descriptor、`voice_ready` 或 final 只要出现 `polish` / `polish_applied:true` 就拒绝，
  不能在 `postprocessor_id:none` 名义下混入后处理文本。
- WAV 先转换为 16 kHz mono Float32，按实际音频时长以 session 起点的绝对 deadline
  投递 20 ms frame；callback 变慢不会逐帧累计漂移，已经迟到时以零延迟追赶且不
  丢帧。不足 20 ms 的尾帧只在 EOF 触发的正常 stop 中补零并提交，cancel 丢弃。
  session 的 partial、stop 与 final 使用 ServerCore 首次 start-now 记录的同一单调锚点。
- native 只允许输出 `final|no_result|error`，每个 corpus sample 恰好一次且顺序
  完全一致；单行上限 1 MiB，总文件上限 16 MiB。native 及其派生进程位于独立
  process group；父进程退出、超时、异常或成功收尾后必须完成一次 group cleanup
  才能继续，除 `ESRCH` 外的终止错误都会令本次采集 fail-closed。Python 随后以
  `O_NOFOLLOW|O_NONBLOCK` 从稳定 inode 有界捕获到自己的 0600 candidate，并让
  authoritative loader 与后续摘要复用同一个已打开 fd；迟到子进程或路径换包都
  不能改变被验证和安装的字节。
- 最终文件在 0700 staging 中以 0600/O_EXCL 产生并通过第 5 节 loader。输出父目录
  在 commit 前先同步，同目录 `replace` 是唯一 commit point；commit 后目录同步若
  报错，只有重新打开 final 并确认 owner/mode/inode/大小/完整 SHA 仍等于已验证
  candidate 才按成功返回，否则以脱敏的 installation-indeterminate 失败。普通失败
  不会同时报告失败又留下一个被当作成功证据的文件。

这是可复现的候选质量/流式行为证据，不是正式性能或发布证据。构造 replay source
前会完整读取、哈希、解析并预转换 WAV；artifact 也在 session 前验证和加载。因此
这些 observations 不测 cold load、WAV IO 或转换耗时，也不证明 TCC、真实麦克风、
三进程资源/键盘共存、运行态 no-INET、音频不落盘、公证或清洁机器。native driver
虽可用 Release 优化构建，但不嵌入输入法/helper 发布包，不读取产品 Store、selector
或 production catalog，也不能生成 release approval。

## 5. Observation schema

observations 是 UTF-8 JSONL，每个 corpus sample 恰好一条。顶层允许字段：

```json
{
  "schema_version": 1,
  "sample_id": "voice-000001",
  "outcome": "final",
  "partials": [
    {"sequence": 1, "text": "参考", "elapsed_ms": 410.0}
  ],
  "stop_received_elapsed_ms": 1800.0,
  "final": {
    "text": "参考文本",
    "confidence": 0.92,
    "elapsed_ms": 2070.0
  },
  "resources": {
    "processing_duration_ms": 1960.0,
    "samples": [
      {
        "elapsed_ms": 1000.0,
        "resident_memory_mb": 82.5,
        "cpu_percent": 18.0,
        "energy_impact": 3.2
      }
    ]
  }
}
```

取消路径示例：

```json
{
  "schema_version": 1,
  "sample_id": "voice-000002",
  "outcome": "cancelled",
  "partials": [],
  "cancel_received_elapsed_ms": 620.0,
  "capture_stopped_elapsed_ms": 641.0
}
```

约束：

- `outcome`：`final|no_result|cancelled|error`。
- partial exact keys 为 `sequence,text,elapsed_ms`；sequence 与时间都必须严格递增，
  时间非负。
- final exact required keys 为 `text,elapsed_ms`，`confidence` 可选且只能为
  `[0,1]` 的有限数。
- final 路径要求 `stop_received_elapsed_ms <= final.elapsed_ms`。
- final 路径不得混入 `cancel_received_elapsed_ms` 或仅供取消路径使用的
  `capture_stopped_elapsed_ms`。
- cancelled 路径要求
  `cancel_received_elapsed_ms <= capture_stopped_elapsed_ms`，且不得携带 final。
- cancelled 若同时记录 stop，必须满足
  `stop_received_elapsed_ms <= cancel_received_elapsed_ms`；`no_result` 必须记录
  `stop_received_elapsed_ms`。
- `no_result|error` 都不得携带 final、cancel 或 capture-stop；`error` 可以不含 stop，
  若含 stop 则它作为该记录的 terminal。
- 若 outcome 存在 terminal 事件，最后一条 partial 不得晚于它；合法且未记录 stop
  的 `error` 没有 terminal 可供比较。
- 所有 elapsed 都从同一个 helper/server 单调 session 起点计算；不得把
  `Date`、文件 mtime 或客户端事件时间混入。
- `resources` 可选，但出现时不得是空对象，只允许 `processing_duration_ms` 与
  `samples`；`samples` 出现时必须是非空数组且 elapsed 严格递增。每个 resource
  sample exact keys 为 `elapsed_ms,resident_memory_mb,cpu_percent`，以及可选的
  `energy_impact`。未知键、非有限数或负时间均拒绝；不得放音频、路径、原文、
  日志或设备序列号。这组 observation 内资源只保留为逐识别适配器的测量信号，
  不能替代第 8 节覆盖完整进程 cohort、全部 session 和键盘阶段的 performance
  sidecar，也不能单独通过资源 gate。

## 6. `rimeai-voice-v1` 归一化

归一化只用于评分副本，原始 reference/hypothesis 不写入 aggregate：

1. Unicode NFKC；全角 Latin/数字按 NFKC 合并。
2. Latin 使用 Unicode casefold；汉字保持原字形。
3. 评分 CER/WER 时剥离标点，标点另行按原顺序计算；不能靠删除标点改善
   punctuation 指标。
4. `三` 与 `3` 不等价，不执行中文数字与阿拉伯数字的语义替换。
5. 汉字与数字按字符计入 micro CER；Latin/digit 片段使用冻结 word tokenizer
   计入 micro WER。
6. `exact` term 在归一化文本中做精确匹配；`ascii_casefold_word` 仅在 ASCII
   `[A-Za-z0-9_]` 边界做 casefold 整词匹配。例如 `go` 不得命中
   `algorithm`。
7. blank 对 trim 后的任何输出都计 false positive；孤立标点同样是输出，不能因
   主 CER 剥标点而漏报。

## 7. 聚合指标

所有错误率采用 micro aggregate：先累加编辑距离和分母，再相除；不对短句和长句
做无权平均。报告不得包含逐样本文本。

- `metrics.mandarin_cer.rate`：Han/数字字符 Levenshtein edits / reference
  characters。
- `metrics.english_wer.rate`：冻结 Latin/digit word tokenizer 的 edits / reference
  words。
- `metrics.punctuation_edit_rate.rate`：按原顺序提取的标点序列 edit distance /
  reference punctuation count。
- `metrics.punctuation_exact_sequence.rate`：逐样本标点序列完全一致的比例；与 edit
  rate 同时报告，避免平均编辑率掩盖整句标点不稳定。
- `metrics.term_exact_match.rate`：要求 term 中被正确保留的比例。
- `metrics.blank_false_positive.rate`：blank 样本中产生任何 trim 后输出的比例。
- `metrics.partial_churn.rate`：相邻 partial 的 NFKC/casefold 文本编辑量 /
  revisions；同时以 `metrics.partial_churn.revisions_per_sample` 报告
  revisions/sample，final 不是额外伪造 partial。
- `metrics.collateral_substitution.rate`：冻结的自动代理指标。对每个样本，若某个在
  corpus 其他位置有术语标注的词既不在本样本术语标注中、也不在本样本 reference 中，
  却出现在 hypothesis 中，则计一次 substitution；分母是这类 corpus 术语机会数。
  它只检测“额外注入已标注技术词”，不推断被替换的原内容，也不会发现由 corpus
  从未标注的普通词造成的替换，因此不能表述为通用文本破坏率。
- `metrics.latency_ms.first_partial`：session 起点到首个 partial 的分布；没有 partial
  的 final 样本不能被当成 0ms。
- `metrics.latency_ms.stop_to_final`：
  `final.elapsed_ms - stop_received_elapsed_ms` 的分布。
- `metrics.latency_ms.cancel_to_capture_stop`：
  `capture_stopped_elapsed_ms - cancel_received_elapsed_ms`。
- observation 层的 `metrics.resources.real_time_factor`：仅在 observation 提供
  `resources.processing_duration_ms` 时，用该值除以 corpus 中的实际音频
  duration；缺失时为 `unmeasured`，不得用 final 的 session elapsed 代替。
  正式 gate 使用 performance sidecar 聚合出的
  `metrics.performance.real_time_factor` 三进程 cohort 范围指标。

此外 `metrics.samples` 固定为样本总数，`metrics.outcomes` 固定聚合
`final|no_result|cancelled|error` 计数。observation 的可选资源信号完整路径为
`metrics.resources.{processing_duration_ms,resident_memory_mb,cpu_percent,
energy_impact,real_time_factor}`。合法 performance sidecar 会增加
`metrics.performance`，其 exact 聚合键为：

- `session_coverage_rate`、`environment`；
- 固定 evaluator-owned 事实 `authenticated_production_driver: false`；
- `collection_protocol`；
- `real_time_factor`、`cohort_peak_resident_mib`、
  `cohort_peak_phys_footprint_mib`、
  `voice_incremental_peak_phys_footprint_mib`、
  `cpu_core_seconds_per_audio_second`、`energy_joules_per_audio_minute`、
  `cold_artifact_load_ms` 与 `product_artifact_payload_bytes`；
- `keyboard.baseline_rime_latency_ms`、`keyboard.helper_loaded_rime_latency_ms`、
  `keyboard.listening_cancel_to_rime_latency_ms`、
  `keyboard.paired_sequence_count`、
  `keyboard.helper_loaded_added_p95_ms`、
  `keyboard.listening_cancel_added_p95_ms` 与
  `keyboard.late_voice_commit_count`、`keyboard.late_challenge_counts`。

其中 performance distribution 返回 `samples,p50,p95,max,measurement`；主 latency
与 observation `processing_duration_ms` 不含 `max`，其余 observation resource
distribution 含 `max`。键盘 added 项为标量 P95，制品体积为
`{value,measurement}`；这些 report path 与第 9 节的 threshold key 是不同合同。

P50/P95 使用 nearest-rank：对升序的 N 个值取
`ceil(percentile * N)`（从 1 开始）的元素；空集合报告证据缺失，不报告 0。
baseline/candidate 只可在 evaluation profile、corpus fingerprint、
`collection_method`、完整 engine 身份（包含产品制品六字段）、platform、audio I/O、
unsupported subsets 与 clock 完全一致时计算百分点增减。policy 除
`hotwords_enabled` / `hotword_set_sha256` 外也必须完全一致；
`implementation_fingerprint` 才允许不同。

聚合报告的稳定顶层语义为：

- `schema_version: 2`、`decision`、`provenance`、`metrics`、`subsets`、
  `quality_report_sha256` 始终存在；未提供 gates 时 `decision` 为
  `measurement_only`，报告不得含 `quality_gate_pass` 或旧 `release_pass`。
- 成对提供 baseline 时增加 `comparison`，其 exact keys 为
  `baseline_implementation_fingerprint,candidate_implementation_fingerprint,
  baseline_hotwords_enabled,candidate_hotwords_enabled,
  technical_term_exact_gain_pp,mandarin_cer_regression_pp`；不嵌入 baseline 的逐条
  记录。
- 提供 gates 时增加聚合 `gates` 检查结果与布尔 `quality_gate_pass`；`decision`
  只能为 `policy_incomplete|policy_ineligible|fail|pass`。CLI 只在
  `quality_gate_pass` 严格等于 `true` 时返回 0。schema v3 路径永远先命中
  `policy_incomplete`，`pass` 保留给尚未定义的新 authenticated evidence schema；
  这个布尔值即使未来为 true 也不代表产品发布批准。
- `quality_report_sha256` 使用 domain
  `rimeai.voice-quality-report.v2\0` 加上 UTF-8 canonical JSON 计算 SHA-256；
  canonical JSON 按 key 排序、无额外空白、保留非 ASCII 字符而不改写为 `\u`
  escape、禁止 NaN/Infinity，并在哈希输入中排除 `quality_report_sha256` 自身。
  metrics、gates、implementation、模型制品
  provenance 或其他报告语义任一变化都会改变摘要。code-shipped release evidence
  只能引用这个摘要，不能用可编辑文件名或展示版本替代。
- `provenance.authenticated_production_driver` 始终存在；当前实现固定为 false。
  提供 performance sidecar 时，`provenance` 还包含原样绑定的
  `collection_protocol`；`provenance.performance_evidence_sha256` 使用
  domain `rimeai.voice-performance.v3\0` 绑定完整、已验证 sidecar 的 UTF-8
  canonical JSON，包括 collector 可执行文件 SHA-256、Team、签名 identifier、
  collection protocol、进程计数器、冷加载、迟到挑战与键盘 trial。该摘要也进入
  `quality_report_sha256`，因此即使聚合数值巧合相同，更换 collector 或任一原始
  证据字段仍会改变质量报告身份。
- `subsets` 的键固定为 `dimension:value`；每个值仍是聚合指标树，不得出现
  sample ID、reference、hypothesis、partial 或音频路径。

## 8. Performance sidecar schema

performance sidecar 是一个 schema v3 JSON 对象。schema v3 输入本身不得携带
`authenticated_production_driver` 或任何等价声明；该
字段是聚合器根据 schema 能力生成的固定 false，而不是 collector、plan、gates 或
用户可提供的证据。它的顶层 exact keys 如下例所示：

下例只展示顶层形状；其中空的 `sessions` / `keyboard_trials` 是排版占位，不能作为
合法证据。实际 sidecar 必须按下述约束完整覆盖 corpus，并至少提供一组三阶段键盘
trial。

```json
{
  "schema_version": 3,
  "evaluation_profile_id": "voice-release-zh-cn-2026-08",
  "corpus_fingerprint": "<64 lowercase hex>",
  "implementation_fingerprint": "<64 lowercase hex>",
  "run_sha256": "<64 lowercase hex>",
  "collection_protocol": {
    "id": "rimeai-release-collection-v1",
    "sha256": "<64 lowercase hex>"
  },
  "artifact": {
    "artifact_id": "rimeai-voice-zh-en-v1",
    "artifact_content_sha256": "<64 lowercase hex>",
    "adapter_id": "sherpa-onnx",
    "engine_id": "sherpa-onnx@0123456789abcdef",
    "model_id": "streaming-zipformer-zh-en",
    "model_revision": "2026.08.1",
    "verified_payload_bytes": 123456789,
    "verified_file_count": 5
  },
  "collector": {
    "collector_id": "rimeai-voice-performance-v1",
    "clock_domain": "mach_continuous_time",
    "sample_interval_ms": 100,
    "memory_source": "proc_pid_rusage_v6",
    "energy_source": "proc_pid_rusage_v6_energy_nj",
    "executable_sha256": "<64 lowercase hex>",
    "team_identifier": "S3T42U45P8",
    "signing_identifier": "fun.wwcn.rimeai.voice-performance-collector"
  },
  "environment": {
    "hardware_model": "Mac15,7",
    "physical_memory_bytes": 8589934592,
    "logical_cpu_count": 8,
    "power_source": "ac",
    "low_power_mode": false,
    "thermal_state_start": "nominal",
    "thermal_state_end": "nominal"
  },
  "required_process_roles": [
    "input_method", "candidate_service", "voice_helper"
  ],
  "cold_artifact_load_ms": [4200.0, 4050.0, 3980.0],
  "sessions": [],
  "keyboard_trials": [],
  "late_voice_commit_count": 0,
  "late_challenge_counts": {
    "cancel": 1,
    "application_switch": 1,
    "secure_input": 1,
    "target_invalidation": 1,
    "keyboard_input": 1
  }
}
```

约束如下：

- `evaluation_profile_id`、corpus/implementation fingerprint 与 canonical
  `run_sha256` 必须精确匹配当前 run。run SHA-256 对完整 schema v2 run 做排序键、
  无空白、保留非 ASCII 字符且禁止非有限数的 canonical JSON 哈希。
- `collection_protocol` exact keys 为 `id,sha256`；ID 是受控、安全标识，摘要是获批
  实时 driver/边界事件合同的 64 位小写 SHA-256。它从 collection plan 原样绑定进
  native result、sidecar、report 与 gates；它不认证 pipe 对端，也不能把静态或重放
  marker 变成真实运行证据。
- `product` run 的 `artifact` 必须逐字段匹配 run 的 artifact、adapter、engine、
  model 和 revision，并额外给出 verifier 得到的正整数 payload bytes/file count；
  `system` run 的 artifact 必须为 `null`。
- collector exact keys 为上例八项；固定使用上例 ID/clock/memory/energy/signing
  identifier，采样间隔为正整数且不超过 100ms。`executable_sha256`、Team 与采样
  间隔必须逐项等于 collection plan，且完整 sidecar 进入
  `performance_evidence_sha256`。不能以 wall clock 或日志时间戳代替连续时钟。
- environment exact enums：`power_source=ac|battery`、thermal state 为
  `nominal|fair|serious|critical`；开始与结束必须一致，Low Power Mode 必须关闭，
  `hardware_model` 必须保留 raw `sysctl hw.model`，满足同一 128-byte 字段专用语法
  并与 run 逐字节一致；`physical_memory_bytes` 与 `logical_cpu_count` 必须是正整数。
- `required_process_roles` 不只是集合，必须按
  `input_method,candidate_service,voice_helper` 的固定顺序逐项相等。
- 每个 corpus sample 必须恰有一个 session，且 `audio_duration_ms` 与 corpus
  一致。session exact keys 为 `sample_id,audio_duration_ms,processing_duration_ms,
  processes`；非零音频的 processing duration 必须为正数。
- 每个 session 必须恰有三个不同实例的 process：`input_method`、
  `candidate_service`、`voice_helper`。每项 exact keys 为 `role,instance_id,
  start_user_cpu_ns,end_user_cpu_ns,start_system_cpu_ns,end_system_cpu_ns,
  start_energy_nj,end_energy_nj,baseline_resident_bytes,peak_resident_bytes,
  baseline_phys_footprint_bytes,peak_phys_footprint_bytes,sample_count,
  maximum_sample_gap_ms`。累计 counter 不能
  回退，baseline RSS/phys-footprint 必须为正、peak 不能低于 baseline；每个 session
  的 voice-helper CPU delta 必须为正，整次证据的 energy delta 总和也必须为正。
  样本数必须覆盖完整处理时长，最大间隔不得超过配置间隔的 2 倍。零值不能用来
  冒充“已测得且表现完美”。
- `keyboard_trials` 按同一正整数 sequence 成组三阶段：`baseline`、
  `helper_loaded_idle`、`listening_cancel_to_rime`；每项还含正且有限的
  `rime_candidate_latency_ms`，且 exact keys 只能为
  `sequence,phase,rime_candidate_latency_ms`。缺阶段、重复阶段或未配对序列均
  无效。
- `late_voice_commit_count` 是非负整数；正式 gate 要求它严格为 0，非零值仍是
  合法证据，但会得到 gate fail，而不是 schema 错误。`cold_artifact_load_ms` 必须是
  非空、正值、有限数组。`late_challenge_counts` exact keys 为
  `cancel,application_switch,secure_input,target_invalidation,keyboard_input`，每项是
  非负整数；是否足够由 gates 的独立下限决定。
- 聚合只输出 RTF、三进程 cohort RSS/phys-footprint、语音增量 footprint、CPU、
  energy、冷加载、制品体积和三阶段键盘延迟分布，不回显 sample/process instance
  ID。当前仓库实现了严格 loader/aggregator，以及负责连续时钟、三进程 V6
  counter、环境和签名复验的 native collector；正式事件 driver、真实 corpus
  驱动和真机运行证据仍未完成，不能用手填 sidecar 或重放 marker 冒充测量。

### 8.1 Collection plan、实时事件与 native collector

用户提供的 `COLLECTION-PLAN.json` 是 schema v1 exact-key 对象，顶层只能包含：

```text
schema_version,collection_protocol,sample_interval_ms,native_collector_sha256,
expected_team_identifier,artifact_directory,processes
```

- `sample_interval_ms` 为 `1...100`；collector SHA-256 是签名后可执行文件的 64 位
  小写十六进制摘要，Team 是 10 位大写字母/数字。
- `collection_protocol` exact keys 为 `id,sha256`，并且必须与获批 gates 中的同名
  requirement 精确相等；native stdout 不得自行改写它。
- `processes` 恰有三项并按 `input_method,candidate_service,voice_helper` 排序；每项
  exact keys 为 `role,pid,expected_executable_path,
  expected_signing_identifier,expected_cdhash`。PID 必须为不同的正整数，CDHash 是
  40 位小写十六进制；三个固定 identifier 依次为
  `fun.wwcn.inputmethod.RimeAI`、`rimeai-daemon`、
  `fun.wwcn.rimeai.voice-helper`。
- 可执行文件路径和 product `artifact_directory` 必须是已存在、绝对、规范化、
  不含符号链接的路径；candidate service 的 `current` 链接必须先解析为实际 release
  路径。system-managed run 的 artifact directory 必须为 `null`。
- 用户 plan 不得声明 native-only `artifact` 对象。Python 在验证 run 后只从 run
  注入 `artifact_id,artifact_content_sha256,adapter_id,engine_id,model_id,
  model_revision`；native verifier 再逐字段核对目录中经 manifest、hash 与权限验证的
  制品事实。该 verifier 不声称模型来源已经过密码学签名或获得发布批准。

实时 stdin 每行是不超过 4096 bytes 的 schema v1 NDJSON exact-key 事件；事件只允许：

```text
cold_artifact_load_begin(sequence) / cold_artifact_load_end(sequence)
session_begin(sample_id) / session_end(sample_id)
keyboard_begin(sequence,phase) / keyboard_candidate_ready(sequence,phase)
challenge(scenario)
late_voice_commit
finish
```

`sequence` 是正整数，`sample_id` 必须是当前 corpus 的受控 ID，keyboard phase 只能为
`baseline|helper_loaded_idle|listening_cancel_to_rime`；challenge scenario 只能为
`cancel|application_switch|secure_input|target_invalidation|keyboard_input`。事件中出现
调用方计时、资源数值、文本、音频路径或未知字段都会失败。`finish` 必须是最后一条
事件，随后 producer 关闭 pipe；缺失 finish、尾随事件、不完整 begin/end 或不完整
键盘三阶段均不产生证据。

`cold_artifact_load_begin/end` 专指同一受控 driver 发起并等待完成的一次全新 backend /
模型 generation 初始化（process-cold），不声称操作系统文件缓存已清空。producer 必须
在任何该 generation 的模型读取前发送 begin，只能在 load probe 成功后发送 end；重放
marker 不能成为证据。为避免 collector 自己先遍历并哈希模型文件、污染这段测量，native
会把 artifact 的完整 manifest/inventory/hash 验证延迟到 `finish` 之后、生成 stdout
之前；验证或身份绑定失败时整次结果被丢弃。当前仓库仍缺能兑现这些因果约束的正式
driver，所以合成事件只验证状态机，不构成冷加载发布证据。

native collector 使用单一串行执行器线性化 timer sample、boundary event 与 finish：

- 所有进程资源读数统一使用 `proc_pid_rusage(RUSAGE_INFO_V6)` 取得 user/system CPU、
  RSS、physical footprint、energy 与 process start/exit token；一个 attested point 对
  每个进程读取 V6 A/B 两次，并以 B 作为输出。处理耗时与事件边界使用
  `mach_continuous_time`，PID token 只用于防复用，不能当作同域时间点。
- 每个进程按 `V6 A -> UID/路径/签名 -> V6 B` 复验 PID 未退出或复用、counter
  未回退、路径/identifier/Team/CDHash 精确匹配。collector 自身及三进程还必须满足
  Developer ID Application 的 intermediate/leaf OID requirement；Apple Development
  或 ad-hoc 构建不得生成正式 sidecar。
- 开始/结束及采样期环境必须稳定；raw `hw.model` 在 native 信任边界按上述专用语法
  校验并原样保留。Low Power Mode、process identity、热状态、供电或 counter 异常
  都会使整次采集失败。native stdout 最多一个不超过 4 MiB 的最终 JSON；stderr
  只有固定安全错误码。
- Python 再把 native result 绑定 corpus 音频时长、run SHA 与 collector
  SHA/Team/identifier/sample interval，复用权威 sidecar validator，并以 `0600`、
  `fsync + atomic replace` 写入预解析后的输出目标。输出不能覆盖 corpus、run、plan、
  collector、模型目录或三个被测可执行文件。

正式采集器必须先做 Release 构建，再以 identifier
`fun.wwcn.rimeai.voice-performance-collector`、hardened runtime 和当前产品 Team 的
Developer ID Application identity 签名，最后计算并写入 plan 的 SHA-256；先哈希后
签名会被双重自验拒绝。普通 `swift build -c release` 的 ad-hoc 产物只适合编译测试，
不能形成 release evidence。native 内部 exact argv 为
`rimeai-voice-performance-collector --plan /absolute/0600-plan.json`；正常用户应通过
本节开头的 Python 命令运行，由 Python 生成该临时 native plan。

受控构建机上的最小顺序如下；`SIGNED-COLLECTOR` 必须是独立的规范绝对路径，不能
覆盖 `.build` 内输入或任何被测可执行文件：

```bash
RIMEAI_SIGNED_COLLECTOR=/absolute/controlled/path/rimeai-voice-performance-collector
swift build -c release --product rimeai-voice-performance-collector
install -m 0755 \
  .build/release/rimeai-voice-performance-collector \
  "$RIMEAI_SIGNED_COLLECTOR"
codesign --force --options runtime --timestamp \
  --identifier fun.wwcn.rimeai.voice-performance-collector \
  --sign "Developer ID Application: … (TEAMID)" \
  "$RIMEAI_SIGNED_COLLECTOR"
codesign --verify --strict --verbose=2 "$RIMEAI_SIGNED_COLLECTOR"
codesign -d --verbose=4 "$RIMEAI_SIGNED_COLLECTOR"
shasum -a 256 "$RIMEAI_SIGNED_COLLECTOR"
```

构建日志、identity、Team、Designated Requirement、hardened-runtime flag 与最终摘要
都应进入受控 run 记录；摘要不得从签名前二进制、软链接或可变副本推导。native
内部 usage failure 为 exit 64，其他 collection rejection 为 exit 65，stdout 为空且
stderr 只有固定错误码；面向用户的 Python CLI 把采集失败统一映射为 exit 2。

## 9. Gates schema

gates 顶层 exact keys 只能为
`schema_version,evaluation_profile_id,required_subsets,thresholds,
evidence_requirements`：

```json
{
  "schema_version": 2,
  "evaluation_profile_id": "voice-release-zh-cn-2026-08",
  "required_subsets": [
    {"dimension": "language_composition", "value": "zh"},
    {"dimension": "language_composition", "value": "en"},
    {"dimension": "language_composition", "value": "mixed"},
    {"dimension": "language_composition", "value": "blank"},
    {"dimension": "domain", "value": "general"},
    {"dimension": "domain", "value": "software"},
    {"dimension": "noise", "value": "quiet"},
    {"dimension": "noise", "value": "common_noise"},
    {"dimension": "distance", "value": "near_field"},
    {"dimension": "distance", "value": "far_field"}
  ],
  "thresholds": {
    "mandarin_cer_max": 0.12,
    "english_wer_max": 0.18,
    "punctuation_edit_rate_max": 0.20,
    "term_exact_match_rate_min": 0.90,
    "blank_false_positive_rate_max": 0.01,
    "partial_churn_rate_max": 1.50,
    "collateral_substitution_rate_max": 0.01,
    "first_partial_p95_ms_max": 500,
    "stop_to_final_p95_ms_max": 800,
    "cancel_to_capture_stop_p95_ms_max": 100,
    "real_time_factor_p95_max": 1.0,
    "cohort_peak_resident_mib_max": 3584,
    "cohort_peak_phys_footprint_mib_max": 3584,
    "voice_incremental_peak_phys_footprint_mib_max": 3584,
    "cpu_core_seconds_per_audio_second_p95_max": 2.0,
    "energy_joules_per_audio_minute_p95_max": 120,
    "product_artifact_payload_bytes_max": 1073741824,
    "cold_artifact_load_p95_ms_max": 8000,
    "keyboard_baseline_rime_p95_ms_max": 30,
    "keyboard_helper_loaded_rime_p95_ms_max": 30,
    "keyboard_helper_loaded_added_p95_ms_max": 5,
    "keyboard_listening_cancel_to_rime_p95_ms_max": 30,
    "keyboard_listening_cancel_added_p95_ms_max": 5
  },
  "evidence_requirements": {
    "collection_protocol": {
      "id": "rimeai-release-collection-v1",
      "sha256": "<64 lowercase hex>"
    },
    "minimum_cold_artifact_load_trials": 3,
    "minimum_paired_keyboard_sequences": 30,
    "minimum_first_partial_samples": 120,
    "minimum_stop_to_final_samples": 160,
    "minimum_cancel_to_capture_stop_samples": 40,
    "minimum_partial_churn_transitions": 40,
    "minimum_required_subset_samples": 20,
    "minimum_late_challenges_per_scenario": {
      "cancel": 10,
      "application_switch": 10,
      "secure_input": 10,
      "target_invalidation": 10,
      "keyboard_input": 10
    }
  }
}
```

上例阈值只演示完整字段集合和方向。500/800/100ms、8 秒冷加载、30ms Rime
P95、5ms 新增同步路径和 3.5GiB 总内存来自 PRD 的产品上限；质量绝对值、RTF、
CPU、能耗、模型体积以及如何在 RSS/phys-footprint/增量门之间分配预算仍必须由
冻结评测计划评审。不得把本示例整体复制成获批策略。

`evidence_requirements` 将“指标存在”与“证据数量足够”分开。已知 exact keys 为
`collection_protocol,minimum_cold_artifact_load_trials,
minimum_paired_keyboard_sequences,minimum_first_partial_samples,
minimum_stop_to_final_samples,minimum_cancel_to_capture_stop_samples,
minimum_partial_churn_transitions,minimum_required_subset_samples,
minimum_late_challenges_per_scenario`。所有 minimum 都是正整数；迟到挑战对象只能含
上述五个场景。示例数字只是展示形状，仍须由冻结评测计划评审。

字段缺失是结构上可加载但政策不完整，结果为 `policy_incomplete`/退出码 1；未知字段、
非法类型、boolean、0 或负数是 gates schema 错误，退出码 2。正式配置必须提供完整
字段集合和五个场景。每个计数在 `minimum-1` 都不得通过，恰好达到 minimum 才算证据
完整；`collection_protocol` 必须与 sidecar 精确相等。性能阈值数值再好，也不能替代
冷加载次数、成对键盘序列、partial/final/cancel/churn 分母、每个 required subset 的
样本数或五类迟到挑战次数。

`authenticated_production_driver` 不是 gates schema 字段，也不属于
`evidence_requirements`；在任一位置添加它都会作为未知字段以退出码 2 拒绝。对于
schema v3，aggregate 中 `gate_policy_complete`、`performance_evidence_complete` 与
`authenticated_production_driver` 三项检查的 `evidence_complete` 均固定为 false，
所以即使其他数值检查逐项通过，最终仍为 `policy_incomplete`/退出码 1。

`required_subsets` 是 unique 的 `{dimension,value}` 数组；正式策略必须至少包含
上例十个 PRD 子集，aggregate 中使用稳定键 `dimension:value`。上例列出的 23 个
质量、延迟、资源与键盘阈值必须全部出现。结构合法但遗漏阈值或必需子集的 gates
可以被加载，但评测结果只能是
`policy_incomplete`/退出码 1，不能用 schema error 隐藏成“尚未运行”。在输入本身
合法且身份绑定一致的前提下，required subset 没有可评分证据、被 run 声明
unsupported 或指标分母为零，都产生 `policy_incomplete` 和
`quality_gate_pass: false`；正式 required subset 不得因 unsupported 声明而跳过。
逐样本 observation/performance 覆盖不完整、profile/fingerprint/run SHA 不匹配，
或时钟合同无效则属于输入/身份错误，必须在评分前以退出码 2 拒绝，不能降格为
`policy_incomplete`。

`thresholds` 中出现未知名称，或值不是有限、非负的 number，属于 gates schema
错误并以退出码 2 拒绝。已知 mandatory 名称缺失才属于上一段的
`policy_incomplete`，两者不得混淆。

数值阈值之外，quality gate 还会复验 corpus 至少 200 条、非 fixture、存在授权
引用、真实录音与说话人隔离声明、非虚拟音频设备，以及 run 同时记录
`requires_on_device=true` / `supports_on_device_at_run=true`。评测器只校验这两个
采集声明，不会自行探测网络或引擎；第 11 节的 no-INET 运行审计仍是独立外部门。
低于 macOS 26 的 `system` 资产仍会使 `engine_policy_eligible` 检查失败；在当前
schema v3 中最终 decision 因更早的认证缺口为 `policy_incomplete`。它仍可保留
measurement 报告，但不能获得 `quality_gate_pass`。performance sidecar 虽允许记录 battery 或稳定的非 nominal
热状态以保留测量，但正式 quality gate 只接受 AC 供电、Low Power Mode 关闭且
采集起止均为 nominal thermal state 的环境。

若 `run.policy.hotwords_enabled` 为 true，还必须成对提供同条件且
`baseline.policy.hotwords_enabled=false` 的 unheated baseline，并额外提供：

- `technical_term_exact_gain_pp_min`
- `mandarin_cer_regression_pp_max`

`pp` 是百分点差，不是相对百分比。缺 baseline、baseline 不可比或任一增益/回归
门缺失时都必须 fail-closed；其中未提供 baseline 或缺少 threshold 会生成
`policy_incomplete`/退出码 1，已经提供但不满足上文 A/B 精确可比条件则是输入错误，
以退出码 2 拒绝且不生成报告。上述两键是已知 schema 名称，但在 hotwords=false
的 run 中多带它们也会使策略的 threshold 集合不精确，从而得到
`policy_incomplete`，而不是被忽略。

## 10. 隐私与仓库存放

- 真实音频、真实 reference、逐条 hypothesis/partial 和可识别说话人信息不得进入
  Git。仓库只允许小型、明确标为 `synthetic_fixture: true` 的合成 fixture。
- 真实 corpus 放在受控外部存储；Git 中最多保存不含凭据、姓名和音频路径的
  fingerprint、聚合报告和外部授权登记引用。
- aggregate stdout 禁止包含 `reference`、`final.text`、partial text、sample 音频
  路径、speaker group、设备序列号或错误行原文。
- observation collection 的成功 stdout 只含 kind/schema/hash/valid 摘要；原生
  driver stdout 固定为空。临时 plan 可以含受控 sample ID、音频路径和请求级热词，
  只能存在于 owner-only staging，不能写入 aggregate、日志或仓库。
- loader 的错误只可暴露 corpus manifest/samples、run、observations、gates、
  performance 等输入控制文件路径、行号及经格式校验的 sample ID。不得回显
  reference、hypothesis 或音频路径。
- 音频不落盘、运行态无 INET socket 与崩溃后缓冲清理必须由独立系统审计证明；
  不能由 corpus schema 或缺少 network entitlement 推断。

## 11. 不能由本评测替代的外部门

即使所有数值 gates 通过，下列证据缺失时仍不得公开放行：

- 真实 Developer ID 输入法/helper、命名 Mach service 双向认证与拒绝矩阵；
- macOS 14/15 清洁用户会话的麦克风和 Speech Recognition TCC 首次授权、拒绝、
  撤销与重试；
- 内置、USB、蓝牙麦克风以及拔插/切换矩阵；
- TextEdit、浏览器、终端、Office 类宿主，Secure Input 与焦点切换矩阵；
- 运行态无 INET、音频不落盘与崩溃清理审计；
- notarization、stapling、Gatekeeper、首次安装、错峰升级和回滚。

这些外部门必须以独立、可审计的 evidence 状态进入发布流程。当前 schema v3 的 CLI
不会产生 `quality_gate_pass: true`；未来 authenticated evidence schema 即使允许该值，
也只证明本文件定义的质量、延迟和资源门，不会把“没有观察到失败”转换成产品发布批准。
