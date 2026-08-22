# RimeAI

RimeAI 是基于 Rime 的本地优先语义输入引擎。当前仓库已经完成 P0
离线验证，并实现 P1/P2-internal 的 macOS 输入法、用户级本地 daemon、隐私
控制中心和可恢复安装生命周期。原型已通过自动测试、Apple Development
签名构建、Developer ID hardened-runtime 签名、用户级安装及 LaunchAgent
运行验证；TextEdit 真实输入路径已验证。macOS 输入法已改为受控静态 librime，
daemon 已改为 Developer ID 签名、自包含的 INT8 ONNX Runtime，并以经过冻结集
验证的 24M 神经排序器与 n-gram 融合作为主排序层。公证、完整宿主矩阵和公开
分发法律审查仍未放行。macOS 另有用户主动配置 API Key 后才启用的阿里云
Qwen 增强路径；它与始终无 INET socket 的本地 daemon 是两个独立进程。

仓库另含一个独立的 iOS 内部可行性工程，用于验证宿主 App、离线自定义键盘
扩展和 TestFlight 发布链路。该工程已接入受控构建的原生 librime 1.17.0、
预编译 Rime 数据、候选 UI，以及精确复现冻结 P0 字符 n-gram 评分的只读本地
排序器。iOS 尚未接入规划中的 24M 神经排序器，也尚未完成真机内存和宿主应用
矩阵；它不改变 macOS 首发范围，也不代表 iOS 产品已完成。

产品和技术设计权威见 [DESIGN.md](DESIGN.md)；冻结实验数字与哈希见
[P0_EVIDENCE.md](docs/P0_EVIDENCE.md)，实现证据与外部阻塞见
[P1_IMPLEMENTATION_EVIDENCE.md](docs/P1_IMPLEMENTATION_EVIDENCE.md)，24M 神经
排序器与 11–30 字扩展结果见
[P3_NEURAL_RANKER_EVIDENCE.md](docs/P3_NEURAL_RANKER_EVIDENCE.md)，量化与发布
制品证据见 [P4_RELEASE_EVIDENCE.md](docs/P4_RELEASE_EVIDENCE.md)。

## 当前状态

| 能力 | 状态 |
|---|---|
| 真实 librime Top-20 候选采集 | 已实现，librime 1.17.0 |
| 10,000 条通用/开发冻结数据 | 已实现，文档级 80/10/10 切分 |
| 候选排序质量门 | 浮点 raw 95.69%；INT8 ONNX 0.90 产品门 94.55%，高于浮点产品门 94.42% |
| 候选排序性能门 | INT8 ONNX CPU P50/P95 15.17/42.70ms，冷启动 119.49ms |
| 4,000 条长输入冻结数据 | 已实现，目标文本长度 6 至 10 个汉字 |
| 1,600 条扩展长输入冻结数据 | 已实现，目标文本真实覆盖 11 至 30 个汉字 |
| 长输入整句质量门 | 0.97 阈值下已通过：6–10 字相对提升 44.09%，11–30 字提升 38.46% |
| 长输入性能门 | 11–30 字 P95 14.71ms；超长或不完整拼音显式弃权 |
| GTE 306M 重排实验 | 已否决：质量与延迟均不达标 |
| Qwen2.5 0.5B 整句实验 | 已否决：难例无修复且远超延迟预算 |
| macOS 输入法、daemon、设置中心 | 已实现简/繁、全/半角、中文/西文标点与 AI 隐私设置；输入法无 Homebrew 运行依赖 |
| iOS 离线 librime 候选键盘 | 模拟器引擎与系统键盘 UI 测试通过；真机待验 |
| 本地语义结论展示 | macOS 显式展示分析中、上下文用量、首选一致、完整候选不足、低置信度、长输入拒答、回退或可选候选 |
| 无空格中英混输 | 连续键流按拼音/ASCII 分段；大写缩写、内置技术词和本地学到的英文词原样保留，纯拼音串保留原链路，Tab 接受独立混输建议；大小写真实 librime 样例已覆盖 |
| iOS 过渡语义排序 | 冻结 P0 字符 n-gram 已以只读紧凑制品接入；24M 神经排序器未接入 |
| 用户级后台生命周期 | LaunchAgent、按需启停、崩溃重启、失败回滚与当前用户 0700 runtime/0600 UDS（无扩展 ACL）的 fail-closed 权限门已验证 |
| 安装、升级、回滚、卸载 | daemon 自包含 release 的 v1→v3、v3→v1、再升级 v5 已验证；输入法/语音 Release 的正式安装、回滚、公证与干净机器待验 |
| Offline Lock | daemon 进程无 INET socket；公开版仍需系统级抓包矩阵 |
| 可选 Qwen 云增强 | candidate-ID-only broker、Top-50/错拼扩候选、800ms 门、cloud.env 文件 API Key（0600）已接入；真实云冻结集尚待跑 |
| 长期记忆 | 配置 API Key 后跨应用明文保存 RimeAI 上屏记录，600 字 recent + 最多 8 条 FTS/HNSW 片段；可导出、永久清除 |
| Release 制品 | 输入法成对 ZIP 约 6.4MB（内嵌独立签名语音 Helper）；daemon 归档约 69MB、安装约 120MB；均有 SHA-256 与 Developer ID 签名 |
| 语音听写（实验、默认关闭） | `⌃⇧V` 按住说话、松开 final、浮层预览、Space/回车确认、Esc/切换/SEI 取消已接入。Debug 只允许显式私有 UDS；Release 只允许双向认证 NSXPC/Mach service，认证失败不回退 UDS。V2 wire 在用户另行开启默认关闭的“Rime 会话热词辅助”后，才把当前焦点会话中用户已确认的 Rime commit 变成有界、带摘要、按引擎上限协商的易失热词快照，并在 final 后销毁原生 stream。产品模型的 manifest schema v2、Store、sherpa-onnx 1.13.6 + ORT 1.27.1 静态 runtime 和真实 C backend 已实现；Debug helper 的 `evaluation-product-managed` 与独立 V0 WAV eval driver 都可严格验证并真实加载显式候选目录，但不产生发布审批。production catalog 因模型权利/来源尚未放行而为空，正式语料结果也未产出；Apple 适配器在 macOS 14/15 仅为 probe-only。这是默认关闭的 V1 交互技术探针，真实 TCC、合格产品模型、公证与干净机器门未通过，不进入公开放行 |
| 自动化测试 | 键盘/云增强、语音协议与状态机、制品/发布策略、PCM/产品引擎、WAV→真实产品状态机的 V0 observation driver、XPC、原生性能采集器及 Python 质量门均有分层回归；各证据边界与最新可复现命令见对应设计文档，不以易过期总数代替测试输出 |
| 公开分发许可证放行 | 未完成；语音候选只有 intake 完整性记录与非发布评测入口，没有获批 production model artifact |

语音 helper 的本地模式离线边界来自 on-device 引擎门禁（本机识别不可用时
fail-closed）和当前实现不存在云 ASR/音频上传代码路径。签名中不含 network
entitlement 只是一项最小权限静态信号；helper 是非沙箱进程，仍须以运行态无
INET socket/抓包审计作为发布门。

语音 IPC 后端由不可变构建配置选择：ad-hoc Debug 使用当前用户 0700 runtime
目录中的 0600 UDS（无扩展 ACL、0177 umask）；Release 使用用户级 LaunchAgent
注册的 `fun.wwcn.rimeai.voice-helper` Mach service。Release 双端 requirement
固定 Apple generic anchor、Developer ID 中间证书/叶证书 OID、同一 Team ID 与
精确 bundle identifier，并在每次 XPC 调用再次校验有效 UID；每帧最多 64 KiB，
每个方向只有一帧在途，待发队列最多 32 帧/256 KiB。签名、UID、容量或代际门
任一失败都中止该连接，Release 不会自动降级到 UDS。

正式配置的输入法 ZIP 现在是一个原子配对制品：唯一顶层
`RimeAIInputMethod.app` 在标准 `Contents/Helpers` 位置内嵌独立签名的
`RimeAIVoiceHelper.app`，并携带签名内的 LaunchAgent 模板与 fail-closed
语音发布策略。Release LaunchAgent 只传 executable 与固定 Mach service，不能用
用户可写 argv 选择引擎；helper 在初始化模型、TCC 或 IPC server 前复验自身 exact
identifier、Developer ID Team/OID 与完整 bundle 资源封印，再严格读取 schema 2
策略。策略同时绑定 code-shipped trusted catalog v2 全字段的 canonical SHA-256，
其中包括来源审核、模型权利审核、再分发审核 ID，以及 schema v2 质量报告顶层的
`quality_report_sha256`；宿主与 helper 内副本必须逐字一致。Swift 只校验该摘要的
形状并把它纳入 catalog；首个生产 approval 前，发布流程还必须重算摘要、确认
`quality_gate_pass == true` 并逐字段核对产品制品 provenance。两端必须使用同一 Team、
相同 version/build；Release 运行时直接
执行 nested helper，不再复制第二份可漂移的可执行文件到 Application Support。
渲染后的 LaunchAgent 还绑定当前 host build 与签名 policy 文件 SHA-256；原位升级
即使路径不变、甚至误复用 build number，只要策略变化也会强制替换旧 helper
进程，避免新输入法继续复用已撤回策略的运行态。
当前策略明确记录 Apple Speech 为 `system_managed`、
`ReleaseEligible=false`，并绑定当前空 production catalog；它不会把尚未完成
模型来源、再分发与质量门的 product-managed 分支放行。

语音 V0 的 corpus、run、observations、聚合指标、隐私约束和质量门报告合同见
[`docs/VOICE_EVAL_FORMAT.md`](docs/VOICE_EVAL_FORMAT.md)。`validate-voice` 可验证
外部受控语料；`collect-voice-observations` 会把冻结 PCM16 WAV 通过真实 artifact
verifier、sherpa loader、产品流式引擎与 ServerCore 生成严格 observations；
`evaluate-voice` 只输出不含逐句原文的聚合报告。该回放在 session 前预读、哈希、
转换音频并加载模型，因此只提供候选质量/流式信号，不是 cold-load、TCC、键盘或
真机发布证据。未传 gates 时报告固定为 `measurement_only`，不得出现
`quality_gate_pass`；当前 schema-v3 performance sidecar 又固定公开
`authenticated_production_driver=false`，所以提供 gates 也只能得到
`policy_incomplete`/退出码 1，不能由 gates 或用户输入把它提升为 true。未来完整
authenticated control plane 落地后必须使用新证据 schema。即使后续质量门通过，
模型权利、TCC、运行态隐私、公证和干净机器等产品发布门仍须独立完成。仓库只
提交运行时生成的合成 WAV 测试夹具，正式授权录音与逐句转录不进入 Git。

`collect-voice-performance` 现已接通一个独立的 macOS native collector：它用
`mach_continuous_time` 和 `proc_pid_rusage(RUSAGE_INFO_V6)` 采集输入法、候选服务、
voice helper 三进程 cohort，并复验 PID generation、UID、规范路径、CDHash、exact
identifier、Team 与 Developer ID requirement；Python 只转发无文本实时边界、绑定
corpus/run/制品身份并原子写入 schema-v3 sidecar。质量 gates v2 还要求获批的
collection-protocol 摘要、冷加载/键盘/partial/final/cancel/churn/子集分母，以及
五类迟到挑战的独立最小次数；空值、零值或只有一次的稀疏证据不能再隐式冒充完整
证据。collector 自身也必须先做 Developer ID 签名再冻结 SHA-256，普通 ad-hoc
SwiftPM build 会 fail-closed。当前尚缺与真实语音回放和键盘阶段相连的受控
production driver 及真机证据，因此 pipe/合成 marker 的通过只能证明采集器合同，
不能获得 release gate 资格；Python evaluator 已把该缺口作为固定 false 写入聚合
metrics/provenance，并让 gate policy 与 performance evidence completeness fail-closed。

产品管理本地 ASR 的 manifest、逐文件 hash、目录权限、`current` / `previous`
原子 selector 与证据边界见
[`docs/VOICE_ASR_ARTIFACT.md`](docs/VOICE_ASR_ARTIFACT.md)。这层只证明本地内容
完整性，不证明来源签名、许可证、质量或 Release 资格。manifest schema v2 只
记录制品事实并拒绝 v1 与 legacy `redistribution_approved` 键；再分发决定和
`VoiceASRReleaseEvidence` 只存在于 code-shipped catalog。当前仓库没有下载或
接入任何获批产品语音模型。

已通过的自动化覆盖：9 消息编解码与状态机、真实私有 UDS 回环和 ACL/权限门、
匿名 NSXPC 回环、首个合法 `voice_hello` promotion、旧连接/旧核心 epoch 丢弃、
认证前回调拒绝、错误 UID ping、64 KiB 帧界限、单飞 FIFO/溢出/NACK，以及
安装器的 Debug/Release 传输选择、Developer ID requirement 构造、完整
`voice_ready` 解析和失败回滚。
这些测试与面向 macOS 14 SDK 的编译探针不等于真实发布验证。

直接启动 Debug helper 时，候选评测只接受 exact 形式
`--socket <path> --engine evaluation-product-managed --artifact-dir <absolute-canonical-directory>`。
该路径以严格 verifier 和真实 sherpa loader 处理
调用方明确选择的目录，但不读写产品 Store、publisher、selector 或 trusted
catalog；helper 的该 argv dispatch 由 Debug 编译条件隔离，不能出现在 Release
argv/policy 中。候选能够
被验证或加载不代表真实质量、TCC、资源、不落盘或识别态 no-INET 已通过。

独立 `rimeai-voice-eval-driver --plan <owner-only-plan>` 则是非发布的 V0 回放工具：
它可用 Release 优化构建复用同一 evaluation factory，但不嵌入输入法/helper 包，
不进入 Release helper argv/policy，也不读写产品 Store、selector 或 trusted catalog。

ad-hoc 开发安装器默认打包用于链路验证的 `apple-speech` on-device 引擎，但不创建
启用 marker、也不启动 LaunchAgent；`--engine unavailable` 仅用于显式验证不可用
故障路径。Developer ID helper 只允许 `--build-only` 并作为正式输入法 ZIP 的 nested
组件，不能再形成第二种 standalone Release 安装拓扑。该 Apple 适配器在 macOS 14/15
不满足 PRD 的产品管理资产要求，
不能因静态签名或协议测试通过而获得发布资格。是否启用语音仍由设置中心的
默认关闭开关决定。尚未完成的语音发布
门是：当前已静态验签的 Developer ID 配对 App 在安装后通过命名 Mach service
完成真实双向连接、真实 macOS 14 运行、麦克风与 Speech Recognition TCC
全流程、公证/stapling/Gatekeeper，以及清洁机器上的安装、错峰升级、回滚和
宿主/设备矩阵。

完整证据与放行边界见 [P0_EVIDENCE.md](docs/P0_EVIDENCE.md)。P0 文件中的
测试数量是当时的冻结快照；当前仓库测试数量以本轮测试输出为准。

模型决策：

- 当前 macOS 首选神经排序器：`RimeAI-Ranker-S-24M`，以
  `BAAI/bge-small-zh-v1.5` 初始化，训练为拼音感知 listwise
  Cross-Encoder。验证集选择的 0.5/0.5 神经+n-gram 融合在冻结测试集同时超过
  单独 n-gram 并满足 50ms P95 门，已经接入 macOS daemon。
- 当前 macOS 实现：INT8 ONNX 24M 融合候选排序 + 拼音约束 beam decoder；字符 n-gram
  保留为融合信号和神经运行时故障回退。daemon
  对重排、首选一致、完整候选不足、低置信度、无候选、超长和不完整候选返回
  显式决策。简体拼音从 2 个字符起进入受字典约束的整句解码，当前运行时整句
  展示门槛为 0.60。
- 当前 iOS 过渡实现：从同一冻结 P0 模型确定性导出的 11.2MiB 只读紧凑
  n-gram 制品；只处理 Rime 候选排序，不包含整句 beam decoder。
- 离线教师：`Qwen3-Reranker-0.6B`，不进入本地运行时。
- 可选云运行时只允许固定的 `glm-5.3`（`https://newapi.wwcn.fun/v1`），
  通过候选 ID 合同工作，不能自由生成上屏文本。
- `LFM2.5-Encoder-230M` 仅作为 P0 challenger。

## 架构

```text
licensed source text
        │
        ├── document-level split ──> librime candidate capture
        │                                  │
        │                                  ├── Top-10 candidate evaluation
        │                                  └── long-input evaluation
        │
        ├── 24M pinyin-aware Cross-Encoder + char n-gram ──> candidate ranking
        ├── frozen Rime dictionary + beam search ──> pinyin-safe sentence suggestion
        │
        └── optional cloud.env credential (0600)
             └── separate Qwen broker + plaintext history/FTS/HNSW
                  └── choose one existing exact/fuzzy candidate ID
```

关键产品边界：

- Rime 始终提供同步候选和故障兜底。
- 本地候选排序只处理可见 Rime Top-10，结果不能改变已显示的数字候选；云端
  内部池最多 50 条，但也只能占用一个显式建议位。
- 当前有效的语义候选出现时，用户按 `Tab` 显式采用；`Space` 始终提交 Rime
  第一候选，数字候选的位置不会因异步结果变化。
- 完整候选少于 2 个时不执行重排，并明确显示“完整候选不足”；不得把未比较
  伪装为模型同意 Rime 首选。
- 模型实际比较后仍选择 Rime 第一项时，第二行明确显示具体文本，例如
  `AI 建议：飞机（与 Rime 首选一致）`；该行只解释模型结论，不重复创建可选项。
- 长输入解码的每个字符必须由同一冻结 Rime 词典证明与原拼音一致；超过
  30 字或只覆盖部分拼音时显式拒答，不展示截断句。
- 当前运行时整句展示门槛为 0.60，仍保留 validation 选择的 beam margin 门禁；
  冻结 409 条 test 明细按外层 0.60 重算后整句准确率为 45.97%，相对 Rime
  首选提升 48.03%。真实接受率和撤销率仍需内部预览验证，因此不继续降低
  beam margin 门禁。
- 本地生成的整句必须与当前简繁设置一致；简体模式不会展示或提交繁体整句。
- 当前整句质量证据覆盖 6 至 30 个汉字；30 字仍是硬上限，不能外推为任意
  长度的续写或开放式生成。
- 命令进程超时、崩溃、协议异常或低置信度时回退 Rime。
- 聚合报告默认不包含上下文、拼音、候选或标准答案。
- 未配置 API Key 时不写长期历史、不启动云 broker；配置后会跨应用明文保存
  RimeAI 上屏文本并上传受限上下文。macOS Secure Event Input 会阻止历史写入
  与云请求。移除 Key 会停用云端但保留历史，历史必须单独永久清除。
- 本地 daemon 的 Offline Lock 是永久不变量，不代表独立云 broker 不联网。

## 仓库组成

- `rimeai_eval/`：数据校验、采集、训练、评测和本地进程协议。
- `Sources/`、`Package.swift`：真实 librime C/C++ 桥、Swift 候选服务、语音 helper、
  product-managed ASR 基础设施与独立 macOS 性能采集器。
- `tools/`：冻结数据构造和模型工作进程。
- `script/`：本地候选、排序和整句服务入口。
- `scripts/`：Rime 数据、语料、模型及干净 Python 包构建脚本。
- `models/`、`datasets/`：版本锁、来源与许可证说明；大制品位于
  `.rimeai/`，不会提交。
- `tests/`：Python 与 Swift 公共行为测试。
- `macos/`：InputMethodKit 输入法、隐私中心和 LaunchAgent 模板。
- `ios/`：原生 iOS 宿主与离线键盘扩展的内部可行性工程。
- `src/`、`public/`：产品展示站。

SwiftPM 的 `rime-candidate-service` 与 macOS App 共用
`macos/Native/RimeAIMacRuntime.xcframework`，不再链接 Homebrew librime。

## 环境

- macOS Apple Silicon。
- Python 3.9 或更高版本；训练/导出使用锁定的 `neural` 可选依赖，安装后的
  macOS daemon 自带 Python/ONNX Runtime，不依赖开发机 Python。
- Swift 6 / Xcode。
- macOS 输入法使用固定源码构建的 librime 1.17.0 arm64 静态 XCFramework，
  最低目标 macOS 14；iOS 内部工程使用独立的 iOS 17 device/Simulator 受控
  制品。正式运行包不依赖 Homebrew bottle。
- 冻结语料构造需要 `uv`；依赖版本由 `uv.lock` 固定。

## 从零重建 P0

准备 Rime 数据并构建候选服务：

```bash
scripts/bootstrap_rime_data.sh
swift build --product rime-candidate-service
```

准备固定语料：

```bash
scripts/bootstrap_corpora.sh
```

构建 10,000 条词/短语源并采集真实候选：

```bash
uv run --isolated --extra dataset python tools/build_capture_source.py \
  --wikivoyage .rimeai/corpora/zhwikivoyage-20260701-pages-articles.xml.bz2 \
  --mdn .rimeai/corpora/mdn-zh-cn-9780b8c.tar.gz \
  --essay .rimeai/rime/shared/essay.txt \
  --output .rimeai/datasets/p0-source-20260729.jsonl \
  --general-samples 5000 \
  --developer-samples 5000

python3 -m rimeai_eval capture \
  .rimeai/datasets/p0-source-20260729.jsonl \
  --candidate-config examples/librime_candidate_source.json \
  --output .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
  --provenance-output \
    .rimeai/datasets/p0-librime-1.17.0-luna-simp.provenance.json
```

训练并评测候选排序器：

```bash
python3 -m rimeai_eval train-ngram \
  .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
  --output .rimeai/models/p0-char-ngram-v1.json.gz

python3 -m rimeai_eval evaluate \
  .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
  --split test \
  --candidate-limit 10 \
  --ranker command \
  --ranker-config examples/ngram_ranker.json
```

准备并训练 24M 神经排序器，再只用 validation 选择融合权重和置信阈值：

```bash
scripts/bootstrap_bge_small_zh.sh

python3 -m rimeai_eval train-neural-ranker \
  .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
  --base-model .rimeai/models/bge-small-zh-v1.5-7999e1d \
  --base-revision 7999e1d3359715c523056ef9478215996d62a620 \
  --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
  --output .rimeai/models/rimeai-ranker-s-24m-v1 \
  --device mps

python3 -m rimeai_eval train-neural-fusion \
  .rimeai/datasets/p0-librime-1.17.0-luna-simp.jsonl \
  --neural-model .rimeai/models/rimeai-ranker-s-24m-v1 \
  --language-model .rimeai/models/p0-char-ngram-v1.json.gz \
  --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
  --output .rimeai/models/rimeai-ranker-s-24m-fusion-v1.json \
  --device cpu
```

构建长输入集、训练解码阈值并评测：

```bash
uv run --isolated --extra dataset python tools/build_long_input_source.py \
  .rimeai/datasets/p0-source-20260729.jsonl \
  --output .rimeai/datasets/p0-long-source-20260729.jsonl \
  --samples 4000

python3 -m rimeai_eval capture \
  .rimeai/datasets/p0-long-source-20260729.jsonl \
  --candidate-config examples/librime_candidate_source.json \
  --output .rimeai/datasets/p0-long-librime-1.17.0-luna-simp.jsonl \
  --provenance-output \
    .rimeai/datasets/p0-long-librime-1.17.0-luna-simp.provenance.json

uv run --isolated --extra dataset python tools/build_long_input_source.py \
  .rimeai/datasets/p0-source-20260729.jsonl \
  --output .rimeai/datasets/p0-long-11-30-source-20260813.jsonl \
  --samples 1600 \
  --minimum-target-characters 11 \
  --preferred-target-characters 30 \
  --maximum-target-characters 30

python3 -m rimeai_eval capture \
  .rimeai/datasets/p0-long-11-30-source-20260813.jsonl \
  --candidate-config examples/librime_candidate_source.json \
  --output .rimeai/datasets/p0-long-11-30-librime-1.17.0-luna-simp.jsonl \
  --provenance-output \
    .rimeai/datasets/p0-long-11-30-librime-1.17.0-luna-simp.provenance.json

python3 -m rimeai_eval train-beam-decoder \
  .rimeai/datasets/p0-long-librime-1.17.0-luna-simp.jsonl \
  .rimeai/datasets/p0-long-11-30-librime-1.17.0-luna-simp.jsonl \
  --language-model .rimeai/models/p0-char-ngram-v1.json.gz \
  --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
  --output .rimeai/models/p0-beam-sentence-v1.json

python3 -m rimeai_eval evaluate-sentence \
  .rimeai/datasets/p0-long-librime-1.17.0-luna-simp.jsonl \
  --decoder-config examples/beam_sentence_decoder.json \
  --rime-dictionary .rimeai/rime/shared/luna_pinyin.dict.yaml \
  --split test \
  --candidate-limit 10
```

## 测试与构建

```bash
python3.11 -m pytest -q
swift test
python3.11 -m compileall -q -x '(^|/)\._' \
  rimeai_eval rimeai_daemon tools
swift build --product rime-candidate-service
npm run build
scripts/build_python_package.sh /tmp/rimeai-python-dist
```

工作区位于会产生 AppleDouble `._*` 元数据的外接磁盘上。Python wheel
必须通过干净临时目录脚本构建；不要直接从工作区执行普通 `uv build`。
仓库内 `.venv` 可仅用于 `--extra release` 的冻结运行环境，不保证包含 pytest；
回归测试使用安装了 pytest 的 Python 3.11 开发解释器。

## macOS 内部预览

构建并打开设置中心：

```bash
script/build_and_run.sh --settings
```

常规输入设置也会显示在 macOS 菜单栏的 RimeAI 输入法菜单中。默认值为
`简体中文 + 半角字符 + 中文标点`；简繁转换所需的 OpenCC 配置和字典随输入法
离线打包。

安装输入法和用户级 daemon：

```bash
script/install_debug_input_method.sh
```

构建 Developer ID 签名的正式配置成对 ZIP（输入法内嵌同版本语音 Helper）：

```bash
RIMEAI_CODE_SIGN_IDENTITY='Developer ID Application: NAME (TEAMID)' \
scripts/build_macos_input_method_release.sh \
  /tmp/RimeAIInputMethod-0.1.0-macos-arm64.zip 0.1.0 26
scripts/verify_macos_input_method_release.sh \
  /tmp/RimeAIInputMethod-0.1.0-macos-arm64.zip
```

构建并安装自包含 INT8 ONNX daemon；安装器要求同名 `.sha256` 侧车文件：

```bash
RIMEAI_CODE_SIGN_IDENTITY='Developer ID Application: NAME (TEAMID)' \
scripts/build_daemon_release.sh \
  /tmp/rimeai-daemon-macos-arm64-0.1.0.tar.gz 0.1.0
script/install_release_daemon.sh \
  /tmp/rimeai-daemon-macos-arm64-0.1.0.tar.gz
script/rollback_release_daemon.sh
```

下列源码签名安装器仍是开发工具：它使用一次性隔离钥匙串，但当前走 Debug
构建，不能代替上面的 Release ZIP、认证 XPC 或公开安装/升级门：

```bash
RIMEAI_DEVELOPER_ID_CERTIFICATE=/path/to/developer-id.cer \
RIMEAI_DEVELOPER_ID_PRIVATE_KEY=/path/to/developer-id-private-key.pem \
RIMEAI_CODE_SIGN_IDENTITY='Developer ID Application: NAME (TEAMID)' \
script/install_developer_id_input_method.sh
```

默认卸载会把应用和 LaunchAgent 移到废纸篓并保留 Rime/RimeAI 数据：

```bash
script/uninstall_debug_input_method.sh
```

只有显式使用 `--trash-rimeai-data` 才会把 daemon、模型、runtime 和控制标记
移到废纸篓；`Application Support/RimeAI/Rime` 中的 Rime 用户数据始终保留。
当前本机 bundle 使用 `Developer ID Application: WEI WANG (S3T42U45P8)`、
hardened runtime 和 Apple 安全时间戳，深度签名验证通过。它尚未公证，
`spctl` 因 `Unnotarized Developer ID` 拒绝；调试安装只复制并验证输入法，
不会绕过“系统设置”自动启用。请在“键盘 → 输入源 → 编辑 → +”中添加
RimeAI。它仍不是可公开分发的安装包。

输入法 ZIP 不保留 resource fork/扩展属性，并由验证器使用普通 `unzip`
解包后检查无 AppleDouble `._*`、arm64/macOS 14、受控 librime 符号、
Developer ID hardened runtime、两端同 Team/同版本、Helper entitlement 精确
白名单、LaunchAgent authenticated-XPC 合同和
`ReleaseEligible=false`。公证脚本在提交成功后分别 staple/validate
nested helper 与外层 App，再重新生成 ZIP。

配置 Apple `notarytool` keychain profile 后，公证和 stapling 使用：

```bash
RIMEAI_NOTARY_PROFILE=rimeai-notary \
scripts/notarize_macos_input_method.sh \
  /tmp/RimeAIInputMethod-0.1.0-macos-arm64.zip \
  /tmp/RimeAIInputMethod-0.1.0-macos-arm64-notarized.zip
```

## 数据、协议与许可证

- [P0_FORMATS.md](docs/P0_FORMATS.md)：候选与整句进程协议。
- [VOICE_INPUT_DESIGN.md](docs/VOICE_INPUT_DESIGN.md)：语音听写独立
  工作流、协议与当前内部原型实现证据。
- [VOICE_ASR_ARTIFACT.md](docs/VOICE_ASR_ARTIFACT.md)：语音制品 schema v2、
  publisher/selector、Debug evaluation 与 trusted catalog v2 审批边界。
- [VOICE_ASR_RUNTIME_INTAKE.md](docs/VOICE_ASR_RUNTIME_INTAKE.md)：固定
  sherpa/ORT runtime 身份、许可证/notices 与候选模型 intake 门。
- [VOICE_IPC_SECURITY.md](docs/VOICE_IPC_SECURITY.md)：Debug 私有 UDS、Release
  双向认证 NSXPC/Mach service 的实现边界与尚未完成的真实发布验证。
- [P0_EVIDENCE.md](docs/P0_EVIDENCE.md)：冻结哈希、指标和放行决定。
- [P1_IMPLEMENTATION_EVIDENCE.md](docs/P1_IMPLEMENTATION_EVIDENCE.md)：
  输入法、daemon、隐私和安装生命周期证据。
- [ATTRIBUTION.md](datasets/ATTRIBUTION.md)：语料归因与修改说明。
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)：第三方组件清单。

当前冻结数据和模型制品混合了 CC BY-SA 与 LGPL 来源。它们可以用于本地
内部验证，但在公开打包、上传或销售前必须完成具体分发方案的法律审查、
归因、源材料提供和 ShareAlike/LGPL 合规；仓库中的清单不等于法律意见。
