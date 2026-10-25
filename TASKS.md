# RimeAI 开发任务

| 项目 | 当前值 |
|---|---|
| 更新日期 | 2026-10-24 |
| 产品发布状态 | `NOT RELEASED` |
| 当前工作树状态 | 当前功能边界按可审查提交收口；产品仍不可发布 |
| 当前最高优先级 | `LM-004` 生产数据积累（自动进行中，去重后 231/1000 行）→ `LM-002` 蒸馏臂（**已拍板 2026-10-24**：A+D+B 组合，教师锁定 glm-5.3 序列级；token 级软标签智谱家族实测全灭已关闭，重启触发＝供应商变更） |

本文件是唯一任务状态源。PRD、产品设计、技术设计和专项协议不再维护重复
checkbox 或路线状态。

## 状态定义

| 状态 | 含义 |
|---|---|
| `DONE-INTERNAL` | 内部范围已实现；不代表公开发布 |
| `IN-PROGRESS` | 已有工作树实现，仍在收口或验收 |
| `TODO` | 尚未开始或没有当前完成证据 |
| `BLOCKED` | 依赖前置修复、外部凭据、设备、语料或审批 |
| `DEFERRED` | 明确不在当前发布主线 |

## P0：恢复可复现工作树

| ID | 状态 | 任务 | 完成条件 |
|---|---|---|---|
| BUILD-001 | `DONE-INTERNAL` | 恢复受控 librime XCFramework header 合同 | 3 个 slice 的公开 headers 已恢复并纳入 artifact lock；fresh SwiftPM、macOS、iOS build 均不依赖环境头文件路径 |
| BUILD-002 | `DONE-INTERNAL` | 修复 shell 入口与 harness 可执行位 | tracked 入口和被嵌套调用的 shell 脚本为 `100755`；直接调用及 release contract harness 通过 |
| BUILD-003 | `DONE-INTERNAL` | 固定 iOS 工程唯一生成源 | `ios/project.yml` 使用显式源文件清单；独立 regeneration check 与生成的 pbxproj 完全一致 |
| VERIFY-001 | `DONE-INTERNAL` | 为当前完整工作树建立 clean 验证基线 | 同一工作树快照的 fresh Swift/Python、macOS、iOS、C/C++、shell gates 全部通过；命令族与结果记录于技术设计 |
| REPO-001 | `DONE-INTERNAL` | 收口当前未提交变更 | 所有预期新增文件进入版本控制；变更按可审查边界拆分；无意删除或生成物不进入提交 |

当前工作树已按功能边界拆分提交，且在清除外部 header 搜索路径、使用全新 Swift
scratch/Xcode DerivedData 且启用 warnings-as-errors 的条件下保持内部基线。该
基线不替代签名、公证、清洁机、真机或真实数据发布验收。

## P1：macOS 键盘与云增强

| ID | 状态 | 任务 | 完成条件 |
|---|---|---|---|
| KBD-005 | `DONE-INTERNAL` | 段焦点编辑与定稿中文显示 | 2026-10-13 决策：预编辑区非焦点段显示定稿中文、←/→ 在段间移动焦点、退格按焦点删（活跃拼音→焦点字面量→复活前一段）；CompositionState 段焦点模型（prefixSegments + 焦点 pinyin + focusedSeparatorLiterals + suffixSegments，派生视图拆至 CompositionState+Derived.swift，Xcode 工程已登记新文件）；T1+T2 已落地，KBD-006/007 已随本轮收口；2026-10-16 iOS 门禁修复并复绿：iOS 键盘子集（project.yml 最小 InputCore 清单）自 2026-08-26 云提交起即缺 CloudGeneratedSentencePolicy 编译（构建坏，先于段焦点工作）；策略已拆为独立共享文件并连同 CompositionState+Derived.swift 注册进 iOS 三目标（project.yml 规范化 + xcodegen 再生成 + 生成一致性验证脚本补镜像清单与可执行位）；RimeAIKeyboardTests 单元套件在 iPhone SE3-repro 全绿（UITest 需模拟器预注册键盘的既有环境前提，xcodebuild 重装会重置注册，另见环境注记）；2026-10-16 真机冻结集复评通过：7 场景（exact/abbreviated/near-sound/missing-syllable/partial-selection/mixed-composition/delete-composition）全部切片与 v1 基线逐项一致（candidate_pool_inclusion/conditional_accuracy/accepted/reverted/backspace_cleared 全 1.0），报告 .rimeai/reports/keyboard-interaction-v1.segment-focus.json；撤销粒度变化（macOS 26 TextEdit 将 IME 提交拆为两步撤销）经 A/B 旧构建证实为环境行为，收集器已自适应（自清洁 + 有界撤销）；2026-10-21 随 KBD-001 收口（v3 冻结集 20 场景含段焦点/部分选词类，全部切片 1.0） |
| KBD-006 | `DONE-INTERNAL` | 分段向后重推 | 2026-10-15 落地：焦点段定稿/移动后按批重推后缀段定稿文本（每段一次本地 daemon infer，ranked-only、无段布局；上下文 = 应用内上下文 + 前缀定稿 + 焦点段首选猜测 + 字面量 + 之前后缀段定稿）；批锚 compositionID + 焦点段拼音，批内自身应用只递增 revision，daemon 失败/用户编辑整批作废，无 Rime 候选段跳过；中段数字选词只确认焦点段（Rime 学习照常）+ 焦点自动右移，历史留待最终整句提交一次落库，末段选词路径与旧版逐字节一致；管线拆分 +Cloud/+LocalResult/+Schedule/+SuffixRefinement 四 extension（主文件自包含），SemanticSuggestionDependencies 增 rimeCandidates（显式 init 同步补参）；SwiftPM 468（含 7 个 SegmentFocus 新用例）+ pytest 657 + macOS Xcode TEST SUCCEEDED |
| KBD-007 | `DONE-INTERNAL` | 云端整句按段接受 | 2026-10-15 落地（交互决策与原 TODO 不同，经用户确认）：跨段整句建议（段数 ≥ 2 且覆盖全部段）Tab 改为按段应用不提交——`CloudGeneratedSentencePolicy.segmentTexts` 按分隔符拆分（与结构校验同口径），`CompositionState.applySegmentedSuggestion` 写入前缀/焦点/后缀各段定稿后用户 ←→ 逐段复核，Space 整句上屏；任一段无法转换到用户字形或单段建议时回退既有 Tab 提交路径；焦点移动使云端建议失效的既有守卫不变；测试见 SemanticSuggestionPipelineSegmentFocusTests；剩余：真机验收计入 KBD-001，历史 source 归因（最终 Space 提交记 rimeMain）为已知 v1 简化 |
| KBD-001 | `DONE-INTERNAL` | 完成真实键盘效果闭环 | 2026-10-21 收口：冻结真实输入集扩充至 20 场景（`datasets/keyboard-interaction-v3.jsonl`，7 类各 3 场景、delete 类 2 场景，v1 场景保留作回归锚；含简拼/缩写、音近、漏音节、无空格混输、部分选词、删除组合）；自动收集（AppleScript 打键）+ `evaluate-keyboard` 报告：全部交互切片 1.0（candidate_pool_inclusion/conditional_accuracy/accepted/reverted/backspace_cleared，报告 `.rimeai/reports/keyboard-interaction-v3.json`；delete 类切片 0.0 为场景语义与 v1 一致）；0.60 运行门 LM-001 后重评（`docs/baselines/kbd001-completion-evidence.json`）：beam v3 制品 + 974 test 样本上 0.40–0.70 门扫描决策分布双峰一致（decoder 句准确率差 ≤0.31pp），0.60 位于平坦区维持不变（baseline 0.727 vs decoder 0.789，+6.2pp）；神经迟到帧独立门控（DaemonProtocol 量纲冻结）。发布后真实使用持续观察不阻塞收口 |
| KBD-002 | `DONE-INTERNAL` | 统一 Debug 与 Release 模型制品 | 2026-10-16 结构修复：runtime ONNX 加载路径曾是死导入（`rimeai_runtime.onnx_ranker` 从未存在，daemon 加载 INT8 model_type 即 ModuleNotFoundError，Release PyInstaller 包不含 torch 故不可回退浮点路径）；现新建 `rimeai_runtime/onnx_ranker.py`（仅 onnxruntime，Python 3.9 工具链），eval 包保留导出/量化与 RankerError/Ranking 评估适配，daemon 诊断 neural_ranker 条目新增 model_type 字段；CharLMScorer 协议成员改只读属性修型变；等价性证明完成：冻结测试集（p0-librime-luna-simp test，974 样本，candidate_limit 10）上浮点 vs INT8 排序 top-1 一致率 99.38%、top1_accuracy 差 -0.10pp（INT8 0.7577 vs 浮点 0.7587）、置信度绝对偏差均值 0.0038、INT8 p50 延迟低 8.5ms（报告 .rimeai/reports/ranker-float-vs-int8.json）；产品决策采用双制品目标（Debug/本机浮点、Release INT8），均由 load_neural_ranker 按 manifest model_type 加载；Release builder 全流程重跑成功（preview-4-segment-focus，120 Mach-O 校验/签名/hardened runtime 全过，context-ablation 门曾因探针 daemon 默认加载本机用户画像而假失败——构建脚本现显式钉死缺失 user-lm 路径，发布验证确定性且 artifact-scoped）；TECHNICAL_DESIGN §4.2 与诊断已显示实际 artifact |
| KBD-003 | `DONE-INTERNAL` | 上屏后智能续句联想（post-commit continuation） | 2026-10-12 完成：默认关闭 opt-in；broker continuation 路由与校验梯 + 真实 qwen3.5:0.8b few-shot 冒烟 10/10 GO（无白名单变更）；协调器/面板/接线完成；真实键盘验收通过（chip 显示、Tab 接受、链式续写、8s 自动隐藏、击键/切会话撤销、开关关闭零请求、历史库 source='continuation' 落库）；修复 broker history_index 无 pinyin 键 KeyError 与 selectMainCandidate 绕过 commitText 两个真实缺陷；review 修复迟到续写帧拆连接/失活后仍 arm/Shift+Tab 误接受；续写 prompt 升级为"逐字紧接/没把握弃权"；已知边界：0.8b 对名句逐字接续会串句，按 Ruling 不做确定性索引补丁，等引入更大模型解决；回归 448 InputCore + 40 macOS + 560 pytest 全绿 |
| KBD-004 | `DONE-INTERNAL` | 整句拼音约束（单一 loose 策略） | 设计变更 2026-10-13：三档约束（exact/fuzzy/loose）移除，仅保留 loose 行为，无用户设置、无 `pinyin_alignment` 请求字段；模型可纠前后鼻音/平翘舌/错别输入，≤128 字符（broker 拒控制字符，>0x20 标量与分段非空段由 Swift 客户端最终把关）、中英混排、segments 分隔符按序复现、anti-echo 用 recent_context 尾部重叠检查；pinyin 输入无条件 `[A-Za-z']` ≤256 字节；broker（cloud_model.py/server.py 单一提词与校验梯）+ 客户端（PinyinAlignmentMode 删除、CloudGeneratedSentencePolicy 单一策略）全链路 |
| KBD-008 | `DONE-INTERNAL` | 部分选词段保留（无分隔符修正） | 2026-10-21 收口（实施+验收证据齐：SwiftPM 520/macOS Xcode 40/pytest 733 全绿；v3 冻结集 partial-selection 3 场景全 1.0 覆盖新行为选词+space 整句上屏；← 回修状态机由 retainFocusedSegmentAsPrefix+moveFocusLeft 单测覆盖——收集器暂无回修探针，端到端回修链自动化留作收集器后续增强）。设计提案 `docs/PARTIAL_SELECTION_DESIGN.md`（D2/D3/D4/D5 已拍板 2026-10-21：历史/热词推迟到最终整句提交一次落库；统一改造末段焦点部分选词；接受撤销语义变化）；本轮落地：`CompositionState.retainFocusedSegmentAsPrefix`（焦点段以所选候选定稿入前缀+焦点字面量运行并入，段拼音只记被消费前缀防历史重复，剩余拼音非法时空守卫回退 false）+ `selectMainCandidate` 新分支 `retainPartialSelectionInComposition`（末段焦点部分选词不再上屏，剩余拼音成新活跃段可 ← 回修，历史/热词留待最终整句提交；校验失败回退既有提交路径字节级一致）；顺手抽出 `appliedSelectionTransition`（rawLeadPrefix 合成候选 transition 调整块，纯行为等价重构，满足 function_body_length）；测试新增 CandidateSelectionTransitionTests 3 用例（段保留+回修/非法剩余拒绝且状态不变/字面量运行并入）；SwiftPM 520 全绿 + macOS Xcode TEST SUCCEEDED（40）；剩余：无（冻结集 v2 复评通过：7 场景全部切片与 v1 基线逐项一致，报告 .rimeai/reports/keyboard-interaction-v2-kbd008.json；输入法重装后 TIS 注册被重置需手动重添加 + TIS API 核实启用态，⌃Space 切换收集器前置；新行为（前缀保留预编辑区）为中间态，最终文档文本与撤销探针与 v1 等价）；真实键盘全链体验验收随 KBD-001 流程；iOS 范围外（iOS 键盘尚未接入段焦点模型） |
| LM-001 reveal 对抗审查修复轮 | `DONE-INTERNAL` | 双延迟档整句架构对抗审查加固（P1×1 + P2×7 + P3×9） | 2026-10-20：跨家族三审 + 交叉验证（P1 为机械复现）；仲裁反向序兑底（神经帧已接管后，后到的同步 ok/timeout 帧只消费槽不改展示，superseded_by_neural_late）；迟到帧改按 requestID 路由（发送登记/帧到取回，多 controller 不再互踩）；预算 deadline 下传 worker 读 + 提交前过期预检 + 交互部署 timeout_ms 封顶 5s；close 先 terminate 后关管道 + kill 后 wait + 打断不计熔断 + 冷启动首读豁免 30s + 连续 5 轮冷却永久弃权；有界行读拒超长行；迟到帧 script-mismatch 复用字形转写；结构门双侧补齐（server min_confidence / Swift 可打印字符）；worker per-request 异常 fail-closed + 请求后回滚释放 beam 尾行；stderr 不再丢弃、stats 死请求移除；加固条款冻结于 TECHNICAL_DESIGN §4.3.1 |
| LM-001 | `DONE-INTERNAL` | 整句解码切换为零 prompt 拼音约束路线（部署化） | 2026-10-19 完成：MLX 8-bit 制品（隔离 venv，mlx 0.32.4/mlx-lm 0.32.2，lock `models/qwen2.5-0.5b-mlx-8bit.lock.json`；4-bit 被证据否决——种子边界分布場塌，见 lock precision_decision）；`rimeai_runtime/mlx_worker.py` 单一持久 prompt cache，beam 跨路径与跨请求共 prefix 回退增量喂入（per-path 正确性保持，确定性测试 `tests/test_mlx_worker.py`）；冻结集句准确率 0.921971 与 fp16 完全一致、逐样本建议一致率 99.8%（净错误差 0），p50 115ms vs fp16 252ms，基线 `docs/baselines/constrained-qwen-v3-mlx.json`；daemon 异步神经臂（`rimeai_daemon/neural_sentence.py` + server `sentence-late` 迟到帧，capability 门控旧客户端，专用执行器不阻塞同步 infer，close 有界拆除），Swift InputCore 迟到帧接受/过期/失活/云槽/结构全 fail-closed（`NeuralSentenceLateTests`）；本机 LaunchAgent 路径真机冒烟：同步 result 0.01s、神经迟到帧交付、hello 诊断含 neural_sentence 条目；仲裁规则冻结于 TECHNICAL_DESIGN §4.3.1；Release/PyInstaller 打包 MLX 与 LM-002 SFT 未包含 |
| LM-002 | `TODO` | 约束解码 SFT | 配方：PinyinGPT 式软标签蒸馏为默认形态（LoRA 作低成本对照），零 prompt/零 chat template 保持不变（TD-009）；基座对照 Qwen 0.5B/2B/4B；作用靶为错误归类的 `model_path_miss` 桶（61/76 真实错误，词典召回与拼音对齐零损失）。配方与门见 [docs/CONTINUOUS_OPTIMIZATION_LOOP_DESIGN.md](docs/CONTINUOUS_OPTIMIZATION_LOOP_DESIGN.md) §4 阶段 C：数据来自 LM-004 冻结数据集（绑定数据集 sha256）；门＝冻结集句准确率 ≥ 现制品 +2pp 且 `model_path_miss` 桶下降 ≥50%、词典基线已命中的 708 样本无新增覆盖损失、p50 延迟与峰值 RSS ≤ 现制品 ×1.2（冻结集与真实历史 80/20 留出集双跑）；制品为 MLX 8-bit + lock（数据集 sha/超参/代码版本/上一版指针，可回滚）。前置：LM-004 → LM-003。**对照臂已落地**（2026-10-21，c06f601）：QLoRA 零 prompt 形态 over 钉死 8-bit base（8044 行 zero-prompt 续写：seed+context+gold；lr 1e-4/batch 4/seed 42，检查点扫描选 2k）句准确率 0.921971→0.941478（+1.95pp）、`model_path_miss` 61→44（-28%）、失败 76→57、回归 11→7、p50 124ms（+8ms）；4k/6k 过拟合（0.9394/0.9148，val loss 5k 后升）；mlx_worker 支持 artifact.manifest.json 制品治理（钉死校验与 model_artifact_id 随 manifest，缺失时内置 pin 不变）+ `RIMEAI_MLX_MODEL_DIR` 评估旁路（产品默认路径不变），验证仍 fail-closed；制品/配方/评测冻结于 `models/qwen2.5-0.5b-mlx-8bit-sft.lock.json`；pytest 739 + SwiftPM 520 + worker 套件 33。对照臂不过门（+2pp/-50%）为预期，默认软标签蒸馏臂须以 0.941478 为 beat 目标；**教师路线已拍板（2026-10-24，用户）：A+D+B 组合，教师锁定 glm-5.3 序列级**——D 骨架（硬标签臂 + LM-004 真实数据重训，0.5B/1.5B 同数据同超参双跑，门不变）；A+B 合流数据放大器（glm-5.3 批量造数：拼音种子→教师生成→词典对齐过滤器（D4 工程化：可被本地词典掩码复现才进，不可复现丢弃计数）→泄漏检查 v2→与真实数据混合）；token 级软标签正式关闭（智谱家族 glm-5.3/4.7/4-flash × coding/paas 全部静默忽略 logprobs，矩阵实测 2026-10-24，重启触发＝供应商变更），详见 docs/LM002_SFT_BASELINE_REPORT.md §7；**数据扩充臂已落地（2026-10-24，de13718/f784c79）**：tools/teacher_synthesis.py（并发 4 线程池、每线程独立 client）+ build_sft_dataset --teacher-synthesis 混合（同键真实优先）；4000 种子造数 kept 931（abstain 1705 + 对齐丢弃 1364 = D4 过滤器正确拒教师自由改写），混合数据集 1124 行 usable=true 提前达标；**D 臂首日四配方全景（负结果，详见报告 §10）**：新数据在当前短句形态下是单调稀释项（纯新 0.7084 负迁移 / 混合×1 0.9343 / 混合×3 0.9240 vs 对照臂纯 zhwiki 0.9415），根因=造数句 2-5 词 vs 评测长句不同构，非 iters 问题；剩余：teacher_synthesis 长句模式重造数（4-12 词对齐评测分布）→混合×1 重训、1.5B 学生随长句数据一起跑、真实历史留出集门侧；**2026-10-25 §10.5 重大更正：mix1 真实分布增益系训练记忆**——训练快照（sft-lm002d-mix1/train.jsonl 899 行 sft 尾部）含 holdout 12 行 verbatim 泄漏（含 baidu，训练行 '。baidu'），剔全部 13 个 overlapped 键后的 35 行干净集（real-holdout-v3，键级交集 0 + sft 尾部 899 行文本级 verbatim 0；zhwiki 部分含 7 个 gold 的 4 字/英文子串偶现已披露，键级不受影响）上基线 = mix1 = 0.8857（+0.0pp）；门①真实侧今后以 35 行干净集为基准（干净线 0.9057；门②仍为 model_path_miss 桶），教师占比相对结论（lm002e 劣 6.5pp）不变 |
| LM-003 | `DONE-INTERNAL` | 决策日志与偏好对采集（闭环传感层） | 2026-10-21 设计冻结（[docs/CONTINUOUS_OPTIMIZATION_LOOP_DESIGN.md](docs/CONTINUOUS_OPTIMIZATION_LOOP_DESIGN.md) §4 阶段 A）；进程归属已拍板：decision_log 归 daemon、云端决策 broker 写穿。**Python 侧已落地**：`rimeai_daemon/decision_log.py`（bounded queue + 单 writer 线程，满队丢弃不阻塞推理；UNIQUE(source,request_id) 幂等；环形裁剪 60d/50k/每 1024 条；拼音≤256B、建议≤128 字、不记按键/上下文/候选池）；daemon server 接线（hello 通告 `sentence-feedback` capability、`sentence_feedback` 帧解析 newest-pending→outcome 且同请求旧行→superseded、同步 infer ranked/sentence 与迟到帧交付后写 display 事件、`--no-decision-log` 开关、close 有界）；broker `decision_journal.py` 写穿 `cloud-decisions.db`（`CloudModelClient.rank` 缓存命中与新鲜路径都记 generate/abstain，journal 故障仅告警不失败请求）、broker server `sentence_feedback` handler + capability、`--no-decision-journal` 开关。测试 13 新增（9+4），全量 778/778。**Swift 侧已落地（2026-10-22 晚）**：`DaemonSentenceFeedback` 帧（fire-and-forget）+ `DaemonClient` hello capability 快照门控（`sentence-feedback` 通告才发）+ 管线 `displayedFeedback` 状态与三 hook（markAdopted/markRejected/expire，一次性消费）+ 展示位登记（同步结果/字形回退/神经迟到帧→daemon 通道，云建议→broker 通道，云接管本地先发 superseded）+ controller 五个发射点（selectSemanticCandidate 采纳、selectMainCandidate 语义采纳/数字与 Space 选词拒绝两条路径）+ `CloudBrokerClient` 同形帧与 capability 门控；SwiftPM 525/525（新增 `SemanticSuggestionPipelineFeedbackTests` 5 用例：adopted 一次性/expired/rejected/superseded 接管/静默无建议）+ macOS Xcode 40/40。**真机端到端收口（2026-10-23/24）**：环境级 TIS 注册损坏（selectCapable=false，disable/enable/kickstart 均无效）经注销重启自愈；GUI 真打字验证全通——decision_log 满血（`jintian…`/`local_senten…` 条目实时落库，24h 新增 1171 行，outcome 回填真实工作：adopted=3/rejected=224/expired=807/superseded=29/pending=153），云/本地双行候选对比 UI 同帧实拍验证（“今天天气很好”双臂首选一致时合并单行，不一致时双行）；`phrase_book`/`continuation` 源 v1 不落行维持不变；发布验收计入 RELEASE-001；**假阴性修复（2026-10-25，51327a0）与端到端验证（同日）**：`markDisplayedSuggestionRejected(committedText:)` 同文上屏（展示建议与提交文本逐字相同）改发 `adopted_via_main`（保留路径信息），文本不同才是真 rejected；daemon/数据管道 OUTCOMES 新增该值。验证证据＝部署（18:25）后真实使用打字产出 300+ adopted_via_main 行（该 outcome 值部署前 DB 不存在，first_seen 20:17），审计 join history_commits 同文占比 98.4%、rejected 侧 84% 不同文（真拒绝保留）；osascript/TextEdit 冒烟因用户焦点竞争未命中同文场景，如实放弃该主张。**fallback 验证结论（pending resolve）被 REFUTE**：post-fix neural_late pending 534/1963（27.2%）未 resolve——`setDisplayedFeedback` 仅云接管本地时发 superseded，本地帧被更新本地帧替换时旧行静默孤儿化（pre-fix 另有 ~630 行 backlog，2026-10-23 起）；孤儿化修复已列 /list 队列 |
| LM-004 | `IN-PROGRESS` | 离线蒸馏数据管道（LM-002 数据前置） | 2026-10-21 设计冻结（同上文档 §4 阶段 A）；**工具已落地**：`tools/build_sft_dataset.py` 读 daemon `decision_log.db` + broker `cloud-decisions.db`（拍板双库）+ 可选 `history.sqlite3`（rejected 建议的 chosen 侧经同拼音 60s 窗口 join，权重 0.7；adopted 直出 chosen-only 权重 1.0；pending/superseded 跳过；云侧只取 adopted generate 教师正样本；按 (pinyin, chosen, rejected) 去重）→ 冻结 jsonl `{id, pinyin, chosen, rejected, weight, source}` + `datasets/sft-constrained-v1.lock.json`（数据集 sha256、生成器版本、源区间、计数/去重统计、usable 旗标、leak_check 记录）；输出 0600；泄漏检查＝冻结评测集 validation+test 拼音键（实测 1060 键）零重叠、有重叠 exit 4 且不写任何文件；`--min-samples`（临时默认 1000，终值由 LM-002 配方定）不足→lock 标 usable=false + exit 3 报「数据不足不启动训练」；仅服务 LM-002，不扩展为教师平台。测试 13 新增、全量 791/791。**剩余**：生产数据积累（需新 daemon/broker 部署 + 真实使用）、LM-002 默认蒸馏臂消费该数据集。**首跑（2026-10-24）**：真实数据试产出 231 行（205 unique pinyin，usable=false，exit 3 按预期报数据不足不启动训练，制品供检查）；泄漏检查 v2 语义落地——重叠样本剔除不写入（lock leak_check 记 overlapped_pinyin/dropped_rows/policy），取代 v1 零重叠整体拒绝（真实使用必含评测集高频拼音，首跑 14/227 行被剔；评测完整性不变），工具 VERSION 2，测试 13/13 |
| CLOUD-001 | `BLOCKED` | 放行固定云候选链路 | 使用真实凭据、冻结语料和目标网络通过覆盖增益、98% 纠错 precision、800ms、stale/SEI、费用/限流/代理/撤权矩阵 |
| CLOUD-002 | `DONE-INTERNAL` | 清理旧 Qwen/阿里云/wwcn 口径 | 2026-10-13 完成：`rimeai_cloud_broker/qwen.py` 更名 `cloud_model.py`，`QwenCandidateRanker`/`QwenBrokerError` 更名 `CloudModelClient`/`CloudBrokerError`，全部 "Qwen ..." 错误文案改中性 cloud 口径；隐私中心用户文案（云端数据流、明文 Key 存储位置）与 candidate panel 无障碍标题/tooltip 改中性云端建议/纠错；PRD/PRODUCT_DESIGN/TECHNICAL_DESIGN/README/CLOUD_INPUT_IMPLEMENTATION 统一为智谱 Coding Plan 直连 + generate/abstain 无候选池合同；LaunchAgent 安装脚本导入检查同步更新。`fun.wwcn.*` 为代码签名 bundle ID 事实标识、`tools/qwen_sentence_worker.py` 与 `models/qwen2.5-0.5b` 为真实 Qwen 离线实验工件，均非误导声明、保持不变。全量 grep 复核无残留误导 provider 声明；pytest 574、InputCore 449、macOS 40 全绿 |
| RELEASE-001 | `BLOCKED` | 放行 macOS 公开预览 | 公证/Gatekeeper、清洁机安装升级回滚、代表宿主与 Secure Input、系统级抓包/日志、最低硬件、许可证和用户指标全部通过 |

## P1B：用户语言画像学习

设计与合同见 [docs/LANGUAGE_PROFILE_DESIGN.md](docs/LANGUAGE_PROFILE_DESIGN.md)。产物分三层（L1 短语库、L2 用户 LM、L3 风格画像），由空闲固化循环生成；原始历史固化后按合同淘汰原文。

| ID | 状态 | 任务 | 完成条件 |
|---|---|---|---|
| LP-001 | `DONE-INTERNAL` | HistoryStore 固化状态与淘汰 | `history_commits` 增加 `consolidation_state` 与固化水位线；满足“统计完成且（L3 完成或显式跳过）”的批次删除原文并 bump generation；崩溃后可由水位线续跑；单测覆盖双删条件与旧索引失效（9/9） |
| LP-002 | `DONE-INTERNAL` | L1 短语库存储与管理 | 存储层、拼音/域查询、保护/删除、域映射、迁移 API（11/11）；设置页"语言画像"含学习状态、画像概要、短语管理（添加/切换保护/删除）、域映射编辑器（增删/改名合并/删除域）与云压缩开关 |
| LX-001 | `DONE-INTERNAL` | 领域词库能力（schema v2） | `DomainLexiconStore`（安装/替换/启停/卸载/跨读音屏蔽/域迁移级联）+ Rime `.dict.yaml` 导入解析器 + 快照融合查询（学习短语优先于词库，12/12）；设置页"领域词库"面板（导入/启停/卸载/词条浏览/屏蔽）；构建工具 `tools/build_domain_lexicon.py`（6/6）与示例词库 `lexicons/it-programming`（215 词条 CC0）；设计见 [docs/DOMAIN_LEXICON_DESIGN.md](docs/DOMAIN_LEXICON_DESIGN.md) |
| LX-002 | `PLANNED` | 领域词库后续 | 词库在线更新通道、更多预置领域（医学/金融/法律）、英文 token 融合进 `englishTokens`、真实用户导入雾凇 cn_dicts 冒烟 |
| LP-003 | `DONE-INTERNAL` | L2 用户 LM 与融合插值 | 每域+global 计数、单 commit 频次上限；两层插值按有效样本量收缩自适应（MAX_USER_WEIGHT=0.35 经首评校准）；域/全局数据不足时退化为现基线（9/9） |
| LP-004 | `DONE-INTERNAL` | 固化循环调度与本地统计 | 空闲≥10 分钟或每日触发、进程内单例锁、单轮分批（批间水位线）；仅处理窗口（7 天）外 `raw` 增量；幂等水位线 + 跨进程事务性领取；固化单属 broker（daemon 只消费产物）（8/8） |
| LP-005 | `DONE-INTERNAL` | L3 风格画像与混合压缩 | 画像 JSON 版本化、merge、单调 rollback 与 `locked_fields`；云压缩走 broker（glm-5.3-flash），无凭据显式跳过且不阻塞统计；坏摘要保留旧版（9/9）；画像仅存储于 broker 本地（merge/rollback），不进入推理 prompt（2026-10-12 决策：prompt 只含 pinyin/recent_context/segments） |
| LP-006 | `DONE-INTERNAL` | 运行时注入 | L2 进入 daemon engine 排序融合（15/15）；L1 短语建议位仲裁：本地+云均无建议时以 `phrase_book` 决策填充独立建议位（数字候选不可移动，pipeline 34/34）；混输个人词表切换到 PhraseBookStore（legacy 256 词幂等迁移 + 接受即学习）；真机冻结集复评计入 KBD-001 |
| LP-007 | `DONE-INTERNAL` | 分域映射与回退 | bundleId→域映射、域改名/合并/删除；commit<50 冷启动回退 global；域优先+global 合并查询链（含在 10/10） |
| LP-008 | `DONE-INTERNAL` | 评估闭环与文档修订 | 时间切分评估器（4/4）；真实历史首评完成（4356 条）：学习增益 +0.299 nats/字、短语命中率 52.3%（>30% 门）、泛化 gap 0.94；冻结集 top1 标注为泄漏监控；报告存 .rimeai/reports/language-profile-first-eval.json |
| LP-009 | `DONE-INTERNAL` | L3 `signature_phrases` 回灌 L1 | 2026-10-21 落地；2026-10-25 全量回归确认后收口（pytest 854 / SwiftPM 528 / macOS Xcode 40 全绿）：新增 `rimeai_daemon/llm_backfill.py`（无状态 reconcile：插入当前画像签名短语 source='llm'/count=0/protected=0，`ON CONFLICT DO NOTHING` 不覆盖真实打字证据；清理不在当前集合且 protected=0 的 llm 孤儿条目；词典不可用整轮跳过 fail-open）；注音 = Rime 词典词级全匹配→贪心最长匹配置回退，多音字确定性选字典序首读音；`consolidation._upsert_phrase` auto 累积加 `WHERE source != 'llm'`（设计「不参与自动频次累积」）；`make_semantic_consolidator` 新增 `signature_backfill` 回调（逐域合并后触发，失败仅告警不致败批）；broker `--signature-dictionary`（默认 `.rimeai/rime/shared/luna_pinyin.dict.yaml`）接线；Swift 侧零改动（`PhraseEntrySource.llm` 已存在、建议位查询无 count 过滤、快照 100k 上限，LP-010 20k 容量保证不被截断）；已知 v1 行为：用户删除 llm 行后若画像仍含该短语则下轮回灌恢复（protected 为持久退出机制）；测试 `tests/test_llm_backfill.py` 12/12（含幂等/不覆盖/孤儿清理/auto 不累积/回调触发与失败隔离）+ consolidation+profile 36/36 |
| LP-010 | `DONE-INTERNAL` | L1 时间衰减与容量上限 | 2026-10-22 落地（数值由 2026-10-21 前置分布报告定值：count p50=1/p99=18/max=261，窗口 ~10 天→时间衰减不可校准）：`ConsolidationPipeline._prune_phrasebook()` 在统计阶段 `_update_phrasebook` 后触发——**仅容量触发**（20,000 → 淘汰至 19,000），半衰期 45d 只定淘汰顺序（score＝count×0.5^(idle/45)，Python 计算因 SQLite pow 依赖编译开关；score/count/last_used 三键定序）；`protected=1` 与 `source='user'` 豁免；删除走静态 `json_each(?)` IN-list；容量/目标/半衰期为 ctor 参数可测；`ConsolidationReport` 新增 `phrasebook_pruned`。已知语义：llm 源 count=0 条目衰减分 0 → 容量触发时最先淘汰（llm 为最低信任层，protected 为持久退出，与 LP-009 一致）；被淘汰短语重打从 count=1 重新开始（不复活旧频次）；半衰期待数据 ≥60 天后重评。测试：新增 5（低于容量 no-op/最低分先行+豁免/停在目标/淘汰后重计从 1 开始/统计阶段内集成含报告字段），全量 805/805 |
| LP-011 | `DONE-INTERNAL` | L2 计数聚合幂等（范围裁决后） | 2026-10-22 范围裁决（用户授权决策）：原 reveal finding「连续 run ≤3 段压缩 + drain/throttle」已不可考且无实证收益（实测 user-lm 137KB gzip / load 6.6ms / serialize 5.0ms，每轮固化单批 512），不做臆造重建——压缩降为量化证据门：user-lm.json.gz ≥5MB 或 load+serialize ≥500ms 才重评。落地核心：`UserLanguageModel.fold(domain, items)` 按 commit id 聚合去重（同 token 至多计一次；环形容量 2048 >4× 批上限，覆盖 15 分钟 claim 过期重取窗）；schema v2 per-domain `folded_tokens`（v1 兼容加载空环——升级前批次均在水位线后；Swift 侧只透传 domain 值不校验版本，rename/merge 级联不受影响）；`_update_user_lm` 改 fold 接线，崩溃重取不再双计 L2（L1 频次/域统计重取仍可能重计，benign 计数器，consolidation docstring 已如实标注）。测试：user_lm 新增 9（幂等/乱序一致/环驱逐/批内去重/v2 round-trip/v1 兼容/容量校验）+ 固化崩溃重试集成 1；全量 800/800 |
| LP-012 | `DONE-INTERNAL` | 闭环离线回归门 | 2026-10-22 脚手架落地（同日 P95 harness 补齐）：`tools/run_loop_gates.py` 单命令三门出报告（`.rimeai/reports/loop-gates-v1.json`），指标级 pass/fail/pending、门取最差、总体取最差，exit 0/1/3；`--only`/`--sidecar-report`/`--model-summary`/`--run-model-gate`/`--typing-path-report`/`--collect` 分级迭代。**字段映射裁决（证据背书）**：外挂层门「top1 净增益 ≥+2pt」降为 monitoring-only（frozen_top1_caveat 自证 leakage 主导）；不可考的 0.94 泛化 gap 公式替换为可定义无塔陷检查（user_test > baseline_test）；P95 延迟回归由新建 `tools/benchmark_typing_path.py` 度量（A/B 交错同请求序列 engine.infer(allow_sentence=False)，L2 开/关双引擎，thermal 漂移对消；--user-lm 默认真实 artifact）。**真机实测（2026-10-22）**：P95 delta＝0.072ms ≤ 1.0ms 预算（基线 0.086ms→L2 开 0.158ms）；sidecar 门 PASS（增益 2.555 nats/命中率 51.8%/无塔陷/P95 ✓）；e2e 门 PASS（真实 v3 报告 20 场景，vacuous-0 语义）；model 门 pending（设计如此，`--run-model-gate` 跑冻结 reproduce，torch 族替代 MLX——LM-001 已证 99.8% 一致，地板 0.90/1.5×p50，晋级门归 LM-002）；overall pending/exit 3（唯一剩余＝model 门实跑，随 LM-002 收口）。测试 19 新增（含 typing-path 三态）、全量 824/824 |

## P2：语音产品资格

| ID | 状态 | 任务 | 完成条件 |
|---|---|---|---|
| VOICE-001 | `BLOCKED` | 取得产品模型与质量资格 | 完成来源、模型权利、再分发和质量审批；production catalog 非空；至少 200 句授权且说话人隔离真实语料通过质量/延迟/资源/热词误伤门 |
| VOICE-002 | `BLOCKED` | 建立正式性能与发布证据 | 与真实 corpus/run 和产品三进程绑定的 authenticated schema-3 evidence 完整通过；schema-2 tracer 不再被当作替代证据 |
| VOICE-003 | `BLOCKED` | 完成真实平台发布矩阵 | 依赖 VOICE-001/002；安装后的命名 XPC、TCC、麦克风/蓝牙/USB、代表宿主、no-INET、无音频落盘、公证、清洁机升级回滚全部通过 |
| SECURITY-001 | `TODO` | 消除 sherpa pathname 同 UID 例外 | 落地 fd/buffer/pread API 或兼容性冻结 fork，并通过 hostile same-UID、重复打开和清理回归 |

## P3：iOS 可行性

| ID | 状态 | 任务 | 完成条件 |
|---|---|---|---|
| IOS-001 | `DEFERRED` | 收口 iOS 内部可行性 | 完成真机内存/生命周期/宿主矩阵和最新 TestFlight 验收；Simulator 与部分候选后缀回归只作为内部前置证据 |
| IOS-002 | `DEFERRED` | 决定是否接入 24M 神经排序器 | 给出扩展内存、延迟、包体与收益预算；没有净收益证据则保持 n-gram |

## 已完成的内部里程碑

| 范围 | 状态 | 边界 |
|---|---|---|
| Rime 同步主链、稳定候选与独立语义位 | `DONE-INTERNAL` | 同一工作树快照的 SwiftPM、macOS 与 iOS 严格基线已通过 |
| 24M + n-gram 候选排序与拼音约束 beam | `DONE-INTERNAL` | Debug/Release artifact 尚待统一 |
| 零 prompt 拼音约束 LM 整句解码对照 | `DONE-INTERNAL` | Qwen2.5-0.5B base 仅做 next-token 打分、合法性由冻结词典拼音掩码强制（beam width 4，无提示工程、无 thinking、无 chat template）：冻结集 92.2% 句准确率 vs 词典基线 72.7%（t2s 校正繁简标签伪影后等效 95.6%）；prompt 生成路线同集 72.6%（910/974 空建议）证伪；错误归类显示词典召回与拼音对齐零损失，剩余真实错误为模型路径选择（LM-002 SFT 靶）；评测阶段产物，未接入产品链（LM-001） |
| 真实键盘交互冻结集 v1 | `DONE-INTERNAL` | 七类真实键盘场景、实际候选面板读取、接受/撤销/退格报告器与 0.60 复评入口已建立；Secure Input、stale result 与完整 KBD-001 数据集仍未关闭 |
| 无空格混输、个人英文词和部分候选后缀 | `DONE-INTERNAL` | 部分候选只提交确认前缀，严格验证后的原始拼音后缀继续组合；原生与跨平台回归已纳入 clean baseline |
| IMK 强制提交原样上屏 | `DONE-INTERNAL` | 切换输入法/宿主终止会话时活跃拼音原样上屏、定稿前缀按定稿文本上屏，不再上屏高亮候选（与 squirrel 一致）；deactivateServer 兼作兜底；xcodebuild build/test 与 `swift test --filter RimeAIInputCoreTests`（406 项）通过，真实键盘 ⌃Space 切换实测通过 |
| 设置四页、导入导出、恢复默认和可录制语音快捷键 | `DONE-INTERNAL` | 启停按依赖顺序串行收敛，daemon 必须通过协议握手与 Offline Lock 验证；真实 AppKit/服务矩阵仍属发布验收 |
| 输入源设置页与菜单栏分面图标 | `DONE-INTERNAL` | 设置页保留逐像素一致的横向徽标，菜单栏使用与系统徽标一致的 22×16 模板图标；资源、plist 与 Release ZIP 合同已锁定，本机 TIS 与菜单栏实测通过，清洁机及双外观验收仍属发布门 |
| candidate-ID-only 云 broker 与明文历史控制 | `DONE-INTERNAL` | 真实云效果与发布未放行 |
| 语音 V2 协议、UI、helper、XPC 代码、ASR 制品/评测/tracer | `DONE-INTERNAL` | 仍是默认关闭技术探针，不具备产品资格 |
| iOS 离线 librime + 紧凑 n-gram 原型 | `DONE-INTERNAL` | fresh Simulator unit/UI 基线通过；非产品支持，最新真机验收未完成 |
| 语言画像 reveal 对抗审查 P1 加固 | `DONE-INTERNAL` | 2026-10-19：跨轮固化水位契约（statistics_watermark 持久化 + 停用清除/首轮/恢复/开启-关闭-开启语义）；renameDomain 重算 id 且开库修复漂移；daemon/broker/Swift 三侧统一域名校验（`PhraseBookDomain.validate`）；停用降级即时生效（`_refresh_user_lm` OSError 无条件清空）；导出聚合三层（GzipCodec 字节级兼容 Python gzip + LanguageProfileExport）；清除补删 L2 user-lm；RimeAIPhraseBookService 按职责拆三 extension；Swift 488 + pytest 668 + macOS Xcode BUILD SUCCEEDED |
| 语言画像 reveal 对抗审查 P1B/P2/P3 加固 | `DONE-INTERNAL` | 2026-10-19：L3 固化改为“fresh/statistics_done 拆分 + 语义失败即释放 claim 重试”双状态机（statistics_done 语义重试积压、semantic_watermark 与 L2 计数解耦）；broker 单实例守卫（flock + pidfile 拒绝启动）+ 画像跨进程 locked() + 凭据每轮重评估（_semantic_consolidator 改 provider）；L3 ProfileStore 修订排序/裁剪/_archive 毫秒时间戳修复；域改名/删除级联 L2/L3 产物（LanguageProfileArtifacts + service 接线）；云端设置页补批量上云披露（≤24KB/域/轮，按 UTF-8 字节计）+ cloud-debug 只记元数据 + 凭据损坏区分「凭据无效」；快照 60 条改为保护优先；PhraseBookStore 缓存条数改 LIMIT 绑定。**更正**：原记录中的“L2 计数改为按 token 聚合”“连续 run 压缩（≤3 条/域）+ 前台/会话边界 drain + throttle 开关接线”在本仓无任何实现落点（`git diff ee4a195 0ab0250` 与全仓 grep 均无命中，`rimeai_daemon/user_lm.py` 本次未改），已降级为 PLANNED（见下行） |
| 语言画像 reveal 对抗审查修复轮（审查发现项） | `DONE-INTERNAL` | 2026-10-20：导出文件改 0600（权限重设失败即报错）+ 导出条目上限 50,000（带 `truncated` 标记）；broker 拒绝 group/world 可读凭据文件（`CredentialPermissionError`）；L3 可用性三分（永久未开启 → 积压判终态并 evict；凭据临时故障/空值 key → 积压保留重试）；云端上传预算改按 UTF-8 字节（24KB/域/轮）并做行对齐字节截断；评测按域分组交叉校验截断占比（换行计入 n-1）；域规则文档/实现对齐（`[a-z0-9-]{1,64}`）+ 旧 `_` 域名开库自动迁移；`PhraseBookDomain.validate` 单一入口；词条超限抛 `tooManyEntries`；user-lm 落盘加目录 fsync；daemon L2 探测改 (mtime, size)（含同 mtime 重写测试）；0 字节 user-lm 视为损坏而非 no-op；gzip 跨语言固件（Swift 编码 → Python 解码）；证据：swift test 513 passed、pytest 732 passed、macOS Debug BUILD SUCCEEDED；终审（glm-5.3:max）16 项修复中 15 项闭环、其余 7 条 P3 已全部修复；跨家族复核（deepseek）因终端被用户接管未交付，标 INCOMPLETE |

## 不在当前任务表

教师软标签蒸馏、领域 adapter、开放式续写、商业定价和跨平台同步发布不是当前
MVP 缺口。只有新的真实数据证明必要时，才新建任务；不保留长期“也许会做”的
占位项。例外：LM-002 已在任务表内，其数据供给前置（LM-003 反馈采集、LM-004
蒸馏管道）随任务创建；二者只服务 LM-002，不扩展为教师平台或领域 adapter 路线。

## 维护规则

1. 一项任务只有在完成条件可复现时才能转为 `DONE-INTERNAL`。
2. 代码完成、测试完成、真实环境验收和产品发布是不同状态，禁止互相替代。
3. 新发现的阻塞直接更新现有任务，不追加对话或日记式记录。
4. 完成项只保留稳定里程碑；临时命令、一次性哈希和旧测试计数不进入本文件。
5. 每次状态变化同步更新日期；README 只摘要当前交付边界，不复制逐项任务状态。
