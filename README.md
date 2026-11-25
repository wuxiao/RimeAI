# RimeAI

RimeAI 是面向 Apple Silicon Mac 的 Rime 本地优先语义输入引擎。Rime 始终负责同步拼音解析与候选兜底；本地双延迟语义引擎在独立建议位提供上下文重排、零提示词拼音约束整句、段焦点回修、无空格中英混输、可检视的个人语言画像与领域词库，并内置端上离线语音听写、智能润色与语音翻译链路（端上原型 / 可选开启，默认关闭）。可选云增强仅在用户显式配置后经独立 broker 运行，所有建议采纳均遵循明确边界，绝不破坏 Rime 同步主链。

- 产品主页：[rimeai.wwcn.fun](https://rimeai.wwcn.fun/)

> 当前状态（2026-11-25）：`NOT RELEASED / INTERNAL BASELINE VERIFIED`。
> 验证口径：SwiftPM / macOS / iOS / Python / 原生与 shell 各层的 clean 命令族与最近一次记录结果见 [TECHNICAL_DESIGN.md](TECHNICAL_DESIGN.md) §1.2；产品主页（Web）以 Vite 生产构建验证（0 error / 0 warning）。以上为历史快照结果，语音工作流等并行收口中的改动以收口后的 clean 复跑为准。尚未通过签名、公证、清洁机、真实宿主/安全输入、正式语音语料与用户效果等公开发布门，详见 [TASKS.md](TASKS.md)。

## 权威文档

- [PRD.md](PRD.md)：唯一产品需求、北极星目标与放行范围。
- [PRODUCT_DESIGN.md](PRODUCT_DESIGN.md)：唯一用户流程、设置中心与交互设计。
- [TECHNICAL_DESIGN.md](TECHNICAL_DESIGN.md)：唯一总体技术设计、进程边界与当前架构。
- [TASKS.md](TASKS.md)：唯一开发任务、优先级、状态和完成条件。
- [docs/ARCHITECTURE_DIAGRAMS.md](docs/ARCHITECTURE_DIAGRAMS.md)：能力级逻辑架构图与决策时序图。

发生冲突时，当前代码和可复现测试优先于文档；文档之间按上面的职责边界解释，不再使用“旧文档由页首补丁覆盖”的维护方式。

## 核心特性（Features）

### 1. Rime 确定性主链与段焦点编辑
- **Rime 同步兜底**：Rime 数字候选即时呈现，不等待 AI，组合期间数字候选位置永不跳动。
- **段焦点模型（KBD-005 / 006 / 008）**：预编辑区按 `[前缀已定稿段][焦点段拼音][焦点字面量][后缀已定稿段]` 展示；`←`/`→` 在拼音段间移动焦点，焦点段定稿后后续段落按最新上下文自动批量重推；末段部分选词保留已选前缀在预编辑区不上屏，支持 `←` 低成本回修。
- **本地/云端双行对比**：当本地语义建议与云端建议内容不同时并排呈现，首选一致时自动合并，避免冗余干扰。

### 2. 双延迟档本地语义与零提示词约束整句
- **同步重排与 Beam（KBD-002 已证等价）**：本地 24M 拼音感知 Cross-Encoder 融合字符 n-gram 与 L2 用户语言模型对 Rime Top-10 上下文重排，同步词典约束 beam 先行给句；Debug 使用浮点 24M，Release 制品使用 INT8 ONNX（974 样本冻结集 top-1 一致率 99.38%，延迟更低）。
- **异步神经整句臂（LM-001）**：基于 `Qwen2.5-0.5B` base 的 MLX 8-bit 零提示词拼音约束解码（单一持久共享 prompt cache，词典拼音掩码强制对齐），974 样本冻结集句准确率 **92.2%**（vs Rime 基线 72.7%）、**p50 115ms**，经 `sentence_late` 帧按 latest-request-wins 接管建议位（Release 暂未打包 MLX）。
- **无空格中英混输**：连续大写英文作为强边界原样保留，小写技术词保守识别；纯拼音可完整解析时优先留给 Rime，标识符、路径与 URL 不被擅自改写。

### 3. 三层语言画像与可装卸领域词库
- **三层个人画像（LP-001 ~ LP-012）**：成功上屏历史经空闲固化循环沉淀为 **L1 短语库**（20k 容量与 45 天半衰期衰减淘汰）、**L2 分域用户 LM**（token 级幂等折叠与基线自适应插值）与 **L3 风格画像**（`signature_phrases` 自动回灌 L1）；原文仅保留 7 天滚动窗口，固化后按合同淘汰。
- **可装卸领域词库（LX-001，schema v2）**：支持导入 Rime `.dict.yaml`（兼容雾凇 `cn_dicts` 生态），内置 `lexicons/it-programming`（215 词条 CC0）；与个人学习短语同库异表，融合优先级为精确命中 > 本域 > 学习短语 > 领域词库 > 频次，支持独立启停、卸载与跨读音屏蔽。

### 4. 可选云增强与上屏后续写联想（默认关闭）
- **独立 Broker 直连**：仅在用户录入 API Key 后启用，固定直连智谱 Coding Plan（`glm-5.3-flash`），本地 daemon 永久无 INET socket。
- **整句生成与按段接受（KBD-004 / KBD-007）**：不携带候选池，单一宽松拼音策略（支持纠正前后鼻音、平翘舌与错键），结果经结构门校验后展示；多段整句建议支持 `Tab` 按段写入各段定稿，由 `←`/`→` 复核后 `Space` 整句上屏。
- **上屏后续写联想（KBD-003，默认关闭）**：上屏后触发单条轻量续写 chip，`Tab` 或点击采纳，任意其他按键即刻撤销，8 秒无操作自动隐藏。

### 5. 端上语音听写、智能润色与一键翻译（端上原型 / 可选开启）
- **离线 MLX Qwen3-ASR 引擎**：独立 `RimeAIVoiceHelper` 新增 `mlx-qwen3-asr` 流式引擎（`qwen3-asr-0.6b-8bit` + `mlx-audio`），进程级禁用 `AF_INET`/`AF_INET6`，音频仅驻内存不落盘；同时通过冻结 `sherpa-onnx` v1.13.6 buffer-loader fork（SECURITY-001）消除自管 ASR 的同 UID pathname TOCTOU 窗口。
- **双层三源热词校正**：Layer-1 注入 ASR 上下文偏置，Layer-2 确定性还原中英混说拼写（如 `Rime AI` → `RimeAI`、`fast api` → `FastAPI`）与同音词；热词融合自定义常用语（最多 128 条）、语言画像/领域词库与当前会话已确认 Rime 词条。
- **灵活触发与极简浮窗**：支持默认 `⌃⇧V` 按住说话、自定义 `⌃⇧`/`⌥⇧` 组合，或一键设为 **右 `⌘` 点按切换**（按一下开始、再按一下结束）；极简非激活浮窗随内容自适应尺寸与换行，无焦点时保持常驻供点击或 `⌘C` 复制。
- **智能润色与一键翻译**：内置 4 种润色风格（精简书面 / 正式专业 / 自然流畅 / 条理整理）——零延迟离线确定性润色器即时去除“嗯、啊、那个”等口头语与叠词口吃并补全标点，配置云增强后自动升级为大模型深度润色（支持理解口语自纠）；另设 **`⌃⇧T` 一键语音翻译**，支持 7 种目标语言（英 / 中 / 日 / 韩 / 法 / 德 / 西）与中英自动互译；云端润色限时 6s、翻译限时 10s，润色或翻译进行中按 `Space`/回车直接以原文上屏。
- **无打断音频体验与本机统计看板**：支持完成后自动粘贴（必要时经剪贴板 + `⌘V` 回退并恢复原剪贴板，Secure Input 全阻断）、录音期间自动静音系统媒体并精确恢复原静音/音量状态、交互提示音，以及独立本机 SQLite 语音历史与使用统计看板（字数、次数、时长、估算节省时间、语速、连续天数、Top 5 应用、检索/过滤/复制/导出/清空）。
- **默认值与隐私开关**：语音总开关默认关闭；开启后自动粘贴、提示音、媒体静音、本机历史与统计、智能润色、上屏后纠错学习均默认开启且可单独关闭。向云端润色/翻译发送热词（`voiceCloudHotwordsEnabled`）与经辅助功能接口回读文档文本（`voiceAXFallbackReadEnabled`）是两个独立的 opt-in 开关，默认关闭。
- > 边界声明：语音功能是默认关闭的端上原型（可选开启），Release 暂未打包 MLX，尚未满足公开发布放行门（`VOICE-001/002/003`），Release 生产模型审批目录仍为空。

### 6. 六页设置中心与隐私安全边界
- 设置中心涵盖六页：**输入与 AI**、**语音**、**历史与统计**、**云端与历史**、**语言画像**、**状态与数据**。
- 支持版本化配置导入导出（绝不含 API Key）、按依赖顺序串行收敛服务启停、以及保留用户数据的安全恢复默认。
- Secure Event Input、旧组合、旧会话、旧光标与过期 deadline 全部 fail-closed。

## 当前交付边界

| 范围 | 最新状态 |
|---|---|
| macOS 键盘主线 | 内部基线收口（`KBD-001/002/005/006/007/008` `DONE-INTERNAL`）：受控 librime、稳定候选、段焦点编辑与后缀重推、部分选词前缀保留回修、无空格混输、双行建议对比、六页设置与安全输入保护；盲打北极星与 first-shot 度量（`KBD-009`）进行中 |
| 本地语义模型 | 24M 排序器 Debug 浮点 / Release INT8 ONNX 等价性已证明（974 样本冻结集 top-1 一致 99.38%）；零 prompt 拼音约束整句已部署为 MLX 8-bit 双延迟档异步神经臂（`LM-001` `DONE-INTERNAL`，974 样本冻结集 92.2%、p50 115ms；Release 暂未打包 MLX）并完成对抗审查加固；决策传感日志（`LM-003`）已收口，离线蒸馏数据积累（`LM-004`）进行中，SFT（`LM-002`）与神经臂多段支持（`LM-005`）待推进；Release 打包暂未含 MLX 依赖 |
| 语言画像与领域词库 | L1 短语库（含容量与 45 天半衰期淘汰）、L2 分域用户 LM（幂等折叠）、L3 风格画像与签名短语回灌、以及 Rime `.dict.yaml` 领域词库（`LP-001~012`、`LX-001`）全部 `DONE-INTERNAL`；三门离线回归门禁已落地 |
| 可选云增强 | 智谱 Coding Plan 直连（`glm-5.3-flash`）：无候选池整句生成（generate/abstain、单一宽松拼音策略、跨段按段接受）、上屏后续写联想（`KBD-003`）及语音深度润色/翻译（`voice_transform`）已实现；真实冻结集、目标网络、费用与发布验收（`CLOUD-001`）未完成 |
| 语音听写与工作流 | 端上原型 / 可选开启、默认关闭：MLX `Qwen3-ASR` 离线流式引擎、双层三源热词、右 `⌘` / `⌃⇧T` 快捷键、离线 + 云端智能润色、7 种目标语言 + 中英自动互译、自动粘贴 / 媒体静音 / 提示音、本机历史与统计、上屏后纠错学习、两项默认关闭的隐私开关及 sherpa-onnx buffer fork（`SECURITY-001`）已内部完成（`VOICE-WF-01`~`06` `DONE-INTERNAL`，Release 暂未打包 MLX）；产品模型审批、正式语料、TCC/设备与发布门（`VOICE-001/002/003`）尚未关闭 |
| iOS | 离线 librime + 紧凑 n-gram 可行性工程（`IOS-001/002` `DEFERRED`）；fresh Simulator unit/UI 已通过，24M 模型与真机验收未完成 |
| 公开分发 | 未放行（`RELEASE-001` `BLOCKED`）；仍需公证、清洁机、宿主/安全输入、网络、许可证和真实用户指标 |

## 核心交互

- Rime 数字候选立即显示，当前组合期间不因异步结果换位。
- 有 Rime 候选时，`Space` 提交 Rime 首选；`Tab` 采纳可选的 AI 建议（多段云端整句建议按段写入供 `←`/`→` 复核后 `Space` 上屏）。
- 预编辑区支持段焦点编辑：`←`/`→` 在拼音段间切换并自动重推后续段落；末段部分选词保留已选前缀在预编辑区，可按 `←` 回修而不提前上屏。
- 开启「上屏后续写联想」（默认关闭）后，上屏文本会触发一次云端续写建议，以单条 chip 展示；`Tab` 或点击接受，任意其他按键即刻撤销，8 秒无操作自动消失。
- 切换输入法或宿主强制结束输入会话时，未确认的活跃拼音原样上屏，定稿前缀按定稿文本上屏；任何未显式确认的候选都不上屏。
- “分析中、首选一致、候选不足、低置信度、超时或失败”只解释状态，不创建可选项。
- Secure Event Input、旧组合、旧应用会话、旧光标和过期 deadline 的结果全部 fail-closed。
- 语音模式与键盘组合态分离：默认按住 `⌃⇧V` 说话（也可录制 `⌃⇧`/`⌥⇧` 组合或一键设为右 `⌘` 点按切换），`⌃⇧T` 触发一键语音翻译；支持完成后自动粘贴，或关闭自动粘贴时按 `Space`/回车确认、`Esc` 取消。该流程为端上原型 / 可选开启，默认关闭，不具备公开发布资格。

## 架构概览

```text
macOS InputMethodKit (RimeAIInputMethod)
  ├─ librime (受控同步主链) ────> 同步候选、段焦点编辑、部分选词保留与上屏兜底
  ├─ local daemon (private UDS, no-INET)
  │    ├─ 24M 排序器 (FP / INT8 ONNX) ⊕ char n-gram ⊕ L2 用户 LM
  │    ├─ 同步词典约束 beam + 决策传感日志 (decision_log.db)
  │    └─ 异步神经整句臂 (MLX 8-bit Qwen2.5-0.5B, sentence_late)
  ├─ 本机个人数据 (SQLite) ─────> L1 短语库 / 领域词库 (schema v2) / 语音历史与统计
  ├─ cloud broker (private UDS, opt-in 唯一网络出口)
  │    └─ 固定 HTTPS (glm-5.3-flash) ─> 整句 generate·abstain / 上屏续写 / 语音润色·翻译 / L3 固化压缩
  └─ voice runtime (默认关闭)
       ├─ Debug: private UDS
       └─ Release: authenticated NSXPC Mach service
            └─ RimeAIVoiceHelper
                 ├─ MLX Qwen3-ASR 离线流式 worker (no-INET, 音频仅驻内存, 双层热词)
                 ├─ Apple Speech probe
                 └─ product-managed sherpa-onnx buffer fork (production catalog 未审批)
```

完整组件、数据流和信任边界见 [TECHNICAL_DESIGN.md](TECHNICAL_DESIGN.md) 与 [docs/ARCHITECTURE_DIAGRAMS.md](docs/ARCHITECTURE_DIAGRAMS.md)。

## 仓库结构

- `Sources/`、`Package.swift`：共享 Swift 核心（输入状态机、设置、语言画像、语音协议/润色/热词/历史）、Rime 桥、语音 Helper 与评测组件。
- `macos/`：InputMethodKit 输入法、六页设置中心、悬浮听写面板与发布工程。
- `ios/`：iOS 宿主与键盘扩展可行性工程。
- `rimeai_daemon/`：本地语义 daemon、异步神经整句调度与决策传感日志。
- `rimeai_runtime/`：daemon、语音 worker 与评测共享的本地运行时包（24M/ONNX 排序、beam decoder、拼音约束 MLX worker、Qwen3-ASR 离线 worker、拼音守卫与 IPC）。
- `rimeai_cloud_broker/`：可选云增强 broker（整句生成、上屏续写、语音润色/翻译、历史检索与语言画像空闲固化）。
- `lexicons/`：预置领域词库源数据与构建产物（含 `it-programming` 示例词库）。
- `rimeai_eval/`、`tools/`：冻结数据、SFT 数据集构建、三门回归门禁、训练与评测工具。
- `third-party/`：冻结的第三方安全补丁（如 `sherpa-onnx` v1.13.6 buffer-loader patch）。
- `src/`、`public/`、`index.html`：RimeAI 产品主页（React + Vite，部署于 Cloudflare Pages；明暗双主题，默认跟随系统并可手动切换）。
- `script/`、`scripts/`：开发、安装、构建、验证与发布脚本。
- `tests/`：Swift、Python、C/C++ 与 shell 回归。
- `docs/`：仍在生效的专项协议、架构图、盲打差距分析、安全与制品合同。

## 开发与验证

当前工作树已经建立不依赖 `CPATH` 或旧构建缓存的内部基线。常用入口如下；完整状态、边界和 Xcode 命令族见 [TASKS.md](TASKS.md) 与 [TECHNICAL_DESIGN.md](TECHNICAL_DESIGN.md)。

```bash
# SwiftPM 严格验证
env -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH \
  swift test --scratch-path "$(mktemp -d /tmp/rimeai-swift.XXXXXX)" \
  --no-parallel -Xswiftc -warnings-as-errors

# Python 严格验证
PYTHONDONTWRITEBYTECODE=1 python3.11 -m pytest -q -p no:cacheprovider

# 原生与工程一致性验证
./scripts/verify_ios_project_generation.sh
./scripts/verify_macos_librime.sh macos/Native/RimeAIMacRuntime.xcframework
./tests/test_rime_partial_candidate_selection.sh

# 产品主页构建与本地预览（产物写入 dist/）
npm run build
npm run dev

# 仅验证主页构建而不改动工作区 dist/
npx vite build --outDir /tmp/rimeai-web-verify --emptyOutDir && rm -rf /tmp/rimeai-web-verify
```

这些检查不证明 Developer ID 签名、公证、清洁机安装、真机兼容、真实云/语音质量或公开发布资格。

## 生效中的专项合同

- [docs/ARCHITECTURE_DIAGRAMS.md](docs/ARCHITECTURE_DIAGRAMS.md)：能力级逻辑架构图与关键决策时序图。
- [docs/P0_FORMATS.md](docs/P0_FORMATS.md)：键盘候选与整句协议。
- [docs/PARTIAL_SELECTION_DESIGN.md](docs/PARTIAL_SELECTION_DESIGN.md)：部分选词前缀保留与回修设计。
- [docs/BLIND_TYPING_GAP_ANALYSIS.md](docs/BLIND_TYPING_GAP_ANALYSIS.md)：盲打北极星与 first-shot 差距拆解。
- [docs/CLOUD_INPUT_IMPLEMENTATION.md](docs/CLOUD_INPUT_IMPLEMENTATION.md)：云候选、凭据、历史与隐私合同。
- [docs/LANGUAGE_PROFILE_DESIGN.md](docs/LANGUAGE_PROFILE_DESIGN.md)：语言画像学习、固化循环与历史淘汰合同。
- [docs/DOMAIN_LEXICON_DESIGN.md](docs/DOMAIN_LEXICON_DESIGN.md)：领域词库 schema v2 与 `.dict.yaml` 导入合同。
- [docs/CONTINUOUS_OPTIMIZATION_LOOP_DESIGN.md](docs/CONTINUOUS_OPTIMIZATION_LOOP_DESIGN.md)：决策日志、离线 SFT 与三门回归闭环设计。
- [docs/VOICE_INPUT_DESIGN.md](docs/VOICE_INPUT_DESIGN.md)：语音交互、润色/翻译工作流与 V2 协议。
- [docs/VOICE_IPC_SECURITY.md](docs/VOICE_IPC_SECURITY.md)：语音 IPC 威胁模型。
- [docs/VOICE_ASR_ARTIFACT.md](docs/VOICE_ASR_ARTIFACT.md)：语音模型制品与 buffer 传输合同。
- [docs/VOICE_ASR_RUNTIME_INTAKE.md](docs/VOICE_ASR_RUNTIME_INTAKE.md)：ASR runtime/model intake 合同。
- [docs/VOICE_EVAL_FORMAT.md](docs/VOICE_EVAL_FORMAT.md)：语音评测与证据 schema。
- [ios/README.md](ios/README.md)：iOS 可行性工程边界。

## 开源与第三方引用

逐项的固定版本/提交、校验值、许可证文本随附关系见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与 [datasets/ATTRIBUTION.md](datasets/ATTRIBUTION.md)；本节只列引用来源。

**输入引擎与 Rime 数据生态**

- [librime](https://github.com/rime/librime)（BSD-3-Clause）：受控同步引擎。
- [rime-luna-pinyin](https://github.com/rime/rime-luna-pinyin)、[rime-prelude](https://github.com/rime/rime-prelude)、[rime-essay](https://github.com/rime/rime-essay)、[rime-stroke](https://github.com/rime/rime-stroke)（LGPL-3.0）：schema、词典与语言数据。
- [OpenCC](https://github.com/BYVoid/OpenCC)（Apache-2.0）：简繁转换与数据（含错误归类分析用的 TSCharacters 字表）。
- LevelDB、marisa-trie、Boost.Regex、yaml-cpp：librime 静态依赖。

**模型**

- [Qwen2.5-0.5B](https://huggingface.co/Qwen/Qwen2.5-0.5B)（Apache-2.0）：零 prompt 拼音约束整句解码基座（MLX 8-bit 异步神经臂）。
- [Qwen3-ASR](https://huggingface.co/Qwen)（Apache-2.0）：端上离线流式语音识别基座（`qwen3-asr-0.6b-8bit` via `mlx-audio`，开发/内部引擎）。
- Qwen2.5-0.5B-Instruct（Apache-2.0）：已证伪的 prompt 整句路线实验。
- [BAAI/bge-small-zh-v1.5](https://huggingface.co/BAAI/bge-small-zh-v1.5)（MIT）：24M 排序器初始化权重与 tokenizer。
- gte-multilingual-reranker-base（Apache-2.0）：已否决的 P0 实验。

**推理与评测运行时**

- [MLX](https://github.com/ml-explore/mlx)、`mlx-lm`、`mlx-audio`：Apple Silicon 本地 8-bit 约束整句解码与离线 Qwen3-ASR 推理（开发/本机隔离 venv，暂未进入 Release 安装包）。
- ONNX Runtime、sherpa-onnx（含 RimeAI v1.13.6 buffer-loader 冻结补丁）：macOS INT8 排序与自管语音 runtime。
- PyTorch、Transformers、safetensors：离线约束解码、SFT 对照与 beam 评测推理（开发机）。
- jieba、pypinyin、HF tokenizers、NumPy、PyYAML、PyInstaller：分词、拼音、同音热词校正、tokenizer、张量、配置与冻结构建。

**语料**

- 中文 Wikivoyage（CC BY-SA 4.0）与 MDN 中文文档（CC BY-SA 2.5+）：冻结评测语料，逐样本归因见 [datasets/ATTRIBUTION.md](datasets/ATTRIBUTION.md)。

**设计参考（非捆绑代码或数据）**

- [lime](https://github.com/xushengfeng/lime)：零提示、零微调的拼音约束解码思想参考；RimeAI 的差异（词典边界索引、beam per-path KV、模糊音节终门）见 [docs/superpowers/plans/2026-10-13-pinyin-constrained-decoder.md](docs/superpowers/plans/2026-10-13-pinyin-constrained-decoder.md)。
- PinyinGPT（拼音辅助 IME 生成模型研究）：LM-002 SFT 蒸馏配方参考。

## 许可证

本项目以 [Apache-2.0](LICENSE) 发布。第三方组件的固定版本、许可证与归因见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
