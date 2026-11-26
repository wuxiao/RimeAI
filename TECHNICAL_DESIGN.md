# RimeAI 技术设计

| 项目 | 当前值 |
|---|---|
| 版本 | 1.3 |
| 更新日期 | 2026-11-25 |
| 状态 | 当前唯一总体技术设计 |
| 当前工作树 | 内部 clean baseline 已收口键盘主线、双延迟档与语音新工作流；尚未通过公开发布门 |

本文件描述现行架构、数据流、信任边界和验证事实。产品需求与交互分别见
[PRD.md](PRD.md) 和 [PRODUCT_DESIGN.md](PRODUCT_DESIGN.md)；开发状态只在
[TASKS.md](TASKS.md) 维护。

## 1. 当前事实基线

当前工作树已按功能边界拆分为可审查提交。以下基线证明同一工作树快照可从全新
构建目录完成内部验证，但不把“内部可构建”解释为“可发布”。

### 1.1 当前边界

1. macOS 与 iOS 受控 librime XCFramework 的 3 个 slice 已恢复公开 headers；
   header、slice 和 `Info.plist` 合同进入 artifact lock，并由原生 contract test
   与 macOS verifier 校验。
2. tracked shell 入口、嵌套依赖和 harness 已记录为 `100755`；直接执行的构建、
   安装、发布策略和二进制隔离 contract tests 通过。
3. `ios/project.yml` 改用跨平台显式源文件清单；独立 regeneration verifier 在
   临时镜像中生成工程并精确比较 pbxproj、scheme 与 workspace。
4. 真实签名、公证、清洁机、真机、目标网络、正式语料、许可证和用户效果矩阵
   尚未关闭。

### 1.2 验证分层

| 层级 | 同一工作树快照的 clean 命令族 | 结果 |
|---|---|---|
| SwiftPM | 清除 header 环境变量，使用全新 scratch，warnings-as-errors | 全量基线 907 tests / 63 suites（2026-08-24）；2026-10-13 时点 InputCore 子集 449 通过 |
| Python | 禁止 bytecode/cache，warnings-as-errors | 632 tests 通过（2026-10-13），无遗留测试进程 |
| macOS | 全新 DerivedData，arm64，Swift/C/C++ warnings-as-errors | 40 tests 通过（2026-10-13） |
| iOS | 全新 DerivedData，Simulator unit + system-keyboard UI | 11 tests 通过（2026-08-24 基线） |
| Native / shell / generation | XCFramework contract、部分候选 C++ 集成、脚本直接调用、XcodeGen 精确再生成 | 全部通过 |
| Web（产品主页） | `npx vite build --outDir <项目外临时目录> --emptyOutDir`（不写入工作区 `dist/`） | 0 error / 0 warning（2026-11-25）；明暗双主题与静态资源（OG 卡片、触控图标）随构建产出 |

SwiftPM 与 macOS 构建均显式移除 `CPATH`、`C_INCLUDE_PATH` 和
`CPLUS_INCLUDE_PATH`；Xcode 使用全新 `/tmp` DerivedData。验证前后仓库快照
一致。以上结果关闭内部构建基线，不构成 release qualification。

## 2. 总体架构

```text
目标应用
  ^
  | insertText / marked text / auto-paste (non-SEI)
macOS InputMethodKit 输入法
  ├─ RimeEngine + controlled librime
  │    └─ 同步候选、段焦点编辑、部分选词前缀保留与回修
  ├─ Local SQLite Stores
  │    ├─ L1 短语库 + 领域词库 (schema v2)
  │    └─ 语音历史与使用统计 (VoiceHistoryStore，独立于键盘历史)
  ├─ DaemonClient ── private UDS (no-INET) ── rimeai-daemon
  │                                  ├─ 24M ranker (FP / INT8 ONNX) ⊕ char n-gram ⊕ L2 User LM
  │                                  ├─ constrained beam decoder + decision_log.db
  │                                  └─ MLX 8-bit neural sentence worker (sentence_late，写序门：严格晚于同步 result 帧)
  ├─ CloudBrokerClient ── private UDS ── cloud broker ── fixed HTTPS gateway (glm-5.3-flash)
  │                         ^                ├─ inference: generate·abstain（≤128 字，无候选池）/ continuation
  │                         ^                ├─ voice_transform: polish / translate（7 种目标语言 + 中英互译）
  │                         ^                └─ embed_texts（历史向量化，当前停用）/ L3 固化
  │                         └─ rolling 7d plaintext history / FTS / cloud-decisions.db
  └─ VoiceDictationRuntime (+ VoiceLocalPolisher / VoiceClipboardPaster / VoiceSystemAudioMuter
       + VoiceSoundEffectsPlayer / VoicePostCommitEditTracker / VoicePostCommitCorrectionLearner)
       ├─ Debug: private UDS
       └─ Release: authenticated NSXPC Mach service
                         └─ RimeAIVoiceHelper
                              ├─ MLX Qwen3-ASR offline worker (no-INET, 音频仅驻内存, 双层热词)
                              ├─ Apple Speech probe
                              └─ product-managed sherpa-onnx buffer fork (production catalog empty)
```

Rime 是唯一同步主链。所有本地模型、云端和语音组件都可以失败、取消或未安装，
而不破坏纯 Rime 键盘输入。

## 3. macOS 输入主链

### 3.1 Rime 与候选选择

- `RimeAIInputController` 接收 InputMethodKit 事件，`RimeEngine` 封装受控
  librime。
- Rime 候选同步显示；AI 使用独立 `SemanticCandidatePresentation`。
- 有 Rime 候选时 Space 选择 index 0，Tab 选择可用语义候选。
- 当前工作树新增 `CandidateSelectionTransition` 和
  `rai_engine_select_candidate`：UI 候选重新绑定到原生 index；若候选只消费
  拼音前缀，只提交确认文本并保留严格验证后的 ASCII 拼音后缀。
- 候选不足、同首选、低置信度、超长、不完整和字形不一致均是不可选状态。

### 3.2 请求生命周期

每个异步结果至少绑定：

- composition ID 与 revision；
- app session 与当前宿主；
- history generation；
- 绝对 deadline；
- 当前 Secure Event Input 与选择状态。

任何一项变化都会使旧结果失效。取消、超时或进程失败只更新对应来源状态，不得
覆盖另一路的成功结果。

### 3.3 本地上下文

- strict：不读取上下文。
- standard：当前产品会话内最多 100 个字符。
- smart：平台允许时最多 400 个字符。
- 切换应用、关闭 AI 或进入安全输入会清除相关易失上下文。

## 4. 本地 daemon 与模型

### 4.1 进程边界

- Python daemon 使用 owner-only runtime 目录和 Unix Domain Socket，校验同 UID。
- 进程级守卫拒绝 `AF_INET`/`AF_INET6`；本地模型路径永久离线。
- 同 UID UDS 只隔离其他系统用户，不抵御同一登录用户下的恶意进程。
- 协议按 request/composition/session/deadline 校验，串行推理并带失败熔断。

### 4.2 当前制品差异

“当前 macOS 运行时都是 INT8”是不准确的：

| 路径 | 当前模型 |
|---|---|
| Debug 脚本与本机 LaunchAgent | 浮点 24M safetensors |
| Release builder 目标 | INT8 ONNX 24M |
| iOS | 紧凑只读 n-gram，无 24M |

Release INT8 曾有冻结质量与延迟证据；本次 clean baseline 未执行真实签名发布
制品与部署环境资格。Debug 与 Release 必须统一目标，或持续维护并验证等价性。

2026-10-16 结构修复：Release 的 ONNX 加载路径此前在运行时包中是死代码
（`rimeai_runtime/neural_ranker.py` 懒加载 `from .onnx_ranker import ...`，
但该模块从未存在，daemon 遇到 ONNX model_type 即 ModuleNotFoundError）。
现 `rimeai_runtime/onnx_ranker.py` 提供运行时加载/推理（仅 onnxruntime，
Python 3.9 工具链），`rimeai_eval/onnx_ranker.py` 保留导出/量化工具与评估
适配层（RankerError/Ranking 合同）；daemon 诊断的 neural_ranker 条目新增
`model_type` 字段，区分 `rimeai-pinyin-listwise-cross-encoder`（浮点）与
`...-onnx`（INT8）。等价性证明已完成（2026-10-16，冻结测试集 top-1 一致率 99.38%、质量差 ±0.12pp、
INT8 延迟更低，报告 `.rimeai/reports/ranker-float-vs-int8.json`）：产品采用双制品
目标——Debug/本机 LaunchAgent 浮点、Release builder INT8（上一表），两者均由
`load_neural_ranker` 按 manifest model_type 加载，诊断条目携带 model_type。
Release builder 全流程已用 ONNX 路径重跑通过（preview-4-segment-focus）；发布
验证的探针 daemon 显式钉死缺失 user-lm 路径——用户画像是机器本地运行时状态，
发布验证必须确定性且 artifact-scoped。

### 4.3 排序与整句

- 24M 拼音感知 Cross-Encoder 与 char n-gram 融合，对可比较的 Rime Top-10
  排序。
- beam decoder 只生成可由冻结 Rime 词典证明的整句，最长 30 个汉字。
- 当前外层整句展示门为 0.60，内层 beam margin 保持冻结 validation 选择值。
- 阈值质量数字只对其冻结数据和 artifact 有效，不能外推到真实接受率。
- 整句解码的既定演进方向是零 prompt 的 LM 拼音约束解码：base LM 只做
  next-token 打分，候选合法性由冻结词典拼音掩码强制（无提示工程、无
  thinking、无 chat template）。prompt 生成路线在 0.5B 冻结集上证伪
  （910/974 空建议，准确率等于词典兜底）；对照基线与错误归类冻结于
  [docs/baselines/constrained-qwen-v2.json](docs/baselines/constrained-qwen-v2.json)。

#### 4.3.1 双延迟档整句架构（LM-001 部署化，2026-10-19）

零 prompt 约束解码已部署进产品链，与同步 n-gram beam 构成双延迟档：

- **引擎**：Qwen2.5-0.5B base 的 MLX 8-bit 制品（隔离 venv
  `.rimeai/mlx-venv`，mlx 0.32.4 / mlx-lm 0.32.2；lock 见
  `models/qwen2.5-0.5b-mlx-8bit.lock.json`）。4-bit 被证据否决：种子边界
  分布場塌（P(今天|。) 1.2e-3→3.4e-6），8-bit 与 fp16 逐样本一致率
  99.8%、净准确率差 0；冻结基线 `docs/baselines/constrained-qwen-v3-mlx.json`（974 样本句准确率 0.921971，p50 115ms vs fp16 252ms）。
- **KV 管理**：单一持久 prompt cache，beam 路径与跨请求共 prefix 均
  回退到最长公共前缀只喂增量（constrained-v2 的 per-path 正确性保持，
  cross-path 共享为已知优化）；确定性测试钉在 `tests/test_mlx_worker.py`。
- **协议**：daemon hello 通告 `sentence-late` capability（仅当客户端
  也通告时才发迟到帧，旧客户端永不会收到未知帧）；迟到帧
  `sentence_late` 携带 composition_id/revision/app_session_id 绑定与
  elapsed_ms。超时/失活/结构违规全部 fail-closed 静默弃权。
- **仲裁规则（冻结）**：同步 n-gram 句建议先出（同步 infer 响应内）；
  神经整句 100-300ms 后经迟到帧按 latest-request-wins 接管同一建议位
  （击键/选词推进 revision 旧帧即 stale，云端已占槽则丢弃，Secure
  Input fail-closed）；Tab 接受路径与同步句一致；展示门 min_confidence
  =0.0（校准证据：置信度对精度区分度弱，见基线 confidence_gate 段）；
  多段（跨标点）请求 v1 不走神经臂，仍由同步 beam 与 KBD-006/007 分段
  机制服务。
- **部署边界**：daemon 本机 LaunchAgent 路径（`--neural-sentence-config`，
  安装脚本自动生成绝对路径配置，交互部署的 worker 读超时封顶
  5s——评测侧 60s 批量配置不随行）；Release builder/PyInstaller 打包
  未包含 MLX 依赖，属后续任务；已安装 daemon 的神经臂 worker
  （脚本/隔离 venv/模型）仍取自 repo checkout，路径在 hello
  artifacts 的 path 字段可巡检（reveal C-F5 冻结注记）。LM-002 SFT
  未开始。
- **reveal 对抗审查加固（2026-10-20，跨家族三审 + 交叉验证）**：
  (1) 仲裁反向序兑底——两臂在 daemon 侧无写序保证，同步帧可能晚于
  神经帧到达；客户端在同令牌神经帧已应用后，后到的同步 ok/timeout/
  failure 帧只消费在途槽不改展示（superseded_by_neural_late 事件）；
  (2) 迟到帧改按 requestID 路由（发送时登记、帧到一次性取回，
  容量 16），消除多 IMK controller 并存时单例单槽被最新 init 覆盖的
  静默丢帧；(3) 交付预算 deadline 下传 worker 读（慢 decode 在预算处
  释放单线程执行器槽）+ 提交前 revision 过期预检；worker stderr 不再
  丢弃、遥测 stats 不再死请求；(4) 服务生命周期：close 先 terminate
  （EOF 唤醒阻塞读）后关管道、kill 后 wait 收尸、打断不计入熔断；
  冷启动首读豁免窗口（30s）；连续 5 轮熔断冷却后永久弃权；
  (5) 迟到帧 script-mismatch 复用同步路径的字形转写；结构门双侧
  补齐（server 层 min_confidence、Swift 侧可打印字符；长度不变式：
  Python 码点计数 ≥ Swift 字形簇计数，无越界旁路）；神经置信度与
  云端 0.60 门量纲差异已在 DaemonProtocol 文档冻结（不得把迟到帧
  路由回 isValid 门）；(6) worker per-request 异常 fail-closed 不再
  崩进程，请求后回滚共享缓存释放 beam 尾行（seed+context 前缀资产
  保留）。

### 4.4 领域词库（schema v2）

- 预置词库资产与学习型 L1 短语同库异表（`lexicons` /
  `lexicon_entries`），词库可安装/替换/启停/卸载，多音字一词多行；
  完整设计见 [docs/DOMAIN_LEXICON_DESIGN.md](docs/DOMAIN_LEXICON_DESIGN.md)。
- 导入格式为 Rime `.dict.yaml`（兼容雾凇 cn_dicts 生态）；拼音规范化
  小写去空格、ü→v，权重 w→w/10 钳制 1–99。
- 词库短语只进独立建议位：快照融合排序为精确命中 > 本域 > 学习短语
  > 词库短语 > 频次；屏蔽跨全部读音生效；不触碰 Rime 用户词典，
  不影响冻结词典基线。
- 构建工具 `tools/build_domain_lexicon.py`：人工只维护
  `lexicons/<name>/source.tsv`，拼音由 luna_pinyin 词级+贪心最长匹配
  自动注音，产出标准 dict.yaml + manifest；示例词库
  `lexicons/it-programming`（215 词条，CC0）。

### 4.5 迟到帧写序与有界关闭（2026-11-25）

- `write_lock` 只保证同一连接上的帧不交错，不保证顺序：神经臂可能先于同步
  `result` 写出 `sentence_late`，而客户端此时尚未为该请求 arm 迟到帧槽，帧被当作
  过期修订丢弃。现每个请求持有一个 `_RequestGate`：同步 `result` 帧写出后才释放
  神经臂；等待上限＝请求 deadline + 1 s 宽限；同步臂无论以 result / 错误 / 超时 /
  取消何种方式结束都会释放门，没有 `result` 则神经臂弃权，不存在无限等待。
- `close()`：先置 `_closing`，所有 handler 在下一轮读循环顶部退出，不再创建新请求
  臂；`shutdown_unix_listener` 在 0.5 s 宽限内冲刷在途帧后中止连接，整体拆除仍受
  `CLOSE_TEARDOWN_TIMEOUT_SECONDS = 5.0` 约束；随后关闭神经臂与决策日志、摘除
  套接字、以 `wait=False` 关闭执行器。
- 客户端会话登记；对端复位（`OSError`）按普通断开处理，不计入熔断。

## 5. 可选云增强

### 5.1 固定合同

- provider：`Zhipu Coding Plan (direct)`
- endpoint：`https://open.bigmodel.cn/api/coding/paas/v4`
- model：`glm-5.3-flash`（单一冻结白名单）
- embedding：`text-embedding-v4`，512 维（后台向量化当前硬停用，检索降级 FTS）
- 请求不携带候选池。broker 按 capability 协商暴露四类能力：
  - `inference`（`text-generation`）：键盘整句路由，唯一决策为 generate / abstain，
    ≤128 字符，多段支持 `Tab` 按段写入复核；
  - `continuation`（`continuation-generation`）：上屏后续写联想，单条 chip；
  - `voice_transform`（`voice-transform`）：语音 4 风格深度润色（`polish`）与翻译
    （`translate`，7 种目标语言 + 中英自动互译）。输入 ≤ 20,000 字符、输出 ≤ 30,000
    字符、deadline 1–30,000 ms；`max_tokens` 随输入长度伸缩
    （`min(8192, max(512, 2×输入字符数 + 256))`）；输出须为单行可打印文本。客户端
    时限：云端润色 6 s、云端翻译 10 s，超时或未配置回退本地润色不丢字；输入 ≥ 80 字
    而输出不足原文 60% 判为残句并回退本地；
  - `embed_texts`：历史向量化的内部方法（`text-embedding-v4`，512 维，≤32 条、每条
    ≤16 KiB），不是客户端路由；后台向量化当前停用，检索降级 FTS。
- 总 deadline：键盘 30s 墙钟（协议上限 30000ms，本地开发调试口径；正式发布口径 8s）；
  语音时限见上。

broker 模块为 `rimeai_cloud_broker/cloud_model.py`（中性云增强命名，
provider 固定为智谱 Coding Plan 直连）。

### 5.2 数据流与接纳

输入法绑定 composition、revision、session、history generation 和 deadline，
经同 UID UDS 发给 broker（不携带候选池）。broker 只能访问固定 HTTPS
endpoint；键盘 `inference` 路由只返回 `generate` 或 `abstain`（`continuation` 与
`voice_transform` 为独立路由，同样不携带候选池）。客户端再次验证全部绑定并过
结构门后才允许展示，采纳需用户显式确认。

### 5.3 凭据与历史

- API Key 位于 `~/.config/rimeai/cloud.env`，目录 0700、文件 0600；它不是
  Keychain，也不抵御 hostile same-UID 进程。
- 凭据不进入设置导出、prompt、历史、日志或诊断。
- 云端配置后，成功上屏记录写入跨应用明文 SQLite，并建立 recent、FTS 和向量
  检索。当前合同最多发送 600 字 recent 和 8 条 snippet。原文只在 7 天滚动
  窗口内保留，窗口外批次固化后按语言画像合同淘汰（详见
  [docs/LANGUAGE_PROFILE_DESIGN.md](docs/LANGUAGE_PROFILE_DESIGN.md)）。
- 移除 Key 只停用云端；历史由独立永久清除操作删除并提升 generation。
- Secure Event Input 阻断请求、历史写入和在途接纳。

详细合同见
[docs/CLOUD_INPUT_IMPLEMENTATION.md](docs/CLOUD_INPUT_IMPLEMENTATION.md)。

## 6. 设置与运行态收敛

- `RimeAISettingsStore` 当前导出 schema 8（向后兼容扩展语音润色/翻译/热词/自动粘贴/
  提示音/媒体静音/语音历史等字段，以及默认关闭的云端热词 `voiceCloudHotwordsEnabled`
  与 AX 回读 `voiceAXFallbackReadEnabled` 两个独立 opt-in 开关；旧版 schema 8 文件
  仍可无损导入，缺失的两个开关按关闭解码）；导入兼容 schema 5–8。
- 设置窗口采用六页结构（输入与 AI / 语音 / 历史与统计 / 云端与历史 / 语言画像 / 状态与数据）。
- 语音快捷键支持在设置中录制、取消与恢复默认：接受 `⌃⇧` / `⌥⇧` 搭配字母数字标点键，
  或一键设为单修饰键点按切换的 **右 `⌘`**（`keyCode 54`）；另支持独立录制一键语音翻译
  快捷键（默认 `⌃⇧T`）；冲突或无效输入 fail-closed，运行态变更立即重注册。
- 导入上限 128 KiB；固定 cloud provider/endpoint/model、Offline Lock、凭据、
  应用列表和语音/AI 依赖均 fail-closed。
- API Key、键盘历史、语音历史与统计、诊断、语言画像、领域词库和模型不进入普通恢复默认删除范围。
- daemon、cloud broker、voice helper 按 stop voice/cloud -> daemon、start
  daemon -> cloud -> voice 的依赖顺序串行收敛；失败服务偏好回退为关闭。
- 设置通知只表达期望变化；只有 lifecycle/ready 验证完成才能表达运行态成功。

## 7. 语音架构

### 7.1 产品边界

语音是默认关闭的独立模态。输入法侧负责快捷键（`VoiceHotKeyManager`，支持按住组合键、
右 `⌘` 单键点按切换与翻译快捷键）、状态机、极简自适应浮窗（`VoiceDictationPanelController`）、
离线确定性润色（`VoiceLocalPolisher`）、可选云端 `voice_transform` 调用、自动粘贴回退
（`VoiceClipboardPaster`，仅非 Secure Input 时生效并恢复原剪贴板）、系统媒体自动静音
（`VoiceSystemAudioMuter`）、交互提示音（`VoiceSoundEffectsPlayer`）、三源热词合并、
宿主守卫与本机语音历史/统计（`VoiceHistoryStore`）；helper 持有音频权限、ASR engine
与服务端状态。语音文本不进入键盘长期历史。上屏后纠错学习
（`VoicePostCommitEditTracker` / `VoicePostCommitCorrectionLearner`）、启动闸门
（`VoiceDictationStartGate`，对安全输入、语音未启用、应用禁用 AI 等逐条给出面向
用户的原因）与时限口径（`VoiceSessionTiming`）同样位于输入法侧。

### 7.2 V2 协议

消息为 `voice_hello`、`voice_ready`、`dictation_start`、
`dictation_stop`、`dictation_delta`、`dictation_final`、
`dictation_cancel`、`dictation_accept`、`dictation_error`。

Debug UDS 使用 NDJSON；Release XPC 的单个 Data RPC 承载一条无换行 JSON，
预解码上限 64 KiB。状态与字段合同见
[docs/VOICE_INPUT_DESIGN.md](docs/VOICE_INPUT_DESIGN.md)。

### 7.3 Debug 与 Release 启动语法

当前 helper 只接受：

```text
Debug:
  --socket <path>
  --socket <path> --engine unavailable|apple-speech|mlx-qwen3-asr|product-managed

Release:
  --mach-service fun.wwcn.rimeai.voice-helper
```

`evaluation-product-managed --artifact-dir` 已被 parser 和测试明确拒绝。
候选 artifact 评测必须走独立 `rimeai-voice-eval-driver --plan ...`；sealer 与
tracer 也都是独立工具，不向 helper argv 增加策略面。

### 7.4 Release IPC

- 双端校验 Apple anchor、Developer ID OID、Team ID、bundle ID 和 effective UID。
- 每次调用重新核对当前 XPC UID/PID；认证失败不回退 UDS。
- 顶层只允许 Data；每方向单帧 in-flight，有界 32 帧/256 KiB FIFO。
- connection、endpoint、core、output 和 session 代际隔离旧回调。

详细威胁模型见 [docs/VOICE_IPC_SECURITY.md](docs/VOICE_IPC_SECURITY.md)。

### 7.5 端上 ASR 引擎（MLX Qwen3-ASR 与产品管理 Sherpa）

- **MLX Qwen3-ASR 离线流式引擎（Debug/开发）**：`MLXQwen3ASREngine` 通过私有
  stdin/stdout NDJSON 管道拉起 `script/voice_mlx_qwen3_asr_service.sh` →
  `rimeai_runtime/qwen3_asr_worker.py`（模型与运行时优先复用跨工具共享标准仓
  `${AI_MODELS_HOME:-~/Models}/qwen3-asr-0.6b-8bit` 及
  `${AI_MODELS_HOME:-~/Models}/runtimes/voice-mlx-venv`，并自动兼容 Hugging Face
  本地离线缓存 `~/.cache/huggingface/hub` 与历史仓库路径 `.rimeai/`）。
  worker 在加载模型前安装进程级 `AF_INET`/`AF_INET6` 网络守卫并开启离线环境变量；
  音频 PCM 仅驻留内存并在 stop/cancel 后清空；识别集成 Layer-1 `hotwords=` 上下文偏置与
  Layer-2 确定性 `HotwordCorrector`（英文去空格/大小写还原 + 基于 `pypinyin` 的保守中文同音校正）
  及静音/热词回声幻觉守卫。
- **产品管理 Sherpa-ONNX 资产**：manifest schema v2 只证明制品内容和运行时合同。
  来源、模型权利、再分发和质量审批只来自 code-shipped trusted catalog；
  `VoiceASRTrustedArtifactCatalog.production` 当前 approvals 为空，Release 因此没有获批
  product-managed ASR。
- **同 UID pathname 窗口已消除（SECURITY-001，2026-10-26）**：采用冻结 fork
  `sherpa-onnx` v1.13.6 + `third-party/sherpa-onnx-v1.13.6-buffer-loader.patch`
  （`macos/Native/SherpaOnnxMacOS-fork.xcframework`），对已校验的 5 个文件
  （含 `bpe.vocab`）通过 fd `pread` 全量读入内存经 pinned buffer 传入识别器，ORT 不再打开
  任何模型/词表 pathname，消除前验→open TOCTOU 窗口；snapshot pathname 仅保留为回归对照。
- evaluation sealer 与三进程 causal tracer 能固定候选并诊断冷加载；schema 2
  结果固定 `authenticated_production_driver=false`，不是 release evidence。

专项合同：

- [docs/VOICE_ASR_ARTIFACT.md](docs/VOICE_ASR_ARTIFACT.md)
- [docs/VOICE_ASR_RUNTIME_INTAKE.md](docs/VOICE_ASR_RUNTIME_INTAKE.md)
- [docs/VOICE_EVAL_FORMAT.md](docs/VOICE_EVAL_FORMAT.md)

### 7.6 语音时限、文本上限与默认值

| 项 | 当前值 |
|---|---|
| 协议 deadline 上限 | `maximumDeadlineMilliseconds = 30_000` |
| 识别收尾 / 云端润色 / 云端翻译 | 10 s / 6 s / 10 s（`VoiceSessionTiming`） |
| `voice_transform` 输入 / 输出 | ≤ 20,000 / ≤ 30,000 字符（客户端与 broker 双重校验） |
| 语音总开关 | 默认关闭，依赖 AI 总开关 |
| 默认开启（语音开启后，均可单独关闭） | 自动粘贴、交互提示音、录音时静音系统音频、本机语音历史与统计、智能润色、上屏后纠错学习 |
| 默认关闭（独立 opt-in） | 向云端润色/翻译发送热词 `voiceCloudHotwordsEnabled`；AX 文档回读 `voiceAXFallbackReadEnabled`（另需辅助功能授权且非 Secure Input） |
| 翻译目标 | 7 种语言（英/中/日/韩/法/德/西）+ 中英自动互译 |

交互合同见 [docs/VOICE_INPUT_DESIGN.md](docs/VOICE_INPUT_DESIGN.md) §3.5、§3.9、§3.10。

## 8. iOS

- iOS 17 host 与 keyboard extension 使用静态 librime 1.17 和预构建 Rime 数据。
- `ios/project.yml` 是工程生成源并使用显式跨平台源文件清单；生成后的 pbxproj、
  scheme 与 workspace 必须通过精确 regeneration check，避免双真相。
- 当前语义层只使用紧凑 n-gram，不包含 24M 模型。
- 部分候选选择只提交确认前缀并保留未消费拼音后缀，已进入 native、Swift 与
  fresh Simulator 回归。
- 语音偏好类型（`VoicePolishStyle` / `VoiceTranslationLanguage`）位于 iOS 可共享的
  `VoicePreferenceTypes.swift`，登记进三个 iOS 目标与再生成校验镜像清单；依赖
  macOS 类型的 `VoiceFeatureTypes.swift` 不进入 iOS 键盘子集。
- 自定义键盘控件使用稳定 accessibility identifier，避免 iOS 系统键盘 chrome
  的同名 globe/dictation 控件造成 UI selector 碰撞。
- XCFramework headers 与 Simulator unit/UI 基线已完成；真机内存、生命周期、
  代表宿主和 TestFlight 发布验证仍未完成。

## 9. 构建、签名与发布

- macOS 输入法 Release 是唯一顶层 App，语音 helper 内嵌于
  `Contents/Helpers`，两者要求同 Team/version/build。
- Debug voice 使用 UDS；Release voice 只使用命名 XPC Mach service。
- daemon、cloud broker 和模型制品使用不可变 release/selector、校验清单与回滚。
- 公开发布还要求 Developer ID、公证/stapling/Gatekeeper、清洁机安装升级回滚、
  宿主/安全输入、网络、资源和许可证矩阵。
- shell 入口和嵌套依赖已可直接执行，发布 contract fixtures 已通过；真实
  Developer ID 制品、签名、公证、部署与回滚仍未验收，因此不能称为可发布链。

## 10. 现行技术决策

| 决策 | 结论 |
|---|---|
| TD-001 | Rime 是同步主引擎；AI 永远是可失败的增强层 |
| TD-002 | AI 使用单一独立建议位；有 Rime 候选时 Space=Rime、Tab=AI |
| TD-003 | 本地推理放在独立 daemon，输入法不在按键线程运行模型 |
| TD-004 | 云端是独立 opt-in broker；所有路由不携带候选池，键盘 `inference` 路由只返回 generate/abstain；续写联想与语音 `voice_transform`（深度润色/翻译）为独立路由 |
| TD-005 | Secure Input、composition/session/generation/deadline 全部 fail-closed |
| TD-006 | Voice Debug 使用私有 UDS；Release 只使用双向认证 XPC，不降级 |
| TD-007 | ASR 内容完整性与产品 Release 资格分离，production catalog 是唯一审批源 |
| TD-008 | 当前不声称抵御任意 hostile same-UID；相关例外必须保留为显式任务 |
| TD-009 | 整句解码演进走零 prompt 拼音约束解码：LM 只打分，拼音掩码保证合法；prompt 生成路线在 0.5B 冻结集上证伪，不再投入 |

## 11. 维护规则

- 本文件只保留当前 clean baseline 的命令族与汇总结果，不维护测试流水、一次性
  哈希、临时路径或本机签名身份。
- 全局状态只在 [TASKS.md](TASKS.md) 更新；专项文档只维护协议与安全合同。
- 任何“已通过”必须绑定同一 revision 的 clean 命令与结果。
- 历史结果由 Git 与机器可读 artifact/baseline 保留，不再复制到活跃设计文档。
