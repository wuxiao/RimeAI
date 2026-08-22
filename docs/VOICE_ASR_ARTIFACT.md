# 产品管理语音模型制品合同

本文记录 RimeAI 在 macOS 14/15 上接入产品管理本地 ASR 时已经实现的制品
边界。它是一层完整性、目录与切换基础设施，不代表仓库已经包含可工作的模型，
也不代表任何候选已通过质量、许可证或发布门。

## 当前结论

- 已实现严格的 `manifest.json` 解码、内容摘要、逐文件 inventory 校验和资源上限。
- Manifest v2 只记录制品事实，并已补齐首个 sherpa online transducer 所需的
  runtime entrypoints、decoding、endpoint 与热词参数；不能再用只有单个 encoder
  的假制品声明能力，也不能在 manifest 中夹带产品发布审批。
- 已实现 `current` / `previous` 选择器、崩溃恢复 journal、原子切换与回滚。
- selector 中的 artifact ID 必须与已验证 manifest 的 `artifact_id` 一致。
- Store 可在 selector 进程锁和文件锁内完成 current 重验、backend load probe 与
  engine generation 绑定；合作式 activate/rollback 不能插入验证和加载之间。
- 已实现 offline-only publisher：本地来源先经完整 verifier 与独立、编译进产品的
  trusted catalog 双重校验，再复制到私有唯一 staging，`fsync` 后用
  `RENAME_EXCL` 原子发布；相同内容幂等，不同内容永不覆盖，发布后可选择激活。
- 生产 trusted catalog 当前为空，因此没有候选能通过生产 publisher。schema v2
  不包含再分发审批字段；v1 manifest 和 legacy `redistribution_approved` 键都会被
  严格解码拒绝。
- Release helper 的 schema 2 签名策略绑定完整 trusted catalog cohort 的 canonical
  SHA-256。摘要覆盖 artifact/content、adapter/ABI、model/revision/format/
  quantization、license/source、再分发决策，以及来源、模型权利、再分发审核 ID
  和质量报告 SHA-256；LaunchAgent argv 不能选择 Release 引擎。helper 在读取
  policy 前主动复验自身 exact identifier、Developer ID Team/OID requirement 与
  bundle 资源封印；当前空 catalog 摘要只允许 Apple system-managed probe 策略，
  且 `ReleaseEligible=false`。
- `VoiceEngineDescriptor` 只区分不可用、系统探针和“产品制品完整性已验证”；
  产品 descriptor 只能由 verified lease 与成功 load probe 的交集工厂构造，
  完整性证据不会被命名为 Release 资格。
- 官方 sherpa-onnx `1.13.6` static XCFramework 与 ONNX Runtime `1.27.1` 已按
  exact checksum 直接链接，真实 C API driver、严格 artifact load 与显式
  `product-managed` helper 分支已存在；但仓库没有获批语音模型，production
  trusted catalog 仍为空，所以该分支必然 fail-closed。Release 仍是 probe-only，
  不声明产品模型或产品 ASR 可用；Apple Speech 仍只作 `system-managed` 链路/TCC
  探针。

## 磁盘布局

```text
~/Library/Application Support/RimeAI/models/voice/
├── releases/
│   └── <artifact-id>/
│       ├── manifest.json
│       └── <manifest inventory 中的全部文件>
├── staging/
├── current
└── previous
```

`VoiceASRArtifactStore` 只选择 `releases/` 中已经发布的不可变目录。它不联网、
不下载模型，也不负责把 staging 内容安装到 releases。`VoiceASRArtifactPublisher`
只接受 canonical 本地目录，并执行：

1. 在隔离 staging 目录完整写入制品；
2. 校验 manifest、inventory、权限、身份，以及独立 trusted catalog 对摘要、
   adapter、model、license/source、再分发决策与完整 release evidence 的绑定；
3. 用 `O_NOFOLLOW` 复制到私有唯一 staging，逐层同步后重新完整验证；
4. 用 `RENAME_EXCL` 原子发布为不可变 release，绝不覆盖已有 artifact ID；
5. 仅在调用方显式要求时，再调用 Store 激活 selector。

生产 public initializer 固定使用空 trusted catalog；测试可注入审批只用于验证状态
机，不能形成发布资格。publisher 没有 URL 下载入口，也不会在失败时联网修复。

## Manifest v2

固定值：

- `schema_version`: `2`
- `artifact_type`: `rimeai.voice-asr-model`
- `asset_management`: `product-managed`
- `target`: `macos` / `arm64` / 最低 macOS `14.0`
- `audio`: 16 kHz、mono、Float32LE、20 ms frame
- `network_policy`: `offline`

manifest 还必须声明受控 artifact/adapter/model 标识、locale、streaming、partial、
endpoint、热词/N-best 能力，许可证/NOTICE/source URL，排序且无重复的逐文件大小
与 SHA-256，以及覆盖 manifest metadata 和排序 inventory 的 canonical
`content_sha256`。canonical 内容使用 `rimeai.voice-asr.content.v2` 域；发布审批不
参与制品自述，也不能由导入目录提供。schema 不是 `2`、出现未知字段，或在
`license` 中携带 legacy `redistribution_approved` 都会 fail-closed。

Schema v2 的 `runtime` 是首个产品 adapter 的严格合同：

- `kind=sherpa-onnx-online-transducer`；
- canonical encoder、decoder、joiner、tokens 和 BPE vocabulary 相对路径，且五项
  必须互不相同、不得复用 LICENSE/NOTICE 路径并全部出现在 inventory；
- `model_type=zipformer`、`modeling_unit=cjkchar+bpe`、80 维 feature、CPU provider；
- 有界线程数、`modified_beam_search`、max active paths；
- 启用 endpoint 的三条毫秒整数规则，以及千分整数 hotword score / blank penalty。
- 一个完整性绑定、非敏感、已知能被该模型编码的 canonical
  `hotword_probe_phrase`；支持热词的制品在广播能力前必须以声明的最大条数重复该
  短语，真实创建并结束有界热词流，不得仅把 manifest 的能力声明当作运行时证据。

当前官方 Swift online API 不返回 N-best 或置信度，因此该 runtime 强制
`maximum_alternatives=1`；beam 的 active paths 不能冒充 N-best。产品结果的
confidence 必须明确使用“未知”语义，不能合成一个虚假评分。

解码拒绝未知或缺失字段、重复 JSON key、NaN、非 canonical 路径、额外/缺失文件、
符号链接、特殊文件、AppleDouble、扩展 ACL、组或其他用户可写项及多硬链接普通
文件。生产上限为 1 MiB manifest、512 个 inventory 文件、2 GiB 总内容、JSON
深度 32/节点 32768、目录深度 32/条目 16384。校验完成前会再次读取 manifest
并重扫目录，降低验证期间的替换窗口。

## Selector 与失败恢复

选择器只保存受控 `VoiceASRArtifactID`。Store 在进程锁和文件锁下：

- 从已打开的受管根目录以 `openat` 打开 `releases` / `staging`；
- 校验 release 目录权限、设备/inode 与 manifest ID；
- 先写并同步 transaction journal，再原子替换 `current`；
- 将旧 `current` 保存为 `previous`，支持幂等回滚；
- 启动时恢复被中断的 selector transaction。

`withVerifiedCurrentArtifact` 在同一把进程锁和 `flock` 内读取 current、校验
release dev/inode、运行完整 verifier、再次检查 selector/目录，并在解锁前调用
backend load closure。closure 获得新的 `VoiceASRVerifiedArtifactLease.generation`；
实际 recognizer load probe 必须回传同一 generation，产品 descriptor 工厂才会
广播 `local_asr`。运行中不热切模型，新的 selector 在下一次 helper/backend
构造时生效。该 closure 位于非递归 selector 锁内，禁止重入 `selectorState`、
`activate`、`rollback` 或另一轮 verified load；音频/TCC 启动也必须在返回后执行。

## 产品引擎装配与流式会话

产品引擎现在有真实 C API backend 与一条可由 fake/synthetic 测试覆盖的装配链：

1. `ProductManagedVoiceEngineBootstrap` 在 verified-load closure 内把 lease 交给
   `VoiceProductBackendLoading`；loader 必须同步打开全部模型文件、构造 recognizer
   并依次完成模型指定的非空 hotword probe 与 fresh empty-stream probe。
2. `VoiceProductBackendLoad` 要求 recognizer driver 与 load probe 的 artifact
   generation 相同；bootstrap 再要求两者与 Store lease generation 相同。
3. `VoiceEngineDescriptor.productManaged` 只取 manifest 与真实 load probe 的能力
   交集；`ProductStreamingVoiceEngine` 构造时再次核验 descriptor/driver generation。
4. Store 解锁后才注入 PCM source factory 和请求热词 provider。provider 只消费
   已由输入法按 V2 协商上限截断、重算摘要并由 helper 重验的不可变快照；
   不在启动麦克风的同步路径读 Rime userdb、历史、剪贴板或文档。麦克风权限、capture 与
   每会话音频源只允许在 `start` 后创建，selector 切换只影响下一次 helper 启动。

当前流式核心把完整、已校验的 wire 请求转换为 helper 内部唯一控制 ID，并把
bundle/session/mode/deadline/max-duration 保留给热词与端点策略。采集层把拥有自身
存储的 44.1/48 kHz mono/stereo Float32 PCM 转成 16 kHz mono、320 samples/20 ms
frame；正常 stop 排空并只对最后不足一帧的尾部补零，cancel/失败丢弃尾部。产品
引擎用单一 decoder queue 独占 recognizer，设定有界 FIFO，按代际线性化 reset 与
cancel。新协议请求总是创建全新的 native stream；同一请求内的 endpoint 才调用
`SherpaOnnxOnlineStreamReset`，保留 native 尚未消费的边界音频并固化当前 segment。
用户 stop 后才产出 exactly-once final，不能用“销毁并新建 stream”冒充 endpoint
reset；final 假设发布前显式销毁当前 native stream，不让上一请求的
热词/context 泄漏到下一请求。
官方 API 不提供置信度，结果固定使用 `0` 表示 unknown，而不是伪造评分。

`SherpaOnnxProductBackendLoader` 已通过真实 C API 强制校验 sherpa version
`1.13.6`、XCFramework embedded revision `0fdffb3e` 与 ORT version `1.27.1`，
创建 online recognizer/stream，并调用 accept/decode/result/endpoint/finish；
Debug helper 可显式选择 `product-managed`，Release helper 则只能由自身签名 policy
选择，并在 native load/TCC/server 前验证 policy 与 production catalog 摘要。它们
证明 runtime 与代码路径存在，
不证明产品 ASR 可用：生产 trusted catalog 仍为空，也没有获批模型可由 production
factory 加载。真实 TCC、麦克风、模型质量、资源、识别态 no-INET 与分发门仍未通过。
静态 runtime 的 Apache-2.0、MIT 与版本匹配的 ONNX Runtime
`ThirdPartyNotices.txt` 随附边界见 [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)；
这些软件许可证材料不延伸为任何模型权重或训练数据权利结论。

Debug 另有一条独立、exact argv 的候选评测入口：
`--socket <path> --engine evaluation-product-managed --artifact-dir <absolute-canonical-directory>`。
helper 的 main dispatch 只在 `DEBUG` 编译中存在；Release main 只接受固定
Mach-service argv，因此即使共用参数解析代码也无法到达该模式。evaluation factory
本身也供独立、非发布的 `rimeai-voice-eval-driver` Release 优化构建复用，以冻结 WAV
生成 V0 observations；该 executable 不嵌入输入法/helper 发布包。两条评测路径都先
用 schema v2 verifier 验证调用方明确指定的目录，再在同一临时 lease 中调用
真实 sherpa backend loader 并装配流式引擎；它不读写产品 Store、publisher、
`current` / `previous` selector，
也不查询或修改 trusted release catalog。这个 bypass 只让候选能够被验证和真实
加载测量，不能生成 catalog approval、不能进入 Release argv/policy，也不证明候选
已成功完成真实质量、TCC、资源或 no-INET 门。

原生库的更深层配置或模型校验可能直接终止 helper，并非所有失败都能被 Swift
`throw` 捕获。进入 C API 前必须以 trusted catalog、artifact/content/file checksum
和严格 manifest/inventory 阻止未批准 cohort；残余 native termination 的恢复边界
是 helper 进程退出并重新启动。不得在同一进程自动重试、切模型或
回退到 Apple/cloud，也不得把“可重启”解释为模型安全证明。

## 证据边界

`content_sha256` 和逐文件 SHA-256 只证明“当前读取的本地内容与 manifest 一致”。
具体而言：

- 不证明 manifest 或模型由 RimeAI/上游可信发布者签名；
- 不证明 code-shipped approval 中的再分发决定或审核 ID 对应真实、完成的法律审查；
- 不证明 runtime、权重和转换产物的来源、许可证与版本配对正确；
- 不证明模型达到真实语料 CER/WER、术语、延迟、资源或热词误伤门；
- 不证明真实 TCC、音频不落盘、识别态 no-INET、公证和清洁机器门已通过。

trusted catalog 是 manifest 外的产品审批边界，但当前仍只是编译期 allowlist，
不是远端签名或供应链透明日志。`VoiceASRTrustedArtifactApproval` 的
`redistributionApproved` 必须为 true，并携带严格的 `VoiceASRReleaseEvidence`：
`sourceReviewID`、`modelRightsReviewID`、`redistributionReviewID` 均为 1–128 bytes
受控标识，`qualityReportSHA256` 必须是
[`VOICE_EVAL_FORMAT.md`](VOICE_EVAL_FORMAT.md) 定义的 schema v2
`quality_report_sha256`（64 位小写十六进制），不是报告文件的任意字节哈希或展示
版本。catalog v2 的 canonical
摘要覆盖 approval 的全部字段与这四项证据；空列表、任一非法 approval 或重复
artifact ID 都使 `hasReleaseApprovals=false`，实际 publisher/runtime 授权也会拒绝
非法 evidence。正式填入任何 approval 前，仍须完成人工来源、模型权利、许可证、
训练数据权利、再分发与质量审核；发布流程还必须重算该报告摘要、确认
`quality_gate_pass == true`，并逐字段核对报告中的产品制品 provenance。Swift
catalog/runtime 当前只校验摘要形状并把它纳入受信 catalog，不会读取报告或把 64
位十六进制本身解释为质量通过。当前生产列表保持为空。

selector 是路径选择，不是长期持有的模型文件描述符；普通哈希也不是对同 UID
恶意进程的认证边界。当前 backend 对五个 runtime 文件使用 `O_NOFOLLOW` 打开，
在已打开描述符上复验类型、UID、权限、大小和 SHA-256，复位 offset 后把同一批
`/dev/fd/<fd>` 路径交给 C runtime，并由 recognizer driver 持有这些描述符到其生命
周期结束。这消除了校验后通过 rename/symlink 替换路径的普通窗口，但仍不把同 UID
进程对同一 vnode 的原地写入变成可防御的密码学边界，也尚未证明所有获批真实模型
在 ORT/SentencePiece 中对 `/dev/fd` 的多次打开与共享 offset 行为兼容。只有“已验证
制品 + 后端成功加载探针”的受控 factory 才能生成产品运行 descriptor；公开 API
不能自行声明该资格。

## 下一步

1. Runtime 候选已按 [`VOICE_ASR_RUNTIME_INTAKE.md`](VOICE_ASR_RUNTIME_INTAKE.md)
   固定；先补齐单一 streaming 模型的训练数据权利、不可变来源 revision 和再分发
   审批。当前候选只可评测、不可发布。
2. 在来源门解除后，把经人工审核的精确 digest/adapter/model/license/source cohort、
   再分发决定与四项 release evidence 编译进生产 trusted catalog；审批前 publisher
   必须继续 fail-closed。
3. 真实 sherpa C driver/load probe 与显式、fail-closed 的 helper 产品模式已实现；
   下一步是在获批模型上验证 native termination→helper restart、启动崩溃循环隔离
   与 selector 回滚。官方 API 没有 N-best，因此首个 adapter 只能声明一个
   alternative；若产品坚持 N-best，须扩展受审 wrapper 或更换 backend。
4. 用外部授权且说话人隔离的至少 200 句冻结语料跑
   [`VOICE_EVAL_FORMAT.md`](VOICE_EVAL_FORMAT.md) 的测量与 gate。
5. 完成真实 macOS 14/15、TCC、设备、识别态 no-INET、不落盘、签名、公证和
   清洁机器验收后，才讨论公开启用。
