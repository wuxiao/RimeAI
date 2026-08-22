# 产品管理语音 ASR runtime / model intake

本文冻结 RimeAI 在 2026-08-20 对首个 macOS 14/15 产品管理语音候选的
上游核对结果。它是后续受控构建和 V0 评测的输入，不是许可证批准、模型发布
批准或真机验收记录。

## 结论

- 静态 `sherpa-onnx 1.13.6` XCFramework 与 ONNX Runtime `1.27.1`
  XCFramework 已按上游精确 URL/checksum 作为直接 SwiftPM `binaryTarget` 接入
  helper engine；这只完成 runtime 字节固定与代码接线，不代表模型或 Release
  已获批准。
- 当前中英流式 Zipformer 模型只有官方 archive 大小和 SHA-256 完整性证据，
  训练数据权利及 archive 到不可变源 revision 的对应证据不足。它只允许进入
  受控 Debug V0 评测，不得进入生产受信 catalog、Release 包或自动下载路径。
  schema v2 manifest 不承载审批；任何 legacy `redistribution_approved` 键都会被
  拒绝，不能用 false 值把未审批候选伪装成生产合同。
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
复验权限、大小和 SHA-256，再把这些受持有的 `/dev/fd` 路径交给 runtime，创建
online recognizer/stream，并执行非空热词容量与 fresh empty-stream probe。流式路径实际调用
accept/decode/result/endpoint/finish；每个新请求创建 fresh stream，同请求的 endpoint
才调用 native reset，以免丢掉 native 尚未消费的边界音频或继承上一请求的上下文。

当前 load probe 实际包含一组非空热词容量输入与随后 fresh empty stream；这验证
配置路径能构造热词 stream 并能清空请求状态，但自动化使用 fake recognizer，不能
替代真实获批模型的 token/BPE、最大异构热词集合与设备运行证据。Release helper
还必须先通过自身签名 schema 2 policy；policy 的 catalog 摘要与 code-shipped
production catalog 不一致时，Store、native runtime 与 TCC 均不得启动。

Debug helper 的 exact evaluation 入口只接受
`--socket <path> --engine evaluation-product-managed --artifact-dir <absolute-canonical-directory>`。
它先严格验证调用方选择的 schema v2 artifact，再把
临时 lease 交给同一个真实 `SherpaOnnxProductBackendLoader`，因此可用于验证候选
和实际 native load/stream 测量；它明确绕过且不修改产品 Store、publisher、
selector 与 trusted catalog。该入口由 `#if DEBUG` 隔离，Release argv 只接受固定
Mach service，且当前签名 policy 仍选择 Apple system-managed probe、
`ReleaseEligible=false`。Debug 成功加载候选也不能生成 release approval，
更不能替代真实质量、TCC、资源、不落盘或识别态 no-INET 证据。

同一 evaluation factory 也由独立 `rimeai-voice-eval-driver` 的 Release 优化构建
复用，用于把冻结 WAV 经真实 backend/ServerCore 生成 V0 observations。`#if DEBUG`
隔离的是 helper 的 argv dispatch，不是这个非发布评测库入口；eval driver 不嵌入
输入法/helper 包、不读写 Store/selector/catalog，也不能生成 release approval。

描述符绑定消除了校验后通过路径 rename/symlink 替换模型的普通窗口，但不是对同
UID 恶意进程原地修改同一 vnode 的认证边界。正式模型 intake 还必须实证 ORT 与
token/BPE loader 对 `/dev/fd` 的重复打开、共享 offset 和 external-data 行为；当前
manifest 不支持未入 inventory 的 external-data 文件，未验证前不得加入生产 catalog。

这个边界不能被描述为“所有坏模型都能变成 Swift `throw`”。sherpa/ONNX Runtime
更深层的原生配置或模型校验可能直接终止 helper，Swift 无法在同一进程捕获。
因此生产安全边界是两层：进入 C API 前以编译进产品且默认空的 trusted catalog、
精确 artifact/content/file checksum 和严格路径/权限/inventory 阻止未经批准的
cohort；Release policy 读取前还会以 exact helper identifier、当前 Developer ID
Team/OID requirement 复验 bundle resource seal。若原生层仍终止，则必须退出并
重新启动独立 helper 恢复，不能原进程重试、自动切模型或回退 Apple/cloud。进程
隔离降低故障域，但不把未知模型变成可信输入。

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
`bpe.model` 通过固定脚本 revision 生成并冻结 `bpe.vocab`。逐文件大小和哈希
只能在受控解包后生成；本文没有下载 archive，因而不声称这些值。

### 中文 2025 int8（拒绝作为替代发布候选）

`sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30` archive 的已知大小为
`132,634,597` bytes，SHA-256 为
`5a2832047ea1f97dd0dc595b816c230c4bafad65cfc0341fa57517cadc50afd0`。
其源 model card 受限且没有足够的权重许可材料，同时也不满足 V1 技术英文混输
目标；不能用 icefall 代码仓库的 Apache-2.0 许可证推导模型权重可分发。

## 受控 intake 门

只有在模型来源门解除后，下一轮 model intake 才可以：

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

任何 intake 失败都必须保持 helper 产品引擎不可用；不得自动回退到 Apple
probe，也不得在运行时联网下载或修复模型。
