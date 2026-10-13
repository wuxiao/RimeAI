# 语音 ASR 第二模型（Paraformer）intake 与切换实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `sherpa-onnx-streaming-paraformer-bilingual-zh-en` 作为第二个冻结评测 cohort 走通 intake → seal → V0 评测全链路，与现有 Zipformer cohort 可 A/B 对比、可经既有 Store selector 切换；生产信任目录保持为空。

**Architecture:** 全部复用现有单 cohort 管线，只做"第二 cohort"的参数化：manifest schema 增加 paraformer kind、backend 按 kind 分支构建 recognizer config、Python intake 与 sealer 各增加一个冻结 cohort 注册项。不新增 UI、不新增下载器、不动运行时二进制、不改信任模型——生产切换的唯一未来变更仍是往 `VoiceASRTrustedArtifactCatalog.production` 里插入一条审批常量（权利审批通过后）。

**Tech Stack:** Swift / SwiftPM（既有 6 个相关 target + tests/），Python（`rimeai_eval/voice_artifact_intake.py` + pytest），sherpa-onnx 1.13.6 静态 XCFramework（已钉死，C API 已暴露 `SherpaOnnxOnlineParaformerModelConfig`，SafeC shim 传整个 config 结构体，无需改 shim）。

**Spec:**
- `docs/VOICE_ASR_RUNTIME_INTAKE.md`（冻结 cohort 与 intake 合同，权威）
- `docs/VOICE_ASR_ARTIFACT.md`（制品/selector 合同）
- `docs/VOICE_EVAL_FORMAT.md`（评测 plan/observation 格式）
- `docs/VOICE_INPUT_DESIGN.md`（V2 协议；热词为可选能力）

## Global Constraints

- Fail-closed 不变：无运行时联网、无运行时下载；`VoiceASRTrustedArtifactCatalog.production` 保持 `approvals: []`（`Sources/RimeAIInputCore/VoiceASRArtifactPublisher.swift:281`）。
- 运行时二进制不动：sherpa-onnx `1.13.6`（embedded rev `0fdffb3e`）、ONNX Runtime `1.27.1`。
- 现有 Zipformer cohort 的 artifactID `...-eval-27ffbd9e`、frozen digests、sealed bytes 一律不改。
- Manifest schema v2 限额不变：manifest ≤ 1 MiB、文件数 ≤ 512、总字节 ≤ 2 GiB、JSON 深度 ≤ 32。
- Paraformer 流式不支持热词：manifest 声明 `hotword_mode: "unsupported"`、`maximum_hotwords: 0`；V2 协议热词是可选能力，`voice_ready` 不声明即合法。
- Paraformer 状态与 Zipformer 相同：**只允许评测**，权利/再分发审批未完成，不进 Release 包。
- 每个任务独立可测、独立提交；测试命令为 `swift test`（SwiftPM）与 `pytest`。

## Review Focus

1. **kind/modelType 交叉错配**（如 `sherpa-onnx-online-paraformer` + `zipformer`）：manifest 校验必须拒绝，不能只靠 enum 解码成功就放行 → Task 1 测试钉住。
2. **热词发给不支持热词的引擎**：`dictation_start` 带非空热词快照 + paraformer 引擎必须 fail-closed 报错，不能静默忽略或崩溃 → Task 2 测试钉住。
3. **Zipformer 回归**：现有全部测试（manifest/backend/sealer/eval driver）不修改断言即须通过；`joinerPath`/`bpeVocabularyPath` 迁移为 `String?` 后的编译波及要全部落在 Task 1/2 内 → Task 1、2 全量 `swift test`。
4. **Sealer cohort 混淆**：拿 Zipformer 目录用 `--cohort paraformer...` 封印（或反之）必须因 payload digest 不匹配 fail-closed → Task 4 测试钉住。
5. **上游 archive 字节漂移**：intake 对 paraformer archive 的 sha256/bytes 校验失败路径必须与 zipformer 同样严格 → Task 3 测试用篡改字节钉住。

---

### Task 1: Manifest schema 支持 paraformer kind

**Files:**
- Modify: `Sources/RimeAIVoiceArtifactCore/VoiceASRArtifactManifest.swift`
- Test: `tests/RimeAIInputCoreTests/VoiceASRArtifactManifestTests.swift`、`tests/RimeAIVoiceArtifactCoreTests/VoiceASRArtifactCoreTests.swift`

**Interfaces:**
- Produces: `Runtime.Kind.sherpaOnnxOnlineParaformer`（raw value `"sherpa-onnx-online-paraformer"`）、`ModelType.paraformer`（`"paraformer"`）；`Runtime.joinerPath: String?`、`Runtime.bpeVocabularyPath: String?`（原为非可选，编码时 zipformer 仍写出、paraformer 省略）；`encoderPath`/`decoderPath`/`tokensPath` 两种 kind 都必需。
- Produces（校验规则，`decode/validate` 内实现）:
  - kind ⇔ modelType 一一对应：transducer↔zipformer、paraformer↔paraformer，其余组合拒绝；
  - transducer：5 路径全非 nil、`hotwordMode == .boundedPhraseList`、`maximumHotwords ∈ 1...128`（现状不变）；
  - paraformer：`joinerPath == nil && bpeVocabularyPath == nil`、encoder/decoder/tokens 非空且在 inventory、`hotwordMode == .unsupported`、`maximumHotwords == 0`；
  - 路径后缀规则不变（`.onnx`/`.txt`/`.vocab`）。

- [ ] **Step 1: 写失败测试**（加进两个既有测试文件，复用其现有 manifest fixture 构造器）：
  - `test_paraformerManifestDecodes`：合法 paraformer manifest（kind/modelType/3 路径/`maximum_hotwords: 0`/`hotword_mode: "unsupported"`）解码并通过 validate；
  - `test_paraformerManifestRejectsJoinerPath`：paraformer manifest 多带 `joiner_path` → validate 抛错；
  - `test_kindModelTypeMismatchRejected`：paraformer kind + `model_type: "zipformer"` → 抛错；
  - `test_paraformerRejectsBoundedHotwords`：paraformer + `hotword_mode: "bounded-phrase-list"` → 抛错；
  - `test_transducerStillRequiresFivePaths`：transducer 缺 `joiner_path` → 抛错（锁回归）。
- [ ] **Step 2: 运行确认失败**：`swift test --filter VoiceASRArtifactManifestTests` → 新用例 FAIL（enum 无该 case）。
- [ ] **Step 3: 实现**：按上述 Interfaces 改 `Kind`/`ModelType` 枚举（`:583-602`）、strict decoder（`:659-677`，`joiner_path`/`bpe_vocabulary_path` 改 `decodeIfPresent`）、cohort 形状 guard（`:1167-1172`）、热词校验（`:1207-1214`、`:1287-1310` 改为按 kind 分支）。`unsupported` 分支 `:1207-1211` 已存在，接通即可。
- [ ] **Step 4: 全量跑**：`swift test` → 全绿（backend/sealer 因可选化产生的编译错误先最小修复——只解包不改逻辑，逻辑分支归 Task 2/4）。
- [ ] **Step 5: Commit**：`git add -A && git commit -m "feat(voice): manifest schema accepts sherpa-onnx online paraformer kind"`

### Task 2: Backend 按 kind 构建 recognizer

**Files:**
- Modify: `Sources/RimeAIVoiceHelper/Engine/SherpaOnnxProductBackend.swift`
- Test: `tests/RimeAIVoiceHelperEngineTests/SherpaOnnxProductBackendTests.swift`；如 `tests/RimeAIVoicePerformanceHelperBridgeTests/SherpaOnnxEvaluationVoiceEngineFactoryTests.swift` 有 kind 钉死断言则同步更新。

**Interfaces:**
- Consumes: Task 1 的 `Kind.sherpaOnnxOnlineParaformer`、可选 `joinerPath`/`bpeVocabularyPath`。
- Produces: `SherpaOnnxProductBackendLoader.validateProductContract` 同时接受两种 kind（`:321-332`）；`makeRecognizer`（`:1581-1659`）按 kind 分支——paraformer 设 `config.model_config.paraformer.encoder/decoder` + `config.model_config.tokens`，不设 `hotwords_score`；snapshot 路径槽位（`:1284-1295`）由"固定 5 槽"改为按 kind 的角色化路径列表（transducer 5 条：encoder/decoder/joiner/tokens/bpe；paraformer 3 条：encoder/decoder/tokens），逐文件独立 inode snapshot 与复验逻辑不变；热词 load probe（`:257-288`）在 `hotwordMode == .unsupported` 时只执行 fresh empty-stream probe，跳过非空热词 probe；`startSession(hotwords:)`（`:1703-1720`）在 unsupported kind 收到非空热词时抛 `SherpaOnnxProductBackendError.hotwordsUnsupported`（新 case）。

- [ ] **Step 1: 写失败测试**（用现有 fake runtime/fixture）：
  - `test_paraformerConfigBuilds`：paraformer manifest 产出的 config 中 `model_config.paraformer.encoder/decoder/tokens` 被赋值、`transducer.*` 为空；
  - `test_paraformerSnapshotUsesThreeFiles`：runtime snapshot 只 clone/rebind 3 个文件；
  - `test_paraformerLoadProbeSkipsHotwordProbe`：load probe 不触发 `CreateOnlineStreamWithHotwords`；
  - `test_paraformerRejectsHotwordSnapshot`：`startSession(hotwords: ["RIMEAI"])` → 抛 `hotwordsUnsupported`；
  - `test_transducerConfigUnchanged`：现有 zipformer fixture 的 config 断言不变且通过。
- [ ] **Step 2: 确认失败**：`swift test --filter SherpaOnnxProductBackendTests` → 新用例 FAIL。
- [ ] **Step 3: 实现**：按 Interfaces 分支；真实 paraformer 模型字节加载留待 Task 6 的真机 tracer 验证，本任务测试全部走 fake。
- [ ] **Step 4: 全量跑**：`swift test` → 全绿。
- [ ] **Step 5: Commit**：`git commit -am "feat(voice): backend loads sherpa-onnx online paraformer artifacts"`

### Task 3: Python intake 支持 cohort 参数

**Files:**
- Modify: `rimeai_eval/voice_artifact_intake.py`
- Test: `tests/test_voice_artifact_intake.py`

**Interfaces:**
- Produces: 模块内 `@dataclass(frozen=True) class FrozenCohort`（字段：`archive_url: str`、`archive_bytes: int`、`archive_sha256: str`、`archive_root: str`、`members: tuple[tuple[str, str, int], ...]`——(archive member, staged path, max bytes)）；`def frozen_cohort(name: str) -> FrozenCohort`，`name ∈ {"zipformer-bilingual-zh-en", "paraformer-bilingual-zh-en"}`，未知名抛 `ValueError`。现有模块级 `FROZEN_ARCHIVE_*` 常量与默认行为保留为 zipformer 项（既有调用方零改动）。staging 校验逻辑（双次 sha256、member allowlist、逐文件上限）按 cohort 数据驱动，不改语义。

- [ ] **Step 1: 写失败测试**：
  - `test_frozen_cohort_registry`：两个名字可取、未知名抛错、zipformer 项的 URL/bytes/sha256 与旧常量逐字相等；
  - `test_paraformer_member_allowlist_enforced`：构造含越界 member 的假 archive（复用现有测试的造包工具）→ 拒绝；
  - `test_tampered_paraformer_archive_rejected`：篡改字节 → sha256 校验失败。
- [ ] **Step 2: 确认失败**：`pytest tests/test_voice_artifact_intake.py -q` → 新用例 FAIL。
- [ ] **Step 3: 实现**：按 Interfaces 重构常量为注册表；paraformer 项的 URL/bytes/sha256/member 名单**此步先留占位空串/空元组并在 docstring 标注"Task 4 冻结后回填"**，仅测试跳过数据校验（registry 与执行语义仍被测）。注意：占位仅允许存在于本任务提交，Task 4 必须消除。
- [ ] **Step 4: 跑**：`pytest tests/test_voice_artifact_intake.py -q` → 全绿。
- [ ] **Step 5: Commit**：`git commit -am "feat(voice): parameterize artifact intake by frozen cohort"`

### Task 4: 冻结 Paraformer archive 输入并回填常量

**Files:**
- Modify: `rimeai_eval/voice_artifact_intake.py`（回填 Task 3 占位）
- Modify: `docs/VOICE_ASR_RUNTIME_INTAKE.md`（新增"### 中英流式 Paraformer（只允许评测）"小节，镜像现有 Zipformer 小节格式：archive URL/bytes/SHA-256、上游 checksum 链接、model card 链接、权利结论）

无新增测试代码；验证即核对动作。

- [ ] **Step 1: 下载并核对 archive**：从 `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/` 下载 `sherpa-onnx-streaming-paraformer-bilingual-zh-en-2023-03-09.tar.bz2`（确切文件名以同 release 的 `checksum.txt` 为准），比对官方 SHA-256 与字节数。
- [ ] **Step 2: 列 member 并定名单**：`tar tjf` 列出成员，确定 fp32 组合（`encoder*.onnx`/`decoder*.onnx`/`tokens.txt`，仿 zipformer cohort 用 fp32）映射到 staged `model/encoder.onnx`、`model/decoder.onnx`、`model/tokens.txt`；另取 LICENSE 类文件入 `licenses/`。记录每个文件 SHA-256。
- [ ] **Step 3: 回填常量**：将 Step 1/2 的值写入 `FrozenCohort` paraformer 项，删除占位与 docstring 标注。
- [ ] **Step 4: 验证 intake**：按 `tests/test_voice_artifact_intake.py` 中既有调用方式对真实 archive 跑一次 staging → 成功产出 `licenses/`+`model/{encoder.onnx,decoder.onnx,tokens.txt}`。
- [ ] **Step 5: 写文档并提交**：`git commit -am "feat(voice): freeze paraformer bilingual zh-en evaluation archive inputs"`

### Task 5: Sealer 支持第二 cohort

**Files:**
- Modify: `Sources/RimeAIVoiceEvaluationArtifactSealer/VoiceEvaluationArtifactSealer.swift`、`Sources/RimeAIVoiceEvaluationArtifactSealer/VoiceEvaluationArtifactSealerCLI.swift`
- Test: `tests/RimeAIVoiceEvaluationArtifactSealerTests/VoiceEvaluationArtifactSealerTests.swift`、`tests/RimeAIVoiceEvaluationArtifactSealerTests/VoiceEvaluationArtifactSealerCLITests.swift`

**Interfaces:**
- Consumes: Task 1 的 manifest paraformer 编码。
- Produces: `VoiceEvaluationArtifactCohort` 从"单一冻结常量组"改为注册表：`static let zipformerBilingualZhEn2023`（值与现有 `:6-67` 逐字节相同）+ `static let paraformerBilingualZhEn`（artifactID `sherpa-onnx-streaming-paraformer-bilingual-zh-en-2023-03-09-eval-<content8>`、payloadPaths `licenses/* + model/{encoder.onnx,decoder.onnx,tokens.txt}`、frozenPayloads 取 Task 4 Step 2 记录的逐文件 SHA-256/bytes、无 hotwordProbePhrase）；`init(cohort:)` 替代隐式钉死。CLI argv 变为 `--artifact-dir <path> [--cohort zipformer-bilingual-zh-en|paraformer-bilingual-zh-en]`，默认 zipformer（既有脚本零改动）。目录形状、NOTICE 逐字节、manifest 生成的 kind/路径/`maximum_hotwords: 0`/`hotword_mode: "unsupported"` 全部按 cohort 数据分支。

- [ ] **Step 1: 写失败测试**：
  - `test_sealsSyntheticSecondCohort`：用测试本地构造的第二 cohort fixture（小假文件 + 冻结 digest）封印成功，manifest 断言 paraformer 字段；
  - `test_cohortDirShapeMismatchFails`：zipformer 形状目录 + paraformer cohort → `payloadDoesNotMatchFrozenCohort`；
  - `test_cliDefaultCohortIsZipformer`：不带 `--cohort` 的 argv 行为与现状逐字节一致；
  - `test_cliUnknownCohortUsageError`：未知 cohort → exit 64。
- [ ] **Step 2: 确认失败**：`swift test --filter VoiceEvaluationArtifactSealer` → FAIL。
- [ ] **Step 3: 实现**：按 Interfaces 重构；manifest 生成处（`:849-878`）按 cohort 输出 runtime 块。真实 paraformer 常量先以 Task 4 记录值写入。
- [ ] **Step 4: 全量跑**：`swift test` → 全绿。
- [ ] **Step 5: 执行真封印**：`swift run <sealer 可执行 target，名字见 Package.swift:68-102> --artifact-dir <Task 4 staging> --cohort paraformer-bilingual-zh-en` → stdout 出 receipt（artifact_id/content_sha256/file_count/bytes），exit 0。
- [ ] **Step 6: 记录并提交**：receipt 五项值补进 `docs/VOICE_ASR_RUNTIME_INTAKE.md` paraformer 小节；`git commit -am "feat(voice): seal paraformer bilingual zh-en evaluation artifact"`

### Task 6: V0 A/B 评测与冷加载 tracer

**Files:**
- Create: 两份 eval plan JSON（owner-only，仓库外或按现有 plan 存放约定；schema 见 `docs/VOICE_EVAL_FORMAT.md` 与 `Sources/RimeAIVoiceEvaluationDriver/VoiceEvaluationPlan.swift:30-43`）
- Create: `docs/baselines/` 下 A/B 结果记录（遵循该目录现有命名惯例）
- Modify（仅当钉死）: `Sources/RimeAIVoicePerformanceTracerBundleBuilder/DarwinVoicePerformanceTracerBundleDependencies.swift` 若其硬钉 zipformer artifactID，则同样改为引用 Task 5 的 cohort 注册表

**Interfaces:**
- Consumes: Task 5 的两个 sealed artifact 目录；既有 `rimeai-voice-eval-driver --plan` 与 tracer bundle/collector 流程。
- Produces: 两 cohort 在同一冻结 WAV 语料上的 CER 对比记录 + paraformer 九帧 schema-2 冷加载 tracer result。此记录是后续"哪个 cohort 先走权利审批"的决策输入，**不是** release evidence。

- [ ] **Step 1: 定语料**：复用现有 Zipformer V0/tracer 用过的冻结 WAV 集（在既有 plan/记录中定位）；若尚无成套语料，录制 ≥20 段中文短句（含中英混说 3 段）为决策探针语料并在记录中明确"非放行语料"。
- [ ] **Step 2: 写两份 plan**：同语料、同 policy（`evaluation_replay`/`push-to-talk`/`zh-CN`/无热词），仅 `artifactDirectory` 与 `artifact.*` 不同；paraformer plan 不得带 `hotwordSnapshot`。
- [ ] **Step 3: 跑两 cohort**：各执行 `rimeai-voice-eval-driver --plan <plan>` → 校验 observation 输出含各自 engine_id（`sherpa-onnx@<content_sha256 前 16 位>`）。
- [ ] **Step 4: 跑 paraformer tracer**：按现有 zipformer tracer 流程产出九帧 schema-2 result（`qualification=tracer`）；如 bundle builder 钉死 cohort，先按本任务 Files 说明参数化（+ 对应单测）再跑。
- [ ] **Step 5: 写 baseline 记录并提交**：CER 对比、冷加载耗时、决策建议；`git commit -am "docs(voice): paraformer vs zipformer V0 evaluation baseline"`
