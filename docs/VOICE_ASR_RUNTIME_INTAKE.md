# 产品管理语音 ASR runtime / model intake

> 本文只维护冻结 cohort 与 intake 合同；当前工作树和发布状态见
> [`TASKS.md`](../TASKS.md)。

本文冻结 RimeAI 截至 2026-08-24 对首个 macOS 14/15 产品管理语音候选的
上游核对、外部 evaluation artifact seal 与冷加载 tracer 合同。它是后续
受控构建和 V0 评测的输入，不是许可证批准、模型发布批准或真机验收记录。

## 结论

- 静态 `sherpa-onnx 1.13.6` XCFramework 与 ONNX Runtime `1.27.1`
  XCFramework 已按上游精确 URL/checksum 作为直接 SwiftPM `binaryTarget` 接入
  helper engine；这只完成 runtime 字节固定与代码接线，不代表模型或 Release
  已获批准。
- 当前中英流式 Zipformer 已经受控外部解包、逐文件固定并封印为
  evaluation artifact，但训练数据权利及 archive 到不可变源 revision 的对应
  证据仍不足。它只允许进入受控 V0 评测，不得进入生产受信 catalog、
  Release 包或自动下载路径。
  schema v2 manifest 不承载审批；任何 legacy `redistribution_approved` 键都会被
  拒绝，不能用 false 值把未审批候选伪装成生产合同。
- evaluation sealer 真实回执固定 artifact ID
  `sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20-eval-27ffbd9e`、
  content SHA-256
  `13276809093a0cd38ecb1b166041172da3421848bbdbb9a1ddbf6cb189699dc9`、7 个
  inventory 文件和 `199080356` bytes；其中 5 个 runtime 模型 payload 合计
  `199068769` bytes，另两个是 LICENSE/NOTICE。
- 基于该 seal 的签名 collector→driver→fresh helper tracer 固定输出完整九帧
  schema-2 result；`qualification=tracer`、
  `authenticated_production_driver=false`，不是 schema-3 release evidence 或产品 gate。
- 代码许可证、runtime binary 完整性、模型权重许可证和训练数据权利是四个
  独立门。任何一个门通过都不能替代其余三项。
- `VoiceASRTrustedArtifactCatalog.production` 当前仍是 `approvals: []`；没有任何
  候选具备 publisher 或 Release product-managed runtime 的生产授权。

## Runtime 候选冻结

### sherpa-onnx

- 版本：`1.13.6`
- tag commit：`1cb484af5e69d3c7803c1eb0b3b5ab8041e0e911`
- XCFramework 内嵌 git revision（C API 自报）：
  `0fdffb3e`
- SwiftPM product：`sherpa-onnx`
- upstream Swift wrapper target：`SherpaOnnx`（本仓库未使用该 wrapper）
- 本仓库导入的 C module：`SherpaOnnxC`
- macOS static binary target：`SherpaOnnxMacOS`
- archive：`sherpa-onnx-v1.13.6-macos-static.xcframework.zip`
- archive bytes：`11,590,556`
- SwiftPM checksum / SHA-256：
  `ef8fa1ae6a7764b8d80a79ab66a49d553b40af2df7dd18b08b8559cdca3a1b1e`
- archive URL：
  <https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.6-macos-static.xcframework.zip>
- upstream package：
  <https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.6/Package.swift>
- upstream release：
  <https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.6>

只允许使用默认 static product。不得切换到 `sherpa-onnx-shared`；这样可避免
把上游 dylib、rpath 和嵌套签名面引入 helper，但最终 app 仍必须由 RimeAI 的
Developer ID 流水线整体签名、公证并在清洁机验证。

`v1.13.6` release tag 指向 `1cb484af…`，但该 release 路径下载到的静态
XCFramework 通过 `SherpaOnnxGetGitSha1()` 自报 `0fdffb3e…`。两者不是同一个
提交，不能互相替代：前者记录 package/release 来源，后者才是 helper 在加载前
强制匹配的二进制构建身份。当前接入同时固定 archive checksum、版本字符串、
embedded revision 和 ONNX Runtime 版本，任一不一致即 fail-closed。

### ONNX Runtime wrapper

- package version：`1.27.1`
- package tag commit：`1fbef5f2a1b5c2691fe9411243f3a8afe9a0b169`
- upstream ONNX Runtime `v1.27.1` release commit：
  `4d863cd7e8ec81403e2900499e3804d68418a96c`
- archive：`onnxruntime-macos-static-xcframework-1.27.1.xcframework.zip`
- 本仓库 macOS binary target：`OnnxruntimeMacOS`
- archive bytes：`68,993,635`
- SwiftPM checksum / SHA-256：
  `89769c25a63985e2ab7a12e72215c173c5078e49dc4a2273cb84b75e587d7b96`
- archive URL：
  <https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.27.1/onnxruntime-macos-static-xcframework-1.27.1.xcframework.zip>
- package manifest：
  <https://github.com/csukuangfj/onnxruntime-libs/blob/1.27.1/Package.swift>

代码许可证必须分别冻结 sherpa-onnx 的 Apache-2.0、Microsoft ONNX Runtime 的
MIT 与 ONNX Runtime `ThirdPartyNotices.txt`；包装仓库本身没有许可证文件，不能
据此省略最终二进制 SBOM 与第三方 notices 审核。版本化官方文本见 sherpa-onnx
[`LICENSE`](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.6/LICENSE)、ONNX Runtime
[`LICENSE`](https://github.com/microsoft/onnxruntime/blob/v1.27.1/LICENSE) 与
[`ThirdPartyNotices.txt`](https://github.com/microsoft/onnxruntime/blob/v1.27.1/ThirdPartyNotices.txt)。

上述 checksum 只固定下载字节，不证明 Developer ID、公证或运行兼容性。当前
直接 `binaryTarget` 接入仍须在 Release 候选上复验 arm64 slice、
`LC_BUILD_VERSION`、modulemap、静态链接结果和最终 helper 的 `otool -L`，并
证明无 `.build`、Homebrew 或开发机绝对路径。

## Runtime 加载与进程边界

helper 已有真实 sherpa C API driver。产品 factory 先在 Store 的 verified lease
内重验 manifest/inventory 与 production trusted catalog，再校验上述 runtime
身份；对 manifest inventory 中的五个模型文件以 `O_NOFOLLOW` 打开并在描述符上
复验类型、UID、link count、权限、大小和 SHA-256。然后从 verified fd 为每个
文件生成独立 inode snapshot：首选 `fclonefileat`，失败则使用 `pread` 逐字节
exclusive copy。snapshot 文件必须是 owner-only、单链接、0400 普通文件，与源
dev/inode 不同。runtime 只在 recognizer 创建期将 private snapshot 目录中的普通
绝对 pathname 交给 Sherpa，让 Sherpa/ORT 重复 open 时每次得到独立
file description/offset，创建
online recognizer/stream，并执行非空热词容量与 fresh empty-stream probe。流式路径实际调用
accept/decode/result/endpoint/finish；每个新请求创建 fresh stream，同请求的 endpoint
才调用 native reset，以免丢掉 native 尚未消费的边界音频或继承上一请求的上下文。

该普通 pathname 的 authority 从 `/` 开始逐祖先建立：目录 owner 只能为 root/euid，
不得有 setid bit；mode `022` 非零仅允许 root-owned sticky directory，因此规范
`/private/tmp` 仍可作为测试树祖先，其他 renameable ancestor fail-closed。普通祖先
若存在 extended ACL，只接受 `acl_valid` 通过且每个 entry 都是 deny；allow、unknown
tag、invalid ACL 或读取/枚举错误一律拒绝。managed artifact root/source tree、
snapshot parent/directory/files 则始终严格 no-ACL。

当前 load probe 实际包含一组非空热词容量输入与随后 fresh empty stream；这验证
配置路径能构造热词 stream 并能清空请求状态。隔离单测仍使用 fake
recognizer；后述签名 tracer 可对当前 exact evaluation cohort 执行真实 native load。
这两者都不能替代真实获批模型的最大异构热词集合、重复性与设备运行证据。Release helper
还必须先通过自身签名 schema 2 policy；policy 的 catalog 摘要与 code-shipped
production catalog 不一致时，Store、native runtime 与 TCC 均不得启动。

候选 evaluation 由独立 `rimeai-voice-eval-driver --plan <owner-only-plan>`
执行。plan 引用调用方明确选择的 schema v2 artifact；driver 严格验证后把临时
lease 交给同一个 `SherpaOnnxProductBackendLoader`，将冻结 WAV 经真实
backend/ServerCore 生成 V0 observations。它不嵌入输入法/helper 包，不读写
Store/selector/catalog，也不能生成 release approval。

Debug helper 不接受
`evaluation-product-managed --artifact-dir`；当前 parser/tests 明确拒绝该旧语法。
Debug helper 的 `product-managed` 只从产品 Store/selector 装配。Release argv
仍只接受固定 Mach service，当前签名 policy 选择 Apple system-managed probe 且
`ReleaseEligible=false`。任何 evaluation 成功都不能替代真实质量、TCC、资源、
不落盘或识别态 no-INET 证据。

另一条非发布入口是 `RimeAIVoicePerformanceTracer.bundle`。bundle builder 重验上述
sealed artifact，并将 exact path/ID/content SHA-256、runtime/release/driver/measurement policies
与三个子进程身份放入 Developer ID 资源封印。外层是无 executable 的
resource-only `BNDL`，不带 hardened-runtime flag；collector、driver、helper 三个
nested App 均带 Developer ID、trusted timestamp 和 hardened runtime，无 entitlement。
builder receipt 的 `measurement_policy_file_sha256` 是原始文件 SHA，
`measurement_policy_canonical_sha256` 才是带域分隔的 policy 权威摘要；控制
协议/result 里的 `measurement_policy_sha256` 指后者。具体摘要由当次 receipt
与 result 绑定，不在 intake 合同中维护一次性运行值。

真实 trial 的 collector 先启动/验证/恢复 driver，driver 再为该 trial 启动一个
suspended fresh helper，collector 验证 helper 后才恢复。九帧 canonical 链为
`collector→driver challenge → collector→helper challenge → driver→collector driver_hello →
helper→collector helper_hello(engine_state=unloaded) → driver→collector arm_cold_load → collector→helper load_engine →
helper→collector load_started → collector→helper load_started_ack → helper→collector load_ready`。
helper 在 ack 前不得进入
native load；collector 使用同一连续时钟在 ack 发送前与 ready 校验后取点，并要求
helper 与 driver 都成功退出/回收后才原子发布结果。监督器把
`waitid(...WNOWAIT)=running → proc_pid_rusage=nil → waitid 暂仍 running` 识别为
direct-child exit-pending race：未 reap 的 child anchor 阻止 PID 复用，随后以 10 ms
有界轮询到 terminal 或 phase deadline；不同 live generation 仍立即 fail-closed。
合法 result 仍只是一次 process-cold 诊断，不声称 OS 文件缓存已清空，也不替代
完整 schema-3 corpus/资源/键盘/late-challenge evidence。

这个 independent-inode snapshot 边界修复了 `/dev/fd` 重复 open 共享 EOF offset 的
问题。runtime 在 recognizer 调用前后通过 held directory fd 和 pathname rebind 复验
snapshot 目录/文件的 dev/inode/owner/nlink/mode/size/SHA-256，并重验 artifact root；
snapshot parent/directory/files、source tree 与 artifact root 在初次验证和后验
rebind 中都重新执行严格 no-ACL 检查。
目录 rename/替换回归确认模型读取后移走目录时，重复 open 捕获的仍是
原 snapshot bytes，但 namespace drift 被后验拒绝。snapshot 路径只服务当次
recognizer 构造，不写入 manifest/policy/result，并在身份重验后清理。当前
sealed Zipformer cohort 可以通过这条 exact 路径执行真实 tracer recognizer
构造，但不能推广到任意模型、schema-3 产品采集或 external-data 布局；重复
通过也不是模型质量/release evidence。当前 manifest 不
支持未入 inventory 的 external-data 文件。

clone/copy 创建 exclusive 名字时立即建立失败清理责任，并在 pathname reopen 前
绑定 dev/inode；此后只清理匹配 identity 的条目。reopen 注入 `EMFILE` 时必须
fail-closed；snapshot directory-open 与 materialized file-reopen 两类回归均为零残留，
且 source bytes/link count 不变。包含祖先、ACL、
namespace 与 `EMFILE` 场景的回归仍须在恢复 clean build 后重跑。

这个设计可在 native 调用后检测篡改，但无法阻止 hostile same-UID 进程在
“前验完成→ORT open pathname”间 rename/替换 snapshot 后让替换字节先进入 native
parser，也无法阻止对 owner-owned bytes 的 `chmod` 或原地改写。后验可拒绝结果，
但不能撤销 parser 已读取的字节。当前威胁模型不声称覆盖任意同 UID 恶意
进程；长期需要上游 fd/buffer/`pread` loader API，或对冻结 cohort 维护受审补丁。

RimeAI-owned `RimeAISherpaOnnxSafeC` C++ `noexcept` shim 现在覆盖 backend 的全部
16 个 Sherpa C API 调用，将当前线程上同步逸出的 `std::bad_alloc`、其他
`std::exception` 与 unknown exception 转为固定 typed status，不泄露 `what()`、路径或
第三方库内部文本。非法 ONNX 永久回归已从 `SIGABRT` 变为
`recognizerInitializationFailed`。该 shim 不能捕获 `abort()`、`exit()`、signal 或另一
线程上的 `terminate`，所以这个边界仍不能描述为“所有坏模型都能变成 Swift
`throw`”。生产安全边界仍要求在 shim 前以默认空的 trusted catalog、精确
artifact/content/file checksum、快照与严格路径/权限/inventory 阻止未批准 cohort；
Release policy 读取前还会以 exact helper identifier、Developer ID Team/OID requirement
复验 bundle resource seal。若原生层仍终止，则必须退出并重新启动独立 helper
恢复，不能原进程重试、自动切模型或回退 Apple/cloud。

## Model 候选冻结

### 中英流式 Zipformer（只允许评测）

- archive：
  `sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2`
- archive bytes：`511,274,346`
- upstream SHA-256：
  `27ffbd9ee24ad186d99acc2f6354d7992b27bcab490812510665fa8f9389c5f8`
- 官方 checksum：
  <https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/checksum.txt>
- 官方使用文档：
  <https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html>
- 上游 model card：
  <https://huggingface.co/csukuangfj/k2fsa-zipformer-chinese-english-mixed>

上游文档将模型描述为社区贡献，并说明它训练于数万小时的某内部数据集。model
card 的 `apache-2.0` 标签不足以单独证明训练数据处理权、权重再分发权以及这个
archive 与不可变源 revision 的一一对应。因此：

- 不得把它加入 `VoiceASRTrustedArtifactCatalog.production`；
- 不得把再分发批准或审核结论写入 manifest；schema v2 会拒绝旧审批键；
- 不得将 archive、解包权重或派生 `bpe.vocab` 放入 Release 包；
- 只有在来源方/法务补齐数据权利、权重许可、不可变 revision 映射及 NOTICE 后，
  才能重新评审。

官方 int8 示例的实际组合是 int8 encoder、fp32 decoder、int8 joiner 和
`tokens.txt`，不能把 decoder 误标为 int8。中英热词还需要从 archive 的
`bpe.model` 通过固定脚本 revision 生成并冻结 `bpe.vocab`。archive 和解包
权重仍不进入仓库，但已完成的外部受控 evaluation intake 现在已固定并验证
7 个 inventory 文件的 exact 字节数/SHA-256，生成 schema-v2 manifest 与本文结论中的
seal receipt。这些值只适用于该 evaluation cohort，不表示来源/权利审核已完成。

### 中英流式 Paraformer（只允许评测）

- archive：
  `sherpa-onnx-streaming-paraformer-bilingual-zh-en.tar.bz2`
- archive bytes：`1,047,319,737`
- 上游 SHA-256：
  `5462a1fce42693deae572af1e8c4687124b12aa85fe61ff4d3168bb5280e205f`
- 官方 checksum：
  <https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/checksum.txt>
- 官方使用文档：
  <https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-paraformer/paraformer-models.html>
- 上游来源 model（ModelScope）：
  <https://www.modelscope.cn/models/damo/speech_paraformer_asr_nat-zh-cn-16k-common-vocab8404-online/summary>
- staged 组合遵循上游 real-time 示例：int8 encoder + int8 decoder + tokens，
  合计 `237,202,501` bytes；archive 内 fp32 encoder/decoder（607MB/218MB）
  只被审计、永不入 cohort：
  - `model/encoder.onnx` ← `encoder.int8.onnx`
    （`165,462,184` bytes，SHA-256
    `81a70226a8934e6ed92aa1d4fc486b428b5398e2f2619ed4897b7294cab90e9a`）
  - `model/decoder.onnx` ← `decoder.int8.onnx`
    （`71,664,561` bytes，SHA-256
    `f3cca9f77bb9d93c8fcbfb63ae617b6b1ee96818df3aa3b151c40658fe38594f`）
  - `model/tokens.txt` ← `tokens.txt`
    （`75,756` bytes，SHA-256
    `59aba8873a2ed1e122c25fee421e25f283b63290efbde85c1f01a853d83cb6e6`）
- 2026-10-13 受控封印回执（`--cohort paraformer-bilingual-zh-en`）：
  - artifactID
    `sherpa-onnx-streaming-paraformer-bilingual-zh-en-eval-5462a1fc`
  - content SHA-256
    `8fee261caf0ca6bc4cd733166e6b8d856b35f4ab8308dfb1dd3e1d66b3ffe7eb`
  - 5 个 inventory 文件、`237,214,088` bytes payload（model 237,202,501
    + Apache-2.0 LICENSE 11,358 + 评测 NOTICE 229）。
- 与 Zipformer cohort 的差异：runtime kind 为
  `sherpa-onnx-online-paraformer`（modeling unit `cjkchar`、greedy 解码、
  无 joiner/BPE），流式 Paraformer 不支持热词，manifest 必须声明
  `hotword_mode: "unsupported"` 与 `maximum_hotwords: 0`。
- 该模型由 ModelScope `speech_paraformer...vocab8404-online` 转换而来；
  训练数据权利、权重再分发权与不可变源 revision 映射未完成审核。因此与
  Zipformer cohort 相同：只允许进入受控 V0 评测（A/B 对比与冷加载 tracer），
  不得进入生产受信 catalog、Release 包或自动下载路径。

### 中文 2025 int8（拒绝作为替代发布候选）

`sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30` archive 的已知大小为
`132,634,597` bytes，SHA-256 为
`5a2832047ea1f97dd0dc595b816c230c4bafad65cfc0341fa57517cadc50afd0`。
其源 model card 受限且没有足够的权重许可材料，同时也不满足 V1 技术英文混输
目标；不能用 icefall 代码仓库的 Apache-2.0 许可证推导模型权重可分发。

## 受控 production intake 门

上述 evaluation intake/seal/tracer 已完成，但它没有改变 production catalog 为空的
事实。只有在模型来源门解除后，下一轮 production model intake 才可以：

1. 在隔离临时目录下载固定 model URL 并核对 archive bytes、SHA-256 与不可变
   source revision；runtime 继续由本文件记录的两个 direct binary target 精确固定；
2. 拒绝符号链接、特殊文件、AppleDouble、扩展 ACL、额外文件和路径穿越；
3. 生成固定 encoder/decoder/joiner/tokens/BPE inventory 和严格 manifest；
4. 把来源、许可证/NOTICE、显式再分发决定，以及
   `sourceReviewID`、`modelRightsReviewID`、`redistributionReviewID`、
   `qualityReportSHA256` 编译进独立的 trusted catalog v2；其中质量摘要必须是
   [`VOICE_EVAL_FORMAT.md`](VOICE_EVAL_FORMAT.md) 定义的 schema v2
   `quality_report_sha256`，不是任意报告文件哈希。四项 evidence 与 approval 其余
   字段全部进入 canonical SHA-256；把 approval 编译进产品前，发布流程还必须重算
   摘要、确认 `quality_gate_pass == true` 并核对产品制品 provenance。Swift catalog
   本身只校验 64 位小写十六进制形状，不会读取质量报告；
5. 通过 offline publisher 发布到不可变 `releases/<artifact-id>`，再在 Store
   selector 锁内重验并完成 backend load probe；
6. 跑至少 200 句授权、说话人隔离的 V0 corpus，以及 TCC、no-INET、不落盘、
   资源、Developer ID、公证和清洁机矩阵。

第 6 步的资源证据必须是与正式 corpus/run 和产品三进程绑定的完整
performance sidecar schema v3。当前 schema-2 tracer result 只有 fresh-helper 冷加载因果链，
`qualification=tracer` 且 `authenticated_production_driver=false`；它不能替代该 sidecar、
gates 或 `VoiceASRReleaseEvidence`。重复 real-model tracer runs 也不改变这一资格边界。

任何 intake 失败都必须保持 helper 产品引擎不可用；不得自动回退到 Apple
probe，也不得在运行时联网下载或修复模型。
